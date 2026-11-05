import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/proxypool.dart';

void main() {
  const purpose = 'upstream:zen';
  late ProxyPool pool;
  late Duration previousTimeout;
  final servers = <HttpServer>[];
  final release = Completer<void>();
  var calls = 0;

  Future<ProxyNode> node(
    String name, {
    Duration delay = Duration.zero,
    int status = 200,
    bool hangBody = false,
    Completer<void>? gate,
  }) async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    servers.add(server);
    server.listen((req) async {
      calls++;
      if (gate != null) await gate.future;
      await Future<void>.delayed(delay);
      try {
        req.response.statusCode = status;
        req.response.bufferOutput = false;
        req.response.write('ok');
        if (hangBody) {
          await req.response.flush();
          await release.future;
        }
        await req.response.close();
      } catch (_) {}
    });
    return ProxyNode(
      type: 'http',
      host: '127.0.0.1',
      port: server.port,
      name: name,
    );
  }

  setUp(() {
    calls = 0;
    pool = ProxyPool();
    previousTimeout = ProxyPool.targetProbeTimeout;
    ProxyPool.targetProbeTimeout = const Duration(milliseconds: 800);
    pool.setPurposeTarget(purpose, 'http://zen.example.test/');
    pool.assignments[purpose] = '飞鸟云';
  });
  tearDown(() async {
    for (final server in servers) {
      await server.close(force: true);
    }
    servers.clear();
    pool.dispose();
    ProxyPool.targetProbeTimeout = previousTimeout;
  });

  test('scan whole group before selection, exclude timeouts/403 and sort successes', () async {
    final bad = await node('403', status: 403);
    // 慢节点延迟 600ms：必须小于探针超时（800ms，否则会被剔除），但与
    // 快节点差距足够大——原来 250ms 在全量并发（CPU 被占）时快节点可能
    // 测出 >250ms，排序翻转 → 偶发失败。
    final slow = await node('slow', delay: const Duration(milliseconds: 600));
    final fast = await node('fast');
    final hung = await node('body hang', hangBody: true);
    final other = await node('Webshare');
    pool.groups.add(ProxyGroup(name: '飞鸟云', nodes: [bad, slow, fast, hung]));
    pool.groups.add(ProxyGroup(name: 'Webshare', nodes: [other]));
    pool.health[hung.id] = NodeHealth()..latencyMs = 1;
    final watch = Stopwatch()..start();
    final measured = await pool.measuredCandidatesFor(purpose);
    // 断言用「慢节点被探到」为准：探测是分批并发的，慢节点那批的实际耗时
    // 从它开始被探算起，比整轮墙钟更贴近被测行为（墙钟会随并发负载漂移）。
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(700));
    expect(measured.map((c) => c.nodeId), [fast.id, slow.id]);
    expect(
      calls,
      4,
      reason: 'all bound nodes tested; no unrelated group traffic',
    );
    expect(pool.targetUsable(hung.id, purpose), isFalse);
    expect(pool.targetUsable(bad.id, purpose), isFalse);
    expect(await pool.measuredCandidatesFor(purpose), hasLength(2));
    expect(calls, 4, reason: 'fresh snapshot reused');
  });

  test('concurrent callers await same full scan', () async {
    final gate = Completer<void>();
    final good = await node('good', gate: gate);
    pool.groups.add(ProxyGroup(name: '飞鸟云', nodes: [good]));
    var complete = 0;
    final a = pool.measuredCandidatesFor(purpose).then((v) {
      complete++;
      return v;
    });
    final b = pool.measuredCandidatesFor(purpose).then((v) {
      complete++;
      return v;
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(complete, 0);
    expect(calls, 1);
    gate.complete();
    final results = await Future.wait([a, b]);
    expect(results.every((r) => r.single.nodeId == good.id), isTrue);
    expect(calls, 1);
  });

  test(
    'all failed returns empty despite old good latency; never selects direct',
    () async {
      final bad = await node('down', status: 502);
      pool.groups.add(ProxyGroup(name: '飞鸟云', nodes: [bad]));
      pool.health[bad.id] = NodeHealth()..latencyMs = 1;
      expect(await pool.measuredCandidatesFor(purpose), isEmpty);
      expect(poolCandidatesFor(pool, purpose), isEmpty);
    },
  );

  test('quota and request failures excluded from measured snapshot', () async {
    final a = await node('a');
    final b = await node('b');
    final c = await node('c');
    pool.groups.add(ProxyGroup(name: '飞鸟云', nodes: [a, b, c]));
    expect(await pool.measuredCandidatesFor(purpose), hasLength(3));
    pool.markQuotaSpent(a.id);
    pool.markTargetFailed(b.id, purpose);
    expect((await pool.measuredCandidatesFor(purpose)).single.nodeId, c.id);
    expect(calls, 3);
  });

  test('CLI 验证过额度可用的出口排到最前（探针只能证明能出网）', () async {
    final a = await node('a');
    final b = await node('b');
    pool.groups.add(ProxyGroup(name: '飞鸟云', nodes: [a, b]));
    expect(await pool.measuredCandidatesFor(purpose), hasLength(2));
    // 只有真 opencode CLI 身份跑通才知道这个 IP 上有额度
    pool.markQuotaOk(b.id);
    expect(pool.isQuotaOk(b.id), isTrue);
    expect(pool.isQuotaOk(a.id), isFalse);
    final after = await pool.measuredCandidatesFor(purpose);
    expect(after.first.nodeId, b.id);
    expect(after.map((c) => c.nodeId), containsAll([a.id, b.id]));
  });

  test('额度冷却：到期前不进候选，到期自动恢复（不必整日拉黑）', () async {
    final a = await node('a');
    pool.groups.add(ProxyGroup(name: '飞鸟云', nodes: [a]));
    expect(await pool.measuredCandidatesFor(purpose), hasLength(1));
    // v2 上游给了确切恢复时刻（retryAfterMs ≈ 几小时后额度自动回来）
    pool.markQuotaCooldown(a.id, DateTime.now().add(const Duration(seconds: 2)));
    expect(pool.inQuotaCooldown(a.id), isTrue);
    expect(await pool.measuredCandidatesFor(purpose), isEmpty,
        reason: '冷却期内该出口不该再被选中');
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(pool.inQuotaCooldown(a.id), isFalse);
    expect(await pool.measuredCandidatesFor(purpose), hasLength(1),
        reason: '到点后自动恢复候选');
  });

  test('冷却取更晚的时刻；重复冷却不会把时间提前', () async {
    final a = await node('a');
    pool.groups.add(ProxyGroup(name: '飞鸟云', nodes: [a]));
    final later = DateTime.now().add(const Duration(minutes: 30));
    final sooner = DateTime.now().add(const Duration(minutes: 5));
    pool.markQuotaCooldown(a.id, later);
    pool.markQuotaCooldown(a.id, sooner);
    expect(pool.health[a.id]?.quotaUntil, later);
  });

  test('额度烧穿的节点会作废之前的「可用」标记', () async {
    final a = await node('a');
    pool.groups.add(ProxyGroup(name: '飞鸟云', nodes: [a]));
    pool.markQuotaOk(a.id);
    expect(pool.isQuotaOk(a.id), isTrue);
    pool.markQuotaSpent(a.id);
    expect(pool.isQuotaSpent(a.id), isTrue);
    expect(pool.isQuotaOk(a.id), isFalse);
    expect(await pool.measuredCandidatesFor(purpose), isEmpty);
  });

  test('CLI 验证可用可解除同一天的烧穿标记', () async {
    final a = await node('a');
    pool.groups.add(ProxyGroup(name: '飞鸟云', nodes: [a]));
    pool.markQuotaSpent(a.id);
    expect(await pool.measuredCandidatesFor(purpose), isEmpty);
    pool.markQuotaOk(a.id);
    expect(pool.isQuotaOk(a.id), isTrue);
    expect(pool.isQuotaSpent(a.id), isFalse);
    expect((await pool.measuredCandidatesFor(purpose)).single.nodeId, a.id);
  });

  test('node additions invalidate scan; failed node recovers on forced measurement', () async {
    final good = await node('good');
    final next = await node('next');
    final group = ProxyGroup(name: '飞鸟云', nodes: [good]);
    pool.groups.add(group);
    expect(await pool.measuredCandidatesFor(purpose), hasLength(1));
    group.nodes.add(next);
    expect(await pool.measuredCandidatesFor(purpose), hasLength(2));
    expect(calls, 3);
    pool.markTargetFailed(good.id, purpose);
    expect(await pool.measuredCandidatesFor(purpose), hasLength(1));
    expect(
      await pool.measuredCandidatesFor(purpose, force: true),
      hasLength(2),
    );
    expect(calls, 5);
  });

  test(
    'binding changed during scan cannot publish old group candidates',
    () async {
      final gate = Completer<void>();
      final old = await node('old', gate: gate);
      final current = await node('new');
      pool.groups.add(ProxyGroup(name: '飞鸟云', nodes: [old]));
      pool.groups.add(ProxyGroup(name: 'new', nodes: [current]));
      final running = pool.measuredCandidatesFor(purpose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      pool.assignments[purpose] = 'new';
      gate.complete();
      expect((await running).single.nodeId, current.id);
      expect(calls, 2);
    },
  );
}
