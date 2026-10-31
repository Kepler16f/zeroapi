import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'anthropic.dart';
import 'config.dart';
import 'modelsdev.dart';
import 'opencode_api.dart';
import 'progate.dart';
import 'proxypool.dart';
import 'socksrelay.dart';
import 'upstream.dart';
import 'zen.dart';

/// 上游流在"尚未向客户端提交响应"前断裂——调用方可透明重试，客户端无感知
class _ZenEarlyReset implements Exception {
  final String why;
  _ZenEarlyReset(this.why);
  @override
  String toString() => 'early-reset: $why';
}

class ModelRoute {
  final String publicName;
  final UpstreamRuntime upstream;
  final String upstreamModel;
  final bool bare;
  ModelRoute(this.publicName, this.upstream, this.upstreamModel, this.bare);
}

/// 单请求上下文：认证通过后经 Zone 注入，深层转发/泵流代码无需改签名即可
/// 读取（密钥标签、接口模式、计时、缓存词元），供统一富日志与记账使用。
class _ReqCtx {
  final String keyLabel;
  final Stopwatch sw = Stopwatch()..start();
  String mode = ''; // chat | anthropic | responses
  bool stream = false;
  String model = '';
  int cached = 0; // 上游 usage.prompt_tokens_details.cached_tokens
  _ReqCtx(this.keyLabel);
}

final _ctxKey = Object();

class ModelRegistry {
  final Map<String, ModelRoute> _routes = {};

  void rebuild(List<UpstreamRuntime> upstreams) {
    _routes.clear();
    final bareTaken = <String>{};
    for (final u in upstreams) {
      if (!u.def.enabled) continue;
      final prefix = u.def.callPrefix;
      for (final m in u.models) {
        // 规范调用名：<来源前缀>/<模型名>（zen/…、WorkBuddy/…）
        final call = '$prefix/$m';
        final route = ModelRoute(call, u, m, false);
        _routes[call] = route;
        // 兼容：前缀与 id 不同时，<id>/<模型名> 也可调用
        if (prefix != u.id) _routes['${u.id}/$m'] = route;
        // 裸名仅作兼容入口：供应商注册顺序先到先得；重名时后来者用全名访问
        if (bareTaken.add(m)) {
          _routes[m] = ModelRoute(m, u, m, true);
        }
      }
    }
  }

  ModelRoute? resolve(String name) => _routes[name];
  int get size => _routes.length;
  List<ModelRoute> get all => _routes.values.toList();
}

/// 一组用量聚合：总量 + 按模型 + 趋势桶（trend 的键由写入方决定：
/// 当天视图为小时 "00"-"23"，跨天汇总为日期 "MM-dd"）
class UsageStats {
  int requests = 0, errors = 0, promptTokens = 0, completionTokens = 0;

  /// 上游 usage.prompt_tokens_details.cached_tokens 累计（缓存命中率分子）
  int cachedTokens = 0;
  final Map<String, int> byModel = {};

  /// 按模型的词元总量（输入+输出）：用量图按此排序/占比，次数仅并列展示
  final Map<String, int> byModelTokens = {};

  /// 按天词元总量（MM-dd → tokens）：周/月/总视图折线的纵轴
  final Map<String, int> byDayTokens = {};
  final Map<String, int> trend = {};

  void add(
    String model,
    int prompt,
    int completion,
    bool isError, {
    String? trendKey,
    int cached = 0,
  }) {
    requests++;
    promptTokens += prompt;
    completionTokens += completion;
    cachedTokens += cached;
    if (isError) errors++;
    byModel.update(model, (v) => v + 1, ifAbsent: () => 1);
    final tokens = prompt + completion;
    byModelTokens.update(model, (v) => v + tokens, ifAbsent: () => tokens);
    if (trendKey != null) {
      trend.update(trendKey, (v) => v + 1, ifAbsent: () => 1);
      byDayTokens.update(trendKey, (v) => v + tokens, ifAbsent: () => tokens);
    }
  }

  void merge(UsageStats o, {String? trendKey}) {
    requests += o.requests;
    errors += o.errors;
    promptTokens += o.promptTokens;
    completionTokens += o.completionTokens;
    cachedTokens += o.cachedTokens;
    o.byModel.forEach(
      (k, v) => byModel.update(k, (x) => x + v, ifAbsent: () => v),
    );
    o.byModelTokens.forEach(
      (k, v) => byModelTokens.update(k, (x) => x + v, ifAbsent: () => v),
    );
    if (trendKey != null) {
      trend.update(trendKey, (x) => x + o.requests, ifAbsent: () => o.requests);
      byDayTokens.update(
        trendKey,
        (x) => x + o.promptTokens + o.completionTokens,
        ifAbsent: () => o.promptTokens + o.completionTokens,
      );
    } else {
      o.trend.forEach(
        (k, v) => trend.update(k, (x) => x + v, ifAbsent: () => v),
      );
      o.byDayTokens.forEach(
        (k, v) => byDayTokens.update(k, (x) => x + v, ifAbsent: () => v),
      );
    }
  }

  Map<String, dynamic> toJson() => {
    'requests': requests,
    'errors': errors,
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'byModel': byModel,
    'byModelTokens': byModelTokens,
  };
}

class ProxyServer {
  final String host;
  final int port;

  /// 网关密钥池：命中任意一把即放行（不与设备绑定）
  final List<GatewayKey> keys;

  /// 允许局域网接入：true 时绑定 0.0.0.0（Windows 首次需防火墙放行）
  final bool allowLan;
  final ModelRegistry registry;
  final bool anthropicEnabled;

  /// 双出口共有模型的优先区：''=跟随号池全局开关（不带 X-Realm）、'cn'、'intl'。
  /// 独占模型恒走自己的出口区，不受此影响。设置页/账号页切换即时生效。
  String workbuddyPreferredRealm = '';
  UsageStats usageToday = UsageStats();
  HttpServer? _server;

  /// 双出口共有模型的高并发分散状态：
  /// - [_realmSticky] 会话指纹 → 出口区：同一会话固定一个区以保住上游前缀
  ///   缓存；不同会话尽量落到不同区（不同账号池），同一模型的并行请求才
  ///   不会被上游单账号并发限制拖慢、打成 429。
  /// - [_realmInflight] 出口区 → 进行中请求数：分配时优先空闲区。
  final Map<String, String> _realmSticky = {};
  final Map<String, int> _realmInflight = {'cn': 0, 'intl': 0};

  /// 出口区 × 模型 → 上游 429 冷却截止时间。号池的 429 是「该区账号都在
  /// 这个模型上被上游限流」，Retry-After 就是最早解冻时间；冷却期内新请求
  /// 优先去另一区，而不是排在同一区的队列里等冷却。
  final Map<String, DateTime> _realmCooling = {};

  /// zen 单模型并发闸门 + 每出口 IP 的 429 冷却。
  ///
  /// 免费层按「出口 IP × 模型」限流（实测并发同模型 5 路时最慢 48.7s、
  /// 且伴随 429）。飞鸟云池是 22 节点 round-robin，天然可分散到不同 IP：
  ///  - [_gate] 同模型并发上限按「候选出口数」取（1 个 IP = 1 个槽），
  ///    排队而不是一起撞同一个 IP 的限流；
  ///  - [_zenIpCooling] 出口 IP × 模型 → 冷却截止：撞过 429 的 IP 在
  ///    Retry-After 内不再承接该模型，新请求优先挑干净 IP。
  final _ModelGate _gate = _ModelGate();
  final Map<String, DateTime> _zenIpCooling = {};

  /// 当前正在处理的 zen 模型名：_zenClientFor 用它挑没被 429 冷却的出口。
  String? _zenGateModel;

  String _zenCoolKey(String ip, String model) => '$ip|$model';

  void _zenIpCool(String ip, String model, Duration wait) {
    if (wait <= Duration.zero || ip.isEmpty) return;
    _zenIpCooling[_zenCoolKey(ip, model)] = DateTime.now().add(wait);
    while (_zenIpCooling.length > 400) {
      final now = DateTime.now();
      _zenIpCooling.removeWhere((_, until) => !until.isAfter(now));
      if (_zenIpCooling.length > 400) {
        _zenIpCooling.remove(_zenIpCooling.keys.first);
      }
    }
  }

