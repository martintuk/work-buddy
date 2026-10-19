# Work Buddy

The interface supports English and Spanish. Documentation and code are in English.

A macOS app that brings together pull requests needing your attention. Review,
approve, merge, or open them in your editor or AI agent. Jira integration is
available as an experimental feature, disabled by default.

## Requirements

- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.
- GitHub CLI (`gh`), authenticated with `gh auth login`.
- Optional: Atlassian CLI (`acli`), authenticated with `acli jira auth login`, for Jira.

## Settings

The gear opens general preferences for language, appearance, automatic action confirmation,
notifications, editor, terminal, and AI agent. Integration settings have two
navigable subsections:

- **GitHub:** organizations, Dependabot teams, and automation accounts.
- **Jira (experimental):** enable the integration, copy the sign-in command,
  and edit **Which tickets to show (JQL)** for **Assigned to me** and
  **Recently created** (up to 10 tickets). List names are fixed.

Jira starts disabled. When disabled, the panel opens GitHub directly, without
category tabs or new Atlassian requests. Credentials remain with `gh` and `acli`;
the app stores its preferences in `UserDefaults`.

## Run

```bash
./Scripts/run.sh          # build in debug mode, install, and restart
./Scripts/run.sh release  # same workflow with an optimized build
```

The app is installed at `~/Applications/Work Buddy.app` with its own icon.
Open it from Finder or add it to macOS login items. The `WorkBuddy` process runs
independently of the terminal and appears in the Dock and app switcher. Clicking
its Dock icon opens the panel. The orbit icon also appears in the menu bar.

Each run replaces the installed copy after building and verifying its signature.
If the build fails, the running app stays open. To install elsewhere, set
`WORK_BUDDY_APP_DIR` for both the run and watch scripts.

- **Left click:** open or close the panel.
- **Right click:** open the context menu (About / Quit).
- Losing focus hides the panel without quitting the app.

Quit with Command-Q, the panel's Quit button, the app menu, or the Dock menu.

### Use another computer and update from Git

On the computer running the app, clone the repository and install its dependencies:

```bash
./Scripts/run.sh
./Scripts/watch-main.sh
```

The watcher checks `origin/main` every five seconds. When new commits arrive,
it updates the checkout, builds, and installs the app in the same location.
There is no need to copy the `.app` manually. The watcher must keep running to
receive updates; stopping it does not quit the app. This computer needs the
Command Line Tools and its own CLI sessions. The watcher does not push local
commits and pauses on conflicts or when the checkout is on another branch.

It also compares the checkout revision with the installed app. A manual pull,
missing installation, or previous build failure triggers installation without
requiring another commit. Failed installations retry every 60 seconds and log to
`build/watch-main.log`. The watcher waits for a clean checkout before building.

## Documentation

- [User guide](docs/user-guide.md): queues, actions, filters, agents, and activity.
- [Development](docs/development.md): builds, tests, architecture, and interface text.
- [Diagnostics](docs/diagnostics.md): logs and performance measurements.
- [Measured assumptions](docs/assumptions.md): evidence and limits behind decisions.
- [Open decisions](docs/open-decisions.md): proposals and scope decisions.
