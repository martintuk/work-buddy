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
APP="${WORK_BUDDY_APP_DIR:-$HOME/Applications}/Work Buddy.app"
UPDATE_LOG="$ROOT/build/watch-main.log"

if [[ ! "$INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    echo "El intervalo debe ser un número entero de segundos mayor a cero." >&2
    exit 1
fi

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

report_commits() {
    last_status=""
    log "↓ Entraron $behind commit(s):"
    git log --format='      %h %s (%an)' "$before..origin/main"
}

# Comparar con el bundle instalado también cubre un pull manual o un reinicio
# del watch después de que falló la compilación. HEAD ya puede estar al día
# aunque la app todavía sea una versión anterior.
failed_install=""
retry_after=0
update_app() {
    local revision installed now
    [[ "$(git branch --show-current)" == main ]] || return 0
    in_progress && return 0
    # No instalar un estado parcial mientras se está editando en este checkout.
    [[ -z "$(git status --porcelain)" ]] || return 0
    revision="$(git rev-parse --short=12 HEAD)"
    installed="$(/usr/libexec/PlistBuddy -c 'Print :WorkBuddyRevision' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$revision" != "$installed" ]] || return 0
    now="$(date +%s)"
    if [[ "$revision" == "$failed_install" && "$now" -lt "$retry_after" ]]; then
        return 0
    fi

    mkdir -p "$ROOT/build" || return 1
    log "↻ Instalando la app en ${revision}…"
    if ./Scripts/run.sh >"$UPDATE_LOG" 2>&1; then
        failed_install=""
        log "✓ App reiniciada en $(git log -1 --format='%h')."
    else
        failed_install="$revision"
        retry_after=$(( $(date +%s) + 60 ))
        log "✗ Falló la actualización; reintento en 60s. Detalle: $UPDATE_LOG"
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
                report_commits
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
        report_commits
    fi

    update_app
    sleep "$INTERVAL"
done
