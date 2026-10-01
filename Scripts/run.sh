#!/usr/bin/env bash
# Compila, instala en una ubicación estable y abre la app con Launch Services.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${WORK_BUDDY_APP_DIR:-$HOME/Applications}"
APP="$APP_DIR/Work Buddy.app"
BUNDLE="$("$ROOT/Scripts/build.sh" "${1:-debug}")"

# Preparar y verificar la copia completa antes de cerrar la app actual.
mkdir -p "$APP_DIR"
STAGING="$(mktemp -d "$APP_DIR/.work-buddy-install.XXXXXX")"
cleanup() {
    # Si falló hasta el rollback, no borrar la última copia funcional.
    if [[ -e "$STAGING/previous.app" ]]; then
        if [[ ! -e "$APP" ]] && mv "$STAGING/previous.app" "$APP"; then
            open -g "$APP" || true
        else
            echo "Respaldo de la app anterior conservado en $STAGING/previous.app" >&2
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

# La ruta fija conserva el acceso desde Finder y los ítems de inicio de macOS.
# No reemplazar el bundle mientras la instancia anterior siga ejecutándose.
pkill -x WorkBuddy 2>/dev/null || true
for ((attempt = 0; attempt < 100; attempt++)); do
    pgrep -x WorkBuddy >/dev/null || break
    sleep 0.1
done
if pgrep -x WorkBuddy >/dev/null; then
    echo "Work Buddy no se cerró; se conserva la instalación anterior." >&2
    exit 1
fi

if [[ -e "$APP" ]]; then
    mv "$APP" "$STAGING/previous.app"
fi
if ! mv "$STAGING/Work Buddy.app" "$APP"; then
    exit 1
fi

# `open` deja el proceso bajo Launch Services, independiente de esta terminal.
# -g evita quitarte el foco cada vez que el watch instala una actualización.
if ! open -g "$APP"; then
    rm -rf "$APP"
    if [[ -e "$STAGING/previous.app" ]]; then
        mv "$STAGING/previous.app" "$APP"
        open -g "$APP" || true
    fi
    echo "No se pudo abrir la actualización; se restauró la instalación anterior si existía." >&2
    exit 1
fi

rm -rf "$STAGING/previous.app"
echo "Corriendo $APP — buscá el icono de órbita en la barra de menú."
