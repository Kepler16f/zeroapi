import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'opencode_api.dart';
import 'opencode_serve.dart';
import 'zen.dart';

/// OpenCode CLI **v2** `opencode serve` 线协议适配层（2026-11-05 实测，
/// @opencode/cli 2.2.5）。对外契约与 [OpenCodeApi]（v1）同形，上层 proxy.dart
/// 可以按运行时版本在二者之间直接二选一。
///
/// 与 v1 的关键差异（全部为实测锁定，勿凭想象"优化"）：
///   * serve 默认开启 HTTP Basic 认证，密码由环境变量
///     `OPENCODE_SERVER_PASSWORD` 固定；用户名**必须是 `opencode`**
///     （空用户名被 401 拒）。本类每个请求都带
///     `Authorization: Basic base64("opencode:<password>")`。
///   * v2 上访问 v1 端点（/global/health、/config/providers、/session、/event）
///     返回 **HTTP 200 + SPA HTML** 而不是 404——不能用状态码判端点是否存在；
///     判据是 `GET /api/info` 能否解析出 JSON（见 [OpenCodeApiV2.probe]）。
///   * 回合流程：POST /api/session → POST /api/session/{sid}/model（204 无体）
///     → POST /api/session/{sid}/prompt（异步，不含答案）→ SSE /api/event
///     取 `session.text.delta` 增量 → POST /api/experimental/session/{sid}/wait
///     等本轮结束（204），并以 `GET /api/session/{sid}/message` 的消息列表兜底
///     （wait 路由带 experimental 前缀，未来可能消失 → 退回轮询消息列表看
///     `idle` 记录与 assistant 终态）。
///   * 额度错误不再走 HTTP 状态码：prompt 永远 200，错误出现在 assistant
///     消息的 `error` 字段（`type` ∈ provider.free-limit 等），由
///     [OpenCodeUpstreamV2Error] 结构化判定（勿只看 429——降级期会误报）。
///   * v1 的 `session.status type=retry` 在 v2 对应 `session.retry.scheduled`：
///     软限流，CLI 自己退避重试，实测 17–71s 后常自愈——只记日志，
///     **绝不因此终止本轮**（v1 曾把它当额度烧穿掐死，2 分钟烧光 62 个出口）。
///
/// SSE 帧没有 `event:` 行，类型在 JSON 的 `type` 字段里；有 `: heartbeat`
/// 注释行。心跳只证明 serve 进程活着，**不刷新停滞看门狗**（v1 教训：
/// 看门狗被心跳骗过导致无限挂 7 分钟）。
class OpenCodeApiV2 implements OpenCodeServeApi {
  OpenCodeApiV2(this.baseUrl, {required String password, HttpClient? client})
    : _authHeader =
          'Basic ${base64.encode(utf8.encode('opencode:$password'))}',
    _client = client ?? HttpClient() {
    // SSE 长连接：模型思考期间可能几十秒无数据，Dart 默认 idleTimeout=15s
    // 会掐断连接——沿用 v1 做法放宽到 2 小时。
    _client.idleTimeout = const Duration(hours: 2);
    _client.connectionTimeout = const Duration(seconds: 30);
  }

  final String baseUrl;
  final HttpClient _client;
  final String _authHeader;

  /// retry 事件回调（可选）：CLI 重试上游失败时通知（网关记日志用）。
  static void Function(String message)? onRetryEvent;
  @override
  void Function(String message)? onRetry;
  @override
  void Function(String message)? onActivity;

  /// 首次有效输出的等待窗口，不是整轮生成的时间上限。
  ///
  /// 90s 的取值权衡：健康出口 <20s 就有首字；CLI 对软限流的自愈窗口实测
  /// 17–71s（要覆盖它，不能更短）；而死出口每轮卡满这个窗口——3 分钟的
  /// 旧值让 6 轮换出口最坏挂 18 分钟（用户实测「好几分钟没反应」）。
  static Duration stallTimeout = const Duration(seconds: 90);

  /// 已开始输出/思考后，每次有效进展重置这个窗口。
  static Duration generationIdleTimeout = const Duration(minutes: 10);

  /// 单轮安全上限（wait 阻塞、SSE 长连接都受它兜底）。
  static Duration requestTimeout = const Duration(hours: 2);

  /// 本轮「已结束」（wait 返回或 SSE execution.succeeded/failed）之后，
  /// 再读消息列表找本轮回复/错误的兜底窗口。
  static Duration completionGrace = const Duration(seconds: 15);

  /// wait 路由不可用（experimental 前缀被移除等）时，轮询消息列表的间隔。
  static Duration waitPollInterval = const Duration(seconds: 3);

  final _cancellations = <void Function()>{};
  @override
  bool generationStarted = false;

  /// 最近一轮的真实 token 用量（`session.usage.updated` 或终态消息 tokens）。
  @override
  ({int input, int output}) lastUsage = (input: 0, output: 0);
  @override
  int cachedReadTokens = 0;
  @override
  int cachedWriteTokens = 0;

