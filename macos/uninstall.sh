#!/bin/bash
# Stop the watcher and remove everything except the history file.
set -euo pipefail
LABEL="com.clipstack.watcher"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -f "$HOME/.local/bin/clipstack"
echo "Removed watcher and binary."
echo "History kept at: $HOME/Library/Application Support/ClipStack"
echo "Delete it with: rm -rf \"$HOME/Library/Application Support/ClipStack\""
echo "Shortcuts must be deleted by hand in the Shortcuts app."
