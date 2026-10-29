// 原生签到中心页测试。
//
// widget 层用 FakeHubService 覆盖 hub 取数/写操作（真实 HTTP 的服务器回调
// 在 FakeAsync 区不推进，widget 测试里起真服务器必挂）；hubPost/hubGet 的
// 真实 I/O 与 token 流程由 service_hub_test 用普通 test() 覆盖。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/checkin_page.dart';
import 'package:zeroapi/gateway/service.dart';

class FakeHubService extends GatewayService {
  FakeHubService({
    required this.accounts,
    this.activity = const [],
    this.tasks,
    this.grants = const [],
  });

  final List<Map<String, dynamic>> accounts;
  final List<Map<String, dynamic>> activity;
  /// GET /tasks 的载荷（null = 模拟无该端点的旧版 hub）
  Map<String, dynamic>? tasks;
  /// GET /accounts/credits/grants 的 rows
  final List<Map<String, dynamic>> grants;
  final posts = <(String, Map<String, dynamic>)>[];
  final gets = <String>[];

  @override
  Future<Map<String, dynamic>?> hubGet(String path) async {
    gets.add(path);
    if (path.startsWith('/tasks')) return tasks;
    if (path == '/accounts/credits/grants') return {'rows': grants};
    return null;
  }

  @override
  Future<List<Map<String, dynamic>>> hubAccounts() async => accounts;

  @override
  Future<List<Map<String, dynamic>>> hubActivity({
    int limit = 30,
    String? range,
    String? task,
    String? result,
  }) async => activity;

  @override
  Future<Map<String, dynamic>> hubPost(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    posts.add((path, body));
    switch (path) {
      case '/tasks/run':
        return {
          'logs': ['接取任务 每日签到 成功', '领取积分 +1450'],
          'credit_added': 1450,
        };
      case '/tasks/claim':
        return {'ok': true, 'msg': '领取成功', 'credit': 200};
      case '/tasks/travel':
        return {'ok': true, 'msg': '旅行已出发'};
      case '/tasks/streak-bonus':
        return {'ok': true, 'msg': '连登奖励与抽奖已完成'};
      default:
        return {
          'results': [
            {'uid': 'x', 'nickname': '某账号', 'ok': true, 'msg': '成功'},
          ],
        };
    }
  }
}

Map<String, dynamic> account({
  required String uid,
  required String nick,
  required String realm,
  Object? lastCheckin,
  Object? lastDailyChat,
  bool enabled = true,
  bool needRelogin = false,
}) => {
  'uid': uid,
  'nickname': nick,
  'realm': realm,
  'enabled': enabled,
  'needRelogin': needRelogin,
  'lastCheckin': lastCheckin,
  'lastDailyChat': lastDailyChat,
};

String todayStr() {
  final n = DateTime.now();
  String p(int v) => v.toString().padLeft(2, '0');
  return '${n.year}-${p(n.month)}-${p(n.day)}';
}

/// GET /tasks 的样例载荷（形状对齐 hub 1.7.30 的 growth_snapshot）。
Map<String, dynamic> growthTasksPayload() => {
  'tasks': [
    {
      'name': '每日签到',
      'task_code': 'sign_in',
      'description': '每日打开加油站签到一次',
      'current': 1,
      'target': 1,
      'status': 'completed',
      'reward_credit': 100,
      'reward_energy': 0,
    },
    {
      'name': '成长任务A',
      'task_code': 'growth_a',
      'description': '累计对话 5 次',
      'current': 2,
      'target': 5,
      'status': 'in_progress',
      'reward_credit': 0,
      'reward_energy': 30,
    },
    {
      'name': '已领取任务',
      'task_code': 'done_one',
      'description': '-',
      'current': 1,
      'target': 1,
      'status': 'claimed',
      'reward_credit': 50,
      'reward_energy': 0,
    },
  ],
  'summary': {
    'streak_days': 7,
    'energy': 233,
    'makeup_cards': 2,
    'lottery_chances': 1,
    'travel': {'state': 'arrived', 'reward_credit': 80},
  },
  'accounts': [
    {'uid': 'cn1', 'nickname': '国内A'},
    {'uid': 'cn2', 'nickname': '国内B'},
  ],
};

