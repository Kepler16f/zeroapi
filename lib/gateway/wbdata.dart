import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// WorkBuddy 号池数据的只读解析层。
///
/// vendor 的 workbuddy2api-hub（随包 Python）把数据落到磁盘：
///   * `%APPDATA%\zeroapi\workbuddy\accounts\{uid}.json` —— 单账号 + 额度
///   * `%APPDATA%\zeroapi\workbuddy\usage\activity_history.jsonl` —— 签到/活跃事件
///   * `%APPDATA%\zeroapi\workbuddy\usage\usage.jsonl` —— 请求级用量日志（单文件 append）
///   * `vendor\workbuddy2api-hub\pricing\pricing.json` —— 模型单价表
/// 这里直接读文件供「账号」页面与看板用，不走 HTTP。
///
/// 约定：
///   * 隐私最小化——账号 JSON 里的 accessToken / refreshToken 解析时直接丢弃，
///     本模块不保留、不返回；
///   * 读不到就返回空、坏数据就跳过，不抛异常；
///   * 只读，不写任何文件。特别注意不要动 `usage/usage-recent-index.json`，
///     那是 hub 自己的行偏移缓存，改动会破坏它的索引一致性。
//
// 定价口径与 vendor/workbuddy2api-hub/wb_pricing.py 的 compute_row / band_for
// 对齐，字段单位、bands 选档规则都照那边实现。

/// 签到状态（对应 credits.checkin；intl 账号可能整体为 null）
class WbCheckin {
  final bool todayCheckedIn;
  final int streakDays;
  final int dailyCredit;
  final int todayCredit;
  final bool active;

  const WbCheckin({
    required this.todayCheckedIn,
    required this.streakDays,
    required this.dailyCredit,
    required this.todayCredit,
    required this.active,
  });
}

/// 一个额度包（credits.packages[] / earliest_expiring）
class WbPackage {
  final String name;
  final String unit;
  final double remain;
  final double used;
  final double size;
  final String cycleEndTime;

  /// 剩余天数；`days_left` 缺失（如 no_expiry 的永久包）时为 null
  final double? daysLeft;
  final bool isExpired;
  final bool inUsage;

  const WbPackage({
    required this.name,
    required this.unit,
    required this.remain,
    required this.used,
    required this.size,
    required this.cycleEndTime,
    this.daysLeft,
    required this.isExpired,
    required this.inUsage,
  });
}

/// 账号额度汇总
class WbCredits {
  final double remain;
  final double used;
  final double size;
  final String usedPercent;
  final String remainPercent;
  final bool isPaidUser;

  /// intl 账号常为 null
  final WbCheckin? checkin;
  final WbPackage? earliestExpiring;
  final List<WbPackage> packages;
  final String? updatedIso;

  const WbCredits({
    required this.remain,
    required this.used,
    required this.size,
    required this.usedPercent,
    required this.remainPercent,
    required this.isPaidUser,
    this.checkin,
    this.earliestExpiring,
    this.packages = const [],
    this.updatedIso,
  });
}

/// 一个 WorkBuddy 账号（只读视图）
class WbAccount {
  final String uid;
  final String nickname;

  /// 账号区：'cn'（codebuddy.cn）或 'intl'（workbuddy.ai）
  final String realm;
  final String domain;

  /// 平台标识，如 'CLI' / 'Agent'
  final String platform;
  final String product;
  final String source;
  final String note;

  final bool enabled;
  final int weight;

  /// 熔断截止时间戳（秒，float）；0 表示未熔断
  final double restrictedUntil;

  /// 访问令牌过期时间（秒，float）；缺失为 null
  final double? expiresAtSec;

  final String proxySlot;
  final String proxy;

  final WbCredits? credits;
  final String? lastCheckin;
  final String? lastDailyChat;

  const WbAccount({
    required this.uid,
    required this.nickname,
    required this.realm,
    required this.domain,
    this.platform = '',
    this.product = '',
    this.source = '',
    this.note = '',
    required this.enabled,
    required this.weight,
    required this.restrictedUntil,
    required this.proxySlot,
    required this.proxy,
    this.expiresAtSec,
    this.credits,
    this.lastCheckin,
    this.lastDailyChat,
  });

