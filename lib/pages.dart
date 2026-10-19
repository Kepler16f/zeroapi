import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../gateway/cf_api.dart';
import '../gateway/config.dart';
import '../gateway/lan.dart';
import '../gateway/proxy.dart';
import '../gateway/service.dart';
import '../gateway/upstream.dart';
import '../gateway/workerdeploy.dart';
import '../version.dart';

// ---------------- 供应商页 ----------------

class UpstreamsPage extends StatelessWidget {
  final GatewayService service;
  const UpstreamsPage({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final ups = service.upstreams;
        return Stack(
          children: [
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (service.startError != null)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('网关启动失败：${service.startError}（端口被占用？去设置页改端口）'),
                    ),
                  ),
                ...ups.map((u) => _UpstreamCard(service: service, rt: u)),
                const SizedBox(height: 80),
              ],
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.extended(
                icon: const Icon(Icons.add),
                label: const Text('接入新供应商'),
                onPressed: () => _showUpstreamEditor(context, service, null),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _UpstreamCard extends StatelessWidget {
  final GatewayService service;
  final UpstreamRuntime rt;
  const _UpstreamCard({required this.service, required this.rt});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final d = rt.def;
    final healthColor = switch (rt.health) {
      UpstreamHealth.healthy => Colors.green,
      UpstreamHealth.down => cs.error,
      _ => Colors.grey,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: healthColor),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    d.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                if (rt.health == UpstreamHealth.checking) ...[
                  const SizedBox(width: 8),
                  Text('启动中…',
                      style: TextStyle(
                          fontSize: 11.5, color: cs.onSurfaceVariant)),
                ],
                if (d.label.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text('id: ${d.id}',
                      style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: cs.onSurfaceVariant)),
                ],
                const SizedBox(width: 8),
                Chip(
                  label: Text(d.typeLabel,
                      style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                ),
                const Spacer(),
                Switch(
                  value: d.enabled,
                  onChanged: (v) => service.toggleUpstream(rt, v),
                ),
                PopupMenuButton<String>(
                  onSelected: (cmd) {
                    if (cmd == 'edit') {
                      _showUpstreamEditor(context, service, rt);
                    } else if (cmd == 'delete') {
                      service.removeUpstream(rt);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('编辑')),
                    PopupMenuItem(value: 'delete', child: Text('移除')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (!d.isManaged && d.type != 'zen')
              Text(d.baseUrl,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.view_in_ar, size: 14, color: cs.onSurfaceVariant),
              const SizedBox(width: 4),
              Text('模型 ${rt.models.length} 个',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              const SizedBox(width: 16),
              Icon(Icons.call_made, size: 14, color: cs.onSurfaceVariant),
              const SizedBox(width: 4),
              Text('请求 ${rt.requests} 次',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              if (rt.child != null) ...[
                const SizedBox(width: 16),
                Icon(Icons.terminal, size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 4),
                Text('子进程 pid=${rt.child!.pid}',
                    style:
                        TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ]),
            if (rt.lastError != null && rt.health == UpstreamHealth.down)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('最近错误：${rt.lastError}',
                    style: TextStyle(fontSize: 11, color: cs.error),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showUpstreamEditor(
    BuildContext context, GatewayService service, UpstreamRuntime? existing) {
  final d = existing?.def;
  return showDialog(
    context: context,
    builder: (ctx) => _UpstreamDialog(
      service: service,
      existingId: d?.id,
      def: d,
    ),
  );
}

class _UpstreamDialog extends StatefulWidget {
  final GatewayService service;
  final String? existingId;
  final UpstreamDef? def;
  const _UpstreamDialog(
      {required this.service, required this.existingId, this.def});

  @override
  State<_UpstreamDialog> createState() => _UpstreamDialogState();
}

class _UpstreamDialogState extends State<_UpstreamDialog> {
  late final TextEditingController id =
      TextEditingController(text: widget.def?.id ?? '');
  late final TextEditingController label =
      TextEditingController(text: widget.def?.label ?? '');
  late final TextEditingController baseUrl =
      TextEditingController(text: widget.def?.baseUrl ?? '');
  late final TextEditingController apiKey =
      TextEditingController(text: widget.def?.apiKey ?? '');
  late final TextEditingController command =
      TextEditingController(text: widget.def?.command ?? '');
  late final TextEditingController args = TextEditingController(
      text: widget.def?.args.join(' ') ?? '');
  late String type = widget.def?.type ?? 'remote';
  bool _obscureKey = true;

  @override
  Widget build(BuildContext context) {
    final isManaged = type == 'managed';
    return AlertDialog(
      title: Text(widget.def == null ? '接入新供应商' : '编辑供应商'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'remote',
                      icon: Icon(Icons.cloud_outlined),
                      label: Text('自定义'),
                      tooltip: '纯转发，供应商自己已在运行'),
                  ButtonSegment(
                      value: 'managed',
                      icon: Icon(Icons.settings_suggest),
                      label: Text('内置'),
                      tooltip: '本应用负责拉起并守护本地进程'),
                ],
                selected: {type == 'zen' ? 'managed' : type},
                onSelectionChanged: (s) => setState(() => type = s.first),
              ),
              const SizedBox(height: 12),
              TextField(
                  controller: id,
                  enabled: widget.def == null,
                  decoration: const InputDecoration(
                      labelText: 'ID（唯一，英文）',
                      helperText: '模型将以 id/model 形式对外暴露')),
              TextField(
                  controller: label,
                  decoration: const InputDecoration(labelText: '备注（可空）')),
              TextField(
                  controller: baseUrl,
                  decoration: const InputDecoration(
                      labelText: 'Base URL',
                      hintText: 'http://127.0.0.1:8790/v1')),
              TextField(
                  controller: apiKey,
                  obscureText: _obscureKey,
                  decoration: InputDecoration(
                    labelText: '供应商 API Key（可空）',
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscureKey ? Icons.visibility_off : Icons.visibility),
                      onPressed: () =>
                          setState(() => _obscureKey = !_obscureKey),
                    ),
                  )),
              if (isManaged) ...[
                TextField(
                    controller: command,
                    decoration: const InputDecoration(
                        labelText: '启动命令',
                        hintText: 'node / C:\\...\\index.js')),
                TextField(
                    controller: args,
                    decoration: const InputDecoration(
                        labelText: '参数（空格分隔）')),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final idText = id.text.trim();
            if (idText.isEmpty || baseUrl.text.trim().isEmpty) return;
            final def = UpstreamDef(
              id: idText,
              type: type,
              label: label.text.trim(),
              baseUrl: baseUrl.text.trim(),
              apiKey: apiKey.text.trim(),
              command: isManaged ? command.text.trim() : null,
              args: isManaged
                  ? args.text
                      .split(RegExp(r'\s+'))
                      .where((s) => s.isNotEmpty)
                      .toList()
                  : const [],
              // 编辑供应商不重置出口代理（在设置页统一配置）
              proxy: widget.def?.proxy ?? '',
              proxyEnabled: widget.def?.proxyEnabled ?? false,
            );
            if (widget.def == null) {
              widget.service.addUpstream(def);
            } else {
              final rt = widget.service.upstreams
                  .firstWhere((u) => u.id == widget.existingId);
              widget.service.updateUpstream(rt, def);
            }
            Navigator.pop(context);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

// ---------------- 模型页 ----------------

class ModelsPage extends StatefulWidget {
  final GatewayService service;
  const ModelsPage({super.key, required this.service});

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  /// false = 按模型聚合（默认）；true = 按来源聚合
  bool _bySource = false;

  static String _fmtCtx(int? n) {
    if (n == null) return '';
    if (n >= 1048576 && n % 1048576 == 0) return '${n ~/ 1048576}M';
    if (n >= 1024) return '${(n / 1024).toStringAsFixed(n % 1024 == 0 ? 0 : 1)}K';
    return '$n';
  }

  /// 去重：同一模型在路由表里有 `id/model` 与裸名两条，只展示一条
  List<ModelRoute> _uniqueModels() {
    final seen = <String>{};
    final out = <ModelRoute>[];
    final routes = widget.service.registry.all.toList()
      ..sort((a, b) => a.upstreamModel.compareTo(b.upstreamModel));
    for (final r in routes) {
      if (seen.add('${r.upstream.id}|${r.upstreamModel}')) out.add(r);
    }
    return out;
  }

  Widget _capChips(ModelRoute r) {
    final info = r.upstream.modelInfo[r.upstreamModel];
    final tags = <String>[
      if (info?.contextWindow != null) '上下文 ${_fmtCtx(info!.contextWindow)}',
      if (info?.maxOutputTokens != null) '输出 ${_fmtCtx(info!.maxOutputTokens)}',
      if (info?.inputModalities.contains('image') ?? false) '视觉',
      if (info?.inputModalities.contains('audio') ?? false) '音频',
      if (info?.inputModalities.contains('video') ?? false) '视频',
      if (info?.inputModalities.contains('pdf') ?? false) 'PDF',
      if (info?.reasoning ?? false) '推理',
      if (info?.toolCall ?? false) '工具调用',
      if (info?.structuredOutput ?? false) '结构化输出',
      if (info?.free ?? false) '免费',
    ];
    if (tags.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final t in tags)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(t, style: const TextStyle(fontSize: 10.5)),
          ),
      ],
    );
  }

  Widget _tile(ModelRoute r, {bool showAlias = true}) {
    final info = r.upstream.modelInfo[r.upstreamModel];
    final known = r.bare ? '${r.upstream.id}/${r.upstreamModel}' : (widget.service.registry.resolve(r.upstreamModel) != null ? r.upstreamModel : null);
    final alias = showAlias ? known : null;
    final pretty = info?.displayName;
    final hasPretty = pretty != null && pretty != r.upstreamModel && pretty != r.publicName;
    return ListTile(
      dense: true,
      leading: Icon(
          Icons.circle,
          size: 10,
          color: r.upstream.health == UpstreamHealth.healthy
              ? Colors.green
              : Colors.grey),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hasPretty ? pretty : r.publicName,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: hasPretty ? FontWeight.w600 : FontWeight.normal,
                  fontFamily: hasPretty ? null : 'monospace')),
          if (hasPretty)
            Text.rich(
              TextSpan(
                style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.grey),
                children: [
                  TextSpan(text: r.publicName),
                  if (alias != null && alias != r.publicName)
                    TextSpan(text: '（别名 $alias）'),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          else if (alias != null && alias != r.publicName)
            Text('别名 $alias',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 3),
          _capChips(r),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.copy, size: 16),
        tooltip: '复制模型名',
        onPressed: () {
          Clipboard.setData(ClipboardData(text: r.publicName));
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('已复制 ${r.publicName}'),
              duration: const Duration(milliseconds: 800)));
        },
      ),
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: r.publicName));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('已复制'), duration: Duration(milliseconds: 600)));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final routes = _uniqueModels();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              child: Row(
                children: [
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('按模型')),
                      ButtonSegment(value: true, label: Text('按来源')),
                    ],
                    selected: {_bySource},
                    onSelectionChanged: (s) =>
                        setState(() => _bySource = s.first),
                  ),
                  const Spacer(),
                  Text('${routes.length} 个模型',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            Expanded(
              child: routes.isEmpty
                  ? const Center(
                      child: Text('暂无模型 — 供应商未就绪或未启用，稍候自动刷新',
                          style: TextStyle(color: Colors.grey)))
                  : !_bySource
                      ? ListView.builder(
                          padding: const EdgeInsets.only(bottom: 8),
                          itemCount: routes.length,
                          itemBuilder: (context, i) => _tile(routes[i]),
                        )
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 8),
                          children: [
                            for (final u in service.upstreams
                                .where((u) => u.def.enabled)) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                                child: Row(children: [
                                  Text(
                                      u.def.label.isNotEmpty ? u.def.label : u.id,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold)),
                                  const SizedBox(width: 8),
                                  Text('id: ${u.id}',
                                      style: const TextStyle(
                                          fontSize: 11, fontFamily: 'monospace')),
                                  const Spacer(),
                                  Text('${u.models.length} 个',
                                      style: const TextStyle(fontSize: 11)),
                                ]),
                              ),
                              const Divider(height: 1, indent: 14, endIndent: 14),
                              for (final r in routes.where((r) => r.upstream.id == u.id))
                                _tile(r),
                            ],
                          ],
                        ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------- 用量页 ----------------

