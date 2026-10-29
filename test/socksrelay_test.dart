import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/socksrelay.dart';

/// 测试用 SOCKS5 服务端（RFC 1928 + RFC 1929）。
class TestSocks {
  TestSocks({this.requireAuth = false, this.user = '', this.pass = ''});

  final bool requireAuth;
  final String user;
  final String pass;

  ServerSocket? _srv;
  final List<Socket> _live = [];
  int dialCount = 0;

  int get port => _srv!.port;

  Future<void> start() async {
    _srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _srv!.listen((s) {
      _live.add(s);
      _serve(s);
    });
  }

  Future<void> stop() async {
    await _srv?.close();
    _srv = null;
    for (final s in _live) {
      s.destroy();
    }
    _live.clear();
  }

  void _serve(Socket sock) {
    final buf = <int>[];
    var stage = 0;
    Socket? up;

    void pump() {
      while (true) {
        if (up != null) return;
        if (stage == 0) {
          if (buf.length < 2) return;
          final total = 2 + buf[1];
          if (buf.length < total) return;
          final methods = buf.sublist(2, total);
          if (requireAuth && !methods.contains(2)) {
            sock.add([5, 0xFF]);
            sock.destroy();
            return;
          }
          sock.add([5, requireAuth ? 2 : 0]);
          buf.removeRange(0, total);
          stage = requireAuth ? 1 : 2;
          continue;
        }
        if (stage == 1) {
          if (buf.length < 2) return;
          final ulen = buf[1];
          if (buf.length < 2 + ulen + 1) return;
          final plen = buf[2 + ulen];
          final total = 2 + ulen + 1 + plen;
          if (buf.length < total) return;
          final u = utf8.decode(buf.sublist(2, 2 + ulen));
          final p = utf8.decode(buf.sublist(3 + ulen, total));
          if (u != user || p != pass) {
            sock.add([1, 1]);
            sock.destroy();
            return;
          }
          sock.add([1, 0]);
          buf.removeRange(0, total);
          stage = 2;
          continue;
        }
        // stage 2: 连接请求
        if (buf.length < 5) return;
        final atyp = buf[3];
        final int need;
        if (atyp == 1) {
          need = 10;
        } else if (atyp == 4) {
          need = 22;
        } else if (atyp == 3) {
          need = 7 + buf[4];
        } else {
          sock.add([5, 8, 0, 1, 0, 0, 0, 0, 0, 0]);
          sock.destroy();
          return;
        }
        if (buf.length < need) return;
        final String host;
        if (atyp == 1) {
          host = '${buf[4]}.${buf[5]}.${buf[6]}.${buf[7]}';
        } else if (atyp == 3) {
          host = utf8.decode(buf.sublist(5, 5 + buf[4]));
        } else {
          host = InternetAddress.fromRawAddress(
            Uint8List.fromList(buf.sublist(4, 20)),
          ).address;
        }
        final p = buf[need - 2] * 256 + buf[need - 1];
        buf.clear();
        stage = 3;
        Socket.connect(host, p)
            .then((u) {
              up = u;
              dialCount++;
              sock.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
              u.listen(
                sock.add,
                onError: (_) => sock.destroy(),
                onDone: () => sock.destroy(),
              );
            })
            .catchError((_) {
              sock.add([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]);
              sock.destroy();
            });
        return;
      }
    }

    sock.listen(
      (d) {
        final u = up;
        if (u != null) {
          u.add(d);
          return;
        }
        buf.addAll(d);
        pump();
        // onError/onDone：客户端断开时把已拨出的上游也拆掉，否则这半边连接
        // 会一直吊住测试 isolate（表现为 tearDown 后长时间不退出）
      },
      onError: (_) {
        up?.destroy();
        sock.destroy();
      },
      onDone: () {
        up?.destroy();
      },
    );
  }
}

Future<HttpServer> startTarget(String body) async {
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((req) async {
    req.response.statusCode = 200;
    req.response.write(body);
    await req.response.close();
  });
  return srv;
}