  /// 令牌过期时间；`expiresAtSec` 缺失时为 null
  DateTime? get expiresAt => expiresAtSec == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch((expiresAtSec! * 1000).round());

  /// 令牌是否已过期
  bool get tokenExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  /// 是否处于熔断期
  bool get isRestricted =>
      restrictedUntil * 1000 > DateTime.now().millisecondsSinceEpoch;
}

/// 账号池聚合视图
class WbPool {
  final List<WbAccount> accounts;

  const WbPool({required this.accounts});

  /// enabled 账号的 remain 求和（credits 缺失按 0 计）
  double get totalRemain => accounts
      .where((a) => a.enabled)
      .fold(0.0, (sum, a) => sum + (a.credits?.remain ?? 0));

  /// enabled 账号的 used 求和
  double get totalUsed => accounts
      .where((a) => a.enabled)
      .fold(0.0, (sum, a) => sum + (a.credits?.used ?? 0));

  /// 今日已签到账号数
  int get checkedInToday =>
      accounts.where((a) => a.credits?.checkin?.todayCheckedIn == true).length;

  int get cnCount => accounts.where((a) => a.realm == 'cn').length;

  int get intlCount => accounts.where((a) => a.realm == 'intl').length;
}

/// activity_history.jsonl 的一条事件
class WbActivity {
  final DateTime ts;
  final String uid;
  final String nickname;
  final String realm;
  final String task;
  final String trigger;
  final String message;
  final bool ok;

  const WbActivity({
    required this.ts,
    required this.uid,
    required this.nickname,
    required this.realm,
    required this.task,
    required this.trigger,
    required this.message,
    required this.ok,
  });
}

/// 一个条件定价档（pricing.json 里 models[].bands 的元素）。
///
/// 每档二选一条件：[minPromptTokens] 输入长度阈值，或 UTC 时段
/// （[days] 星期 + [start]/[end]，分钟口径 0..2400，如 1600 = 16:00）。
class WbPricingBand {
  final double inputCacheHit;
  final double inputCacheMiss;
  final double output;

  /// 输入长度阈值；null 表示这档用的是 UTC 时段条件
  final double? minPromptTokens;

  /// UTC 时段生效的星期，短码（'mon'..'sun'）；空表示不限星期
  final List<String> days;
  final int start;
  final int end;

  const WbPricingBand({
    required this.inputCacheHit,
    required this.inputCacheMiss,
    required this.output,
    this.minPromptTokens,
    this.days = const [],
    this.start = 0,
    this.end = 0,
  });

  bool get hasLengthCondition => minPromptTokens != null;
}

/// 一个模型的单价（美元 / [unit] token，取自 flat 档）
class WbModelPrice {
  final String display;
  final String orId;

  /// 计价单位：每 unit 个 token 的价格，缺省 1000000
  final double unit;

  /// 缺失时为 null，计费时回退 [inputCacheMiss]（与 vendor 一致，估分不会偏低）
  final double? inputCacheHit;
  final double inputCacheMiss;
  final double output;

  /// 条件定价档；按顺序取最后命中的那一档，都不命中回落 flat
  final List<WbPricingBand> bands;

  const WbModelPrice({
    required this.display,
    required this.orId,
    required this.unit,
    required this.inputCacheHit,
    required this.inputCacheMiss,
    required this.output,
    this.bands = const [],
  });
}

/// 定价表
class WbPricing {
  /// 美元兑人民币；折算 CNY 价用
  final double usdCny;
  final Map<String, WbModelPrice> models;

  const WbPricing({required this.usdCny, required this.models});

  WbModelPrice? model(String model) => models[model];

  /// 估算一次请求的美元成本。
  ///
  /// inputCacheMiss 计未缓存输入、inputCacheHit 计 cached 输入、output 计输出；
  /// 分母是该模型的 [WbModelPrice.unit]。模型未收录返回 null。
  ///
  /// 计费规则与 wb_pricing.compute_row 一致：cached 不超过 input；
  /// reasoning_tokens 已含在 completion 里，不重复计。
  double? costUsd(
    String model, {
    required int input,
    required int output,
    int cached = 0,
  }) {
    final m = models[model];
    if (m == null) return null;
    final rate = _ratesFor(m, input);
    // cached 不应超过 input，否则会把未缓存输入算成负数
    final hit = cached.clamp(0, input);
    final miss = input - hit;
    return (rate.miss * miss + rate.hit * hit + rate.output * output) / m.unit;
  }

