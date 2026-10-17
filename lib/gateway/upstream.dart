import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';

enum UpstreamHealth { unknown, checking, healthy, down }

/// 供应商运行时：健康探测 + managed 类型子进程托管（拉起/守护/退避重启）
class UpstreamRuntime {
  final UpstreamDef def;
  UpstreamHealth health = UpstreamHealth.unknown;
  List<String> models = [];
  String? lastError;
  Process? child;
  int requests = 0, promptTokens = 0, completionTokens = 0, errors = 0;
  DateTime? lastSpawnAt;
  bool _stopping = false;
  int _backoffMs = 1000;
  Timer? _probeTimer;

  UpstreamRuntime(this.def);

  String get id => def.id;
  bool get isManaged => def.type == 'managed';

  Map<String, String> _headers([Map<String, String>? extra]) => {
        'Content-Type': 'application/json',
        if (def.apiKey.isNotEmpty) 'Authorization': 'Bearer ${def.apiKey}',
        ...?extra,
      };

  Future<bool> probe() async {
    try {
      final uri = Uri.parse('${def.baseUrl.replaceAll(RegExp(r'/+$'), '')}/models');
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(uri);
      _headers().forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode != 200) throw HttpException('HTTP ${resp.statusCode}');
      final j = jsonDecode(body) as Map<String, dynamic>;
      final data = (j['data'] as List?) ?? const [];
      models = data
          .map((m) => (m as Map<String, dynamic>)['id'])
          .whereType<String>()
          .toList();
      health = UpstreamHealth.healthy;
      lastError = null;
      _backoffMs = 1000;
      return true;
    } catch (e) {
      health = UpstreamHealth.down;
      lastError = e.toString();
      return false;
    }
  }

  /// managed：不健康 → 若是外部实例（如用户手动起的）则不拉起；否则启动子进程
  Future<void> ensure() async {
    if (!def.enabled) return;
    if (await probe()) return;
    if (!isManaged || child != null || _stopping) return;
    if (_externalGraceActive()) return;
    // 端口可连但探测失败 → 视为外部实例（或密钥不对），10 分钟内不重复拉起，避免端口冲突
    try {
      final uri = Uri.parse(def.baseUrl);
      final sock = await Socket.connect(uri.host, uri.port,
          timeout: const Duration(milliseconds: 600));
      sock.destroy();
      _externalSeenAt = DateTime.now();
      lastError = '端口 ${uri.port} 有服务但探测失败（外部实例或密钥不对）';
      return;
    } catch (_) {}
    _spawn();
  }

  /// 外部实例宽限期内
  bool _externalGraceActive() {
    final ext = _externalSeenAt;
    if (ext == null) return false;
    if (DateTime.now().difference(ext) < const Duration(minutes: 10)) return true;
    _externalSeenAt = null;
    return false;
  }

  DateTime? _externalSeenAt;

  void _spawn() {
    final cmd = def.command;
    if (cmd == null || cmd.isEmpty) {
      lastError = 'managed 供应商未配置 command（本机未检测到可执行入口）';
      return;
    }
    try {
      final logFile = _logSink();
      logFile?.writeln('[${DateTime.now().toIso8601String()}] spawn: $cmd ${def.args.join(" ")}');
      Process.start(cmd, def.args).then((p) {
        child = p;
        lastSpawnAt = DateTime.now();
        final sink = _logSink();
        p.stdout.listen((d) => sink?.add(d),
            onDone: () => sink?.flush());
        p.stderr.listen((d) => sink?.add(d),
            onDone: () => sink?.flush());
        unawaited(p.exitCode.then((code) {
          logFile?.writeln('[${DateTime.now().toIso8601String()}] exit code=$code');
          sink?.flush();
          child = null;
          health = UpstreamHealth.unknown;
          if (_stopping) return;
          // 退避重启
          Future.delayed(Duration(milliseconds: _backoffMs), () async {
            if (_stopping) return;
            _backoffMs = (_backoffMs * 2).clamp(1000, 60000);
            await ensure();
          });
        }));
      });
    } catch (e) {
      lastError = '拉起失败: $e';
    }
  }

  IOSink? _logFileSink;
  IOSink? _logSink() {
    try {
      final base = Platform.isWindows
          ? Platform.environment['APPDATA']!
          : '${Platform.environment['HOME']}/.config';
      final dir = Directory('$base/zeroapi/logs');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _logFileSink ??=
          File('${dir.path}/upstream-$id.log').openWrite(mode: FileMode.append);
      return _logFileSink;
    } catch (_) {
      return null;
    }
  }

  void startPeriodicProbe({Duration every = const Duration(seconds: 30)}) {
    _probeTimer?.cancel();
    _probeTimer = Timer.periodic(every, (_) async {
      if (!def.enabled) return;
      if (health == UpstreamHealth.healthy) {
        // 定期复检，失败转 down
        await probe();
      } else {
        await ensure();
      }
    });
  }

  void stop() {
    _stopping = true;
    _probeTimer?.cancel();
    final c = child;
    if (c != null) {
      if (Platform.isWindows) {
        Process.run('taskkill', ['/PID', '${c.pid}', '/T', '/F']);
      } else {
        c.kill();
      }
    }
    child = null;
  }
}
