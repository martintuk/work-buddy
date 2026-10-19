# Measured assumptions

Several decisions came from measuring the API or operating system rather than
reading documentation. If their underlying conditions change, the app may silently
omit results instead of reporting a failure. Each entry records the assumption,
its evidence, what breaks, and how to detect a change. Unless stated otherwise,
measurements date from **2026-09-02** and describe that environment at that time.

## 1. Repositories require review

**Location:** `MergeQueue.query`, specifically `review:approved` in the
`review-requested:@me` search. The `author:@me` and `reviewed-by:@me` searches omit
it to avoid this assumption; their original sets were small (one and 12 PRs).

**Assumption:** a mergeable PR has `reviewDecision = APPROVED`, allowing a
server-side search filter.

**Evidence:** of 56 queued PRs, 45 were `BLOCKED` awaiting review. Every mergeable
PR had `APPROVED`. Filtering reduced the result from 56 to two without losing any
merge candidate.

**Why it matters:** requesting `mergeable` makes GitHub calculate mergeability,
the expensive part of the query. Without this filter, the full queue took three
pages and roughly 17 seconds instead of one page and roughly four seconds.

**Failure mode:** a repository that stops requiring review can have a mergeable
PR with `reviewDecision = null`. If you remain a requested reviewer, it may be
missing from Ready to merge without an error. The impact is narrower if you
already reviewed it: `reviewed-by:@me` can still find it.

**Detection:** compare with an unfiltered request:

```bash
# Current filtered search
gh api graphql -f query='query{search(query:"is:open is:pr review-requested:@me review:approved archived:false",type:ISSUE,first:1){issueCount}}' --jq '.data.search.issueCount'

# Unfiltered search, examining GitHub's mergeable verdicts
gh api graphql -f query='query{search(query:"is:open is:pr review-requested:@me archived:false",type:ISSUE,first:25){nodes{... on PullRequest{mergeable mergeStateStatus reviewDecision}}}}' \
  | python3 -c 'import sys,json; n=[x for x in json.load(sys.stdin)["data"]["search"]["nodes"] if x]; print([x["reviewDecision"] for x in n if x["mergeable"]=="MERGEABLE" and x["mergeStateStatus"] in ("CLEAN","UNSTABLE","HAS_HOOKS")])'
```

A `None` in the second result disproves the assumption.

## 2. Review requests define scope instead of a repository list

**Location:** `ReviewQueue.searchQuery` and `DependabotQueue.searchQuery`.
Configured organizations add `org:<organization>` filters. This is why there is
no `repos.txt`.

**Assumption:** `review-requested:@me` includes requests inherited through team
membership as well as direct requests. CODEOWNERS and team membership then define
relevant repositories using the same information GitHub uses to route reviews.

**Evidence (2026-09-03):**

| Search | All PRs | Dependabot only |
| --- | --- | --- |
| `review-requested:@me` | 57 | 50 |
| `user-review-requested:@me` | 27 | 21 |

The 50 Dependabot PRs split into 21 direct requests and 29 through four teams.
Compared with a previous tool's 23-repository allowlist:

- Fourteen repositories appeared in both.
- Eight appeared only in the list: seven had no open Dependabot PR, and the eighth
  had four assigned to a team the user did not belong to.
- Seven appeared only in the query and had been omitted from the list.

**Failure mode:** if GitHub changes `review-requested:` to mean direct requests
only, the team requests disappear silently. Conversely, joining a large team can
expand the queue unexpectedly.

**Detection:** compare both counts:

```bash
for q in review-requested user-review-requested; do
  printf "%-24s " "$q"
  gh api graphql -f query="query{search(query:\"is:open is:pr $q:@me archived:false\",type:ISSUE,first:1){issueCount}}" --jq '.data.search.issueCount'
done
```

Equal counts, or fewer results from `review-requested`, warrant investigation;
the original evidence depended on actual team requests being present.

## 3. Author filters partition the review search

**Location:** `ReviewQueue.searchQuery` uses `-author:app/dependabot`;
`DependabotQueue.searchQuery` uses `author:app/dependabot`.

