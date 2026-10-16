# 排错

## 1. `Model provider \`X\` not found`

**现象**：Codex 里打开某个会话就报

> ChatGPT 无法加载 config.toml，因此无法继续此聊天。
> 请修复 config.toml 中的问题：Model provider `custom` not found。

**原因**：`config.toml` 里写着 `model_provider = "custom"`，但文件里没有 `[model_providers.custom]` 段。常见于用其他工具切换供应商时只改了一行、没写整段。

**处理**：跑一次本工具任意通道即可（脚本每次运行都会检测并补回该段）：

```bash
~/.codex-switcher/codex_switch.sh <任意通道> --dry-run   # 先看
~/.codex-switcher/codex_switch.sh <任意通道>             # 真修
```

## 2. 切换后"一部分会话不见了"

**原因**：Codex 按 `model_provider` 分桶列出历史，而别的工具切换时只改了 `config.toml` / `auth.json`，没有同步历史标签，于是当前 provider 的桶里只有一部分会话。

**处理**：本工具默认会做（第 5 步）。若你曾用 `--no-history` 跳过，补跑一次即可：

```bash
~/.codex-switcher/codex_switch.sh <通道>     # 第 5 步会统一标签
```

底层做的就是：把 `~/.codex/state_5.sqlite` 的 `threads.model_provider` 与 `~/.codex/sessions/**/*.jsonl` 里的 `"model_provider"` / `"model_provider_id"` 统一成固定 id。

> 注意目录里可能存在 `….jsonl_副本` 这类文件，只按 `*.jsonl` 匹配会漏——脚本会额外兜底扫一遍。

## 3. 验证报 `DAILY_LIMIT_EXCEEDED` / `USAGE_LIMIT_EXCEEDED`

**含义**：配置已经写好，但**这个上游现在发不出请求**（额度用尽，通常来自中继背后的账号池）。

**处理**：切到另一个通道，或等额度重置。想先跳过验证：`--no-verify`。

## 4. 切换后立刻用不了 / 行为没变

Codex 桌面端在**启动时**读取配置和登录态。切换后请重启它：

```bash
~/.codex-switcher/codex_switch.sh <通道> --restart
```

或用 App 里的「切换后自动退出并重启 Codex」勾选框。

## 5. 在 Codex 自带模型选择器里点了模型，然后报模型不支持

本工具按通道在 `providers.json` 里设置 `model`；而在应用里手动点选模型会把这个值改写掉，可能写出当前通道不支持的模型名。

**处理**：别在 Codex 的模型选择器里选具体模型（保持"默认"），需要换模型改 `providers.json` 里该通道的 `model` 后再切一次。

## 6. 中继返回 `404 page not found`

`base_url` 路径不对。两种协议拼接方式不同：

- OpenAI Responses（`wireApi: "responses"`）：客户端会自己拼 `/responses`，所以 `base_url` 写 **根域名或 `…/v1`**，按你的中继试
- Anthropic Messages：客户端会自己拼 `/v1/messages`，`base_url` 要写**不带 `/v1`** 的根地址

反复 404 时，用 curl 直接打两个候选路径确认哪个通：

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST "https://<你的中继>/responses" \
  -H "Authorization: Bearer sk-…" -H 'Content-Type: application/json' \
  -d '{"model":"<模型>","input":"hi","max_output_tokens":8,"store":false}'
```

## 7. 官方通道登录失效

脚本会在切换到官方时尝试刷新 token（先走 `providers.json` 的 `proxy`，再直连）。如果两者都不通：

- 网络能直连 `auth.openai.com` 就不需要代理，可把 `proxy` 留空
- 都不通时会沿用快照里的 token（通常还有效数天）；彻底失效则需在 Codex 里重新登录一次，再切一次（脚本会更新快照）

快照位置：`~/.codex-switcher/auth/official.json`（0600）。

## 8. 想彻底退回旧行为

```bash
~/.codex-switcher/codex_switch.sh <通道> --legacy-ids
```

官方用内置 `openai`、中继用 `custom` —— 会重新分桶，仅在需要与旧工具保持一致时使用。

## 9. 回滚

每次切换前都会备份：

```
~/.codex-switcher/backups/<时间>-<通道>/
    config.toml.before
    auth.json.before
    state_5.sqlite.before
```

把 `config.toml.before` / `auth.json.before` 拷回 `~/.codex/` 即可回滚配置与登录态；历史标签的改动可用 `state_5.sqlite.before` 还原。
