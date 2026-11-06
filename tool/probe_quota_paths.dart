// 量当前三条通路哪条还有额度：家宽直连 / 池出口 / 池出口→Worker。
// 用真 2.2.5 CLI（真身份才有额度），每次隔离 HOME、独立端口。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const exe = r'C:\Users\胡天泽\AppData\Roaming\zeroapi\opencode\v2\bin\opencode.exe';
const worker = 'https://zeroapi-opencode-zen.2428556060.workers.dev';

Future<void> main(List<String> args) async {
  final mode = args.isNotEmpty ? args[0] : 'direct'; // direct | <proxy-url> | worker:<proxy-url>
  var proxy = '';
  var overrideBase = '';
  if (mode == 'direct') {
    // 不设代理
  } else if (mode.startsWith('worker:')) {
    proxy = mode.substring(7);
    overrideBase = '$worker/inference/v1';
  } else {
    proxy = mode;
  }
  // 端口取自毫秒时钟对 2000 求余（4600-6599），连发也不易撞；serve 起不来
  // 时由下面的 serverUp 等待兜底报错。
  final port = 4600 + (DateTime.now().millisecondsSinceEpoch % 2000);
  const pw = 'probe-pw';
  final root = Directory.systemTemp.createTempSync('oc-path-');
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
  if (proxy.isNotEmpty) {
    env['HTTP_PROXY'] = proxy;
    env['HTTPS_PROXY'] = proxy;
    env['http_proxy'] = proxy;
    env['https_proxy'] = proxy;
  } else {
    env.remove('HTTP_PROXY');
    env.remove('HTTPS_PROXY');
  }
  if (overrideBase.isNotEmpty) {
    // 把 opencode provider 的 baseURL 指到 Worker（0.3.3 已验证此接线可行）
    env['OPENCODE_CONFIG_CONTENT'] = jsonEncode({
      '\$schema': 'https://opencode.ai/config.json',
      'provider': {
        'opencode': {'options': {'baseURL': overrideBase}},
      },
    });
  }

  final proc = await Process.start(
    exe,
    ['serve', '--hostname', '127.0.0.1', '--port', '$port'],
    environment: env,
    workingDirectory: root.path,
  );
  var serverUp = false;
  proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
    if (l.contains('listening')) serverUp = true;
  });
  for (var i = 0; i < 60 && !serverUp; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  if (!serverUp) {
    stdout.writeln('[$mode] SERVE-FAILED（未监听）');
    proc.kill();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
    return;
  }
  final sw = Stopwatch()..start();
  try {
    final client = HttpClient();
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/api/session'),
    );
    req.headers.set('authorization', 'Basic ${base64Encode(utf8.encode('opencode:$pw'))}');
    req.headers.set('content-type', 'application/json');
    req.add(utf8.encode(jsonEncode({
      'title': 'probe',
      'permissions': [
        {'action': '*', 'resource': '*', 'effect': 'ask'},
        {'action': 'execute', 'resource': '*', 'effect': 'deny'},
        {'action': 'browser', 'resource': '*', 'effect': 'deny'},
      ],
    })));
    final sresp = await req.close().timeout(const Duration(seconds: 15));
    final sraw = await utf8.decoder.bind(sresp).join();
    final sbody = jsonDecode(sraw);
    final sdata = sbody is Map ? sbody['data'] : null;
    if (sdata is! Map || sdata['id'] is! String) {
      stdout.writeln('[$mode] SESSION-FAIL ${sresp.statusCode} ${sraw.length > 200 ? sraw.substring(0, 200) : sraw}');
      client.close(force: true);
      return;
    }
    final sid = sdata['id'] as String;

    Future<void> api(String method, String path, [Object? body]) async {
      final r = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
      r.headers.set('authorization', 'Basic ${base64Encode(utf8.encode('opencode:$pw'))}');
      if (body != null) {
        r.headers.set('content-type', 'application/json');
        r.add(utf8.encode(jsonEncode(body)));
      }
      final resp = await r.close().timeout(const Duration(seconds: 30));
      await resp.drain<void>().timeout(const Duration(seconds: 5), onTimeout: () {});
    }

    await api('POST', '/api/session/$sid/model', {
      'model': {'providerID': 'opencode', 'id': 'deepseek-v4.1-flash-free'},
    });
    await api('POST', '/api/session/$sid/prompt', {
      'text': 'reply with the single word OK',
    });
    // 等本轮结束：轮询消息列表（wait 路由可能挂较久）
    Map? assistant;
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final r = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:$port/api/session/$sid/message?limit=50'),
      );
      r.headers.set('authorization', 'Basic ${base64Encode(utf8.encode('opencode:$pw'))}');
      final resp = await r.close().timeout(const Duration(seconds: 10));
      final raw = await utf8.decoder.bind(resp).join();
      final body = jsonDecode(raw);
      final records =
          body is Map ? (body['data'] as List?) ?? const [] : const [];
      for (final m in records.whereType<Map>()) {
        if (m['type'] == 'idle') {
          assistant = m;
        }
        if (m['type'] == 'assistant') assistant = m;
      }
      if (assistant != null && records.any((m) => m is Map && m['type'] == 'idle')) {
        break;
      }
    }
    final dt = sw.elapsedMilliseconds / 1000;
    if (assistant == null) {
      stdout.writeln('[$mode] TIMEOUT ${dt.toStringAsFixed(1)}s');
    } else {
      final err = assistant['error'] as Map?;
      final content = (assistant['content'] as List?) ?? const [];
      final text = content
          .whereType<Map>()
          .where((p) => p['type'] == 'text')
          .map((p) => p['text'])
          .join();
      if (err != null) {
        final retry = err['retryAfterMs'];
        stdout.writeln(
          '[$mode] QUOTA ${dt.toStringAsFixed(1)}s type=${err['type']} retryAfterMs=$retry',
        );
      } else {
        stdout.writeln('[$mode] OK ${dt.toStringAsFixed(1)}s text=${text.trim()}');
      }
    }
    client.close(force: true);
  } catch (e) {
    stdout.writeln('[$mode] ERROR ${e.runtimeType}: $e');
  } finally {
    proc.kill();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  }
}

class Random {
  int nextInt(int max) => DateTime.now().microsecondsSinceEpoch % max;
}
