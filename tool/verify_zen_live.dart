// Opt-in live check for a locally installed OpenCode CLI and one existing
// loopback proxy listener. Emits metadata-only JSONL; never logs response text.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

String? arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return i < 0 || i + 1 >= args.length ? null : args[i + 1];
}

void record(String check, String status, {int? code, String? detail}) {
  stdout.writeln(jsonEncode({
    'at': DateTime.now().toUtc().toIso8601String(),
    'check': check,
    'status': status,
    'http_status': ?code,
    'detail': ?detail,
  }));
}

Future<(int, String)> request(String method, Uri uri,
    {Map<String, Object?>? body, Duration timeout = const Duration(seconds: 30)}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await (method == 'GET' ? client.getUrl(uri) : client.postUrl(uri))
        .timeout(timeout);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
    }
    final res = await req.close().timeout(timeout);
    return (res.statusCode, await res.transform(utf8.decoder).join().timeout(timeout));
  } finally {
    client.close(force: true);
  }
}

void collectModelIds(Object? v, Set<String> out) {
  if (v is Map) {
    for (final e in v.entries) {
      if (e.key == 'id' && e.value is String) out.add(e.value as String);
      collectModelIds(e.value, out);
    }
  } else if (v is List) {
    for (final e in v) { collectModelIds(e, out); }
  }
}

