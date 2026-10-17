import 'dart:io';

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
                    d.label.isNotEmpty ? d.label : d.id,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
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
                  label: Text(d.type == 'managed' ? '托管' : '远端',
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
                      label: Text('远端'),
                      tooltip: '纯转发，供应商自己已在运行'),
                  ButtonSegment(
                      value: 'managed',
                      icon: Icon(Icons.settings_suggest),
                      label: Text('托管'),
                      tooltip: '本应用负责拉起并守护本地进程'),
                ],
                selected: {type},
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
    final alias = r.bare ? '${r.upstream.id}/${r.upstreamModel}' : (widget.service.registry.resolve(r.upstreamModel) != null ? r.upstreamModel : null);
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
          Text(
            info?.displayName != null && info!.displayName != r.upstreamModel
                ? '${r.publicName}  · ${info.displayName}'
                : r.publicName,
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 13.5)),
          const SizedBox(height: 3),
          _capChips(r),
        ],
      ),
      subtitle: (showAlias && alias != null)
          ? Text('别名可直用：$alias', style: const TextStyle(fontSize: 11))
          : null,
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

class UsagePage extends StatelessWidget {
  final GatewayService service;
  const UsagePage({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final server = service.server;
        if (server == null) return const Center(child: Text('网关未启动'));
        final u = server.usageToday;
        final cs = Theme.of(context).colorScheme;
        final logs = server.logs.reversed.take(100).toList();
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
            if (u.byModel.isNotEmpty) ...[
              const Text('按模型', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...u.byModel.entries
                  .map((e) => ListTile(
                        dense: true,
                        title: Text(e.key,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 13)),
                        trailing: Text('${e.value} 次'),
                      ))
                  ,
              const SizedBox(height: 16),
            ],
            const Text('网关日志（本次运行）',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
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
              '托管型供应商由本应用负责拉起与守护。'
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
