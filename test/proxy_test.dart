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
  final client = HttpClient();

  setUp(() async {
    fake = await HttpServer.bind('127.0.0.1', 0);
    baseUrl = 'http://127.0.0.1:${fake.port}/v1';
    fake.listen((req) async {
      final path = req.uri.path;
      if (path.endsWith('/models')) {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'data': [
              {'id': 'gpt-test'},
              {'id': 'other-model'},
            ]
          }));
        await req.response.close();
        return;
      }
      if (path.endsWith('/chat/completions')) {
        final body = jsonDecode(await utf8.decodeStream(req));
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'choices': [
              {'message': {'content': 'hello ${body['model']}'}}
            ],
            'usage': {'prompt_tokens': 10, 'completion_tokens': 5}
          }));
        await req.response.close();
        return;
      }
      if (path.endsWith('/responses')) {
        final body = jsonDecode(await utf8.decodeStream(req));
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'id': 'resp_1',
            'object': 'response',
            'model': body['model'],
            'output': [],
            'usage': {'input_tokens': 7, 'output_tokens': 3}
          }));
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
    proxy = ProxyServer('127.0.0.1', 0, 'sk-gw', registry);
    await proxy.start();
  });

  tearDown(() async {
    await proxy.stop();
    await fake.close(force: true);
  });

  Future<HttpClientResponse> gw(String method, String path,
      [Object? json]) async {
    final req = await client.openUrl(
        method, Uri.parse('http://127.0.0.1:${proxy.boundPort}$path'));
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
    final resp = await gw('POST', '/v1/chat/completions',
        {'model': 'fake/gpt-test', 'messages': []});
    expect(resp.statusCode, 200);
    final body = jsonDecode(await utf8.decodeStream(resp));
    expect(body['choices'][0]['message']['content'], 'hello gpt-test');
  });

  test('responses 透传并按 input/output_tokens 记账', () async {
    final resp =
        await gw('POST', '/v1/responses', {'model': 'fake/gpt-test', 'input': 'hi'});
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

  test('usageRange 今日聚合含内存记账与小时趋势', () async {
    await gw('POST', '/v1/chat/completions',
        {'model': 'fake/gpt-test', 'messages': []});
    await gw('POST', '/v1/chat/completions',
        {'model': 'gpt-test', 'messages': []});
    final s = await proxy.usageRange(days: 1);
    expect(s.requests, greaterThanOrEqualTo(2));
    expect(s.byModel['fake/gpt-test'], greaterThanOrEqualTo(1));
    expect(s.trend.length, greaterThanOrEqualTo(1)); // 小时桶
    // tokens 来自 fake 上游固定值（prompt 10 / completion 5 每次）
    expect(s.promptTokens, greaterThanOrEqualTo(10));
  });

  test('错误网关 key 返回 401', () async {
    final req = await client.openUrl(
        'POST', Uri.parse('http://127.0.0.1:${proxy.boundPort}/v1/responses'));
    req.headers.set('Authorization', 'Bearer wrong');
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode({'model': 'fake/gpt-test'})));
    final resp = await req.close();
    expect(resp.statusCode, 401);
  });
}
