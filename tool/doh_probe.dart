// 诊断脚本：直接用应用里的 NodeDns 解析代理池域名，验证 DoH 链路。
// 用法: dart run tool/doh_probe.dart
import 'dart:io';

import 'package:zeroapi/gateway/nodedns.dart';

Future<void> main() async {
  final data = File('${Platform.environment['APPDATA']}/zeroapi/proxies.json');
  if (!data.existsSync()) {
    stderr.writeln('找不到 ${data.path}');
    exit(1);
  }
  final hosts = RegExp(r'"host"\s*:\s*"([^"]+)"')
      .allMatches(data.readAsStringSync())
      .map((m) => m.group(1)!)
      .where((h) => !NodeDns.isIpLiteral(h))
      .toSet();
  stdout.writeln('待解析域名: ${hosts.length}');
  final sw = Stopwatch()..start();
  final ips = await NodeDns.instance.resolveAll(hosts);
  stdout.writeln(
    '解析成功: ${ips.length}/${hosts.length}，'
    '耗时 ${sw.elapsedMilliseconds}ms',
  );
  for (final e in ips.entries) {
    stdout.writeln('  ${e.key} -> ${e.value}');
  }
  final failed = hosts.where((h) => !ips.containsKey(h.toLowerCase())).toList();
  if (failed.isNotEmpty) stdout.writeln('失败: ${failed.join(', ')}');
}
