import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'opencode_serve.dart';
import 'zen.dart';

/// opencode serve 原生协议的客户端 + OpenAI/Anthropic 翻译层。
///
/// serve 的接口（2026-10-26 实测，opencode-ai 1.19.3）：
///   POST /session                          → {id}
///   GET  /event                            → SSE（message.part.updated 等）
///   POST /session/{id}/message             → 同步返回完整 assistant 消息
///   GET  /config/providers                 → provider 与模型清单
///   GET  /global/health                    → {"healthy":true,"version":"1.19.3"}
///
/// 实测要点：
///   * 设了 OPENCODE_SERVER_PASSWORD 时 POST message 会挂住不返回——
///     本机回环 + 隔离 HOME 已够，故不设密码（见 opencode.dart 的 env）。
///   * message.part.updated 的 text part 是「累积快照」：同一 id 多次推送，
///     后一次包含前一次全部内容。翻译成 OpenAI 增量时按 diff 取新增片段。
///   * 同步返回的 message.parts[] 含 step-start / text / step-finish，
///     text part 即最终答案；finish 字段为 stop / tool-calls / length 等。
class OpenCodeApi implements OpenCodeServeApi {
  OpenCodeApi(this.baseUrl, {HttpClient? client})
    : _client = client ?? HttpClient() {
    // SSE 事件流是长连接：模型思考期间可能几十秒无数据，Dart 默认
    // idleTimeout=15s 会把连接掐断（表现为流中途断、客户端只拿到半截）。
    // 放宽到 2 小时，与网关侧流式请求的上限对齐。
    _client.idleTimeout = const Duration(hours: 2);
    _client.connectionTimeout = const Duration(seconds: 30);
  }

  final String baseUrl;
  final HttpClient _client;

  /// retry 事件回调（可选）：CLI 重试上游失败时通知（网关记日志用）。
  static void Function(String message)? onRetryEvent;
  @override
  void Function(String message)? onRetry;

  /// 首次有效输出的等待窗口，不是整轮生成的时间上限。
  static Duration stallTimeout = const Duration(minutes: 3);

  /// 已开始输出/思考后，每次有效进展重置这个窗口。
  static Duration generationIdleTimeout = const Duration(minutes: 10);
  static Duration requestTimeout = const Duration(hours: 2);
  static Duration completionGrace = const Duration(seconds: 2);
  @override
  void Function(String message)? onActivity;
  final _cancellations = <void Function()>{};
  @override
  bool generationStarted = false;

  /// 最近一轮的真实 token 用量（serve 的 info.tokens）；流完成前读到 0。
  @override
  ({int input, int output}) lastUsage = (input: 0, output: 0);
  @override
  int cachedReadTokens = 0;
  @override
  int cachedWriteTokens = 0;

  /// v1 上游不回报重试时机（只有文案），恒 null——网关按「换出口」而非
  /// 「等到几点」处理 v1 的额度错误。
  @override
  int? get retryAfterSeconds => null;

  static const _model = {'providerID': 'opencode'};

  Map<String, String> get _headers => const {
    'content-type': 'application/json',
    'accept': 'application/json',
  };

