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
BINARY="$SCRIPT_DIR/BlueLightFilter"

echo "🔅 Blue Light Filter"
echo "===================="
echo ""

# Compile if needed
if [ ! -f "$BINARY" ] || [ "$SCRIPT_DIR/BlueLightFilter.swift" -nt "$BINARY" ]; then
    echo "Compiling..."
    swiftc -O \
        -framework Cocoa \
        -framework QuartzCore \
        -o "$BINARY" \
        "$SCRIPT_DIR/BlueLightFilter.swift"
    echo "✓ Compiled successfully"
fi

echo ""
echo "Starting Blue Light Filter..."
echo "  • Look for the 🔅 icon in your menu bar"
echo "  • Use the menu to adjust intensity or switch methods"
echo "  • Press Ctrl+C here or use Quit from the menu to stop"
echo ""

# Run — when it exits, gamma is restored automatically
trap 'echo ""; echo "Display restored. Goodbye!"; exit 0' INT TERM
"$BINARY"
