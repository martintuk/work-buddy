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

# Desde el SDK 27, @State es un macro cuyo plugin (SwiftUIMacros) solo viene con
# Xcode. Si las Command Line Tools no lo traen, compilamos contra el SDK 26.
DEVELOPER_DIR_PATH="$(xcode-select -p)"
LEGACY_SDK="$DEVELOPER_DIR_PATH/SDKs/MacOSX26.sdk"
if [[ -z "${SDKROOT:-}" && -d "$LEGACY_SDK" ]] \
    && ! find "$DEVELOPER_DIR_PATH" -name libSwiftUIMacros.dylib -print -quit 2>/dev/null | grep -q .; then
    export SDKROOT="$LEGACY_SDK"
fi

# El log de compilación va a stderr para que stdout sea solo la ruta del bundle.
swift build -c "$CONFIG" >&2
BIN="$(swift build -c "$CONFIG" --show-bin-path)/$EXECUTABLE"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BIN" "$BUNDLE/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
# Permite identificar la versión exacta instalada en otra máquina.
REVISION="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
if [[ "$REVISION" != unknown ]] && [[ -n "$(git status --porcelain)" ]]; then
    REVISION="$REVISION-dirty"
fi
/usr/libexec/PlistBuddy -c "Add :WorkBuddyRevision string $REVISION" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# Usamos una identidad Apple cuando está disponible: la firma ad-hoc puede
# ejecutar la app, pero macOS puede rechazar su solicitud de notificaciones.
SIGNING_IDENTITY="${WORK_BUDDY_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
        | awk '/"Apple Development:|"Mac Developer:|"Developer ID Application:/ { if (!identity) identity = $2 } END { print identity }')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
    echo "Aviso: firma ad-hoc; macOS puede rechazar las notificaciones. Configurá WORK_BUDDY_SIGNING_IDENTITY con una identidad Apple." >&2
fi
codesign --force --sign "$SIGNING_IDENTITY" "$BUNDLE" >&2
codesign --verify --strict "$BUNDLE" >&2

echo "$BUNDLE"
