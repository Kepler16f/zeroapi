import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/opencode_api.dart';
import 'package:zeroapi/gateway/opencode_api_v2.dart';
import 'package:zeroapi/gateway/opencode_serve.dart';

/// 本地假 v2 serve：逐字复刻 2026-11-05 用 @opencode/cli 2.2.5 实测的
/// 端点形状（Basic 鉴权、异步 prompt、阻塞 wait、无 event: 行的 SSE、
/// 消息列表里的合成记录与结构化 error）。
class _TurnScript {
  _TurnScript({
    this.deltas = const [],
    this.sendUsage = false,
    this.endWithExecution = false,
    this.holdForever = false,
    this.heartbeat = false,
    this.removeWaitRoute = false,
    this.retryMessage,
    this.transportRetryCount = 0,
    this.assistantText = 'reply OK',
    this.errorType,
    this.errorMessage,
    this.errorStatus,
    this.retryAfterMs,
    this.nestedErrorBody = false,
    this.dropLastDelta = false,
    this.inputTokens = 4764,
    this.outputTokens = 2,
    this.cacheRead = 256,
    this.cacheWrite = 0,
  });

  /// session.text.delta 序列（只这些，不混 reasoning）。
  final List<String> deltas;
  final bool sendUsage;
  final bool endWithExecution;

  /// 永不结束本轮（测停滞看门狗）。
  final bool holdForever;

  /// 事件连接上周期性写 `: heartbeat` 注释行。
  final bool heartbeat;

  /// wait 路由被移除（experimental 前缀消失）→ 404，测消息轮询兜底。
  final bool removeWaitRoute;

  /// session.retry.scheduled 的文案（软限流）。
  final String? retryMessage;

  /// >0 时模拟传输重试风暴：连发 N 条 session.retry.scheduled（provider
  /// .transport）。用于验证「连续 4 次传输重试且无输出 → 判出口不可达」。
  final int transportRetryCount;
  final String? assistantText;

  /// assistant 消息的结构化 error（额度/传输）。
  final String? errorType;
  final String? errorMessage;
  final int? errorStatus;
  final int? retryAfterMs;

  /// error.response.body 内嵌 FreeUsageLimitError JSON。
  final bool nestedErrorBody;

  /// 模拟「SSE 最后一帧没赶上结束信号」：SSE 只推除最后一个之外的 delta，
  /// 但终态消息里仍是完整累积全文（真实 serve 的消息列表就是全文）。
  final bool dropLastDelta;

  final int inputTokens;
  final int outputTokens;
  final int cacheRead;
  final int cacheWrite;
}

class _FakeServe {
  _FakeServe({this.password = 'test-pw', this.v1Mode = false});

  final String password;

  /// 模拟 v1 serve：任何路径一律 200 + SPA HTML。
  final bool v1Mode;

  HttpServer? _server;
  String get baseUrl => 'http://127.0.0.1:${_server!.port}';

  _TurnScript script = _TurnScript();

  /// 请求顺序日志与捕获内容（测试断言用）。
  final List<String> log = [];
  final List<String> promptTexts = [];
  final List<String> promptContentTypes = [];
  List<Map<String, Object?>>? modelCatalog;

