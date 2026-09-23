"""launchd and daemon tests use temporary paths and a mocked command runner."""

import os
import plistlib
from unittest.mock import Mock

import pytest

from imsg_agent.daemon import Daemon, LaunchAgent, status, worker_lock, worker_running
from imsg_agent.models import AppConfig
from imsg_agent.store import Store


def test_worker_singleton_and_stale_file(tmp_path):
    assert not worker_running(tmp_path)
    with worker_lock(tmp_path):
        assert worker_running(tmp_path)
        with pytest.raises(RuntimeError), worker_lock(tmp_path):
            pass
    assert not worker_running(tmp_path)


def test_install_start_stop_uninstall(tmp_path):
    runner = Mock()
    runner.return_value.returncode = 1
    manager = LaunchAgent(tmp_path / "config.json", tmp_path / "data", tmp_path / "agents", runner)
    installed = manager.install()
    with open(installed, "rb") as handle:
        payload = plistlib.load(handle)
    assert os.path.isabs(payload["ProgramArguments"][0])
    assert payload["ProgramArguments"][-1] == str(tmp_path / "config.json")
    assert "VENV_PYTHON" not in str(payload)
    runner.assert_not_called()
    with pytest.raises(ValueError):
        manager.install()
    manager.start()
    assert runner.call_args.args[0][1] == "bootstrap"
    runner.return_value.returncode = 0
    manager.stop()
    assert runner.call_args.args[0][1] == "bootout"
    manager.uninstall()
    assert not manager.path.exists()


def test_install_preserves_virtualenv_path(tmp_path, monkeypatch):
    monkeypatch.setattr("imsg_agent.daemon.sys.executable", "/project/.venv/bin/python")
    manager = LaunchAgent(tmp_path / "config.json", tmp_path, tmp_path / "agents")
    assert manager.payload()["ProgramArguments"][0] == "/project/.venv/bin/python"


def test_status_and_stop_foreground_request(tmp_path):
    config = AppConfig(data_dir=str(tmp_path))
    assert not status(config)["running"]
    manager = LaunchAgent(tmp_path / "config.json", tmp_path, tmp_path / "agents", Mock())
    with worker_lock(tmp_path):
        manager.stop()
        assert (tmp_path / "daemon.stop").exists()
        assert status(config)["running"]


def test_daemon_heartbeat_and_clean_shutdown(tmp_path):
    config = AppConfig(data_dir=str(tmp_path))
    store = Store(tmp_path / "imsg_agent.db")
    daemon = Daemon(config, store=store, messenger=Mock(dry_run=True))

    def tick():
        daemon.scheduler.stop_event.set()
        return []

    daemon.scheduler.tick = Mock(side_effect=tick)
    daemon.run()
    assert not worker_running(tmp_path)
    assert store.get_heartbeat()["pid"] == 0


def test_wrong_config_cannot_replace_or_stop_installed_agent(tmp_path):
    runner = Mock()
    manager = LaunchAgent(tmp_path / "one.json", tmp_path / "data", tmp_path / "agents", runner)
    manager.install()
    other = LaunchAgent(tmp_path / "two.json", tmp_path / "data", tmp_path / "agents", runner)
    with pytest.raises(ValueError):
        other.stop()
    runner.assert_not_called()
    assert manager.path.exists()
