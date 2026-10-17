#!/bin/bash
# Builds MacThrottle.app with the Command Line Tools only (no Xcode needed).
# Output: .build-cli/MacThrottle.app
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MacThrottle"
OUT_DIR=".build-cli"
APP="$OUT_DIR/$APP_NAME.app"
VERSION=$(grep -m1 "MARKETING_VERSION" "$APP_NAME.xcodeproj/project.pbxproj" | sed -E 's/.*= (.*);/\1/')

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc \
    -O \
    -parse-as-library \
    -swift-version 6 \
    -target arm64-apple-macos15.0 \
    -framework IOKit \
    -o "$APP/Contents/MacOS/$APP_NAME" \
    $(find "$APP_NAME" -name "*.swift")

# App icon from the asset catalog PNGs
ICONSET="$OUT_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
cp -R "$APP_NAME/Assets.xcassets/AppIcon.appiconset" "$ICONSET"
rm -f "$ICONSET/Contents.json"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>com.macthrottle.app</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - --entitlements "$APP_NAME/$APP_NAME.entitlements" "$APP"
echo "Built $APP ($VERSION)"
