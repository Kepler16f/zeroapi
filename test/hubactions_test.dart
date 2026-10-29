import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/hubactions.dart';

/// HubActions.summarizeCheckin（一键签到结果汇总）的纯函数单元测试。
/// 不起网络、不读文件：直接喂 hub `/accounts/checkin` 的响应结构。
void main() {
  group('summarizeCheckin', () {
    test('2 成功 1 失败：报数并带上失败账号与原因', () {
      final text = HubActions.summarizeCheckin({
        'results': [
          {
            'uid': '1000000001',
            'nickname': '账号A',
            'ok': true,
            'msg': '签到成功，获得 10 积分',
          },
          {'uid': '1000000002', 'nickname': '账号B', 'ok': true, 'msg': '今天已签到'},
          {
            'uid': '1000000003',
            'nickname': '账号C',
            'ok': false,
            'error': '已达上限',
          },
        ],
        'accounts': [],
      });
      expect(text, contains('成功 2'));
      expect(text, contains('失败 1'));
      expect(text, contains('账号C'));
      expect(text, contains('已达上限'));
    });

    test('全成功：只出现成功数，不出现「失败」', () {
      final text = HubActions.summarizeCheckin({
        'results': [
          {'uid': '1', 'nickname': '甲', 'ok': true, 'msg': 'ok'},
          {'uid': '2', 'nickname': '乙', 'ok': true, 'msg': 'ok'},
          {'uid': '3', 'nickname': '丙', 'ok': true, 'msg': 'ok'},
        ],
      });
      expect(text, contains('成功 3'));
      expect(text, isNot(contains('失败')));
    });

    test('results 为空列表：没有可签到的账号', () {
      expect(
        HubActions.summarizeCheckin({'results': [], 'accounts': []}),
        '没有可签到的账号',
      );
    });

    test('结构异常不抛异常：缺 results / 非列表 / 条目缺字段都有兜底文案', () {
      expect(HubActions.summarizeCheckin({}), '没有可签到的账号');
      expect(HubActions.summarizeCheckin({'results': 'oops'}), '没有可签到的账号');
      // 有条目但 nickname/uid/error/msg 全缺：仍报数，名字与原因用兜底值
      final text = HubActions.summarizeCheckin({
        'results': [
          {'ok': false},
        ],
      });
      expect(text, contains('成功 0'));
      expect(text, contains('失败 1'));
      expect(text, contains('未知账号'));
      expect(text, contains('未知原因'));
    });

    test('失败条目缺 error 时回落 msg；缺 nickname 时回落 uid 前 8 位', () {
      final text = HubActions.summarizeCheckin({
        'results': [
          {'uid': '1234567890', 'ok': false, 'msg': '网络超时'},
        ],
      });
      expect(text, contains('12345678')); // uid 前 8 位
      expect(text, contains('网络超时'));
    });
  });

  group('checkinAll 入参校验（不触网）', () {
    test('空地址直接抛 FormatException，不会走到网络层', () async {
      await expectLater(
        HubActions.checkinAll('  '),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
