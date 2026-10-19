# ZeroApi — 零汇聚合网关（Flutter 桌面应用）

把多个 **OpenAI 兼容供应商**聚合为一个统一入口，供 ZCode、任意 OpenAI SDK
或聊天客户端使用。一个应用同时管理所有网关类服务：开关、探活、拉起、聚合、记账。

```
你的客户端（本机 / 局域网设备）──(OpenAI API + 网关 key)──▶ ZeroApi(:8123)
                                        ├──▶ OpenCode Zen Free (内置：直连，免费模型自动发现)
                                        ├──▶ Qoder2API-Hub  (自定义：转发)
                                        ├──▶ niceboat       (自定义：转发)
                                        └──▶ 未来任意兼容供应商  (加一条配置即可)
```

同一入口同时支持 **OpenAI 格式**（/v1/chat/completions、/v1/responses）与
**Anthropic 格式**（/v1/messages，Claude Code 可直接对接），两种格式在网关内
自动互转。

## 开箱即用

Windows：直接双击 `build/windows/<arch>/runner/Release/zeroapi.exe`
（首次启动自带内置供应商 OpenCode Zen Free：网关原生直连 Zen 免费通道，
无需安装任何其他组件、无需 API key，免费模型自动发现并可用）。

配置与日志在 `%APPDATA%\zeroapi\`（Linux/macOS 为 `~/.config/zeroapi/`）。
首次启动会自动把旧 `%APPDATA%\polygate\` 目录迁移过去。

## 供应商形态

| 类型 | UI 名称 | 含义 | 典型例子 |
|------|---------|------|----------|
| `zen`     | 内置 | 网关原生直连 OpenCode Zen 免费通道（纯 Dart 实现，不含 zengate/opencode 等外部二进制）：按客户端指纹请求 `opencode.ai/inference/v1`，只暴露免费档模型（`*-free`/big-pickle，其余默认隐藏），无需任何本地进程 | OpenCode Zen Free |
| `managed` | 内置 | ZeroApi 负责 `启动命令 + 参数` 拉起子进程；进程退出自动退避重启；端口已有实例则视为外部进程、不重复拉起 | 本地网关类供应商（如自建的 OpenAI 兼容服务） |
| `remote`  | 自定义 | 只做转发与探活，供应商由它自己负责 | Qoder2API-Hub、niceboat、OpenRouter 等任何 OpenAI 兼容端点 |

新增供应商：供应商页 → 「接入新供应商」，填 Base URL（带 `/v1`）与 Key；内置型再填命令与参数。

## 模型命名规则

- 模型名**全局唯一**时直接以裸名暴露（如 `big-pickle`）：OpenCode Zen 的 big-pickle
  在模型列表与路由中统一显示为裸名，不再出现 `zen/` 前缀的重复条目；
- 跨供应商**重名**的模型仍以 **`供应商id/模型名`** 消歧，避免歧义。
- `GET /v1/models` 返回全部路由及归属。
- 模型的能力信息（上下文窗口、视觉/推理/工具调用等）来自上游返回与
  [models.dev](https://models.dev) 目录（每日自动刷新，离线时用本地缓存）。

## 客户端怎么接

任何 OpenAI 兼容客户端只需两项（设置页可见、可复制，协议格式可在设置页切换）：

- Base URL：`http://127.0.0.1:8123/v1`（局域网内其他设备用本机局域网地址，见下文）
- API Key：**多网关密钥**——设置页可创建多把 key（标签 + 值），支持新建/重命名/删除/复制，
  每把 key 记录最近使用时间，便于按"不同设备/不同客户端一把 key"分发管理；
  旧的单 key 配置会自动迁移为一把「默认」key。

```bash
curl http://127.0.0.1:8123/v1/chat/completions \
  -H "Authorization: Bearer <key>" -H "Content-Type: application/json" \
  -d '{"model":"big-pickle","messages":[{"role":"user","content":"ping"}]}'
```

Anthropic 客户端（Claude Code 等）：设 `ANTHROPIC_BASE_URL=http://127.0.0.1:8123`，
API Key 同上；网关暴露 `/v1/messages` 并在 OpenAI ⇄ Anthropic 双向翻译
（含流式 SSE 事件），支持 `x-api-key` 鉴权。

### 局域网访问

设置页打开「允许局域网连接」开关后，网关监听 `0.0.0.0`，界面显示本机局域网地址；
同一 Wi-Fi/内网的其他设备（手机、另一台电脑）即可直接用该地址访问。注意：

- 首次监听会触发 Windows 防火墙授权弹窗，需点击「允许」；
- 配合多密钥使用，可给每台设备单独发一把 key，分开管理与追查。

## 已验证行为（本机）

- 内置 Zen：网关启动即原生直连（纯 Dart，无 zengate/opencode 二进制）Zen 免费通道拉模型目录
  （只保留免费档），预热就绪前不显示连接拒绝错误；
  429/5xx 与连接错误自动指数退避重试；供应商日志落 `%APPDATA%\zeroapi\logs\`。
- 上游 403（IP 滥用风控）统一映射为 429 限流语义：单模型进入冷却、**不转投其他模型**；
  判定出口 IP 被封时，应用内弹窗征询处理。
- 设置页提供「出口代理」：支持 http/socks5，逗号分隔多个可作轮换池；
  以及「一键部署 Cloudflare Worker」——用用户自己的免费 CF 账号部署，token 不落盘；
  注意 workers.dev 域名在国内需代理才可达。
- 非流式 + SSE 流式透传；每条请求日志记录：模型名、所用密钥标签、接口模式
  （chat/anthropic/responses、流式/非流式）、词元用量（输入/输出）、耗时与上游出口；
  上游返回缓存命中信息时一并显示缓存命中率。
- 用量页：横向条形图（模型名/条形/行尾词元·次数）、饼图、折线图；词元以中文「万/亿」计；
  用量跨重启持久（当日 jsonl 回填）。
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

- [jcleng/opencode-free-provider](https://github.com/jcleng/opencode-free-provider) —
  OpenCode Zen 免费通道的客户端指纹接入方式（本项目直连实现的主要参考）。
- [LAGcomcom/zen-gate](https://github.com/LAGcomcom/zen-gate)、[routatic/proxy](https://github.com/routatic/proxy) —
  同类 Zen 网关项目，接入细节交叉印证。
- [models.dev](https://models.dev) — 开放模型目录，本项目模型能力信息
  （上下文窗口、模态、推理/工具调用等）的数据来源。
- [LXGW WenKai / 霞鹜文楷](https://github.com/lxgw/LxgwWenKai-Lite) — 应用内置
  中文字体（SIL OFL 1.1）。