  /// 共享上游 HttpClient：连接池复用（TLS keep-alive），高并发下避免
  /// 每请求重建客户端造成的握手风暴与 socket 耗尽；只在 stop() 时关闭。
  HttpClient? _up;
  HttpClient get upClient => _up ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 60)
    ..maxConnectionsPerHost = 64;
  final _logLines = <String>[]; // 环形日志，UI 展示
  static const _maxLog = 200;
  String _usageDay = DateTime.now().toIso8601String().substring(0, 10);

  /// 未知模型时的自救：由 GatewayService 注入"重探全部上游 + 重建路由"。
  /// 上游模型目录是动态的（如 opencode 随 models.dev 上新/重启后变化），
  /// 本地路由表可能滞后；重探一次仍找不到才 404，与上游目录严格同步。
  Future<void> Function()? onUnknownModel;

  /// 首次检测到 IP 级滥用封锁时回调一次（解封后重置）。UI 据此提示用户
  /// 启用出口代理或一键部署 Worker——Worker 模式默认不启用，只在被封时问。
  void Function(String upstreamId)? onIpBan;
  /// zen/CLI 通路命中「免费额度耗尽」时回调：上层换一个出口 IP 并重启
  /// CLI 子进程（CLI 进程级绑定出口，换 IP 必须换进程）。
  void Function(String upstreamId)? onQuotaExhausted;
  bool _ipBanSignaled = false;
  DateTime _lastUnknownRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  /// 模型规范名：`zen/big-pickle` 与 `big-pickle` 指向同一路由时统一为裸名，
  /// 使记账与所有时间视图（今日/本周/本月/所有）不出现带前缀的重复条目；
  /// 跨供应商重名（裸名被别家占用）仍保留 供应商id/模型名 消歧。
  String _canonicalModel(String name) {
    final r = registry.resolve(name);
    if (r == null) return name;
    final bare = registry.resolve(r.upstreamModel);
    if (bare != null &&
        bare.upstream.id == r.upstream.id &&
        bare.upstreamModel == r.upstreamModel) {
      return r.upstreamModel;
    }
    return r.publicName;
  }

  /// 统一记账：内存当日汇总（含小时趋势）+ jsonl 落盘（跨天自动换文件）
  void _account(
    String model,
    String upstream,
    int p,
    int c,
    bool err, {
    int cached = 0,
  }) {
    model = _canonicalModel(model);
    final now = DateTime.now();
    final day = now.toIso8601String().substring(0, 10);
    if (day != _usageDay) {
      _usageDay = day;
      usageToday = UsageStats();
    }
    usageToday.add(
      model,
      p,
      c,
      err,
      trendKey: now.hour.toString().padLeft(2, '0'),
      cached: cached,
    );
    // 同步追加落盘：IOSink 的底层 open 是异步的，目录在 openWrite 后被删
    // 时异常会从 done 逃逸成 unhandled async error（try/catch 拦不住）；
    // 同步写把错误收敛在当场，也免掉 flush/close 生命周期管理。
    try {
      final dir = Directory(_usageDirPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File('${dir.path}/usage-$day.jsonl').writeAsStringSync(
        '${jsonEncode({'ts': now.toIso8601String(), 'model': model, 'upstream': upstream, 'prompt': p, 'completion': c, 'error': err, if (cached > 0) 'cached': cached})}\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  /// 从 usage map 提取缓存命中词元（OpenAI: prompt_tokens_details.cached_tokens；
  /// Responses: input_tokens_details.cached_tokens）
  static int _cachedOf(Map? us) {
    if (us == null) return 0;
    final d =
        (us['prompt_tokens_details'] ?? us['input_tokens_details']) as Map?;
    return ((d?['cached_tokens'] ?? 0) as num).toInt();
  }

  /// 富日志行尾：密钥标签 · 模式 · 词元(含缓存) · 耗时
  String _tail(_ReqCtx? ctx, int p, int c) {
    if (ctx == null) return '';
    final parts = <String>[
      'key=${ctx.keyLabel}',
      ctx.mode + (ctx.stream ? '·流' : ''),
    ];
    if (p > 0 || c > 0) {
      final cache = ctx.cached > 0 && p > 0
          ? '/缓${(ctx.cached / p * 100).toStringAsFixed(0)}%'
          : '';
      parts.add('$p+$c词元$cache');
    }
    parts.add('${(ctx.sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
    return '  · ${parts.join(' · ')}';
  }

  /// 从磁盘 jsonl 聚合指定天数范围的用量（含按天趋势）。
  /// days=1 今日（小时趋势）；days=7/30 按天趋势；days=null 全部。
  Future<UsageStats> usageRange({int? days}) async {
    final out = UsageStats();
    try {
      final dir = Directory(_usageDirPath);
      if (!dir.existsSync()) return out;
      final cutoff = days == null
          ? null
          : DateTime.now().subtract(Duration(days: days - 1));
      final files =
          dir
              .listSync()
              .whereType<File>()
              // 严格 .jsonl 结尾：备份/临时文件（*.jsonl.bak-*）不得混入重复计入
              .where(
                (f) => f.path.contains('usage-') && f.path.endsWith('.jsonl'),
              )
              .toList()
            // File 不可 Comparable：必须显式按路径比较，否则多文件时 sort 抛
            // 异常被外层 catch 吞掉 → 整个聚合静默返回 0（2026-10-19 线上教训）
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        final m = RegExp(r'usage-(\d{4}-\d{2}-\d{2})\.jsonl$')
            .firstMatch(f.path);
        if (m == null) continue;
        final fileDay = DateTime.tryParse(m.group(1)!);
        if (fileDay == null) continue;
        // 当天文件用内存态（含未落盘的 flush 延迟）；历史文件读磁盘。
        // 跨天视图把当天聚合成一个日期桶，今日视图保留小时桶。
        if (m.group(1) == _usageDay) {
          out.merge(
            usageToday,
            trendKey: days == 1 ? null : _usageDay.substring(5),
          );
          continue;
        }
        if (cutoff != null && fileDay.isBefore(cutoff)) continue;
        final lines = await f.readAsLines();
        for (final l in lines) {
          try {
            final j = jsonDecode(l) as Map<String, dynamic>;
            out.add(
              _canonicalModel((j['model'] ?? '?') as String),
              (j['prompt'] ?? 0) as int,
              (j['completion'] ?? 0) as int,
              (j['error'] ?? false) as bool,
              trendKey: m.group(1)!.substring(5),
            ); // MM-dd
          } catch (_) {}
        }
      }
    } catch (_) {}
    return out;
  }

  void _log(String s) {
    _logLines.add('[${DateTime.now().toIso8601String().substring(11, 19)}] $s');
    if (_logLines.length > _maxLog) _logLines.removeAt(0);
  }

  ProxyServer(
    this.host,
    this.port,
    String apiKey,
    this.registry, {
    this.anthropicEnabled = true,
    this.allowLan = false,
    List<GatewayKey>? keys,
    this.usageDir,
    this.onKeyUsed,
  }) : keys = keys ?? [GatewayKey('默认', apiKey)];

  /// 用量 jsonl 目录覆盖（测试注入隔离目录；生产走 %APPDATA%/zeroapi/logs）
  final String? usageDir;

  /// 密钥命中回调（service 侧更新 lastUsed 并限频落盘）
  final void Function(GatewayKey key)? onKeyUsed;

  String get _usageDirPath =>
      usageDir ??
      (Platform.isWindows
          ? '${Platform.environment['APPDATA']}/zeroapi/logs'
          : '${Platform.environment['HOME']}/.config/zeroapi/logs');

  List<String> get logs => List.unmodifiable(_logLines);

  /// 实际监听端口（port 传 0 时由系统分配，测试用）
  int get boundPort => _server?.port ?? port;

  Future<void> start() async {
    _restoreTodayUsage();
    // 局域网模式绑定 0.0.0.0 让同网段设备可接入；否则仅本机回环
    final server = await HttpServer.bind(
      allowLan ? InternetAddress.anyIPv4 : host,
      port,
    );
    _server = server;
    server.listen(_handle, onError: (e) => _log('server error: $e'));
    _log(
      allowLan
          ? 'zeroapi 监听 http://$host:$port/v1（局域网 0.0.0.0:$port，首次需允许防火墙）'
          : 'zeroapi 监听 http://$host:$port/v1',
    );
  }

  /// 重启后从当日 jsonl 回填内存用量，使今日统计跨重启连续
  /// （今日文件只回填一次；之后新请求仍照常走 _account 增量写）
  void _restoreTodayUsage() {
    try {
      final f = File('$_usageDirPath/usage-$_usageDay.jsonl');
      if (!f.existsSync()) return;
      for (final line in f.readAsLinesSync()) {
        try {
          final j = jsonDecode(line) as Map<String, dynamic>;
          usageToday.add(
            _canonicalModel((j['model'] ?? '?') as String),
            (j['prompt'] ?? 0) as int,
            (j['completion'] ?? 0) as int,
            (j['error'] ?? false) as bool,
            trendKey: DateTime.parse(j['ts'] as String).hour
                .toString()
                .padLeft(2, '0'),
          );
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _up?.close(force: true);
    _up = null;
    _zenUp?.close(force: true);
    _zenUp = null;
    _zenProxySig = '';
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      req.response.headers
        ..set('Access-Control-Allow-Origin', '*')
        ..set(
          'Access-Control-Allow-Headers',
          'Authorization, Content-Type, X-Api-Key, Anthropic-Version',
        )
        ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      if (req.method == 'OPTIONS') {
        req.response.statusCode = 204;
        await req.response.close();
        return;
      }

      final path = req.uri.path;

      if (path == '/healthz') {
        return _json(req, {'ok': true, 'models': registry.size});
      }
      if (path == '/admin/status') {
        return _json(req, {
          'uptime': DateTime.now().toIso8601String(),
          'models': registry.size,
          'usageToday': usageToday.toJson(),
        });
      }

      final auth = req.headers.value('authorization') ?? '';
      final xkey = req.headers.value('x-api-key') ?? '';
      // 密钥池：Authorization: Bearer <key> 或 x-api-key: <key> 命中任意一把即
      // 放行（Anthropic 系客户端默认带 anthropic-version + x-api-key）
      final provided = auth.startsWith('Bearer ')
          ? auth.substring(7).trim()
          : xkey.trim();
      final matched = provided.isEmpty
          ? const <GatewayKey>[]
          : keys.where((k) => k.value == provided).toList();
      if (matched.isEmpty) {
        return _json(req, {
          'error': {'message': '无效的网关 API key'},
        }, 401);
      }
      // 请求上下文经 Zone 注入：深层转发/泵流无需改签名即可读密钥标签、
      // 计时、模式，产出统一富日志
      await runZoned(
        () => _dispatch(req, path),
        zoneValues: {_ctxKey: _ReqCtx(matched.first.label)},
      );
      onKeyUsed?.call(matched.first);
    } catch (e) {
      _log('handler 异常: $e');
      try {
        _json(req, {
          'error': {'message': '$e'},
        }, 500);
      } catch (_) {}
    }
  }

  /// 鉴权通过后的路由分发（运行在带 _ReqCtx 的 Zone 中）
  Future<void> _dispatch(HttpRequest req, String path) async {
    if (path == '/v1/models' && req.method == 'GET') {
      // 去重：同一 (供应商,模型) 只暴露一条，优先暴露带来源前缀的规范调用名
      // （zen/…、WorkBuddy/…）；裸名仅作为兼容入口保留，不在清单里重复出现。
      final byModel = <String, ModelRoute>{};
      for (final r in registry.all) {
        final key = '${r.upstream.id}|${r.upstreamModel}';
        final cur = byModel[key];
        if (cur == null || (!r.bare && cur.bare)) byModel[key] = r;
      }
      return _json(req, {
        'object': 'list',
        'data': byModel.values.map((r) {
          final info =
              r.upstream.modelInfo[r.upstreamModel] ??
              ModelInfo.fromMaps(
                {},
                ModelsDev.instance.lookup(r.upstream.def.id, r.upstreamModel),
              );
          return {
            'id': r.publicName,
            'object': 'model',
            'created': 0,
            // 客户端（CC Switch 等）常按 owned_by 分组展示；用调用前缀
            // 作为归属，让 zen / WorkBuddy 天然分成两组。
            'owned_by': r.upstream.def.callPrefix,
            'zeroapi': {
              'bare': r.bare,
              'group': r.upstream.def.displayName,
              'provider': r.upstream.def.callPrefix,
              'upstream_model': r.upstreamModel,
              'healthy': r.upstream.health == UpstreamHealth.healthy,
              if (r.upstream.modelRealms[r.upstreamModel] != null)
                'realm': r.upstream.modelRealms[r.upstreamModel],
              if (ProGate.instance.isPro(r.upstream.def.id, r.upstreamModel))
                'pro_only': true,
              ...info.toJson(),
            },
          };
        }).toList(),
      });
    }

    if (path == '/v1/chat/completions' && req.method == 'POST') {
      _ctx?.mode = 'chat';
      return _chat(req);
    }
    if (path == '/v1/responses' && req.method == 'POST') {
      _ctx?.mode = 'responses';
      return _responses(req);
    }
    if (path == '/v1/messages' && req.method == 'POST') {
      if (!anthropicEnabled) {
        return _json(req, {
          'type': 'error',
          'error': {
            'type': 'not_found_error',
            'message': 'Anthropic 适配已在设置中关闭',
          },
        }, 404);
      }
      _ctx?.mode = 'anthropic';
      return _messages(req);
    }
    _json(req, {
      'error': {'message': '不支持 ${req.method} $path'},
    }, 404);
  }

  /// 当前请求上下文（Zone 注入；非请求路径如测试直调时为 null）
  _ReqCtx? get _ctx => Zone.current[_ctxKey] as _ReqCtx?;

  /// 读取 JSON 请求体；非法 JSON 时写回 400 并返回 null
  Future<Map<String, dynamic>?> _readJson(HttpRequest req) async {
    try {
      return jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
    } catch (_) {
      _json(req, {
        'error': {'message': '请求体不是合法 JSON'},
      }, 400);
      return null;
    }
  }

  /// 解析模型路由并确保供应商可用；失败时写回 404/503 并返回 null。
  /// [forResponses]：调用来自 /v1/responses——Zen 直连上游实测不支持该端点，需拒绝。
  Future<ModelRoute?> _resolveRoute(
    Map<String, dynamic> body,
    HttpRequest req, {
    bool anthropicErrors = false,
    bool forResponses = false,
  }) async {
    final publicName = (body['model'] ?? '') as String;
    var route = registry.resolve(publicName);
    void fail(
      String msg,
      String openaiType,
      String anthropicType,
      int status,
    ) => anthropicErrors
        ? _json(req, {
            'type': 'error',
            'error': {'message': msg, 'type': anthropicType},
          }, status)
        : _json(req, {
            'error': {'message': msg, 'type': openaiType},
          }, status);
    if (route == null) {
      final refresh = onUnknownModel;
      // 5 秒去抖：并发 404 只触发一次全量重探
      if (refresh != null &&
          DateTime.now().difference(_lastUnknownRefresh) >=
              const Duration(seconds: 5)) {
        _lastUnknownRefresh = DateTime.now();
        _log('未知模型 $publicName：重探上游目录…');
        try {
          await refresh().timeout(
            const Duration(seconds: 30),
            onTimeout: () {},
          );
        } catch (_) {}
        route = registry.resolve(publicName);
        if (route != null) {
          _log('未知模型 $publicName：重探后已收录（${route.upstream.id}）');
        }
      }
      if (route == null) {
        fail(
          '未知模型 $publicName，见 GET /v1/models',
          'unknown_model',
          'not_found_error',
          404,
        );
        return null;
      }
    }
    final u = route.upstream;
    if (u.health != UpstreamHealth.healthy) {
      final ok = await u.probe();
      if (!ok) {
        fail(
          '供应商 ${u.id} 不可用: ${u.lastError ?? "未知"}',
          'upstream_down',
          'overloaded_error',
          503,
        );
        return null;
      }
    }
    // Zen 免费通道只支持 chat 系列端点（实测 /responses 无指纹/带 tools 均 403）
    if ((u.isZen || u.isOpenCode) && forResponses) {
      fail(
        'Zen 免费通道仅支持 chat 系列端点（/v1/chat/completions、/v1/messages）',
        'unsupported_endpoint',
        'invalid_request_error',
        404,
      );
      return null;
    }
    return route;
  }

  Future<void> _chat(HttpRequest req) async {
    final body = await _readJson(req);
    if (body == null) return;
    final publicName = (body['model'] ?? '') as String;
    final route = await _resolveRoute(body, req);
    if (route == null) return;
    await _forward(
      req,
      route,
      publicName,
      'chat/completions',
      body,
      isStream: body['stream'] == true,
    );
  }

  /// Responses API（/v1/responses）透传：聚合层只负责路由与记账，
  /// 请求体原样转发到供应商的 /responses 端点。
  Future<void> _responses(HttpRequest req) async {
    final body = await _readJson(req);
    if (body == null) return;
    final publicName = (body['model'] ?? '') as String;
    final route = await _resolveRoute(body, req, forResponses: true);
    if (route == null) return;
    await _forward(
      req,
      route,
      publicName,
      'responses',
      body,
      isStream: body['stream'] == true,
      responsesApi: true,
    );
  }

  /// Anthropic Messages API（/v1/messages）适配：请求体翻译成 OpenAI 格式
  /// 走上游 chat/completions，响应/SSE 再翻译回 Anthropic 事件格式。
  Future<void> _messages(HttpRequest req) async {
    final aBody = await _readJson(req);
    if (aBody == null) return;
    final publicName = (aBody['model'] ?? '') as String;
    final route = await _resolveRoute(aBody, req, anthropicErrors: true);
    if (route == null) return;
    final isStream = aBody['stream'] == true;
    final oai = AnthropicAdapter.toOpenAIRequest(aBody);
    if (isStream) oai['stream_options'] = {'include_usage': true};
    await _forward(
      req,
      route,
      publicName,
      'chat/completions',
      oai,
      isStream: isStream,
      anthropic: true,
    );
  }

  /// 会话指纹：取首两条非 system 消息（截断）做散列。不用整段对话——
  /// 后续轮次增长会让同一个会话算出不同指纹，粘性就失效了。
  String _conversationKey(Map<String, dynamic> body) {
    final msgs = body['messages'];
    if (msgs is List) {
      final b = StringBuffer();
      var n = 0;
      for (final m in msgs) {
        if (m is! Map) continue;
        final role = '${m['role'] ?? ''}';
        if (role == 'system') continue;
        var c = m['content'];
        if (c is List) {
          c = c.map((e) => e is Map ? (e['text'] ?? '') : e).join();
        }
        final s = c is String ? c : '$c';
        b
          ..write(role)
          ..write('|')
          ..write(s.length > 1600 ? s.substring(0, 1600) : s)
          ..write('\n');
        if (++n >= 2) break;
      }
      if (b.isNotEmpty) {
        final raw = b.toString();
        return '${raw.hashCode.toRadixString(16)}-${raw.length}';
      }
    }
    // Responses API 的 input 可能是字符串或消息数组
    final raw = '${body['input'] ?? ''}';
    if (raw.isEmpty) return '';
    final s = raw.length > 3200 ? raw.substring(0, 3200) : raw;
    return '${s.hashCode.toRadixString(16)}-${s.length}';
  }

  /// 共有模型选出口区（cn/intl）。返回 (realm, counted)，counted=true 表示
  /// 已把该区在途计数 +1，调用方须在响应结束时 -1。规则按「账号容量」算，
  /// 不把偏好区钉死——单账号硬钉偏好区正是两个会话同模型并发撞 429 的根因：
  ///  - 两区都不知道有没有账号（面板不可达）→ 偏好区或空（交给 hub 全局开关）；
  ///  - 只有一区有可用账号 → 明确指到该区，别赌全局开关；
  ///  - 两区都有 → 同会话粘住原区（保住上游前缀缓存），该区满了才溢出；
  ///    新会话先挑还有空闲容量的区，偏好区只用来在同空闲时定先后。
  ({String? realm, bool counted}) _pickSharedRealm(
    UpstreamRuntime u,
    String model,
    Map<String, dynamic> body,
  ) {
    final pref = workbuddyPreferredRealm;
    final realms = [
      for (final r in const ['cn', 'intl'])
        if (u.readyRealms.contains(r)) r,
    ];
    if (realms.isEmpty) {
      return (realm: pref.isEmpty ? null : pref, counted: false);
    }
    if (realms.length == 1) return (realm: realms.single, counted: false);
    int load(String r) => _realmInflight[r] ?? 0;
    // 一账号一并发槽（与号池自己的扩缩容口径一致）
    int cap(String r) {
      final n = u.readyAccounts[r] ?? 0;
      return n > 0 ? n : 1;
    }

    // 刚被上游 429 的区在冷却期内不承接新请求；两区都在冷却时去最早
    // 解冻的一区（重试等待最短）。冷却只看「区 × 模型」，别的模型不受影响。
    final healthy = [
      for (final r in realms)
        if (!_isCooling(r, model)) r,
    ];
    final usable = healthy.isEmpty ? realms : healthy;
    if (healthy.isEmpty) {
      usable.sort(
        (a, b) => _coolingLeft(a, model).compareTo(_coolingLeft(b, model)),
      );
    }

    final key = _conversationKey(body);
    final cur = key.isEmpty ? null : _realmSticky[key];
    String chosen;
    var keepSticky = false;
    if (healthy.isEmpty) {
      // 两区都在冷却：去最早解冻的一区，不保留原来的粘性
      chosen = usable.first;
    } else if (cur != null && usable.contains(cur)) {
      // 粘性区还没溢出就继续用它（容许 1 个超额，配合闸门排队）；
      // 真的堆起来了才溢出到另一区，且不改粘性——缓存归属保持稳定。
      // 只剩这一个健康区时就排队等它，不要再去找冷却中的区。
      final curUsable = usable.length == 1 || load(cur) <= cap(cur);
      chosen = curUsable ? cur : usable.firstWhere((r) => r != cur);
      keepSticky = true;
    } else {
      final free = usable.where((r) => load(r) < cap(r)).toList();
      if (free.isEmpty) {
        chosen = load(usable.first) <= load(usable.last)
            ? usable.first
            : usable.last;
      } else if (free.length == 1) {
        chosen = free.single;
      } else if (pref.isNotEmpty && free.contains(pref)) {
        chosen = pref;
      } else {
        // 两区同样空闲：按会话指纹散列，避免新会话全挤到同一区
        chosen = key.hashCode.isEven ? free.first : free.last;
      }
    }
    if (key.isNotEmpty && !keepSticky) {
      _realmSticky[key] = chosen;
      while (_realmSticky.length > 400) {
        _realmSticky.remove(_realmSticky.keys.first);
      }
    }
    _realmInflight[chosen] = load(chosen) + 1;
    return (realm: chosen, counted: true);
  }

  void _releaseRealm(String realm) {
    final n = _realmInflight[realm] ?? 0;
    _realmInflight[realm] = n > 0 ? n - 1 : 0;
  }

  String _realmCoolingKey(String realm, String model) => '$realm|$model';

  bool _isCooling(String realm, String model) {
    final key = _realmCoolingKey(realm, model);
    final until = _realmCooling[key];
    if (until == null) return false;
    if (!until.isAfter(DateTime.now())) {
      _realmCooling.remove(key);
      return false;
    }
    return true;
  }

  Duration _coolingLeft(String realm, String model) {
    final until = _realmCooling[_realmCoolingKey(realm, model)];
    if (until == null) return Duration.zero;
    final left = until.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  void _markRealmCooling(String realm, String model, Duration wait) {
    if (wait <= Duration.zero) return;
    _realmCooling[_realmCoolingKey(realm, model)] = DateTime.now().add(wait);
    while (_realmCooling.length > 200) {
      final now = DateTime.now();
      _realmCooling.removeWhere((_, until) => !until.isAfter(now));
      if (_realmCooling.length > 200) {
        _realmCooling.remove(_realmCooling.keys.first);
      }
    }
  }

  Future<void> _forward(
    HttpRequest req,
    ModelRoute route,
    String publicName,
    String endpoint,
    Map<String, dynamic> body, {
    required bool isStream,
    bool responsesApi = false,
    bool anthropic = false,
  }) async {
    final u = route.upstream;
    // 请求上下文（测试直调 _forward 时可能为 null，全部判空使用）
    final ctx = _ctx
      ?..model = publicName
      ..stream = isStream;
    // 剥离非 OpenAI 标准的客户端扩展字段：ZCode 等会带 thinking/enable_thinking
    // 之类，Zen 严格 JSON 解码报 unknown field → 400。清单见 Zen.strictDropFields，
    // 清单外字段由 _zenTurn 的 400 自愈机制（解析报错→剥离→重试）兜底。
    for (final f in Zen.strictDropFields) {
      body.remove(f);
    }
    body['model'] = route.upstreamModel;
    if (u.isZen) {
      await _forwardZen(
        req,
        route,
        publicName,
        body,
        clientWantsStream: isStream,
        anthropic: anthropic,
      );
      return;
    }
    if (u.isOpenCode) {
      await _forwardOpenCode(
        req,
        route,
        publicName,
        body,
        clientWantsStream: isStream,
        anthropic: anthropic,
      );
      return;
    }
    final tag = responsesApi
        ? ' [responses]'
        : anthropic
        ? ' [anthropic]'
        : '';
    void failJson(Map<String, dynamic> err, int status) => anthropic
        ? _json(req, {'type': 'error', 'error': err}, status)
        : _json(req, {'error': err}, status);

    String? gateKey;
    var gateHeld = false;
    try {
      // 建连（含出口候选轮换 + 健康度上报）：拿到响应头才算连接成功，
      // 之后的错误属于流/响应阶段，不再换出口
      // WorkBuddy 号池双出口：独占模型必须带 X-Realm（否则 hub 按全局开关
      // 判成跨区直接 400，gpt-5.5 等国际模型在国内开关下必挂）；两区共有的
      // 模型按用户偏好走（未设置则跟随号池全局开关，不强加头）。
      String? realm;
      var realmCounted = false;
      final isShared =
          u.modelRealms[route.upstreamModel] == null &&
          u.sharedModels.contains(route.upstreamModel);
      void resolveRealm() {
        if (u.modelRealms.isNotEmpty ||
            u.sharedModels.contains(route.upstreamModel)) {
          final exclusive = u.modelRealms[route.upstreamModel];
          if (exclusive != null) {
            realm = exclusive;
            realmCounted = false;
          } else if (isShared) {
            final pick = _pickSharedRealm(u, route.upstreamModel, body);
            realm = pick.realm;
            realmCounted = pick.counted;
          } else {
            realm = workbuddyPreferredRealm;
            realmCounted = false;
          }
        } else {
          realm = null;
          realmCounted = false;
        }
      }

      resolveRealm();
      // 响应（流式含整个生成过程）结束才释放该区在途名额；重试换区时
      // 先 releaseTracked() 再重新登记，done 回调释放的始终是当前区。
      var tracked = false;
      void releaseTracked() {
        if (!tracked) return;
        tracked = false;
        final r = realm;
        if (r != null && r.isNotEmpty) _releaseRealm(r);
      }

      if (realmCounted) {
        tracked = true;
        unawaited(
          req.response.done
              .catchError((Object _) => null)
              .whenComplete(releaseTracked),
        );
      }
      final payload = utf8.encode(jsonEncode(body));
      var extraHeaders = (realm ?? '').isNotEmpty
          ? <String, String>{'X-Realm': realm!}
          : const <String, String>{};
      // 单账号防 429 的并发闸门：同一 供应商×出口区×模型 的并发上限取该区
      // 可用账号数（号池自己的扩缩容口径也是「一账号一并发槽」）。只有一个
      // 账号时两个会话同模型请求会排队，而不是一起撞上游限流打成 429。
      if (u.isManaged) {
        gateKey = '${u.id}|${realm ?? '-'}|${route.upstreamModel}';
        gateHeld = await _gate.acquire(
          gateKey,
          _gateLimit(u, realm),
          const Duration(seconds: 120),
        );
      }
      final firstByteTimeout = isStream
          ? const Duration(hours: 2)
          : const Duration(minutes: 70);
      var (uresp, client) = await _openRemoteWithEgress(
        u.def,
        endpoint,
        payload,
        firstByteTimeout: firstByteTimeout,
        extraHeaders: extraHeaders,
      );

      // 上游 429：响应头已拿到、还没向客户端提交任何字节，退避重试是安全的。
      // 号池的 429 有两种来源：全局队列打满（换号/换区可能立刻成功），以及
      // 该区账号在这个模型上被上游限流（Retry-After 指向解冻时间）。策略：
      //  1) 先换到没冷却的另一区立刻重试（共有模型）；
      //  2) 两区都在冷却就按 Retry-After 等（上限 75s；更久的多是当日额度，
      //     直接如实返回 429，不把连接挂着）；
      //  3) 退避期间让出模型闸门，避免一个在等冷却的请求把同模型的其它
      //     请求一起堵在队列里（实测会把第二个请求拖到 80s+）。
      // 退避循环里 break 时，错误体已经从上一个 uresp 读出（Stream 只能
      // listen 一次）；下面的非 200 分支要复用它，不能再读一遍，否则
      // 「Bad state: Stream has already been listened to」。
      String? drainedErr;
      for (var retry = 0; uresp.statusCode == 429 && retry < 2; retry++) {
        final wait = _retryDelay(uresp, retry);
        drainedErr = await uresp.transform(utf8.decoder).join();
        client.close(force: true);
        if (wait == null) {
          // 多为号池账号当日额度（Retry-After 指向零点）：挂连接干等几小时
          // 没有意义。先把这个区×模型冷却 15 分钟（新会话自动绕开）；若是
          // 共有模型且另一区还健康，换过去立即重试；没有退路才如实返回 429。
          final spent = realm;
          if (u.isManaged && spent != null && spent.isNotEmpty) {
            _markRealmCooling(
              spent,
              route.upstreamModel,
              const Duration(minutes: 15),
            );
          }
          var switchNow = false;
          if (isShared && retry < 1) {
            releaseTracked();
            resolveRealm();
            tracked = realmCounted;
            extraHeaders = (realm ?? '').isNotEmpty
                ? <String, String>{'X-Realm': realm!}
                : const <String, String>{};
            switchNow = (realm ?? '') != (spent ?? '');
          }
          if (!switchNow) {
            _log('$publicName ⏸ 上游 429 冷却时间过长，如实返回 429');
            break;
          }
          _log(
            '$publicName ⟳ 上游 429（$spent 疑似当日额度），换区 $realm 重试'
            '（${retry + 1}/2）',
          );
          if (gateHeld) {
            gateHeld = false;
            _gate.release(gateKey!);
            gateKey = null;
          }
          if (u.isManaged) {
            gateKey = '${u.id}|${realm ?? '-'}|${route.upstreamModel}';
            gateHeld = await _gate.acquire(
              gateKey,
              _gateLimit(u, realm),
              const Duration(seconds: 120),
            );
          }
          (uresp, client) = await _openRemoteWithEgress(
            u.def,
            endpoint,
            payload,
            firstByteTimeout: firstByteTimeout,
            extraHeaders: extraHeaders,
          );
          drainedErr = null;
          continue;
        }
        final oldRealm = realm;
        if (u.isManaged && oldRealm != null && oldRealm.isNotEmpty) {
          _markRealmCooling(oldRealm, route.upstreamModel, wait);
        }
        if (gateHeld) {
          gateHeld = false;
          _gate.release(gateKey!);
          gateKey = null;
        }
        var effectiveWait = wait;
        if (isShared) {
          releaseTracked();
          resolveRealm();
          tracked = realmCounted;
          extraHeaders = (realm ?? '').isNotEmpty
              ? <String, String>{'X-Realm': realm!}
              : const <String, String>{};
          final r = realm;
          if (r != null && r.isNotEmpty) {
            if (_isCooling(r, route.upstreamModel)) {
              // 换到的区也在冷却：等它解冻，不再傻等原来的区
              final left =
                  _coolingLeft(r, route.upstreamModel) +
                  const Duration(milliseconds: 300);
              if (left < effectiveWait) effectiveWait = left;
            } else if (r != oldRealm) {
              // 另一个区健康：立刻换过去，不陪冷却中的区一起等
              effectiveWait = Duration(
                milliseconds: 120 + Random().nextInt(160),
              );
            }
          }
        }
        _log(
          '$publicName ⟳ 上游 429'
          '${realm != oldRealm ? '，换区 ${realm ?? '-'}' : ''}'
          '，${effectiveWait.inMilliseconds}ms 后重试（${retry + 1}/2）',
        );
        await Future<void>.delayed(effectiveWait);
        if (u.isManaged) {
          gateKey = '${u.id}|${realm ?? '-'}|${route.upstreamModel}';
          gateHeld = await _gate.acquire(
            gateKey,
            _gateLimit(u, realm),
            const Duration(seconds: 120),
          );
        }
        (uresp, client) = await _openRemoteWithEgress(
          u.def,
          endpoint,
          payload,
          firstByteTimeout: firstByteTimeout,
          extraHeaders: extraHeaders,
        );
        // 新响应没读过：错误体必须重新从它读，上面那份作废
        drainedErr = null;
      }

      if (uresp.statusCode != 200) {
        final err = drainedErr ?? await uresp.transform(utf8.decoder).join();
        client.close(force: true);
        // 上游按账号类型拒绝（11158 / not allowed for user type）：
        // 标成「仅 Pro 可用」，模型清单与调用名旁给出提示；号池加了
        // 付费账号后任一请求成功即自动解除。
        if (ProGate.isUserTypeRejection(err)) {
          ProGate.instance.mark(u.def.id, route.upstreamModel);
          _log('$publicName ⚠ 上游判定该模型需 Pro 账号，已标注「仅 Pro」');
        }
        _log('$publicName ← 供应商 ${u.id} HTTP ${uresp.statusCode}');
        _account(publicName, u.id, 0, 0, true);
        final parsed = err.isNotEmpty ? _safeJson(err) : null;
        final errMsg =
            (parsed?['error']?['message'] ??
                    parsed?['message'] ??
                    '供应商 ${u.id} HTTP ${uresp.statusCode}')
                as String;
        final errType = anthropic
            ? 'upstream_error'
            : (parsed?['error']?['type'] ?? 'upstream_error') as String;
        return failJson({'message': errMsg, 'type': errType}, uresp.statusCode);
      }
      // 成功即解除「仅 Pro」标记（可能刚加了付费账号）
      if (ProGate.instance.isPro(u.def.id, route.upstreamModel)) {
        ProGate.instance.clear(u.def.id, route.upstreamModel);
      }

      if (isStream && anthropic) {
        // Anthropic 模式：OpenAI chunk 逐条翻译成 Claude SSE 事件
        // charset 必须显式 utf-8：SSE 事件含模型原文（CJK/em-dash），
        // 缺省 latin1 编码会让 write() 抛 'Contains invalid characters'
        req.response.headers
          ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
          ..set('Cache-Control', 'no-cache')
          ..set('x-zeroapi-upstream', u.id);
        req.response.statusCode = 200;
        int prompt = 0, completion = 0;
        final aStream = AnthropicAdapter.streamTransformer(route.upstreamModel);
        var buf = '';
        await for (final chunk in uresp) {
          buf += utf8.decode(chunk, allowMalformed: true);
          int idx;
          while ((idx = buf.indexOf('\n')) >= 0) {
            final line = buf.substring(0, idx).trim();
            buf = buf.substring(idx + 1);
            if (!line.startsWith('data:')) continue;
            final data = line.substring(5).trim();
            List<String> evs;
            if (data == '[DONE]') {
              evs = aStream.finish();
            } else if (data.isEmpty) {
              continue;
            } else {
              evs = aStream.feed(data);
              try {
                final us = (jsonDecode(data) as Map)['usage'] as Map?;
                if (us != null) {
                  prompt = (us['prompt_tokens'] ?? prompt) as int;
                  completion = (us['completion_tokens'] ?? completion) as int;
                  ctx?.cached = _cachedOf(us);
                }
              } catch (_) {}
            }
            for (final ev in evs) {
              req.response.add(utf8.encode(ev));
            }
            await req.response.flush();
          }
        }
        await req.response.close();
        _account(
          publicName,
          u.id,
          prompt,
          completion,
          false,
          cached: ctx?.cached ?? 0,
        );
        _log(
          '$publicName ✓ stream ${u.id}$tag${_tail(ctx, prompt, completion)}',
        );
      } else if (isStream) {
        req.response.headers
          ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
          ..set('Cache-Control', 'no-cache')
          ..set('x-zeroapi-upstream', u.id);
        req.response.statusCode = 200;
        int prompt = 0, completion = 0;
        var buf = '';
        await for (final chunk in uresp) {
          final s = utf8.decode(chunk, allowMalformed: true);
          buf += s;
          int idx;
          while ((idx = buf.indexOf('\n')) >= 0) {
            final line = buf.substring(0, idx).trim();
            buf = buf.substring(idx + 1);
            if (line.startsWith('data:')) {
              final data = line.substring(5).trim();
              if (data.isNotEmpty && data != '[DONE]') {
                try {
                  final j = jsonDecode(data) as Map<String, dynamic>;
                  if (responsesApi) {
                    // Responses API 的 usage 在最终 response.completed 事件里
                    if (j['type'] == 'response.completed') {
                      final us =
                          (j['response'] as Map<String, dynamic>?)?['usage']
                              as Map<String, dynamic>?;
                      prompt = (us?['input_tokens'] ?? 0) as int;
                      completion = (us?['output_tokens'] ?? 0) as int;
                    }
                  } else {
                    final us = j['usage'] as Map<String, dynamic>?;
                    if (us != null) {
                      prompt += (us['prompt_tokens'] ?? 0) as int;
                      completion += (us['completion_tokens'] ?? 0) as int;
                      ctx?.cached += _cachedOf(us);
                    }
                  }
                } catch (_) {}
              }
            }
          }
          req.response.add(chunk);
          await req.response.flush();
        }
        await req.response.close();
        _account(
          publicName,
          u.id,
          prompt,
          completion,
          false,
          cached: ctx?.cached ?? 0,
        );
        _log(
          '$publicName ✓ stream ${u.id}$tag${_tail(ctx, prompt, completion)}',
        );
      } else {
        final data = await uresp.transform(utf8.decoder).join();
        int prompt = 0, completion = 0;
        try {
          final j = jsonDecode(data) as Map<String, dynamic>;
          final us = j['usage'] as Map<String, dynamic>?;
          if (responsesApi) {
            prompt = (us?['input_tokens'] ?? 0) as int;
            completion = (us?['output_tokens'] ?? 0) as int;
          } else {
            prompt = (us?['prompt_tokens'] ?? 0) as int;
            completion = (us?['completion_tokens'] ?? 0) as int;
          }
          ctx?.cached = _cachedOf(us);
        } catch (_) {}
        _account(
          publicName,
          u.id,
          prompt,
          completion,
          false,
          cached: ctx?.cached ?? 0,
        );
        _log('$publicName ✓ ${u.id}$tag${_tail(ctx, prompt, completion)}');
        req.response.headers
          ..contentType = ContentType.json
          ..set('x-zeroapi-upstream', u.id);
        req.response.statusCode = 200;
        if (anthropic) {
          req.response.write(
            jsonEncode(
              AnthropicAdapter.toAnthropicResponse(
                jsonDecode(data) as Map<String, dynamic>,
              ),
            ),
          );
        } else {
          req.response.write(data);
        }
        await req.response.close();
      }
      client.close(force: true);
    } catch (e) {
      if (!u.warming) {
        u.health = UpstreamHealth.down;
        u.lastError = e.toString();
      }
      _account(publicName, u.id, 0, 0, true);
      _log('$publicName ✗ ${u.id}: $e');
      try {
        failJson({
          'message': '供应商 ${u.id} 请求失败: $e',
          'type': anthropic ? 'api_error' : 'upstream_error',
        }, 502);
      } catch (_) {}
    } finally {
      if (gateHeld) _gate.release(gateKey!);
    }
  }

  /// 单模型闸门容量：该出口区当前可用的账号数（拿不到账号信息按 1 算）。
  int _gateLimit(UpstreamRuntime u, String? realm) {
    if (u.readyAccounts.isEmpty) return 1;
    if (realm != null && realm.isNotEmpty) {
      final n = u.readyAccounts[realm] ?? 0;
      return n > 0 ? n : 1;
    }
    var total = 0;
    for (final n in u.readyAccounts.values) {
      total += n;
    }
    return total > 0 ? total : 1;
  }

  /// 429 重试等待：优先上游的 Retry-After，否则短指数退避 + 抖动。
  /// 429 的退避时长。号池的 Retry-After 是「该区最早解冻时间」（实测
  /// 60s），必须等够才有意义；超过 75s 的多半是当日额度/零点恢复，返回
  /// null 表示不值得挂住连接重试。
  Duration? _retryDelay(HttpClientResponse resp, int retry) {
    final h = resp.headers.value('retry-after');
    if (h != null) {
      final s = int.tryParse(h.trim());
      if (s != null) {
        if (s > 75) return null;
        return Duration(seconds: max(1, s));
      }
    }
    return Duration(milliseconds: 700 * (retry + 1) + Random().nextInt(300));
  }

  /// 连接阶段错误（还没拿到响应头）：换出口重试才有意义。
  bool _isConnectError(Object e) =>
      e is SocketException || e is TimeoutException || e is HttpException;

  /// 建连（含出口候选轮换 + 健康度上报）：
  /// - 池候选连接失败 → noteEgress(false) 累计冷却，换下一个候选立即重试；
  /// - 拿到响应头 → noteEgress(true)（节点可达），返回响应与存活的 client，
  ///   由调用方读完响应后关闭。
  /// 全部候选耗尽（或无候选直连失败）时抛最后一个错误。
  Future<(HttpClientResponse, HttpClient)> _openRemoteWithEgress(
    UpstreamDef def,
    String endpoint,
    List<int> payload, {
    required Duration firstByteTimeout,
    Map<String, String> extraHeaders = const {},
  }) async {
    final candidates = await def.egress(SocksRelayHub.instance);
    final url = Uri.parse(
      '${def.baseUrl.replaceAll(RegExp(r'/+$'), '')}/$endpoint',
    );
    final tries = candidates.isEmpty ? 1 : min(candidates.length, 4);
    Object? lastErr;
    for (var attempt = 0; attempt < tries; attempt++) {
      final cand = candidates.isEmpty
          ? null
          : candidates[_remoteProxyTick++ % candidates.length];
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..findProxy = (_) => cand?.directive ?? 'DIRECT';
      try {
        final ureq = await client.openUrl('POST', url);
        ureq.headers.set('Content-Type', 'application/json');
        if (def.apiKey.isNotEmpty) {
          ureq.headers.set('Authorization', 'Bearer ${def.apiKey}');
        }
        extraHeaders.forEach((k, v) => ureq.headers.set(k, v));
        ureq.add(payload);
        final uresp = await ureq.close().timeout(firstByteTimeout);
        if (cand?.nodeId != null) {
          activePool?.noteEgress(cand!.nodeId!, true);
        }
        return (uresp, client);
      } catch (e) {
        client.close(force: true);
        if (cand?.nodeId != null) {
          activePool?.noteEgress(cand!.nodeId!, false);
        }
        lastErr = e;
        if (!_isConnectError(e) || attempt == tries - 1) rethrow;
        _log(
          '⟳ ${def.id} 出口 ${cand?.directive ?? 'DIRECT'} 连接失败，'
          '换下一个候选重试（${attempt + 2}/$tries）',
        );
      }
    }
    throw lastErr ?? StateError('egress exhausted');
  }

  /// Zen 直连转发：复刻免费层客户端指纹、强制 stream:true + 诱饵工具，
  /// 回传时剔除模型对诱饵工具的调用。
  ///
  /// 高并发要点：
  /// - 共享连接池（upClient，TLS keep-alive 复用），不再每请求 new HttpClient
  /// - 先探流再向客户端提交 200：首字节前发现断流/错误可透明重试，
  ///   客户端不会看到半截流
  /// - 429/5xx 打开单模型熔断（冷却窗口），冷却期内同模型请求快速失败并
  ///   如实报错（不转投其他模型），尊重 Retry-After
  /// - 指数退避 + 抖动重试，仅未提交时进行
  /// OpenCode CLI 通路转发：把 OpenAI/Anthropic 请求翻译成 serve 的
  /// session + message 协议，流式时把 SSE 增量转成 OpenAI chunk。
  ///
  /// 与 _forwardZen 的差别：上游不是 OpenAI 兼容端点，而是原生会话协议；
  /// 没有 token 计数（opencode 不上报 usage），记账记 0。
  Future<void> _forwardOpenCode(HttpRequest req, ModelRoute route,
      String publicName, Map<String, dynamic> body,
      {required bool clientWantsStream, bool anthropic = false}) async {
    final u = route.upstream;
    void failJson(Map<String, dynamic> err, int status) => anthropic
        ? _json(req, {'type': 'error', 'error': err}, status)
        : _json(req, {'error': err}, status);

    if (u.health != UpstreamHealth.healthy) {
      // serve 还没起来：managed 生命周期会拉它，这里如实告知稍后重试
      return failJson({
        'message': 'OpenCode CLI 正在启动，请稍后重试',
        'type': anthropic ? 'api_error' : 'overloaded_error',
      }, 503);
    }

    final messages = (body['messages'] as List?) ?? const [];
    final api = OpenCodeApi(u.def.baseUrl);
    final id = 'chatcmpl-${DateTime.now().millisecondsSinceEpoch}';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final model = route.upstreamModel;
    var prompt = 0, completion = 0;

    // 与 _forwardZen 同一原则：**收到上游第一个增量之前不向客户端提交 200**。
    // CLI 额度耗尽时会在 ~1s 内报错——若此时已提交 200，错误只能走流内
    // error 帧，客户端（ZCode）解析不了就显示 reason=unknown；未提交时
    // 则能以干净的 429 JSON 返回，客户端按限流语义自动重试。
    var committed = false;
    try {
      if (clientWantsStream) {
        final pieces = api.chat(
            model: model,
            messages: messages.cast<Map<String, dynamic>>().toList());
        final it = StreamIterator(pieces);
        String? first;
        try {
          if (await it.moveNext()) first = it.current;
        } catch (e) {
          // 首增量前失败：未提交，按未提交路径走干净的 429/502
          prompt = api.lastUsage.input;
          completion = api.lastUsage.output;
          rethrow;
        }
        req.response.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        req.response.headers.set('x-zeroapi-upstream', u.id);
        req.response.statusCode = 200;
        committed = true;
        // 首帧：role
        req.response.add(utf8.encode('data: ${jsonEncode({
              'id': id,
              'object': 'chat.completion.chunk',
              'created': created,
              'model': model,
              'choices': [
                {
                  'index': 0,
                  'delta': {'role': 'assistant'}
                }
              ]
            })}\n\n'));
        if (first != null) {
          completion += first.length;
          req.response.add(utf8.encode('data: ${jsonEncode({
                'id': id,
                'object': 'chat.completion.chunk',
                'created': created,
                'model': model,
                'choices': [
                  {
                    'index': 0,
                    'delta': {'content': first}
                  }
                ]
              })}\n\n'));
        }
        while (await it.moveNext()) {
          final piece = it.current;
          completion += piece.length;
          req.response.add(utf8.encode('data: ${jsonEncode({
                'id': id,
                'object': 'chat.completion.chunk',
                'created': created,
                'model': model,
                'choices': [
                  {
                    'index': 0,
                    'delta': {'content': piece}
                  }
                ]
              })}\n\n'));
          await req.response.flush();
        }
        // 流结束 = 同步响应已回来：换上 serve 给的真实 token 数
        prompt = api.lastUsage.input;
        completion = api.lastUsage.output;
        req.response.add(utf8.encode('data: ${jsonEncode({
              'id': id,
              'object': 'chat.completion.chunk',
              'created': created,
              'model': model,
              'choices': [
                {'index': 0, 'delta': const {}, 'finish_reason': 'stop'}
              ],
              'usage': {
                'prompt_tokens': prompt,
                'completion_tokens': completion,
                'total_tokens': prompt + completion
              }
            })}\n\n'));
        req.response.add(utf8.encode('data: [DONE]\n\n'));
        await req.response.close();
      } else {
        final text = StringBuffer();
        await for (final piece in api.chat(
            model: model,
            messages: messages.cast<Map<String, dynamic>>().toList())) {
          text.write(piece);
          completion += piece.length;
        }
        // 流结束 = 同步响应已回来：换上 serve 给的真实 token 数
        prompt = api.lastUsage.input;
        completion = api.lastUsage.output;
        final out = {
          'id': id,
          'object': 'chat.completion',
          'created': created,
          'model': model,
          'choices': [
            {
              'index': 0,
              'message': {'role': 'assistant', 'content': text.toString()},
              'finish_reason': 'stop'
            }
          ],
          'usage': {
            'prompt_tokens': prompt,
            'completion_tokens': completion,
            'total_tokens': prompt + completion
          }
        };
        req.response.headers.contentType = ContentType.json;
        req.response.headers.set('x-zeroapi-upstream', u.id);
        req.response.statusCode = 200;
        req.response.write(jsonEncode(anthropic
            ? AnthropicAdapter.toAnthropicResponse(out)
            : out));
        await req.response.close();
      }
      // serve 在同步响应里给真实 token 数（字符数只是流式期间的近似值）
      prompt = api.lastUsage.input;
      completion = api.lastUsage.output;
      _account(publicName, u.id, prompt, completion, false);
      _log('$publicName ✓ ${u.id}${_tail(_ctx, prompt, completion)}');
    } catch (e) {
      _account(publicName, u.id, 0, 0, true);
      _log('$publicName ✗ ${u.id}: $e');
      if (committed) {
        // 已提交 200：只能补一个 error 帧收尾，不能再写 JSON 错误体
        try {
          req.response.add(utf8.encode('data: ${jsonEncode({
                'error': {
                  'message': e.toString(),
                  'type': 'upstream_error',
                }
              })}\n\n'));
          req.response.add(utf8.encode('data: [DONE]\n\n'));
          await req.response.close();
        } catch (_) {}
        return;
      }
      // 上游额度耗尽 → 429 rate_limit（客户端会退避重试）；
      // 其余上游错误 → 502。凭证/地域类不映射 4xx，避免客户端误判认证失败。
      if (e is OpenCodeUpstreamError) {
        if (e.isQuotaExhausted) {
          // 额度按「最终到达 opencode.ai 的出口 IP × 天」计：这个出口烧穿了，
          // 换节点（换 IP）才有救。CLI 进程绑定了出口，得重启它才换 IP。
          onQuotaExhausted?.call(u.id);
          return failJson({
            'message': 'OpenCode 免费额度已用完（上游原文：${e.message}）。'
                '额度按出口 IP 每天 UTC 零点重置：可稍后再试、换出口，'
                '或订阅 OpenCode Go。',
            'type': anthropic ? 'rate_limit_error' : 'rate_limit_exceeded',
            'code': 'free_quota_exhausted',
          }, 429);
        }
        return failJson({
          'message': 'OpenCode 上游错误：${e.message}',
          'type': anthropic ? 'api_error' : 'upstream_error',
        }, 502);
      }
      failJson({
        'message': 'OpenCode CLI 请求失败: $e',
        'type': anthropic ? 'api_error' : 'upstream_error',
      }, 502);
    } finally {
      api.close();
    }
  }

  Future<void> _forwardZen(
    HttpRequest req,
    ModelRoute route,
    String publicName,
    Map<String, dynamic> body, {
    required bool clientWantsStream,
    bool anthropic = false,
  }) async {
    final u = route.upstream;
    void failJson(Map<String, dynamic> err, int status) => anthropic
        ? _json(req, {'type': 'error', 'error': err}, status)
        : _json(req, {'error': err}, status);

    // IP 级滥用封锁静默窗口：彻底不碰上游，直到窗口结束再放一个请求探测
    final ipBan = _zenIpBanUntil;
    if (ipBan != null && ipBan.isAfter(DateTime.now())) {
      _account(publicName, u.id, 0, 0, true);
      return failJson({
        'message':
            'OpenCode 检测到本机 IP 滥用流量并临时封锁免费通道（多为短时风控，'
            '继续请求会延长封锁）。静默至 ${_fmtClock(ipBan)}，届时自动恢复。',
        'type': anthropic ? 'rate_limit_error' : 'rate_limited',
        'code': 'ip_abuse_backoff',
      }, 429);
    }
    // 熔断打开：该端点冷却中 → 快速失败并如实报错。绝不静默转投其他模型：
    // 用户指定的模型必须原样执行，换模型出答案等于伪造结果
    final target = route.upstreamModel;
    if (_breaker.isOpen(target)) {
      _account(publicName, u.id, 0, 0, true);
      return failJson({
        'message': '模型 $target 正在退避冷却（上游限流），请稍后重试或改用其他免费模型',
        'type': anthropic ? 'rate_limit_error' : 'rate_limited',
        'code': 'model_backoff',
      }, 429);
    }
    // 同模型并发闸门：免费层按「出口 IP × 模型」限流，并发上限取可用出口
    // 候选数（1 个 IP = 1 个槽）。多路并发时排队分批走不同 IP，而不是
    // 全部同时挤同一个 IP 把它打到 429（实测 5 路同模型全走一个 IP 会
    // 429 + 最慢 48.7s；换 IP 分散后全部 200）。
    final prevGateModel = _zenGateModel;
    _zenGateModel = target;
    var gateHeld = false;
    try {
      final limit = _zenGateLimit();
      if (limit > 1) {
        gateHeld = await _gate.acquire(
          'zen|$target',
          limit,
          const Duration(seconds: 120),
        );
        if (!gateHeld) {
          // 等不到名额也照样发（闸门只是优化，不能把请求无限期挂着）
          _log('$publicName ⚠ zen 同模型并发已满，直接放行');
        }
      }
      await _zenTurn(
        req,
        route,
        publicName,
        body,
        clientWantsStream: clientWantsStream,
        anthropic: anthropic,
        attempt: 0,
      );
    } finally {
      if (gateHeld) _gate.release('zen|$target');
      _zenGateModel = prevGateModel;
    }
  }

  /// zen 同模型并发上限：可用出口候选数（每个 IP 一个并发槽）。直连
  /// （无候选）算 1。上限再截到 8，避免节点池极大时把免费层打爆。
  int _zenGateLimit() {
    final n = _zenEgress.isEmpty ? 1 : _zenEgress.length;
    return n < 1 ? 1 : (n > 8 ? 8 : n);
  }

  final ModelBreaker _breaker = ModelBreaker();

  /// 上游 IP 级滥用封锁（403 abusive traffic）后的全局静默窗口：
  /// 期间暂停一切 zen 请求。单模型熔断不够——换任何模型都会再撞一次风控，
  /// 继续撞只会延长封锁；彻底沉默才给 IP 解封留机会。
  /// 窗口指数递增（5→10→20→40→60m）：持续封锁时降低探测频率。
  DateTime? _zenIpBanUntil;
  int _zenBanStreak = 0;

  /// zen 出口代理客户端：配置了 proxy 池才独立建（findProxy 指向当前代理），
  /// 否则复用共享 upClient 直连。轮换代理时按新 findProxy 重建。
  HttpClient? _zenUp;
  int _zenProxyIdx = 0;
  String _zenProxySig = '';

  /// 当前出口候选与来源节点（连接失败上报健康度、风控轮换用）
  List<EgressCandidate> _zenEgress = const [];
  String? _zenCurrentNode;

  /// 返回本次 zen 请求使用的 HttpClient，以及「是否归本请求临时持有」——
  /// Worker 模式下每请求独立建一条 TLS 连接（= CF 新出口 IP，见下），请求
  /// 结束后必须由本调用优雅 close；共享客户端/直连则传 false（不关）。
  Future<(HttpClient, bool)> _zenClientFor(UpstreamDef def) async {
    _zenEgress = await def.egress(SocksRelayHub.instance);
    final viaWorker = def.baseUrl.contains('workers.dev');
    final cand = _zenEgress.isEmpty
        ? null
        // 优先挑一个当前没在该模型上被 429 冷却的出口（同模型并发时把请求
        // 分散到不同 IP，而不是全挤在同一个被限流的 IP 上排队）
        :
        _zenPickEgress(_zenGateModel ?? '');
    final fp = cand?.directive ?? 'DIRECT';
    final sig = '$fp@${def.baseUrl}';
    _zenCurrentNode = cand?.nodeId;
    if (viaWorker) {
      // 经 workers.dev：每条新 TLS 连接都会被 Cloudflare 分到新的落地机房 /
      // 出口 IP（2026-10-22 实测：同一路径连开 12 条新连接全 200）。免费额度
      // 按出口 IP × 天计，「一请求一连接」等于把配额自动均摊到整池出口；复用
      // keep-alive 反而会把会话钉死在一个 IP 上，它一烧穿就每次都撞 429。
      // 有代理池时这条连接再叠加「经哪个节点」的维度，双保险。
      final c = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..idleTimeout = const Duration(seconds: 60)
        ..findProxy = (_) => fp;
      if (_zenProxySig.isNotEmpty && _zenProxySig != sig) {
        _zenIpBanUntil = null;
        _zenBanStreak = 0;
      }
      _zenProxySig = sig;
      return (c, true);
    }
    if (cand == null) {
      // 直连（开关关闭或清空地址）：释放代理客户端，复用共享连接池。
      // 非 force：正在流式传输的旧请求（可能属于别的会话）要能走完
      _zenUp?.close();
      _zenUp = null;
      _zenProxySig = '';
      return (upClient, false);
    }
    if (_zenUp != null && _zenProxySig == sig) return (_zenUp!, false);
    // 出口实际变化（换代理/换池/换入口）：被封的静默窗口是针对旧出口的，
    // 立即解除——换节点或切 Worker 后就能马上重试，不必干等
    if (_zenProxySig.isNotEmpty && _zenProxySig != sig) {
      _zenIpBanUntil = null;
      _zenBanStreak = 0;
    }
    // 换出口：旧共享客户端优雅关闭（force 会打断别的会话正在流式传输的请求）
    final old = _zenUp;
    old?.close();
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 60)
      ..maxConnectionsPerHost = 64
      ..findProxy = (_) => fp;
    _zenUp = c;
    _zenProxySig = sig;
    return (c, false);
  }

  int _remoteProxyTick = 0;

  /// 连接阶段失败：上报节点健康度（累计到冷却阈值后 poolCandidatesFor 直接
  /// 跳过它）并推进游标，让下一次尝试换下一个候选。直连/手写地址无节点可报。
  void _zenEgressConnectFailed() {
    final node = _zenCurrentNode;
    if (node != null) activePool?.noteEgress(node, false);
    if (_zenEgress.length > 1) {
      _zenProxyIdx = (_zenProxyIdx + 1) % _zenEgress.length;
    }
  }

  /// 连接阶段成功：清掉该节点的历史失败计数（请求高频，noteEgress 内部
  /// 只在状态真变化时才广播）。
  void _zenEgressConnectOk() {
    final node = _zenCurrentNode;
    if (node != null) activePool?.noteEgress(node, true);
  }

  /// 命中 IP 风控时切到下一个出口候选；候选 ≤1 无法轮换返回 false。
  bool _rotateZenProxy(UpstreamDef def) {
    if (_zenEgress.length <= 1) return false;
    _zenProxyIdx = (_zenProxyIdx + 1) % _zenEgress.length;
    _log('⟳ zen 出口代理轮换 → 第 ${_zenProxyIdx + 1}/${_zenEgress.length} 个');
    return true;
  }

  /// 挑一个当前没在该模型上被 429 冷却的出口候选。全部在冷却时返回最接近
  /// 解冻的那个。候选只有一个时原样返回（没得选）。
  EgressCandidate _zenPickEgress(String model) {
    final list = _zenEgress;
    if (list.length <= 1) {
      return list.isEmpty ? const EgressCandidate('') : list.first;
    }
    final now = DateTime.now();
    EgressCandidate? best;
    var bestLeft = const Duration(days: 1);
    for (var i = 0; i < list.length; i++) {
      final c = list[(_zenProxyIdx + i) % list.length];
      final id = c.nodeId ?? c.directive;
      // 直连模式下今天额度烧穿的节点不再选（UTC 零点翻篇）
      if (c.nodeId != null &&
          activePool != null &&
          activePool!.isQuotaSpent(c.nodeId!)) {
        continue;
      }
      final until = _zenIpCooling[_zenCoolKey(id, model)];
      if (until == null || !until.isAfter(now)) return c;
      final left = until.difference(now);
      if (left < bestLeft) {
        bestLeft = left;
        best = c;
      }
    }
    return best ?? list[_zenProxyIdx % list.length];
  }

  /// 额度/地理失败后挑下一个出口：先推进游标再选（跳过今天拉黑/冷却的节点）。
  ///  - 经 Worker：新连接本身就换 CF 落地机房，顺带挪到下一个节点，让
  ///    「本机→CF」的连接路径也参与轮换（不同国家出口落到不同 CF 池，额度
  ///    互相独立）；
  ///  - 直连：换节点就是换出口 IP；全部拉黑时清掉当天标记重头来——额度标记
  ///    是启发式的，宁可多等一轮也不永久封死，且判定基于上游 QUOTA 文案。
  EgressCandidate _zenNextRotatableEgress(String model) {
    if (_zenEgress.isEmpty) {
      // 无池（直连单 IP 或 Worker 单一路径）：只剩「新建 TLS 连接」一招，
      // 调用方已处理，候选不变
      return const EgressCandidate('');
    }
    final pool = activePool;
    final spentAll =
        pool != null &&
        _zenEgress.every(
          (c) => c.nodeId != null && pool.isQuotaSpent(c.nodeId!),
        );
    if (spentAll) {
      _log('⟳ zen 全部出口今天都报额度耗尽，清掉当天标记重头轮换');
      // clearQuotaSpent 内部 notify → 落盘由 _onPoolChanged 负责
      for (final c in _zenEgress) {
        if (c.nodeId != null) pool.clearQuotaSpent(c.nodeId!);
      }
    }
    _zenProxyIdx = (_zenProxyIdx + 1) % _zenEgress.length;
    return _zenPickEgress(model);
  }

  /// 把游标移到指定候选，下次 _zenClientFor 用它（并重建客户端）。
  void _zenUseEgress(EgressCandidate c) {
    final idx = _zenEgress.indexOf(c);
    if (idx >= 0) _zenProxyIdx = idx;
  }

  /// 单次 zen 请求尝试：发送→探流→提交→泵流；可重试错误在提交前发生。
  Future<void> _zenTurn(
    HttpRequest req,
    ModelRoute route,
    String publicName,
    Map<String, dynamic> origBody, {
    required bool clientWantsStream,
    required bool anthropic,
    required int attempt,
  }) async {
    final u = route.upstream;
    final injected = <String>{};
    final sent = Map<String, dynamic>.from(origBody)
      ..['model'] = route.upstreamModel
      ..['stream'] = true
      ..['stream_options'] = {'include_usage': true}
      ..['tools'] = Zen.ensureFreeTools(origBody['tools'], injected);
    // 上游工具名 ≤64 字符（ZCode 的 MCP 工具会超）：截断发送，响应回映
    final nameMap = Zen.shortenToolNames(sent);

    void failJson(Map<String, dynamic> err, int status) => anthropic
        ? _json(req, {'type': 'error', 'error': err}, status)
        : _json(req, {'error': err}, status);

    const maxAttempts = 5;
    final rnd = Random();
    HttpClientResponse? uresp;
    int? errStatus;
    String? errBody;
    Duration? retryAfter;
    HttpClient? zclient;
    var transient = false;
    try {
      final (c, t) = await _zenClientFor(u.def);
      zclient = c;
      transient = t;
      // 临时客户端（Worker 一请求一连接）：由 finally 里非 force 的 close()
      // 负责——拿到响应头后连接不再复用，进行中的响应流照常读完；下一条
      // 请求新建 TLS 连接（= CF 新出口 IP）。
      final ureq = await zclient.openUrl(
        'POST',
        Uri.parse(
          '${u.def.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions',
        ),
      );
      Zen.headers(u.def.apiKey).forEach((k, v) => ureq.headers.set(k, v));
      ureq.headers.set('Content-Type', 'application/json');
      ureq.add(utf8.encode(jsonEncode(sent)));
      final r = await ureq.close().timeout(
        clientWantsStream
            ? const Duration(hours: 2)
            : const Duration(minutes: 70),
      );
      // 拿到响应头 = 连接阶段走通（哪怕状态码是 403/429）：节点可达
      _zenEgressConnectOk();
      if (r.statusCode == 200) {
        uresp = r;
      } else {
        errStatus = r.statusCode;
        final ra = r.headers.value('retry-after');
        retryAfter = int.tryParse(ra ?? '') != null
            ? Duration(seconds: int.parse(ra!))
            : null;
        errBody = await r.transform(utf8.decoder).join();
      }
    } catch (e) {
      // 连接阶段失败（典型：节点挂了/QUIC 超时）：记一次失败并换候选重试
      _zenEgressConnectFailed();
      errBody = e.toString();
    }
    // Worker 临时客户端：非 force close 表示「不再复用」，进行中的响应流
    // 照常读完再释放——下一条请求因此新建 TLS 连接（= CF 新出口 IP）。
    if (transient) zclient?.close();

    Future<void> retryOrFail(String why) async {
      _breaker.onFailure(route.upstreamModel, retryAfter: retryAfter);
      if (attempt < maxAttempts - 1) {
        // 退避：优先尊重 Retry-After，否则指数 + 抖动（避免并发请求同步重试）
        final base =
            retryAfter?.inMilliseconds ?? (500 * pow(2, attempt)).toInt();
        final w = (min(base, 15000)) + rnd.nextInt(400);
        _log('$publicName ⟳ zen 第 ${attempt + 1} 次失败($why)，${w}ms 后重试');
        await Future.delayed(Duration(milliseconds: w));
        // 只重试用户指定的原模型，绝不转投其他模型（换模型=伪造结果）
        return _zenTurn(
          req,
          route,
          publicName,
          origBody,
          clientWantsStream: clientWantsStream,
          anthropic: anthropic,
          attempt: attempt + 1,
        );
      }
      final parsed = (errBody != null && errBody.isNotEmpty)
          ? _safeJson(errBody)
          : null;
      final msg =
          (parsed?['error']?['message'] ??
                  parsed?['message'] ??
                  errBody ??
                  'Zen 请求失败')
              as String;
      u.lastError = msg;
      _account(publicName, u.id, 0, 0, true);
      _log('$publicName ✗ zen ${errStatus ?? 'conn'}: $msg');
      return failJson({
        'message': msg,
        'type': anthropic
            ? 'api_error'
            : (errStatus == 429 ? 'rate_limit_exceeded' : 'upstream_error'),
      }, errStatus ?? 502);
    }

    if (uresp == null) {
      // 400 自愈：按上游报错修正请求体（未知字段/推理回传/参数归一）后
      // 透明重试——这是确定性修正，不计错误、不开熔断
      if (errStatus == 400 &&
          attempt < maxAttempts - 1 &&
          (errBody ?? '').isNotEmpty) {
        final fix = Zen.healBody(errBody!, origBody);
        if (fix != null) {
          _log('$publicName ⟳ 上游 400 已自愈（$fix），透明重试');
          return _zenTurn(
            req,
            route,
            publicName,
            origBody,
            clientWantsStream: clientWantsStream,
            anthropic: anthropic,
            attempt: attempt + 1,
          );
        }
      }
      final parsed0 = (errBody ?? '').isNotEmpty ? _safeJson(errBody!) : null;
      final msg0 =
          (parsed0?['error']?['message'] ?? parsed0?['message'] ?? '')
              as String;
      // 免费额度耗尽(429) / 地理拒绝(403)：按「出口 IP × 天」「出口国家」计，
      // 换一个出口就有救——退避或快败都是错的（2026-10-22 实测：同一模型
      // 直连节点已烧穿，换节点/换一条到 Worker 的新连接立即 200；连打 12
      // 次新连接全 200）。策略：最多连续换 3 次出口；每次都强制新建 TLS
      // 连接（经 Worker 时新连接 = CF 新落地机房 = 新出口 IP）。
      final rotatable = Zen.isQuotaExhausted(msg0) || Zen.isGeoBlocked(msg0);
      // 有得可换才换：经 Worker（新连接=新出口 IP）或有出口池（换节点）。
      // 直连单 IP 没有可换的出口，额度/地理当天就是死局，直接如实报错。
      final viaWorker = u.def.baseUrl.contains('workers.dev');
      // 经 Worker 且没有出口池时，「换新连接」就是把同一个出口再发一次
      // （请求循环本来就会新建 TLS 连接，这里并没有额外动作）。日志必须
      // 如实写「换出口」，不能谎称「换新连接/机房」误导排查。
      final canActuallySwitch = _zenEgress.length > 1;
      if (rotatable && canActuallySwitch && attempt < 3) {
        final node = _zenCurrentNode;
        if (Zen.isQuotaExhausted(msg0) &&
            !viaWorker &&
            node != null &&
            node.isNotEmpty) {
          // 直连模式：这个节点 IP 今天额度烧穿了，按天拉黑（UTC 零点翻篇）
          // markQuotaSpent 内部 notify → 生产环境 _onPoolChanged 会落盘，
          // 这里不显式 save（避免测试隔离没注入 savePath 时误写真实池）
          activePool?.markQuotaSpent(node);
        }
        _account(publicName, u.id, 0, 0, true);
        final next = _zenNextRotatableEgress(route.upstreamModel);
        _log(
          '$publicName ⟳ zen ${Zen.isGeoBlocked(msg0) ? '地理拒绝' : '额度耗尽'}'
          '（换出口 ${next.nodeId ?? next.directive}）'
          '，第 ${attempt + 1}/3 次',
        );
        _zenProxySig = ''; // 强制新建 HttpClient：一条全新的 TLS 连接
        if (next.directive.isNotEmpty) _zenUseEgress(next);
        await Future<void>.delayed(
          Duration(milliseconds: 150 + rnd.nextInt(200)),
        );
        return _zenTurn(
          req,
          route,
          publicName,
          origBody,
          clientWantsStream: clientWantsStream,
          anthropic: anthropic,
          attempt: attempt + 1,
        );
      }
      if (rotatable) {
        // 到这里 = 没有第二个出口可换（_zenEgress.length<=1）：经 Worker
        // 时也只是同一个 CF 出口反复重发，日志不能谎称换过出口。
        u.lastError = msg0;
        _account(publicName, u.id, 0, 0, true);
        final triedRotate = canActuallySwitch && attempt > 0;
        final tail = triedRotate ? '，换出口重试后仍未恢复' : '';
        if (Zen.isQuotaExhausted(msg0)) {
          _log('$publicName ✗ zen 免费额度耗尽$tail: $msg0');
          return failJson({
            'message':
                'OpenCode Zen 免费额度已用完$tail'
                '（上游原文：$msg0）。额度按出口 IP 每天 UTC 零点重置：'
                '可稍后再试、切换其他免费模型，或订阅 OpenCode Go。',
            'type': anthropic ? 'rate_limit_error' : 'rate_limit_exceeded',
            'code': 'free_quota_exhausted',
          }, 429);
        }
        _log('$publicName ✗ zen 地理拒绝$tail: $msg0');
        return failJson({
          'message': 'OpenCode 判定该模型在当前出口地区不可用$tail：$msg0',
          'type': anthropic ? 'rate_limit_error' : 'rate_limited',
          'code': 'geo_blocked',
        }, 429);
      }
      final retryable =
          errStatus == null || errStatus == 429 || errStatus >= 500;
      if (retryable) {
        // IP 级 429：这个出口 IP 在该模型上被限流。换一个干净 IP 立即重试
        // 比陪它退避有效得多（飞鸟云 22 节点 round-robin，实测同模型 5 路
        // 并发时逐个换 IP 全部 200，最长 48.7s；不换 IP 时反复 429）。
        if (errStatus == 429 && attempt < maxAttempts - 1) {
          final node = _zenCurrentNode;
          if (node != null) {
            final wait = retryAfter ?? const Duration(seconds: 60);
            _zenIpCool(node, route.upstreamModel, wait);
          }
          final next = _zenPickEgress(route.upstreamModel);
          final switched = next.directive.isNotEmpty &&
              next.directive != _zenEgress[_zenProxyIdx % _zenEgress.length].directive;
          if (switched) {
            _zenUseEgress(next);
            _account(publicName, u.id, 0, 0, true);
            _log(
              '$publicName ⟳ zen 429 换出口 IP 重试'
              '（${next.nodeId ?? 'direct'}，第 ${attempt + 1} 次）',
            );
            return _zenTurn(
              req,
              route,
              publicName,
              origBody,
              clientWantsStream: clientWantsStream,
              anthropic: anthropic,
              attempt: attempt + 1,
            );
          }
        }
        return retryOrFail('HTTP ${errStatus ?? 'conn'}');
      }
      final parsed = (errBody ?? '').isNotEmpty ? _safeJson(errBody!) : null;
      final rawMsg =
          (parsed?['error']?['message'] ?? '供应商 ${u.id} HTTP $errStatus')
              as String;
      // 403 绝不能原样透传：上游滥用风控/门控与认证无关，客户端会把 403
      // 统一显示成 authentication failed 并可能禁用 provider。改为 429
      // （限流语义，客户端退避重试）。IP 级封锁再进 5 分钟全局静默。
      if (errStatus == 403) {
        final abuse =
            rawMsg.toLowerCase().contains('abus') ||
            (errBody ?? '').toLowerCase().contains('abusive traffic');
        _breaker.onFailure(
          route.upstreamModel,
          retryAfter: const Duration(seconds: 90),
        );
        if (abuse) {
          // 有代理池：先换出口 IP 立即重试（新 IP 可能直接可用），不进长静默；
          if (_rotateZenProxy(u.def) && attempt < maxAttempts - 1) {
            _account(publicName, u.id, 0, 0, true);
            _log('$publicName ⟳ 命中 IP 风控，换出口代理重试（第 ${attempt + 1} 次）');
            return _zenTurn(
              req,
              route,
              publicName,
              origBody,
              clientWantsStream: clientWantsStream,
              anthropic: anthropic,
              attempt: attempt + 1,
            );
          }
          if (u.def.proxyPool.isEmpty && _zenEgress.isEmpty) {
            // 直连被封：出口 IP 固定，继续撞只会延长封锁 → 递增全局静默；
            // 首次触发时通知 UI 征询用户是否启用出口代理/部署 Worker
            _zenBanStreak = min(_zenBanStreak + 1, 5);
            final mins = min(60, 5 << (_zenBanStreak - 1)); // 5,10,20,40,60
            _zenIpBanUntil = DateTime.now().add(Duration(minutes: mins));
            _log('$publicName ⛔ IP 滥用封锁（第 $_zenBanStreak 次），静默 $mins 分钟');
            if (!_ipBanSignaled) {
              _ipBanSignaled = true;
              onIpBan?.call(u.id);
            }
          } else {
            // 经代理/Worker 出网时，403 只代表「这一个出口 IP 被标记」：
            // FlClash 每连接随机节点、CF 也是 IP 池，下一个请求大概率是
            // 干净 IP。只保留上面的单模型 90s 冷却，绝不全局静默——
            // 实测教训：全局窗口会把明明可用的其他模型一起误拦几分钟
            _log(
              '$publicName ⚠ 经代理出口命中 IP 风控（仅冷却 ${route.upstreamModel}，'
              '其他模型不受影响）',
            );
            if (!_ipBanSignaled) {
              _ipBanSignaled = true;
              onIpBan?.call(u.id);
            }
          }
        }
        _account(publicName, u.id, 0, 0, true);
        _log('$publicName ✗ zen 403 ${abuse ? 'IP 滥用封锁' : '门控拒绝'}: $rawMsg');
        return failJson({
          'message': abuse
              ? 'OpenCode 检测到本机出口 IP 的滥用流量并限制免费通道（与账号无关）：$rawMsg'
              : 'OpenCode 免费通道拒绝了该请求：$rawMsg',
          'type': anthropic ? 'rate_limit_error' : 'rate_limited',
          'code': abuse ? 'ip_abuse_backoff' : 'upstream_forbidden',
        }, 429);
      }
      _account(publicName, u.id, 0, 0, true);
      return failJson({
        'message': rawMsg,
        'type': anthropic ? 'api_error' : 'upstream_error',
      }, errStatus);
    }

    _breaker.onSuccess(route.upstreamModel);
    _zenBanStreak = 0;
    _zenIpBanUntil = null;
    _ipBanSignaled = false;
    u.health = UpstreamHealth.healthy;
    u.lastError = null;
    // 解码流交给 pump：pump 只在产出首个有效输出后才提交响应头，
    // 提交前的断流以 _ZenEarlyReset 抛出 → 此处透明重试
    final lines = uresp.transform(utf8.decoder);
    try {
      if (clientWantsStream) {
        await _pumpZenStream(
          lines,
          req,
          route,
          publicName,
          injected,
          anthropic: anthropic,
          nameMap: nameMap,
        );
      } else {
        await _pumpZenAggregate(
          lines,
          req,
          route,
          publicName,
          injected,
          anthropic: anthropic,
          nameMap: nameMap,
        );
      }
    } on _ZenEarlyReset catch (e) {
      if (attempt < maxAttempts - 1) return retryOrFail('early(${e.why})');
      _account(publicName, u.id, 0, 0, true);
      _log('$publicName ✗ zen 提交前流断（已尽重试）: ${e.why}');
      return failJson({
        'message': '上游免费端点不稳定（连接被重置），请稍后重试',
        'type': anthropic ? 'api_error' : 'upstream_error',
      }, 502);
    } catch (e) {
      _account(publicName, u.id, 0, 0, true);
      _log('$publicName ✗ zen stream: $e');
    }
  }

  /// 流式泵：延迟提交——产出首个有效输出前如果上游断流，抛 _ZenEarlyReset
  /// （调用方还能透明重试，客户端什么都没收到）；提交后的断流只能带错误收尾。
  Future<void> _pumpZenStream(
    Stream<String> lines,
    HttpRequest req,
    ModelRoute route,
    String publicName,
    Set<String> injected, {
    required bool anthropic,
    Map<String, String> nameMap = const {},
  }) async {
    final decoy = <int, bool>{};
    int prompt = 0, completion = 0;
    var committed = false;
    var done = false;

    // 响应体必须按 utf-8 写出：免费模型输出常含 CJK/em-dash 等 latin1 覆盖不
    // 了的字符，若 contentType 不带 charset，Dart 会回落 latin1 编码，write()
    // 直接抛 'Contains invalid characters' 截断已提交的流。显式带 utf-8，并用
    // add(utf8.encode(...)) 按字节写，彻底绕开响应默认编码假设。
    void commit() {
      if (committed) return;
      req.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set('Cache-Control', 'no-cache')
        ..set('x-zeroapi-upstream', route.upstream.id);
      req.response.statusCode = 200;
      committed = true;
    }

    final aStream = anthropic
        ? AnthropicAdapter.streamTransformer(route.upstreamModel)
        : null;

    // 逐行解析 SSE；事件可能跨多个解码块，按 \n 切行缓冲
    String pending = '';
    Future<void> handleData(String data) async {
      if (data == '[DONE]') {
        done = true;
        if (aStream != null) {
          commit();
          for (final ev in aStream.finish()) {
            req.response.add(utf8.encode(ev));
          }
        } else {
          commit();
          req.response.add(utf8.encode('data: [DONE]\n\n'));
        }
        await req.response.flush();
        return;
      }
      Map<String, dynamic>? j;
      try {
        j = jsonDecode(data) as Map<String, dynamic>;
      } catch (_) {
        j = null;
      }
      if (j == null) return;
      final us = j['usage'] as Map?;
      if (us != null) {
        prompt = (us['prompt_tokens'] ?? prompt) as int;
        completion = (us['completion_tokens'] ?? completion) as int;
        _ctx?.cached = _cachedOf(us);
      }
      final out = Zen.filterDecoyChunk(j, injected, decoyIndex: decoy);
      if (out != null) Zen.restoreToolNames(out, nameMap);
      if (aStream != null) {
        if (out == null) return; // 纯诱饵增量，不喂给适配器
        final evs = aStream.feed(jsonEncode(out));
        if (evs.isNotEmpty) {
          commit();
          for (final ev in evs) {
            req.response.add(utf8.encode(ev));
          }
          await req.response.flush();
        }
      } else if (out != null) {
        commit();
        req.response.add(utf8.encode('data: ${jsonEncode(out)}\n\n'));
        await req.response.flush();
      }
    }

    try {
      await for (final s in lines) {
        pending += s;
        int nl;
        while ((nl = pending.indexOf('\n')) >= 0) {
          final line = pending.substring(0, nl).trim();
          pending = pending.substring(nl + 1);
          if (!line.startsWith('data:')) continue;
          final data = line.substring(5).trim();
          if (data.isEmpty) continue;
          await handleData(data);
          if (done) break;
        }
        if (done) break;
      }
    } catch (e) {
      if (!committed) {
        throw _ZenEarlyReset('$e');
      }
      rethrow; // 已提交：错误直接上抛，由 _zenTurn 的 catch 记录
    }
    if (!committed) {
      // 流正常结束但一个事件都没有（免费端点秒断的另一种表现）
      if (!done) throw _ZenEarlyReset('empty-stream');
    }
    await req.response.close();
    _account(
      publicName,
      route.upstream.id,
      prompt,
      completion,
      false,
      cached: _ctx?.cached ?? 0,
    );
    _log(
      '$publicName ✓ zen stream ${route.upstream.id}'
      '${anthropic ? ' [anthropic]' : ''}${_tail(_ctx, prompt, completion)}',
    );
  }

  /// 非流式泵：先全量读 SSE 聚合，读失败且尚未写响应 → 抛 _ZenEarlyReset 可重试
  Future<void> _pumpZenAggregate(
    Stream<String> lines,
    HttpRequest req,
    ModelRoute route,
    String publicName,
    Set<String> injected, {
    required bool anthropic,
    Map<String, String> nameMap = const {},
  }) async {
    final text = StringBuffer();
    try {
      await for (final s in lines) {
        text.write(s);
      }
    } catch (e) {
      throw _ZenEarlyReset('aggregate: $e');
    }
    final datas = <Map<String, dynamic>>[];
    for (final raw in text.toString().split('\n')) {
      final t = raw.trim();
      if (!t.startsWith('data:')) continue;
      final d = t.substring(5).trim();
      if (d.isEmpty || d == '[DONE]') continue;
      try {
        final m = jsonDecode(d) as Map<String, dynamic>;
        Zen.restoreToolNames(m, nameMap);
        datas.add(m);
      } catch (_) {}
    }
    final agg = Zen.aggregate(datas, route.upstreamModel, injected);
    int prompt = 0, completion = 0;
    final us = agg['usage'] as Map?;
    if (us != null) {
      prompt = (us['prompt_tokens'] ?? 0) as int;
      completion = (us['completion_tokens'] ?? 0) as int;
      _ctx?.cached = _cachedOf(us);
    }
    req.response.headers
      ..contentType = ContentType.json
      ..set('x-zeroapi-upstream', route.upstream.id);
    req.response.statusCode = 200;
    req.response.write(
      jsonEncode(anthropic ? AnthropicAdapter.toAnthropicResponse(agg) : agg),
    );
    await req.response.close();
    _account(
      publicName,
      route.upstream.id,
      prompt,
      completion,
      false,
      cached: _ctx?.cached ?? 0,
    );
    _log(
      '$publicName ✓ zen ${route.upstream.id}'
      '${anthropic ? ' [anthropic]' : ''}${_tail(_ctx, prompt, completion)}',
    );
  }

  /// HH:MM 时刻显示（本地时区），用于提示静默窗口结束时间
  static String _fmtClock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Map<String, dynamic> _safeJson(String s) {
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return {
        'error': {'message': s},
      };
    }
  }

  void _json(HttpRequest req, Object body, [int status = 200]) {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    req.response.close();
  }
}

