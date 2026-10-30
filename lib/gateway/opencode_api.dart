import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
class OpenCodeApi {
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

  /// 最近一轮的真实 token 用量（serve 的 info.tokens）；流完成前读到 0。
  ({int input, int output}) lastUsage = (input: 0, output: 0);

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
    req.write('{}');
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
  Stream<String> chat({
    required String model,
    required List<Map<String, dynamic>> messages,
    int? maxTokens,
  }) {
    final ctrl = StreamController<String>();
    _run(model, messages, maxTokens, ctrl);
    return ctrl.stream;
  }

  Future<void> _run(
    String model,
    List<Map<String, dynamic>> messages,
    int? maxTokens,
    StreamController<String> ctrl,
  ) async {
    HttpClientResponse? eventResp;
    StreamSubscription<String>? sub;
    try {
      final sid = await createSession();
      // 1) 先订阅事件流，再发消息——否则可能错过开头增量
      final evReq = await _client.getUrl(Uri.parse('$baseUrl/event'));
      eventResp = await evReq.close().timeout(const Duration(seconds: 30));

      final lastText = <String, String>{};
      // 本轮 assistant 消息的 id 集合（serve 会回显用户消息的 part，需过滤）
      final assistantMsgIds = <String>{};
      var done = false;
      final finished = Completer<void>();
      // 错误可能在无人监听时发生（Future.any 先胜出、消费者已关流），
      // 不加 ignore 会变成 unhandled async error 把用例/请求搞崩
      finished.future.ignore();
      // 上游错误事件（session.error）：CLI 内部会重试若干次才返回，
      // 等它重试完再报错会让客户端干等数分钟——错误一到就立刻如实抛出
      final upstreamError = Completer<Object>();

      sub = eventResp
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (done) return;
        if (!line.startsWith('data:')) return;
        Map<String, dynamic> j;
        try {
          j = jsonDecode(line.substring(5)) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        final type = j['type'];
        final props = (j['properties'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
        if (props['sessionID'] != null && props['sessionID'] != sid) return;

        if (type == 'session.error') {
          final err = (props['error'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
          final data = (err['data'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
          final e = OpenCodeUpstreamError(
            message: (data['message'] ?? err['name'] ?? '上游错误').toString(),
            statusCode: (data['statusCode'] as int?) ??
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
              (props['info'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
          if (info['role'] == 'assistant') {
            final mid = info['id'] as String?;
            if (mid != null) assistantMsgIds.add(mid);
          }
          return;
        }
        if (type == 'message.part.updated') {
          final part = (props['part'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
          if (part['type'] != 'text') return;
          final mid = part['messageID'] as String?;
          // 只转发 assistant 消息的文本；用户消息的回显 part 跳过
          // （messageID 缺失的旧事件保守放行）
          if (mid != null && !assistantMsgIds.contains(mid)) return;
          final id = part['id'] as String? ?? '';
          final text = (part['text'] ?? '') as String;
          final prev = lastText[id] ?? '';
          if (text.length > prev.length && text.startsWith(prev)) {
            lastText[id] = text;
            if (!ctrl.isClosed) ctrl.add(text.substring(prev.length));
          }
          return;
        }
        // 会话回到 idle = 本轮结束
        if (type == 'session.status') {
          final st = (props['status'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
          // 额度耗尽时 CLI 发的是 status.type='retry'（message 里带
          // "Free usage exceeded, subscri…"），不是 session.error；而且
          // 它会一直重试下去、message 端点永不返回（实测 100s+ 不返回）。
          // 识别出来立即报错，别让客户端干等。
          if (st['type'] == 'retry') {
            final msg = (st['message'] ?? '').toString();
            if (msg.isNotEmpty && Zen.isQuotaExhausted(msg)) {
              final e = OpenCodeUpstreamError(message: msg, statusCode: 429);
              if (!upstreamError.isCompleted) upstreamError.completeError(e);
              if (!finished.isCompleted) finished.completeError(e);
              return;
            }
          }
          if (st['type'] == 'idle' && !finished.isCompleted) {
            finished.complete();
          }
        }
        if (type == 'session.idle' && !finished.isCompleted) finished.complete();
      }, onError: (Object e) {
        if (!finished.isCompleted) finished.completeError(e);
      });

      // 2) 发消息。CLI 内部会对失败重试若干次（实测无效 key 重试 3 次要
      // 69 秒），所以「等 message 响应」与「等上游错误事件」要竞速：
      // session.error 一到就立刻如实报错，不让客户端干等重试结束。
      final msgReq = await _client.postUrl(
          Uri.parse('$baseUrl/session/$sid/message'));
      _headers.forEach((k, v) => msgReq.headers.set(k, v));
      msgReq.write(jsonEncode({
        'model': {..._model, 'modelID': model},
        'parts': [
          {
            'type': 'text',
            'text': _flattenMessages(messages),
          }
        ],
      }));
      final msgFuture = msgReq.close().timeout(const Duration(hours: 2));
      final status = await Future.any<Object>([
        upstreamError.future, // 出错即抛（completeError）
        msgFuture.then((r) async {
          final body = await r.transform(utf8.decoder).join();
          if (r.statusCode != 200) {
            throw HttpException('opencode message HTTP ${r.statusCode}');
          }
          // 同步返回体里也可能带 error（上游失败但 HTTP 200）
          final j = jsonDecode(body) as Map<String, dynamic>;
          final info = (j['info'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
          final err = info['error'];
          if (err is Map) {
            final data = (err['data'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
            throw OpenCodeUpstreamError(
              message: (data['message'] ?? err['name'] ?? '上游错误').toString(),
              statusCode: data['statusCode'] as int?,
            );
          }
          // 记账：serve 返回真实 token 数（info.tokens.{input,output}）
          final tokens = (info['tokens'] ?? const <String, dynamic>{}) as Map<String, dynamic>;
          lastUsage = (
            input: (tokens['input'] as num?)?.toInt() ?? 0,
            output: (tokens['output'] as num?)?.toInt() ?? 0,
          );
          return r.statusCode;
        }),
      ]);
      if (status != 200) {
        throw HttpException('opencode message HTTP $status');
      }
      // 3) 等事件流自然结束（idle）或短暂兜底
      await finished.future.timeout(const Duration(seconds: 5), onTimeout: () {});
      done = true;
      await ctrl.close();
    } catch (e, st) {
      if (!ctrl.isClosed) {
        ctrl.addError(e, st);
        await ctrl.close();
      }
    } finally {
      await sub?.cancel();
      eventResp?.detachSocket();
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
      String baseUrl, HttpClient client) async {
    final req = await client.getUrl(Uri.parse('$baseUrl/config/providers'));
    const hdrs = {
      'content-type': 'application/json',
      'accept': 'application/json',
    };
    hdrs.forEach((k, v) => req.headers.set(k, v));
    final resp = await req.close().timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) return const [];
    final j = jsonDecode(await resp.transform(utf8.decoder).join())
        as Map<String, dynamic>;
    final providers = (j['providers'] ?? const []) as List;
    for (final p in providers) {
      if (p is! Map || p['id'] != 'opencode') continue;
      final models = (p['models'] ?? const {}) as Map;
      final ids = models.keys
          .whereType<String>()
          .where((k) => k == 'big-pickle' || k.contains('-free'))
          .toList()
        ..sort();
      return ids;
    }
    return const [];
  }

  void close() => _client.close(force: true);
}

/// 上游错误（opencode serve 的 session.error / message.info.error）：
/// 带上游原文与状态码，网关据此如实回报客户端（429 额度、401 凭证…）。
class OpenCodeUpstreamError implements Exception {
  final String message;
  final int? statusCode;
  const OpenCodeUpstreamError({required this.message, this.statusCode});

  /// 上游文案里常见的额度耗尽关键词——命中时网关回 429 rate_limit_exceeded，
  /// 免得客户端把「额度用完」当成认证失败。判定统一走 [Zen.isQuotaExhausted]
  /// （两处文案：补全的 "Free usage limit reached"、重试事件的
  /// "Free usage exceeded"），别在这里再维护一份。
  bool get isQuotaExhausted => Zen.isQuotaExhausted(message);

  @override
  String toString() => message;
}
