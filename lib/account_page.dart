import 'package:flutter/material.dart';

import 'gateway/accountdata.dart';
import 'gateway/config.dart';
import 'gateway/service.dart';
import 'checkin_page.dart';
import 'hub_dashboard.dart';

// ---------------- 纯函数：格式化与文案（account_page_test 直接测这几条） ----------------

const _cnRealms = {'cn', 'china', 'domestic', '国内'};
const _intlRealms = {'intl', 'international', 'global', '国际'};

/// realm 原始值（'cn' / 'intl' / 其它）→ 徽标文字。
String wbRealmLabel(String realm) {
  final r = realm.trim().toLowerCase();
  if (_cnRealms.contains(r)) return '国内';
  if (_intlRealms.contains(r)) return '国际';
  return '未知';
}

/// 账号行状态：风控中优先于禁用（风控期即使账号被启用也不能用）。
String wbStatusLabel({required bool enabled, required bool restricted}) {
  if (restricted) return '风控中';
  if (!enabled) return '禁用';
  return '可用';
}

Color wbStatusColor(String status) => switch (status) {
  '可用' => Colors.green,
  '风控中' => Colors.orange,
  _ => Colors.grey,
};

/// 显示名：有昵称用昵称，没有就用 uid 前 8 位（带省略号）。
String wbDisplayLabel({required String nickname, required String uid}) {
  final n = nickname.trim();
  if (n.isNotEmpty) return n;
  if (uid.length <= 8) return uid.isEmpty ? '—' : uid;
  return '${uid.substring(0, 8)}…';
}

/// 额度：保留 1 位小数（100000 → '100000.0'）
String wbCreditsText(double v) => v.toStringAsFixed(1);

/// 成本：人民币，保留 2 位小数（0.1267 → '¥0.13'）
String wbCnyText(double v) => '¥${v.toStringAsFixed(2)}';

/// 词元数：≥1000 缩写成 k。
String wbTokensText(double v) =>
    v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : v.toStringAsFixed(0);

String _p2(int v) => v.toString().padLeft(2, '0');

/// 时间/日期统一渲染成 'YYYY-MM-dd HH:mm'（空值 → '—'）。
/// 兼容 [DateTime] 与 ISO 字符串两种来源；只取能解析到的部分。
String wbWhenText(Object? v) {
  if (v == null) return '—';
  final s = v is DateTime ? v.toIso8601String() : v.toString().trim();
  if (s.isEmpty) return '—';
  final m = RegExp(r'^(\d{4}-\d{2}-\d{2})(?:T| )?(\d{2}:\d{2})?').firstMatch(s);
  if (m == null) return s;
  final date = m.group(1)!;
  final hm = m.group(2);
  return hm == null ? date : '$date $hm';
}

/// 数据加载时刻，标题栏显示。
String wbClockText(DateTime? t) {
  if (t == null) return '—';
  return '${_p2(t.hour)}:${_p2(t.minute)}:${_p2(t.second)}';
}

// ---------------- 页面 ----------------

class AccountPage extends StatefulWidget {
  final GatewayService service;
  const AccountPage({super.key, required this.service});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  WbOverview? _overview;
  String? _error;
  bool _loading = false;

