// 订阅拉取回归（2026-11-07）：
// 机场按 User-Agent 决定返回格式——clash 系 UA 给完整 YAML，未知 UA 给
// base64 的「剩余流量」假节点（ss://…@127.0.0.1:443，用户实测导入后只有
// 假节点、真节点一个没有）。本测试锁两件事：
// 1. fetchSubscriptionBody 必须以 clash 客户端 UA 请求；
// 2. 机场返回的假节点（loopback 主机）导入时被识别为风险节点。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/proxypool.dart';
import 'package:zeroapi/gateway/service.dart';

void main() {
  test('订阅拉取必须带 clash 客户端 UA（机场按 UA 决定返回格式）', () async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    String? ua;
    server.listen((req) async {
      ua = req.headers.value('user-agent');
      req.response
        ..headers.contentType = ContentType.text
        ..write('proxies: []');
      await req.response.close();
    });
    addTearDown(() async {
      await server.close(force: true);
    });

    final service = GatewayService();
    addTearDown(service.dispose);
    // 不校验返回内容（空 proxies 解析 0 节点），只抓 UA
    try {
      await service.fetchSubscriptionBody(
        'http://127.0.0.1:${server.port}/sub?token=x',
      );
    } catch (_) {
      // 解析 0 节点等结果不影响本断言
    }
    expect(
      ua,
      contains('clash'),
      reason: 'UA 不是 clash 客户端时，机场返回的是「剩余流量」假节点而不是真订阅',
    );
  });

  test('机场的 loopback 假节点（剩余流量桩）导入时被标记为风险', () {
    final pool = ProxyPool();
    // 真实桩的形状：ss://…@127.0.0.1:443#剩余流量：1132.11 GB
    final stub =
        'ss://YWVzLTEyOC1nY206MDA4NjA0MDItNGIwNC00NzE3LWIyNmMtMDI3OWYyZDdjZjMz@'
        '127.0.0.1:443#%E5%89%A9%E4%BD%99%E6%B5%81%E9%87%8F%EF%BC%9A1132.11%20GB';
    final nodes = pool.parseNodesFromText(stub);
    expect(nodes, isNotEmpty, reason: '桩节点本身是合法 ss 链接，解析器认得');
    expect(
      pool.warnings.join(),
      anyOf(contains('127.0.0.1'), contains('回环'), contains('本机')),
      reason: 'loopback 主机的节点必须进风险提示——连出去只会连到本机',
    );
  });
}
