# ZeroApi — 零汇聚合网关（Flutter 桌面应用）

把多个 **OpenAI 兼容供应商**聚合为一个统一入口，供 ZCode、任意 OpenAI SDK
或聊天客户端使用。一个应用同时管理所有网关类服务：开关、探活、拉起、聚合、记账。

```
你的客户端 ──(OpenAI API + 统一 key)──▶ ZeroApi(:8123)
                                        ├──▶ OpenCode Zen Free (内置：自动拉起/守护) → 免费模型
                                        ├──▶ Qoder2API-Hub  (自定义：转发)
                                        ├──▶ niceboat       (自定义：转发)
                                        └──▶ 未来任意兼容供应商  (加一条配置即可)
```

同一入口同时支持 **OpenAI 格式**（/v1/chat/completions、/v1/responses）与
**Anthropic 格式**（/v1/messages，Claude Code 可直接对接），两种格式在网关内
自动互转。

## 开箱即用

Windows：直接双击 `build/windows/<arch>/runner/Release/zeroapi.exe`
（首次启动自动检测本机 `npm -g` 安装的 zengate 并读取其 API key，
以"内置供应商"身份接入，界面显示为 OpenCode Zen Free——没装 zengate 则该项跳过，其他供应商照常）。

配置与日志在 `%APPDATA%\zeroapi\`（Linux/macOS 为 `~/.config/zeroapi/`）。
首次启动会自动把旧 `%APPDATA%\polygate\` 目录迁移过去。

## 供应商的两种形态

| 类型 | UI 名称 | 含义 | 典型例子 |
|------|---------|------|----------|
| `managed` | 内置 | ZeroApi 负责 `启动命令 + 参数` 拉起子进程；进程退出自动退避重启；端口已有实例则视为外部进程、不重复拉起 | OpenCode Zen Free（`node .../zengate/index.js`） |
| `remote`  | 自定义 | 只做转发与探活，供应商由它自己负责 | Qoder2API-Hub、niceboat、OpenRouter 等任何 OpenAI 兼容端点 |

新增供应商：供应商页 → 「接入新供应商」，填 Base URL（带 `/v1`）与 Key；内置型再填命令与参数。

## 模型命名规则

- 每个供应商的模型以 **`供应商id/模型名`** 暴露（如 `zen/big-pickle`）；
- 当某个裸模型名在所有供应商中**唯一**时，也可直接用裸名（如 `big-pickle`）；重名时请带前缀，避免歧义。
- `GET /v1/models` 返回全部路由及归属。
- 模型的能力信息（上下文窗口、视觉/推理/工具调用等）来自上游返回与
  [models.dev](https://models.dev) 目录（每日自动刷新，离线时用本地缓存）。

## 客户端怎么接

任何 OpenAI 兼容客户端只需两项（设置页可见、可复制，协议格式可在设置页切换）：

- Base URL：`http://127.0.0.1:8123/v1`
- API Key：设置页显示 / 复制 / 一键更换

```bash
curl http://127.0.0.1:8123/v1/chat/completions \
  -H "Authorization: Bearer <key>" -H "Content-Type: application/json" \
  -d '{"model":"zen/big-pickle","messages":[{"role":"user","content":"ping"}]}'
```

Anthropic 客户端（Claude Code 等）：设 `ANTHROPIC_BASE_URL=http://127.0.0.1:8123`，
API Key 同上；网关暴露 `/v1/messages` 并在 OpenAI ⇄ Anthropic 双向翻译
（含流式 SSE 事件），支持 `x-api-key` 鉴权。

## 已验证行为（本机）

- 内置：ZeroApi 启动即拉起 zengate 子进程，预热就绪前不显示连接拒绝错误；
  供应商日志落 `%APPDATA%\zeroapi\logs\upstream-<id>.log`；
  子进程意外退出自动重启（1s 起指数退避，封顶 60s）。
- 非流式 + SSE 流式透传；usage 记账（内存汇总 + 按天 jsonl + 分时段图表）。
- `/v1/responses` 端点透传（请求体原样转发供应商 `/responses`，
  usage 按 `input_tokens`/`output_tokens` 记账）。
- `/v1/messages`（Anthropic 格式）非流式与流式端到端可用。
- 供应商不可达 → 503，并在下次请求时重新探活/重新拉起。
- `flutter test`：路由解析、chat/responses/messages 透传、Anthropic 协议转换、
  401/404 均有端到端用例。

## 已知边界（设计上"开放"，当前未做）

- chat 与 responses 两种格式之间不做互相转换：客户端发哪种就透传到供应商对应端点，
  供应商不支持该端点则原样报错。Anthropic ⇄ OpenAI 已做双向转换。
- 路由亲和/权重：当前按注册顺序，裸名冲突即拒。
- 单实例：端口被占直接报错，无主从选举。

## 构建

全平台矩阵（Windows x64/arm64、Linux x64/arm64、macOS、iOS、Android；
HarmonyOS NEXT 需 OpenHarmony 定制 Flutter SDK，脚本仅占位提示）：

```bash
powershell -File tool/build.ps1 -Platforms windows-arm64            # 构建
powershell -File tool/build.ps1 -Platforms windows-arm64 -Installer # 构建+安装包
powershell -File tool/build.ps1                                    # 交互式选择
```

版本号单一来源 `lib/version.dart`（构建前与发布者确认）。
Windows 安装包（Inno Setup 6）：

```bash
iscc /DMyArch=arm64 /DMyVersion=1.1.0 packaging/zeroapi.iss
# 产物：installer/zeroapi-setup-arm64-<version>.exe
```

图标由 `tool/make_icon.ps1` 从「环枢 Hub Ring」几何参数直接渲染
（`assets/icon/zeroapi.ico` 多尺寸 + `icon_<px>.png`），并已接入
`windows/runner/resources/app_icon.ico`。

## 致谢

- [zengate](https://github.com/developingchet/zengate) — 本项目内置供应商
  OpenCode Zen Free 的上游实现；其中 OpenCode Zen 免费模型的接入方式与
  部分设计参考了该项目。
- [models.dev](https://models.dev) — 开放模型目录，本项目模型能力信息
  （上下文窗口、模态、推理/工具调用等）的数据来源。
- [LXGW WenKai / 霞鹜文楷](https://github.com/lxgw/LxgwWenKai-Lite) — 应用内置
  中文字体（SIL OFL 1.1）。