  /// 建一个会话。ZeroApi 每次客户端请求建一个新会话（无状态翻译，
  /// 多轮上下文由客户端传来的 messages 数组承载——见 [chatCompletions]）。
  Future<String> createSession() async {
    final req = await _client.postUrl(Uri.parse('$baseUrl/session'));
    _headers.forEach((k, v) => req.headers.set(k, v));
    // 中转层不应再执行一套 agent 工具，更不能等待无人可见的权限弹窗。
    req.add(
      utf8.encode(
        jsonEncode({
          'permission': [
            {'permission': '*', 'pattern': '*', 'action': 'deny'},
          ],
        }),
      ),
    );
    final resp = await req.close().timeout(const Duration(seconds: 30));
    final body = await resp.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw HttpException('opencode /session HTTP ${resp.statusCode}: $body');
    }
    final j = jsonDecode(body) as Map<String, dynamic>;
    return j['id'] as String;
  }

  /// 发一轮对话，流式回传文本增量。
  ///
  /// [messages] 是 OpenAI 形态的消息数组；[system] 为系统提示（Anthropic 形态
  /// 单独传入时由调用方合并进 messages）。
  /// 返回的 Stream 元素是文本增量片段；完成时正常结束。
  /// 出错时 Stream 抛异常（由上层转成客户端可见的错误）。
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
      _run(
        model,
        messages,
        maxTokens,
        ctrl,
        cancelled,
      ).whenComplete(() => _cancellations.remove(cancel)),
    );
    return ctrl.stream;
  }

  Future<void> _run(
    String model,
    List<Map<String, dynamic>> messages,
    int? maxTokens,
    StreamController<String> ctrl,
    Completer<void> cancelled,
  ) async {
    HttpClientResponse? eventResp;
    StreamSubscription<String>? sub;
    Timer? stall;
    Timer? deadline;
    HttpClientRequest? msgReq;
    String? sessionId;
    var successful = false;
    var done = false;
    Object? failure;
    StackTrace? failureStack;
    try {
      final sid = await createSession();
      sessionId = sid;
      // 1) 先订阅事件流，再发消息——否则可能错过开头增量
      final evReq = await _client.getUrl(Uri.parse('$baseUrl/event'));
      eventResp = await evReq.close().timeout(const Duration(seconds: 30));

      final lastText = <String, String>{};
      var responseParts = const <dynamic>[];
      final partTypes = <String, String>{};
      // 本轮 assistant 消息的 id 集合（serve 会回显用户消息的 part，需过滤）
      final assistantMsgIds = <String>{};
      final finished = Completer<void>();
      // 错误可能在无人监听时发生（Future.any 先胜出、消费者已关流），
      // 不加 ignore 会变成 unhandled async error 把用例/请求搞崩
      finished.future.ignore();
      // 上游错误事件（session.error）：CLI 内部会重试若干次才返回，
      // 等它重试完再报错会让客户端干等数分钟——错误一到就立刻如实抛出
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
          fail(
            OpenCodeUpstreamError(
              message: hasProgress
                  ? 'opencode CLI 已开始生成，但连续 ${timeout.inSeconds}s 无有效进展，正在停止本轮'
                  : 'opencode CLI ${timeout.inSeconds}s 无任何响应（未收到模型有效输出），正在停止本轮',
              statusCode: 504,
              stalled: true,
            ),
          );
        });
      }

      void progress() {
        if (!hasProgress) onActivity?.call('已收到模型输出或思考，切换为生成空闲超时');
        hasProgress = true;
        generationStarted = true;
        armStall();
      }

      void snapshot(Map part) {
        final id = part['id'] as String? ?? '';
        final kind = part['type'] as String? ?? '';
        final mid = part['messageID'] as String?;
        if (mid != null && !assistantMsgIds.contains(mid)) return;
        partTypes[id] = kind;
        if (kind != 'text' && kind != 'reasoning') return;
        final text = (part['text'] ?? '') as String;
        final prev = lastText[id] ?? '';
        if (text.length <= prev.length || !text.startsWith(prev)) return;
        lastText[id] = text;
        progress();
        if (kind == 'text' && !ctrl.isClosed && !cancelled.isCompleted) {
          ctrl.add(text.substring(prev.length));
        }
      }

      deadline = Timer(
        requestTimeout,
        () => fail(
          const OpenCodeUpstreamError(
            message: 'opencode CLI 达到单轮安全上限，正在停止本轮',
            statusCode: 504,
          ),
        ),
      );

      sub = eventResp
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (done) return;
              if (!line.startsWith('data:')) return;
              Map<String, dynamic> j;
              try {
                j = jsonDecode(line.substring(5)) as Map<String, dynamic>;
              } catch (_) {
                return;
              }
              final type = j['type'];
              final props =
                  (j['properties'] ?? const <String, dynamic>{})
                      as Map<String, dynamic>;
              final eventSession =
                  props['sessionID'] ??
                  (props['info'] is Map
                      ? (props['info'] as Map)['sessionID']
                      : null) ??
                  (props['part'] is Map
                      ? (props['part'] as Map)['sessionID']
                      : null);
              if (eventSession != sid) return;
              // 心跳只证明 serve 进程活着，不代表本轮有进展——不刷新看门狗：
              // serve 每 10s 推一个 heartbeat，若照单全收，上游真 hang 时
              // 看门狗永远不触发（实测挂 7 分钟无任何报错就是这么来的）。
              if (type == 'server.heartbeat') return;
              if (type == 'permission.asked' ||
                  type == 'permission.v2.asked' ||
                  type == 'question.asked' ||
                  type == 'question.v2.asked') {
                fail(
                  const OpenCodeUpstreamError(
                    message: '中转 CLI 意外进入工具权限/提问等待，已请求停止；工具应由调用客户端执行',
                    statusCode: 502,
                  ),
                );
                return;
              }

              if (type == 'session.error') {
                final err =
                    (props['error'] ?? const <String, dynamic>{})
                        as Map<String, dynamic>;
                final data =
                    (err['data'] ?? const <String, dynamic>{})
                        as Map<String, dynamic>;
                final e = OpenCodeUpstreamError(
                  message: (data['message'] ?? err['name'] ?? '上游错误')
                      .toString(),
                  statusCode:
                      (data['statusCode'] as int?) ??
                      (err['statusCode'] as int?),
                );
                if (!upstreamError.isCompleted) upstreamError.completeError(e);
                if (!finished.isCompleted) finished.completeError(e);
                return;
              }
              // 追踪 assistant 消息 id：serve 会把「用户消息的回显 part」也推到
              // 事件流里（messageID 属于用户消息），不过滤会把客户端的输入原样
              // 转发回去、混进答案里（实测输出变成 "User: xxxOK"）。
              // message.updated(role=assistant) 一定先于它的 part 事件到达。
              if (type == 'message.updated') {
                final info =
                    (props['info'] ?? const <String, dynamic>{})
                        as Map<String, dynamic>;
                if (info['role'] == 'assistant') {
                  final mid = info['id'] as String?;
                  if (mid != null) assistantMsgIds.add(mid);
                  _readUsage(info);
                }
                return;
              }
              if (type == 'message.part.updated') {
                final part =
                    (props['part'] ?? const <String, dynamic>{})
                        as Map<String, dynamic>;
                snapshot(part);
                return;
              }
              if (type == 'message.part.delta') {
                if (!assistantMsgIds.contains(props['messageID'])) return;
                if (props['field'] != 'text') return;
                final id = props['partID'] as String? ?? '';
                final kind = partTypes[id];
                final delta = props['delta'] as String? ?? '';
                if (delta.isEmpty || (kind != 'text' && kind != 'reasoning')) {
                  return;
                }
                lastText[id] = '${lastText[id] ?? ''}$delta';
                progress();
                if (kind == 'text' &&
                    !ctrl.isClosed &&
                    !cancelled.isCompleted) {
                  ctrl.add(delta);
                }
                return;
              }
              // 会话回到 idle = 本轮结束
              if (type == 'session.status') {
                final st =
                    (props['status'] ?? const <String, dynamic>{})
                        as Map<String, dynamic>;
                // CLI 的上游软失败以 status.type='retry' 呈现，**分两类，处理
                // 必须不同**（2026-10-31 的“见 retry 就掐死”把两类一起杀了，
                // 2026-11-04 实测证明那是误杀）：
                //  · 额度（"Free usage exceeded…"）：CLI 自带退避重试，同一出口
                //    常在 17~71s 后成功（实测）。这里**绝不**中止，只记日志；
                //    久等无输出由停滞看门狗/单轮上限兜底后再换出口。
                //  · 连不通（"Cannot connect to API"等）：该出口到不了上游，
                //    CLI 走同一代理重试永远不会好，早停早换（不烧额度标记）。
                if (st['type'] == 'retry') {
                  final msg = (st['message'] ?? '').toString();
                  if (msg.isEmpty) return;
                  (onRetry ?? onRetryEvent)?.call(msg);
                  if (!Zen.isQuotaExhausted(msg)) {
                    final conn = OpenCodeUpstreamError(
                      message: msg,
                      statusCode: 502,
                    );
                    if (conn.isConnectionFailure) {
                      if (!upstreamError.isCompleted) {
                        upstreamError.completeError(conn);
                      }
                      if (!finished.isCompleted) finished.completeError(conn);
                    }
                  }
                  return;
                }
                if (st['type'] == 'idle' && !finished.isCompleted) {
                  finished.complete();
                }
              }
              if (type == 'session.idle' && !finished.isCompleted) {
                finished.complete();
              }
            },
            onError: (Object e) {
              fail(e);
            },
          );

      // 2) 发消息。CLI 内部会对失败重试若干次（实测无效 key 重试 3 次要
      // 69 秒），所以「等 message 响应」与「等上游错误事件」要竞速：
      // session.error 一到就立刻如实报错，不让客户端干等重试结束。
      final disabledTools = await _disabledTools();
      if (cancelled.isCompleted) return;
      msgReq = await _client.postUrl(
        Uri.parse('$baseUrl/session/$sid/message'),
      );
      // content-type 必须带 charset=utf-8：Dart 的 HttpRequest.write(String)
      // 在无 charset 时按 latin1 编码，系统提示/用户输入含 CJK 即抛
      // "Contains invalid characters"（ZCode 的提示词必然有中文，必踩）。
      // 体一律按 utf8 字节写入，不走 write(String)。
      msgReq.headers.set('content-type', 'application/json; charset=utf-8');
      msgReq.add(
        utf8.encode(
          jsonEncode({
            'model': {..._model, 'modelID': model},
            'tools': disabledTools,
            'parts': [
              {'type': 'text', 'text': _flattenMessages(messages)},
            ],
          }),
        ),
      );
      armStall();
      final msgFuture = msgReq.close().timeout(requestTimeout);
      final responseFuture = msgFuture.then((r) async {
        final body = await r.transform(utf8.decoder).join();
        if (done) return 200;
        if (r.statusCode != 200) {
          throw HttpException('opencode message HTTP ${r.statusCode}');
        }
        final j = jsonDecode(body) as Map<String, dynamic>;
        final info =
            (j['info'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
        final err = info['error'];
        if (err is Map) {
          final data =
              (err['data'] ?? const <String, dynamic>{})
                  as Map<String, dynamic>;
          throw OpenCodeUpstreamError(
            message: (data['message'] ?? err['name'] ?? '上游错误').toString(),
            statusCode: data['statusCode'] as int?,
          );
        }
        _readUsage(info);
        responseParts = j['parts'] as List? ?? const [];
        return r.statusCode;
      });
      final status = await Future.any<Object>([
        upstreamError.future, // 出错即抛（completeError）
        responseFuture,
        // idle 是本轮已结束的明确信号；同步 HTTP 返回丢失不能再空等两小时。
        finished.future.then(
          (_) => responseFuture.timeout(completionGrace, onTimeout: () => 200),
        ),
        cancelled.future.then((_) => -1),
      ]);
      if (cancelled.isCompleted) return;
      if (status != 200) {
        throw HttpException('opencode message HTTP $status');
      }
      stall?.cancel();
      deadline.cancel();
      // 3) 等事件流自然结束（idle）或短暂兜底
      await finished.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      for (final part in responseParts) {
        if (part is Map && (part['id'] != null || lastText.isEmpty)) {
          snapshot(part);
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
      // Future.timeout 不会取消网络请求；必须同时停止 CLI 任务与本地 HTTP。
      if (sessionId != null && !successful) {
        await _sessionRequest(sessionId, abort: true);
      }
      msgReq?.abort();
      await sub?.cancel();
      if (sessionId != null) await _deleteSession(sessionId);
      if (failure != null && !ctrl.isClosed && !cancelled.isCompleted) {
        ctrl.addError(failure, failureStack);
      }
      if (!ctrl.isClosed) await ctrl.close();
    }
  }

  Future<void> _deleteSession(String id) async {
    await _sessionRequest(id);
  }

  Future<Map<String, bool>> _disabledTools() async {
    final tools = <String, bool>{
      for (final id in [
        'invalid',
        'question',
        'bash',
        'read',
        'glob',
        'grep',
        'edit',
        'write',
        'task',
        'webfetch',
        'todowrite',
        'websearch',
        'skill',
        'apply_patch',
        'list',
        'patch',
        'lsp',
      ])
        id: false,
    };
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(
        Uri.parse('$baseUrl/experimental/tool/ids'),
      );
      final resp = await req.close().timeout(const Duration(seconds: 2));
      final raw = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode == 200) {
        final ids = jsonDecode(raw);
        if (ids is List) {
          for (final id in ids.whereType<String>()) {
            tools[id] = false;
          }
        }
      }
    } catch (_) {
      // 旧版 CLI 无此目录时保留已知工具列表，session 权限另有 deny 兜底。
    } finally {
      client.close(force: true);
    }
    return tools;
  }

  void _readUsage(Map info) {
    if (info['tokens'] is! Map) return;
    final tokens = info['tokens'] as Map;
    final cache = tokens['cache'] is Map ? tokens['cache'] as Map : const {};
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

  Future<void> _sessionRequest(String id, {bool abort = false}) async {
    final cleanup = HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);
    try {
      final uri = Uri.parse('$baseUrl/session/$id${abort ? '/abort' : ''}');
      final req = await (abort ? cleanup.postUrl(uri) : cleanup.deleteUrl(uri));
      final response = await req.close().timeout(const Duration(seconds: 2));
      await response.drain<void>().timeout(const Duration(seconds: 2));
      if (abort && response.statusCode == 200) onActivity?.call('CLI 已确认停止本轮');
    } catch (_) {
      // Cleanup failure must not replace the generation result.
    } finally {
      cleanup.close(force: true);
    }
  }

  /// 对外暴露的消息扁平化（OpenAI messages → opencode 单文本 part）。
  static String chatMessages(List<Map<String, dynamic>> messages) =>
      _flattenMessages(messages);

  /// 把 OpenAI messages 数组压成一段纯文本（opencode 的 text part 只接受
  /// 单串；多轮上下文靠这段文本传递）。按 role 标注，避免模型混淆发言者。
  static String _flattenMessages(List<Map<String, dynamic>> messages) {
    final sb = StringBuffer();
    for (final m in messages) {
      final role = (m['role'] ?? 'user').toString();
      var content = m['content'];
      if (content is List) {
        // OpenAI 多模态 content 数组：只取 text 段
        final parts = content
            .whereType<Map>()
            .where((p) => p['type'] == 'text')
            .map((p) => p['text']?.toString() ?? '')
            .where((s) => s.isNotEmpty);
        content = parts.join('\n');
      }
      final text = (content ?? '').toString();
      if (text.isEmpty) continue;
      if (role == 'system') {
        sb.write('$text\n\n');
      } else if (role == 'assistant') {
        sb.write('Assistant: $text\n\n');
      } else {
        sb.write('User: $text\n\n');
      }
    }
    final out = sb.toString().trim();
    return out.isEmpty ? 'hi' : out;
  }

  /// 模型清单：/config/providers 里 opencode provider 的免费档。
  static Future<List<String>> freeModels(
    String baseUrl,
    HttpClient client,
  ) async {
    final req = await client.getUrl(Uri.parse('$baseUrl/config/providers'));
    const hdrs = {
      'content-type': 'application/json',
      'accept': 'application/json',
    };
    hdrs.forEach((k, v) => req.headers.set(k, v));
    final resp = await req.close().timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) return const [];
    final j = jsonDecode(
      await resp.transform(utf8.decoder).join(),
    ) as Map<String, dynamic>;
    final providers = (j['providers'] ?? const []) as List;
    for (final p in providers) {
      if (p is! Map || p['id'] != 'opencode') continue;
      final models = (p['models'] ?? const {}) as Map;
      final ids =
          models.keys
              .whereType<String>()
              .where((k) => k == 'big-pickle' || k.contains('-free'))
              .toList()
            ..sort();
      return ids;
    }
    return const [];
  }

  @override
  void close() {
    for (final cancel in _cancellations.toList()) {
      cancel();
    }
    _client.close(force: true);
  }
}

