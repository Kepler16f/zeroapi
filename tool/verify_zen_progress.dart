// Explicit live acceptance against an already-running local CLI. Does not
// restart it, change its proxy/settings, or print prompts/response contents.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zeroapi/gateway/opencode_api.dart';

Future<void> main(List<String> args) async {
  final base = args.isEmpty ? 'http://127.0.0.1:4097' : args.first;
  final model = args.length > 1 ? args[1] : 'deepseek-v4.1-flash-free';
  final api = OpenCodeApi(base);
  final sw = Stopwatch()..start();
  var chars = 0, chunks = 0;
  int? firstMs;
  try {
    await for (final piece in api.chat(
      model: model,
      messages: [
        {
          'role': 'user',
          'content':
              '请用中文解释为什么 HTTP 网关的首次输出超时和生成空闲超时应该分开，'
              '给出三个具体例子，每例约100字。只生成解释，不使用任何工具。',
        },
      ],
    )) {
      firstMs ??= sw.elapsedMilliseconds;
      chars += piece.length;
      chunks++;
    }
    stdout.writeln(
      jsonEncode({
        'check': 'real_cli_generation',
        'model': model,
        'ok': chars > 0,
        'elapsed_ms': sw.elapsedMilliseconds,
        'first_text_ms': firstMs,
        'characters': chars,
        'chunks': chunks,
        'input_tokens': api.lastUsage.input,
        'output_tokens': api.lastUsage.output,
        'cached_read': api.cachedReadTokens,
      }),
    );
    if (chars == 0) exitCode = 1;
  } catch (e) {
    stdout.writeln(
      jsonEncode({
        'check': 'real_cli_generation',
        'model': model,
        'ok': false,
        'elapsed_ms': sw.elapsedMilliseconds,
        'error': e.toString(),
      }),
    );
    exitCode = 1;
  } finally {
    api.close();
  }
}
