import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'anthropic.dart';
import 'modelsdev.dart';
import 'upstream.dart';

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

class UsageStats {
  int requests = 0, errors = 0, promptTokens = 0, completionTokens = 0;
  final Map<String, int> byModel = {};

  void add(String model, int prompt, int completion, bool isError) {
    requests++;
    promptTokens += prompt;
    completionTokens += completion;
    if (isError) errors++;
    byModel.update(model, (v) => v + 1, ifAbsent: () => 1);
  }

  Map<String, dynamic> toJson() => {
        'requests': requests,
        'errors': errors,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'byModel': byModel,
      };
}

class ProxyServer {
  final String host;
  final int port;
  final String apiKey;
  final ModelRegistry registry;
  final bool anthropicEnabled;
  final UsageStats usageToday = UsageStats();
  HttpServer? _server;
  IOSink? _usageSink;
  final _logLines = <String>[]; // 环形日志，UI 展示
  static const _maxLog = 200;
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

  /// 解析模型路由并确保供应商可用；失败时写回 404/503 并返回 null
  Future<ModelRoute?> _resolveRoute(
      Map<String, dynamic> body, HttpRequest req, {bool anthropicErrors = false}) async {
    final publicName = (body['model'] ?? '') as String;
    final route = registry.resolve(publicName);
    void fail(String msg, String openaiType, String anthropicType, int status) => anthropicErrors
        ? _json(req, {'type': 'error', 'error': {'message': msg, 'type': anthropicType}}, status)
        : _json(req, {'error': {'message': msg, 'type': openaiType}}, status);
    if (route == null) {
      fail('未知模型 $publicName，见 GET /v1/models', 'unknown_model', 'not_found_error', 404);
      return null;
    }
    final u = route.upstream;
    if (u.health != UpstreamHealth.healthy) {
      final ok = await u.probe();
      if (!ok) {
        fail('供应商 ${u.id} 不可用: ${u.lastError ?? "未知"}', 'upstream_down', 'overloaded_error', 503);
        return null;
      }
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
    final route = await _resolveRoute(body, req);
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
      final uresp = await ureq.close().timeout(
            isStream ? const Duration(hours: 2) : const Duration(minutes: 10),
          );

      if (uresp.statusCode != 200) {
        final err = await uresp.transform(utf8.decoder).join();
        _log('$publicName ← 供应商 ${u.id} HTTP ${uresp.statusCode}');
        usageToday.add(publicName, 0, 0, true);
        _usageLine(publicName, u.id, 0, 0, true);
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
        usageToday.add(publicName, prompt, completion, false);
        _usageLine(publicName, u.id, prompt, completion, false);
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
        usageToday.add(publicName, prompt, completion, false);
        _usageLine(publicName, u.id, prompt, completion, false);
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
        usageToday.add(publicName, prompt, completion, false);
        _usageLine(publicName, u.id, prompt, completion, false);
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
      u.health = UpstreamHealth.down;
      u.lastError = e.toString();
      usageToday.add(publicName, 0, 0, true);
      _usageLine(publicName, u.id, 0, 0, true);
      _log('$publicName ✗ ${u.id}: $e');
      try {
        failJson({'message': '供应商 ${u.id} 请求失败: $e', 'type': anthropic ? 'api_error' : 'upstream_error'}, 502);
      } catch (_) {}
      client.close(force: true);
    }
  }

  Map<String, dynamic> _safeJson(String s) {
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return {'error': {'message': s}};
    }
  }

  void _usageLine(String model, String upstream, int p, int c, bool err) {
    try {
      _usageSink ??= _openUsageFile();
      _usageSink?.writeln(jsonEncode({
        'ts': DateTime.now().toIso8601String(),
        'model': model,
        'upstream': upstream,
        'prompt': p,
        'completion': c,
        'error': err,
      }));
    } catch (_) {}
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
