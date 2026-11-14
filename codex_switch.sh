#!/bin/bash
# ============================================================================
#  Codex Switcher —— 切换 Codex 上游，但 provider id 永不变（会话不分桶）
#
#  用法:  ./codex_switch.sh <provider-id> [选项]
#    --dry-run      只显示将要做的改动，不写入任何文件
#    --no-history   跳过会话历史标签统一（默认会做，保证侧边栏看得到全部会话）
#    --restart      切换后自动退出并重新启动 Codex 桌面端
#    --no-verify    跳过切换后的真实请求验证（切换本身仍是毫秒级）
#    --verify-cli   用 Codex 自带 CLI 做验证（更接近真实会话，但启动慢 30–90 秒）
#    --no-ccswitch  不把状态同步进 cc-switch（若装了的话）
#    --legacy-ids   用「官方=openai / 中继=custom」的双 id 方案（会产生分桶，仅兼容旧用法）
#    magpie         启用 Magpie 本地网关（仍固定使用 main，不改变会话分桶）
#
#  provider-id 来自 ~/.codex-switcher/providers.json
#
#  核心设计
#    * config.toml 里的 model_provider 永远是同一个 id（providers.json 的
#      "providerId"，默认 "main"），切换只改 [model_providers.<id>] 的
#      base_url / experimental_bearer_token。Codex 按 provider id 分桶列出历史，
#      id 固定 ⇒ 会话永远在同一个列表里，也不会因为切换而"消失"。
#    * requires_openai_auth = true 让 Codex 保留 ChatGPT 登录态：
#        官方通道：base_url 指向 chatgpt.com/backend-api/codex，不带 token
#        中继通道：base_url 指向中继，带 experimental_bearer_token
#      （此写法与 yetone/magpie issue #994 讨论的「绑定 OAuth」一致）
#    * provider 段常驻 + 自修复：即使别的工具把配置改坏
#      （model_provider 指向一个不存在的段 → Codex 报 Model provider not found），
#      本脚本每次运行都会把段写回去。
#
#  切换流程（简化后只有 3 步，正常 2–5 秒）
#    1) 检查 + 备份   —— 只备份 config/auth；state 库只在真要迁移历史时才备份
#    2) 应用          —— 只写缺的：token 快过期才刷新、config 有差异才写、
#                        历史标签不一致才迁移、cc-switch 已同步就不动
#    3) 验证 + 重启   —— 真发一次请求；--restart 时重启桌面端
#    已经处于目标通道时直接秒退（不备份 / 不写 / 不验证 / 不重启）。
# ============================================================================
set -uo pipefail

ROOT="${CODEX_SWITCHER_HOME:-$HOME/.codex-switcher}"
PROV_JSON="$ROOT/providers.json"
CFG="${CODEX_HOME:-$HOME/.codex}/config.toml"
CODEX_DIR="$(dirname "$CFG")"
AUTH="$CODEX_DIR/auth.json"
STATE_DB="$CODEX_DIR/state_5.sqlite"
SESSIONS_DIR="$CODEX_DIR/sessions"
ARCHIVED_DIR="$CODEX_DIR/archived_sessions"
OFFICIAL_AUTH="$ROOT/auth/official.json"
CCSW_DB="$HOME/.cc-switch/cc-switch.db"
CCSW_SETTINGS="$HOME/.cc-switch/settings.json"
CHATGPT_APP="${CODEX_APP:-/Applications/ChatGPT.app}"
CODEX_CLI="$CHATGPT_APP/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
CLIENT_ID="app_EMoamEEZ73f0CkXaXp7hrann"
MAGPIE_BIN="${MAGPIE_BIN:-$HOME/.local/bin/magpie}"
MAGPIE_ADDR="${MAGPIE_ADDR:-127.0.0.1:3425}"
MAGPIE_BASE="http://${MAGPIE_ADDR}/v1"
MAGPIE_KEY="${MAGPIE_KEY:-magpie}"
MAGPIE_PID_FILE="$ROOT/magpie.pid"
MAGPIE_LOG="$ROOT/logs/magpie-gateway.log"
MAGPIE_CATALOG="$ROOT/magpie-models.json"
MAGPIE_CONFIG_DIR="${MAGPIE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/magpie}"
MAGPIE_BACKUP_CONFIG=""

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "用法: $(basename "$0") <provider-id|magpie> [--dry-run] [--no-history] [--restart] [--no-verify] [--verify-cli] [--no-ccswitch] [--legacy-ids]"
  echo "可用通道见 $PROV_JSON"
  exit 64
fi
shift
DRY=0; HISTORY=1; RESTART=0; VERIFY=1; CCSW=1; LEGACY=0; VERIFY_CLI=0
for a in "$@"; do
  case "$a" in
    --dry-run)     DRY=1 ;;
    --no-history)  HISTORY=0 ;;
    --restart)     RESTART=1 ;;
    --no-verify)   VERIFY=0 ;;
    --no-ccswitch) CCSW=0 ;;
    --legacy-ids)  LEGACY=1 ;;
    --verify-cli)  VERIFY_CLI=1 ;;
    *) echo "未知选项: $a"; exit 64 ;;
  esac
done

TS=$(date +%Y%m%d_%H%M%S)
mkdir -p "$ROOT/logs" "$ROOT/backups" "$ROOT/auth"
LOG="$ROOT/logs/$TS-$TARGET.log"
T0=$(date +%s)
TMP_FILES=""
trap '[ -n "$TMP_FILES" ] && rm -f $TMP_FILES' EXIT
if [ "${CODEX_SWITCHER_NO_TEE:-0}" = "1" ]; then
  :  # 测试/受限环境：不接管 stdout，日志文件留空
else
  exec > >(tee -a "$LOG") 2>&1
fi

step() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
warn() { printf '  ⚠️  %s\n' "$*"; }
err()  { printf '  ❌ %s\n' "$*"; }
skip() { printf '  ⏭  %s\n' "$*"; }
mask() { sed -E 's/(sk-[A-Za-z0-9]{6})[A-Za-z0-9]+/\1***/g'; }
tildify() { printf '%s' "${1/#$HOME/~}"; }
elapsed() { echo $(( $(date +%s) - T0 )); }
now_hm() { date '+%Y-%m-%d %H:%M'; }

# ── Magpie 回滚 ─────────────────────────────────────────────────────────────
if [ "$TARGET" = "magpie-off" ]; then
  latest=$(find "$ROOT/backups" -type f -name 'config.toml.before' -path '*-magpie/*' 2>/dev/null | sort | tail -1)
  [ -n "$latest" ] || { err "找不到 Magpie 模式备份，无法自动回滚"; exit 75; }
  latest_dir=$(dirname "$latest")
  if [ "$DRY" = "1" ]; then
    skip "试运行：会恢复 $(tildify "$latest")"
  else
    expected_file="$latest_dir/config.toml.after.sha256"
    current_hash=$(shasum -a 256 "$CFG" 2>/dev/null | awk '{print $1}')
    expected_hash=$(cat "$expected_file" 2>/dev/null || true)
    if [ -n "$expected_hash" ] && [ "$current_hash" = "$expected_hash" ]; then
      cp "$latest" "$CFG"
      ok "已恢复 Magpie 之前的 config.toml"
    elif [ -n "$expected_hash" ]; then
      if ! BEFORE="$latest" CURRENT="$CFG" python3 - <<'PY'
import json, os, re, tomllib
before = os.environ['BEFORE']; current = os.environ['CURRENT']
old = open(before).read(); cur = open(current).read()
old_doc = tomllib.loads(old)

def set_kv(text, k, value):
    pat = re.compile(rf'^{re.escape(k)} = .*$', re.M)
    if value is None:
        return pat.sub('', text, count=1)
    line = f'{k} = "{value}"'
    if pat.search(text):
        return pat.sub(line, text, count=1)
    return re.sub(r'^(model_provider = .*)$', rf'\1\n{line}', text, count=1, flags=re.M)

for key in ('model_provider', 'model', 'model_catalog_json'):
    value = old_doc.get(key)
    cur = set_kv(cur, key, value if isinstance(value, str) else None)

