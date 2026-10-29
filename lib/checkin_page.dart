import 'package:flutter/material.dart';

import 'account_page.dart' show wbRealmLabel, wbRealmColor, wbWhenText;
import 'gateway/service.dart';

/// 某字段（'YYYY-MM-dd HH:mm:ss' 字符串或 epoch 秒）是否落在今天。
/// 国内签到时间用字符串、国际打卡时间用 epoch 秒，两种来源统一判。
bool wbDoneToday(Object? v, {DateTime? now}) {
  if (v == null) return false;
  final n = now ?? DateTime.now();
  if (v is num) {
    final dt = DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000);
    return dt.year == n.year && dt.month == n.month && dt.day == n.day;
  }
  String p(int x) => x.toString().padLeft(2, '0');
  return '$v'.startsWith('${n.year}-${p(n.month)}-${p(n.day)}');
}

/// 汇总 hub 写操作（签到/打卡）响应为一句人类可读结果。
String wbSummarizeResults(Map<String, dynamic> j, {required bool checkin}) {
  final raw = j['results'];
  if (raw is! List || raw.isEmpty) return '没有可执行的账号';
  var ok = 0;
  final fails = <String>[];
  for (final r in raw.whereType<Map>()) {
    if (r['ok'] == true) {
      ok++;
      continue;
    }
    final name = '${r['nickname'] ?? ''}'.trim();
    final uid = '${r['uid'] ?? ''}';
    final reason = '${r['error'] ?? r['msg'] ?? '未知原因'}';
    fails.add(
      '${name.isNotEmpty ? name : uid.substring(0, uid.length < 8 ? uid.length : 8)}：$reason',
    );
  }
  final verb = checkin ? '签到' : '打卡';
  return fails.isEmpty
      ? '$verb成功 $ok 个'
      : '$verb成功 $ok 个、失败 ${fails.length} 个（${fails.join('；')}）';
}

/// 猫猫旅行状态 → 中文标签（hub 面板 loadGrowthTasks 里 catState 的同一判法）。
String wbTravelLabel(Map<String, dynamic>? travel) {
  final tr = travel ?? const {};
  if (tr['state'] == 'arrived') {
    final c = tr['reward_credit'];
    return c is num && c > 0 ? '待领奖 (+$c 积分)' : '待领奖';
  }
  if (tr['state'] == 'traveling') return '旅行中';
  if (tr['daily_limit_reached'] == true) return '今日已完成';
  return '在家待命';
}

/// 福利总积分：GET /accounts/credits/grants 的 rows 按 hub 面板同口径过滤求和。
/// cn 计签到/成长/活动/裂变来源；intl 计 Bonus Pack 或活跃来源。
/// JS 的 `size || amount` 语义：size 为 0/缺失才落到 amount。
int wbGrantsSum(List rows, {required bool cn}) {
  var total = 0;
  for (final x in rows.whereType<Map>()) {
    if ('${x['realm']}' != (cn ? 'cn' : 'intl')) continue;
    final name = '${x['name'] ?? ''}';
    if (cn) {
      final reason = '${x['grant_reason'] ?? ''}';
      final hit =
          reason.contains('签到') ||
          reason.contains('成长') ||
          reason.contains('活动') ||
          reason.contains('裂变') ||
          name.contains('裂变');
      if (!hit) continue;
    } else {
      final inferred = '${x['source_inferred'] ?? ''}';
      if (!(name == 'Bonus Pack' || inferred.contains('活跃'))) continue;
    }
    final size = x['size'];
    final amt = x['amount'];
    final v = (size is num && size != 0)
        ? size
        : (amt is num ? amt : 0);
    total += v.toInt();
  }
  return total;
}

/// uid 短显（前 6 位，容忍短 uid）。
String _shortUid(String uid) => uid.substring(0, uid.length < 6 ? uid.length : 6);

/// 任务可否领奖：未领取且（已完成或进度达标）——hub 表格「领取」按钮的判法。
bool wbTaskClaimable(Map t) {
  final status = '${t['status']}';
  if (status == 'claimed') return false;
  num n(Object? v) => v is num ? v : num.tryParse('$v') ?? 0;
  return status == 'completed' || n(t['current']) >= n(t['target']);
}

