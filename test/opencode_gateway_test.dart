import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/proxy.dart';
import 'package:zeroapi/gateway/upstream.dart';

/// 假 opencode serve（原生协议子集）+ ProxyServer：
/// 验证 _forwardOpenCode 的 OpenAI/Anthropic ↔ session/message 翻译、
/// SSE 增量转发与探活/模型清单。
void main() {
  late HttpServer serve;
  late ProxyServer proxy;
  late ModelRegistry registry;
  late UpstreamRuntime runtime;
  late Directory usageDir;
  bool serveClosed = false;
  String? injectError; // 非空则 message 端点返回该错误
  String? injectRetry; // 非空则推 session.status=retry 事件（CLI 额度耗尽的真实形态）
  late StreamController<String> events;
  final client = HttpClient();

  setUp(() async {
    events = StreamController<String>.broadcast();
    usageDir = await Directory.systemTemp.createTemp('zeroapi-oc-test-');
    serve = await HttpServer.bind('127.0.0.1', 0);
    serve.listen((req) async {
      final path = req.uri.path;
      if (path == '/global/health') {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'healthy': true, 'version': '1.19.3'}));
        await req.response.close();
        return;
      }
      if (path == '/config/providers') {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'providers': [
              {
                'id': 'opencode',
                'models': {
                  'deepseek-v4.1-flash-free': {},
                  'big-pickle': {},
                  'beam-free': {},
                  'jev-1.13-free': {},
                  'claude-opus-5': {},
                }
              }
            ]
          }));
        await req.response.close();
        return;
      }
      if (path == '/session' && req.method == 'POST') {
        await req.drain<void>();
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'id': 'ses_mock'}));
        await req.response.close();
        return;
      }
      if (path == '/event') {
        req.response
          ..headers.contentType = ContentType('text', 'event-stream')
          ..headers.set('cache-control', 'no-cache');
        // 真 serve 一连上就推 server.connected；mock 同构，否则网关
        // 等 /event 响应头、mock 等消息事件，两边死锁
        req.response.write('data: {"type":"server.connected","properties":{}}\n\n');
        // SSE 处理器在流结束前不能 return：dart:io 会把「handler 返回」
        // 当作请求完成并关闭响应，后续写入抛 Bad state
        final done = Completer<void>();
        late StreamSubscription<String> sub;
        sub = events.stream.listen((e) {
          // 网关读完即 detachSocket，此时再写会抛 Bad state——忽略即可
          try {
            req.response.write('data: $e\n\n');
          } catch (_) {}
          if (jsonDecode(e)['type'] == 'session.status' &&
              !done.isCompleted) {
            done.complete();
          }
        });
        await done.future.timeout(const Duration(seconds: 5),
            onTimeout: () {});
        await sub.cancel();
        await req.response.close();
        return;
      }
      final msgMatch = RegExp(r'^/session/([^/]+)/message$').firstMatch(path);
      if (msgMatch != null && req.method == 'POST') {
        final body = jsonDecode(await utf8.decodeStream(req))
            as Map<String, dynamic>;
        final sid = msgMatch.group(1);
        final text = (body['parts'] as List)[0]['text'] as String;
        // 真实 serve 的事件序：先回显「用户消息」（role=user + 它的 text
        // part），再推 assistant 消息的增量。回显必须被网关过滤掉。
        events.add(jsonEncode({
          'type': 'message.updated',
          'properties': {
            'sessionID': sid,
            'info': {'id': 'msg_user', 'role': 'user'}
          }
        }));
        events.add(jsonEncode({
          'type': 'message.part.updated',
          'properties': {
            'sessionID': sid,
            'part': {'type': 'text', 'id': 'prt_echo', 'messageID': 'msg_user',
                     'text': text}
          }
        }));
        events.add(jsonEncode({
          'type': 'message.updated',
          'properties': {
            'sessionID': sid,
            'info': {'id': 'msg_asst', 'role': 'assistant'}
          }
        }));
        // assistant 的两段增量 + idle，再返回同步结果
        void emit(String t) => events.add(jsonEncode({
              'type': 'message.part.updated',
              'properties': {
                'sessionID': sid,
                'part': {'type': 'text', 'id': 'prt_1', 'messageID': 'msg_asst',
                         'text': t}
              }
            }));
        if (injectRetry != null) {
          // 真实形态：额度耗尽 → 没有任何内容增量，retry 事件先于首增量
          events.add(jsonEncode({
            'type': 'session.status',
            'properties': {
              'sessionID': sid,
              'status': {'type': 'retry', 'attempt': 1, 'message': injectRetry}
            }
          }));
          await Future.delayed(const Duration(seconds: 30));
          req.response.statusCode = 504;
          await req.response.close();
          return;
        }
        emit('Hel');
        emit('Hello <$text>');
        events.add(jsonEncode({
          'type': 'session.status',
          'properties': {
            'sessionID': sid,
            'status': {'type': 'idle'}
          }
        }));
        if (injectError != null) {
          // 上游失败：先推 session.error，再返回带 error 的同步结果
          events.add(jsonEncode({
            'type': 'session.error',
            'properties': {
              'sessionID': sid,
              'error': {
                'name': 'APIError',
                'data': {'message': injectError, 'statusCode': 429}
              }
            }
          }));
        }
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'info': {
              'finish': 'stop',
              if (injectError != null)
                'error': {
                  'name': 'APIError',
                  'data': {'message': injectError, 'statusCode': 429}
                }
            },
            'parts': [
              {'type': 'text', 'text': 'Hello <$text>'}
            ]
          }));
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    final def = UpstreamDef(
        id: 'zen',
        type: 'managed',
        label: 'OpenCode Zen Free',
        modelPrefix: 'zen',
        baseUrl: 'http://127.0.0.1:${serve.port}',
        command: '', // probe 成功即不 spawn
        healthUrl: 'http://127.0.0.1:${serve.port}/global/health');
    runtime = UpstreamRuntime(def);
    await runtime.probe();
    registry = ModelRegistry()..rebuild([runtime]);
    proxy = ProxyServer('127.0.0.1', 0, 'sk-gw', registry,
        usageDir: usageDir.path);
    await proxy.start();
  });

  tearDown(() async {
    await proxy.stop();
    if (!serveClosed) await serve.close(force: true);
    await events.close();
    try {
      usageDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<HttpClientResponse> gw(String path, Object body) async {
    final req = await client.openUrl(
        'POST', Uri.parse('http://127.0.0.1:${proxy.boundPort}$path'));
    req.headers.set('Authorization', 'Bearer sk-gw');
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(body)));
    return req.close();
  }

  test('探活：健康 + 模型清单过滤（含 opencode/ 前缀，剔除不可用档）', () {
    expect(runtime.health, UpstreamHealth.healthy);
    // claude 付费档被滤掉；beam-free/jev-1.13-free 因不可用被剔除
    expect(runtime.models, ['big-pickle', 'deepseek-v4.1-flash-free']);
    expect(registry.resolve('zen/deepseek-v4.1-flash-free'), isNotNull);
    expect(registry.resolve('deepseek-v4.1-flash-free'), isNotNull);
  });

  test('非流式：SSE 增量聚合成完整 content 并带 usage 壳', () async {
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'ping'}
      ],
      'stream': false
    });
    final raw = await utf8.decodeStream(resp);
    expect(resp.statusCode, 200, reason: raw);
    final body = jsonDecode(raw);
    expect(body['choices'][0]['message']['content'], contains('ping'));
    expect(body['choices'][0]['message']['content'], startsWith('Hello'));
    expect(body['model'], 'big-pickle');
  });

  test('流式：OpenAI chunk 序列 + [DONE]', () async {
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ],
      'stream': true
    });
    expect(resp.statusCode, 200);
    final raw = await utf8.decodeStream(resp);
    final lines =
        raw.split('\n').where((l) => l.startsWith('data: ')).toList();
    expect(lines.length, greaterThanOrEqualTo(3));
    final deltas = lines
        .where((l) => l != 'data: [DONE]')
        .map((l) => jsonDecode(l.substring(6)))
        .toList();
    final content = deltas
        .map((j) => (j['choices'][0]['delta']['content'] ?? '') as String)
        .join();
    expect(content, 'Hello <User: hi>');
    expect(lines.last, 'data: [DONE]');
  });

  test('Anthropic 入口：同一条 CLI 通路翻译为 messages 格式', () async {
    final resp = await gw('/v1/messages', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'anthropic-hi'}
      ],
      'max_tokens': 16
    });
    expect(resp.statusCode, 200);
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(body['type'], 'message');
    final text = ((body['content'] as List).first['text'] ?? '') as String;
    expect(text, contains('anthropic-hi'));
  });

  test('serve 未就绪时快速 503，不 spawn 失败刷屏', () async {
    // 关掉 mock 让 re-probe 也失败，走「不可用」503 分支
    serveClosed = true;
    await serve.close(force: true);
    runtime.health = UpstreamHealth.checking;
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ]
    });
    expect(resp.statusCode, 503);
    runtime.health = UpstreamHealth.healthy;
  });

  test('上游额度耗尽 → 429 rate_limit，不再挂到超时', () async {
    injectError = 'Free usage limit reached. Subscribe to OpenCode Go';
    final sw = Stopwatch()..start();
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ]
    });
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(resp.statusCode, 429);
    expect(body['error']['code'], 'free_quota_exhausted');
    expect(body['error']['type'], 'rate_limit_exceeded');
    // 关键：不能等 CLI 内部重试结束（实测重试 3 次要 69 秒）
    expect(sw.elapsedMilliseconds / 1000, lessThan(20));
    injectError = null;
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('非额度类上游错误 → 502 且带原文', () async {
    injectError = 'Upstream request failed: Invalid credential';
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ]
    });
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(resp.statusCode, 502);
    expect(body['error']['message'], contains('Invalid credential'));
    injectError = null;
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('CLI 额度耗尽（status=retry 事件）→ 快速 429，不等 CLI 重试结束', () async {
    injectRetry = 'Free usage exceeded, subscribe to OpenCode Go to keep going';
    final sw = Stopwatch()..start();
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ]
    });
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(resp.statusCode, 429, reason: '$body');
    expect(body['error']['code'], 'free_quota_exhausted');
    expect(sw.elapsedMilliseconds / 1000, lessThan(15));
    injectRetry = null;
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('流式 + 首增量前额度耗尽 → 干净 429（不提交 200）', () async {
    injectRetry = 'Free usage exceeded, subscribe to OpenCode Go to keep going';
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'hi'}
      ],
      'stream': true
    });
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(resp.statusCode, 429, reason: '$body');
    expect(body['error']['code'], 'free_quota_exhausted');
    injectRetry = null;
  }, timeout: const Timeout(Duration(seconds: 40)));
}