class UsagePage extends StatefulWidget {
  final GatewayService service;
  const UsagePage({super.key, required this.service});

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  /// 今日/本周/本月/所有的天数范围；null = 所有
  int? _days;
  /// 图表形态：柱状/饼图/折线（折线仅跨天视图可用）
  String _chart = 'bar';
  UsageStats _stats = UsageStats();
  int _loadedCount = -1;

  static const _views = <String, int?>{
    '今日': 1,
    '本周': 7,
    '本月': 30,
    '所有': null,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final server = widget.service.server;
    if (server == null) return;
    final s = await server.usageRange(days: _days);
    if (!mounted) return;
    setState(() {
      _stats = s;
      _loadedCount = server.usageToday.requests;
    });
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final server = service.server;
        if (server == null) return const Center(child: Text('网关未启动'));
        // 记账数变化时刷新历史聚合
        if (server.usageToday.requests != _loadedCount) _load();
        final u = _stats;
        final cs = Theme.of(context).colorScheme;
        final logs = server.logs.reversed.take(100).toList();
        final crossDay = _days != 1;
        final chartTypes = <String, String>{
          'bar': '柱状',
          'pie': '饼图',
          if (crossDay) 'line': '折线',
        };
        if (_chart == 'line' && !crossDay) _chart = 'bar';
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _StatCard('请求', '${u.requests}', cs.primaryContainer),
                _StatCard('失败', '${u.errors}', cs.errorContainer),
                _StatCard('输入词元', _fmtTokens(u.promptTokens), cs.secondaryContainer),
                _StatCard('输出词元', _fmtTokens(u.completionTokens), cs.tertiaryContainer),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                SegmentedButton<String>(
                  segments: [
                    for (final e in _views.entries)
                      ButtonSegment(value: e.key, label: Text(e.key)),
                  ],
                  selected: {
                    _views.entries.firstWhere((e) => e.value == _days).key
                  },
                  onSelectionChanged: (sel) {
                    setState(() {
                      _days = _views[sel.first];
                      // 折线图仅跨天视图可用
                      if (_days == 1 && _chart == 'line') _chart = 'bar';
                    });
                    _load();
                  },
                ), Spacer(),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    for (final e in chartTypes.entries)
                      ButtonSegment(value: e.key, label: Text(e.value)),
                  ],
                  selected: {_chart},
                  onSelectionChanged: (sel) =>
                      setState(() => _chart = sel.first),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (u.requests > 0) ...[
              Text(
                _chart == 'line'
                    ? '词元用量趋势（按天）'
                    : '按模型词元用量（输入+输出）',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              if (_chart == 'bar')
                _TokenBarChart(stats: u)
              else if (_chart == 'pie')
                _PieChart(stats: u)
              else
                _LineChart(
                  data: (u.byDayTokens.entries.toList()
                    ..sort((a, b) => a.key.compareTo(b.key))),
                ),
              const SizedBox(height: 16),
            ] else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                    child: Text('该时段暂无请求',
                        style: TextStyle(color: cs.onSurfaceVariant))),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  const Text('网关日志（本次运行）',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(
                          ClipboardData(text: logs.reversed.join('\n')));
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('日志已复制到剪贴板'),
                              duration: Duration(seconds: 2),
                              behavior: SnackBarBehavior.floating));
                    },
                    icon: const Icon(Icons.copy_all, size: 16),
                    label: const Text('复制'),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              // 固定高度窗口内滚动：logs 现有取法已倒序（logs[0] 最新），
              // 故用 reversed:false——最新一条落在窗口最上方，进入即见最新，
              // 鼠标/触控板在窗口内向下拖动查看历史，不再撑开整页
              child: SizedBox(
                height: 220,
                child: logs.isEmpty
                    ? Center(
                        child: Text('（暂无日志）',
                            style: TextStyle(
                                color: cs.onSurfaceVariant, fontSize: 12)))
                    : ListView.builder(
                        itemCount: logs.length,
                        itemBuilder: (context, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            logs[i],
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 11),
                          ),
                        ),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}