/// WorkBuddy 号池「签到」原生页（移植自 hub 网页面板的签到区）。
///
/// 四块：
///  1. 国内版每日签到（POST /accounts/checkin）：全部或指定账号；
///  2. 国际版每日活跃打卡（POST /accounts/daily-chat）：全部或指定账号；
///  3. 国内版任务与福利（GET /tasks + run/claim/travel/streak-bonus +
///     credits/grants）：账号选择、状态卡、成长任务表、流水日志；
///  4. 签到与活跃记录（GET /activity/history）：按时间/账号/任务/结果筛选。
///
/// 账号状态行直接吃 hub /accounts 的 public() 视图：lastCheckin（国内签到
/// 时间）与 lastDailyChat（国际打卡时间，epoch 秒）用来标「今日已/未」。
class CheckinPage extends StatefulWidget {
  final GatewayService service;
  const CheckinPage({super.key, required this.service});

  @override
  State<CheckinPage> createState() => _CheckinPageState();
}

class _CheckinPageState extends State<CheckinPage> {
  bool _loading = true;
  bool _busyCheckin = false;
  bool _busyChat = false;
  String? _error;
  List<Map<String, dynamic>> _accounts = const [];
  List<Map<String, dynamic>> _activity = const [];
  String _range = '7d';

  // —— 国内版任务与福利（hub「任务与福利」页 sectionGrowthTasks 的原生移植）——
  /// 成长面板当前选择的国内账号：'all' = 批量。写接口的 {uid?} 全按它下发。
  String _growthUid = 'all';
  List<Map<String, dynamic>> _growthTasks = const [];
  Map<String, dynamic> _growthSummary = const {};
  /// GET /tasks 的 accounts 字段：[{uid, nickname}]，喂给账号下拉框。
  List<Map<String, dynamic>> _growthAccounts = const [];
  /// GET /accounts/credits/grants 的 rows：算两区「已获取福利总积分」。
  List<Map<String, dynamic>> _grants = const [];
  bool _busyRun = false;
  bool _busyTravel = false;
  bool _busyStreak = false;
  /// 正在领取中的任务代码（单行 loading，其余领取按钮禁用）。
  String? _busyClaimCode;
  /// 任务流水（一键做任务的 logs + 领取/旅行/连登结果），hub 的 taskLogBox 同款。
  List<String> _taskLog = const [];

