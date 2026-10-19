#!/usr/bin/env bash
# Build, install at a stable location, and open through Launch Services.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${WORK_BUDDY_APP_DIR:-$HOME/Applications}"
APP="$APP_DIR/Work Buddy.app"
BUNDLE="$("$ROOT/scripts/build.sh" "${1:-debug}")"

# Prepare and verify the complete copy before closing the running app.
mkdir -p "$APP_DIR"
STAGING="$(mktemp -d "$APP_DIR/.work-buddy-install.XXXXXX")"
cleanup() {
    # If rollback also failed, preserve the last working copy.
    if [[ -e "$STAGING/previous.app" ]]; then
        if [[ ! -e "$APP" ]] && mv "$STAGING/previous.app" "$APP"; then
            open -g "$APP" || true
        else
            echo "Previous app backup preserved at $STAGING/previous.app" >&2
            return
        fi
    fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ditto "$BUNDLE" "$STAGING/Work Buddy.app"
codesign --verify --strict "$STAGING/Work Buddy.app"

# A stable path preserves Finder access and macOS login items.
# Do not replace the bundle while the previous instance is running.
pkill -x WorkBuddy 2>/dev/null || true
for ((attempt = 0; attempt < 100; attempt++)); do
    pgrep -x WorkBuddy >/dev/null || break
    sleep 0.1
done
if pgrep -x WorkBuddy >/dev/null; then
    echo "Work Buddy did not quit; preserving the previous installation." >&2
    exit 1
fi

if [[ -e "$APP" ]]; then
    mv "$APP" "$STAGING/previous.app"
fi
if ! mv "$STAGING/Work Buddy.app" "$APP"; then
    exit 1
fi

# Launch Services owns the process independently of this terminal.
# -g avoids stealing focus whenever the watcher installs an update.
if ! open -g "$APP"; then
    rm -rf "$APP"
    if [[ -e "$STAGING/previous.app" ]]; then
        mv "$STAGING/previous.app" "$APP"
        open -g "$APP" || true
    fi
    echo "Could not open the update; restored the previous installation if available." >&2
    exit 1
fi

rm -rf "$STAGING/previous.app"
echo "Running $APP — look for the orbit icon in the menu bar."
