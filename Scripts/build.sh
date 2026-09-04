#!/usr/bin/env bash
# Compila con SwiftPM y arma el .app a mano.
# No necesita Xcode completo: alcanza con las Command Line Tools.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"

APP_NAME="work-buddy"
EXECUTABLE="WorkBuddy"
BUNDLE="$ROOT/build/$APP_NAME.app"

cd "$ROOT"

# El log de compilación va a stderr para que stdout sea solo la ruta del bundle.
swift build -c "$CONFIG" >&2
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$EXECUTABLE"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BIN" "$BUNDLE/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Firma ad-hoc: sin firma macOS puede matar el proceso al reemplazar el binario.
codesign --force --sign - "$BUNDLE" >&2

echo "$BUNDLE"