/// 上游错误（opencode serve 的 session.error / message.info.error）：
/// 带上游原文与状态码，网关据此如实回报客户端（429 额度、401 凭证…）。
class OpenCodeUpstreamError implements Exception {
  final String message;
  final int? statusCode;
  final bool stalled;
  const OpenCodeUpstreamError({
    required this.message,
    this.statusCode,
    this.stalled = false,
  });

  /// 上游文案里常见的额度耗尽关键词——命中时网关回 429 rate_limit_exceeded，
  /// 免得客户端把「额度用完」当成认证失败。判定统一走 [Zen.isQuotaExhausted]
  /// （两处文案：补全的 "Free usage limit reached"、重试事件的
  /// "Free usage exceeded"），别在这里再维护一份。
  bool get isQuotaExhausted => Zen.isQuotaExhausted(message);

  /// 上游连不通（出口坏了 / 目标站不可达 / DNS 失败）。
  ///
  /// 与额度耗尽要分开处理：额度是「这个出口今天用完了」，换出口有意义；
  /// 连不通是「这个出口根本到不了 API」，同样要换出口，但不该记成额度烧穿。
  bool get isConnectionFailure {
    final m = message.toLowerCase();
    return m.contains('cannot connect') ||
        m.contains('unable to connect') ||
        m.contains('econnrefused') ||
        m.contains('enotfound') ||
        m.contains('econnreset') ||
        m.contains('fetch failed') ||
        m.contains('network error') ||
        m.contains('unable to access');
  }

  /// 本轮没有任何进展被看门狗中止（出口连不通时 CLI 会一直挂着）。
  /// 与连接失败同等处理：换出口再试一次。
  bool get isStall =>
      stalled || message.contains('无任何响应') || message.contains('已中止本轮');

  @override
  String toString() => message;
}

/// 当前没有可用出口（代理组无可用节点，或出口连不通）。
/// 网关据此快速失败，不再让客户端空等看门狗。
class ZenExitUnavailable implements Exception {
  final String message;
  const ZenExitUnavailable(this.message);
  @override
  String toString() => message;
}

/// 整池免费额度烧穿（所有出口都报 free-limit）。与 [ZenExitUnavailable] 的
/// 区别：这是**有时限的已知状态**（retryAfter 指向重置点），调用方应快速
/// 返回 429 并附恢复时刻，而不是 502，更不该再走 6 轮轮换白等 2 分钟。
class ZenQuotaExhausted implements Exception {
  final String message;

  /// 预计恢复时刻（本地时区）。
  final DateTime until;
  const ZenQuotaExhausted(this.message, this.until);
  @override
  String toString() => message;
}
