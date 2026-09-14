#!/bin/zsh
# Builds LookAwayBlur.app (no Xcode project needed) and ad-hoc signs it.
set -e
cd "$(dirname "$0")"
APP=LookAwayBlur.app
mkdir -p $APP/Contents/MacOS
cat > $APP/Contents/Info.plist <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.siva.lookawayblur</string>
<key>CFBundleName</key><string>LookAwayBlur</string>
<key>CFBundleExecutable</key><string>LookAwayBlur</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSMotionUsageDescription</key><string>Reads AirPods head orientation to blur the screen when you look away.</string>
</dict></plist>
PL
# universal binary so Intel Macs work too
swiftc -O -target arm64-apple-macos14.0  -framework Cocoa -framework CoreMotion -framework Carbon LookAwayBlur.swift -o /tmp/lab_arm64
swiftc -O -target x86_64-apple-macos14.0 -framework Cocoa -framework CoreMotion -framework Carbon LookAwayBlur.swift -o /tmp/lab_x86
lipo -create /tmp/lab_arm64 /tmp/lab_x86 -output $APP/Contents/MacOS/LookAwayBlur && rm -f /tmp/lab_arm64 /tmp/lab_x86
SIGN="${SIGN_ID:--}"   # export SIGN_ID="Developer ID Application: ..." for distribution
codesign -s "$SIGN" --force --options runtime --timestamp $APP 2>/dev/null || codesign -s "$SIGN" --force $APP
echo "built $APP (signed as: $SIGN)"
ditto -c -k --keepParent $APP LookAwayBlur.zip && echo "zipped LookAwayBlur.zip"
