import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'hostnet.dart';
import 'proxypool.dart';
import 'nodedns.dart';

/// 加密协议（ss / ssr / vmess / vless / trojan / hysteria2 / tuic）的本地内核。
///
/// Dart 里没有这些协议的实现，纯 Dart 也不可能在合理成本内补齐（vmess 的
/// AEAD、hysteria2 的 QUIC、trojan 的 TLS 指纹…）。这里采用与 Clash/mihomo
/// 相同的思路：随包带一个 mihomo 内核，为**每个节点**生成一个只绑
/// 127.0.0.1 的 HTTP listener（`listeners[].proxy` 固定指向该节点）。
/// 于是每个节点都有独立的本地端口，ProxyPool 的逐节点轮换/健康度照旧成立。
///
/// 安全边界：listener 只绑回环、`allow-lan: false`，不触碰系统代理；
/// 配置文件写在 %APPDATA%\zeroapi\proxy-core，不进入用户 config.json。
class ProxyCore {
  ProxyCore._();
  static final ProxyCore instance = ProxyCore._();

  Process? _proc;
  String _sig = '';
  final Map<String, int> _ports = {};

  bool get running => _proc != null;
  Map<String, int> get ports => Map.unmodifiable(_ports);

  /// 随包内核位置：安装目录/vendor/proxy-core/mihomo.exe（向上找 7 层，
  /// 兼容开发树 build\windows\arm64\runner\Release 布局）。
  static Directory? findCoreDir() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    var dir = exeDir;
    for (var i = 0; i < 7; i++) {
      final c = Directory('${dir.path}/vendor/proxy-core');
      if (File('${c.path}/mihomo.exe').existsSync()) return c;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    final c = Directory('${Directory.current.path}/vendor/proxy-core');
    return File('${c.path}/mihomo.exe').existsSync() ? c : null;
  }

  static bool get available => findCoreDir() != null;

  static Directory _dataDir() {
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']!
        : '${Platform.environment['HOME']}/.config';
    final d = Directory('$base/zeroapi/proxy-core');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 按代理池当前内容同步内核：无加密节点 → 停止；节点有变化 → 重启；
  /// 无变化 → 保留现有进程。结束后把 nodeId→端口 写回 [pool.corePorts]。
  Future<void> sync(ProxyPool pool) async {
    final nodes = [
      for (final n in pool.allNodes)
        if (ProxyPool.needsCore(n)) n,
    ];
    final coreDir = findCoreDir();
    if (nodes.isEmpty || coreDir == null) {
      await stop();
      _ports.clear();
      pool.corePorts = {};
      return;
    }
    // 先用 DoH 把节点域名解析成真实 IP。系统 DNS 在 Clash TUN 下返回
    // fake-ip（198.18.x），内核拿到假地址会所有节点一起超时；解析失败
    // 的域名不出现在 map 里，配置仍写原域名（TUN 关闭时本来就可直连）。
    final resolved = await NodeDns.instance.resolveAll([
      for (final n in nodes) n.host,
    ]);
    final overrides = <String, String>{
      for (final n in nodes)
        if (resolved[n.host.trim().toLowerCase()] != null)
          n.id: resolved[n.host.trim().toLowerCase()]!,
    };
    final sig = jsonEncode([
      for (final n in nodes)
        [n.id, n.type, n.host, n.port, n.password, n.extras, overrides[n.id]],
    ]);
    if (sig == _sig && _proc != null) {
      pool.corePorts = Map<String, int>.from(_ports);
      return;
    }
    await stop();
    final dataDir = _dataDir();
    // 重启内核时优先复用该节点原来的端口：节点域名重解析/IP 轮换导致的
    // 重启不应把下游指令全部改写，端口稳定也能避免瞬时 502。
    final previous = Map<String, int>.from(_ports);
    final ports = <String, int>{};
    for (final n in nodes) {
      final cached = previous[n.id];
      final p = (cached != null && await _portFree(cached))
          ? cached
          : await _freePort();
      if (p != null) ports[n.id] = p;
    }
    if (ports.isEmpty) {
      pool.corePorts = {};
      return;
    }
    // 宿主自己开着 TUN（FlClash 等）时，TUN 虚拟网卡抢走默认路由，内核出站
    // 被二次套代理 → 加密类节点握手超时、整池不可用。绑定物理网卡绕开它。
    final bindIface = HostNetwork.hasTunnelAdapter()
        ? HostNetwork.physicalInterface()
        : null;
    final cfg = File('${dataDir.path}/config.yaml')
      ..writeAsStringSync(
        pool.coreConfigYaml(ports,
            serverOverrides: overrides, bindInterface: bindIface),
      );
    final exe = File('${coreDir.path}/mihomo.exe');
    // 先做配置校验，语法错误立即失败，避免反复拉起坏进程
    final check = await Process.run(exe.path, [
      '-t',
      '-d',
      dataDir.path,
      '-f',
      cfg.path,
    ], runInShell: false);
    final log = File('${dataDir.path}/mihomo.log')
        .openWrite(mode: FileMode.append);
    log.writeln(
      '[${DateTime.now().toIso8601String()}] check exit=${check.exitCode} '
      'resolved=${overrides.length}/${nodes.length}',
    );
    if (check.exitCode != 0) {
      log.writeln(check.stdout);
      log.writeln(check.stderr);
      await log.flush();
      await log.close();
      pool.corePorts = {};
      return;
    }
    // detachedWithStdio：控制台程序不分配黑窗，同时保留日志管道。
    // 内核是被动重启的（用户点「重启网关」或池变化），不依赖 exitCode。
    final proc = await Process.start(exe.path, [
      '-d',
      dataDir.path,
      '-f',
      cfg.path,
    ], mode: ProcessStartMode.detachedWithStdio);
    proc.stdout.listen(log.add);
    proc.stderr.listen(log.add);
    _proc = proc;
    _sig = sig;
    // 等待所有 listener 可连接（最多 6 秒）
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(deadline)) {
      var all = true;
      for (final p in ports.values) {
        try {
          final s = await Socket.connect(
            '127.0.0.1',
            p,
            timeout: const Duration(milliseconds: 250),
          );
          s.destroy();
        } catch (_) {
          all = false;
          break;
        }
      }
      if (all) break;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    _ports
      ..clear()
      ..addAll(ports);
    pool.corePorts = Map<String, int>.from(_ports);
    log.writeln(
      '[${DateTime.now().toIso8601String()}] started pid=${proc.pid} '
      'listeners=${ports.length}',
    );
    await log.flush();
  }

  Future<void> stop() async {
    final p = _proc;
    _proc = null;
    _sig = '';
    if (p != null) {
      try {
        p.kill();
      } catch (_) {}
      try {
        Process.killPid(p.pid);
      } catch (_) {}
    }
  }

  static Future<bool> _portFree(int port) async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<int?> _freePort() async {
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close();
      return port;
    } catch (_) {
      return null;
    }
  }
}
