"""A limited preference vocabulary cannot encode tool permissions or actions."""

from typing import Literal

from pydantic import Field, model_validator

from imsg_agent.models import Model

PREFERENCE_VALUES = {
    "language": (
        "English",
        "Vietnamese",
        "Spanish",
        "French",
        "German",
        "Italian",
        "Portuguese",
        "Japanese",
        "Korean",
        "Chinese",
        "Arabic",
        "Hindi",
    ),
    "tone": ("warm", "neutral", "direct", "friendly", "professional"),
    "length": ("short", "medium", "detailed"),
    "emoji": ("none", "light", "expressive"),
    "formality": ("casual", "neutral", "formal"),
}


class Preference(Model):
    key: Literal["language", "tone", "length", "emoji", "formality"]
    value: str = Field(min_length=1, max_length=40)

    @model_validator(mode="after")
    def allowed_value(self):
        choices = PREFERENCE_VALUES[self.key]
        canonical = next((v for v in choices if v.casefold() == self.value.casefold()), None)
        if canonical is None:
            raise ValueError(f"{self.key} must be one of: {', '.join(choices)}")
        # Avoid recursive assignment validation.
        object.__setattr__(self, "value", canonical)
        return self
