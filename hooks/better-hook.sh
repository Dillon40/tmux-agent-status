#!/usr/bin/env bash

# Claude Code hook for tmux-agent-status
# Updates tmux session and pane status files based on Claude's working state

STATUS_DIR="$HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
PANE_DIR="$STATUS_DIR/panes"
REFRESH_FILE="$STATUS_DIR/.sidebar-refresh"
mkdir -p "$STATUS_DIR" "$WAIT_DIR" "$PARKED_DIR" "$PANE_DIR"
[ -f "$REFRESH_FILE" ] || : > "$REFRESH_FILE"

# Read JSON from stdin (required by Claude Code hooks). The Stop payload
# carries a `background_tasks` array that we inspect below.
HOOK_JSON="$(cat 2>/dev/null || true)"

in_remote_session() {
    [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]
}

get_tmux_session() {
    local tmux_session=""

    if [ -n "${TMUX:-}" ] || in_remote_session; then
        tmux_session=$(tmux display-message -p '#{session_name}' 2>/dev/null)

        if [ -z "$tmux_session" ]; then
            if in_remote_session; then
                case "$(hostname -s 2>/dev/null)" in
                    instance-*) tmux_session="reachgpu" ;;
                    keen-schrodinger) tmux_session="sd1" ;;
                    sam-l4-workstation-image) tmux_session="l4-workstation" ;;
                    persistent-faraday) tmux_session="tig" ;;
                    instance-20250620-122051) tmux_session="reachgpu" ;;
                    *) tmux_session=$(hostname -s 2>/dev/null) ;;
                esac
            elif [ -n "${TMUX:-}" ]; then
                local socket_path="${TMUX%%,*}"
                tmux_session=$(basename "$socket_path")
            fi
        fi
    fi

    [ -n "$tmux_session" ] || return 1
    printf '%s\n' "$tmux_session"
}

# Mirrors status_priority in scripts/lib/session-status.sh. Kept local so the
# hook stays dependency-free and fast — it runs on every tool call.
hook_status_priority() {
    case "$1" in
        working) echo 6 ;;
        wait)    echo 5 ;;
        ask)     echo 4 ;;
        done)    echo 3 ;;
        stale)   echo 2 ;;
        parked)  echo 1 ;;
        *)       echo 0 ;;
    esac
}

set_status() {
    local tmux_session="$1"
    local requested_status="$2"
    local session_status="$requested_status"
    local status_file="$STATUS_DIR/${tmux_session}.status"
    local remote_status_file="$STATUS_DIR/${tmux_session}-remote.status"

    if [ -n "${TMUX_PANE:-}" ]; then
        local pane_file="$PANE_DIR/${tmux_session}_${TMUX_PANE}.status"
        local agent_file="$PANE_DIR/${tmux_session}_${TMUX_PANE}.agent"
        echo "$requested_status" > "$pane_file"
        echo "claude" > "$agent_file"

        # Roll the session up to its most urgent live pane. The old version
        # only recognised working and wait, so an "ask" pane silently reported
        # the session as done.
        local live_panes=""
        live_panes=" $(tmux list-panes -s -t "$tmux_session" -F '#{pane_id}' 2>/dev/null | tr '\n' ' ') "

        session_status="done"
        local best_priority=0
        best_priority=$(hook_status_priority "$session_status")

        local existing_pane_file=""
        for existing_pane_file in "$PANE_DIR/${tmux_session}_"*.status; do
            [ -f "$existing_pane_file" ] || continue

            local pane_name pane_id
            pane_name=$(basename "$existing_pane_file" .status)
            pane_id="${pane_name##*_}"

            # Panes only get their state files removed when closed through the
            # switcher, so a pane that simply exited leaves a status file
            # behind. A stranded "working" file pinned the whole session to
            # working forever. Reap it instead of counting it.
            if [ "$live_panes" != "  " ] && [[ "$live_panes" != *" $pane_id "* ]]; then
                rm -f "$existing_pane_file" "$PANE_DIR/${tmux_session}_${pane_id}.agent" 2>/dev/null
                continue
            fi

            local pane_status="" pane_priority=0
            pane_status=$(cat "$existing_pane_file" 2>/dev/null || echo "")
            pane_priority=$(hook_status_priority "$pane_status")
            if [ "$pane_priority" -gt "$best_priority" ]; then
                best_priority="$pane_priority"
                session_status="$pane_status"
            fi
        done
    fi

    echo "$session_status" > "$status_file"
    if in_remote_session; then
        echo "$session_status" > "$remote_status_file" 2>/dev/null
    fi
}

clear_interaction_overrides() {
    local tmux_session="$1"
    local session_wait_file="$WAIT_DIR/${tmux_session}.wait"
    local session_parked_file="$PARKED_DIR/${tmux_session}.parked"

    if [ -f "$session_wait_file" ]; then
        rm -f "$session_wait_file" "$WAIT_DIR/${tmux_session}_"*.wait 2>/dev/null
    elif [ -n "${TMUX_PANE:-}" ]; then
        rm -f "$WAIT_DIR/${tmux_session}_${TMUX_PANE}.wait"
    fi

    if [ -f "$session_parked_file" ]; then
        rm -f "$session_parked_file" "$PARKED_DIR/${tmux_session}_"*.parked 2>/dev/null
    elif [ -n "${TMUX_PANE:-}" ]; then
        rm -f "$PARKED_DIR/${tmux_session}_${TMUX_PANE}.parked"
    fi
}

mark_refresh() {
    touch "$REFRESH_FILE" 2>/dev/null || true
}

