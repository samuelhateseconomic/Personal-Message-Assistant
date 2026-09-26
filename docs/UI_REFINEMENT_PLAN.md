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
