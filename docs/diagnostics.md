# Performance diagnostics

Run commands from the repository root.

## Diagnose a slow load on another computer

The app automatically records the last **10 accepted refreshes in total**,
identifying GitHub and Jira separately and prioritizing active refreshes. A stuck
request remains visible while the other service updates. No Terminal or debug
flag is needed. Right-click the menu bar icon and choose **Export diagnostics…**
to save an attachable `.txt` file. Export while the delay is happening or just
after it ends. If the app froze, restart and export immediately.

The export includes app version and build revision, phase and publication times,
PR/page/batch counts, team-search concurrency, retries, and ownership-cache hits
and age. Pending phases are recorded from their start. Refreshes in progress are
distinguished from ones interrupted by a previous shutdown. `firstContent` measures
the first publication of available panel data, not SwiftUI rendering time.
`queuesLoaded` and `refreshEnded` separate completed queues from later branch
comparisons. A completed cycle can include partial failures; inspect its events
and error categories.

Logs do not include tokens, arguments, queries, responses, raw error messages,
repository/team/user names, PR IDs, titles, or comments. Nothing is uploaded
automatically. Files live under
`~/Library/Application Support/work-buddy/Diagnostics/`, limited to 128 KiB per
refresh and roughly 1.25 MiB total. A capture reaching its limit includes a
`truncated` event and must not be treated as complete. Writes run off the UI thread.

The same export includes the last **10 panel openings** in a separate history
(`Diagnostics/Panels/`, up to 16 KiB per opening). Opening and closing the panel
does not evict GitHub or Jira refresh logs. Each opening records:

- `panelOpen`: from handling the opening request through AppKit's `popoverDidShow`.
  This indicates a shown window, not the compositor's first frame.
- `panelRefresh`, `panelLayout`, and `panelShow`: synchronous work before display.
- `opening` and `hasSnapshot`: opening number in this session and whether GitHub
  already had a complete in-memory snapshot, for comparing first and later openings.
- `mainThreadDelayed`: main-run-loop delays of at least 100 ms against a probe
  every 250 ms, only while the panel is open. Closing records the count and maximum.
  The clock excludes machine sleep. This samples responsiveness; it is neither an
  FPS counter nor proof that no stutter occurred.

To diagnose responsiveness, repeatedly open and close the panel and use the list
during refreshes. Close it and export normally. Queues publish each result when
its request completes; loading state and notifications wait for the required
sources. A failed secondary request retains its previous data. A canceled load
does not publish late responses.

## Tune concurrent team searches

Dependabot searches across team repositories use **two concurrent groups** by
default. To compare settings on another computer, quit the app and run:

```bash
defaults write dev.martintuk.work-buddy performance.teamSearchConcurrency -int 4
```

Reopen the app. This persisted setting accepts values from **1 to 8**, clamping
out-of-range values. `1` restores sequential execution. Restore the default with:

```bash
defaults delete dev.martintuk.work-buddy performance.teamSearchConcurrency
```

The limit applies only to these groups; other queues also run concurrently.
Each group paginates sequentially, reusing its slot upon completion. Result order,
deduplication, and rejection of partial responses are preserved. Diagnostics
include `concurrency` and `searches` under `teamDependabot` and classify GitHub's
rate-limit responses as `rate_limited` without retaining the raw message.

Compare 2, 4, and 6 with two complete loads each, without forcing ownership
rediscovery. Compare `teamDependabot`, `queuesLoaded`, and `refreshEnded` timing,
along with retries and failures. Export before changing the setting to retain
both loads. If timing stops improving, keep the lower concurrency. Respect
GitHub's indicated wait before retrying a rate-limited request.
