// 上游非 200 错误透传回归（2026-11-05）：
// WorkBuddy 号池拒绝超长上下文时返回顶层 {"code":11115,"msg":"prompt is
// too long: 100001 tokens > 100000 maximum"}——既没有 error.message 也没有
// message 字段。网关旧实现把它压成「供应商 workbuddy HTTP 400」，真实原因
// 全丢；且 type 给了 upstream_error，客户端（ZCode）当可重试错误连发 17 次
// 同一请求（每 4-5s 一次，全部无效）。
//
// 本测试锁两件事：
// 1. 提取顶层 msg：错误消息必须带上游原文；
// 2. 400 的类型必须是 invalid_request_error（OpenAI 标准里非重试类），
//    防止客户端对确定性拒绝反复重发。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/proxy.dart';
import 'package:zeroapi/gateway/upstream.dart';

void main() {
  late HttpServer fake;
  late ProxyServer proxy;
  late HttpClient client;

  setUp(() async {
    client = HttpClient();
    fake = await HttpServer.bind('127.0.0.1', 0);
    fake.listen((req) async {
      final path = req.uri.path;
      if (path.endsWith('/models')) {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'data': [
              {'id': 'hy3'},
            ],
          }));
        await req.response.close();
        return;
      }
      if (path.endsWith('/chat/completions')) {
        await utf8.decodeStream(req);
        req.response
          ..statusCode = 400
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'code': 11115,
              'msg':
                  'prompt is too long: 100001 tokens > 100000 maximum',
              'retry_policy': {'retry': false},
            }),
          );
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    final def = UpstreamDef(
      id: 'workbuddy',
      type: 'managed',
      label: 'wb',
      baseUrl: 'http://127.0.0.1:${fake.port}/v1',
    );
    final runtime = UpstreamRuntime(def);
    await runtime.probe();
    final registry = ModelRegistry()..rebuild([runtime]);
    proxy = ProxyServer('127.0.0.1', 0, 'sk-gw', registry);
    await proxy.start();
  });

  tearDown(() async {
    client.close(force: true);
    await proxy.stop();
    await fake.close(force: true);
  });

  Future<({int status, Map<String, dynamic> body})> chat({bool anthropic = false}) async {
    final req = await client.openUrl(
      'POST',
      Uri.parse('http://127.0.0.1:${proxy.boundPort}/v1/${anthropic ? 'messages' : 'chat/completions'}'),
    );
    req.headers.set('authorization', 'Bearer sk-gw');
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode({
        'model': anthropic ? 'workbuddy/hy3' : 'hy3',
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
      }),
    );
    final resp = await req.close();
    final body = jsonDecode(await utf8.decoder.bind(resp).join())
        as Map<String, dynamic>;
    return (status: resp.statusCode, body: body);
  }

  test('上游 400 顶层 msg 透传，类型标为不可重试的 invalid_request_error', () async {
    final r = await chat();
    expect(r.status, 400);
    final err = r.body['error'] as Map<String, dynamic>;
    expect(
      err['message'],
      contains('prompt is too long: 100001 tokens > 100000 maximum'),
      reason: '真实拒绝原因必须透传给客户端',
    );
    expect(
      err['type'],
      'invalid_request_error',
      reason: '400 若标成 upstream_error，客户端会当可重试错误反复重发',
    );
  });

  test('Anthropic 侧同样：400 → invalid_request_error', () async {
    final r = await chat(anthropic: true);
    expect(r.status, 400);
    expect(r.body['type'], 'error');
    final err = r.body['error'] as Map<String, dynamic>;
    expect(err['type'], 'invalid_request_error');
    expect(err['message'], contains('prompt is too long'));
  });
}
