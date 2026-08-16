#!/usr/bin/env bash

# Regression test for agents-mode row selection.
#
# get_agents_rows used to iterate every pane on the server with no agent
# filter, keeping any pane whose status resolved to a known state. Because
# get_pane_status fell back to the session rollup for panes with no status
# file, two things went wrong at once:
#
#   1. plain shells inherited the session status and appeared as agents
#   2. one busy agent made every unreported sibling pane read "working"
#
# Both are the same defect: session state leaking down into pane state.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"
PANE_DIR="$STATUS_DIR/panes"

mkdir -p "$FAKE_BIN" "$STATUS_DIR" "$PANE_DIR"

# Panes: %1 agent (working, has status file)
#        %2 plain shell, no agent process
#        %3 agent process but never ran a hook (no status file)
cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-panes)
        if [ "${2:-}" = "-a" ]; then
            printf 'work\t%%1\t1\tmain\tclaude\tclaude\t101\n'
            printf 'work\t%%2\t2\tshell\tbash\tnexus\t102\n'
            printf 'work\t%%3\t3\treview\tclaude\tclaude\t103\n'
            exit 0
        fi
        exit 1
        ;;
    show-option)
        exit 0
        ;;
esac

exit 1
EOF
chmod +x "$FAKE_BIN/tmux"

# %1 -> pid 101 runs claude; %2 -> pid 102 runs bash only; %3 -> pid 103 claude.
cat > "$FAKE_BIN/ps" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
  101   1 claude
  102   1 -bash
  103   1 claude
OUT
EOF
chmod +x "$FAKE_BIN/ps"

echo "working" > "$PANE_DIR/work_%1.status"
echo "claude"  > "$PANE_DIR/work_%1.agent"
echo "working" > "$STATUS_DIR/work.status"

rows=$(PATH="$FAKE_BIN:$PATH" HOME="$TEST_HOME" \
    bash "$REPO_DIR/scripts/hook-based-switcher.sh" --rows-agents 2>/dev/null)

fail() { echo "Assertion failed: $1" >&2; echo "--- rows ---" >&2; echo "$rows" >&2; exit 1; }

grep -q 'work:%1' <<<"$rows" || fail "an agent pane with a status file should be listed"
grep -q 'work:%3' <<<"$rows" || fail "an agent pane that predates the hooks should still be listed"

if grep -q 'work:%2' <<<"$rows"; then
    fail "a plain shell with no agent process must not appear in agents mode"
fi

if grep -E 'work:%3.*working' <<<"$rows" >/dev/null; then
    fail "an unreported agent pane must not inherit the session's working status"
fi

grep -E 'work:%3.*idle' <<<"$rows" >/dev/null \
    || fail "an unreported agent pane should render as idle"

grep -E 'work:%1.*working' <<<"$rows" >/dev/null \
    || fail "the genuinely working pane should still read working"

echo "switcher agents-mode pane filter regression checks passed"
