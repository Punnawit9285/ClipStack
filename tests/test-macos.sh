#!/bin/bash
# Integration tests for the macOS binary.
#
# Everything runs against a throwaway data folder (CLIPSTACK_HOME) and a private
# named pasteboard (CLIPSTACK_PASTEBOARD), so your real history, your clipboard
# and an installed watcher are never touched.
#
#   ./tests/test-macos.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Building"
swift build 2>&1 | grep -E "error|warning:" && exit 1
BIN="$ROOT/.build/debug/clipstack"

export CLIPSTACK_HOME="$(mktemp -d -t clipstack-test)"
export CLIPSTACK_PASTEBOARD="com.clipstack.test.$$"
SENTINEL="@@CLIPSTACK@@"
WATCHER=""

cleanup() {
    [ -n "$WATCHER" ] && kill "$WATCHER" 2>/dev/null
    osascript -l JavaScript "$ROOT/tests/pasteboard.js" "$CLIPSTACK_PASTEBOARD" release >/dev/null 2>&1
    rm -rf "$CLIPSTACK_HOME"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }
# eq DESCRIPTION ACTUAL EXPECTED
eq() {
    if [ "$2" == "$3" ]; then ok "$1"; else
        bad "$1"; printf '        expected: %q\n        got:      %q\n' "$3" "$2"; fi
}
# check DESCRIPTION COMMAND...   (passes when the command succeeds)
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
# fails DESCRIPTION COMMAND...   (passes when the command exits non-zero)
fails() { local d=$1; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

cs()   { "$BIN" "$@"; }
pb()   { osascript -l JavaScript "$ROOT/tests/pasteboard.js" "$CLIPSTACK_PASTEBOARD" "$@"; }
top()  { cs list -n 1 --sep; }
json() { python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), ensure_ascii=False))'; }

