# User guide

Choose **English** or **Español** in **Settings → Language**. Interface labels,
tooltips, notifications, and activity messages follow the selected language.

The queue includes personal and team review requests. Categories distinguish
required actions, approved pull requests, and automation.

In **Settings → GitHub**, **Include Dependabot from my teams** lets you select
teams without maintaining a repository list. The app queries their repositories
and reads CODEOWNERS on the default branch. It includes repositories whose last
catch-all `*` rule mentions you or a selected team. Directory-specific ownership
does not expand this scope: this is a general ownership signal, not a per-file
CODEOWNERS evaluation for each PR. Discovery is cached by account and teams for
24 hours. A failure preserves the last valid list and can be retried in Settings.
Open Dependabot PRs from these repositories join the existing searches without
requiring a review request and are deduplicated within the existing sections.
This feature starts disabled and respects the organization filter.

## Pull request categories

| Section | Contents |
| --- | --- |
| Ready to merge | Your PRs and automation PRs that GitHub considers mergeable |
| To fix | Your PRs with failing or errored CI, including drafts |
| To review | Requests to you or your teams, without your current approval or GitHub's aggregate approval |
| Already approved | `reviewDecision = APPROVED` without your current approval; your review is optional |
| Automation · Not ready (collapsed) | Dependabot waiting for successful CI, confirmed absence of conflicts, or draft removal; bots with failing CI or your approval while another review is required, excluding merge-ready PRs |
| Ignored (collapsed) | PRs you manually hid |

The menu bar badge counts actionable PRs without counting a PR twice. Team
requests count like personal requests. Age and previous comments do not change
the review category. Your current approval removes a PR from both review
categories even when a team request remains. Dismissing that approval or later
requesting changes can make it reappear.

Automation you approved that remains `REVIEW_REQUIRED` stays in Automation · Not
ready without contributing to the badge. Dependabot enters a review category
only with successful CI, confirmed absence of conflicts, and no draft flag.
Until then, it does not count or notify as a pending review. Other bots without
failing CI follow their review status; pending or unknown CI keeps its indicator.
Bots needing review count and notify. Merge-ready bots appear only under Ready
to merge.

To fix respects filters, favorites, and ignored PRs. An optional failing check
can put a PR in both To fix and Ready to merge. Automation with failing CI stays
in its automation section unless ready to merge. Pending, unknown, or successful
CI does not qualify for To fix.

## Individual actions

The `⋯` menu offers open, approve, rebase an outdated branch, merge, ignore, and
restore. Approval, rebase (including Dependabot), and merge use an inline
confirmation bar unless automatic confirmation is enabled. Opening, ignoring,
and restoring run directly. Clicking a row selects it; double-clicking opens
the PR without confirmation.

Dependabot uses its dedicated rebase command. The repository chooses the merge
method. Opening a PR refreshes the GitHub queues. Writes wait for GitHub's
response before refreshing, including on failure. If a refresh is already
running, another runs afterward. Ignore and restore update the panel and badge
locally without another GitHub request.

## Multiple selection

The checkbox icon enables multiple selection on the main screen. Rows keep their
contents and gain a checkbox. Selection supports human and automation PRs while
respecting filters and ignored items. **Approve N** and **Merge N** act on selected
PRs in the corresponding review and merge categories. Running one action keeps
the other group's selection. The count button confirms the batch even when
individual actions use automatic confirmation. Progress and **Stop** share the
bottom bar; the list icon opens per-PR results.

Selection survives closing the panel. Refreshes add new PRs without selecting
them and remove selections that no longer qualify or whose commit, base, action,
or merge method changed. Each execution fixes its candidate set and revalidates
every PR against GitHub before writing. Merge requests include the selected SHA
and method and count as complete only after GitHub confirms the merge. A merge
can block the next PR, which is then skipped until another execution.