  /// 结构化 429 的重试间隔（秒）。上游没给时机就是 null——**绝不瞎猜**。
  /// 主代理可在 catch 后直接读，无需对错误对象判型。
  int? lastRetryAfterSeconds;

  @override
  int? get retryAfterSeconds => lastRetryAfterSeconds;

  static const _sessionPath = '/api/session';

  Map<String, String> get _headers => {
    'content-type': 'application/json; charset=utf-8',
    'accept': 'application/json',
    'authorization': _authHeader,
  };

  /// 建一个 v2 会话。权限必须在建会话时下发（action=* 一律 ask → 实际是
  /// 「不执行」）：中转层不该执行 agent 工具，也不该等待无人可见的权限弹窗。
  Future<String> createSession() async {
    final resp = await _send('POST', _sessionPath, {
      'title': 'zeroapi',
      'permissions': [
        {'action': '*', 'resource': '*', 'effect': 'ask'},
        {'action': 'execute', 'resource': '*', 'effect': 'deny'},
        {'action': 'browser', 'resource': '*', 'effect': 'deny'},
      ],
    });
    final body = await _readBody(resp);
    if (resp.statusCode != 200) {
      throw _httpFailure('/api/session', resp.statusCode);
    }
    final j = _jsonObject(body);
    final data = j['data'];
    final id = data is Map ? data['id'] : null;
    if (id is! String || id.isEmpty) {
      throw const OpenCodeUpstreamError(
        message: 'opencode v2 /api/session 未返回会话 id',
        statusCode: 502,
      );
    }
    return id;
  }

  /// 设置本轮模型。v2 端点返回 **204 无体**；字段名是 `id` 而不是 v1 的
  /// `modelID`，providerID 固定 `opencode`。
  Future<void> setModel(String sessionId, String model) async {
    final resp = await _send('POST', '$_sessionPath/$sessionId/model', {
      'model': {'providerID': 'opencode', 'id': model},
    });
    await resp.drain<void>();
    if (resp.statusCode != 204 && resp.statusCode != 200) {
      throw OpenCodeUpstreamError(
        message: 'opencode v2 设置模型 HTTP ${resp.statusCode}',
        statusCode: 502,
      );
    }
  }

  /// 发提示词。**异步**：200 响应只回执用户消息，不含答案。
  Future<void> postPrompt(String sessionId, String text) async {
    final resp = await _send(
      'POST',
      '$_sessionPath/$sessionId/prompt',
      {'text': text},
    );
    await resp.drain<void>();
    if (resp.statusCode != 200) {
      throw OpenCodeUpstreamError(
        message: 'opencode v2 /prompt HTTP ${resp.statusCode}',
        statusCode: resp.statusCode,
      );
    }
  }

  /// 「本轮结束」的主信号：v2 运行中会阻塞到回合结束返回 204，空闲时约 3ms
  /// 秒回。路由带 experimental 前缀、未来可能移除——HttpException 视为路由
  /// 不存在（由调用方退回消息轮询），其余异常照常上抛。
  Future<void> waitForTurn(String sessionId) async {
    final resp = await _send(
      'POST',
      '/api/experimental/session/$sessionId/wait',
      null,
      timeout: requestTimeout,
    );
    await resp.drain<void>();
    if (resp.statusCode != 204 && resp.statusCode != 200) {
      throw HttpException(
        'opencode v2 /wait HTTP ${resp.statusCode}',
        uri: Uri.parse('$baseUrl/api/experimental/session/$sessionId/wait'),
      );
    }
  }

  /// 拉取会话消息列表（asc 分页、cursor.next 续页、按 id 去重）。
  /// 返回原始消息 Map 列表——里面混有合成记录（model-switched / user /
  /// idle），调用方只应取 assistant 消息的 content[]。
  Future<List<Map<String, dynamic>>> listMessages(String sessionId) async {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    String? cursor;
    for (var page = 0; page < 50; page++) {
      // 服务端规则（2026-11-05 实测）：cursor 不能与 order 同时出现
      // （"Cursor cannot be combined with order" → HTTP 400）。翻页时只带
      // cursor；首屏才带 order=asc。
      final query = cursor == null
          ? '?limit=200&order=asc'
          : '?limit=200&cursor=${Uri.encodeQueryComponent(cursor)}';
      final resp = await _send(
        'GET',
        '$_sessionPath/$sessionId/message$query',
        null,
      );
      final body = await _readBody(resp);
      if (resp.statusCode != 200) {
        // 带上响应体：v2 的错误体是 {"_tag":...,"message":...}，不带出来
        // 就只能看到「HTTP 400」这种没信息量的文案。
        throw OpenCodeUpstreamError(
          message:
              'opencode v2 /message HTTP ${resp.statusCode}'
              '${body.isEmpty ? '' : '：${body.length > 300 ? body.substring(0, 300) : body}'}',
          statusCode: resp.statusCode,
        );
      }
      final j = _jsonObject(body);
      final data = j['data'];
      if (data is List) {
        for (final m in data.whereType<Map>()) {
          final id = m['id'];
          if (id is String && !seen.add(id)) continue;
          out.add(m.cast<String, dynamic>());
        }
      }
      final c = j['cursor'];
      final next = c is Map ? c['next'] : null;
      if (next is! String || next.isEmpty || next == cursor) break;
      cursor = next;
    }
    return out;
  }

