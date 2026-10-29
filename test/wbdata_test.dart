import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/wbdata.dart';

/// WorkBuddy 号池只读解析（账号池 / 定价表 / 活跃事件 / 请求日志）的单元测试。
/// 全部数据写在临时目录里，不读真实 %APPDATA%。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wbdata_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String joinPath(String file) =>
      File('${tmp.path}${Platform.pathSeparator}$file').path;

  /// 在 [dir] 下写文本文件，返回目录内路径
  File writeText(String dir, String file, String content) {
    final sep = Platform.pathSeparator;
    final f = File('${dir.endsWith(sep) ? dir : '$dir$sep'}$file');
    f.writeAsStringSync(content);
    return f;
  }

  /// 写 JSON 文件（对象走 jsonEncode，字符串原样写，方便造坏数据）
  File writeJson(String file, Object? value) {
    final f = File(joinPath(file));
    f.writeAsStringSync(value is String ? value : jsonEncode(value));
    return f;
  }

  double epoch(DateTime t) => t.millisecondsSinceEpoch / 1000;

  /// 造一个账号 JSON（accessToken/refreshToken 故意写假密钥，用来验证不被带回）
  Map<String, dynamic> accountJson({
    required String uid,
    required String realm,
    bool enabled = true,
    int weight = 1,
    double restrictedUntil = 0,
    double expiresAt = 1794841180,
    bool noExpiresAt = false,
    String platform = 'CLI',
    String product = 'workbuddy',
    String source = 'oauth',
    String note = '',
    Map<String, dynamic>? credits,
    String? lastCheckin,
    String? lastDailyChat,
  }) => {
    'uid': uid,
    'nickname': '账号$uid',
    'domain': realm == 'cn' ? 'www.codebuddy.cn' : 'www.workbuddy.ai',
    'realm': realm,
    'platform': platform,
    'product': product,
    'enterpriseId': '',
    'accessToken': 'SECRET_ACCESS_$uid',
    'refreshToken': 'SECRET_REFRESH_$uid',
    if (!noExpiresAt) 'expiresAt': expiresAt,
    'addedAt': 1792421984.3004751,
    'source': source,
    'proxySlot': '',
    'proxy': '',
    'enabled': enabled,
    'weight': weight,
    'note': note,
    'disabledModels': <String>[],
    'restrictedUntil': restrictedUntil,
    'credits': credits,
    'lastCheckin': lastCheckin,
    'lastDailyChat': lastDailyChat,
    'modelCaps': <String, dynamic>{},
  };

  Map<String, dynamic> packageJson({
    String name = '裂变包',
    double remain = 0,
    double used = 0,
    double size = 0,
    double? daysLeft = 0,
    bool noDaysLeft = false,
  }) => {
    'name': name,
    'package_code': 'TCACA_code_007_nzdH5h4Nl0',
    'remain': remain,
    'used': used,
    'size': size,
    'unit': 'credits',
    'in_usage': false,
    'auto_renew': false,
    'cycle_start_time': '2026-10-18 21:59:03',
    'cycle_end_time': '2026-11-18 21:59:02',
    'expire_time': '2026-11-18 21:59:02',
    'no_expiry': false,
    'days_left': noDaysLeft ? null : daysLeft,
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
    List<Map<String, dynamic>> packages = const [],
  }) => {
    'remain': remain,
    'used': used,
    'size': size,
    'used_percent': '0.0%',
    'remain_percent': '100.0%',
    'is_paid_user': false,
    // includeCheckin: false 用来模拟 intl 账号的 "checkin": null
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
    'packages': packages,
    'updated_iso': '2026-10-19 23:18:25',
  };

  /// 造一行 usage.jsonl 请求日志
  Map<String, dynamic> usageRow({
    required DateTime at,
    String model = 'deepseek-v4.1-flash',
    String? requestedModel,
    String account = 'a1',
    String realm = 'cn',
    String outcome = 'completed',
    int prompt = 1000,
    int completion = 500,
    int cached = 900,
    int? total,
    double? credit,
    int elapsedMs = 1234,
    int ttftMs = 234,
    bool usageMissing = false,
  }) {
    final row = <String, dynamic>{
      'at': epoch(at),
      'iso': at.toLocal().toIso8601String(),
      'model': model,
      'stream': true,
      'outcome': outcome,
      'elapsed_ms': elapsedMs,
      'ttft_ms': ttftMs,
      'gen_ms': 900,
      'account': account,
      'realm': realm,
      'key': '',
      'cost_policy': 'v20261002',
      'tokens_per_sec': 12.5,
      'cache_hit_pct': 90.0,
    };
    if (requestedModel != null) row['requested_model'] = requestedModel;
    if (usageMissing) row['usage_missing'] = true;
    // usage_missing 的行没有 usage 块，vendor 不写这几个字段
    if (!usageMissing) {
      row['prompt_tokens'] = prompt;
      row['completion_tokens'] = completion;
      row['cached_tokens'] = cached;
    }
    if (total != null) row['total_tokens'] = total;
    if (credit != null) row['credit'] = credit;
    return row;
  }

  /// 把解析出的账号重新编码，用于断言 accessToken/refreshToken 没有被带回
  String accountToJson(WbAccount a) {
    final c = a.credits;
    return jsonEncode({
      'uid': a.uid,
      'nickname': a.nickname,
      'realm': a.realm,
      'domain': a.domain,
      'platform': a.platform,
      'product': a.product,
      'source': a.source,
      'note': a.note,
      'enabled': a.enabled,
      'weight': a.weight,
      'restrictedUntil': a.restrictedUntil,
      'proxySlot': a.proxySlot,
      'proxy': a.proxy,
      'expiresAtSec': a.expiresAtSec,
      'expiresAt': a.expiresAt?.toIso8601String(),
      'tokenExpired': a.tokenExpired,
      'isRestricted': a.isRestricted,
      'lastCheckin': a.lastCheckin,
      'lastDailyChat': a.lastDailyChat,
      'credits': c == null
          ? null
          : {
              'remain': c.remain,
              'used': c.used,
              'size': c.size,
              'usedPercent': c.usedPercent,
              'remainPercent': c.remainPercent,
              'isPaidUser': c.isPaidUser,
              'checkin': c.checkin == null
                  ? null
                  : {
                      'todayCheckedIn': c.checkin!.todayCheckedIn,
                      'streakDays': c.checkin!.streakDays,
                      'dailyCredit': c.checkin!.dailyCredit,
                      'todayCredit': c.checkin!.todayCredit,
                      'active': c.checkin!.active,
                    },
              'earliestExpiring': c.earliestExpiring?.name,
              'packages': c.packages.map((p) => p.name).toList(),
              'updatedIso': c.updatedIso,
            },
    });
  }

  group('readPool', () {
    test('只解析 {uid}.json，跳过配置类文件与坏数据，字段映射正确', () async {
      final cnCredits = creditsJson(
        remain: 2600,
        used: 0,
        size: 2600,
        todayCheckedIn: true,
        earliestExpiring: packageJson(
          name: '裂变包',
          remain: 500,
          size: 500,
          daysLeft: 29.9,
        ),
        packages: [
          packageJson(name: '裂变包', remain: 500, size: 500, daysLeft: 29.9),
        ],
      );
      final intlCredits = creditsJson(
        remain: 350,
        used: 30,
        size: 380,
        includeCheckin: false, // intl 账号 checkin 为 null
        packages: [
          packageJson(name: '永久包', remain: 100, size: 100, noDaysLeft: true),
        ],
      );
      writeJson(
        'a1.json',
        accountJson(
          uid: 'a1',
          realm: 'cn',
          credits: cnCredits,
          note: '主力号',
          lastCheckin: '2026-10-19 23:18:26',
        ),
      );
      writeJson(
        'a2.json',
        accountJson(
          uid: 'a2',
          realm: 'intl',
          credits: intlCredits,
          lastDailyChat: '2026-10-19 23:19:35',
        ),
      );
      // 同目录混入的非账号文件（vendor NON_ACCOUNT_FILES + 老版缓存）
      writeJson('active_realm.json', {
        'realm': 'cn',
        'updated_iso': '2026-10-19 23:18:12',
      });
      writeJson('settings.json', {
        'panel_password_salt': 'x',
        'panel_password_hash': 'y',
      });
      writeJson('model_windows.json', {
        'openai-gpt-5.2': [400000, 128000],
      });
      writeJson('quota_scan.json', {'scanned_at': '2026-10-19 23:18:12'});
      writeJson('model.json', {
        'openai-gpt-5.2': [400000, 128000],
      });
      // 坏数据：截断的 JSON、完全不是 JSON、JSON 数组
      writeJson('broken.json', '{ "uid": "broken", "enabled": tru');
      writeJson('notjson.json', '这是不是一个 json 呢');
      writeJson('list.json', [1, 2, 3]);
      // 是 JSON 对象但没有 uid
      writeJson('node.json', {'realm': 'cn', 'enabled': true});
      // 非 .json 后缀
      writeJson('ignored.txt', accountJson(uid: 'zz', realm: 'cn'));

      final pool = await WbData.readPool(tmp.path);

      expect(pool.accounts.length, 2, reason: '配置类文件与坏数据都应被跳过');
      expect(pool.accounts.map((a) => a.uid).toList(), ['a1', 'a2']);
      final a1 = pool.accounts[0];
      final a2 = pool.accounts[1];
      expect(a1.realm, 'cn');
      expect(a1.domain, 'www.codebuddy.cn');
      expect(a1.nickname, '账号a1');
      expect(a1.platform, 'CLI');
      expect(a1.product, 'workbuddy');
      expect(a1.source, 'oauth');
      expect(a1.note, '主力号');
      expect(a1.enabled, isTrue);
      expect(a1.weight, 1);
      expect(a1.restrictedUntil, 0);
      expect(a1.proxySlot, '');
      expect(a1.proxy, '');
      expect(a1.lastCheckin, '2026-10-19 23:18:26');
      expect(a1.lastDailyChat, isNull);
      expect(a1.expiresAtSec, 1794841180);
      expect(a1.expiresAt, isNotNull);
      expect(a1.expiresAt!.isAfter(DateTime.now()), isTrue);
      expect(a1.tokenExpired, isFalse);
      expect(a1.credits, isNotNull);
      expect(a1.credits!.remain, 2600);
      expect(a1.credits!.size, 2600);
      expect(a1.credits!.usedPercent, '0.0%');
      expect(a1.credits!.remainPercent, '100.0%');
      expect(a1.credits!.isPaidUser, isFalse);
      expect(a1.credits!.updatedIso, '2026-10-19 23:18:25');
      expect(a1.credits!.checkin, isNotNull);
      expect(a1.credits!.checkin!.todayCheckedIn, isTrue);
      expect(a1.credits!.checkin!.streakDays, 1);
      expect(a1.credits!.checkin!.dailyCredit, 100);
      expect(a1.credits!.checkin!.todayCredit, 100);
      expect(a1.credits!.checkin!.active, isTrue);
      expect(a1.credits!.earliestExpiring, isNotNull);
      expect(a1.credits!.earliestExpiring!.name, '裂变包');
      expect(a1.credits!.earliestExpiring!.unit, 'credits');
      expect(a1.credits!.earliestExpiring!.remain, 500);
      expect(a1.credits!.earliestExpiring!.daysLeft, 29.9);
      expect(a1.credits!.earliestExpiring!.cycleEndTime, '2026-11-18 21:59:02');
      expect(a1.credits!.packages.single.daysLeft, 29.9);
      // intl 账号：checkin 为 null，永久包 days_left 为 null
      expect(a2.realm, 'intl');
      expect(a2.domain, 'www.workbuddy.ai');
      expect(a2.lastCheckin, isNull);
      expect(a2.lastDailyChat, '2026-10-19 23:19:35');
      expect(a2.credits, isNotNull);
      expect(a2.credits!.remain, 350);
      expect(a2.credits!.used, 30);
      expect(a2.credits!.checkin, isNull);
      expect(a2.credits!.earliestExpiring, isNull);
      expect(a2.credits!.packages.single.name, '永久包');
      expect(a2.credits!.packages.single.daysLeft, isNull);
      // 隐私最小化：解析结果里不含任何 token
      for (final a in pool.accounts) {
        expect(
          accountToJson(a),
          isNot(contains('SECRET')),
          reason: 'token 泄漏到 ${a.uid}',
        );
      }
    });

    test('目录不存在返回空池', () async {
      final pool = await WbData.readPool(
        '${tmp.path}${Platform.pathSeparator}no_such_dir',
      );
      expect(pool.accounts, isEmpty);
      expect(pool.totalRemain, 0);
    });

    test('WbPool 聚合：仅 enabled 计入额度，签到与区域计数', () async {
      writeJson(
        'a1.json',
        accountJson(
          uid: 'a1',
          realm: 'cn',
          credits: creditsJson(
            remain: 2600,
            used: 100,
            size: 2600,
            todayCheckedIn: true,
          ),
        ),
      );
      writeJson(
        'a2.json',
        accountJson(
          uid: 'a2',
          realm: 'intl',
          credits: creditsJson(
            remain: 350,
            used: 50,
            size: 380,
            includeCheckin: false,
          ),
        ),
      );
      // a3 熔断中：额度不计入，但今日签到仍计
      writeJson(
        'a3.json',
        accountJson(
          uid: 'a3',
          realm: 'cn',
          enabled: false,
          credits: creditsJson(
            remain: 9999,
            used: 8888,
            size: 9999,
            todayCheckedIn: true,
          ),
        ),
      );
      writeJson('a4.json', accountJson(uid: 'a4', realm: 'intl')); // 无 credits

      final pool = await WbData.readPool(tmp.path);

      expect(pool.accounts.length, 4);
      expect(pool.totalRemain, 2950); // 2600 + 350，a3 熔断不计、a4 无额度按 0
      expect(pool.totalUsed, 150); // 100 + 50
      expect(pool.checkedInToday, 2); // a1 + a3（熔断账号的今日签到也算事实）
      expect(pool.cnCount, 2);
      expect(pool.intlCount, 2);
    });

    test('isRestricted：restrictedUntil 为未来秒级时间戳时为 true，0 为 false', () async {
      final future = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      writeJson('a1.json', accountJson(uid: 'a1', realm: 'cn'));
      writeJson(
        'a2.json',
        accountJson(
          uid: 'a2',
          realm: 'intl',
          restrictedUntil: future.toDouble(),
        ),
      );
      writeJson(
        'a3.json',
        accountJson(uid: 'a3', realm: 'cn', restrictedUntil: 0.0),
      );

      final pool = await WbData.readPool(tmp.path);
      final byUid = {for (final a in pool.accounts) a.uid: a};

      expect(byUid['a1']!.restrictedUntil, 0);
      expect(byUid['a1']!.isRestricted, isFalse);
      expect(byUid['a2']!.restrictedUntil, future);
      expect(byUid['a2']!.isRestricted, isTrue);
      expect(byUid['a3']!.isRestricted, isFalse);
    });

    test('tokenExpired：expiresAt 已过期为 true，缺失 / 为 0 时为 false', () async {
      writeJson(
        'a1.json',
        accountJson(uid: 'a1', realm: 'cn', expiresAt: 1500000000),
      ); // 2017
      writeJson('a2.json', accountJson(uid: 'a2', realm: 'intl', expiresAt: 0));
      writeJson(
        'a3.json',
        accountJson(uid: 'a3', realm: 'intl', noExpiresAt: true),
      );
      final a2File = File(joinPath('a2.json'));

      final pool = await WbData.readPool(tmp.path);
      final byUid = {for (final a in pool.accounts) a.uid: a};

      expect(byUid['a1']!.tokenExpired, isTrue);
      expect(byUid['a1']!.expiresAt!.isBefore(DateTime.now()), isTrue);
      // epoch 0 和字段缺失都表示「没有令牌」，都不能读成 1970 年已过期
      expect(byUid['a2']!.expiresAtSec, isNull);
      expect(byUid['a2']!.tokenExpired, isFalse);
      expect(byUid['a3']!.expiresAtSec, isNull);
      expect(byUid['a3']!.expiresAt, isNull);
      expect(byUid['a3']!.tokenExpired, isFalse);
      // 文件本身没被改坏（只读约定）
      final raw = jsonDecode(a2File.readAsStringSync()) as Map<String, dynamic>;
      expect(raw['expiresAt'], 0);
      expect(raw['accessToken'], 'SECRET_ACCESS_a2');
    });
  });

  group('readPricing', () {
    late File pricing;

    setUp(() {
      pricing = writeJson('pricing.json', {
        'meta': {
          'generated_at': '2026-10-02T01:39:39',
          'base_currency': 'CNY',
          'usd_cny': 7.1,
        },
        'models': {
          'deepseek-v4.1-flash': {
            'display': 'deepseek-v4.1-flash',
            'source': 'openrouter',
            'currency': 'USD',
            'unit': 1000000,
            'or_id': 'deepseek/deepseek-v4.1-flash',
            'flat': {
              'input_cache_hit': 0.01,
              'input_cache_miss': 0.03,
              'output': 0.5,
            },
            'bands': <Map<String, dynamic>>[],
          },
          // 两个升序长度档：验证「取最后命中档」而不是「取第一个命中」
          'gpt-6-astra': {
            'display': 'gpt-6-astra',
            'currency': 'USD',
            'unit': 1000000,
            'or_id': 'openai/gpt-6-astra',
            'flat': {
              'input_cache_hit': 1.0,
              'input_cache_miss': 10.0,
              'output': 50.0,
            },
            'bands': [
              {
                'flat': {
                  'input_cache_hit': 1.5,
                  'input_cache_miss': 15.0,
                  'output': 60.0,
                },
                'min_prompt_tokens': 128000,
              },
              {
                'flat': {
                  'input_cache_hit': 2.0,
                  'input_cache_miss': 20.0,
                  'output': 75.0,
                },
                'min_prompt_tokens': 272000,
              },
            ],
          },
          // 非 1000000 的计价单位 + 缺 input_cache_hit + 只有 UTC 时段档
          'kimi-custom': {
            'display': 'kimi-custom',
            'currency': 'USD',
            'unit': 1000,
            'or_id': 'moonshotai/kimi-custom',
            'flat': {'input_cache_miss': 0.002, 'output': 0.01},
            'bands': [
              {
                'flat': {
                  'input_cache_hit': 0.001,
                  'input_cache_miss': 0.003,
                  'output': 0.015,
                },
                'days': ['mon', 'tue'],
                'start': 0,
                'end': 1600,
              },
            ],
          },
        },
      });
    });

    test('读取汇率、计价单位与 bands 结构', () async {
      final p = await WbData.readPricing(pricing.path);

      expect(p.usdCny, 7.1);
      expect(p.models.length, 3);
      final ds = p.model('deepseek-v4.1-flash')!;
      expect(ds.display, 'deepseek-v4.1-flash');
      expect(ds.orId, 'deepseek/deepseek-v4.1-flash');
      expect(ds.unit, 1000000);
      expect(ds.inputCacheHit, 0.01);
      expect(ds.inputCacheMiss, 0.03);
      expect(ds.output, 0.5);
      expect(ds.bands, isEmpty);
      // 长度阈值档：按 JSON 顺序保留
      expect(p.model('gpt-6-astra')!.bands.length, 2);
      expect(p.model('gpt-6-astra')!.bands[0].minPromptTokens, 128000);
      expect(p.model('gpt-6-astra')!.bands[0].inputCacheMiss, 15.0);
      final band2 = p.model('gpt-6-astra')!.bands[1];
      expect(band2.minPromptTokens, 272000);
      expect(band2.inputCacheHit, 2.0);
      expect(band2.output, 75.0);
      // UTC 时段档：条件原样保留，标记为「非长度档」
      final window = p.model('kimi-custom')!.bands.single;
      expect(window.minPromptTokens, isNull);
      expect(window.hasLengthCondition, isFalse);
      expect(window.days, ['mon', 'tue']);
      expect(window.start, 0);
      expect(window.end, 1600);
      expect(p.model('gpt-6-astra')!.orId, 'openai/gpt-6-astra');
    });

    test(
      'costUsd：cached 部分按 inputCacheHit 计，其余按 inputCacheMiss，输出按 output',
      () async {
        final p = await WbData.readPricing(pricing.path);

        // 60 万未缓存 + 40 万缓存 + 10 万输出
        // = 600000*0.03/1e6 + 400000*0.01/1e6 + 100000*0.5/1e6
        // = 0.018 + 0.004 + 0.05 = 0.072
        expect(
          p.costUsd(
            'deepseek-v4.1-flash',
            input: 1000000,
            output: 100000,
            cached: 400000,
          ),
          closeTo(0.072, 1e-12),
        );
        // 无缓存输入全部按 miss 计
        expect(
          p.costUsd('deepseek-v4.1-flash', input: 1000000, output: 100000),
          closeTo(0.08, 1e-12),
        );
        // cached 超过 input 时不应算出负的未缓存输入
        expect(
          p.costUsd(
            'deepseek-v4.1-flash',
            input: 1000,
            output: 0,
            cached: 99999,
          ),
          closeTo(1e-05, 1e-14),
        );
      },
    );

    test('bands 按 min_prompt_tokens 取最后命中档，都不命中回落 flat', () async {
      final p = await WbData.readPricing(pricing.path);

      // 低于所有阈值：走 flat（miss 10）
      expect(
        p.costUsd('gpt-6-astra', input: 50000, output: 0),
        closeTo(0.5, 1e-12),
      );
      // 只命中第一档（miss 15）
      expect(
        p.costUsd('gpt-6-astra', input: 200000, output: 0),
        closeTo(3.0, 1e-12),
      );
      // 两档都命中，取最后那档（miss 20）——证明不是取第一个命中
      expect(
        p.costUsd('gpt-6-astra', input: 300000, output: 0),
        closeTo(6.0, 1e-12),
      );
      // 命中档后 cached 也按该档的 hit 价计
      // = 200000*20/1e6 + 100000*2/1e6 = 4 + 0.2 = 4.2
      expect(
        p.costUsd('gpt-6-astra', input: 300000, output: 0, cached: 100000),
        closeTo(4.2, 1e-12),
      );
      // UTC 时段档不参与选档：低输入仍落 flat
      expect(
        p.costUsd('kimi-custom', input: 500, output: 0),
        closeTo(0.001, 1e-15),
      );
    });

    test('unit 不是 1000000 时按模型自己的 unit 计；缺 input_cache_hit 回退 miss', () async {
      final p = await WbData.readPricing(pricing.path);
      final k = p.model('kimi-custom')!;
      expect(k.unit, 1000);
      expect(k.inputCacheHit, isNull);

      // 缓存部分没有 hit 价，回退按 miss 计：200*0.002/1000 = 0.0004
      expect(
        p.costUsd('kimi-custom', input: 200, output: 0, cached: 200),
        closeTo(0.0004, 1e-12),
      );
      // cached 不会超过 input，多出来的当未缓存算
      expect(
        p.costUsd('kimi-custom', input: 100, output: 0, cached: 200),
        closeTo(0.0002, 1e-12),
      );
      // 全部未缓存 + 输出：100*0.002/1000 + 50*0.01/1000 = 0.0002 + 0.0005
      expect(
        p.costUsd('kimi-custom', input: 100, output: 50),
        closeTo(0.0007, 1e-12),
      );
      expect(
        p.costCny('kimi-custom', input: 100, output: 50),
        closeTo(0.0007 * 7.1, 1e-12),
      );
    });

    test('未命中模型返回 null', () async {
      final p = await WbData.readPricing(pricing.path);

      expect(p.costUsd('no-such-model', input: 100, output: 10), isNull);
      expect(p.costCny('no-such-model', input: 100, output: 10), isNull);
      expect(p.model('no-such-model'), isNull);
    });

    test('costCny = costUsd * usd_cny', () async {
      final p = await WbData.readPricing(pricing.path);

      final usd = p.costUsd(
        'deepseek-v4.1-flash',
        input: 1000000,
        output: 100000,
        cached: 400000,
      )!;
      final cny = p.costCny(
        'deepseek-v4.1-flash',
        input: 1000000,
        output: 100000,
        cached: 400000,
      )!;
      expect(usd, closeTo(0.072, 1e-12));
      expect(cny, closeTo(0.072 * 7.1, 1e-12));
    });

    test('文件不存在 / 坏数据返回空表，costUsd 为 null', () async {
      expect(
        (await WbData.readPricing(
          '${tmp.path}${Platform.pathSeparator}none.json',
        )).models,
        isEmpty,
      );
      expect(
        (await WbData.readPricing(joinPath('bad.json')))
            .costUsd('x', input: 1, output: 1),
        isNull,
      );
      writeJson('bad.json', '{ not json');
      expect((await WbData.readPricing(joinPath('bad.json'))).models, isEmpty);
      // 空表读取后 costCny 同样为 null
      expect(
        (await WbData.readPricing(joinPath('bad.json')))
            .costCny('x', input: 1, output: 1),
        isNull,
      );
    });
  });

  group('readActivity', () {
    test('按时间倒序返回，limit 截断', () async {
      final usage = Directory('${tmp.path}${Platform.pathSeparator}usage')
        ..createSync();
      final lines = <String>[
        jsonEncode({
          'ts': '2026-10-19T23:19:35+08:00',
          'uid': 'a2',
          'nickname': '账号a2',
          'realm': 'intl',
          'task': 'daily_chat',
          'trigger': 'manual',
          'ok': true,
          'message': '每日活跃对话成功完成',
        }),
        jsonEncode({
          'ts': '2026-10-19T22:59:45+08:00',
          'uid': 'a1',
          'nickname': '账号a1',
          'realm': 'cn',
          'task': 'checkin',
          'trigger': 'account_add',
          'ok': true,
          'message': 'OK',
        }),
        jsonEncode({
          'ts': '2026-10-19T23:18:55+08:00',
          'uid': 'a2',
          'nickname': '账号a2',
          'realm': 'intl',
          'task': 'daily_chat',
          'trigger': 'manual',
          'ok': false,
          'message': 'SSL EOF',
        }),
        jsonEncode({
          'ts': '2026-10-19T23:19:31+08:00',
          'uid': 'a2',
          'nickname': '账号a2',
          'realm': 'intl',
          'task': 'daily_chat',
          'trigger': 'manual',
          'ok': true,
          'message': '成功',
        }),
        jsonEncode({
          'ts': '2026-10-19T20:00:00+08:00',
          'uid': 'a1',
          'nickname': '账号a1',
          'realm': 'cn',
          'task': 'quota_scan',
          'trigger': 'periodic',
          'ok': true,
          'message': 'scan done',
        }),
      ];
      writeText(usage.path, 'activity_history.jsonl', "${lines.join('\n')}\n");

      final all = await WbData.readActivity(usage.path);
      expect(all.length, 5);
      // 倒序：时间单调不增
      for (var i = 1; i < all.length; i++) {
        expect(
          all[i - 1].ts.isAfter(all[i].ts),
          isTrue,
          reason: '${all[i - 1].ts} 应晚于 ${all[i].ts}',
        );
      }
      // 最新的在前，最旧的在后（+08:00 时间戳统一归一到 UTC 比较）
      expect(all.first.ts.toUtc(), DateTime.utc(2026, 10, 19, 15, 19, 35));
      expect(all.last.ts.toUtc(), DateTime.utc(2026, 10, 19, 12, 0, 0));
      expect(all.last.task, 'quota_scan');

      final top3 = await WbData.readActivity(usage.path, limit: 3);
      expect(top3.length, 3);
      expect(top3[0].task, 'daily_chat');
      expect(top3[0].uid, 'a2');
      expect(top3[0].nickname, '账号a2');
      expect(top3[0].realm, 'intl');
      expect(top3[0].trigger, 'manual');
      expect(top3[0].message, '每日活跃对话成功完成');
      expect(top3[0].ok, isTrue);
      // limit 截掉的最旧一条
      expect(top3[2].task, 'daily_chat');
      expect(top3.any((e) => e.task == 'quota_scan'), isFalse);

      // ok / message 字段逐条正确
      expect(all.where((e) => !e.ok).length, 1);
      final failed = all.singleWhere((e) => !e.ok);
      expect(failed.message, 'SSL EOF');
      expect(failed.task, 'daily_chat');

      // 空文件：只有空 activity_history.jsonl
      final empty = Directory('${usage.path}${Platform.pathSeparator}empty')
        ..createSync();
      writeText(empty.path, 'activity_history.jsonl', '');
      expect(await WbData.readActivity(empty.path), isEmpty);
    });

    test('坏行与缺 ts 的行跳过；目录不存在返回空', () async {
      final usage = Directory('${tmp.path}${Platform.pathSeparator}usage2')
        ..createSync();
      writeText(
        usage.path,
        'activity_history.jsonl',
        [
          '{ broken json', // 坏 JSON 行
          '', // 空行
          jsonEncode({
            'ts': '2026-10-19T10:00:00+08:00',
            'uid': 'a1',
            'nickname': 'x',
            'realm': 'cn',
            'task': 'checkin',
            'trigger': 'auto',
            'ok': true,
            'message': 'OK',
          }),
          jsonEncode({'uid': 'a2', 'task': 'checkin'}), // 没有 ts
          '',
        ].join('\n'),
      );

      final list = await WbData.readActivity(usage.path);
      expect(list.length, 1);
      expect(list.single.uid, 'a1');
      expect(
        list.single.ts.toUtc(),
        DateTime.utc(2026, 10, 19, 2, 0, 0),
      ); // +08:00 → UTC 02:00

      expect(
        await WbData.readActivity('${tmp.path}${Platform.pathSeparator}nope'),
        isEmpty,
      );
    });
  });

  group('WbUsageRow', () {
    test('billedCny 优先上游 credit，没有时用本地估算，都没有则 null', () {
      WbUsageRow base(double? credit, double? costCny, String outcome) =>
          WbUsageRow(
            ts: DateTime.utc(2026, 10, 19, 10),
            model: 'm',
            account: 'a1',
            realm: 'cn',
            prompt: 10,
            completion: 5,
            cached: 0,
            total: 15,
            elapsedMs: 1,
            ttftMs: 1,
            outcome: outcome,
            ok: outcome == 'completed',
            usageMissing: false,
            credit: credit,
            costCny: costCny,
          );

      expect(base(1.5, 0.9, 'completed').billedCny, 1.5);
      expect(base(null, 0.9, 'completed').billedCny, 0.9);
      expect(base(null, null, 'failed').billedCny, isNull);
      expect(base(null, 0.9, 'client_aborted').ok, isFalse);
      expect(base(null, 0.9, 'completed').ok, isTrue);
    });
  });

  group('readUsage', () {
    late Directory usage;
    late WbPricing pricing;

    /// 测试用价表：deepseek-v4.1-flash 价 hit .01 / miss .03 / out .5（每百万 token）
    WbPricing loadPricing() => WbPricing(
      usdCny: 7.1,
      models: {
        'deepseek-v4.1-flash': const WbModelPrice(
          display: 'deepseek-v4.1-flash',
          orId: 'deepseek/deepseek-v4.1-flash',
          unit: 1000000,
          inputCacheHit: 0.01,
          inputCacheMiss: 0.03,
          output: 0.5,
        ),
      },
    );

    setUp(() async {
      usage = Directory('${tmp.path}${Platform.pathSeparator}usage')
        ..createSync();
      pricing = loadPricing();
    });

    test('聚合请求数/词元/成本/按模型按账号按天；credit 优先于本地估算', () async {
      final now = DateTime.now();
      final rows = <Map<String, dynamic>>[
        // 有 credit：入账按 credit 算，本地估算不叠加
        usageRow(
          at: now,
          prompt: 1000,
          completion: 500,
          cached: 900,
          total: 1500,
          credit: 0.05,
          account: 'a1',
          realm: 'cn',
          requestedModel: 'ds-flash',
        ),
        // 无 credit：用本地价表估算 (100*0.03 + 50*0.5)/1e6*7.1
        usageRow(
          at: now.subtract(const Duration(minutes: 1)),
          prompt: 100,
          completion: 50,
          cached: 0,
          total: 150,
          account: 'a2',
          realm: 'intl',
        ),
        // usage_missing：没有 usage 块，outcome 为 failed，词元全 0
        usageRow(
          at: now.subtract(const Duration(minutes: 2)),
          account: 'a2',
          realm: 'intl',
          outcome: 'failed',
          prompt: 0,
          completion: 0,
          cached: 0,
          usageMissing: true,
        ),
        // 有 credit、缺 total_tokens：total 回退成 prompt+completion
        usageRow(
          at: now.subtract(const Duration(minutes: 3)),
          prompt: 200,
          completion: 100,
          cached: 100,
          credit: 0.001,
          account: 'a1',
          realm: 'cn',
        ),
      ];
      writeText(
        usage.path,
        'usage.jsonl',
        "${rows.map((r) => jsonEncode(r)).join('\n')}\n",
      );

      final stats = await WbData.readUsage(usage.path, pricing: pricing);

      expect(stats.requests, 4);
      expect(stats.errors, 1); // 只有 outcome=failed 那条
      expect(stats.promptTokens, 1300); // 1000 + 100 + 0 + 200
      expect(stats.completionTokens, 650); // 500 + 50 + 0 + 100
      expect(stats.cachedTokens, 1000); // 900 + 0 + 0 + 100
      expect(stats.creditSum, closeTo(0.051, 1e-12));
      expect(stats.creditKnown, 2);
      // 0.05(credit) + 0.0001988(估算) + 0.001(credit)
      expect(stats.costCnySum, closeTo(0.0511988, 1e-9));
      expect(stats.costByModel, {
        'deepseek-v4.1-flash': closeTo(0.0511988, 1e-9),
      });
      expect(stats.byModel, {'deepseek-v4.1-flash': 4});
      expect(stats.byAccount, {'a1': 2, 'a2': 2});
      expect(stats.byRealm, {'cn': 2, 'intl': 2});
      // 全部落在最近几分钟内，可能跨天，所以只校验合计
      expect(stats.byDay.values.fold(0, (s, v) => s + v), 4);
      expect(
        stats.tokensByDay.values.fold(0, (s, v) => s + v),
        1950,
      ); // 含 total 回退的 300
    });

    test('未传 pricing 时不估算，credit 仍正常合计', () async {
      final now = DateTime.now();
      writeText(
        usage.path,
        'usage.jsonl',
        "${jsonEncode(usageRow(at: now, prompt: 1000, completion: 500, cached: 900, total: 1500, credit: 0.05))}\n"
            "${jsonEncode(usageRow(at: now, prompt: 100, completion: 50, cached: 0, total: 150))}\n",
      );

      final stats = await WbData.readUsage(usage.path);

      expect(stats.requests, 2);
      expect(stats.creditSum, closeTo(0.05, 1e-12));
      expect(stats.creditKnown, 1);
      expect(stats.costCnySum, closeTo(0.05, 1e-12)); // 只有 credit 那条入账
      expect(stats.costByModel['deepseek-v4.1-flash'], closeTo(0.05, 1e-12));
    });

    test('limit 从文件尾部取；坏行跳过；usage-recent-index.json 不被改写', () async {
      final sentinel = '{"offsets": {"usage.jsonl": 12345}}';
      writeText(usage.path, 'usage-recent-index.json', sentinel);

      final now = DateTime.now();
      final lines = <String>[
        for (var i = 0; i < 7; i++)
          jsonEncode(
            usageRow(
              at: now.subtract(Duration(minutes: i)),
              prompt: 10 + i,
              completion: 5,
              cached: 0,
              total: 15 + i,
            ),
          ),
      ];
      lines.insert(2, '{ broken json'); // 中间夹坏行
      lines.insert(5, ''); // 空行
      writeText(usage.path, 'usage.jsonl', "${lines.join('\n')}\n");

      final all = await WbData.readUsage(usage.path, limit: 100);
      expect(all.requests, 7); // 坏行与空行被跳过

      final last3 = await WbData.readUsage(usage.path, limit: 3);
      expect(last3.requests, 3);
      // 尾部 3 行是 i=4/5/6：prompt 14+15+16，total 19+20+21
      expect(last3.promptTokens, 45);
      expect(last3.completionTokens, 15);
      expect(last3.tokensByDay.values.fold(0, (s, v) => s + v), 60);
      expect(last3.byModel['deepseek-v4.1-flash'], 3);

      // 索引文件原样保留
      expect(
        File('${usage.path}${Platform.pathSeparator}usage-recent-index.json')
            .readAsStringSync(),
        sentinel,
      );
      // 只读：usage.jsonl 也没被改写
      expect(
        File('${usage.path}${Platform.pathSeparator}usage.jsonl')
            .readAsStringSync(),
        "${lines.join('\n')}\n",
      );
    });

    test('超过整读阈值的日志走尾部按块读，尾部行照样取得到', () async {
      // hub 的 usage.jsonl 一天能长到 20MB，超过阈值不能整读进内存
      final now = DateTime.now();
      final rows = [
        for (var i = 0; i < 5; i++)
          jsonEncode(
            usageRow(
              at: now.subtract(Duration(minutes: i)),
              prompt: 10 + i,
              completion: 5,
              total: 15 + i,
            ),
          ),
      ];
      final usageFile = File(
        '${usage.path}${Platform.pathSeparator}usage.jsonl',
      );
      writeText(
        usage.path,
        'usage.jsonl',
        '${'x' * (33 * 1024 * 1024)}\n${rows.join('\n')}\n',
      );
      expect(usageFile.lengthSync(), greaterThan(32 * 1024 * 1024));

      final all = await WbData.readUsage(usage.path, limit: 5);
      expect(all.requests, 5); // 超长 padding 行不是 JSON，跳过
      expect(all.promptTokens, 60); // 10+11+12+13+14
      expect(all.tokensByDay.values.fold(0, (s, v) => s + v), 85); // 15..19

      final last2 = await WbData.readUsage(usage.path, limit: 2);
      expect(last2.requests, 2);
      expect(last2.promptTokens, 27); // 尾部两行 13 + 14
      expect(last2.completionTokens, 10);

      // 只读：大文件也没被改写
      expect(usageFile.lengthSync(), greaterThan(32 * 1024 * 1024));
    });

    test('sinceDays 只统计最近几天（含今天）', () async {
      final now = DateTime.now();
      final lines = <String>[
        jsonEncode(
          usageRow(at: now.subtract(const Duration(days: 3)), total: 100),
        ),
        jsonEncode(
          usageRow(at: now.subtract(const Duration(days: 2)), total: 100),
        ),
        jsonEncode(usageRow(at: now, total: 100)),
      ];
      writeText(usage.path, 'usage.jsonl', "${lines.join('\n')}\n");

      final all = await WbData.readUsage(usage.path);
      expect(all.requests, 3);

      final last3 = await WbData.readUsage(usage.path, sinceDays: 3);
      expect(last3.requests, 2); // 今天 + 2 天前
      expect(last3.byDay.values.fold(0, (s, v) => s + v), 2);

      final todayOnly = await WbData.readUsage(usage.path, sinceDays: 1);
      expect(todayOnly.requests, 1);
    });

    test('文件不存在 / 空文件返回空统计', () async {
      final absent = await WbData.readUsage(
        '${tmp.path}${Platform.pathSeparator}nope',
      );
      expect(absent.requests, 0);
      expect(absent.byModel, isEmpty);

      writeText(usage.path, 'usage.jsonl', '');
      final empty = await WbData.readUsage(usage.path);
      expect(empty.requests, 0);
      expect(empty.costCnySum, 0);
    });
  });
}
