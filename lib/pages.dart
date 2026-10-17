import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../gateway/config.dart';
import '../gateway/service.dart';
import '../gateway/upstream.dart';

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
                Text(d.id,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
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
            if (d.label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(d.label,
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
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

class ModelsPage extends StatelessWidget {
  final GatewayService service;
  const ModelsPage({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final routes = service.registry.all
          ..sort((a, b) => a.upstream.id.compareTo(b.upstream.id));
        if (routes.isEmpty) {
          return const Center(
              child: Text('暂无模型 — 供应商未就绪或未启用，稍候自动刷新',
                  style: TextStyle(color: Colors.grey)));
        }
        return ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: routes.length,
          itemBuilder: (context, i) {
            final r = routes[i];
            return ListTile(
              dense: true,
              leading: Icon(
                  r.bare ? Icons.circle : Icons.circle_outlined,
                  size: 10,
                  color: r.upstream.health == UpstreamHealth.healthy
                      ? Colors.green
                      : Colors.grey),
              title: Text(r.publicName,
                  style: const TextStyle(
                      fontFamily: 'monospace', fontSize: 13.5)),
              subtitle: Text(
                  '← ${r.upstream.id} / ${r.upstreamModel}',
                  style: const TextStyle(fontSize: 11.5)),
              trailing: IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: '复制模型名',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: r.publicName));
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('已复制 ${r.publicName}'), duration: const Duration(milliseconds: 800)));
                },
              ),
              onLongPress: () {
                Clipboard.setData(ClipboardData(text: r.publicName));
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制'), duration: Duration(milliseconds: 600)));
              },
            );
          },
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

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('网关接入信息（任何 OpenAI 客户端填这两项即可）',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      'Base URL  http://${s.config.host}:${s.config.port}/v1',
                      style: const TextStyle(fontFamily: 'monospace'),
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
            Text('配置文件', style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 4),
            SelectableText(_configPath(),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
            const SizedBox(height: 24),
            const Text('关于',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'ZeroApi — 零汇聚合网关。把多个 OpenAI 兼容供应商（Opencode Zen Free、'
              'Qoder2API-Hub、niceboat…）聚合为一个统一入口；托管型供应商由本应用'
              '负责拉起与守护。模型命名：供应商id/模型名；跨供应商不重名时可直接用裸名。',
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
