// 设置页「出口方式」的服务层行为：
//  - 「本应用内置代理池」= 启用 `upstream:<id>` 用途（分组绑定归「代理」页，
//    设置页不选分组）；未绑定分组时开了也不产生池出口。
//  - 「手写地址」= 停用该用途，出口回落到 proxy 字段/直连。
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/proxypool.dart';
import 'package:zeroapi/gateway/service.dart';

void main() {
  final purpose = ProxyPool.pUpstream('zen');

  ProxyPool buildPool({bool bind = true}) {
    final pool = ProxyPool();
    pool.importFromText(
      'http://10.0.0.1:3128#A\nhttp://10.0.0.2:3128#B\n',
      groupName: '导入',
    );
    if (bind) pool.assign(purpose, '导入');
    return pool;
  }

  test('已绑定分组：默认走池；切「手写地址」停用用途，池出口消失', () {
    final s = GatewayService();
    final pool = buildPool();
    s.proxies = pool;

    expect(s.upstreamUsesPool('zen'), isTrue);
    expect(poolDirectivesFor(pool, purpose), [
      'PROXY 10.0.0.1:3128',
      'PROXY 10.0.0.2:3128',
    ]);

    s.setUpstreamPoolEgress('zen', usePool: false);
    expect(s.upstreamUsesPool('zen'), isFalse);
    expect(
      poolDirectivesFor(pool, purpose),
      isEmpty,
      reason: '停用后池不参与出口，回落手写地址/直连',
    );
    // 绑定关系保留：重新开启立即恢复
    expect(pool.groupFor(purpose), '导入');
    s.setUpstreamPoolEgress('zen', usePool: true);
    expect(s.upstreamUsesPool('zen'), isTrue);
  });

  test('未绑定分组：开了开关也不算走池，且不出池出口', () {
    final s = GatewayService();
    final pool = buildPool(bind: false);
    s.proxies = pool;

    expect(s.upstreamPoolGroup('zen'), isNull);
    s.setUpstreamPoolEgress('zen', usePool: true);
    expect(s.upstreamUsesPool('zen'), isFalse, reason: '开关开了但没有绑定分组，池出口不存在');
    expect(poolDirectivesFor(pool, purpose), isEmpty);
    expect(s.upstreamPoolGroup('zen'), isNull);
  });

  test('无池 / service 未加载池时不崩溃、恒为 false', () {
    final s = GatewayService();
    s.proxies = null;
    expect(s.upstreamUsesPool('zen'), isFalse);
    s.setUpstreamPoolEgress('zen', usePool: true);
    expect(s.upstreamUsesPool('zen'), isFalse);

    s.proxies = ProxyPool();
    expect(s.upstreamUsesPool('zen'), isFalse);
  });
}
