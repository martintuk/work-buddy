# Open decisions and pending checks

This records undecided proposals, deliberately rejected ideas, and implemented
behavior that still needs manual verification. Measurements live in
[assumptions.md](assumptions.md). The purpose is to preserve why something was not
done, rather than repeatedly proposing it.

Last documentation cleanup: **2026-10-19**. Pending manual checks remain unverified.

## Proposed, undecided

### Blocker chips instead of separate badges

`CI✗`, `draft`, `N✓`, and `↓N` are separate badges that must be interpreted together.
They are not mutually exclusive, so none alone answers what still blocks a merge.

### Keep a row visible after approval

Approval removes you from review requests. The row disappears on refresh, leaving
only a dismissible result banner. A roughly 15-minute recently-completed state
could keep that confirmation visible.

For merges, the current decision is to remove the PR from the local snapshot as
soon as GitHub confirms success. No persistent exclusion is stored; a later
refresh can bring it back.

## Deliberately rejected

Measure again before revisiting these decisions.

| Idea | Reason | Evidence |
| --- | --- | --- |
| Manual repository list (`repos.txt`) | Of eight extra repositories, seven had no open Dependabot PR and one belonged to another team. The list also missed seven repositories found by the query. | Assumption 2 |
| Merge-method selector | GitHub supplies `viewerDefaultMergeMethod`; the app follows it. | — |
| Filter by CI status | Hid 40 of 63 PRs, many still needing review. CI remains a badge. | Past mistakes |
| Count approvals manually | A PR with three approvals remained `REVIEW_REQUIRED` because of CODEOWNERS. | Past mistakes |
| Search only `review-requested:@me` | Approval removes you from that search, hiding merge candidates. | Past mistakes |
| Smaller Dependabot field set | The complete set fit `first: 50`; the reduced set lost `reviewedByMe` and `approvals` without benefit. | Assumption 7 |
| `.confirmationDialog` for merging | A system dialog inside `NSPopover` conflicts with focus-loss dismissal. Use an inline bar. | — |
| Merge coworkers' PRs | Outside the intended scope: these merges belong to their authors. | — |

When GitHub has already computed a verdict, use it rather than reconstructing it.
This applies to `reviewDecision`, `mergeStateStatus`, `viewerDefaultMergeMethod`,
and the author's `__typename`.

## Implemented, not manually verified

- **The `⋯` menu keeps the panel open.** The `NSApp.isActive` distinction was
  measured, but the interaction remains unverified. Assumption 5 includes a log command.
- **Merge candidates contribute to the badge.** Action queues are deduplicated by
  ID, and tests exclude ignored PRs. During the manual check, `readyToMerge` was
  zero, so nonzero contributions from both review and merge were not observed.
- **Automation with 50 rows.** It starts collapsed; scrolling the expanded section
  at that size remains unverified.