  /// 发一轮对话，流式回传助手文本增量。契约与 v1 [OpenCodeApi.chat] 一致：  /// 只吐 assistant 的 text 增量；出错时 stream 抛异常；每请求新建会话
  /// （无状态翻译，多轮上下文由 messages 扁平化文本承载——复用 v1 的
  /// [OpenCodeApi.chatMessages]，保证两版扁平化行为一致，不另造一套）。
  @override
  Stream<String> chat({
    required String model,
    required List<Map<String, dynamic>> messages,
    int? maxTokens,
  }) {
    final cancelled = Completer<void>();
    void cancel() {
      if (!cancelled.isCompleted) cancelled.complete();
    }

    final ctrl = StreamController<String>(onCancel: cancel);
    _cancellations.add(cancel);
    unawaited(
      _run(model, messages, ctrl, cancelled).whenComplete(
        () => _cancellations.remove(cancel),
      ),
    );
    return ctrl.stream;
  }

  Future<void> _run(
    String model,
    List<Map<String, dynamic>> messages,
    StreamController<String> ctrl,
    Completer<void> cancelled,
  ) async {
    StreamSubscription<String>? sub;
    Timer? stall;
    Timer? deadline;
    String? sessionId;
    var successful = false;
    var done = false;
    var emittedAny = false;

    /// 本轮的传输层重试计数（session.retry.scheduled 且 message 带
    /// provider.transport）。连续 4 次即判出口不可达——CLI 对传输错误会无限
    /// 重试（实测 10 次 / 148s），同一 IP 上第 5 次不会有不同结果。
    var transportRetries = 0;
    var sawFailed = false;

    /// 本轮最后一次 CLI 重试的原因（provider.rate-limit / provider.transport…）。
    /// 看门狗中止时用它补上下文：**上游过载**导致的停滞不是出口死了，
    /// 不能据此冷却档位/判节点失败（换出口只是给上游恢复时间）。
    String? lastRetryReason;
    Object? failure;
    StackTrace? failureStack;
    try {
      final sid = await createSession();
      sessionId = sid;
      // 1) 先订阅事件流，再发提示词——否则可能错过开头增量。
      final req = await _client.getUrl(Uri.parse('$baseUrl/api/event'));
      req.headers.set('authorization', _authHeader);
      req.headers.set('accept', 'text/event-stream');
      final eventResp = await req.close().timeout(const Duration(seconds: 30));
      if (eventResp.statusCode != 200) {
        throw _httpFailure('/api/event', eventResp.statusCode);
      }

      final finished = Completer<void>();
      // 错误可能在无人监听时发生（Future.any 先胜出、消费者已关流），
      // 不加 ignore 会变成 unhandled async error 把用例/请求搞崩。
      finished.future.ignore();
      final upstreamError = Completer<Object>();
      upstreamError.future.ignore();

      var hasProgress = false;
      void fail(Object e) {
        if (!upstreamError.isCompleted) upstreamError.completeError(e);
        if (!finished.isCompleted) finished.completeError(e);
      }

      void armStall() {
        stall?.cancel();
        final timeout = hasProgress ? generationIdleTimeout : stallTimeout;
        stall = Timer(timeout, () {
          if (done || finished.isCompleted || upstreamError.isCompleted) return;
          // 上游过载时 CLI 只是在退避重试、没有输出 → 看门狗照样会掐。
          // 把最后的重试原因带上：这样上层能分清「出口死了」与「上游在限流
          // （所有出口都打同一个上游，换出口只是给它恢复时间）」。
          final hint = lastRetryReason == null
              ? ''
              : '（上游最后报告：${lastRetryReason!.length > 160 ? '${lastRetryReason!.substring(0, 160)}…' : lastRetryReason}）';
          fail(
            OpenCodeUpstreamError(
              message: hasProgress
                  ? 'opencode v2 CLI 已开始生成，但连续 ${timeout.inSeconds}s 无有效进展，正在停止本轮$hint'
                  : 'opencode v2 CLI ${timeout.inSeconds}s 无任何响应（未收到模型有效输出），正在停止本轮$hint',
              statusCode: 504,
              stalled: true,
            ),
          );
        });
      }

      void progress() {
        if (!hasProgress) {
          onActivity?.call('已收到模型输出，切换为生成空闲超时');
        }
        hasProgress = true;
        generationStarted = true;
        armStall();
      }

      /// 已吐出的文本（用于收尾时与终态消息对账）。
      final emittedText = StringBuffer();

      /// 是否已收到 usage 事件。usage 事件可能与结束信号紧邻到达而被漏掉，
      /// 收尾时要用终态消息的 tokens 补上——否则记账归零（真机表现为
      /// 「这次请求用了 0 词元」）。
      var usageFromEvent = false;

      void emit(String text) {
        if (text.isEmpty || ctrl.isClosed || cancelled.isCompleted) return;
        emittedAny = true;
        emittedText.write(text);
        ctrl.add(text);
      }

      void readUsage(Map tokens) {
        final cache = tokens['cache'] is Map
            ? tokens['cache'] as Map
            : const {};
        cachedReadTokens = (cache['read'] as num?)?.toInt() ?? 0;
        cachedWriteTokens = (cache['write'] as num?)?.toInt() ?? 0;
        lastUsage = (
          input:
              ((tokens['input'] as num?)?.toInt() ?? 0) +
              cachedReadTokens +
              cachedWriteTokens,
          output: (tokens['output'] as num?)?.toInt() ?? 0,
        );
      }

      deadline = Timer(requestTimeout, () {
        fail(
          const OpenCodeUpstreamError(
            message: 'opencode v2 CLI 达到单轮安全上限，正在停止本轮',
            statusCode: 504,
          ),
        );
      });

      sub = eventResp
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (done) return;
              // v2 SSE 没有 event: 行；`: heartbeat` 等注释行一律忽略，且
              // 不得刷新看门狗（v1 实测教训：心跳骗过 watchdog 挂 7 分钟）。
              if (!line.startsWith('data:')) return;
              Map<String, dynamic> j;
              try {
                j = jsonDecode(line.substring(5).trim())
                    as Map<String, dynamic>;
              } catch (_) {
                return; // 非 JSON 的 data 行（理论上不该出现）直接忽略。
              }
              final type = j['type'];
              final data =
                  (j['data'] ?? const <String, dynamic>{})
                      as Map<String, dynamic>;
              final eventSession =
                  data['sessionID'] ??
                  data['sessionId'] ??
                  (data['message'] is Map
                      ? (data['message'] as Map)['sessionID']
                      : null);
              if (eventSession != sid) return;
              if (type == 'server.connected') return;

              if (type == 'session.usage.updated') {
                // data 形如 {sessionID, cost, tokens:{input,output,cache}}：
                // tokens 嵌在 data.tokens 里（2026-11-05 沙箱抓包），把 data
                // 整包传给 readUsage 会把 input/output 读成 0。
                final tk = data['tokens'];
                if (tk is Map) {
                  readUsage(tk);
                  usageFromEvent = true;
                }
                return;
              }
              if (type == 'session.text.delta') {
                // 增量文本在 data.delta；思考增量走 session.reasoning.delta，
                // 本适配层不吐给客户端。
                final delta = data['delta'] as String? ?? '';
                if (delta.isNotEmpty) {
                  progress();
                  emit(delta);
                }
                return;
              }
              if (type == 'session.text.started' ||
                  type == 'session.text.ended' ||
                  type == 'session.step.started' ||
                  type == 'session.step.ended' ||
                  type == 'session.execution.started') {
                // 有活动但非文本进展：不置 generationStarted、不刷新看门狗，
                // 免得空转的 step 循环把停滞计时无限续命。
                return;
              }
              if (type == 'session.retry.scheduled') {
                // v1 的 session.status type=retry 在 v2 的对应物：**软限流**。
                // CLI 会自己退避重试，额度类 3 次后自会放弃（AI_RetryError）。
                // 这里只记日志，绝不把额度 retry 当烧穿——11-04 误杀回归教训。
                //
                // 但**传输层风暴**（ECONNRESET 等）不同：CLI 对传输错误会一直
                // 重试下去（实测 10 次 / 148s，直到看门狗掐掉），而同一个出口
                // IP 上第 5 次连接和第 4 次不会有不同结果。连续 4 次传输重试
                // 且无任何输出 → 判定出口不可达，立即换（148s → ~60s）。
                final msg =
                    (data['message'] ?? data['reason'] ?? data['error'] ?? '')
                        .toString();
                if (msg.isNotEmpty) {
                  lastRetryReason = msg;
                  (onRetry ?? onRetryEvent)?.call(msg);
                }
                if (!generationStarted &&
                    msg.contains('provider.transport') &&
                    ++transportRetries >= 4) {
                  fail(
                    OpenCodeUpstreamError(
                      message:
                          'opencode v2 CLI 连续 $transportRetries 次连接上游'
                          '失败（出口不可达）',
                      statusCode: 502,
                      connectionFailure: true,
                    ),
                  );
                }
                return;
              }
              if (type == 'session.execution.succeeded') {
                if (!finished.isCompleted) finished.complete();
                return;
              }
              if (type == 'session.execution.failed') {
                // 不当场抛通用错：v2 的结构化错误（额度/传输）只写在 assistant
                // 消息的 error 字段里，先记旗标，让收尾的消息列表解码出真实
                // 类型，再由 [OpenCodeUpstreamV2Error] 判定。
                sawFailed = true;
                if (!finished.isCompleted) finished.complete();
                return;
              }
              if (type == 'session.error') {
                sawFailed = true;
                if (!finished.isCompleted) finished.complete();
                return;
              }
              // 其余事件族（session.inbox.*、session.instructions.updated、
              // session.reasoning.*、session.permission.* 等）：中转层不需要，
              // 忽略且不刷新看门狗。权限已在建会话时 deny 死，若 CLI 仍卡在
              // 权限等待，由停滞看门狗兜底中止。
            },
            onError: (Object e) {
              fail(e);
            },
          );

