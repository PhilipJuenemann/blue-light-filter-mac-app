# 🔅 Blue Light Filter for macOS

A lightweight, native Swift app that removes blue light from your Mac screen while keeping everything looking natural and readable.

## How It Works

Unlike macOS Night Shift (which just adds an orange tint), this filter uses **display gamma table manipulation** to surgically remove blue light while compensating with subtle warm adjustments:

- **Red channel**: Slight boost (+8%) to compensate for lost brightness
- **Green channel**: Minimal reduction (-5%) for natural warmth
- **Blue channel**: Fully removed (0% blue light emission)

The result looks like wearing high-quality blue-light-blocking glasses — warm and comfortable, but still with good contrast and readability.

## Quick Start

```bash
cd BlueLightFilter
chmod +x run.sh
./run.sh
```

That's it. The app compiles itself on first run and appears as a **🔅 icon** in your menu bar.

## Menu Bar Controls

| Option | Description |
|--------|-------------|
| **Gamma Method** | Modifies display gamma tables (recommended, looks best) |
| **Overlay Method** | Uses a composited amber overlay window (fallback) |
| **100% (No Blue)** | Complete blue light removal |
| **75%** | Strong filter, slight blue remaining |
| **50%** | Moderate filter |
| **Disable Filter** | Turn off without quitting |
| **Quit** | Restore display and exit |

## Safety

- Display always restores to normal when the app quits (including Ctrl+C, force quit, or crashes)
- Signal handlers ensure gamma tables are reset even on unexpected termination
- The app runs as a menu-bar-only accessory (no Dock icon)

## Packaging as a Mac App

To create a proper `.app` bundle:

```bash
# 1. Compile the binary
swiftc -O -framework Cocoa -framework QuartzCore -o BlueLightFilter BlueLightFilter.swift

# 2. Create app structure
mkdir -p BlueLightFilter.app/Contents/MacOS
mkdir -p BlueLightFilter.app/Contents/Resources

# 3. Copy binary
cp BlueLightFilter BlueLightFilter.app/Contents/MacOS/

# 4. Create Info.plist
cat > BlueLightFilter.app/Contents/Info.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BlueLightFilter</string>
    <key>CFBundleIdentifier</key>
    <string>com.bluelightfilter.app</string>
    <key>CFBundleName</key>
    <string>Blue Light Filter</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Blue Light Filter</string>
</dict>
</plist>
PLIST

# 5. Done! Double-click BlueLightFilter.app to run
open BlueLightFilter.app
```

## Requirements

- macOS 12+ (Monterey or later)
- Xcode Command Line Tools (`xcode-select --install`)

## How It Compares

| Feature | This App | Night Shift | f.lux |
|---------|----------|-------------|-------|
| 100% blue removal | ✅ | ❌ (partial) | ❌ (partial) |
| Natural appearance | ✅ | ⚠️ (orange tint) | ✅ |
| Adjustable intensity | ✅ | ✅ | ✅ |
| No install needed | ✅ | ✅ | ❌ |
| Open source | ✅ | ❌ | ❌ |
| Menu bar control | ✅ | ❌ | ✅ |
