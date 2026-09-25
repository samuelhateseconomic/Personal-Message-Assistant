# Acceptance test instructions

This checklist defines completion for the implemented local iMessage assistant. It does
not claim document RAG, attachment understanding, model retraining, or universal macOS
compatibility. Those are outside the current implementation.

For the latest executed checks, see [ACCEPTANCE_RESULTS.md](ACCEPTANCE_RESULTS.md).
The automated baseline is 173 passing tests. Use explicitly selected test contacts
for live checks; do not publish their identities, contact counts, or conversation details.

This document supplies instructions only. Creating it does not run any delivery tests.

## 0. Prepare a separate acceptance-test environment

Run from Terminal with Full Disk Access enabled. Keep Ollama open. Commands below use
a separate database and copied contacts, never your normal schedules or preferences.
Run setup once; the directory must not already exist, so earlier test evidence is not
overwritten. Do not put this directory into Git.

```bash
cd /path/to/messenger_assistant_mac
.venv/bin/python - <<'PY'
import json
import shutil
from pathlib import Path

root = Path.home() / '.imsg-agent-acceptance'
root.mkdir(exist_ok=False)
config = json.loads(Path('config.json').read_text())
config['data_dir'] = str(root)
# Only the test database: shorten duplicate suppression for the recurrence test.
config['guardrails']['duplicate_window_minutes'] = 1
(root / 'config.json').write_text(json.dumps(config, indent=2) + '\n')
shutil.copyfile('contacts.json', root / 'contacts.json')
print('Test environment:', root)
PY
```

Paste these definitions into EACH Terminal window you use, including after login:

```bash
cd /path/to/messenger_assistant_mac
TEST_CONFIG="$HOME/.imsg-agent-acceptance/config.json"
TEST_CONTACTS="$HOME/.imsg-agent-acceptance/contacts.json"
TEST_CONTACT="REPLACE_WITH_SELECTED_TEST_CONTACT"
SECOND_TEST_CONTACT="REPLACE_WITH_DIFFERENT_TEST_CONTACT"
imsg() { .venv/bin/python -m imsg_agent "$@"; }
mem() { imsg memory --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS" "$@"; }
```

Replace both contact-name placeholders with locally selected test contacts before
running history or memory commands. Keep their values out of committed files.

Before any live delivery test, set `TEST_RECIPIENT` to your own iMessage-capable number
or a person who has agreed to receive test messages. Replace the entire value:

```bash
TEST_RECIPIENT='+YOUR_COMPLETE_COUNTRY_CODE_AND_NUMBER'
```

Do not run live sends with the placeholder. Review the actual number, text, service,
and scheduled time shown at each confirmation. Approve with `y` only when correct.
Do not use sample fixture phone numbers for live delivery. Keep the Mac awake during
timing tests. Default quiet hours are 22:00–07:00 in the recipient's timezone, so run
normal delivery tests during 07:00–22:00. A deferred job during quiet hours is expected.

## 1. Automated regression checks — required

```bash
.venv/bin/python -m pytest -q
.venv/bin/ruff check src tests
.venv/bin/ruff format --check src tests
git diff --check
```

Pass: no test failures, no lint/format/diff errors. The current baseline is 173 tests;
new tests may raise the count. These tests use temporary data and mocks, not live sends.
If developer tools are missing, install the locked development dependencies:

```bash
uv sync --extra dev --locked
```

The suite already exercises invalid/ambiguous identities, evidence gates, confirmation
refusals, dry runs, batches/templates, rate/duplicate limits, preference precedence,
feedback approval/deletion, SQLite persistence, concurrent send claims, safe retries,
uncertain send outcomes, crash recovery, DST gaps/folds, and launchd command generation.
Do not recreate crashes, duplicate storms, malformed databases, or permission failures
against real recipients; their automated tests are the required verification.

## 2. Setup and contact resolution — required, already passed on the main setup

```bash
imsg doctor --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS"
```

