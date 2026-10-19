#!/usr/bin/env bash
# Build with SwiftPM and assemble the .app bundle manually.
# The Command Line Tools are sufficient; full Xcode is not required.
set -euo pipefail

usage() {
    cat <<EOF
Usage: scripts/build.sh [debug|release]

Build build/work-buddy.app (default: debug) and print its path.
Set WORK_BUDDY_SIGNING_IDENTITY to choose a code-signing identity.
EOF
}

case "${1:-debug}" in
    debug | release) CONFIG="${1:-debug}" ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="work-buddy"
EXECUTABLE="WorkBuddy"
BUNDLE="$ROOT/build/$APP_NAME.app"

cd "$ROOT"

# shellcheck source=lib/toolchain.sh
source "$ROOT/scripts/lib/toolchain.sh"

# Send build logs to stderr so stdout contains only the bundle path.
swift build -c "$CONFIG" >&2
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$EXECUTABLE"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BIN" "$BUNDLE/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
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
codesign --force --sign "$SIGNING_IDENTITY" "$BUNDLE" >&2
codesign --verify --strict "$BUNDLE" >&2

echo "$BUNDLE"
