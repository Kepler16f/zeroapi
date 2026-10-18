import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'anthropic.dart';
import 'modelsdev.dart';
import 'upstream.dart';
import 'zen.dart';

class ModelRoute {
  final String publicName;
  final UpstreamRuntime upstream;
  final String upstreamModel;
  final bool bare;
  ModelRoute(this.publicName, this.upstream, this.upstreamModel, this.bare);
}

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
  final Map<String, int> byModel = {};
  /// 按模型的词元总量（输入+输出）：用量图按此排序/占比，次数仅并列展示
  final Map<String, int> byModelTokens = {};
  /// 按天词元总量（MM-dd → tokens）：周/月/总视图折线的纵轴
  final Map<String, int> byDayTokens = {};
  final Map<String, int> trend = {};

  void add(String model, int prompt, int completion, bool isError, {String? trendKey}) {
    requests++;
    promptTokens += prompt;
    completionTokens += completion;
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
  final String apiKey;
  final ModelRegistry registry;
  final bool anthropicEnabled;
  UsageStats usageToday = UsageStats();
  HttpServer? _server;
  IOSink? _usageSink;
  final _logLines = <String>[]; // 环形日志，UI 展示
  static const _maxLog = 200;
  String _usageDay = DateTime.now().toIso8601String().substring(0, 10);

  /// 未知模型时的自救：由 GatewayService 注入"重探全部上游 + 重建路由"。
  /// 上游模型目录是动态的（如 opencode 随 models.dev 上新/重启后变化），
  /// 本地路由表可能滞后；重探一次仍找不到才 404，与上游目录严格同步。
  Future<void> Function()? onUnknownModel;
  DateTime _lastUnknownRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  /// 统一记账：内存当日汇总（含小时趋势）+ jsonl 落盘（跨天自动换文件）
  void _account(String model, String upstream, int p, int c, bool err) {
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
    usageToday.add(model, p, c, err, trendKey: now.hour.toString().padLeft(2, '0'));
    try {
      _usageSink ??= _openUsageFile();
      _usageSink?.writeln(jsonEncode({
        'ts': now.toIso8601String(),
        'model': model,
        'upstream': upstream,
        'prompt': p,
        'completion': c,
        'error': err,
      }));
    } catch (_) {}
  }

  /// 从磁盘 jsonl 聚合指定天数范围的用量（含按天趋势）。
  /// days=1 今日（小时趋势）；days=7/30 按天趋势；days=null 全部。
  Future<UsageStats> usageRange({int? days}) async {
    final out = UsageStats();
    try {
      final base = Platform.isWindows
          ? Platform.environment['APPDATA']!
          : '${Platform.environment['HOME']}/.config';
      final dir = Directory('$base/zeroapi/logs');
      if (!dir.existsSync()) return out;
      final cutoff = days == null
          ? null
          : DateTime.now().subtract(Duration(days: days - 1));
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('usage-'))
          .toList()
        ..sort();
      for (final f in files) {
        final m = RegExp(r'usage-(\d{4}-\d{2}-\d{2})\.jsonl').firstMatch(f.path);
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

  ProxyServer(this.host, this.port, this.apiKey, this.registry,
      {this.anthropicEnabled = true});

  List<String> get logs => List.unmodifiable(_logLines);

  /// 实际监听端口（port 传 0 时由系统分配，测试用）
  int get boundPort => _server?.port ?? port;

  Future<void> start() async {
    final server = await HttpServer.bind(host, port);
    _server = server;
    server.listen(_handle, onError: (e) => _log('server error: $e'));
    _log('zeroapi 监听 http://$host:$port/v1');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
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
      // Anthropic 系客户端（Claude Code/SDK）默认带 anthropic-version + x-api-key，
      // 两种头任一匹配即可
      if (auth != 'Bearer $apiKey' && xkey != apiKey) {
        return _json(req, {'error': {'message': '无效的网关 API key'}}, 401);
      }

      if (path == '/v1/models' && req.method == 'GET') {
        return _json(req, {
          'object': 'list',
          'data': registry.all
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
                    ...info.toJson(),
                  },
                };
              })
              .toList(),
        });
      }

      if (path == '/v1/chat/completions' && req.method == 'POST') {
        await _chat(req);
        return;
      }

      if (path == '/v1/responses' && req.method == 'POST') {
        await _responses(req);
        return;
      }

      if (path == '/v1/messages' && req.method == 'POST') {
        if (!anthropicEnabled) {
          return _json(req, {
            'type': 'error',
            'error': {'type': 'not_found_error', 'message': 'Anthropic 适配已在设置中关闭'}
          }, 404);
        }
        await _messages(req);
        return;
      }

      _json(req, {'error': {'message': '不支持 ${req.method} $path'}}, 404);
    } catch (e) {
      _log('handler 异常: $e');
      try {
        _json(req, {'error': {'message': '$e'}}, 500);
      } catch (_) {}
    }
  }

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

    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
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
        req.response.headers
          ..contentType = ContentType('text', 'event-stream')
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
                }
              } catch (_) {}
            }
            for (final ev in evs) {
              req.response.write(ev);
            }
            await req.response.flush();
          }
        }
        await req.response.close();
        _account(publicName, u.id, prompt, completion, false);
        _log('$publicName ✓ stream ${u.id}$tag');
      } else if (isStream) {
        req.response.headers
          ..contentType = ContentType('text', 'event-stream')
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
        _account(publicName, u.id, prompt, completion, false);
        _log('$publicName ✓ stream ${u.id}$tag');
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
        } catch (_) {}
        _account(publicName, u.id, prompt, completion, false);
        _log('$publicName ✓ ${u.id}$tag');
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
  /// 回传时剔除模型对诱饵工具的调用。429/5xx/连接错误指数退避重试（仅首字节
  /// 前，流式已提交后不可重试）。客户端 stream 决定是否把上游 SSE 聚合成非流式。
  Future<void> _forwardZen(HttpRequest req, ModelRoute route, String publicName,
      Map<String, dynamic> body,
      {required bool clientWantsStream, bool anthropic = false}) async {
    final u = route.upstream;
    final injected = <String>{};
    final sent = Map<String, dynamic>.from(body)
      ..['stream'] = true
      ..['stream_options'] = {'include_usage': true}
      ..['tools'] = Zen.ensureFreeTools(body['tools'], injected);

    void failJson(Map<String, dynamic> err, int status) => anthropic
        ? _json(req, {'type': 'error', 'error': err}, status)
        : _json(req, {'error': err}, status);

    const maxAttempts = 3;
    final rnd = Random();
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      HttpClientResponse? uresp;
      int? errStatus;
      String? errBody;
      try {
        final ureq = await client
            .openUrl('POST', Uri.parse('${Zen.base}/chat/completions'));
        Zen.headers(u.def.apiKey).forEach((k, v) => ureq.headers.set(k, v));
        ureq.headers.set('Content-Type', 'application/json');
        ureq.add(utf8.encode(jsonEncode(sent)));
        final r = await ureq.close().timeout(
            clientWantsStream ? const Duration(hours: 2) : const Duration(minutes: 70));
        if (r.statusCode == 200) {
          uresp = r;
        } else {
          errStatus = r.statusCode;
          errBody = await r.transform(utf8.decoder).join();
          client.close(force: true);
        }
      } catch (e) {
        errBody = e.toString();
        client.close(force: true);
      }

      if (uresp == null) {
        final retryable =
            errStatus == null || errStatus == 429 || errStatus >= 500;
        if (retryable && attempt < maxAttempts - 1) {
          final w = (500 * pow(2, attempt)).toInt() + rnd.nextInt(300);
          _log('$publicName ⟳ zen 第 ${attempt + 1} 次失败(${errStatus ?? 'conn'})，${w}ms 后重试');
          await Future.delayed(Duration(milliseconds: w));
          continue;
        }
        final parsed = (errBody != null && errBody.isNotEmpty) ? _safeJson(errBody) : null;
        final msg = (parsed?['error']?['message'] ??
                parsed?['message'] ??
                errBody ??
                'Zen 请求失败')
            as String;
        u.health = UpstreamHealth.down;
        u.lastError = msg;
        _account(publicName, u.id, 0, 0, true);
        _log('$publicName ✗ zen HTTP ${errStatus ?? 'conn'}: $msg');
        return failJson({
          'message': msg,
          'type': anthropic ? 'api_error' : 'upstream_error'
        }, errStatus ?? 502);
      }

      u.health = UpstreamHealth.healthy;
      u.lastError = null;
      try {
        if (clientWantsStream) {
          await _pumpZenStream(uresp, req, route, publicName, injected,
              anthropic: anthropic, client: client);
        } else {
          await _pumpZenAggregate(uresp, req, route, publicName, injected,
              anthropic: anthropic, client: client);
        }
      } catch (e) {
        _account(publicName, u.id, 0, 0, true);
        _log('$publicName ✗ zen stream: $e');
        client.close(force: true);
      }
      return;
    }
  }

  Future<void> _pumpZenStream(HttpClientResponse uresp, HttpRequest req,
      ModelRoute route, String publicName, Set<String> injected,
      {required bool anthropic, required HttpClient client}) async {
    req.response.headers
      ..contentType = ContentType('text', 'event-stream')
      ..set('Cache-Control', 'no-cache')
      ..set('x-zeroapi-upstream', route.upstream.id);
    req.response.statusCode = 200;
    final decoy = <int, bool>{};
    int prompt = 0, completion = 0;

    if (anthropic) {
      final aStream = AnthropicAdapter.streamTransformer(route.upstreamModel);
      var buf = '';
      await for (final raw in uresp) {
        buf += utf8.decode(raw, allowMalformed: true);
        int nl;
        while ((nl = buf.indexOf('\n')) >= 0) {
          final line = buf.substring(0, nl).trim();
          buf = buf.substring(nl + 1);
          if (!line.startsWith('data:')) continue;
          final data = line.substring(5).trim();
          if (data.isEmpty) continue;
          if (data == '[DONE]') {
            for (final ev in aStream.finish()) {
              req.response.write(ev);
            }
            await req.response.flush();
            continue;
          }
          Map<String, dynamic>? j;
          try {
            j = jsonDecode(data) as Map<String, dynamic>;
          } catch (_) {
            j = null;
          }
          if (j == null) continue;
          final us = j['usage'] as Map?;
          if (us != null) {
            prompt = (us['prompt_tokens'] ?? prompt) as int;
            completion = (us['completion_tokens'] ?? completion) as int;
          }
          Zen.filterDecoyChunk(j, injected, decoyIndex: decoy);
          for (final ev in aStream.feed(jsonEncode(j))) {
            req.response.write(ev);
          }
          await req.response.flush();
        }
      }
    } else {
      var buf = '';
      await for (final raw in uresp) {
        buf += utf8.decode(raw, allowMalformed: true);
        int nl;
        while ((nl = buf.indexOf('\n')) >= 0) {
          final line = buf.substring(0, nl).trim();
          buf = buf.substring(nl + 1);
          if (!line.startsWith('data:')) continue;
          final data = line.substring(5).trim();
          if (data.isEmpty) continue;
          if (data == '[DONE]') {
            req.response.write('data: [DONE]\n\n');
            await req.response.flush();
            continue;
          }
          Map<String, dynamic>? j;
          try {
            j = jsonDecode(data) as Map<String, dynamic>;
          } catch (_) {
            j = null;
          }
          if (j == null) continue;
          final us = j['usage'] as Map?;
          if (us != null) {
            prompt += (us['prompt_tokens'] ?? 0) as int;
            completion += (us['completion_tokens'] ?? 0) as int;
          }
          final out = Zen.filterDecoyChunk(j, injected, decoyIndex: decoy);
          if (out == null) continue;
          req.response.write('data: ${jsonEncode(out)}\n\n');
          await req.response.flush();
        }
      }
    }
    await req.response.close();
    _account(publicName, route.upstream.id, prompt, completion, false);
    _log('$publicName ✓ zen stream ${route.upstream.id}${anthropic ? ' [anthropic]' : ''}');
    client.close(force: true);
  }

  Future<void> _pumpZenAggregate(HttpClientResponse uresp, HttpRequest req,
      ModelRoute route, String publicName, Set<String> injected,
      {required bool anthropic, required HttpClient client}) async {
    final text = await uresp.transform(utf8.decoder).join();
    client.close(force: true);
    final datas = <Map<String, dynamic>>[];
    for (final raw in text.split('\n')) {
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
    }
    req.response.headers
      ..contentType = ContentType.json
      ..set('x-zeroapi-upstream', route.upstream.id);
    req.response.statusCode = 200;
    req.response.write(jsonEncode(anthropic
        ? AnthropicAdapter.toAnthropicResponse(agg)
        : agg));
    await req.response.close();
    _account(publicName, route.upstream.id, prompt, completion, false);
    _log('$publicName ✓ zen ${route.upstream.id}${anthropic ? ' [anthropic]' : ''}');
  }

  Map<String, dynamic> _safeJson(String s) {
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return {'error': {'message': s}};
    }
  }


  static IOSink? _openUsageFile() {
    try {
      final base = Platform.isWindows
          ? Platform.environment['APPDATA']!
          : '${Platform.environment['HOME']}/.config';
      final dir = Directory('$base/zeroapi/logs');
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
