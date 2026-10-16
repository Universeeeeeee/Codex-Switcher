#!/bin/bash
# 编译并打包 CodexSwitcher.app
# 用法: ./build.sh [输出目录]   默认 ../dist
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/../dist}"
mkdir -p "$OUT"

echo "== 编译 =="
swiftc -swift-version 5 -parse-as-library -O \
  -framework SwiftUI -framework AppKit \
  -o "$OUT/CodexSwitcher" "$HERE/main.swift"

APP="$OUT/CodexSwitcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT/CodexSwitcher" "$APP/Contents/MacOS/CodexSwitcher"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Codex Switcher</string>
  <key>CFBundleDisplayName</key><string>Codex Switcher</string>
  <key>CFBundleExecutable</key><string>CodexSwitcher</string>
  <key>CFBundleIdentifier</key><string>io.github.codex-switcher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "✅ 已生成 $APP"