# Returns 0 if the Claude Code Stop payload reports a background task that is
# still running (e.g. a `run_in_background` Bash command). When the agent ends
# its turn while a background task keeps working, it isn't really idle, so we
# keep it "working" instead of flipping to "done". Claude re-invokes the agent
# when the task finishes, firing another Stop with an empty (or all-finished)
# background_tasks array, which then marks the session done.
#
# Older Claude versions omit the field entirely; that yields no match and the
# Stop is treated as done, matching the previous behaviour.
has_running_background_task() {
    local json="$1"
    [ -n "$json" ] || return 1

    if command -v jq >/dev/null 2>&1; then
        local count
        count="$(printf '%s' "$json" | \
            jq -r '[.background_tasks[]? | select(.status == "running")] | length' \
            2>/dev/null)"
        [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null
        return
    fi

    # Fallback without jq: an empty array is "background_tasks":[] and is
    # rejected first; otherwise look for a running task in a populated array.
    case "$json" in
        *'"background_tasks":[]'*) return 1 ;;
        *'"background_tasks":['*'"status":"running"'*) return 0 ;;
        *) return 1 ;;
    esac
}

# Pull a top-level string field out of the hook payload. jq when available,
# otherwise a grep/sed pass good enough for the flat fields we care about.
json_field() {
    local json="$1"
    local field="$2"
    [ -n "$json" ] || return 1

    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null
        return
    fi

    printf '%s' "$json" \
        | grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 \
        | sed "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"//;s/\"$//"
}

# Which flavour of Notification fired. Claude Code supports Notification
# matchers (permission_prompt, idle_prompt, …), so the cleanest signal is the
# matcher name passed through as $2. Fall back to reading it off the payload
# so a single unmatched Notification entry still behaves sensibly.
notification_kind() {
    local explicit="${1:-}"
    if [ -n "$explicit" ]; then
        printf '%s\n' "$explicit"
        return
    fi

    local kind
    for field in notification_type type event; do
        kind=$(json_field "$HOOK_JSON" "$field")
        [ -n "$kind" ] && { printf '%s\n' "$kind"; return; }
    done

    # No typed field: infer from the human-readable message.
    local message
    message=$(json_field "$HOOK_JSON" "message")
    case "$message" in
        *permission*|*Permission*|*"approve"*) printf 'permission_prompt\n' ;;
        *) printf 'idle_prompt\n' ;;
    esac
}

current_status() {
    local tmux_session="$1"
    if [ -n "${TMUX_PANE:-}" ] && [ -f "$PANE_DIR/${tmux_session}_${TMUX_PANE}.status" ]; then
        cat "$PANE_DIR/${tmux_session}_${TMUX_PANE}.status" 2>/dev/null
        return
    fi
    cat "$STATUS_DIR/${tmux_session}.status" 2>/dev/null
}

TMUX_SESSION=$(get_tmux_session) || exit 0
HOOK_TYPE="${1:-}"
HOOK_MATCHER="${2:-}"
WAIT_FILE="$WAIT_DIR/${TMUX_SESSION}.wait"
PARKED_FILE="$PARKED_DIR/${TMUX_SESSION}.parked"

case "$HOOK_TYPE" in
    UserPromptSubmit)
        # User submitted a prompt — this is an explicit interaction, so
        # cancel wait mode and unpark.
        clear_interaction_overrides "$TMUX_SESSION"
        set_status "$TMUX_SESSION" "working"
        mark_refresh
        ;;
    PreToolUse)
        # Agent is calling a tool — mark working but do NOT unpark.
        # Parking is an explicit user decision; only user interaction
        # (UserPromptSubmit) should unpark.
        rm -f "$WAIT_FILE"
        if [ ! -f "$PARKED_FILE" ]; then
            # AskUserQuestion means the agent has stopped to ask something and
            # is blocked on a human. Restored from PR #25, which PR #22 dropped
            # when it rewrote this file — the read side (icon, sort priority,
            # sound) survived, leaving "ask" renderable but unreachable.
            if [ "$(json_field "$HOOK_JSON" tool_name)" = "AskUserQuestion" ]; then
                set_status "$TMUX_SESSION" "ask"
                SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
                "$SCRIPT_DIR/../scripts/play-sound.sh" ask 2>/dev/null &
            else
                set_status "$TMUX_SESSION" "working"
            fi
        fi
        mark_refresh
        ;;
    Stop)
        # Claude has finished responding (SubagentStop excluded - subagents
        # finishing doesn't mean the main agent is done). If the turn ended
        # while a background task is still running, the agent isn't idle yet —
        # keep it working until a later Stop reports the task finished.
        if has_running_background_task "$HOOK_JSON"; then
            set_status "$TMUX_SESSION" "working"
        else
            set_status "$TMUX_SESSION" "done"
        fi
        mark_refresh
        ;;
    Notification)
        # Not all notifications mean the same thing. A permission prompt is a
        # hard block — the agent cannot proceed without a human — while an idle
        # prompt just means the turn ended a while ago. Collapsing both to
        # "done" made blocked agents indistinguishable from finished ones.
        NOTIFY_KIND=$(notification_kind "$HOOK_MATCHER")
        case "$NOTIFY_KIND" in
            permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input)
                set_status "$TMUX_SESSION" "ask"
                SOUND_ARG="ask"
                ;;
            *)
                # Never let a plain idle ping downgrade a pane that is already
                # blocked on a question or a permission decision.
                case "$(current_status "$TMUX_SESSION")" in
                    ask) SOUND_ARG="" ;;
                    *)   set_status "$TMUX_SESSION" "done"; SOUND_ARG="" ;;
                esac
                ;;
        esac
        mark_refresh

        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        "$SCRIPT_DIR/../scripts/play-sound.sh" $SOUND_ARG 2>/dev/null &
        ;;
esac

# Always exit successfully
exit 0
