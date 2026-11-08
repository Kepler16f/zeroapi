// 三级通路状态机回归（2026-11-07，用户指定顺序）：
// Worker（CF 边缘 IP，同节点重连）→ 机场节点 → 直连。
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/zen_egress_plan.dart';

void main() {
  test('额度耗尽：Worker 档先重连换 CF IP（预算 2 次）', () {
    final plan = ZenEgressPlan();
    expect(
      plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
      ZenEgressAction.workerReconnect,
    );
    expect(
      plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
      ZenEgressAction.workerReconnect,
      reason: '第二次重连 = 再换一个 CF 边缘 IP',
    );
    // Worker 预算用尽 → 机场档
    expect(
      plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
      ZenEgressAction.airportNext,
    );
  });

  test('传输失败：Worker 档直接降机场档（同节点重连到不了 workers.dev）', () {
    final plan = ZenEgressPlan();
    expect(
      plan.next(lastFailureKind: 'transport', airportHasCandidate: true),
      ZenEgressAction.airportNext,
      reason: '节点连 workers.dev 都不通，同节点重连无意义',
    );
  });

  test('机场档额度耗尽：节点冷却并换下一个，3 次后降直连', () {
    final plan = ZenEgressPlan();
    plan.next(lastFailureKind: 'quota', airportHasCandidate: true); // worker#1
    plan.next(lastFailureKind: 'quota', airportHasCandidate: true); // worker#2
    plan.next(lastFailureKind: 'quota', airportHasCandidate: true); // airport#1
    expect(plan.tier, ZenEgressTier.airport);
    expect(
      plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
      ZenEgressAction.airportNext,
    );
    expect(
      plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
      ZenEgressAction.airportNext,
    );
    // 机场 3 次用尽 → 直连
    expect(
      plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
      ZenEgressAction.direct,
    );
    expect(plan.tier, ZenEgressTier.direct);
  });

  test('直连额度耗尽：三档全部耗尽 → exhausted', () {
    final plan = ZenEgressPlan();
    plan.next(lastFailureKind: 'quota', airportHasCandidate: true);
    plan.next(lastFailureKind: 'quota', airportHasCandidate: true);
    plan.next(lastFailureKind: 'quota', airportHasCandidate: true);
    plan.next(lastFailureKind: 'quota', airportHasCandidate: true);
    plan.next(lastFailureKind: 'quota', airportHasCandidate: true);
    expect(
      plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
      ZenEgressAction.direct,
    );
    expect(
      plan.next(lastFailureKind: 'quota', airportHasCandidate: false),
      ZenEgressAction.exhausted,
      reason: '直连也烧穿 = 全部桶耗尽',
    );
  });

  test('机场无候选（全冷却）：Worker 烧完预算后跳过机场档直达直连', () {
    final plan = ZenEgressPlan();
    // Worker 重连与机场候选无关：CF IP 桶独立于机场节点
    expect(
      plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
      ZenEgressAction.workerReconnect,
    );
    expect(
      plan.next(lastFailureKind: 'quota', airportHasCandidate: false),
      ZenEgressAction.workerReconnect,
      reason: '第 2 次重连 = 再换一个 CF 边缘 IP',
    );
    // Worker 预算用尽 → 机场档无候选 → 跳过 → 直连
    expect(
      plan.next(lastFailureKind: 'quota', airportHasCandidate: false),
      ZenEgressAction.direct,
    );
  });

  test('直连不可用（家宽也挂）：Worker 烧完预算后直接 exhausted', () {
    final plan = ZenEgressPlan();
    plan.next(
      lastFailureKind: 'quota',
      airportHasCandidate: false,
      directUsable: false,
    );
    expect(
      plan.next(
        lastFailureKind: 'quota',
        airportHasCandidate: false,
        directUsable: false,
      ),
      ZenEgressAction.workerReconnect,
    );
    expect(
      plan.next(
        lastFailureKind: 'quota',
        airportHasCandidate: false,
        directUsable: false,
      ),
      ZenEgressAction.exhausted,
      reason: 'Worker 预算用尽 + 机场无候选 + 直连不可用 = 全部桶耗尽',
    );
  });

  group('档位冷却（挂死后不再从死档起步）', () {
    test('Worker 档在冷却中 → 本轮直接从机场档起步', () {
      final plan = ZenEgressPlan(
        skipTiers: {ZenEgressTier.worker},
      );
      expect(plan.tier, ZenEgressTier.airport);
      expect(
        plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
        ZenEgressAction.airportNext,
        reason: '跳过挂死的 Worker 档，直接换机场节点',
      );
    });

    test('冷却中的 Worker 档遇到额度失败也不重连（省 90s 看门狗）', () {
      final plan = ZenEgressPlan(skipTiers: {ZenEgressTier.worker});
      expect(
        plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
        ZenEgressAction.airportNext,
      );
    });

    test('机场档在冷却中 → 直接降直连档', () {
      final plan = ZenEgressPlan(skipTiers: {ZenEgressTier.airport});
      // 构造到机场档：先让 Worker 走完额度预算
      plan.next(lastFailureKind: 'quota', airportHasCandidate: true);
      plan.next(lastFailureKind: 'quota', airportHasCandidate: true);
      expect(
        plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
        ZenEgressAction.direct,
        reason: '机场档挂死 → 不再试机场节点，直接直连',
      );
    });

    test('未冷却时行为不变（默认档仍是 Worker）', () {
      final plan = ZenEgressPlan();
      expect(plan.tier, ZenEgressTier.worker);
      expect(
        plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
        ZenEgressAction.workerReconnect,
      );
    });

    test('从上次成功的档起步（省掉前面已烧穿的档）', () {
      // 装机态实测（2026-11-08）：Worker×2 + 机场×3 全是额度耗尽（每个
      // 12-15s），走完 6 个出口才轮到直连档成功 → 每请求 90s；从上次
      // 成功的档起步则只要 2s。
      final plan = ZenEgressPlan(startTier: ZenEgressTier.direct);
      expect(plan.tier, ZenEgressTier.direct);
      expect(
        plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
        ZenEgressAction.direct,
        reason: '直连档起步时先试直连',
      );
      expect(
        plan.next(lastFailureKind: 'quota', airportHasCandidate: true),
        ZenEgressAction.exhausted,
        reason: '直连也失败 = 全部桶耗尽',
      );
    });

    test('起步档在冷却中 → 回落到默认顺序', () {
      final plan = ZenEgressPlan(
        startTier: ZenEgressTier.worker,
        skipTiers: {ZenEgressTier.worker},
      );
      expect(plan.tier, ZenEgressTier.airport);
    });
  });
}