  final Map<String, _Sess> _sessions = {};
  final List<HttpResponse> _sseClients = [];
  Timer? _heartbeatTimer;
  int _evtSeq = 0;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(
      _handle,
      // 客户端 abort 订阅时 serve 侧会见到异常；测试里无需处理。
      onError: (Object _) {},
    );
  }

  Future<void> close() async {
    _heartbeatTimer?.cancel();
    for (final r in _sseClients) {
      try {
        await r.close();
      } catch (_) {}
    }
    _sseClients.clear();
    await _server?.close(force: true);
  }

  String _basic(String user, String pw) =>
      'Basic ${base64.encode(utf8.encode('$user:$pw'))}';

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final resp = req.response;
    if (v1Mode) {
      // v1 上没有 /api/*，SPA 兜底路由对任何 GET 返回 200 HTML。
      resp.statusCode = 200;
      resp.headers.contentType = ContentType.html;
      resp.write('<!DOCTYPE html><html><body>opencode console</body></html>');
      await resp.close();
      return;
    }
    final auth = req.headers.value('authorization');
    if (auth != _basic('opencode', password)) {
      // 实测：空用户名/错密码一律 401，body 是结构化 UnauthorizedError。
      resp.statusCode = 401;
      resp.headers.set('www-authenticate', 'Basic realm="opencode"');
      resp.headers.contentType = ContentType.json;
      resp.write(
        jsonEncode({
          '_tag': 'UnauthorizedError',
          'message': 'Authentication required',
        }),
      );
      await resp.close();
      return;
    }

    // GET /api/info —— 版本探测判据（v2 返回含 version 的 JSON）。
    if (req.method == 'GET' && path == '/api/info') {
      resp.write(
        jsonEncode({
          'version': '2.2.5',
          'pid': 4242,
          'hostname': '127.0.0.1',
          'urls': {'injected': 'http://127.0.0.1:${_server!.port}'},
          'paths': {'home': 'C:/fake/home', 'data': 'C:/fake/data'},
          'capabilities': {'v2': true},
        }),
      );
      await resp.close();
      return;
    }
    if (req.method == 'GET' && path == '/api/model') {
      resp.write(
        jsonEncode({
          'data':
              modelCatalog ??
              [
                {'id': 'big-pickle'},
                {'id': 'glm-4.7-free'},
                {'id': 'gpt-5.1'},
              ],
        }),
      );
      await resp.close();
      return;
    }
    // GET /api/event —— SSE：没有 event: 行，类型在 JSON type 字段里。
    if (req.method == 'GET' && path == '/api/event') {
      resp.statusCode = 200;
      resp.headers.set('content-type', 'text/event-stream; charset=utf-8');
      resp.headers.set('cache-control', 'no-cache');
      // bufferOutput 必须关掉：否则表头/帧全留在服务器缓冲里，
      // 客户端 req.close() 连响应头都收不到（首批用例就是这样挂死的）。
      resp.bufferOutput = false;
      // 真 serve 一连上就推 server.connected——它同时把表头刷出去，
      // 客户端的 close() future 才能完成。
      resp.write(
        'data: ${jsonEncode({
              'id': 'evt_0',
              'type': 'server.connected',
              'data': <String, Object?>{},
            })}\n\n',
      );
      await resp.flush();
      _sseClients.add(resp);
      // 不 close：保持长连接，事件由 _runTurn 推送；测试结束统一关。
      return;
    }

    final sessionMatch = RegExp(
      r'^/api/session/([^/]+)(/model|/prompt|/message|/interrupt)?$',
    ).firstMatch(path);
    final waitMatch = RegExp(
      r'^/api/experimental/session/([^/]+)/wait$',
    ).firstMatch(path);

    if (req.method == 'POST' && path == '/api/session') {
      final body = await _readJson(req);
      final id = 'ses_${_sessions.length + 1}';
      _sessions[id] = _Sess(id, (body['title'] ?? '').toString());
      log.add('session');
      resp.write(
        jsonEncode({
          'data': {
            'id': id,
            'projectID': 1,
            'cost': 0,
            'tokens': {
              'input': 0,
              'output': 0,
              'reasoning': 0,
              'cache': {'read': 0, 'write': 0},
            },
            'time': {'created': 0},
            'title': body['title'],
            'permissions': body['permissions'],
            'location': {'directory': 'C:/fake'},
          },
        }),
      );
      await resp.close();
      return;
    }

    if (waitMatch != null && req.method == 'POST') {
      final sid = waitMatch.group(1)!;
      final s = _sessions[sid];
      log.add('wait');
      if (script.removeWaitRoute) {
        // 实验路由被移除 → 非 204。
        resp.statusCode = 404;
        resp.write('{"_tag":"NotFoundError"}');
        await resp.close();
        return;
      }
      if (s != null && s.done) {
        resp.statusCode = 204;
        await resp.close();
        return;
      }
      if (s != null) {
        // 阻塞到本轮结束再回 204。
        unawaited(
          s.doneFuture.then((_) async {
            resp.statusCode = 204;
            await resp.close();
          }).catchError((Object _) {}),
        );
        return;
      }
      resp.statusCode = 404;
      await resp.close();
      return;
    }

    if (sessionMatch != null) {
      final sid = sessionMatch.group(1)!;
      final sub = sessionMatch.group(2);
      final s = _sessions[sid];
      if (s == null) {
        resp.statusCode = 404;
        await resp.close();
        return;
      }
      if (sub == '/model' && req.method == 'POST') {
        final body = await _readJson(req);
        final model = body['model'];
        // 实测：字段是 id（不是 modelID），providerID 固定 opencode；204 无体。
        if (model is! Map || model['id'] is! String || model['providerID'] != 'opencode') {
          resp.statusCode = 400;
          await resp.close();
          return;
        }
        s.model = model['id'] as String;
        log.add('model');
        resp.statusCode = 204;
        await resp.close();
        return;
      }
      if (sub == '/prompt' && req.method == 'POST') {
        final ct = req.headers.value('content-type') ?? '';
        promptContentTypes.add(ct);
        if (!ct.contains('application/json')) {
          // 实测：不带 application/json → 415 Unsupported content-type。
          resp.statusCode = 415;
          resp.write('{"message":"Unsupported content-type"}');
          await resp.close();
          return;
        }
        final raw = await utf8.decoder.bind(req).join();
        final body = jsonDecode(raw) as Map<String, dynamic>;
        final text = (body['text'] ?? '').toString();
        promptTexts.add(text);
        log.add('prompt');
        s.userText = text;
        unawaited(_runTurn(s));
        resp.write(
          jsonEncode({
            'data': {
              'id': 'msg_user_$sid',
              'sessionID': sid,
              'type': 'user',
              'payload': {'text': text},
              'delivery': 'steer',
            },
          }),
        );
        await resp.close();
        return;
      }
      if (sub == '/message' && req.method == 'GET') {
        log.add('message');
        resp.write(jsonEncode({'data': s.messages()}));
        await resp.close();
        return;
      }
      if (sub == '/interrupt' && req.method == 'POST') {
        log.add('interrupt');
        s.finishTurn();
        resp.statusCode = 200;
        resp.write('{"data":true}');
        await resp.close();
        return;
      }
      if (sub == null && req.method == 'DELETE') {
        log.add('delete');
        _sessions.remove(sid);
        resp.statusCode = 200;
        resp.write('{"data":{"deleted":true}}');
        await resp.close();
        return;
      }
    }

    resp.statusCode = 404;
    await resp.close();
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    if (raw.isEmpty) return const {};
    final j = jsonDecode(raw);
    return j is Map<String, dynamic> ? j : const {};
  }

  Future<void> _runTurn(_Sess s) async {
    final sc = script;
    if (sc.heartbeat) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
        for (final r in _sseClients) {
          try {
            r.write(': heartbeat\n\n');
          } catch (_) {}
        }
      });
    }
    void push(String type, Map<String, Object?> data) {
      final frame = {
        'id': 'evt_${++_evtSeq}',
        'type': type,
        'data': {'sessionID': s.id, ...data},
        'location': {'directory': 'C:/fake'},
        'durable': {'aggregateID': s.id, 'seq': _evtSeq, 'version': 1},
      };
      for (final r in _sseClients) {
        try {
          r.write('data: ${jsonEncode(frame)}\n\n');
        } catch (_) {}
      }
    }

    // 本轮消息记录（实测列表里混有 model-switched / user / assistant / idle，
    // user 消息的文本在顶层 text，assistant 的文本在 content[] 里）。
    final tokens = {
      'input': sc.inputTokens,
      'output': sc.outputTokens,
      'reasoning': 0,
      'cache': {'read': sc.cacheRead, 'write': sc.cacheWrite},
    };
    Map<String, Object?>? assistantError;
    if (sc.errorType != null) {
      assistantError = {
        'type': sc.errorType,
        'message': sc.errorMessage ?? '上游错误',
        'status': sc.errorStatus,
        if (sc.retryAfterMs != null) 'retryAfterMs': sc.retryAfterMs,
        if (sc.nestedErrorBody)
          'response': {
            'body':
                '{"type":"error","error":{"type":"FreeUsageLimitError","code":"quota_exceeded"}}',
          },
      };
    }

    if (sc.retryMessage != null) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // transportRetryCount>0 时模拟**传输风暴**：连发 N 条 provider.transport
      // 重试事件（真实 CLI 对 ECONNRESET 会重试 10 次 / 148s，直到看门狗掐）。
      final n = sc.transportRetryCount > 0 ? sc.transportRetryCount : 1;
      for (var k = 1; k <= n; k++) {
        push('session.retry.scheduled', {
          'message': sc.retryMessage,
          'attempt': k,
          'nextRetryAt': 0,
        });
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    }
    var ordinal = 0;
    for (final d in sc.deltas) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      // dropLastDelta：最后一帧不推（模拟它没赶上结束信号），但终态消息
      // 里仍是完整累积全文。
      final isLast = ordinal == sc.deltas.length - 1;
      if (isLast && sc.dropLastDelta) {
        ordinal++;
        continue;
      }
      push('session.text.started', {'assistantMessageID': 'msg_a1', 'ordinal': ordinal});
      push('session.text.delta', {
        'assistantMessageID': 'msg_a1',
        'ordinal': ordinal,
        'delta': d,
      });
      push('session.text.ended', {'assistantMessageID': 'msg_a1', 'ordinal': ordinal});
      ordinal++;
    }
    if (sc.sendUsage) {
      push('session.usage.updated', {'cost': 0, 'tokens': tokens});
    }
    s.assistantRecord = {
      'type': 'assistant',
      'id': 'msg_a1',
      'sessionID': s.id,
      'finish': assistantError == null ? 'stop' : null,
      'cost': 0,
      'tokens': assistantError == null ? tokens : null,
      'error': assistantError,
      'content':
          assistantError != null
              ? const <Object?>[]
              : [
                {'type': 'reasoning', 'text': 'internal thinking…'},
                // 真实 v2 消息列表里的 text 是**累积全文**（含 deltas）。镜像
                // 这点：轮询结束信号与 SSE 增量是两条通道，负载下可能乱序，
                // 适配器靠「列表全文补吐」兜底——假件必须给全文。
                {
                  'type': 'text',
                  // 有 deltas 时用累积全文（真实 v2 消息列表就是全文），
                  // 否则用显式指定的 assistantText。
                  'text': sc.deltas.isNotEmpty
                      ? sc.deltas.join()
                      : (sc.assistantText ?? ''),
                },
              ],
    };
    s.idleOutcome = assistantError == null ? 'succeeded' : 'failed';
    if (sc.holdForever) return; // 看门狗测试：永不结束。
    if (assistantError != null) {
      push('session.execution.failed', {'message': sc.errorMessage ?? 'failed'});
    } else if (sc.endWithExecution) {
      push('session.execution.succeeded', {'cost': 0});
    }
    s.finishTurn();
  }
}

