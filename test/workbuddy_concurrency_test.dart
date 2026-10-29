// WorkBuddy 单账号高并发优化：
//  1) 同一模型的并发请求按可用账号数排队（1 个账号 = 1 个并发槽），
//     不让两个会话同时打到上游把号撞出 429；
//  2) 上游仍回 429 时（号池账号被别的客户端占用），网关退避重试，
//     客户端拿到的是最终成功响应。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/proxy.dart';
import 'package:zeroapi/gateway/upstream.dart';

void main() {
  late HttpServer hub;
  late UpstreamRuntime runtime;
  late ProxyServer proxy;
  final client = HttpClient();

  var active = 0;
  var maxActive = 0;
  var chatSeen = 0;
  var failuresLeft = 0;

  setUp(() async {
    active = 0;
    maxActive = 0;
    chatSeen = 0;
    failuresLeft = 0;
    hub = await HttpServer.bind('127.0.0.1', 0);
    hub.listen((req) async {
      final path = req.uri.path;
      if (path.endsWith('/models')) {
        // 两区目录完全相同 → hy3 是共有模型（走并发分散/闸门逻辑）
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'data': [
                {'id': 'hy3'},
              ],
            }),
          );
        await req.response.close();
        return;
      }
      if (path.endsWith('/chat/completions')) {
        chatSeen++;
        await utf8.decodeStream(req);
        if (failuresLeft > 0) {
          failuresLeft--;
          req.response
            ..statusCode = 429
            ..headers.set('Retry-After', '0')
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'error': {'message': 'usage exceeds frequency limit'},
              }),
            );
          await req.response.close();
          return;
        }
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        active--;
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'ok'},
                },
              ],
              'usage': {'prompt_tokens': 1, 'completion_tokens': 1},
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
      label: 'WorkBuddy',
      baseUrl: 'http://127.0.0.1:${hub.port}/v1',
      catalogPaths: const ['/models?realm=intl', '/models?realm=cn'],
    );
    runtime = UpstreamRuntime(def);
    expect(await runtime.probe(), isTrue);
    // 号池只有一个国内账号
    runtime.readyRealms = {'cn'};
    runtime.readyAccounts = {'cn': 1};
    proxy = ProxyServer(
      '127.0.0.1',
      0,
      'sk-gw',
      ModelRegistry()..rebuild([runtime]),
    );
    await proxy.start();
  });

  tearDown(() async {
    await proxy.stop();
    await hub.close(force: true);
  });

  Future<HttpClientResponse> chat(String content) async {
    final req = await client.openUrl(
      'POST',
      Uri.parse('http://127.0.0.1:${proxy.boundPort}/v1/chat/completions'),
    );
    req.headers.set('Authorization', 'Bearer sk-gw');
    req.headers.contentType = ContentType.json;
    req.add(
      utf8.encode(
        jsonEncode({
          'model': 'workbuddy/hy3',
          'messages': [
            {'role': 'user', 'content': content},
          ],
        }),
      ),
    );
    return req.close();
  }

  test('单账号：同一模型并发请求排队，上游同时只看到 1 个', () async {
    final rs = await Future.wait([chat('A'), chat('B')]);
    for (final r in rs) {
      expect(r.statusCode, 200);
      await r.drain<void>();
    }
    expect(chatSeen, 2);
    expect(maxActive, 1, reason: '1 个账号只能有 1 个并发槽，避免撞 429');
  });

  test('429 自动退避重试，客户端拿到成功响应', () async {
    failuresLeft = 1;
    final resp = await chat('A');
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    expect(chatSeen, 2, reason: '首次 429 + 重试一次');
  });
}
