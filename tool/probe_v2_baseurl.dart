// 验证 v2 CLI 是否遵守 OPENCODE_CONFIG_CONTENT 的 provider baseURL 注入：
// 把 baseURL 指到一个必然失败的地址，若 prompt 报「连接 127.0.0.1:1」类
// 传输错误 → 注入生效（Worker 备胎路线的技术前提成立）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const exe = r'C:\Users\胡天泽\AppData\Roaming\zeroapi\opencode\v2\bin\opencode.exe';

Future<void> main() async {
  const pw = 'probe-pw';
  final root = Directory.systemTemp.createTempSync('oc-burl-');
  final env = Map<String, String>.from(Platform.environment);
  env['OPENCODE_API_KEY'] = '';
  env['OPENCODE_SERVER_PASSWORD'] = pw;
  env['OPENCODE_DISABLE_AUTOUPDATE'] = '1';
  env['OPENCODE_DISABLE_SHARE'] = '1';
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
  // 关键：baseURL 指向必然拒绝连接的地址
  env['OPENCODE_CONFIG_CONTENT'] = jsonEncode({
    '\$schema': 'https://opencode.ai/config.json',
    'provider': {
      'opencode': {'options': {'baseURL': 'http://127.0.0.1:1/v1'}},
    },
  });

  final proc = await Process.start(
    exe,
    ['serve', '--hostname', '127.0.0.1', '--port', '4700'],
    environment: env,
    workingDirectory: root.path,
  );
  var up = false;
  proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
    if (l.contains('listening')) up = true;
  });
  for (var i = 0; i < 40 && !up; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  if (!up) {
    stdout.writeln('SERVE-FAILED');
    proc.kill();
    return;
  }

  final client = HttpClient();
  String auth() => 'Basic ${base64Encode(utf8.encode('opencode:$pw'))}';

  Future<Map<String, dynamic>> api(
    String method,
    String path, [
    Object? body,
  ]) async {
    final r = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:4700$path'),
    );
    r.headers.set('authorization', auth());
    if (body != null) {
      r.headers.set('content-type', 'application/json');
      r.add(utf8.encode(jsonEncode(body)));
    }
    final resp = await r.close().timeout(const Duration(seconds: 30));
    final raw = await utf8.decoder.bind(resp).join();
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  final s = await api('POST', '/api/session', {
    'title': 'probe',
    'permissions': [
      {'action': '*', 'resource': '*', 'effect': 'ask'},
      {'action': 'execute', 'resource': '*', 'effect': 'deny'},
      {'action': 'browser', 'resource': '*', 'effect': 'deny'},
    ],
  });
  final sid = ((s['data'] as Map)['id']) as String;
  await api('POST', '/api/session/$sid/model', {
    'model': {'providerID': 'opencode', 'id': 'deepseek-v4.1-flash-free'},
  });
  await api('POST', '/api/session/$sid/prompt', {'text': 'reply OK'});

  // 轮询消息列表等结果
  Map? assistant;
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    final r = await client.openUrl(
      'GET',
      Uri.parse('http://127.0.0.1:4700/api/session/$sid/message?limit=50'),
    );
    r.headers.set('authorization', auth());
    final resp = await r.close().timeout(const Duration(seconds: 10));
    final body = jsonDecode(await utf8.decoder.bind(resp).join());
    final records = (body['data'] as List?) ?? const [];
    final hasIdle = records.any((m) => m is Map && m['type'] == 'idle');
    for (final m in records.whereType<Map>()) {
      if (m['type'] == 'assistant') assistant = m;
    }
    if (hasIdle) break;
  }
  if (assistant == null) {
    stdout.writeln('NO-RESULT（轮询内无 assistant 消息）');
  } else {
    final err = assistant['error'] as Map?;
    if (err != null) {
      stdout.writeln(
        'INJECTED ✓ error.type=${err['type']} status=${err['status']} '
        'message=${err['message']}',
      );
    } else {
      final content = (assistant['content'] as List?) ?? const [];
      final text = content
          .whereType<Map>()
          .where((p) => p['type'] == 'text')
          .map((p) => p['text'])
          .join();
      if (text.trim().isEmpty) {
        stdout.writeln('AMBIGUOUS：无 error 也无文本，完整记录：');
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(assistant));
      } else {
        stdout.writeln('UNEXPECTED-OK text=$text（baseURL 注入可能没生效）');
      }
    }
  }
  client.close(force: true);
  proc.kill();
  try {
    root.deleteSync(recursive: true);
  } catch (_) {}
}
