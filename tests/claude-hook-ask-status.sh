#!/usr/bin/env bash

# Regression test for the "ask" status write path.
#
# PR #25 added "ask" (agent is blocked on a human). PR #22 rewrote
# hooks/better-hook.sh a day later and dropped every writer, while the read
# side — icon, sort priority, sound, status-line counts — survived. The state
# stayed renderable but unreachable for months. These assertions fail loudly
# if a future rewrite drops it again.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
WAIT_DIR="$STATUS_DIR/wait"
PARKED_DIR="$STATUS_DIR/parked"
PANE_DIR="$STATUS_DIR/panes"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$WAIT_DIR" "$PARKED_DIR" "$PANE_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    display-message)
        if [ "${2:-}" = "-p" ] && [ "${3:-}" = "#{session_name}" ]; then
            echo "asksess"
            exit 0
        fi
        ;;
    list-panes)
        # Session rollup asks for live panes; report both test panes.
        echo "%1"
        echo "%2"
        exit 0
        ;;
esac

exit 1
EOF
chmod +x "$FAKE_BIN/tmux"

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    if [ "$expected" != "$actual" ]; then
        echo "Assertion failed: $message" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

run_hook() {
    local hook_name="$1" pane_id="$2" payload="$3" matcher="${4:-}"

    printf '%s\n' "$payload" | \
        PATH="$FAKE_BIN:$PATH" \
        HOME="$TEST_HOME" \
        TMUX="/tmp/tmux-test,4242,0" \
        TMUX_PANE="$pane_id" \
        "$REPO_DIR/hooks/better-hook.sh" "$hook_name" $matcher
}

pane_status() { cat "$PANE_DIR/asksess_$1.status"; }
sess_status() { cat "$STATUS_DIR/asksess.status"; }

# ── AskUserQuestion marks the pane blocked ───────────────────────────
run_hook PreToolUse "%1" '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'
assert_eq "ask" "$(pane_status %1)" "AskUserQuestion should mark the pane ask"
assert_eq "ask" "$(sess_status)" "AskUserQuestion should roll the session up to ask"

# ── An ordinary tool call is still just working ──────────────────────
run_hook PreToolUse "%1" '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
assert_eq "working" "$(pane_status %1)" "a normal tool call should mark the pane working"

# ── A permission prompt is a block, not a completion ─────────────────
run_hook Notification "%1" '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}'
assert_eq "ask" "$(pane_status %1)" "a permission_prompt notification should mark the pane ask, not done"

# ── An explicit matcher argument wins over payload sniffing ──────────
run_hook PreToolUse "%1" '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
run_hook Notification "%1" '{"hook_event_name":"Notification"}' "permission_prompt"
assert_eq "ask" "$(pane_status %1)" "an explicit permission_prompt matcher should mark the pane ask"

# ── An idle ping must not downgrade a blocked pane ───────────────────
run_hook Notification "%1" '{"hook_event_name":"Notification","message":"Claude is waiting for your input"}' "idle_prompt"
assert_eq "ask" "$(pane_status %1)" "an idle notification must not overwrite ask with done"

# ── An idle ping on a working pane still means done ──────────────────
run_hook PreToolUse "%2" '{"hook_event_name":"PreToolUse","tool_name":"Read"}'
run_hook Notification "%2" '{"hook_event_name":"Notification","message":"Claude is waiting for your input"}' "idle_prompt"
assert_eq "done" "$(pane_status %2)" "an idle notification on a working pane should mark it done"

# ── Session rollup prefers the blocked pane over the finished one ────
assert_eq "ask" "$(sess_status)" "a session with one ask pane and one done pane should report ask"

# ── Stop still finishes the turn ─────────────────────────────────────
run_hook Stop "%1" '{"hook_event_name":"Stop"}'
assert_eq "done" "$(pane_status %1)" "Stop should mark the pane done"

echo "claude hook ask status regression checks passed"
