#!/usr/bin/env bash
# Compila, mata la instancia anterior y lanza la app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE="$("$ROOT/Scripts/build.sh" "${1:-debug}")"

# La app no tiene ventanas ni icono en el Dock: hay que cerrarla a mano.
pkill -x WorkBuddy 2>/dev/null || true

open "$BUNDLE"
echo "Corriendo $BUNDLE — buscá el icono </> en la barra de menú."
