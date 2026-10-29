// zen 额度耗尽/地理拒绝的换出口重试（2026-10-22 实测机制）：
//  1) 额度按「出口 IP × 天」计、地理拒绝按出口国家计——换一个出口就有救：
//     第一个节点报 QUOTA → 拉黑该节点（当天 UTC）+ 换下一个节点重试成功；
//  2) 地理 403 同样换出口；
//  3) 没有任何可换出口（直连单 IP）：不空转重试，立即如实 429。
// 每个「节点」就是一个本地假上游：findProxy 模式下客户端把绝对 URI 发给
// 代理，假上游按 path 应答即可，无需真实隧道。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/proxy.dart';
import 'package:zeroapi/gateway/proxypool.dart';
import 'package:zeroapi/gateway/upstream.dart';

class FakeZen {
  final HttpServer server;
  final String behavior; // 'quota' | 'geo' | 'ok' | 'flaky'
  int hits = 0;
  FakeZen(this.server, this.behavior);
}

void main() {
  final client = HttpClient();
  late List<FakeZen> hubs;
  late ProxyPool pool;
  late ProxyServer proxy;
  late UpstreamRuntime runtime;

  Future<FakeZen> startHub(String behavior) async {
    final srv = await HttpServer.bind('127.0.0.1', 0);
    final hub = FakeZen(srv, behavior);
    srv.listen((req) async {
      final path = req.uri.path;
      if (path.endsWith('/models')) {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'data': [
              {'id': 'big-pickle'},
            ],
          }));
        await req.response.close();
        return;
      }
      if (path.endsWith('/chat/completions')) {
        hub.hits++;
        await utf8.decodeStream(req);
        if (hub.behavior == 'quota') {
          req.response
            ..statusCode = 429
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'error': {
                  'message':
                      'Free usage limit reached. Subscribe to OpenCode Go: '
                      'https://opencode.ai/go',
                },
              }),
            );
          await req.response.close();
          return;
        }
        if (hub.behavior == 'geo') {
          req.response
            ..statusCode = 403
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'error': {'message': 'This model is not available in your country'},
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
    return hub;
  }

  Future<void> setUpPool(String baseUrl, List<FakeZen> nodes) async {
    pool = ProxyPool();
    final group = ProxyGroup(name: '假池', strategy: 'round-robin');
    for (final n in nodes) {
      group.nodes.add(
        ProxyNode(type: 'http', host: '127.0.0.1', port: n.server.port),
      );
    }
    pool.groups.add(group);
    pool.assignments[ProxyPool.pUpstream('zen')] = '假池';
    activePool = pool;
    final def = UpstreamDef(
      id: 'zen',
      type: 'zen',
      label: 'Zen',
      baseUrl: baseUrl,
    );
    runtime = UpstreamRuntime(def);
    expect(await runtime.probe(), isTrue);
    proxy = ProxyServer(
      '127.0.0.1',
      0,
      'sk-gw',
      ModelRegistry()..rebuild([runtime]),
    );
    await proxy.start();
  }

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

  tearDown(() async {
    await proxy.stop();
    for (final h in hubs) {
      await h.server.close(force: true);
    }
    activePool = null;
  });

  test('额度耗尽：拉黑坏节点并换下一个出口，客户端拿到 200', () async {
    hubs = [await startHub('quota'), await startHub('ok')];
    // 注意 baseUrl 不含 workers.dev → 直连+池模式（换节点才有意义）
    await setUpPool('http://zen.invalid/v1', hubs);
    final resp = await chat();
    expect(resp.statusCode, 200, reason: 'A 报额度后应换 B 成功');
    await resp.drain<void>();
    expect(hubs[0].hits, 1);
    expect(hubs[1].hits, 1);
    final aId = pool.groups.single.nodes[0].id;
    final bId = pool.groups.single.nodes[1].id;
    expect(
      pool.isQuotaSpent(aId),
      isTrue,
      reason: 'A 今天额度耗尽应被拉黑（UTC 零点翻篇）',
    );
    expect(pool.isQuotaSpent(bId), isFalse);
  });

  test('地理拒绝：同样换出口重试直到成功', () async {
    hubs = [
      await startHub('geo'),
      await startHub('ok'),
    ];
    await setUpPool('http://zen.invalid/v1', hubs);
    final resp = await chat();
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    expect(hubs[0].hits, 1);
    expect(hubs[1].hits, 1);
    // 地理拒绝不是额度：不应把节点拉黑一整天
    expect(
      pool.isQuotaSpent(pool.groups.single.nodes[0].id),
      isFalse,
    );
  });

  test('无池可换（直连单 IP 额度耗尽）：不空转，立即如实 429', () async {
    hubs = [await startHub('quota')];
    // baseUrl 不含 workers.dev 且不设 pool：无任何可换出口
    activePool = null;
    final def = UpstreamDef(
      id: 'zen',
      type: 'zen',
      label: 'Zen',
      baseUrl: 'http://127.0.0.1:${hubs[0].server.port}/v1',
    );
    runtime = UpstreamRuntime(def);
    expect(await runtime.probe(), isTrue);
    proxy = ProxyServer(
      '127.0.0.1',
      0,
      'sk-gw',
      ModelRegistry()..rebuild([runtime]),
    );
    await proxy.start();
    final resp = await chat();
    expect(resp.statusCode, 429);
    final body = jsonDecode(await utf8.decoder.bind(resp).join());
    expect(body['error']['code'], 'free_quota_exhausted');
    expect(hubs[0].hits, 1, reason: '没有可换的出口就不该反复撞');
  });

  test('全部节点都报额度：清掉当天标记重头轮换', () async {
    hubs = [await startHub('quota'), await startHub('quota')];
    await setUpPool('http://zen.invalid/v1', hubs);
    final resp = await chat();
    expect(resp.statusCode, 429);
    final body = jsonDecode(await utf8.decoder.bind(resp).join());
    expect(body['error']['code'], 'free_quota_exhausted');
    // 尝试序列：A(0)→B(1)→全拉黑清标记→A(2)→B(3) 达上限如实 429
    expect(hubs[0].hits, 2);
    expect(hubs[1].hits, 2);
  });
}
