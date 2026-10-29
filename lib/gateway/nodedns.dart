import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 节点域名解析（DoH）。
///
/// 为什么不用系统 DNS：用户开着 Clash/FlClash 的 TUN 时，系统 DNS 会被
/// 改成 fake-ip（198.18.0.0/15）。内置内核若把节点域名解析成 198.18.0.x，
/// 整个 QUIC 握手都会超时，表现就是「每个节点都 502 / deadline exceeded」，
/// 而在 Clash 里同一个节点却正常。这里用 DoH 拿真实 A 记录，配置里直接写
/// IP（sni 仍保留原域名），彻底绕开 fake-ip。
///
/// 失败就回退到原始域名，让内核自己再试——TUN 关闭时系统 DNS 本来就没问题。
class NodeDns {
  NodeDns._() : _fetchOverride = null;

  /// 生产环境单例；测试用 [NodeDns.testing] 注入假响应。
  static final NodeDns instance = NodeDns._();

  static const List<String> endpoints = [
    'https://doh.pub/dns-query',
    'https://dns.alidns.com/resolve',
  ];
  static const Duration _ttl = Duration(minutes: 5);
  static const Duration _negativeTtl = Duration(minutes: 1);
  static const Duration _timeout = Duration(seconds: 4);

  final Map<String, _Entry> _cache = {};
  HttpClient? _client;

  /// 测试入口：fetcher 返回 DoH 的 JSON 响应体。
  NodeDns.testing(this._fetchOverride);

  final Future<String> Function(Uri uri)? _fetchOverride;

  HttpClient _http() => _client ??= HttpClient()
    ..connectionTimeout = _timeout
    ..idleTimeout = const Duration(seconds: 20)
    ..userAgent = 'ZeroApi/1.0';

  /// 解析单个域名，返回真实 IPv4；解析不出来返回 null。
  Future<String?> resolve(String host) async {
    final h = host.trim().toLowerCase();
    if (h.isEmpty || isIpLiteral(h)) return null;
    final cached = _cache[h];
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      return cached.ip;
    }
    for (final base in endpoints) {
      try {
        final uri = Uri.parse(base)
            .replace(queryParameters: {'name': h, 'type': 'A'});
        final body = await (_fetchOverride?.call(uri) ?? _get(uri)).timeout(
          _timeout,
        );
        final ip = parseDohAnswer(body);
        if (ip != null) {
          _cache[h] = _Entry(ip, DateTime.now().add(_ttl));
          return ip;
        }
      } catch (_) {
        // 换下一个 DoH 端点
      }
    }
    _cache[h] = _Entry(null, DateTime.now().add(_negativeTtl));
    return null;
  }

  /// 批量解析（限并发 6）。返回 域名→真实 IP，解析失败的域名不出现在结果里。
  /// [budget] 是总时间预算：离线时每个端点都要等超时，不设上限会把应用启动
  /// 拖到几十秒，超预算的域名直接回退成原域名交给内核。
  Future<Map<String, String>> resolveAll(
    Iterable<String> hosts, {
    Duration budget = const Duration(seconds: 8),
  }) async {
    final uniq = <String>{
      for (final h in hosts)
        if (h.trim().isNotEmpty && !isIpLiteral(h.trim()))
          h.trim().toLowerCase(),
    }.toList();
    final out = <String, String>{};
    final stopwatch = Stopwatch()..start();
    const limit = 6;
    for (var i = 0; i < uniq.length; i += limit) {
      if (stopwatch.elapsed > budget) break;
      final batch = uniq.skip(i).take(limit);
      final results = await Future.wait([
        for (final h in batch) resolve(h).then((ip) => MapEntry(h, ip)),
      ]);
      for (final r in results) {
        final ip = r.value;
        if (ip != null) out[r.key] = ip;
      }
    }
    return out;
  }

  Future<String> _get(Uri uri) async {
    final req = await _http().getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw HttpException('DoH ${res.statusCode}', uri: uri);
    }
    return body;
  }

  /// DoH JSON（RFC 8484 的 application/dns-json 形态）里取第一条 A 记录。
  /// 假地址（198.18.0.0/15 等）一律忽略。
  static String? parseDohAnswer(String body) {
    Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (json is! Map) return null;
    if (json['Status'] != 0) return null;
    final answers = json['Answer'];
    if (answers is! List) return null;
    for (final a in answers) {
      if (a is! Map) continue;
      if (a['type'] != 1 && a['type'] != '1') continue;
      final ip = '${a['data'] ?? ''}'.trim();
      if (ip.isEmpty || isFakeIp(ip)) continue;
      return ip;
    }
    return null;
  }

  /// Clash 的 fake-ip 段（RFC 2544 基准测试网段）以及其它不可路由地址。
  static bool isFakeIp(String ip) {
    final p = ip.split('.').map(int.tryParse).toList();
    if (p.length != 4 || p.any((e) => e == null)) return false;
    final a = p[0]!, b = p[1]!;
    if (a == 198 && (b == 18 || b == 19)) return true;
    if (a == 0 || a == 127) return true;
    if (a == 169 && b == 254) return true;
    return false;
  }

  static bool isIpLiteral(String host) {
    final h = host.trim();
    if (InternetAddress.tryParse(h) == null) return false;
    // InternetAddress.tryParse 也接受 `1.2.3` 这类简写，这里只认标准点分四段
    return RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h) || h.contains(':');
  }

  /// 清空缓存（测试/池整体变化时用）。
  void clear() => _cache.clear();
}

class _Entry {
  _Entry(this.ip, this.expires);
  final String? ip;
  final DateTime expires;
}
