import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'accountdata.dart';
import 'config.dart';
import 'hubactions.dart';
import 'modelsdev.dart';
import 'opencode.dart';
import 'opencode_api.dart';
import 'opencode_api_v2.dart';
import 'ocruntime.dart';
import 'proxy.dart';
import 'proxycore.dart';
import 'proxypool.dart';
import 'socksrelay.dart';
import 'upstream.dart';
import 'wbdata.dart';
import 'workbuddy.dart';
import 'zen_egress_plan.dart';

/// 聚合所有组件的应用级服务，向 UI 广播状态变化
class GatewayService extends ChangeNotifier {
  GatewayService()
    : config = GatewayConfig.load(),
      _initializeProviders = true,
      _fileLog = true;

  /// 网关监听顺序测试只使用内存配置，不接触真实号池、配置或代理内核。
  ///
  /// 也不落盘网关日志：测试实例监听 127.0.0.1:0，若跟着写用户的真实
  /// gateway.log，会把「监听 http://127.0.0.1:0/v1」这类测试痕迹混进
  /// 排障现场（2026-11-07 连续踩两次，害我误判现场）。
  @visibleForTesting
  GatewayService.listenerTest(this.config)
    : _initializeProviders = false,
      _fileLog = false;

  /// 是否把网关日志落盘到用户目录（仅生产实例 true）。
  final bool _fileLog;

  GatewayConfig config;
  final bool _initializeProviders;
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

