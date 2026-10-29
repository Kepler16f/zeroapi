import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 「仅 Pro」持久标记：上游按账号类型拒绝模型（workbuddy 错误码 11158 /
/// "not allowed for user type [personal_free_user]"）时记下该模型；号池里
/// 没有付费账号时，Pro 专属模型第一次被调用即标注在模型清单上，
/// 任一账号调用成功即自动解除。
///
/// 刻意不预置模型名单：上游策略会变（今天 Pro 专属的模型，明天可能进免费
/// 池），以真实调用结果为准，标出来的都是"确实被拒过"的，不会出现假标签。
/// 持久化在 %APPDATA%\zeroapi\progate.json，重启后标签不丢。
class ProGate {
  ProGate._() {
    _load();
  }

  static final ProGate instance = ProGate._();

  static File? _overrideFile;

  /// 测试注入：改用临时目录，别污染 %APPDATA%\zeroapi\progate.json。
  @visibleForTesting
  static void setFileForTest(File f) {
    _overrideFile = f;
    instance._load();
  }

  static File _file() {
    final o = _overrideFile;
    if (o != null) return o;
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']!
        : '${Platform.environment['HOME']}/.config';
    final dir = Directory('$base/zeroapi');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}/progate.json');
  }

  /// upstreamId → 被判定 Pro 专属的上游模型名集合
  final Map<String, Set<String>> _pro = {};

  void _load() {
    _pro.clear();
    try {
      final j = jsonDecode(_file().readAsStringSync());
      if (j is Map) {
        for (final e in j.entries) {
          final list = e.value;
          if (list is List) {
            _pro['${e.key}'] = {for (final m in list) '$m'};
          }
        }
      }
    } catch (_) {
      // 读不到就空表：下一次被拒会重新标记
    }
  }

  void _save() {
    try {
      _file().writeAsStringSync(
        const JsonEncoder.withIndent('  ')
            .convert({for (final e in _pro.entries) e.key: e.value.toList()}),
      );
    } catch (_) {}
  }

  /// 从上游错误文本判定是否「账号类型不支持该模型」。
  static bool isUserTypeRejection(String errText) {
    final l = errText.toLowerCase();
    return l.contains('11158') ||
        l.contains('not allowed for user type') ||
        l.contains('user type') && l.contains('not allowed') ||
        errText.contains('账号类型暂不支持');
  }

  void mark(String upstreamId, String model) {
    final set = _pro.putIfAbsent(upstreamId, () => <String>{});
    if (set.add(model)) _save();
  }

  void clear(String upstreamId, String model) {
    final set = _pro[upstreamId];
    if (set != null && set.remove(model)) _save();
  }

  bool isPro(String upstreamId, String model) =>
      _pro[upstreamId]?.contains(model) ?? false;

  Set<String> proModels(String upstreamId) =>
      Set.unmodifiable(_pro[upstreamId] ?? const {});

  /// 测试注入用
  void resetForTest() => _pro.clear();
}
