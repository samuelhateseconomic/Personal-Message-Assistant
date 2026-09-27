# UI refinement plan

## Goal

Finish reliable user workflows before adding features. Keep a minimalist sidebar with
Assistant, Plans, Contacts, and eventual Settings; one primary action per screen and
consistent feedback, empty/loading/error states. Keep delivery disabled until the worker
and authorization gates pass. Do not present examples as functioning AI integrations.

## Agreed search behavior — first implementation

Saved-plan search ANDs every whitespace-separated keyword across recipient name, endpoint,
message, current native name/phone/email when connected, and app-local profile name,
connection type and private note. Case, diacritics and common phone formatting are ignored.
Keywords may match different fields. No semantic inference or remote service is involved.

Filter groups intersect with search and each other. Multiple selections within one group
are ORed. Filters: connection type, native contact identity, saved draft/cancelled status,
and planned date (today, next seven calendar days including today, inclusive custom range).
Dates use the current Mac timezone and calendar, with exclusive next-day boundaries.
Active filters have individually removable chips; Clear all resets search and filters.
Result counts and no-match guidance are visible. Private notes are never excerpted in
result previews. Note search reads local annotations, not Apple Contacts' notes field.

The recipient selector uses the same keyword matcher and connection filter. Contact,
plan-status and date filters are not useful there, so they are absent. Search/filter changes
do not change the chosen recipient or erase a draft. Assistant and Plan share recipient
search state; saved-plan search is separate. Profile saves refresh metadata within the app,
and refresh/unlock reloads local metadata. Lock clears the index and visible search state.
Unreadable profile data produces an explicit partial-search notice rather than silent success.

## Remaining implementation stages

1. Workflow audit: connection/permission handling, selection, contact create/edit/conflict,
   plan create/edit/cancel, AI draft generation, lock/unlock, failure/restart. Record outcomes
   and classify UI defects versus backend gaps. Validate on device using dedicated test data.
2. Shared shell: stable headers, spacing, progress/error feedback, keyboard navigation,
   minimum-size layout and unsaved-change dialogs. Move potentially slow I/O off main UI.
3. Contacts: list/detail layout, individual labeled phone/email rows, account attribution,
   private annotation section, clear success/failure and preserved input. Move demo data out
   of normal workflows; finish source-specific conflict verification.
4. Plans: separate list/detail and composer; edit the stored record with revision checks and
   fresh review; stable list refresh; cancellation feedback. Keep truthful draft-only status.
5. Assistant: compact recipient selector, context disclosure, manual draft preservation,
   cancellable model generation and rejection of stale outputs. Requires Python/IPC bridge.
6. End-to-end QA: screen sizes, keyboard/VoiceOver, loading/error/permission states,
   connection changes, lock during operations, Keychain and restart recovery.

## Acceptance for search/filter implementation

- A query like "Alex friend birthday" matches across three distinct fields.
- Every keyword is required; connections/contacts/status/date further narrow results.
- Same-name contacts remain distinct by native ID; missing/unlinked notes are not inferred.
- Filtering never changes a recipient or plan, and hidden notes are not revealed in snippets.
- Clearing restores all records; a no-match state explains how to recover.
- Custom dates include the final day; invalid ranges are labeled and match nothing.
- Lock clears search metadata. Search sends nothing to a model and creates no delivery job.
- Automated matcher/date tests pass; on-device filter-popover/layout/accessibility checks
  remain pending until exercised on the built app.

## Second increment — preview 0.4.2

Plans now opens a compact saved-plan list with an explicit selected detail view. The
composer is a separate view entered through New plan or Assistant → Create plan. Search,
filters and selected-plan identity survive moving between the list and composer. A
successful save selects the new stored plan, returns to the list and shows confirmation.
The detail view contains the exact recipient/address, full message, time/timezone, status,
creation time and cancellation action; private contact notes stay out of previews.

Back navigation offers keep-editing, keep-draft-and-return, or explicit discard when an
unfinished draft exists. Resume draft reopens it; New plan also protects an existing draft.
Recipient/destination changes ask before clearing typed text. The inactive Pause delivery
switch has been removed. Delivery remains disabled. A selected plan outside the current
filters is labeled explicitly rather than silently changing selection.

This completes part of the Plans navigation pass, not stored-plan editing or the complete
redesign. Contact layout, model integration, main-thread I/O improvements, settings,
keyboard/VoiceOver and on-device navigation testing remain open.

## Priority correction — Assistant completion

The user clarified that the Assistant must retrieve information and plan/manage actions,
including contact create/edit/delete, rather than only generate messages. Follow
[ASSISTANT_COMPLETION_PLAN.md](ASSISTANT_COMPLETION_PLAN.md) for revised scope, audited gaps,
review/deletion rules, backend contracts and ordered delivery gates. Further UI refinement
must follow those complete workflows. The next implementation is the shared native action
contract and saved-plan editing, not another isolated panel control.


### Conversational workflow increment — 0.6.0

The Assistant now presents a prompt, cancellation, clarification, source-backed identity
choices and proposal cards. Contact actions open the existing editable contact form; plan
actions open the shared plan composer/review. Native persistence supplies the result text.
Manual create/edit/delete and plan create/edit/cancel remain available without inference.
The installed app shows 0.6.0; authenticated UI/keyboard/accessibility checks remain pending.
Next work is the remaining multi-step/context/memory integration and those device checks,
not another standalone example-generation control.
