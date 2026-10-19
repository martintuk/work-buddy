#!/usr/bin/env bash
# Follow origin/main and restart the app when new commits arrive.
#
# Fast-forward when there are no local commits; otherwise rebase them onto
# origin/main. On conflict, abort the rebase and wait, leaving no partial rebase.
# Never push. --no-write-fetch-head avoids interfering with a manual git pull.
#
# Report each status only when it changes to avoid flooding the terminal.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERVAL="${1:-5}"
APP="${WORK_BUDDY_APP_DIR:-$HOME/Applications}/Work Buddy.app"
UPDATE_LOG="$ROOT/build/watch-main.log"

if [[ ! "$INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    echo "The interval must be a positive integer number of seconds." >&2
    exit 1
fi

cd "$ROOT"

log() { printf '%s  %s\n' "$(date +%T)" "$*"; }

# Print only when the message changed since the previous iteration.
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
    log "↓ Received $behind commit(s):"
    git log --format='      %h %s (%an)' "$before..origin/main"
}

# Compare the installed bundle too, covering manual pulls and watcher restarts
# after failed builds. HEAD may be current while the installed app is still old.
failed_install=""
retry_after=0
update_app() {
    local revision installed now
    [[ "$(git branch --show-current)" == main ]] || return 0
    in_progress && return 0
    # Do not install a partial state while this checkout is being edited.
    [[ -z "$(git status --porcelain)" ]] || return 0
    revision="$(git rev-parse --short=12 HEAD)"
    installed="$(/usr/libexec/PlistBuddy -c 'Print :WorkBuddyRevision' "$APP/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$revision" != "$installed" ]] || return 0
    now="$(date +%s)"
    if [[ "$revision" == "$failed_install" && "$now" -lt "$retry_after" ]]; then
        return 0
    fi

    mkdir -p "$ROOT/build" || return 1
    log "↻ Installing app at ${revision}…"
    if ./Scripts/run.sh >"$UPDATE_LOG" 2>&1; then
        failed_install=""
        log "✓ App restarted at $(git log -1 --format='%h')."
    else
        failed_install="$revision"
        retry_after=$(( $(date +%s) + 60 ))
        log "✗ Update failed; retrying in 60s. Details: $UPDATE_LOG"
    fi
}

# Remember the HEAD/origin/main pair whose rebase failed to avoid retrying it every cycle.
failed_rebase=""

log "Watching origin/main every ${INTERVAL}s at $(git log -1 --format='%h %s'). Ctrl-C to exit."

while true; do
    if ! error="$(git fetch -q --no-write-fetch-head origin +main:refs/remotes/origin/main 2>&1)"; then
        status "✗ Fetch failed: ${error##*$'\n'}"
        sleep "$INTERVAL"
        continue
    fi

    read -r ahead behind < <(git rev-list --left-right --count HEAD...origin/main)
    branch="$(git branch --show-current)"

    if [[ "$behind" == 0 ]]; then
        if [[ "$ahead" == 0 ]]; then
            status "✓ Up to date with origin/main."
        else
            status "✓ Up to date; $ahead unpushed local commit(s)."
        fi
    elif [[ "$branch" != main ]]; then
        status "⏸ origin/main has $behind new commit(s), but the current branch is '${branch:-HEAD detached}'."
    elif in_progress; then
        status "⏸ origin/main has $behind new commit(s), but a rebase or merge is in progress."
    elif [[ "$ahead" != 0 ]]; then
        pair="$(git rev-parse HEAD) $(git rev-parse origin/main)"
        if ! git diff --quiet || ! git diff --cached --quiet; then
            status "⏸ origin/main has $behind new commit(s) and main has $ahead local commit(s); commit or discard changes before rebasing."
        elif [[ "$pair" == "$failed_rebase" ]]; then
            :
        else
            before="$(git merge-base HEAD origin/main)"
            if git rebase -q origin/main >/dev/null 2>&1; then
                log "↺ Rebased $ahead local commit(s) onto origin/main (still unpushed)."
                report_commits
            else
                files="$(git diff --name-only --diff-filter=U | paste -sd ',' - | sed 's/,/, /g')"
                in_progress && git rebase --abort >/dev/null 2>&1
                failed_rebase="$pair"
                status "⏸ Your $ahead local commit(s) conflict with origin/main${files:+ in $files}. Restored the previous state; rebase manually."
            fi
        fi
    elif before="$(git rev-parse HEAD)" && ! error="$(git merge -q --ff-only origin/main 2>&1)"; then
        files="$(sed -n 's/^[[:space:]]\{1,\}//p' <<<"$error" | grep -v '^Please\|^Aborting' | paste -sd ',' - | sed 's/,/, /g')"
        status "⏸ origin/main has $behind new commit(s); local changes prevent updating: ${files:-${error%%$'\n'*}}"
    else
        report_commits
    fi

    update_app
    sleep "$INTERVAL"
done
