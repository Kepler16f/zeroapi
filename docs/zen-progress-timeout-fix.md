# Zen 生成误判超时修复（2026-11-01）

## 日志证据

用户目录 `zeroapi/logs/usage-2026-11-01.jsonl` 中多次请求约 150 秒失败。
隔离 CLI 的 `.local/share/opencode/log/opencode.log` 显示：

- 本地时间 16:21:25 请求访问外部目录，`external_directory` 判为 `ask`。
- 16:24:29、16:29:49、16:32:16、16:34:42、16:41:39 和 16:44:30 再次进入同类权限等待。
- CLI 版本为 1.19.3；本机 `/doc` 包含 `message.part.delta`、会话级 permission、message.tools 和 `POST /session/{sessionID}/abort`。

这证明至少上述请求并非纯粹网络连不通：中转 CLI 又执行了自己的 agent 工具，
在客户端不可见的权限请求处停住。旧网关不处理这些请求，最后按无活动超时报错。
不能据此断言所有历史 120 秒错误都由同一个原因造成。

## 修改

- 临时会话设置 deny 权限，查询 CLI 工具目录并在消息中明确禁用所有工具，旧版目录不可用时使用已知工具列表兜底。不自动批准任何目录权限。
- 若仍出现 permission/question 等待，立即返回具体错误并停止任务。
- 首次有效模型输出最多等待 3 分钟；开始文本/思考后切换为连续 10 分钟无有效进展超时。每个真实新增文本或思考增量续期，整轮安全上限为 2 小时。
- 同时兼容累积快照和 `message.part.delta`，去除最终快照重复；思考只计进度，不混入正文。
- 重复快照、busy、用户回显、别的会话、server heartbeat 不续期。长生成无总计 120 秒限制。
- 收到 idle 后等待同步 HTTP 最多 2 秒以补全用量，不再因 HTTP 没返回而无限挂起；支持从 assistant 事件读取用量。
- 错误或取消先调用官方 abort，再关闭 message HTTP、取消事件订阅和删除临时会话；清理后才向网关交付错误，避免下一请求抢入旧任务。
- 流式响应关闭缓冲并每 15 秒发送保活；保活不续上游看门狗。已开始生成的请求不自动换出口重发。
- 真正停滞返回 504 / `generation_idle_timeout`；已输出部分内容时发送协议内错误并关闭，Anthropic 不伪造成功 `message_stop`。

官方协议依据：[OpenCode Server](https://opencode.ai/docs/server/)，并以本机 `/doc` 核对字段。

## 验收

- 68 项相关测试通过，涵盖 Zen/CLI 协议、出口保护、并发、内核生命周期与启动顺序。
- 其中新增长生成/思考续期、快照去重、重复状态不续期、显式 abort、消费者取消、idle 后 HTTP 挂起、OpenAI/Anthropic 部分输出错误结束及后续请求释放队列测试。
- 修改后的 27 项定向回归与分析检查再次执行，结果见 `build/zen-progress-final-tests.log`。
- 真实本机 CLI：DeepSeek 在约 5 秒返回 `Free usage exceeded, subscribe to Go`；big-pickle 在约 1.45 秒返回同一额度错误。两者都未达到本地超时，不能将其写成真实生成成功。
- 真实生成复测工具：`dart run tool/verify_zen_progress.dart [baseUrl] [model]`，只输出耗时、块数和 token 等元数据。未重启在用 CLI，未变更代理设置，未覆盖安装。
- Windows ARM64 Release 构建成功。安装包单独命名为 `installer/zeroapi-setup-arm64-0.3.3-zen-progress-fix.exe`，保留原版安装包；覆盖安装必须在用户同意后进行。

以上时长为当前默认策略，不能保证上游服务始终可用。当前额度拒绝需要在上游允许调用后补做真实生成验收。
