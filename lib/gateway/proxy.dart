import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'anthropic.dart';
import 'config.dart';
import 'modelsdev.dart';
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
      for (final m in u.models) {
        _routes['${u.id}/$m'] = ModelRoute('${u.id}/$m', u, m, false);
        // 裸名：供应商注册顺序先到先得；重名时后来者用全名访问
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

  void add(String model, int prompt, int completion, bool isError,
      {String? trendKey, int cached = 0}) {
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
    o.byModel.forEach((k, v) => byModel.update(k, (x) => x + v, ifAbsent: () => v));
    o.byModelTokens.forEach((k, v) => byModelTokens.update(k, (x) => x + v, ifAbsent: () => v));
    if (trendKey != null) {
      trend.update(trendKey, (x) => x + o.requests, ifAbsent: () => o.requests);
      byDayTokens.update(trendKey, (x) => x + o.promptTokens + o.completionTokens,
          ifAbsent: () => o.promptTokens + o.completionTokens);
    } else {
      o.trend.forEach((k, v) => trend.update(k, (x) => x + v, ifAbsent: () => v));
      o.byDayTokens.forEach((k, v) => byDayTokens.update(k, (x) => x + v, ifAbsent: () => v));
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
  UsageStats usageToday = UsageStats();
  HttpServer? _server;
  IOSink? _usageSink;

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
  bool _ipBanSignaled = false;
  DateTime _lastUnknownRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  /// 统一记账：内存当日汇总（含小时趋势）+ jsonl 落盘（跨天自动换文件）
  void _account(String model, String upstream, int p, int c, bool err,
      {int cached = 0}) {
    final now = DateTime.now();
    final day = now.toIso8601String().substring(0, 10);
    if (day != _usageDay) {
      _usageDay = day;
      usageToday = UsageStats();
      try {
        _usageSink?.flush();
        _usageSink?.close();
      } catch (_) {}
      _usageSink = null;
    }
    usageToday.add(model, p, c, err,
        trendKey: now.hour.toString().padLeft(2, '0'), cached: cached);
    try {
      _usageSink ??= _openUsageFile();
      _usageSink?.writeln(jsonEncode({
        'ts': now.toIso8601String(),
        'model': model,
        'upstream': upstream,
        'prompt': p,
        'completion': c,
        'error': err,
        if (cached > 0) 'cached': cached,
      }));
    } catch (_) {}
  }

  /// 从 usage map 提取缓存命中词元（OpenAI: prompt_tokens_details.cached_tokens；
  /// Responses: input_tokens_details.cached_tokens）
  static int _cachedOf(Map? us) {
    if (us == null) return 0;
    final d = (us['prompt_tokens_details'] ?? us['input_tokens_details']) as Map?;
    return ((d?['cached_tokens'] ?? 0) as num).toInt();
  }

  /// 富日志行尾：密钥标签 · 模式 · 词元(含缓存) · 耗时
  String _tail(_ReqCtx? ctx, int p, int c) {
    if (ctx == null) return '';
    final parts = <String>['key=${ctx.keyLabel}', ctx.mode + (ctx.stream ? '·流' : '')];
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
      final files = dir
          .listSync()
          .whereType<File>()
          // 严格 .jsonl 结尾：备份/临时文件（*.jsonl.bak-*）不得混入重复计入
          .where((f) => f.path.contains('usage-') && f.path.endsWith('.jsonl'))
          .toList()
        // File 不可 Comparable：必须显式按路径比较，否则多文件时 sort 抛
        // 异常被外层 catch 吞掉 → 整个聚合静默返回 0（2026-10-19 线上教训）
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        final m = RegExp(r'usage-(\d{4}-\d{2}-\d{2})\.jsonl$').firstMatch(f.path);
        if (m == null) continue;
        final fileDay = DateTime.tryParse(m.group(1)!);
        if (fileDay == null) continue;
        // 当天文件用内存态（含未落盘的 flush 延迟）；历史文件读磁盘。
        // 跨天视图把当天聚合成一个日期桶，今日视图保留小时桶。
        if (m.group(1) == _usageDay) {
          out.merge(usageToday, trendKey: days == 1 ? null : _usageDay.substring(5));
          continue;
        }
        if (cutoff != null && fileDay.isBefore(cutoff)) continue;
        final lines = await f.readAsLines();
        for (final l in lines) {
          try {
            final j = jsonDecode(l) as Map<String, dynamic>;
            out.add(
                (j['model'] ?? '?') as String,
                (j['prompt'] ?? 0) as int,
                (j['completion'] ?? 0) as int,
                (j['error'] ?? false) as bool,
                trendKey: m.group(1)!.substring(5)); // MM-dd
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

  ProxyServer(this.host, this.port, String apiKey, this.registry,
      {this.anthropicEnabled = true,
      this.allowLan = false,
      List<GatewayKey>? keys,
      this.usageDir,
      this.onKeyUsed})
      : keys = keys ?? [GatewayKey('默认', apiKey)];

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
        allowLan ? InternetAddress.anyIPv4 : host, port);
    _server = server;
    server.listen(_handle, onError: (e) => _log('server error: $e'));
    _log(allowLan
        ? 'zeroapi 监听 http://$host:$port/v1（局域网 0.0.0.0:$port，首次需允许防火墙）'
        : 'zeroapi 监听 http://$host:$port/v1');
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
              (j['model'] ?? '?') as String,
              (j['prompt'] ?? 0) as int,
              (j['completion'] ?? 0) as int,
              (j['error'] ?? false) as bool,
              trendKey: DateTime.parse(j['ts'] as String)
                  .hour
                  .toString()
                  .padLeft(2, '0'));
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
        ..set('Access-Control-Allow-Headers',
            'Authorization, Content-Type, X-Api-Key, Anthropic-Version')
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
      final provided =
          auth.startsWith('Bearer ') ? auth.substring(7).trim() : xkey.trim();
      final matched = provided.isEmpty
          ? const <GatewayKey>[]
          : keys.where((k) => k.value == provided).toList();
      if (matched.isEmpty) {
        return _json(req, {'error': {'message': '无效的网关 API key'}}, 401);
      }
      // 请求上下文经 Zone 注入：深层转发/泵流无需改签名即可读密钥标签、
      // 计时、模式，产出统一富日志
      await runZoned(() => _dispatch(req, path),
          zoneValues: {_ctxKey: _ReqCtx(matched.first.label)});
      onKeyUsed?.call(matched.first);
    } catch (e) {
      _log('handler 异常: $e');
      try {
        _json(req, {'error': {'message': '$e'}}, 500);
      } catch (_) {}
    }
  }

  /// 鉴权通过后的路由分发（运行在带 _ReqCtx 的 Zone 中）
  Future<void> _dispatch(HttpRequest req, String path) async {
    if (path == '/v1/models' && req.method == 'GET') {
      // 去重：同一 (供应商,模型) 只暴露一条，裸名可用时优先裸名
      // （big-pickle 而非 zen/big-pickle）；裸名被他家占用才用 前缀名 消歧
      final byModel = <String, ModelRoute>{};
      for (final r in registry.all) {
        final key = '${r.upstream.id}|${r.upstreamModel}';
        final cur = byModel[key];
        if (cur == null || (r.bare && !cur.bare)) byModel[key] = r;
      }
      return _json(req, {
        'object': 'list',
        'data': byModel.values
            .map((r) {
              final info = r.upstream.modelInfo[r.upstreamModel] ??
                  ModelInfo.fromMaps({},
                      ModelsDev.instance.lookup(r.upstream.def.id, r.upstreamModel));
              return {
                'id': r.publicName,
                'object': 'model',
                'created': 0,
                'owned_by': r.upstream.id,
                'zeroapi': {
                  'bare': r.bare,
                  'upstream_model': r.upstreamModel,
                  'healthy': r.upstream.health == UpstreamHealth.healthy,
                  ...info.toJson() },
              };
            })
            .toList(),
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
          'error': {'type': 'not_found_error', 'message': 'Anthropic 适配已在设置中关闭'}
        }, 404);
      }
      _ctx?.mode = 'anthropic';
      return _messages(req);
    }
    _json(req, {'error': {'message': '不支持 ${req.method} $path'}}, 404);
  }

  /// 当前请求上下文（Zone 注入；非请求路径如测试直调时为 null）
  _ReqCtx? get _ctx => Zone.current[_ctxKey] as _ReqCtx?;

  /// 读取 JSON 请求体；非法 JSON 时写回 400 并返回 null
  Future<Map<String, dynamic>?> _readJson(HttpRequest req) async {
    try {
      return jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
    } catch (_) {
      _json(req, {'error': {'message': '请求体不是合法 JSON'}}, 400);
      return null;
    }
  }

  /// 解析模型路由并确保供应商可用；失败时写回 404/503 并返回 null。
  /// [forResponses]：调用来自 /v1/responses——Zen 直连上游实测不支持该端点，需拒绝。
  Future<ModelRoute?> _resolveRoute(
      Map<String, dynamic> body, HttpRequest req,
      {bool anthropicErrors = false, bool forResponses = false}) async {
    final publicName = (body['model'] ?? '') as String;
    var route = registry.resolve(publicName);
    void fail(String msg, String openaiType, String anthropicType, int status) => anthropicErrors
        ? _json(req, {'type': 'error', 'error': {'message': msg, 'type': anthropicType}}, status)
        : _json(req, {'error': {'message': msg, 'type': openaiType}}, status);
    if (route == null) {
      final refresh = onUnknownModel;
      // 5 秒去抖：并发 404 只触发一次全量重探
      if (refresh != null &&
          DateTime.now().difference(_lastUnknownRefresh) >= const Duration(seconds: 5)) {
        _lastUnknownRefresh = DateTime.now();
        _log('未知模型 $publicName：重探上游目录…');
        try {
          await refresh().timeout(const Duration(seconds: 30), onTimeout: () {});
        } catch (_) {}
        route = registry.resolve(publicName);
        if (route != null) {
          _log('未知模型 $publicName：重探后已收录（${route.upstream.id}）');
        }
      }
      if (route == null) {
        fail('未知模型 $publicName，见 GET /v1/models', 'unknown_model', 'not_found_error', 404);
        return null;
      }
    }
    final u = route.upstream;
    if (u.health != UpstreamHealth.healthy) {
      final ok = await u.probe();
      if (!ok) {
        fail('供应商 ${u.id} 不可用: ${u.lastError ?? "未知"}', 'upstream_down', 'overloaded_error', 503);
        return null;
      }
    }
    // Zen 免费通道只支持 chat 系列端点（实测 /responses 无指纹/带 tools 均 403）
    if (u.isZen && forResponses) {
      fail('Zen 免费通道仅支持 chat 系列端点（/v1/chat/completions、/v1/messages）',
          'unsupported_endpoint', 'invalid_request_error', 404);
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
    await _forward(req, route, publicName, 'chat/completions', body,
        isStream: body['stream'] == true);
  }

  /// Responses API（/v1/responses）透传：聚合层只负责路由与记账，
  /// 请求体原样转发到供应商的 /responses 端点。
  Future<void> _responses(HttpRequest req) async {
    final body = await _readJson(req);
    if (body == null) return;
    final publicName = (body['model'] ?? '') as String;
    final route = await _resolveRoute(body, req, forResponses: true);
    if (route == null) return;
    await _forward(req, route, publicName, 'responses', body,
        isStream: body['stream'] == true, responsesApi: true);
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
    await _forward(req, route, publicName, 'chat/completions', oai,
        isStream: isStream, anthropic: true);
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
      await _forwardZen(req, route, publicName, body,
          clientWantsStream: isStream, anthropic: anthropic);
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

    final proxy = _remoteFindProxy(u.def);
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..findProxy = (_) => proxy ?? 'DIRECT';
    try {
      final ureq = await client.openUrl('POST',
          Uri.parse('${u.def.baseUrl.replaceAll(RegExp(r'/+$'), '')}/$endpoint'));
      ureq.headers.set('Content-Type', 'application/json');
      if (u.def.apiKey.isNotEmpty) {
        ureq.headers.set('Authorization', 'Bearer ${u.def.apiKey}');
      }
      ureq.add(utf8.encode(jsonEncode(body)));
      // 首字节超时对齐上游 REQUEST_TIMEOUT_MS（内置 zen 为 1h）并留余量：
      // 免费模型思考几分钟属正常，不能比上游先掐断
      final uresp = await ureq.close().timeout(
            isStream ? const Duration(hours: 2) : const Duration(minutes: 70),
          );

      if (uresp.statusCode != 200) {
        final err = await uresp.transform(utf8.decoder).join();
        _log('$publicName ← 供应商 ${u.id} HTTP ${uresp.statusCode}');
        _account(publicName, u.id, 0, 0, true);
        final parsed = err.isNotEmpty ? _safeJson(err) : null;
        final errMsg = (parsed?['error']?['message'] ??
            parsed?['message'] ??
            '供应商 ${u.id} HTTP ${uresp.statusCode}') as String;
        final errType = anthropic ? 'upstream_error' : (parsed?['error']?['type'] ?? 'upstream_error') as String;
        return failJson({'message': errMsg, 'type': errType}, uresp.statusCode);
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
        _account(publicName, u.id, prompt, completion, false,
            cached: ctx?.cached ?? 0);
        _log('$publicName ✓ stream ${u.id}$tag${_tail(ctx, prompt, completion)}');
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
                      final us = (j['response'] as Map<String, dynamic>?)?['usage']
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
        _account(publicName, u.id, prompt, completion, false,
            cached: ctx?.cached ?? 0);
        _log('$publicName ✓ stream ${u.id}$tag${_tail(ctx, prompt, completion)}');
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
        _account(publicName, u.id, prompt, completion, false,
            cached: ctx?.cached ?? 0);
        _log('$publicName ✓ ${u.id}$tag${_tail(ctx, prompt, completion)}');
        req.response.headers
          ..contentType = ContentType.json
          ..set('x-zeroapi-upstream', u.id);
        req.response.statusCode = 200;
        if (anthropic) {
          req.response.write(jsonEncode(AnthropicAdapter.toAnthropicResponse(
              jsonDecode(data) as Map<String, dynamic>)));
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
        failJson({'message': '供应商 ${u.id} 请求失败: $e', 'type': anthropic ? 'api_error' : 'upstream_error'}, 502);
      } catch (_) {}
      client.close(force: true);
    }
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
  Future<void> _forwardZen(HttpRequest req, ModelRoute route, String publicName,
      Map<String, dynamic> body,
      {required bool clientWantsStream, bool anthropic = false}) async {
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
    await _zenTurn(req, route, publicName, body,
        clientWantsStream: clientWantsStream,
        anthropic: anthropic,
        attempt: 0);
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

  HttpClient _zenClientFor(UpstreamDef def) {
    final pool = def.proxyPool;
    if (pool.isEmpty) {
      // 直连（开关关闭或清空地址）：释放代理客户端，复用共享连接池
      _zenUp?.close(force: true);
      _zenUp = null;
      _zenProxySig = '';
      return upClient;
    }
    final fp = pool[_zenProxyIdx % pool.length];
    // sig 含 baseUrl：切到 Worker/换入口同样视为「出口变化」
    final sig = '$fp@${def.baseUrl}';
    if (_zenUp != null && _zenProxySig == sig) return _zenUp!;
    // 出口实际变化（换代理/换池/换入口）：被封的静默窗口是针对旧出口的，
    // 立即解除——换节点或切 Worker 后就能马上重试，不必干等
    if (_zenProxySig.isNotEmpty && _zenProxySig != sig) {
      _zenIpBanUntil = null;
      _zenBanStreak = 0;
    }
    _zenUp?.close(force: true);
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 60)
      ..maxConnectionsPerHost = 64
      ..findProxy = (_) => fp;
    _zenUp = c;
    _zenProxySig = sig;
    return c;
  }

  /// 通用（remote）转发路径的出口代理：每请求新建 client，轮流用池里的代理
  String? _remoteFindProxy(UpstreamDef def) {
    final pool = def.proxyPool;
    if (pool.isEmpty) return null;
    return pool[_remoteProxyTick++ % pool.length];
  }

  int _remoteProxyTick = 0;

  /// 命中 IP 风控时切到池里下一个出口代理；池大小 ≤1 无法轮换返回 false。
  bool _rotateZenProxy(UpstreamDef def) {
    final pool = def.proxyPool;
    if (pool.length <= 1) return false;
    _zenProxyIdx = (_zenProxyIdx + 1) % pool.length;
    _log('⟳ zen 出口代理轮换 → 第 ${_zenProxyIdx + 1}/${pool.length} 个');
    return true;
  }

  /// 单次 zen 请求尝试：发送→探流→提交→泵流；可重试错误在提交前发生。
  Future<void> _zenTurn(HttpRequest req, ModelRoute route, String publicName,
      Map<String, dynamic> origBody,
      {required bool clientWantsStream,
      required bool anthropic,
      required int attempt}) async {
    final u = route.upstream;
    final injected = <String>{};
    final sent = Map<String, dynamic>.from(origBody)
      ..['model'] = route.upstreamModel
      ..['stream'] = true
      ..['stream_options'] = {'include_usage': true}
      ..['tools'] = Zen.ensureFreeTools(origBody['tools'], injected);

    void failJson(Map<String, dynamic> err, int status) => anthropic
        ? _json(req, {'type': 'error', 'error': err}, status)
        : _json(req, {'error': err}, status);

    const maxAttempts = 5;
    final rnd = Random();
    HttpClientResponse? uresp;
    int? errStatus;
    String? errBody;
    Duration? retryAfter;
    try {
      final ureq = await _zenClientFor(u.def)
          .openUrl('POST', Uri.parse(
              '${u.def.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions'));
      Zen.headers(u.def.apiKey).forEach((k, v) => ureq.headers.set(k, v));
      ureq.headers.set('Content-Type', 'application/json');
      ureq.add(utf8.encode(jsonEncode(sent)));
      final r = await ureq.close().timeout(
          clientWantsStream ? const Duration(hours: 2) : const Duration(minutes: 70));
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
      errBody = e.toString();
    }

    Future<void> retryOrFail(String why) async {
      _breaker.onFailure(route.upstreamModel, retryAfter: retryAfter);
      if (attempt < maxAttempts - 1) {
        // 退避：优先尊重 Retry-After，否则指数 + 抖动（避免并发请求同步重试）
        final base = retryAfter?.inMilliseconds ??
            (500 * pow(2, attempt)).toInt();
        final w = (min(base, 15000)) + rnd.nextInt(400);
        _log('$publicName ⟳ zen 第 ${attempt + 1} 次失败($why)，${w}ms 后重试');
        await Future.delayed(Duration(milliseconds: w));
        // 只重试用户指定的原模型，绝不转投其他模型（换模型=伪造结果）
        return _zenTurn(req, route, publicName, origBody,
            clientWantsStream: clientWantsStream,
            anthropic: anthropic,
            attempt: attempt + 1);
      }
      final parsed = (errBody != null && errBody.isNotEmpty) ? _safeJson(errBody) : null;
      final msg = (parsed?['error']?['message'] ??
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
            : (errStatus == 429 ? 'rate_limit_exceeded' : 'upstream_error')
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
          return _zenTurn(req, route, publicName, origBody,
              clientWantsStream: clientWantsStream,
              anthropic: anthropic,
              attempt: attempt + 1);
        }
      }
      final retryable = errStatus == null || errStatus == 429 || errStatus >= 500;
      if (retryable) return retryOrFail('HTTP ${errStatus ?? 'conn'}');
      final parsed = (errBody ?? '').isNotEmpty ? _safeJson(errBody!) : null;
      final rawMsg = (parsed?['error']?['message'] ??
              '供应商 ${u.id} HTTP $errStatus')
          as String;
      // 403 绝不能原样透传：上游滥用风控/门控与认证无关，客户端会把 403
      // 统一显示成 authentication failed 并可能禁用 provider。改为 429
      // （限流语义，客户端退避重试）。IP 级封锁再进 5 分钟全局静默。
      if (errStatus == 403) {
        final abuse = rawMsg.toLowerCase().contains('abus') ||
            (errBody ?? '').toLowerCase().contains('abusive traffic');
        _breaker.onFailure(route.upstreamModel,
            retryAfter: const Duration(seconds: 90));
        if (abuse) {
          // 有代理池：先换出口 IP 立即重试（新 IP 可能直接可用），不进长静默；
          if (_rotateZenProxy(u.def) && attempt < maxAttempts - 1) {
            _account(publicName, u.id, 0, 0, true);
            _log('$publicName ⟳ 命中 IP 风控，换出口代理重试（第 ${attempt + 1} 次）');
            return _zenTurn(req, route, publicName, origBody,
                clientWantsStream: clientWantsStream,
                anthropic: anthropic,
                attempt: attempt + 1);
          }
          if (u.def.proxyPool.isEmpty) {
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
            _log('$publicName ⚠ 经代理出口命中 IP 风控（仅冷却 ${route.upstreamModel}，'
                '其他模型不受影响）');
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
      return failJson(
          {'message': rawMsg, 'type': anthropic ? 'api_error' : 'upstream_error'},
          errStatus);
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
        await _pumpZenStream(lines, req, route, publicName, injected,
            anthropic: anthropic);
      } else {
        await _pumpZenAggregate(lines, req, route, publicName, injected,
            anthropic: anthropic);
      }
    } on _ZenEarlyReset catch (e) {
      if (attempt < maxAttempts - 1) return retryOrFail('early(${e.why})');
      _account(publicName, u.id, 0, 0, true);
      _log('$publicName ✗ zen 提交前流断（已尽重试）: ${e.why}');
      return failJson({
        'message': '上游免费端点不稳定（连接被重置），请稍后重试',
        'type': anthropic ? 'api_error' : 'upstream_error'
      }, 502);
    } catch (e) {
      _account(publicName, u.id, 0, 0, true);
      _log('$publicName ✗ zen stream: $e');
    }
  }

  /// 流式泵：延迟提交——产出首个有效输出前如果上游断流，抛 _ZenEarlyReset
  /// （调用方还能透明重试，客户端什么都没收到）；提交后的断流只能带错误收尾。
  Future<void> _pumpZenStream(Stream<String> lines, HttpRequest req,
      ModelRoute route, String publicName, Set<String> injected,
      {required bool anthropic}) async {
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
    _account(publicName, route.upstream.id, prompt, completion, false,
        cached: _ctx?.cached ?? 0);
    _log('$publicName ✓ zen stream ${route.upstream.id}'
        '${anthropic ? ' [anthropic]' : ''}${_tail(_ctx, prompt, completion)}');
  }

  /// 非流式泵：先全量读 SSE 聚合，读失败且尚未写响应 → 抛 _ZenEarlyReset 可重试
  Future<void> _pumpZenAggregate(Stream<String> lines, HttpRequest req,
      ModelRoute route, String publicName, Set<String> injected,
      {required bool anthropic}) async {
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
        datas.add(jsonDecode(d) as Map<String, dynamic>);
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
    req.response.write(jsonEncode(anthropic
        ? AnthropicAdapter.toAnthropicResponse(agg)
        : agg));
    await req.response.close();
    _account(publicName, route.upstream.id, prompt, completion, false,
        cached: _ctx?.cached ?? 0);
    _log('$publicName ✓ zen ${route.upstream.id}'
        '${anthropic ? ' [anthropic]' : ''}${_tail(_ctx, prompt, completion)}');
  }

  /// HH:MM 时刻显示（本地时区），用于提示静默窗口结束时间
  static String _fmtClock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Map<String, dynamic> _safeJson(String s) {
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return {'error': {'message': s}};
    }
  }


  IOSink? _openUsageFile() {
    try {
      final dir = Directory(_usageDirPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final day = DateTime.now().toIso8601String().substring(0, 10);
      return File('${dir.path}/usage-$day.jsonl')
          .openWrite(mode: FileMode.append);
    } catch (_) {
      return null;
    }
  }

  void _json(HttpRequest req, Object body, [int status = 200]) {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    req.response.close();
  }
}
