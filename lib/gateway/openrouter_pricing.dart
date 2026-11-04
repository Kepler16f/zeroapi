import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'model_identity.dart';

/// OpenRouter public catalog pricing. Prices are USD per token.
class OpenRouterPricing {
  OpenRouterPricing({
    HttpClient? httpClient,
    File? cacheFile,
    Uri? catalog,
    this._requestTimeout = const Duration(seconds: 30),
    this._responseTimeout = const Duration(seconds: 30),
  })
    : _httpClient = httpClient ?? HttpClient(),
      _cacheFileOverride = cacheFile,
      _catalog = catalog ?? Uri.parse(catalogUri);

  static final OpenRouterPricing instance = OpenRouterPricing();
  static const catalogUri = 'https://openrouter.ai/api/v1/models';

  final HttpClient _httpClient;
  final File? _cacheFileOverride;
  final Uri _catalog;
  final Duration _requestTimeout;
  final Duration _responseTimeout;
  Map<String, ModelTokenPrice> _prices = {};
  DateTime? fetchedAt;

  /// 仅测试用：直接注入价目，避免测试依赖网络。
  void debugSetPrices(Map<String, ModelTokenPrice> prices) {
    _prices = {...prices};
    fetchedAt = DateTime.now();
  }

  /// 本地目录是否已过期（默认 24 小时）。价格目录本地化后离线可用，
  /// 过期只影响新鲜度，不影响估算。
  static const Duration freshness = Duration(hours: 24);

  /// 目录是否需要刷新（没有缓存，或缓存已过期）。
  bool get isStale {
    final at = fetchedAt;
    if (at == null) return true;
    return DateTime.now().difference(at) > freshness;
  }

  /// 加载本地缓存；过期时顺带刷新一次（失败仍用缓存）。
  Future<void> ensureFresh() async {
    await loadCache();
    if (isStale) await refresh();
  }

  static File defaultCacheFile() {
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']
        : Platform.environment['HOME'];
    final root = base ?? Directory.systemTemp.path;
    return File(Platform.isWindows
        ? '$root/zeroapi/openrouter-pricing-cache.json'
        : '$root/.config/zeroapi/openrouter-pricing-cache.json');
  }

