import 'dart:convert';
import 'dart:io';

/// Cloudflare Workers REST API 的精简封装：只覆盖「一键部署 Zen 出口
/// Worker」所需的最少端点。API Token 仅在调用期间存在于内存（不落盘、
/// 不写 config.json），部署完成即丢弃——每个用户使用自己的免费 Cloudflare
/// 账号，应用不内置任何账号凭据。
class CloudflareApi {
  static const _api = 'https://api.cloudflare.com/client/v4';

  /// 与 deploy/cloudflare-worker/wrangler.toml 保持一致的脚本名
  static const scriptName = 'zeroapi-opencode-zen';

  final String token;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20);

  CloudflareApi(this.token);

  void close() => _client.close(force: true);

  Future<List<CfAccount>> listAccounts() async {
    final j = await _get('/accounts');
    return ((j['result'] ?? []) as List)
        .map((e) => CfAccount('${e['id']}', '${e['name']}'))
        .toList();
  }

  /// 账号的 workers.dev 泛域名前缀（zeroapi-opencode-zen.<sub>.workers.dev）
  Future<String> subdomain(String accountId) async {
    final j = await _get('/accounts/$accountId/workers/subdomain');
    return '${(j['result'] as Map)['subdomain']}';
  }

  /// 上传/替换单文件 ES Module Worker（multipart：metadata + index.js）
  Future<void> deployScript({
    required String accountId,
    required String code,
    required String compatibilityDate,
  }) async {
    final boundary = '----zeroapi${DateTime.now().microsecondsSinceEpoch}';
    final meta = jsonEncode({
      'main_module': 'index.js',
      'compatibility_date': compatibilityDate,
    });
    final body = <int>[];
    void part(String s) => body.addAll(utf8.encode(s));
    part(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="metadata"\r\n'
      'Content-Type: application/json\r\n\r\n$meta\r\n',
    );
    part(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="index.js"; filename="index.js"\r\n'
      'Content-Type: application/javascript+module\r\n\r\n',
    );
    part(code);
    part('\r\n--$boundary--\r\n');

    final uri = Uri.parse(
      '$_api/accounts/$accountId/workers/scripts/$scriptName',
    );
    final req = await _client.openUrl('PUT', uri);
    req.headers.set('Authorization', 'Bearer $token');
    req.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');
    req.add(body);
    final res = await req.close().timeout(const Duration(seconds: 90));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw StateError('Cloudflare API ${res.statusCode}: ${_errOf(text)}');
    }
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final req = await _client.getUrl(Uri.parse('$_api$path'));
    req.headers.set('Authorization', 'Bearer $token');
    final res = await req.close().timeout(const Duration(seconds: 30));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw StateError('Cloudflare API ${res.statusCode}: ${_errOf(text)}');
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  static String _errOf(String body) {
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;
      final errs = (j['errors'] as List? ?? [])
          .map((e) => '${(e as Map)['code']}: ${(e)['message']}')
          .join('; ');
      if (errs.isNotEmpty) return errs;
    } catch (_) {}
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }
}

class CfAccount {
  final String id;
  final String name;
  CfAccount(this.id, this.name);
  @override
  String toString() => name.isEmpty ? id : '$name ($id)';
}
