// 启动顺序回归：网关端口必须先于重型初始化（代理池/内核/供应商预热）就绪。
// 内核同步实测 17s、号池首拉目录数十秒，这些都不能挡住端口监听。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/service.dart';

void main() {
  test('start() 返回时网关已可连接', () async {
    final service = GatewayService.listenerTest(
      GatewayConfig(port: 0, keys: [GatewayKey('默认', 'sk-test')]),
    );
    final sw = Stopwatch()..start();
    await service.start();
    final elapsed = sw.elapsedMilliseconds;
    expect(service.running, isTrue, reason: 'start() 返回时网关应已在运行');
    expect(service.startError, isNull);

    final port = service.server?.boundPort ?? 0;
    expect(port, greaterThan(0));
    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/healthz'),
      );
      final resp = await req.close().timeout(const Duration(seconds: 5));
      final body = jsonDecode(await resp.transform(utf8.decoder).join());
      expect(resp.statusCode, 200);
      expect(body['ok'], isTrue);
    } finally {
      client.close(force: true);
    }
    // ignore: avoid_print
    print('start() 返回耗时 ${elapsed}ms，端口 $port 已可连接');
    service.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