old_match = re.search(r'^\[model_providers\.main\]\n(?:[^\[].*\n|\n)*', old, re.M)
cur_match = re.search(r'^\[model_providers\.main\]\n(?:[^\[].*\n|\n)*', cur, re.M)
if not old_match or not cur_match:
    raise SystemExit('备份中没有 [model_providers.main]')
old_block = old_match.group(0)
cur_block = cur_match.group(0)
old_table = old_doc.get('model_providers', {}).get('main', {})
controlled = ('name', 'wire_api', 'request_max_retries', 'stream_max_retries',
              'requires_openai_auth', 'base_url', 'experimental_bearer_token')

def toml_value(value):
    if isinstance(value, bool): return 'true' if value else 'false'
    if isinstance(value, (int, float)): return str(value)
    return json.dumps(value, ensure_ascii=False)

for key in controlled:
    pat = re.compile(rf'^{re.escape(key)} = .*\n', re.M)
    if key in old_table:
        line = f'{key} = {toml_value(old_table[key])}\n'
        if pat.search(cur_block): cur_block = pat.sub(line, cur_block, count=1)
        else: cur_block = cur_block.replace('\n', '\n' + line, 1)
    else:
        cur_block = pat.sub('', cur_block, count=1)

cur = cur[:cur_match.start()] + cur_block + cur[cur_match.end():]
tomllib.loads(cur)
open(current, 'w').write(cur)
PY
      then
        err "配置冲突恢复失败，保留当前 config.toml"
        exit 77
      fi
      ok "检测到配置冲突，仅恢复 Magpie 受控字段，保留其他手动修改"
    else
      err "无法安全回滚：缺少配置指纹，请手动比较 $latest 与当前 config.toml"
      exit 76
    fi
    if [ -f "$MAGPIE_PID_FILE" ]; then
      pid=$(cat "$MAGPIE_PID_FILE" 2>/dev/null || true)
      cmd=$(ps -p "$pid" -o command= 2>/dev/null || true)
      if [ -n "$pid" ] && [[ "$cmd" == *"$MAGPIE_BIN serve"* ]]; then
        kill "$pid" 2>/dev/null || true
        rm -f "$MAGPIE_PID_FILE"
        ok "已停止由 Switcher 启动的 Magpie（pid=$pid）"
      fi
    fi
  fi
  if [ "$RESTART" = "1" ] && [ "$DRY" = "0" ]; then
    osascript - "$CHATGPT_APP" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  tell application (item 1 of argv) to quit
end run
APPLESCRIPT
    open -a "$CHATGPT_APP" >/dev/null 2>&1 || true
    ok "ChatGPT 已请求重启"
  fi
  exit 0
fi

# ── Magpie 网关模式 ────────────────────────────────────────────────────────
# 只管理 Magpie 网关和固定 main Provider；直连模式沿用下面原有流程。
if [ "$TARGET" = "magpie" ]; then
  magpie_health() {
    [ -x "$MAGPIE_BIN" ] || return 1
    "$MAGPIE_BIN" healthcheck --addr "$MAGPIE_ADDR" >/dev/null 2>&1
  }

  magpie_start() {
    if magpie_health; then
      ok "Magpie 网关已运行（${MAGPIE_ADDR}）"
      return 0
    fi
    [ -x "$MAGPIE_BIN" ] || { err "找不到 Magpie：$MAGPIE_BIN"; return 1; }
    if [ "$DRY" = "1" ]; then
      skip "试运行：会启动 Magpie 网关（${MAGPIE_ADDR}）"
      return 0
    fi
    mkdir -p "$(dirname "$MAGPIE_LOG")"
    MAGPIE_ADDR="$MAGPIE_ADDR" nohup "$MAGPIE_BIN" serve >>"$MAGPIE_LOG" 2>&1 &
    local pid=$!
    printf '%s\n' "$pid" >"$MAGPIE_PID_FILE"
    for _ in $(seq 1 60); do
      if magpie_health; then
        ok "Magpie 网关已启动（pid=$pid，$MAGPIE_ADDR）"
        return 0
      fi
      sleep 0.2
    done
    err "Magpie 网关启动失败，请查看 $(tildify "$MAGPIE_LOG")"
    return 1
  }

  magpie_sync() {
    [ "$DRY" = "1" ] && { skip "试运行：会同步 georder/xfastapi 到 Magpie"; return 0; }
    local sync_output
    if ! sync_output=$(PROV_JSON="$PROV_JSON" MAGPIE_BIN="$MAGPIE_BIN" MAGPIE_CONFIG_DIR="$MAGPIE_CONFIG_DIR" python3 - <<'PY'
import json, os, subprocess, sys

prov = json.load(open(os.environ['PROV_JSON']))
magpie = os.environ['MAGPIE_BIN']
saved = {}
saved_path = os.path.join(os.environ['MAGPIE_CONFIG_DIR'], 'providers.json')
try:
    saved = {x.get('id'): x for x in json.load(open(saved_path)).get('providers', [])}
except (FileNotFoundError, json.JSONDecodeError):
    pass
for pid in ('georder', 'xfastapi'):
    p = next((x for x in prov.get('providers', []) if x.get('id') == pid), None)
    if not p or not p.get('baseUrl') or not p.get('apiKey'):
        print(f'{pid}: providers.json 缺少 baseUrl/apiKey', file=sys.stderr)
        raise SystemExit(1)
    if pid in saved:
        result = subprocess.run([magpie, 'provider', 'key', pid, p['apiKey']],
                                text=True, capture_output=True, timeout=45)
        if result.returncode == 0 and saved[pid].get('chat', '') != p['baseUrl']:
            result = subprocess.run([magpie, 'provider', 'set', pid, 'url=' + p['baseUrl']],
                                    text=True, capture_output=True, timeout=45)
        if result.returncode == 0:
            result = subprocess.run([magpie, 'provider', 'models', pid, 'gpt-6-astra'],
                                    text=True, capture_output=True, timeout=45)
    else:
        args = [magpie, 'provider', 'add', pid,
                'url=' + p['baseUrl'], 'key=' + p['apiKey'],
                'models=gpt-6-astra']
        result = subprocess.run(args, text=True, capture_output=True, timeout=45)
    if result.returncode:
        print((result.stdout + result.stderr).replace(p['apiKey'], '<redacted>'), file=sys.stderr)
        raise SystemExit(result.returncode)
    print(pid)
PY
    ); then
      err "georder/xfastapi 同步失败，保留原有 Magpie 配置"
      return 1
    fi
    printf '%s\n' "$sync_output"
    ok "georder/xfastapi 已同步到 Magpie"
  }

  magpie_route() {
    if [ "$DRY" = "1" ]; then
      skip "试运行：会确保 group/codex-astra 与 model-map 映射"
      return 0
    fi
    if ! "$MAGPIE_BIN" group set codex-astra \
      models=codex/gpt-6-astra,georder/gpt-6-astra,xfastapi/gpt-6-astra \
      routing=order stays=session >/dev/null 2>&1; then
      if ! "$MAGPIE_BIN" group add "Codex Astra" \
        models=codex/gpt-6-astra,georder/gpt-6-astra,xfastapi/gpt-6-astra \
        routing=order stays=session >/dev/null 2>&1; then
        err "无法创建或更新 group/codex-astra"
        return 1
      fi
    fi
    local route
    route=$("$MAGPIE_BIN" group codex-astra 2>/dev/null) || {
      err "无法读取 group/codex-astra"
      return 1
    }
    ROUTE="$route" python3 - <<'PY'
import os, re
s = os.environ['ROUTE']
expected = ['codex/gpt-6-astra', 'georder/gpt-6-astra', 'xfastapi/gpt-6-astra']
if not re.search(r'routing\s+order', s):
    raise SystemExit('routing 不是 order')
pos = [s.find(x) for x in expected]
if any(x < 0 for x in pos) or pos != sorted(pos):
    raise SystemExit('路由成员或顺序不匹配')
PY
    if [ "$?" -ne 0 ]; then
      err "group/codex-astra 成员或顺序校验失败"
      return 1
    fi
    local plugin_json
    plugin_json=$("$MAGPIE_BIN" plugin list --json 2>/dev/null) || {
      err "无法读取 Magpie 插件状态"
      return 1
    }
    plugin_state=$(PLUGIN_JSON="$plugin_json" python3 - <<'PY'
import json, os
d = json.loads(os.environ['PLUGIN_JSON'])
specs = [x.get('spec', '') for x in d.get('plugins', [])]
loaded = d.get('middleware', {})
print('installed' if any('middleware-model-map' in x or 'model-map' in x for x in specs) else 'missing')
print('enabled' if any('model-map' in x for x in loaded) else 'disabled')
PY
)
    if [[ "$plugin_state" == *missing* ]]; then
      "$MAGPIE_BIN" plugin add @magpie-community/middleware-model-map >/dev/null 2>&1 || {
        err "无法安装 Magpie model-map 插件"; return 1;
      }
    elif [[ "$plugin_state" == *disabled* ]]; then
      "$MAGPIE_BIN" plugin on model-map >/dev/null 2>&1 || {
        err "无法启用 Magpie model-map 插件"; return 1;
      }
    fi
    local plugin_options
    plugin_options=$(PLUGIN_JSON="$plugin_json" python3 - <<'PY'
import json, os
d = json.loads(os.environ['PLUGIN_JSON'])
opts = {}
for p in d.get('plugins', []):
    if 'model-map' in p.get('spec', ''):
        opts = p.get('options') or {}
        break
mapping = opts.get('mapping') if isinstance(opts.get('mapping'), dict) else {
    k: v for k, v in opts.items() if k != 'keep_upstream_name'
}
mapping = dict(mapping)
mapping['gpt-6-astra'] = 'group/codex-astra'
opts['mapping'] = mapping
print(json.dumps(opts, ensure_ascii=False, separators=(',', ':')))
PY
    ) || {
      err "无法合并 Model Map 原有配置"
      return 1
    }
    if [ "$DRY" = "0" ] && [ -f "$MAGPIE_CONFIG_DIR/plugins.json" ]; then
      local plugin_backup="$ROOT/backups/$TS-magpie/plugins.json.before"
      mkdir -p "$(dirname "$plugin_backup")"
      cp "$MAGPIE_CONFIG_DIR/plugins.json" "$plugin_backup" || {
        err "无法备份 Model Map 原有配置"
        return 1
      }
    fi
    "$MAGPIE_BIN" plugin options model-map "$plugin_options" >/dev/null 2>&1 || {
        err "无法配置 Magpie model-map 插件"; return 1;
      }
    ok "路由组已固定：main → georder → xfastapi（gpt-6-astra）"
  }

  magpie_catalog() {
    if [ "$DRY" = "1" ]; then
      skip "试运行：会生成只包含 gpt-6-astra 的 Codex 模型目录"
      return 0
    fi
    if ! CODEX_DIR="$CODEX_DIR" OUT="$MAGPIE_CATALOG" python3 - <<'PY'
import json, os, pathlib, tempfile
cache = pathlib.Path(os.environ['CODEX_DIR']) / 'models_cache.json'
if not cache.exists():
    raise SystemExit(f'找不到 Codex 模型缓存：{cache}')
data = json.loads(cache.read_text())
models = [m for m in data.get('models', []) if m.get('slug') == 'gpt-6-astra']
if len(models) != 1:
    raise SystemExit('Codex 模型缓存中没有唯一的 gpt-6-astra')
out = pathlib.Path(os.environ['OUT'])
out.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix='.magpie-models-', dir=str(out.parent))
try:
    with os.fdopen(fd, 'w') as f:
        json.dump({'models': models}, f, ensure_ascii=False, separators=(',', ':'))
        f.write('\n')
    os.chmod(tmp, 0o600)
    os.replace(tmp, out)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
