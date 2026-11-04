# Zen real-call verification

This opt-in check starts the installed OpenCode CLI in an isolated temporary
home, binds its local `serve` API to a random loopback port, and routes its
outbound requests through exactly one already-running loopback HTTP, HTTPS, or
SOCKS5 listener. It makes one health request, one model-catalog request, and at
most one short `glm-5.3-flash-free` generation in each of non-streaming and
stream-observed modes. It does not rotate nodes or issue a retry itself.

## Run

Choose a local listener that already represents the desired configured proxy
node (for example a Mihomo per-node HTTP listener). Do not pass a subscription
URL, remote proxy address, or URL containing username/password. The script
rejects non-loopback addresses and embedded credentials.

```powershell
dart run tool/verify_zen_live.dart `
  --cli "$env:APPDATA\zeroapi\opencode\bin\opencode.exe" `
  --proxy "http://127.0.0.1:PORT"
```

Replace `PORT` with the existing listener's port. An installed CLI elsewhere
can be selected with `--cli`; another catalog-listed model can be selected with
`--model`. The output is JSONL on stdout. Redirect it to a file if desired;
records include only UTC timestamp, check name, pass/fail status, HTTP status,
and fixed non-sensitive reason labels. Response text, prompts, CLI output,
proxy configuration, credentials, and subscription data are not recorded.

The child receives a minimal environment allowlist and a new temporary HOME,
USERPROFILE, APPDATA, and LOCALAPPDATA. Ambient provider API keys are omitted;
OpenCode's own Zen sign-in/config files therefore do not carry across. This
check relies on the CLI's anonymous/public Zen access. The temporary home and
CLI process are cleaned up on completion. Existing app and Mihomo processes
and persistent settings are not modified.

The CLI may perform its own upstream retry behavior. The verifier itself sends
only one message per requested mode and stops after a bounded timeout. A 429
is reported as a failed live generation; it is not treated as a successful
check or as evidence of quota bypass. The reference implementation
[developingchet/zengate](https://github.com/developingchet/zengate) is useful
for understanding CLI/session isolation; neither it nor this verifier bypasses
Zen account, model, or IP-based limits.

## Recorded status for this task（2026-11-01 实测）

CLI：`%APPDATA%\npm\node_modules\zengate\node_modules\opencode-ai\bin\opencode.exe`；
出口：本机 mihomo 的逐节点 HTTP listener（`vendor\proxy-core\mihomo.exe` 起的
`127.0.0.1:<port>`）。

| 检查 | 结果 | 证据 |
|---|---|---|
| CLI 健康（`/global/health`） | 通过 | `{"check":"health","status":"passed"}` |
| 模型目录（`/config/providers`） | 通过，目标模型在目录内 | `{"check":"model_catalog","status":"passed","detail":"requested_model_available"}` |
| 真实生成（出口 = 已退出的 listener 13356） | 失败：连不上 | `session_error message=Cannot connect to API: Unable to connect`（该端口所属内核实例已退出，TCP 连接被拒） |
| 真实生成（出口 = 存活 listener 1416） | 未获得有效生成结果 | 非流式与流式均未拿到正文。站点首页 200 不能证明推理接口可达，也不足以认定额度或风控是原因。 |
| 代理节点可达 opencode.ai | 部分节点可达 | 逐个 listener 探测：1416 返回 200，1413/1414/1415/1417/1418 等 TLS 失败 |
| 默认探活目标 `cp.cloudflare.com` | 大量节点超时 | 内核日志 `[TCP] dial n_xxx --> cp.cloudflare.com:80 error: context deadline exceeded`，说明「能出网」与「能访问上游 API」不是一回事 |

### 结论

健康与模型目录仅证明本地 CLI 控制接口正常，不能证明到推理接口的网络或授权正常。
已确认影响调用的出口问题包括：

1. **出口不可达**：CLI 报 `Cannot connect to API`。此前应用侧还叠加了一个缺陷——
   内置内核重启后 listener 端口会变（实测 13356 → 1413 一轮），而 Zen CLI 的
   `HTTP_PROXY` 仍指向旧端口，于是出口静默失效。
2. **出口可达但额度被上游拒绝**：CLI 报 `Free usage exceeded, subscribe to Go`。
   这类错误应按上游原文记录；其计量维度、恢复时间与账户授权要求需要以官方说明
   或对照测试为准，不能仅凭错误文案断言为 IP 每日额度。

因此「探测可用但实际调用不可用」是必然的：探活只验证了 CLI 进程与本地目录接口，
既不验证出口，也不验证额度。本轮据此改造了应用侧（见 `docs/zen-cli-hardening.md`）。
2026-11-01 再次故障现场：Zen 记录的代理为 `127.0.0.1:18549`，TCP 连接被拒；
同一个 ZeroApi 父进程下存在两个 mihomo。代码检查确认并发 sync 没有串行化、
停止旧进程时未等退出、五分钟刷新没有同步 CLI 的代理环境。此次修复覆盖这些路径。
