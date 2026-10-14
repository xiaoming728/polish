#!/bin/zsh
# 用法: assemble.sh <pkg 目录> <root|resources>   (组装 .app + ad-hoc 签名)
set -euo pipefail
PKG=$1; MODE=${2:-resources}
swift build -c release --package-path "$PKG" >&2
BIN=$(swift build -c release --package-path "$PKG" --show-bin-path)
APP="$PKG/Demo.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Demo" "$APP/Contents/MacOS/Demo"
if [[ $MODE == root ]]; then DEST="$APP"; else DEST="$APP/Contents/Resources"; fi
cp -R "$BIN/KeyboardShortcuts_KeyboardShortcuts.bundle" "$DEST/"
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.polish.demo</string>
<key>CFBundleName</key><string>Demo</string>
<key>CFBundleExecutable</key><string>Demo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
P
codesign --force --sign - "$APP"
echo "assembled: $APP ($MODE)"
