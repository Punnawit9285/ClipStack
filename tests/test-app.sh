#!/bin/bash
# Tests the menu bar app's picker. It opens the picker window for a few seconds
# per check (it may take keyboard focus meanwhile), but plays its key presses
# from inside the app, so nothing you type is involved. Uses a throwaway history
# and a private pasteboard, like test-macos.sh.
#
#   ./tests/test-app.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift build 2>&1 | grep -E "error|warning:" && exit 1
BIN="$ROOT/.build/debug/clipstack"

export CLIPSTACK_HOME="$(mktemp -d -t clipstack-apptest)"
export CLIPSTACK_PASTEBOARD="com.clipstack.apptest.$$"
echo '{"pollSeconds": 0.1}' > "$CLIPSTACK_HOME/config.json"
trap 'osascript -l JavaScript "$ROOT/tests/pasteboard.js" "$CLIPSTACK_PASTEBOARD" release >/dev/null 2>&1; rm -rf "$CLIPSTACK_HOME"' EXIT

PASS=0; FAIL=0
eq() { if [ "$2" == "$3" ]; then PASS=$((PASS+1)); echo "  ok    $1"; else FAIL=$((FAIL+1)); echo "  FAIL  $1"; printf '        expected: %q\n        got:      %q\n' "$3" "$2"; fi; }
pb() { osascript -l JavaScript "$ROOT/tests/pasteboard.js" "$CLIPSTACK_PASTEBOARD" "$@"; }

# Runs the app with a picker script (steps separated by ';') and waits for it.
picker() {
    local log="$CLIPSTACK_HOME/app.log" steps
    steps=$(echo "$1" | tr ';' '\n' | wc -l)
    CLIPSTACK_PICKER_SCRIPT="$1" CLIPSTACK_APP=1 CLIPSTACK_NO_SETUP=1 "$BIN" > "$log" 2>&1 &
    local pid=$!
    for _ in $(seq $((steps * 5 + 40))); do grep -q "script: done" "$log" && break; sleep 0.1; done
    sleep 0.3
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}

# History to pick from: four texts and an image.
"$BIN" watch 2>/dev/null & W=$!
for t in "Jane Ferrer" "jane@acme.io" "+44 7700 900112" "Invoice #1042"; do pb set "$t" >/dev/null; sleep 0.3; done
pb data "public.png=$ROOT/demo/icon.png" >/dev/null; sleep 0.6
kill $W; wait $W 2>/dev/null

echo "==> Picker"
picker "type:jane;down;tab;up;tab;return"
eq "ticked clips paste together, in the order ticked" "$(pb get)" $'Jane Ferrer\njane@acme.io'

picker "type:image;tab;esc;type:7700;tab;opt+return"
eq "⌥↩ queues them; the image comes first, as an image" "$(pb types)" '[["public.png","public.tiff","com.clipstack.restored"]]'
eq "…and the rest waits for Paste Next" "$("$BIN" next) $(pb get)" "2/2 +44 7700 900112"

picker "type:invoice;cmd+p;esc;esc"
eq "⌘P pins a clip" "$("$BIN" list --pretty -n 1 | grep -c '^  0\* Invoice #1042')" "1"

N=$("$BIN" list | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
picker "type:7700;cmd+backspace;esc;esc"
eq "⌘⌫ deletes a clip" "$("$BIN" list | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" "$((N - 1))"

SECOND="$("$BIN" list | python3 -c 'import json,sys; print(json.load(sys.stdin)[1])')"
picker "cmd+2"
if [[ "$SECOND" == "🖼"* ]]; then   # an image row pastes as an image
    eq "⌘2 pastes the second row (an image)" "$(pb types | grep -c public.png)" "1"
else
    eq "⌘2 pastes the second row" "$(pb get)" "$SECOND"
fi

picker "type:nothing matches this;return;esc;esc"
eq "↩ with no matches does nothing" "$(grep -c 'copied' "$CLIPSTACK_HOME/app.log")" "0"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
