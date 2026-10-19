#!/usr/bin/env bash
# Build with SwiftPM and assemble the .app bundle manually.
# The Command Line Tools are sufficient; full Xcode is not required.
set -euo pipefail

usage() {
    cat <<EOF
Usage: scripts/build.sh [debug|release]

Build build/work-buddy.app (default: debug) and print its path.
Set WORK_BUDDY_SIGNING_IDENTITY to choose a code-signing identity.
Set WORK_BUDDY_UNIVERSAL=1 to build for Apple silicon and Intel.
Set WORK_BUDDY_VERSION and WORK_BUDDY_BUILD_NUMBER to override bundle versions.
EOF
}

case "${1:-debug}" in
    debug | release) CONFIG="${1:-debug}" ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
esac

if [[ -n "${WORK_BUDDY_VERSION:-}" && ! "$WORK_BUDDY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "WORK_BUDDY_VERSION must have the form 1.2.3." >&2
    exit 64
fi
if [[ -n "${WORK_BUDDY_BUILD_NUMBER:-}" && ! "$WORK_BUDDY_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "WORK_BUDDY_BUILD_NUMBER must be a positive integer." >&2
    exit 64
fi
case "${WORK_BUDDY_UNIVERSAL:-0}" in
    0 | 1) ;;
    *) echo "WORK_BUDDY_UNIVERSAL must be 0 or 1." >&2; exit 64 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="work-buddy"
EXECUTABLE="WorkBuddy"
BUNDLE="$ROOT/build/$APP_NAME.app"

cd "$ROOT"

# shellcheck source=lib/toolchain.sh
source "$ROOT/scripts/lib/toolchain.sh"

# Send build logs to stderr so stdout contains only the bundle path.
BUILD_ARGS=(-c "$CONFIG")
if [[ "${WORK_BUDDY_UNIVERSAL:-0}" == 1 ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}" >&2
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/$EXECUTABLE"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BIN" "$BUNDLE/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
if [[ -n "${WORK_BUDDY_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $WORK_BUDDY_VERSION" "$BUNDLE/Contents/Info.plist"
fi
if [[ -n "${WORK_BUDDY_BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $WORK_BUDDY_BUILD_NUMBER" "$BUNDLE/Contents/Info.plist"
fi
# Identify the exact revision installed on another computer.
REVISION="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
if [[ "$REVISION" != unknown ]] && [[ -n "$(git status --porcelain)" ]]; then
    REVISION="$REVISION-dirty"
fi
/usr/libexec/PlistBuddy -c "Add :WorkBuddyRevision string $REVISION" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Prefer an Apple identity: ad-hoc signing can run the app,
# but macOS may reject its notification authorization request.
SIGNING_IDENTITY="${WORK_BUDDY_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
        | awk '/"Apple Development:|"Mac Developer:|"Developer ID Application:/ { if (!identity) identity = $2 } END { print identity }')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
    echo "Warning: ad-hoc signing; macOS may reject notifications. Set WORK_BUDDY_SIGNING_IDENTITY to an Apple identity." >&2
fi
SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$CONFIG" == release ]]; then
    SIGN_ARGS+=(--options runtime --entitlements "$ROOT/Resources/WorkBuddy.entitlements")
    if [[ "$SIGNING_IDENTITY" != - ]]; then
        SIGN_ARGS+=(--timestamp)
    fi
fi
codesign "${SIGN_ARGS[@]}" "$BUNDLE" >&2
codesign --verify --strict "$BUNDLE" >&2

echo "$BUNDLE"
