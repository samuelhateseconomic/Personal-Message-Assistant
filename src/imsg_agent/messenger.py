"""Messages.app bridge. Success means submitted, not confirmed delivery."""

import platform
import re
import subprocess
from typing import Literal

from imsg_agent.models import PHONE_PATTERN, SendResult


class MessengerError(RuntimeError):
    """Submission failed or its outcome is unknown; do not blindly resend."""


class Messenger:
    def __init__(self, dry_run: bool = False, timeout: float = 30):
        self.dry_run = dry_run
        self.timeout = timeout

    @staticmethod
    def _escape(value: str) -> str:
        return value.replace("\\", "\\\\").replace('"', '\\"')

    @staticmethod
    def _detect_version() -> str:
        return platform.mac_ver()[0]

    def ensure_messages_running(self) -> None:
        subprocess.run(
            ["/usr/bin/open", "-a", "Messages"],
            check=True,
            capture_output=True,
            timeout=self.timeout,
        )

    def send(
        self, to: str, message: str, service: Literal["iMessage", "SMS"] = "iMessage"
    ) -> SendResult:
        if not re.fullmatch(PHONE_PATTERN, to):
            raise ValueError("Recipient must be an E.164 phone number")
        if not message.strip() or "\x00" in message:
            raise ValueError("Message must be nonempty and cannot contain NUL")
        if service not in ("iMessage", "SMS"):
            raise ValueError("Unsupported messaging service")
        if self.dry_run:
            return SendResult(status="dry_run", service=service)
        if platform.system() != "Darwin":
            raise MessengerError("Sending requires macOS")
        # Pass content as argv, never interpolate user text into AppleScript code.
        # Do not retry via SMS after an uncertain iMessage submission.
        script = """on run argv
    tell application "Messages"
        set selectedService to first service whose service type is SERVICE_TYPE
        set recipientBuddy to buddy (item 1 of argv) of selectedService
        send (item 2 of argv) to recipientBuddy
    end tell
end run""".replace("SERVICE_TYPE", service)
        try:
            self.ensure_messages_running()
            subprocess.run(
                ["/usr/bin/osascript", "-e", script, to, message],
                check=True,
                capture_output=True,
                text=True,
                timeout=self.timeout,
            )
        except (subprocess.SubprocessError, OSError) as exc:
            raise MessengerError(
                "Messages submission failed or timed out; check Messages "
                "and Automation permission before retrying"
            ) from exc
        return SendResult(status="submitted", service=service)