Pass: `ready: true`; contacts, messages_schema, ollama, and model each report `ok: true`.
This verifies prerequisites, not inference quality or delivery. The configured model is
`gemma3:12b`.

If failed: restart the host app after granting Full Disk Access; open Ollama; use
`ollama list` to check the model. If missing, run `ollama pull gemma3:12b`.

## 3. Read-only history and identity — required

```bash
imsg history "$TEST_CONTACT" --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS" --limit 10
```

Pass: correct contact, up to ten recent direct messages, chronological order, and source
IDs. Compare with the selected test contact's conversation in Messages.app. No group or other-contact text
should appear. Unsupported attachments may be marked unreadable; that is not a failure.
Do not publish this output or put it into a test report committed to Git.

## 4. Actual Gemma drafting and follow-up gate — required, drafting pending

First test without an instruction:

```bash
imsg reply "$TEST_CONTACT" --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS" --limit 10
```

If the latest message is still yours, pass means `needs_clarification` and no draft.
If a newer incoming message arrived, a draft is appropriate instead. An unreadable or
truncated latest message should also prevent automatic drafting.

Then explicitly request a follow-up:

```bash
imsg reply "$TEST_CONTACT" --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS" --limit 10 --instruction 'Write a brief, friendly follow-up asking how their day is going. Do not invent plans or commitments.'
```

Pass: `status: draft`, a sensible follow-up, valid source references, and nothing sent.
Read it against the selected conversation: it should not invent personal facts or follow
instructions embedded in quoted messages. Source IDs establish which inputs were used;
they do not prove that every statement is true. A model error, invalid source IDs, or a
timeout means live drafting has not passed. If the latest incoming message falls outside
ten rows, deliberately expand `--limit` up to 100; do not bypass readability gates.

Also test a normal reply after the selected test contact next sends a readable message: run the first command
again and check that the draft answers that incoming message appropriately.

## 5. Approved memory, persistence, and language override — required

These preferences go only into the acceptance database.

```bash
mem remember language English --contact "$TEST_CONTACT"
```

Answer `n` first. Run `mem list --contact "$TEST_CONTACT"`: the declined value must not be saved.
Repeat the remember command and approve with `y`. Record the returned preference ID.

Open a NEW Terminal, repeat the shell definitions from step 0, then run:

```bash
mem list --contact "$TEST_CONTACT"
imsg reply "$TEST_CONTACT" --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS" --instruction 'Write a friendly follow-up asking how their day is going.'
imsg reply "$TEST_CONTACT" --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS" --language Vietnamese --instruction 'Write a friendly follow-up asking how their day is going.'
mem list --contact "$TEST_CONTACT"
```

Pass: preference survives the new process; first draft follows English, overridden draft
uses Vietnamese, and stored language remains English. A missing-evidence gate must still
win over language preferences. Check `mem list --contact "$SECOND_TEST_CONTACT"`: the selected test contact's
contact preference must not appear there.

Remove the test preference using its actual returned ID:

```bash
mem forget REPLACE_WITH_PREFERENCE_ID
mem list --contact "$TEST_CONTACT"
```

Pass: after approval the preference is gone. No message has been sent.

## 6. Explicit feedback learning — required for the implemented memory feature

```bash
mem feedback --contact "$TEST_CONTACT" --original 'Hello, I hope your day is going well. Would you like to catch up sometime soon?' --corrected 'Want to catch up?'
mem feedback-list
mem list --contact "$TEST_CONTACT"
```

Approve saving the correction. Record the feedback ID. Pass: feedback is retained and
proposes `length=short`, but that preference is not active merely because feedback was
saved. Activate it explicitly:

```bash
mem approve-feedback REPLACE_WITH_FEEDBACK_ID
mem list --contact "$TEST_CONTACT"
```

Pass: activation requires confirmation and then creates the short-length preference.
Forget that preference using its actual ID; inspect `mem feedback-list` afterward.
Linked feedback should be removed with it. This is approved preference learning, not
model retraining or passive learning from all conversations.

