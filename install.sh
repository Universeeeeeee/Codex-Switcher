#!/bin/bash
# 安装 Codex Switcher 到本机：~/.codex-switcher/ + CodexSwitcher.app
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${CODEX_SWITCHER_HOME:-$HOME/.codex-switcher}"

echo "== 1/4 安装切换到 $ROOT =="
mkdir -p "$ROOT/auth" "$ROOT/logs" "$ROOT/backups"
cp "$HERE/codex_switch.sh" "$ROOT/codex_switch.sh"
chmod +x "$ROOT/codex_switch.sh"

echo "== 2/4 生成 providers.json =="
if [ -f "$ROOT/providers.json" ]; then
  echo "   已存在，保留不动（模板见 $HERE/providers.example.json）"
else
  cp "$HERE/providers.example.json" "$ROOT/providers.json"
  chmod 600 "$ROOT/providers.json"
  echo "   已从模板创建，请编辑 $ROOT/providers.json 填入你的通道与 key"
fi

echo "== 3/4 编译 App =="
if command -v swiftc >/dev/null 2>&1; then
  "$HERE/app/build.sh" >/dev/null
  APP_SRC="$HERE/dist/CodexSwitcher.app"
  if [ -w /Applications ]; then DEST="/Applications/CodexSwitcher.app"; else DEST="$HOME/Applications/CodexSwitcher.app"; fi
  mkdir -p "$(dirname "$DEST")"
  rm -rf "$DEST"
  cp -R "$APP_SRC" "$DEST"
  echo "   已安装: $DEST"
else
  echo "   ⚠️ 未找到 swiftc（需 Xcode Command Line Tools），跳过 App；切换脚本仍可使用"
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
