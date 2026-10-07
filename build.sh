#!/bin/sh
# Builds "trackme.app" using the Xcode command line tools (no Xcode project needed).
#
#   ./build.sh            build and launch from ./build
#   ./build.sh install    build, copy to /Applications, launch from there
#   ./build.sh test       run the engine tests
set -e
cd "$(dirname "$0")"

if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "Swift compiler not found. Install the command line tools with: xcode-select --install"
    exit 1
fi

if [ "$1" = "test" ]; then
    exec sh tests/run.sh
fi

APP="build/trackme.app"
LOG="build/build.log"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

{
    echo "macOS $(sw_vers -productVersion) $(uname -m)"
    swiftc --version 2>&1
    echo "---"
} > "$LOG"

echo "Compiling..."
if ! swiftc -swift-version 5 -O -wmo \
        -target "$(uname -m)-apple-macos12.0" \
        -o "$APP/Contents/MacOS/trackme" \
        sources/core/*.swift sources/app/*.swift >> "$LOG" 2>&1; then
    cat "$LOG"
    echo "BUILD FAILED" >> "$LOG"
    echo
    echo "Build failed. The full log is in $LOG"
    exit 1
fi
echo "BUILD OK" >> "$LOG"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>trackme</string>
    <key>CFBundleDisplayName</key><string>trackme</string>
    <key>CFBundleIdentifier</key><string>local.trackme</string>
    <key>CFBundleExecutable</key><string>trackme</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally, nothing is sent anywhere.
codesign --force --sign - "$APP" >> "$LOG" 2>&1 || true

pkill -x trackme 2>/dev/null || true

if [ "$1" = "install" ]; then
    DEST="/Applications/trackme.app"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    APP="$DEST"
fi

open "$APP"
echo "Built and launched: $APP"
echo "Look for the spend figure in the menu bar."
