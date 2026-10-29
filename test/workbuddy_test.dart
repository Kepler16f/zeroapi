import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/workbuddy.dart';

void main() {
  group('WorkBuddy.panelUrl', () {
    UpstreamDef def(String baseUrl, [String id = WorkBuddy.id]) =>
        UpstreamDef(id: id, type: 'managed', label: 'wb', baseUrl: baseUrl);

    test('去掉 /v1 后缀，得到面板根地址', () {
      expect(
        WorkBuddy.panelUrl(def('http://127.0.0.1:8788/v1')),
        'http://127.0.0.1:8788/',
      );
    });

    test('base url 已经不带路径时也补上斜杠', () {
      expect(
        WorkBuddy.panelUrl(def('http://127.0.0.1:8788')),
        'http://127.0.0.1:8788/',
      );
    });

    test('保留非 loopback 地址（局域网场景）', () {
      expect(
        WorkBuddy.panelUrl(def('http://192.168.1.10:8788/v1')),
        'http://192.168.1.10:8788/',
      );
    });

    test('已经是根路径时不重复斜杠', () {
      expect(
        WorkBuddy.panelUrl(def('http://127.0.0.1:8788/')),
        'http://127.0.0.1:8788/',
      );
    });

    test('带面板 token 时生成本机免密入口', () {
      expect(
        WorkBuddy.panelUrl(def('http://127.0.0.1:8788/v1'), token: 'abc123'),
        'http://127.0.0.1:8788/?panel_token=abc123',
      );
    });

    test('token 做 URL 编码', () {
      expect(
        WorkBuddy.panelUrl(def('http://127.0.0.1:8788/v1'), token: 'a b&c'),
        'http://127.0.0.1:8788/?panel_token=a+b%26c',
      );
    });
  });

  group('WorkBuddy.panelPassword', () {
    UpstreamDef def(List<String> args) => UpstreamDef(
      id: WorkBuddy.id,
      type: 'managed',
      label: 'wb',
      baseUrl: 'http://127.0.0.1:8788/v1',
      command: 'pythonw.exe',
      args: args,
    );

    test('从 --panel-password 参数取值', () {
      expect(
        WorkBuddy.panelPassword(
          def(['--panel-password', '3kQz9vNm7xPb2rLt', '--port', '8788']),
        ),
        '3kQz9vNm7xPb2rLt',
      );
    });

    test('参数在最后也能取到', () {
      expect(
        WorkBuddy.panelPassword(
          def(['--port', '8791', '--panel-password', '末位密码']),
        ),
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

    test(
      '参数为空时回落到 admin',
      () => expect(WorkBuddy.panelPassword(def([])), 'admin'),
    );
  });

  group('WorkBuddy 本地免密（buildDef）', () {
    test(
      '新定义不含 --api-key/--panel-password，apiKey 为空，label 为 WorkBuddy',
      () async {
        final def = await WorkBuddy.buildDef();
        if (def == null) return; // 源码树未 provision vendor 时跳过
        expect(def.args, isNot(contains('--api-key')));
        expect(def.args, isNot(contains('--panel-password')));
        expect(def.apiKey, isEmpty);
        expect(def.label, 'WorkBuddy');
        expect(def.catalogPaths, [
          '/models?realm=intl',
          '/models?realm=cn',
        ], reason: '双出口目录合并');
        // 面板密码回落默认 admin，「复制面板密码」与 hub 实际密码一致
        expect(WorkBuddy.panelPassword(def), 'admin');
      },
    );
  });

  group('GatewayConfig.migrateWorkBuddyLocal', () {
    UpstreamDef old() => UpstreamDef(
      id: WorkBuddy.id,
      type: 'managed',
      label: 'WorkBuddy 号池（腾讯 CodeBuddy）',
      baseUrl: 'http://127.0.0.1:8788/v1',
      apiKey: 'sk-zb-qfKKc2P8Qk83tNfmWCnlr7SYnXHTTqbxIEScvzmh',
      args: [
        'wb_proxy.py',
        '--api-key',
        'sk-zb-qfKKc2P8Qk83tNfmWCnlr7SYnXHTTqbxIEScvzmh',
        '--panel-password',
        'U1aP6XN2gSsrAZjx',
        '--accounts-dir',
        'X:\\accounts',
      ],
    );

    test('移除密钥参数、清空生成密钥、归一 label', () {
      final u = old();
      expect(
        GatewayConfig.migrateWorkBuddyLocal(u, accountsDirOverride: 'skip'),
        isTrue,
      );
      expect(u.args, isNot(contains('--api-key')));
      expect(u.args, isNot(contains('--panel-password')));
      expect(u.args, contains('--accounts-dir'), reason: '其余参数保留');
      expect(u.apiKey, isEmpty);
      expect(u.label, 'WorkBuddy');
    });

    test('用户手填的非 sk-zb- 密钥保留', () {
      final u = old()..apiKey = 'sk-custom-key';
      GatewayConfig.migrateWorkBuddyLocal(u, accountsDirOverride: 'skip');
      expect(u.apiKey, 'sk-custom-key');
    });

    test('迁移是幂等的：第二次调用返回 false', () {
      final u = UpstreamDef(
        id: WorkBuddy.id,
        type: 'managed',
        label: 'WorkBuddy',
        baseUrl: 'http://127.0.0.1:8788/v1',
        args: old().args,
        apiKey: 'sk-zb-abc',
        catalogPaths: const ['/models?realm=intl', '/models?realm=cn'],
      );
      // 第一次会做免密/路径归一（测试环境能找到仓库 vendor），第二次必须无变化
      GatewayConfig.migrateWorkBuddyLocal(u, accountsDirOverride: 'skip');
      expect(
        GatewayConfig.migrateWorkBuddyLocal(u, accountsDirOverride: 'skip'),
        isFalse,
      );
      expect(u.label, 'WorkBuddy');
      expect(u.apiKey, isEmpty);
      expect(u.args, isNot(contains('--api-key')));
    });

    test('存量升级到双出口目录探测', () {
      final u = old();
      expect(u.catalogPaths, ['/models']); // 默认单探
      GatewayConfig.migrateWorkBuddyLocal(u, accountsDirOverride: 'skip');
      expect(u.catalogPaths, ['/models?realm=intl', '/models?realm=cn']);
    });

    test('catalogPaths 为空（旧配置省略字段）也升级到双出口', () {
      final u = old()..catalogPaths = const [];
      GatewayConfig.migrateWorkBuddyLocal(u, accountsDirOverride: 'skip');
      expect(u.catalogPaths, ['/models?realm=intl', '/models?realm=cn']);
    });

    test('用户自定义过的 catalogPaths 不动', () {
      final u = old()..catalogPaths = const ['/models?realm=cn'];
      GatewayConfig.migrateWorkBuddyLocal(u, accountsDirOverride: 'skip');
      expect(u.catalogPaths, const ['/models?realm=cn']);
    });

    test('非 workbuddy 供应商不动', () {
      final u = UpstreamDef(
        id: 'other',
        type: 'managed',
        label: 'x',
        baseUrl: 'http://x',
      );
      expect(
        GatewayConfig.migrateWorkBuddyLocal(u, accountsDirOverride: 'skip'),
        isFalse,
      );
    });

    test('面板密码哈希被清掉，回到默认 admin', () {
      final dir = Directory.systemTemp.createTempSync('wbmig');
      addTearDown(() => dir.deleteSync(recursive: true));
      final settings = File('${dir.path}/settings.json')
        ..writeAsStringSync(
          '{'
          '"panel_password_hash": "abcd",'
          '"panel_password_salt": "ef01",'
          '"panel_password_rounds": 120000,'
          '"theme": "dark"}',
        );
      GatewayConfig.migrateWorkBuddyLocal(old(), accountsDirOverride: dir.path);
      final back =
          jsonDecode(settings.readAsStringSync()) as Map<String, dynamic>;
      expect(back.containsKey('panel_password_hash'), isFalse);
      expect(back.containsKey('panel_password_salt'), isFalse);
      expect(back['theme'], 'dark', reason: '无关键保持');
    });
  });

  group('WorkBuddy.accountSummary', () {
    test(
      '从未探到账号池信息时提示未知',
      () => expect(WorkBuddy.accountSummary(null, null), '账号池状态未知'),
    );

    test(
      '没有任何账号时给出可行动的提示',
      () => expect(WorkBuddy.accountSummary(0, 0), '未添加账号'),
    );

    test(
      '有账号但未就绪时给出就绪比例',
      () => expect(WorkBuddy.accountSummary(3, 1), '账号 1/3 可用'),
    );

    test(
      '全部就绪时给出就绪比例',
      () => expect(WorkBuddy.accountSummary(5, 5), '账号 5/5 可用'),
    );

    test(
      '就绪数缺失时按 0 显示',
      () => expect(WorkBuddy.accountSummary(2, null), '账号 0/2 可用'),
    );
  });

  group('WorkBuddy.isWorkBuddy', () {
    UpstreamDef def(String id) => UpstreamDef(
      id: id,
      type: 'managed',
      label: 'x',
      baseUrl: 'http://x/v1',
    );

    test(
      '按 id 识别',
      () => expect(WorkBuddy.isWorkBuddy(def(WorkBuddy.id)), isTrue),
    );

    test(
      '其他 id 不匹配',
      () => expect(WorkBuddy.isWorkBuddy(def('other')), isFalse),
    );
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
        baseUrl: 'http://1.2.3.4/v1',
      );
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
        '${Directory.systemTemp.path}/wb-loc-${DateTime.now().microsecondsSinceEpoch}',
      );
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
      command: '{{wbdir}}/python/pythonw.exe',
    );

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
