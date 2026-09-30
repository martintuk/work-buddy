#!/usr/bin/env bash
# Sigue origin/main y reinicia la app cuando entra algo nuevo.
#
# Sin commits locales avanza por fast-forward. Con commits locales los rebasea
# sobre origin/main; si hay conflicto aborta el rebase y espera, así que nunca
# deja el repo a mitad de camino. No pushea. `--no-write-fetch-head` evita
# pisarse con un `git pull` manual sobre FETCH_HEAD.
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

in_progress() {
    local path
    for path in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
        [[ -e "$(git rev-parse --git-path "$path")" ]] && return 0
    done
    return 1
}

restart() {
    last_status=""
    log "↓ Entraron $behind commit(s):"
    git log --format='      %h %s (%an)' "$before..origin/main"
    log "↻ Reiniciando la app…"
    if ./Scripts/run.sh >/dev/null 2>&1; then
        log "✓ App reiniciada en $(git log -1 --format='%h')."
    else
        log "✗ Falló ./Scripts/run.sh; corrélo a mano para ver el error."
    fi
}

# Par HEAD/origin/main cuyo rebase ya falló, para no reintentarlo cada vuelta.
failed_rebase=""

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
    elif in_progress; then
        status "⏸ origin/main tiene $behind commit(s) nuevo(s), pero hay un rebase o merge en curso."
    elif [[ "$ahead" != 0 ]]; then
        pair="$(git rev-parse HEAD) $(git rev-parse origin/main)"
        if ! git diff --quiet || ! git diff --cached --quiet; then
            status "⏸ origin/main tiene $behind commit(s) nuevo(s) y main $ahead local(es); commiteá o descartá los cambios para rebasear."
        elif [[ "$pair" == "$failed_rebase" ]]; then
            :
        else
            before="$(git merge-base HEAD origin/main)"
            if git rebase -q origin/main >/dev/null 2>&1; then
                log "↺ Rebaseé $ahead commit(s) local(es) sobre origin/main (siguen sin pushear)."
                restart
            else
                files="$(git diff --name-only --diff-filter=U | paste -sd ',' - | sed 's/,/, /g')"
                in_progress && git rebase --abort >/dev/null 2>&1
                failed_rebase="$pair"
                status "⏸ Tus $ahead commit(s) local(es) chocan con origin/main${files:+ en $files}. Dejé todo como estaba; rebaseá a mano."
            fi
        fi
    elif before="$(git rev-parse HEAD)" && ! error="$(git merge -q --ff-only origin/main 2>&1)"; then
        files="$(sed -n 's/^[[:space:]]\{1,\}//p' <<<"$error" | grep -v '^Please\|^Aborting' | paste -sd ',' - | sed 's/,/, /g')"
        status "⏸ origin/main tiene $behind commit(s) nuevo(s); cambios locales impiden avanzar: ${files:-${error%%$'\n'*}}"
    else
        restart
    fi

    sleep "$INTERVAL"
done