  /// [costUsd] 按 [usdCny] 折算成人民币
  double? costCny(
    String model, {
    required int input,
    required int output,
    int cached = 0,
  }) {
    final usd = costUsd(model, input: input, output: output, cached: cached);
    return usd == null ? null : usd * usdCny;
  }

  /// 选出本次请求适用的单价表。
  ///
  /// 按顺序遍历 bands 取最后命中的一档，都不命中回落 flat。当前只判断
  /// min_prompt_tokens（输入 token 数即 prompt）；UTC 时段条件（days +
  /// start/end）本次不参与选档——那需要按行的时间戳判断，而 [costUsd] 没有
  /// 时间入参，估出来的会是「当前时刻」的档，对历史记录失真，所以先不算。
  static _Rate _ratesFor(WbModelPrice m, int input) {
    _Rate? picked;
    for (final b in m.bands) {
      if (b.hasLengthCondition && input >= b.minPromptTokens!.round()) {
        picked = _Rate(
          hit: b.inputCacheHit,
          miss: b.inputCacheMiss,
          output: b.output,
        );
      }
    }
    if (picked != null) return picked;
    return _Rate(
      hit: m.inputCacheHit ?? m.inputCacheMiss,
      miss: m.inputCacheMiss,
      output: m.output,
    );
  }
}

/// 一档解析后的单价（inputCacheHit 缺失已回退成 inputCacheMiss）
class _Rate {
  final double hit;
  final double miss;
  final double output;
  const _Rate({required this.hit, required this.miss, required this.output});
}

/// hub 单条请求记录（对应 usage.jsonl 一行）
class WbUsageRow {
  /// 由 `at`（秒）解析；缺失时回退 `iso`
  final DateTime ts;
  final String model;

  /// 客户端别名；无则 null
  final String? requestedModel;

  /// 账号 uid
  final String account;
  final String realm;

  final double prompt;
  final double completion;
  final double cached;
  final double total;

  /// 上游回传的实际扣费（人民币元）；无则 null
  final double? credit;

  /// 本地价表估算成本（人民币元）；价表未命中或 usage_missing 时 null
  final double? costCny;

  final int elapsedMs;
  final int ttftMs;

  /// outcome == 'completed'
  final bool ok;
  final String outcome;
  final bool usageMissing;

  const WbUsageRow({
    required this.ts,
    required this.model,
    required this.account,
    required this.realm,
    required this.prompt,
    required this.completion,
    required this.cached,
    required this.total,
    required this.elapsedMs,
    required this.ttftMs,
    required this.outcome,
    required this.ok,
    required this.usageMissing,
    this.requestedModel,
    this.credit,
    this.costCny,
  });

  /// 该请求实际入账成本：优先上游扣费，没有时用本地估算
  double? get billedCny => credit ?? costCny;
}

/// 请求日志聚合结果：请求数/成功失败/词元/成本/按模型/按账号
class WbUsageStats {
  int requests = 0;
  int errors = 0;
  double promptTokens = 0;
  double completionTokens = 0;
  double cachedTokens = 0;

  /// 上游实际扣费合计（人民币元）
  double creditSum = 0;

  /// 估算成本合计（credit 优先，缺 credit 时本地价表估算）
  double costCnySum = 0;

  /// 有多少条带 credit，用来判断估算的可信度
  int creditKnown = 0;
  final Map<String, int> byModel = {};
  final Map<String, int> byAccount = {};
  final Map<String, int> byRealm = {};
  final Map<String, double> costByModel = {};

  /// 'YYYY-MM-dd' → 请求数（本地时区）
  final Map<String, int> byDay = {};

  /// 'YYYY-MM-dd' → 词元数（本地时区）
  final Map<String, int> tokensByDay = {};

