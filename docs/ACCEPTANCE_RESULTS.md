# Acceptance results — 2026-09-24

Scope: draft-only acceptance, explicitly selected by the user. No messages were sent,
no schedules were created in the normal database, and no delivery workers were started
or installed during this run. Local history/model checks ran outside the execution
sandbox with authorization. Preferences and chat audit state used temporary databases
that were removed afterward. Conversation text and contact details are omitted here.

| Check | Result | Evidence and limits |
| --- | --- | --- |
| Automated regression | PASS | 173 tests passed after prompt changes; Ruff lint/format and diff checks clean |
| Preflight | PASS | Contact validation passed; Messages schema readable; local Ollama responds; gemma3:12b installed |
| Selected history | PASS | Identity resolution and bounded direct-history retrieval passed; not an exhaustive macOS compatibility test |
| English follow-up | PASS | Live model returned a valid brief follow-up with source IDs accepted by the deterministic gate |
| Vietnamese override | PASS after correction | Initial output ignored the override; explicit output-language instruction in the system prompt produced Vietnamese on retest |
| Preference isolation | PASS | Temporary saved English preference remained English after Vietnamese override; no feedback automatically saved |
| Chat contact lookup | PASS | Observed live resolve_contact tool call |
| Chat guarded send preview | CONDITIONAL PASS | Explicit contact-name wording produced resolve_contact then send_message_now; receipt was dry_run with exact requested text |
| Short chat wording | LIMITATION | An ambiguously phrased request was interpreted as missing a recipient; no tool action occurred. Use explicit “contact named” wording or the direct CLI |
| Chat reset | PASS | In-process history cleared |
| Memory/feedback/scheduler edge cases | AUTOMATED PASS | Covered by regression suite; not a claim of live scheduled delivery |
| Real delivery, recurrence, launchd/login | DEFERRED | User chose draft-only testing |

Changes made during acceptance:

- Draft prompt states the effective output language explicitly and separates it from
  the language of quoted conversation/task text. Explicit user language instructions
  retain precedence. Model compliance is still probabilistic, not language detection.
- Chat instructions explain that send_message_now performs the guarded preview and
  exact-action confirmation, and that suggest_reply handles history-based drafts.
  Neither instruction bypasses confirmation or the dry-run mechanism.
- README and skeleton updated to distinguish passed live checks from pending tests.

Direct submission has been exercised; independent recipient receipt is not established
by a submission result. The outgoing-latest-message gate was also exercised. No recipient
identity or conversation details are retained in this report.

Remaining work: wider model evaluation (including normal replies to new incoming
messages), robustness for ambiguous conversational wording, and the explicitly approved
live delivery/daemon tests in ACCEPTANCE_TESTS.md. Current results do not establish
reliable routing for every phrasing, factual accuracy for every draft, or production
readiness for unattended messaging. These results accompany the native transformation
milestone; publishing the source does not expand the verified behavior described above.