      // 2) 设置模型 → 发提示词。prompt 是异步的：HTTP 200 只回执用户消息。
      await setModel(sid, model);
      if (cancelled.isCompleted) return;
      await postPrompt(sid, OpenCodeApi.chatMessages(messages));
      armStall();

      // 3) 等本轮结束：主信号 = wait 路由（204）或 SSE 的 execution.succeeded/
      // failed；wait 抛错（路由被移除、连接断、超时等）→ 退回轮询消息列表看
      // idle 记录，SSE 仍是错误面的兜底。
      var polling = false;
      void startPollFallback() {
        if (polling) return;
        polling = true;
        unawaited(_pollForTurnEnd(sid, finished, () => done));
      }

      final waitFuture = waitForTurn(sid).then<Object?>((_) => 'wait').catchError(
        (Object e, StackTrace st) {
          startPollFallback();
          return 'wait-unavailable';
        },
      );

      var raced = await Future.any<Object?>([
        upstreamError.future,
        finished.future.then<Object?>((_) => 'turn'),
        waitFuture,
        cancelled.future.then<Object?>((_) => const _Cancelled()),
      ]);
      if (raced is _Cancelled || cancelled.isCompleted) return;

      // wait 秒回但不等于本轮真的结束：会话恰好空闲时 wait 约 3ms 返回，而
      // 提示词还在收件队列里；实验路由消失时同理。此时继续等 SSE/轮询信号，
      // 看门狗保持计时，不收流。
      if ((raced == 'wait' || raced == 'wait-unavailable') &&
          !finished.isCompleted &&
          !upstreamError.isCompleted) {
        startPollFallback();
        raced = await Future.any<Object?>([
          upstreamError.future,
          finished.future.then<Object?>((_) => 'turn'),
          cancelled.future.then<Object?>((_) => const _Cancelled()),
        ]);
        if (raced is _Cancelled || cancelled.isCompleted) return;
      }
      stall?.cancel();