**Reason for separation:** Dependabot accounted for 50 of 57 queued PRs. A single
query took three pages and roughly 17 seconds. Separate requests let the human
queue fit on one page and appear in roughly four seconds, with Dependabot loaded
separately.

The human and Dependabot searches are complementary, as checked in
`QueryShapeTests`. `ReviewQueueStore.reviewQueue` now also includes team Dependabot
results and deduplicates all three sources by ID.

**Failure mode:** after a migration to Renovate, its PRs enter `ReviewQueue` because
that filter does not exclude them. `Author.isBot` groups failing automation under
Automation · Not ready. Bots without failing CI can appear in review categories
and count toward the badge; see assumption 4.

**Detection:** `--dump-queue` prints human and Dependabot counts. A large increase
in the human-query count or bot accounts appearing there indicates a changed mix.

## 4. Configured machine accounts are complete

**Location:** Settings and `AppConfiguration`.

**Assumption:** `__typename == "Bot"` plus configured account logins covers all
automation.

**Evidence:** in the original environment, `__typename` identified almost every
automated account. One service account was typed as `User` and needed explicit
configuration.

**Failure mode:** a new machine account typed as `User` is treated as human. Its
failing-CI PRs can remain in review, count toward the badge, and notify instead
of appearing under Automation · Not ready.

**Detection:** inspect unfamiliar logins in the review category:

```bash
gh api graphql -f query='query{search(query:"is:open is:pr review-requested:@me archived:false",type:ISSUE,first:100){nodes{... on PullRequest{author{login __typename}}}}}' \
  | python3 -c 'import sys,json,collections; n=json.load(sys.stdin)["data"]["search"]["nodes"]; print(collections.Counter(((x.get("author") or {}).get("__typename"),(x.get("author") or {}).get("login")) for x in n if x))'
```

## 5. NSApp.isActive distinguishes an internal menu from focus loss

**Location:** `MenuBarController.autoClose()`.

**Assumption:** opening a menu inside the panel leaves the app active, whereas
switching focus to another app deactivates it. This keeps the `⋯` menu from
closing the panel.

**Evidence:** with the panel focused, `NSApp.isActive` was true and its window was
key. Activating another app delivered `didResignKey` with `isActive = false` on
macOS 26.6.2.

**Failure mode:** a macOS activation change could close the panel when its menu
opens, or keep it open after focus moves elsewhere.

**Detection:** open `⋯` and observe panel behavior with logging:

```bash
./scripts/build.sh
WORK_BUDDY_DEBUG=1 "build/work-buddy.app/Contents/MacOS/WorkBuddy" --open-panel
```

## 6. Batch 20 branch comparisons per request

**Location:** `BehindCount.batchSize`.

**Evidence:** GraphQL `Ref.compare(headRef:)` returned the same `behindBy` as REST's
comparison API for a real PR: one commit behind in both. Aliased repository fields
allow batching:

| For 20 PRs | REST | Batched GraphQL |
| --- | --- | --- |
| Requests | 20 | 1 |
| Bytes | About 540 KB (27 KB each) | 820 |
| Time | Sequential requests | 3.8 seconds |

REST `per_page=1` did not reduce the dominant payload: the diff's `files` array.
A later check with 59 PRs in three batches of 20 left zero unmeasured rows.

**Failure mode:** tighter GitHub cost limits could break batches of 20. Failed
batches leave `behindCount = nil`, displayed as `↓?`, never as zero.

**Detection:** new `↓?` badges where counts were previously available. Consider
reducing `batchSize`.

**Interpolation constraint:** owner, repository, and refs are interpolated into
GraphQL. `BehindCount.isSafeRef` checks the expected ref restrictions, excluding
quotes, backslashes, and spaces. Supporting additional characters should use
GraphQL variables rather than ad-hoc escaping.

## 7. Mergeability determines the practical page-size limit

**Location:** `ReviewQueue.pageSize` and `DependabotQueue.pageSize`, currently 25.

**Evidence:** with nested `reviewRequests`, `latestReviews`, and `commits`:

| Fields | `first:` | Result |
| --- | --- | --- |
| `PullRequestFields.base` | 100 | Consistent 502 |
| `PullRequestFields.base` | 50 | Successful 5/5 times, about 9 seconds (2026-09-03) |
| `PullRequestFields.base` | 25 | Successful |
| `base` + `mergeable` | 50 | 502 on 3/3 attempts (2026-09-03) |
| `base` + `mergeable` | 25 | Successful |

