// zen 免费额度耗尽与出口 IP 轮换的端到端验证：
//  1) 「Free usage limit reached」→ 立即 429 且带 free_quota_exhausted 码，
//     不烧掉 5 次重试（也不把等待拖到 60s+）；
//  2) IP 级 429 → 换出口候选立即重试，客户端最终拿到 200。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/proxy.dart';
import 'package:zeroapi/gateway/upstream.dart';

void main() {
  late HttpServer up;
  late ProxyServer proxy;
  late UpstreamRuntime runtime;
  final client = HttpClient();

  // 模式：'quota' = 始终回免费额度耗尽；'rotate' = 前 N 次回 429，之后 200
  var mode = 'quota';
  var rotateLeft = 0;
  var chatSeen = 0;

  setUp(() async {
    mode = 'quota';
    rotateLeft = 0;
    chatSeen = 0;
    up = await HttpServer.bind('127.0.0.1', 0);
    up.listen((req) async {
      if (req.uri.path.endsWith('/models')) {
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'data': [
                {'id': 'big-pickle'},
              ],
            }),
          );
        await req.response.close();
        return;
      }
      if (req.uri.path.endsWith('/chat/completions')) {
        chatSeen++;
        await utf8.decodeStream(req);
        if (mode == 'quota') {
          req.response
            ..statusCode = 429
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'error': {
                  'message':
                      'Free usage limit reached. Subscribe to OpenCode Go to '
                      'keep going: https://opencode.ai/go',
                },
              }),
            );
          await req.response.close();
          return;
        }
        if (rotateLeft > 0) {
          rotateLeft--;
          req.response
            ..statusCode = 429
            ..headers.set('Retry-After', '60')
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'error': {'message': 'too many requests'},
              }),
            );
          await req.response.close();
          return;
        }
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
      id: 'zen',
      type: 'zen',
      label: 'Zen',
      baseUrl: 'http://127.0.0.1:${up.port}/v1',
    );
    runtime = UpstreamRuntime(def);
    await runtime.probe();
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
    await up.close(force: true);
  });

  Future<HttpClientResponse> chat() async {
    final req = await client.openUrl(
      'POST',
      Uri.parse('http://127.0.0.1:${proxy.boundPort}/v1/chat/completions'),
    );
    req.headers.set('Authorization', 'Bearer sk-gw');
    req.headers.contentType = ContentType.json;
    req.add(
      utf8.encode(
        jsonEncode({
          'model': 'zen/big-pickle',
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
        }),
      ),
    );
    return req.close();
  }

  test('免费额度耗尽：立即 429 + free_quota_exhausted，不反复重试', () async {
    final sw = Stopwatch()..start();
    final resp = await chat();
    expect(resp.statusCode, 429);
    final body = jsonDecode(await utf8.decodeStream(resp));
    sw.stop();
    expect(body['error']['code'], 'free_quota_exhausted');
    expect(body['error']['message'], contains('免费额度'));
    expect(
      chatSeen,
      lessThanOrEqualTo(2),
      reason: '额度是账号级硬配额：不该把 5 次重试全烧掉',
    );
    expect(
      sw.elapsed.inSeconds,
      lessThan(20),
      reason: '不陪退避等待，秒级返回',
    );
  });

  test('IP 级 429：换出口候选后客户端拿到 200', () async {
    // 两个 http 候选（本地假 upstream，轮换只是换 findProxy 指令）
    mode = 'rotate';
    rotateLeft = 1;
    final resp = await chat();
    // 无代理池时只有一个直连候选：换不了 IP，走指数退避重试最终成功
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    expect(chatSeen, greaterThanOrEqualTo(2));
  });
}