String _fmtTokens(int n) {
  if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(2)}亿';
  if (n >= 10000) return '${(n / 10000).toStringAsFixed(n >= 10000000 ? 0 : 1)}万';
  return '$n';
}

List<Color> _tokenPalette(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  return [
    cs.primary,
    cs.tertiary,
    cs.secondary,
    cs.error,
    cs.primary.withValues(alpha: 0.6),
    cs.tertiary.withValues(alpha: 0.6),
    cs.secondary.withValues(alpha: 0.6),
    cs.error.withValues(alpha: 0.6),
  ];
}

/// 横向条形图：每行一个模型——左侧模型名，中间条形长度=词元用量，
/// 行尾标注「词元·次数」。按用量降序。
class _TokenBarChart extends StatelessWidget {
  final UsageStats stats;
  const _TokenBarChart({required this.stats});

  @override
  Widget build(BuildContext context) {
    final entries = stats.byModelTokens.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (entries.isEmpty) return const SizedBox.shrink();
    final max = entries.first.value;
    final palette = _tokenPalette(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < entries.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 132,
                  child: Text(entries[i].key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                          fontSize: 11, fontFamily: 'monospace')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LayoutBuilder(builder: (context, cx) {
                    final w = max == 0
                        ? 6.0
                        : (entries[i].value / max * cx.maxWidth).clamp(6.0, cx.maxWidth);
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 14,
                        width: w,
                        decoration: BoxDecoration(
                          color: palette[i % palette.length],
                          borderRadius:
                              const BorderRadius.horizontal(right: Radius.circular(4)),
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 110,
                  child: Text(
                    '${_fmtTokens(entries[i].value)} 词元 · ${stats.byModel[entries[i].key] ?? 0} 次',
                    style: const TextStyle(fontSize: 10.5, height: 1.2),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 饼图：模型词元占比 + 图例（次数并列显示）
class _PieChart extends StatelessWidget {
  final UsageStats stats;
  const _PieChart({required this.stats});

  @override
  Widget build(BuildContext context) {
    final entries = stats.byModelTokens.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<int>(0, (s, e) => s + e.value);
    if (total == 0) return const SizedBox.shrink();
    final palette = _tokenPalette(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 160,
          height: 160,
          child: CustomPaint(
            painter: _PiePainter(
              slices: [
                for (var i = 0; i < entries.length; i++)
                  _PieSlice(entries[i].value / total * pi * 2,
                      palette[i % palette.length])
              ],
            ),
          ),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < entries.length && i < 8; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                            color: palette[i % palette.length],
                            borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(entries[i].key,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 11.5)),
                    ),
                    const SizedBox(width: 8),
                    Text(
                        '${_fmtTokens(entries[i].value)} 词元 · ${stats.byModel[entries[i].key] ?? 0} 次 · ${(entries[i].value / total * 100).toStringAsFixed(1)}%',
                        style: TextStyle(
                            fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ]),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PieSlice {
  final double sweep;
  final Color color;
  const _PieSlice(this.sweep, this.color);
}

class _PiePainter extends CustomPainter {
  final List<_PieSlice> slices;
  const _PiePainter({required this.slices});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    var start = -pi / 2;
    final paint = Paint()..style = PaintingStyle.fill;
    for (final s in slices) {
      paint.color = s.color;
      canvas.drawArc(rect, start, s.sweep, true, paint);
      start += s.sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _PiePainter old) => old.slices != slices;
}

/// 折线图：按天词元用量趋势
class _LineChart extends StatelessWidget {
  final List<MapEntry<String, int>> data;
  const _LineChart({required this.data});

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const SizedBox.shrink();
    final max = data.map((e) => e.value).fold<int>(0, (a, b) => a > b ? a : b);
    return SizedBox(
      height: 180,
      child: CustomPaint(
        size: Size.infinite,
        painter: _LinePainter(
          points: data.map((e) => e.value.toDouble()).toList(),
          labels: data.map((e) => e.key).toList(),
          maxValue: (max == 0 ? 1 : max).toDouble(),
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  final List<double> points;
  final List<String> labels;
  final double maxValue;
  final Color color;
  const _LinePainter(
      {required this.points,
      required this.labels,
      required this.maxValue,
      required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const bottomPad = 22.0, topPad = 14.0;
    final w = size.width, h = size.height - bottomPad;
    final step = points.length > 1 ? (w - 24) / (points.length - 1) : 0.0;
    double x(int i) => 12 + (points.length > 1 ? i * step : (w - 24) / 2);
    double y(double v) => topPad + (h - topPad) * (1 - v / maxValue);

    // 面积填充
    final path = Path()..moveTo(x(0), y(points[0]));
    for (var i = 1; i < points.length; i++) {
      path.lineTo(x(i), y(points[i]));
    }
    path.lineTo(x(points.length - 1), h);
    path.lineTo(x(0), h);
    path.close();
    canvas.drawPath(path, Paint()..color = color.withValues(alpha: 0.12));

    // 折线
    final line = Path()..moveTo(x(0), y(points[0]));
    for (var i = 1; i < points.length; i++) {
      line.lineTo(x(i), y(points[i]));
    }
    canvas.drawPath(
        line, Paint()..color = color..strokeWidth = 2..style = PaintingStyle.stroke..strokeCap = StrokeCap.round);

    // 数据点 + 标签（点多时只画间隔点）
    final labelEvery = (points.length / 8).ceil();
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(Offset(x(i), y(points[i])), 3, Paint()..color = color);
      if (i % labelEvery == 0 || i == points.length - 1) {
        tp.text = TextSpan(
            text: labels[i],
            style: const TextStyle(fontSize: 9, color: Colors.grey));
        tp.layout();
        tp.paint(canvas, Offset(x(i) - tp.width / 2, size.height - bottomPad + 4));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) =>
      old.points != points || old.maxValue != maxValue;
}

class _StatCard extends StatelessWidget {
  final String label, value;
  final Color bg;
  const _StatCard(this.label, this.value, this.bg);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      padding: const EdgeInsets.all(14),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          Text(value,
              style:
                  const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

// ---------------- Cloudflare Worker 一键部署 ----------------

/// 独立于任何页面状态：设置页按钮与「IP 被封」提示共用。
/// token 只存在于对话框内存，部署完即随对话框销毁、不落盘。
Future<void> showWorkerDeployDialog(BuildContext context, GatewayService s) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _WorkerDeployDialog(service: s),
  );
}

class _WorkerDeployDialog extends StatefulWidget {
  final GatewayService service;
  const _WorkerDeployDialog({required this.service});

  @override
  State<_WorkerDeployDialog> createState() => _WorkerDeployDialogState();
}

class _WorkerDeployDialogState extends State<_WorkerDeployDialog> {
  final TextEditingController _cfToken = TextEditingController();
  List<CfAccount>? _cfAccounts;
  String _cfBusy = '';

  Future<void> _verify() async {
    setState(() => _cfBusy = '正在校验 token…');
    try {
      final accs = await CfWorkerDeployer.verify(_cfToken.text.trim());
      if (!mounted) return;
      setState(() {
        _cfAccounts = accs;
        _cfBusy = accs.isEmpty ? '该账号下没有可用工作区' : '';
      });
    } catch (e) {
      if (mounted) setState(() => _cfBusy = '$e');
    }
  }

  Future<void> _deploy(CfAccount acc) async {
    setState(() => _cfBusy = '正在部署 Worker 到「${acc.name}」…');
    try {
      final url = await CfWorkerDeployer.deploy(
          token: _cfToken.text.trim(), accountId: acc.id);
      widget.service.applyWorkerBaseUrl(url);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Worker 已部署并接入：$url\n'
              '注意 workers.dev 域名需代理可达（开启你的本地代理即可）'),
          duration: const Duration(seconds: 8)));
    } catch (e) {
      if (mounted) setState(() => _cfBusy = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('一键部署 Cloudflare Worker（Zen 出口）'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '把 zen 流量改走你自己的 Cloudflare Worker，上游看到的是 '
                'Cloudflare 的海量边缘 IP，不再是你本机 IP——绕过按 IP 的'
                '滥用风控。\n使用你自己的免费 Cloudflare 账号（不绑卡、'
                '每天 10 万次请求内免费）；token 仅本次使用，不会保存。',
                style: TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 8),
              Text(
                '创建 token：dash.cloudflare.com → My Profile → API Tokens → '
                'Create Token，模板「Edit cloudflare workers scripts」',
                style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _cfToken,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'API Token'),
              ),
              const SizedBox(height: 10),
              if (_cfAccounts == null)
                FilledButton(
                    onPressed: _cfBusy.isEmpty ? _verify : null,
                    child: const Text('校验 token')),
              if (_cfBusy.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_cfBusy,
                      style:
                          TextStyle(fontSize: 12, color: Colors.orange.shade800)),
                ),
              if (_cfAccounts != null && _cfAccounts!.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('选择账号并部署：', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 4),
                for (final a in _cfAccounts!)
                  ListTile(
                    dense: true,
                    title: Text(a.name.isEmpty ? a.id : a.name),
                    trailing: FilledButton(
                        onPressed: _cfBusy.isEmpty ? () => _deploy(a) : null,
                        child: const Text('部署')),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }
}

// ---------------- 设置页 ----------------

class SettingsPage extends StatefulWidget {
  final GatewayService service;
  const SettingsPage({super.key, required this.service});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController host =
      TextEditingController(text: widget.service.config.host);
  late final TextEditingController port =
      TextEditingController(text: '${widget.service.config.port}');
  /// 密钥行显隐状态：index -> 是否明文显示（默认遮罩）
  final Map<int, bool> _keyRevealed = {};
  /// 局域网 IPv4 枚举的 Future：仅在开关打开时按需刷新
  Future<List<String>>? _lanIpsFuture;
  String _protocol = 'openai';

  // 出口代理：目标供应商 + 地址输入框（跟随选择联动）
  String? _proxyTargetId;
  final TextEditingController _proxyAddr = TextEditingController();

  // Cloudflare Worker 一键部署：入口转调顶层组件（设置页与封禁提示共用）
  Future<void> _showWorkerDeployDialog() =>
      showWorkerDeployDialog(context, widget.service);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncProxyTarget();
  }

  void _syncProxyTarget() {
    final ups = widget.service.config.upstreams;
    if (ups.isEmpty) return;
    final id = (_proxyTargetId != null &&
            ups.any((u) => u.id == _proxyTargetId))
        ? _proxyTargetId!
        : (ups.any((u) => u.proxyEnabled)
            ? ups.firstWhere((u) => u.proxyEnabled).id
            : ups.first.id);
    if (id != _proxyTargetId) _proxyTargetId = id;
    final def = ups.firstWhere((u) => u.id == id);
    if (_proxyAddr.text != def.proxy) _proxyAddr.text = def.proxy;
  }

  // ---- 网关密钥池管理 ----

  /// 轮换默认密钥（第一把）：会让所有用旧 key 的客户端立即失效，先弹确认
  Future<void> _confirmRotate(GatewayService s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('轮换默认密钥'),
        content: const Text(
            '将生成一把新的默认密钥替换现有值，旧密钥立即失效，'
            '所有正在使用它的客户端需要更新配置。确定继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('轮换')),
        ],
      ),
    );
    if (ok == true) s.rotateApiKey();
  }

  Future<void> _confirmDeleteKey(
      GatewayService s, int index, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除密钥'),
        content: Text('确定删除密钥「$label」吗？'
            '使用该密钥的客户端将立即无法接入网关。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      s.deleteGatewayKey(index);
      // 删除后其后的行会前移，重置相关行的显隐状态避免错位
      _keyRevealed.removeWhere((i, _) => i >= index);
    }
  }

  /// 添加密钥：标签必填（空则服务层自动生成序号），值可自定义、留空自动生成
  Future<void> _showAddKeyDialog(GatewayService s) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _AddKeyDialog(service: s),
    );
  }

  /// 局域网接入地址列表：开关打开后展示本机各网卡的 http://ip:port/v1，可整段复制
  Widget _buildLanAccess(GatewayService s) {
    if (_lanIpsFuture == null) {
      // 页面初次构建时开关可能已处于打开态（非本次交互翻上来的），补一次枚举
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _lanIpsFuture == null && s.config.allowLan) {
          setState(() => _lanIpsFuture = localIPv4Addresses());
        }
      });
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    final port = s.config.port;
    return FutureBuilder<List<String>>(
      future: _lanIpsFuture,
      builder: (context, snap) {
        if (!snap.hasData) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('正在检测本机局域网地址…',
                style:
                    TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          );
        }
        final hint = lanHintText(snap.data!, port);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(hint,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12)),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: '复制接入地址',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: hint));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('已复制接入地址'),
                      duration: Duration(milliseconds: 600)));
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final anthropicOn = s.config.anthropicEnabled;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('网关接入信息',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SegmentedButton<String>(
                      segments: [
                        const ButtonSegment(
                            value: 'openai', label: Text('OpenAI 格式')),
                        ButtonSegment(
                            value: 'anthropic',
                            label: Text(anthropicOn
                                ? 'Anthropic 格式'
                                : 'Anthropic 格式（已关闭）'),
                            enabled: anthropicOn),
                      ],
                      selected: {_protocol},
                      onSelectionChanged: (sel) =>
                          setState(() => _protocol = sel.first),
                    ),
                    const SizedBox(height: 10),
                    SelectableText(
                      'Base URL  http://${s.config.host}:${s.config.port}${_protocol == 'anthropic' ? '' : '/v1'}',
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    if (_protocol == 'anthropic')
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Claude Code 等 Anthropic 客户端设 ANTHROPIC_BASE_URL=http://${s.config.host}:${s.config.port} 即可，对话端点为 /v1/messages',
                          style: TextStyle(
                              fontSize: 11.5, color: cs.onSurfaceVariant),
                        ),
                      ),
                    const SizedBox(height: 6),
                    // 密钥池：每行一把 key，默认遮罩、可显隐/复制/删除
                    Text(
                      '持有任一密钥即可访问网关（本机与局域网设备通用，不绑定设备）',
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 4),
                    ...s.config.keys.asMap().entries.map((e) => _GatewayKeyRow(
                          index: e.key,
                          gk: e.value,
                          revealed: _keyRevealed[e.key] ?? false,
                          onToggleReveal: () => setState(() =>
                              _keyRevealed[e.key] =
                                  !(_keyRevealed[e.key] ?? false)),
                          onRotate: e.key == 0 ? () => _confirmRotate(s) : null,
                          onDelete: e.key > 0
                              ? () => _confirmDeleteKey(s, e.key, e.value.label)
                              : null,
                        )),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('添加密钥'),
                        onPressed: () => _showAddKeyDialog(s),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: host,
              decoration:
                  const InputDecoration(labelText: '监听地址', suffixText: '改后需重启网关'),
            ),
            TextField(
              controller: port,
              decoration:
                  const InputDecoration(labelText: '端口', suffixText: '改后需重启网关'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            Row(children: [
              FilledButton.icon(
                icon: const Icon(Icons.restart_alt),
                label: const Text('应用并重启网关'),
                onPressed: () async {
                  await s.updateGateway(
                    host: host.text.trim(),
                    port: int.tryParse(port.text.trim()) ?? s.config.port,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: s.startError == null
                            ? const Text('网关已重启')
                            : Text('重启失败：${s.startError}')));
                  }
                },
              ),
            ]),
            const SizedBox(height: 16),
            // ---- 局域网访问 ----
            const Text('局域网访问',
                style: TextStyle(fontWeight: FontWeight.bold)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('允许局域网连接', style: TextStyle(fontSize: 14)),
              subtitle: Text(
                '开启后监听 0.0.0.0，同网段设备凭任意密钥接入；'
                'Windows 首次会弹防火墙授权，请点允许',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              value: s.config.allowLan,
              onChanged: (v) async {
                await s.setAllowLan(v);
                if (v && mounted) {
                  // 开启时枚举本机 IPv4，供下方接入地址列表展示
                  setState(() => _lanIpsFuture = localIPv4Addresses());
                }
              },
            ),
            if (s.config.allowLan) _buildLanAccess(s),
            const SizedBox(height: 24),
            const Text('出口代理',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              '上游对免费通道按出口 IP 做滥用风控。本机 IP 被标记时，'
              '可让选定供应商经本地代理（如 Clash 的 mixed 端口）或代理池换 IP 出网。',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            if (s.config.upstreams.isEmpty)
              const Text('（暂无供应商）')
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('对供应商生效：'),
                      const SizedBox(width: 8),
                      DropdownButton<String>(
                        value: _proxyTargetId ?? s.config.upstreams.first.id,
                        items: [
                          for (final u in s.config.upstreams)
                            DropdownMenuItem(
                                value: u.id,
                                child: Text(u.displayName)),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          final def = s.config.upstreams
                              .firstWhere((u) => u.id == v);
                          setState(() {
                            _proxyTargetId = v;
                            _proxyAddr.text = def.proxy;
                          });
                        },
                      ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('启用出口代理', style: TextStyle(fontSize: 14)),
                    subtitle: Text(
                      '关闭则保留地址但直连；命中 IP 风控且填有多个代理时自动轮换下一个出口',
                      style: TextStyle(
                          fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                    value: () {
                      final id = _proxyTargetId;
                      if (id == null) return false;
                      final hit =
                          s.config.upstreams.where((u) => u.id == id);
                      return hit.isNotEmpty && hit.first.proxyEnabled;
                    }(),
                    onChanged: (v) {
                      final id = _proxyTargetId;
                      if (id == null) return;
                      s.setUpstreamProxy(id,
                          enabled: v, proxy: _proxyAddr.text.trim());
                    },
                  ),
                  TextField(
                    controller: _proxyAddr,
                    onChanged: (v) {
                      final id = _proxyTargetId;
                      if (id == null) return;
                      final hit = s.config.upstreams.where((u) => u.id == id);
                      if (hit.isEmpty) return;
                      s.setUpstreamProxy(id,
                          enabled: hit.first.proxyEnabled, proxy: v.trim());
                    },
                    decoration: const InputDecoration(
                      labelText: '代理地址',
                      hintText: 'http://127.0.0.1:7890',
                      helperText: '支持 http / socks5；逗号分隔多个=轮换池（换节点=换 IP）',
                      helperMaxLines: 2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _showWorkerDeployDialog,
                    icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                    label: const Text('一键部署 Cloudflare Worker（Zen 出口换 IP）'),
                  ),
                ],
              ),
            const SizedBox(height: 24),
            const Text('外观', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'system', label: Text('跟随系统'), icon: Icon(Icons.brightness_auto)),
                ButtonSegment(value: 'light', label: Text('浅色'), icon: Icon(Icons.light_mode_outlined)),
                ButtonSegment(value: 'dark', label: Text('深色'), icon: Icon(Icons.dark_mode_outlined)),
              ],
              selected: {s.config.themeMode},
              onSelectionChanged: (sel) => s.setThemeMode(sel.first),
            ),
            const SizedBox(height: 24),
            const Text('窗口行为', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                    value: true,
                    icon: Icon(Icons.minimize),
                    label: Text('收起到托盘'),
                    tooltip: '点关闭隐藏到系统托盘，网关继续运行'),
                ButtonSegment(
                    value: false,
                    icon: Icon(Icons.close),
                    label: Text('退出应用'),
                    tooltip: '点关闭直接退出'),
              ],
              selected: {s.config.closeToTray},
              onSelectionChanged: (sel) => s.setCloseToTray(sel.first),
            ),
            const SizedBox(height: 24),
            const Text('协议适配', style: TextStyle(fontWeight: FontWeight.bold)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Anthropic 格式接口',
                  style: TextStyle(fontSize: 14)),
              subtitle: Text(
                '暴露 /v1/messages，自动与 OpenAI 格式互相转换，供 Claude Code 等客户端接入',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              value: anthropicOn,
              onChanged: (v) async {
                await s.setAnthropicEnabled(v);
                if (!v && _protocol == 'anthropic') {
                  if (context.mounted) setState(() => _protocol = 'openai');
                }
              },
            ),
            const SizedBox(height: 8),
            Text('配置文件', style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 4),
            SelectableText(_configPath(),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
            const SizedBox(height: 24),
            const Text('关于',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('版本 $kAppVersion',
                style: const TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 4),
            Text(
              'ZeroApi — 零汇聚合网关。把多个 OpenAI 兼容供应商聚合为一个统一入口；'
              '内置 OpenCode Zen Free 由本应用原生直连，其他内置型由应用拉起守护。'
              '模型命名：供应商id/模型名；跨供应商不重名时可直接用裸名。',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
            ),
          ],
        );
      },
    );
  }

  String _configPath() {
    final base = Platform.isWindows
        ? (Platform.environment['APPDATA'] ?? '%APPDATA%')
        : '${Platform.environment['HOME'] ?? '~'}/.config';
    return '$base${Platform.pathSeparator}zeroapi${Platform.pathSeparator}config.json';
  }
}

