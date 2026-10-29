import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_windows/webview_windows.dart';

import '../gateway/cf_api.dart';
import '../gateway/config.dart';
import '../gateway/lan.dart';
import '../gateway/opencode.dart';
import '../gateway/ocruntime.dart';
import '../gateway/progate.dart';
import '../gateway/proxy.dart';
import '../gateway/proxypool.dart';
import '../gateway/service.dart';
import '../gateway/upstream.dart';
import '../gateway/wbdata.dart';
import '../gateway/workbuddy.dart';
import '../hub_dashboard.dart';
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
                      child: Text(
                        '网关启动失败：${service.startError}（端口被占用？去设置页改端口）',
                      ),
                    ),
                  ),
                if (!ups.any((u) => WorkBuddy.isWorkBuddy(u.def)))
                  _workbuddyEntryCard(context, service),
                  if (!ups.any((u) => OpenCode.isOpenCode(u.def)))
                    _OpenCodeEntryCard(service: service),
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
    final hasPanel = d.healthUrl.isNotEmpty;
    final noAccounts = rt.accountTotal != null && (rt.accountReady ?? 0) == 0;
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
                // 左侧内容整体占满剩余空间（内部标题可省略号），使开关+菜单
                // 贴右边缘；此前 Flexible(标题) 与 Spacer 各占一半弹性空间，
                // 导致开关被挤到中间。
                Expanded(
                  child: Row(
                    children: [
                      Icon(Icons.circle, size: 10, color: healthColor),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          d.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (rt.health == UpstreamHealth.checking) ...[
                        const SizedBox(width: 8),
                        Text(
                          '启动中…',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (d.label.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          'id: ${d.id}',
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(width: 8),
                      Chip(
                        label: Text(
                          d.typeLabel,
                          style: const TextStyle(fontSize: 11),
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: d.enabled,
                  onChanged: (v) => service.toggleUpstream(rt, v),
                ),
                IconButton(
                  tooltip: '刷新该供应商（重新探测 + 模型清单）',
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: () => service.refreshUpstream(rt.def.id),
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
              Text(
                d.baseUrl,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.view_in_ar, size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  '模型 ${rt.models.length} 个',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                const SizedBox(width: 16),
                Icon(Icons.call_made, size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  '请求 ${rt.requests} 次',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                if (rt.child != null) ...[
                  const SizedBox(width: 16),
                  Icon(Icons.terminal, size: 14, color: cs.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(
                    '子进程 pid=${rt.child!.pid}',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ],
              ],
            ),
            if (hasPanel) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.group_outlined,
                    size: 14,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    WorkBuddy.accountSummary(rt.accountTotal, rt.accountReady),
                    style: TextStyle(
                      fontSize: 12,
                      color: noAccounts
                          ? Colors.orange.shade800
                          : cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              if (noAccounts)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '还没有可用账号：打开管理面板，用「登录新账号」或「扫描桌面端登录」导入后即可使用。',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Colors.orange.shade800,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => HubDashboardPage(service: service),
                        ),
                      ),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('管理面板'),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(
                          ClipboardData(text: WorkBuddy.panelPassword(d)),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('管理面板密码已复制')),
                        );
                      },
                      icon: const Icon(Icons.key_outlined, size: 16),
                      label: const Text('复制面板密码'),
                    ),
                  ],
                ),
              ),
            ],
            if (rt.lastError != null && rt.health == UpstreamHealth.down)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '最近错误：${rt.lastError}',
                  style: TextStyle(fontSize: 11, color: cs.error),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 供应商列表里没有 WorkBuddy 时的接入入口（手动移除后也能加回来）。
Widget _workbuddyEntryCard(BuildContext context, GatewayService service) {
  return Card(
    child: ListTile(
      leading: const Icon(Icons.workspaces_outline),
      title: const Text('接入 WorkBuddy 号池'),
      subtitle: const Text(
        '内置 workbuddy2api-hub：多账号轮换、登录/桌面端导入、签到保活；账号数据保存在本机。',
      ),
      trailing: FilledButton.tonal(
        onPressed: () async {
          final err = await service.addWorkBuddy();
          if (!context.mounted) return;
          if (err != null) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(err)));
          }
        },
        child: const Text('接入'),
      ),
    ),
  );
}

/// OpenCode CLI（TLS 指纹通路）的接入入口：本机已有 CLI 就直接接入；
/// 没有则给出按需下载（约 177MB，npm 官方包）的按钮与进度。
class _OpenCodeEntryCard extends StatefulWidget {
  final GatewayService service;
  const _OpenCodeEntryCard({required this.service});

  @override
  State<_OpenCodeEntryCard> createState() => _OpenCodeEntryCardState();
}

class _OpenCodeEntryCardState extends State<_OpenCodeEntryCard> {
  bool _downloading = false;
  double? _progress;
  int _received = 0;
  int _total = 0;

  bool get _ready => OpenCodeRuntime.isReady;

  Future<void> _attach() async {
    final err = await widget.service.addOpenCode();
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _progress = 0;
      _received = 0;
      _total = 0;
    });
    final err = await widget.service.downloadOpenCodeRuntime(
        onProgress: (received, total) {
      if (!mounted) return;
      setState(() {
        _received = received;
        _total = total;
        _progress = total > 0 ? received / total : null;
      });
    });
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _progress = null;
    });
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: const Icon(Icons.terminal_outlined),
        title: const Text('接入 OpenCode Zen（CLI 通路）'),
        subtitle: Text(_ready
            // 说明它为什么存在：上游按 TLS 指纹识别，只有真 CLI 能过免费层门禁
            ? '检测到本机 opencode CLI（${OpenCodeRuntime.findExecutable()}）。'
                'Zen 免费层 2026-10-24 起按 TLS 指纹识别客户端，只有真 CLI 能过门禁，'
                '接入后可用 ${OpenCode.freeModels.length} 个免费模型。'
            : 'Zen 免费层 2026-10-24 起按 TLS 指纹识别客户端，只有真 CLI 能过门禁。'
                r'本机未检测到 opencode CLI，可自动从 npm 下载对应平台的官方包'
                r'（约 177MB，存到 %APPDATA%\zeroapi\opencode）。'),
        trailing: _downloading
            ? SizedBox(
                width: 120,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    LinearProgressIndicator(value: _progress),
                    const SizedBox(height: 4),
                    Text(
                        _total > 0
                            ? '${(_progress ?? 0 * 100).toStringAsFixed(0)}% '
                                '(${(_received / 1048576).toStringAsFixed(1)}/'
                                '${(_total / 1048576).toStringAsFixed(1)}MB)'
                            : '${(_received / 1048576).toStringAsFixed(1)}MB',
                        style: TextStyle(
                            fontSize: 10, color: cs.onSurfaceVariant)),
                  ],
                ),
              )
            : FilledButton.tonal(
                onPressed: _ready ? _attach : _download,
                child: Text(_ready ? '接入' : '下载运行时'),
              ),
      ),
    );
  }
}

Future<void> _showUpstreamEditor(
  BuildContext context,
  GatewayService service,
  UpstreamRuntime? existing,
) {
  final d = existing?.def;
  return showDialog(
    context: context,
    builder: (ctx) =>
        _UpstreamDialog(service: service, existingId: d?.id, def: d),
  );
}

class _UpstreamDialog extends StatefulWidget {
  final GatewayService service;
  final String? existingId;
  final UpstreamDef? def;
  const _UpstreamDialog({
    required this.service,
    required this.existingId,
    this.def,
  });

  @override
  State<_UpstreamDialog> createState() => _UpstreamDialogState();
}

