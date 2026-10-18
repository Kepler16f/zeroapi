import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../gateway/config.dart';
import '../gateway/proxy.dart';
import '../gateway/service.dart';
import '../gateway/upstream.dart';
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
                _StatCard('输入 tokens', '${u.promptTokens}', cs.secondaryContainer),
                _StatCard('输出 tokens', '${u.completionTokens}', cs.tertiaryContainer),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: logs
                    .map((l) => Text(l,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 11.5)))
                    .toList(),
              ),
            ),
          ],
        );
      },
    );
  }
}

String _fmtTokens(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(n >= 10000000 ? 0 : 1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}K';
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
                        '${_fmtTokens(entries[i].value)} tok · ${stats.byModel[entries[i].key] ?? 0} 次 · ${(entries[i].value / total * 100).toStringAsFixed(1)}%',
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
  late final TextEditingController apiKey =
      TextEditingController(text: widget.service.config.apiKey);
  bool _obscure = true;
  String _protocol = 'openai';

  // 出口代理：目标供应商 + 地址输入框（跟随选择联动）
  String? _proxyTargetId;
  final TextEditingController _proxyAddr = TextEditingController();

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
                    Row(children: [
                      Expanded(
                        child: SelectableText(
                          'API Key   ${_obscure ? '••••••••' : s.config.apiKey}',
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                            _obscure ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy),
                        tooltip: '复制 key',
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: s.config.apiKey));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text('已复制'),
                              duration: Duration(milliseconds: 600)));
                        },
                      ),
                    ]),
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
              const SizedBox(width: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.key),
                label: const Text('更换 API Key'),
                onPressed: () => s.rotateApiKey(),
              ),
            ]),
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