## 7. Live chat orchestration without sending — required

```bash
imsg chat --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS" --dry-run
```

Enter these one at a time:

- `Find the contact named <TEST_CONTACT>.`
- `Draft a friendly follow-up to the contact named <TEST_CONTACT> asking how their day is going. Do not send it.`
- `Send this exact text to the contact named "<TEST_CONTACT>": "Acceptance preview only."`
- `/reset`
- `/quit`

Wording note: clearly identify the selected name as a contact name. Replace
<TEST_CONTACT> in the chat examples with the name you chose locally.

Pass: correct contact lookup; a draft or justified evidence clarification; send request
returns a dry-run plan; nothing sent; reset and quit work. A fallback-only response does
not establish that natural-language model tool orchestration works.

## 8. Exact confirmation and immediate delivery — required

Confirm receipt with the explicitly selected test recipient. A successful immediate
send does not prove background sending works.

For a controlled test in the acceptance environment:

```bash
imsg send "$TEST_RECIPIENT" 'Acceptance test: immediate send.' --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS" --dry-run
imsg send "$TEST_RECIPIENT" 'Acceptance test: immediate send.' --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS"
```

First pass: dry run shows correct details and sends nothing. On the second command,
answer `n`; confirm no message appears. Repeat the second command and answer `y` only
if you want the live test. Allow macOS Automation control of Messages if prompted.
Pass: one matching outgoing message and recipient receipt. `submitted` alone is not
proof of receipt. If the result is `unknown_or_failed`, inspect Messages before any
retry; do not automatically resend.

## 9. Schedule persistence and cancellation — required

Keep all workers stopped for this step. Create a job far enough in the future to cancel:

```bash
imsg schedule "$TEST_RECIPIENT" 'Acceptance test: must be cancelled.' --at 'in 30 minutes' --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS"
imsg list --status pending --config "$TEST_CONFIG"
```

Approve, record the returned `msg-...` ID, then open a new Terminal with the same shell
definitions and list again. Pass: the same pending job survives process exit.

```bash
imsg cancel REPLACE_WITH_SCHEDULE_ID --config "$TEST_CONFIG"
imsg list --status cancelled --config "$TEST_CONFIG"
```

Decline cancellation once: job remains pending. Repeat and approve: job becomes
cancelled. It must never send when workers run in later steps.

## 10. Foreground scheduled delivery and singleton — required

Create and approve a one-time schedule:

```bash
imsg schedule "$TEST_RECIPIENT" 'Acceptance test: foreground scheduled send.' --at 'in 3 minutes' --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS"
imsg daemon start --foreground --dry-run --config "$TEST_CONFIG"
```

Wait beyond the due time. Pass: nothing sent; job remains pending. Stop with Ctrl–C.
Then start the real worker; this WILL submit the overdue approved test:

```bash
imsg daemon start --foreground --config "$TEST_CONFIG"
```

In a second Terminal (with step 0 definitions):

```bash
imsg daemon status --config "$TEST_CONFIG"
imsg daemon start --foreground --config "$TEST_CONFIG"
```

Pass: status shows running; the second worker refuses to start; exactly one scheduled
message is submitted and received; cancelled job never sends. Check:

```bash
imsg list --status sent --config "$TEST_CONFIG"
```

Stop the first worker with Ctrl–C. Verify `running: false`. An in-flight submission may
finish during shutdown. Here `sent` means submitted to Messages, not a delivery receipt.

## 11. Installed background worker — required before unattended use

The project supports one launch-agent label per macOS user. If an agent is already
installed for your normal configuration, stop here and inspect it; do not replace it
just to run the test. Stop the foreground worker first. Review the test pending list:
only intentionally approved test jobs should exist.

```bash
imsg daemon install --config "$TEST_CONFIG"
imsg daemon start --config "$TEST_CONFIG"
imsg daemon status --config "$TEST_CONFIG"
imsg schedule "$TEST_RECIPIENT" 'Acceptance test: launchd scheduled send.' --at 'in 3 minutes' --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS"
```

