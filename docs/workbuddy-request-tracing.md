# WorkBuddy 请求追踪关联

`assets/engines/workbuddy_launcher.py` 作为受管引擎入口加载随包的
`vendor/workbuddy2api-hub/wb_proxy.py`，不会修改 vendor 文件。launcher 保留
原有命令行参数，原脚本的无参 `main()` 仍负责解析 `sys.argv` 和启动服务。

在 hub 的 `Handler.do_POST` 调用期间，launcher 从
`X-ZeroApi-Request-Id` 读取本次请求 ID，并在 `_persist_usage` 公共 JSONL 写入点
向成功与错误行附加 `request_id`。线程局部上下文在 `finally` 中恢复；同一
keep-alive 连接上后续请求重新读取请求头，没有该请求头时不会写该字段。网关与
hub 的两条 usage 记录因此可通过相同的 `request_id` 关联/去重。

## 受管启动集成

父代理的 `workbuddy.dart` 构造 command/args 时，应把命令改为随包 Python
解释器，并把 launcher 路径作为第一个脚本参数，其余 `wb_proxy.py` 参数保持原样：

```text
<bundle>/vendor/workbuddy2api-hub/python/pythonw.exe
<bundle>/assets/engines/workbuddy_launcher.py
--host 127.0.0.1 --port <port> --accounts-dir <dir> --usage-dir <dir>
```

launcher 默认从源码树的 `vendor/workbuddy2api-hub/wb_proxy.py` 定位上游文件；
打包后若布局不同，需在引擎环境中设置 `ZEROAPI_WORKBUDDY_HUB` 为实际
`wb_proxy.py` 路径。把 `assets/engines/workbuddy_launcher.py` 加入
`pubspec.yaml` 的 Flutter assets 集合，并确保它被复制/解包成可供 Python
解释器读取的真实文件路径（不能只保留在 Flutter asset bundle 中）。同时将
vendor hub 运行时与该资产一起放入安装包。Dart `UpstreamRuntime`/代理池等
启动参数无需新增 request-id 参数；ID 是每个 HTTP 请求通过 header 传递。

ZeroApi 网关侧必须在自己的 usage `_account` 记录 `request_id`，并只对
WorkBuddy 上游转发 `X-ZeroApi-Request-Id`。当前实现不会给没有该 header 的 hub
请求合成 ID，也不会影响其它方法或不相关的 usage 写入。

## 验证

```powershell
python test/workbuddy_request_id_test.py -v
```

测试覆盖同一 handler keep-alive 连续请求、错误/成功 usage 行、并发线程隔离和
无网关 header 的普通请求。
