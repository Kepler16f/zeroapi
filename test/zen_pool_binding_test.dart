// zen 池绑定孤儿回归（2026-11-07）：
// 用户「删了重新导入」后 zen 只有一个出口能用——真因是删分组时
// removeGroup 把指向它的用途绑定（upstream:zen）一起清掉了，重新导入不会
// 恢复：没有绑定 = 三级轮换（Worker→机场→直连）整个被绕过，zen 静默直连
// 家宽，行为与「池里没别的节点」完全一样。
//
// 补测（2026-11-07 晚）：第一版自动重绑（commit 6a751e6）**从未生效**——
// 它在 bootstrap 早期调用，却用「zen 运行时实例存在吗」做守卫，那时运行时
// 还没创建 → 永远 rt == null → 直接 return。实测装机态池里 89 个节点躺着、
// assignments 里没有 upstream:zen。因此这次修复：
//   1) 判定改用 config（zen 供应商在不在、启没启用），不依赖运行时；
//   2) 判定「绑定是否失效」用 groupFor（指向已删分组同样算失效）；
//   3) 用户显式关掉「zen 走池」时不自动绑回（尊重显式选择）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/proxypool.dart';
import 'package:zeroapi/gateway/service.dart';

void main() {
  group('池层语义', () {
    test('删分组会清掉 zen 的用途绑定（问题根源）', () {
      final pool = ProxyPool();
      pool.importFromText(
        'http://10.0.0.1:3128#A\nhttp://10.0.0.2:3128#B\n',
        groupName: '飞鸟云',
      );
      pool.assign(ProxyPool.pUpstream('zen'), '飞鸟云');
      expect(pool.groupFor(ProxyPool.pUpstream('zen')), '飞鸟云');

      pool.removeGroup('飞鸟云');
      expect(
        pool.groupFor(ProxyPool.pUpstream('zen')),
        isNull,
        reason: '删分组会清掉指向它的绑定——重新导入不会恢复，这就是'
            '「删了重新导入也不行」的机制',
      );
    });

    test('重新导入同名分组后绑定仍是空的（需靠自动重绑兜住）', () {
      final pool = ProxyPool();
      pool.importFromText(
        'http://10.0.0.1:3128#A\n',
        groupName: '飞鸟云',
      );
      pool.assign(ProxyPool.pUpstream('zen'), '飞鸟云');
      pool.removeGroup('飞鸟云');
      pool.importFromText(
        'http://10.0.0.1:3128#A\nhttp://10.0.0.2:3128#B\n',
        groupName: '飞鸟云',
      );
      expect(
        pool.groupFor(ProxyPool.pUpstream('zen')),
        isNull,
        reason: '导入不会恢复绑定（这是要修的行为）',
      );
    });
  });

  group('服务层自动重绑（不需要运行时实例）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('zeroapi_zen_bind');
    });

    tearDown(() async {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// 造一个池：一个订阅分组（带 sourceUrl）+ 若干节点。
    ProxyPool buildPool({int subGroups = 1}) {
      final pool = ProxyPool()..savePath = '${tmp.path}/proxies.json';
      for (var i = 0; i < subGroups; i++) {
        final name = '订阅$i';
        pool.importFromText(
          'http://10.0.0.$i:3128#A\nhttp://10.0.1.$i:3128#B\n',
          groupName: name,
        );
        pool.groups.firstWhere((g) => g.name == name).sourceUrl =
            'https://example.com/sub$i';
      }
      return pool;
    }

    GatewayService buildService({bool zenEnabled = true}) {
      final cfg = GatewayConfig(
        port: 0,
        keys: [GatewayKey('默认', 'sk-test')],
        upstreams: [
          UpstreamDef(
            id: 'zen',
            type: 'managed',
            label: 'Zen',
            baseUrl: 'http://127.0.0.1:4097',
            enabled: zenEnabled,
          ),
        ],
      );
      return GatewayService.listenerTest(cfg);
    }

    test('绑定缺失 → 自动绑到唯一的订阅分组', () {
      final pool = buildPool();
      final s = buildService();
      s.ensureZenPoolBinding(pool);
      expect(
        pool.groupFor(ProxyPool.pUpstream('zen')),
        '订阅0',
        reason: '没有绑定 = 三级轮换被整个绕过，必须自动补上',
      );
    });

    test('绑定指向已删除的分组（残留脏键）→ 同样自动重绑', () {
      final pool = buildPool();
      pool.assignments[ProxyPool.pUpstream('zen')] = '已被删掉的组';
      final s = buildService();
      s.ensureZenPoolBinding(pool);
      expect(pool.groupFor(ProxyPool.pUpstream('zen')), '订阅0');
    });

    test('绑定已有效 → 不动', () {
      final pool = buildPool();
      pool.assign(ProxyPool.pUpstream('zen'), '订阅0');
      final s = buildService();
      s.ensureZenPoolBinding(pool);
      expect(pool.groupFor(ProxyPool.pUpstream('zen')), '订阅0');
    });

    test('用户显式关掉「zen 走池」→ 不自动绑回', () {
      final pool = buildPool();
      pool.setEnabled(ProxyPool.pUpstream('zen'), false);
      final s = buildService();
      s.ensureZenPoolBinding(pool);
      expect(
        pool.groupFor(ProxyPool.pUpstream('zen')),
        isNull,
        reason: '显式关掉是用户的选择，不能被自动修复覆盖',
      );
    });

    test('多个订阅分组 → 不猜（保持未绑定，等用户手动选）', () {
      final pool = buildPool(subGroups: 2);
      final s = buildService();
      s.ensureZenPoolBinding(pool);
      expect(pool.groupFor(ProxyPool.pUpstream('zen')), isNull);
    });

    test('zen 供应商不存在或被禁用 → 不绑', () {
      final pool = buildPool();
      final s = buildService(zenEnabled: false);
      s.ensureZenPoolBinding(pool);
      expect(pool.groupFor(ProxyPool.pUpstream('zen')), isNull);
    });

    test('重绑会落盘（重启后依然有效）', () {
      final pool = buildPool();
      final s = buildService();
      s.ensureZenPoolBinding(pool);
      final f = File('${tmp.path}/proxies.json');
      expect(f.existsSync(), isTrue, reason: '必须落盘，否则重启又丢绑定');
      final reloaded = ProxyPool.load(path: '${tmp.path}/proxies.json');
      expect(reloaded.groupFor(ProxyPool.pUpstream('zen')), '订阅0');
    });
  });
}
