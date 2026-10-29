import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'modelsdev.dart';
import 'opencode.dart';
import 'opencode_api.dart';
import 'proxypool.dart';
import 'socksrelay.dart';
import 'zen.dart';

enum UpstreamHealth { unknown, checking, healthy, down }

/// 供应商运行时：健康探测 + 内置(managed)类型的子进程拉起/守护/退避重启
class UpstreamRuntime {
  final UpstreamDef def;
  UpstreamHealth health = UpstreamHealth.unknown;
  List<String> models = [];

  /// 模型能力元数据（上游 /v1/models 条目 + models.dev 目录合并）
  final Map<String, ModelInfo> modelInfo = {};

  /// 上游模型 → 出口区（WorkBuddy 号池的国内/国际双出口用）。多目录探测时
  /// 按 `?realm=` 记录；两区都有的模型以先探到的为准。转发时据此带 X-Realm，
  /// 否则 hub 会按全局开关判成跨区、把国际独占模型（gpt-5.5 等）直接 400 拒掉。
  final Map<String, String> modelRealms = {};

  /// 两区目录都出现的模型（任何一区的账号都能服务）。高并发时网关据此把
  /// 同模型的并行请求分散到不同区（不同账号），避免全部堆在同一个号上撞
  /// 上游单账号并发/频控（表现为很慢 + 一直 429）。
  final Set<String> sharedModels = {};

  /// 号池当前有可用（启用、未过期）账号的区集合，服务层经 /accounts 刷新。
  Set<String> readyRealms = {};

  /// 各区可用账号数：网关据此给「同模型并发」定闸门容量（一账号一并发槽），
  /// 只有一个账号时同模型的并行请求排队而不是一起撞上游 429。
  Map<String, int> readyAccounts = {};
  String? lastError;
  Process? child;

  /// 带管理面的内置供应商（目前是 WorkBuddy）：管理面 /health 的账号池状态
  int? accountTotal;
  int? accountReady;
  Map<String, dynamic>? hostInfo;

  /// 累计请求数/词元/失败数（含历史：启动时由 [ProxyServer.usageRange] 回填）
  int requests = 0, promptTokens = 0, completionTokens = 0, errors = 0;

