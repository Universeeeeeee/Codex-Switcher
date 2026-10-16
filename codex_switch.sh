#!/bin/bash
# ============================================================================
#  Codex Switcher —— 切换 Codex 上游，但 provider id 永不变（会话不分桶）
#
#  用法:  ./codex_switch.sh <provider-id> [选项]
#    --dry-run      只显示将要做的改动，不写入任何文件
#    --no-history   跳过会话历史标签统一（默认会做，保证侧边栏看得到全部会话）
#    --restart      切换后自动退出并重新启动 Codex 桌面端
#    --no-verify    跳过切换后的端到端验证
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
# ============================================================================
set -uo pipefail

ROOT="${CODEX_SWITCHER_HOME:-$HOME/.codex-switcher}"
PROV_JSON="$ROOT/providers.json"
CFG="${CODEX_HOME:-$HOME/.codex}/config.toml"
AUTH="$(dirname "$CFG")/auth.json"
STATE_DB="$(dirname "$CFG")/state_5.sqlite"
SESSIONS_DIR="$(dirname "$CFG")/sessions"
ARCHIVED_DIR="$(dirname "$CFG")/archived_sessions"
OFFICIAL_AUTH="$ROOT/auth/official.json"
CCSW_DB="$HOME/.cc-switch/cc-switch.db"
CCSW_SETTINGS="$HOME/.cc-switch/settings.json"
CHATGPT_APP="${CODEX_APP:-/Applications/ChatGPT.app}"
CODEX_CLI="$CHATGPT_APP/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
CLIENT_ID="app_EMoamEEZ73f0CkXaXp7hrann"

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "用法: $(basename "$0") <provider-id> [--dry-run] [--no-history] [--restart] [--no-verify] [--no-ccswitch] [--legacy-ids]"
  echo "可用通道见 $PROV_JSON"
  exit 64
fi
shift
DRY=0; HISTORY=1; RESTART=0; VERIFY=1; CCSW=1; LEGACY=0
for a in "$@"; do
  case "$a" in
    --dry-run)     DRY=1 ;;
    --no-history)  HISTORY=0 ;;
    --restart)     RESTART=1 ;;
    --no-verify)   VERIFY=0 ;;
    --no-ccswitch) CCSW=0 ;;
    --legacy-ids)  LEGACY=1 ;;
    *) echo "未知选项: $a"; exit 64 ;;
  esac
done

TS=$(date +%Y%m%d_%H%M%S)
mkdir -p "$ROOT/logs" "$ROOT/backups" "$ROOT/auth"
LOG="$ROOT/logs/$TS-$TARGET.log"
exec > >(tee -a "$LOG") 2>&1

step() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '  ✅ %s\n' "$*"; }
warn() { printf '  ⚠️  %s\n' "$*"; }
err()  { printf '  ❌ %s\n' "$*"; }
mask() { sed -E 's/(sk-[A-Za-z0-9]{6})[A-Za-z0-9]+/\1***/g'; }

echo "═══════════════════════════════════════════════"
echo " Codex 切换 -> $TARGET    $(date '+%Y-%m-%d %H:%M:%S')"
[ "$DRY" = "1" ] && echo " 模式: 试运行（不写入）"
[ "$LEGACY" = "1" ] && echo " 模式: 旧双 id（会产生分桶）"
echo "═══════════════════════════════════════════════"

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
import json,sys
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

echo "  名称  : $P_NAME"
echo "  模式  : $P_MODE  | 模型: $P_MODEL  | effort: $P_EFFORT"
echo "  provider id: $PROVIDER_ID$([ "$LEGACY" = "0" ] && echo '   (固定 → 会话不分桶)')"
[ "$P_MODE" = "apikey" ] && echo "  地址  : $P_BASE  | key: $(printf '%s' "$P_KEY" | mask)"

