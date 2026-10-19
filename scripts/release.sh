#!/usr/bin/env bash
# Build a signed, notarized universal app for distribution. Never publish it.
set -euo pipefail

usage() {
    cat <<EOF
Usage: scripts/release.sh VERSION BUILD_NUMBER

Create build/releases/VERSION-BUILD_NUMBER/work-buddy-VERSION-universal.zip.
VERSION must have the form 1.2.3; BUILD_NUMBER must be a positive integer.

Required environment:
  WORK_BUDDY_SIGNING_IDENTITY  Developer ID Application certificate name or SHA-1
  WORK_BUDDY_NOTARY_PROFILE    Credentials saved with notarytool store-credentials

The script submits the app to Apple, staples the accepted ticket, checks
Gatekeeper, and writes a SHA-256 checksum. It does not upload to GitHub.
EOF
}

case "${1:-}" in
    -h | --help) usage; exit 0 ;;
esac
if [[ $# != 2 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
    usage >&2
    exit 64
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$1"
BUILD_NUMBER="$2"
DESTINATION="$ROOT/build/releases/$VERSION-$BUILD_NUMBER"
if [[ -e "$DESTINATION" ]]; then
    echo "Release already exists: $DESTINATION. Choose a new build number." >&2
    exit 1
fi
if [[ -z "${WORK_BUDDY_SIGNING_IDENTITY:-}" || -z "${WORK_BUDDY_NOTARY_PROFILE:-}" ]]; then
    echo "Set WORK_BUDDY_SIGNING_IDENTITY and WORK_BUDDY_NOTARY_PROFILE. See docs/releasing.md." >&2
    exit 1
fi

# Resolve only valid distribution identities. Local/ad-hoc certificates must
# fail before building or sending anything to Apple's notarization service.
IDENTITY="$(security find-identity -v -p codesigning | awk -v requested="$WORK_BUDDY_SIGNING_IDENTITY" '
    /"Developer ID Application:/ {
        hash = $2
        name = $0
        sub(/^[^"]*"/, "", name)
        sub(/".*$/, "", name)
        if (requested == name || toupper(requested) == toupper(hash)) { print hash; exit }
    }')"
if [[ -z "$IDENTITY" ]]; then
    echo "The requested Developer ID Application identity is not available in the keychain." >&2
    exit 1
fi
xcrun --find notarytool >/dev/null
xcrun --find stapler >/dev/null

mkdir -p "$ROOT/build/releases"
STAGING="$(mktemp -d "$ROOT/build/releases/.release-$VERSION-$BUILD_NUMBER.XXXXXX")"
report_failure() {
    local result=$?
    if [[ $result != 0 ]]; then
        echo "Release failed; diagnostic files retained at $STAGING" >&2
    fi
}
trap report_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

BUNDLE="$(WORK_BUDDY_SIGNING_IDENTITY="$IDENTITY" \
    WORK_BUDDY_UNIVERSAL=1 WORK_BUDDY_VERSION="$VERSION" \
    WORK_BUDDY_BUILD_NUMBER="$BUILD_NUMBER" "$ROOT/scripts/build.sh" release)"
APP="$STAGING/Work Buddy.app"
ditto "$BUNDLE" "$APP"
codesign --verify --strict "$APP"
# Verify the actual signature as well as the selected keychain identity.
codesign --verify --strict -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$APP"
lipo "$APP/Contents/MacOS/WorkBuddy" -verify_arch arm64
lipo "$APP/Contents/MacOS/WorkBuddy" -verify_arch x86_64

ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/submission.zip"
SUBMIT_RESULT=0
xcrun notarytool submit "$STAGING/submission.zip" \
    --keychain-profile "$WORK_BUDDY_NOTARY_PROFILE" --wait --output-format plist \
    > "$STAGING/submission.plist" || SUBMIT_RESULT=$?
SUBMISSION_ID="$(/usr/libexec/PlistBuddy -c 'Print :id' "$STAGING/submission.plist" 2>/dev/null || true)"
STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' "$STAGING/submission.plist" 2>/dev/null || true)"
if [[ -n "$SUBMISSION_ID" ]]; then
    echo "Notarization submission: $SUBMISSION_ID ($STATUS)" >&2
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$WORK_BUDDY_NOTARY_PROFILE" \
        "$STAGING/notarization.json" >&2 || echo "Could not retrieve notarization log." >&2
fi
if [[ $SUBMIT_RESULT != 0 || "$STATUS" != Accepted ]]; then
    echo "Notarization was not accepted. Inspect submission.plist and notarization.json before retrying." >&2
    exit 1
fi

xcrun stapler staple "$APP" >&2
xcrun stapler validate "$APP" >&2
codesign --verify --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# The downloadable archive must contain the stapled app, not the submission copy.
ARCHIVE="work-buddy-$VERSION-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/$ARCHIVE"
(
    cd "$STAGING"
    shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
)
rm "$STAGING/submission.zip"
mv "$STAGING" "$DESTINATION"
echo "$DESTINATION/$ARCHIVE"
