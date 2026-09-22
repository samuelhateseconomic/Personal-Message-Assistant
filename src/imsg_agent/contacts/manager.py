"""Contact resolution with explicit ambiguity and manual live reload."""

import re
from pathlib import Path

from rapidfuzz.fuzz import WRatio

from imsg_agent.models import PHONE_PATTERN, Contact, ContactList, ResolveResult


class ContactManager:
    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()
        self.contacts: list[Contact] = []
        self.reload()

    def reload(self) -> None:
        # Validate first so a malformed edit does not destroy the loaded contacts.
        data = ContactList.model_validate_json(self.path.read_text(encoding="utf-8"))
        self.contacts = data.contacts

    @staticmethod
    def _result(matches: list[Contact]) -> ResolveResult:
        if len(matches) == 1:
            return ResolveResult(status="resolved", contact=matches[0])
        if matches:
            return ResolveResult(status="ambiguous", candidates=matches)
        return ResolveResult(status="not_found")

    def resolve(self, query: str) -> ResolveResult:
        query = query.strip()
        key = query.casefold()
        if not key:
            return self._result([])
        for matches in (
            [c for c in self.contacts if c.name.casefold() == key],
            [c for c in self.contacts if key in [a.casefold() for a in c.aliases]],
            [c for c in self.contacts if c.phone == query],
        ):
            if matches:
                return self._result(matches)
        if re.fullmatch(PHONE_PATTERN, query):
            return self._result([Contact(name=query, phone=query)])
        # Never fuzzy-match a malformed phone number to a person.
        if query.startswith("+") or query.replace(" ", "").isdigit():
            return self._result([])
        scores = [
            (c, max(WRatio(key, n.casefold()) for n in [c.name, *c.aliases])) for c in self.contacts
        ]
        best = max((score for _, score in scores), default=0)
        return self._result([c for c, score in scores if score >= 70 and score >= best - 5])

    def get_group(self, group_name: str) -> list[Contact]:
        return [
            c for c in self.contacts if group_name.casefold() in [g.casefold() for g in c.group]
        ]

    def get_template(self, contact_name: str, template_key: str) -> str | None:
        result = self.resolve(contact_name)
        return result.contact.templates.get(template_key) if result.contact else None

    def get_summary(self) -> dict:
        return {
            "count": len(self.contacts),
            "groups": sorted({group for c in self.contacts for group in c.group}),
        }