      // 4) 收尾兜底（读消息列表）：
      //    a) v2 额度/传输错误 HTTP 层永远 200，只写进 assistant 消息的
      //       error 字段——必须从列表里把结构化错误解码出来；
      //    b) usage 事件丢失时用终态消息的 tokens 补 lastUsage/缓存；
      //    c) **补齐尾部**：SSE 的最后一帧可能与 execution.succeeded 紧邻到达，
      //       本轮结束信号先到时会漏掉最后一句（实测尾部丢字）。这里用终态
      //       消息的完整文本与已吐文本对账，缺的部分补上。
      // v1 曾把用户消息回显混进答案（"User: reply OKOK"）——v2 的用户消息在
      // 顶层 `text`，这里只读 assistant 的 `content[]`，且只认 type=='text'
      // （reasoning/model-switched/idle 一律不吐）。
      {
        final deadlineAt = DateTime.now().add(completionGrace);
        while (true) {
          final records = await listMessages(sid);
          Map<String, dynamic>? terminal;
          var sawIdle = false;
          var idleFailed = false;
          for (final m in records) {
            final t = m['type'];
            if (t == 'idle') {
              sawIdle = true;
              if (m['outcome'] == 'failed') idleFailed = true;
              continue;
            }
            if (t == 'assistant') {
              final err = m['error'];
              if (err is Map && err.isNotEmpty) {
                throw _decodeUpstreamError(err);
              }
              if (m['finish'] != null || terminal == null) terminal = m;
            }
          }
          final complete =
              terminal != null &&
              (terminal['finish'] != null ||
                  (terminal['content'] is List &&
                      (terminal['content'] as List).isNotEmpty));
          if (sawIdle || complete || sawFailed) {
            if (terminal != null) {
              final tokens = terminal['tokens'];
              // usage 事件可能与结束信号紧邻到达而漏掉 → 用终态消息的
              // tokens 补上，否则记账归零。
              if (tokens is Map && !usageFromEvent) readUsage(tokens);
              // 补齐尾部：SSE 最后一帧可能与结束信号紧邻到达而丢失。
              // 终态消息的文本是**累积全文**，与已吐文本对账后补差量。
              final text = assistantText(terminal);
              if (text != null && text.isNotEmpty) {
                final sent = emittedText.toString();
                if (sent.isEmpty) {
                  progress();
                  emit(text);
                } else if (text.length > sent.length && text.startsWith(sent)) {
                  emit(text.substring(sent.length));
                }
              }
            }
            if (!emittedAny && (idleFailed || sawFailed)) {
              throw OpenCodeUpstreamError(
                message:
                    'opencode v2 回合以失败结束（${idleFailed ? 'idle failed' : 'execution failed'}）',
                statusCode: 502,
              );
            }
            if (!emittedAny) {
              throw const OpenCodeUpstreamError(
                message: 'opencode v2 回合结束但未产生任何回复',
                statusCode: 502,
              );
            }
            break;
          }
          if (!DateTime.now().isBefore(deadlineAt)) {
            if (!emittedAny) {
              throw const OpenCodeUpstreamError(
                message: 'opencode v2 回合结束但未读到本轮回复',
                statusCode: 502,
              );
            }
            break;
          }
          await Future<void>.delayed(waitPollInterval);
        }
      }
      done = true;
      successful = true;
    } catch (e, st) {
      failure = e;
      failureStack = st;
    } finally {
      done = true;
      stall?.cancel();
      deadline?.cancel();
      if (sessionId != null && !successful) {
        await _abortSession(sessionId);
      }
      await sub?.cancel();
      if (sessionId != null) await _deleteSession(sessionId);
      if (failure != null && !ctrl.isClosed && !cancelled.isCompleted) {
        ctrl.addError(failure, failureStack);
      }
      if (!ctrl.isClosed) await ctrl.close();
    }
  }

  /// wait 路由不可用时的兜底：轮询消息列表，出现 `idle` 记录即视为本轮结束。
  Future<void> _pollForTurnEnd(
    String sessionId,
    Completer<void> finished,
    bool Function() isDone,
  ) async {
    while (!finished.isCompleted && !isDone()) {
      try {
        final records = await listMessages(sessionId);
        for (final m in records) {
          if (m['type'] == 'idle') {
            if (!finished.isCompleted) finished.complete();
            return;
          }
        }
      } catch (_) {
        // 轮询失败不打断：停滞看门狗与单轮上限会兜底。
      }
      if (finished.isCompleted || isDone()) return;
      await Future<void>.delayed(waitPollInterval);
    }
  }

  /// assistant 消息 content[] 里 `type=="text"` 段拼出的最终文本。
  static String? assistantText(Map<String, dynamic> msg) {
    final content = msg['content'];
    if (content is! List) return null;
    final parts = content
        .whereType<Map>()
        .where((p) => p['type'] == 'text')
        .map((p) => p['text']?.toString() ?? '')
        .where((s) => s.isNotEmpty);
    final joined = parts.join();
    return joined.isEmpty ? null : joined;
  }

  Future<HttpClientResponse> _send(
    String method,
    String pathAndQuery,
    Object? body, {
    Duration? timeout,
  }) async {
    final uri = Uri.parse('$baseUrl$pathAndQuery');
    final HttpClientRequest req;
    switch (method) {
      case 'POST':
        req = await _client.postUrl(uri);
      case 'GET':
        req = await _client.getUrl(uri);
      case 'DELETE':
        req = await _client.deleteUrl(uri);
      default:
        throw ArgumentError('unsupported method $method');
    }
    _headers.forEach((k, v) => req.headers.set(k, v));
    if (body != null) {
      // 体一律按 utf8 字节写入 + content-type 显式 charset=utf-8：Dart 的
      // write(String) 在无 charset 时按 latin1 编码，提示词含 CJK 即抛
      // "Contains invalid characters"（v1 实测崩溃点，ZCode 提示词必然有
      // 中文，必踩）。
      req.add(utf8.encode(jsonEncode(body)));
    }
    return req.close().timeout(timeout ?? const Duration(seconds: 30));
  }

  static Future<String> _readBody(HttpClientResponse resp) =>
      resp.transform(utf8.decoder).join();

  static Map<String, dynamic> _jsonObject(String body) {
    final j = jsonDecode(body);
    if (j is Map<String, dynamic>) return j;
    if (j is Map) return j.cast<String, dynamic>();
    return const {};
  }

  OpenCodeUpstreamError _httpFailure(String path, int status) {
    if (status == 401) {
      // 绝不把 _authHeader/密码/响应体带进异常文本——上层会把它写进日志
      // 与客户端响应。
      return OpenCodeUpstreamError(
        message: 'opencode v2 $path 认证失败（HTTP 401，服务器密码不匹配）',
        statusCode: 401,
      );
    }
    if (status == 415) {
      return OpenCodeUpstreamError(
        message:
            'opencode v2 $path 拒绝内容类型（HTTP 415，需 application/json; charset=utf-8）',
        statusCode: 415,
      );
    }
    return OpenCodeUpstreamError(
      message: 'opencode v2 $path HTTP $status',
      statusCode: status,
    );
  }

  /// v2 结构化错误 → [OpenCodeUpstreamError] 的 v2 子类。
  /// err 是 assistant 消息的 error 字段（或 session.error 事件的 data）。
  OpenCodeUpstreamError _decodeUpstreamError(Object? err) {
    if (err is! Map) {
      return OpenCodeUpstreamError(
        message: 'opencode v2 上游错误：${err ?? '未知'}',
        statusCode: 502,
      );
    }
    final type = (err['type'] ?? err['name'] ?? err['code'] ?? '')
        .toString()
        .toLowerCase();
    final message = (err['message'] ?? '上游错误').toString();
    final status = (err['status'] as num?)?.toInt();
    final retryAfterMs = (err['retryAfterMs'] as num?)?.toInt();
    // 主代理读 api.retryAfterSeconds 即可，无需判型错误对象。向上取整，
    // 宁可多睡一秒也别提前撞限流；上游没给就不设。
    if (retryAfterMs != null && retryAfterMs > 0) {
      lastRetryAfterSeconds = (retryAfterMs / 1000).ceil();
    }
    final response = err['response'];
    final respBody = response is Map ? (response['body'] ?? '').toString() : '';
    return OpenCodeUpstreamV2Error(
      message: message,
      statusCode: status,
      errorType: type.isEmpty ? null : type,
      retryAfterMs: retryAfterMs,
      responseBody: respBody.isEmpty ? null : respBody,
    );
  }

  /// 回合结束后删除会话（每请求一个会话，无状态翻译；与 v1 同形，
  /// 失败不替换生成结果）。
  Future<void> _deleteSession(String sessionId) async {
    final cleanup = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await cleanup.deleteUrl(
        Uri.parse('$baseUrl$_sessionPath/$sessionId'),
      );
      req.headers.set('authorization', _authHeader);
      final resp = await req.close().timeout(const Duration(seconds: 2));
      await resp.drain<void>().timeout(const Duration(seconds: 2));
    } catch (_) {
      // 清理失败不得替换生成结果。
    } finally {
      cleanup.close(force: true);
    }
  }

  /// 失败/取消时请求 CLI 停止本轮（端点未在 v2 实测清单内，尽力而为；
  /// 失败绝不替换生成结果）。
  Future<void> _abortSession(String sessionId) async {
    final cleanup = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await cleanup.postUrl(
        Uri.parse('$baseUrl$_sessionPath/$sessionId/interrupt'),
      );
      req.headers.set('authorization', _authHeader);
      final resp = await req.close().timeout(const Duration(seconds: 2));
      await resp.drain<void>().timeout(const Duration(seconds: 2));
      onActivity?.call('已请求 v2 CLI 停止本轮');
    } catch (_) {
      // 清理失败不得替换生成结果。
    } finally {
      cleanup.close(force: true);
    }
  }

  /// 版本探测：v2 上 v1 端点返回 **200 + SPA HTML**（不是 404），判据只能是
  /// `GET /api/info` 返回可解析、含 `version` 的 JSON。解析不了/非 200 → 当 v1。
  ///
  /// 入参命名 password（主代理接线约定）。**401 不视为失败**：serve 要求
  /// 鉴权恰恰说明它是 v2（v1 无 Basic），此时返回 [OpenCodeV2Probe.passwordRequired]，
  /// 由主代理决定补密码。返回 v2 即同时验证了密码可用（200+JSON）。
  static Future<OpenCodeV2Probe> probe(
    String baseUrl, {
    String? password,
    HttpClient? client,
  }) async {
    final ownClient = client == null;
    final c =
        client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 5));
    try {
      final req = await c.getUrl(Uri.parse('$baseUrl/api/info'));
      if (password != null) {
        req.headers.set('authorization', _basic(password));
      }
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        // 需要鉴权的 v2 serve（密码缺失或不匹配都到不了这里之后半段）。
        return OpenCodeV2Probe.passwordRequired;
      }
      if (resp.statusCode != 200) return OpenCodeV2Probe.notV2;
      try {
        final j = jsonDecode(body);
        return j is Map && j.containsKey('version')
            ? OpenCodeV2Probe.v2
            : OpenCodeV2Probe.notV2;
      } catch (_) {
        // SPA HTML 也是 200——解析不了 JSON 就当 v1。
        return OpenCodeV2Probe.notV2;
      }
    } catch (_) {
      return OpenCodeV2Probe.notV2;
    } finally {
      if (ownClient) c.close(force: true);
    }
  }

  /// v2 模型清单：GET /api/model。与 v1 [OpenCodeApi.freeModels] 同形：
  /// 只回免费档（内置 big-pickle 或 id 含 -free——付费 id 上游免费门会拒），
  /// 失败返回空表、不抛。
  static Future<List<String>> freeModels(
    String baseUrl,
    HttpClient client, {
    String password = '',
  }) async {
    try {
      final req = await client.getUrl(Uri.parse('$baseUrl/api/model'));
      req.headers.set('authorization', _basic(password));
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) return const [];
      final body = await resp.transform(utf8.decoder).join();
      final j = jsonDecode(body);
      final list = j is Map ? (j['data'] ?? j['models']) : j;
      final out = <String>{};
      void collect(Object? e) {
        if (e is Map) {
          final id = e['id'] ?? e['modelID'];
          // 主代理接线约定：只回免费档（内置 big-pickle 或含 -free）。
          if (id is String &&
              id.isNotEmpty &&
              (id == 'big-pickle' || id.contains('-free'))) {
            out.add(id);
          }
        }
      }

      if (list is List) {
        list.forEach(collect);
      } else if (list is Map) {
        list.values.forEach(collect);
      }
      return out.toList()..sort();
    } catch (_) {
      return const [];
    }
  }

  static String _basic(String password) =>
      'Basic ${base64.encode(utf8.encode('opencode:$password'))}';

  @override
  void close() {
    for (final cancel in _cancellations.toList()) {
      cancel();
    }
    _client.close(force: true);
  }
}

