# Releasing Work Buddy

Work Buddy is distributed as a Developer ID-signed, notarized app in
[GitHub Releases](https://github.com/martintuk/work-buddy/releases).
The [Homebrew cask](https://github.com/martintuk/homebrew-tap/blob/main/Casks/work-buddy.rb)
downloads the same archive. The local release script prepares the archive; it does not
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

### Publish to GitHub and Homebrew

The first public release is **0.1.0, build 2**. For each subsequent version:

1. Commit the source changes, run the tests, push the commit, and wait for CI
   to pass. Build from a clean checkout so `WorkBuddyRevision` identifies that
   exact commit. Pick a new version and an increasing build number.
2. Run `release.sh` with that version and build number. Check the notarization
   log for issues, and test the final ZIP as described above.
3. Create and push a tag pointing to the **commit used for that build**, then
   create a draft GitHub Release with the ZIP and checksum. For example:

   ```bash
   git tag -a v0.1.1 -m 'Work Buddy 0.1.1' <built-commit>
   git push origin v0.1.1
   gh release create v0.1.1 \
     build/releases/0.1.1-3/work-buddy-0.1.1-universal.zip \
     build/releases/0.1.1-3/work-buddy-0.1.1-universal.zip.sha256 \
     --repo martintuk/work-buddy --verify-tag --draft \
     --title 'Work Buddy 0.1.1' --notes-file /path/to/release-notes.md
   ```

4. Review the draft, then publish with
   `gh release edit v0.1.1 --repo martintuk/work-buddy --draft=false --latest`.
   Verify the download works without GitHub authentication.
5. In `martintuk/homebrew-tap`, update `version` and `sha256` in
   `Casks/work-buddy.rb` using the final ZIP's checksum. The URL interpolates
   the version automatically. Commit and push the cask only after the release
   is downloadable.
6. Verify `brew fetch --cask martintuk/tap/work-buddy` and test installation.
   Existing users update with `brew update` followed by
   `brew upgrade --cask work-buddy`.

Keep published release assets immutable. Ship a new version when the app or
archive changes so checksums and Homebrew updates remain consistent.

Signing and notarization currently run on the maintainer's Mac; GitHub CI runs
tests and a build. The signing private key and notarization credentials remain
in the local Keychain. A future signing workflow would need a temporary
keychain and explicitly configured GitHub secrets.

References: Apple's [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
and [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events).
