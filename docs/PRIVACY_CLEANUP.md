# Publication privacy cleanup

Prepared for review. GitHub history has not yet been replaced by this plan.

## Sanitized content

- Contact-specific examples now use variables selected locally by the tester.
- Removed private contact labels, address-book counts, and recipient-specific activity.
- Replaced the personal absolute project path with a generic checkout path.
- Retained the explicitly approved author name and Berkeley email in Git metadata.
- Personal address books, import reports, databases, logs, and build artifacts remain ignored.
- Synthetic fixtures remain: their sample values are not imported personal contacts.

## History replacement procedure

1. Confirm the remote main tip has not changed since inspection.
2. Prepare a replacement for the affected native-transformation commit, preserving its
   parent, source changes, title, and author identity, but using the sanitized tree.
   Unaffected earlier commits retain their IDs. Keep a local review branch only; do not
   push a backup branch containing the original affected commit.
3. Audit all commits reachable from the replacement against the private source locally.
   Do not commit the source data, a sensitive denylist, or a report containing its values.
4. Review the replacement tree and diff. Obtain approval for publishing rewritten history.
5. Push the reviewed replacement to main with an explicit force-with-lease tied to the
   inspected old tip. If the lease fails, stop and inspect the new remote changes.
6. Align the local main branch with the published replacement while preserving ignored
   personal files. Verify the remote tip and a clean checkout.
7. Review other published branches/tags and any PRs referencing the original commit.
   A branch rewrite alone cannot guarantee erasure from GitHub caches, forks, downloads,
   or existing clones. Request GitHub Support assistance with cached references if needed.
8. Other clones should re-clone or carefully move onto sanitized history; merging an old
   branch can reintroduce the affected commit. Local Codex checkpoint refs/reflogs may
   also retain old objects; do not delete app-managed refs without a separate review.

## Future publishing checks

Review both code and documents before publishing. Use generic contact placeholders in
instructions; keep real test identities and raw outputs out of version control. Check
staged paths, ignored artifacts, private-source exact matches, author metadata, and
credential patterns. A scanner cannot guarantee detection of every sensitive format;
manual review of live-test writeups remains necessary.
