import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 模型能力元数据来源：models.dev 目录（OpenCode/Zen 官方数据的聚合源）。
/// 上游 /v1/models 不返回能力字段时由此补充；启动异步拉取、每日刷新、
/// 磁盘缓存离线兜底。按 owned_by 匹配 provider，未命中不编造。
class ModelsDev {
  static final ModelsDev instance = ModelsDev._();
  ModelsDev._();

  Map<String, Map<String, dynamic>> _byProvider = {};
  DateTime? _fetchedAt;
  Timer? _timer;

  /// 目录数据成功刷新后的回调（service 借此让供应商重探以更新能力信息）
  void Function()? onUpdated;

  static File _cacheFile() {
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']!
        : '${Platform.environment['HOME']}/.config';
    return File('$base/zeroapi/modelsdev-cache.json');
  }

  Future<void> start() async {
    _loadCache();
    unawaited(refresh());
    _timer ??=
        Timer.periodic(const Duration(hours: 24), (_) => unawaited(refresh()));
  }

  void stop() => _timer?.cancel();

  void _loadCache() {
    try {
      final f = _cacheFile();
      if (!f.existsSync()) return;
      final j = jsonDecode(f.readAsStringSync());
      if (j is Map<String, dynamic>) {
        _byProvider = (j['providers'] as Map?)?.map(
              (k, v) => MapEntry(
                  k as String, (v['models'] as Map?)?.map((mid, m) =>
                          MapEntry(mid as String, m as Map<String, dynamic>)) ??
                      {}),
            ) ??
            {};
        final at = j['fetchedAt'] as String?;
        if (at != null) _fetchedAt = DateTime.tryParse(at);
      }
    } catch (_) {}
  }

  Future<void> refresh() async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(Uri.parse('https://models.dev/api.json'));
      final resp = await req.close().timeout(const Duration(seconds: 30));
      final body = await resp.transform(utf8.decoder).join();
      client.close(force: true);
      final j = jsonDecode(body) as Map<String, dynamic>;
      _byProvider = {
        for (final e in j.entries)
          if (e.value is Map<String, dynamic> && (e.value['models'] is Map))
            e.key: (e.value['models'] as Map).map(
                (id, m) => MapEntry(id as String, m as Map<String, dynamic>)),
      };
      _fetchedAt = DateTime.now();
      try {
        _cacheFile().writeAsStringSync(jsonEncode({
          'fetchedAt': _fetchedAt!.toIso8601String(),
          'providers': _byProvider,
        }));
      } catch (_) {}
      onUpdated?.call();
    } catch (_) {
      // 拉取失败继续用缓存，不阻塞
    }
  }

  DateTime? get fetchedAt => _fetchedAt;

  /// 按上游 owned_by/provider 名与模型 id 查找能力元数据；查不到返回 null
  Map<String, dynamic>? lookup(String? ownedBy, String modelId) {
    if (ownedBy == null || ownedBy.isEmpty) return null;
    return _byProvider[ownedBy.toLowerCase()]?[modelId]
        // zen 模型即 opencode 目录，兜底再试一次
        ?? _byProvider['opencode']?[modelId.replaceFirst(RegExp(r'^opencode/'), '')];
  }
}

/// 归一化后的模型能力信息，供 UI 与 /v1/models 输出
class ModelInfo {
  final int? contextWindow;
  final int? maxOutputTokens;
  final List<String> inputModalities; // text/image/audio/video/pdf
  final bool reasoning;
  final bool toolCall;
  final bool structuredOutput;
  final bool free;
  final String? displayName;
  final String? releasedAt;

  const ModelInfo({
    this.contextWindow,
    this.maxOutputTokens,
    this.inputModalities = const ['text'],
    this.reasoning = false,
    this.toolCall = false,
    this.structuredOutput = false,
    this.free = false,
    this.displayName,
    this.releasedAt,
  });

  static ModelInfo fromMaps(
      Map<String, dynamic> upstreamEntry, Map<String, dynamic>? catalog) {
    // 上游条目若原生携带这些字段则优先（“按上游信息及时更新”的第一来源）
    final src = <String, dynamic>{...?catalog, ..._flattenUpstream(upstreamEntry)};
    final limit = src['limit'] as Map<String, dynamic>?;
    final modal = src['modalities'] as Map<String, dynamic>?;
    final input = (modal?['input'] as List?)?.whereType<String>().toList();
    final cost = src['cost'] as Map<String, dynamic>?;
    return ModelInfo(
      contextWindow: (src['context_window'] ?? limit?['context']) as int?,
      maxOutputTokens:
          (src['max_output_tokens'] ?? src['max_tokens'] ?? limit?['output']) as int?,
      inputModalities: (input == null || input.isEmpty) ? const ['text'] : input,
      reasoning: (src['reasoning'] ?? false) as bool,
      toolCall: (src['tool_call'] ?? src['function_calling'] ?? false) as bool,
      structuredOutput: (src['structured_output'] ?? false) as bool,
      free: cost != null &&
          (cost['input'] as num? ?? 0) == 0 &&
          (cost['output'] as num? ?? 0) == 0,
      displayName: src['name'] as String?,
      releasedAt: (src['release_date'] ?? src['last_updated']) as String?,
    );
  }

  static Map<String, dynamic> _flattenUpstream(Map<String, dynamic> e) => {
        if (e['context_window'] != null) 'context_window': e['context_window'],
        if (e['max_output_tokens'] != null)
          'max_output_tokens': e['max_output_tokens'],
        if (e['supported_input_types'] != null)
          'modalities': {'input': (e['supported_input_types'] as List?) ?? []},
        if (e['capabilities'] != null) ..._flattenCaps(e['capabilities']),
        if (e['release_date'] != null) 'release_date': e['release_date'],
        if (e['name'] != null && e['name'] != e['id']) 'name': e['name'],
      };

  static Map<String, dynamic> _flattenCaps(dynamic caps) {
    if (caps is! Map) return const {};
    final c = caps.cast<String, dynamic>();
    return {
      if (c['reasoning'] != null) 'reasoning': c['reasoning'],
      if (c['tool_call'] != null) 'tool_call': c['tool_call'],
      if (c['tools'] != null) 'tool_call': c['tools'],
      if (c['structured_output'] != null) 'structured_output': c['structured_output'],
    };
  }

  Map<String, dynamic> toJson() => {
        if (contextWindow != null) 'context_window': contextWindow,
        if (maxOutputTokens != null) 'max_output_tokens': maxOutputTokens,
        'input_modalities': inputModalities,
        'reasoning': reasoning,
        'tool_call': toolCall,
        'structured_output': structuredOutput,
        'free': free,
        if (displayName != null) 'display_name': displayName,
        if (releasedAt != null) 'release_date': releasedAt,
      };
}
