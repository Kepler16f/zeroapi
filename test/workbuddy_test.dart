import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/workbuddy.dart';

void main() {
  group('WorkBuddy.panelUrl', () {
    UpstreamDef def(String baseUrl, [String id = WorkBuddy.id]) =>
        UpstreamDef(id: id, type: 'managed', label: 'wb', baseUrl: baseUrl);

    test('去掉 /v1 后缀，得到面板根地址', () {
      expect(WorkBuddy.panelUrl(def('http://127.0.0.1:8788/v1')),
          'http://127.0.0.1:8788/');
    });

    test('base url 已经不带路径时也补上斜杠', () {
      expect(WorkBuddy.panelUrl(def('http://127.0.0.1:8788')),
          'http://127.0.0.1:8788/');
    });

    test('保留非 loopback 地址（局域网场景）', () {
      expect(WorkBuddy.panelUrl(def('http://192.168.1.10:8788/v1')),
          'http://192.168.1.10:8788/');
    });

    test('已经是根路径时不重复斜杠', () {
      expect(WorkBuddy.panelUrl(def('http://127.0.0.1:8788/')),
          'http://127.0.0.1:8788/');
    });
  });

  group('WorkBuddy.panelPassword', () {
    UpstreamDef def(List<String> args) => UpstreamDef(
        id: WorkBuddy.id,
        type: 'managed',
        label: 'wb',
        baseUrl: 'http://127.0.0.1:8788/v1',
        command: 'pythonw.exe',
        args: args);

    test('从 --panel-password 参数取值', () {
      expect(
        WorkBuddy.panelPassword(def([
          '--panel-password',
          '3kQz9vNm7xPb2rLt',
          '--port',
          '8788',
        ])),
        '3kQz9vNm7xPb2rLt',
      );
    });

    test('参数在最后也能取到', () {
      expect(
        WorkBuddy.panelPassword(def(['--port', '8791', '--panel-password', '末位密码'])),
        '末位密码',
      );
    });

    test('--panel-password 后面没有值时回落到 admin', () {
      expect(
        WorkBuddy.panelPassword(def(['--port', '8788', '--panel-password'])),
        'admin',
      );
    });

    test('命令行里没有该参数时回落到 admin', () {
      expect(
        WorkBuddy.panelPassword(def(['--port', '8788', '--accounts-dir', 'D'])),
        'admin',
      );
    });

    test('参数为空时回落到 admin', () => expect(WorkBuddy.panelPassword(def([])), 'admin'));
  });

  group('WorkBuddy.accountSummary', () {
    test('从未探到账号池信息时提示未知', () =>
        expect(WorkBuddy.accountSummary(null, null), '账号池状态未知'));

    test('没有任何账号时给出可行动的提示', () =>
        expect(WorkBuddy.accountSummary(0, 0), '未添加账号'));

    test('有账号但未就绪时给出就绪比例', () =>
        expect(WorkBuddy.accountSummary(3, 1), '账号 1/3 可用'));

    test('全部就绪时给出就绪比例', () =>
        expect(WorkBuddy.accountSummary(5, 5), '账号 5/5 可用'));

    test('就绪数缺失时按 0 显示', () =>
        expect(WorkBuddy.accountSummary(2, null), '账号 0/2 可用'));
  });

  group('WorkBuddy.isWorkBuddy', () {
    UpstreamDef def(String id) =>
        UpstreamDef(id: id, type: 'managed', label: 'x', baseUrl: 'http://x/v1');

    test('按 id 识别', () =>
        expect(WorkBuddy.isWorkBuddy(def(WorkBuddy.id)), isTrue));

    test('其他 id 不匹配', () =>
        expect(WorkBuddy.isWorkBuddy(def('other')), isFalse));
  });

  group('UpstreamDef.healthUrl 持久化', () {
    test('带 healthUrl 的序列化往返', () {
      final d = UpstreamDef(
        id: WorkBuddy.id,
        type: 'managed',
        label: 'wb',
        baseUrl: 'http://127.0.0.1:8788/v1',
        command: r'python\pythonw.exe',
        healthUrl: 'http://127.0.0.1:8788/health',
      );
      final back = UpstreamDef.fromJson(d.toJson());
      expect(back.healthUrl, 'http://127.0.0.1:8788/health');
      expect(back.baseUrl, d.baseUrl);
    });

    test('省略 healthUrl 的往返为空串', () {
      final d = UpstreamDef(
          id: 'remote1',
          type: 'remote',
          label: 'r',
          baseUrl: 'http://1.2.3.4/v1');
      final back = UpstreamDef.fromJson(d.toJson());
      expect(back.healthUrl, isEmpty);
    });

    test('缺省 healthUrl 字段也能解析', () {
      final back = UpstreamDef.fromJson(const {
        'id': 'remote2',
        'type': 'remote',
        'label': 'r',
        'baseUrl': 'http://1.2.3.4/v1',
      });
      expect(back.healthUrl, isEmpty);
    });
  });

  group('{{wbdir}} 占位符', () {
    late Directory sandbox;
    late Directory originalCwd;

    setUp(() {
      originalCwd = Directory.current;
      sandbox = Directory(
          '${Directory.systemTemp.path}/wb-loc-${DateTime.now().microsecondsSinceEpoch}');
      sandbox.createSync(recursive: true);
    });

    tearDown(() {
      Directory.current = originalCwd;
      sandbox.deleteSync(recursive: true);
    });

    UpstreamDef wbDef() => UpstreamDef(
        id: WorkBuddy.id,
        type: 'managed',
        label: 'wb',
        baseUrl: 'http://127.0.0.1:8788/v1',
        command: '{{wbdir}}/python/pythonw.exe');

    test('vendor 就位时解析出真实路径', () {
      Directory.current = sandbox;
      File('vendor/workbuddy2api-hub/wb_proxy.py').createSync(recursive: true);
      File('vendor/workbuddy2api-hub/python/pythonw.exe')
          .createSync(recursive: true);

      final vendor = GatewayConfig.findWorkBuddyVendor();
      expect(vendor, isNotNull);
      expect(File('${vendor!.path}/python/pythonw.exe').existsSync(), isTrue);

      final def = wbDef();
      GatewayConfig.resolvePlaceholders(def);
      expect(def.command, '${vendor.path}/python/pythonw.exe');
    });

    test('缺少校验文件时占位符原样保留', () {
      // 目录在但结构不完整（例如 vendor_workbuddy.ps1 还没跑完校验）
      Directory.current = sandbox;
      Directory('vendor/workbuddy2api-hub').createSync(recursive: true);

      expect(GatewayConfig.findWorkBuddyVendor(), isNull);
      final def = wbDef();
      GatewayConfig.resolvePlaceholders(def);
      expect(def.command, '{{wbdir}}/python/pythonw.exe');
    });
  });
}