/// GET /accounts/credits/grants 的样例 rows（含计入与不计入的边界）。
List<Map<String, dynamic>> grantsRows() => [
  {'realm': 'cn', 'name': 'Buddy 成长', 'grant_reason': '成长任务', 'size': 1450},
  {'realm': 'cn', 'name': '体验包', 'grant_reason': '', 'size': 500},
  {'realm': 'cn', 'name': '裂变礼包', 'source_inferred': 'x', 'size': 0, 'amount': 200},
  {'realm': 'intl', 'name': 'Bonus Pack', 'size': 30},
  {'realm': 'intl', 'name': 'other', 'source_inferred': '每日活跃', 'amount': 27},
  {'realm': 'intl', 'name': 'other', 'source_inferred': '', 'amount': 999},
];

void main() {
  group('纯函数', () {
    test('wbDoneToday 认字符串与 epoch 秒', () {
      final now = DateTime(2026, 10, 20, 12);
      expect(wbDoneToday('2026-10-20 08:00:00', now: now), isTrue);
      expect(wbDoneToday('2026-10-19 23:00:00', now: now), isFalse);
      final todayEpoch =
          DateTime(2026, 10, 20, 9).millisecondsSinceEpoch ~/ 1000;
      expect(wbDoneToday(todayEpoch, now: now), isTrue);
      expect(wbDoneToday(todayEpoch - 86400, now: now), isFalse);
      expect(wbDoneToday(null, now: now), isFalse);
      expect(wbDoneToday('', now: now), isFalse);
    });

    test('wbSummarizeResults 汇总成败', () {
      expect(
        wbSummarizeResults({
          'results': [
            {'uid': 'a', 'ok': true},
            {'uid': 'b', 'ok': true},
          ],
        }, checkin: true),
        '签到成功 2 个',
      );
      expect(
        wbSummarizeResults({
          'results': [
            {'uid': 'b', 'nickname': '国内B', 'ok': false, 'error': '今天已签到'},
          ],
        }, checkin: true),
        '签到成功 0 个、失败 1 个（国内B：今天已签到）',
      );
      expect(wbSummarizeResults({'results': []}, checkin: false), '没有可执行的账号');
    });
  });

  group('签到中心页', () {
    late FakeHubService service;

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(home: CheckinPage(service: service)));
      await tester.pumpAndSettle();
    }

    setUp(() {
      service = FakeHubService(
        accounts: [
          account(
            uid: 'cn1',
            nick: '国内A',
            realm: 'cn',
            lastCheckin: '${todayStr()} 08:00:00',
          ),
          account(uid: 'cn2', nick: '国内B', realm: 'cn'),
          account(
            uid: 'intl1',
            nick: '国际A',
            realm: 'intl',
            // 当前时刻的 epoch 秒：减 2 小时在跨零点时会落到昨天
            lastDailyChat: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          ),
          account(uid: 'intl2', nick: '国际B', realm: 'intl'),
          account(
            uid: 'intl3',
            nick: '国际C（失效）',
            realm: 'intl',
            needRelogin: true,
          ),
        ],
        activity: [
          {
            'ts': '${todayStr()}T08:00:00',
            'uid': 'cn1',
            'nickname': '国内A',
            'realm': 'cn',
            'task': 'checkin',
            'trigger': 'manual',
            'ok': true,
            'message': '签到成功',
          },
          {
            'ts': '${todayStr()}T08:01:00',
            'uid': 'intl2',
            'nickname': '国际B',
            'realm': 'intl',
            'task': 'daily_chat',
            'trigger': 'manual',
            'ok': false,
            'message': '上游限流',
          },
        ],
      );
    });

    testWidgets('按区渲染账号与今日状态', (tester) async {
      await pump(tester);
      expect(find.text('国内版每日签到'), findsOne);
      expect(find.text('国际版每日活跃打卡'), findsOne);
      expect(find.textContaining('2 个账号，今日已签到 1 个'), findsOne);
      expect(find.textContaining('3 个账号，今日已打卡 1 个'), findsOne);
      expect(
        find.text('国内A'),
        findsAtLeastNWidgets(1),
        reason: '账号列表与活动记录各出现一次',
      );
      // 「今日已签到」在账号行与国际打卡副标题里都出现（文案前缀重叠），
      // 账号行 2 行（国内A已签 + 国际A已打卡）+ 区头统计行 1 处
      expect(find.textContaining('今日已签到'), findsAtLeastNWidgets(2));
      expect(find.textContaining('今日未签到'), findsAtLeastNWidgets(1));
      expect(find.textContaining('今日已打卡'), findsAtLeastNWidgets(2));
      expect(find.text('需重登'), findsOne);
      // 任务与福利区加入后页面变长，记录卡懒加载需滚动
      await tester.scrollUntilVisible(
        find.textContaining('上游限流'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('签到与活跃记录'), findsOne);
      expect(find.textContaining('上游限流'), findsOne);
    });

    testWidgets('一键签到 POST {}；勾选后按 uid 列表提交', (tester) async {
      await pump(tester);
      await tester.tap(find.text('一键签到'));
      await tester.pumpAndSettle();
      expect(service.posts.single.$1, '/accounts/checkin');
      expect(service.posts.single.$2, isEmpty);

      await tester.tap(find.text('国内B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('所选(1)'));
      await tester.pumpAndSettle();
      // 国内签到接口只认单 uid：勾选后逐个签
      expect(service.posts.last.$2, {'uid': 'cn2'});
    });

    testWidgets('一键打卡走 /accounts/daily-chat', (tester) async {
      await pump(tester);
      await tester.tap(find.text('一键打卡'));
      await tester.pumpAndSettle();
      expect(service.posts.single.$1, '/accounts/daily-chat');
    });

    testWidgets('需重登账号不可勾选', (tester) async {
      await pump(tester);
      await tester.tap(find.text('国际C（失效）'));
      await tester.pumpAndSettle();
      expect(find.text('所选(0)'), findsNothing);
      expect(service.posts, isEmpty);
    });
  });

  group('任务与福利纯函数', () {
    test('wbTravelLabel 四种旅行状态', () {
      expect(
        wbTravelLabel({'state': 'arrived', 'reward_credit': 80}),
        '待领奖 (+80 积分)',
      );
      expect(wbTravelLabel({'state': 'arrived'}), '待领奖');
      expect(wbTravelLabel({'state': 'traveling'}), '旅行中');
      expect(wbTravelLabel({'daily_limit_reached': true}), '今日已完成');
      expect(wbTravelLabel({}), '在家待命');
      expect(wbTravelLabel(null), '在家待命');
    });

    test('wbGrantsSum 按 hub 面板口径过滤、size||amount 取值', () {
      expect(wbGrantsSum(grantsRows(), cn: true), 1650);
      expect(wbGrantsSum(grantsRows(), cn: false), 57);
      expect(wbGrantsSum(const [], cn: true), 0);
    });

    test('wbTaskClaimable 未领取且达标才可领', () {
      expect(wbTaskClaimable({'status': 'completed'}), isTrue);
      expect(wbTaskClaimable({'status': 'claimed', 'current': 5, 'target': 5}), isFalse);
      expect(wbTaskClaimable({'status': 'in_progress', 'current': 2, 'target': 5}), isFalse);
      expect(wbTaskClaimable({'status': 'not_accepted', 'current': '5', 'target': 5}), isTrue,
          reason: 'current/target 是字符串也要按数值比');
    });
  });

  group('国内版任务与福利区', () {
    late FakeHubService service;

    Future<void> scroll(WidgetTester tester, Finder target, {double delta = 300}) =>
        tester.scrollUntilVisible(
          target,
          delta,
          scrollable: find.byType(Scrollable).first,
        );

    Future<void> pumpPage(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(home: CheckinPage(service: service)));
      await tester.pumpAndSettle();
      await scroll(tester, find.text('国内版任务与福利'));
      await tester.pumpAndSettle();
    }

    setUp(() {
      service = FakeHubService(
        accounts: [
          account(uid: 'cn1', nick: '国内A', realm: 'cn'),
          account(uid: 'cn2', nick: '国内B', realm: 'cn'),
        ],
        tasks: growthTasksPayload(),
        grants: grantsRows(),
      );
    });

    testWidgets('状态卡与任务表渲染', (tester) async {
      await pumpPage(tester);
      expect(find.text('国内版任务与福利'), findsOneWidget);
      expect(find.text('7 天'), findsOneWidget);
      expect(find.text('2 张'), findsOneWidget);
      expect(find.text('1 次'), findsOneWidget);
      expect(find.text('233'), findsOneWidget);
      expect(find.text('待领奖 (+80 积分)'), findsOneWidget);
      expect(find.text('+1650 积分'), findsOneWidget);
      expect(find.text('+57 积分'), findsOneWidget);
      // 任务表在按钮之下，滚动后才构建
      await scroll(tester, find.text('已领取'));
      await tester.pumpAndSettle();
      expect(find.text('成长任务A'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '领取'), findsOneWidget);
      expect(find.text('进行中'), findsOneWidget);
      expect(find.text('已领取'), findsOneWidget);
    });

    testWidgets('一键做任务：POST /tasks/run，logs 与汇总进流水框', (tester) async {
      await pumpPage(tester);
      await scroll(tester, find.text('一键做任务领积分'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('一键做任务领积分'));
      await tester.pumpAndSettle();
      expect(service.posts.last.$1, '/tasks/run');
      expect(service.posts.last.$2, {'claim': true});
      expect(find.textContaining('接取任务 每日签到 成功'), findsOneWidget);
      expect(
        find.textContaining('成长任务流水执行完成，共增加 +1450 积分'),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets('批量模式领单个任务被拦；选账号后带 uid+code', (tester) async {
      await pumpPage(tester);
      await scroll(tester, find.widgetWithText(TextButton, '领取'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '领取'));
      await tester.pump();
      expect(find.textContaining('领取单个任务需先在右上角选择一个国内版账号'), findsOneWidget);
      expect(service.posts.where((p) => p.$1 == '/tasks/claim'), isEmpty);

      // 下拉框在区头一行，滚回去
      await scroll(tester, find.text('全部国内账号（批量）'), delta: -300);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(DropdownMenuItem<String>, '国内A'));
      await tester.pumpAndSettle();
      expect(service.gets, contains('/tasks?uid=cn1'));

      await scroll(tester, find.widgetWithText(TextButton, '领取'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '领取'));
      await tester.pumpAndSettle();
      expect(service.posts.last.$1, '/tasks/claim');
      expect(service.posts.last.$2, {'uid': 'cn1', 'code': 'sign_in'});
      // 选中账号后，批量类写接口也收窄成 {uid}
      await tester.tap(find.text('猫猫旅行'));
      await tester.pumpAndSettle();
      expect(service.posts.last.$1, '/tasks/travel');
      expect(service.posts.last.$2, {'uid': 'cn1'});
    });

    testWidgets('连登管家与加油站签到按选择下发', (tester) async {
      await pumpPage(tester);
      await scroll(tester, find.text('连登管家与抽奖'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('连登管家与抽奖'));
      await tester.pumpAndSettle();
      expect(service.posts.last.$1, '/tasks/streak-bonus');
      expect(service.posts.last.$2, isEmpty);
      await tester.pump(const Duration(seconds: 5)); // 收掉 snackbar 再点下一个

      await tester.tap(find.text('Buddy 加油站签到'));
      await tester.pumpAndSettle();
      expect(service.posts.last.$1, '/accounts/checkin');
      expect(service.posts.last.$2, isEmpty);
    });
  });
}