Approve the schedule. Close Terminal; wait until due, then reopen Terminal and restore
step 0 definitions. Pass: worker continues without Terminal, exactly one message is
received, and the job becomes sent. Terminal's successful send does not guarantee
launchd has Automation permission; a failure here remains a live integration blocker.
Inspect errors locally if necessary:

```bash
tail -n 50 "$HOME/.imsg-agent-acceptance/daemon.log"
tail -n 50 "$HOME/.imsg-agent-acceptance/daemon-error.log"
```

Logs may contain private details. Do not commit them.

## 12. Recurrence and missed-run behavior — required if claiming recurring delivery

Only the acceptance config uses a one-minute duplicate window so this test can finish
quickly; the normal configuration is unchanged. Keep the installed worker running.

```bash
imsg schedule "$TEST_RECIPIENT" 'Acceptance test: recurring send.' --at 'in 1 minute' --cron '*/5 * * * *' --config "$TEST_CONFIG" --contacts "$TEST_CONTACTS"
```

Approve and record the ID. Pass: first occurrence follows `--at`; later occurrences use
five-minute clock boundaries in the displayed contact timezone. Confirm two submissions,
then stop the worker before further occurrences:

```bash
imsg daemon stop --config "$TEST_CONFIG"
imsg daemon status --config "$TEST_CONFIG"
```

Wait until `running: false`, then leave it stopped for at least eleven minutes so more
than one recurrence is missed. Start it again during allowed hours. Pass: one overdue
catch-up submission, no burst replay of every missed slot, and the next due time lies
in the future. Duplicate/rate restrictions may defer execution; inspect the job state.
Cancel the recurring job immediately after this check using its original schedule ID.
DST gap/fold and crash/uncertain-outcome behavior are covered by automated tests; do not
change your Mac's clock or kill it mid-send to reproduce them manually.

## 13. Login startup and clean shutdown — required if claiming login startup

First cancel every pending test schedule, particularly recurrence. With no pending jobs,
leave the launch agent installed. Save other work, log out of macOS, and log back in.
Restore the step 0 definitions and check:

```bash
imsg daemon status --config "$TEST_CONFIG"
```

Pass: worker starts after login, with a current heartbeat. With no pending jobs this
should send nothing. Then remove the test agent:

```bash
imsg daemon stop --config "$TEST_CONFIG"
imsg daemon status --config "$TEST_CONFIG"
imsg daemon uninstall --config "$TEST_CONFIG"
imsg daemon status --config "$TEST_CONFIG"
imsg list --status pending --config "$TEST_CONFIG"
```

Pass: worker stops, agent is removed, and no pending test schedules remain. Stop is
asynchronous; check status again if it is still running. Uninstall preserves logs and
schedules; it is not cancellation. Keep the test database locally until results have
been reviewed. Do not accidentally restart it with pending jobs.

## 14. Release review — required before calling the release verified

- Record each test's date, pass/fail, macOS/model version, and non-sensitive evidence.
- Clearly distinguish model output quality, Messages submission, and recipient receipt.
- Do not mark skipped live tests passed because unit tests passed.
- Update README.md and skeleton.md with the verified results and remaining limitations.
- Rerun step 1 after any code fixes.
- Check private data remains excluded before committing:

```bash
git status --short
git check-ignore contacts.json contacts.import-review.json
git diff --check
```

- Review and commit the diagnostics, checklist, documentation, and any tested fixes.
- Push unpublished commits when ready to publish. Git commit/push alone does not verify
  application behavior.

Completion criterion: all applicable required tests pass, failures are resolved or
explicitly limit the release claim, documentation matches evidence, and the intended
release is committed/published. SMS, group sending, and templates need additional live
acceptance tests before claiming those pathways are verified on this Mac; they are not
needed for a release limited to individual iMessage drafting and scheduling.