class _UpstreamDialogState extends State<_UpstreamDialog> {
  late final TextEditingController id = TextEditingController(
    text: widget.def?.id ?? '',
  );
  late final TextEditingController label = TextEditingController(
    text: widget.def?.label ?? '',
  );
  late final TextEditingController baseUrl = TextEditingController(
    text: widget.def?.baseUrl ?? '',
  );
  late final TextEditingController apiKey = TextEditingController(
    text: widget.def?.apiKey ?? '',
  );
  late final TextEditingController command = TextEditingController(
    text: widget.def?.command ?? '',
  );
  late final TextEditingController args = TextEditingController(
    text: widget.def?.args.join(' ') ?? '',
  );
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
                    tooltip: '纯转发，供应商自己已在运行',
                  ),
                  ButtonSegment(
                    value: 'managed',
                    icon: Icon(Icons.settings_suggest),
                    label: Text('内置'),
                    tooltip: '本应用负责拉起并守护本地进程',
                  ),
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
                  helperText: '模型将以 id/model 形式对外暴露',
                ),
              ),
              TextField(
                controller: label,
                decoration: const InputDecoration(labelText: '备注（可空）'),
              ),
              TextField(
                controller: baseUrl,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  hintText: 'http://127.0.0.1:8790/v1',
                ),
              ),
              TextField(
                controller: apiKey,
                obscureText: _obscureKey,
                decoration: InputDecoration(
                  labelText: '供应商 API Key（可空）',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureKey ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                  ),
                ),
              ),
              if (isManaged) ...[
                TextField(
                  controller: command,
                  decoration: const InputDecoration(
                    labelText: '启动命令',
                    hintText: 'node / C:\\...\\index.js',
                  ),
                ),
                TextField(
                  controller: args,
                  decoration: const InputDecoration(labelText: '参数（空格分隔）'),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
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
              // 管理面健康地址属于内置供应商的接线信息，编辑时保留
              healthUrl: widget.def?.healthUrl ?? '',
            );
            if (widget.def == null) {
              widget.service.addUpstream(def);
            } else {
              final rt = widget.service.upstreams.firstWhere(
                (u) => u.id == widget.existingId,
              );
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

/// 逻辑模型名：去掉末尾的 `-free` 后缀（大小写不敏感），保留原大小写
/// 用于展示。例如 `deepseek-v4.1-flash-free` → `deepseek-v4.1-flash`。
/// 聚合比较时再统一转小写，避免大小写差异拆成两行。
String logicalModelName(String upstreamModel) {
  final s = upstreamModel.trim();
  if (s.length > 5 && s.toLowerCase().endsWith('-free')) {
    return s.substring(0, s.length - 5);
  }
  return s.isEmpty ? upstreamModel : s;
}

bool _isFreeVariantName(String name) =>
    name.trim().toLowerCase().endsWith('-free');

String _logicalKey(String name) => logicalModelName(name).toLowerCase();

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
    if (n >= 1024) {
      return '${(n / 1024).toStringAsFixed(n % 1024 == 0 ? 0 : 1)}K';
    }
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

  /// 按逻辑名聚合（key = 小写逻辑名）：同名但来自不同供应商、
  /// 或互为 -free/非 -free 的条目都落到同一组。
  Map<String, List<ModelRoute>> _logicalGroups(List<ModelRoute> routes) {
    final groups = <String, List<ModelRoute>>{};
    for (final r in routes) {
      groups.putIfAbsent(_logicalKey(r.upstreamModel), () => []).add(r);
    }
    for (final list in groups.values) {
      list.sort((a, b) {
        final bySource = a.upstream.def.displayName.toLowerCase().compareTo(
          b.upstream.def.displayName.toLowerCase(),
        );
        if (bySource != 0) return bySource;
        return a.upstreamModel.toLowerCase().compareTo(
          b.upstreamModel.toLowerCase(),
        );
      });
    }
    return groups;
  }

  /// 聚合行展示的逻辑名：优先取不带 -free 的原始名，保证展示的是
  /// 标准调用名而不是免费变体名。
  String _logicalDisplay(List<ModelRoute> routes) {
    final sorted = [...routes]
      ..sort((a, b) {
        final af = _isFreeVariantName(a.upstreamModel) ? 1 : 0;
        final bf = _isFreeVariantName(b.upstreamModel) ? 1 : 0;
        if (af != bf) return af - bf;
        return a.upstreamModel.toLowerCase().compareTo(
          b.upstreamModel.toLowerCase(),
        );
      });
    return logicalModelName(sorted.first.upstreamModel);
  }

  Widget _countBadge(String text) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10.5, color: cs.onPrimaryContainer),
      ),
    );
  }

  /// 聚合行：逻辑名一行；展开后直接列出这个模型的全部调用名/变体详情
  /// （来源、能力、倍率、Pro 限制），不再按供应商套一层折叠。
  Widget _logicalTile(String key, List<ModelRoute> routes) {
    final display = _logicalDisplay(routes);
    final sorted = [...routes]
      ..sort((a, b) {
        final byVendor = a.upstream.def.displayName.toLowerCase().compareTo(
          b.upstream.def.displayName.toLowerCase(),
        );
        if (byVendor != 0) return byVendor;
        return a.upstreamModel.toLowerCase().compareTo(
          b.upstreamModel.toLowerCase(),
        );
      });
    final anyHealthy = routes.any(
      (r) => r.upstream.health == UpstreamHealth.healthy,
    );
    return Column(
      children: [
        ExpansionTile(
          key: PageStorageKey<String>('model-group-$key'),
          leading: Icon(
            Icons.circle,
            size: 10,
            color: anyHealthy ? Colors.green : Colors.grey,
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _countBadge('${routes.length} 个调用名'),
            ],
          ),
          subtitle: Text(
            '展开查看来源、能力、倍率与 Pro 限制',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          childrenPadding: const EdgeInsets.only(bottom: 4),
          children: [for (final r in sorted) _routeTile(r)],
        ),
        const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }

  /// 具体条目：调用名与能力标签同一行；来源/展示名收成一行，去掉裸名别名，
  /// 尽量节省纵向空间（节点多时一屏能看更多）。
  Widget _routeTile(ModelRoute r) {
    final info = r.upstream.modelInfo[r.upstreamModel];
    final pretty = info?.displayName;
    final call = '${r.upstream.def.callPrefix}/${r.upstreamModel}';
    final meta = <String>[
      '来源：${r.upstream.def.displayName}',
      if (pretty != null && pretty.isNotEmpty && pretty != r.upstreamModel)
        '展示名：$pretty',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 4, 12, 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                call,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              ),
              const SizedBox(width: 10),
              Expanded(child: _capChips(r)),
            ],
          ),
          const SizedBox(height: 1),
          Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    );
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
    final multiplier = info?.creditMultiplier ?? '';
    if (tags.isEmpty &&
        multiplier.isEmpty &&
        !ProGate.instance.isPro(r.upstream.def.id, r.upstreamModel)) {
      return const SizedBox.shrink();
    }
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
        // 倍率：来自上游 /v1/models 的 credits 字段（号池动态下发），不写死
        if (multiplier.isNotEmpty)
          Tooltip(
            message:
                '倍率来自上游目录的 credits 字段，随号池动态更新；'
                '数字越低越省额度',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.teal.shade50,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.teal.shade200),
              ),
              child: Text(
                '倍率 $multiplier',
                style: TextStyle(fontSize: 10.5, color: Colors.teal.shade800),
              ),
            ),
          ),
        // 「仅 Pro」：上游按账号类型拒绝过该模型（11158），号池里没有
        // 能服务它的付费账号；任一请求成功会自动解除。
        if (ProGate.instance.isPro(r.upstream.def.id, r.upstreamModel))
          Tooltip(
            message:
                '上游判定该模型仅限 Pro（付费）账号使用：当前号池调用它会被\n'
                '「not allowed for user type」拒绝。添加对应区的付费账号后\n'
                '成功调用一次，此标记自动消失。',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.amber.shade100,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.amber.shade600),
              ),
              child: Text(
                '仅 Pro 可用',
                style: TextStyle(fontSize: 10.5, color: Colors.brown.shade800),
              ),
            ),
          ),
      ],
    );
  }

  Widget _tile(ModelRoute r, {bool showAlias = true}) {
    final info = r.upstream.modelInfo[r.upstreamModel];
    final known = r.bare
        ? '${r.upstream.id}/${r.upstreamModel}'
        : (widget.service.registry.resolve(r.upstreamModel) != null
              ? r.upstreamModel
              : null);
    final alias = showAlias ? known : null;
    final pretty = info?.displayName;
    final hasPretty =
        pretty != null && pretty != r.upstreamModel && pretty != r.publicName;
    return ListTile(
      dense: true,
      leading: Icon(
        Icons.circle,
        size: 10,
        color: r.upstream.health == UpstreamHealth.healthy
            ? Colors.green
            : Colors.grey,
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hasPretty ? pretty : r.publicName,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: hasPretty ? FontWeight.w600 : FontWeight.normal,
              fontFamily: hasPretty ? null : 'monospace',
            ),
          ),
          if (hasPretty)
            Text.rich(
              TextSpan(
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: Colors.grey,
                ),
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
            Text(
              '别名 $alias',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          const SizedBox(height: 3),
          _capChips(r),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.copy, size: 16),
        tooltip: '复制模型名',
        onPressed: () {
          Clipboard.setData(ClipboardData(text: r.publicName));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已复制 ${r.publicName}'),
              duration: const Duration(milliseconds: 800),
            ),
          );
        },
      ),
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: r.publicName));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已复制'),
            duration: Duration(milliseconds: 600),
          ),
        );
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
        final groups = _logicalGroups(routes);
        final groupKeys = groups.keys.toList()
          ..sort(
            (a, b) =>
                _logicalDisplay(groups[a]!)
                    .toLowerCase()
                    .compareTo(_logicalDisplay(groups[b]!).toLowerCase()),
          );
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
                  Text(
                    '${groups.length} 个模型 · ${routes.length} 个条目',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: routes.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无模型 — 供应商未就绪或未启用，稍候自动刷新',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : !_bySource
                  ? ListView.builder(
                      padding: const EdgeInsets.only(bottom: 8),
                      itemCount: groupKeys.length,
                      itemBuilder: (context, i) =>
                          _logicalTile(groupKeys[i], groups[groupKeys[i]]!),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 8),
                      children: [
                        for (final u in service.upstreams.where(
                          (u) => u.def.enabled,
                        )) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                            child: Row(
                              children: [
                                Text(
                                  u.def.label.isNotEmpty ? u.def.label : u.id,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'id: ${u.id}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '${u.models.length} 个',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1, indent: 14, endIndent: 14),
                          for (final r in routes.where(
                            (r) => r.upstream.id == u.id,
                          ))
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

/// 把 `-free` 变体合并到逻辑模型名后的用量副本：总量、按天趋势与
/// 次数/词元总量保持不变，仅 byModel / byModelTokens 按逻辑名重新累加。
/// 同一逻辑名大小写不同时，优先用不带 `-free` 的写法作为展示名。
UsageStats mergeFreeUsageVariants(UsageStats src) {
  final out = UsageStats()
    ..requests = src.requests
    ..errors = src.errors
    ..promptTokens = src.promptTokens
    ..completionTokens = src.completionTokens
    ..cachedTokens = src.cachedTokens;
  out.trend.addAll(src.trend);
  out.byDayTokens.addAll(src.byDayTokens);

  final names =
      <String>{...src.byModel.keys, ...src.byModelTokens.keys}.toList()
        ..sort((a, b) {
          final af = _isFreeVariantName(a) ? 1 : 0;
          final bf = _isFreeVariantName(b) ? 1 : 0;
          if (af != bf) return af - bf;
          return a.toLowerCase().compareTo(b.toLowerCase());
        });
  final display = <String, String>{};
  for (final n in names) {
    display.putIfAbsent(_logicalKey(n), () => logicalModelName(n));
  }
  void mergeInto(Map<String, int> from, Map<String, int> to) {
    from.forEach((name, value) {
      final key = display[_logicalKey(name)] ?? logicalModelName(name);
      to.update(key, (v) => v + value, ifAbsent: () => value);
    });
  }

  mergeInto(src.byModel, out.byModel);
  mergeInto(src.byModelTokens, out.byModelTokens);
  return out;
}

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

  /// 是否区分 `-free` 变体：默认关闭，所有视图合并到同一逻辑模型名
  UsageStats _stats = UsageStats();

  /// WorkBuddy 号池本地用量（与当前时间范围同口径）。null=未取到/失败，按 0 计
  WbUsageStats? _wb;
  int _loadedCount = -1;

  static const _views = <String, int?>{'今日': 1, '本周': 7, '本月': 30, '所有': null};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final server = widget.service.server;
    if (server == null) return;
    final days = _days;
    // 网关聚合与号池聚合并发取，互不阻塞
    final gwFuture = server.usageRange(days: days);
    WbUsageStats? wb;
    try {
      wb = await widget.service.loadWorkBuddyUsage(sinceDays: days);
    } catch (_) {
      wb = null; // 号池取数失败不阻塞用量页，按 0 合并
    }
    final s = await gwFuture;
    if (!mounted) return;
    if (days != _days) return; // 期间切了视图，由切换触发的下一次刷新覆盖
    setState(() {
      _stats = s;
      _wb = wb;
      _loadedCount = server.usageToday.requests;
    });
  }

  /// 网关 + 号池合并口径：请求/失败/词元总量、按模型次数与词元、
  /// 按天词元全部相加。号池记录只有全局词元总量，按各模型请求次数
  /// 比例摊到模型维度（仅供分模型图展示，总量严格一致）；按天词元
  /// 用号池真实值（'YYYY-MM-dd' → 'MM-dd'，与网关跨天桶对齐）。
  /// 号池数据缺失（null/异常）时按 0 处理，返回网关原值。
  UsageStats _merged() {
    final gw = _stats;
    final wb = _wb;
    if (wb == null || wb.requests == 0) return gw;
    final out = UsageStats()..merge(gw);
    out.requests += wb.requests;
    out.errors += wb.errors;
    final prompt = wb.promptTokens.round();
    final completion = wb.completionTokens.round();
    out.promptTokens += prompt;
    out.completionTokens += completion;
    out.cachedTokens += wb.cachedTokens.round();
    final tokensTotal = prompt + completion;
    wb.byModel.forEach((m, c) {
      out.byModel.update(m, (v) => v + c, ifAbsent: () => c);
      final t = (tokensTotal * c / wb.requests).round();
      out.byModelTokens.update(m, (v) => v + t, ifAbsent: () => t);
    });
    wb.tokensByDay.forEach((day, t) {
      final key = day.length >= 10 ? day.substring(5) : day;
      out.byDayTokens.update(key, (v) => v + t, ifAbsent: () => t);
    });
    return out;
  }

  /// 合并成本（人民币元）：网关侧无成本概念计 0，全部来自号池记录
  /// （credit 优先、缺失按号池价表折算，口径在 wbdata 内实现）。
  double get _mergedCostCny => _wb?.costCnySum ?? 0;

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
        final u = _merged();
        // 默认把 -free 变体合并进同一逻辑模型；开关打开时保留原始调用名
        // -free 与同名标准变体始终合并统计（与号池计费口径一致）
        final displayStats = mergeFreeUsageVariants(u);
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
                _StatCard(
                  '输入词元',
                  _fmtTokens(u.promptTokens),
                  cs.secondaryContainer,
                ),
                _StatCard(
                  '输出词元',
                  _fmtTokens(u.completionTokens),
                  cs.tertiaryContainer,
                ),
                _StatCard(
                  '成本',
                  '¥${_mergedCostCny.toStringAsFixed(2)}',
                  cs.surfaceContainerHighest,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '含 WorkBuddy 号池本地记录（按号池价表折算成本）',
                style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant),
              ),
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
                    _views.entries.firstWhere((e) => e.value == _days).key,
                  },
                  onSelectionChanged: (sel) {
                    setState(() {
                      _days = _views[sel.first];
                      // 折线图仅跨天视图可用
                      if (_days == 1 && _chart == 'line') _chart = 'bar';
                    });
                    _load();
                  },
                ),
                Spacer(),
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
            const SizedBox(height: 8),
            const SizedBox(height: 12),
            if (u.requests > 0) ...[
              Text(
                _chart == 'line' ? '词元用量趋势（按天）' : '按模型词元用量（输入+输出）',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              if (_chart == 'bar')
                _TokenBarChart(stats: displayStats)
              else if (_chart == 'pie')
                _PieChart(stats: displayStats)
              else
                _LineChart(
                  data: (displayStats.byDayTokens.entries.toList()
                    ..sort((a, b) => a.key.compareTo(b.key))),
                ),
              const SizedBox(height: 16),
            ] else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '该时段暂无请求',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  const Text(
                    '网关日志（最新一条）',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: logs.reversed.join('\n')),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('日志已复制到剪贴板'),
                          duration: Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
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
                        child: Text(
                          '（暂无日志）',
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      )
                    // 只显示最新一条：失败重试会把「⟳ 第 N 次失败」刷成一大
                    // 串黄字，看的人只关心现在这一轮发生了什么，历史在「复制」
                    // 按钮里仍可取全量（200 条环形缓冲）
                    : ListView(
                        children: [
                          Text(
                            logs.first,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        ],
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
  if (n >= 10000) {
    return '${(n / 10000).toStringAsFixed(n >= 10000000 ? 0 : 1)}万';
  }
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
                  child: Text(
                    entries[i].key,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, cx) {
                      final w = max == 0
                          ? 6.0
                          : (entries[i].value / max * cx.maxWidth).clamp(
                              6.0,
                              cx.maxWidth,
                            );
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          height: 14,
                          width: w,
                          decoration: BoxDecoration(
                            color: palette[i % palette.length],
                            borderRadius: const BorderRadius.horizontal(
                              right: Radius.circular(4),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
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
                  _PieSlice(
                    entries[i].value / total * pi * 2,
                    palette[i % palette.length],
                  ),
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
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: palette[i % palette.length],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          entries[i].key,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${_fmtTokens(entries[i].value)} 词元 · ${stats.byModel[entries[i].key] ?? 0} 次 · ${(entries[i].value / total * 100).toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
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
  const _LinePainter({
    required this.points,
    required this.labels,
    required this.maxValue,
    required this.color,
  });

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
      line,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );

    // 数据点 + 标签（点多时只画间隔点）
    final labelEvery = (points.length / 8).ceil();
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(Offset(x(i), y(points[i])), 3, Paint()..color = color);
      if (i % labelEvery == 0 || i == points.length - 1) {
        tp.text = TextSpan(
          text: labels[i],
          style: const TextStyle(fontSize: 9, color: Colors.grey),
        );
        tp.layout();
        tp.paint(
          canvas,
          Offset(x(i) - tp.width / 2, size.height - bottomPad + 4),
        );
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
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

// ---------------- Cloudflare Worker 一键部署 ----------------

/// 独立于任何页面状态：设置页按钮与「IP 被封」提示共用。
/// token 只存在于对话框内存，部署完即随对话框销毁、不落盘。
Future<void> showWorkerDeployDialog(
  BuildContext context,
  GatewayService s,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _WorkerDeployDialog(service: s),
  );
}

/// 内置 WebView2 打开号池管理面板：账号登录（扫码 / 桌面端授权）都在
/// 应用内完成，不再跳系统浏览器。WebView2 运行时缺失或初始化失败时
/// 回退到浏览器打开，并提示原因。
Future<void> showWorkBuddyPanel(
  BuildContext context,
  GatewayService s,
  UpstreamDef d,
) async {
  // 本机免密：先取面板 token，再带进 URL（dashboard.html 存 sessionStorage）
  final token = await s.hubPanelToken();
  final controller = WebviewController();
  try {
    await controller.initialize();
    await controller.loadUrl(WorkBuddy.panelUrl(d, token: token));
  } catch (e) {
    try {
      await controller.dispose();
    } catch (_) {}
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('内置窗口不可用（$e），已改用浏览器打开'),
          duration: const Duration(seconds: 6),
        ),
      );
      await WorkBuddy.openPanel(d, token: token);
    }
    return;
  }
  if (!context.mounted) {
    await controller.dispose();
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: SizedBox(
        width: 1100,
        height: 760,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 14, right: 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'WorkBuddy 管理面板',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    icon: const Icon(Icons.refresh),
                    onPressed: () => controller.reload(),
                  ),
                  IconButton(
                    tooltip: '用浏览器打开',
                    icon: const Icon(Icons.open_in_browser),
                    onPressed: () => WorkBuddy.openPanel(d, token: token),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: Webview(controller)),
          ],
        ),
      ),
    ),
  );
  try {
    await controller.dispose();
  } catch (_) {}
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
        token: _cfToken.text.trim(),
        accountId: acc.id,
      );
      widget.service.applyWorkerBaseUrl(url);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Worker 已部署并接入：$url\n'
            '注意 workers.dev 域名需代理可达（开启你的本地代理即可）',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
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
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
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
                  child: const Text('校验 token'),
                ),
              if (_cfBusy.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _cfBusy,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange.shade800,
                    ),
                  ),
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
                      child: const Text('部署'),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
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
  late final TextEditingController host = TextEditingController(
    text: widget.service.config.host,
  );
  late final TextEditingController port = TextEditingController(
    text: '${widget.service.config.port}',
  );

  /// 密钥行显隐状态：index -> 是否明文显示（默认遮罩）
  final Map<int, bool> _keyRevealed = {};

  /// 局域网 IPv4 枚举的 Future：仅在开关打开时按需刷新
  Future<List<String>>? _lanIpsFuture;
  String _protocol = 'openai';

  // 出口代理地址：对所有供应商统一生效（不在这里选择作用于哪个供应商）
  final TextEditingController _proxyAddr = TextEditingController();

  // Cloudflare Worker 一键部署：入口转调顶层组件（设置页与封禁提示共用）
  Future<void> _showWorkerDeployDialog() =>
      showWorkerDeployDialog(context, widget.service);

  @override
  void initState() {
    super.initState();
    // 回填现有地址（忽略本机回环供应商——它们不走手写代理）
    for (final u in widget.service.config.upstreams) {
      if (u.isLoopbackBaseUrl) continue;
      if (u.proxy.trim().isNotEmpty) {
        _proxyAddr.text = u.proxy;
        break;
      }
    }
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
          '所有正在使用它的客户端需要更新配置。确定继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('轮换'),
          ),
        ],
      ),
    );
    if (ok == true) s.rotateApiKey();
  }

  Future<void> _confirmDeleteKey(
    GatewayService s,
    int index,
    String label,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除密钥'),
        content: Text(
          '确定删除密钥「$label」吗？'
          '使用该密钥的客户端将立即无法接入网关。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
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
          setState(() {
            // 赋值表达式的值是 Future，直接写在 setState 回调里会触发
            // 「setState() callback argument returned a Future」断言
            _lanIpsFuture = localIPv4Addresses();
          });
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
            child: Text(
              '正在检测本机局域网地址…',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          );
        }
        final hint = lanHintText(snap.data!, port);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  hint,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: '复制接入地址',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: hint));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制接入地址'),
                      duration: Duration(milliseconds: 600),
                    ),
                  );
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
            const Text('网关接入信息', style: TextStyle(fontWeight: FontWeight.bold)),
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
                          value: 'openai',
                          label: Text('OpenAI 格式'),
                        ),
                        ButtonSegment(
                          value: 'anthropic',
                          label: Text(
                            anthropicOn ? 'Anthropic 格式' : 'Anthropic 格式（已关闭）',
                          ),
                          enabled: anthropicOn,
                        ),
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
                            fontSize: 11.5,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                    const SizedBox(height: 6),
                    // 密钥池：每行一把 key，默认遮罩、可显隐/复制/删除
                    Text(
                      '持有任一密钥即可访问网关（本机与局域网设备通用，不绑定设备）',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...s.config.keys.asMap().entries.map(
                      (e) => _GatewayKeyRow(
                        index: e.key,
                        gk: e.value,
                        revealed: _keyRevealed[e.key] ?? false,
                        onToggleReveal: () => setState(
                          () => _keyRevealed[e.key] =
                              !(_keyRevealed[e.key] ?? false),
                        ),
                        onRotate: e.key == 0 ? () => _confirmRotate(s) : null,
                        onDelete: e.key > 0
                            ? () => _confirmDeleteKey(s, e.key, e.value.label)
                            : null,
                      ),
                    ),
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
              decoration: const InputDecoration(
                labelText: '监听地址',
                suffixText: '改后需重启网关',
              ),
            ),
            TextField(
              controller: port,
              decoration: const InputDecoration(
                labelText: '端口',
                suffixText: '改后需重启网关',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('应用并重启网关'),
                  onPressed: () async {
                    await s.updateGateway(
                      host: host.text.trim(),
                      port: int.tryParse(port.text.trim()) ?? s.config.port,
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: s.startError == null
                              ? const Text('网关已重启')
                              : Text('重启失败：${s.startError}'),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            // ---- 局域网访问 ----
            const Text('局域网访问', style: TextStyle(fontWeight: FontWeight.bold)),
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
                  setState(() {
                    // 赋值表达式的值是 Future，直接写在 setState 回调里会触发
                    // 「setState() callback argument returned a Future」断言
                    _lanIpsFuture = localIPv4Addresses();
                  });
                }
              },
            ),
            if (s.config.allowLan) _buildLanAccess(s),
            const SizedBox(height: 24),
            const Text('出口代理', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              '上游对免费通道按出口 IP 做滥用风控。本机 IP 被标记时，'
              '可让所有上游经本地代理（如 Clash 的 mixed 端口）出网；'
              '只是「用什么代理」，不在这里选择作用于哪个供应商。',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            if (s.config.upstreams.isEmpty)
              const Text('（暂无供应商）')
            else ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('启用出口代理', style: TextStyle(fontSize: 14)),
                subtitle: Text(
                  '关闭则保留地址但直连；地址对所有供应商生效。'
                  '内置代理池不在这里开关——到「代理」页的「用途分配」按供应商绑定分组即可。',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
                value: s.globalProxyEnabled,
                onChanged: (v) {
                  s.setGlobalUpstreamProxy(
                    enabled: v,
                    proxy: _proxyAddr.text.trim(),
                  );
                },
              ),
              TextField(
                controller: _proxyAddr,
                onChanged: (v) {
                  s.setGlobalUpstreamProxy(
                    enabled: s.globalProxyEnabled,
                    proxy: v.trim(),
                  );
                },
                decoration: const InputDecoration(
                  labelText: '代理地址（对所有供应商生效）',
                  hintText: 'http://127.0.0.1:7890',
                  helperText:
                      '支持 http / socks5；逗号分隔多个=轮换池（换节点=换 IP）。'
                      '本机服务（如随包号池）强制直连；仅作用于本应用，不改系统代理。',
                  helperMaxLines: 2,
                ),
              ),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _showWorkerDeployDialog,
              icon: const Icon(Icons.cloud_upload_outlined, size: 18),
              label: const Text('一键部署 Cloudflare Worker（Zen 出口换 IP）'),
            ),
            const SizedBox(height: 24),
            const Text('外观', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'system',
                  label: Text('跟随系统'),
                  icon: Icon(Icons.brightness_auto),
                ),
                ButtonSegment(
                  value: 'light',
                  label: Text('浅色'),
                  icon: Icon(Icons.light_mode_outlined),
                ),
                ButtonSegment(
                  value: 'dark',
                  label: Text('深色'),
                  icon: Icon(Icons.dark_mode_outlined),
                ),
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
                  tooltip: '点关闭隐藏到系统托盘，网关继续运行',
                ),
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.close),
                  label: Text('退出应用'),
                  tooltip: '点关闭直接退出',
                ),
              ],
              selected: {s.config.closeToTray},
              onSelectionChanged: (sel) => s.setCloseToTray(sel.first),
            ),
            const SizedBox(height: 24),
            const Text('协议适配', style: TextStyle(fontWeight: FontWeight.bold)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Anthropic 格式接口',
                style: TextStyle(fontSize: 14),
              ),
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
            SelectableText(
              _configPath(),
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 24),
            const Text('关于', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              '版本 $kAppVersion',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
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
                      child: Text(
                        gk.label.isEmpty ? '密钥 ${index + 1}' : gk.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (index == 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '默认',
                          style: TextStyle(
                            fontSize: 10,
                            color: cs.onPrimaryContainer,
                          ),
                        ),
                      ),
                      if (onRotate != null)
                        TextButton(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            textStyle: const TextStyle(fontSize: 12),
                          ),
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
                    fontFamily: 'monospace',
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _fmtLastUsed(gk.lastUsed),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          IconButton(
            icon: Icon(
              revealed ? Icons.visibility_off : Icons.visibility,
              size: 18,
            ),
            tooltip: revealed ? '隐藏' : '显示',
            onPressed: onToggleReveal,
          ),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: '复制密钥',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: gk.value));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已复制'),
                  duration: Duration(milliseconds: 600),
                ),
              );
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
                labelText: '标签',
                hintText: '如：手机 / 实验室机器（留空自动编号）',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _value,
              decoration: InputDecoration(
                labelText: '密钥值（可选）',
                hintText: '留空自动生成 sk-pg-…',
                helperText: '自定义值需全局唯一，建议使用工具生成的格式',
                helperStyle: TextStyle(
                  fontSize: 11,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            widget.service.addGatewayKey(
              _label.text,
              value: _value.text.trim().isEmpty ? null : _value.text,
            );
            Navigator.of(context).pop();
          },
          child: const Text('添加'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 代理轮换池页面
// ---------------------------------------------------------------------------

/// 内置代理轮换池：导入 Clash 配置 / 订阅 / 分享链接，按分组管理节点，
/// 把分组绑定到「用途」（某供应商出口 / 号池国内与国际出口 / WorkBuddy
/// 登录 / 第三方站点），网关出口链路即按分组的轮换策略取节点出网。
///
/// 页面只负责编辑与展示；池实例由 [GatewayService] 持有并落盘（增删改后
/// 池自身 notifyListeners，服务层监听器统一 save）。
class ProxyPoolPage extends StatefulWidget {
  final GatewayService service;
  const ProxyPoolPage({super.key, required this.service});

  @override
  State<ProxyPoolPage> createState() => _ProxyPoolPageState();
}

class _ProxyPoolPageState extends State<ProxyPoolPage> {
  final TextEditingController _importText = TextEditingController();
  final TextEditingController _subUrl = TextEditingController();
  bool _importing = false;
  bool _importingUrl = false;

  /// 上一次导入用的分组名（作为下次的默认值，便于连续导入同一订阅）
  String _lastGroup = '';

  /// 已展开的分组名集合：默认为空 = 全部收起（节点一多默认展开太长）
  final Set<String> _expandedGroups = {};

  /// 测速中的分组（null = 空闲）；同一时刻只跑一组、组内串行
  String? _probingGroup;
  final Map<String, int> _probeTotal = {};
  final Map<String, int> _probeDone = {};
  final Map<String, String> _probeResult = {};
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    // 冷却剩余时间按秒重绘，灰显才不会停在加载那一刻
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _importText.dispose();
    _subUrl.dispose();
    super.dispose();
  }

  GatewayService get _s => widget.service;
  ProxyPool? get _pool => _s.proxies;

  /// 导入/刷新结果用临时提示，不留下常驻横幅（提示完自动消失）
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
      );
  }

  // ---- 导入 ----

  /// 每次导入询问写入哪个分组（不同批次分开管理，同名分组合并）。
  /// 返回 null = 用户取消。
  Future<String?> _askImportGroup(String suggest) async {
    final controller = TextEditingController(
      text: _lastGroup.isNotEmpty ? _lastGroup : suggest,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入到分组'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
              decoration: const InputDecoration(
                labelText: '分组名称',
                hintText: '例如：机场A、备用线路、10月订阅',
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '不同批次的代理分开成组；同名分组合并。'
              '导入后可在下方「用途分配」里为每个出口单独选择用哪一组。',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    final trimmed = (name ?? '').trim();
    if (trimmed.isEmpty) return null;
    _lastGroup = trimmed;
    return trimmed;
  }

  String _suggestGroup([String prefix = '导入']) {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '$prefix ${two(n.month)}-${two(n.day)} ${two(n.hour)}:${two(n.minute)}';
  }

  /// 把一段文本导入指定分组（粘贴/剪贴板/文件共用）
  Future<void> _importTextInto(String text, String groupName) async {
    setState(() => _importing = true);
    // 粘贴/文件内容也可能是整段 base64（保存下来的订阅），统一先解包
    final added = await _s.importProxies(
      unwrapSubscriptionBody(text),
      groupName: groupName,
    );
    if (!mounted) return;
    setState(() {
      _importing = false;
      if (added > 0) _importText.clear();
    });
    _toast(
      added > 0
          ? '已导入 $added 个节点到分组「$groupName」'
          : '分组「$groupName」未新增节点（内容无效，或全部与池中已有节点重复）',
    );
  }

  Future<void> _doImport() async {
    final pool = _pool;
    if (pool == null || _importing) return;
    final text = _importText.text.trim();
    if (text.isEmpty) {
      _toast('请先粘贴内容（Clash YAML / 订阅链接 / 分享链接逐行）');
      return;
    }
    final group = await _askImportGroup(_suggestGroup());
    if (group == null || !mounted) return;
    await _importTextInto(text, group);
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = (data?.text ?? '').trim();
    if (t.isEmpty) {
      _toast('剪贴板是空的');
      return;
    }
    _importText.text = t;
    await _doImport();
  }

  /// 从本地文件导入（Clash YAML / 订阅文本 / 分享链接清单）
  Future<void> _importFromFile() async {
    if (_importing) return;
    const group = XTypeGroup(
      label: '代理配置',
      extensions: ['yaml', 'yml', 'txt', 'json', 'conf', 'list'],
    );
    try {
      final file = await openFile(acceptedTypeGroups: const [group]);
      if (file == null) return;
      final content = await file.readAsString();
      if (!mounted) return;
      final base = file.name.replaceAll(RegExp(r'\.[^.]+$'), '');
      final name = await _askImportGroup(base.isEmpty ? _suggestGroup() : base);
      if (name == null || !mounted) return;
      await _importTextInto(content, name);
    } catch (e) {
      _toast('读取文件失败：$e');
    }
  }

  /// 订阅链接：拉取响应体后按 base64 / 明文 / Clash YAML 自动识别
  Future<void> _doImportUrl() async {
    final pool = _pool;
    if (pool == null || _importingUrl) return;
    final url = _subUrl.text.trim();
    if (url.isEmpty) {
      _toast('请先填写订阅链接');
      return;
    }
    final host = Uri.tryParse(url)?.host ?? '';
    final group = await _askImportGroup(
      host.isEmpty ? _suggestGroup('订阅') : '订阅 $host',
    );
    if (group == null || !mounted) return;
    setState(() => _importingUrl = true);
    _toast('正在拉取订阅…');
    try {
      final added = await _s.importProxiesFromUrl(url, groupName: group);
      if (!mounted) return;
      if (added > 0) setState(() => _subUrl.clear());
      _toast(
        added > 0
            ? '订阅导入成功：新增 $added 个节点到分组「$group」'
            : '订阅已拉取，分组「$group」没有新节点（内容无效或全部重复）',
      );
    } catch (e) {
      _toast('订阅导入失败：$e');
    } finally {
      if (mounted) setState(() => _importingUrl = false);
    }
  }

  // ---- 编辑辅助 ----

  Future<void> _renameGroup(ProxyPool pool, String oldName) async {
    final controller = TextEditingController(text: oldName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分组'),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: controller,
            autofocus: true,
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
            decoration: const InputDecoration(labelText: '新分组名'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    pool.renameGroup(oldName, name.trim());
    _s.saveProxies();
  }

  /// 正在刷新订阅的分组名（按钮转圈，防重复点击）
  final Set<String> _refreshingSubs = {};

  /// 分组订阅设置：编辑/填写来源链接（保存后可手动刷新，自动刷新按开关走）
  Future<void> _editGroupSubscription(ProxyPool pool, ProxyGroup g) async {
    final controller = TextEditingController(text: g.sourceUrl);
    var auto = g.autoRefresh;
    var interval = g.refreshIntervalHours;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text('订阅来源 · ${g.name}'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '订阅链接',
                    hintText:
                        'https://example.com/api/v1/client/subscribe?token=...',
                    helperText: '机场会轮换节点地址；绑定后「立即刷新」或自动刷新会重新拉取并替换整组节点',
                    helperMaxLines: 3,
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    '自动刷新（每 $interval 小时）',
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: const Text(
                    '节点大面积冷却时也会自动提前刷新（30 分钟最多一次）',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: auto,
                  onChanged: (v) => setDlg(() => auto = v),
                ),
                Row(
                  children: [
                    const Text('刷新间隔：', style: TextStyle(fontSize: 13)),
                    const SizedBox(width: 8),
                    DropdownButton<int>(
                      value: interval,
                      items: const [1, 2, 3, 6, 12, 24, 48]
                          .map(
                            (h) => DropdownMenuItem(
                              value: h,
                              child: Text(
                                '$h 小时',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setDlg(() => interval = v);
                      },
                    ),
                  ],
                ),
                if (g.lastRefreshAt != null)
                  Text(
                    '上次刷新：${g.lastRefreshAt!.toLocal()}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    final url = controller.text.trim();
    controller.dispose();
    if (ok != true) return;
    g
      ..sourceUrl = url
      ..autoRefresh = auto
      ..refreshIntervalHours = interval;
    _s.saveProxies();
    setState(() {});
    if (url.isEmpty) return;
    // 填了链接直接拉一次，省得用户再点刷新
    await _refreshSubscription(pool, g);
  }

  /// 立即刷新分组订阅（重新拉取链接 → 整组替换节点；幸存节点保留健康度）
  Future<void> _refreshSubscription(ProxyPool pool, ProxyGroup g) async {
    if (_refreshingSubs.contains(g.name)) return;
    setState(() => _refreshingSubs.add(g.name));
    String msg;
    try {
      msg = await _s.refreshGroupSubscription(g.name);
    } catch (e) {
      msg = '订阅刷新失败：$e';
    }
    if (!mounted) return;
    setState(() => _refreshingSubs.remove(g.name));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 5)),
    );
  }

  Future<void> _confirmRemoveGroup(ProxyPool pool, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除分组「$name」？'),
        content: const Text(
          '节点本身仍留在池中，只是不再随该分组轮换；'
          '绑定到该分组的用途会一并解绑。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      pool.removeGroup(name);
      _s.saveProxies();
    }
  }

  void _removeNode(ProxyPool pool, String groupName, String nodeId) {
    pool.removeNode(groupName, nodeId);
    _s.saveProxies();
    _toast('已从「$groupName」移除；之后刷新订阅也不会再把它加回来');
  }

  // ---- 探活测速 ----

  /// 测速代际令牌：启动/停止/换组都递增，进行中的循环据此自行退出，避免
  /// 停止后残留请求继续写 UI。
  int _probeGen = 0;

  void _stopProbe() {
    _probeGen += 1;
    _probingGroup = null;
    _pool?.save();
    if (mounted) setState(() {});
  }

  /// 串行测一组（避免并发打爆出口）；结果逐行回填 [_probeResult]。
  Future<void> _startProbe(ProxyPool pool, ProxyGroup g) async {
    if (_probingGroup != null) return;
    final myGen = ++_probeGen;
    final nodes = g.nodes.toList();
    setState(() {
      _probingGroup = g.name;
      _probeTotal[g.name] = nodes.length;
      _probeDone[g.name] = 0;
      _probeResult[g.name] = '';
      for (final n in nodes) {
        _probeResult.remove('${g.name}#${n.id}');
      }
    });
    for (final n in nodes) {
      if (myGen != _probeGen || !mounted) return;
      setState(() => _probeDone[g.name] = (_probeDone[g.name] ?? 0) + 1);
      await _probeNode(pool, g.name, n);
    }
    if (myGen != _probeGen || !mounted) return;
    _probeGen += 1; // 本组测完：释放 _probingGroup
    _probingGroup = null;
    pool.save();
    setState(() => _probeResult[g.name] = '测速完成');
  }

  Future<void> _probeNode(ProxyPool pool, String group, ProxyNode n) async {
    final key = '$group#${n.id}';
    final directive = pool.directiveOf(n);
    if (directive == null) {
      setState(
        () => _probeResult[key] =
            '${n.name}：不可拨（加密协议需外置 HTTP 口，'
            '或 socks5 中转未预热）',
      );
      return;
    }
    final sw = Stopwatch()..start();
    String line;
    bool ok = false;
    try {
      // 探测请求本身经该节点出网（findProxy 覆盖环境变量代理，不存在自环：
      // 到代理地址的连接是直连的）
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 6)
        ..findProxy = (_) => directive;
      final req = await client.getUrl(
        Uri.parse('http://cp.cloudflare.com/generate_204'),
      );
      final resp = await req.close().timeout(const Duration(seconds: 8));
      await resp.drain<void>();
      sw.stop();
      ok = resp.statusCode == 204;
      line = ok
          ? '${n.name}：${sw.elapsedMilliseconds}ms'
          : '${n.name}：HTTP ${resp.statusCode}';
      client.close(force: true);
    } catch (_) {
      sw.stop();
      line = '${n.name}：失败（超时或连接错误）';
    }
    pool.report(n.id, ok, latencyMs: ok ? sw.elapsedMilliseconds : null);
    pool.save();
    if (mounted) setState(() => _probeResult[key] = line);
  }

  // ---- 导出 ----

  Future<void> _showExport(ProxyPool pool) async {
    final text = pool.exportConfigText();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出 Clash 配置'),
        content: SizedBox(
          width: 640,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(ctx)
                  .showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
            },
            child: const Text('全选复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ---- 用途列表 ----

  List<(String, String)> _purposes(ProxyPool pool) {
    final out = <(String, String)>[];
    for (final u in _s.config.upstreams) {
      // 本地服务（如 WorkBuddy hub）没有"供应商出口"可言：网关到它走回环，
      // 它的出网由自己的 realm 用途控制；绑定出口代理只会把回环请求截走。
      if (u.isLoopbackBaseUrl) continue;
      out.add((ProxyPool.pUpstream(u.id), '供应商出口 · ${u.displayName}'));
    }
    out.add((ProxyPool.pRealm(ProxyPool.realmCn), 'WorkBuddy 国内出口'));
    out.add((ProxyPool.pRealm(ProxyPool.realmIntl), 'WorkBuddy 国际出口'));
    if (_s.config.upstreams.any((u) => u.id == WorkBuddy.id)) {
      out.add((ProxyPool.pSignin(WorkBuddy.id), 'WorkBuddy 登录'));
    }
    out.add((ProxyPool.pThirdParty, '第三方站点'));
    return out;
  }

  // ---- 构建 ----

  String _cooldownLeft(NodeHealth h, DateTime now) {
    final last = h.lastChecked;
    if (last == null) return '';
    final left = ProxyPool.cooldown - now.difference(last);
    if (left <= Duration.zero) return '';
    final m = left.inMinutes;
    final s = left.inSeconds % 60;
    return m > 0 ? '${m}m${s}s' : '${s}s';
  }

  Widget _healthBadge(ProxyNode n, ProxyPool pool, DateTime now) {
    final h = pool.health[n.id];
    final cs = Theme.of(context).colorScheme;
    String label;
    Color color;
    if (h != null &&
        h.failCount >= ProxyPool.failLimit &&
        h.lastChecked != null &&
        now.difference(h.lastChecked!) < ProxyPool.cooldown) {
      label = '冷却中 ${_cooldownLeft(h, now)}';
      color = cs.onSurfaceVariant;
    } else if (h != null && h.failCount > 0) {
      label = '失败 ${h.failCount}/${ProxyPool.failLimit}';
      color = Colors.orange.shade700;
    } else if (h != null && h.latencyMs >= 0) {
      label = '${h.latencyMs}ms';
      color = Colors.green.shade700;
    } else {
      label = '未测';
      color = cs.onSurfaceVariant;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, color: color)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _s,
      builder: (context, _) {
        final pool = _pool;
        if (pool == null) {
          return Center(
            child: Text(
              '网关正在启动，代理池尚未加载…',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        final cs = Theme.of(context).colorScheme;
        final now = DateTime.now();
        final purposes = _purposes(pool);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ---- 导入区 ----
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '导入代理',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '支持粘贴：Clash YAML（proxies: 段 / 订阅全文）、各类分享链接逐行'
                      '（ss/vmess/vless/trojan/socks5/http…），或纯文本 host:port。'
                      '也可直接粘贴订阅链接自动拉取。代理仅作用于本应用发出的请求，'
                      '不修改系统代理。加密协议节点入池后仍需外置 HTTP 混合端口才能拨号（导入时会提示）。',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _importText,
                      minLines: 5,
                      maxLines: 12,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText:
                            'http://127.0.0.1:7890\n'
                            'socks5://user:pass@1.2.3.4:1080#东京\n'
                            '…或整段 Clash YAML',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: _importing ? null : _doImport,
                          icon: _importing
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.download, size: 18),
                          label: const Text('导入'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _importing ? null : _importFromClipboard,
                          icon: const Icon(Icons.paste, size: 18),
                          label: const Text('从剪贴板导入'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _importing ? null : _importFromFile,
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: const Text('从文件导入'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _subUrl,
                            style: const TextStyle(fontSize: 12),
                            onSubmitted: (_) => _doImportUrl(),
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                              labelText: '订阅链接',
                              hintText: 'https://example.com/api/v1/client/subscribe?token=…',
                              helperText:
                                  '自动拉取并解析：base64 / 明文分享链接 / Clash YAML',
                              helperMaxLines: 2,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          onPressed: _importingUrl ? null : _doImportUrl,
                          icon: _importingUrl
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.cloud_download_outlined,
                                  size: 18,
                                ),
                          label: const Text('拉取订阅'),
                        ),
                      ],
                    ),
                    if (pool.warnings.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final w in pool.warnings)
                              Text(
                                w,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.orange.shade700,
                                ),
                              ),
                          ],
                        ),
                      ),
                    if (pool.parseErrors.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final e in pool.parseErrors)
                              Text(
                                '解析失败：$e',
                                style: TextStyle(fontSize: 12, color: cs.error),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // ---- 分组列表 ----
            for (final g in pool.groups)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              tooltip: _expandedGroups.contains(g.name)
                                  ? '收起分组'
                                  : '展开分组',
                              visualDensity: VisualDensity.compact,
                              icon: Icon(
                                _expandedGroups.contains(g.name)
                                    ? Icons.expand_more
                                    : Icons.chevron_right,
                                size: 20,
                              ),
                              onPressed: () => setState(() {
                                if (!_expandedGroups.remove(g.name)) {
                                  _expandedGroups.add(g.name);
                                }
                              }),
                            ),
                            Icon(
                              Icons.folder_outlined,
                              size: 18,
                              color: cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Tooltip(
                              message: '双击重命名',
                              child: GestureDetector(
                                onDoubleTap: () => _renameGroup(pool, g.name),
                                child: Text(
                                  g.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${g.nodes.length} 个节点'
                              '${_expandedGroups.contains(g.name) ? '' : ' · ${g.strategy == 'latency' ? '延迟优先' : '轮换'}'}',
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            const Spacer(),
                            if (_probingGroup == g.name) ...[
                              Text(
                                '测速 ${_probeDone[g.name] ?? 0}/${_probeTotal[g.name] ?? 0}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: _stopProbe,
                                child: const Text('停止'),
                              ),
                            ] else
                              OutlinedButton.icon(
                                onPressed: g.nodes.isEmpty
                                    ? null
                                    : () => _startProbe(pool, g),
                                icon: const Icon(Icons.speed, size: 18),
                                label: const Text('测速'),
                              ),
                            const SizedBox(width: 4),
                            IconButton(
                              tooltip: '删除分组',
                              icon: Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: cs.error,
                              ),
                              onPressed: () =>
                                  _confirmRemoveGroup(pool, g.name),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // ---- 订阅来源：链接 + 自动刷新 + 手动刷新（收起也可见）----
                        Row(
                          children: [
                            Icon(
                              Icons.rss_feed,
                              size: 15,
                              color: cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: GestureDetector(
                                onTap: () => _editGroupSubscription(pool, g),
                                child: Text(
                                  g.sourceUrl.isEmpty
                                      ? '未绑定订阅链接（点击设置，可一键刷新/自动刷新）'
                                      : '订阅：${g.sourceUrl}'
                                            '${g.lastRefreshAt != null ? ' · 上次刷新 ${g.lastRefreshAt!.toLocal().toString().substring(0, 16)}' : ''}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: g.sourceUrl.isEmpty
                                        ? cs.onSurfaceVariant
                                        : cs.primary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            if (g.sourceUrl.isNotEmpty)
                              Tooltip(
                                message: g.autoRefresh
                                    ? '自动刷新已开：每 ${g.refreshIntervalHours} 小时'
                                          '或大面积失败时自动更新订阅（点订阅行可改间隔）'
                                    : '自动刷新已关',
                                child: Switch(
                                  value: g.autoRefresh,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  onChanged: (v) {
                                    g.autoRefresh = v;
                                    _s.saveProxies();
                                    setState(() {});
                                  },
                                ),
                              ),
                            if (g.sourceUrl.isNotEmpty)
                              _refreshingSubs.contains(g.name)
                                  ? const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  : IconButton(
                                      tooltip:
                                          '立即刷新订阅（重新拉取链接，'
                                          '替换整组节点；下线节点会被移除）',
                                      icon: const Icon(Icons.sync, size: 18),
                                      onPressed: () =>
                                          _refreshSubscription(pool, g),
                                    ),
                          ],
                        ),
                        // ---- 出口选择：自动（按策略轮换）或手动指定某个节点 ----
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.alt_route,
                                    size: 14,
                                    color: cs.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '出口',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                              SegmentedButton<String>(
                                style: const ButtonStyle(
                                  visualDensity: VisualDensity.compact,
                                ),
                                segments: const [
                                  ButtonSegment(
                                    value: 'auto',
                                    label: Text(
                                      '自动选择',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                  ButtonSegment(
                                    value: 'manual',
                                    label: Text(
                                      '手动指定',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ],
                                selected: {
                                  g.pinnedNodeId == null ? 'auto' : 'manual',
                                },
                                onSelectionChanged: (sel) {
                                  if (sel.first == 'auto') {
                                    pool.pinNode(g.name, null);
                                  } else {
                                    if (g.nodes.isEmpty) {
                                      _toast('该分组还没有节点');
                                      return;
                                    }
                                    final keep = g.nodes.any(
                                      (n) => n.id == g.pinnedNodeId,
                                    );
                                    pool.pinNode(
                                      g.name,
                                      keep ? g.pinnedNodeId : g.nodes.first.id,
                                    );
                                  }
                                  _s.saveProxies();
                                  setState(() {});
                                },
                              ),
                              if (g.pinnedNodeId != null)
                                g.nodes.any((n) => n.id == g.pinnedNodeId)
                                    ? ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 260,
                                        ),
                                        child: DropdownButton<String>(
                                          value: g.pinnedNodeId,
                                          isDense: true,
                                          isExpanded: true,
                                          items: [
                                            for (final n in g.nodes)
                                              DropdownMenuItem(
                                                value: n.id,
                                                child: Text(
                                                  n.name,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ),
                                          ],
                                          onChanged: (id) {
                                            if (id == null) return;
                                            pool.pinNode(g.name, id);
                                            _s.saveProxies();
                                            setState(() {});
                                          },
                                        ),
                                      )
                                    : Text(
                                        '指定节点已被移除，请重新选择',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: cs.error,
                                        ),
                                      ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        if (_expandedGroups.contains(g.name)) ...[
                          SegmentedButton<String>(
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                            segments: const [
                              ButtonSegment(
                                value: 'round-robin',
                                label: Text(
                                  '轮换',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              ButtonSegment(
                                value: 'latency',
                                label: Text(
                                  '延迟优先',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                            selected: {g.strategy},
                            onSelectionChanged: (sel) {
                              pool.setStrategy(g.name, sel.first);
                              _s.saveProxies();
                            },
                          ),
                          Text(
                            g.strategy == 'latency'
                                ? '延迟优先：始终走测速最快且未冷却的节点（按延迟升序参与出口轮换）'
                                : '轮换：组内节点轮流参与出口轮换，冷却节点自动跳过',
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (g.nodes.isEmpty)
                            Text(
                              '（空分组，导入时可在内容里用名字指定归属）',
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            )
                          else
                            for (final n in g.nodes)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 96,
                                      child: _healthBadge(n, pool, now),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            n.name,
                                            style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          Text(
                                            '${n.type} · ${n.host}:${n.port}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontFamily: 'monospace',
                                              color: cs.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (_probeResult.containsKey(
                                      '${g.name}#${n.id}',
                                    ))
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 8,
                                        ),
                                        child: Text(
                                          _probeResult['${g.name}#${n.id}']!,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: cs.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    if (pool.directiveOf(n) == null &&
                                        n.dartUsable == false &&
                                        n.type.toLowerCase() != 'socks5' &&
                                        n.type.toLowerCase() != 'socks')
                                      Text(
                                        '需外置 HTTP 口',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.orange.shade700,
                                        ),
                                      ),
                                    if (g.pinnedNodeId == n.id)
                                      Tooltip(
                                        message: '已钉住：本组出口固定用这个节点',
                                        child: Icon(
                                          Icons.push_pin,
                                          size: 16,
                                          color: Colors.orange.shade700,
                                        ),
                                      ),
                                    IconButton(
                                      tooltip: g.pinnedNodeId == n.id
                                          ? '取消钉住（恢复组内轮换）'
                                          : '钉住：该组出口固定用这个节点',
                                      icon: Icon(
                                        g.pinnedNodeId == n.id
                                            ? Icons.push_pin
                                            : Icons.push_pin_outlined,
                                        size: 17,
                                        color: g.pinnedNodeId == n.id
                                            ? Colors.orange.shade700
                                            : cs.onSurfaceVariant,
                                      ),
                                      onPressed: () {
                                        pool.pinNode(
                                          g.name,
                                          g.pinnedNodeId == n.id ? null : n.id,
                                        );
                                        _s.saveProxies();
                                      },
                                    ),
                                    IconButton(
                                      tooltip: '从本组移除',
                                      icon: Icon(
                                        Icons.close,
                                        size: 18,
                                        color: cs.onSurfaceVariant,
                                      ),
                                      onPressed: () =>
                                          _removeNode(pool, g.name, n.id),
                                    ),
                                  ],
                                ),
                              ),
                          if (_probeResult[g.name] != null &&
                              _probeResult[g.name]!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                _probeResult[g.name]!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            // ---- 用途分配 ----
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '用途分配',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const Spacer(),
                        OutlinedButton.icon(
                          onPressed: pool.groups.isEmpty
                              ? null
                              : () => _showExport(pool),
                          icon: const Icon(Icons.ios_share, size: 18),
                          label: const Text('导出 Clash 配置'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '把分组绑定到用途后，对应链路的出口自动按分组策略轮换；'
                      '开关关闭 = 该用途直连（保留绑定）。',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final p in purposes)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 220,
                              child: Text(
                                p.$2,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            Switch(
                              value: pool.isEnabled(p.$1),
                              onChanged: (v) {
                                pool.setEnabled(p.$1, v);
                                _s.saveProxies();
                              },
                            ),
                            const SizedBox(width: 8),
                            DropdownButton<String?>(
                              value: pool.assignments[p.$1],
                              hint: const Text(
                                '不绑定',
                                style: TextStyle(fontSize: 12),
                              ),
                              items: [
                                const DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text(
                                    '不绑定',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                                for (final g in pool.groups)
                                  DropdownMenuItem<String?>(
                                    value: g.name,
                                    child: Text(
                                      '${g.name}（${g.strategy == 'latency' ? '延迟' : '轮换'}）',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                              ],
                              onChanged: (v) {
                                pool.assign(p.$1, v);
                                _s.saveProxies();
                              },
                            ),
                            const SizedBox(width: 12),
                            Text(
                              pool.assignments[p.$1] == null
                                  ? ''
                                  : (pool.isEnabled(p.$1)
                                        ? '${poolDirectivesFor(pool, p.$1).length} 个可拨出口'
                                        : '已关闭'),
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '提示：供应商出口链路（设置 → 出口代理）会把绑定分组的节点排到手写地址之前；'
              'socks5 节点经内置本地中转出网（临时端口随会话变化，不写入配置文件）。',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        );
      },
    );
  }
}
