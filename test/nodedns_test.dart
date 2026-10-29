import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/nodedns.dart';

void main() {
  group('DoH 响应解析', () {
    test('取第一条 A 记录', () {
      const body =
          '{"Status":0,"Answer":['
          '{"name":"a.example.com.","type":5,"data":"cname.example.com."},'
          '{"name":"a.example.com.","type":1,"data":"1.2.3.4"},'
          '{"name":"a.example.com.","type":1,"data":"5.6.7.8"}]}';
      expect(NodeDns.parseDohAnswer(body), '1.2.3.4');
    });

    test('跳过 fake-ip 地址', () {
      const body =
          '{"Status":0,"Answer":['
          '{"type":1,"data":"198.18.0.20"},'
          '{"type":1,"data":"198.19.3.4"},'
          '{"type":1,"data":"47.130.164.214"}]}';
      expect(NodeDns.parseDohAnswer(body), '47.130.164.214');
    });

    test('全是 fake-ip 时返回 null', () {
      const body = '{"Status":0,"Answer":[{"type":1,"data":"198.18.0.2"}]}';
      expect(NodeDns.parseDohAnswer(body), isNull);
    });

    test('Status 非 0 / 无 Answer / 坏 JSON 都是 null', () {
      expect(NodeDns.parseDohAnswer('{"Status":3}'), isNull);
      expect(NodeDns.parseDohAnswer('{"Status":0}'), isNull);
      expect(NodeDns.parseDohAnswer('not json'), isNull);
    });
  });

  group('地址判定', () {
    test('fake-ip 段', () {
      expect(NodeDns.isFakeIp('198.18.0.2'), isTrue);
      expect(NodeDns.isFakeIp('198.19.255.255'), isTrue);
      expect(NodeDns.isFakeIp('198.20.0.1'), isFalse);
      expect(NodeDns.isFakeIp('127.0.0.1'), isTrue);
      expect(NodeDns.isFakeIp('47.131.94.75'), isFalse);
    });

    test('IP 字面量', () {
      expect(NodeDns.isIpLiteral('47.131.94.75'), isTrue);
      expect(NodeDns.isIpLiteral('2001:db8::1'), isTrue);
      expect(NodeDns.isIpLiteral('sg01.459292.xyz'), isFalse);
      expect(NodeDns.isIpLiteral('1.2.3'), isFalse);
    });
  });

  group('解析流程', () {
    test('成功结果进缓存，第二次不再请求', () async {
      var calls = 0;
      final dns = NodeDns.testing((uri) async {
        calls++;
        expect(uri.queryParameters['type'], 'A');
        expect(uri.queryParameters['name'], 'node.example.com');
        return '{"Status":0,"Answer":[{"type":1,"data":"9.9.9.9"}]}';
      });
      expect(await dns.resolve('node.example.com'), '9.9.9.9');
      expect(await dns.resolve('NODE.example.com'), '9.9.9.9');
      expect(calls, 1);
    });

    test('第一个端点给假地址时换下一个端点', () async {
      var calls = 0;
      final dns = NodeDns.testing((uri) async {
        calls++;
        if (calls == 1) {
          return '{"Status":0,"Answer":[{"type":1,"data":"198.18.0.2"}]}';
        }
        return '{"Status":0,"Answer":[{"type":1,"data":"8.8.4.4"}]}';
      });
      expect(await dns.resolve('x.example.com'), '8.8.4.4');
      expect(calls, 2);
    });

    test('全部失败返回 null，并短时间负缓存', () async {
      var calls = 0;
      final dns = NodeDns.testing((_) async {
        calls++;
        throw StateError('offline');
      });
      expect(await dns.resolve('dead.example.com'), isNull);
      expect(await dns.resolve('dead.example.com'), isNull);
      expect(calls, 2, reason: '负缓存后不再打端点');
    });

    test('批量去重、跳过 IP 字面量', () async {
      final asked = <String>[];
      final dns = NodeDns.testing((uri) async {
        final name = uri.queryParameters['name']!;
        asked.add(name);
        return '{"Status":0,"Answer":[{"type":1,"data":"1.1.1.1"}]}';
      });
      final out = await dns.resolveAll([
        'a.example.com',
        'A.example.com',
        '10.0.0.1',
        ' ',
        'b.example.com',
      ]);
      expect(out, {'a.example.com': '1.1.1.1', 'b.example.com': '1.1.1.1'});
      expect(asked, ['a.example.com', 'b.example.com']);
    });
  });
}