class _Sess {
  _Sess(this.id, this.title);

  final String id;
  final String title;
  String? model;
  String? userText;
  Map<String, Object?>? assistantRecord;
  String? idleOutcome;
  bool done = false;
  final _done = Completer<void>();

  Future<void> get doneFuture => _done.future;

  void finishTurn() {
    done = true;
    if (!_done.isCompleted) _done.complete();
  }

  /// 实测的混合记录序列：model-switched / user（顶层 text）/ assistant / idle。
  List<Map<String, Object?>> messages() {
    return [
      {
        'type': 'model-switched',
        'model': {'id': model ?? 'm', 'providerID': 'opencode'},
      },
      if (userText != null)
        {'type': 'user', 'id': 'msg_user_$id', 'sessionID': id, 'text': userText},
      ?assistantRecord,
      if (done && idleOutcome != null) {'type': 'idle', 'outcome': idleOutcome},
    ];
  }
}

Future<({List<String> chunks, Object? error})> _drain(Stream<String> stream) {
  final chunks = <String>[];
  final c = Completer<({List<String> chunks, Object? error})>();
  stream.listen(
    chunks.add,
    onError: (Object e) {
      if (!c.isCompleted) c.complete((chunks: chunks, error: e));
    },
    onDone: () {
      if (!c.isCompleted) c.complete((chunks: chunks, error: null));
    },
  );
  return c.future;
}