  Future<void>? _starting;
  Future<void>? _restarting;
  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);

  /// 启动代次：重启时递增，后台初始化发现代次过期就放弃，避免上一轮的
  /// 异步任务把上一轮的运行时写进当前状态。
  int _generation = 0;

  /// 已释放：后台初始化可能在 dispose 之后才回调，届时不能再通知监听者。
  bool _disposed = false;

  /// 安全通知：dispose 之后静默跳过（后台任务仍会收尾，但不再触碰 UI）。
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> _start() async {
    if (running) return;
    startError = null;
    final generation = ++_generation;
    // 网关先起：代理池、内核同步（实测 17s）与供应商预热都很慢，放到后台
    // 做，窗口与网关端口立即可用，模型随后陆续出现。
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
            // 生产实例才落盘网关日志（测试实例不写用户的真实日志文件）
            logDir: _fileLog ? _zenLogDir : null,
          )
          ..onUnknownModel = _refreshRoutes
          ..onIpBan = (id) {
            onIpBanDetected?.call(id);
          }
          ..onQuotaExhausted = _markZenQuotaExhausted
          ..onPrepareOpenCode = _prepareZenRequest
          ..onOpenCodeFinished = _finishZenRequest
          ..onOpenCodeSuccess = _markZenQuotaOk
          ..onRotateEgress =
              ((id, retryAfterSeconds, failureKind) => _serializeEgress(
                () => _rotateZenEgressAndWait(id, retryAfterSeconds, failureKind),
              ))
          ..onEgressBudgetExhausted = _markZenEgressBudgetExhausted
          ..onStaleCli = _restartStaleZenCli;
    try {
      await server!.start();
      running = true;
      _notify();
    } catch (e) {
      startError = '$e';
      _notify();
      return;
    }
    if (_initializeProviders) unawaited(_bootstrap(generation));
  }

  /// 后台初始化：模型目录、号池接入、代理池与内核、供应商运行时、定时器。
  Future<void> _bootstrap(int generation) async {
    try {
      await _bootstrapInner(generation);
    } catch (e) {
      if (generation != _generation || _disposed) return;
      startError = '$e';
      _notify();
    }
  }

  Future<void> _bootstrapInner(int generation) async {
    ModelsDev.instance.onUpdated = () {
      for (final u in _runtimes) {
        if (u.def.enabled) {
          unawaited(
            u
                .probe()
                .then((_) => registry.rebuild(_runtimes))
                .then((_) => _notify()),
          );
        }
      }
    };
    unawaited(ModelsDev.instance.start());
    if (generation != _generation) return;
    // 首次启动自动接入 WorkBuddy 号池（仅在随包运行时存在时；只做一次）
    // 用户手动指定的 CLI 路径优先于自动探测
    OpenCodeRuntime.overridePath = config.opencodeCliPath.isEmpty
        ? null
        : config.opencodeCliPath;
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
        if (!u.supportsUpstreamEgress &&
            pool.assignments.remove(ProxyPool.pUpstream(u.id)) != null) {
          cleaned = true;
        }
      }
      if (cleaned) pool.save();
      pool.addListener(_onPoolChanged);
      activePool = proxies = pool;
    }
    // Zen CLI 的真实目标是 opencode.ai：默认探活目标（Cloudflare 204）
    // 只能证明「节点能出网」，不能证明「节点能访问上游 API」。按用途登记
    // 真实目标后，不通上游的节点不会进入 Zen 的轮换候选。
    proxies?.setPurposeTarget(
      ProxyPool.pUpstream(OpenCode.id),
      'https://opencode.ai/',
    );
    // zen 池绑定孤儿自动修复（分组被删过 → 绑定丢了 → 三级轮换被绕过）
    if (proxies != null) ensureZenPoolBinding(proxies!);
    // 加密协议节点（ss/vmess/vless/trojan/hysteria2/tuic）交给随包 mihomo：
    // 每个节点一个 127.0.0.1 HTTP listener，端口写回 pool.corePorts。
    await ProxyCore.instance.sync(proxies!);
    if (_disposed || generation != _generation) return;
    for (final runtime in _runtimes) {
      runtime.onStatusChanged = null;
      final child = runtime.child;
      runtime.stop();
      if (child != null) {
        await child.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1,
        );
      }
    }
    _runtimes.clear();
    for (final def in config.upstreams) {
      // zen CLI 通路：出口走池（自动探测优先；家宽直连仅兜底——免费额度
      // 按出口 IP × 天计，家宽单 IP 撑不住长上下文对话）
      if (def.id == OpenCode.id && def.type == 'managed') {
        // 线协议按本机 CLI 大版本对齐（v2 必须 Basic 鉴权 + /api/*；v1 绝不能
        // 设 OPENCODE_SERVER_PASSWORD——设了 POST message 会挂死）。必须在
        // 子进程第一次 spawn 之前跑：env 会原样传给子进程。
        if (await OpenCode.reconcileProtocol(def)) config.save();
        final url = _pickZenCliEgress(def.id);
        if (url != null) _setZenCliEgressEnv(def, url);
      }
      // 供应商预热就绪时立即重建路由表（不等 60s 周期刷新），
      // 否则冷启动后模型要干等下一轮刷新才出现
      final rt = UpstreamRuntime(def)..onStatusChanged = refreshRoutesNow;
      _runtimes.add(rt);
      // 号池：先用本地缓存的模型目录把清单填上，引擎就绪后由真实探测覆盖。
      // 否则引擎拉远端目录期间模型页是空的（实测可达数十秒）。
      if (def.id == WorkBuddy.id) {
        final cached = await WorkBuddy.cachedCatalog();
        if (cached.realms.isNotEmpty && rt.models.isEmpty) {
          rt.models = cached.realms.keys.toList();
          rt.modelRealms.addAll({
            for (final e in cached.realms.entries)
              if (!cached.shared.contains(e.key)) e.key: e.value,
          });
          rt.sharedModels.addAll(cached.shared);
          registry.rebuild(_runtimes);
          _notify();
        }
      }
      // 出口同步可能触发 CLI 重启与探活（数秒），不能挡住后面的初始化。
      if (rt.isOpenCode) unawaited(_syncZenCliEgress());
      rt.startPeriodicProbe();
      // managed 立即拉起/探活：此前只靠 30s 的周期定时器，冷启动后
      // 内置供应商（zen CLI/号池）要干等 30s 才出现，期间请求全 404
      if (def.enabled && def.type == 'managed') {
        unawaited(rt.ensure());
      }
    }
    if (generation != _generation) return;
    server!.workbuddyPreferredRealm = config.workbuddyPreferredRealm;
    unawaited(_refreshRoutes());
    // 节点可达性巡检：启动即扫一轮，之后每 60s 一轮；成功清零失败计数
    // 解禁冷却（坏节点不用手动逐个刷新，修好一分钟内自动回轮换）。
    final pool = proxies;
    if (pool != null) {
      unawaited(pool.autoProbeOnce());
      pool.startAutoProbe();
      // zen 出口**预热测速**：启动后台立刻测一轮（87 个节点约 10s），
      // 这样第一个用户请求命中的是热快照，而不是在请求关键路径上等全量扫描
      // （实测冷启动第一个请求 25s，其中 10.8s 是那次扫描）。
      unawaited(
        pool
            .measuredCandidatesFor(ProxyPool.pUpstream(OpenCode.id))
            .catchError((Object _) => const <PoolCandidate>[]),
      );
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
      unawaited(_syncCoreAndEgress(pool));
    });
    // 订阅自动刷新：每 30 分钟巡检一次（到期刷新 + 失败优先刷新；
    // 池变化/探测完成也会即时触发检查）
    _subRefreshTimer ??= Timer.periodic(const Duration(minutes: 30), (_) {
      final pool = proxies;
      if (pool != null) _maybeAutoRefreshGroups(pool);
    });
    _notify();
  }

  Future<void> restartServer() =>
      _restarting ??= _restartServer().whenComplete(() => _restarting = null);

  Future<void> _restartServer() async {
    await _starting;
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

  /// 一轮完整测速后的候选，以及当前请求已经尝试的节点。
  final Map<String, List<PoolCandidate>> _zenMeasuredCandidates = {};
  final Set<String> _zenAttemptedNodes = {};

  /// 三级通路轮换状态机（Worker → 机场 → 直连，用户指定顺序）。
  ZenEgressPlan _zenPlan = ZenEgressPlan();

  /// **档位冷却**：某档刚挂死（传输失败/停滞）时，短时间内不再从这档起步。
  /// 挂死的档每次都要白等一轮 90s 看门狗（用户实测「一个你好两分钟没反应」
  /// = 第一档挂死 → 90s → 才换档）。额度耗尽**不**冷却：Worker 额度用完
  /// 重连就能换 CF 边缘 IP，值得再试。
  final Map<ZenEgressTier, DateTime> _zenTierCooldown = {};

  /// 档位冷却时长（挂死后多久再从这档起步）。
  static const _zenTierCooldownSec = 5 * 60;

  /// 本轮的起步档：上次成功的那一档（如果它没在冷却中）。
  ZenEgressTier? _zenStartTier() {
    final last = _zenLastOkTier;
    if (last == null) return null;
    final tier = ZenEgressTier.values.where((t) => t.name == last).firstOrNull;
    if (tier == null) return null;
    if (_zenTierCooldown[tier]?.isAfter(DateTime.now()) == true) return null;
    return tier;
  }

  /// 当前处于冷却中的档位（已过期的不算）。
  Set<ZenEgressTier> _zenSkippedTiers() {
    final now = DateTime.now();
    _zenTierCooldown.removeWhere((_, until) => until.isBefore(now));
    return _zenTierCooldown.keys.toSet();
  }

  /// 记录某档挂死：冷却 5 分钟，期间的新请求直接从下一档起步。
  void _markZenTierStalled(ZenEgressTier tier) {
    final until = DateTime.now().add(
      const Duration(seconds: _zenTierCooldownSec),
    );
    _zenTierCooldown[tier] = until;
    server?.log(
      'Zen ${tier.name} 档挂死，冷却 '
      '${_zenTierCooldownSec ~/ 60} 分钟（期间请求直接从下一档起步）',
    );
  }

  /// **当前 CLI 正在用的出口节点 id**（直接记录，不再从 env 里的代理 URL
  /// 反查候选列表）。Worker/直连档无对应池节点（CF 边缘 IP / 家宽）。
  final Map<String, String> _zenCurrentNodeId = {};

  /// Worker 档的隧道节点（Worker 也要经机场节点才能到 workers.dev）。
  final Map<String, String> _zenWorkerTunnelNode = {};

  /// 最近一次**成功**的档位（'worker'/'airport'/'direct'）：下次请求优先
  /// 复用同档同出口（成功说明该桶有额度）。
  String? _zenLastOkTier;

  /// 当前的「快速失败」是不是**轮换超时**（预算用尽）而不是真的额度烧穿。
  /// 两种成因的恢复节奏与文案都不同：超时只锁 5 分钟（池里还有出口没试），
  /// 额度烧穿按上游给的 retryAfter（≈UTC 零点）。
  bool _zenExhaustedIsBudget = false;

  /// **整池免费额度烧穿**的已知截止时刻（本轮轮换所有出口都报 free-limit 时
  /// 取观测到的最大 retryAfter）。
  ///
  /// 免费额度按「客户端身份 × 出口 IP × 天」计，共享机场 IP 的日额度会被
  /// 同订阅其他用户烧穿；Worker 的 CF anycast 池同样被全球流量摊薄（实测
  /// 两条路同时报 free-limit、retryAfter 都指向同一重置点）。此时**每个
  /// 请求都重走 6 轮轮换 ≈ 2 分钟才报 429** 是纯粹的浪费——后续请求直接
  /// 快速失败并给出恢复时刻，由后台探测在恢复后自动解除。
  DateTime? _zenExhaustedUntil;
  Timer? _zenRecoveryTimer;
  bool _zenRecoveryProbing = false;
  bool _zenRequestPreparing = false;
  int _zenRequestsActive = 0;
  bool _zenSyncPending = false;
  ProxyPool? _pendingCorePool;

  void _finishZenRequest() {
    if (_zenRequestsActive > 0) _zenRequestsActive--;
    if (_disposed || _zenRequestsActive > 0) return;
    final pool = _pendingCorePool;
    _pendingCorePool = null;
    if (pool != null) {
      unawaited(_syncCoreAndEgress(pool));
    } else if (_zenSyncPending) {
      unawaited(_syncZenCliEgress());
    }
  }

  Future<void> _syncCoreAndEgress(ProxyPool pool) async {
    if (_zenRequestsActive > 0 || _zenRequestPreparing) {
      _pendingCorePool = pool;
      return;
    }
    await ProxyCore.instance.sync(pool);
    if (_disposed || !identical(proxies, pool)) return;
    await _syncZenCliEgress();
    _notify();
  }

  Future<void> _prepareZenRequest() async {
    _zenAttemptedNodes.clear();
    // 每请求重开一轮三档轮换；刚挂死的档位直接跳过（不白等 90s 看门狗）；
    // 起步档 = 上次成功的那一档（额度按桶×天计，成功说明那个桶还有额度，
    // 前面烧穿的档位不必每次重走一遍）。
    _zenPlan = ZenEgressPlan(
      skipTiers: _zenSkippedTiers(),
      startTier: _zenStartTier(),
    );
    _zenRequestPreparing = true;
    try {
      await _serializeEgress(_prepareZenRequestNow);
    } finally {
      _zenRequestPreparing = false;
    }
  }

  Future<void> _prepareZenRequestNow() async {
    final pool = proxies;
    if (pool == null || _disposed) return;
    final rt = _runtimes.where((r) => r.isOpenCode).firstOrNull;
    if (rt == null) return;
    // 整池烧穿已知期内：快速失败（不再 6 轮轮换白等 2 分钟）。恢复由后台
    // 探测负责（_scheduleZenRecoveryProbe），到点自动解除。
    final exhausted = _zenExhaustedUntil;
    if (exhausted != null && DateTime.now().isBefore(exhausted)) {
      final clock =
          '${exhausted.hour.toString().padLeft(2, '0')}:'
          '${exhausted.minute.toString().padLeft(2, '0')}';
      // 两种成因要给不同文案：额度烧穿 vs 轮换超时（后者池里还有出口没试）。
      final msg = _zenExhaustedIsBudget
          ? 'OpenCode 出口轮换超时（本轮试过的出口都没能完成请求，池里还有'
                '出口没试完），约 $clock 前后自动恢复探测；期间请求会快速失败。'
          : 'OpenCode 免费额度整池烧穿（共享出口的当日额度被同网络其他用户'
                '消耗，与你的用量无关），预计 $clock 前后恢复；'
                '期间可改用其他供应商的模型。';
      throw ZenQuotaExhausted(msg, exhausted);
    }
    if (exhausted != null) _zenExhaustedUntil = null;
    final purpose = ProxyPool.pUpstream(rt.id);
    if (upstreamUsesPool(rt.id)) {
      // 上次成功的档位 + 出口仍然健康 → 直接复用，不测速不重启（额度按
      // 「桶 × 天」计，当天不变）。Worker 档的 env（baseURL 注入 + 隧道）
      // 都在 def 里持久化，什么都不用改。
      final lastTier = _zenLastOkTier;
      final lastNode = _zenCurrentNodeId[rt.id];
      final reuseOk =
          lastTier != null &&
          rt.health == UpstreamHealth.healthy &&
          (lastTier == 'worker' ||
              (lastNode != null && pool.isQuotaOk(lastNode)));
      if (reuseOk) {
        server?.log('Zen 复用上次成功的出口（$lastTier 档）');
        _zenRequestsActive++;
        return;
      }
      // 先同步 listener，再等待全组检测；绝不从旧列表盲取三个。
      final sw = Stopwatch()..start();
      await ProxyCore.instance.sync(pool);
      server?.log('Zen 出口内核同步耗时 ${sw.elapsedMilliseconds}ms');
      if (_disposed || !identical(proxies, pool)) return;
      server?.log('Zen 正在全量测速绑定分组，等待检测完成后选择出口');
      sw.reset();
      final candidates = await pool.measuredCandidatesFor(purpose);
      server?.log('Zen 全量测速耗时 ${sw.elapsedMilliseconds}ms，候选 ${candidates.length} 个');
      _zenMeasuredCandidates[rt.id] = candidates;
      // 起步档 = 直连（上次成功的就是家宽）时，池里有没有候选都无所谓：
      // 这一档不走池。不能用「没有出口」把请求掐死。
      if (candidates.isEmpty && _zenPlan.tier != ZenEgressTier.direct) {
        // 全部候选被剔除时，先看是不是额度冷却造成的——是就按「整池烧穿」
        // 快速失败并附恢复时刻，而不是误导性的「没有出口」。
        final cooldowns = pool.health.values
            .map((h) => h.quotaUntil)
            .whereType<DateTime>()
            .where((t) => t.isAfter(DateTime.now()))
            .toList();
        if (cooldowns.isNotEmpty) {
          final until = cooldowns.reduce(
            (a, b) => a.isBefore(b) ? a : b,
          );
          _zenExhaustedUntil = until;
          _scheduleZenRecoveryProbe(until);
          throw ZenQuotaExhausted(
            'OpenCode 免费额度整池烧穿（共享出口的当日额度被同网络其他用户'
            '消耗，与你的用量无关），预计 '
            '${until.hour.toString().padLeft(2, '0')}:'
            '${until.minute.toString().padLeft(2, '0')} 前后恢复；'
            '期间可改用其他供应商的模型。',
            until,
          );
        }
        throw const ZenExitUnavailable(
          'Zen 全量测速完成：绑定分组没有通过目标站检测的出口（超时/失败均已剔除）',
        );
      }
      server?.log('Zen 全量测速完成：${candidates.length} 个出口通过');
      // **三级通路（用户指定顺序）：Worker(CF 边缘 IP) → 机场节点 → 直连。**
      // 初始档 = Worker：出口 IP 归 CF 边缘池，同一节点断开重连即换 CF IP
      // （10-22 实测 12 连接全 200），不消耗机场节点的额度桶。机场档的
      // quotaOk 优先在此仍适用——隧道节点选已验证可用的最稳。
      //
      /// 例外：Worker 档刚挂死且在冷却中 → 这一轮直接从机场档起步，
      /// 不再白等一轮 90s 首字看门狗（用户实测「一个你好两分钟没反应」）。
      final verified = candidates
          .where((c) => c.nodeId != null && pool.isQuotaOk(c.nodeId!))
          .toList();
      // 直连档起步时可能一个候选都没有（池全冷却）——那一档不用池。
      final selected = verified.isNotEmpty
          ? verified.first
          : (candidates.isNotEmpty
                ? candidates.first
                : const PoolCandidate('', null));
      if (selected.nodeId != null) {
        _zenAttemptedNodes.add(selected.nodeId!);
        _zenCurrentNodeId[rt.id] = selected.nodeId!;
        _zenWorkerTunnelNode[rt.id] = selected.nodeId!;
      }
      final startTier = _zenPlan.tier;
      // 直连档不用任何代理（家宽出口，独立的额度桶）。
      final url = startTier == ZenEgressTier.direct
          ? ''
          : _zenCandidateUrl(selected);
      if (_setZenTierEnv(rt, startTier, url)) {
        await rt.restartChild();
      }
      server?.log(
        switch (startTier) {
          ZenEgressTier.worker =>
            'Zen Worker 档（CF 边缘 IP）→ 隧道 ${selected.nodeId}',
          ZenEgressTier.airport =>
            'Zen 机场档起步 → ${selected.nodeId}'
                '（Worker 档冷却中/上次成功的档位在后面，不再从它起步）',
          ZenEgressTier.direct =>
            'Zen 直连档起步（家宽，独立额度桶；Worker/机场档已烧穿或冷却）',
        },
      );
      await rt.ensure();
    }
    // 出口是否可用：CLI 进程活着就说明代理口是通的（进程启动时已经连上过）。
    // 旧实现每个请求都去 socket 探一次代理口（2s 超时）+ 再跑一遍出口同步
    // （可能又重启 CLI）——请求越多等得越久（用户实测「一个你好两分钟」）。
    // 现在只在 CLI 不健康时才做连通性检查与出口修复。
    if (rt.health != UpstreamHealth.healthy) {
      final uri = Uri.tryParse(rt.def.env['HTTPS_PROXY'] ?? '');
      var alive = uri == null || uri.host.isEmpty;
      if (!alive) {
        try {
          final socket = await Socket.connect(
            uri.host,
            uri.port,
            timeout: const Duration(seconds: 2),
          );
          socket.destroy();
          alive = true;
        } catch (_) {}
      }
      if (!alive ||
          (upstreamUsesPool(rt.id) && (uri == null || uri.host.isEmpty))) {
        await ProxyCore.instance.sync(pool);
        await _syncZenCliEgressNow(preparing: true);
      } else {
        await _syncZenCliEgressNow(preparing: true);
      }
    }
    for (var i = 0; i < 30 && !_disposed; i++) {
      if (rt.health == UpstreamHealth.healthy) {
        _zenRequestsActive++;
        return;
      }
      await rt.ensure();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw const ZenExitUnavailable('Zen CLI 未能就绪，请检查运行时日志');
  }

  String _zenCandidateUrl(PoolCandidate candidate) =>
      'http://${candidate.directive.replaceFirst('PROXY ', '')}';

  /// **按档位写 CLI env**：Worker 档注入 provider baseURL 覆盖
  /// （OPENCODE_CONFIG_CONTENT，v2.2.5 实测遵守），机场/直连档还原种子值。
  /// [nodeUrl] 为隧道代理地址（直连档传 ''）。返回是否有变化。
  bool _setZenTierEnv(UpstreamRuntime rt, ZenEgressTier tier, String nodeUrl) {
    var changed = _setZenCliEgressEnv(rt.def, nodeUrl);
    final want = tier == ZenEgressTier.worker
        ? OpenCode.workerConfigContent()
        : '{"permission":{"*":"deny"}}';
    if ((rt.def.env['OPENCODE_CONFIG_CONTENT'] ?? '') != want) {
      rt.def.env = {...rt.def.env, 'OPENCODE_CONFIG_CONTENT': want};
      changed = true;
    }
    return changed;
  }

  /// 只从完成全量检测的快照取候选。池配置变更时先等下一轮检测。
  ///
  /// 额度按「客户端身份 × 出口 IP」计：只有真 opencode CLI 的 TLS 身份带
  /// 免费额度，通用探针只能证明「能出网」，证明不了「这个 IP 上有额度」。
  /// 被真 CLI 验证过当天有额度的出口优先选。
  String? _pickZenCliEgress(String upstreamId) {
    final pool = proxies;
    if (pool == null) return null;
    final purpose = ProxyPool.pUpstream(upstreamId);
    final valid = poolCandidatesFor(pool, purpose);
    final usable = <PoolCandidate>[];
    final measured = _zenMeasuredCandidates[upstreamId];
    for (final candidate in measured ?? <PoolCandidate>[]) {
      if (candidate.nodeId != null && pool.isQuotaSpent(candidate.nodeId!)) {
        continue;
      }
      if (!valid.any(
        (c) =>
            c.nodeId == candidate.nodeId && c.directive == candidate.directive,
      )) {
        continue;
      }
      usable.add(candidate);
    }
    final ok = usable
        .where((c) => c.nodeId != null && pool.isQuotaOk(c.nodeId!))
        .firstOrNull;
    final picked = ok ?? usable.firstOrNull;
    if (picked != null) return _zenCandidateUrl(picked);
    // 还没测速（应用刚启动）→ 退回**纯内存**的候选列表（poolCandidatesFor
    // 不做网络探测）。否则启动后第一个请求会因「没有测速快照」而报
    // 「暂无可用出口」并白等一轮测速。
    return valid.isEmpty ? null : _zenCandidateUrl(valid.first);
  }

  /// 把出口写进 zen CLI 的 env（HTTP_PROXY 等）。返回是否发生变化。
  bool _setZenCliEgressEnv(UpstreamDef def, String url) {
    final changed = (def.env['HTTPS_PROXY'] ?? '') != url;
    def.env = {
      ...def.env,
      'HTTP_PROXY': url,
      'HTTPS_PROXY': url,
      'http_proxy': url,
      'https_proxy': url,
      'ALL_PROXY': '',
      'all_proxy': '',
      'NO_PROXY': 'localhost,127.0.0.1,::1',
      'no_proxy': 'localhost,127.0.0.1,::1',
    };
    return changed;
  }

  Future<void> _egressQueue = Future<void>.value();
  Future<T> _serializeEgress<T>(Future<T> Function() action) {
    final result = _egressQueue.then((_) => action());
    _egressQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _syncZenCliEgress() => _serializeEgress(_syncZenCliEgressNow);

  Future<void> _syncZenCliEgressNow({bool preparing = false}) async {
    if (_zenRequestsActive > 0 || (_zenRequestPreparing && !preparing)) {
      _zenSyncPending = true;
      return;
    }
    _zenSyncPending = false;
    for (final rt in _runtimes.where((r) => r.isOpenCode && r.def.enabled)) {
      String? url;
      if (upstreamUsesPool(rt.id)) {
        final old = rt.def.env['HTTPS_PROXY'] ?? '';
        final candidates = poolCandidatesFor(
          proxies,
          ProxyPool.pUpstream(rt.id),
        ).where((c) => c.nodeId == null || !proxies!.isQuotaSpent(c.nodeId!));
        final stillAvailable = candidates.any(
          (c) => 'http://${c.directive.replaceFirst('PROXY ', '')}' == old,
        );
        url = stillAvailable ? old : _pickZenCliEgress(rt.id);
        if (url == null) {
          server?.log('Zen 绑定分组暂无可用出口，请检查节点连通性');
          continue;
        }
      } else {
        final raw = rt.def.proxyPool.firstOrNull;
        if (raw != null && raw.startsWith('socks5://')) {
          final relay = await SocksRelayHub.instance.ensure(raw);
          final directive = relay?.directive;
          final match = directive == null
              ? null
              : RegExp(r'PROXY\s+(\S+)').firstMatch(directive);
          if (match == null) continue;
          url = 'http://${match.group(1)}';
        } else {
          url = raw ?? '';
        }
      }
      if (_setZenCliEgressEnv(rt.def, url)) {
        server?.log('Zen 出口配置已更新，正在重启 CLI');
        await rt.restartChild();
        await rt.ensure();
      }
    }
  }

  /// CLI 通路成功 → 把「当前这个出口今天有额度」记到池里。
  ///
  /// 免费额度按「客户端身份 × 出口 IP」计，只有真 opencode CLI 的 TLS 身份
  /// 才带额度；通用探针只能证明「能出网」，证明不了「这个 IP 上有额度」。
  /// 所以 CLI 真跑通一次，才把该出口标记为当天可用，下次测速排序时优先。
  void _markZenQuotaOk(String upstreamId) {
    final pool = proxies;
    if (pool == null) return;
    // 成功档位记下来：下次请求优先复用同档同出口。
    _zenLastOkTier = _zenPlan.tier.name;
    // 只有机场档的额度桶对应池节点（Worker 桶是 CF 边缘 IP、直连是家宽）。
    if (_zenPlan.tier != ZenEgressTier.airport) return;
    final nodeId = _zenCurrentNodeId[upstreamId];
    if (nodeId == null) return;
    pool.markQuotaOk(nodeId);
    server?.log('Zen 已标记机场出口 $nodeId 当天额度可用');
  }

  /// 整池烧穿后的**后台恢复探测**：到预计恢复点前几分钟起，每隔几分钟用
  /// 一个最小请求试一个出口；跑通即解除烧穿状态、标记该出口可用——用户
  /// 无感知恢复。用户请求到来时探测会让路（不与真实请求抢 CLI）。
  void _scheduleZenRecoveryProbe(DateTime until) {
    _zenRecoveryTimer?.cancel();
    // 比预计恢复点早 2 分钟开始试，每 4 分钟一轮
    var next = until.subtract(const Duration(minutes: 2));
    final now = DateTime.now();
    if (next.isBefore(now.add(const Duration(seconds: 30)))) {
      next = now.add(const Duration(minutes: 4));
    }
    _zenRecoveryTimer = Timer(next.difference(now), () {
      unawaited(_zenRecoveryTick());
    });
  }

  Future<void> _zenRecoveryTick() async {
    if (_disposed) return;
    if (_zenRequestsActive > 0 || _zenRequestPreparing) {
      // 用户请求在跑：2 分钟后再看
      _zenRecoveryTimer = Timer(
        const Duration(minutes: 2),
        () => unawaited(_zenRecoveryTick()),
      );
      return;
    }
    if (_zenRecoveryProbing) return;
    _zenRecoveryProbing = true;
    try {
      final recovered = await _serializeEgress(_probeZenRecovery);
      if (recovered) {
        _zenExhaustedUntil = null;
        server?.log('Zen 免费额度已恢复（后台探测跑通），解除烧穿状态');
        return;
      }
      // 仍烧穿：4 分钟后再试
      _zenRecoveryTimer = Timer(
        const Duration(minutes: 4),
        () => unawaited(_zenRecoveryTick()),
      );
    } finally {
      _zenRecoveryProbing = false;
    }
  }

  /// 恢复探测的一次尝试：挑一个未冷却的出口发最小请求。返回是否跑通。
  Future<bool> _probeZenRecovery() async {
    final pool = proxies;
    if (pool == null || _disposed) return false;
    final rt = _runtimes.where((r) => r.isOpenCode).firstOrNull;
    if (rt == null) return false;
    final purpose = ProxyPool.pUpstream(rt.id);
    await ProxyCore.instance.sync(pool);
    final candidates = await pool.measuredCandidatesFor(purpose);
    _zenMeasuredCandidates[rt.id] = candidates;
    final node = candidates
        .where((c) => c.nodeId != null)
        .firstOrNull;
    if (node == null) return false;
    _zenCurrentNodeId[rt.id] = node.nodeId!;
    final url = _zenCandidateUrl(node);
    _setZenCliEgressEnv(rt.def, url);
    await rt.restartChild();
    await rt.ensure();
    for (var i = 0; i < 30 && !_disposed; i++) {
      if (rt.health == UpstreamHealth.healthy) break;
      await rt.ensure();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (rt.health != UpstreamHealth.healthy) return false;
    final model = rt.models.firstWhere(
      (m) => m.endsWith('-free') || m == 'big-pickle',
      orElse: () => rt.models.isNotEmpty ? rt.models.first : '',
    );
    if (model.isEmpty) return false;
    final api = rt.openCodeV2
        ? OpenCodeApiV2(
            rt.def.baseUrl,
            password: rt.def.env[OpenCode.serverPasswordEnv] ?? '',
          )
        : OpenCodeApi(rt.def.baseUrl)
      ..onActivity = ((_) {});
    try {
      final pieces = api.chat(
        model: model,
        messages: [
          {'role': 'user', 'content': 'reply with the single word OK'},
        ],
      );
      final it = StreamIterator(pieces);
      if (await it.moveNext().timeout(const Duration(seconds: 90))) {
        pool.markQuotaOk(node.nodeId!);
        return true;
      }
      return false;
    } on OpenCodeUpstreamError catch (e) {
      if (e.isQuotaExhausted) {
        final wait = api.retryAfterSeconds ?? 300;
        pool.markQuotaCooldown(
          node.nodeId!,
          DateTime.now().add(Duration(seconds: wait.clamp(60, 12 * 3600))),
        );
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      api.close();
    }
  }

  void _markZenQuotaExhausted(String upstreamId, int? retryAfterSeconds) {
    final rt = _runtimes.where((r) => r.id == upstreamId).firstOrNull;
    final pool = proxies;
    if (rt == null || pool == null) return;
    final old = rt.def.env['HTTPS_PROXY'] ?? '';
    for (final candidate
        in _zenMeasuredCandidates[upstreamId] ?? <PoolCandidate>[]) {
      if (candidate.nodeId != null && _zenCandidateUrl(candidate) == old) {
        // v2 给了确切恢复时刻（≈几小时后额度自动回来）：按它定时冷却，到点
        // 自动恢复——不整日拉黑（那样会误伤当天稍后可能有额度的出口），
        // 也不反复去撞（冷却期内它不进候选）。
        if (retryAfterSeconds != null && retryAfterSeconds > 0) {
          pool.markQuotaCooldown(
            candidate.nodeId!,
            DateTime.now().add(Duration(seconds: retryAfterSeconds)),
          );
        } else {
          // 上游没给时机（v1 只有文案）：按「出口 IP × 天」整日拉黑。
          pool.markQuotaSpent(candidate.nodeId!);
        }
      }
    }
    // 最终错误不另行启动第四个出口；下次请求重新按检测结果选择。
    onQuotaExhausted?.call(upstreamId);
  }

  /// 换出口并等新 CLI 进程就绪，供网关在同一次请求里原样重发。
  ///
  /// CLI 进程的出口在启动时由 HTTP_PROXY 绑定，换 IP 必须换进程；新进程
  /// 还要等 serve 就绪（几秒），期间请求会被上游拒绝，因此调用方要用
  /// 「未提交响应」路径重试。
  ///
  /// 额度耗尽的出口必须记成**额度**标记而不是「目标站不可达」：后者会被下一
  /// 轮全量测速清掉（首页探测成功就恢复候选）→ 又被挑中 → 又失败。
  /// 实测（2026-11-05）池里 77 个出口约一半额度可用，按延迟排序盲选会连续
  /// 撞到没额度的出口——这正是「实测还是不行」的机制。
  /// 三级通路的轮换执行：Worker(CF 边缘 IP，同节点重连) → 机场节点 → 直连。
  ///
  /// [failureKind]：'quota'（额度耗尽）/ 'transport'（连不上或挂死）——
  /// Worker 档的额度失败走「重连换 CF IP」（新连接≠旧 IP），传输失败直接
  /// 降机场档；机场档额度失败冷却该节点换下一个；直连失败即全部桶耗尽。
  Future<bool> _rotateZenEgressAndWait(
    String upstreamId, [
    int? retryAfterSeconds,
    String failureKind = 'quota',
  ]) async {
    final rt = _runtimes.where((r) => r.def.id == upstreamId).firstOrNull;
    if (rt == null) return false;
    final pool = proxies;
    if (pool == null) return false;
    if (!upstreamUsesPool(upstreamId)) return false;

    final purpose = ProxyPool.pUpstream(upstreamId);
    // 挂死（传输失败）的档位先记下来：冷却 5 分钟，期间的新请求直接从
    // 下一档起步，不再在这个死档上白等一轮 90s 看门狗。
    // 只冷却 **Worker 档**：它整档共用同一条 CF 通路，挂死多半是边缘 IP
    // 不行。机场档的挂死通常是「单个节点坏了」——换节点即可（下面已按
    // 节点记失败），不该把整档停掉。
    // **'overload'（上游过载）不冷却**：所有出口都打同一个推理服务，
    // 出口没坏（实测：Worker 档被过载拖死后换机场档就成功了）。
    final failedTier = _zenPlan.tier;
    if (failureKind == 'transport' && failedTier == ZenEgressTier.worker) {
      _markZenTierStalled(failedTier);
    }
    final action = _zenPlan.next(
      lastFailureKind: failureKind,
      airportHasCandidate: _zenAirportHasNext(upstreamId, purpose),
    );

    switch (action) {
      case ZenEgressAction.workerReconnect:
        // 同节点（env 未变）+ Worker baseURL 已注入：重启 CLI = 断开重连
        // = 换一个 CF 边缘 IP。额度桶在 CF 侧，机场节点不背锅、不冷却。
        server?.log(
          '⟳ zen Worker 档重连（换 CF 边缘 IP，'
          '第 ${_zenPlan.workerAttempts}/${ZenEgressPlan.workerBudget} 次）',
        );
        await rt.restartChild();
        await rt.ensure();
        return await _waitZenHealthy(rt);

      case ZenEgressAction.airportNext:
        // 降机场档：还原 provider baseURL（不注入 Worker），换下一个池节点
        if (_zenPlan.leftWorker) {
          server?.log('⟳ zen Worker 档不可用，降级机场节点档');
          _zenWorkerTunnelNode.remove(upstreamId);
        }
        final candidates = await pool.measuredCandidatesFor(purpose);
        _zenMeasuredCandidates[upstreamId] = candidates;
        final usable = candidates
            .where(
              (c) =>
                  c.nodeId != null &&
                  !_zenAttemptedNodes.contains(c.nodeId),
            )
            .toList();
        if (usable.isEmpty) {
          return await _rotateDirectOrExhaust(
            rt,
            upstreamId,
            failureKind,
            retryAfterSeconds,
          );
        }
        // 额度耗尽的节点当天冷却（有 retryAfter 按时刻，没有整日拉黑）；
        // 传输挂掉的节点记目标失败；**上游过载的节点不记任何失败**——
        // 出口本身是好的（所有出口都打同一个推理服务），不能冤枉节点。
        final failedNode = _zenCurrentNodeId[upstreamId];
        if (failedNode != null) {
          if (failureKind == 'quota') {
            if (retryAfterSeconds != null && retryAfterSeconds > 0) {
              pool.markQuotaCooldown(
                failedNode,
                DateTime.now().add(Duration(seconds: retryAfterSeconds)),
              );
            } else {
              pool.markQuotaSpent(failedNode);
            }
          } else if (failureKind == 'transport') {
            pool.markTargetFailed(failedNode, purpose);
          }
        }
        final next = usable.firstWhere(
          (c) => pool.isQuotaOk(c.nodeId!),
          orElse: () => usable.first,
        );
        _zenAttemptedNodes.add(next.nodeId!);
        _zenCurrentNodeId[upstreamId] = next.nodeId!;
        final url = _zenCandidateUrl(next);
        if (_setZenTierEnv(rt, ZenEgressTier.airport, url)) {
          server?.log('⟳ zen 机场档换出口 → $url（等待新进程就绪）');
          await rt.restartChild();
        }
        await rt.ensure();
        return await _waitZenHealthy(rt);

      case ZenEgressAction.direct:
        server?.log('⟳ zen 机场档耗尽，回退直连出口（家宽，独立额度桶）');
        _zenCurrentNodeId.remove(upstreamId);
        if (_setZenTierEnv(rt, ZenEgressTier.direct, '')) {
          await rt.restartChild();
        }
        await rt.ensure();
        return await _waitZenHealthy(rt);

      case ZenEgressAction.exhausted:
        // 三档全部耗尽：记录恢复时刻（直连档的 retryAfter ≈ 重置点），
        // 后续请求快速失败，后台探测到点自动恢复。
        final wait = retryAfterSeconds ?? 30 * 60;
        final until = DateTime.now().add(
          Duration(seconds: wait.clamp(60, 12 * 3600)),
        );
        if (_zenExhaustedUntil == null ||
            _zenExhaustedUntil!.isBefore(DateTime.now())) {
          _zenExhaustedUntil = until;
          server?.log(
            'Zen 三级通路全部耗尽（Worker→机场→直连），预计 '
            '${until.hour.toString().padLeft(2, '0')}:'
            '${until.minute.toString().padLeft(2, '0')} 前后恢复；'
            '后续请求将快速失败，恢复由后台探测自动完成',
          );
          _scheduleZenRecoveryProbe(until);
        }
        return false;
    }
  }

  /// 停滞看门狗掐掉一轮后**重启 CLI**（出口不变）：CLI 的 provider 连接池
  /// 里那条半路断流的连接还在，下一个请求复用它 → 又是一句之后卡死。
  /// 用户实测「第一句对话正常，第二句说了一句话然后卡住」就是这个连锁
  /// （2026-11-08 装机态：11:01:07 正常 → 11:01:47 卡 180s → 之后一直不健康）。
  ///
  /// 后台执行（不拖慢失败响应）；走出口队列，避免和换出口并发重启同一进程。
  Future<void> _restartStaleZenCli(String upstreamId) async {
    final rt = _runtimes.where((r) => r.def.id == upstreamId).firstOrNull;
    if (rt == null || _disposed) return;
    server?.log('⟳ zen 本轮被看门狗中止，重启 CLI 清理半死连接（出口不变）');
    await _serializeEgress(() async {
      if (_disposed) return;
      await rt.restartChild();
      await rt.ensure();
    });
  }

  /// zen 池绑定孤儿检查：zen 走池但 `upstream:zen` 的绑定失效（用户删过
  /// 分组——removeGroup 会把指向它的用途绑定一起清掉，重新导入不会恢复；
  /// 或绑定指向已删除的分组，groupFor 返回 null），且池里**恰好只有一个
  /// 订阅分组**时，自动重新绑定。没有绑定 = 三级轮换整个被绕过，zen 静默
  /// 直连家宽（2026-11-07 用户实测「删了重新导入也不行」的直接机制）。
  /// 多个订阅分组时不猜（让用户在代理页手动选）。
  ///
  /// 判定只用 [config]，**不依赖运行时实例**：本方法在 bootstrap 里
  /// 早于运行时创建调用，早期版本按「runtime 存在吗」判断 → 永远拿不到
  /// runtime → 修复从未生效（2026-11-07 实测：池里 89 个节点躺着，
  /// assignments 里却没有 upstream:zen，zen 一直直连）。
  void ensureZenPoolBinding(ProxyPool pool) {
    final purpose = ProxyPool.pUpstream(OpenCode.id);
    // 绑定仍然有效 → 什么都不用做
    if (pool.groupFor(purpose) != null) return;
    // 用户显式关掉了「zen 走池」→ 尊重用户选择，不自动绑回
    if (pool.isEnabled(purpose) == false) return;
    final zenDef = config.upstreams.where((u) => u.id == OpenCode.id).firstOrNull;
    if (zenDef == null || !zenDef.enabled) return;
    final subs = pool.groups
        .where((g) => g.sourceUrl.trim().isNotEmpty && g.nodes.isNotEmpty)
        .toList();
    if (subs.length != 1) {
      if (subs.length > 1) {
        server?.log(
          'Zen 池绑定缺失，且池里有 ${subs.length} 个订阅分组，无法自动判断用哪个；'
          '请在代理页为 zen 选择出口分组（不选则 zen 直连、三级轮换不生效）',
        );
      }
      return;
    }
    pool.assignments[purpose] = subs.single.name;
    pool.save();
    server?.log(
      'Zen 池绑定缺失（分组被删过），已自动重新绑定 → ${subs.single.name}'
      '（${subs.single.nodes.length} 节点）；如非预期请在代理页修改',
    );
    _notify();
  }

  /// 机场档是否还有没试过的候选节点（用最近一次测速快照判断，纯内存）。
  bool _zenAirportHasNext(String upstreamId, String purpose) {
    final pool = proxies;
    if (pool == null) return false;
    final snapshot = _zenMeasuredCandidates[upstreamId];
    if (snapshot == null) return true; // 还没测速：乐观假设有
    return snapshot.any(
      (c) =>
          c.nodeId != null &&
          !_zenAttemptedNodes.contains(c.nodeId) &&
          pool.targetUsable(c.nodeId!, purpose),
    );
  }

  /// 等待 CLI 就绪（轮换后的公共尾部）。
  Future<bool> _waitZenHealthy(UpstreamRuntime rt) async {
    for (var i = 0; i < 40; i++) {
      if (rt.health == UpstreamHealth.healthy) return true;
      await Future.delayed(const Duration(milliseconds: 500));
      if (rt.health != UpstreamHealth.healthy) await rt.probe();
    }
    return rt.health == UpstreamHealth.healthy;
  }

  /// 机场档耗尽后的收尾：先直连（独立额度桶），直连也失败才记整池烧穿。
  Future<bool> _rotateDirectOrExhaust(    UpstreamRuntime rt,
    String upstreamId,
    String failureKind,
    int? retryAfterSeconds,
  ) async {
    final plan = _zenPlan;
    final action = plan.next(
      lastFailureKind: failureKind,
      airportHasCandidate: false,
    );
    if (action == ZenEgressAction.direct) {
      server?.log('⟳ zen 机场档耗尽，回退直连出口（家宽，独立额度桶）');
      _zenCurrentNodeId.remove(upstreamId);
      if (_setZenTierEnv(rt, ZenEgressTier.direct, '')) {
        await rt.restartChild();
      }
      await rt.ensure();
      return await _waitZenHealthy(rt);
    }
    // exhausted：记录恢复时刻
    final wait = retryAfterSeconds ?? 30 * 60;
    final until = DateTime.now().add(
      Duration(seconds: wait.clamp(60, 12 * 3600)),
    );
    if (_zenExhaustedUntil == null ||
        _zenExhaustedUntil!.isBefore(DateTime.now())) {
      _zenExhaustedIsBudget = false;
      _zenExhaustedUntil = until;
      server?.log(
        'Zen 三级通路全部耗尽（Worker→机场→直连），预计 '
        '${until.hour.toString().padLeft(2, '0')}:'
        '${until.minute.toString().padLeft(2, '0')} 前后恢复；'
        '后续请求将快速失败，恢复由后台探测自动完成',
      );
      _scheduleZenRecoveryProbe(until);
    }
    return false;
  }

  /// 换出口墙钟预算用尽（网关层判定）：本轮所有出口都没能完成请求。
  /// 记下「整池烧穿 + 恢复时刻」，让后续请求**快速失败**而不是每次都
  /// 重跑一遍 6 轮轮换（每轮最坏等 90s 看门狗 → 用户看到的是「一个你好
  /// 两分钟没反应」）。恢复由后台探测在到点后自动解除。
  Future<void> _markZenEgressBudgetExhausted(
    String upstreamId,
    int? retryAfterSeconds,
  ) async {
    // 预算用尽 ≠ 整池烧穿：只是**时间**不够（每轮 40-70s，3 轮就撞到
    // 150s 墙钟），池里几十个出口根本没试完。上游给的 retryAfter 是
    // **某一个出口的额度桶**的恢复点（≈UTC 零点），拿它锁全池 = 因噎废食
    // （实测 2026-11-08：只试了 3 个出口就把网关锁到 01:50，12 小时）。
    // 所以这里固定锁 5 分钟，后台探测每 4 分钟试一个出口，恢复了立刻解除。
    const wait = 5 * 60;
    final until = DateTime.now().add(
      Duration(seconds: wait.clamp(60, 12 * 3600)),
    );
    if (_zenExhaustedUntil != null &&
        _zenExhaustedUntil!.isAfter(DateTime.now())) {
      return; // 已有更晚的恢复点，保留
    }
    _zenExhaustedIsBudget = true;
    _zenExhaustedUntil = until;
    server?.log(
      'Zen 换出口预算用尽：本轮三级通路都没能完成请求（可能是上游过载或'
      '出口全部不可达）。已暂停重试，预计 '
      '${until.hour.toString().padLeft(2, '0')}:'
      '${until.minute.toString().padLeft(2, '0')} 前后自动恢复探测；'
      '期间请求会快速失败（不再每次重跑整轮轮换）',
    );
    _scheduleZenRecoveryProbe(until);
  }

  /// 接入 OpenCode CLI 供应商（TLS 指纹通路）。
  /// 成功返回 null；找不到运行时返回给 UI 展示的原因（UI 据此引导下载）。
  /// 网关日志目录（生产实例）。null = 不落盘。
  String? get _zenLogDir {
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']
        : '${Platform.environment['HOME']}/.config';
    if (base == null || base.isEmpty) return null;
    return '$base/zeroapi/logs';
  }

  Future<String?> addOpenCode() async {
    if (config.upstreams.any((u) => u.id == OpenCode.id)) {
      return 'OpenCode CLI 已在供应商列表中';
    }
    final port = await OpenCode.pickPort();
    final def = OpenCode.seed(port: port, proxyUrl: _zenProxyUrl());
    if (def == null) {
      return '本机未检测到 opencode CLI。可以在供应商页「下载运行时」自动获取'
          '（2.x 约 240MB 解包，来自 npm 官方平台分包），或自行安装'
          ' @opencode/cli 后重启应用。';
    }
    await OpenCode.reconcileProtocol(def);
    addUpstream(def);
    return null;
  }

  /// 用户手动指定了新的 CLI 路径：更新 def.command、按新二进制的线协议
  /// 重配鉴权/端点，再重启 serve 子进程。返回 null=成功；否则为失败原因。
  Future<String?> updateOpenCodeCommand(String exePath) async {
    final rt = _runtimes.where((r) => r.def.id == OpenCode.id).firstOrNull;
    if (rt == null) return 'OpenCode CLI 尚未接入';
    rt.def
      ..command = exePath
      ..env['OPENCODE_API_KEY'] = '';
    await OpenCode.reconcileProtocol(rt.def);
    config.save();
    rt.restartChild();
    unawaited(Future.delayed(const Duration(milliseconds: 500), rt.ensure));
    return null;
  }

  /// 按需下载 opencode CLI 运行时（tarball → %APPDATA%\zeroapi\opencode\bin），
  /// 完成后自动接入供应商。返回 null=成功；否则为失败原因。
  Future<String?> downloadOpenCodeRuntime({
    void Function(int received, int total)? onProgress,
  }) async {
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
      unawaited(_syncCoreAndEgress(pool));
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
      // **UA 必须装成 clash 客户端**：机场按 UA 决定返回格式——clash 系 UA
      // 返回完整 YAML（81 节点），未知 UA 返回 base64 的「剩余流量」假节点
      // （ss://…@127.0.0.1:443#剩余流量：xxx GB，实测 2026-11-07）。这是
      // 订阅接口的标准约定，clash-verge / Clash Meta 等客户端都这么发。
      ..userAgent = 'clash-verge/1.0';
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
    await _syncCoreAndEgress(pool);
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
    unawaited(_syncZenCliEgress());
    notifyListeners();
  }

  /// 设置页的出口代理对所有供应商统一生效（本机回环服务除外——随包号池
  /// 必须直连，否则回环请求会被代理截走）。设置页只负责「用什么代理」；
  /// 哪个供应商走内置代理池由「代理」页的用途分配决定。
  void setGlobalUpstreamProxy({required bool enabled, String proxy = ''}) {
    for (final u in config.upstreams) {
      if (!u.supportsUpstreamEgress) continue;
      u
        ..proxyEnabled = enabled
        ..proxy = proxy;
    }
    config.save();
    // 运行中的 runtime 可能持有旧 config 实例的 def，同步到实际实例
    for (final rt in _runtimes) {
      if (!rt.def.supportsUpstreamEgress) continue;
      rt.def
        ..proxyEnabled = enabled
        ..proxy = proxy;
    }
    unawaited(_syncZenCliEgress());
    notifyListeners();
  }

  /// 是否有供应商开着出口代理（设置页开关的展示状态）
  bool get globalProxyEnabled =>
      config.upstreams.any((u) => u.supportsUpstreamEgress && u.proxyEnabled);

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
    _disposed = true;
    _generation++; // 让在途的后台初始化立刻作废
    ModelsDev.instance.stop();
    _refreshTimer?.cancel();
    _zenRecoveryTimer?.cancel();
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
