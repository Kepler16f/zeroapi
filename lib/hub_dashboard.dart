import 'package:flutter/material.dart';

import 'gateway/service.dart';
import 'gateway/workbuddy.dart';

/// WorkBuddy 号池原生看板。
///
/// 之前「管理面板」直接内嵌 WebView2 打开 hub 的网页看板，进程重、切换卡顿。
/// 这里改为全部用 Flutter 原生渲染：账号、今日用量、调度、任务、最近活动，
/// 数据来自 hub 的管理接口（面板密码登录后带 X-Panel-Token）。
/// 扫码登录等网页专属操作仍保留「用浏览器打开完整面板」入口。
class HubDashboardPage extends StatefulWidget {
  final GatewayService service;
  const HubDashboardPage({super.key, required this.service});

  @override
  State<HubDashboardPage> createState() => _HubDashboardPageState();
}

class _HubDashboardPageState extends State<HubDashboardPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _accounts = const [];
  Map<String, dynamic>? _usage;
  Map<String, dynamic>? _scheduler;
  List<Map<String, dynamic>> _tasks = const [];
  List<Map<String, dynamic>> _activity = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final s = widget.service;
    final results = await Future.wait<Object?>([
      s.hubAccounts(),
      s.hubUsageToday(),
      s.hubScheduler(),
      s.hubTasks(),
      s.hubActivity(),
    ]);
    if (!mounted) return;
    final accounts = results[0] as List<Map<String, dynamic>>;
    final usage = results[1] as Map<String, dynamic>?;
    setState(() {
      _accounts = accounts;
      _usage = usage;
      _scheduler = results[2] as Map<String, dynamic>?;
      _tasks = results[3] as List<Map<String, dynamic>>;
      _activity = results[4] as List<Map<String, dynamic>>;
      _loading = false;
      _error = accounts.isEmpty && usage == null
          ? '号池未就绪：hub 未启动，或面板登录失败（密码不是默认 admin？）'
          : null;
    });
  }

  static num _num(dynamic v) => v is num ? v : 0;
  static String _str(dynamic v) => v is String ? v : (v?.toString() ?? '');

  String _fmtTokens(num n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return n.toStringAsFixed(0);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('WorkBuddy 看板'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (v) async {
              if (v != 'browser') return;
              // 扫码登录等网页专属操作仍用系统浏览器（不再内嵌 WebView）。
              // 本机打开免密：带上面板 token，面板页收到后存 sessionStorage。
              for (final u in widget.service.config.upstreams) {
                if (u.id != 'workbuddy') continue;
                final token = await widget.service.hubPanelToken();
                await WorkBuddy.openPanel(u, token: token);
                break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'browser', child: Text('用浏览器打开完整面板（本机免密）')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null) _errorCard(cs),
                _overviewCard(cs),
                const SizedBox(height: 12),
                _accountsCard(cs),
                const SizedBox(height: 12),
                _usageCard(cs),
                const SizedBox(height: 12),
                _activityCard(cs),
                const SizedBox(height: 12),
                _tasksCard(cs),
              ],
            ),
    );
  }

  Widget _errorCard(ColorScheme cs) => Card(
    color: cs.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: cs.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: TextStyle(fontSize: 12, color: cs.error),
            ),
          ),
          TextButton(onPressed: _load, child: const Text('重试')),
        ],
      ),
    ),
  );

  Widget _stat(String title, String value, [String? sub]) => SizedBox(
    width: 170,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(fontSize: 12, color: csOf(context))),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (sub != null)
              Text(sub, style: TextStyle(fontSize: 11, color: csOf(context))),
          ],
        ),
      ),
    ),
  );

  static Color csOf(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;

  Widget _overviewCard(ColorScheme cs) {
    final ready = _accounts
        .where(
          (a) =>
              a['enabled'] == true &&
              a['tokenExpired'] != true &&
              a['needRelogin'] != true,
        )
        .length;
    final cn = _accounts.where((a) => a['realm'] == 'cn').length;
    final intl = _accounts.where((a) => a['realm'] == 'intl').length;
    final relogin = _accounts.where((a) => a['needRelogin'] == true).length;
    final u = _usage ?? const <String, dynamic>{};
    final cost = _num(u['cost_cny']);
    final credit = _num(u['credit']);
    final sched = _scheduler;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _stat(
                  '账号',
                  '$ready/${_accounts.length} 可用',
                  '国内 $cn · 国际 $intl${relogin > 0 ? ' · 需重登 $relogin' : ''}',
                ),
                _stat(
                  '今日请求',
                  _num(u['requests']).toStringAsFixed(0),
                  '失败 ${_num(u['errors']).toStringAsFixed(0)}',
                ),
                _stat(
                  '今日词元',
                  '${_fmtTokens(_num(u['prompt_tokens']))} / ${_fmtTokens(_num(u['completion_tokens']))}',
                  '输入 / 输出',
                ),
                _stat(
                  '今日成本',
                  '¥${cost.toStringAsFixed(2)}',
                  'credit ${credit.toStringAsFixed(1)}',
                ),
                _stat(
                  '调度',
                  sched == null
                      ? '未知'
                      : (sched['enabled'] == true ? '已启用' : '已停用'),
                  _str(sched?['mode_cn'] ?? sched?['mode']),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
  );

  Widget _accountsCard(ColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('账号（${_accounts.length}）'),
            if (_accounts.isEmpty)
              Text(
                '暂无账号',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              )
            else
              for (final a in _accounts) _accountRow(a, cs),
          ],
        ),
      ),
    );
  }

  Widget _accountRow(Map<String, dynamic> a, ColorScheme cs) {
    final realm = _str(a['realm']);
    final credits = a['credits'];
    double remain = 0;
    double size = 0;
    if (credits is Map) {
      remain = _num(credits['remain']).toDouble();
      size = _num(credits['size']).toDouble();
    }
    final bad = a['needRelogin'] == true || a['tokenExpired'] == true;
    final enabled = a['enabled'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.circle,
            size: 8,
            color: bad ? Colors.orange : (enabled ? Colors.green : Colors.grey),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _str(a['nickname']).isEmpty
                            ? '${_str(a['uid']).split('-').first}…'
                            : _str(a['nickname']),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _badge(
                      realm == 'cn' ? '国内' : (realm == 'intl' ? '国际' : '未知'),
                      cs.primaryContainer,
                    ),
                    if (bad) ...[
                      const SizedBox(width: 4),
                      _badge('需重登', Colors.orange.shade100),
                    ],
                  ],
                ),
                Text(
                  [
                    if (_str(a['platform']).isNotEmpty) _str(a['platform']),
                    if (_str(a['expiresIn']).isNotEmpty)
                      '到期 ${_str(a['expiresIn'])}',
                    if (_str(a['note']).isNotEmpty) _str(a['note']),
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            size > 0
                ? '${remain.toStringAsFixed(1)}/${size.toStringAsFixed(1)}'
                : '—',
            style: TextStyle(
              fontSize: 12,
              color: enabled ? null : Colors.grey,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(String text, Color bg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(text, style: const TextStyle(fontSize: 10.5)),
  );

  Widget _usageCard(ColorScheme cs) {
    final byModel = _usage?['by_model'];
    final entries = <MapEntry<String, num>>[];
    if (byModel is Map) {
      for (final e in byModel.entries) {
        final v = e.value;
        final n = v is Map ? _num(v['requests']) : _num(v);
        entries.add(MapEntry(e.key.toString(), n));
      }
    }
    entries.sort((a, b) => b.value.compareTo(a.value));
    final top = entries.take(10).toList();
    final maxV = top.isEmpty ? 1 : top.first.value;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('今日用量（按模型）'),
            if (top.isEmpty)
              Text(
                '今日暂无请求记录',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              )
            else
              for (final e in top)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 180,
                        child: Text(
                          e.key,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: maxV == 0
                                ? 0
                                : (e.value / maxV).clamp(0.02, 1.0).toDouble(),
                            child: Container(
                              height: 10,
                              decoration: BoxDecoration(
                                color: cs.primary.withValues(alpha: 0.7),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        e.value.toStringAsFixed(0),
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
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

  Widget _activityCard(ColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('最近活动'),
            if (_activity.isEmpty)
              Text(
                '暂无活动记录',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              )
            else
              for (final r in _activity.take(15))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 44,
                        child: Text(
                          _hhmm(_str(r['ts'])),
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      Icon(
                        Icons.circle,
                        size: 7,
                        color: r['ok'] == true ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 110,
                        child: Text(
                          _str(r['nickname']),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5),
                        ),
                      ),
                      SizedBox(
                        width: 90,
                        child: Text(
                          _str(r['task']),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          _str(r['message']),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
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

  Widget _tasksCard(ColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('任务'),
            if (_tasks.isEmpty)
              Text(
                '暂无任务数据',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              )
            else
              for (final t in _tasks.take(12))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.task_alt,
                        size: 13,
                        color: t['status'] == 'claimed'
                            ? Colors.green
                            : cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _str(t['name']),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      Text(
                        '${_num(t['current']).toStringAsFixed(0)}/${_num(t['target']).toStringAsFixed(0)}',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '+${_num(t['reward_credit']).toStringAsFixed(0)}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: Colors.green,
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

  static String _hhmm(String iso) {
    if (iso.length >= 16) return iso.substring(11, 16);
    return iso;
  }
}