/// 密钥池单行：标签（第一把带「默认」标记与轮换按钮）、值（默认遮罩，
/// 行内显隐/复制）、最近使用时间，行尾删除按钮（index>0 才有回调）。
class _GatewayKeyRow extends StatelessWidget {
  final int index;
  final GatewayKey gk;
  final bool revealed;
  final VoidCallback onToggleReveal;
  final VoidCallback? onRotate;
  final VoidCallback? onDelete;

  const _GatewayKeyRow({
    required this.index,
    required this.gk,
    required this.revealed,
    required this.onToggleReveal,
    this.onRotate,
    this.onDelete,
  });

  /// lastUsed 展示：MM-dd HH:mm，从未使用显示「未使用」
  static String _fmtLastUsed(DateTime? t) {
    if (t == null) return '未使用';
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(gk.label.isEmpty ? '密钥 ${index + 1}' : gk.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    if (index == 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('默认',
                            style: TextStyle(
                                fontSize: 10, color: cs.onPrimaryContainer)),
                      ),
                      if (onRotate != null)
                        TextButton(
                          style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8),
                              textStyle: const TextStyle(fontSize: 12)),
                          onPressed: onRotate,
                          child: const Text('轮换'),
                        ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  revealed ? gk.value : '••••••••••••',
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 12.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(_fmtLastUsed(gk.lastUsed),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          IconButton(
            icon: Icon(revealed ? Icons.visibility_off : Icons.visibility,
                size: 18),
            tooltip: revealed ? '隐藏' : '显示',
            onPressed: onToggleReveal,
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: '复制密钥',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: gk.value));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('已复制'),
                  duration: Duration(milliseconds: 600)));
            },
          ),
          if (onDelete != null)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: '删除密钥',
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }
}

/// 添加密钥对话框：标签 + 可选自定义值（留空自动生成）
class _AddKeyDialog extends StatefulWidget {
  final GatewayService service;
  const _AddKeyDialog({required this.service});

  @override
  State<_AddKeyDialog> createState() => _AddKeyDialogState();
}

class _AddKeyDialogState extends State<_AddKeyDialog> {
  final TextEditingController _label = TextEditingController();
  final TextEditingController _value = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('添加密钥'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _label,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: '标签', hintText: '如：手机 / 实验室机器（留空自动编号）'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _value,
              decoration: InputDecoration(
                  labelText: '密钥值（可选）',
                  hintText: '留空自动生成 sk-pg-…',
                  helperText: '自定义值需全局唯一，建议使用工具生成的格式',
                  helperStyle: TextStyle(
                      fontSize: 11, color: cs.onSurfaceVariant)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(
            onPressed: () {
              widget.service.addGatewayKey(_label.text,
                  value: _value.text.trim().isEmpty ? null : _value.text);
              Navigator.of(context).pop();
            },
            child: const Text('添加')),
      ],
    );
  }
}