/// v2 错误的结构化包装：复用 v1 [OpenCodeUpstreamError] 的 message/statusCode
/// 与文案判定（isStall 等），叠加 v2 独有的 `error.type` 集合判定与
/// `retryAfterMs` 退避语义。
///
/// 主代理接线：proxy.dart 现有 `e is OpenCodeUpstreamError` 分支直接命中本类
/// （isQuotaExhausted/isConnectionFailure 已按 v2 结构覆写）；需要冷却时长时
/// **判型读取**：
///   final wait = e is OpenCodeUpstreamV2Error ? e.retryAfter : null;
/// 不往 v1 类的 message 里塞标记文案——isConnectionFailure 用子串匹配
/// message，塞词会污染 v1 的判定语义。
class OpenCodeUpstreamV2Error extends OpenCodeUpstreamError {
  const OpenCodeUpstreamV2Error({
    required super.message,
    super.statusCode,
    super.stalled,
    this.errorType,
    this.retryAfterMs,
    this.responseBody,
  });

  /// v2 assistant 消息 error.type（小写化），如 provider.free-limit、
  /// provider.transport。null 表示 v2 未给出结构化类型。
  final String? errorType;

  /// 上游给的退避时长（毫秒）。null 表示上游没提供——**绝不瞎猜冷却时间**。
  final int? retryAfterMs;

