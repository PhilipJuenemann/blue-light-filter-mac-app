#!/bin/bash

# Blue Light Filter for macOS
# Compiles and runs a native Swift app that removes blue light from your screen.
#
# Usage:
#   chmod +x run.sh
#   ./run.sh
#
# The app will appear as a 🔅 icon in your menu bar.
# Press Ctrl+C in terminal or use the menu bar to quit (display will restore).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="$SCRIPT_DIR/BlueLightFilter.app"
BINARY="$APP_BUNDLE/Contents/MacOS/BlueLightFilter"

echo "🔅 Blue Light Filter"
echo "===================="
echo ""

# Compile if needed (check source, Info.plist, or missing binary)
if [ ! -f "$BINARY" ] \
   || [ "$SCRIPT_DIR/BlueLightFilter.swift" -nt "$BINARY" ] \
   || [ "$SCRIPT_DIR/Info.plist" -nt "$APP_BUNDLE/Contents/Info.plist" ]; then
    echo "Compiling..."
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
    swiftc -O \
        -framework Cocoa \
        -framework QuartzCore \
        -framework CoreLocation \
        -o "$BINARY" \
        "$SCRIPT_DIR/BlueLightFilter.swift"
    echo "✓ Compiled successfully"
fi

echo ""
echo "Starting Blue Light Filter..."
echo "  • Look for the 🔅 icon in your menu bar"
echo "  • Use the menu to adjust intensity or switch methods"
echo "  • Open Schedule Settings (⌘,) to configure auto schedule"
echo "  • Press Ctrl+C here or use Quit from the menu to stop"
echo ""

# Run — when it exits, gamma is restored automatically
trap 'echo ""; echo "Display restored. Goodbye!"; exit 0' INT TERM
"$BINARY"