  /// 记账入口：网关线程每请求一次，累加运行期计数（UI 显示的"请求 N 次"）
  void addUsage(int prompt, int completion, bool isError, {int cached = 0}) {
    requests++;
    promptTokens += prompt;
    completionTokens += completion;
    if (isError) errors++;
  }

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
  /// OpenCode CLI 托管通路（spawn `opencode serve`，绕过 TLS 指纹识别）。
  /// 与旧的「zen 直连」共用 id=zen（模型前缀 zen/xxx 保持不变），
  /// 靠 type 区分：直连是 type='zen'，CLI 通路是 type='managed'。
  bool get isOpenCode => def.id == OpenCode.id && def.type == 'managed';

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
    if (isOpenCode) return _probeOpenCode();
    return _probeCatalog();
  }

  /// 逐条探测模型目录路径并合并清单。多路径（如 WorkBuddy 号池的国内/国际
  /// 两个出口）任一成功即视为供应商可用：一个出口故障不该把整个供应商判死，
  /// 只是另一个出口的模型暂时不可见。
  Future<bool> _probeCatalog() async {
    final base = def.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final merged = <String, Map<String, dynamic>>{}; // id → 条目（先探到的优先）
    final realmOf = <String, String>{}; // id → 首次探到的出口区
    final shared = <String>{}; // 出现在 2 个及以上目录的模型（两区都服务）
    String? firstErr;
    var ok = false;
    for (final p in def.catalogProbes) {
      final path = p.startsWith('/') ? p : '/$p';
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 8);
        final uri = Uri.parse('$base$path');
        final req = await client.getUrl(uri);
        _headers().forEach((k, v) => req.headers.set(k, v));
        final resp = await req.close().timeout(const Duration(seconds: 10));
        final body = await resp.transform(utf8.decoder).join();
        client.close(force: true);
        if (resp.statusCode != 200) {
          firstErr ??= 'HTTP ${resp.statusCode}';
          continue;
        }
        final j = jsonDecode(body) as Map<String, dynamic>;
        final data = (j['data'] as List?) ?? const [];
        // 目录路径上的 ?realm= 参数即这批模型的出口区（号池按区返回清单）
        final realm = uri.queryParameters['realm'] ?? '';
        for (final m in data) {
          if (m is Map<String, dynamic> && m['id'] is String) {
            final id = m['id'] as String;
            merged.putIfAbsent(id, () => m);
            if (realm.isNotEmpty) {
              final prev = realmOf[id];
              if (prev != null && prev != realm) shared.add(id);
              realmOf.putIfAbsent(id, () => realm);
            }
          }
        }
        ok = true;
      } catch (e) {
        firstErr ??= '$e';
      }
    }
    if (!ok) {
      await _probeHostInfo();
      // 号池网关卡在"进程已就绪但还没添加账号"时，/v1/models 返回 503。
      // 这属于待配置而不是故障：保持可用状态，由卡片提示去面板登录。
      if (_noAccounts) {
        models = const [];
        health = UpstreamHealth.healthy;
        lastError = null;
        return true;
      }
      if (_warming) {
        // 预热窗口内（子进程尚未就绪）：保持"启动中"，不记拒绝错误
        health = UpstreamHealth.checking;
        lastError = null;
      } else {
        health = UpstreamHealth.down;
        lastError = firstErr;
      }
      return false;
    }
    // 元数据 = 上游条目自带字段（若有，优先） + models.dev 目录（兜底补充）
    modelInfo.clear();
    for (final e in merged.values) {
      final id = e['id'] as String;
      modelInfo[id] = ModelInfo.fromMaps(
        e,
        ModelsDev.instance.lookup((e['owned_by'] ?? def.id) as String?, id),
      );
    }
    // 只给「单区独占」模型记出口区：两区目录都有的模型（hy3/glm-5.3…）
    // 任意账号都能服务，交给高并发分散逻辑（sharedModels），
    // 独占模型（国际 gpt-5.5/gemini…、国内 deepseek-v4-pro/minimax…）
    // 必须带区，否则 hub 按全局开关判成跨区直接 400。
    modelRealms.clear();
    modelRealms.addAll({
      for (final e in realmOf.entries)
        if (!shared.contains(e.key)) e.key: e.value,
    });
    sharedModels.clear();
    sharedModels.addAll(shared);
    models = merged.keys.toList();
    health = UpstreamHealth.healthy;
    lastError = null;
    _backoffMs = 1000;
    await _probeHostInfo();
    return true;
  }

  bool get _noAccounts => accountTotal != null && (accountReady ?? 0) == 0;

  /// 管理面健康检查：顺带把账号池状态读到 UI 层（WorkBuddy 卡片用）。
  /// 失败静默——主探活已经决定了供应商状态。
  Future<void> _probeHostInfo() async {
    final url = def.healthUrl;
    if (url.isEmpty) return;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(Uri.parse(url));
      _headers().forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close().timeout(const Duration(seconds: 4));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return;
      final j = jsonDecode(body);
      if (j is Map<String, dynamic>) {
        hostInfo = j;
        accountTotal = (j['accounts'] as num?)?.toInt();
        accountReady = (j['accounts_ready'] as num?)?.toInt();
      }
    } catch (_) {
      // 管理面不可达不影响主探活结论
    } finally {
      client.close(force: true);
    }
  }

  /// OpenCode CLI（serve）探活：GET /global/health 判进程就绪；
  /// 模型清单走 /config/providers（serve 无 OpenAI /models 端点，/v1/models
  /// 返回 HTML）。只登记实测可用的免费档，beam-free（上游按国家拒绝）与
  /// jev-1.13-free（上游 500）不展示，避免用户点了才报错。
  Future<bool> _probeOpenCode() async {
    try {
      final base = def.baseUrl.replaceAll(RegExp(r'/+$'), '');
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.parse('$base/global/health'));
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final hbody = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        client.close(force: true);
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final hj = jsonDecode(hbody) as Map<String, dynamic>;
      if (hj['healthy'] != true) {
        client.close(force: true);
        throw const HttpException('health 未就绪');
      }
      final ids = await OpenCodeApi.freeModels(base, client);
      client.close(force: true);
      final usable = ids
          .where((id) => !OpenCode.unavailableFreeModels.containsKey(id))
          .toList();
      models = usable;
      modelInfo.clear();
      for (final id in usable) {
        modelInfo[id] = ModelInfo.fromMaps(
          {'id': id, 'owned_by': 'opencode'},
          ModelsDev.instance.lookup('opencode', id),
        );
      }
      health = UpstreamHealth.healthy;
      lastError = null;
      _backoffMs = 1000;
      return true;
    } catch (e) {
      if (_warming) {
        health = UpstreamHealth.checking;
        lastError = null;
      } else {
        health = UpstreamHealth.down;
        lastError = e.toString();
      }
      return false;
    }
  }

  /// zen：直连 OpenCode Zen inference API，列 free 档模型（无本地进程）。
  /// baseUrl 即 zen 通道入口：默认真直连；用户填自建反代（如 Cloudflare
  /// Worker）时从反代出口 IP 出网，目录与补全都走同一条路。
  Future<bool> _probeZen() async {
    try {
      final base = def.baseUrl.replaceAll(RegExp(r'/+$'), '');
      // 探针与补全走同一条出口：配了出口代理/Worker 时也必须经代理，
      // 否则代理重启窗口期目录探测直连 workers.dev 会被墙，误判"未知模型"。
      // 候选逐个试（池绑定排最前），拿到 200 即认定该节点可用并上报健康度；
      // 连不上的节点记一次失败——绑了坏节点也不会把整个 zen 判死（曾因此
      // 目录永久为空、所有 zen 模型「未知」）。全失败再落直连兜底。
      final cands = await def.egress(SocksRelayHub.instance);
      final tryList = <String?>[
        for (final c in cands) c.directive,
        if (cands.isNotEmpty) null, // 直连兜底：池整体不可用时至少还能探活
      ];
      if (cands.isEmpty) tryList.insert(0, null); // 无出口 = 纯直连
      Object? lastErr;
      Map<String, dynamic>? okJson;
      for (var i = 0; i < tryList.length; i++) {
        final d = tryList[i];
        final cand = i < cands.length ? cands[i] : null;
        HttpClient? client;
        try {
          client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
          if (d != null) client.findProxy = (_) => d;
          final req = await client.getUrl(Uri.parse('$base/models'));
          Zen.headers(def.apiKey).forEach((k, v) => req.headers.set(k, v));
          final resp = await req.close().timeout(const Duration(seconds: 15));
          final body = await resp.transform(utf8.decoder).join();
          if (resp.statusCode != 200) {
            throw HttpException('HTTP ${resp.statusCode}');
          }
          final nid = cand?.nodeId;
          if (nid != null) activePool?.noteEgress(nid, true);
          okJson = jsonDecode(body) as Map<String, dynamic>;
          break;
        } catch (e) {
          final nid = cand?.nodeId;
          if (nid != null) activePool?.noteEgress(nid, false);
          lastErr = e;
        } finally {
          client?.close(force: true);
        }
      }
      final j = okJson;
      if (j == null) throw lastErr ?? const HttpException('zen 所有出口均不可用');
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
          e,
          ModelsDev.instance.lookup('opencode', id),
        );
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
      final sock = await Socket.connect(
        uri.host,
        uri.port,
        timeout: const Duration(milliseconds: 600),
      );
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
    if (DateTime.now().difference(ext) < const Duration(minutes: 10)) {
      return true;
    }
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
      logFile?.writeln(
        '[${DateTime.now().toIso8601String()}] spawn: $cmd ${def.args.join(" ")}',
      );
      // normal 模式：pythonw.exe 是 GUI 子系统进程，不会分配控制台（历史黑窗
      // 来自 taskkill/cmd.exe，已移除，见 stop() 注释）；保留 exitCode 回调
      // 供崩溃退避重启（detachedWithStdio 拿不到 exitCode，不能用）。
      Process.start(
        cmd,
        def.args,
        environment: def.env.isEmpty ? null : def.env,
      ).then((p) {
        child = p;
        lastSpawnAt = DateTime.now();
        onStatusChanged?.call();
        unawaited(_warmup());
        final sink = _logSink();
        p.stdout.listen((d) => sink?.add(d), onDone: () => sink?.flush());
        p.stderr.listen((d) => sink?.add(d), onDone: () => sink?.flush());
        unawaited(
          p.exitCode.then((code) {
            logFile?.writeln(
              '[${DateTime.now().toIso8601String()}] exit code=$code',
            );
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
          }),
        );
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
      _logFileSink ??= File('${dir.path}/upstream-$id.log')
          .openWrite(mode: FileMode.append);
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

  /// 只重启子进程（不改 _stopping）：用于「换了环境变量要重新拉起」的场景
  /// （如 zen CLI 换了出口代理）。stop() 是彻底关闭，_stopping 置位后
  /// ensure() 不再拉起，不能用于重启。
  void restartChild() {
    final c = child;
    if (c != null) {
      if (!c.kill()) Process.killPid(c.pid);
    }
    child = null;
    health = UpstreamHealth.checking;
    lastError = null;
  }

  void stop() {
    _stopping = true;
    _probeTimer?.cancel();
    final c = child;
    if (c != null) {
      // 不能走 `taskkill /PID /T /F`：那要新起一个控制台进程，在无控制台的
      // 桌面应用里表现为闪一下黑窗（用户反复反馈的问题）。TerminateProcess
      // 是系统调用，不产生窗口。vendor 子进程是 pythonw（叶子进程），无需杀树。
      if (!c.kill()) Process.killPid(c.pid);
    }
    child = null;
  }
}
