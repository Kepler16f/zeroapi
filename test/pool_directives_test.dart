// 内置代理池接入网关出口链路的测试：
//  1) poolDirectivesFor —— 用途 → 分组 → 全量可拨指令（round-robin 保序、
//     latency 升序、冷却跳过、socks5 未预热跳过 / 预热后出现）
//  2) UpstreamDef.directives —— activePool 绑定节点排在手写地址之前、去重、
//     activePool=null 时行为与接入前一致
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/proxypool.dart';
import 'package:zeroapi/gateway/socksrelay.dart';

void main() {
  final purpose = ProxyPool.pUpstream('zen');

  ProxyPool buildPool() {
    final pool = ProxyPool();
    pool.importFromText('''
http://10.0.0.1:3128#A
socks5://u:p@1.2.3.4:1080#S
http://10.0.0.2:3128#B
''');
    pool.assign(purpose, '导入');
    return pool;
  }

  group('poolDirectivesFor', () {
    test('round-robin：按组内顺序全量返回；未预热 socks5 跳过，预热后出现', () async {
      final pool = buildPool();
      // 未设 relayHub：socks5 不可拨，只剩两个 http，且保持组内顺序
      expect(poolDirectivesFor(pool, purpose), [
        'PROXY 10.0.0.1:3128',
        'PROXY 10.0.0.2:3128',
      ]);

      final hub = SocksRelayHub();
      pool.relayHub = hub;
      await pool.prepareRelays();
      final warmed = poolDirectivesFor(pool, purpose);
      expect(warmed.length, 3, reason: '预热后 socks5 经本地中转参与轮换');
      expect(warmed.first, 'PROXY 10.0.0.1:3128', reason: '组内顺序保持');
      expect(warmed.last, 'PROXY 10.0.0.2:3128');
      expect(warmed[1], hub.directiveFor('socks5://u:p@1.2.3.4:1080'));
      expect(
        warmed[1],
        startsWith('PROXY 127.0.0.1:'),
        reason: '绝不能产出 SOCKS5 前缀',
      );
      await hub.stopAll();
    });

    test('未绑定 / 关闭 / null 池 → 空列表', () {
      final pool = buildPool();
      expect(poolDirectivesFor(pool, ProxyPool.pThirdParty), isEmpty);
      pool.setEnabled(purpose, false);
      expect(poolDirectivesFor(pool, purpose), isEmpty);
      expect(poolDirectivesFor(null, purpose), isEmpty);
      // 重新打开后恢复
      pool.setEnabled(purpose, true);
      expect(poolDirectivesFor(pool, purpose), isNotEmpty);
    });

    test('冷却节点被跳过', () {
      final pool = buildPool();
      // report 三次失败 → 进冷却（lastChecked=now）
      final b = pool.allNodes.last.id;
      pool.report(b, false);
      pool.report(b, false);
      pool.report(b, false);
      expect(poolDirectivesFor(pool, purpose), [
        'PROXY 10.0.0.1:3128',
      ], reason: 'B 冷却中，只剩 A');
    });

    test('latency 组按延迟升序返回', () {
      final pool = buildPool();
      pool.setStrategy('导入', 'latency');
      final a = pool.allNodes.first.id; // A: 10.0.0.1
      final b = pool.allNodes.last.id; // B: 10.0.0.2
      pool.report(b, true, latencyMs: 111);
      pool.report(a, true, latencyMs: 22);
      // B 未测的 socks5 排最后；A(22) < B(111) < 未探到延迟的 socks5
      expect(poolDirectivesFor(pool, purpose), [
        'PROXY 10.0.0.1:3128',
        'PROXY 10.0.0.2:3128',
      ]);
    });
  });

  group('UpstreamDef.directives 合并 activePool', () {
    tearDown(() {
      activePool = null;
    });

    test('池绑定节点排在手写地址之前；与手写地址重复时去重', () async {
      final pool = buildPool();
      activePool = pool;
      final hub = SocksRelayHub();
      final def = UpstreamDef(
        id: 'zen',
        baseUrl: 'https://x/v1',
        proxy: 'http://10.0.0.1:3128, http://127.0.0.1:7890',
        proxyEnabled: true,
      );
      final d = await def.directives(hub);
      expect(d, [
        'PROXY 10.0.0.1:3128',
        'PROXY 10.0.0.2:3128',
        'PROXY 127.0.0.1:7890',
      ], reason: '池候选在前且按首次出现去重；手写 7890 保留在后');
      await hub.stopAll();
    });

    test('未绑定用途 / activePool=null 时与接入前行为一致', () async {
      final hub = SocksRelayHub();
      final def = UpstreamDef(
        id: 'zen',
        baseUrl: 'https://x/v1',
        proxy: 'http://a:1, socks5://b:2',
        proxyEnabled: true,
      );
      // 池存在但没绑定这个用途
      activePool = buildPool()..assignments.remove(purpose);
      var d = await def.directives(hub);
      expect(d.first, 'PROXY a:1');
      expect(d.length, 2);
      // activePool=null：与老行为完全一致
      activePool = null;
      d = await def.directives(hub);
      expect(d.first, 'PROXY a:1');
      expect(d[1], startsWith('PROXY 127.0.0.1:'));
      await hub.stopAll();
    });

    test('开关关闭（proxyEnabled=false）仍可仅靠池绑定出网', () async {
      final pool = buildPool();
      activePool = pool;
      final hub = SocksRelayHub();
      final def = UpstreamDef(
        id: 'zen',
        baseUrl: 'https://x/v1',
        proxyEnabled: false,
      );
      final d = await def.directives(hub);
      expect(d, [
        'PROXY 10.0.0.1:3128',
        'PROXY 10.0.0.2:3128',
      ], reason: '手写池关闭但用途绑定了分组时，分组节点即全部出口');
      await hub.stopAll();
    });

    test('egress() 候选带 nodeId（连接失败上报健康度的依据）', () async {
      final pool = buildPool();
      activePool = pool;
      final hub = SocksRelayHub();
      final def = UpstreamDef(id: 'zen', baseUrl: 'https://x/v1');
      final cands = await def.egress(hub);
      expect(
        cands.map((c) => c.directive),
        await def.directives(hub),
        reason: '候选视图与指令视图一一对应',
      );
      expect(cands.length, 2, reason: '该用例手写地址为空，候选全部来自池节点');
      for (final c in cands) {
        expect(c.nodeId, isNotNull);
        final node = pool.allNodes.firstWhere((n) => n.id == c.nodeId);
        expect(c.directive, 'PROXY ${node.host}:${node.port}');
      }
      // 手写地址候选没有 nodeId
      final def2 = UpstreamDef(
        id: 'zen',
        baseUrl: 'https://x/v1',
        proxy: 'http://127.0.0.1:7890',
        proxyEnabled: true,
      );
      final cands2 = await def2.egress(hub);
      expect(cands2.last.nodeId, isNull, reason: '手写地址来源无节点可报');
      expect(cands2.last.directive, 'PROXY 127.0.0.1:7890');
      await hub.stopAll();
    });
  });
}
