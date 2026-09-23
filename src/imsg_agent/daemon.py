"""Foreground worker and launchd integration. No model service is needed."""

import fcntl
import os
import plistlib
import signal
import subprocess
import sys
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path

from imsg_agent.logger import get_logger
from imsg_agent.messenger import Messenger
from imsg_agent.models import utc_now
from imsg_agent.scheduler import TickScheduler
from imsg_agent.store import Store

LABEL = "com.imsg-agent.daemon"


def notify(title, message):
    script = (
        "on run argv\ndisplay notification (item 2 of argv) with title (item 1 of argv)\nend run"
    )
    subprocess.run(
        ["/usr/bin/osascript", "-e", script, title, message],
        check=True,
        capture_output=True,
        timeout=10,
    )


@contextmanager
def worker_lock(data_dir):
    path = Path(data_dir) / "daemon.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError("A daemon is already running for this data directory") from exc
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def worker_running(data_dir):
    path = Path(data_dir) / "daemon.lock"
    if not path.exists():
        return False
    with path.open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(handle, fcntl.LOCK_UN)
        return False


class Daemon:
    def __init__(self, config, store=None, messenger=None):
        self.config = config
        self.store = store or Store(Path(config.data_dir) / "imsg_agent.db")
        self.scheduler = TickScheduler(self.store, messenger or Messenger(), config, notify=notify)
        self.logger = get_logger("imsg_agent.daemon", Path(config.data_dir) / "daemon.log")
        self.stop_file = Path(config.data_dir) / "daemon.stop"

    def _handle_signal(self, signum, frame):
        self.scheduler.stop_event.set()

    def run(self):
        with worker_lock(self.config.data_dir):
            self.stop_file.unlink(missing_ok=True)
            previous = {
                sig: signal.signal(sig, self._handle_signal)
                for sig in (signal.SIGTERM, signal.SIGINT)
            }
            last_heartbeat = None
            self.logger.info("Daemon started")
            try:
                while not self.scheduler.stop_event.is_set():
                    if self.stop_file.exists():
                        break
                    self.scheduler.tick()
                    now = utc_now()
                    if last_heartbeat is None or (now - last_heartbeat).total_seconds() >= 300:
                        pending = self.store.get_pending()
                        self.store.update_heartbeat(
                            os.getpid(), len(pending), pending[0].send_at if pending else None
                        )
                        last_heartbeat = now
                    self.scheduler.stop_event.wait(self.scheduler.interval)
            finally:
                for sig, handler in previous.items():
                    signal.signal(sig, handler)
                self.stop_file.unlink(missing_ok=True)
                self.store.update_heartbeat(0, len(self.store.get_pending()))
                self.store.close()
                self.logger.info("Daemon stopped")


class LaunchAgent:
    def __init__(self, config_path, data_dir, agents_dir=None, runner=subprocess.run):
        self.config_path = Path(config_path).expanduser().resolve()
        self.data_dir = Path(data_dir).expanduser().resolve()
        self.path = (
            Path(agents_dir) if agents_dir else Path.home() / "Library/LaunchAgents"
        ) / f"{LABEL}.plist"
        self.runner = runner
        self.domain = f"gui/{os.getuid()}"

    def payload(self):
        return {
            "Label": LABEL,
            "ProgramArguments": [
                os.path.abspath(sys.executable),
                "-m",
                "imsg_agent",
                "daemon",
                "start",
                "--foreground",
                "--config",
                str(self.config_path),
            ],
            "RunAtLoad": True,
            "KeepAlive": {"SuccessfulExit": False},
            "ThrottleInterval": 10,
            "StandardOutPath": str(self.data_dir / "daemon.log"),
            "StandardErrorPath": str(self.data_dir / "daemon-error.log"),
        }

    def install(self):
        if self.path.exists():
            raise ValueError(
                "Launch agent already installed; uninstall it before replacing its configuration"
            )
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.data_dir.mkdir(parents=True, exist_ok=True)
        with self.path.open("xb") as handle:
            plistlib.dump(self.payload(), handle)
        return str(self.path)

    def _command(self, *args, check=True):
        return self.runner(
            ["/bin/launchctl", *args], check=check, capture_output=True, text=True, timeout=15
        )

    def loaded(self):
        return self._command("print", f"{self.domain}/{LABEL}", check=False).returncode == 0

    def _check_installed_config(self):
        if not self.path.exists():
            raise ValueError("Install the launch agent first with daemon install")
        with self.path.open("rb") as handle:
            payload = plistlib.load(handle)
        if payload.get("ProgramArguments") != self.payload()["ProgramArguments"]:
            raise ValueError("Installed launch agent uses a different interpreter or configuration")

    def start(self):
        self._check_installed_config()
        if worker_running(self.data_dir):
            return "Already running"
        if self.loaded():
            self._command("kickstart", f"{self.domain}/{LABEL}")
        else:
            self._command("bootstrap", self.domain, str(self.path))
        return "Start requested; use daemon status to verify startup"

    def stop(self):
        if self.path.exists():
            self._check_installed_config()
            if self.loaded():
                self._command("bootout", f"{self.domain}/{LABEL}")
        if worker_running(self.data_dir):
            (self.data_dir / "daemon.stop").touch()
        return "Stop requested; an in-flight submission may finish before shutdown"

    def uninstall(self):
        self.stop()
        self.path.unlink(missing_ok=True)
        return "Launch agent removed; schedules and logs preserved"


def status(config):
    path = Path(config.data_dir) / "imsg_agent.db"
    heartbeat = None
    if path.exists():
        store = Store(path)
        try:
            heartbeat = store.get_heartbeat()
        finally:
            store.close()
    return {
        "running": worker_running(config.data_dir),
        "heartbeat": heartbeat,
        "heartbeat_age_seconds": (
            utc_now() - datetime.fromisoformat(heartbeat["updated_at"])
        ).total_seconds()
        if heartbeat
        else None,
    }
