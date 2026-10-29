// account_page.dart 里暴露出来的纯函数测试：不碰 GatewayService、不起 widget。
import 'package:zeroapi/account_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('wbRealmLabel', () {
    test('cn / intl 映射到国内国际', () {
      expect(wbRealmLabel('cn'), '国内');
      expect(wbRealmLabel('intl'), '国际');
    });

    test('大小写与空白宽容', () {
      expect(wbRealmLabel('INTL'), '国际');
      expect(wbRealmLabel(' cn '), '国内');
      expect(wbRealmLabel('China'), '国内');
    });

    test('空值与未知值都归为未知', () {
      expect(wbRealmLabel(''), '未知');
      expect(wbRealmLabel('  '), '未知');
      expect(wbRealmLabel('us'), '未知');
    });
  });

  group('wbStatusLabel', () {
    test('风控优先于禁用', () {
      expect(wbStatusLabel(enabled: true, restricted: true), '风控中');
      expect(wbStatusLabel(enabled: false, restricted: true), '风控中');
    });

    test('禁用与可用', () {
      expect(wbStatusLabel(enabled: false, restricted: false), '禁用');
      expect(wbStatusLabel(enabled: true, restricted: false), '可用');
    });
  });

  group('wbDisplayLabel', () {
    test('有昵称用昵称', () {
      expect(wbDisplayLabel(nickname: '小泽', uid: '1234567890'), '小泽');
    });

    test('无昵称取 uid 前 8 位并加省略号', () {
      expect(wbDisplayLabel(nickname: '', uid: '12345678901234'), '12345678…');
    });

    test('短 uid 原样显示，昵称的空白也算没有', () {
      expect(wbDisplayLabel(nickname: '   ', uid: 'abc'), 'abc');
    });

    test('两边都空给占位符', () {
      expect(wbDisplayLabel(nickname: '', uid: ''), '—');
    });
  });

  group('额度与成本格式化', () {
    test('wbCreditsText 保留 1 位小数', () {
      expect(wbCreditsText(100000), '100000.0');
      expect(wbCreditsText(0), '0.0');
      expect(wbCreditsText(1.24), '1.2');
      expect(wbCreditsText(1.25), '1.3'); // Dart 的四舍五入：半分进位
    });

    test('wbCnyText 带 ¥ 并保留 2 位小数', () {
      expect(wbCnyText(0), '¥0.00');
      expect(wbCnyText(0.5), '¥0.50');
      expect(wbCnyText(12.34), '¥12.34');
    });

    test('wbTokensText 千位缩写成 k', () {
      expect(wbTokensText(999), '999');
      expect(wbTokensText(1000), '1.0k');
      expect(wbTokensText(1234), '1.2k');
      expect(wbTokensText(12345), '12.3k');
      expect(wbTokensText(0), '0');
    });
  });

  group('时间格式化', () {
    test('DateTime 渲染成日期加时分', () {
      expect(wbWhenText(DateTime(2026, 10, 20, 13, 45)), '2026-10-20 13:45');
    });

    test('字符串时间取到解析得到的部分', () {
      expect(wbWhenText('2026-10-20'), '2026-10-20');
      expect(wbWhenText('2026-10-20T09:30:00Z'), '2026-10-20 09:30');
      expect(wbWhenText('2026-10-20 09:30:00'), '2026-10-20 09:30');
    });

    test('空值给占位符，无法解析的原样返回', () {
      expect(wbWhenText(null), '—');
      expect(wbWhenText(''), '—');
      expect(wbWhenText('nope'), 'nope');
    });

    test('wbClockText 给时分秒', () {
      expect(wbClockText(DateTime(2026, 10, 20, 9, 5, 3)), '09:05:03');
      expect(wbClockText(null), '—');
    });
  });

  group('状态与区色', () {
    final cs = ThemeData().colorScheme;

    test('状态色：可用绿、风控橙、禁用灰', () {
      expect(wbStatusColor('可用'), Colors.green);
      expect(wbStatusColor('风控中'), Colors.orange);
      expect(wbStatusColor('禁用'), Colors.grey);
      expect(wbStatusColor('其它'), Colors.grey);
    });

    test('区色按国内/国际/未知分三档', () {
      expect(wbRealmColor('cn', cs), cs.primaryContainer);
      expect(wbRealmColor('intl', cs), cs.secondaryContainer);
      expect(wbRealmColor('', cs), cs.surfaceContainerHighest);
    });
  });
}