void main() {
  group('SocksRelayHub.parse', () {
    test('解析 scheme / 凭据 / 默认端口', () {
      final a = SocksRelayHub.parse('socks5://127.0.0.1:7891');
      expect(a, isNotNull);
      expect(a!.host, '127.0.0.1');
      expect(a.port, 7891);
      expect(a.username, isEmpty);

      final b = SocksRelayHub.parse('socks://u%40x:p%3Aw@10.0.0.2:1080');
      expect(b!.username, 'u@x');
      expect(b.password, 'p:w');

      final c = SocksRelayHub.parse('socks5://host.example');
      expect(c!.port, 1080);

      expect(SocksRelayHub.parse('http://127.0.0.1:7890'), isNull);
      expect(SocksRelayHub.parse('127.0.0.1:1080'), isNull);
    });
  });

  group('SocksRelay', () {
    test('absolute-form GET 经 SOCKS5 到达目标', () async {
      final socks = TestSocks();
      await socks.start();
      final target = await startTarget('hello-via-relay');
      final relay = SocksRelay(host: '127.0.0.1', port: socks.port);
      await relay.start();
      addTearDown(() async {
        await relay.stop();
        await socks.stop();
        await target.close(force: true);
      });

      final client = HttpClient()..findProxy = (_) => relay.directive!;
      addTearDown(() => client.close(force: true));

      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${target.port}/x?y=1'),
      );
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      expect(resp.statusCode, 200);
      expect(body, 'hello-via-relay');
      expect(socks.dialCount, 1);
    });

    test('CONNECT 隧道双向透传', () async {
      final socks = TestSocks();
      await socks.start();
      final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      echo.listen((s) => s.listen((d) => s.add([...utf8.encode('E:'), ...d])));
      final relay = SocksRelay(host: '127.0.0.1', port: socks.port);
      await relay.start();
      addTearDown(() async {
        await relay.stop();
        await socks.stop();
        await echo.close();
      });

      final s = await Socket.connect('127.0.0.1', relay.localPort);
      final got = <int>[];
      final done = Completer<void>();
      s.listen((d) {
        got.addAll(d);
        if (utf8.decode(got, allowMalformed: true).contains('E:ping')) {
          if (!done.isCompleted) done.complete();
        }
      });
      s.add(
        utf8.encode(
          'CONNECT 127.0.0.1:${echo.port} HTTP/1.1\r\n'
          'Host: 127.0.0.1\r\n\r\n',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      s.add(utf8.encode('ping'));
      await done.future.timeout(const Duration(seconds: 5));
      expect(utf8.decode(got), contains('200 Connection Established'));
      expect(utf8.decode(got), contains('E:ping'));
      s.destroy();
    });

    test('用户名/密码认证', () async {
      final socks = TestSocks(requireAuth: true, user: 'alice', pass: 's3cret');
      await socks.start();
      final target = await startTarget('authed');
      final relay = SocksRelay(
        host: '127.0.0.1',
        port: socks.port,
        username: 'alice',
        password: 's3cret',
      );
      await relay.start();
      addTearDown(() async {
        await relay.stop();
        await socks.stop();
        await target.close(force: true);
      });

      final client = HttpClient()..findProxy = (_) => relay.directive!;
      addTearDown(() => client.close(force: true));
      final req = await client.getUrl(
        Uri.parse('http://127.0.0.1:${target.port}/'),
      );
      final resp = await req.close();
      expect(await resp.transform(utf8.decoder).join(), 'authed');
    });

    test('上游不可用时回 502，不挂到超时', () async {
      // 指向一个没有监听的端口
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();

      final relay = SocksRelay(
        host: '127.0.0.1',
        port: deadPort,
        connectTimeout: const Duration(seconds: 2),
      );
      await relay.start();
      addTearDown(relay.stop);

      final client = HttpClient()..findProxy = (_) => relay.directive!;
      addTearDown(() => client.close(force: true));
      final sw = Stopwatch()..start();
      try {
        final req = await client.getUrl(Uri.parse('http://example.invalid/x'));
        final resp = await req.close();
        expect(resp.statusCode, 502);
        await resp.drain<void>();
      } on HttpException {
        // HttpClient 也可能把 502 当成连接失败抛出，两者都可接受
      }
      expect(sw.elapsed, lessThan(const Duration(seconds: 8)));
    });

    test('stop 后不再接受连接', () async {
      final socks = TestSocks();
      await socks.start();
      final relay = SocksRelay(host: '127.0.0.1', port: socks.port);
      await relay.start();
      final p = relay.localPort;
      expect(relay.running, isTrue);
      await relay.stop();
      expect(relay.running, isFalse);
      expect(relay.directive, isNull);
      await expectLater(
        Socket.connect('127.0.0.1', p, timeout: const Duration(seconds: 2)),
        throwsA(isA<SocketException>()),
      );
      await socks.stop();
    });
  });
}
