import 'dart:async';

import 'package:flutter/foundation.dart';

import 'config.dart';
import 'modelsdev.dart';
import 'proxy.dart';
import 'upstream.dart';

/// 聚合所有组件的应用级服务，向 UI 广播状态变化
class GatewayService extends ChangeNotifier {
  GatewayConfig config = GatewayConfig.load();
  final ModelRegistry registry = ModelRegistry();
  ProxyServer? server;
  bool running = false;
  String? startError;

  List<UpstreamRuntime> get upstreams => _runtimes;
  final List<UpstreamRuntime> _runtimes = [];
  Timer? _refreshTimer;

  Future<void> start() async {
    if (running) return;
    startError = null;
    ModelsDev.instance.onUpdated = () {
      for (final u in _runtimes) {
        if (u.def.enabled) unawaited(u.probe().then((_) => registry.rebuild(_runtimes)).then((_) => notifyListeners()));
      }
    };
    unawaited(ModelsDev.instance.start());
    _runtimes.clear();
    for (final def in config.upstreams) {
      final rt = UpstreamRuntime(def);
      _runtimes.add(rt);
      rt.startPeriodicProbe();
    }
    server = ProxyServer(config.host, config.port, config.apiKey, registry,
        anthropicEnabled: config.anthropicEnabled);
    try {
      await server!.start();
      running = true;
      unawaited(_refreshRoutes());
      _refreshTimer ??= Timer.periodic(
          const Duration(seconds: 60), (_) => unawaited(_refreshRoutes()));
    } catch (e) {
      startError = '$e';
    }
    notifyListeners();
  }

  Future<void> restartServer() async {
    await server?.stop();
    running = false;
    await start();
  }

  Future<void> _refreshRoutes() async {
    await Future.wait([
      for (final u in _runtimes)
        u.def.enabled
            ? (u.isManaged ? u.ensure() : u.probe())
            : Future.value(),
    ]);
    registry.rebuild(_runtimes);
    notifyListeners();
  }

  void refreshRoutesNow() => unawaited(_refreshRoutes());

  // ---- 供应商管理 ----

  void addUpstream(UpstreamDef def) {
    config.upstreams.add(def);
    final rt = UpstreamRuntime(def);
    _runtimes.add(rt);
    rt.startPeriodicProbe();
    config.save();
    unawaited(def.enabled
        ? (def.type == 'managed' ? rt.ensure() : rt.probe())
        : Future.value());
    notifyListeners();
  }

  void updateUpstream(UpstreamRuntime rt, UpstreamDef newDef) {
    final old = rt.def;
    final wasManagedRunning = old.type == 'managed' && rt.child != null;
    if (wasManagedRunning &&
        (newDef.type != 'managed' ||
            newDef.command != old.command ||
            newDef.args.toString() != old.args.toString())) {
      rt.stop(); // 配置变了，旧的子进程回收
    }
    rt.def
      ..type = newDef.type
      ..label = newDef.label
      ..baseUrl = newDef.baseUrl
      ..apiKey = newDef.apiKey
      ..command = newDef.command
      ..args = newDef.args
      ..enabled = newDef.enabled;
    final i = config.upstreams.indexWhere((x) => x.id == old.id);
    if (i >= 0) config.upstreams[i] = newDef;
    config.save();
    if (rt.def.enabled) {
      unawaited(rt.def.type == 'managed' ? rt.ensure() : rt.probe());
    }
    notifyListeners();
  }

  void removeUpstream(UpstreamRuntime rt) {
    rt.stop();
    _runtimes.remove(rt);
    config.upstreams.removeWhere((x) => x.id == rt.def.id);
    config.save();
    registry.rebuild(_runtimes);
    notifyListeners();
  }

  void toggleUpstream(UpstreamRuntime rt, bool enabled) {
    rt.def.enabled = enabled;
    final i = config.upstreams.indexWhere((x) => x.id == rt.def.id);
    if (i >= 0) config.upstreams[i].enabled = enabled;
    config.save();
    if (enabled) {
      unawaited(rt.def.type == 'managed' ? rt.ensure() : rt.probe());
    } else {
      if (rt.isManaged) rt.stop();
      rt.health = UpstreamHealth.unknown;
    }
    registry.rebuild(_runtimes);
    notifyListeners();
  }

  // ---- 设置 ----

  Future<void> updateGateway({String? host, int? port, String? apiKey}) async {
    config
      ..host = host ?? config.host
      ..port = port ?? config.port
      ..apiKey = apiKey ?? config.apiKey;
    config.save();
    await restartServer();
  }

  void rotateApiKey() {
    config.apiKey =
        'sk-pg-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    config.save();
    unawaited(restartServer());
  }

  void setThemeMode(String mode) {
    config.themeMode = mode;
    config.save();
    notifyListeners();
  }

  Future<void> setAnthropicEnabled(bool enabled) async {
    config.anthropicEnabled = enabled;
    config.save();
    await restartServer();
  }

  @override
  void dispose() {
    ModelsDev.instance.stop();
    _refreshTimer?.cancel();
    for (final u in _runtimes) {
      u.stop();
    }
    server?.stop();
    super.dispose();
  }
}