  /// 一键签到进行中：按钮禁用并转圈

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 重新拉取号池概览。失败必须显式提示，不能静默。
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final o = await widget.service.loadWorkBuddyOverview();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _overview = o;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '号池概览加载失败：$e';
      });
    }
  }

  /// workbuddy 供应商定义；`hasWorkBuddy == true` 时应当存在。
  UpstreamDef? get _wbDef => widget.service.config.upstreams
      .where((u) => u.id == 'workbuddy')
      .toList()
      .firstOrNull;

  Future<void> _openPanel() async {
    if (_wbDef == null) return;
    // 原生看板（不再内嵌 WebView）；扫码登录等网页操作在页内菜单里用浏览器打开
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HubDashboardPage(service: widget.service),
      ),
    );
  }

  Future<void> _connect() async {
    final err = await widget.service.addWorkBuddy();
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    } else {
      await _load();
    }
  }

  Future<void> _openCheckin() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CheckinPage(service: widget.service)),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: widget.service,
      builder: (context, _) {
        if (!widget.service.hasWorkBuddy) return _notConnected(cs);
        final o = _overview;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _header(cs),
            if (_error != null) ...[
              _errorCard(cs, _error!),
              const SizedBox(height: 10),
            ],
            if (o == null) _notReadyCard(cs) else ..._content(cs, o),
            const SizedBox(height: 80),
          ],
        );
      },
    );
  }

  /// 供应商列表里没有 WorkBuddy：给出接入入口。
  Widget _notConnected(ColorScheme cs) {
    return Center(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.workspaces_outline, size: 40, color: cs.primary),
              const SizedBox(height: 10),
              const Text(
                '未接入 WorkBuddy 号池',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                '内置 workbuddy2api-hub：多账号轮换、登录/桌面端导入、签到保活；'
                '接入后可在此页看账号额度与今日用量。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              FilledButton.tonal(
                onPressed: _connect,
                child: const Text('接入 WorkBuddy 号池'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ColorScheme cs) {
    final d = _wbDef;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'WorkBuddy 号池',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 2),
              Text(
                d == null
                    ? '供应商定义缺失'
                    : '更新于 ${wbClockText(_overview?.loadedAt)}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
        // 签到中心：国内签到 / 国际打卡 / 签到记录（原生页，不再跳网页面板）
        TextButton.icon(
          onPressed: _loading ? null : _openCheckin,
          icon: const Icon(Icons.event_available, size: 16),
          label: const Text('签到中心'),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: _loading ? '加载中' : '刷新',
          onPressed: _loading ? null : _load,
          icon: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(),
                )
              : const Icon(Icons.refresh),
        ),
      ],
    );
  }

  Widget _errorCard(ColorScheme cs, String msg) {
    return Card(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: cs.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                msg,
                style: TextStyle(fontSize: 12, color: cs.onErrorContainer),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 已接入但还没拉到概览：hub 未启动或还没有账号。
  Widget _notReadyCard(ColorScheme cs) {
    final d = _wbDef;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 36,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(height: 10),
            const Text(
              '号池未就绪（hub 未启动或还没账号）',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              '网关未运行，或 WorkBuddy hub 里还没有登录任何账号。'
              '打开管理面板登录账号后回到本页刷新即可。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: d == null ? null : _openPanel,
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('管理面板'),
                ),
                TextButton.icon(
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重试'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _content(ColorScheme cs, WbOverview o) {
    return [
      _stats(cs, o),
      const SizedBox(height: 10),
      _realmPreference(cs),
      const SizedBox(height: 10),
      _accountsCard(cs, o),
    ];
  }

  /// 双出口共有模型的优先区（gpt-*/minimax-* 等独占模型不受影响，
  /// 恒走自己唯一的出口区）。切换即时生效。
  Widget _realmPreference(ColorScheme cs) {
    final cur = widget.service.config.workbuddyPreferredRealm;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '共有模型优先出口',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    '两区都提供的模型（hy3 / glm-5.3…）优先走哪边；'
                    '该区的账号并发跑满时自动溢出到另一区（避免两个会话同模型'
                    '撞 429），同会话仍粘在同一区。独占模型不受影响',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SegmentedButton<String>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity(horizontal: -4),
              ),
              segments: const [
                ButtonSegment(value: '', label: Text('跟随号池')),
                ButtonSegment(value: 'cn', label: Text('国内')),
                ButtonSegment(value: 'intl', label: Text('国际')),
              ],
              selected: {cur},
              onSelectionChanged: (sel) =>
                  widget.service.setWorkbuddyPreferredRealm(sel.first),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stats(ColorScheme cs, WbOverview o) {
    // 今日请求/成本两块已合并进「用量」页，这里只保留账号与额度维度
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _stat(
          '账号',
          '${o.ready}/${o.total} 可用',
          '国内 ${o.cnCount} / 国际 ${o.intlCount} · 今日签到 ${o.checkedInToday}',
        ),
        _stat(
          '额度',
          wbCreditsText(o.totalRemain),
          '剩余（已用 ${wbCreditsText(o.totalUsed)}）',
        ),
      ],
    );
  }

  Widget _stat(String title, String value, String sub) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 2),
            Text(
              sub,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _accountsCard(ColorScheme cs, WbOverview o) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Row(
                children: [
                  const Text(
                    '账号列表',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${o.accounts.length} 个',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            for (var i = 0; i < o.accounts.length; i++) ...[
              Divider(height: 1, indent: 12, endIndent: 12),
              _accountRow(o.accounts[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _accountRow(WbAccountView a) {
    final cs = Theme.of(context).colorScheme;
    final status = wbStatusLabel(enabled: a.enabled, restricted: a.restricted);
    final sc = wbStatusColor(status);
    final label = wbDisplayLabel(nickname: a.nickname, uid: a.uid);
    final dim = !a.enabled;
    final fg = dim ? Colors.grey : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.circle, size: 10, color: sc),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: fg,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _badge(wbRealmLabel(a.realm), wbRealmColor(a.realm, cs)),
                    if (a.platform.trim().isNotEmpty) ...[
                      const SizedBox(width: 6),
                      _badge(a.platform.trim(), cs.surfaceContainerHighest),
                    ],
                    const SizedBox(width: 6),
                    Text(status, style: TextStyle(fontSize: 12, color: sc)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '套餐 ${a.planName.isEmpty ? '—' : a.planName}'
                  ' · 到期 ${wbWhenText(a.expiresAt)}'
                  ' · 最近签到 ${wbWhenText(a.lastCheckin)}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (a.note.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      a.note.trim(),
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${wbCreditsText(a.creditsRemain)} 剩余额度',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
              if (a.creditsSize > 0)
                Text(
                  '${wbCreditsText(a.creditsSize)} 总量',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _badge(String text, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: const TextStyle(fontSize: 10.5)),
    );
  }
}

/// realm 徽标底色：国内/国际用主题容器色区分，未知走最浅一级。
Color wbRealmColor(String realm, ColorScheme cs) {
  switch (wbRealmLabel(realm)) {
    case '国内':
      return cs.primaryContainer;
    case '国际':
      return cs.secondaryContainer;
    default:
      return cs.surfaceContainerHighest;
  }
}