  Future<bool> loadCache() async {
    try {
      final file = _cacheFileOverride ?? defaultCacheFile();
      if (!await file.exists()) return false;
      final decoded = jsonDecode(await file.readAsString()) as Map;
      final entries = decoded['models'] as Map?;
      if (entries == null) return false;
      _prices = {
        for (final entry in entries.entries)
          if (entry.key is String && entry.value is Map)
            entry.key as String: ModelTokenPrice.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            ),
      };
      fetchedAt = DateTime.tryParse(decoded['fetchedAt']?.toString() ?? '');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Refreshes from the public, unauthenticated catalog. On failure cached data
  /// remains available and false is returned.
  Future<bool> refresh() async {
    try {
      final request = await _httpClient
          .getUrl(_catalog)
          .timeout(_requestTimeout);
      final response = await request.close().timeout(_responseTimeout);
      if (response.statusCode != HttpStatus.ok) return false;
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_responseTimeout);
      final root = jsonDecode(body) as Map;
      final data = root['data'] as List;
      final next = <String, ModelTokenPrice>{};
      for (final item in data) {
        if (item is! Map || item['id'] is! String || item['pricing'] is! Map) {
          continue;
        }
        next[(item['id'] as String).toLowerCase()] =
            ModelTokenPrice.fromJson(Map<String, dynamic>.from(item['pricing'] as Map));
      }
      _prices = next;
      fetchedAt = DateTime.now();
      try {
        final file = _cacheFileOverride ?? defaultCacheFile();
        await file.parent.create(recursive: true);
        await file.writeAsString(jsonEncode({
          'fetchedAt': fetchedAt!.toIso8601String(),
          'models': {for (final e in _prices.entries) e.key: e.value.toJson()},
        }));
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Exact full-ID lookup first; then exact normalized model identity.
  ModelTokenPrice? priceFor(String modelId) {
    final fullId = modelId.trim().toLowerCase();
    final exact = _prices[fullId];
    if (exact != null) return exact;
    final identity = ModelIdentity.normalize(modelId);
    final matches = _prices.entries.where(
      (e) => ModelIdentity.normalize(e.key) == identity,
    ).toList();
    // Ambiguous providers are unknown. Never pick a convenient fuzzy match.
    return matches.length == 1 ? matches.single.value : null;
  }

  PricingEstimate estimate(
    String modelId, {
    required int promptTokens,
    required int completionTokens,
    int cachedPromptTokens = 0,
    int cachedCompletionTokens = 0,
    int cachedPromptWriteTokens = 0,
    int cachedCompletionWriteTokens = 0,
  }) {
    final price = priceFor(modelId);
    if (price == null) return PricingEstimate.unknown(modelId);
    final totalPrompt = promptTokens < 0 ? 0 : promptTokens;
    final totalCompletion = completionTokens < 0 ? 0 : completionTokens;
    final cachedPromptRead = cachedPromptTokens.clamp(0, totalPrompt);
    final cachedPromptWrite = cachedPromptWriteTokens.clamp(
      0,
      totalPrompt - cachedPromptRead,
    );
    final cachedCompletionRead = cachedCompletionTokens.clamp(
      0,
      totalCompletion,
    );
    final cachedCompletionWrite = cachedCompletionWriteTokens.clamp(
      0,
      totalCompletion - cachedCompletionRead,
    );
    final uncachedPrompt = totalPrompt - cachedPromptRead - cachedPromptWrite;
    final uncachedCompletion =
        totalCompletion - cachedCompletionRead - cachedCompletionWrite;
    final missingInput = (uncachedPrompt > 0 && price.prompt == null) ||
        (cachedPromptRead > 0 && price.inputCacheRead == null) ||
        (cachedPromptWrite > 0 && price.inputCacheWrite == null);
    final missingOutput = (uncachedCompletion > 0 && price.completion == null) ||
        (cachedCompletionRead > 0 && price.outputCacheRead == null) ||
        (cachedCompletionWrite > 0 && price.outputCacheWrite == null);
    // When a cache-specific rate is absent, use the regular token rate as a
    // non-discounting estimate and mark it partial. Never silently treat cache
    // usage as free.
    final hasInputPrice =
        (uncachedPrompt == 0 || price.prompt != null) &&
        (cachedPromptRead == 0 ||
            price.inputCacheRead != null ||
            price.prompt != null) &&
        (cachedPromptWrite == 0 ||
            price.inputCacheWrite != null ||
            price.prompt != null);
    final hasOutputPrice =
        (uncachedCompletion == 0 || price.completion != null) &&
        (cachedCompletionRead == 0 ||
            price.outputCacheRead != null ||
            price.completion != null) &&
        (cachedCompletionWrite == 0 ||
            price.outputCacheWrite != null ||
            price.completion != null);
    final inputCost = hasInputPrice
        ? (price.prompt == null ? 0.0 : uncachedPrompt * price.prompt!) +
              cachedPromptRead *
                  (price.inputCacheRead ?? price.prompt ?? 0.0) +
              cachedPromptWrite *
                  (price.inputCacheWrite ?? price.prompt ?? 0.0)
        : null;
    final outputCost = hasOutputPrice
        ? (price.completion == null
                  ? 0.0
                  : uncachedCompletion * price.completion!) +
              cachedCompletionRead *
                  (price.outputCacheRead ?? price.completion ?? 0.0) +
              cachedCompletionWrite *
                  (price.outputCacheWrite ?? price.completion ?? 0.0)
        : null;
    return PricingEstimate(
      modelId: modelId,
      usd: inputCost == null && outputCost == null
          ? null
          : (inputCost ?? 0.0) + (outputCost ?? 0.0),
      isPartial: missingInput || missingOutput ||
          inputCost == null || outputCost == null,
    );
  }
}

class ModelTokenPrice {
  const ModelTokenPrice({this.prompt, this.completion, this.inputCacheRead,
    this.inputCacheWrite, this.outputCacheRead, this.outputCacheWrite});
  final double? prompt;
  final double? completion;
  final double? inputCacheRead;
  final double? inputCacheWrite;
  final double? outputCacheRead;
  final double? outputCacheWrite;

  factory ModelTokenPrice.fromJson(Map<String, dynamic> json) => ModelTokenPrice(
    prompt: _number(json['prompt']), completion: _number(json['completion']),
    inputCacheRead: _number(json['input_cache_read'] ?? json['cache_read']),
    inputCacheWrite: _number(json['input_cache_write'] ?? json['cache_write']),
    outputCacheRead: _number(json['output_cache_read']),
    outputCacheWrite: _number(json['output_cache_write']),
  );

  Map<String, Object?> toJson() => {
    'prompt': prompt?.toString(), 'completion': completion?.toString(),
    'input_cache_read': inputCacheRead?.toString(),
    'input_cache_write': inputCacheWrite?.toString(),
    'output_cache_read': outputCacheRead?.toString(),
    'output_cache_write': outputCacheWrite?.toString(),
  };

  static double? _number(Object? value) {
    if (value == null) return null;
    final parsed = double.tryParse(value.toString());
    return parsed != null && parsed.isFinite && parsed >= 0 ? parsed : null;
  }
}

class PricingEstimate {
  const PricingEstimate({required this.modelId, required this.usd,
    required this.isPartial, this.unknownModel = false});
  final String modelId;
  final double? usd;
  final bool isPartial;
  final bool unknownModel;

  factory PricingEstimate.unknown(String modelId) => PricingEstimate(
    modelId: modelId, usd: null, isPartial: true, unknownModel: true);
}