The expensive field was `mergeable`, not the overall field count. A reduced field
set without `latestReviews` would have lost `reviewedByMe` and `approvals` without
an observed benefit. The human review queue uses 25 conservatively; with only
seven PRs in that measurement, moving to 50 would not help.

The same query also returned intermittent 502 responses, roughly one in four
attempts, motivating `GH.runRetrying`.

**Failure mode:** tighter limits require smaller pages. Looser limits merely
leave extra latency. Dependabot now requests `mergeable` so review eligibility
requires confirmed absence of conflicts; it uses pages of 25 and up to eight
pages to retain the previous 200-PR capacity. Do not return to 50 while requesting
that field. `QueryShapeTests` checks the actual Dependabot query.

**Detection:** HTTP 502 errors surviving all four retry attempts.

## 8. GitHub CLI installation paths

**Location:** `GH.candidatePaths`.

Finder-launched apps may not inherit the shell's PATH. The app searches known
absolute paths and the available PATH rather than assuming `gh` resolves by name.

**Failure mode:** installation in an unrecognized prefix can produce “Could not
find gh” even though the command works in a terminal.

**Detection:** `which gh` works in Terminal but the app cannot find it. Add the
prefix to `candidatePaths`.

## 9. Signing and permissions affect notifications

**Historical evidence (2026-09-02):** an ad-hoc-signed bundle successfully requested
authorization and delivered a test notification on macOS 26.6.2. This does not
guarantee acceptance on other installations.

**Current behavior:** `scripts/build.sh` uses an available Apple identity or
`WORK_BUDDY_SIGNING_IDENTITY`. Without one, it signs ad hoc and warns that macOS
may reject notifications. `Notifier` reports authorization errors. Settings
provides enable and test controls.

**Verification:**

```bash
"build/work-buddy.app/Contents/MacOS/WorkBuddy" --check-notifications
```

## 10. Failing CI does not predict an outdated branch

**Location:** deliberately not implemented as a rule.

A previous tool treated failing Dependabot CI as evidence that a rebase would
help. Comparing `statusCheckRollup` and `BehindCount.behindBy` for 50 actual
Dependabot PRs on 2026-09-03 showed:

| | Behind | Up to date |
| --- | --- | --- |
| Failing CI | 24 (48%) | 22 (44%) |
| Successful CI | 1 (2%) | 3 (6%) |

Of 46 PRs with failing CI, only 52% were behind. Thirteen of those 24 were just
one commit behind, which alone does not explain a CI failure. Their behind counts
were `1×13, 5×6, 7, 8, 9, 12, 13`. Eleven of 46 (24%) were at least five commits
behind, a narrower set where rebasing was a plausible hypothesis.

Rebase availability should not depend on failing CI. The `↓N` badge supplies the
objective behind count; the user decides. GitHub's `mergeStateStatus: BEHIND`
identified only one of four actually outdated branches in an earlier check.

To inspect the current queue:

```bash
swift build && .build/debug/WorkBuddy --dump-queue
```

Compare the automation rows' `CI✗` and `↓N` indicators rather than treating either
as a substitute for the other.

## Past mistakes

**Searching only `review-requested:@me`.** Approval removes a PR from your review
requests. The action that makes it mergeable can remove it from that search.
An approved service-account PR marked `CLEAN` exposed the problem. Adding
`reviewed-by:@me` grew the merge section from one PR to five. Review requests
represent outstanding requests, not every PR relevant to you.

**Filtering by CI.** `statusCheckRollup` includes optional checks. Treating every
failed check as the author's responsibility hid 40 of 63 PRs, many needing review.
CI status remains an indicator rather than a universal exclusion rule.

**Counting approvals manually.** An `approvals > 0` rule ignored branch protection
and CODEOWNERS. A real PR had three approvals but remained `REVIEW_REQUIRED`.
The app uses `reviewDecision` instead.

Use GitHub's verdicts rather than reconstructing `reviewDecision`,
`mergeStateStatus`, or author `__typename` locally.
