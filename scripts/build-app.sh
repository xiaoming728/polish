#!/bin/sh
# 构建 build/Polish.app 并签名（有本地证书用证书，否则 ad-hoc）。用法：scripts/build-app.sh [--install]
#   --install  复制到 /Applications（终端集成片段里的 polish-edit 路径随 .app 位置而定）
set -eu
cd "$(dirname "$0")/.."

VERSION=0.0.1
APP=build/Polish.app

swift build -c release --product Polish
BIN=$(swift build -c release --show-bin-path)/Polish

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Polish"
ln -s Polish "$APP/Contents/MacOS/polish-edit" # 按 argv[0] 进入终端编辑器模式

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.polish.app</string>
    <key>CFBundleName</key><string>Polish</string>
    <key>CFBundleDisplayName</key><string>Polish</string>
    <key>CFBundleExecutable</key><string>Polish</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>个人使用</string>
</dict>
</plist>
EOF

# 有本地签名证书（scripts/make-signing-cert.sh）就用它：身份固定，重建后不必重新授予辅助功能 / 输入监控 / 钥匙串
IDENTITY="Polish Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --sign "$IDENTITY" "$APP"
    KIND="本地证书签名"
else
    codesign --force --sign - "$APP"
    KIND="ad-hoc 签名，重建后需重新授权"
fi
codesign --verify --strict --verbose=2 "$APP"
echo "✓ ${APP}（${VERSION}，${KIND}）"

if [ "${1:-}" = "--install" ]; then
    pkill -x Polish 2>/dev/null || true
    rm -rf /Applications/Polish.app
    cp -R "$APP" /Applications/Polish.app
    echo "✓ 已安装到 /Applications/Polish.app"
fi
