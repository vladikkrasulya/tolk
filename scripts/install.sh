#!/bin/bash
# Installs build/Tolk.app into ~/Applications and registers a login LaunchAgent.
# Usage: scripts/install.sh [--no-autostart]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/Tolk.app"
DEST_DIR="/Applications"
DEST="$DEST_DIR/Tolk.app"
LABEL="local.vk.tolk"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -d "$SRC" ] || { echo "No $SRC — run scripts/build-app.sh first." >&2; exit 1; }

# Quit a running copy so the bundle can be replaced.
osascript -e 'tell application id "local.vk.tolk" to quit' >/dev/null 2>&1 || true
pkill -x Tolk 2>/dev/null || true

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
echo "==> installed $DEST"

if [ "${1:-}" != "--no-autostart" ]; then
    mkdir -p "$(dirname "$AGENT")"
    cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>-a</string>
		<string>$DEST</string>
		<string>--args</string>
		<string>--background</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
PLIST
    plutil -lint "$AGENT" >/dev/null
    # Re-register (bootout fails harmlessly if it was not loaded).
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
    echo "==> autostart registered: $AGENT (also starts Tolk now)"
else
    open "$DEST"
fi

echo "Remove autostart: launchctl bootout gui/\$(id -u)/$LABEL && rm $AGENT"
