# WorkBuddy 原生管理支持矩阵

API 契约以随包 `vendor/workbuddy2api-hub/wb_proxy.py` 当前路由为依据。管理操作使用
`GatewayService.hubGet/hubPost` 的面板会话认证；可选 GET 接口返回缺失或失败时，页面应提示
当前号池版本不支持或无法连接，不能将失败显示为成功。此文档只描述本 Flutter 客户端。

| 能力 | 当前状态 | 路由/限制 |
| --- | --- | --- |
| 账号列表、启停、权重、备注、禁用模型、账号代理地址/代理槽位、任务开关、删除 | 已有原生入口 | `GET /accounts?realm=all`、`POST /accounts/set`、`POST /accounts/delete`；上游 set 接受 `proxy`、`proxySlot`、`tasksEnabled` 等字段 |
| 风控与账号诊断信息 | 只读展示 | 列表显示 `restrictedUntil`、`cooldownUntil`；没有原生解除风控/清冷却操作，账户级状态由上游计算 |
| OAuth | 已有原生启动、复制授权 URL、3 秒轮询、取消 | `POST /accounts/login/start` (`realm`, `platform: CLI`)、`GET /accounts/login/poll?state=…`、`POST /accounts/login/cancel` (`state`)；轮询识别 `ok/success/done` |
| 静态 Key | 已有原生表单和前缀检查 | `POST /accounts/add-api-key` (`key`, `nickname`)；上游会在线探测有效性后才落盘，凭证不会在 UI 回显 |
| 账号导出 | 已有原生文件保存 | `GET /accounts/export`，可选 `uid`；导出文件包含敏感凭证，应由用户妥善保存 |
| 账号 JSON 导入 | 文件选择、JSON 解析、dry-run 校验/正式导入 | `POST /accounts/import` (`data`, `dryRun`, `overwrite`, 可选 `realm`)；UI 不再要求用户在 JSON 文本框编辑 |
| 本机桌面账号导入 | 已有一键导入 | `POST /accounts/import/desktop` (`all: true`)；扫描/恢复密钥的更细粒度流程未提供原生界面 |
| 账号测试、额度刷新、凭证刷新 | 已有账号菜单入口 | `POST /accounts/test`、`/accounts/credits`、`/accounts/refresh` |
| 调度器状态、开关、立即巡检 | 已有看板和调度设置页入口 | `GET /scheduler`、`POST /scheduler/toggle`、`POST /scheduler/trigger` |
| 调度时间、预留额度、并发上限及可见布尔项 | 有条件支持 | 从 `GET /settings` 实际返回值动态显示；`POST /settings/save` 只发送由当前响应提供的字段。未知字段隐藏，兼容性由保存后重新读取核验 |
| 任务执行/领取/旅行/连胜奖励、历史、签到与活跃 | 只有既有签到中心/历史相关页面支持 | 上游提供 `/tasks/run`、`/tasks/claim`、`/tasks/travel`、`/tasks/streak-bonus`、`/activity/history` 等；本管理页未提供全部任务动作的独立工作流 |
| 代理池槽位 CRUD、全局风控策略管理、解封/清冷却 | 未覆盖 | 账号代理槽位绑定可编辑；代理池自身管理、完整全局风控策略及清除风险状态未实现 |

上游路由存在不代表所有旧版号池都支持。遇到 HTTP 404/405 的可选能力按不支持处理；账号列表沿用服务层兼容接口，服务层对 GET 的网络/非 200 错误仍可能折叠为 `null`，此时 UI 只能显示读取失败，不能区分版本缺失与服务不可达。
