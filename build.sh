#!/bin/zsh
# 构建 release 版并打包成 OpenView.app
set -e
cd "$(dirname "$0")"
swift build -c release
APP=build/OpenView.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OpenView "$APP/Contents/MacOS/OpenView"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # 由 Resources/AppIcon-source.png 生成
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>OpenView</string>
  <key>CFBundleDisplayName</key><string>OpenView</string>
  <key>CFBundleIdentifier</key><string>io.github.openview</string>
  <key>CFBundleExecutable</key><string>OpenView</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force -s - "$APP"
echo "Built $APP"
