"""Validated shared data types. Stored timestamps are timezone-aware UTC."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any, Literal
from uuid import uuid4
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, field_validator

PHONE_PATTERN = r"^\+[1-9]\d{7,14}$"
ScheduleStatus = Literal["pending", "sent", "failed", "cancelled"]


def utc_now() -> datetime:
    return datetime.now(UTC)


class Model(BaseModel):
    model_config = ConfigDict(extra="forbid", validate_assignment=True)


class BlackoutHours(Model):
    start: int = Field(default=22, ge=0, le=23)
    end: int = Field(default=7, ge=0, le=23)


class Contact(Model):
    name: str = Field(min_length=1)
    phone: str = Field(pattern=PHONE_PATTERN)
    aliases: list[str] = Field(default_factory=list)
    service: Literal["iMessage", "SMS"] = "iMessage"
    group: list[str] = Field(default_factory=list)
    timezone: str = "America/Los_Angeles"
    metadata: dict[str, Any] = Field(default_factory=dict)
    templates: dict[str, str] = Field(default_factory=dict)
    blackout_hours: BlackoutHours | None = None

    @field_validator("timezone")
    @classmethod
    def valid_timezone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError) as exc:
            raise ValueError("Expected an IANA timezone name") from exc
        return value


class ContactList(Model):
    contacts: list[Contact] = Field(default_factory=list)


class ResolveResult(Model):
    status: Literal["resolved", "ambiguous", "not_found"]
    contact: Contact | None = None
    candidates: list[Contact] = Field(default_factory=list)


class GuardrailConfig(Model):
    blackout_hours: BlackoutHours = Field(default_factory=BlackoutHours)
    max_messages_per_hour: int = Field(default=20, gt=0)
    max_messages_per_contact_per_hour: int = Field(default=5, gt=0)
    max_batch_size: int = Field(default=10, gt=0)
    max_message_length: int = Field(default=2000, gt=0)
    require_confirmation: bool = True
    dry_run_mode: bool = False
    duplicate_window_minutes: int = Field(default=60, gt=0)


class AppConfig(Model):
    ollama_model: str = "gemma3:12b"
    ollama_host: str = "http://localhost:11434"
    data_dir: str = "~/.imsg-agent"
    max_retries: int = Field(default=3, ge=0)
    guardrails: GuardrailConfig = Field(default_factory=GuardrailConfig)


class RuleResult(Model):
    rule: str
    decision: Literal["approve", "warn", "block"]
    reason: str = ""


class GuardrailResult(Model):
    decision: Literal["approve", "warn", "block"]
    results: list[RuleResult] = Field(default_factory=list)
    summary: str = ""
    requires_confirmation: bool = True


class SendMessageArgs(Model):
    to: str = Field(min_length=1)
    message: str = Field(min_length=1)


class ScheduleMessageArgs(SendMessageArgs):
    send_at: datetime
    cron: str | None = None

    @field_validator("send_at")
    @classmethod
    def aware_datetime(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("Timestamp must include a timezone")
        return value.astimezone(UTC)

    @field_validator("cron")
    @classmethod
    def valid_cron(cls, value: str | None) -> str | None:
        if value is not None:
            from croniter import croniter

            if len(value.split()) != 5 or not croniter.is_valid(value):
                raise ValueError("Expected a valid five-field cron expression")
        return value


class ScheduledMessage(ScheduleMessageArgs):
    to: str = Field(pattern=PHONE_PATTERN)
    id: str = Field(default_factory=lambda: "msg-" + uuid4().hex)
    status: ScheduleStatus = "pending"
    service: Literal["iMessage", "SMS"] = "iMessage"
    timezone: str = "America/Los_Angeles"
    attempts: int = Field(default=0, ge=0)
    last_error: str | None = None
    created_at: datetime = Field(default_factory=utc_now)

    _valid_timezone = field_validator("timezone")(Contact.valid_timezone.__func__)
    _aware_created = field_validator("created_at")(ScheduleMessageArgs.aware_datetime.__func__)


class CancelScheduledArgs(Model):
    id: str = Field(min_length=1)


class ListScheduledArgs(Model):
    status: ScheduleStatus | None = None


class ResolveContactArgs(Model):
    query: str = Field(min_length=1)


class ListContactsArgs(Model):
    group: str | None = None


class GetRecentMessagesArgs(Model):
    contact: str = Field(min_length=1)
    limit: int = Field(default=10, ge=1, le=100)


class SuggestReplyArgs(GetRecentMessagesArgs):
    instruction: str = ""


class MessageRecord(Model):
    text: str
    sent_at: datetime
    is_from_me: bool


class ConversationSummary(Model):
    contact: str
    latest_message: MessageRecord | None = None


class ValidationResult(Model):
    valid: bool
    args: dict[str, Any] = Field(default_factory=dict)
    errors: list[str] = Field(default_factory=list)


class FallbackResult(Model):
    tool_name: str
    args: dict[str, Any]


class SendResult(Model):
    status: Literal["submitted", "dry_run"]
    service: Literal["iMessage", "SMS"]


TOOL_ARG_MODELS = {
    "send_message_now": SendMessageArgs,
    "schedule_message": ScheduleMessageArgs,
    "cancel_scheduled": CancelScheduledArgs,
    "list_scheduled": ListScheduledArgs,
    "resolve_contact": ResolveContactArgs,
    "list_contacts": ListContactsArgs,
    "get_recent_messages": GetRecentMessagesArgs,
    "suggest_reply": SuggestReplyArgs,
}
