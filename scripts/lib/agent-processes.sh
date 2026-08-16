#!/usr/bin/env bash

# Shared helpers for finding Claude/Codex/Devin processes inside tmux sessions.
# Uses an iterative BFS with a pre-built PID map to avoid recursive subshells.

# Global PID→children map and PID→args cache, built once per script invocation.
declare -A _AP_CHILDREN=()  # pid → space-separated child PIDs
declare -A _AP_ARGS=()      # pid → command args
_AP_MAP_BUILT=0

_build_agent_pid_map() {
    (( _AP_MAP_BUILT )) && return
    _AP_MAP_BUILT=1
    _AP_CHILDREN=()
    _AP_ARGS=()
    local pid ppid args
    # Split on whitespace rather than stripping a single leading field: ps
    # right-aligns pid in a fixed-width column, so most rows arrive with
    # leading spaces. The old "${line%% *}" prefix strip returned empty for
    # every one of those and skipped the process — only pids wide enough to
    # fill the column survived, silently gutting the map.
    while read -r pid ppid args; do
        [ -z "$pid" ] && continue
        [ -z "$ppid" ] && continue
        _AP_ARGS[$pid]="$args"
        _AP_CHILDREN[$ppid]+="$pid "
    done < <(ps -eo pid=,ppid=,args= 2>/dev/null)
}

find_matching_descendant_pid() {
    local root_pid="$1"
    local pattern="${2:-claude|codex|devin}"

    _build_agent_pid_map

    # BFS using a simple queue (array + index)
    local queue=("$root_pid")
    local qi=0
    while (( qi < ${#queue[@]} )); do
        local cur="${queue[$qi]}"
        ((qi++))
        local cur_args="${_AP_ARGS[$cur]:-}"
        if [ -n "$cur_args" ] && [[ "$cur_args" =~ (^|[[:space:]/])($pattern)([[:space:]]|$) ]]; then
            echo "$cur"
            return 0
        fi
        # Enqueue children
        local children="${_AP_CHILDREN[$cur]:-}"
        if [ -n "$children" ]; then
            for child in $children; do
                queue+=("$child")
            done
        fi
    done
    return 1
}

find_session_agent_pid() {
    local session="$1"
    local pattern="${2:-claude|codex|devin}"

    _build_agent_pid_map

    # -s scopes to every pane in the session. Without it tmux resolves a bare
    # session target to that session's *current window*, so agents running in
    # any other window went undetected.
    local pane_pids
    pane_pids=$(tmux list-panes -s -t "$session" -F "#{pane_pid}" 2>/dev/null) || return 1

    local pane_pid
    while IFS= read -r pane_pid; do
        [ -z "$pane_pid" ] && continue
        local match_pid
        match_pid=$(find_matching_descendant_pid "$pane_pid" "$pattern")
        if [ -n "$match_pid" ]; then
            echo "$match_pid"
            return 0
        fi
    done <<< "$pane_pids"

    return 1
}

session_has_agent_process() {
    local session="$1"
    local pattern="${2:-claude|codex|devin}"

    find_session_agent_pid "$session" "$pattern" >/dev/null 2>&1
}

# Scan all processes for agent commands, printing "name pid args" per match.
# Matches the executable basename, or the first argument's basename when the
# executable is an interpreter (npm installs run Claude as
# "node /path/to/bin/claude"). Deliberately narrower than matching the whole
# command line: "man claude" or "tail -f logs/claude" must not register a
# pane as an agent.
scan_agent_processes() {
    ps -eo pid=,args= 2>/dev/null | awk '
        function base(s) { sub(".*/", "", s); return s }
        {
            name = base($2)
            if (name !~ /^(claude|codex|devin)$/) {
                if (name !~ /^(node|bun|deno|python[0-9.]*)$/) next
                name = base($3)
                if (name !~ /^(claude|codex|devin)$/) next
            }
            print name, $0
        }
    '
}

_agent_name_from_args() {
    case "$1" in
        *claude*) echo "claude" ;;
        *codex*)  echo "codex" ;;
        *devin*)  echo "devin" ;;
        *)        echo "agent" ;;
    esac
}

# Agent name for a single pane, or empty (status 1) when the pane is not
# running an agent. Hook-written .agent markers win, since they carry the
# name the agent reported for itself; process detection fills the gap for
# agents that started before the hooks were installed.
#
# Callers in a loop should pass pane_pid from their existing list-panes
# format string — resolving it here costs a tmux round trip per pane.
pane_agent_name() {
    local session="$1"
    local pane_id="$2"
    local pane_pid="${3:-}"
    local marker="${PANE_DIR:-$HOME/.cache/tmux-agent-status/panes}/${session}_${pane_id}.agent"

    if [ -f "$marker" ]; then
        local name
        name=$(<"$marker")
        if [ -n "$name" ]; then
            printf '%s\n' "$name"
            return 0
        fi
    fi

    if [ -z "$pane_pid" ]; then
        pane_pid=$(tmux display-message -p -t "$pane_id" '#{pane_pid}' 2>/dev/null)
    fi
    [ -n "$pane_pid" ] || return 1

    local apid
    apid=$(find_matching_descendant_pid "$pane_pid") || return 1

    _build_agent_pid_map
    _agent_name_from_args "${_AP_ARGS[$apid]:-}"
}

# True when the pane is running an agent right now, or carries a hook-written
# marker saying it did.
pane_has_agent() {
    pane_agent_name "$@" >/dev/null 2>&1
}

# Best-effort agent type for a session, from the command line of the first
# agent process found in it. Prints "agent" when nothing more specific is
# known.
find_session_agent_name() {
    local session="$1"
    local apid

    apid=$(find_session_agent_pid "$session" 2>/dev/null)
    if [ -n "$apid" ]; then
        # The pid lookup above runs in a subshell, so make sure the args
        # cache exists in this shell before reading it.
        _build_agent_pid_map
        _agent_name_from_args "${_AP_ARGS[$apid]:-}"
        return
    fi
    echo "agent"
}
