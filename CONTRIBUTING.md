# Contributing

Thanks for your interest in Work Buddy. Bug reports, ideas, and pull requests are welcome.

## Getting started

You need macOS 14+, the Xcode Command Line Tools, and an authenticated GitHub CLI (`gh auth login`). See the
[README](README.md) for details.

```bash
./scripts/run.sh   # build, install to ~/Applications, and restart the app
./scripts/test.sh  # Swift tests
```

[Development](docs/development.md) covers the architecture, debugging flags, and interface text.

## Before opening a pull request

Run the same checks as CI:

```bash
./scripts/test.sh
python3 -m unittest discover -s Tests/scripts
shellcheck scripts/*.sh scripts/lib/*.sh
```

- Add or update tests for behavior changes.
- Add interface text to both the English and Spanish catalogs in `Sources/WorkBuddy/Localization/`.
- Write code, comments, and documentation in English.
- Keep each pull request focused on one change, and use [Conventional Commits](https://www.conventionalcommits.org/)
  for commit messages (`feat:`, `fix:`, `docs:`, `chore:`).

## Reporting bugs

Open an issue with your macOS version, the steps to reproduce, and what you expected. [Diagnostics](docs/diagnostics.md)
explains how to collect logs. Remove private repository names and other sensitive data before posting.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
