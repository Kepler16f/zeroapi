import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'modelsdev.dart';
import 'zen.dart';

enum UpstreamHealth { unknown, checking, healthy, down }

/// 供应商运行时：健康探测 + 内置(managed)类型的子进程拉起/守护/退避重启
class UpstreamRuntime {
  final UpstreamDef def;
  UpstreamHealth health = UpstreamHealth.unknown;
  List<String> models = [];
  /// 模型能力元数据（上游 /v1/models 条目 + models.dev 目录合并）
  final Map<String, ModelInfo> modelInfo = {};
  String? lastError;
  Process? child;
  int requests = 0, promptTokens = 0, completionTokens = 0, errors = 0;
  DateTime? lastSpawnAt;
  bool _stopping = false;
  int _backoffMs = 1000;
  Timer? _probeTimer;

  UpstreamRuntime(this.def);

  /// 状态变化回调（由 GatewayService 接 notifyListeners，UI 即时感知就绪）
  void Function()? onStatusChanged;

  String get id => def.id;
  bool get isManaged => def.type == 'managed';
  /// OpenCode Zen 免费层直连（原生实现，无本地进程）
  bool get isZen => def.type == 'zen';
  /// 内置供应商刚拉起、子进程尚未就绪的预热窗口：
  /// 期间连接拒绝是预期噪声，不显示为错误
  bool _warming = false;
  bool get warming => _warming;

  Map<String, String> _headers([Map<String, String>? extra]) => {
        'Content-Type': 'application/json',
        if (def.apiKey.isNotEmpty) 'Authorization': 'Bearer ${def.apiKey}',
        ...?extra,
      };

  Future<bool> probe() async {
    if (isZen) return _probeZen();
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
      final entries = data
          .map((m) => m as Map<String, dynamic>)
          .where((m) => m['id'] is String)
          .toList();
      models = entries.map((m) => m['id'] as String).toList();
      // 元数据 = 上游条目自带字段（若有，优先） + models.dev 目录（兜底补充）
      modelInfo.clear();
      for (final e in entries) {
        final id = e['id'] as String;
        modelInfo[id] = ModelInfo.fromMaps(
            e, ModelsDev.instance.lookup((e['owned_by'] ?? def.id) as String?, id));
      }
      health = UpstreamHealth.healthy;
      lastError = null;
      _backoffMs = 1000;
      return true;
    } catch (e) {
      if (_warming) {
        // 预热窗口内（子进程尚未就绪）：保持"启动中"，不记拒绝错误
        health = UpstreamHealth.checking;
        lastError = null;
      } else {
        health = UpstreamHealth.down;
        lastError = e.toString();
      }
      return false;
    }
  }

  /// zen：直连 OpenCode Zen inference API，列 free 档模型（无本地进程）
  Future<bool> _probeZen() async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(Uri.parse('${Zen.base}/models'));
      Zen.headers(def.apiKey).forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      if (resp.statusCode != 200) throw HttpException('HTTP ${resp.statusCode}');
      final j = jsonDecode(body) as Map<String, dynamic>;
      final data = (j['data'] as List?) ?? const [];
      // 只保留免费档：big-pickle / *-free；付费模型默认隐藏（用户要求）
      final entries = data
          .map((m) => m as Map<String, dynamic>)
          .where((m) => m['id'] is String && Zen.isFreeModel(m['id'] as String))
          .toList();
      models = entries.map((m) => m['id'] as String).toList();
      modelInfo.clear();
      for (final e in entries) {
        final id = e['id'] as String;
        modelInfo[id] = ModelInfo.fromMaps(
            e, ModelsDev.instance.lookup('opencode', id));
      }
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
      lastError = '内置供应商未配置 command（本机未检测到可执行入口）';
      return;
    }
    // 已决定拉起：立即进入"启动中"。子进程就绪前的连接拒绝是预期噪声，
    // 不能以红色错误呈现（否则应用每次启动都会先闪一帧"积极拒绝"）
    health = UpstreamHealth.checking;
    lastError = null;
    _warming = true;
    try {
      final logFile = _logSink();
      logFile?.writeln('[${DateTime.now().toIso8601String()}] spawn: $cmd ${def.args.join(" ")}');
      Process.start(cmd, def.args,
              environment: def.env.isEmpty ? null : def.env)
          .then((p) {
        child = p;
        lastSpawnAt = DateTime.now();
        onStatusChanged?.call();
        unawaited(_warmup());
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
          onStatusChanged?.call();
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

  /// 子进程就绪前每 500ms 探一次，最长 15s；就绪即通知 UI 刷新
  Future<void> _warmup() async {
    for (var i = 0; i < 30 && !_stopping; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (_stopping || child == null) {
        _warming = false;
        return;
      }
      if (await probe()) {
        _warming = false;
        onStatusChanged?.call();
        return;
      }
    }
    // 15s 内没就绪：结束预热窗口，此后探测失败如实报 down（真实故障）
    _warming = false;
    if (health == UpstreamHealth.checking) {
      health = UpstreamHealth.down;
      lastError = '启动超时：子进程 15 秒内未就绪（查看供应商日志）';
    }
    onStatusChanged?.call();
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
