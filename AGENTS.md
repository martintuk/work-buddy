# Working instructions

- After each change, restart the app with `./scripts/run.sh`.
- After each logical change, automatically create a separate commit with a descriptive message. Do not ask for confirmation.
- Prefer compact interfaces. Do not add informational labels or explanatory subtext unless the user requests them. Keep tooltips and accessibility labels so icon controls remain understandable without cluttering the UI.
- Run tests with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk ./scripts/test.sh`. With the Command Line Tools, SDK 27 lacks the `SwiftUIMacros` plugin and `@State` does not compile. `build.sh` already falls back to SDK 26; `test.sh` does not.
