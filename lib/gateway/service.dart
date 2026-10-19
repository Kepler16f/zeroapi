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

  /// IP 级滥用封锁首次检测回调（UI 订阅：提示用户启用出口代理/部署 Worker；
  /// 该模式默认不开启，只在被封时征询）
  void Function(String upstreamId)? onIpBanDetected;

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
      // 供应商预热就绪时立即重建路由表（不等 60s 周期刷新），
      // 否则冷启动后模型要干等下一轮刷新才出现
      final rt = UpstreamRuntime(def)..onStatusChanged = refreshRoutesNow;
      _runtimes.add(rt);
      rt.startPeriodicProbe();
    }
    server = ProxyServer(config.host, config.port, config.apiKey, registry,
        anthropicEnabled: config.anthropicEnabled,
        allowLan: config.allowLan,
        keys: config.keys,
        onKeyUsed: _touchKey)
      ..onUnknownModel = _refreshRoutes
      ..onIpBan = (id) => onIpBanDetected?.call(id);
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
    final rt = UpstreamRuntime(def)..onStatusChanged = notifyListeners;
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
      ..env = newDef.env
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

  Future<void> updateGateway({String? host, int? port}) async {
    config
      ..host = host ?? config.host
      ..port = port ?? config.port;
    config.save();
    await restartServer();
  }

  /// 局域网接入开关：改监听地址必须重启网关才生效
  Future<void> setAllowLan(bool enabled) async {
    config.allowLan = enabled;
    config.save();
    await restartServer();
  }

  // ---- 网关密钥池（持有任意一把即可接入，不与设备绑定）----

  void addGatewayKey(String label, {String? value}) {
    final v = (value ?? '').trim();
    config.keys.add(GatewayKey(
        label.trim().isEmpty ? '密钥 ${config.keys.length + 1}' : label.trim(),
        v.isEmpty ? genGatewayKey() : v));
    config.save();
    unawaited(restartServer()); // keys 以 List 引用注入，重建保险起见
  }

  void renameGatewayKey(int index, String label) {
    if (index < 0 || index >= config.keys.length) return;
    config.keys[index].label = label.trim().isEmpty ? config.keys[index].label : label.trim();
    config.save();
    notifyListeners();
  }

  void deleteGatewayKey(int index) {
    if (index <= 0 || index >= config.keys.length) return; // 保留首把默认 key
    config.keys.removeAt(index);
    config.save();
    unawaited(restartServer());
  }

  /// 轮换默认 key（旧「更换 API Key」语义）
  void rotateApiKey() {
    if (config.keys.isEmpty) {
      config.keys.add(GatewayKey('默认', genGatewayKey()));
    } else {
      config.keys.first.value = genGatewayKey();
    }
    config.save();
    unawaited(restartServer());
  }

  /// 密钥命中回调（网关线程）：限频 1 分钟内同一把不重复落盘
  final Map<String, DateTime> _keyTouchMark = {};
  void _touchKey(GatewayKey k) {
    final now = DateTime.now();
    final last = _keyTouchMark[k.value];
    if (last != null && now.difference(last).inSeconds < 60) return;
    _keyTouchMark[k.value] = now;
    k.lastUsed = now;
    config.save();
    notifyListeners();
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

  /// 关窗行为仅写入 config.json；windows/runner 的 C++ 层在每次 WM_CLOSE
  /// 时重新读取，切换即时生效，无需重启网关或应用
  void setCloseToTray(bool enabled) {
    config.closeToTray = enabled;
    config.save();
    notifyListeners();
  }

  /// 出口代理：写目标供应商的 proxy/proxyEnabled。代理客户端由 ProxyServer
  /// 每次请求实时解析 proxyPool，切换即时生效（下一次请求就走新出口）
  void setUpstreamProxy(String upstreamId,
      {required bool enabled, String? proxy}) {
    final i = config.upstreams.indexWhere((x) => x.id == upstreamId);
    if (i < 0) return;
    config.upstreams[i]
      ..proxyEnabled = enabled
      ..proxy = proxy ?? config.upstreams[i].proxy;
    config.save();
    // 运行中的 runtime 共用同一 def 对象引用会随 config 重载失效——同步到
    // _runtimes 里的实际实例，保证网关侧立即读到新值
    for (final rt in _runtimes) {
      if (rt.def.id == upstreamId) {
        rt.def
          ..proxyEnabled = enabled
          ..proxy = config.upstreams[i].proxy;
      }
    }
    notifyListeners();
  }

  /// 把 zen 供应商的 baseUrl 指到自建 Worker（一键部署完成时调用）；
  /// 同时确保出口代理开关开着——workers.dev 在部分网络环境需借代理可达
  void applyWorkerBaseUrl(String workerRoot) {
    final i = config.upstreams.indexWhere((x) => x.type == 'zen');
    if (i < 0) return;
    final u = config.upstreams[i];
    u.baseUrl = workerRoot.endsWith('/')
        ? '${workerRoot}inference/v1'
        : '$workerRoot/inference/v1';
    if (u.proxyEnabled == false && u.proxy.trim().isEmpty) u.proxyEnabled = true;
    config.save();
    for (final rt in _runtimes) {
      if (rt.def.type == 'zen') {
        rt.def.baseUrl = u.baseUrl;
        unawaited(rt.probe());
      }
    }
    notifyListeners();
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
