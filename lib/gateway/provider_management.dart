import 'dart:convert';
import 'dart:io';

import 'service.dart';

/// Optional management capabilities exposed by a provider adapter.
enum ProviderCapability {
  accounts, desktopImport, accountImport, staticApiKey, oauth, accountProxy,
  scheduler, tasks,
}

abstract interface class ProviderManagement {
  Set<ProviderCapability> get capabilities;
  Future<List<Map<String, dynamic>>> accounts();
  Future<Map<String, dynamic>> updateAccount(
    String uid,
    Map<String, dynamic> changes,
  );
  Future<Map<String, dynamic>> deleteAccount(String uid);
}

class WorkBuddyManagement implements ProviderManagement {
  WorkBuddyManagement(this.service, {this.readOverride});
  final GatewayService service;

  /// Test or provider transport injection.
  final Future<Map<String, dynamic>> Function(String path)? readOverride;
  @override
  Set<ProviderCapability> get capabilities => const {
    ProviderCapability.accounts,
    ProviderCapability.desktopImport,
    ProviderCapability.accountImport,
    ProviderCapability.scheduler,
    ProviderCapability.staticApiKey,
    ProviderCapability.oauth,
    ProviderCapability.accountProxy,
    ProviderCapability.tasks,
  };

  /// Preserve HTTP errors for optional endpoints; a missing route is distinct
  /// from authentication and connectivity failures.
  Future<Map<String, dynamic>> get(String path) async {
    if (readOverride != null) return readOverride!(path);
    final base = service.workbuddyHubBase;
    if (base.isEmpty) throw StateError('未接入 WorkBuddy 号池');
    for (var attempt = 0; attempt < 2; attempt++) {
      final token = await service.hubPanelToken(forceRefresh: attempt > 0);
      if (token == null) throw StateError('号池面板登录失败');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.getUrl(Uri.parse('$base$path'));
        req.headers.set('X-Panel-Token', token);
        final response = await req.close().timeout(const Duration(seconds: 30));
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 30));
        if (response.statusCode == 401 && attempt == 0) continue;
        if (response.statusCode == 404 || response.statusCode == 405) {
          throw UnsupportedError('当前号池版本不支持此功能');
        }
        if (response.statusCode != 200) {
          throw HttpException('号池请求失败：HTTP ${response.statusCode}');
        }
        final value = jsonDecode(body);
        if (value is! Map<String, dynamic>) {
          throw const FormatException('号池响应不是 JSON 对象');
        }
        return value;
      } finally {
        client.close(force: true);
      }
    }
    throw StateError('号池面板会话失效');
  }

  Future<Map<String, dynamic>> startLogin(String realm) =>
      post('/accounts/login/start', {'realm': realm, 'platform': 'CLI'});
  Future<Map<String, dynamic>> pollLogin(String state) =>
      get('/accounts/login/poll?state=${Uri.encodeComponent(state)}');
  Future<Map<String, dynamic>> cancelLogin(String state) =>
      post('/accounts/login/cancel', {'state': state});
  Future<Map<String, dynamic>> exportAccounts([String? uid]) => get(
    '/accounts/export${uid == null ? '' : '?uid=${Uri.encodeComponent(uid)}'}',
  );

  Future<Map<String, dynamic>> importAccounts(
    Object data, {bool dryRun = false, bool overwrite = false, String? realm,}
  ) => post('/accounts/import', {
    'data': data, 'dryRun': dryRun, 'overwrite': overwrite,
    'realm': ?realm,
  });

  Future<Map<String, dynamic>> importDesktop({bool all = true}) =>
      post('/accounts/import/desktop', {'all': all});

  Future<Map<String, dynamic>> addStaticKey(String key, String nickname) {
    final normalized = key.trim();
    if (!RegExp(r'^(ck_|pt_)').hasMatch(normalized)) {
      throw const FormatException('静态 Key 必须以 ck_ 或 pt_ 开头');
    }
    return post('/accounts/add-api-key', {
      'key': normalized, 'nickname': nickname.trim(),
    });
  }

  Future<Map<String, dynamic>> scheduler() => get('/scheduler');
  Future<Map<String, dynamic>> settings() => get('/settings');
  Future<Map<String, dynamic>> saveSettings(Map<String, dynamic> patch) =>
      post('/settings/save', patch);
  Future<Map<String, dynamic>> schedulerAction(String action) {
    if (!const {'toggle', 'trigger'}.contains(action)) {
      throw ArgumentError.value(action, 'action');
    }
    return post('/scheduler/$action');
  }

  @override
  Future<List<Map<String, dynamic>>> accounts() async {
    final result = await service.hubGet('/accounts?realm=all');
    if (result == null || result['accounts'] is! List) {
      throw StateError('号池账号列表响应缺少 accounts');
    }
    return (result['accounts'] as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<Map<String, dynamic>> post(
    String path, [
    Map<String, dynamic> body = const {},
  ]) async {
    Map<String, dynamic> result;
    try {
      result = await service.hubPost(path, body);
    } on HttpException catch (e) {
      if (e.message.contains('HTTP 404') || e.message.contains('HTTP 405')) {
        throw UnsupportedError('当前号池版本不支持此功能');
      }
      rethrow;
    }
    if (result['ok'] == false) {
      throw StateError('${result['msg'] ?? result['error'] ?? '操作失败'}');
    }
    return result;
  }

  @override
  Future<Map<String, dynamic>> updateAccount(
    String uid,
    Map<String, dynamic> changes,
  ) => post('/accounts/set', {...changes, 'uid': uid});
  @override
  Future<Map<String, dynamic>> deleteAccount(String uid) =>
      post('/accounts/delete', {'uid': uid});
}