List<Map<String, dynamic>> _msgs({String text = 'reply please'}) => [
  {'role': 'system', 'content': 'be brief'},
  {'role': 'user', 'content': text},
];

void main() {
  late Duration origStall;
  late Duration origGenIdle;
  late Duration origPoll;
  late Duration origGrace;

  setUp(() {
    origStall = OpenCodeApiV2.stallTimeout;
    origGenIdle = OpenCodeApiV2.generationIdleTimeout;
    origPoll = OpenCodeApiV2.waitPollInterval;
    origGrace = OpenCodeApiV2.completionGrace;
  });
  tearDown(() {
    OpenCodeApiV2.stallTimeout = origStall;
    OpenCodeApiV2.generationIdleTimeout = origGenIdle;
    OpenCodeApiV2.waitPollInterval = origPoll;
    OpenCodeApiV2.completionGrace = origGrace;
  });

  group('OpenCodeApiV2 (fake v2 serve)', () {
    test('non-streaming full chain: session→model→prompt→wait→messages', () async {
      final fake = _FakeServe();
      fake.script = _TurnScript(
        // 无 delta：答案只出现在消息列表（异步 prompt + wait 的主路径）。
        assistantText: 'reply OK',
      );
      await fake.start();
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });

      final r = await _drain(
        api.chat(model: 'glm-4.7-free', messages: _msgs()),
      );
      expect(r.error, isNull, reason: '${r.error}');
      expect(r.chunks.join(), 'reply OK');
      // 只吐 assistant 文本：不混 reasoning、不回显 User。
      expect(r.chunks.join(), isNot(contains('User:')));
      expect(r.chunks.join(), isNot(contains('thinking')));
      // lastUsage 从终态消息 tokens 取（v1 口径：input 含缓存）。
      expect(api.lastUsage, (input: 4764 + 256 + 0, output: 2));
      expect(api.cachedReadTokens, 256);
      expect(api.cachedWriteTokens, 0);
      // 端点顺序与 v2 实测一致；收尾删会话（无状态翻译，不泄漏）。
      expect(fake.log, containsAllInOrder(['session', 'model', 'prompt', 'wait', 'message', 'delete']));
      // model 端点的 providerID/id 字段形状由 fake 校验（错形会 400 导致失败）。
    });

    test('streaming: session.text.delta in order; usage.updated fills tokens', () async {
      final fake = _FakeServe();
      fake.script = _TurnScript(
        deltas: ['Hello', ' world'],
        sendUsage: true,
        endWithExecution: true,
        heartbeat: true,
        inputTokens: 4853,
        outputTokens: 5,
        cacheRead: 5248,
        cacheWrite: 0,
      );
      await fake.start();
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });
      final activities = <String>[];
      api.onActivity = activities.add;

      final r = await _drain(api.chat(model: 'big-pickle', messages: _msgs()));
      expect(r.error, isNull, reason: '${r.error}');
      expect(r.chunks, ['Hello', ' world']);
      expect(api.generationStarted, isTrue);
      expect(api.lastUsage, (input: 4853 + 5248, output: 5));
      expect(api.cachedReadTokens, 5248);
      expect(activities, isNotEmpty);
    });

    test('SSE 最后一帧与结束信号紧邻到达时不丢尾部文字', () async {
      // 回归 2026-11-05：SSE 的最后一个 text.delta 可能与
      // session.execution.succeeded 紧邻到达，本轮结束信号先到时会把最后
      // 一句丢掉（真机表现为回答结尾被截断）。适配器须用终态消息的累积全文
      // 与已吐文本对账补差量。
      final fake = _FakeServe();
      fake.script = _TurnScript(
        deltas: ['前半', '后半'],
        endWithExecution: true,
        // 模拟「最后一帧没赶上」：SSE 只推前半，终态消息里有完整全文
        dropLastDelta: true,
      );
      await fake.start();
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });

      final r = await _drain(api.chat(model: 'big-pickle', messages: _msgs()));
      expect(r.error, isNull, reason: '${r.error}');
      expect(
        r.chunks.join(),
        '前半后半',
        reason: '尾部文字必须补上，不能丢',
      );
    });

    test('传输重试风暴：连续 4 次 provider.transport 且无输出 → 判出口不可达',
        () async {
      // 回归 2026-11-06：死出口上 CLI 对 ECONNRESET 无限重试（实测 10 次 /
      // 148s，直到看门狗 150s 掐掉）。同一 IP 上第 5 次连接不会有不同结果，
      // 连续 4 次传输重试且无任何输出就应立即判失败换出口（148s → ~60s）。
      final fake = _FakeServe();
      fake.script = _TurnScript(
        retryMessage:
            '{type: provider.transport, message: ECONNRESET: The socket '
            'connection was closed unexpectedly.}',
        transportRetryCount: 6,
        holdForever: true, // 没有恢复：等适配器主动判失败
      );
      await fake.start();
      OpenCodeApiV2.stallTimeout = const Duration(seconds: 30);
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });
      final retries = <String>[];
      api.onRetry = retries.add;

      final r = await _drain(api.chat(model: 'big-pickle', messages: _msgs()));
      final e = r.error;
      expect(e, isA<OpenCodeUpstreamError>());
      expect((e! as OpenCodeUpstreamError).isConnectionFailure, isTrue,
          reason: '传输风暴必须按「出口不可达」处理（网关据此换出口）');
      expect(
        (e as OpenCodeUpstreamError).message,
        contains('连续 4 次'),
        reason: '第 4 次就止损，不等看门狗',
      );
      expect(retries.length, greaterThanOrEqualTo(4));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('额度 retry（非传输类）不触发风暴止损：照常等 CLI 自愈', () async {
      final fake = _FakeServe();
      fake.script = _TurnScript(
        retryMessage: 'Free usage exceeded, subscribing may help: retry in 17s',
        transportRetryCount: 6, // 即使连发 6 次
        deltas: ['恢复', '了'],
        endWithExecution: true,
      );
      await fake.start();
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });

      final r = await _drain(api.chat(model: 'big-pickle', messages: _msgs()));
      expect(r.error, isNull, reason: '${r.error}');
      expect(r.chunks.join(), '恢复了');
    });

    test('wrong password → 401 auth error, password never leaked', () async {      final fake = _FakeServe(password: 's3cr3t-pw');
      await fake.start();
      final api = OpenCodeApiV2(fake.baseUrl, password: 'WRONG-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });

      final r = await _drain(api.chat(model: 'big-pickle', messages: _msgs()));
      final e = r.error;
      expect(e, isA<OpenCodeUpstreamError>());
      expect((e! as OpenCodeUpstreamError).statusCode, 401);
      // 异常文本绝不含任一密码（上层会写进日志与客户端响应）。
      expect(e.toString(), isNot(contains('s3cr3t-pw')));
      expect(e.toString(), isNot(contains('WRONG-pw')));
    });

    test('session.retry.scheduled only logs via onRetry — never kills the turn', () async {
      // 回归 11-04 误杀：软限流文案里带额度词也不能中止本轮。
      final fake = _FakeServe();
      fake.script = _TurnScript(
        retryMessage: 'Free usage exceeded, subscribing may help: retry in 17s',
        deltas: ['after', ' retry'],
        endWithExecution: true,
      );
      await fake.start();
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });
      final retries = <String>[];
      api.onRetry = retries.add;

      final r = await _drain(api.chat(model: 'big-pickle', messages: _msgs()));
      expect(r.error, isNull, reason: 'retry.scheduled 不得终止本轮: ${r.error}');
      expect(r.chunks.join(), 'after retry');
      expect(retries, hasLength(1));
      expect(retries.single, contains('Free usage exceeded'));
    });

    test('provider.free-limit message error → isQuotaExhausted + retryAfter', () async {
      final fake = _FakeServe();
      fake.script = _TurnScript(
        assistantText: null,
        errorType: 'provider.free-limit',
        errorMessage: 'Free usage limit reached. Subscribe to keep going',
        errorStatus: 429,
        retryAfterMs: 28042000,
      );
      await fake.start();
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });

      final r = await _drain(api.chat(model: 'big-pickle', messages: _msgs()));
      final e = r.error;
      expect(e, isA<OpenCodeUpstreamV2Error>());
      final v2 = e! as OpenCodeUpstreamV2Error;
      expect(v2.isQuotaExhausted, isTrue);
      expect(v2.statusCode, 429);
      expect(v2.retryAfterMs, 28042000);
      expect(v2.retryAfter, const Duration(seconds: 28042));
      // 主代理接线：接口上的 retryAfterSeconds（整秒、向上取整）。
      expect(api.retryAfterSeconds, 28042);
      expect(api.lastRetryAfterSeconds, 28042);
      expect(r.chunks, isEmpty);
    });

    test('quota detected via nested response.body type even if type field absent', () async {
      final fake = _FakeServe();
      fake.script = _TurnScript(
        assistantText: null,
        errorType: 'unknown.thing', // 顶层类型不在额度集合
        errorMessage: 'HTTP 429', // 文案也不含额度词（防只看 429 的误报回归）
        errorStatus: 429,
        nestedErrorBody: true, // response.body: FreeUsageLimitError
      );
      await fake.start();
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });

      final r = await _drain(api.chat(model: 'big-pickle', messages: _msgs()));
      expect(r.error, isA<OpenCodeUpstreamV2Error>());
      expect((r.error! as OpenCodeUpstreamV2Error).isQuotaExhausted, isTrue);
    });

    test('provider.transport → isConnectionFailure, NOT quota', () async {
      final fake = _FakeServe();
      fake.script = _TurnScript(
        assistantText: null,
        errorType: 'provider.transport',
        errorMessage: 'connect ECONNREFUSED 127.0.0.1:443 (quota wording trap)',
        errorStatus: 502,
      );
      await fake.start();
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });

      final r = await _drain(api.chat(model: 'big-pickle', messages: _msgs()));
      final e = r.error;
      expect(e, isA<OpenCodeUpstreamV2Error>());
      final v2 = e! as OpenCodeUpstreamV2Error;
      expect(v2.isConnectionFailure, isTrue);
      expect(v2.isQuotaExhausted, isFalse);
      // 传输错误既不是额度也不是停滞——上层据此立即换出口。
      expect(v2.isStall, isFalse);
      expect(api.retryAfterSeconds, isNull);
    });

    test('heartbeat comments do NOT refresh the stall watchdog', () async {
      final fake = _FakeServe();
      fake.script = _TurnScript(holdForever: true, heartbeat: true);
      await fake.start();
      OpenCodeApiV2.stallTimeout = const Duration(milliseconds: 400);
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });

      final sw = Stopwatch()..start();
      final r = await _drain(api.chat(model: 'big-pickle', messages: _msgs()));
      sw.stop();
      final e = r.error;
      expect(e, isA<OpenCodeUpstreamError>());
      expect((e! as OpenCodeUpstreamError).isStall, isTrue);
      // serve 心跳每 40ms 一跳：若看门狗被注释行骗过，这里会挂到测试超时。
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(r.chunks, isEmpty);
    });

    test('CJK prompt survives as utf-8 (latin1 regression guard)', () async {
      final fake = _FakeServe();
      fake.script = _TurnScript(deltas: ['好的'], endWithExecution: true);
      await fake.start();
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });

      final r = await _drain(
        api.chat(model: 'big-pickle', messages: [
          {'role': 'system', 'content': '你是一个简洁的中文助手'},
          {'role': 'user', 'content': '你好，世界！测试中文 🚀'},
        ]),
      );
      expect(r.error, isNull, reason: '${r.error}');
      expect(r.chunks.join(), '好的');
      // 服务器按 utf8 解出的提示词与原文逐字一致，且 content-type 显式 utf-8。
      expect(fake.promptTexts.single, contains('你好，世界！测试中文 🚀'));
      expect(fake.promptTexts.single, contains('你是一个简洁的中文助手'));
      expect(
        fake.promptContentTypes.single,
        allOf(contains('application/json'), contains('utf-8')),
      );
    });

    test('probe: SPA-HTML 200 is NOT v2; JSON is; 401 is passwordRequired', () async {
      final v1 = _FakeServe(v1Mode: true);
      await v1.start();
      final v2 = _FakeServe(password: 'right-pw');
      await v2.start();
      addTearDown(() async {
        await v1.close();
        await v2.close();
      });

      // v1 serve 对 /api/info 也回 200 HTML → 解析不了 JSON → 判 v1。
      expect(await OpenCodeApiV2.probe(v1.baseUrl), OpenCodeV2Probe.notV2);
      expect(
        await OpenCodeApiV2.probe(v1.baseUrl, password: 'whatever'),
        OpenCodeV2Probe.notV2,
      );
      // v2 + 正确密码 → v2；缺/错密码 → 401 但那是 v2 的行为，单独成态。
      expect(
        await OpenCodeApiV2.probe(v2.baseUrl, password: 'right-pw'),
        OpenCodeV2Probe.v2,
      );
      expect(await OpenCodeApiV2.probe(v2.baseUrl), OpenCodeV2Probe.passwordRequired);
      expect(
        await OpenCodeApiV2.probe(v2.baseUrl, password: 'nope'),
        OpenCodeV2Probe.passwordRequired,
      );
    });

    test('wait route removed → message-list polling fallback still streams', () async {
      final fake = _FakeServe();
      fake.script = _TurnScript(
        removeWaitRoute: true,
        deltas: ['A', 'B'],
        // 不推 execution.succeeded：结束信号只能来自轮询的 idle。
        endWithExecution: false,
      );
      await fake.start();
      OpenCodeApiV2.waitPollInterval = const Duration(milliseconds: 50);
      OpenCodeApiV2.stallTimeout = const Duration(seconds: 5);
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });

      final r = await _drain(api.chat(model: 'big-pickle', messages: _msgs()));
      expect(r.error, isNull, reason: '${r.error}');
      // 轮询结束信号与 SSE 增量是两条通道，负载下可能乱序：增量已吐时是
      // ['A','B']，列表全文补吐时是 ['AB']——按拼接文本断言两种都认。
      expect(r.chunks.join(), 'AB');
      expect(fake.log, contains('wait'));
    });

    test('user echo records never pollute assistant output', () async {
      // v1 曾有 "User: reply OKOK" 污染——v2 列表里用户消息在顶层 text，
      // 本类只读 assistant content[]。
      final fake = _FakeServe();
      fake.script = _TurnScript(
        assistantText: 'the answer',
      );
      await fake.start();
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });

      final r = await _drain(
        api.chat(model: 'big-pickle', messages: _msgs(text: 'reply please')),
      );
      expect(r.error, isNull, reason: '${r.error}');
      final out = r.chunks.join();
      expect(out, 'the answer');
      expect(out, isNot(contains('User:')));
      expect(out, isNot(contains('reply please')));
      expect(out, isNot(contains('model-switched')));
    });

    test('close() with no active stream is safe; abort path cleans up', () async {
      final fake = _FakeServe();
      fake.script = _TurnScript(holdForever: true);
      await fake.start();
      OpenCodeApiV2.stallTimeout = const Duration(milliseconds: 300);
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });

      final r = await _drain(api.chat(model: 'big-pickle', messages: _msgs()));
      expect((r.error! as OpenCodeUpstreamError).isStall, isTrue);
      expect(fake.log, containsAllInOrder(['prompt', 'interrupt', 'delete']));
      // 再次 close 不应抛。
      api.close();
    });

    test('freeModels: GET /api/model, free tier filtered and sorted', () async {
      final fake = _FakeServe();
      fake.modelCatalog = [
        {'id': 'gpt-5.1'},
        {'id': 'big-pickle'},
        {'id': 'claude-sonnet-4.5-free'},
        {'id': 'kimi-k2.6'},
      ];
      await fake.start();
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await fake.close();
      });

      final ids = await OpenCodeApiV2.freeModels(
        fake.baseUrl,
        client,
        password: 'test-pw',
      );
      expect(ids, ['big-pickle', 'claude-sonnet-4.5-free']);
      // 密码错误 → 401 → 空表不抛（与 v1 同形的宽容失败）。
      final none = await OpenCodeApiV2.freeModels(fake.baseUrl, client);
      expect(none, isEmpty);
    });

    test('OpenCodeApiV2 is an OpenCodeServeApi (interface conformance)', () async {
      final fake = _FakeServe();
      await fake.start();
      final api = OpenCodeApiV2(fake.baseUrl, password: 'test-pw');
      addTearDown(() async {
        api.close();
        await fake.close();
      });
      // 主代理按接口类型持有：字段/静态成员必须都在。
      expect(api, isA<OpenCodeServeApi>());
      expect(OpenCodeApiV2.stallTimeout, isNotNull);
      expect(OpenCodeApiV2.generationIdleTimeout, isNotNull);
      expect(OpenCodeApiV2.requestTimeout, isNotNull);
      expect(OpenCodeApiV2.completionGrace, isNotNull);
    });
  });
}
