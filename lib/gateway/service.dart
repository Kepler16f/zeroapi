import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'accountdata.dart';
import 'config.dart';
import 'hubactions.dart';
import 'modelsdev.dart';
import 'opencode.dart';
import 'ocruntime.dart';
import 'proxy.dart';
import 'proxycore.dart';
import 'proxypool.dart';
import 'socksrelay.dart';
import 'upstream.dart';
import 'wbdata.dart';
import 'workbuddy.dart';

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

  /// 内置代理轮换池（start() 加载，之后常驻）。供应商出口、号池出口等用途
  /// 经它绑定分组、按策略轮换；UI 直接持有它做增删改（ProxyPool 自身
  /// ChangeNotifier），改完记得调 [saveProxies] 落盘。
  ProxyPool? proxies;

  /// IP 级滥用封锁首次检测回调（UI 订阅：提示用户启用出口代理/部署 Worker；
  /// 该模式默认不开启，只在被封时征询）
  void Function(String upstreamId)? onIpBanDetected;
  /// zen/CLI 命中额度耗尽 → 换出口 IP 并重启 CLI 子进程
  void Function(String upstreamId)? onQuotaExhausted;

  Future<void> start() async {
    if (running) return;
    startError = null;
    ModelsDev.instance.onUpdated = () {
      for (final u in _runtimes) {
        if (u.def.enabled) {
          unawaited(
            u
                .probe()
                .then((_) => registry.rebuild(_runtimes))
                .then((_) => notifyListeners()),
          );
        }
      }
    };
    unawaited(ModelsDev.instance.start());
    // 首次启动自动接入 WorkBuddy 号池（仅在随包运行时存在时；只做一次）
    await WorkBuddy.seedIfNeeded(config);
    // 旧的 zen 直连条目自 2026-10-24 起全量 429（上游改按 TLS 指纹识别），
    // 迁移成 CLI 通路（id/模型前缀不变，客户端配置无需改）
    await OpenCodeMigration.migrate(config);
    // 内置代理轮换池：加载持久化数据、挂上 SOCKS5 本地中转并预热，然后把
    // activePool 全局交给出口链路（UpstreamDef.directives 会读它）。restart
    // 走同一池实例，不重复加载/加监听。
    if (proxies == null) {
      final pool = ProxyPool.load();
      pool.relayHub = SocksRelayHub.instance;
      await pool.prepareRelays(); // 预热 socks5 本地中转
      // 清理本地供应商的历史出口绑定：回环请求套代理只会 502（egress()
      // 已强制 loopback 直连，这里把脏数据抹掉，代理页也不再显示该行）
      var cleaned = false;
      for (final u in config.upstreams) {
        if (u.isLoopbackBaseUrl &&
            pool.assignments.remove(ProxyPool.pUpstream(u.id)) != null) {
          cleaned = true;
        }
      }
      if (cleaned) pool.save();
      pool.addListener(_onPoolChanged);
      activePool = proxies = pool;
    }
    // 加密协议节点（ss/vmess/vless/trojan/hysteria2/tuic）交给随包 mihomo：
    // 每个节点一个 127.0.0.1 HTTP listener，端口写回 pool.corePorts。
    await ProxyCore.instance.sync(proxies!);
    _runtimes.clear();
    for (final def in config.upstreams) {
      // 供应商预热就绪时立即重建路由表（不等 60s 周期刷新），
      // 否则冷启动后模型要干等下一轮刷新才出现
      final rt = UpstreamRuntime(def)..onStatusChanged = refreshRoutesNow;
      _runtimes.add(rt);
      rt.startPeriodicProbe();
    }
    server =
        ProxyServer(
            config.host,
            config.port,
            config.apiKey,
            registry,
            anthropicEnabled: config.anthropicEnabled,
            allowLan: config.allowLan,
            keys: config.keys,
            onKeyUsed: _touchKey,
          )
          ..onUnknownModel = _refreshRoutes
          ..onIpBan = (id) {
            onIpBanDetected?.call(id);
          }
          ..onQuotaExhausted = (id) {
            _rotateZenEgress(id);
          };
    try {
      await server!.start();
      server!.workbuddyPreferredRealm = config.workbuddyPreferredRealm;
      running = true;
      unawaited(_refreshRoutes());
      // 节点可达性巡检：启动即扫一轮，之后每 60s 一轮；成功清零失败计数
      // 解禁冷却（坏节点不用手动逐个刷新，修好一分钟内自动回轮换）。
      final pool = proxies;
      if (pool != null) {
        unawaited(pool.autoProbeOnce());
        pool.startAutoProbe();
      }
      _refreshTimer ??= Timer.periodic(
        const Duration(seconds: 60),
        (_) => unawaited(_refreshRoutes()),
      );
      // 节点域名走 DoH；机场经常改解析，5 分钟重解析一次，IP 变了
      // sync 会自动重启内核并换端口（sig 里含解析结果）。
      _coreRefreshTimer ??= Timer.periodic(const Duration(minutes: 5), (_) {
        final pool = proxies;
        if (pool == null) return;
        unawaited(ProxyCore.instance.sync(pool).then((_) => notifyListeners()));
      });
      // 订阅自动刷新：每 30 分钟巡检一次（到期刷新 + 失败优先刷新；
      // 池变化/探测完成也会即时触发检查）
      _subRefreshTimer ??= Timer.periodic(const Duration(minutes: 30), (_) {
        final pool = proxies;
        if (pool != null) _maybeAutoRefreshGroups(pool);
      });
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
        u.def.enabled ? (u.isManaged ? u.ensure() : u.probe()) : Future.value(),
    ]);
    // 号池双出口：记录哪些区当前有可用账号。共有模型的高并发分散只在
    // 两区都有可用账号时才跨区，否则请求会落到空号池的区上必挂。
    for (final rt in _runtimes) {
      if (rt.id != WorkBuddy.id || !rt.def.enabled) continue;
      final accounts = await hubAccounts();
      // 空列表可能只是面板会话暂时不可用：号池明明有账号就保留上次结论
      if (accounts.isEmpty && (rt.accountTotal ?? 0) > 0) continue;
      final counts = <String, int>{};
      for (final a in accounts) {
        if (a['enabled'] == false) continue;
        if (a['needRelogin'] == true) continue;
        if (a['inCooldown'] == true) continue;
        if ((a['restrictedFor'] as num?) != null) continue;
        if ((a['breakerFor'] as num?) != null) continue;
        if (a['creditLimitReached'] == true) continue;
        if (a['dailyLimitBlocked'] == true) continue;
        final r = '${a['realm'] ?? ''}';
        if (r == 'cn' || r == 'intl') counts[r] = (counts[r] ?? 0) + 1;
      }
      rt.readyAccounts = counts;
      rt.readyRealms = counts.keys.toSet();
    }
    registry.rebuild(_runtimes);
    notifyListeners();
  }

  void refreshRoutesNow() => unawaited(_refreshRoutes());

  /// 手动刷新单个供应商（供应商卡片上的刷新按钮）：重新探测/拉模型清单，
  /// 完成后重建路由表并广播。只动这一家，不影响其他供应商的探测节奏。
  void refreshUpstream(String id) {
    for (final rt in _runtimes) {
      if (rt.def.id != id || !rt.def.enabled) continue;
      unawaited(
        (rt.isManaged ? rt.ensure() : rt.probe())
            .then((_) => registry.rebuild(_runtimes))
            .then((_) => notifyListeners()),
      );
    }
  }

  // ---- 供应商管理 ----

  /// 手动接入 WorkBuddy 号池（首次自动接入被跳过，或用户移除后想加回来）。
  /// 成功返回 null，失败返回给 UI 展示的原因。
  Future<String?> addWorkBuddy() async {
    if (config.upstreams.any((u) => u.id == WorkBuddy.id)) {
      return 'WorkBuddy 号池已在供应商列表中';
    }
    final def = await WorkBuddy.buildDef();
    if (def == null) {
      return '未找到随包的 WorkBuddy 运行时（vendor/workbuddy2api-hub），'
          '请重新安装，或运行 tool/vendor_workbuddy.ps1 后重启应用';
    }
    config.workbuddySeeded = true;
    addUpstream(def);
    return null;
  }

  /// zen/CLI 通路的出网代理（池里挑一个节点的 HTTP 代理）。
  /// 免费额度按「最终到达 opencode.ai 的出口 IP × 天」计，走不同节点等于
  /// 把额度分摊到多个 IP；池里没有可用节点返回 null（CLI 直连）。
  String? _zenProxyUrl() {
    final pool = proxies;
    if (pool == null) return null;
    final d = pool.pickDirective(ProxyPool.pUpstream(OpenCode.id));
    if (d == null) return null;
    // findProxy 指令形如 'PROXY 127.0.0.1:12345' → HTTP 代理 URL
    final m = RegExp(r'PROXY\s+(\S+)').firstMatch(d);
    if (m == null) return null;
    return 'http://${m.group(1)}';
  }
  /// zen/CLI 通路命中额度耗尽：换一个出口节点并重启 CLI 子进程。
  ///
  /// CLI 进程通过 HTTP_PROXY 绑定出口，换 IP 必须换进程——所以这里改
  /// def.env 再杀子进程，由 managed 生命周期按退避重新拉起。
  void _rotateZenEgress(String upstreamId) {
    final rt = _runtimes.where((r) => r.def.id == upstreamId).firstOrNull;
    if (rt == null) return;
    final pool = proxies;
    if (pool == null) return;
    final purpose = ProxyPool.pUpstream(upstreamId);
    // 跳过已判定额度烧穿的节点，直到下一个
    final candidates = poolCandidatesFor(pool, purpose)
        .where((c) => c.nodeId == null || !pool.isQuotaSpent(c.nodeId!))
        .toList();
    if (candidates.isEmpty) {
      // 全烧穿：清标记重头轮换
      for (final c in poolCandidatesFor(pool, purpose)) {
        if (c.nodeId != null) pool.clearQuotaSpent(c.nodeId!);
      }
      return;
    }
    final pick = candidates.first;
    final m = RegExp(r'PROXY\s+(\S+)').firstMatch(pick.directive);
    final url = m == null ? '' : 'http://${m.group(1)}';
    if (url.isEmpty) return;
    // 标记旧节点额度烧穿，避免下次又选回它
    final old = rt.def.env['HTTPS_PROXY'];
    final oldPort = RegExp(r':(\d+)$').firstMatch(old ?? '');
    if (oldPort != null) {
      final node = pool.allNodes.where((n) {
        final d = pool.directiveOf(n);
        return d != null && d.endsWith(oldPort.group(1)!);
      }).firstOrNull;
      if (node != null) pool.markQuotaSpent(node.id);
    }
    rt.def.env['HTTP_PROXY'] = url;
    rt.def.env['HTTPS_PROXY'] = url;
    rt.def.env['http_proxy'] = url;
    rt.def.env['https_proxy'] = url;
    // 重启子进程：新的 env 才生效。用 restartChild（只换进程）而不是
    // stop()——后者会置 _stopping，之后 ensure() 不会重新拉起。
    rt.restartChild();
    unawaited(Future.delayed(const Duration(milliseconds: 500), rt.ensure));
  }
  /// 接入 OpenCode CLI 供应商（TLS 指纹通路）。
  /// 成功返回 null；找不到运行时返回给 UI 展示的原因（UI 据此引导下载）。
  Future<String?> addOpenCode() async {
    if (config.upstreams.any((u) => u.id == OpenCode.id)) {
      return 'OpenCode CLI 已在供应商列表中';
    }
    final port = await OpenCode.pickPort();
    final def = OpenCode.seed(port: port, proxyUrl: _zenProxyUrl());
    if (def == null) {
      return '本机未检测到 opencode CLI。可以在供应商页「下载运行时」自动获取'
          '（约 177MB，来自 npm 官方包），或自行安装 opencode-ai 后重启应用。';
    }
    addUpstream(def);
    return null;
  }

  /// 按需下载 opencode CLI 运行时（tarball → %APPDATA%\zeroapi\opencode\bin），
  /// 完成后自动接入供应商。返回 null=成功；否则为失败原因。
  Future<String?> downloadOpenCodeRuntime(
      {void Function(int received, int total)? onProgress}) async {
    try {
      await OpenCodeRuntime.downloadAndInstall(onProgress: onProgress);
    } catch (e) {
      return '下载失败：$e';
    }
    return addOpenCode();
  }

  void addUpstream(UpstreamDef def) {
    config.upstreams.add(def);
    final rt = UpstreamRuntime(def)..onStatusChanged = notifyListeners;
    _runtimes.add(rt);
    rt.startPeriodicProbe();
    config.save();
    unawaited(
      def.enabled
          ? (def.type == 'managed' ? rt.ensure() : rt.probe())
          : Future.value(),
    );
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
      ..healthUrl = newDef.healthUrl
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
    config.keys.add(
      GatewayKey(
        label.trim().isEmpty ? '密钥 ${config.keys.length + 1}' : label.trim(),
        v.isEmpty ? genGatewayKey() : v,
      ),
    );
    config.save();
    unawaited(restartServer()); // keys 以 List 引用注入，重建保险起见
  }

  void renameGatewayKey(int index, String label) {
    if (index < 0 || index >= config.keys.length) return;
    config.keys[index].label = label.trim().isEmpty
        ? config.keys[index].label
        : label.trim();
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

  /// 池变化时落盘（ProxyPool 内部 notifyListeners 会触发这里；save 很轻，
  /// 不做防抖）。UI 直接经 s.proxies! 操作时（assign/setEnabled/remove…）
  /// 同样经由这里自动保存。
  void _onPoolChanged() {
    proxies?.save();
    notifyListeners();
    // 节点增删/改参数后重建内核 listener（防抖：导入会连续触发多次）
    _coreSyncTimer?.cancel();
    _coreSyncTimer = Timer(const Duration(milliseconds: 800), () {
      final pool = proxies;
      if (pool == null) return;
      // 订阅自动刷新检查挂在这里：健康探测（probe 会 notify）失败一大片时
      // 也能触发，不必等 30 分钟的周期定时器
      _maybeAutoRefreshGroups(pool);
      unawaited(
        ProxyCore.instance.sync(pool).then((_) {
          // 端口就绪后重建路由，让新节点立刻可被选中
          notifyListeners();
        }),
      );
    });
  }

  Timer? _coreSyncTimer;
  Timer? _coreRefreshTimer;
  Timer? _subRefreshTimer;

  /// 导入代理文本（Clash YAML / 订阅内容 / 分享链接），返回新增节点数。
  /// 新增含 socks5 节点时预热本地中转；warnings/parseErrors 由 UI 从
  /// pool.warnings / pool.parseErrors 直接读。
  Future<int> importProxies(String text, {String? groupName}) async {
    final pool = proxies;
    if (pool == null) return 0;
    final added = pool.importFromText(text, groupName: groupName);
    if (added > 0 &&
        pool.allNodes.any((n) => n.type == 'socks5' || n.type == 'socks')) {
      await pool.prepareRelays();
    }
    pool.save();
    notifyListeners();
    return added;
  }

  /// 手动落盘池状态（UI 直接调 pool 方法后用这个统一保存；_onPoolChanged
  /// 已覆盖大多数场景，留一个显式入口）
  void saveProxies() => proxies?.save();

  /// 从订阅链接拉取并导入。响应体可能是 base64（机场标准）或明文分享
  /// 链接/Clash YAML，交给 [unwrapSubscriptionBody] 判定。
  /// 拉取失败抛异常（UI 显示原因），成功返回新增节点数。
  Future<int> importProxiesFromUrl(String url, {String? groupName}) async {
    final body = await fetchSubscriptionBody(url);
    final added = await importProxies(
      unwrapSubscriptionBody(body),
      groupName: groupName,
    );
    // 记住订阅来源：分组之后可一键/自动刷新（机场会轮换节点）
    final pool = proxies;
    final g = groupName?.trim();
    if (pool != null && g != null && g.isNotEmpty) {
      pool.setGroupSource(g, url.trim());
    }
    return added;
  }

  /// 拉取订阅链接响应体（供导入与刷新共用）。
  Future<String> fetchSubscriptionBody(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('订阅链接需为 http:// 或 https:// 开头');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'ZeroApi/0.2.1 (proxy subscription import)';
    try {
      final req = await client.getUrl(uri);
      // 机场常见 302 → 真实地址；HttpClient 默认自动跟随重定向
      final resp = await req.close().timeout(const Duration(seconds: 25));
      if (resp.statusCode != 200) {
        throw HttpException('订阅拉取失败：HTTP ${resp.statusCode}');
      }
      final bytes = await resp
          .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
          .timeout(const Duration(seconds: 25));
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      client.close(force: true);
    }
  }

  /// 手动刷新分组订阅：重新拉取 [groupName] 的来源链接并整组替换节点
  /// （id 稳定哈希，幸存节点的健康度/绑定保留，机场下线的节点删除）。
  /// 返回人类可读结果；[urlOverride] 临时改用其它链接（会写回分组）。
  Future<String> refreshGroupSubscription(
    String groupName, {
    String? urlOverride,
  }) async {
    final pool = proxies;
    if (pool == null) throw StateError('代理池未就绪');
    final g = pool.groups.where((x) => x.name == groupName).firstOrNull;
    if (g == null) throw StateError('分组不存在：$groupName');
    final url = (urlOverride ?? g.sourceUrl).trim();
    if (url.isEmpty) {
      throw const FormatException('该分组没有订阅链接，先在对话框里填写');
    }
    final body = await fetchSubscriptionBody(url);
    final (added, removed) = pool.replaceGroupFromText(
      groupName,
      unwrapSubscriptionBody(body),
    );
    pool.setGroupSource(groupName, url);
    await ProxyCore.instance.sync(pool);
    return '订阅已刷新：新增 $added、移除 $removed，现 ${pool.groups.firstWhere((x) => x.name == groupName).nodes.length} 个节点';
  }

  /// 自动订阅刷新检查（周期定时器与池变化时都会调）：
  ///  - 到期（距上次刷新超过该组设置的间隔，且组开了自动刷新）→ 刷新；
  ///  - 大面积失败（组内 ≥60% 节点进冷却）→ 提前刷新，限流 30 分钟一次
  ///    （机场轮换节点后不刷新只会一直撞死节点）。
  /// 成功才推进 lastRefreshAt；成败都限流，避免拉取失败时打爆订阅接口。
  final Set<String> _refreshingGroups = {};
  final Map<String, DateTime> _lastRefreshAttempt = {};

  void _maybeAutoRefreshGroups(ProxyPool pool) {
    final now = DateTime.now();
    for (final g in pool.groups) {
      if (g.sourceUrl.trim().isEmpty) continue;
      final every = Duration(hours: g.refreshIntervalHours.clamp(1, 168));
      final stale =
          g.lastRefreshAt == null || now.difference(g.lastRefreshAt!) > every;
      final degraded =
          g.failedRatio(pool) >= 0.6 &&
          (g.lastRefreshAt == null ||
              now.difference(g.lastRefreshAt!) > const Duration(minutes: 30));
      if (!(g.autoRefresh && stale) && !degraded) continue;
      final last = _lastRefreshAttempt[g.name];
      if (last != null && now.difference(last) < const Duration(minutes: 30)) {
        continue;
      }
      if (!_refreshingGroups.add(g.name)) continue;
      _lastRefreshAttempt[g.name] = now;
      final name = g.name;
      unawaited(
        refreshGroupSubscription(name)
            .then(
              (msg) {
                stderr.writeln('[zeroapi] 订阅自动刷新[$name] $msg');
              },
              onError: (Object e) {
                stderr.writeln('[zeroapi] 订阅自动刷新失败[$name] $e');
              },
            )
            .whenComplete(() => _refreshingGroups.remove(name)),
      );
    }
  }

  /// 出口代理：写目标供应商的 proxy/proxyEnabled。代理客户端由 ProxyServer
  /// 每次请求实时解析 proxyPool，切换即时生效（下一次请求就走新出口）
  void setUpstreamProxy(
    String upstreamId, {
    required bool enabled,
    String? proxy,
  }) {
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

  /// 设置页的出口代理对所有供应商统一生效（本机回环服务除外——随包号池
  /// 必须直连，否则回环请求会被代理截走）。设置页只负责「用什么代理」；
  /// 哪个供应商走内置代理池由「代理」页的用途分配决定。
  void setGlobalUpstreamProxy({required bool enabled, String proxy = ''}) {
    for (final u in config.upstreams) {
      if (u.isLoopbackBaseUrl) continue;
      u
        ..proxyEnabled = enabled
        ..proxy = proxy;
    }
    config.save();
    // 运行中的 runtime 可能持有旧 config 实例的 def，同步到实际实例
    for (final rt in _runtimes) {
      if (rt.def.isLoopbackBaseUrl) continue;
      rt.def
        ..proxyEnabled = enabled
        ..proxy = proxy;
    }
    notifyListeners();
  }

  /// 是否有供应商开着出口代理（设置页开关的展示状态）
  bool get globalProxyEnabled =>
      config.upstreams.any((u) => !u.isLoopbackBaseUrl && u.proxyEnabled);

  /// 当前供应商出口是否走内置代理池：代理池里 `upstream:<id>` 有绑定分组
  /// 且该用途启用。绑定分组在「代理」页的用途分配里设置，这里只读。
  bool upstreamUsesPool(String upstreamId) {
    final pool = proxies;
    if (pool == null) return false;
    final p = ProxyPool.pUpstream(upstreamId);
    return pool.isEnabled(p) && pool.groupFor(p) != null;
  }

  /// 该供应商当前绑定的池分组名（未绑定为 null），设置页仅用于展示状态。
  String? upstreamPoolGroup(String upstreamId) =>
      proxies?.groupFor(ProxyPool.pUpstream(upstreamId));

  /// 双出口共有模型的优先区：''=跟随号池全局开关，'cn'/'intl' 优先对应区。
  /// 优先区账号跑满时新会话自动溢出到另一区（见 ProxyServer._pickSharedRealm）。
  /// 独占模型不受影响。写 config + 同步到运行中的网关，下一次请求即生效。
  void setWorkbuddyPreferredRealm(String realm) {
    final r = realm == 'cn' || realm == 'intl' ? realm : '';
    if (config.workbuddyPreferredRealm == r) return;
    config.workbuddyPreferredRealm = r;
    config.save();
    server?.workbuddyPreferredRealm = r;
    notifyListeners();
  }

  /// 出口方式切换。「内置代理池」= 启用 `upstream:<id>` 用途（分组去
  /// 「代理」页绑定）；「手写地址」= 停用该用途，出口回落到 proxy 字段。
  /// 切换即时生效（directives() 每次请求现算），落盘由 _onPoolChanged 完成。
  void setUpstreamPoolEgress(String upstreamId, {required bool usePool}) {
    final pool = proxies;
    if (pool == null) return;
    final p = ProxyPool.pUpstream(upstreamId);
    if (pool.isEnabled(p) == usePool) return;
    pool.setEnabled(p, usePool);
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
    if (u.proxyEnabled == false && u.proxy.trim().isEmpty) {
      u.proxyEnabled = true;
    }
    config.save();
    for (final rt in _runtimes) {
      if (rt.def.type == 'zen') {
        rt.def.baseUrl = u.baseUrl;
        unawaited(rt.probe());
      }
    }
    notifyListeners();
  }

  // ---- WorkBuddy 号池数据（账号 / 额度 / 成本）----

  /// 配置里是否有 WorkBuddy 号池供应商
  bool get hasWorkBuddy => config.upstreams.any((u) => u.id == WorkBuddy.id);

  /// 账号目录：取 workbuddy 供应商的 `--accounts-dir`，缺省兜底
  /// `%APPDATA%\zeroapi\workbuddy\accounts`（非 Windows 用 HOME/.config）
  String get workbuddyAccountsDir =>
      _workbuddyArg('--accounts-dir') ??
      '${_workbuddyDataRoot.path}${Platform.pathSeparator}accounts';

  /// 用量目录：取 `--usage-dir`，缺省兜底 `<dataRoot>/usage`
  String get workbuddyUsageDir =>
      _workbuddyArg('--usage-dir') ??
      '${_workbuddyDataRoot.path}${Platform.pathSeparator}usage';

  /// 定价表：`<dataRoot>/pricing/pricing.json`。数据目录里没有随包价表时
  /// 回落 vendor 自带的（随包运行时会带 pricing/pricing.json），都缺失时返回
  /// 规范路径（读出来是空价表，成本按 0 计，不报错）。
  String get workbuddyPricingPath {
    final p =
        '${_workbuddyDataRoot.path}${Platform.pathSeparator}pricing'
        '${Platform.pathSeparator}pricing.json';
    if (File(p).existsSync()) return p;
    final vendor = GatewayConfig.findWorkBuddyVendor();
    if (vendor != null) {
      final v =
          '${vendor.path}${Platform.pathSeparator}pricing'
          '${Platform.pathSeparator}pricing.json';
      if (File(v).existsSync()) return v;
    }
    return p;
  }

  /// 读取号池总览。账号目录不存在或读取失败时返回 null（UI 显示「无数据」）。
  Future<WbOverview?> loadWorkBuddyOverview() async {
    try {
      return await AccountData.load(
        accountsDir: workbuddyAccountsDir,
        usageDir: workbuddyUsageDir,
        pricingPath: workbuddyPricingPath,
      );
    } catch (_) {
      return null;
    }
  }

  /// hub 根地址（baseUrl 去掉末尾 `/v1`，形如 `http://127.0.0.1:8788`）。
  /// 一键签到等 hub 管理接口都挂在这个根下，不在 `/v1` 里。
  /// 配置里没有 workbuddy 供应商或 baseUrl 异常时返回空串。
  String get workbuddyHubBase {
    for (final def in config.upstreams) {
      if (def.id != WorkBuddy.id) continue;
      var base = def.baseUrl.trim();
      while (base.endsWith('/')) {
        base = base.substring(0, base.length - 1);
      }
      if (base.endsWith('/v1')) {
        base = base.substring(0, base.length - 3);
      }
      return base;
    }
    return '';
  }

  /// 号池用量（hub 自己的 usage.jsonl 聚合）。[sinceDays] 限制天数
  /// （含今天），null 表示全部；成本按 wbdata 口径：credit 优先、
  /// 缺失时用 [workbuddyPricingPath] 价表估算。usage 目录不存在或
  /// 读取失败返回 null（UI 显示「无数据」），与 [loadWorkBuddyOverview] 一致。
  Future<WbUsageStats?> loadWorkBuddyUsage({int? sinceDays}) async {
    try {
      final pricing = await WbData.readPricing(workbuddyPricingPath);
      return await WbData.readUsage(
        workbuddyUsageDir,
        sinceDays: sinceDays,
        pricing: pricing,
      );
    } catch (_) {
      return null;
    }
  }

  /// 一键签到（全部国内账号，POST {hub}/accounts/checkin）。
  /// 成功返回 HubActions.summarizeCheckin 的汇总文案；未接入号池或
  /// 请求失败抛异常，UI 直接显示异常原因。
  Future<String> checkinWorkBuddy() async {
    final base = workbuddyHubBase;
    if (base.isEmpty) {
      throw StateError('未接入 WorkBuddy 号池，无法签到');
    }
    return HubActions.checkinAll(base);
  }

  // ---- 号池看板（原生 Flutter，经 hub 管理接口取数）----

  String? _hubToken;

  /// 面板会话 token：POST /panel/login（密码取 workbuddy 启动参数，默认
  /// admin），成功后缓存；[forceRefresh] 清缓存重登。
  Future<String?> hubPanelToken({bool forceRefresh = false}) async {
    if (!forceRefresh && _hubToken != null) return _hubToken;
    _hubToken = null;
    final base = workbuddyHubBase;
    if (base.isEmpty) return null;
    UpstreamDef? def;
    for (final u in config.upstreams) {
      if (u.id == WorkBuddy.id) {
        def = u;
        break;
      }
    }
    if (def == null) return null;
    final password = WorkBuddy.panelPassword(def);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(Uri.parse('$base/panel/login'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'password': password}));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(body);
      if (j is Map && j['token'] is String) {
        _hubToken = j['token'] as String;
        return _hubToken;
      }
    } catch (_) {
      // 忽略：面板未启动/密码不符都按未就绪处理
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// 带面板 token 的 GET；401 时自动重登一次。失败返回 null（不抛）。
  Future<Map<String, dynamic>?> hubGet(String path) async {
    final base = workbuddyHubBase;
    if (base.isEmpty) return null;
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await hubPanelToken(forceRefresh: attempt > 0);
      if (token == null) return null;
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.getUrl(Uri.parse('$base$path'));
        req.headers.set('X-Panel-Token', token);
        final resp = await req.close().timeout(const Duration(seconds: 20));
        final body = await resp.transform(utf8.decoder).join();
        if (resp.statusCode == 401) continue; // 会话失效 → 重登
        if (resp.statusCode != 200) return null;
        final j = jsonDecode(body);
        return j is Map<String, dynamic> ? j : null;
      } catch (_) {
        return null;
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  /// 带面板 token 的 POST（签到/打卡等写操作）；401 自动重登一次。
  /// 成功返回解析后的 JSON 对象，失败（网络/非 200/非对象）抛 [HttpException]
  /// 或 [FormatException]，由 UI 显示原因。[body] 为空对象即 `{}`（全部账号）。
  Future<Map<String, dynamic>> hubPost(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final base = workbuddyHubBase;
    if (base.isEmpty) throw StateError('未接入 WorkBuddy 号池');
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await hubPanelToken(forceRefresh: attempt > 0);
      if (token == null) throw StateError('号池面板登录失败');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.postUrl(Uri.parse('$base$path'));
        req.headers.set('X-Panel-Token', token);
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
        final resp = await req.close().timeout(timeout);
        final text = await resp.transform(utf8.decoder).join();
        if (resp.statusCode == 401) continue; // 会话失效 → 重登一次
        if (resp.statusCode != 200) {
          throw HttpException(
            'HTTP ${resp.statusCode}',
            uri: Uri.parse('$base$path'),
          );
        }
        final j = jsonDecode(text);
        if (j is! Map<String, dynamic>) {
          throw const FormatException('号池响应不是 JSON 对象');
        }
        return j;
      } finally {
        client.close(force: true);
      }
    }
    throw StateError('号池面板会话失效');
  }

  Future<List<Map<String, dynamic>>> hubAccounts() async {
    // realm=all：hub 缺省只返回全局开关那一个区的账号，双区同开必须取全部
    final j = await hubGet('/accounts?realm=all');
    final list = j?['accounts'];
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map<String, dynamic>) e,
    ];
  }

  Future<Map<String, dynamic>?> hubUsageToday() => hubGet('/v1/usage?days=1');
  Future<Map<String, dynamic>?> hubScheduler() => hubGet('/scheduler');

  Future<List<Map<String, dynamic>>> hubTasks() async {
    final j = await hubGet('/tasks?limit=20');
    final list = j?['tasks'];
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map<String, dynamic>) e,
    ];
  }

  /// 活动历史（签到/每日活跃记录）。[range] 取 hub 的 today/1d/7d/30d/90d/all，
  /// [task] 取 checkin/daily_chat，[result] 取 ok/failed；缺省不筛。
  Future<List<Map<String, dynamic>>> hubActivity({
    int limit = 30,
    String? range,
    String? task,
    String? result,
  }) async {
    final q = StringBuffer('/activity/history?limit=$limit');
    if (range != null && range.isNotEmpty) q.write('&range=$range');
    if (task != null && task.isNotEmpty) q.write('&task=$task');
    if (result != null && result.isNotEmpty) q.write('&result=$result');
    final j = await hubGet(q.toString());
    final list = j?['rows'];
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map<String, dynamic>) e,
    ];
  }

  /// WorkBuddy 数据根目录（与随包 hub 写入的位置一致）
  Directory get _workbuddyDataRoot => WorkBuddy.dataRoot();

  /// 从 workbuddy 供应商的 args 里取 `--flag value` 的 value；取不到返回 null
  String? _workbuddyArg(String flag) {
    for (final def in config.upstreams) {
      if (def.id != WorkBuddy.id) continue;
      final i = def.args.indexOf(flag);
      if (i >= 0 && i + 1 < def.args.length) {
        final v = def.args[i + 1].trim();
        if (v.isNotEmpty) return v;
      }
      return null;
    }
    return null;
  }

  @override
  void dispose() {
    ModelsDev.instance.stop();
    _refreshTimer?.cancel();
    for (final u in _runtimes) {
      u.stop();
    }
    server?.stop();
    // 代理池：摘掉自动保存监听、清全局句柄，停掉进程内 SOCKS5 中转
    // （中转挂的是 SocksRelayHub.instance 的 loopback 监听，进程退出前不
    //  显式 stop 会一直占端口）
    final pool = proxies;
    if (pool != null) {
      pool.removeListener(_onPoolChanged);
      pool.stopAutoProbe(); // 停掉可达巡检计时器，避免 dispose 后仍在后台探测
      if (identical(activePool, pool)) activePool = null;
      unawaited(SocksRelayHub.instance.stopAll());
    }
    _coreSyncTimer?.cancel();
    _coreRefreshTimer?.cancel();
    _subRefreshTimer?.cancel();
    unawaited(ProxyCore.instance.stop());
    proxies = null;
    super.dispose();
  }
}
