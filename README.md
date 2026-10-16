# Codex Switcher

> 在 Codex 里一键切换上游（官方 / 各种中继），**但 provider id 永不变 —— 会话历史永远在同一个列表里。**

[English](README.en.md) · [三条优势](#为什么选它三条) · [与 magpie / cc-switch 对比](#与-magpie--cc-switch-对比) · [安装](#安装)

macOS · 一个 bash 脚本 + 一个 250 KB 的原生小窗口 · 无网关、无常驻服务 · MIT

![Codex Switcher 界面](docs/images/app-window.png)

<sub>每次切换都会逐步骤输出（备份 → 凭据 → 配置 → 历史标签 → 真实请求验证 → 重启）：</sub>

```text
▶ 4/9 生成 config.toml
  provider=main | model=gpt-6-astra | effort=high | 中继 https://<你的中继> | 保留 ChatGPT 登录
  ✅ config.toml 已更新
  ✅ 已确认 provider 段存在（不会再出现 'Model provider not found'）

▶ 5/9 会话历史桶 -> main
  ✅ 标签已一致（647 条），无需改写        ← 固定 id 之后，从第二次起就不用再改写

▶ 7/9 端到端验证
  ✅ 真实请求成功（模型回复 OK）—— 该通道当前可用
```

---

## 为什么选它：三条

1. **分桶问题今天就能解决。** magpie 的方案更完整但还在 issue 阶段；cc-switch 不处理这件事。本项目用「固定 provider id」从源头消除分桶——而且必要时提供**一次性**历史迁移（`threads.model_provider` + 会话文件里的 `model_provider` / `model_provider_id` 一起改，含 `….jsonl_副本` 这类容易漏掉的文件）。
2. **零常驻依赖。** Codex 直接连官方后端或你的中继，中间没有网关、没有守护进程、没有端口。magpie 很强大，但它要求网关常驻——magpie 一退出，Agent 就失去 provider。
3. **切换即自证，坏了会自修。** 每次切换后真的发一条请求（用 Codex 自带的 CLI，`--ephemeral` 不写会话文件），上游额度耗尽会明确报 `DAILY_LIMIT_EXCEEDED` 而不是静默失败；同时每次运行都检查 `model_provider` 指向的 `[model_providers.*]` 表是否存在——这正是 Codex 报 `Model provider not found` 的原因。

## 与 magpie / cc-switch 对比

| | **Codex Switcher**（本项目） | [cc-switch](https://github.com/farion1231/cc-switch) | [magpie](https://github.com/yetone/magpie) |
|---|---|---|---|
| 定位 | 只干一件事：Codex 换上游但历史不分桶 | 多 CLI 的供应商配置切换（GUI） | 所有 Agent 的模型 / 供应商 / 账号统一管理 |
| 界面 | 原生小窗口（3 个按钮） | GUI | 菜单栏 + 窗口 + TUI + CLI |
| **会话历史是否分桶** | ✅ **永不**（provider id 固定） | ❌ 切换后另一个桶的会话看不到¹ | ⚠️ 目前会分成 `openai` / `magpie` 两个桶，#994 已决定实现，**截至 2026-10-16 未发布** |
| 保留 ChatGPT 登录 | ✅ 中继通道也保留（可选退回 apikey） | 可配置保留 | ✅ 明确「不触碰登录」 |
| 切换后是否验证真的可用 | ✅ **每次都真发一次请求**（`codex exec --ephemeral`，不落盘） | ❌ 无 | ⚠️ 有网关侧健康检查，不校验 Codex 端到端 |
| 配置被改坏时自修复 | ✅ 每次运行检测 `model_provider` 指向的表是否存在，缺失即补 | ❌ | ✅ 文档明确会补回 |
| 运行依赖 | **无**（Codex 直连上游） | GUI 应用 | **本地网关常驻** 127.0.0.1:3425，magpie 退出后 Agent 就失去 provider |
| 体量 / 可审计 | ~450 行 bash + ~250 行 Swift，纯文本 | GUI | 大型项目（多语言、插件、路由） |

¹ 我们在 macOS + Codex 桌面端上的实测：用 cc-switch 切换供应商后，Codex 侧的历史桶标签没有跟着变，于是侧边栏只剩下与新 provider 匹配的那一个桶（我们那次是 647 条里只看得到 1 条）。cc-switch 的定位是管理 `config.toml` / `auth.json`，会话标签不在它的职责范围内。

### 什么时候该用别的

- 你要**多 Agent、多账号、额度用尽自动换号**、想让中继模型出现在 Codex 自带模型列表里 → 用 **magpie**，它比本项目强得多。
- 你主要切 Claude Code 的配置 → 用 **cc-switch**。
- 你只关心「Codex 换上游时历史别乱」 → 本项目。

---

## 它解决的问题

Codex（以及 ChatGPT 桌面端里的 Codex）**按 `model_provider` 给历史会话分桶**：用哪个 provider id 聊的，会话就挂在哪个桶里，侧边栏只列当前 provider 的桶。

于是只要你切过上游（官方 ↔ 中继，或者从中继 A 换到中继 B），就会遇到：

- 切过去之后，**原来那边的会话像是"消失"了**（其实还在，只是在另一个桶里）；
- 从别的工具迁过来的历史挂在 `custom`、`main` 之类的旧 id 下，同样看不到；
- 配置被改坏成 `model_provider = "xxx"` 但没有 `[model_providers.xxx]` 段时，Codex 直接**打不开这个会话**：

  > ChatGPT 无法加载 config.toml …… Model provider `custom` not found

## 解决方式

**永远用同一个 provider id，只换它指向哪。**

```toml
model_provider = "main"            # 永远不变（providers.json 里的 providerId）

[model_providers.main]             # 这张表常驻，切换只改这张表的内容
name = "main"
wire_api = "responses"
requires_openai_auth = true        # Codex 始终保留 ChatGPT 登录态
base_url = "https://…"             # 官方后端 / 某个中继
experimental_bearer_token = "…"    # 仅中继通道有
```

- **官方通道**：`base_url = https://chatgpt.com/backend-api/codex`，不带 token
- **中继通道**：`base_url = <你的中继>`，带 `experimental_bearer_token`

`requires_openai_auth = true` 让 Codex 一直用 `auth.json` 里的 ChatGPT 登录（App 里很多功能依赖登录态），而模型请求带中继 key 发往 `base_url`。这个写法与 [yetone/magpie#994](https://github.com/yetone/magpie/issues/994) 讨论的「绑定 OAuth」一致，本仓库把它做成了一个开箱可用的工具。

因为 provider id 从不变，**Codex 的会话列表自始至终是同一个**：不需要每次切换后补迁移，也不会再有第二个桶。

## 安装

```bash
git clone https://github.com/Universeeeeeee/Codex-Switcher.git
cd Codex-Switcher
./install.sh
```

安装脚本会：把切换脚本装到 `~/.codex-switcher/`、从模板生成 `providers.json`（0600）、编译 `CodexSwitcher.app` 并放到 `/Applications`（无权限时放 `~/Applications`）。

## 配置

编辑 `~/.codex-switcher/providers.json`：

```json
{
  "providerId": "main",
  "officialBaseUrl": "https://chatgpt.com/backend-api/codex",
  "proxy": "http://127.0.0.1:7897",
  "providers": [
    { "id": "official", "name": "邮箱登录（官方）", "mode": "chatgpt",
      "model": "gpt-6.1-sol", "effort": "high",
      "authFile": "~/.codex-switcher/auth/official.json" },

    { "id": "relay-a", "name": "中继 A", "mode": "apikey",
      "model": "gpt-6-astra", "effort": "high",
      "baseUrl": "https://your-relay.example.com", "wireApi": "responses",
      "apiKey": "sk-…" }
  ]
}
```

| 字段 | 说明 |
|---|---|
| `providerId` | **固定不变的 provider id**，默认 `main`。三个通道共用它 |
| `officialBaseUrl` | 官方后端地址，一般不用改 |
| `proxy` | 仅用于**刷新官方登录 token**（无代理可留空） |
| `mode` | `chatgpt`（用官方登录态）或 `apikey`（用 `apiKey` 直连中继） |
| `model` / `effort` | 该通道下写入 Codex 的默认模型与推理档位 |
| `baseUrl` / `wireApi` / `apiKey` | 中继通道的地址（`…/v1` 或裸域名都可以，按你的中继）与 key |

> ⚠️ `providers.json` 含明文 key，权限请保持 `600`，不要提交到 git（仓库的 `.gitignore` 已排除）。

## 使用

```bash
# 命令行
~/.codex-switcher/codex_switch.sh relay-a              # 切换
~/.codex-switcher/codex_switch.sh official --restart   # 切换并自动重启 Codex
~/.codex-switcher/codex_switch.sh relay-a --dry-run    # 只看会改什么，不写入

# 或直接打开 App 点按钮
open /Applications/CodexSwitcher.app
```

首次使用：**先在 Codex 桌面端用官方账号登录一次**，然后随便切一次（脚本会把登录态留存到 `~/.codex-switcher/auth/official.json`），之后三个通道之间就可以随便来回切。

其它开关：`--no-history`、`--no-verify`、`--no-ccswitch`、`--legacy-ids`。

## 它在每次切换时做了什么

```
1/9 检查当前状态        解析 config.toml；检测 provider 段缺失这种"坏配置"
2/9 备份                config.toml / auth.json / state_5.sqlite → ~/.codex-switcher/backups/（保留最近 15 份）
3/9 凭据                官方：恢复登录态快照并尝试刷新 token；中继：保留登录态（或退回 apikey）
4/9 生成 config.toml    只重写 [model_providers.*] 这一段，其余内容与注释原样保留；写完再断言段存在
5/9 会话历史标签        统一到固定 provider id（第一次会迁移，之后每次都是"已一致"）
6/9 同步 cc-switch      装了才做，按 base_url 匹配行，尽力而为
7/9 端到端验证          用 Codex 自带 CLI 真发一次请求（--ephemeral，不产生会话）
8/9 重启应用            可选（--restart 或 App 里的勾选框）
9/9 摘要 + 日志          ~/.codex-switcher/logs/<时间>-<通道>.log
```

## 实测证据（macOS 26 / codex-cli 0.163.0-alpha.10.2）

| 验证项 | 方法 | 结果 |
|---|---|---|
| 中继通道确实走中继，且不动官方账号 | 固定 id + `requires_openai_auth = true` + bearer token，发请求前后查中继自己的用量接口 | `gpt-6-astra` 请求数 **315 → 316**；同期 `~/.codex/auth.json` 始终是 `auth_mode: "chatgpt"` |
| 官方通道在同一个 id 下可用 | `base_url = https://chatgpt.com/backend-api/codex`、不带 token | 同一个 provider id 下正常，返回 `cached_input_tokens: 5632`（确由官方后端服务） |
| 切换不再改标签 | 官方 ↔ 中继来回切 | 第二次起提示 **"标签已一致（647 条），无需改写"**，历史始终同一列表 |
| 配置自修复 | 人为造出 `model_provider = "custom"` 但无该段的坏配置 | 切换后段被写回，Codex 不再报 `Model provider not found` |

## 安全与回滚

- 切换前**必做备份**（config / auth / state 库），保留最近 15 份：`~/.codex-switcher/backups/`
- `--dry-run` 可先看不写；脚本对 `model_provider`、`base_url`、token 都有断言校验
- 历史标签迁移只改标签字段（`model_provider` / `model_provider_id`），**不动会话内容与模型字段**
- 想完全退回旧行为：`--legacy-ids`（官方=`openai`、中继=`custom`，但会重新分桶）

## 限制

- **仅 macOS、仅 Codex**。GUI 用 SwiftUI 写的，需要 Xcode Command Line Tools 才能编译
- **没有额度路由/故障转移**：上游额度耗尽时脚本会告诉你，但不会自动换通道
- **不会把中继的模型注入 Codex 自带模型列表**（那是 magpie 的 `model_catalog_json` 做的事）。所以别在 Codex 的模型选择器里点具体模型——模型由本工具的 `providers.json` 按通道设置
- 官方后端地址 `https://chatgpt.com/backend-api/codex` 是从 CLI 二进制里取出来的，属于未公开接口，Codex 升级后可能变化
- 个人工具，无维护承诺；Codex 的配置格式变化需要跟（例如 `disable_response_storage` 在新版已被判为 unrecognized，本脚本会自动清理）

## 致谢

- [yetone/magpie#994](https://github.com/yetone/magpie/issues/994) —— 「固定 provider id + 保留 ChatGPT 登录」的讨论与 `requires_openai_auth` 用法的来源
- [openai/codex](https://github.com/openai/codex) —— `resolve_provider_auth` 的凭据优先级（bearer token 优先于 ChatGPT session）

## License

MIT
