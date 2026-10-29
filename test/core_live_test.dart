// 真机联调（不进常规 CI）：用真实代理池 + DoH 生成内核配置，校验并抽样探测。
// 用法: ZEROAPI_LIVE=1 flutter test test/core_live_test.dart
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/nodedns.dart';
import 'package:zeroapi/gateway/proxypool.dart';

void main() {
  final live = Platform.environment['ZEROAPI_LIVE'] == '1';
  test(
    '真实代理池：DoH 覆盖后配置可被内核接受，抽样节点可用',
    () async {
      final pool = ProxyPool.load();
      final nodes = [
        for (final n in pool.allNodes)
          if (ProxyPool.needsCore(n)) n,
      ];
      expect(nodes, isNotEmpty, reason: '本机 proxies.json 里应有加密节点');

      final resolved = await NodeDns.instance.resolveAll([
        for (final n in nodes) n.host,
      ]);
      final overrides = <String, String>{
        for (final n in nodes)
          if (resolved[n.host.toLowerCase()] != null)
            n.id: resolved[n.host.toLowerCase()]!,
      };
      print('resolved ${overrides.length}/${nodes.length}');

      final ports = <String, int>{};
      var p = 27000;
      for (final n in nodes) {
        ports[n.id] = p++;
      }
      final dir = Directory.systemTemp.createTempSync('zeroapi_live_');
      final cfg = File('${dir.path}/config.yaml')
        ..writeAsStringSync(
          pool.coreConfigYaml(ports, serverOverrides: overrides),
        );
      print('config: ${cfg.path}');

      final check = await Process.run('vendor/proxy-core/mihomo.exe', [
        '-t',
        '-d',
        dir.path,
        '-f',
        cfg.path,
      ]);
      print('mihomo -t exit=${check.exitCode}');
      if (check.exitCode != 0) {
        print(check.stdout);
        print(check.stderr);
      }
      expect(check.exitCode, 0, reason: '内核配置校验必须通过');

      final proc = await Process.start('vendor/proxy-core/mihomo.exe', [
        '-d',
        dir.path,
        '-f',
        cfg.path,
      ]);
      proc.stdout.drain<void>();
      proc.stderr.drain<void>();
      await Future.delayed(const Duration(seconds: 6));
      var ok = 0;
      final failed = <String>[];
      for (final n in nodes.take(8)) {
        final r = await _probe(ports[n.id]!);
        if (r == '204') {
          ok++;
        } else {
          failed.add('${n.name}:$r');
        }
      }
      proc.kill();
      try {
        await proc.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {}
      print('sample ok=$ok/8 failed=${failed.join(', ')}');
      expect(ok, greaterThan(0), reason: '至少应有节点可用');
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // 内核退出后 Windows 偶尔还持有句柄，临时目录留给系统清理
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: !live,
  );
}

Future<String> _probe(int port) async {
  try {
    final client = HttpClient()
      ..findProxy = ((_) => 'PROXY 127.0.0.1:$port')
      ..connectionTimeout = const Duration(seconds: 10);
    final req = await client
        .getUrl(Uri.parse('http://www.gstatic.com/generate_204'))
        .timeout(const Duration(seconds: 12));
    final res = await req.close().timeout(const Duration(seconds: 12));
    await res.drain<void>();
    client.close(force: true);
    return '${res.statusCode}';
  } catch (e) {
    return 'err:$e';
  }
}