Future<bool> waitHealth(Uri base, Process proc) async {
  var exited = false;
  unawaited(proc.exitCode.then((_) => exited = true));
  for (var i = 0; i < 30 && !exited; i++) {
    try {
      final (code, raw) = await request('GET', base.resolve('/global/health'),
          timeout: const Duration(seconds: 3));
      if (code == 200 && (jsonDecode(raw) as Map)['healthy'] == true) return true;
    } catch (_) {}
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return false;
}

Future<bool> generate(Uri base, {required bool stream, required String model}) async {
  final (sc, sessionRaw) = await request('POST', base.resolve('/session'), body: {});
  if (sc != 200) { record(stream ? 'generation_stream' : 'generation_nonstream', 'failed', code: sc); return false; }
  final sid = (jsonDecode(sessionRaw) as Map)['id'] as String;
  var sawText = false;
  HttpClient? eventClient;
  StreamSubscription<String>? eventSub;
  try {
    if (stream) {
      eventClient = HttpClient()..idleTimeout = const Duration(minutes: 3);
      final er = await eventClient.getUrl(base.resolve('/event'));
      final es = await er.close().timeout(const Duration(seconds: 20));
      final done = Completer<void>();
      // 先标记为「已处理」，避免错误先于 await 到达时变成 unhandled error。
      done.future.ignore();
      final assistantIds = <String>{};
      eventSub = es.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (!line.startsWith('data:')) return;
        try {
          final ev = jsonDecode(line.substring(5).trim()) as Map;
          final props = ev['properties'];
          if (ev['type'] == 'message.updated' && props is Map) {
            final info = props['info'];
            if (info is Map && info['role'] == 'assistant' && info['id'] is String) assistantIds.add(info['id'] as String);
          }
          if (ev['type'] == 'message.part.updated' && props is Map) {
            final p = props['part'];
            if (p is Map && p['type'] == 'text' && p['text'] is String &&
                (p['messageID'] == null || assistantIds.contains(p['messageID'])) &&
                (p['text'] as String).isNotEmpty) {
              sawText = true;
            }
          }
          final status = props is Map ? props['status'] : null;
          if (ev['type'] == 'session.status' && props['sessionID'] == sid && status is Map && status['type'] == 'idle' && !done.isCompleted) done.complete();
          if (ev['type'] == 'session.idle' && props is Map && props['sessionID'] == sid && !done.isCompleted) done.complete();
          if (ev['type'] == 'session.error' && props is Map && props['sessionID'] == sid && !done.isCompleted) {
            final err = props['error'];
            final data = err is Map ? (err['data'] ?? const <String, dynamic>{}) : const <String, dynamic>{};
            final message = data is Map ? (data['message'] ?? err['name'] ?? '') : '';
            final status = data is Map ? (data['statusCode'] ?? '') : '';
            done.completeError(StateError('session_error status=$status message=$message'));
          }
          if (ev['type'] == 'session.status' && props is Map && props['sessionID'] == sid) {
            final st = props['status'];
            if (st is Map && st['type'] == 'retry' && !done.isCompleted) {
              done.completeError(StateError('retry message=${st['message'] ?? ''}'));
            }
          }
        } catch (_) {}
      }, onError: (Object _) { if (!done.isCompleted) done.completeError(StateError('event stream error')); });
      // Allow event subscription to establish before submitting the prompt.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final (code, _) = await request('POST', base.resolve('/session/$sid/message'), body: {
        'model': {'providerID': 'opencode', 'modelID': model},
        'parts': [{'type': 'text', 'text': 'Reply with exactly OK.'}],
      }, timeout: const Duration(seconds: 100));
      if (code != 200) { record('generation_stream', 'failed', code: code); return false; }
      await done.future.timeout(const Duration(seconds: 100));
    } else {
      final (code, raw) = await request('POST', base.resolve('/session/$sid/message'), body: {
        'model': {'providerID': 'opencode', 'modelID': model},
        'parts': [{'type': 'text', 'text': 'Reply with exactly OK.'}],
      }, timeout: const Duration(seconds: 100));
      if (code != 200) { record('generation_nonstream', 'failed', code: code); return false; }
      final result = jsonDecode(raw);
      // CLI 也会以 HTTP 200 + info.error 报上游失败（如额度耗尽）。
      final info = result is Map ? result['info'] : null;
      final err = info is Map ? info['error'] : null;
      if (err is Map) {
        final data = err['data'];
        final message = data is Map ? (data['message'] ?? err['name'] ?? '') : '';
        final status = data is Map ? (data['statusCode'] ?? '') : '';
        final lower = message.toString().toLowerCase();
        final label = lower.contains('usage exceeded') ||
                lower.contains('quota') ||
                lower.contains('free usage')
            ? 'quota_exceeded'
            : 'session_error status=$status message=$message';
        record('generation_nonstream', 'failed', detail: label);
        return false;
      }
      sawText = result is Map && result['parts'] is List &&
          (result['parts'] as List).any((p) => p is Map && p['type'] == 'text' && p['text'] is String && (p['text'] as String).trim().isNotEmpty);
    }
    record(stream ? 'generation_stream' : 'generation_nonstream', sawText ? 'passed' : 'failed');
    return sawText;
  } catch (e) {
    // 归一化失败原因：区分额度拒绝、上游状态码与超时，不记录响应正文。
    final raw = e is TimeoutException ? 'timeout' : e.toString();
    final lower = raw.toLowerCase();
    final label = lower.contains('usage exceeded') || lower.contains('quota') || lower.contains('free usage')
        ? 'quota_exceeded'
        : lower.contains('status=429')
            ? 'upstream_429'
            : lower.contains('session_error')
                ? 'session_error'
                : lower.contains('retry')
                    ? 'upstream_retry'
                    : e is TimeoutException
                        ? 'timeout'
                        : 'request_error';
    record(stream ? 'generation_stream' : 'generation_nonstream', 'failed', detail: label);
    return false;
  } finally {
    await eventSub?.cancel();
    eventClient?.close(force: true);
    try { await request('DELETE', base.resolve('/session/$sid')); } catch (_) {}
  }
}

