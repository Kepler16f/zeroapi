# ZeroApi — 零汇聚合网关（Flutter 桌面应用）

把多个 **OpenAI 兼容供应商**聚合为一个统一入口，供 ZCode、任意 OpenAI SDK
或聊天客户端使用。一个应用同时管理所有网关类服务：开关、探活、拉起、聚合、记账。

```
你的客户端 ──(OpenAI API + 统一 key)──▶ ZeroApi(:8123)
                                        ├──▶ Opencode Zen Free (托管：自动拉起/守护) → 免费模型
                                        ├──▶ Qoder2API-Hub  (远端转发)
                                        ├──▶ niceboat       (远端转发)
                                        └──▶ 未来任意兼容供应商  (加一条配置即可)
```

## 开箱即用

Windows：直接双击 `build/windows/<arch>/runner/Release/zeroapi.exe`
（首次启动自动检测本机 `npm -g` 安装的 zengate 并读取其 API key，
以"托管供应商"身份接入，界面显示为 Opencode Zen Free——没装 zengate 则该项跳过，其他供应商照常）。

配置与日志在 `%APPDATA%\zeroapi\`（Linux/macOS 为 `~/.config/zeroapi/`）。
首次启动会自动把旧 `%APPDATA%\polygate\` 目录迁移过去。

## 供应商的两种形态

| 类型 | 含义 | 典型例子 |
|------|------|----------|
| `managed` | ZeroApi 负责 `启动命令 + 参数` 拉起子进程；进程退出自动退避重启；端口已有实例则视为外部进程、不重复拉起 | Opencode Zen Free（`node .../zengate/index.js`） |
| `remote`  | 只做转发与探活，供应商由它自己负责 | Qoder2API-Hub、niceboat、OpenRouter 等任何 OpenAI 兼容端点 |

新增供应商：供应商页 → 「接入新供应商」，填 Base URL（带 `/v1`）与 Key；托管型再填命令与参数。

## 模型命名规则

- 每个供应商的模型以 **`供应商id/模型名`** 暴露（如 `zen/big-pickle`）；
- 当某个裸模型名在所有供应商中**唯一**时，也可直接用裸名（如 `big-pickle`）；重名时请带前缀，避免歧义。
- `GET /v1/models` 返回全部路由及归属。

## 客户端怎么接

任何 OpenAI 兼容客户端只需两项（设置页可见、可复制）：

- Base URL：`http://127.0.0.1:8123/v1`
- API Key：设置页显示 / 复制 / 一键更换

```bash
curl http://127.0.0.1:8123/v1/chat/completions \
  -H "Authorization: Bearer <key>" -H "Content-Type: application/json" \
  -d '{"model":"zen/big-pickle","messages":[{"role":"user","content":"ping"}]}'
```

## 已验证行为（本机）

- 托管：ZeroApi 启动即拉起 zengate 子进程；供应商日志落
  `%APPDATA%\zeroapi\logs\upstream-<id>.log`；子进程意外退出自动重启（1s 起指数退避，封顶 60s）。
- 非流式 + SSE 流式透传；usage 记账（内存汇总 + 按天 jsonl）。
- `/v1/responses` 端点透传（请求体原样转发供应商 `/responses`，
  usage 按 `input_tokens`/`output_tokens` 记账）。
- 供应商不可达 → 503，并在下次请求时重新探活/重新拉起。
- `flutter test`：路由解析、chat/responses 透传、401/404 均有端到端用例。

## 已知边界（设计上"开放"，当前未做）

- chat 与 responses 两种格式之间不做互相转换：客户端发哪种就透传到供应商对应端点，
  供应商不支持该端点则原样报错。
- 路由亲和/权重：当前按注册顺序，裸名冲突即拒。
- 单实例：端口被占直接报错，无主从选举。

## 构建

全平台矩阵（Windows x64/arm64、Linux x64/arm64、macOS、iOS、Android；
HarmonyOS NEXT 需 OpenHarmony 定制 Flutter SDK，脚本仅占位提示）：

```bash
powershell -File tool/build.ps1 -Platforms windows-arm64            # 构建
powershell -File tool/build.ps1 -Platforms windows-x64 -Installer   # 构建+安装包
powershell -File tool/build.ps1                                    # 交互式选择
```

Windows 安装包（Inno Setup 6）：

```bash
iscc /DMyArch=arm64 /DMyVersion=1.0.0 packaging/zeroapi.iss
# 产物：installer/zeroapi-setup-arm64-1.0.0.exe
```

图标由 `tool/make_icon.ps1` 从方案（环枢 Hub Ring）几何参数直接渲染
（`assets/icon/zeroapi.ico` 多尺寸 + `icon_<px>.png`），并已接入
`windows/runner/resources/app_icon.ico`。
