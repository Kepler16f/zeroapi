import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/opencode_api.dart';
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
  bool hangMessage = false;
  bool partialHang = false;
  var abortCount = 0;
  var messageCount = 0;
  late Completer<void> aborted;
  String? injectRetry; // 非空则推 session.status=retry 事件（CLI 软失败形态）
  // 额度 retry 有两种后续（2026-11-04 实测）：CLI 退避后自愈成功（真 CLI
  // 17~71s 后 OK），或重试预算耗尽后终态 error（info.error）。
  bool retryRecovers = false; // true=retry 后继续正常输出→期望 200；false=重试耗尽→429
  late StreamController<String> events;
  final client = HttpClient();

  setUp(() async {
    injectError = null;
    injectRetry = null;
    retryRecovers = false;
    hangMessage = false;
    aborted = Completer<void>();
    partialHang = false;
    abortCount = 0;
    messageCount = 0;
    events = StreamController<String>.broadcast();
    usageDir = await Directory.systemTemp.createTemp('zeroapi-oc-test-');
    serve = await HttpServer.bind('127.0.0.1', 0);
    serve.listen((req) async {
      final path = req.uri.path;
      if (path.endsWith('/abort')) {
        abortCount++;
        if (!aborted.isCompleted) aborted.complete();
        req.response.headers.contentType = ContentType.json;
        req.response.write('true');
        await req.response.close();
        return;
      }
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
          ..write(
            jsonEncode({
              'providers': [
                {
                  'id': 'opencode',
                  'models': {
                    'deepseek-v4.1-flash-free': {},
                    'big-pickle': {},
                    'beam-free': {},
                    'jev-1.13-free': {},
                    'claude-opus-5': {},
                  },
                },
              ],
            }),
          );
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
        req.response.bufferOutput = false;
        req.response
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          )
          ..headers.set('cache-control', 'no-cache');
        // 真 serve 一连上就推 server.connected；mock 同构，否则网关
        // 等 /event 响应头、mock 等消息事件，两边死锁
        req.response.write(
          'data: {"type":"server.connected","properties":{}}\n\n',
        );
        // SSE 处理器在流结束前不能 return：dart:io 会把「handler 返回」
        // 当作请求完成并关闭响应，后续写入抛 Bad state
        final done = Completer<void>();
        late StreamSubscription<String> sub;
        sub = events.stream.listen((e) {
          // 网关读完即 detachSocket，此时再写会抛 Bad state——忽略即可。
          // 事件里可能含 CJK：必须 utf8 字节写入（无 charset 的
          // write(String) 会按 latin1 抛异常、事件被静默吞掉）
          try {
            req.response.add(utf8.encode('data: $e\n\n'));
          } catch (_) {}
          if (jsonDecode(e)['type'] == 'session.status' && !done.isCompleted) {
            done.complete();
          }
        });
        await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
        await sub.cancel();
        await req.response.close();
        return;
      }
      final msgMatch = RegExp(r'^/session/([^/]+)/message$').firstMatch(path);
      if (msgMatch != null && req.method == 'POST') {
        messageCount++;
        final body =
            jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
        final sid = msgMatch.group(1);
        final text = (body['parts'] as List)[0]['text'] as String;
        // 真实 serve 的事件序：先回显「用户消息」（role=user + 它的 text
        // part），再推 assistant 消息的增量。回显必须被网关过滤掉。
        events.add(
          jsonEncode({
            'type': 'message.updated',
            'properties': {
              'sessionID': sid,
              'info': {'id': 'msg_user', 'role': 'user'},
            },
          }),
        );
        events.add(
          jsonEncode({
            'type': 'message.part.updated',
            'properties': {
              'sessionID': sid,
              'part': {
                'type': 'text',
                'id': 'prt_echo',
                'messageID': 'msg_user',
                'text': text,
              },
            },
          }),
        );
        events.add(
          jsonEncode({
            'type': 'message.updated',
            'properties': {
              'sessionID': sid,
              'info': {'id': 'msg_asst', 'role': 'assistant'},
            },
          }),
        );
        // assistant 的两段增量 + idle，再返回同步结果
        void emit(String t) => events.add(
          jsonEncode({
            'type': 'message.part.updated',
            'properties': {
              'sessionID': sid,
              'part': {
                'type': 'text',
                'id': 'prt_1',
                'messageID': 'msg_asst',
                'text': t,
              },
            },
          }),
        );
        if (partialHang) {
          emit('partial answer');
          await req.response.flush();
          await aborted.future;
          await req.response.close();
          return;
        }
        if (hangMessage) {
          // 上游 hang 形态：message 端点永不返回，也不发任何本会话事件
          await Future.delayed(const Duration(seconds: 30));
          req.response.statusCode = 504;
          await req.response.close();
          return;
        }
        if (injectRetry != null) {
          // 真实形态：CLI 软失败先报 retry（无内容增量）。两种后续（11-04 实测）：
          // retryRecovers=CLI 退避后自愈 → 落入下方正常输出路径；
          // 否则=重试预算耗尽 → message 同步响应带 info.error（终态）。
          events.add(
            jsonEncode({
              'type': 'session.status',
              'properties': {
                'sessionID': sid,
                'status': {
                  'type': 'retry',
                  'attempt': 1,
                  'message': injectRetry,
                },
              },
            }),
          );
          if (!retryRecovers) {
            await Future.delayed(const Duration(milliseconds: 400));
            req.response
              ..headers.contentType = ContentType.json
              ..write(
                jsonEncode({
                  'info': {
                    'finish': 'error',
                    'error': {
                      'name': 'APIError',
                      'data': {'message': injectRetry, 'statusCode': 429},
                    },
                  },
                  'parts': [],
                }),
              );
            await req.response.close();
            return;
          }
          await Future.delayed(const Duration(milliseconds: 300));
        }
        emit('Hel');
        emit('Hello <$text>');
        events.add(
          jsonEncode({
            'type': 'session.status',
            'properties': {
              'sessionID': sid,
              'status': {'type': 'idle'},
            },
          }),
        );
        if (injectError != null) {
          // 上游失败：先推 session.error，再返回带 error 的同步结果
          events.add(
            jsonEncode({
              'type': 'session.error',
              'properties': {
                'sessionID': sid,
                'error': {
                  'name': 'APIError',
                  'data': {'message': injectError, 'statusCode': 429},
                },
              },
            }),
          );
        }
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'info': {
                'finish': 'stop',
                if (injectError != null)
                  'error': {
                    'name': 'APIError',
                    'data': {'message': injectError, 'statusCode': 429},
                  },
              },
              'parts': [
                {'type': 'text', 'text': 'Hello <$text>'},
              ],
            }),
          );
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
      healthUrl: 'http://127.0.0.1:${serve.port}/global/health',
    );
    runtime = UpstreamRuntime(def);
    await runtime.probe();
    registry = ModelRegistry()..rebuild([runtime]);
    proxy = ProxyServer(
      '127.0.0.1',
      0,
      'sk-gw',
      registry,
      usageDir: usageDir.path,
    );
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
      'POST',
      Uri.parse('http://127.0.0.1:${proxy.boundPort}$path'),
    );
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
        {'role': 'user', 'content': 'ping'},
      ],
      'stream': false,
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
        {'role': 'user', 'content': 'hi'},
      ],
      'stream': true,
    });
    expect(resp.statusCode, 200);
    final raw = await utf8.decodeStream(resp);
    final lines = raw.split('\n').where((l) => l.startsWith('data: ')).toList();
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
        {'role': 'user', 'content': 'anthropic-hi'},
      ],
      'max_tokens': 16,
    });
    expect(resp.statusCode, 200);
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(body['type'], 'message');
    final text = ((body['content'] as List).first['text'] ?? '') as String;
    expect(text, contains('anthropic-hi'));
  });

  test('Anthropic 流式 CLI 返回原生事件而非 OpenAI chunk', () async {
    final response = await gw('/v1/messages', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'hello'},
      ],
      'max_tokens': 16,
      'stream': true,
    });
    final text = await utf8.decodeStream(response);
    expect(response.statusCode, 200);
    expect(text, contains('event: message_start'));
    expect(text, contains('event: content_block_delta'));
    expect(text, contains('event: message_stop'));
    expect(text, isNot(contains('chat.completion.chunk')));
    expect(text, isNot(contains('[DONE]')));
  });

  test('serve 未就绪时快速 503，不 spawn 失败刷屏', () async {
    // 关掉 mock 让 re-probe 也失败，走「不可用」503 分支
    serveClosed = true;
    await serve.close(force: true);
    runtime.health = UpstreamHealth.checking;
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'hi'},
      ],
    });
    expect(resp.statusCode, 503);
    runtime.health = UpstreamHealth.healthy;
  });

  test('额度耗尽 → 换出口后同一请求重试并成功', () async {
    injectError = 'Free usage exceeded, subscribe to Go';
    var rotated = 0;
    proxy.onRotateEgress = (id, _) async {
      rotated++;
      // 换到新出口后上游恢复正常（真实场景是换 IP 后额度可用）。
      injectError = null;
      return true;
    };
    addTearDown(() => proxy.onRotateEgress = null);

    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'ping'},
      ],
      'stream': false,
    });
    final raw = await utf8.decodeStream(resp);
    expect(resp.statusCode, 200, reason: raw);
    expect(rotated, 1, reason: '应触发一次出口轮换');
    final body = jsonDecode(raw);
    expect(body['choices'][0]['message']['content'], contains('ping'));
  });

  test('出口连不通 → 换出口后同请求恢复，失败不污染额度回调', () async {
    injectError = 'Cannot connect to API: Unable to connect';
    var rotated = 0;
    var quotaCalls = 0;
    proxy.onRotateEgress = (id, _) async {
      rotated++;
      injectError = null;
      return true;
    };
    proxy.onQuotaExhausted = (_, _) => quotaCalls++;
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/deepseek-v4.1-flash-free',
      'messages': [
        {'role': 'user', 'content': 'ping'},
      ],
    });
    final raw = await utf8.decodeStream(resp);
    expect(resp.statusCode, 200, reason: raw);
    expect(rotated, 1);
    expect(quotaCalls, 0);
  });

  test('出口连不通 → 换出口失败时如实报 502', () async {
    injectError = 'Cannot connect to API: Unable to connect';
    proxy.onRotateEgress = (id, _) async => false;
    addTearDown(() => proxy.onRotateEgress = null);

    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'ping'},
      ],
      'stream': false,
    });
    final raw = await utf8.decodeStream(resp);
    expect(resp.statusCode, 502, reason: raw);
    expect(raw, contains('egress_unreachable'));
  });

  test('前两个出口连接失败，第三个成功且不再轮换', () async {
    injectRetry = 'Cannot connect to API: Unable to connect';
    var rotations = 0;
    proxy.onRotateEgress = (_, _) async {
      rotations++;
      if (rotations == 2) injectRetry = null;
      return true;
    };
    final response = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'third works'},
      ],
    });
    final raw = await utf8.decodeStream(response);
    expect(response.statusCode, 200, reason: raw);
    expect(rotations, 2);
    expect(messageCount, 3);
    injectRetry = null;
  });

  test('六个出口均失败：返回错误，绝不发起第七次调用', () async {
    // 额度按出口 IP 隔离（2026-11-05 实测：池里约一半出口有额度），
    // 只试 3 次命中率不够——尝试预算放宽到 6 次。
    injectRetry = 'Cannot connect to API: Unable to connect';
    var rotations = 0;
    proxy.onRotateEgress = (_, _) async {
      rotations++;
      return true;
    };
    final response = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'fail'},
      ],
    });
    final raw = await utf8.decodeStream(response);
    expect(response.statusCode, 502, reason: raw);
    expect(rotations, 5, reason: '首发 + 5 次轮换 = 6 个出口');
    expect(messageCount, 6);
    injectRetry = null;
  });

  test('整池烧穿已知期内：快速 429 附恢复时刻，不再 6 轮轮换白等', () async {
    // 回归 2026-11-06：共享出口的日额度被同网络其他用户烧穿时（6 轮轮换全
    // free-limit），每个请求都要白等 2 分钟才报错。prepare 抛
    // ZenQuotaExhausted 必须直接映射成快速 429。
    proxy.onPrepareOpenCode = () async {
      throw ZenQuotaExhausted(
        '整池烧穿，预计 08:54 前后恢复',
        DateTime.now().add(const Duration(hours: 8)),
      );
    };
    addTearDown(() => proxy.onPrepareOpenCode = null);

    final sw = Stopwatch()..start();
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/deepseek-v4.1-flash-free',
      'messages': [
        {'role': 'user', 'content': 'ping'},
      ],
    });
    final raw = await utf8.decodeStream(resp);
    final elapsed = sw.elapsedMilliseconds;
    expect(resp.statusCode, 429, reason: raw);
    final body = jsonDecode(raw);
    expect(body['error']['code'], 'free_quota_exhausted');
    expect(body['error']['message'], contains('08:54'));
    expect(elapsed, lessThan(5000), reason: '烧穿期内必须快速失败（实测原为 2 分钟）');
  });

  test('CLI 请求结束后释放出口保护（成功和失败）', () async {
    var prepared = 0;
    var finished = 0;
    proxy.onPrepareOpenCode = () async {
      prepared++;
    };
    final signals = [Completer<void>(), Completer<void>()];
    proxy.onOpenCodeFinished = () {
      signals[finished].complete();
      finished++;
    };
    final response = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'ping'},
      ],
    });
    await response.drain<void>();
    await signals[0].future.timeout(const Duration(seconds: 3));
    expect(prepared, 1);
    expect(finished, 1);
    injectError = 'Cannot connect to API';
    final failed = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'ping'},
      ],
    });
    await failed.drain<void>();
    await signals[1].future.timeout(const Duration(seconds: 3));
    expect(prepared, 2);
    expect(finished, 2);
  });

  test('上游额度耗尽 → 429 rate_limit，不再挂到超时', () async {
    injectError = 'Free usage limit reached. Subscribe to OpenCode Go';
    final sw = Stopwatch()..start();
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'hi'},
      ],
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
        {'role': 'user', 'content': 'hi'},
      ],
    });
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(resp.statusCode, 502);
    expect(body['error']['message'], contains('Invalid credential'));
    injectError = null;
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('额度 retry 不掐死：CLI 退避后自愈 → 200（11-04 误杀回归）', () async {
    // 关键回归：真 CLI 收到 retry 后常在 17~71s 自愈成功（同出口）。旧实现见
    // retry 就掐死本轮并换出口，导致一批本来会成功的请求全被误杀。
    injectRetry = 'Free usage exceeded, subscribe to OpenCode Go to keep going';
    retryRecovers = true; // retry 事件后 CLI 继续正常输出
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'hi'},
      ],
    });
    final raw = await utf8.decodeStream(resp);
    expect(resp.statusCode, 200, reason: raw);
    expect(jsonDecode(raw)['choices'][0]['message']['content'], contains('Hello'));
    injectRetry = null;
    retryRecovers = false;
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('额度 retry 后终态 error（重试预算耗尽）→ 429', () async {
    // retry 本身不中止；只有同步响应带回 info.error（CLI 重试放弃）才落 429。
    injectRetry = 'Free usage exceeded, subscribe to OpenCode Go to keep going';
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'hi'},
      ],
    });
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(resp.statusCode, 429, reason: '$body');
    expect(body['error']['code'], 'free_quota_exhausted');
    injectRetry = null;
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('流式 + 额度 retry 后终态 error → 干净 429（未提交不写流内错误帧）', () async {
    injectRetry = 'Free usage exceeded, subscribe to OpenCode Go to keep going';
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'hi'},
      ],
      'stream': true,
    });
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(resp.statusCode, 429, reason: '$body');
    expect(body['error']['code'], 'free_quota_exhausted');
    injectRetry = null;
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('中文内容（系统提示/用户输入）不再触发 latin1 编码崩溃', () async {
    // 回归：content-type 无 charset 时 Dart write(String) 按 latin1 编码，
    // CJK 直接抛 "Contains invalid characters"（ZCode 提示词必含中文）
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'system', 'content': '你是 ZCode 编码助手（胡天泽的中文提示词）'},
        {'role': 'user', 'content': '你好，请回复 OK'},
      ],
      'stream': false,
    });
    final raw = await utf8.decodeStream(resp);
    expect(resp.statusCode, 200, reason: raw);
    final body = jsonDecode(raw);
    expect(body['choices'][0]['message']['content'], contains('你好'));
  });

  test('看门狗：只有心跳没有会话事件时停滞被中止（心跳不续命）', () async {
    // 上游 hang：message 端点挂住，/event 只推心跳（进程活着≠本轮有进展）
    hangMessage = true;
    final ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      events.add(jsonEncode({'type': 'server.heartbeat', 'properties': {}}));
    });
    addTearDown(ticker.cancel);
    final previous = OpenCodeApi.stallTimeout;
    OpenCodeApi.stallTimeout = const Duration(seconds: 2);
    addTearDown(() => OpenCodeApi.stallTimeout = previous);
    final sw = Stopwatch()..start();
    final resp = await gw('/v1/chat/completions', {
      'model': 'zen/big-pickle',
      'messages': [
        {'role': 'user', 'content': 'hi'},
      ],
      'stream': false,
    });
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(resp.statusCode, 504, reason: '$body');
    expect(body['error']['message'], contains('无任何响应'));
    // 心跳若在续命，这里会是 30s+
    expect(sw.elapsedMilliseconds / 1000, lessThan(10));
    hangMessage = false;
  }, timeout: const Timeout(Duration(seconds: 40)));

  for (final anthropic in [false, true]) {
    test('部分输出后真停滞：${anthropic ? 'Anthropic' : 'OpenAI'} 错误收尾并释放队列', () async {
      partialHang = true;
      final previous = OpenCodeApi.generationIdleTimeout;
      OpenCodeApi.generationIdleTimeout = const Duration(milliseconds: 500);
      addTearDown(() => OpenCodeApi.generationIdleTimeout = previous);
      var rotations = 0;
      proxy.onRotateEgress = (_, _) async {
        rotations++;
        return true;
      };
      final response = await gw(
        anthropic ? '/v1/messages' : '/v1/chat/completions',
        {
          'model': 'zen/big-pickle',
          'max_tokens': 100,
          'stream': true,
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
        },
      );
      final raw = await utf8
          .decodeStream(response)
          .timeout(const Duration(seconds: 8));
      expect(raw, contains('partial answer'));
      expect(raw, contains('generation_idle_timeout'));
      expect(abortCount, 1);
      expect(messageCount, 1);
      expect(rotations, 0);
      if (anthropic) {
        expect(raw, contains('event: error'));
        expect(raw, isNot(contains('event: message_stop')));
      } else {
        expect(raw, contains('[DONE]'));
        expect(raw, isNot(contains('"finish_reason":"stop"')));
      }
      partialHang = false;
      final next = await gw('/v1/chat/completions', {
        'model': 'zen/big-pickle',
        'messages': [
          {'role': 'user', 'content': 'next'},
        ],
      });
      expect(next.statusCode, 200);
      expect(await utf8.decodeStream(next), contains('next'));
    });
  }
}
