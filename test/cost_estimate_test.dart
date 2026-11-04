import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/cost_estimate.dart';
import 'package:zeroapi/gateway/openrouter_pricing.dart';
import 'package:zeroapi/gateway/response_records.dart';
import 'package:zeroapi/gateway/wbdata.dart';

ResponseRecord _row(
  String model, {
  String provider = 'zen',
  int input = 1000,
  int output = 100,
  int cached = 0,
  double? costCny,
}) =>
    ResponseRecord(
      time: DateTime(2026),
      model: model,
      provider: provider,
      source: '网关',
      input: input,
      output: output,
      cached: cached,
      costCny: costCny,
    );

void main() {
  test('号池实际扣费优先，成本已是人民币', () {
    final estimator = CostEstimator(
      hubPricing: const WbPricing(usdCny: 7.1, models: {}),
      openRouter: OpenRouterPricing(),
    );
    final cost = estimator.estimate(_row('any-model', costCny: 1.23));
    expect(cost.cny, 1.23);
    expect(cost.source, CostSource.hubCredit);
  });

  test('OpenRouter 价目按汇率折算成人民币', () {
    final openRouter = OpenRouterPricing();
    // 每百万 token 1 美元 → 每 token 1e-6 美元
    openRouter.debugSetPrices({
      'vendor/model-x': const ModelTokenPrice(
        prompt: 0.000001,
        completion: 0.000002,
      ),
    });
    final estimator = CostEstimator(
      hubPricing: const WbPricing(usdCny: 7.1, models: {}),
      openRouter: openRouter,
    );
    final cost = estimator.estimate(_row('model-x', input: 1000, output: 100));
    expect(cost.source, CostSource.openRouter);
    // 1000 * 1e-6 + 100 * 2e-6 = 0.0012 美元 → 0.00852 元
    expect(cost.cny, closeTo(0.0012 * 7.1, 1e-9));
  });

  test('免费档模型按 0 计，不套用付费价', () {
    final estimator = CostEstimator(
      hubPricing: const WbPricing(usdCny: 7.1, models: {}),
      openRouter: OpenRouterPricing(),
    );
    expect(
      estimator.estimate(_row('zen/big-pickle')).source,
      CostSource.freeTier,
    );
    expect(
      estimator.estimate(_row('deepseek-v4.1-flash-free')).source,
      CostSource.freeTier,
    );
  });

  test('未知模型记为无价目，汇总里单独计数', () {
    final estimator = CostEstimator(
      hubPricing: const WbPricing(usdCny: 7.1, models: {}),
      openRouter: OpenRouterPricing(),
    );
    final summary = estimator.summarize([
      _row('never-heard-of-it'),
      _row('zen/big-pickle'),
    ]);
    expect(summary.unpriced, 1);
    expect(summary.free, 1);
    expect(summary.priced, 1);
    expect(summary.cny, 0);
  });

  test('号池本地价表命中时按价表折算人民币', () {
    final estimator = CostEstimator(
      hubPricing: WbPricing(
        usdCny: 7.1,
        models: const {
          'hy3': WbModelPrice(
            display: 'Hy3',
            orId: 'vendor/hy3',
            unit: 1000000,
            inputCacheHit: 0.000001,
            inputCacheMiss: 0.002,
            output: 0.006,
          ),
        },
      ),
      openRouter: OpenRouterPricing(),
    );
    final cost = estimator.estimate(
      _row('hy3', provider: 'WorkBuddy', input: 1000000, output: 1000000),
    );
    expect(cost.source, CostSource.hubTable);
    expect(cost.cny, closeTo((0.002 + 0.006) * 7.1, 1e-9));
  });
}
