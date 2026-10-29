// 代理池自动可达巡检（B1）：坏节点不用手动逐个刷新——
//  巡检拨通 204 即清零 failCount、解除冷却；巡检失败只记时间戳，不累加
//  失败数（瞬时抖动不该把正在服务的节点踢出轮换）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/proxypool.dart';

void main() {
  late Directory tmp;
  late HttpServer alive;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('zeroapi_autoprobe_');
  });
  setUp(() async {
    ProxyPool.probeTarget = 'http://probe.invalid/generate_204';
    // 「活节点」：绑一个总回 204 的本地假上游（findProxy 转发绝对 URI 到它）
    alive = await HttpServer.bind('127.0.0.1', 0);
    alive.listen((req) async {
      req.response.statusCode = 204;
      await req.drain();
      await req.response.close();
    });
  });
  tearDown(() async {
    await alive.close(force: true);
    ProxyPool.probeTarget = 'http://cp.cloudflare.com/generate_204';
  });
  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ProxyPool poolWith(String id, int port) {
    final pool = ProxyPool();
    pool.savePath = '${tmp.path}/$id.json';
    pool.groups.add(
      ProxyGroup(
        name: 'g',
        nodes: [ProxyNode(type: 'http', host: '127.0.0.1', port: port, id: id)],
      ),
    );
    pool.assignments[ProxyPool.pUpstream('zen')] = 'g';
    return pool;
  }

  test('巡检成功：清零失败计数、解禁冷却、记录延迟', () async {
    final pool = poolWith('a', alive.port);
    for (var i = 0; i < 3; i++) {
      pool.noteEgress('a', false); // 预置「已坏」：3 连败进冷却
    }
    expect(poolCandidatesFor(pool, ProxyPool.pUpstream('zen')), isEmpty);

    await pool.autoProbeOnce();

    final h = pool.health['a']!;
    expect(h.failCount, 0, reason: '巡检拨通应清零失败计数（自动解禁）');
    expect(h.latencyMs, greaterThanOrEqualTo(0));
    expect(
      poolCandidatesFor(pool, ProxyPool.pUpstream('zen')),
      isNotEmpty,
      reason: '巡检成功后节点自动回归轮换（无需手动刷新）',
    );
  });

  test('巡检失败：只记时间戳，不累加失败数（服务中节点不被误踢）', () async {
    final dead = await HttpServer.bind('127.0.0.1', 0);
    final deadPort = dead.port;
    await dead.close(force: true); // 端口随即不可拨
    final pool = poolWith('d', deadPort);
    pool.noteEgress('d', false); // 已有 1 次真实失败
    await pool.autoProbeOnce();
    final h = pool.health['d']!;
    expect(h.failCount, 1, reason: '巡检失败不该累加 failCount');
    expect(h.lastChecked, isNotNull);
  });

  test('重入保护：巡检进行中再调直接返回', () async {
    final pool = poolWith('e', alive.port);
    final f1 = pool.autoProbeOnce();
    final f2 = pool.autoProbeOnce(); // 重入应立即完成
    await f1;
    await f2;
    expect(pool.health['e']!.failCount, 0);
  });
}