# ── 1) 当前状态（含破损检测）───────────────────────────────────────────────
step "1/9 检查当前状态"
[ -f "$CFG" ] || { err "找不到 $CFG"; exit 66; }
PARSE=$(python3 - "$CFG" <<'PY'
import sys, tomllib
try:
    c = tomllib.load(open(sys.argv[1], 'rb'))
except Exception as e:
    print(f"PARSE_FAIL\t{e}"); raise SystemExit
mp = c.get('model_provider', '(未设置)')
defined = list((c.get('model_providers') or {}).keys())
broken = (mp not in ('openai', '(未设置)')) and (mp not in defined)
print(f"OK\t{mp}\t{','.join(defined) if defined else '(无)'}\t{'BROKEN' if broken else 'FINE'}")
PY
)
if [[ "$PARSE" == PARSE_FAIL* ]]; then
  err "config.toml 解析失败：${PARSE#PARSE_FAIL	}"
  exit 66
fi
IFS=$'\t' read -r _ CUR_PROVIDER CUR_DEFINED CUR_HEALTH <<<"$PARSE"
ok "config.toml 可解析"
if [ "$CUR_HEALTH" = "BROKEN" ]; then
  warn "破损状态：model_provider = \"$CUR_PROVIDER\" 但没有 [model_providers.$CUR_PROVIDER] 段"
  warn "（这正是 Codex 报 'Model provider not found' 的原因）→ 本次切换会修好它"