/// 按 key 限流的异步闸门（同一模型并发 ≤ 容量）。等待者 FIFO 交接名额；
/// 等太久（上游迟迟不结束）则超时放行——宁可冒险，也不让请求无限挂着。
class _ModelGate {
  final Map<String, int> _active = {};
  final Map<String, List<_GateWaiter>> _waiters = {};

  Future<bool> acquire(String key, int limit, Duration timeout) async {
    final active = _active[key] ?? 0;
    if (active < limit) {
      _active[key] = active + 1;
      return true;
    }
    final w = _GateWaiter();
    (_waiters[key] ??= []).add(w);
    final timer = Timer(timeout, () {
      if (w.completer.isCompleted) return;
      w.timedOut = true;
      _waiters[key]?.remove(w);
      w.completer.complete();
    });
    await w.completer.future;
    timer.cancel();
    return !w.timedOut;
  }

  void release(String key) {
    final queue = _waiters[key];
    while (queue != null && queue.isNotEmpty) {
      final w = queue.removeAt(0);
      if (w.timedOut) continue;
      w.completer.complete(); // 名额直接交接，_active 不变
      return;
    }
    final n = (_active[key] ?? 1) - 1;
    if (n <= 0) {
      _active.remove(key);
    } else {
      _active[key] = n;
    }
  }
}

class _GateWaiter {
  final completer = Completer<void>();
  bool timedOut = false;
}
