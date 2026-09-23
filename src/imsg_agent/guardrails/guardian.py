"""Audit every evaluated mutation; confirmation cannot be disabled by model arguments."""

import json

from imsg_agent.guardrails.rules import RULES
from imsg_agent.models import GuardrailResult, utc_now


class Guardian:
    def __init__(self, config, store, now=utc_now):
        self.config, self.store, self.now = config, store, now
        self.rules = [rule() for rule in RULES]

    def validate(self, tool_name, args):
        results = []
        for rule in self.rules:
            result = rule.check(tool_name, args, self.config, self.store, self.now())
            results.append(result)
            if result.decision == "block":
                break
        decision = (
            "block"
            if any(r.decision == "block" for r in results)
            else "warn"
            if any(r.decision == "warn" for r in results)
            else "approve"
        )
        summary = json.dumps({"action": tool_name, **args}, ensure_ascii=False, indent=2)
        warnings = "\n".join(r.reason for r in results if r.decision != "approve")
        self.store.log_audit(tool_name, args, decision, warnings)
        return GuardrailResult(
            decision=decision,
            results=results,
            summary=summary + "\n" + warnings,
            requires_confirmation=True,
        )
