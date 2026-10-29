import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 一个 SOCKS5 上游的**进程内 HTTP 中转**。
///
/// 为什么需要它（三条已实测的 Dart 3.13.2 事实）：
/// 1. [HttpClient.findProxy] 只接受 PAC 语法 `DIRECT` / `PROXY host:port`，
///    返回 `SOCKS5 host:port` 会在发请求时抛 `HttpException`
///    （sky_engine `_http/http_impl.dart` 的 `_ProxyConfiguration`）。
/// 2. `HttpClient.connectionFactory` 可以注入任意 socket，但 `cancel(withOutCancel:)`
///    与 `Socket.read()` 都已被移除；取消订阅后再 `listen` 同一个 Socket 会抛
///    `StateError: Stream has already been listened to`，所以无法把「握手过的
///    socket」交回 HttpClient。
/// 3. `StreamSubscription.onData()` 仍在，可以**一次订阅贯穿连接生命周期**：
///    先当协议读取器，握手完成后原地切换成透明转发泵。
///
/// 因此这里采用与 mihomo / Clash 相同的结构：自己监听一个本地 HTTP 代理端口，
/// 把 HTTP 请求（absolute-form）或隧道（CONNECT）转成 SOCKS5。HttpClient 只需
/// 走标准 `PROXY 127.0.0.1:<port>`，两端 socket 都由本类从建立起完全拥有。
class SocksRelay {
  SocksRelay({
    required this.host,
    required this.port,
    this.username = '',
    this.password = '',
    this.connectTimeout = const Duration(seconds: 10),
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final Duration connectTimeout;

  ServerSocket? _srv;
  final Set<Socket> _live = {};

  /// 监听成功后才有值；`PROXY 127.0.0.1:<port>` 里的端口。
  int get localPort => _srv?.port ?? 0;

  bool get running => _srv != null;

  /// 给 [HttpClient.findProxy] 用的指令；未启动时为 null。
  String? get directive => running ? 'PROXY 127.0.0.1:${_srv!.port}' : null;

  /// 绑定 loopback 的临时端口并开始接受连接。重复调用是幂等的。
  Future<void> start() async {
    if (_srv != null) return;
    final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _srv = srv;
    srv.listen((s) {
      _live.add(s);
      _handle(s).whenComplete(() => _live.remove(s));
    });
  }

  Future<void> stop() async {
    final srv = _srv;
    _srv = null;
    await srv?.close();
    for (final s in _live.toList()) {
      s.destroy();
    }
    _live.clear();
  }

  /// 处理一条入站连接：CONNECT → 隧道；absolute-form → 改写后转发。
  Future<void> _handle(Socket inbound) async {
    _Tunnel? tunnel;
    try {
      final inP = _Pump(inbound);
      final header = await inP.takeHeader().timeout(connectTimeout);
      final lines = header.split('\r\n');
      final parts = lines.first.split(' ');
      if (parts.length < 2) {
        inbound.destroy();
        return;
      }

      final String targetHost;
      final int targetPort;
      String forwardHeader;

      if (parts[0] == 'CONNECT') {
        final hp = _splitHostPort(parts[1], 443);
        targetHost = hp.$1;
        targetPort = hp.$2;
        forwardHeader = '';
      } else {
        final uri = Uri.parse(parts[1]);
        targetHost = uri.host;
        targetPort = uri.hasPort ? uri.port : 80;
        // 代理收到的是 absolute-form，源站要的是 origin-form
        lines[0] =
            '${parts[0]} ${uri.path.isEmpty ? '/' : uri.path}'
            '${uri.hasQuery ? '?${uri.query}' : ''} HTTP/1.1';
        forwardHeader = '${lines.join('\r\n')}\r\n';
      }

      tunnel = await _openTunnel(targetHost, targetPort);
      if (forwardHeader.isNotEmpty) tunnel.send(utf8.encode(forwardHeader));

      if (parts[0] == 'CONNECT') {
        inbound.add(utf8.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
      }

      final t = tunnel;
      // 任一方向断开都拆掉另一侧，否则半开连接会一直占着 socket
      inP.onClosed = t.destroy;
      t.onClosed = inbound.destroy;
      inP.toRelay(t.send);
      t.pumpTo(inbound.add);
    } catch (_) {
      tunnel?.destroy();
      // 握手阶段失败：给客户端一个明确的 502，而不是让它挂到超时
      try {
        inbound.add(
          utf8.encode(
            'HTTP/1.1 502 Bad Gateway\r\n'
            'Content-Length: 0\r\nConnection: close\r\n\r\n',
          ),
        );
      } catch (_) {}
      inbound.destroy();
    }
  }

  /// 完成 SOCKS5 握手，返回一条可直接灌字节的隧道。
  Future<_Tunnel> _openTunnel(String targetHost, int targetPort) async {
    final raw = await Socket.connect(host, port, timeout: connectTimeout);
    final pump = _Pump(raw);
    try {
      // 问候：有凭据时同时提供「无认证」与「用户名/密码」两种
      final wantsAuth = username.isNotEmpty;
      raw.add(wantsAuth ? [5, 2, 0, 2] : [5, 1, 0]);
      final greet = await pump.take(2).timeout(connectTimeout);
      if (greet[0] != 5) throw const SocketException('不是 SOCKS5 代理');
      final method = greet[1];
      if (method == 0xFF) throw const SocketException('代理拒绝所有认证方式');
      if (method == 2) {
        final u = utf8.encode(username);
        final p = utf8.encode(password);
        raw.add([1, u.length, ...u, p.length, ...p]);
        final ar = await pump.take(2).timeout(connectTimeout);
        if (ar[1] != 0) throw const SocketException('SOCKS5 认证失败');
      } else if (method != 0) {
        throw SocketException('不支持的 SOCKS5 认证方式 $method');
      }

      // 连接请求：IP 字面量用 ATYP 1/4，域名用 ATYP 3（交给代理解析）
      final ip = InternetAddress.tryParse(targetHost);
      final List<int> addr;
      if (ip != null && ip.type == InternetAddressType.IPv4) {
        addr = [1, ...ip.rawAddress];
      } else if (ip != null && ip.type == InternetAddressType.IPv6) {
        addr = [4, ...ip.rawAddress];
      } else {
        final h = utf8.encode(targetHost);
        addr = [3, h.length, ...h];
      }
      raw.add([5, 1, 0, ...addr, (targetPort >> 8) & 0xff, targetPort & 0xff]);

      final head = await pump.take(4).timeout(connectTimeout);
      if (head[1] != 0) {
        throw SocketException('SOCKS5 连接失败 code=${head[1]}');
      }
      final atyp = head[3];
      int skip;
      if (atyp == 1) {
        skip = 4;
      } else if (atyp == 4) {
        skip = 16;
      } else if (atyp == 3) {
        skip = (await pump.take(1).timeout(connectTimeout))[0];
      } else {
        skip = 0;
      }
      if (skip > 0) await pump.take(skip).timeout(connectTimeout);
      await pump.take(2).timeout(connectTimeout); // bound port

      return _Tunnel(pump, raw);
    } catch (_) {
      raw.destroy();
      rethrow;
    }
  }

  static (String, int) _splitHostPort(String s, int fallbackPort) {
    final i = s.lastIndexOf(':');
    if (i < 0) return (s, fallbackPort);
    final p = int.tryParse(s.substring(i + 1));
    if (p == null) return (s, fallbackPort);
    var h = s.substring(0, i);
    if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
    return (h, p);
  }
}

/// 握手完成后的隧道：把 `_Pump` 切换到透明转发。
class _Tunnel {
  _Tunnel(this._pump, this._raw) {
    _pump.onClosed = () => onClosed?.call();
  }

  final _Pump _pump;
  final Socket _raw;

  /// 上游断开时回调（由 [_Pump.onClosed] 转发）。
  void Function()? onClosed;

  void send(List<int> data) => _raw.add(data);

  /// 上游 → 客户端；两端任一断开就销毁。
  void pumpTo(void Function(List<int>) sink) => _pump.toRelay(sink);

  void destroy() => _raw.destroy();
}

/// 单个 Socket 的读取器：**只订阅一次**，靠 [StreamSubscription.onData]
/// 在「协议读取」与「透明转发」之间切换。
class _Pump {
  _Pump(this._s) {
    // 订阅本身由 Socket 的内部控制器持有，这里不需要额外保存引用。
    _s.listen(
      (d) {
        final fwd = _forward;
        if (fwd != null) {
          fwd(d);
          return;
        }
        _buf.addAll(d);
        _wake();
      },
      onError: (_) {},
      onDone: () {
        _done = true;
        _wake();
        onClosed?.call();
      },
    );
  }

  final Socket _s;
  final List<int> _buf = [];
  final List<Completer<void>> _wait = [];
  void Function(List<int>)? _forward;
  bool _done = false;

  /// 对端断开时回调（用于拆除另一侧，避免 socket 泄漏）。
  void Function()? onClosed;

  void _wake() {
    // 注意：必须先复制再 clear，否则 w 与 _wait 是同一个 List，
    // clear 之后循环体一次都不会执行（waiter 永远不被唤醒）。
    final w = List<Completer<void>>.from(_wait);
    _wait.clear();
    for (final c in w) {
      if (!c.isCompleted) c.complete();
    }
  }

  Future<Uint8List> take(int n) async {
    while (_buf.length < n) {
      if (_done) throw const SocketException('连接在握手完成前关闭');
      final c = Completer<void>();
      _wait.add(c);
      await c.future;
    }
    final out = Uint8List.fromList(_buf.sublist(0, n));
    _buf.removeRange(0, n);
    return out;
  }

  Future<String> takeHeader() async {
    while (true) {
      final i = _crlfCrlf(_buf);
      if (i >= 0) {
        final s = String.fromCharCodes(_buf.sublist(0, i + 4));
        _buf.removeRange(0, i + 4);
        return s;
      }
      if (_done) throw const SocketException('连接在请求头完成前关闭');
      if (_buf.length > 64 * 1024) throw const SocketException('请求头过长');
      final c = Completer<void>();
      _wait.add(c);
      await c.future;
    }
  }

  /// 切到透明转发：先把已缓冲的剩余字节（如 POST 正文）吐出去。
  void toRelay(void Function(List<int>) fwd) {
    if (_buf.isNotEmpty) {
      fwd(Uint8List.fromList(_buf));
      _buf.clear();
    }
    _forward = fwd;
  }

  static int _crlfCrlf(List<int> b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }
}

/// 按上游端点复用中转监听器。
///
/// `findProxy` 是同步的，而启动监听器是异步的，所以这里在启动阶段预先把所有
/// 配置过的 SOCKS5 端点拉起来；[directiveFor] 之后就是纯查表。
class SocksRelayHub {
  SocksRelayHub();
  static final SocksRelayHub instance = SocksRelayHub();

  final Map<String, SocksRelay> _relays = {};

  /// 解析形如 `socks5://user:pass@host:port` 的端点；不是 SOCKS 返回 null。
  static SocksRelay? parse(String raw) {
    final s = raw.trim();
    final m = RegExp(r'^socks5?://', caseSensitive: false).firstMatch(s);
    if (m == null) return null;
    var rest = s.substring(m.end);
    final slash = rest.indexOf('/');
    if (slash >= 0) rest = rest.substring(0, slash);

    var user = '';
    var pass = '';
    final at = rest.lastIndexOf('@');
    if (at >= 0) {
      final cred = rest.substring(0, at);
      rest = rest.substring(at + 1);
      final colon = cred.indexOf(':');
      if (colon >= 0) {
        user = Uri.decodeComponent(cred.substring(0, colon));
        pass = Uri.decodeComponent(cred.substring(colon + 1));
      } else {
        user = Uri.decodeComponent(cred);
      }
    }

    final hp = _splitHostPort(rest, 1080);
    if (hp.$1.isEmpty) return null;
    return SocksRelay(host: hp.$1, port: hp.$2, username: user, password: pass);
  }

  static (String, int) _splitHostPort(String s, int fallback) {
    if (s.startsWith('[')) {
      final end = s.indexOf(']');
      if (end > 0) {
        final h = s.substring(1, end);
        final p = end + 1 < s.length && s[end + 1] == ':'
            ? int.tryParse(s.substring(end + 2))
            : null;
        return (h, p ?? fallback);
      }
    }
    final i = s.lastIndexOf(':');
    if (i < 0) return (s, fallback);
    final p = int.tryParse(s.substring(i + 1));
    if (p == null) return (s, fallback);
    return (s.substring(0, i), p);
  }

  /// 确保单个 SOCKS 端点有本地中转（幂等；非 SOCKS 地址返回 null）。
  /// 绑定 loopback 临时端口几乎不会失败——连不上真实 SOCKS 服务器是转发
  /// 时才发生的事（表现为 502），所以这里可以每次请求都安全调用。
  Future<SocksRelay?> ensure(String raw) async {
    final relay = parse(raw);
    if (relay == null) return null;
    final key = '${relay.host}:${relay.port}:${relay.username}';
    final existing = _relays[key];
    if (existing != null && existing.running) return existing;
    try {
      await relay.start();
      _relays[key] = relay;
      return relay;
    } catch (_) {
      return null;
    }
  }

  /// 预热：为一组原始代理地址里的 SOCKS5 端点各起一个监听器。
  /// 先 [await] 它再读 [directiveFor]，避免首个请求因未就绪而回退直连。
  Future<void> prepare(Iterable<String> raws) async {
    for (final raw in raws.toList()) {
      await ensure(raw);
    }
  }

  /// 返回该 SOCKS 端点对应的本地 `PROXY` 指令；未预热成功时为 null。
  String? directiveFor(String raw) {
    final relay = parse(raw);
    if (relay == null) return null;
    final key = '${relay.host}:${relay.port}:${relay.username}';
    return _relays[key]?.directive;
  }

  bool has(String raw) => directiveFor(raw) != null;

  Future<void> stopAll() async {
    for (final r in _relays.values) {
      await r.stop();
    }
    _relays.clear();
  }
}