PY
    then
      err "生成 Codex 模型目录失败，保留原有目录"
      return 1
    fi
    [ -s "$MAGPIE_CATALOG" ] || {
      err "生成的 Codex 模型目录为空"
      return 1
    }
    ok "Codex 模型目录已限制为 gpt-6-astra"
  }

  magpie_config() {
    [ -f "$CFG" ] || { err "找不到 $CFG"; return 1; }
    local desired
    desired=$(mktemp)
    TMP_FILES="$TMP_FILES $desired"
    if ! CFG="$CFG" OUT="$desired" BASE="$MAGPIE_BASE" KEY="$MAGPIE_KEY" CATALOG="$MAGPIE_CATALOG" \
      python3 - <<'PY'
import os, re, tomllib

cfg = os.environ['CFG']; out = os.environ['OUT']
base = os.environ['BASE']; key = os.environ['KEY']
catalog = os.environ['CATALOG']
t = open(cfg).read()

def set_kv(text, k, v):
    pat = re.compile(rf'^{re.escape(k)} = .*$', re.M)
    if pat.search(text):
        return pat.sub(f'{k} = "{v}"', text, count=1)
    return re.sub(r'^(model_provider = .*)$', rf'\1\n{k} = "{v}"', text, count=1, flags=re.M)

t = set_kv(t, 'model_provider', 'main')
t = set_kv(t, 'model', 'gpt-6-astra')
t = set_kv(t, 'model_catalog_json', catalog)
t = re.sub(r'^\[model_providers\.main\]\n(?:[^\[].*\n|\n)*', '', t, flags=re.M)
t = t.rstrip('\n') + '\n\n[model_providers.main]\n' + '\n'.join([
    'name = "main"',
    'wire_api = "responses"',
    'request_max_retries = 10',
    'stream_max_retries = 10',
    'requires_openai_auth = true',
    f'base_url = "{base}"',
    f'experimental_bearer_token = "{key}"',
]) + '\n'
tomllib.loads(t)
open(out, 'w').write(t)
PY
    then
      err "生成 Magpie config.toml 失败，保留原始配置"
      return 1
    fi
    if ! CONFIG_FILE="$desired" python3 - <<'PY'
import os, tomllib
path = os.environ['CONFIG_FILE']
if not os.path.getsize(path):
    raise SystemExit('临时配置为空')
data = tomllib.load(open(path, 'rb'))
if data.get('model_provider') != 'main':
    raise SystemExit('model_provider 不是 main')
if data.get('model_providers', {}).get('main', {}).get('base_url') != 'http://127.0.0.1:3425/v1':
    raise SystemExit('main Provider base_url 不正确')
PY
    then
      err "生成的 Magpie config.toml 未通过解析或约束校验"
      return 1
    fi
    if cmp -s "$CFG" "$desired"; then
      ok "Codex 已经指向 Magpie（main / gpt-6-astra）"
      return 0
    fi
    if [ "$DRY" = "1" ]; then
      skip "试运行：会更新 [model_providers.main] 指向 Magpie"
      return 0
    fi
    local bk="$ROOT/backups/$TS-magpie"
    mkdir -p "$bk"
    cp "$CFG" "$bk/config.toml.before" || {
      err "无法备份原始 config.toml"
      return 1
    }
    [ -f "$AUTH" ] && cp "$AUTH" "$bk/auth.json.before"
    cp "$desired" "$CFG" || {
      err "写入 config.toml 失败"
      return 1
    }
    shasum -a 256 "$CFG" | awk '{print $1}' >"$bk/config.toml.after.sha256"
    MAGPIE_BACKUP_CONFIG="$bk/config.toml.before"
    ok "config.toml 已更新（main → Magpie · gpt-6-astra）"
  }

  magpie_verify() {
    [ "$VERIFY" = "1" ] || { skip "按参数跳过 Magpie 请求验证"; return 0; }
    [ "$DRY" = "1" ] && { skip "试运行：会发送一条 gpt-6-astra 最小请求"; return 0; }
    local result
    if ! result=$(MAGPIE_BASE="$MAGPIE_BASE" MAGPIE_KEY="$MAGPIE_KEY" python3 - <<'PY'
import json, os, urllib.request
base = os.environ['MAGPIE_BASE'].rstrip('/')
body = {'model':'gpt-6-astra','input':'Reply with exactly MAGPIE_OK.','store':False,'max_output_tokens':16}
req = urllib.request.Request(base + '/responses', data=json.dumps(body).encode(),
    headers={'Authorization':'Bearer ' + os.environ['MAGPIE_KEY'], 'Content-Type':'application/json'})
with urllib.request.urlopen(req, timeout=60) as r:
    data = json.loads(r.read().decode())
text = ''.join(x.get('text','') for o in data.get('output',[]) for x in o.get('content',[]))
if 'MAGPIE_OK' not in text:
    raise SystemExit('响应未包含 MAGPIE_OK')
print('MAGPIE_OK')
PY
    ); then
      err "Magpie Responses 验证失败"
      if [ -n "$MAGPIE_BACKUP_CONFIG" ] && [ -f "$MAGPIE_BACKUP_CONFIG" ]; then
        cp "$MAGPIE_BACKUP_CONFIG" "$CFG"
        warn "已回滚本次 Magpie 配置修改"
      fi
      return 1
    fi
    printf '%s\n' "$result"
    ok "Magpie Responses 验证成功"
  }

  step "Magpie 模式：检查并启动网关"
  magpie_start || exit 70
  step "同步上游和路由组"
  magpie_sync || exit 71
  magpie_route || exit 72
  magpie_catalog || exit 73
  step "固定 main Provider 指向 Magpie"
  magpie_config || exit 74
  step "验证"
  magpie_verify || exit 75
  if [ "$RESTART" = "1" ] && [ "$DRY" = "0" ]; then
    osascript - "$CHATGPT_APP" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  tell application (item 1 of argv) to quit
