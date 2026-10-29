import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/proxy.dart';
import 'package:zeroapi/gateway/upstream.dart';

/// 端到端测试：本地起 fake 供应商 + ProxyServer，验证路由与透传。
void main() {
  late HttpServer fake;
  late ProxyServer proxy;
  late ModelRegistry registry;
  late UpstreamRuntime runtime;
  late String baseUrl;
  late Directory usageDir;
  final client = HttpClient();

  setUp(() async {
    usageDir = await Directory.systemTemp.createTemp('zeroapi-test-');
    fake = await HttpServer.bind('127.0.0.1', 0);
    baseUrl = 'http://127.0.0.1:${fake.port}/v1';
    fake.listen((req) async {
      final path = req.uri.path;
      if (path.endsWith('/models')) {
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'data': [
                {'id': 'gpt-test'},
                {'id': 'other-model'},
              ],
            }),
          );
        await req.response.close();
        return;
      }
      if (path.endsWith('/chat/completions')) {
        final body = jsonDecode(await utf8.decodeStream(req));
        if (body['stream'] == true) {
          // 含 CJK 与 em-dash 的流式输出：latin1 编码会在写响应体时抛
          // 'Contains invalid characters'，用于回归 SSE utf-8 修复
          req.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          req.response.add(
            utf8.encode(
              'data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"你好 — 底层"}}]}\n\n',
            ),
          );
          req.response.add(
            utf8.encode(
              'data: {"id":"c1","object":"chat.completion.chunk","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":4}}\n\n',
            ),
          );
          req.response.add(utf8.encode('data: [DONE]\n\n'));
          await req.response.close();
          return;
        }
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'hello ${body['model']}'},
                },
              ],
              'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
            }),
          );
        await req.response.close();
        return;
      }
      if (path.endsWith('/responses')) {
        final body = jsonDecode(await utf8.decodeStream(req));
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'id': 'resp_1',
              'object': 'response',
              'model': body['model'],
              'output': [],
              'usage': {'input_tokens': 7, 'output_tokens': 3},
            }),
          );
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    final def = UpstreamDef(id: 'fake', baseUrl: baseUrl, apiKey: 'sk-up');
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
    await fake.close(force: true);
    try {
      usageDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<HttpClientResponse> gw(
    String method,
    String path, [
    Object? json,
  ]) async {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${proxy.boundPort}$path'),
    );
    req.headers.set('Authorization', 'Bearer sk-gw');
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(json)));
    }
    return req.close();
  }

  test('registry 暴露带前缀路由与唯一裸名', () {
    expect(registry.resolve('fake/gpt-test'), isNotNull);
    expect(registry.resolve('gpt-test')!.bare, true);
    expect(registry.resolve('unknown'), isNull);
  });

  test('chat/completions 透传并翻译模型名', () async {
    final resp = await gw('POST', '/v1/chat/completions', {
      'model': 'fake/gpt-test',
      'messages': [],
    });
    expect(resp.statusCode, 200);
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(body['choices'][0]['message']['content'], 'hello gpt-test');
  });

  test('responses 透传并按 input/output_tokens 记账', () async {
    final resp = await gw('POST', '/v1/responses', {
      'model': 'fake/gpt-test',
      'input': 'hi',
    });
    expect(resp.statusCode, 200);
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(body['object'], 'response');
    expect(body['model'], 'gpt-test');
    expect(proxy.usageToday.promptTokens, 7);
    expect(proxy.usageToday.completionTokens, 3);
  });

  test('未知模型返回 404', () async {
    final resp = await gw('POST', '/v1/responses', {'model': 'nope'});
    expect(resp.statusCode, 404);
  });

  test('未知模型触发重探后命中', () async {
    // 模拟路由表滞后：清空后按 stale 解析不到，但上游实际有该模型
    registry.rebuild([]);
    proxy.onUnknownModel = () async {
      await runtime.probe();
      registry.rebuild([runtime]);
    };
    final resp = await gw('POST', '/v1/chat/completions', {
      'model': 'gpt-test',
      'messages': [],
    });
    expect(resp.statusCode, 200);
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(body['choices'][0]['message']['content'], 'hello gpt-test');
  });

  test('重探后仍不存在的模型返回 404', () async {
    registry.rebuild([]);
    proxy.onUnknownModel = () async {
      await runtime.probe();
      registry.rebuild([runtime]);
    };
    final resp = await gw('POST', '/v1/chat/completions', {
      'model': 'truly-unknown',
      'messages': [],
    });
    expect(resp.statusCode, 404);
  });

  test('usageRange 今日聚合含内存记账与小时趋势', () async {
    await gw('POST', '/v1/chat/completions', {
      'model': 'fake/gpt-test',
      'messages': [],
    });
    await gw('POST', '/v1/chat/completions', {
      'model': 'gpt-test',
      'messages': [],
    });
    final s = await proxy.usageRange(days: 1);
    expect(s.requests, greaterThanOrEqualTo(2));
    // 带前缀与裸名归一到同一规范名：合并为 gpt-test 两条，不再分裂
    expect(s.byModel['gpt-test'], greaterThanOrEqualTo(2));
    expect(s.byModel.containsKey('fake/gpt-test'), false);
    expect(s.trend.length, greaterThanOrEqualTo(1)); // 小时桶
    // tokens 来自 fake 上游固定值（prompt 10 / completion 5 每次）
    expect(s.promptTokens, greaterThanOrEqualTo(10));
    // 按 token 聚合：两次合并到 gpt-test（每次 15），带前缀键不出现
    expect(s.byModelTokens['gpt-test'], greaterThanOrEqualTo(30));
    expect(s.byModelTokens.containsKey('fake/gpt-test'), false);
  });

  test('SSE 含 CJK 不崩：/v1/messages 流式（Anthropic 转换路径）完整读回', () async {
    final req = await client.openUrl(
      'POST',
      Uri.parse('http://127.0.0.1:${proxy.boundPort}/v1/messages'),
    );
    req.headers.set('Authorization', 'Bearer sk-gw');
    req.headers.contentType = ContentType.json;
    req.add(
      utf8.encode(
        jsonEncode({
          'model': 'fake/gpt-test',
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
          'stream': true,
          'max_tokens': 64,
        }),
      ),
    );
    final resp = await req.close();
    expect(resp.statusCode, 200);
    expect(resp.headers.contentType?.charset?.toLowerCase(), 'utf-8');
    final text = await utf8.decodeStream(resp);
    expect(text, contains('content_block_delta'));
    expect(text, contains('你好'));
    expect(text, contains('—')); // em-dash：latin1 写路径会在这里炸
    expect(text, contains('message_stop'));
  });

  test('SSE 含 CJK 不崩：/v1/chat/completions 流式（透传字节路径）', () async {
    final resp = await gw('POST', '/v1/chat/completions', {
      'model': 'fake/gpt-test',
      'messages': [],
      'stream': true,
    });
    expect(resp.statusCode, 200);
    expect(resp.headers.contentType?.charset?.toLowerCase(), 'utf-8');
    final text = await utf8.decodeStream(resp);
    expect(text, contains('你好'));
    expect(text, contains('—')); // em-dash 随上游原始字节透传，不经字符串编码
    expect(text, contains('data: [DONE]'));
  });

  test('usageRange 跨多文件聚合（回归：File 不可 sort 导致全 0 的静默崩溃）', () async {
    final dir = Directory(usageDir.path)..createSync(recursive: true);
    final y = DateTime.now().subtract(const Duration(days: 1));
    final yDay = y.toIso8601String().substring(0, 10);
    final tDay = DateTime.now().toIso8601String().substring(0, 10);
    // 昨天的文件（先写，文件名字典序在前）——两个文件才会触发 sort 比较
    File('${dir.path}/usage-$yDay.jsonl').writeAsStringSync(
      '${jsonEncode({'ts': '${yDay}T10:00:00.000', 'model': 'old-m', 'upstream': 'zen', 'prompt': 100, 'completion': 50, 'error': false})}\n',
    );
    // 今天已有内存记账（setUp 的 proxy 处理过 fake 请求）；再加备份文件不得计入
    File('${dir.path}/usage-$tDay.jsonl.bak-x').writeAsStringSync(
      '${jsonEncode({'ts': '${tDay}T09:00:00.000', 'model': 'ghost', 'upstream': 'zen', 'prompt': 999999, 'completion': 999999, 'error': false})}\n',
    );
    final s7 = await proxy.usageRange(days: 7);
    expect(s7.byModel['old-m'], 1);
    expect(s7.promptTokens, greaterThanOrEqualTo(100));
    expect(s7.byModel.containsKey('ghost'), false, reason: '备份文件不得混入');
    // 昨日桶存在且今日桶来自内存合并
    expect(s7.byDayTokens.containsKey(yDay.substring(5)), true);
  });

  test('错误网关 key 返回 401', () async {
    final req = await client.openUrl(
      'POST',
      Uri.parse('http://127.0.0.1:${proxy.boundPort}/v1/responses'),
    );
    req.headers.set('Authorization', 'Bearer wrong');
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode({'model': 'fake/gpt-test'})));
    final resp = await req.close();
    expect(resp.statusCode, 401);
  });

  test('密钥池：任意一把命中即放行，未知 key 401', () async {
    final dir2 = await Directory.systemTemp.createTemp('zeroapi-test-');
    final p2 = ProxyServer(
      '127.0.0.1',
      0,
      'sk-gw',
      registry,
      usageDir: dir2.path,
      keys: [GatewayKey('默认', 'sk-gw'), GatewayKey('手机', 'sk-phone')],
    );
    await p2.start();
    Future<int> callWith(String key) async {
      final req = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${p2.boundPort}/v1/models'),
      );
      req.headers.set('Authorization', 'Bearer $key');
      final r = await req.close();
      await r.drain();
      return r.statusCode;
    }

    expect(await callWith('sk-gw'), 200);
    expect(await callWith('sk-phone'), 200);
    expect(await callWith('nope'), 401);
    await p2.stop();
    dir2.deleteSync(recursive: true);
  });

  test('/v1/models 去重：同一模型只出现一条且优先来源前缀调用名', () async {
    final resp = await gw('GET', '/v1/models');
    final ids =
        ((jsonDecode(await utf8.decodeStream(resp)) as Map)['data'] as List)
            .map((m) => m['id'] as String)
            .toList();
    // 规范调用名是 <来源>/<模型>；裸名只作为兼容入口保留，不在清单里重复出现
    expect(ids, contains('fake/gpt-test'));
    expect(ids.contains('gpt-test'), false);
    expect(ids.toSet().length, ids.length, reason: '不应有重复条目');
  });

  test('非标准字段 thinking 被剥离，不再触发上游 400', () async {
    // fake 上游回显收到的 model；这里验证带 thinking 的请求不再报错且正常路由
    final resp = await gw('POST', '/v1/chat/completions', {
      'model': 'fake/gpt-test',
      'messages': [],
      'thinking': {'type': 'enabled', 'budget_tokens': 100},
    });
    expect(resp.statusCode, 200);
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(body['choices'][0]['message']['content'], 'hello gpt-test');
  });

  test('重启回填：当日 jsonl 在 start() 时载入内存用量', () async {
    final day = DateTime.now().toIso8601String().substring(0, 10);
    final dir = Directory(usageDir.path)..createSync(recursive: true);
    File('${dir.path}/usage-$day.jsonl').writeAsStringSync(
      '${jsonEncode({'ts': '${day}T08:00:00.000', 'model': 'rb-m1', 'upstream': 'zen', 'prompt': 11, 'completion': 7, 'error': false})}\n'
      '${jsonEncode({'ts': '${day}T08:30:00.000', 'model': 'rb-m2', 'upstream': 'zen', 'prompt': 3, 'completion': 2, 'error': true})}\n'
      '${jsonEncode({'ts': '${day}T23:59:59.000', 'model': 'rb-m3', 'upstream': 'zen', 'prompt': 1, 'completion': 1, 'error': false})}\n',
      mode: FileMode.append,
    );
    // 模拟重启：全新 ProxyServer 启动即带回今天的记账
    final p2 = ProxyServer(
      '127.0.0.1',
      0,
      'sk-gw',
      ModelRegistry(),
      usageDir: usageDir.path,
    );
    await p2.start();
    expect(p2.usageToday.requests, greaterThanOrEqualTo(3));
    expect(p2.usageToday.errors, greaterThanOrEqualTo(1));
    expect(p2.usageToday.promptTokens, greaterThanOrEqualTo(15));
    expect(p2.usageToday.byModelTokens['rb-m1'], greaterThanOrEqualTo(18));
    expect(p2.usageToday.trend['08'], greaterThanOrEqualTo(2));
    expect(p2.usageToday.trend['23'], greaterThanOrEqualTo(1));
    await p2.stop();
  });
}
