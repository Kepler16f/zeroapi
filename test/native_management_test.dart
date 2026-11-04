import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/provider_management.dart';
import 'package:zeroapi/gateway/service.dart';
import 'package:zeroapi/native_account_management.dart';

class ManagementService extends GatewayService {
  final posts = <(String, Map<String, dynamic>)>[];
  @override
  Future<Map<String, dynamic>?> hubGet(String path) async => {
    'accounts': [
      {
        'uid': 'u1',
        'nickname': '测试账号',
        'realm': 'cn',
        'enabled': true,
        'weight': 1,
        'tasksEnabled': true,
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> hubPost(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    posts.add((path, body));
    if (path == '/accounts/login/start') {
      return {'state': 's &1', 'authUrl': 'https://example.org/auth'};
    }
    return {'ok': true};
  }
}

void main() {
  test('OAuth 及导出使用打包 hub 的请求字段和 URL 编码', () async {
    final service = ManagementService();
    final paths = <String>[];
    final api = WorkBuddyManagement(
      service,
      readOverride: (path) async {
        paths.add(path);
        return {
          'status': 'ok',
          'account': {'uid': 'u1'},
        };
      },
    );
    expect((await api.startLogin('cn'))['authUrl'], 'https://example.org/auth');
    expect(service.posts.single.$1, '/accounts/login/start');
    expect(service.posts.single.$2, {'realm': 'cn', 'platform': 'CLI'});
    expect((await api.pollLogin('s &1'))['status'], 'ok');
    await api.cancelLogin('s &1');
    await api.exportAccounts('a/b');
    expect(paths, [
      '/accounts/login/poll?state=s%20%261',
      '/accounts/export?uid=a%2Fb',
    ]);
    expect(service.posts.last.$1, '/accounts/login/cancel');
    expect(service.posts.last.$2, {'state': 's &1'});
  });
  testWidgets('原生 OAuth 等待并识别 ok 状态后刷新账号', (tester) async {
    final service = ManagementService();
    final paths = <String>[];
    final api = WorkBuddyManagement(
      service,
      readOverride: (path) async {
        paths.add(path);
        return {
          'status': 'ok',
          'account': {'uid': 'u1'},
        };
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: NativeAccountManagementPage(service: service, management: api),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('OAuth 登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('国内').last);
    await tester.pumpAndSettle();
    expect(find.text('等待授权'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(paths.single, '/accounts/login/poll?state=s%20%261');
    expect(find.text('OAuth 授权'), findsNothing);
    expect(find.text('测试账号'), findsOneWidget);
  });
  testWidgets('账号开关发送明确的 enabled 字段', (tester) async {
    final service = ManagementService();
    await tester.pumpWidget(
      MaterialApp(home: NativeAccountManagementPage(service: service)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(service.posts.single.$1, '/accounts/set');
    expect(service.posts.single.$2, {'uid': 'u1', 'enabled': false});
  });
  test('不支持的写入接口与其他 HTTP 错误区分', () async {
    final service = _FailingService();
    final api = WorkBuddyManagement(service);
    await expectLater(api.post('/missing'), throwsA(isA<UnsupportedError>()));
  });
}

class _FailingService extends ManagementService {
  @override
  Future<Map<String, dynamic>> hubPost(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 30),
  }) async => throw const HttpException('HTTP 404');
}