  /// 按区分开的勾选集合：两区各一个，避免「勾了国内账号却给国际打卡」
  final Set<String> _selectedCn = {};
  final Set<String> _selectedIntl = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final s = widget.service;
    final uidQ = _growthUid == 'all'
        ? ''
        : '?uid=${Uri.encodeComponent(_growthUid)}';
    final results = await Future.wait([
      s.hubAccounts(),
      s.hubActivity(limit: 100, range: _range),
      s.hubGet('/tasks$uidQ'),
      s.hubGet('/accounts/credits/grants'),
    ]);
    if (!mounted) return;
    final accounts = results[0] as List<Map<String, dynamic>>;
    final tasksJ = (results[2] as Map<String, dynamic>?) ?? const {};
    final grantRows = (results[3] as Map<String, dynamic>?)?['rows'];
    setState(() {
      _accounts = accounts;
      _activity = results[1] as List<Map<String, dynamic>>;
      _growthTasks = [
        for (final t in (tasksJ['tasks'] as List? ?? const []))
          if (t is Map<String, dynamic>) t,
      ];
      final sum = tasksJ['summary'];
      _growthSummary = sum is Map<String, dynamic> ? sum : const {};
      _growthAccounts = [
        for (final a in (tasksJ['accounts'] as List? ?? const []))
          if (a is Map<String, dynamic>) a,
      ];
      _grants = [
        for (final x in (grantRows as List? ?? const []))
          if (x is Map<String, dynamic>) x,
      ];
      // 之前选中的账号退出任务池/被删了就回到「全部」
      if (_growthUid != 'all' &&
          !_growthAccounts.any((a) => '${a['uid']}' == _growthUid)) {
        _growthUid = 'all';
      }
      _loading = false;
      _error = _accounts.isEmpty ? '号池未就绪：hub 未启动，或面板登录失败' : null;
      // 已不可用（禁用/需重登）的选中项清掉
      final actionable = <String>{
        for (final a in accounts)
          if (_actionable(a)) '${a['uid']}',
      };
      _selectedCn.retainWhere(actionable.contains);
      _selectedIntl.retainWhere(actionable.contains);
    });
  }

  List<Map<String, dynamic>> get _cnAccounts =>
      _accounts.where((a) => '${a['realm']}' == 'cn').toList();
  List<Map<String, dynamic>> get _intlAccounts =>
      _accounts.where((a) => '${a['realm']}' == 'intl').toList();

  bool _actionable(Map<String, dynamic> a) =>
      a['enabled'] == true && a['needRelogin'] != true;

  /// 今日是否已签到/打卡：lastCheckin 是 'YYYY-MM-dd HH:mm:ss' 字符串，
  /// lastDailyChat 是 epoch 秒数字（wbDoneToday 两种都认）。
  bool _doneToday(Map<String, dynamic> a, String field) =>
      wbDoneToday(a[field]);

  Future<void> _run({required bool checkin, List<String>? uids}) async {
    if (checkin && _busyCheckin) return;
    if (!checkin && _busyChat) return;
    setState(() => checkin ? _busyCheckin = true : _busyChat = true);
    String msg;
    try {
      if (checkin) {
        // hub 的签到接口只认单个 uid（{uid}）或全部（{}）；多选时逐个签
        // 并在本地合并结果，未选中就发 {} 签全部国内账号。
        final results = <Map<String, dynamic>>[];
        if (uids == null) {
          final j = await widget.service.hubPost(
            '/accounts/checkin',
            const {},
            timeout: const Duration(seconds: 90),
          );
          results.addAll(_rowsOf(j));
        } else {
          for (final uid in uids) {
            final j = await widget.service.hubPost('/accounts/checkin', {
              'uid': uid,
            }, timeout: const Duration(seconds: 90));
            results.addAll(_rowsOf(j));
          }
        }
        msg = wbSummarizeResults({'results': results}, checkin: true);
      } else {
        // 国际每日活跃：hub 支持 uids 精确名单（空名单一个都不打）
        final body = uids == null ? <String, dynamic>{} : {'uids': uids};
        final j = await widget.service.hubPost(
          '/accounts/daily-chat',
          body,
          timeout: const Duration(seconds: 120),
        );
        msg = wbSummarizeResults(j, checkin: false);
      }
    } catch (e) {
      msg = '${checkin ? '签到' : '打卡'}失败：$e';
    }
    if (!mounted) return;
    setState(() => checkin ? _busyCheckin = false : _busyChat = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    await _load();
  }

  static List<Map<String, dynamic>> _rowsOf(Map<String, dynamic> j) {
    final raw = j['results'];
    if (raw is! List) return const [];
    return [for (final r in raw.whereType<Map>()) Map<String, dynamic>.from(r)];
  }

  // —— 国内版任务与福利：写操作（端点与 hub 面板一一对应）——

  /// 当前选择 → hub 写接口的可选 uid 载荷：'all' 时传 {} 即批量。
  Map<String, dynamic> _uidBody() =>
      _growthUid == 'all' ? <String, dynamic>{} : {'uid': _growthUid};

  void _logTask(String line) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    setState(() => _taskLog = [..._taskLog, '[$t] $line']);
  }

  /// 一键做任务领积分：POST /tasks/run → logs[] 逐行进流水、credit_added 汇总。
  Future<void> _runGrowthTasks() async {
    if (_busyRun) return;
    setState(() => _busyRun = true);
    _logTask('[task_runner] 启动任务接取、事件上报与奖励领取…');
    var msg = '成长任务流水执行完成';
    try {
      final j = await widget.service.hubPost(
        '/tasks/run',
        {..._uidBody(), 'claim': true},
        timeout: const Duration(minutes: 3),
      );
      for (final l in (j['logs'] as List? ?? const [])) {
        _logTask('$l');
      }
      final added = j['credit_added'];
      if (added is num && added != 0) msg += '，共增加 +$added 积分';
      _logTask(msg);
    } catch (e) {
      msg = '任务执行失败：$e';
      _logTask(msg);
    }
    if (!mounted) return;
    setState(() => _busyRun = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    await _load();
  }

  /// 猫猫旅行：POST /tasks/travel → {ok,msg} 或批量 {ok,results[]}。
  Future<void> _runCatTravel() async {
    if (_busyTravel) return;
    setState(() => _busyTravel = true);
    var msg = '猫猫旅行';
    try {
      final j = await widget.service.hubPost('/tasks/travel', _uidBody());
      final results = _rowsOf(j);
      msg = results.isEmpty
          ? '${j['msg'] ?? (j['ok'] == true ? '旅行已出发' : '旅行未执行')}'
          : results.map((r) {
              final uid = '${r['uid'] ?? ''}';
              final nick = '${r['nickname']}'.trim().isEmpty
                  ? uid.substring(0, uid.length < 6 ? uid.length : 6)
                  : '${r['nickname']}';
              final ok = r['ok'] == true;
              return '$nick：${ok ? (r['msg'] ?? '旅行已出发') : (r['error'] ?? r['msg'] ?? '失败')}';
            }).join('；');
    } catch (e) {
      msg = '猫猫旅行失败：$e';
    }
    if (!mounted) return;
    setState(() => _busyTravel = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    await _load();
  }

  /// 连登管家与抽奖：POST /tasks/streak-bonus → {ok,msg}。
  Future<void> _runStreakBonus() async {
    if (_busyStreak) return;
    setState(() => _busyStreak = true);
    var msg = '连登管家与抽奖';
    try {
      final j = await widget.service.hubPost(
        '/tasks/streak-bonus',
        _uidBody(),
        timeout: const Duration(minutes: 2),
      );
      msg = '${j['msg'] ?? (j['ok'] == true ? '执行完成' : '操作未完成')}';
    } catch (e) {
      msg = '连登管家执行失败：$e';
    }
    if (!mounted) return;
    setState(() => _busyStreak = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    await _load();
  }

  /// 单个任务领取：POST /tasks/claim {uid, code}——hub 同款要求先选具体账号。
  Future<void> _claimTask(String code) async {
    if (_busyClaimCode != null) return;
    if (_growthUid == 'all') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('领取单个任务需先在右上角选择一个国内版账号')),
      );
      return;
    }
    setState(() => _busyClaimCode = code);
    var msg = '';
    try {
      final j = await widget.service.hubPost(
        '/tasks/claim',
        {'uid': _growthUid, 'code': code},
      );
      final credit = j['credit'];
      msg = '${j['msg'] ?? (j['ok'] == true ? '领取成功' : '领取失败')}';
      if (j['ok'] == true && credit is num && credit != 0) {
        msg += '（+$credit 积分）';
      }
    } catch (e) {
      msg = '领取失败：$e';
    }
    if (!mounted) return;
    setState(() => _busyClaimCode = null);
    _logTask('领取 $code：$msg');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('WorkBuddy 签到'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Card(
                    color: cs.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        _error!,
                        style: TextStyle(color: cs.onErrorContainer),
                      ),
                    ),
                  ),
                _section(
                  title: '国内版每日签到',
                  subtitle: 'Buddy 加油站签到（仅国内账号；企业版不支持）',
                  busy: _busyCheckin,
                  count: _cnAccounts.length,
                  doneCount: _cnAccounts
                      .where((a) => _doneToday(a, 'lastCheckin'))
                      .length,
                  onAll: () => _run(checkin: true),
                  onSelected: _selectedCn.isEmpty
                      ? null
                      : () => _run(checkin: true, uids: _selectedCn.toList()),
                  selectedCount: _selectedCn.length,
                  buttonLabel: '签到',
                ),
                _accountList(
                  _cnAccounts,
                  field: 'lastCheckin',
                  selected: _selectedCn,
                ),
                const SizedBox(height: 16),
                _section(
                  title: '国际版每日活跃打卡',
                  subtitle: '每日对话任务（仅国际账号）',
                  busy: _busyChat,
                  count: _intlAccounts.length,
                  doneCount: _intlAccounts
                      .where((a) => _doneToday(a, 'lastDailyChat'))
                      .length,
                  onAll: () => _run(checkin: false),
                  onSelected: _selectedIntl.isEmpty
                      ? null
                      : () =>
                            _run(checkin: false, uids: _selectedIntl.toList()),
                  selectedCount: _selectedIntl.length,
                  buttonLabel: '打卡',
                ),
                _accountList(
                  _intlAccounts,
                  field: 'lastDailyChat',
                  selected: _selectedIntl,
                ),
                const SizedBox(height: 20),
                _growthSection(cs),
                const SizedBox(height: 20),
                _activityCard(cs),
                const SizedBox(height: 40),
              ],
            ),
    );
  }

  Widget _section({
    required String title,
    required String subtitle,
    required bool busy,
    required int count,
    required int doneCount,
    required VoidCallback onAll,
    VoidCallback? onSelected,
    required int selectedCount,
    required String buttonLabel,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  Text(
                    count == 0
                        ? subtitle
                        : '$subtitle · $count 个账号，今日已$buttonLabel $doneCount 个',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (onSelected != null)
              OutlinedButton.icon(
                onPressed: busy ? null : onSelected,
                icon: const Icon(Icons.checklist, size: 16),
                label: Text('所选($selectedCount)'),
              ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: busy || count == 0 ? null : onAll,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.event_available, size: 16),
              label: Text(busy ? '$buttonLabel中…' : '一键$buttonLabel'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _accountList(
    List<Map<String, dynamic>> accounts, {
    required String field,
    required Set<String> selected,
  }) {
    final cs = Theme.of(context).colorScheme;
    if (accounts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '（没有该区域的账号）',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      );
    }
    return Column(
      children: [
        for (final a in accounts)
          CheckboxListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            controlAffinity: ListTileControlAffinity.leading,
            value: selected.contains('${a['uid']}'),
            onChanged: _actionable(a)
                ? (v) => setState(() {
                    v == true
                        ? selected.add('${a['uid']}')
                        : selected.remove('${a['uid']}');
                  })
                : null,
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    '${a['nickname'] ?? '${a['uid']}'}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5),
                  ),
                ),
                const SizedBox(width: 6),
                _badge(
                  wbRealmLabel('${a['realm']}'),
                  wbRealmColor('${a['realm']}', cs),
                ),
                if (a['enabled'] != true)
                  _badge('禁用', cs.surfaceContainerHighest),
                if (a['needRelogin'] == true) _badge('需重登', cs.errorContainer),
              ],
            ),
            subtitle: Text(
              _doneToday(a, field)
                  ? '今日已${field == 'lastCheckin' ? '签到' : '打卡'}（${wbWhenText(a[field])}）'
                  : '今日未${field == 'lastCheckin' ? '签到' : '打卡'}'
                        '${a[field] != null ? ' · 上次 ${wbWhenText(a[field])}' : ''}',
              style: TextStyle(
                fontSize: 11.5,
                color: _doneToday(a, field)
                    ? Colors.green.shade700
                    : cs.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }

  Widget _activityCard(ColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '签到与活跃记录',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                for (final r in const ['today', '7d', '30d'])
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: ChoiceChip(
                      label: Text(r == 'today' ? '今日' : r),
                      selected: _range == r,
                      onSelected: (_) {
                        setState(() => _range = r);
                        _load();
                      },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_activity.isEmpty)
              Text(
                '这个区间里没有签到或活跃记录。',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            for (final row in _activity)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(
                      row['ok'] == true
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 15,
                      color: row['ok'] == true
                          ? Colors.green.shade600
                          : cs.error,
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 120,
                      child: Text(
                        wbWhenText(row['ts']),
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 130,
                      child: Text(
                        '${row['nickname']}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    _badge(
                      row['task'] == 'checkin' ? '签到' : '活跃',
                      row['task'] == 'checkin'
                          ? cs.primaryContainer
                          : cs.secondaryContainer,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${row['message'] ?? ''}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 国内版任务与福利区：移植 hub「任务与福利」页 sectionGrowthTasks——
  /// 账号下拉（全部/单个，写操作按它下发）、状态卡、四个动作按钮、
  /// 成长任务表（可领取行带领取按钮）与任务流水框。
  Widget _growthSection(ColorScheme cs) {
    final travel = _growthSummary['travel'];
    final doneCn = _cnAccounts.where((a) => _doneToday(a, 'lastCheckin')).length;
    Object? sum(String k) => _growthSummary.isEmpty ? null : _growthSummary[k];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '国内版任务与福利',
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '自动接取成长任务、事件上报点亮并领取官方积分，以及猫猫日常与连登奖励',
                        style: TextStyle(fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
                DropdownButton<String>(
                  value: _growthAccounts.any((a) => '${a['uid']}' == _growthUid)
                      ? _growthUid
                      : 'all',
                  style: TextStyle(fontSize: 12, color: cs.onSurface),
                  items: [
                    const DropdownMenuItem(
                      value: 'all',
                      child: Text('全部国内账号（批量）'),
                    ),
                    for (final a in _growthAccounts)
                      DropdownMenuItem(
                        value: '${a['uid']}',
                        child: Text(
                          '${a['nickname'] ?? ''}'.trim().isEmpty
                              ? _shortUid('${a['uid'] ?? ''}')
                              : '${a['nickname']}',
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    if (v == null || v == _growthUid) return;
                    setState(() => _growthUid = v);
                    _load();
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _miniStat(cs, '本期加油站签到', _cnAccounts.isEmpty ? '无国内账号' : '今日已签 $doneCn/${_cnAccounts.length}'),
                _miniStat(cs, '当前连续登录天数', sum('streak_days') == null ? '-' : '${sum('streak_days')} 天'),
                _miniStat(cs, '补签卡余额', sum('makeup_cards') == null ? '-' : '${sum('makeup_cards')} 张'),
                _miniStat(cs, '成长抽奖次数', sum('lottery_chances') == null ? '-' : '${sum('lottery_chances')} 次'),
                _miniStat(
                  cs,
                  '猫猫旅行状态',
                  wbTravelLabel(travel is Map ? Map<String, dynamic>.from(travel) : null),
                ),
                _miniStat(cs, '成长能量余额', sum('energy') == null ? '-' : '${sum('energy')}'),
                _miniStat(cs, '已获取福利总积分（国内）', '+${wbGrantsSum(_grants, cn: true)} 积分'),
                _miniStat(cs, '国际版已获取福利', '+${wbGrantsSum(_grants, cn: false)} 积分'),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _busyCheckin || _cnAccounts.isEmpty
                      ? null
                      : () => _run(
                          checkin: true,
                          uids: _growthUid == 'all' ? null : [_growthUid],
                        ),
                  child: Text(_busyCheckin ? '签到中…' : 'Buddy 加油站签到'),
                ),
                FilledButton(
                  onPressed: _busyRun ? null : _runGrowthTasks,
                  child: Text(_busyRun ? '任务执行中…' : '一键做任务领积分'),
                ),
                OutlinedButton(
                  onPressed: _busyTravel ? null : _runCatTravel,
                  child: Text(_busyTravel ? '旅行中…' : '猫猫旅行'),
                ),
                OutlinedButton(
                  onPressed: _busyStreak ? null : _runStreakBonus,
                  child: Text(_busyStreak ? '执行中…' : '连登管家与抽奖'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_growthTasks.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text('暂无任务或未登录国内版账号', style: TextStyle(fontSize: 12)),
              )
            else
              Column(
                children: [for (final t in _growthTasks) _taskRow(cs, t)],
              ),
            if (_taskLog.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                height: 150,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.outlineVariant),
                ),
                child: ListView(
                  children: [
                    for (final l in _taskLog)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          l,
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 小号状态卡（hub 面板 cards 的原生对应）：上标签、下数值。
  Widget _miniStat(ColorScheme cs, String k, String v) => Container(
    width: 150,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      border: Border.all(color: cs.outlineVariant),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          k,
          style: TextStyle(fontSize: 10.5, color: cs.onSurfaceVariant),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          v,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );

  /// 成长任务一行：名称/代码、说明、进度、奖励、状态（可领取时给领取按钮）。
  Widget _taskRow(ColorScheme cs, Map<String, dynamic> t) {
    final status = '${t['status']}';
    final claimable = wbTaskClaimable(t);
    final claimed = status == 'claimed';
    final prog = claimed || status == 'completed'
        ? '已达成'
        : '${t['current'] ?? 0} / ${t['target'] ?? 0}';
    final credit = t['reward_credit'];
    final energy = t['reward_energy'];
    final reward = [
      if (credit is num && credit != 0) '+$credit 积分',
      if (energy is num && energy != 0) '+$energy 能量',
    ].join(' ');
    final (badgeText, badgeBg) = claimed
        ? ('已领取', cs.surfaceContainerHighest)
        : claimable
        ? ('待领奖', cs.tertiaryContainer)
        : (status == 'accepted' || status == 'in_progress')
        ? ('进行中', cs.primaryContainer)
        : ('未接取', cs.surfaceContainerHighest);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${t['name'] ?? t['task_code']}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                Text(
                  '${t['task_code'] ?? ''}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '${t['description'] ?? '-'}',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
              ),
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(prog, style: const TextStyle(fontSize: 12)),
          ),
          SizedBox(
            width: 104,
            child: Text(
              reward.isEmpty ? '-' : reward,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          _badge(badgeText, badgeBg),
          if (claimable)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: SizedBox(
                height: 26,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _busyClaimCode != null ? null : () => _claimTask('${t['task_code']}'),
                  child: _busyClaimCode == '${t['task_code']}'
                      ? const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('领取', style: TextStyle(fontSize: 12)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _badge(String text, Color bg) => Container(
    margin: const EdgeInsets.only(left: 4),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(text, style: const TextStyle(fontSize: 10.5)),
  );
}
