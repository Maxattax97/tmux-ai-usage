# shellcheck shell=sh
# Shared activity-state helpers. Sourced by ai-usage and ai-activity.
#
# Activity is tracked as one marker file per running agent session in
# ACTIVITY_DIR. Markers are created when an agent starts working and removed
# when it goes idle. A marker records the owning agent process so a turn that
# runs longer than ACTIVITY_TTL still counts as active; the TTL only retires
# markers whose owner could not be identified, and ACTIVITY_MAX caps how long
# any single unrefreshed marker may hold the machine awake.

ACTIVITY_CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/tmux-ai-usage
ACTIVITY_DIR=$ACTIVITY_CACHE_DIR/active
ACTIVITY_LOCK_DIR=$ACTIVITY_CACHE_DIR/inhibit.lock
ACTIVITY_PID_FILE=$ACTIVITY_CACHE_DIR/inhibit.pid
case ${AI_USAGE_ACTIVE_TTL:-} in
    '' | *[!0-9]*) ACTIVITY_TTL=300 ;;
    *) ACTIVITY_TTL=$AI_USAGE_ACTIVE_TTL ;;
esac
case ${AI_USAGE_ACTIVE_MAX:-} in
    '' | *[!0-9]*) ACTIVITY_MAX=3600 ;;
    *) ACTIVITY_MAX=$AI_USAGE_ACTIVE_MAX ;;
esac
ACTIVITY_INHIBIT=${AI_USAGE_INHIBIT_SLEEP:-on}

activity_mtime() {
    # Capture failed stat output: GNU stat -f prints filesystem information
    # before rejecting the BSD format, which must not enter date arithmetic.
    if mtime=$(stat -c %Y "$1" 2> /dev/null) || mtime=$(stat -f %m "$1" 2> /dev/null); then
        printf '%s\n' "$mtime"
    else
        printf '0\n'
    fi
}

activity_marker() {
    agent=$1
    session=$2

    session=$(printf '%s' "$session" | tr -c 'A-Za-z0-9._-' '_')
    [ -n "$session" ] || session=default

    printf '%s/%s-%s\n' "$ACTIVITY_DIR" "$agent" "$session"
}

activity_process_name() {
    name=$(ps -o comm= -p "$1" 2> /dev/null) || return 1
    [ -n "$name" ] || return 1

    printf '%s\n' "${name##*/}"
}

# A hook runs a few levels below the agent itself, so walk up until the agent
# process is found. Its liveness is what "still working" really means. Agents
# that can report their own PID (an in-process plugin, say) pass it instead.
activity_owner_pid() {
    agent=$1

    case ${AI_USAGE_OWNER_PID:-} in
        '' | *[!0-9]*) ;;
        *)
            printf '%s\n' "$AI_USAGE_OWNER_PID"
            return 0
            ;;
    esac

    pid=$$
    depth=0

    while [ "$pid" -gt 1 ] && [ "$depth" -lt 8 ]; do
        case $(activity_process_name "$pid" || true) in
            "$agent" | "$agent "*)
                printf '%s\n' "$pid"
                return 0
                ;;
        esac

        pid=$(ps -o ppid= -p "$pid" 2> /dev/null | tr -d ' ') || return 1
        case $pid in
            '' | *[!0-9]*) return 1 ;;
        esac
        depth=$((depth + 1))
    done

    return 1
}

# alive: owner still running. dead: owner recorded but gone. unknown: no owner
# was ever recorded, so only the TTL can judge the marker.
activity_owner_state() {
    marker=$1

    pid=
    owner=
    while IFS='=' read -r key value; do
        case $key in
            pid) pid=$value ;;
            owner) owner=$value ;;
        esac
    done < "$marker"

    case $pid in
        '' | *[!0-9]*)
            printf 'unknown\n'
            return
            ;;
    esac

    if kill -0 "$pid" 2> /dev/null; then
        # The process name recorded at begin time guards against PID reuse
        # handing us an unrelated process.
        if [ "$(activity_process_name "$pid" || true)" = "$owner" ]; then
            printf 'alive\n'
            return
        fi
    fi

    printf 'dead\n'
}

activity_begin() {
    mkdir -p "$ACTIVITY_DIR"
    marker=$(activity_marker "$1" "$2")
    pid=$(activity_owner_pid "$1" || true)

    {
        printf 'pid=%s\n' "$pid"
        [ -n "$pid" ] && printf 'owner=%s\n' "$(activity_process_name "$pid" || true)"
    } > "$marker"

    return 0
}

activity_end() {
    marker=$(activity_marker "$1" "$2")
    rm -f "$marker"
}

activity_prune() {
    [ -d "$ACTIVITY_DIR" ] || return 0

    now=$(date +%s)
    for marker in "$ACTIVITY_DIR"/*; do
        [ -f "$marker" ] || continue

        age=$((now - $(activity_mtime "$marker")))

        case $(activity_owner_state "$marker") in
            # A live owner is not proof of work: a turn interrupted with Esc
            # fires no Stop hook, so cap even a live session at ACTIVITY_MAX.
            alive) limit=$ACTIVITY_MAX ;;
            dead)
                rm -f "$marker"
                continue
                ;;
            *) limit=$ACTIVITY_TTL ;;
        esac

        [ "$age" -ge "$limit" ] && rm -f "$marker"
    done

    return 0
}

activity_count() {
    count=0

    if [ -d "$ACTIVITY_DIR" ]; then
        for marker in "$ACTIVITY_DIR"/*; do
            [ -f "$marker" ] || continue
            count=$((count + 1))
        done
    fi

    printf '%s\n' "$count"
}

activity_is_active() {
    [ "$(activity_count)" -gt 0 ]
}

inhibit_running() {
    [ -f "$ACTIVITY_PID_FILE" ] || return 1

    pid=$(cat "$ACTIVITY_PID_FILE" 2> /dev/null || true)
    case $pid in
        '' | *[!0-9]*) return 1 ;;
    esac

    kill -0 "$pid" 2> /dev/null
}

inhibit_start() {
    inhibit_running && return 0

    if command -v caffeinate > /dev/null 2>&1; then
        # -i blocks idle system sleep only; the display may still sleep.
        nohup caffeinate -i > /dev/null 2>&1 &
    elif command -v systemd-inhibit > /dev/null 2>&1; then
        nohup systemd-inhibit --what=idle:sleep --who=tmux-ai-usage \
            --why='AI agent running' --mode=block \
            sleep infinity > /dev/null 2>&1 &
    else
        return 0
    fi

    printf '%s\n' "$!" > "$ACTIVITY_PID_FILE"
}

inhibit_stop() {
    inhibit_running || {
        rm -f "$ACTIVITY_PID_FILE"
        return 0
    }

    kill "$(cat "$ACTIVITY_PID_FILE")" 2> /dev/null || true
    rm -f "$ACTIVITY_PID_FILE"
}

# Reconcile the sleep inhibitor with current activity. Safe to call from any
# process; the lock keeps concurrent tmux/hook invocations from double-spawning.
inhibit_sync() {
    mkdir -p "$ACTIVITY_CACHE_DIR"
    mkdir "$ACTIVITY_LOCK_DIR" 2> /dev/null || return 0
    trap 'rmdir "$ACTIVITY_LOCK_DIR" 2>/dev/null || true' EXIT HUP INT TERM

    if [ "$ACTIVITY_INHIBIT" = "on" ] && activity_is_active; then
        inhibit_start
    else
        inhibit_stop
    fi

    rmdir "$ACTIVITY_LOCK_DIR" 2> /dev/null || true
    trap - EXIT HUP INT TERM
}
