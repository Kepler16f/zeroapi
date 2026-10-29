import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/accountdata.dart';

/// AccountData（账号 / 额度 / 成本聚合层）的单元测试。
/// 全部数据写在临时目录里，不读真实 %APPDATA%。
void main() {
  late Directory tmp;
  late Directory accounts;
  late Directory usage;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('accountdata_test_');
    accounts = Directory('${tmp.path}${Platform.pathSeparator}accounts')
      ..createSync();
    usage = Directory('${tmp.path}${Platform.pathSeparator}usage')
      ..createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  double epoch(DateTime t) => t.millisecondsSinceEpoch / 1000;

  final sep = Platform.pathSeparator;

  void writeJson(String dir, String file, Map<String, dynamic> value) {
    File('$dir$sep$file').writeAsStringSync(jsonEncode(value));
  }

  void writeText(String dir, String file, String content) {
    File('$dir$sep$file').writeAsStringSync(content);
  }

  Map<String, dynamic> packageJson({String name = '裂变包'}) => {
    'name': name,
    'package_code': 'TCACA_code_007',
    'remain': 500,
    'used': 0,
    'size': 500,
    'unit': 'credits',
    'in_usage': false,
    'cycle_start_time': '2026-10-18 21:59:03',
    'cycle_end_time': '2026-11-18 21:59:02',
    'expire_time': '2026-11-18 21:59:02',
    'no_expiry': false,
    'days_left': 29.9,
    'is_expired': false,
    'status': 0,
  };

  Map<String, dynamic> creditsJson({
    double remain = 0,
    double used = 0,
    double size = 0,
    bool includeCheckin = true,
    bool todayCheckedIn = false,
    Map<String, dynamic>? earliestExpiring,
  }) => {
    'remain': remain,
    'used': used,
    'size': size,
    'used_percent': '0.0%',
    'remain_percent': '100.0%',
    'is_paid_user': false,
    'checkin': includeCheckin
        ? {
            'today_checked_in': todayCheckedIn,
            'streak_days': 1,
            'daily_credit': 100,
            'today_credit': 100,
            'active': true,
          }
        : null,
    'earliest_expiring': earliestExpiring,
    'packages': <Map<String, dynamic>>[],
    'updated_iso': '2026-10-19 23:18:25',
  };

  /// 造一个账号 JSON（含假 token，顺带确认不会泄漏进视图）
  Map<String, dynamic> accountJson({
    required String uid,
    required String realm,
    bool enabled = true,
    double restrictedUntil = 0,
    double expiresAt = 1794841180,
    bool noExpiresAt = false,
    String platform = 'CLI',
    String note = '',
    Map<String, dynamic>? credits,
    String? lastCheckin,
  }) => {
    'uid': uid,
    'nickname': '账号$uid',
    'domain': realm == 'cn' ? 'www.codebuddy.cn' : 'www.workbuddy.ai',
    'realm': realm,
    'platform': platform,
    'product': 'workbuddy',
    'accessToken': 'SECRET_ACCESS_$uid',
    'refreshToken': 'SECRET_REFRESH_$uid',
    if (!noExpiresAt) 'expiresAt': expiresAt,
    'source': 'oauth',
    'proxySlot': '',
    'proxy': '',
    'enabled': enabled,
    'weight': 1,
    'note': note,
    'restrictedUntil': restrictedUntil,
    'credits': credits,
    'lastCheckin': lastCheckin,
    'lastDailyChat': null,
  };

  /// 造一行 usage.jsonl 请求日志
  Map<String, dynamic> usageRow({
    required DateTime at,
    String model = 'deepseek-v4.1-flash',
    String account = 'a1',
    String realm = 'cn',
    String outcome = 'completed',
    int prompt = 1000,
    int completion = 500,
    int cached = 900,
    int? total,
    double? credit,
  }) {
    final row = <String, dynamic>{
      'at': epoch(at),
      'iso': at.toLocal().toIso8601String(),
      'model': model,
      'stream': true,
      'outcome': outcome,
      'elapsed_ms': 1234,
      'ttft_ms': 234,
      'account': account,
      'realm': realm,
      'prompt_tokens': prompt,
      'completion_tokens': completion,
      'cached_tokens': cached,
    };
    if (total != null) row['total_tokens'] = total;
    if (credit != null) row['credit'] = credit;
    return row;
  }

  group('AccountData.load', () {
    test('账号字段映射：realm/enabled/credits/planName/expiresAt', () async {
      writeJson(
        accounts.path,
        'a1.json',
        accountJson(
          uid: 'a1',
          realm: 'cn',
          platform: 'CLI',
          note: '主力号',
          credits: creditsJson(
            remain: 2600,
            used: 100,
            size: 2600,
            todayCheckedIn: true,
            earliestExpiring: packageJson(name: '裂变包'),
          ),
          lastCheckin: '2026-10-19 23:18:26',
        ),
      );
      // intl 账号：无 credits、无 expiresAt、无 lastCheckin
      writeJson(
        accounts.path,
        'a2.json',
        accountJson(
          uid: 'a2',
          realm: 'intl',
          platform: 'Agent',
          noExpiresAt: true,
        ),
      );

      final overview = await AccountData.load(
        accountsDir: accounts.path,
        usageDir: usage.path,
        pricingPath: '${tmp.path}${sep}pricing${sep}pricing.json',
      );
      expect(overview, isNotNull);

      final byUid = {for (final v in overview!.accounts) v.uid: v};
      final a1 = byUid['a1']!;
      expect(a1.nickname, '账号a1');
      expect(a1.realm, 'cn');
      expect(a1.platform, 'CLI');
      expect(a1.note, '主力号');
      expect(a1.enabled, isTrue);
      expect(a1.restricted, isFalse);
      expect(a1.ready, isTrue);
      expect(a1.creditsRemain, 2600);
      expect(a1.creditsSize, 2600);
      expect(a1.planName, '裂变包');
      expect(a1.expiresAt, isNotNull);
      expect(a1.expiresAt!.isAfter(DateTime.now()), isTrue);
      expect(a1.lastCheckin, '2026-10-19 23:18:26');

      final a2 = byUid['a2']!;
      expect(a2.realm, 'intl');
      expect(a2.platform, 'Agent');
      expect(a2.note, '');
      expect(a2.creditsRemain, 0);
      expect(a2.creditsSize, 0);
      expect(a2.planName, '');
      expect(a2.expiresAt, isNull);
      expect(a2.lastCheckin, '');
      expect(a2.ready, isTrue);

      // 隐私最小化：视图的可见字段里不出现 token
      final fields = jsonEncode([
        for (final v in overview.accounts)
          {
            'uid': v.uid,
            'nickname': v.nickname,
            'realm': v.realm,
            'enabled': v.enabled,
            'restricted': v.restricted,
            'platform': v.platform,
            'note': v.note,
            'creditsRemain': v.creditsRemain,
            'creditsSize': v.creditsSize,
            'planName': v.planName,
            'expiresAt': v.expiresAt?.toIso8601String(),
            'lastCheckin': v.lastCheckin,
          },
      ]);
      expect(fields, isNot(contains('SECRET')));

      // 池聚合透传
      expect(overview.total, 2);
      expect(overview.ready, 2);
      expect(overview.cnCount, 1);
      expect(overview.intlCount, 1);
      expect(overview.totalRemain, 2600);
      expect(overview.totalUsed, 100);
      expect(overview.checkedInToday, 1);
      expect(overview.loadedAt, isNotNull);
    });

    test('restrictedUntil 在未来 → restricted=true、ready=false', () async {
      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      writeJson(
        accounts.path,
        'a1.json',
        accountJson(uid: 'a1', realm: 'cn', restrictedUntil: future.toDouble()),
      );
      // 熔断 + 未启用：两个条件各自都会把 ready 打成 false
      writeJson(
        accounts.path,
        'a2.json',
        accountJson(uid: 'a2', realm: 'intl', enabled: false),
      );
      writeJson(
        accounts.path,
        'a3.json',
        accountJson(
          uid: 'a3',
          realm: 'cn',
          enabled: false,
          restrictedUntil: future.toDouble(),
        ),
      );
      writeJson(accounts.path, 'a4.json', accountJson(uid: 'a4', realm: 'cn'));

      final overview = await AccountData.load(
        accountsDir: accounts.path,
        usageDir: usage.path,
        pricingPath: '${tmp.path}${sep}pricing${sep}pricing.json',
      );
      expect(overview, isNotNull);
      final byUid = {for (final v in overview!.accounts) v.uid: v};

      expect(byUid['a1']!.restricted, isTrue);
      expect(byUid['a1']!.enabled, isTrue);
      expect(byUid['a1']!.ready, isFalse);
      expect(byUid['a2']!.restricted, isFalse);
      expect(byUid['a2']!.enabled, isFalse);
      expect(byUid['a2']!.ready, isFalse);
      expect(byUid['a3']!.restricted, isTrue);
      expect(byUid['a3']!.ready, isFalse);
      expect(byUid['a4']!.restricted, isFalse);
      expect(byUid['a4']!.ready, isTrue);
      expect(overview.total, 4);
      expect(overview.ready, 1, reason: '只有 a4 可参与轮换');
    });

    test('目录不存在 → load 返回 null，不抛异常', () async {
      final absent = await AccountData.load(
        accountsDir: '${tmp.path}${sep}no_such_accounts_dir',
        usageDir: usage.path,
        pricingPath: '${tmp.path}${sep}pricing${sep}pricing.json',
      );
      expect(absent, isNull);

      // 账号目录存在但里面是坏 JSON / 没有 uid：不抛异常，返回空总览
      writeText(
        accounts.path,
        'broken.json',
        '{ "uid": "broken", "enabled": tru',
      );
      writeJson(accounts.path, 'node.json', {'realm': 'cn', 'enabled': true});
      final overview = await AccountData.load(
        accountsDir: accounts.path,
        usageDir: usage.path,
        pricingPath: '${tmp.path}${sep}pricing${sep}pricing.json',
      );
      expect(overview, isNotNull);
      expect(overview!.accounts, isEmpty);
      expect(overview.total, 0);
      expect(overview.ready, 0);
    });

    test('聚合：today 与 overall 的 requests 不同，costCnyToday 有值', () async {
      writeJson(accounts.path, 'a1.json', accountJson(uid: 'a1', realm: 'cn'));

      final now = DateTime.now();
      // 今天的行：带上游 credit，成本按 credit 精确入账
      final todayRow = usageRow(
        at: now,
        prompt: 1000,
        completion: 500,
        cached: 900,
        total: 1500,
        credit: 2.5,
        account: 'a1',
        realm: 'cn',
      );
      // 两天前的行：必须被 sinceDays: 1 排除
      final oldRow = usageRow(
        at: now.subtract(const Duration(days: 2)),
        prompt: 2000,
        completion: 800,
        cached: 0,
        total: 2800,
        credit: 0.75,
        account: 'a1',
        realm: 'intl',
      );
      writeText(
        usage.path,
        'usage.jsonl',
        '${jsonEncode(todayRow)}\n${jsonEncode(oldRow)}\n',
      );

      final overview = await AccountData.load(
        accountsDir: accounts.path,
        usageDir: usage.path,
        pricingPath: '${tmp.path}${sep}pricing${sep}pricing.json',
      );
      expect(overview, isNotNull);

      expect(overview!.today.requests, 1, reason: '只有今天的行计入 today');
      expect(overview.overall.requests, 2, reason: 'overall 不限天数');
      expect(overview.today.requests, isNot(equals(overview.overall.requests)));
      expect(overview.costCnyToday, closeTo(2.5, 1e-12));
      expect(overview.overall.costCnySum, closeTo(3.25, 1e-12));
      expect(overview.today.promptTokens, 1000);
      expect(overview.overall.promptTokens, 3000);
    });

    test('pricing 命中时缺 credit 的行按本地价表估算；价表缺失时降级为 0', () async {
      writeJson(accounts.path, 'a1.json', accountJson(uid: 'a1', realm: 'cn'));

      final pricingFile = Directory('${tmp.path}${sep}pricing')..createSync();
      writeJson(pricingFile.path, 'pricing.json', {
        'meta': {'usd_cny': 7.1},
        'models': {
          'deepseek-v4.1-flash': {
            'display': 'deepseek-v4.1-flash',
            'unit': 1000000,
            'flat': {
              'input_cache_hit': 0.01,
              'input_cache_miss': 0.03,
              'output': 0.5,
            },
            'bands': <Map<String, dynamic>>[],
          },
        },
      });

      final now = DateTime.now();
      // 1000 未缓存输入 + 500 输出 + 0 缓存：(1000*0.03 + 500*0.5)/1e6 = 0.00028
      // 折算 CNY = 0.00028 * 7.1
      writeText(
        usage.path,
        'usage.jsonl',
        '${jsonEncode(usageRow(at: now, prompt: 1000, completion: 500, cached: 0, total: 1500))}\n',
      );

      final withPricing = await AccountData.load(
        accountsDir: accounts.path,
        usageDir: usage.path,
        pricingPath: '${pricingFile.path}${sep}pricing.json',
      );
      expect(withPricing, isNotNull);
      expect(withPricing!.today.requests, 1);
      expect(withPricing.costCnyToday, closeTo(0.00028 * 7.1, 1e-12));

      // 价表路径不存在：不估算，成本为 0，但仍正常返回总览
      final withoutPricing = await AccountData.load(
        accountsDir: accounts.path,
        usageDir: usage.path,
        pricingPath: '${tmp.path}${sep}pricing${sep}missing.json',
      );
      expect(withoutPricing, isNotNull);
      expect(withoutPricing!.today.requests, 1);
      expect(withoutPricing.costCnyToday, 0);
    });
  });
}