Future<void> main(List<String> args) async {
  final exe = arg(args, '--cli');
  final proxyText = arg(args, '--proxy');
  final model = arg(args, '--model') ?? 'glm-5.3-flash-free';
  if (args.contains('--help') || exe == null || proxyText == null) {
    stderr.writeln('Usage: dart run tool/verify_zen_live.dart --cli <opencode.exe> --proxy http://127.0.0.1:<listener-port> [--model glm-5.3-flash-free]');
    stderr.writeln('Exactly one loopback HTTP/SOCKS listener is used. Proxy credentials and remote URLs are rejected.');
    exitCode = args.contains('--help') ? 0 : 64;
    return;
  }
  final proxy = Uri.tryParse(proxyText);
  if (proxy == null || !{'http', 'https', 'socks5'}.contains(proxy.scheme) ||
      !{'127.0.0.1', 'localhost', '::1'}.contains(proxy.host) ||
      proxy.userInfo.isNotEmpty || proxy.port < 1 || proxy.port > 65535) {
    record('preflight', 'blocked', detail: 'proxy_must_be_loopback_listener_without_credentials');
    exitCode = 2;
    return;
  }
  if (!File(exe).existsSync()) {
    record('preflight', 'blocked', detail: 'cli_file_not_found');
    exitCode = 2;
    return;
  }
  final home = await Directory.systemTemp.createTemp('zen-live-');
  Process? proc;
  try {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final isolated = home.path;
    // Start from a small allowlist so ambient provider keys/tokens cannot
    // reach the child process. Keep only variables needed to launch on Windows.
    final env = <String, String>{
      for (final k in ['PATH', 'SystemRoot', 'WINDIR', 'TEMP', 'TMP', 'PROCESSOR_ARCHITECTURE'])
        if (Platform.environment.containsKey(k)) k: Platform.environment[k] ?? '',
    }
      ..['HOME'] = isolated
      ..['USERPROFILE'] = isolated
      ..['APPDATA'] = '$isolated/AppData/Roaming'
      ..['LOCALAPPDATA'] = '$isolated/AppData/Local'
      ..['OPENCODE_API_KEY'] = ''
      ..['OPENCODE_DISABLE_AUTOUPDATE'] = '1'
      ..['OPENCODE_DISABLE_SHARE'] = '1'
      ..['OPENCODE_DISABLE_LSP_DOWNLOAD'] = '1'
      ..['OPENCODE_DISABLE_PROJECT_CONFIG'] = '1'
      ..['OPENCODE_DISABLE_CLAUDE_CODE'] = '1'
      ..['OPENCODE_DISABLE_EXTERNAL_SKILLS'] = '1'
      ..['OPENCODE_DISABLE_DEFAULT_PLUGINS'] = '1'
      ..['OPENCODE_CONFIG_CONTENT'] = '{"permission":{"*":"deny"}}'
      ..['OPENCODE_DISABLE_EMBEDDED_WEB_UI'] = '1'
      ..['HTTP_PROXY'] = proxyText
      ..['HTTPS_PROXY'] = proxyText
      ..['ALL_PROXY'] = proxyText
      ..['http_proxy'] = proxyText
      ..['https_proxy'] = proxyText
      ..['all_proxy'] = proxyText;
    proc = await Process.start(exe, ['serve', '--hostname', '127.0.0.1', '--port', '$port'], environment: env);
    proc.stdout.listen((_) {}); // discard CLI output; it may contain local details
    proc.stderr.listen((_) {});
    final base = Uri.parse('http://127.0.0.1:$port');
    if (!await waitHealth(base, proc)) {
      record('health', 'failed', detail: 'cli_start_or_health_failed');
      exitCode = 1;
      return;
    }
    record('health', 'passed');
    try {
      final (code, raw) = await request('GET', base.resolve('/config/providers'));
      if (code != 200) {
        record('model_catalog', 'failed', code: code);
        exitCode = 1;
        return;
      }
      final ids = <String>{};
      collectModelIds(jsonDecode(raw), ids);
      final found = ids.contains(model);
      record('model_catalog', found ? 'passed' : 'failed', detail: found ? 'requested_model_available' : 'requested_model_not_found');
      if (!found) { exitCode = 1; return; }
    } catch (_) {
      record('model_catalog', 'failed', detail: 'catalog_parse_or_request_error');
      exitCode = 1;
      return;
    }
    final nonstream = await generate(base, stream: false, model: model);
    final streaming = await generate(base, stream: true, model: model);
    if (!nonstream || !streaming) exitCode = 1;
  } catch (_) {
    record('preflight', 'failed', detail: 'local_setup_error');
    exitCode = 1;
  } finally {
    proc?.kill();
    await home.delete(recursive: true);
  }
}
