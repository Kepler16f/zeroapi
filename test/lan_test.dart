import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/lan.dart';

/// 局域网 IPv4 枚举与接入地址提示文本的单元测试。
void main() {
  final ipv4Pattern = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');

  test('localIPv4Addresses：可 await、不抛异常、仅非回环 IPv4', () async {
    final ips = await localIPv4Addresses();
    for (final ip in ips) {
      expect(ipv4Pattern.hasMatch(ip), true, reason: '$ip 不是合法 IPv4');
    }
    expect(ips.contains('127.0.0.1'), false, reason: '不应包含回环地址');
  });

  test('lanHintText：多地址一行一个 URL；空列表返回排查提示', () {
    final hint = lanHintText(['192.168.1.5', '10.0.0.2'], 8123);
    expect(hint, contains('http://192.168.1.5:8123/v1'));
    expect(hint, contains('http://10.0.0.2:8123/v1'));
    expect(hint.split('\n').length, 2);
    expect(lanHintText([], 8123), contains('未检测到'));
  });
}
