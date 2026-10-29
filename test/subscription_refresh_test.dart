// 代理组订阅刷新与钉节点：
//  - replaceGroupFromText：整组替换、幸存节点保留实例（健康度延续）、
//    下线节点删除、钉住目标消失自动解钉；
//  - pinNode + pickDirective/poolCandidatesFor：钉住时只出该节点，冷却回退；
//  - failedRatio：大面积失败判定（自动刷新触发条件）；
//  - 序列化往返：sourceUrl/lastRefreshAt/autoRefresh/pinnedNodeId 持久化。
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/proxypool.dart';

void main() {
  const linksA = '''
http://10.0.0.1:3128#A
socks5://u:p@1.2.3.4:1080#S
http://10.0.0.2:3128#B
''';

  ProxyPool buildPool() {
    final pool = ProxyPool();
    pool.importFromText(linksA, groupName: '机场');
    return pool;
  }

  group('订阅刷新（整组替换）', () {
    test('幸存节点保留原实例与健康度；新增/移除计数正确', () {
      final pool = buildPool();
      final a = pool.allNodes.firstWhere((n) => n.name == 'A');
      pool.report(a.id, true, latencyMs: 42);
      pool.setGroupSource('机场', 'https://sub.example.com/x');

      // 新订阅：保留 A（同 host:port），B 下线，新增 C
      final (added, removed) = pool.replaceGroupFromText('机场', '''
http://10.0.0.1:3128#A
http://10.0.0.9:3128#C
''');
      expect(added, 1);
      expect(removed, 2, reason: 'S 与 B 被移除');
      final g = pool.groups.single;
      expect(g.nodes.map((n) => n.name), ['A', 'C']);
      final a2 = g.nodes.first;
      expect(identical(a2, a), isTrue, reason: '同 id 复用原实例');
      expect(pool.health[a.id]!.latencyMs, 42, reason: '健康度延续');
    });

    test('刷新后保留订阅来源与刷新时间，钉住节点消失时解钉', () {
      final pool = buildPool();
      pool.setGroupSource('机场', 'https://sub.example.com/x');
      final a = pool.allNodes.firstWhere((n) => n.name == 'A');
      expect(pool.pinNode('机场', a.id), isTrue);
      expect(pool.groups.single.pinnedNodeId, a.id);

      pool.replaceGroupFromText('机场', 'http://10.0.0.9:3128#C');
      final g = pool.groups.single;
      expect(g.sourceUrl, 'https://sub.example.com/x');
      expect(g.lastRefreshAt, isNotNull);
      expect(g.pinnedNodeId, isNull, reason: '被钉节点已下线 → 自动解钉');
    });

    test('组不存在返回 (-1,-1)；空文本清空组', () {
      final pool = buildPool();
      expect(pool.replaceGroupFromText('不存在', linksA), (-1, -1));
      final (added, removed) = pool.replaceGroupFromText('机场', '');
      expect(added, 0);
      expect(removed, 3);
      expect(pool.groups.single.nodes, isEmpty);
    });

    test('手动删除的节点不会被订阅刷新加回来；手动导入可恢复', () {
      final pool = buildPool();
      final b = pool.allNodes.firstWhere((n) => n.name == 'B');
      pool.removeNode('机场', b.id);
      expect(pool.groups.single.nodes.any((n) => n.id == b.id), isFalse);

      // 订阅里仍然有 B → 刷新时应跳过
      pool.replaceGroupFromText('机场', linksA);
      expect(
        pool.groups.single.nodes.any((n) => n.id == b.id),
        isFalse,
        reason: '删掉的节点不应被机场下次下发刷回来',
      );

      // 用户手动导入同一节点 = 明确要它，解除排除
      pool.importFromText('http://10.0.0.2:3128#B', groupName: '机场');
      expect(pool.groups.single.nodes.any((n) => n.id == b.id), isTrue);
    });
  });

  group('钉节点出口', () {
    test('pickDirective 只出钉住的节点；冷却中回退轮换', () {
      final pool = buildPool();
      final p = ProxyPool.pThirdParty;
      pool.assign(p, '机场');
      // 默认只有 http 可拨（socks5 未预热）：A、B 轮换
      final seen = {for (var i = 0; i < 4; i++) pool.pickDirective(p)};
      expect(seen.length, 2);

      final b = pool.allNodes.firstWhere((n) => n.name == 'B');
      expect(pool.pinNode('机场', b.id), isTrue);
      expect(pool.pickDirective(p), 'PROXY 10.0.0.2:3128');
      expect(pool.pickDirective(p), 'PROXY 10.0.0.2:3128', reason: '钉住后不再轮换');

      // 钉住节点 3 连败进冷却 → 回退到组内其他节点
      pool.report(b.id, false);
      pool.report(b.id, false);
      pool.report(b.id, false);
      expect(pool.pickDirective(p), 'PROXY 10.0.0.1:3128');
    });

    test('poolCandidatesFor 钉住时只返回该节点', () {
      final pool = buildPool();
      final p = ProxyPool.pThirdParty;
      pool.assign(p, '机场');
      final a = pool.allNodes.firstWhere((n) => n.name == 'A');
      pool.pinNode('机场', a.id);
      final cands = poolCandidatesFor(pool, p);
      expect(cands.length, 1);
      expect(cands.single.directive, 'PROXY 10.0.0.1:3128');
      expect(cands.single.nodeId, a.id);
    });

    test('钉不在组内的节点返回 false，不改变状态', () {
      final pool = buildPool();
      expect(pool.pinNode('机场', 'no-such-id'), isFalse);
      expect(pool.groups.single.pinnedNodeId, isNull);
      expect(pool.pinNode('不存在', 'x'), isFalse);
    });
  });

  group('大面积失败判定', () {
    test('failedRatio 按冷却阈值算比例', () {
      final pool = buildPool();
      final g = pool.groups.single;
      expect(g.failedRatio(pool), 0);
      // 3 个节点里 2 个三连败 → 2/3
      final a = pool.allNodes[0];
      final b = pool.allNodes[1];
      for (var i = 0; i < 3; i++) {
        pool.report(a.id, false);
        pool.report(b.id, false);
      }
      expect(g.failedRatio(pool), closeTo(2 / 3, 0.001));
    });
  });

  group('序列化', () {
    test('sourceUrl/lastRefreshAt/autoRefresh/pinnedNodeId 往返', () {
      final pool = buildPool();
      pool.setGroupSource('机场', 'https://sub.example.com/x');
      final a = pool.allNodes.firstWhere((n) => n.name == 'A');
      pool.pinNode('机场', a.id);
      pool.groups.single.autoRefresh = false;

      final restored = ProxyPool.fromJson(pool.toJson());
      final g = restored.groups.single;
      expect(g.sourceUrl, 'https://sub.example.com/x');
      expect(g.lastRefreshAt, isNotNull);
      expect(g.autoRefresh, isFalse);
      expect(g.pinnedNodeId, a.id);
    });

    test('refreshIntervalHours 与 excludedNodeIds 往返', () {
      final pool = buildPool();
      pool.setGroupRefreshInterval('机场', 2);
      final b = pool.allNodes.firstWhere((n) => n.name == 'B');
      pool.removeNode('机场', b.id);

      final restored = ProxyPool.fromJson(pool.toJson());
      final g = restored.groups.single;
      expect(g.refreshIntervalHours, 2);
      expect(g.excludedNodeIds, contains(b.id));
    });

    test('旧 JSON（无新字段）按默认值读：自动刷新开、无来源、无钉住', () {
      final pool = ProxyPool.fromJson({
        'nodes': [
          {
            'id': 'n1',
            'name': 'A',
            'type': 'http',
            'host': '10.0.0.1',
            'port': 3128,
          },
        ],
        'groups': [
          {
            'name': '旧组',
            'strategy': 'round-robin',
            'nodeIds': ['n1'],
          },
        ],
      });
      final g = pool.groups.single;
      expect(g.sourceUrl, isEmpty);
      expect(g.lastRefreshAt, isNull);
      expect(g.autoRefresh, isTrue);
      expect(g.pinnedNodeId, isNull);
      expect(g.refreshIntervalHours, 6);
      expect(g.excludedNodeIds, isEmpty);
    });
  });
}
