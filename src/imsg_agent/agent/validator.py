"""Validate tool arguments; repair unambiguous field typos and natural-language dates."""

import re
from datetime import UTC, datetime
from zoneinfo import ZoneInfo

import dateparser
from pydantic import ValidationError
from rapidfuzz.fuzz import ratio

from imsg_agent.models import TOOL_ARG_MODELS, ValidationResult, utc_now


class ToolCallValidator:
    def __init__(self, timezone="America/Los_Angeles", now=utc_now):
        ZoneInfo(timezone)
        self.timezone = timezone
        self.now = now

    def validate(self, tool_name, args):
        model = TOOL_ARG_MODELS.get(tool_name) if isinstance(tool_name, str) else None
        if model is None or not isinstance(args, dict):
            return ValidationResult(
                valid=False, errors=["Unknown tool or arguments are not an object"]
            )
        try:
            repaired = self.try_repair(tool_name, args)
            parsed = model.model_validate(repaired)
            return ValidationResult(valid=True, args=parsed.model_dump(mode="json"))
        except (ValueError, TypeError, ValidationError) as exc:
            return ValidationResult(valid=False, errors=[str(exc)])

    def try_repair(self, tool_name, args):
        fields = TOOL_ARG_MODELS[tool_name].model_fields
        result = dict(args)
        for key in list(result):
            if key not in fields:
                matches = [f for f in fields if ratio(key, f) >= 80]
                if len(matches) == 1 and matches[0] not in result:
                    result[matches[0]] = result.pop(key)
        if "send_at" in result and isinstance(result["send_at"], str):
            value = result["send_at"]
            try:
                parsed = datetime.fromisoformat(value)
            except ValueError:
                parsed = dateparser.parse(
                    value,
                    settings={
                        "RELATIVE_BASE": self.now().astimezone(ZoneInfo(self.timezone)),
                        "TIMEZONE": self.timezone,
                        "RETURN_AS_TIMEZONE_AWARE": True,
                        "PREFER_DATES_FROM": "future",
                    },
                )
            if parsed is None:
                raise ValueError("Cannot understand send_at; specify a date and time")
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=ZoneInfo(self.timezone))
            # Reject nonexistent and ambiguous wall times unless an explicit offset was supplied.
            local = parsed.astimezone(ZoneInfo(self.timezone))
            explicit_offset = bool(re.search(r"(Z|[+-]\d\d:\d\d)$", value))
            if not explicit_offset:
                wall = parsed.replace(tzinfo=None)
                zone = ZoneInfo(self.timezone)
                a, b = wall.replace(tzinfo=zone, fold=0), wall.replace(tzinfo=zone, fold=1)
                if (
                    a.utcoffset() != b.utcoffset()
                    or local.astimezone(UTC).astimezone(zone).replace(tzinfo=None) != wall
                ):
                    raise ValueError(
                        "Ambiguous or nonexistent local time; include an explicit UTC offset"
                    )
            result["send_at"] = parsed.isoformat()
        return result