  /// error.response.body 原文（内层常是 {"type":"error","error":{...}} 的
  /// 上游 JSON），用于兜底判型。
  final String? responseBody;

  /// v2 额度耗尽的**结构化**类型集合：只命中这些才判「额度烧穿」。
  /// 不能只看 429——降级期上游也会回 429（实测误报）。
  static const Set<String> quotaTypes = {
    'provider.free-limit',
    'provider.quota',
    'insufficient_quota',
    'quota_exceeded',
    'freeusagelimiterror',
  };

  /// **上游过载**（推理服务侧容量不足）的结构化类型：provider.rate-limit。
  ///
  /// 这类错误**换出口没用**——所有出口最终都打同一个推理服务；CLI 内部
  /// 退避重试（实测 3 次 / ~30s）后放弃。此时若再换出口轮换，只会在每个
  /// 死路上白等一轮 90s 看门狗（用户实测「一个你好两分钟没反应」）。
  /// 正确做法：如实报「上游过载，稍后重试」。
  static const Set<String> overloadedTypes = {
    'provider.rate-limit',
    'provider.overloaded',
    'overloaded',
  };

  @override
  bool get isUpstreamOverloaded {
    final t = (errorType ?? '').toLowerCase();
    if (overloadedTypes.contains(t)) return true;
    final raw = responseBody;
    if (raw != null && raw.toLowerCase().contains('overloaded')) return true;
    return super.isUpstreamOverloaded; // 兜底：文案判定
  }

