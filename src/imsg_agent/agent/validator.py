"""Tool-Call Validator — Pydantic schema enforcement for model outputs.

Validates tool call arguments from Ollama against Pydantic models.
Auto-repairs common model mistakes:
- Misspelled field names (rapidfuzz matching)
- Natural language dates → ISO 8601 (dateparser)
- String-to-number coercion
- Missing ID prefixes

If validation + repair fails after 2 retries, control passes
to the regex fallback parser.
"""
from __future__ import annotations

# TODO: Implement ToolCallValidator class
# TODO: Implement validate(tool_name, args) -> ValidationResult
# TODO: Implement try_repair(tool_name, args) -> dict | None
# TODO: Implement _fix_field_names() using rapidfuzz
# TODO: Implement _parse_dates() using dateparser
# TODO: Implement _coerce_types()