end run
APPLESCRIPT
    open -a "$CHATGPT_APP" >/dev/null 2>&1 || true
    ok "ChatGPT 已请求重启"
  fi
  echo "═══════════════════════════════════════════════"
  echo " ✅ Magpie 模式完成（main / gpt-6-astra，网关 ${MAGPIE_ADDR}，用时 $(elapsed)s）"
  exit 0
fi

# ── 0) 供应商定义 ──────────────────────────────────────────────────────────
if [ ! -f "$PROV_JSON" ]; then
  err "找不到 $PROV_JSON"
  err "复制 providers.example.json 为 providers.json 并填写你的通道后再试"
  exit 65
fi

DEF=$(python3 - "$PROV_JSON" "$TARGET" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
pid = d.get('providerId', 'main')
obase = d.get('officialBaseUrl', 'https://chatgpt.com/backend-api/codex')
proxy = d.get('proxy', '')
for p in d.get('providers', []):
    if p.get('id') == sys.argv[2]:
        print('\x1f'.join([p.get('name',''), p.get('mode',''), p.get('model',''),
                           p.get('effort','high'), p.get('baseUrl',''),
                           p.get('wireApi','responses'), p.get('apiKey',''),
                           p.get('authFile',''), pid, obase, proxy]))
        break
else:
    sys.exit(3)
PY
)
if [ $? -ne 0 ] || [ -z "$DEF" ]; then
  err "providers.json 里没有 id 为 '$TARGET' 的通道"
  python3 -c "
import json
d=json.load(open('$PROV_JSON'))
print('  可用:', ', '.join(p['id'] for p in d.get('providers',[])))" 2>/dev/null
  exit 65
fi
IFS=$'\x1f' read -r P_NAME P_MODE P_MODEL P_EFFORT P_BASE P_WIRE P_KEY P_AUTHFILE FIXED_ID OFFICIAL_BASE PROXY_CFG <<<"$DEF"
[ -z "$P_AUTHFILE" ] && P_AUTHFILE="$OFFICIAL_AUTH"
P_AUTHFILE="${P_AUTHFILE/#\~/$HOME}"
PROXY="${CODEX_SWITCH_PROXY:-${PROXY_CFG:-http://127.0.0.1:7897}}"

if [ "$LEGACY" = "1" ]; then
  if [ "$P_MODE" = "chatgpt" ]; then PROVIDER_ID="openai"; else PROVIDER_ID="custom"; fi
else
  PROVIDER_ID="$FIXED_ID"
fi

if [ "$P_MODE" = "chatgpt" ]; then
  HEAD_BACKEND="官方后端 $OFFICIAL_BASE"
else
  HEAD_BACKEND="中继 $P_BASE"
fi

echo "═══════════════════════════════════════════════"
echo " Codex 切换 -> $P_NAME    $(date '+%Y-%m-%d %H:%M:%S')"
echo " provider=$PROVIDER_ID$([ "$LEGACY" = "0" ] && echo '（固定 → 会话不分桶）') · $P_MODEL / $P_EFFORT · $HEAD_BACKEND"
[ "$DRY" = "1" ] && echo " 模式: 试运行（不写入任何文件）"
[ "$LEGACY" = "1" ] && echo " 模式: 旧双 id（会产生分桶）"
echo "═══════════════════════════════════════════════"

# ── 1) 检查当前状态（含破损检测）───────────────────────────────────────────
step "1/3 检查 & 备份"
[ -f "$CFG" ] || { err "找不到 $CFG"; exit 66; }
PARSE=$(python3 - "$CFG" <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib
p = sys.argv[1]
try:
    c = tomllib.load(open(p, 'rb'))
except Exception as e:
    print(f"PARSE_FAIL\t{e}"); raise SystemExit
mp = c.get('model_provider', '(未设置)')
defined = list((c.get('model_providers') or {}).keys())
broken = (mp not in ('openai', '(未设置)')) and (mp not in defined)
print(f"OK\t{mp}\t{','.join(defined) if defined else '(无)'}\t{'BROKEN' if broken else 'FINE'}")
PY
) || { err "config.toml 解析失败：请检查上方 Python/TOML 错误"; exit 66; }
if [[ "$PARSE" != OK$'\t'* ]]; then
  err "config.toml 解析失败：${PARSE#*$'\t'}"
  exit 66
