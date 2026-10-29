import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/hostnet.dart';
import 'package:zeroapi/gateway/proxypool.dart';

void main() {
  test('IPv6-only 节点判定', () {
    expect(ProxyPool.isIpv6Only('2400:8902::2000:2bff:fe65:79d8'), true);
    expect(ProxyPool.isIpv6Only('[2400:1::1]'), true);
    expect(ProxyPool.isIpv6Only('sg01.example.com'), false);
    expect(ProxyPool.isIpv6Only('1.2.3.4'), false);
    expect(ProxyPool.isIpv6Only(''), false);
  });

  test('宿主网卡探测：能区分 TUN 与物理网卡', () {
    // 只验证接口可用且不抛异常；具体结果依赖运行环境
    expect(() => HostNetwork.hasTunnelAdapter(), returnsNormally);
    expect(() => HostNetwork.physicalInterface(), returnsNormally);
    expect(() => HostNetwork.hasIpv6Egress, returnsNormally);
  });
}