  static bool _quotaType(Object? s) =>
      s != null && quotaTypes.contains(s.toString().toLowerCase());

  /// error.response.body 的嵌套 JSON 里再找一轮类型（type/code/error.type/
  /// error.code/error.name），任一命中额度集合即算。
  bool get _nestedQuota {
    final raw = responseBody;
    if (raw == null || raw.isEmpty) return false;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return false;
      final inner = j['error'] is Map ? j['error'] as Map : const {};
      return _quotaType(j['type']) ||
          _quotaType(j['code']) ||
          _quotaType(inner['type']) ||
          _quotaType(inner['code']) ||
          _quotaType(inner['name']);
    } catch (_) {
      // response.body 可能不是 JSON（HTML 错误页等）：只认字面错误类名。
      return raw.toLowerCase().contains('freeusagelimiterror');
    }
  }

  @override
  bool get isQuotaExhausted =>
      _quotaType(errorType) ||
      Zen.isQuotaExhausted(message) ||
      _nestedQuota;

  @override
  bool get isConnectionFailure =>
      errorType == 'provider.transport' || super.isConnectionFailure;

  /// 传输错误不是额度：即使文案碰巧带 "quota" 字样也不该烧穿出口标记。
  @override
  bool get isStall => !isConnectionFailure && super.isStall;

  /// Retry-After 语义（主代理读这里）：上游明确给了才回，没给就是 null。
  Duration? get retryAfter {
    final ms = retryAfterMs;
    return ms == null ? null : Duration(milliseconds: ms);
  }

  @override
  String toString() => message;
}

/// 内部哨兵：Future.any 里表示「调用方取消了流」。
class _Cancelled {
  const _Cancelled();
}

/// [OpenCodeApiV2.probe] 的三态结果。
enum OpenCodeV2Probe {
  /// `GET /api/info` 返回了含 `version` 的 JSON —— 确认是 v2（密码也对）。
  v2,

  /// `GET /api/info` 返回 401/403 —— serve 要求鉴权，这是 v2 的行为
  /// （v1 的 /global/health 无 Basic）。不是失败：主代理补密码后重探即可。
  passwordRequired,

  /// 不是 v2：v1 端点（返回 200 + SPA HTML 解析不出 JSON）、非 200、
  /// 连不通等。按 v1 适配器处理。
  notV2;

  bool get isV2 => this == v2;
}
