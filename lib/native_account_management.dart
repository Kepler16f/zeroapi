import 'dart:convert';
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';

import 'gateway/provider_management.dart';
import 'gateway/service.dart';

class NativeAccountManagementPage extends StatefulWidget {
  const NativeAccountManagementPage({
    super.key,
    required this.service,
    this.management,
  });
  final GatewayService service;
  final WorkBuddyManagement? management;
  @override
  State<NativeAccountManagementPage> createState() =>
      _NativeAccountManagementPageState();
}

class _NativeAccountManagementPageState
    extends State<NativeAccountManagementPage> {
  late final WorkBuddyManagement api =
      widget.management ?? WorkBuddyManagement(widget.service);
  List<Map<String, dynamic>> accounts = [];
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final rows = await api.accounts();
      if (mounted) setState(() => accounts = rows);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> action(Future<Map<String, dynamic>> Function() run) async {
    setState(() => busy = true);
    try {
      final result = await run();
      if (!mounted) return;
      final msg = result['msg'] ?? '操作完成';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$msg')));
      await load();
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('操作失败：$e')));
      }
    }
  }

  Future<void> edit(Map<String, dynamic> a) async {
    final weight = TextEditingController(text: '${a['weight'] ?? 1}');
    final note = TextEditingController(text: '${a['note'] ?? ''}');
    final proxy = TextEditingController(text: '${a['proxy'] ?? ''}');
    final slot = TextEditingController(text: '${a['proxySlot'] ?? ''}');
    final models = TextEditingController(
      text: (a['disabledModels'] is List
          ? (a['disabledModels'] as List).join(', ')
          : ''),
    );
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑账号'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: weight,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '权重（1–100）'),
              ),
              TextField(
                controller: note,
                decoration: const InputDecoration(labelText: '备注'),
              ),
              TextField(
                controller: proxy,
                decoration: const InputDecoration(labelText: '账号代理地址（留空直连）'),
              ),
              TextField(
                controller: slot,
                decoration: const InputDecoration(labelText: '代理槽位 ID（留空取消绑定）'),
              ),
              TextField(
                controller: models,
                decoration: const InputDecoration(labelText: '禁用模型（逗号分隔）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(weight.text);
              if (n == null || n < 1 || n > 100) return;
              Navigator.pop(ctx, {
                'weight': n,
                'note': note.text,
                'proxy': proxy.text.trim(),
                'proxySlot': slot.text.trim(),
                'disabledModels': models.text
                    .split(RegExp(r'[,，\n]'))
                    .map((e) => e.trim())
                    .where((e) => e.isNotEmpty)
                    .toList(),
              });
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    weight.dispose();
    note.dispose();
    models.dispose();
    proxy.dispose();
    slot.dispose();
    if (result != null) {
      await action(() => api.updateAccount('${a['uid']}', result));
    }
  }

  Future<void> importJson() async {
    final file = await openFile(
      acceptedTypeGroups: [const XTypeGroup(label: 'JSON', extensions: ['json'])],
    );
    if (file == null) return;
    if (!mounted) return;
    try {
      final data = jsonDecode(await file.readAsString());
      if (data is! Map && data is! List) {
        throw const FormatException('需要 JSON 对象或数组');
      }
      if (!mounted) return;
      final dryRun = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入账号文件'),
          content: Text('已读取 ${file.name}。先校验文件且不写入账号？'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('直接导入')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('仅校验')),
          ],
        ),
      );
      if (dryRun != null) {
        await action(() => api.importAccounts(data, dryRun: dryRun));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  Future<void> remove(Map<String, dynamic> a) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账号？'),
        content: Text('将从号池删除 ${a['nickname'] ?? a['uid']}。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes == true) await action(() => api.deleteAccount('${a['uid']}'));
  }

  Future<void> addKey() async {
    final key = TextEditingController();
    final nickname = TextEditingController();
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加 CodeBuddy 静态 Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: key,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'ck_ / pt_ Key'),
            ),
            TextField(
              controller: nickname,
              decoration: const InputDecoration(labelText: '昵称（可选）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, {
              'key': key.text.trim(),
              'nickname': nickname.text.trim(),
            }),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    key.dispose();
    nickname.dispose();
    if (data != null && (data['key'] as String).isNotEmpty) {
      await action(() => api.addStaticKey(data['key'] as String, data['nickname'] as String));
    }
  }

  Future<void> exportAccounts([String? uid]) async {
    try {
      final location = await getSaveLocation(
        suggestedName: 'workbuddy-accounts.json',
        acceptedTypeGroups: [
          const XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (location == null) return;
      final data = await api.exportAccounts(uid);
      await XFile.fromData(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
        mimeType: 'application/json',
      ).saveTo(location.path);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('账号已导出，请妥善保管凭证文件')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  Future<void> login() async {
    final realm = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择登录区域'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cn'),
            child: const Text('国内'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'intl'),
            child: const Text('国际'),
          ),
        ],
      ),
    );
    if (realm == null || !mounted) return;
    try {
      final start = await api.startLogin(realm);
      final state = start['state']?.toString() ?? '';
      final url = start['authUrl']?.toString() ?? '';
      if (state.isEmpty || url.isEmpty) {
        throw const FormatException('登录响应缺少 state 或授权地址');
      }
      if (!mounted) {
        await api.cancelLogin(state);
        return;
      }
      final completed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _LoginDialog(api: api, state: state, url: url),
      );
      if (completed == true && mounted) await load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('登录失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('账号管理'),
      actions: [
        IconButton(
          onPressed: busy ? null : load,
          icon: const Icon(Icons.refresh),
          tooltip: '刷新',
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(
              onPressed: busy ? null : login,
              child: const Text('OAuth 登录'),
            ),
            FilledButton.tonal(
              onPressed: busy ? null : addKey,
              child: const Text('添加静态 Key'),
            ),
            FilledButton.tonal(
              onPressed: busy ? null : () => exportAccounts(),
              child: const Text('导出账号'),
            ),
            FilledButton.tonal(
              onPressed: busy
                  ? null
                  : () => action(api.importDesktop),
              child: const Text('导入本机桌面账号'),
            ),
            FilledButton.tonal(
              onPressed: busy ? null : importJson,
              child: const Text('导入 JSON'),
            ),
          ],
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (!busy && accounts.isEmpty && error == null)
          const ListTile(title: Text('暂无账号')),
        for (final a in accounts)
          Card(
            child: ListTile(
              title: Text('${a['nickname'] ?? a['uid'] ?? '未知账号'}'),
              subtitle: Text(
                '${a['realm'] ?? '未知'} · 权重 ${a['weight'] ?? 1} · ${a['note'] ?? ''}\n风控至 ${a['restrictedUntil'] ?? '未知'} · 冷却 ${a['cooldownUntil'] ?? '无数据'}',
              ),
              leading: Switch(
                value: a['enabled'] == true,
                onChanged: busy
                    ? null
                    : (v) => action(
                        () => api.updateAccount('${a['uid']}', {'enabled': v}),
                      ),
              ),
              trailing: PopupMenuButton<String>(
                enabled: !busy,
                onSelected: (v) {
                  if (v == 'edit') edit(a);
                  if (v == 'delete') remove(a);
                  if (v == 'export') exportAccounts('${a['uid']}');
                  if (v == 'test') {
                    action(() => api.post('/accounts/test', {'uid': a['uid']}));
                  }
                  if (v == 'tasks') {
                    action(
                      () => api.updateAccount('${a['uid']}', {
                        'tasksEnabled': a['tasksEnabled'] != true,
                      }),
                    );
                  }
                  if (v == 'credits') {
                    action(
                      () => api.post('/accounts/credits', {'uid': a['uid']}),
                    );
                  }
                  if (v == 'refresh') {
                    action(
                      () => api.post('/accounts/refresh', {'uid': a['uid']}),
                    );
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'tasks', child: Text('切换任务开关')),
                  PopupMenuItem(value: 'test', child: Text('测试账号')),
                  PopupMenuItem(value: 'credits', child: Text('刷新积分')),
                  PopupMenuItem(value: 'export', child: Text('导出账号')),
                  PopupMenuItem(value: 'refresh', child: Text('刷新凭证')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class _LoginDialog extends StatefulWidget {
  const _LoginDialog({
    required this.api,
    required this.state,
    required this.url,
  });
  final WorkBuddyManagement api;
  final String state;
  final String url;
  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  Timer? timer;
  bool polling = false;
  bool complete = false;
  String status = '等待授权';
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => poll());
  }

  Future<void> poll() async {
    if (polling || complete) return;
    polling = true;
    try {
      final result = await widget.api.pollLogin(widget.state);
      if (!mounted) return;
      final state = result['status']?.toString() ?? 'unknown';
      if (state == 'ok' || state == 'success' || state == 'done') {
        complete = true;
        timer?.cancel();
        Navigator.pop(context, true);
        return;
      }
      if (state != 'pending') timer?.cancel();
      setState(() => status = '${result['message'] ?? state}');
    } catch (e) {
      timer?.cancel();
      if (mounted) setState(() => status = '查询失败：$e');
    } finally {
      polling = false;
    }
  }

  Future<void> cancel() async {
    timer?.cancel();
    try {
      await widget.api.cancelLogin(widget.state);
    } catch (_) {}
    if (mounted) Navigator.pop(context, false);
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('OAuth 授权'),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('复制授权地址到浏览器完成登录，完成后自动加入账号池。'),
          const SizedBox(height: 8),
          SelectableText(widget.url),
          const SizedBox(height: 8),
          Text(status),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Clipboard.setData(ClipboardData(text: widget.url)),
        child: const Text('复制授权地址'),
      ),
      TextButton(onPressed: cancel, child: const Text('取消')),
    ],
  );
}
