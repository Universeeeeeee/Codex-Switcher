#!/bin/bash
# 安装 Codex Switcher 到本机：~/.codex-switcher/ + CodexSwitcher.app
#
# 用法:
#   ./install.sh                # 从当前目录安装（会本地编译 App）
#   ./install.sh --release      # 从 GitHub Release 下载脚本/配置/App（无需 swiftc）
#
# 也可以一行装（下载 install.sh 与资源都走 Release）:
#   curl -fsSL https://github.com/Universeeeeeee/Codex-Switcher/releases/latest/download/install.sh | bash -s -- --release
set -euo pipefail

REPO="Universeeeeeee/Codex-Switcher"
REL="https://github.com/$REPO/releases/latest/download"
FROM_RELEASE=0
[ "${1:-}" = "--release" ] && FROM_RELEASE=1

HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo /tmp)"
ROOT="${CODEX_SWITCHER_HOME:-$HOME/.codex-switcher}"
mkdir -p "$ROOT/auth" "$ROOT/logs" "$ROOT/backups"

# 本地没有脚本（例如只下载了 install.sh）时，也走 Release
if [ ! -f "$HERE/codex_switch.sh" ]; then FROM_RELEASE=1; fi

echo "== 1/4 安装切换到 $ROOT =="
if [ "$FROM_RELEASE" = "1" ]; then
  echo "   来源: GitHub Release"
  curl -fsSL "$REL/codex_switch.sh" -o "$ROOT/codex_switch.sh"
  [ -f "$HERE/providers.example.json" ] || curl -fsSL "$REL/providers.example.json" -o /tmp/codex-switcher.providers.example.json
else
  echo "   来源: 当前目录"
  cp "$HERE/codex_switch.sh" "$ROOT/codex_switch.sh"
fi
chmod +x "$ROOT/codex_switch.sh"

echo "== 2/4 生成 providers.json =="
if [ -f "$ROOT/providers.json" ]; then
  echo "   已存在，保留不动（模板: providers.example.json）"
else
  SRC="$HERE/providers.example.json"
  [ -f "$SRC" ] || SRC="/tmp/codex-switcher.providers.example.json"
  curl -fsSL "$REL/providers.example.json" -o "$SRC" 2>/dev/null || true
  cp "$SRC" "$ROOT/providers.json"
  chmod 600 "$ROOT/providers.json"
  echo "   已从模板创建，请编辑 $ROOT/providers.json 填入你的通道与 key"
fi

echo "== 3/4 安装 App =="
if [ -w /Applications ]; then DEST="/Applications/CodexSwitcher.app"; else DEST="$HOME/Applications/CodexSwitcher.app"; fi
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
if [ "$FROM_RELEASE" = "1" ]; then
  TMP=$(mktemp -d)
  if curl -fsSL "$REL/CodexSwitcher.app.zip" -o "$TMP/app.zip" 2>/dev/null && unzip -q "$TMP/app.zip" -d "$TMP"; then
    cp -R "$TMP/CodexSwitcher.app" "$DEST"
    echo "   已从 Release 安装: $DEST"
  else
    echo "   ⚠️ Release 里没有 App 包，跳过（切换脚本仍可使用）"
  fi
  rm -rf "$TMP"
elif command -v swiftc >/dev/null 2>&1; then
  "$HERE/app/build.sh" >/dev/null
  cp -R "$HERE/dist/CodexSwitcher.app" "$DEST"
  echo "   已本地编译并安装: $DEST"
else
  echo "   ⚠️ 未找到 swiftc（需 Xcode Command Line Tools）；可用 ./install.sh --release 直接下载 App"
fi

echo "== 4/4 完成 =="
cat <<TIP

下一步:
  1) 编辑 $ROOT/providers.json（providerId / officialBaseUrl / 各通道 baseUrl、apiKey、model）
  2) 先切到官方通道并在 Codex 桌面端登录一次（脚本会自动留存登录态快照）
  3) 命令行切换:  $ROOT/codex_switch.sh <provider-id> --restart
     或打开 App 点按钮

可选: 想先看会改什么，加 --dry-run
TIP
