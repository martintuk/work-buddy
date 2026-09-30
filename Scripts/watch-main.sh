#!/usr/bin/env bash
# Sigue origin/main y reinicia la app cuando entra algo nuevo.
#
# Sólo avanza por fast-forward: nunca rebasea ni mergea, así que no deja el
# repo a mitad de un conflicto. Con commits o cambios locales que estorben,
# espera hasta que se resuelvan. `--no-write-fetch-head` evita pisarse con un
# `git pull` manual sobre FETCH_HEAD.
#
# Cada estado se informa una sola vez, cuando cambia, para no llenar la
# terminal cada pocos segundos.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERVAL="${1:-5}"

cd "$ROOT"

log() { printf '%s  %s\n' "$(date +%T)" "$*"; }

# Imprime sólo si el mensaje cambió desde la última vuelta.
last_status=""
status() {
    [[ "$1" == "$last_status" ]] && return
    last_status="$1"
    log "$1"
}

log "Siguiendo origin/main cada ${INTERVAL}s en $(git log -1 --format='%h %s'). Ctrl-C para salir."

while true; do
    if ! error="$(git fetch -q --no-write-fetch-head origin +main:refs/remotes/origin/main 2>&1)"; then
        status "✗ Falló el fetch: ${error##*$'\n'}"
        sleep "$INTERVAL"
        continue
    fi

    read -r ahead behind < <(git rev-list --left-right --count HEAD...origin/main)
    branch="$(git branch --show-current)"

    if [[ "$behind" == 0 ]]; then
        if [[ "$ahead" == 0 ]]; then
            status "✓ Al día con origin/main."
        else
            status "✓ Al día; $ahead commit(s) local(es) sin pushear."
        fi
    elif [[ "$branch" != main ]]; then
        status "⏸ origin/main tiene $behind commit(s) nuevo(s), pero estás en '${branch:-HEAD detached}'."
    elif [[ "$ahead" != 0 ]]; then
        status "⏸ origin/main tiene $behind commit(s) nuevo(s) y main $ahead local(es): no hay fast-forward. Pusheá o rebaseá a mano."
    elif before="$(git rev-parse HEAD)" && ! error="$(git merge -q --ff-only origin/main 2>&1)"; then
        files="$(sed -n 's/^[[:space:]]\{1,\}//p' <<<"$error" | grep -v '^Please\|^Aborting' | paste -sd ',' - | sed 's/,/, /g')"
        status "⏸ origin/main tiene $behind commit(s) nuevo(s); cambios locales impiden avanzar: ${files:-${error%%$'\n'*}}"
    else
        last_status=""
        log "↓ Entraron $behind commit(s):"
        git log --format='      %h %s (%an)' "$before..HEAD"
        log "↻ Reiniciando la app…"
        if ./Scripts/run.sh >/dev/null 2>&1; then
            log "✓ App reiniciada en $(git log -1 --format='%h')."
        else
            log "✗ Falló ./Scripts/run.sh; corrélo a mano para ver el error."
        fi
    fi

    sleep "$INTERVAL"
done
