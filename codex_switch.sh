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

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "用法: $(basename "$0") <provider-id> [--dry-run] [--no-history] [--restart] [--no-verify] [--verify-cli] [--no-ccswitch] [--legacy-ids]"
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
HASCHAT="$HAS_CHATGPT" LEGACY="$LEGACY" python3 <<'PY' || { err "config.toml 生成失败"; exit 68; }
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

def set_kv(text, k, v):
    pat = re.compile(rf'^{re.escape(k)} = .*$', re.M)
    if pat.search(text):
        return pat.sub(f'{k} = "{v}"', text, count=1)
    return re.sub(r'^(model_provider = .*)$', rf'\1\n{k} = "{v}"', text, count=1, flags=re.M)

# 新版 Codex 已不识别该键（会被忽略并在每次运行时告警）
t = re.sub(r'^disable_response_storage = .*\n', '', t, flags=re.M)

t = set_kv(t, 'model_provider', pid)
t = set_kv(t, 'model', model)
t = set_kv(t, 'model_reasoning_effort', effort)

# 只重写 model_providers 段，其余内容与注释原样保留
t = re.sub(r'^\[model_providers\.[^\]]+\]\n(?:[^\[].*\n|\n)*', '', t, flags=re.M)

if not (legacy and mode == 'chatgpt'):
    fields = [f'name = "{pid}"', f'wire_api = "{wire}"']
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
  local t0 i bin appname
  t0=$(date +%s)
  bin="$CHATGPT_APP/Contents/MacOS/$(basename "$CHATGPT_APP" .app)"
  appname=$(basename "$CHATGPT_APP" .app)
  if ! pgrep -f "$bin" >/dev/null 2>&1; then
    if open -a "$CHATGPT_APP" >/dev/null 2>&1; then
      ok "ChatGPT 未在运行，已启动（$(( $(date +%s) - t0 ))s）"
    else
      warn "启动 ChatGPT 失败，请手动打开"
    fi
    return 0
  fi
  osascript -e "tell application \"$appname\" to quit" >/dev/null 2>&1
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
