import 'dart:io';

import 'wbdata.dart';

/// WorkBuddy 号池的「账号 / 额度 / 成本」只读数据层。
///
/// 在 [wbdata.dart] 的底层解析（WbData.readPool / readPricing / readUsage）之上
/// 做一层 UI 友好的归一化：账号字段拍平成展示视图，池与用量聚合成一个
/// [WbOverview]，供「账号」页与看板直接渲染，不必各自重复聚合逻辑。
///
/// 约定与 wbdata 一致：只读、不抛异常、坏数据跳过、读不到给空值。
/// [AccountData.load] 唯一会返回 null 的情形是账号目录不存在（没有号池就没有
/// 数据可展示）；usage / pricing 缺失只降级成空统计与空价表，不影响返回。

/// 单个账号的展示视图（从 WbAccount 派生的只读投影）
class WbAccountView {
  const WbAccountView({
    required this.uid,
    required this.nickname,
    required this.realm,
    required this.enabled,
    required this.restricted,
    required this.platform,
    required this.note,
    required this.creditsRemain,
    required this.creditsSize,
    required this.planName,
    required this.expiresAt,
    required this.lastCheckin,
  });

  final String uid;
  final String nickname;

  /// 'cn' | 'intl' | ''
  final String realm;
  final bool enabled;

  /// 熔断中（restrictedUntil 晚于当前时刻）
  final bool restricted;
  final String platform;
  final String note;

  /// credits 缺失时按 0 计
  final double creditsRemain;
  final double creditsSize;

  /// 最快到期的额度包名（credits.earliest_expiring.name），无则空串
  final String planName;

  /// 访问令牌过期时间；缺失为 null
  final DateTime? expiresAt;

  /// 上次签到时间；缺失为空串
  final String lastCheckin;

  /// 可参与轮换：启用且不在熔断期
  bool get ready => enabled && !restricted;
}

/// 号池总览：账号列表 + 池聚合 + 今日/累计用量与成本
class WbOverview {
  WbOverview({
    required this.accounts,
    required this.total,
    required this.ready,
    required this.cnCount,
    required this.intlCount,
    required this.totalRemain,
    required this.totalUsed,
    required this.checkedInToday,
    required this.today,
    required this.overall,
    required this.costCnyToday,
    required this.loadedAt,
  });

  final List<WbAccountView> accounts;

  /// 账号总数（含被禁用 / 熔断的）
  final int total;

  /// 可参与轮换的账号数（enabled 且未熔断）
  final int ready;
  final int cnCount;
  final int intlCount;

  /// enabled 账号的剩余额度 / 已用额度合计
  final double totalRemain;
  final double totalUsed;

  /// 今日已签到账号数
  final int checkedInToday;

  /// 今日用量（sinceDays: 1，含今天）
  final WbUsageStats today;

  /// 累计用量（不限天数）
  final WbUsageStats overall;

  /// 今日实际入账成本（人民币元），= today.costCnySum
  final double costCnyToday;

  /// 本次加载时刻
  final DateTime loadedAt;
}

/// 号池数据读取入口
class AccountData {
  AccountData._();

  /// 读取账号池与用量，聚合成一个 [WbOverview]。
  ///
  /// [accountsDir] 不存在时返回 null（无号池可展示）。其余路径缺失只降级：
  /// usage 缺失给空统计，pricing 缺失给空价表（成本按 0 计）。任何解析异常
  /// 都被吞掉并返回 null，调用方不需要 try/catch。
  static Future<WbOverview?> load({
    required String accountsDir,
    required String usageDir,
    required String pricingPath,
  }) async {
    if (!Directory(accountsDir).existsSync()) return null;
    try {
      final pool = await WbData.readPool(accountsDir);
      final pricing = await WbData.readPricing(pricingPath);
      final today = await WbData.readUsage(
        usageDir,
        sinceDays: 1,
        pricing: pricing,
      );
      final overall = await WbData.readUsage(usageDir, pricing: pricing);
      final accounts = [for (final a in pool.accounts) _view(a)];
      return WbOverview(
        accounts: accounts,
        total: accounts.length,
        ready: accounts.where((v) => v.ready).length,
        cnCount: pool.cnCount,
        intlCount: pool.intlCount,
        totalRemain: pool.totalRemain,
        totalUsed: pool.totalUsed,
        checkedInToday: pool.checkedInToday,
        today: today,
        overall: overall,
        costCnyToday: today.costCnySum,
        loadedAt: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  /// WbAccount → WbAccountView 的字段归一化
  static WbAccountView _view(WbAccount a) {
    final c = a.credits;
    return WbAccountView(
      uid: a.uid,
      nickname: a.nickname,
      realm: a.realm,
      enabled: a.enabled,
      restricted: a.isRestricted,
      platform: a.platform,
      note: a.note,
      creditsRemain: c?.remain ?? 0,
      creditsSize: c?.size ?? 0,
      planName: c?.earliestExpiring?.name ?? '',
      expiresAt: a.expiresAt,
      lastCheckin: a.lastCheckin ?? '',
    );
  }
}
