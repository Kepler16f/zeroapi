import 'openrouter_pricing.dart';
import 'response_records.dart';
import 'wbdata.dart';

/// 一条响应记录的成本（人民币元）。
class RecordCost {
  final double? cny;

  /// 计价来源，用于界面说明「这个数从哪来」。
  final CostSource source;

  const RecordCost(this.cny, this.source);
}

enum CostSource {
  /// 号池自己记的账（上游实际扣费）。
  hubCredit,

  /// 号池本地价表估算（OpenRouter 价 × 汇率）。
  hubTable,

  /// OpenRouter 公开价目估算。
  openRouter,

  /// 免费档模型，成本记 0。
  freeTier,

  /// 找不到价目。
  unknown,
}

/// 成本估算器：全部以人民币输出。
///
/// 价目有两个来源，都以 OpenRouter 公开价为准：
///   * 号池随包的 `pricing.json`（本地化的 OpenRouter 价表，含汇率与
///     条件档），覆盖号池模型，并带号池自己的实际扣费；
///   * 本地缓存的 OpenRouter 目录（见 [OpenRouterPricing]），覆盖其余供应商。
///
/// 两者口径一致：OpenRouter 的价是「每 token 美元」，乘以同一张表的
/// `usd_cny` 汇率得到人民币。
class CostEstimator {
  CostEstimator({
    required this.hubPricing,
    required this.openRouter,
  });

  final WbPricing hubPricing;
  final OpenRouterPricing openRouter;

  /// 美元兑人民币。优先取号池本地价表里的汇率（与号池自身计费口径一致）。
  double get usdCny {
    final rate = hubPricing.usdCny;
    if (rate > 0) return rate;
    return _fallbackUsdCny;
  }

  static const double _fallbackUsdCny = 7.1;

  /// OpenRouter 目录的本地更新时间（null = 还没拿到过目录）。
  DateTime? get catalogUpdatedAt => openRouter.fetchedAt;

  /// 单条记录的成本。
  RecordCost estimate(ResponseRecord r) {
    // 号池自己记的账最准：上游实际扣了多少就是多少。
    if (r.costCny != null) return RecordCost(r.costCny, CostSource.hubCredit);

    final input = r.input ?? 0;
    final output = r.output ?? 0;
    final cached = r.cached ?? 0;

    // Zen 免费档：模型名带 -free 或 big-pickle，成本就是 0，不该按付费价算。
    if (_isFreeTier(r.model)) {
      return RecordCost(0, CostSource.freeTier);
    }

    // 号池本地价表（OpenRouter 价的本地化版本，含条件档）。
    final hubCost = hubPricing.costCny(
      r.model,
      input: input,
      output: output,
      cached: cached,
    );
    if (hubCost != null) return RecordCost(hubCost, CostSource.hubTable);

    // 其余供应商：OpenRouter 公开价目 × 汇率。
    final estimate = openRouter.estimate(
      r.model,
      promptTokens: input,
      completionTokens: output,
      cachedPromptTokens: cached,
      cachedPromptWriteTokens: r.cacheWrite ?? 0,
    );
    final usd = estimate.usd;
    if (usd == null) return RecordCost(null, CostSource.unknown);
    return RecordCost(usd * usdCny, CostSource.openRouter);
  }

  /// 一批记录的成本合计。
  CostSummary summarize(List<ResponseRecord> records) {
    var total = 0.0;
    var priced = 0;
    var unpriced = 0;
    var free = 0;
    var hub = 0.0;
    var openRouter = 0.0;
    for (final r in records) {
      final c = estimate(r);
      switch (c.source) {
        case CostSource.unknown:
          unpriced++;
        case CostSource.freeTier:
          free++;
          priced++;
        case CostSource.hubCredit:
        case CostSource.hubTable:
          hub += c.cny ?? 0;
          priced++;
        case CostSource.openRouter:
          openRouter += c.cny ?? 0;
          priced++;
      }
    }
    total = hub + openRouter;
    return CostSummary(
      cny: total,
      priced: priced,
      unpriced: unpriced,
      free: free,
      hubCny: hub,
      openRouterCny: openRouter,
      usdCny: usdCny,
    );
  }

  /// 免费档判定：Zen 免费模型（*-free 与 big-pickle）。
  static bool _isFreeTier(String model) {
    final m = model.trim().toLowerCase();
    final bare = m.contains('/') ? m.substring(m.lastIndexOf('/') + 1) : m;
    return bare.endsWith('-free') || bare == 'big-pickle';
  }
}

/// 成本汇总。
class CostSummary {
  const CostSummary({
    required this.cny,
    required this.priced,
    required this.unpriced,
    required this.free,
    required this.hubCny,
    required this.openRouterCny,
    required this.usdCny,
  });

  /// 合计（人民币元）。
  final double cny;

  /// 有价记录数（含免费档）。
  final int priced;

  /// 没有价目的记录数。
  final int unpriced;

  /// 免费档记录数。
  final int free;

  /// 号池部分（人民币）。
  final double hubCny;

  /// OpenRouter 价目部分（人民币）。
  final double openRouterCny;

  /// 使用的美元兑人民币汇率。
  final double usdCny;
}
