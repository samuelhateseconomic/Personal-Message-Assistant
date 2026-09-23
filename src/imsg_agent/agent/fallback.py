"""Conservative, anchored command grammar used without an available model."""

import re

from imsg_agent.agent.validator import ToolCallValidator
from imsg_agent.models import FallbackResult


class FallbackParser:
    def __init__(self, validator=None):
        self.validator = validator or ToolCallValidator()

    def parse(self, user_input):
        patterns = [
            (r'send "(?P<message>[^"\n]+)" to (?P<to>[^\n]+)', "send_message_now"),
            (
                r'schedule "(?P<message>[^"\n]+)" to (?P<to>.+?) at (?P<send_at>[^\n]+)',
                "schedule_message",
            ),
            (r"cancel (?P<id>msg-[a-zA-Z0-9-]+)", "cancel_scheduled"),
            (r"list(?: (?P<status>pending|sending|sent|failed|cancelled))?", "list_scheduled"),
            (r"what did (?P<contact>[^\n]+?) say\??", "get_recent_messages"),
            (r"reply to (?P<contact>[^\n]+)", "suggest_reply"),
        ]
        for pattern, name in patterns:
            match = re.fullmatch(pattern, user_input.strip(), flags=re.IGNORECASE)
            if match:
                args = {k: v for k, v in match.groupdict().items() if v is not None}
                if "status" in args:
                    args["status"] = args["status"].lower()
                checked = self.validator.validate(name, args)
                if checked.valid:
                    return FallbackResult(tool_name=name, args=checked.args)
        return None
