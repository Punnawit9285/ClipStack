#!/bin/bash
# Build clipstack, install it, and start the background watcher.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/clipstack"
LABEL="com.clipstack.watcher"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs"
LOG="$LOG_DIR/clipstack.log"

echo "==> Building"
cd "$ROOT"
swift build -c release --disable-sandbox

echo "==> Installing to $BIN"
mkdir -p "$BIN_DIR" "$LOG_DIR"
install -m 755 "$ROOT/.build/release/clipstack" "$BIN"

echo "==> Writing launch agent"
mkdir -p "$(dirname "$AGENT")"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN</string>
		<string>watch</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ProcessType</key><string>Background</string>
	<key>StandardOutPath</key><string>$LOG</string>
	<key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

echo "==> Starting watcher"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$AGENT"
launchctl enable "gui/$UID/$LABEL" 2>/dev/null || true

echo "==> Generating shortcuts"
CLIPSTACK_BIN="$BIN" python3 "$ROOT/macos/make-shortcuts.py"

sleep 1
if launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
	echo "==> Watcher is running"
else
	echo "!! Watcher did not start; see $LOG" >&2
fi

cat <<NEXT

Installed. clipstack is at $BIN

Next, so you can reach the history without a terminal:

  1. Double-click each file in $ROOT/macos/
       ClipStack - Paste Multiple.shortcut     <- the main one
       ClipStack - Queue Multiple.shortcut
       ClipStack - Paste Next.shortcut
     and click Add Shortcut.

  2. In Shortcuts, select a shortcut, open the info panel (the (i) on the right),
     and set a keyboard shortcut. Suggested:
       Paste Multiple  Cmd-Shift-V
       Queue Multiple  Cmd-Shift-Q
       Paste Next      Cmd-Shift-N

  3. Shortcuts > Settings > Advanced > tick "Allow Running Scripts".

Try it now:  $BIN list --pretty
Not using Shortcuts?  $BIN pick
NEXT
