# Releasing Work Buddy

The distribution target is a Developer ID-signed, notarized app in GitHub
Releases. A Homebrew cask can download that same archive once public releases
are available. The local release script prepares the archive; it does not
create a release, push a tag, or change repository visibility.

## One-time setup

1. Create a **Developer ID Application** certificate through Xcode's account
   settings or the Apple Developer portal, and install it with its private key
   in your login keychain. An Apple Development certificate supports local
   development but cannot be used for distribution.
2. Confirm the identity is available:

   ```bash
   security find-identity -v -p codesigning
   ```

3. Make sure `xcrun --find notarytool` and `xcrun --find stapler` succeed. If
   your Command Line Tools installation lacks either tool, install and select
   full Xcode.
4. Store notarization credentials in Keychain. Run the interactive command
   below and follow its prompts for your Apple ID, developer Team ID, and an
   app-specific password:

   ```bash
   xcrun notarytool store-credentials work-buddy-notary
   ```

   An App Store Connect API key is also supported by `store-credentials`;
   see `xcrun notarytool store-credentials --help` for the key options.
   Keep private keys, exported certificates, and passwords outside the repo.

## Build a release

Run the tests first, and use a clean, committed checkout for a published build:

```bash
./scripts/test.sh
python3 -m unittest discover -s Tests/scripts
export WORK_BUDDY_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export WORK_BUDDY_NOTARY_PROFILE=work-buddy-notary
./scripts/release.sh 0.1.0 1
```

Replace the identity with its exact keychain name or SHA-1 hash. The arguments
set the app's version and build number without editing the source plist. Use
an increasing build number for each published build. The script refuses to
overwrite an existing release directory.

The script builds for Apple silicon and Intel, signs with hardened runtime and
a secure timestamp, submits the app to Apple, and waits for acceptance. It
then staples and validates the ticket, verifies the signature and Gatekeeper
assessment, and creates:

- `build/releases/0.1.0-1/work-buddy-0.1.0-universal.zip`
- `build/releases/0.1.0-1/work-buddy-0.1.0-universal.zip.sha256`
- The stapled `Work Buddy.app`, submission response, and notarization log.

Failures retain diagnostic files in a `.release-*` directory under
`build/releases/`; no final release directory is created. If submission is
interrupted, consult `xcrun notarytool history --keychain-profile work-buddy-notary`
before resubmitting. Initial notarization may take a while.

Release builds include the Apple Events entitlement used to open terminal
sessions through AppleScript. Ordinary `build.sh` / `run.sh` builds still select
an available Apple identity or fall back to ad-hoc signing; `release.sh` never
falls back to a development or ad-hoc identity.

## Verify and distribute

Test the downloaded archive on a different Mac with Gatekeeper enabled before
publishing it widely. Check first launch, notification authorization, and
opening a session in the supported terminals. Automated checks on the build
machine cannot replace this test.

Upload the final zip and checksum to a GitHub Release for the matching version
tag. Users can extract **Work Buddy.app**, move it to Applications, and open it.
They need macOS 14+ and an authenticated GitHub CLI (`gh auth login`); they do
not need Xcode or Swift to run the packaged app.

For Homebrew, the next step is a public `martintuk/homebrew-tap` repository with
`Casks/work-buddy.rb` referencing the release URL, SHA-256, macOS minimum, `gh`
dependency, and `app "Work Buddy.app"`. That will enable
`brew install --cask martintuk/tap/work-buddy` and `brew upgrade --cask work-buddy`.
These commands are not available until the tap and downloadable release exist.
The source repository can stay private if the release artifacts are hosted
separately at a public URL. Review repository history before making it public.

After the local release passes, CI can call the same script with a temporary
signing keychain and notarization credentials supplied through GitHub secrets.

References: Apple's [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
and [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events).
