# Work Buddy

The interface supports English and Spanish. Documentation and code are in English.

A macOS app that brings together pull requests needing your attention. Review,
approve, merge, or open them in your editor or AI agent. Jira integration is
available as an experimental feature, disabled by default.

## Install

With [Homebrew](https://brew.sh):

```bash
brew install --cask martintuk/tap/work-buddy
gh auth login
```

Open **Work Buddy** from Applications. The download supports Apple silicon and
Intel, is signed with Developer ID, and is notarized by Apple. Homebrew also
installs the GitHub CLI dependency.

To update:

```bash
brew update
brew upgrade --cask work-buddy
```

For a manual installation, download the ZIP from
[GitHub Releases](https://github.com/martintuk/work-buddy/releases/latest),
extract it, and move **Work Buddy.app** to Applications. Install the GitHub CLI
with `brew install gh` and sign in with `gh auth login`.

## Requirements

- macOS 14+
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

## Build from source

Install Xcode Command Line Tools (`xcode-select --install`), then clone this
repository. Full Xcode is not required for ordinary local builds.

```bash
./scripts/run.sh          # build in debug mode, install, and restart
./scripts/run.sh release  # same workflow with an optimized build
```

The app is installed at `~/Applications/Work Buddy.app` with its own icon.
Open it from Finder or add it to macOS login items. The `WorkBuddy` process runs
independently of the terminal and appears in the Dock and app switcher. Clicking
its Dock icon opens the panel. The orbit icon also appears in the menu bar.

Each run replaces the installed copy after building and verifying its signature.
If the build fails, the running app stays open. To install elsewhere, set
`WORK_BUDDY_APP_DIR`.

- **Left click:** open or close the panel.
- **Right click:** open the context menu (About / Quit).
- Losing focus hides the panel without quitting the app.

Quit with Command-Q, the panel's Quit button, the app menu, or the Dock menu.

## Documentation

- [User guide](docs/user-guide.md): queues, actions, filters, agents, and activity.
- [Development](docs/development.md): builds, tests, architecture, and interface text.
- [Releasing](docs/releasing.md): signing, notarization, and distribution packaging.
- [Diagnostics](docs/diagnostics.md): logs and performance measurements.
- [Measured assumptions](docs/assumptions.md): evidence and limits behind decisions.
- [Open decisions](docs/open-decisions.md): proposals and scope decisions.
- [Contributing](CONTRIBUTING.md): checks to run before opening a pull request.

## License

[MIT](LICENSE)
