import 'package:flutter/material.dart';

import 'gateway/provider_management.dart';
import 'gateway/service.dart';

/// Edits only fields returned by the running hub, so older versions do not
/// silently accept settings they cannot apply.
class NativeSchedulerSettingsPage extends StatefulWidget {
  const NativeSchedulerSettingsPage({super.key, required this.service});
  final GatewayService service;
  @override
  State<NativeSchedulerSettingsPage> createState() =>
      _NativeSchedulerSettingsPageState();
}

class _NativeSchedulerSettingsPageState
    extends State<NativeSchedulerSettingsPage> {
  late final api = WorkBuddyManagement(widget.service);
  Map<String, dynamic>? settings;
  Map<String, dynamic>? schedulerState;
  String? error;
  bool busy = true;
  final controllers = <String, TextEditingController>{};
  static const labels = {
    'reserve_credits': '预留积分',
    'account_max_concurrent': '单账号并发上限',
  };
  static const scheduleLabels = {
    'checkin': '签到时段（整点）',
    'travel': '旅行时段（整点）',
    'keepalive': '保活时段（整点）',
    'cat': '猫猫时段（整点）',
    'daily_chat': '每日活跃时间（HH:MM）',
  };
  static const switches = {
    'remaining_priority_enabled': '剩余额度优先',
    'egress_backoff_enabled': '出口退避',
    'realm_fallback_enabled': '区域回退',
    'daily_chat_web': '网页每日活跃',
    'daily_chat_startup_catchup': '启动时补打',
  };
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final values = await Future.wait([api.settings(), api.scheduler()]);
      final data = values[0];
      if (!mounted) return;
      for (final c in controllers.values) {
        c.dispose();
      }
      controllers.clear();
      for (final key in labels.keys) {
        if (data[key] is num) {
          controllers[key] = TextEditingController(text: '${data[key]}');
        }
      }
      final schedule = data['schedule'];
      if (schedule is Map) {
        for (final key in scheduleLabels.keys) {
          if (schedule[key] is List) {
            controllers['schedule.$key'] = TextEditingController(
              text: (schedule[key] as List).join(', '),
            );
          }
        }
      }
      setState(() {
        settings = data;
        schedulerState = values[1];
        busy = false;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  Future<void> save() async {
    try {
      final patch = <String, dynamic>{};
      final schedule = <String, dynamic>{};
      for (final entry in controllers.entries) {
        if (entry.key.startsWith('schedule.')) {
          final key = entry.key.substring(9);
          final parts = entry.value.text
              .split(RegExp(r'[,，\s]+'))
              .where((v) => v.isNotEmpty)
              .toList();
          if (key == 'daily_chat') {
            if (parts.any(
              (v) => !RegExp(r'^(?:[01]?\d|2[0-3]):[0-5]\d$').hasMatch(v),
            )) {
              throw const FormatException('每日活跃时间应为 HH:MM');
            }
            schedule[key] = parts;
          } else {
            final hours = parts.map(int.tryParse).toList();
            if (hours.isEmpty || hours.any((v) => v == null || v < 0 || v > 23)) {
              throw const FormatException('排程整点须为 0–23');
            }
            schedule[key] = hours;
          }
        } else {
          final value = num.tryParse(entry.value.text);
          if (value == null ||
              value < 0 ||
              (entry.key == 'account_max_concurrent' && value != value.toInt())) {
            throw FormatException('${labels[entry.key]}须为非负数');
          }
          patch[entry.key] = entry.key == 'account_max_concurrent'
              ? value.toInt()
              : value;
        }
      }
      if (schedule.isNotEmpty) patch['schedule'] = schedule;
      for (final key in switches.keys) {
        if (settings!.containsKey(key)) patch[key] = settings![key];
      }
      setState(() => busy = true);
      await api.saveSettings(patch);
      final returned = await api.settings();
      final ignored = patch.keys.where((key) {
        if (key == 'schedule') return returned['schedule'] == null;
        return !returned.containsKey(key);
      }).toList();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ignored.isEmpty ? '调度设置已保存' : '未确认支持：${ignored.join('、')}',
          ),
        ),
      );
      await load();
    } catch (e) {
      if (mounted) {
        setState(() => busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    }
  }

  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('调度与限额设置')),
    body: busy
        ? const Center(child: CircularProgressIndicator())
        : error != null
        ? Center(child: Text('读取失败：$error'))
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('仅编辑当前运行版本公开的设置；多个时段用逗号分隔。'),
              if (schedulerState != null)
                Card(child: ListTile(
                  title: Text('调度器：${schedulerState!['enabled'] == true ? '已启用' : '已停止'}'),
                  subtitle: Text('${schedulerState!['msg'] ?? ''} 运行状态：${schedulerState!['running'] == true ? '运行中' : '空闲'}'),
                  trailing: Wrap(children: [
                    IconButton(tooltip: '切换调度', onPressed: busy ? null : () async {
                      try { await api.schedulerAction('toggle'); await load(); }
                      catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('切换失败：$e')));
                      }
                    }, icon: const Icon(Icons.power_settings_new)),
                    IconButton(tooltip: '立即巡检', onPressed: busy ? null : () async {
                      try { await api.schedulerAction('trigger'); }
                      catch (e) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('巡检失败：$e')));
                      }
                    }, icon: const Icon(Icons.play_arrow)),
                  ]),
                )),
              for (final key in labels.keys)
                if (controllers.containsKey(key))
                  TextField(
                    controller: controllers[key],
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(labelText: labels[key]),
                  ),
              for (final entry in scheduleLabels.entries)
                if (controllers.containsKey('schedule.${entry.key}'))
                  TextField(
                    controller: controllers['schedule.${entry.key}'],
                    decoration: InputDecoration(labelText: entry.value),
                  ),
              for (final entry in switches.entries)
                if (settings!.containsKey(entry.key))
                  SwitchListTile(
                    title: Text(entry.value),
                    value: settings![entry.key] == true,
                    onChanged: (v) => setState(() => settings![entry.key] = v),
                  ),
              if (controllers.isEmpty &&
                  switches.keys.every((key) => !settings!.containsKey(key)))
                const Text('当前号池版本不支持这些设置'),
              const SizedBox(height: 16),
              FilledButton(onPressed: save, child: const Text('保存')),
            ],
          ),
  );
}