Individual approvals, batch approvals, and batch merges share one execution
queue, a one-second pause, and rate-limit handling. Explicit limits, including
`422` with “was submitted too quickly”, honor `Retry-After` or `X-RateLimit-Reset`.
Without headers, the queue waits 60 seconds and increases that delay on repeated
limits. It tries at most three times, revalidating each time without repeating
recorded actions. Persistent limits skip the remaining items. Permission errors,
validation errors, and uncertain transport failures are not retried. **Stop**
interrupts waits but lets an already-sent write finish.

## Autopilot

The lightning icon opens Autopilot disabled with its queue expanded. Opening
this mode does not execute actions. The bottom bar enables or disables it and
expands a bounded, scrollable queue upward. It shows the current and pending
operations; its history icon opens results. Main rows retain their presentation.

Autopilot processes only Dependabot, merges before approvals, with the same
eligibility rules, filters, ignored items, validation, and retries as batches.
The queue follows general refresh publications even while disabled. The current
PR keeps its snapshot until completion; pending items follow their latest state.
An approved PR can later enter as a merge once GitHub considers it ready. With
no pending items, Autopilot waits.

It remains active when the panel closes and starts disabled after app restart.
Manual selection is unavailable while it is active. Disabling it interrupts waits
and lets an already-sent write finish. Account changes or errors after exhausted
retries stop it. Successes and uncertain errors are not repeated for the same
commit, action, base, and merge method during the app session, including after
re-enabling it. Errors remain for manual review. A PR skipped as not ready can
return after leaving and re-entering the general queue.

The app refreshes every five minutes and notifies about newly actionable PRs.

## Experimental Jira integration

Enable it in **Settings → Jira (experimental)**. It starts disabled, including
for users of older versions. Disabled Jira hides the category tabs: the panel
opens GitHub directly and starts no Jira queries. Disabling it invalidates any
pending load and clears visible tickets. Saved queries remain available for
next time.

**Assigned to me** and **Recently created** have fixed names.
**Which tickets to show (JQL)** controls their contents and ordering. Defaults:

- Assigned to me: `assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC`.
- Recently created: `creator = currentUser() ORDER BY created DESC`, limited to 10 tickets.

**Save changes** applies edits and reloads. **Restore defaults** restores the
fields; save to apply them. Errors identify the failed list, what to check, and
the original CLI details.

The account and site come from the active `acli` session. **Copy sign-in command**
copies `acli jira auth login`. Paste it into Terminal to connect or change the
account/site, then use **Check Jira connection**. Work Buddy never requests or
stores credentials. It requires no team-specific custom fields or statuses.

## Repositories and local tools

The **Repositories** button opens a searchable, scrollable list filling the
panel. It combines distinct repositories from review, automation, and merge
results before filtering. The eye selects repositories to show exclusively;
clicking again deselects one. Mute shows everything except muted repositories.
These modes are mutually exclusive: using the eye clears mutes, and muting clears
eye selections. No selection shows everything. **Show all** clears the filter.
Filters persist across restarts and affect sections, badge counts, and new
notifications. Repositories with saved preferences remain listed without current
results so they can be restored.

The folder icon associates a local clone or worktree root containing `.git`.
The association persists and keeps the repository listed without PRs. Hover to
see the path, click again to change it, or remove it from the context menu.
Association only saves the folder: it does not clone, switch branches, or verify
the remote. Local actions verify identity before operating.

With an associated folder, the PR menu offers **Open in editor**. Select an IDE
in **Settings → Editor**; this is a global preference, and the menu then displays
the selected app, such as **Open in RubyMine**. Detection supports JetBrains IDEs
(including Toolbox), VS Code, Cursor, Xcode, and other installed editors.
**Choose another app…** supports custom locations.

Before opening the editor or an agent, the app verifies a repository remote and
checks that the local branch matches the PR's displayed commit. If the local
branch is absent, it uses the verified remote's branch, fetching when needed.
It never resets branches or discards local work. An outdated branch, a different
fork revision, or an incorrect folder produces an error instead of an automatic
launch. Update or manually check out the PR and retry. The app verifies the
commit again after switching branches.
