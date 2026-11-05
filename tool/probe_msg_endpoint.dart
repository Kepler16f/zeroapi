// 打真 2.2.5 serve，看 /api/session/{id}/message 到底哪种参数组合被接受。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final exe =
      r"C:\Users\胡天泽\AppData\Roaming\zeroapi\opencode\v2\bin\opencode.exe";
  const pw = 'probe-pw';
  final root = Directory.systemTemp.createTempSync('oc-probe-');
  final env = Map<String, String>.from(Platform.environment);
  env['OPENCODE_API_KEY'] = '';
  env['OPENCODE_SERVER_PASSWORD'] = pw;
  env['HOME'] = root.path;
  env['USERPROFILE'] = root.path;
  env['APPDATA'] = '${root.path}/AppData/Roaming';
  env['LOCALAPPDATA'] = '${root.path}/AppData/Local';
  env['XDG_DATA_HOME'] = '${root.path}/data';
  env['XDG_CONFIG_HOME'] = '${root.path}/config';
  env['XDG_CACHE_HOME'] = '${root.path}/cache';
  env['XDG_STATE_HOME'] = '${root.path}/state';
  env.remove('HTTP_PROXY');
  env.remove('HTTPS_PROXY');

  final proc = await Process.start(
    exe,
    ['serve', '--hostname', '127.0.0.1', '--port', '4403'],
    environment: env,
    workingDirectory: root.path,
  );
  proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
    if (l.contains('listening')) stdout.writeln('serve: $l');
  });
  await Future<void>.delayed(const Duration(seconds: 4));

  final client = HttpClient();
  String auth() =>
      'Basic ${base64Encode(utf8.encode('opencode:$pw'))}';

  Future<Map<String, dynamic>> req(
    String method,
    String path, [
    Object? body,
  ]) async {
    final r = await client.openUrl(method, Uri.parse('http://127.0.0.1:4403$path'));
    r.headers.set('authorization', auth());
    if (body != null) {
      r.headers.set('content-type', 'application/json');
      r.add(utf8.encode(jsonEncode(body)));
    }
    final resp = await r.close();
    final raw = await utf8.decoder.bind(resp).join();
    stdout.writeln('$method $path -> ${resp.statusCode} ${raw.length > 300 ? raw.substring(0, 300) : raw}');
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  final s = await req('POST', '/api/session', {
    'title': 'probe',
    'permissions': [
      {'action': '*', 'resource': '*', 'effect': 'ask'},
      {'action': 'execute', 'resource': '*', 'effect': 'deny'},
      {'action': 'browser', 'resource': '*', 'effect': 'deny'},
    ],
  });
  final sid = (s['data'] as Map)['id'] as String;
  stdout.writeln('sid=$sid');
  await req('POST', '/api/session/$sid/model', {
    'model': {'providerID': 'opencode', 'id': 'deepseek-v4.1-flash-free'},
  });
  await req('POST', '/api/session/$sid/prompt', {'text': 'reply OK'});
  await Future<void>.delayed(const Duration(seconds: 12));
  await req('GET', '/api/session/$sid/message?limit=200&order=asc');
  await req('GET', '/api/session/$sid/message?limit=50');
  await req('GET', '/api/session/$sid/message');
  await req('POST', '/api/experimental/session/$sid/wait');
  await req('GET', '/api/session/$sid/message?limit=200&order=asc');

  client.close(force: true);
  proc.kill();
  root.deleteSync(recursive: true);
}