# The most recently recorded clip, whether or not a pinned one is listed above it.
newest() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["items"][0]["text"])' "$CLIPSTACK_HOME/history.json" 2>/dev/null; }
# Simulate another app copying TEXT, then wait until the watcher has recorded it.
copy_and_wait() {
    pb set "$@" >/dev/null
    for _ in $(seq 50); do [ "$(newest)" == "$1" ] && return 0; sleep 0.1; done
    return 1
}
# Copy something the watcher should ignore, then a marker it must record. Once
# the marker lands, the ignored copy has certainly been seen and skipped.
MARK=0
copy_ignored() {
    pb set "$@" >/dev/null; sleep 0.25
    MARK=$((MARK + 1)); copy_and_wait "marker $MARK"
}
start_watcher() {
    "$BIN" watch 2>>"$CLIPSTACK_HOME/watch.log" &
    WATCHER=$!
    sleep 0.4
}
stop_watcher() { kill "$WATCHER" 2>/dev/null; wait "$WATCHER" 2>/dev/null; WATCHER=""; }
reset() { stop_watcher; rm -f "$CLIPSTACK_HOME"/*.json; rm -rf "$CLIPSTACK_HOME/media"; }
# A field of the newest recorded clip, as JSON (e.g. newest_field media).
newest_field() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["items"][0].get(sys.argv[2]), ensure_ascii=False))' "$CLIPSTACK_HOME/history.json" "$1" 2>/dev/null; }
clip_count() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["items"]))' "$CLIPSTACK_HOME/history.json"; }
media_files() { ls "$CLIPSTACK_HOME/media" 2>/dev/null | wc -l | tr -d ' '; }
# Copy image/video data (TYPE=PATH …) and wait until the newest clip has media.
copy_media() {
    local before; before="$(newest_field media)"
    pb data "$@" >/dev/null
    for _ in $(seq 60); do
        local now; now="$(newest_field media)"
        [ "$now" != "null" ] && [ "$now" != "$before" ] && return 0
        sleep 0.1
    done
    return 1
}
# make_png PATH W H SEED: random pixels, so it doesn't compress and sizes are predictable.
make_png() {
    python3 - "$@" <<'PY'
import random, struct, sys, zlib
path, w, h, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
rnd = random.Random(seed)
raw = b"".join(b"\x00" + rnd.randbytes(w * 3) for _ in range(h))
chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                       + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
PY
}

# ---------------------------------------------------------------------------
echo "==> Empty state"
check "help prints usage"                    sh -c "'$BIN' help | grep -q 'clipstack watch'"
eq    "list on empty history is []"          "$(cs list)" "[]"
eq    "list --pretty on empty history"       "$(cs list --pretty)" "(no clips yet)"
fails "copy with no clips exits non-zero"    cs copy 0
eq    "next with no queue"                   "$(cs next)" "queue empty"
eq    "queue-status with no queue"           "$(cs queue-status)" "no queue"
check "status names the history file"        sh -c "'$BIN' status | grep -q '$CLIPSTACK_HOME/history.json'"

# ---------------------------------------------------------------------------
echo "==> Recording"
echo '{"pollSeconds": 0.1}' > "$CLIPSTACK_HOME/config.json"   # partial config on purpose
start_watcher

check "records a copy"                       copy_and_wait "alpha"
check "records a second copy"                copy_and_wait "beta"
check "records a third copy"                 copy_and_wait "gamma"
eq    "newest first"                         "$(cs list)" '["gamma","beta","alpha"]'
check "records the source app"               python3 -c "
import json; h = json.load(open('$CLIPSTACK_HOME/history.json'))
assert all(c.get('app') for c in h['items'])"
check "re-copying promotes instead of duplicating" copy_and_wait "alpha"
eq    "…so there are still three clips"      "$(cs list)" '["alpha","gamma","beta"]'

check "whitespace-only copy is skipped"      copy_ignored $'   \n\t '
check "ConcealedType (passwords) is skipped" copy_ignored "hunter2" "org.nspasteboard.ConcealedType"
check "TransientType is skipped"             copy_ignored "transient" "org.nspasteboard.TransientType"
check "1Password marker is skipped"          copy_ignored "op-secret" "com.agilebits.onepassword"
fails "…and none of them reached history"    grep -qE 'hunter2|transient|op-secret' "$CLIPSTACK_HOME/history.json"

pb file "/tmp/some folder/report.pdf" >/dev/null
check "file copies are recorded as paths"    sh -c 'for i in $(seq 50); do [ "$('"$BIN"' list -n 1 --sep)" = "/tmp/some folder/report.pdf" ] && exit 0; sleep 0.1; done; exit 1'

UNI="héllo — 日本語 🎉"
check "unicode and emoji are recorded"       copy_and_wait "$UNI"
eq    "…and come back intact"                "$(cs list -n 1 | json)" "[\"$UNI\"]"

MULTI=$'line one\nline two\n\n  indented'
check "multi-line clip is recorded"          copy_and_wait "$MULTI"
eq    "…with its newlines preserved"         "$(cs list -n 1 --sep)" "$MULTI"

# ---------------------------------------------------------------------------
echo "==> Listing and searching"
reset; echo '{"pollSeconds": 0.1}' > "$CLIPSTACK_HOME/config.json"; start_watcher
for c in "Invoice #1042 from Acme" "jane@acme.io" "Jane Ferrer" "+44 7700 900112" "invoice total: £420"; do
    copy_and_wait "$c" || bad "setup copy: $c"
done
eq    "-n limits the list"                   "$(cs list -n 2)" '["invoice total: £420","+44 7700 900112"]'
eq    "--sep joins with the sentinel"        "$(cs list -n 2 --sep)" "invoice total: £420${SENTINEL}+44 7700 900112"
check "--pretty numbers the rows"            sh -c "'$BIN' list --pretty | grep -q '^  2  Jane Ferrer'"
eq    "search is case-insensitive"           "$(cs search INVOICE)" '["invoice total: £420","Invoice #1042 from Acme"]'
eq    "search terms are ANDed"               "$(cs search acme jane)" '["jane@acme.io"]'
eq    "search -n N doesn't search for N"     "$(cs search invoice -n 1)" '["invoice total: £420"]'
eq    "search with no match"                 "$(cs search nothing-like-this --pretty)" "(no matches)"
# The number shown by search must be the number copy/pin/merge accept.
ROW="$(cs search jane --pretty | grep 'acme.io')"
IDX="$(echo "$ROW" | awk '{print $1}')"
eq    "search --pretty shows the real index"  "$IDX" "3"
cs copy "$IDX" 2>/dev/null
eq    "…so copy <that index> copies that clip" "$(pb get)" "jane@acme.io"

# ---------------------------------------------------------------------------
echo "==> Copy, pin, clear"
sleep 0.3   # let the watcher promote the clip copy just put back
nth() { cs list | python3 -c "import json,sys; print(json.load(sys.stdin)[$1])"; }
WANT="$(nth 2)"; cs copy 2 2>/dev/null
eq    "copy puts a clip back on the clipboard" "$(pb get)" "$WANT"
fails "copy rejects an out-of-range index"   cs copy 99
fails "copy rejects a non-number"            cs copy abc

sleep 0.3
PINNED="$(nth 3)"; cs pin 3 2>/dev/null
eq    "pinned clip is hoisted to the top"    "$(top)" "$PINNED"
check "…and marked with *"                   sh -c "'$BIN' list --pretty | grep -q '^  0\* '"
# Regression: the watcher used to overwrite the file with its stale copy.
check "a new copy after pinning…"            copy_and_wait "copied after pin"
check "…keeps the pin (watcher reloads first)" python3 -c "
import json; h = json.load(open('$CLIPSTACK_HOME/history.json'))
assert [c['text'] for c in h['items'] if c['pinned']] == ['''$PINNED''']"

cs clear 2>/dev/null
eq    "clear keeps only pinned clips"        "$(cs list --sep)" "$PINNED"
copy_and_wait "first copy after clear" >/dev/null
eq    "…and a later copy doesn't bring them back" "$(cs list | json)" "[\"$PINNED\", \"first copy after clear\"]"
cs unpin 0 2>/dev/null
check "unpin clears the flag"                python3 -c "
import json; h = json.load(open('$CLIPSTACK_HOME/history.json'))
assert not any(c['pinned'] for c in h['items'])"

# ---------------------------------------------------------------------------
echo "==> Merge"
reset; echo '{"pollSeconds": 0.1}' > "$CLIPSTACK_HOME/config.json"; start_watcher
for c in "Jane Ferrer" "jane@acme.io" "+44 7700 900112"; do copy_and_wait "$c" || bad "setup copy: $c"; done
stop_watcher   # otherwise each merged result is recorded and the indexes shift
# Newest first, so: 0 = phone, 1 = email, 2 = name
cs merge 2 1 0 >/dev/null
eq    "merge joins with new lines, in the order given" "$(pb get)" $'Jane Ferrer\njane@acme.io\n+44 7700 900112'
cs merge 0 2 >/dev/null
eq    "merge honours any order"              "$(pb get)" $'+44 7700 900112\nJane Ferrer'
cs merge 2 1 --join ", " >/dev/null
eq    "--join sets the separator"            "$(pb get)" "Jane Ferrer, jane@acme.io"
cs merge 2 1 --join '\t' >/dev/null
eq    "--join understands \\t"               "$(pb get)" $'Jane Ferrer\tjane@acme.io'
eq    "merge reports how many"               "$(cs merge 2 1)" "copied 2 clips"
fails "merge needs indexes"                  cs merge
fails "merge rejects a bad index"            cs merge 1 99

# ---------------------------------------------------------------------------
echo "==> Queue"
reset; echo '{"pollSeconds": 0.1}' > "$CLIPSTACK_HOME/config.json"; start_watcher
for c in "Jane Ferrer" "jane@acme.io" "+44 7700 900112"; do copy_and_wait "$c" || bad "setup copy: $c"; done
stop_watcher
eq    "queue by index loads the first"       "$(cs queue 2 1 0)" "1/3"
eq    "…onto the clipboard"                  "$(pb get)" "Jane Ferrer"
eq    "queue-status"                         "$(cs queue-status)" "1/3"
eq    "next loads the second"                "$(cs next)" "2/3"
eq    "…onto the clipboard"                  "$(pb get)" "jane@acme.io"
eq    "next loads the third"                 "$(cs next)" "3/3"
eq    "…onto the clipboard"                  "$(pb get)" "+44 7700 900112"
eq    "next past the end says so"            "$(cs next)" "queue empty"
eq    "…and the queue is gone"               "$(cs queue-status)" "no queue"
fails "queue rejects a bad index"            cs queue 0 42

# The Shortcuts path: sentinel-joined text on stdin, clips may contain new lines.
eq    "queue from stdin"                     "$(printf 'one\ntwo lines%sthree\n' "$SENTINEL" | cs queue)" "1/2"
eq    "…keeps new lines inside a clip"       "$(pb get)" $'one\ntwo lines'
cs next >/dev/null
eq    "…and trims the trailing one Shortcuts adds" "$(pb get)" "three"
fails "queue with empty stdin fails"         sh -c "printf '' | '$BIN' queue"

cs queue 0 1 >/dev/null; cs clear 2>/dev/null
eq    "clear also drops the queue"           "$(cs queue-status)" "no queue"

# ---------------------------------------------------------------------------
echo "==> Images, videos and files"
FIX="$(mktemp -d -t clipstack-fixtures)"
make_png "$FIX/red.png" 40 30 1
make_png "$FIX/blue.png" 20 10 2
make_png "$FIX/web.png" 16 16 3
make_png "$FIX/sheet.png" 12 12 4
sips -s format tiff "$FIX/blue.png" --out "$FIX/blue.tiff" >/dev/null
head -c 300000 /dev/urandom > "$FIX/clip.mp4"
mkdir -p "$FIX/files"; head -c 1000 /dev/urandom > "$FIX/files/holiday.mov"; cp "$FIX/red.png" "$FIX/files/photo.png"

reset; echo '{"pollSeconds": 0.1}' > "$CLIPSTACK_HOME/config.json"; start_watcher
check "a copied PNG is recorded"             copy_media "public.png=$FIX/red.png"
check "…labelled with its size"              sh -c "'$BIN' list --pretty -n 1 | grep -q '🖼 Image 40×30'"
RED="$CLIPSTACK_HOME/media/$(newest_field media | python3 -c 'import json,sys; print(json.load(sys.stdin)["file"])')"
check "…stored byte for byte, not re-encoded" cmp -s "$RED" "$FIX/red.png"

check "a TIFF-only image is recorded"        copy_media "public.tiff=$FIX/blue.tiff"
eq    "…and stored as PNG, not bulky TIFF"   "$(newest_field media | python3 -c 'import json,sys; m=json.load(sys.stdin); print(m["type"], m["file"].rsplit(".",1)[1], m["width"], m["height"])')" "public.png png 20 10"

copy_and_wait "some text" >/dev/null
N="$(clip_count)"; F="$(media_files)"
check "copying the same image again…"        copy_media "public.png=$FIX/red.png"
eq    "…promotes it instead of duplicating"  "$(clip_count):$(media_files)" "$N:$F"

check "an image with its web address (browser style)" copy_media "public.png=$FIX/web.png" --text "https://example.com/cat.png"
eq    "…is kept as the image, with the address" "$(cs list -n 1)" '["🖼 Image 16×16 · https://example.com/cat.png"]'
eq    "…which is its text"                   "$(newest_field text)" '"https://example.com/cat.png"'

pb data "public.png=$FIX/sheet.png" --text "42" >/dev/null
for _ in $(seq 30); do [ "$(newest)" == "42" ] && break; sleep 0.1; done
eq    "text with a rendered picture (spreadsheet style) stays text" "$(newest_field media):$(newest)" "null:42"

check "copied video data is recorded"        copy_media "public.mpeg-4=$FIX/clip.mp4"
check "…labelled as a video"                 sh -c "'$BIN' list --pretty -n 1 | grep -q '🎬 Video 300 KB'"
eq    "…and kept as .mp4"                    "$(newest_field media | python3 -c 'import json,sys; print(json.load(sys.stdin)["file"].rsplit(".",1)[1])')" "mp4"

pb file "$FIX/files/holiday.mov" >/dev/null
for _ in $(seq 30); do [ "$(newest)" == "$FIX/files/holiday.mov" ] && break; sleep 0.1; done
check "a video file copied in Finder is recorded by reference" sh -c "'$BIN' list --pretty -n 1 | grep -q '🎬 holiday.mov'"
pb file "$FIX/files/holiday.mov" "$FIX/files/photo.png" >/dev/null
for _ in $(seq 30); do [ "$(newest_field files)" != "null" ] && [ "$(newest_field files | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" == "2" ] && break; sleep 0.1; done
check "several files are one clip"           sh -c "'$BIN' list --pretty -n 1 | grep -q '🗂 2 files: holiday.mov, photo.png'"
eq    "…and nothing was copied into ClipStack" "$(ls "$CLIPSTACK_HOME/media" | grep -c -E 'mov$')" "0"
check "search finds images by 'image'"       sh -c "'$BIN' search image --pretty | grep -q '🖼 Image 40×30'"
check "search finds files by name"           sh -c "'$BIN' search holiday --pretty | grep -q 'holiday.mov'"

stop_watcher   # keep the numbers still while pasting back
idx() { cs list --pretty | grep -F "$1" | head -1 | awk '{print $1}'; }

cs copy "$(idx '🖼 Image 40×30')" 2>/dev/null
check "copy puts the image back"             sh -c "osascript -l JavaScript '$ROOT/tests/pasteboard.js' '$CLIPSTACK_PASTEBOARD' types | grep -q 'public.png'"
pb save public.png "$FIX/out.png" >/dev/null
check "…exactly as it was copied"            cmp -s "$FIX/out.png" "$FIX/red.png"
check "…with TIFF alongside for older apps"  sh -c "osascript -l JavaScript '$ROOT/tests/pasteboard.js' '$CLIPSTACK_PASTEBOARD' types | grep -q 'public.tiff'"
check "…and marked as ClipStack's own paste" sh -c "osascript -l JavaScript '$ROOT/tests/pasteboard.js' '$CLIPSTACK_PASTEBOARD' types | grep -q 'com.clipstack.restored'"

cs copy "$(idx '🖼 Image 16×16')" 2>/dev/null
eq    "an image copied with an address pastes both" "$(pb get)" "https://example.com/cat.png"

cs copy "$(idx '🎬 Video')" 2>/dev/null
TYPES="$(pb types)"
check "copy puts the video back as data…"    sh -c "echo '$TYPES' | grep -q 'public.mpeg-4'"
check "…and as a file apps can take"         sh -c "echo '$TYPES' | grep -q 'public.file-url'"

cs copy "$(idx '🗂 2 files')" 2>/dev/null
eq    "copy puts files back as the files"    "$(pb urls)" "[\"$FIX/files/holiday.mov\",\"$FIX/files/photo.png\"]"

cs merge "$(idx 'some text')" "$(idx '🖼 Image 40×30')" "$(idx '🖼 Image 20×10')" >/dev/null
eq    "merging text and images inlines the pictures (RTFD)" "$(pb attachments)" "2"
check "…and in HTML for browsers"            sh -c "osascript -l JavaScript '$ROOT/tests/pasteboard.js' '$CLIPSTACK_PASTEBOARD' types | grep -q 'public.html'"
eq    "…with the text on its own for plain fields" "$(pb get)" "some text"

cs merge "$(idx '🎬 holiday.mov')" "$(idx '🗂 2 files')" >/dev/null
eq    "merging files pastes all of them"     "$(pb urls)" "[\"$FIX/files/holiday.mov\",\"$FIX/files/holiday.mov\",\"$FIX/files/photo.png\"]"

eq    "queue can hold images"                "$(cs queue "$(idx '🖼 Image 20×10')" "$(idx 'some text')")" "1/2"
check "…the first goes on as an image"       sh -c "osascript -l JavaScript '$ROOT/tests/pasteboard.js' '$CLIPSTACK_PASTEBOARD' types | grep -q 'public.png'"
cs next >/dev/null
eq    "…then the text"                       "$(pb get)" "some text"

# The Shortcuts path: labels in, clips out, even if a copy lands in between.
LABELS="$(cs list --labels | python3 -c "import sys; s=sys.stdin.read().strip().split('@@CLIPSTACK@@'); print('@@CLIPSTACK@@'.join(l for l in s if 'Image 40×30' in l or 'some text' in l))")"
start_watcher; copy_and_wait "copied while the picker was open" >/dev/null; stop_watcher
printf '%s' "$LABELS" | cs merge --labels >/dev/null
eq    "merge --labels finds the clips even after the numbers shift" "$(pb attachments):$(pb get)" "1:some text"
printf '%s' "$LABELS" | cs queue --labels >/dev/null
eq    "queue --labels works the same way"    "$(cs queue-status)" "1/2"

N_MEDIA="$(media_files)"
cs pin "$(idx '🖼 Image 40×30')" 2>/dev/null
cs clear 2>/dev/null
eq    "clear deletes unpinned images and videos, keeps pinned ones" "$(media_files)" "1"
[ -f "$RED" ] && ok "…the pinned one is still there" || bad "…the pinned one is still there"

reset; echo '{"pollSeconds": 0.1, "recordMedia": false}' > "$CLIPSTACK_HOME/config.json"; start_watcher
pb data "public.png=$FIX/red.png" >/dev/null; sleep 0.4; copy_and_wait "after" >/dev/null
eq    "recordMedia: false leaves images out" "$(cs list)" '["after"]'

make_png "$FIX/big.png" 820 820 5        # about 2 MB
reset; echo '{"pollSeconds": 0.1, "maxMediaMB": 1}' > "$CLIPSTACK_HOME/config.json"; start_watcher
pb data "public.png=$FIX/big.png" >/dev/null; sleep 0.6; copy_and_wait "after" >/dev/null
eq    "maxMediaMB skips an oversized image"  "$(cs list):$(media_files)" '["after"]:0'

for i in 1 2 3; do make_png "$FIX/m$i.png" 450 450 $((10 + i)); done   # about 600 KB each
reset; echo '{"pollSeconds": 0.1, "mediaBudgetMB": 1}' > "$CLIPSTACK_HOME/config.json"; start_watcher
for i in 1 2 3; do copy_media "public.png=$FIX/m$i.png" || bad "setup m$i"; done
eq    "the media budget keeps only what fits, newest first" "$(clip_count):$(media_files)" "1:1"

reset; echo '{"pollSeconds": 0.1, "maxItems": 2}' > "$CLIPSTACK_HOME/config.json"; start_watcher
copy_media "public.png=$FIX/red.png" >/dev/null
copy_and_wait "one" >/dev/null; copy_and_wait "two" >/dev/null
eq    "an image pushed out by maxItems has its file deleted" "$(media_files)" "0"

# A big image, then two quick copies while it is still being stored: polling
# must carry on (or the first would be missed) and the order must hold.
make_png "$FIX/huge.png" 4000 4000 9
sips -s format tiff "$FIX/huge.png" --out "$FIX/huge.tiff" >/dev/null
reset; echo '{"pollSeconds": 0.1}' > "$CLIPSTACK_HOME/config.json"; start_watcher
T0=$(python3 -c 'import time; print(time.time())')
pb data "public.tiff=$FIX/huge.tiff" >/dev/null; sleep 0.3
for n in 1 2 3; do pb set "copied during $n" >/dev/null; sleep 0.15; done
for _ in $(seq 150); do [ "$(clip_count 2>/dev/null)" == "4" ] && break; sleep 0.1; done
T1=$(python3 -c 'import time; print(time.time())')
eq    "copies made while a big image is being stored are all caught, in order" \
      "$(cs list)" '["copied during 3","copied during 2","copied during 1","🖼 Image 4000×4000"]'
echo "        (the image: a $(( $(stat -f %z "$FIX/huge.tiff") / 1048576 )) MB TIFF, stored as PNG in the background; all three recorded after $(python3 -c "print(round($T1 - $T0, 2))")s)"
stop_watcher
rm -rf "$FIX"

# ---------------------------------------------------------------------------
echo "==> Config"
reset
echo '{"pollSeconds": 0.1, "maxItems": 3}' > "$CLIPSTACK_HOME/config.json"; start_watcher
copy_and_wait "keep me" >/dev/null; cs pin 0 2>/dev/null
for i in 1 2 3 4 5; do copy_and_wait "clip $i" >/dev/null; done
eq    "maxItems caps history; pinned clips don't count" "$(cs list)" '["keep me","clip 5","clip 4","clip 3"]'

reset
echo '{"pollSeconds": 0.1, "maxChars": 10}' > "$CLIPSTACK_HOME/config.json"; start_watcher
check "maxChars skips oversized copies"      copy_ignored "this is longer than ten characters"
fails "…so it isn't in history"              grep -q "longer than ten" "$CLIPSTACK_HOME/history.json"

reset
FRONT="$(lsappinfo info -only bundleid "$(lsappinfo front)" | sed -E 's/.*="(.*)"/\1/')"
if [ -n "$FRONT" ]; then
    echo "{\"pollSeconds\": 0.1, \"ignoredBundleIDs\": [\"$FRONT\"]}" > "$CLIPSTACK_HOME/config.json"
    start_watcher
    pb set "copied in an ignored app" >/dev/null; sleep 0.6
    eq "ignoredBundleIDs skips copies made in that app ($FRONT)" "$(cs list)" "[]"
    stop_watcher
fi

echo 'not json' > "$CLIPSTACK_HOME/config.json"
check "a broken config.json is reported"     sh -c "'$BIN' list 2>&1 >/dev/null | grep -q 'ignoring'"
eq    "…and the defaults still work"         "$(cs list 2>/dev/null)" "[]"
rm -f "$CLIPSTACK_HOME/config.json"

# ---------------------------------------------------------------------------
echo "==> Shortcuts generator"
GEN="$CLIPSTACK_HOME/gen"; mkdir -p "$GEN"; cp "$ROOT/macos/make-shortcuts.py" "$GEN/"
check "builds three workflows that call the binary" python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('m', '$GEN/make-shortcuts.py'); m = importlib.util.module_from_spec(spec)
import os; os.environ['CLIPSTACK_BIN'] = '/opt/x/clipstack'; spec.loader.exec_module(m)
wfs = m.build(); assert len(wfs) == 3
for name, wf in wfs.items():
    ids = [a['WFWorkflowActionIdentifier'] for a in wf['WFWorkflowActions']]
    scripts = [a['WFWorkflowActionParameters'].get('Script', '') for a in wf['WFWorkflowActions']]
    assert any('/opt/x/clipstack' in s for s in scripts), name
    if 'Multiple' in name:
        chooser = next(a for a in wf['WFWorkflowActions'] if a['WFWorkflowActionIdentifier'].endswith('choosefromlist'))
        assert chooser['WFWorkflowActionParameters']['WFChooseFromListActionSelectMultiple'] is True
        assert scripts[0].endswith('list --labels'), scripts[0]
        assert scripts[-1].endswith(('merge --labels', 'queue --labels')), scripts[-1]
"
if command -v shortcuts >/dev/null; then
    check "signs them"                       sh -c "cd '$GEN' && CLIPSTACK_BIN=/opt/x/clipstack python3 make-shortcuts.py && ls '$GEN'/*.shortcut | wc -l | grep -q 3"
fi

# ---------------------------------------------------------------------------
echo "==> Scripts"
check "install.sh parses"                    bash -n "$ROOT/macos/install.sh"
check "uninstall.sh parses"                  bash -n "$ROOT/macos/uninstall.sh"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