  /// 累加一行
  void add(WbUsageRow r) {
    requests++;
    if (!r.ok) errors++;
    promptTokens += r.prompt;
    completionTokens += r.completion;
    cachedTokens += r.cached;
    if (r.credit != null) {
      creditSum += r.credit!;
      creditKnown++;
    }
    final cost = r.billedCny;
    if (cost != null) {
      costCnySum += cost;
      costByModel[r.model] = (costByModel[r.model] ?? 0) + cost;
    }
    byModel[r.model] = (byModel[r.model] ?? 0) + 1;
    if (r.account.isNotEmpty) {
      byAccount[r.account] = (byAccount[r.account] ?? 0) + 1;
    }
    if (r.realm.isNotEmpty) byRealm[r.realm] = (byRealm[r.realm] ?? 0) + 1;
    final day = WbData._dayKey(r.ts);
    byDay[day] = (byDay[day] ?? 0) + 1;
    tokensByDay[day] = (tokensByDay[day] ?? 0) + r.total.round();
  }
}

/// 文件读取入口：账号池 / 定价表 / 活跃事件 / 请求日志。
class WbData {
  WbData._();

  /// accounts 目录下每个 `{uid}.json` → 一个 [WbAccount]。
  ///
  /// 跳过 vendor 写在同目录的非账号文件（NON_ACCOUNT_FILES）；坏 JSON 跳过。
  /// 目录不存在返回空池，不抛异常。
  static Future<WbPool> readPool(String accountsDir) async {
    final dir = Directory(accountsDir);
    if (!dir.existsSync()) return const WbPool(accounts: []);
    final accounts = <WbAccount>[];
    final entities = await dir.list(followLinks: false).toList();
    for (final e in entities) {
      if (e is! File) continue;
      final name = _basename(e.path);
      if (!name.endsWith('.json') || _skipFiles.contains(name)) continue;
      final a = await _parseAccount(e);
      if (a != null) accounts.add(a);
    }
    // 稳定顺序，避免目录枚举顺序影响界面展示
    accounts.sort((a, b) => a.uid.compareTo(b.uid));
    return WbPool(accounts: accounts);
  }

