# Development

Run commands from the repository root.

## Tests

```bash
./Scripts/test.sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Scripts
```

With the Command Line Tools and SDK 27, run Swift tests using
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ./Scripts/test.sh`.
Script tests verify installation and error recovery without touching the
installed app.

Use the script instead of plain `swift test`: with the Command Line Tools as the
active developer directory, SwiftPM omits the `Testing.framework` search path
and `lib_TestingInterop.dylib` rpath even though both are bundled. Without those
flags, compilation fails with `no such module 'Testing'`.

Tests cover classification, grouping, write arguments, search query shape,
persistence, cancellation, and recovery. Regression fixtures document the
behavior that originally failed.

## Run without the GUI

```bash
swift build && .build/debug/WorkBuddy --dump-queue  # grouped queue dump
```

The dump loads the panel's data sources, including human PRs, Dependabot, and
merge candidates, and calculates the badge for comparison with the interface.

Features depending on the bundle, including notifications, UserDefaults, and
the panel, must run from the executable inside the `.app` so `Bundle.main`
resolves correctly:

```bash
./Scripts/build.sh
APP="build/work-buddy.app/Contents/MacOS/WorkBuddy"
WORK_BUDDY_DEBUG=1 "$APP" --open-panel   # open on startup; log to stderr
"$APP" --check-notifications            # diagnose notification permissions
```

## Build without launching

```bash
./Scripts/build.sh  # print the generated .app path under build/
swift build         # executable only, without a bundle
```

The build script uses an available Apple code-signing identity from the keychain.
Set `WORK_BUDDY_SIGNING_IDENTITY` to choose one. Without an identity, it uses
ad-hoc signing and warns that macOS may reject notifications.

In Settings, **Enable** saves the automatic-notification preference and **Test**
sends a notification. Both require macOS permission. If denied, enable it in
System Settings → Notifications → work-buddy; the app cannot grant itself access.

Each PR entering a review or merge action category produces its own notification,
without grouping. Notifications use the panel's filtered lists, including eligible
bots. Each section's first load is silent. A PR that leaves and later re-enters
can notify again.

## Structure

```text
Sources/WorkBuddy/
├── main.swift                Entry point; NSApplication in .regular mode.
├── AppDelegate.swift         Lifecycle and MenuBarController ownership.
├── MenuBarController.swift   NSStatusItem, NSPopover, badge, focus, and clicks.
├── GitHub/
│   ├── GH.swift              gh CLI execution and retry handling.
│   ├── PullRequestNode.swift Shared GraphQL fields and DTOs.
│   ├── PullRequestSearch.swift Shared paginated search.
│   ├── ReviewQueue.swift     Human review requests.
│   ├── DependabotQueue.swift Separate Dependabot query; see assumption 3.
│   ├── FixQueue.swift        Paginated own PRs; domain rules filter failed CI.
│   ├── MergeQueue.swift      Merge candidates from three searches.
│   ├── BehindCount.swift     Commits behind the base, in batches of 20.
│   └── GitHubWrite.swift     Rebase, approve, and merge writes.
├── Jira/                     ACLI authentication and configurable JQL queries.
├── Domain/                   Classification and grouping policies.
├── Models/
│   ├── AppConfiguration.swift Persisted GitHub configuration.
│   ├── JiraConfiguration.swift Experimental opt-in and Jira queries.
│   ├── PullRequest.swift     PR data and status.
│   ├── ReviewQueueStore.swift Panel state, refreshes, and actions.
│   ├── IgnoreList.swift      Persisted ignored PRs.
│   └── PullRequestAction.swift Per-PR actions.
├── Localization/             Semantic text keys and interface strings.
├── Notifications/Notifier.swift
├── Views/                    Panel, rows, settings, and activity.
└── Debug/                    CLI dumps and diagnostics.

Resources/Info.plist          App metadata and bundle identifier.
Resources/AppIcon.icns        App icon; generator under Scripts/.
Scripts/                     Build, install, and test utilities.
Tests/                       Domain, lifecycle, persistence, and script tests.
```

## Design decisions

**AppKit lifecycle, SwiftUI content.** SwiftUI's `MenuBarExtra` would reduce code
but offers less control over panel timing and size. `NSStatusItem` and `NSPopover`
with `NSHostingController` combine AppKit control with SwiftUI view composition.

**SwiftPM with a manually assembled bundle.** There is no `.xcodeproj`. Builds run
from Terminal without full Xcode, and `Package.swift` is easier to review than a
project file.

## Adding features

`PanelView` hosts the panel content. Configure its popover through
`MenuBarController.configurePopover()` when changing its window behavior.

## Interface text

Repository documentation, code comments, identifiers, and test descriptions are
in English. The interface supports English and Spanish through the language
selector in Settings. Keep both catalogs and their format placeholders aligned.

Interface text, tooltips, accessibility labels, errors, and notifications live in
`Sources/WorkBuddy/Localization/`, grouped by feature. `LocalizationKey.swift`
defines semantic keys. Use `L10n.text(.settingsTitle)` instead of embedding copy
in a view. Interpolated messages use `%@` with separate arguments.

Strings are compiled into the executable; rendering does not read or parse
resource files. Repository names, PR and ticket titles, CLI responses, and user
content remain as received from their source.