fi
IFS=$'\t' read -r _ CUR_PROVIDER CUR_DEFINED CUR_HEALTH <<<"$PARSE"
CUR_MODE=$(python3 -c "
import json
try: print(json.load(open('$AUTH')).get('auth_mode','?'))
except Exception: print('?')")
CUR_TOTAL=$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM threads;" 2>/dev/null)
ok "config.toml 可解析 · 当前 provider=$CUR_PROVIDER / auth=$CUR_MODE · 会话 ${CUR_TOTAL:-0} 条"
if [ "$CUR_HEALTH" = "BROKEN" ]; then
  warn "破损状态：model_provider = \"$CUR_PROVIDER\" 但没有 [model_providers.$CUR_PROVIDER] 段"
  warn "（这正是 Codex 报 'Model provider not found' 的原因）→ 本次切换会修好它"
fi

HAS_CHATGPT=0
[ -f "$P_AUTHFILE" ] && HAS_CHATGPT=1
[ "$CUR_MODE" = "chatgpt" ] && HAS_CHATGPT=1

# 登录态计划：选「快照 / 当前 auth.json」里 token 更新的那个；只有快过期才刷新
AUTH_PLAN=$(python3 - "$AUTH" "$P_AUTHFILE" "$P_MODE" <<'PY'
import json, base64, sys, time
auth_p, snap_p, mode = sys.argv[1], sys.argv[2], sys.argv[3]

def load(p):
    try:
        return json.load(open(p))
    except Exception:
        return None

def exp_of(a):
    try:
        t = a['tokens']['access_token']
        seg = t.split('.')[1]
        seg += '=' * (-len(seg) % 4)
        return int(json.loads(base64.urlsafe_b64decode(seg)).get('exp', 0))
    except Exception:
        return 0

cur, snap = load(auth_p), load(snap_p)
cur_exp, snap_exp = exp_of(cur or {}), exp_of(snap or {})

if mode == 'chatgpt' and not snap:
    print('ERROR\t缺少登录态快照'); raise SystemExit
if mode == 'chatgpt':
    chosen = 'current' if cur_exp >= snap_exp else 'snapshot'
    chosen_exp = max(cur_exp, snap_exp)
    # access token 还剩 1 天以上就直接用；否则刷新（刷新会顺带轮换 refresh token）
    need_refresh = 0 if (chosen_exp and chosen_exp - time.time() > 86400) else 1
else:
    chosen = 'none'
    chosen_exp = cur_exp
    need_refresh = 0
days = round((chosen_exp - time.time()) / 86400, 1) if chosen_exp else 0
print(f'OK\t{chosen}\t{chosen_exp}\t{need_refresh}\t{days}')
PY
)
if [[ "$AUTH_PLAN" == ERROR* ]]; then
  err "找不到 ChatGPT 登录态快照 $P_AUTHFILE"
  err "请先在 Codex 桌面端用官方账号登录一次，再运行本脚本切换（脚本会自动留存快照）"
  exit 67
fi
IFS=$'\t' read -r _ AUTH_CHOICE TOKEN_EXP NEED_REFRESH TOKEN_DAYS _ <<<"$AUTH_PLAN"
if [ "$P_MODE" = "chatgpt" ]; then
  if [ "$AUTH_CHOICE" = "current" ]; then CHOSEN_AUTH="$AUTH"; else CHOSEN_AUTH="$P_AUTHFILE"; fi
else
  CHOSEN_AUTH=""
fi

# 会话历史标签：只查一次，用来决定「要不要备份 state 库 / 要不要迁移」
HIST_NEEDS=0
HIST_DIFF=0
if [ "$HISTORY" = "1" ] && [ -f "$STATE_DB" ]; then
  HIST_DIFF=$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM threads WHERE model_provider<>'$PROVIDER_ID';" 2>/dev/null)
  [ -n "$HIST_DIFF" ] && [ "$HIST_DIFF" -gt 0 ] 2>/dev/null && HIST_NEEDS=1
fi

# 生成期望的 config.toml（写到临时文件，先比较，再决定是否落盘）
DESIRED=$(mktemp); TMP_FILES="$TMP_FILES $DESIRED"
CFG="$CFG" OUT="$DESIRED" PID_="$PROVIDER_ID" MODE="$P_MODE" MODEL="$P_MODEL" \
EFFORT="$P_EFFORT" BASE="$P_BASE" OBASE="$OFFICIAL_BASE" WIRE="$P_WIRE" KEY="$P_KEY" \
HASCHAT="$HAS_CHATGPT" LEGACY="$LEGACY" CATALOG="$MAGPIE_CATALOG" python3 <<'PY' || { err "config.toml 生成失败"; exit 68; }
import os, re
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

cfg_path, out = os.environ['CFG'], os.environ['OUT']
pid = os.environ['PID_']; mode = os.environ['MODE']
model = os.environ['MODEL']; effort = os.environ['EFFORT']
base = os.environ['BASE']; obase = os.environ['OBASE']
wire = os.environ['WIRE']; key = os.environ['KEY']
has_chat = os.environ['HASCHAT'] == '1'; legacy = os.environ['LEGACY'] == '1'

t = open(cfg_path).read()
catalog = os.environ.get('CATALOG', '')

def set_kv(text, k, v):
    pat = re.compile(rf'^{re.escape(k)} = .*$', re.M)
    if pat.search(text):
        return pat.sub(f'{k} = "{v}"', text, count=1)
    return re.sub(r'^(model_provider = .*)$', rf'\1\n{k} = "{v}"', text, count=1, flags=re.M)

# 新版 Codex 已不识别该键（会被忽略并在每次运行时告警）
t = re.sub(r'^disable_response_storage = .*\n', '', t, flags=re.M)

# Magpie owns only its own catalog; direct mode removes that catalog reference
# while preserving any user-managed model_catalog_json path.
if catalog:
    t = re.sub(rf'^model_catalog_json = "{re.escape(catalog)}"\n', '', t, flags=re.M)

t = set_kv(t, 'model_provider', pid)
t = set_kv(t, 'model', model)
t = set_kv(t, 'model_reasoning_effort', effort)

# 只重写 model_providers 段，其余内容与注释原样保留
t = re.sub(r'^\[model_providers\.[^\]]+\]\n(?:[^\[].*\n|\n)*', '', t, flags=re.M)

if not (legacy and mode == 'chatgpt'):
    fields = [f'name = "{pid}"', f'wire_api = "{wire}"']
    # 失败自动重试次数统一设为 10（Codex 默认：stream_max_retries=5，request_max_retries=4）
    fields.append('request_max_retries = 10')
    fields.append('stream_max_retries = 10')
    fields.append(f'requires_openai_auth = {"true" if has_chat else "false"}')
    if mode == 'chatgpt':
        fields.append(f'base_url = "{obase}"')
    else:
        fields.append(f'base_url = "{base}"')
        fields.append(f'experimental_bearer_token = "{key}"')
    t = t.rstrip('\n') + '\n\n[model_providers.' + pid + ']\n' + '\n'.join(fields) + '\n'

open(out, 'w').write(t)
c = tomllib.load(open(out, 'rb'))
assert c['model_provider'] == pid, 'model_provider 未生效'
assert c['model'] == model, 'model 未生效'
if not (legacy and mode == 'chatgpt'):
    sec = c['model_providers'][pid]
    assert sec['wire_api'] == wire
    if mode == 'chatgpt':
        assert sec['base_url'] == obase and 'experimental_bearer_token' not in sec
    else:
        assert sec['base_url'] == base and sec['experimental_bearer_token'] == key
PY

SAME_CFG=0
cmp -s "$CFG" "$DESIRED" && SAME_CFG=1

# 已经在目标通道？→ 秒退（不备份、不写、不验证、不重启）
NOOP=0
if [ "$SAME_CFG" = "1" ] && [ "$HIST_NEEDS" = "0" ] && [ "$NEED_REFRESH" = "0" ]; then
  if [ "$P_MODE" = "chatgpt" ] && [ "$AUTH_CHOICE" = "current" ]; then NOOP=1; fi
  if [ "$P_MODE" != "chatgpt" ] && [ "$CUR_MODE" = "chatgpt" ]; then NOOP=1; fi
fi

if [ "$NOOP" = "1" ]; then
  if [ "$DRY" = "1" ]; then
    skip "试运行：已处于目标通道，无改动"
    echo "═══════════════════════════════════════════════"
    echo " 试运行结束（未写入任何文件）"
    exit 0
  fi
  ok "已是「${P_NAME}」，无需切换"
  echo "═══════════════════════════════════════════════"
  echo " ✅ 无需切换（用时 $(elapsed)s）"
  exit 0
fi

# 备份：config + auth 永远备；20MB 的 state 库只在真要迁移标签时才备
BK="$ROOT/backups/$TS-$TARGET"
if [ "$DRY" = "1" ]; then
  skip "试运行：跳过备份（真跑时会备份 config/auth$([ "$HIST_NEEDS" = "1" ] && echo ' + state 库')）"
else
  mkdir -p "$BK"
  cp "$CFG" "$BK/config.toml.before" 2>/dev/null
  cp "$AUTH" "$BK/auth.json.before" 2>/dev/null
  if [ "$HIST_NEEDS" = "1" ]; then
    sqlite3 "$STATE_DB" ".backup '$BK/state_5.sqlite.before'" 2>/dev/null
    ok "已备份 config/auth/state 库 → $(tildify "$BK")"
  else
    ok "已备份 config/auth → $(tildify "$BK")"
  fi
  ls -dt "$ROOT"/backups/*/ 2>/dev/null | tail -n +16 | while IFS= read -r d; do rm -rf "$d"; done
fi

# ── 2) 应用：只写缺的 ─────────────────────────────────────────────────────
step "2/3 应用"

# 2a) 登录态
refresh_auth_json() {
  local rt code out exp body
  out=$(mktemp)
  rt=$(python3 -c "
import json
try: print(json.load(open('$AUTH'))['tokens']['refresh_token'])
except Exception: pass" 2>/dev/null)
  [ -n "$rt" ] || { rm -f "$out"; return 1; }
  body="{\"client_id\":\"$CLIENT_ID\",\"grant_type\":\"refresh_token\",\"refresh_token\":\"$rt\"}"
  code="000"
  # 先走 providers.json 里的代理，再直连
  if [ -n "$PROXY" ]; then
    code=$(curl -sS --connect-timeout 4 -m 20 -x "$PROXY" -o "$out" -w '%{http_code}' \
      -H "Content-Type: application/json" -d "$body" \
      "https://auth.openai.com/oauth/token" 2>/dev/null) || code="000"
  fi
  if [ "$code" != "200" ]; then
    code=$(curl -sS --connect-timeout 4 -m 20 -o "$out" -w '%{http_code}' \
      -H "Content-Type: application/json" -d "$body" \
      "https://auth.openai.com/oauth/token" 2>/dev/null) || code="000"
  fi
  if [ "$code" != "200" ]; then rm -f "$out"; return 1; fi
  exp=$(python3 - "$AUTH" "$out" <<'PY'
import json, sys, os, base64, datetime
auth_p, resp_p = sys.argv[1], sys.argv[2]
r = json.load(open(resp_p))
a = json.load(open(auth_p))
a.setdefault('tokens', {}).update({k: r[k] for k in ('id_token', 'access_token', 'refresh_token') if k in r})
a['last_refresh'] = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
json.dump(a, open(auth_p, 'w'), indent=2)
os.chmod(auth_p, 0o600)
seg = r['access_token'].split('.')[1]
seg += '=' * (-len(seg) % 4)
c = json.loads(base64.urlsafe_b64decode(seg))
print(datetime.datetime.fromtimestamp(c['exp']).strftime('%Y-%m-%d %H:%M'))
PY
)
  rm -f "$out"
  [ -n "$exp" ] || return 1
  printf '%s' "$exp"
}

if [ "$P_MODE" = "chatgpt" ]; then
  if [ "$DRY" = "1" ]; then
    if [ "$NEED_REFRESH" = "1" ]; then
      skip "试运行：会恢复登录态快照并刷新 token"
    else
      skip "试运行：登录态 token 剩余 ${TOKEN_DAYS} 天，无需刷新"
    fi
  else
    if [ "$NEED_REFRESH" = "1" ]; then
      if [ "$CHOSEN_AUTH" != "$AUTH" ]; then cp "$CHOSEN_AUTH" "$AUTH" && chmod 600 "$AUTH"; fi
      if EXP=$(refresh_auth_json); then
        ok "登录态 token 已刷新（到期 ${EXP}）"
        cp "$AUTH" "$P_AUTHFILE" 2>/dev/null
      else
        warn "token 刷新失败（代理/网络不通）—— 沿用快照里的 token，验证时会给出结论"
        cp "$CHOSEN_AUTH" "$AUTH" 2>/dev/null && chmod 600 "$AUTH"
      fi
    elif [ "$CHOSEN_AUTH" != "$AUTH" ]; then
      if cmp -s "$CHOSEN_AUTH" "$AUTH"; then
        ok "登录态有效（token 剩余 ${TOKEN_DAYS} 天），无需刷新"
      else
        cp "$CHOSEN_AUTH" "$AUTH" && chmod 600 "$AUTH"
        ok "已恢复登录态（token 剩余 ${TOKEN_DAYS} 天）"
      fi
    else
      ok "登录态有效（token 剩余 ${TOKEN_DAYS} 天），无需刷新"
    fi
  fi
else
  if [ "$CUR_MODE" = "chatgpt" ] && [ "$DRY" = "0" ]; then
    if ! cmp -s "$AUTH" "$P_AUTHFILE"; then cp "$AUTH" "$P_AUTHFILE" 2>/dev/null && chmod 600 "$P_AUTHFILE"; fi
  fi
  if [ "$DRY" = "1" ]; then
    skip "试运行：保留 ChatGPT 登录态，auth.json 不动"
  elif [ "$HAS_CHATGPT" = "1" ]; then
    ok "登录态：保留 ChatGPT 登录（模型请求带 bearer token 发往中继）"
  else
    KEY="$P_KEY" python3 - "$AUTH" <<'PY'
import json, os, sys
p = sys.argv[1]
json.dump({'auth_mode': 'apikey', 'OPENAI_API_KEY': os.environ['KEY']}, open(p, 'w'), indent=2)
os.chmod(p, 0o600)
PY
    warn "没有 ChatGPT 登录态 → 退回 apikey 模式（该通道不依赖官方登录）"
  fi
fi

# 2b) config.toml（只有真的不同才写）
if [ "$SAME_CFG" = "1" ]; then
  ok "config.toml 无需改动（已是目标配置）"
elif [ "$DRY" = "1" ]; then
  skip "试运行：会写入 config.toml（$HEAD_BACKEND · $P_MODEL / ${P_EFFORT}）"
else
  cp "$DESIRED" "$CFG" || { err "写入 config.toml 失败"; exit 68; }
  ok "config.toml 已更新（$HEAD_BACKEND · $P_MODEL / ${P_EFFORT}）"
fi

# 2c) 历史标签（不一致才迁移）
HIST_NOTE="历史标签一致（${CUR_TOTAL:-0} 条）"
if [ "$HISTORY" = "0" ]; then
  HIST_NOTE="历史标签已按参数跳过"
elif [ "$HIST_NEEDS" = "1" ]; then
  if [ "$DRY" = "1" ]; then
    HIST_NOTE="会迁移 $HIST_DIFF 条历史标签"
  else
    echo "  ↻ 迁移 $HIST_DIFF 条历史标签…"
    sqlite3 "$STATE_DB" "UPDATE threads SET model_provider='$PROVIDER_ID' WHERE model_provider<>'$PROVIDER_ID';" \
      || { err "threads 迁移失败"; exit 69; }
    for FROM in openai custom magpie; do
      [ "$FROM" = "$PROVIDER_ID" ] && continue
      find "$SESSIONS_DIR" "$ARCHIVED_DIR" -name '*.jsonl' -print0 2>/dev/null \
        | xargs -0 perl -pi -e "s/\"model_provider\":\"$FROM\"/\"model_provider\":\"$PROVIDER_ID\"/g; s/\"model_provider_id\":\"$FROM\"/\"model_provider_id\":\"$PROVIDER_ID\"/g"
    done
    # 兜底：历史目录里可能存在非 .jsonl 的遗留文件（例如 ….jsonl_副本）
    grep -rlE '"model_provider":"(openai|custom|magpie)"' "$SESSIONS_DIR" "$ARCHIVED_DIR" 2>/dev/null \
      | while IFS= read -r f; do
          perl -pi -e "s/\"model_provider\":\"(openai|custom|magpie)\"/\"model_provider\":\"$PROVIDER_ID\"/g; s/\"model_provider_id\":\"(openai|custom|magpie)\"/\"model_provider_id\":\"$PROVIDER_ID\"/g" "$f"
        done
    LEFT=$(grep -rhoE '"model_provider":"(openai|custom|magpie)"' "$SESSIONS_DIR" "$ARCHIVED_DIR" 2>/dev/null | wc -l | tr -d ' ')
    [ "${LEFT:-0}" = "0" ] || { err "仍有 $LEFT 处残留"; exit 69; }
    HIST_NOTE="历史标签已迁移（$HIST_DIFF 条）"
  fi
fi

# 2d) cc-switch（已同步就不写）
CCSW_NOTE=""
if [ "$CCSW" = "0" ]; then
  CCSW_NOTE=" · cc-switch 已跳过"
elif [ ! -f "$CCSW_DB" ]; then
  CCSW_NOTE=""
elif [ "$DRY" = "1" ]; then
  CCSW_NOTE=" · cc-switch 执行时同步"
else
  if CCSW_OUT=$(CFG="$CFG" AUTH="$AUTH" T="$TARGET" python3 <<'PY'
import json, sqlite3, os, re
target = os.environ['T']
cfg_text = open(os.environ['CFG']).read()
m = re.search(r'^model_provider = "([^"]+)"', cfg_text, re.M)
pid = m.group(1) if m else ''
blk = ''
mm = re.search(rf'^\[model_providers\.{re.escape(pid)}\]\n((?:[^\[]*\n)*)', cfg_text, re.M)
if mm: blk = mm.group(1)
base = (re.search(r'base_url = "([^"]+)"', blk) or [None, ''])[1]

db = sqlite3.connect(os.path.expanduser('~/.cc-switch/cc-switch.db'))
rows = db.execute("SELECT id, name, settings_config FROM providers WHERE app_type='codex'").fetchall()
row_id = None
# 先按 base_url 精确匹配，再按名称包含 target 匹配
for rid, name, sc in rows:
    try: c = json.loads(sc)
    except Exception: continue
    if base and base in (c.get('config') or ''):
        row_id = rid; break
if row_id is None:
    for rid, name, sc in rows:
        if name and (target.lower() in name.lower() or target.lower() == (name or '').lower()):
            row_id = rid; break
if row_id is None:
    raise SystemExit(1)

sp = os.path.expanduser('~/.cc-switch/settings.json')
s = {}
if os.path.exists(sp):
    try: s = json.load(open(sp))
    except Exception: s = {}
already = (s.get('currentProviderCodex') == row_id)
try:
    if not already:
        s['currentProviderCodex'] = row_id
        json.dump(s, open(sp, 'w'), indent=2, ensure_ascii=False)
except Exception:
    pass
db.execute("UPDATE providers SET is_current=0 WHERE app_type='codex'")
db.execute("UPDATE providers SET is_current=1 WHERE app_type='codex' AND id=?", (row_id,))
auth = json.load(open(os.environ['AUTH']))
r = db.execute("SELECT settings_config FROM providers WHERE app_type='codex' AND id=?", (row_id,)).fetchone()
if r:
    c = json.loads(r[0]); c['config'] = cfg_text; c['auth'] = auth
    db.execute("UPDATE providers SET settings_config=? WHERE app_type='codex' AND id=?", (json.dumps(c), row_id))
db.commit()
print('changed' if not already else 'same')
PY
); then
    if [ "$CCSW_OUT" = "same" ]; then CCSW_NOTE=" · cc-switch 已同步"; else CCSW_NOTE=" · cc-switch 已同步"; fi
  else
    CCSW_NOTE=" · ⚠️ cc-switch 同步失败"
  fi
fi

if [[ "$CCSW_NOTE" == *"⚠️"* ]]; then
  ok "$HIST_NOTE"
  warn "cc-switch 同步失败（不影响使用）"
else
  ok "$HIST_NOTE$CCSW_NOTE"
fi

# ── 3) 验证 + 重启 ─────────────────────────────────────────────────────────
step "3/3 验证 & 重启"

# 快速验证：按 Codex 的协议直接发一条最小真实请求。
# 不启动整个 codex CLI —— 后者会先初始化内置 MCP/插件，实测要 30–90 秒。
verify_http() {
  V_MODE="$P_MODE" V_URL="$([ "$P_MODE" = "chatgpt" ] && echo "$OFFICIAL_BASE" || echo "$P_BASE")" \
  V_MODEL="$P_MODEL" V_EFFORT="$P_EFFORT" V_KEY="$P_KEY" \
  V_PROXY="$([ "$P_MODE" = "chatgpt" ] && echo "$PROXY" || echo '')" \
  AUTH="$AUTH" python3 - <<'PY'
import json, os, re, shutil, subprocess, sys, tempfile, time

mode = os.environ['V_MODE']
base = (os.environ.get('V_URL') or '').rstrip('/')
model = os.environ['V_MODEL']
effort = os.environ['V_EFFORT']
key = os.environ.get('V_KEY', '')
proxy = os.environ.get('V_PROXY', '')
auth_path = os.environ['AUTH']
url = base + '/responses'

def snippet(s, n=140):
    s = re.sub(r'\s+', ' ', str(s)).strip()
    return s[:n]

headers = ['Content-Type: application/json']
if mode == 'chatgpt':
    try:
        tok = json.load(open(auth_path))['tokens']
        headers.append('Authorization: Bearer ' + tok['access_token'])
        headers.append('chatgpt-account-id: ' + tok['account_id'])
    except Exception as e:
        print('AUTH|0|登录态读取失败：' + snippet(e)); sys.exit(0)
    headers.append('OpenAI-Beta: responses=experimental')
    headers.append('originator: codex_cli_rs')
else:
    if not key:
        print('FAIL|0|该通道没有 apiKey'); sys.exit(0)
    headers.append('Authorization: Bearer ' + key)

body = {
    'model': model,
    'instructions': 'You are a helpful assistant.',
    'input': [{'type': 'message', 'role': 'user',
               'content': [{'type': 'input_text', 'text': 'Reply with exactly: OK'}]}],
    'stream': True,
    'store': False,
    'reasoning': {'effort': effort, 'summary': 'auto'},
    'include': ['reasoning.encrypted_content'],
}

tmpd = tempfile.mkdtemp(prefix='cs-verify-')
hdr_f, body_f, out_f = (os.path.join(tmpd, n) for n in ('h', 'b', 'o'))
try:
    with open(hdr_f, 'w') as f:
        f.write('\n'.join(headers) + '\n')
    os.chmod(hdr_f, 0o600)
    with open(body_f, 'w') as f:
        json.dump(body, f)
    os.chmod(body_f, 0o600)
    # 代理可能偶发 TLS 卡住：代理/直连交替重试几次，只对"没连上"重试
    candidates = []
    if mode == 'chatgpt' and proxy:
        candidates = [proxy, '', proxy, '']
    else:
        candidates = ['', '']
    t0 = time.time()
    code, err, raw = '000', '', ''
    for px in candidates:
        cmd = ['curl', '-sS', '--connect-timeout', '5', '-m', '20', '-o', out_f, '-w', '%{http_code}']
        if px:
            cmd += ['-x', px]
        cmd += ['-H', '@' + hdr_f, '-X', 'POST', '--data-binary', '@' + body_f, url]
        try:
            p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            code = (p.stdout or '').strip() or '000'
            err = (p.stderr or '').strip()
        except Exception as e:
            code, err = '000', str(e)
        try:
            raw = open(out_f, errors='replace').read()
        except Exception:
            raw = ''
        if code != '000':
            break
    secs = time.time() - t0

    def msg_from(raw):
        m = re.search(r'"message"\s*:\s*"((?:[^"\\]|\\.)*)"', raw or '')
        if m:
            try:
                return json.loads('"' + m.group(1) + '"')
            except Exception:
                return m.group(1)
        return ''

    ok = ('"text":"OK"' in raw) or ('"delta":"OK"' in raw) or ('"output_text":"OK"' in raw)
    if code == '200' and ok:
        print('OK|%.1f|%s' % (secs, model)); sys.exit(0)
    low = (raw or '').lower()
    busy = any(k in low for k in ('daily_limit', 'usage_limit', 'quota', 'at capacity',
                                  'service_unavailable', 'overloaded', 'rate limit'))
    if code == '200':
        m = msg_from(raw) or snippet(raw)
        print(('QUOTA' if busy else 'FAIL') + '|%.1f|%s' % (secs, snippet(m))); sys.exit(0)
    m = msg_from(raw) or err
    if code == '401':
        print('AUTH|%.1f|HTTP 401：%s' % (secs, snippet(m))); sys.exit(0)
    if code == '000':
        print('UNVERIFIED|%.1f|%s' % (secs, snippet(err or '网络/代理不通'))); sys.exit(0)
    print(('QUOTA' if busy else 'FAIL') + '|%.1f|HTTP %s：%s' % (secs, code, snippet(m))); sys.exit(0)
finally:
    shutil.rmtree(tmpd, ignore_errors=True)
PY
}

write_verify_cache() {
  python3 - "$ROOT/verify-cache.json" "$TARGET" "$CFG" "$AUTH" <<'PY'
import hashlib, json, os, sys, time
path, target, cfg, auth = sys.argv[1:5]
try:
    tok = json.load(open(auth))['tokens']['access_token'].encode()
except Exception:
    tok = b''
try:
    fp = hashlib.sha256(open(cfg, 'rb').read() + tok).hexdigest()
    data = {}
    try:
        data = json.load(open(path))
    except Exception:
        pass
    data[target] = {'fp': fp, 'at': time.time(), 'ok': True}
    with open(path, 'w') as f:
        json.dump(data, f)
    os.chmod(path, 0o600)
except Exception:
    pass
PY
}

# 2 分钟内、配置与登录态都没变过，就不重复发请求
cache_hit_seconds() {
  [ -f "$ROOT/verify-cache.json" ] || return 0
  python3 - "$ROOT/verify-cache.json" "$TARGET" "$CFG" "$AUTH" <<'PY'
import hashlib, json, sys, time
path, target, cfg, auth = sys.argv[1:5]
try:
    c = json.load(open(path)).get(target) or {}
    try:
        tok = json.load(open(auth))['tokens']['access_token'].encode()
    except Exception:
        tok = b''
    fp = hashlib.sha256(open(cfg, 'rb').read() + tok).hexdigest()
    age = time.time() - c.get('at', 0)
    if c.get('fp') == fp and c.get('ok') and age < 120:
        print(int(age))
except Exception:
    pass
PY
}

# --verify-cli：原来的方式（codex exec；启动慢）
verify_cli() {
  local out t0 secs
  t0=$(date +%s)
  out=$(cd /tmp && "$CODEX_CLI" exec --ephemeral -s read-only -C /tmp --skip-git-repo-check --json \
        "Reply with exactly: OK" </dev/null 2>&1)
  secs=$(( $(date +%s) - t0 ))
  if echo "$out" | grep -q '"text":"OK"'; then
    ok "真实请求成功（模型回复 OK，${secs}s）—— 该通道当前可用"
    return 0
  elif echo "$out" | grep -qiE 'DAILY_LIMIT|USAGE_LIMIT|quota'; then
    err "上游额度已用尽（DAILY_LIMIT_EXCEEDED）—— 配置已写好，但该通道现在发不出请求"
    warn "可切到另一个通道，或等额度重置"
    return 2
  else
    warn "验证未通过（${secs}s），关键输出："
    echo "$out" | grep -E '"message"|"type":"error"' | tail -2 | mask | sed 's/^/       /'
    return 1
  fi
}

apply_verify_result() {
  local st secs msg
  IFS='|' read -r st secs msg <<<"$1"
  case "$st" in
    OK)
      ok "真实请求成功（模型回复 OK，${secs}s）—— 该通道当前可用"
      write_verify_cache
      return 0 ;;
    QUOTA)
      err "上游额度/容量问题：${msg}"
      warn "配置已写好，但该通道现在发不出正常请求；可换通道或稍后重试"
      return 2 ;;
    AUTH)
      warn "验证失败（登录态可能过期）：${msg}"
      return 3 ;;
    UNVERIFIED)
      warn "验证没发出去（网络/代理不稳），本次不做结论：${msg}"
      return 0 ;;
    *)
      warn "验证未通过（${secs}s）：${msg}"
      return 1 ;;
  esac
}

restart_app() {
  local t0 i bin
  t0=$(date +%s)
  bin="$CHATGPT_APP/Contents/MacOS/$(basename "$CHATGPT_APP" .app)"
  if ! pgrep -f "$bin" >/dev/null 2>&1; then
    if open -a "$CHATGPT_APP" >/dev/null 2>&1; then
      ok "ChatGPT 未在运行，已启动（$(( $(date +%s) - t0 ))s）"
    else
      warn "启动 ChatGPT 失败，请手动打开"
    fi
    return 0
  fi
  # 使用完整路径，避免退出同名的浏览器网页版 ChatGPT。
  osascript - "$CHATGPT_APP" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  tell application (item 1 of argv) to quit
end run
APPLESCRIPT
  i=0
  # 这个 App 优雅退出可能要 10 秒以上；最多等 1.5 秒就强制结束（与旧版 sleep 2 + pkill 等效）
  while pgrep -f "$bin" >/dev/null 2>&1 && [ "$i" -lt 15 ]; do sleep 0.1; i=$((i + 1)); done
  if pgrep -f "$bin" >/dev/null 2>&1; then
    pkill -f "$bin" >/dev/null 2>&1
    i=0
    while pgrep -f "$bin" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
  fi
  # 刚强杀后 LaunchServices 偶尔会短暂拒绝启动，重试几次
  i=0
  local oerr=""
  while [ "$i" -lt 5 ]; do
    oerr=$(open -a "$CHATGPT_APP" 2>&1) && break
    i=$((i + 1))
    sleep 0.4
  done
  if [ "$i" -lt 5 ]; then
    ok "ChatGPT 已重启（$(( $(date +%s) - t0 ))s）"
  else
    warn "已退出但启动失败（${oerr:-未知错误}），请手动打开"
  fi
}

VERIFY_FAILED=0
if [ "$DRY" = "1" ]; then
  skip "试运行：跳过验证与重启"
else
  DO_VERIFY=0
  if [ "$VERIFY" = "0" ]; then
    skip "已跳过验证（--no-verify）"
  elif ! command -v curl >/dev/null 2>&1 && [ "$VERIFY_CLI" != "1" ]; then
    skip "找不到 curl，跳过验证（--verify-cli 可换用 Codex CLI 验证）"
  else
    CACHE_AGE=$(cache_hit_seconds)
    if [ -n "${CACHE_AGE:-}" ]; then
      skip "该通道 ${CACHE_AGE}s 前刚验证通过，跳过重复验证"
    else
      DO_VERIFY=1
    fi
  fi

  # 验证（~几秒）和重启 App（~2 秒）互不依赖 → 并行，省掉重启的等待时间
  RPID=""
  RESTART_TMP=""
  if [ "$RESTART" = "1" ] && [ "$DO_VERIFY" = "1" ] && [ "$VERIFY_CLI" = "0" ]; then
    RESTART_TMP=$(mktemp)
    TMP_FILES="$TMP_FILES $RESTART_TMP"
    restart_app >"$RESTART_TMP" 2>&1 &
    RPID=$!
  fi

  if [ "$DO_VERIFY" = "1" ]; then
    if [ "$VERIFY_CLI" = "1" ]; then
      verify_cli; VRC=$?
      [ "$VRC" = "0" ] || VERIFY_FAILED=1
    else
      VOUT=$(verify_http)
      apply_verify_result "$VOUT"; VRC=$?
      if [ "$VRC" = "3" ] && [ "$P_MODE" = "chatgpt" ]; then
        echo "  ↻ 尝试刷新登录态后重试一次…"
        if EXP=$(refresh_auth_json); then
          ok "登录态 token 已刷新（到期 ${EXP}）"
          cp "$AUTH" "$P_AUTHFILE" 2>/dev/null
          VOUT=$(verify_http)
          apply_verify_result "$VOUT"; VRC=$?
        fi
      fi
      [ "$VRC" = "0" ] || VERIFY_FAILED=1
    fi
  fi

  if [ "$RESTART" = "0" ]; then
    skip "未重启（加 --restart 自动重启，或手动 Cmd+Q 后重开）"
  elif [ -n "$RPID" ]; then
    wait "$RPID" 2>/dev/null
    cat "$RESTART_TMP"
  else
    restart_app
  fi
fi

# ── 摘要 ──────────────────────────────────────────────────────────────────
if [ "$P_MODE" = "chatgpt" ]; then LOGIN_DESC="ChatGPT 官方登录"; else
  if [ "$HAS_CHATGPT" = "1" ]; then LOGIN_DESC="保留 ChatGPT 登录 + 中继 bearer token"; else LOGIN_DESC="apikey"; fi
fi

echo "═══════════════════════════════════════════════"
if [ "$DRY" = "1" ]; then
  echo " 试运行结束（未写入任何文件）"
elif [ "$VERIFY_FAILED" = "1" ]; then
  echo " ✅ 已切换到「${P_NAME}」· 用时 $(elapsed)s（⚠️ 验证未通过，详见上方/日志）"
else
  echo " ✅ 已切换到「${P_NAME}」· 用时 $(elapsed)s"
fi
echo "    登录态: $LOGIN_DESC | 日志: $(tildify "$LOG")"
exit 0