  /// 解析随包的 pricing.json；文件不存在或坏数据返回空表。
  static Future<WbPricing> readPricing(String pricingJsonPath) async {
    final f = File(pricingJsonPath);
    if (!f.existsSync()) return const WbPricing(usdCny: 0, models: {});
    try {
      final d = jsonDecode(await f.readAsString());
      if (d is! Map) return const WbPricing(usdCny: 0, models: {});
      final j = d.cast<String, dynamic>();
      final meta = j['meta'] is Map
          ? (j['meta'] as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      final usdCny = _d(meta, 'usd_cny');
      final models = <String, WbModelPrice>{};
      if (j['models'] is Map) {
        for (final e in (j['models'] as Map).entries) {
          final m = _modelPrice(e.key as String, e.value);
          if (m != null) models[e.key as String] = m;
        }
      }
      return WbPricing(usdCny: usdCny, models: models);
    } catch (_) {
      return const WbPricing(usdCny: 0, models: {});
    }
  }

  /// 读 usage 目录下的 activity_history.jsonl，按时间倒序取最新 [limit] 条。
  static Future<List<WbActivity>> readActivity(
    String usageDir, {
    int limit = 50,
  }) async {
    final f = File(_join(usageDir, 'activity_history.jsonl'));
    if (!f.existsSync()) return const [];
    final list = <WbActivity>[];
    for (final raw in (await f.readAsString()).split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final a = _parseActivity(line);
      if (a != null) list.add(a);
    }
    list.sort((a, b) => b.ts.compareTo(a.ts));
    return list.length > limit ? list.sublist(0, limit) : list;
  }

  /// 读 hub 自己的请求级用量日志 `usage.jsonl`（单文件尾部 append）。
  ///
  /// [sinceDays] 限制天数（含今天，本地时区），null 表示全部；
  /// [limit] 最多处理多少行（从文件尾部取，默认 5000 行够看板用）；
  /// [pricing] 传入后缺 credit 的行会用本地价表估算成本。
  ///
  /// 只读 `usage.jsonl`；`usage-recent-index.json` 是 hub 的行偏移缓存，不碰。
  static Future<WbUsageStats> readUsage(
    String usageDir, {
    int? sinceDays,
    int? limit,
    WbPricing? pricing,
  }) async {
    final stats = WbUsageStats();
    final f = File(_join(usageDir, 'usage.jsonl'));
    if (!f.existsSync()) return stats;
    final maxLines = limit ?? _defaultUsageLimit;
    final tail = await _tailLines(f, maxLines);
    // 先去掉空行再截尾，否则末尾那个换行符会占掉一个名额、丢掉一条真行
    final lines = tail.where((l) => l.trim().isNotEmpty).toList();
    final picked = lines.length > maxLines
        ? lines.sublist(lines.length - maxLines)
        : lines;
    final cutoff = _sinceCutoff(sinceDays);
    for (final line in picked) {
      final row = _parseUsageRow(line, pricing);
      if (row == null) continue;
      if (cutoff != null && row.ts.isBefore(cutoff)) continue;
      stats.add(row);
    }
    return stats;
  }

  // ---------- 常量 ----------

  /// vendor 写在 accounts 目录里的非账号文件（wb_accounts.NON_ACCOUNT_FILES）
  static const Set<String> _skipFiles = {
    'settings.json',
    'active_realm.json',
    'model_windows.json',
    'quota_scan.json',
    // 老版本的模型能力缓存，同样是混写进来的非账号文件
    'model.json',
  };

  static const int _defaultUsageLimit = 5000;

  /// 文件小于这个体积时整读，否则从尾部按块往前取
  static const int _fullReadBytes = 32 * 1024 * 1024;

  /// 尾部取行时每块 1 MiB
  static const int _chunkSize = 1 << 20;

  // ---------- 解析 ----------

  static Future<WbAccount?> _parseAccount(File f) async {
    Map<String, dynamic>? j;
    try {
      final d = jsonDecode(await f.readAsString());
      if (d is Map) j = d.cast<String, dynamic>();
    } catch (_) {
      return null; // 坏 JSON / 非对象，跳过
    }
    if (j == null) return null;
    final uid = _s(j, 'uid');
    if (uid.isEmpty) return null; // 没有 uid 的不算账号
    return WbAccount(
      uid: uid,
      nickname: _s(j, 'nickname'),
      realm: _s(j, 'realm'),
      domain: _s(j, 'domain'),
      platform: _s(j, 'platform'),
      product: _s(j, 'product'),
      source: _s(j, 'source'),
      note: _s(j, 'note'),
      enabled: _b(j, 'enabled', def: true),
      weight: _i(j, 'weight', def: 1),
      restrictedUntil: _d(j, 'restrictedUntil'),
      proxySlot: _s(j, 'proxySlot'),
      proxy: _s(j, 'proxy'),
      expiresAtSec: _optDouble(j, 'expiresAt', ignoreZero: true),
      credits: _credits(j['credits']),
      // 注意：accessToken / refreshToken 在此丢弃，不进内存
      lastCheckin: _optStr(j, 'lastCheckin'),
      lastDailyChat: _optStr(j, 'lastDailyChat'),
    );
  }

  static WbCredits? _credits(dynamic v) {
    if (v is! Map) return null;
    final m = v.cast<String, dynamic>();
    final packages = <WbPackage>[];
    if (m['packages'] is List) {
      for (final p in m['packages'] as List) {
        final pkg = _package(p);
        if (pkg != null) packages.add(pkg);
      }
    }
    return WbCredits(
      remain: _d(m, 'remain'),
      used: _d(m, 'used'),
      size: _d(m, 'size'),
      usedPercent: _s(m, 'used_percent'),
      remainPercent: _s(m, 'remain_percent'),
      isPaidUser: _b(m, 'is_paid_user'),
      checkin: _checkin(m['checkin']),
      earliestExpiring: _package(m['earliest_expiring']),
      packages: packages,
      updatedIso: _optStr(m, 'updated_iso'),
    );
  }

  static WbCheckin? _checkin(dynamic v) {
    if (v is! Map) return null;
    final m = v.cast<String, dynamic>();
    return WbCheckin(
      todayCheckedIn: _b(m, 'today_checked_in'),
      streakDays: _i(m, 'streak_days'),
      dailyCredit: _i(m, 'daily_credit'),
      todayCredit: _i(m, 'today_credit'),
      active: _b(m, 'active', def: true),
    );
  }

  static WbPackage? _package(dynamic v) {
    if (v is! Map) return null;
    final m = v.cast<String, dynamic>();
    return WbPackage(
      name: _s(m, 'name'),
      unit: _s(m, 'unit'),
      remain: _d(m, 'remain'),
      used: _d(m, 'used'),
      size: _d(m, 'size'),
      cycleEndTime: _s(m, 'cycle_end_time'),
      daysLeft: _optDouble(m, 'days_left'),
      isExpired: _b(m, 'is_expired'),
      inUsage: _b(m, 'in_usage'),
    );
  }

  static WbModelPrice? _modelPrice(String id, dynamic v) {
    if (v is! Map) return null;
    final m = v.cast<String, dynamic>();
    final flat = m['flat'] is Map
        ? (m['flat'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final bands = <WbPricingBand>[];
    if (m['bands'] is List) {
      for (final b in m['bands'] as List) {
        final band = _band(b);
        if (band != null) bands.add(band);
      }
    }
    return WbModelPrice(
      display: _s(m, 'display', def: id),
      orId: _s(m, 'or_id'),
      unit: _d(m, 'unit', def: 1000000),
      inputCacheHit: _optDouble(flat, 'input_cache_hit'),
      inputCacheMiss: _d(flat, 'input_cache_miss'),
      output: _d(flat, 'output'),
      bands: bands,
    );
  }

  static WbPricingBand? _band(dynamic v) {
    if (v is! Map) return null;
    final m = v.cast<String, dynamic>();
    final flat = m['flat'] is Map
        ? (m['flat'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    if (flat.isEmpty) return null;
    return WbPricingBand(
      inputCacheHit: _d(
        flat,
        'input_cache_hit',
        def: _d(flat, 'input_cache_miss'),
      ),
      inputCacheMiss: _d(flat, 'input_cache_miss'),
      output: _d(flat, 'output'),
      minPromptTokens: _optDouble(m, 'min_prompt_tokens'),
      days: (m['days'] as List?)?.whereType<String>().toList() ?? const [],
      start: _i(m, 'start'),
      end: _i(m, 'end'),
    );
  }

  static WbActivity? _parseActivity(String line) {
    dynamic d;
    try {
      d = jsonDecode(line);
    } catch (_) {
      return null; // 坏行跳过
    }
    if (d is! Map) return null;
    final m = d.cast<String, dynamic>();
    final ts = _parseTs(m);
    if (ts == null) return null; // 没有有效时间戳的行无法排序
    return WbActivity(
      ts: ts,
      uid: _s(m, 'uid'),
      nickname: _s(m, 'nickname'),
      realm: _s(m, 'realm'),
      task: _s(m, 'task'),
      trigger: _s(m, 'trigger'),
      message: _s(m, 'message'),
      ok: _b(m, 'ok'),
    );
  }

  static WbUsageRow? _parseUsageRow(String line, WbPricing? pricing) {
    dynamic d;
    try {
      d = jsonDecode(line);
    } catch (_) {
      return null; // 坏行跳过
    }
    if (d is! Map) return null;
    final m = d.cast<String, dynamic>();
    final ts = _parseTs(m);
    final model = _s(m, 'model');
    if (ts == null || model.isEmpty) return null;
    final outcome = _s(m, 'outcome');
    final prompt = _d(m, 'prompt_tokens');
    final completion = _d(m, 'completion_tokens');
    final cached = _d(m, 'cached_tokens');
    final total = _d(m, 'total_tokens');
    final usageMissing = _b(m, 'usage_missing');
    return WbUsageRow(
      ts: ts,
      model: model,
      requestedModel: _optStr(m, 'requested_model'),
      account: _s(m, 'account'),
      realm: _s(m, 'realm'),
      prompt: prompt,
      completion: completion,
      cached: cached,
      // total_tokens 缺失时按 prompt+completion 兜底
      total: total > 0 ? total : prompt + completion,
      elapsedMs: _i(m, 'elapsed_ms'),
      ttftMs: _i(m, 'ttft_ms'),
      outcome: outcome,
      ok: outcome == 'completed',
      usageMissing: usageMissing,
      credit: _optDouble(m, 'credit'),
      // usage_missing 的行词元不可信，不估算
      costCny: usageMissing
          ? null
          : pricing?.costCny(
              model,
              input: prompt.round(),
              output: completion.round(),
              cached: cached.round(),
            ),
    );
  }

  /// 时间戳：优先 `at`（epoch 秒，float），缺失回退 `iso` 字符串
  /// 解析时间戳。usage.jsonl 用 `at`（epoch 秒），activity_history.jsonl
  /// 用 `ts`（ISO 字符串），两个文件各写各的，都认。
  static DateTime? _parseTs(Map m) {
    final epoch = m['at'] ?? m['ts'];
    if (epoch is num) {
      final sec = epoch.toDouble();
      if (sec <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch((sec * 1000).round());
    }
    final iso = m['ts'] ?? m['iso'];
    return iso is String ? DateTime.tryParse(iso) : null;
  }

  /// `sinceDays` → 本地时区「今天往前数 n 天」的起点；null 表示不限制
  static DateTime? _sinceCutoff(int? sinceDays) {
    if (sinceDays == null || sinceDays <= 0) return null;
    final now = DateTime.now();
    return DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(Duration(days: sinceDays - 1));
  }

  /// 取文件尾部最多 [maxLines] 行。
  ///
  /// 小文件整读；大文件从末尾按 [\_chunkSize] 往前读，凑够行数就停，避免把
  /// 几十 MB 的日志全加载进内存。
  static Future<List<String>> _tailLines(File f, int maxLines) async {
    final length = await f.length();
    if (length == 0 || maxLines <= 0) return const [];
    if (length <= _fullReadBytes) return (await f.readAsString()).split('\n');
    var buf = '';
    var newlines = 0;
    var pos = length;
    final raf = await f.open();
    try {
      while (pos > 0) {
        final from = pos > _chunkSize ? pos - _chunkSize : 0;
        await raf.setPosition(from);
        // readSync 可能一次读不满，循环读满整块
        final bytes = BytesBuilder(copy: false);
        var left = pos - from;
        while (left > 0) {
          final got = raf.readSync(left);
          if (got.isEmpty) break;
          bytes.add(got);
          left -= got.length;
        }
        final chunk = utf8.decode(bytes.takeBytes(), allowMalformed: true);
        buf = '$chunk$buf';
        for (var i = 0; i < chunk.length; i++) {
          if (chunk.codeUnitAt(i) == 0x0A) newlines++;
        }
        pos = from;
        // 被截断的是 buf 开头那一行，只要完整行够 maxLines 条，截尾 sublist
        // 自然会把它丢掉，不用再往前读
        if (newlines >= maxLines) break;
      }
    } finally {
      raf.closeSync();
    }
    return buf.split('\n');
  }

  // ---------- 取值辅助 ----------

  static String _s(Map m, String k, {String def = ''}) =>
      m[k] is String ? m[k] as String : def;

  static String? _optStr(Map m, String k) =>
      m[k] is String ? m[k] as String : null;

  static bool _b(Map m, String k, {bool def = false}) =>
      m[k] is bool ? m[k] as bool : def;

  static int _i(Map m, String k, {int def = 0}) =>
      m[k] is num ? (m[k] as num).toInt() : def;

  static double _d(Map m, String k, {double def = 0}) =>
      m[k] is num ? (m[k] as num).toDouble() : def;

  /// 取数值字段；缺失返回 null。[ignoreZero] 为 true 时 0/负值也当缺失
  /// 处理——epoch 0 不是有效时间戳（expiresAt 缺省就是 0），当 null 比当
  /// 「1970 年已过期」更有用。
  static double? _optDouble(Map m, String k, {bool ignoreZero = false}) {
    if (m[k] is! num) return null;
    final v = (m[k] as num).toDouble();
    return ignoreZero && v <= 0 ? null : v;
  }

  /// 'YYYY-MM-dd'，本地时区
  static String _dayKey(DateTime t) {
    final d = t.toLocal();
    return '${d.year.toString().padLeft(4, '0')}'
        '-${d.month.toString().padLeft(2, '0')}'
        '-${d.day.toString().padLeft(2, '0')}';
  }

  static String _join(String dir, String file) {
    final sep = Platform.pathSeparator;
    return dir.endsWith(sep) ? '$dir$file' : '$dir$sep$file';
  }

  static String _basename(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    for (var i = parts.length - 1; i >= 0; i--) {
      if (parts[i].isNotEmpty) return parts[i];
    }
    return path;
  }
}
