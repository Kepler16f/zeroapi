// 复现应用的订阅拉取：同样的 UA + unwrap + 解析链，数节点。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/proxypool.dart';

void main() {
  test('reproduce app fetch + parse', () async {
    const url =
        'https://cggac.908970.xyz/api/v1/client/subscribe?token=da63183e0fbc9a9fac5176d05f7711ee';
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'ZeroApi/0.2.1 (proxy subscription import)';
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close().timeout(const Duration(seconds: 25));
    final bytes = await resp
        .fold<List<int>>(<int>[], (acc, c) => acc..addAll(c))
        .timeout(const Duration(seconds: 25));
    final body = utf8.decode(bytes, allowMalformed: true);
    // ignore: avoid_print
    print('HTTP ${resp.statusCode}, ${bytes.length} bytes');
    // ignore: avoid_print
    print('content-type: ${resp.headers.value("content-type")}');
    // ignore: avoid_print
    print('body 头 300 字: ${body.length > 300 ? body.substring(0, 300) : body}');

    final unwrapped = unwrapSubscriptionBody(body);
    // ignore: avoid_print
    print('unwrapped 头 300 字: ${unwrapped.length > 300 ? unwrapped.substring(0, 300) : unwrapped}');

    final pool = ProxyPool();
    final nodes = pool.parseNodesFromText(unwrapped);
    // ignore: avoid_print
    print('解析节点数: ${nodes.length}');
    // ignore: avoid_print
    print('parseErrors: ${pool.parseErrors.take(3)}');
    expect(nodes, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
