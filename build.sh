#!/bin/bash
# Builds "Homework Helper.app" in ./build. Run: ./build.sh && open "build/Homework Helper.app"
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Homework Helper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library \
  Sources/*.swift -o "$APP/Contents/MacOS/HomeworkHelper"

# App icon from icon/AppIcon.png (redraw it with: swift icon/make_icon.swift)
SET="build/AppIcon.iconset"
rm -rf "$SET" && mkdir -p "$SET" "$APP/Contents/Resources"
for s in 16 32 128 256 512; do
  sips -z $s $s icon/AppIcon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon/AppIcon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.homeworkbot.app</string>
  <key>CFBundleName</key><string>Homework Helper</string>
  <key>CFBundleExecutable</key><string>HomeworkHelper</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUseContinuityCameraDeviceType</key><true/>
  <key>NSCameraUsageDescription</key><string>The camera looks at your homework on the desk.</string>
  <key>NSMicrophoneUsageDescription</key><string>The microphone hears your questions.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Speech recognition turns your questions into text.</string>
</dict></plist>
EOF

xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $APP"
