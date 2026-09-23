#!/bin/bash
# A self-running tour of ClipStack on macOS.
#
# It runs the real binary against a throwaway history and a private pasteboard,
# so your clipboard, your history and an installed watcher are left alone. The
# "copies" are made by the demo, standing in for you pressing Cmd-C in other apps.
#
#   ./demo/demo.sh             play it
#   ./demo/demo.sh --record    also save demo/transcript.json for render-svg.py
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECORD=""; [ "${1:-}" == "--record" ] && RECORD="$ROOT/demo/transcript.json"
SPEED="${DEMO_SPEED:-1}"   # >1 plays faster

swift build --package-path "$ROOT" 2>&1 | grep -E "error|warning:" && exit 1

SANDBOX="$(mktemp -d -t clipstack-demo)"
export CLIPSTACK_HOME="$SANDBOX/data"
export CLIPSTACK_PASTEBOARD="com.clipstack.demo.$$"
mkdir -p "$SANDBOX/bin" "$CLIPSTACK_HOME" && ln -s "$ROOT/.build/debug/clipstack" "$SANDBOX/bin/clipstack"
export PATH="$SANDBOX/bin:$PATH"
echo '{"pollSeconds": 0.1}' > "$CLIPSTACK_HOME/config.json"

clipstack watch 2>/dev/null &
WATCHER=$!
disown
cleanup() {
    kill "$WATCHER" 2>/dev/null
    osascript -l JavaScript "$ROOT/tests/pasteboard.js" "$CLIPSTACK_PASTEBOARD" release >/dev/null
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

# --- presentation --------------------------------------------------------------

DIM=$'\e[2m'; BOLD=$'\e[1m'; CYAN=$'\e[36m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
EVENTS=()

pause() { sleep "$(echo "$1 / $SPEED" | bc -l)"; }
record() { [ -n "$RECORD" ] && EVENTS+=("$(python3 -c 'import json,sys; print(json.dumps({"kind": sys.argv[1], "text": sys.argv[2]}))' "$1" "$2")"); return 0; }

note() {
    record note "$1"
    printf '%s# %s%s\n' "$DIM" "$1" "$RESET"; pause 1.2
}

# Types a command, runs it for real, shows its output.
run() {
    record cmd "$*"
    printf '%s$%s ' "$GREEN" "$RESET"
    local s="$*"
    for ((i = 0; i < ${#s}; i++)); do printf '%s' "${s:i:1}"; sleep "$(echo "0.035 / $SPEED" | bc -l)"; done
    pause 0.35; printf '\n'
    local output; output="$("$@" 2>&1)"
    record out "$output"
    printf '%s\n' "$output"; pause 1.6
}

# Shows what is on the (demo) clipboard right now.
clipboard() {
    local text; text="$(osascript -l JavaScript "$ROOT/tests/pasteboard.js" "$CLIPSTACK_PASTEBOARD" get)"
    record clip "$text"
    printf '%s┌ clipboard%s\n' "$CYAN" "$RESET"
    while IFS= read -r line; do printf '%s│%s %s\n' "$CYAN" "$RESET" "$line"; done <<< "$text"
    printf '%s└%s\n' "$CYAN" "$RESET"; pause 1.8
}

# Another app copies TEXT; waits until the watcher has recorded it.
copy() {
    local shown="$1"
    osascript -l JavaScript "$ROOT/tests/pasteboard.js" "$CLIPSTACK_PASTEBOARD" set "$@" >/dev/null
    if [ $# -gt 1 ]; then shown="••••••••  (from a password manager)"; sleep 0.4; else
        for _ in $(seq 50); do [ "$(clipstack list -n 1 --sep)" == "$1" ] && break; sleep 0.1; done
    fi
    record copy "$shown"
    printf '  %s⌘C%s  %s\n' "$YELLOW" "$RESET" "$shown"; pause 0.5
}

# --- the tour --------------------------------------------------------------------

printf '%sClipStack%s — clipboard history with multi-clip paste\n\n' "$BOLD" "$RESET"
record title "ClipStack — clipboard history with multi-clip paste"

note "Everything you copy is recorded in the background."
copy "Jane Ferrer"
copy "jane@acme.io"
copy "+44 7700 900112"
copy "Invoice #1042 — Acme Ltd, due 30 Sep"
copy "https://acme.io/orders/1042"
run clipstack list --pretty

note "Merge: pick several clips, paste them once."
run clipstack merge 4 3 2
clipboard

note "Queue: paste them into different fields, one after another."
run clipstack list --pretty -n 6
run clipstack queue 5 4 3
clipboard
run clipstack next
clipboard
run clipstack next
clipboard

note "Search, then copy by the number it shows."
run clipstack search acme --pretty
run clipstack copy "$(clipstack search acme --pretty | awk '/Invoice/ {print $1}')"
clipboard

note "Password managers mark secrets as concealed; those are never recorded."
copy "hunter2" "org.nspasteboard.ConcealedType"
run clipstack search hunter2 --pretty

note "clipstack pick does all of this from a dialog — tick as many as you like."

if [ -n "$RECORD" ]; then
    printf '%s\n' "${EVENTS[@]}" | python3 -c 'import json,sys; json.dump([json.loads(l) for l in sys.stdin], open(sys.argv[1], "w"), ensure_ascii=False, indent=1)' "$RECORD"
    echo "${DIM}recorded $RECORD${RESET}"
fi