fi
CUR_MODE=$(python3 -c "
import json
try: print(json.load(open('$AUTH')).get('auth_mode','?'))
except Exception: print('?')")
CUR_TOTAL=$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM threads;" 2>/dev/null)
CUR_BUCKET=$(sqlite3 "$STATE_DB" "SELECT model_provider FROM threads GROUP BY model_provider ORDER BY COUNT(*) DESC LIMIT 1;" 2>/dev/null)
echo "  当前: provider=$CUR_PROVIDER | auth=$CUR_MODE | 会话桶=${CUR_BUCKET:-?}（共 ${CUR_TOTAL:-0} 条）"

HAS_CHATGPT=0
[ -f "$P_AUTHFILE" ] && HAS_CHATGPT=1
[ "$CUR_MODE" = "chatgpt" ] && HAS_CHATGPT=1

# ── 2) 备份 ────────────────────────────────────────────────────────────────
step "2/9 备份当前状态"
BK="$ROOT/backups/$TS-$TARGET"
if [ "$DRY" = "0" ]; then
  mkdir -p "$BK"
  cp "$CFG" "$BK/config.toml.before" 2>/dev/null
  cp "$AUTH" "$BK/auth.json.before" 2>/dev/null
  [ -f "$STATE_DB" ] && sqlite3 "$STATE_DB" ".backup '$BK/state_5.sqlite.before'" 2>/dev/null
  ok "已备份到 $BK"
  ls -dt "$ROOT"/backups/*/ 2>/dev/null | tail -n +16 | while read -r d; do rm -rf "$d"; done
else
  ok "(试运行：跳过)"
fi

# ── 3) 登录凭据 ────────────────────────────────────────────────────────────
step "3/9 处理登录凭据"
if [ "$P_MODE" = "chatgpt" ]; then
  [ -f "$P_AUTHFILE" ] || {
    err "找不到 ChatGPT 登录态快照 $P_AUTHFILE"
    err "请先在 Codex 桌面端用官方账号登录一次，再运行本脚本切换（脚本会自动留存快照）"
    exit 67
  }
  ok "使用登录态快照 $P_AUTHFILE"
  if [ "$DRY" = "0" ]; then
    cp "$P_AUTHFILE" "$AUTH" && chmod 600 "$AUTH"
    RT=$(python3 -c "import json;print(json.load(open('$AUTH'))['tokens']['refresh_token'])" 2>/dev/null)
    VERDICT="SKIP"
    if [ -n "$RT" ]; then
      for M in "-x $PROXY" ""; do
        # shellcheck disable=SC2086
        CODE=$(curl -sS -m 30 $M -o /tmp/cs_refresh.json -w '%{http_code}' \
          -H "Content-Type: application/json" \
          -d "{\"client_id\":\"$CLIENT_ID\",\"grant_type\":\"refresh_token\",\"refresh_token\":\"$RT\"}" \
          "https://auth.openai.com/oauth/token" 2>/dev/null) || CODE="000"
        [ "$CODE" = "200" ] && { VERDICT="REFRESHED"; break; }
      done
    fi
    if [ "$VERDICT" = "REFRESHED" ]; then
      python3 - <<'PY'
import json, os, base64, datetime, sys
r = json.load(open('/tmp/cs_refresh.json'))
p = os.path.join(os.environ.get('CODEX_HOME', os.path.expanduser('~/.codex')), 'auth.json')
a = json.load(open(p))
a['tokens'].update({k: r[k] for k in ('id_token','access_token','refresh_token') if k in r})
a['last_refresh'] = datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
json.dump(a, open(p, 'w'), indent=2); os.chmod(p, 0o600)
seg = r['access_token'].split('.')[1]; seg += '=' * (-len(seg) % 4)
c = json.loads(base64.urlsafe_b64decode(seg))
print('  ✅ token 已刷新，到期', datetime.datetime.fromtimestamp(c['exp']).strftime('%Y-%m-%d %H:%M'))
PY
      cp "$AUTH" "$P_AUTHFILE" 2>/dev/null
    else
      warn "token 刷新失败（代理/网络不通），沿用快照里的 token"
    fi
    rm -f /tmp/cs_refresh.json
  else
    ok "(试运行：恢复登录态到 auth.json)"
  fi
else
  if [ "$CUR_MODE" = "chatgpt" ] && [ "$DRY" = "0" ]; then
    cp "$AUTH" "$P_AUTHFILE" && chmod 600 "$P_AUTHFILE"
    ok "已把当前 ChatGPT 登录态存入官方快照（切回官方时用）"
  fi
  if [ "$DRY" = "1" ]; then
    ok "(试运行：保留 ChatGPT 登录态，auth.json 不动)"
  elif [ "$HAS_CHATGPT" = "1" ]; then
    ok "保留 ChatGPT 登录态（模型请求带 bearer token 发往中继，账号身份不变）"
  else
    KEY="$P_KEY" python3 -c "
import json, os
p = os.path.join(os.environ.get('CODEX_HOME', os.path.expanduser('~/.codex')), 'auth.json')
json.dump({'auth_mode':'apikey','OPENAI_API_KEY':os.environ['KEY']}, open(p,'w'), indent=2)
os.chmod(p, 0o600)"
    warn "没有 ChatGPT 登录态 → 退回 apikey 模式（该通道不依赖官方登录）"
  fi
fi

# ── 4) config.toml ─────────────────────────────────────────────────────────
step "4/9 生成 config.toml"
if [ "$DRY" = "1" ]; then CFG_NEW=$(mktemp); else CFG_NEW="$BK/config.toml.new"; fi
CFG="$CFG" OUT="$CFG_NEW" PID_="$PROVIDER_ID" MODE="$P_MODE" MODEL="$P_MODEL" \
EFFORT="$P_EFFORT" BASE="$P_BASE" OBASE="$OFFICIAL_BASE" WIRE="$P_WIRE" KEY="$P_KEY" \
HASCHAT="$HAS_CHATGPT" LEGACY="$LEGACY" python3 <<'PY'
import os, re, tomllib

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
print(f"  provider={pid} | model={model} | effort={effort} | "
      + (f"官方后端 {obase}" if mode == 'chatgpt' else f"中继 {base}")
      + (" | 保留 ChatGPT 登录" if has_chat and mode != 'chatgpt' else ""))
PY
if [ $? -ne 0 ]; then err "config.toml 生成失败"; exit 68; fi

if [ "$DRY" = "0" ]; then
  cp "$CFG_NEW" "$CFG" && ok "config.toml 已更新"
  python3 - "$CFG" "$PROVIDER_ID" <<'PY' || { err "校验失败：provider 段缺失"; exit 68; }
import sys, tomllib
c = tomllib.load(open(sys.argv[1], 'rb'))
mp = c.get('model_provider')
assert mp == sys.argv[2], f'model_provider={mp}'
if mp != 'openai':
    assert mp in (c.get('model_providers') or {}), f'[model_providers.{mp}] 缺失'
PY
  ok "已确认 provider 段存在（不会再出现 'Model provider not found'）"
else
  echo "  ── 试运行生成的 config 顶层 ──"
  awk '/^\[/{exit} NF' "$CFG_NEW" | head -8 | sed 's/^/    /'
  grep -A6 '^\[model_providers\.' "$CFG_NEW" 2>/dev/null | mask | sed 's/^/    /'
  rm -f "$CFG_NEW"
fi

# ── 5) 会话历史标签 ────────────────────────────────────────────────────────
step "5/9 会话历史桶 -> $PROVIDER_ID"
if [ "$HISTORY" = "0" ]; then
  warn "已按参数跳过（侧边栏可能看不到其它桶的会话）"
elif [ "$DRY" = "1" ]; then
  echo "  会把 threads（${CUR_TOTAL:-0} 条）与转录里的 provider 标签统一为 '$PROVIDER_ID'"
elif [ ! -f "$STATE_DB" ]; then
  warn "找不到 ${STATE_DB}，跳过"
else
  DIFF=$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM threads WHERE model_provider<>'$PROVIDER_ID';" 2>/dev/null)
  if [ "$DIFF" = "0" ]; then
    ok "标签已一致（${CUR_TOTAL:-0} 条），无需改写"
  else
    echo "  需要迁移 $DIFF 条会话标签…"
    sqlite3 "$STATE_DB" "UPDATE threads SET model_provider='$PROVIDER_ID' WHERE model_provider<>'$PROVIDER_ID';" \
      && ok "threads 已迁移" || { err "threads 迁移失败"; exit 69; }
    for FROM in openai custom magpie; do
      [ "$FROM" = "$PROVIDER_ID" ] && continue
      find "$SESSIONS_DIR" "$ARCHIVED_DIR" -name '*.jsonl' -print0 2>/dev/null \
        | xargs -0 perl -pi -e "s/\"model_provider\":\"$FROM\"/\"model_provider\":\"$PROVIDER_ID\"/g; s/\"model_provider_id\":\"$FROM\"/\"model_provider_id\":\"$PROVIDER_ID\"/g"
    done
    # 兜底：历史目录里可能存在非 .jsonl 的遗留文件（例如 ….jsonl_副本）
    grep -rlE '"model_provider":"(openai|custom|magpie)"' "$SESSIONS_DIR" "$ARCHIVED_DIR" 2>/dev/null \
      | while IFS= read -r f; do
          perl -pi -e "s/\"model_provider\":\"(openai|custom|magpie)\"/\"model_provider\":\"$PROVIDER_ID\"/g; s/\"model_provider_id\":\"(openai|custom|magpie)\"/\"model_provider_id\":\"$PROVIDER_ID\"/g" "$f"
          echo "    兜底改写: $(basename "$f")"
        done
    LEFT=$(grep -rhoE '"model_provider":"(openai|custom|magpie)"' "$SESSIONS_DIR" "$ARCHIVED_DIR" 2>/dev/null | wc -l | tr -d ' ')
    [ "$LEFT" = "0" ] && ok "转录标签已迁移（0 残留）" || { err "仍有 $LEFT 处残留"; exit 69; }
  fi
fi

# ── 6) cc-switch 同步（可选、尽力而为）─────────────────────────────────────
step "6/9 同步 cc-switch 状态"
if [ "$CCSW" = "0" ]; then
  warn "已按参数跳过"
elif [ ! -f "$CCSW_DB" ]; then
  warn "未安装 cc-switch，跳过"
elif [ "$DRY" = "1" ]; then
  echo "  会把 cc-switch 中对应通道设为当前"
else
  CFG="$CFG" AUTH="$AUTH" T="$TARGET" python3 <<'PY' 2>/dev/null && ok "已同步" || warn "同步失败（不影响使用）"
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
try:
    s = json.load(open(sp)); s['currentProviderCodex'] = row_id
    json.dump(s, open(sp, 'w'), indent=2, ensure_ascii=False)
except Exception: pass
db.execute("UPDATE providers SET is_current=0 WHERE app_type='codex'")
db.execute("UPDATE providers SET is_current=1 WHERE app_type='codex' AND id=?", (row_id,))
auth = json.load(open(os.environ['AUTH']))
r = db.execute("SELECT settings_config FROM providers WHERE app_type='codex' AND id=?", (row_id,)).fetchone()
if r:
    c = json.loads(r[0]); c['config'] = cfg_text; c['auth'] = auth
    db.execute("UPDATE providers SET settings_config=? WHERE app_type='codex' AND id=?", (json.dumps(c), row_id))
db.commit()
print('    cc-switch 行:', row_id)
PY
fi

# ── 7) 端到端验证（真发一次请求）──────────────────────────────────────────
step "7/9 端到端验证"
if [ "$DRY" = "1" ]; then warn "试运行，跳过"
elif [ "$VERIFY" = "0" ]; then warn "已按参数跳过"
elif [ -x "$CODEX_CLI" ]; then
  OUT=$(cd /tmp && "$CODEX_CLI" exec --ephemeral -s read-only -C /tmp --skip-git-repo-check --json \
        "Reply with exactly: OK" 2>&1)
  if echo "$OUT" | grep -q '"text":"OK"'; then
    ok "真实请求成功（模型回复 OK）—— 该通道当前可用"
  elif echo "$OUT" | grep -qiE 'DAILY_LIMIT|USAGE_LIMIT|quota'; then
    err "上游额度已用尽（DAILY_LIMIT_EXCEEDED）—— 配置已写好，但该通道现在发不出请求"
    warn "可切到另一个通道，或等额度重置"
  else
    warn "验证未通过，关键输出："
    echo "$OUT" | grep -E '"message"|"type":"error"' | tail -3 | mask | sed 's/^/     /'
  fi
else
  warn "找不到 Codex CLI（${CODEX_CLI}），跳过端到端验证"
fi

# ── 8) 可选重启 ────────────────────────────────────────────────────────────
if [ "$DRY" = "0" ] && [ "$RESTART" = "1" ]; then
  step "8/9 重启 Codex 桌面端"
  osascript -e 'tell application "ChatGPT" to quit' >/dev/null 2>&1
  sleep 2
  pkill -f "$CHATGPT_APP/Contents/MacOS/ChatGPT" 2>/dev/null
  sleep 1
  open -a "$CHATGPT_APP" 2>/dev/null && ok "已重新启动" || warn "启动失败，请手动打开"
else
  step "8/9 重启应用"
  echo "  跳过（加 --restart 自动重启，或手动 Cmd+Q 后重开）"
fi

# ── 9) 摘要 ────────────────────────────────────────────────────────────────
step "9/9 摘要"
echo "  通道    : $P_NAME"
echo "  provider: $PROVIDER_ID$([ "$LEGACY" = "0" ] && echo '（固定 → 所有通道共用，会话不分桶）')"
echo "  模型    : $P_MODEL / $P_EFFORT"
if [ "$P_MODE" = "chatgpt" ]; then LOGIN_DESC="ChatGPT 官方登录"; else
  if [ "$HAS_CHATGPT" = "1" ]; then LOGIN_DESC="保留 ChatGPT 登录 + 中继 bearer token"; else LOGIN_DESC="apikey"; fi
fi
echo "  登录态  : $LOGIN_DESC"
echo "  日志    : $LOG"
echo "═══════════════════════════════════════════════"
[ "$DRY" = "1" ] && echo " 试运行结束（未写入任何文件）" || echo " ✅ 已切换到: $P_NAME"
exit 0
