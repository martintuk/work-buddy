#!/usr/bin/env bash
# Sigue origin/main y reinicia la app cuando entra algo nuevo.
#
# Sólo avanza por fast-forward: nunca rebasea ni mergea, así que no deja el
# repo a mitad de un conflicto. Con commits o cambios locales que estorben,
# espera hasta que se resuelvan. `--no-write-fetch-head` evita pisarse con un
# `git pull` manual sobre FETCH_HEAD.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERVAL="${1:-5}"

cd "$ROOT"

last=""
while true; do
    git fetch -q --no-write-fetch-head origin +main:refs/remotes/origin/main 2>/dev/null \
        && git merge -q --ff-only origin/main >/dev/null 2>&1
    head="$(git rev-parse HEAD)"
    if [[ "$head" != "$last" ]]; then
        [[ -n "$last" ]] && echo "$(date +%T) $(git log -1 --format='%h %s')"
        [[ -n "$last" ]] && ./Scripts/run.sh
        last="$head"
    fi
    sleep "$INTERVAL"
done
