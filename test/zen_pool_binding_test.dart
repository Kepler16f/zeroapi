// zen 池绑定孤儿回归（2026-11-07）：
// 用户「删了重新导入」后 zen 只有一个出口能用——真因是删分组时
// removeGroup 把指向它的用途绑定（upstream:zen）一起清掉了，重新导入不会
// 恢复：没有绑定 = 三级轮换（Worker→机场→直连）整个被绕过，zen 静默直连
// 家宽，行为与「池里没别的节点」完全一样。
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/proxypool.dart';

void main() {
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
}
