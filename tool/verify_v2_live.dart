// 真机验证 v2 通路：起真 2.2.5 serve（Basic 鉴权）→ 用 OpenCodeApiV2
// 走完整协议（session→model→prompt→wait→消息列表）→ 打印真实回复与 usage。
// 用法：dart run tool/verify_v2_live.dart [--proxy http://127.0.0.1:<port>]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zeroapi/gateway/opencode_api_v2.dart';

Future<void> main(List<String> args) async {
  final exe =
      r"C:\Users\胡天泽\AppData\Roaming\zeroapi\opencode\v2\bin\opencode.exe";
  if (!File(exe).existsSync()) {
    stdout.writeln('no v2 exe at $exe');
    return;
  }
  var proxy = '';
  var port = 4402;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--proxy' && i + 1 < args.length) proxy = args[i + 1];
    if (args[i] == '--port' && i + 1 < args.length) {
      port = int.tryParse(args[i + 1]) ?? port;
    }
  }
  const pw = 'verify-local-pw';
  final root = Directory.systemTemp.createTempSync('oc-v2-');
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
  } else {
    env.remove('HTTP_PROXY');
    env.remove('HTTPS_PROXY');
  }

  final proc = await Process.start(
    exe,
    ['serve', '--hostname', '127.0.0.1', '--port', '$port'],
    environment: env,
    workingDirectory: root.path,
  );
  proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
    if (l.contains('listening')) stdout.writeln('serve: $l');
  });
  await Future<void>.delayed(const Duration(seconds: 4));

  final api = OpenCodeApiV2('http://127.0.0.1:$port', password: pw);
  api.onRetry = (m) => stdout.writeln('RETRY: $m');
  api.onActivity = (m) => stdout.writeln('ACT: $m');
  final sw = Stopwatch()..start();
  final chunks = <String>[];
  try {
    await for (final c in api.chat(
      model: 'deepseek-v4.1-flash-free',
      messages: [
        {'role': 'system', 'content': 'be brief'},
        {'role': 'user', 'content': 'reply with the single word OK'},
      ],
    )) {
      chunks.add(c);
    }
    stdout.writeln('---');
    stdout.writeln('reply: ${chunks.join()}');
    stdout.writeln('usage: ${api.lastUsage} cachedRead=${api.cachedReadTokens}');
    stdout.writeln('elapsed: ${sw.elapsedMilliseconds}ms');
  } catch (e) {
    stdout.writeln('ERROR(${e.runtimeType}): $e');
    stdout.writeln('retryAfter=${api.retryAfterSeconds}');
  } finally {
    api.close();
    proc.kill();
    root.deleteSync(recursive: true);
  }
}
