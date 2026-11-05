// 本轮 UI 改动的控件级测试：
//  - 代理页：分组「出口」自动/手动切换 + 手动后出节点下拉；订阅对话框可设刷新间隔；
//  - 设置页：不再有「对供应商生效」的供应商下拉/出口方式选择；
//  - 模型页：单层展开（不再有供应商二级折叠），行内显示倍率。
//
// 代理页用 NoSaveService 拦住 saveProxies()：测试绝不能写用户真实的
// %APPDATA%\zeroapi\proxies.json。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/modelsdev.dart';
import 'package:zeroapi/gateway/proxypool.dart';
import 'package:zeroapi/gateway/service.dart';
import 'package:zeroapi/gateway/upstream.dart';
import 'package:zeroapi/pages.dart';

class NoSaveService extends GatewayService {
  @override
  void saveProxies() {}
}

ProxyPool poolWithGroup() {
  final pool = ProxyPool();
  pool.importFromText(
    'http://10.0.0.1:3128#节点一\nhttp://10.0.0.2:3128#节点二\n',
    groupName: '测试组',
  );
  pool.groups.single.sourceUrl = 'https://example.com/sub';
  return pool;
}

void main() {
  group('代理页', () {
    testWidgets('出口可以选择自动/手动，手动后出现节点下拉', (tester) async {
      final s = NoSaveService();
      final pool = poolWithGroup();
      s.proxies = pool;
      await tester.pumpWidget(MaterialApp(home: ProxyPoolPage(service: s)));
      await tester.pump();

      expect(find.text('自动选择'), findsOneWidget);
      expect(find.text('手动指定'), findsOneWidget);
      expect(pool.groups.single.pinnedNodeId, isNull);

      await tester.tap(find.text('手动指定'));
      await tester.pump();
      expect(
        pool.groups.single.pinnedNodeId,
        isNotNull,
        reason: '切到手动 = 钉住一个节点',
      );

      await tester.tap(find.text('自动选择'));
      await tester.pump();
      expect(pool.groups.single.pinnedNodeId, isNull);
    });

    testWidgets('订阅设置里有刷新间隔选项', (tester) async {
      final s = NoSaveService();
      final pool = poolWithGroup();
      s.proxies = pool;
      await tester.pumpWidget(MaterialApp(home: ProxyPoolPage(service: s)));
      await tester.pump();

      await tester.tap(find.textContaining('订阅：https://example.com/sub'));
      await tester.pump();
      expect(find.text('刷新间隔：'), findsOneWidget);
      expect(find.text('自动刷新（每 6 小时）'), findsOneWidget);
    });
  });

  group('设置页', () {
    testWidgets('不再选择代理用于哪个供应商', (tester) async {
      final s = GatewayService();
      // 出口代理区块只在有供应商时渲染：塞一个远端供应商
      s.config.upstreams.add(
        UpstreamDef(
          id: 'zen',
          type: 'zen',
          label: 'Zen',
          baseUrl: 'https://example.com/inference/v1',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsPage(service: s)),
        ),
      );
      await tester.pumpAndSettle();
      // 出口代理在长列表下方：ListView 懒加载，先滚过去
      await tester.scrollUntilVisible(
        find.text('启用出口代理'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('启用出口代理'), findsOneWidget);
      expect(find.textContaining('代理地址'), findsOneWidget);
      expect(find.text('对供应商生效：'), findsNothing);
      expect(find.text('出口方式：'), findsNothing);
      expect(find.text('本应用内置代理池'), findsNothing);
    });
  });

  group('模型页', () {
    testWidgets('单层展开 + 行内倍率', (tester) async {
      final s = GatewayService();
      final def = UpstreamDef(
        id: 'workbuddy',
        type: 'managed',
        label: 'WorkBuddy',
        baseUrl: 'http://127.0.0.1:8788/v1',
      );
      final rt = UpstreamRuntime(def)
        ..health = UpstreamHealth.healthy
        ..models = const ['hy3', 'gpt-5.5'];
      rt.modelInfo['hy3'] = const ModelInfo(
        contextWindow: 200000,
        reasoning: true,
        creditMultiplier: 'x0.29',
      );
      rt.modelInfo['gpt-5.5'] = const ModelInfo(creditMultiplier: 'x3.50');
      rt.modelRealms['gpt-5.5'] = 'intl';
      s.registry.rebuild([rt]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ModelsPage(service: s)),
        ),
      );
      await tester.pumpAndSettle();

      // 供应商那一层折叠已消失
      final statusDots = tester.widgetList<Icon>(find.byIcon(Icons.circle));
      expect(statusDots.where((icon) => icon.color == Colors.green), isNotEmpty,
          reason: '已连接供应商的模型状态必须显示绿色');
      expect(find.text('id: workbuddy'), findsNothing);
      expect(find.textContaining('个来源'), findsNothing);
      expect(find.textContaining('个调用名'), findsWidgets);

      await tester.tap(find.textContaining('hy3').first);
      await tester.pumpAndSettle();
      expect(find.text('倍率 x0.29'), findsOneWidget);

      await tester.tap(find.textContaining('gpt-5.5').first);
      await tester.pumpAndSettle();
      expect(find.text('倍率 x3.50'), findsOneWidget);
    });

    testWidgets('展开模型详情后供应商刷新通知不会让展开态回弹（不闪烁）',
        (tester) async {
      final s = GatewayService();
      final def = UpstreamDef(
        id: 'workbuddy',
        type: 'managed',
        label: 'WorkBuddy',
        baseUrl: 'http://127.0.0.1:8788/v1',
      );
      final rt = UpstreamRuntime(def)
        ..health = UpstreamHealth.healthy
        ..models = const ['hy3'];
      rt.modelInfo['hy3'] = const ModelInfo(contextWindow: 200000);
      s.registry.rebuild([rt]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ModelsPage(service: s)),
        ),
      );
      await tester.pumpAndSettle();

      // 展开「hy3」详情
      await tester.tap(find.textContaining('hy3').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('来源：WorkBuddy'), findsOneWidget);

      // 模拟供应商探活完成后的通知：整页会重建
      s.notifyListeners();
      await tester.pumpAndSettle();

      // 重建后详情必须仍然是展开的（此前 ExpansionTile 被重新实例化，
      // 展开动画重放 → 视觉上就是「展开时闪烁」）
      expect(
        find.textContaining('来源：WorkBuddy'),
        findsOneWidget,
        reason: '父级重建后展开态必须保持，不能回弹',
      );
      // 再来一次通知，仍然稳定
      s.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.textContaining('来源：WorkBuddy'), findsOneWidget);
    });

    testWidgets('展开后上游报错信息出现不会让详情面板高度跳变（不抖动）',
        (tester) async {
      final s = GatewayService();
      final def = UpstreamDef(
        id: 'workbuddy',
        type: 'managed',
        label: 'WorkBuddy',
        baseUrl: 'http://127.0.0.1:8788/v1',
      );
      final rt = UpstreamRuntime(def)
        ..health = UpstreamHealth.healthy
        ..models = const ['hy3'];
      rt.modelInfo['hy3'] = const ModelInfo(contextWindow: 200000);
      s.registry.rebuild([rt]);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ModelsPage(service: s)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('hy3').first);
      await tester.pumpAndSettle();

      final detail = find.textContaining('来源：WorkBuddy');
      final h1 = tester.getSize(detail).height;

      // 上游开始报错：详情里会多一行「最近调用错误」。高度变了不算 bug
      // （信息量变了），但**必须一次性出现**——不能是每次重建都出现/消失，
      // 那正是肉眼看到的抖动。
      rt.modelCallErrors['hy3'] = 'boom';
      s.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.textContaining('最近调用错误'), findsOneWidget);

      s.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.textContaining('最近调用错误'), findsOneWidget,
          reason: '错误行必须稳定存在，不能在重建时闪烁');
      expect(tester.getSize(detail).height, greaterThanOrEqualTo(h1));
    });
  });
}
