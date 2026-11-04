import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/opencode_api.dart';

class CliFixture {
  late HttpServer server;
  late OpenCodeApi api;
  HttpResponse? events;
  final deleted = Completer<void>();
  final finished = Completer<void>();
  final cleanup = <String>[];
  Map<String, dynamic>? sessionBody;
  Map<String, dynamic>? messageBody;
  late Future<void> Function(HttpRequest) generate;

  Future<void> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    api = OpenCodeApi('http://127.0.0.1:${server.port}');
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/event') {
        events = req.response;
        events!.bufferOutput = false;
        events!.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        events!.write('data: {"type":"server.connected","properties":{}}\n\n');
        await events!.flush();
        await finished.future;
      } else if (req.uri.path == '/experimental/tool/ids') {
        req.response.write('["bash","question","mcp_custom"]');
      } else if (req.uri.path == '/session') {
        sessionBody =
            jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
        req.response.write('{"id":"ses_own"}');
      } else if (req.uri.path.endsWith('/abort')) {
        cleanup.add('abort');
        req.response.write('true');
      } else if (req.method == 'DELETE') {
        cleanup.add('delete');
        req.response.write('true');
        if (!finished.isCompleted) finished.complete();
        if (!deleted.isCompleted) deleted.complete();
      } else {
        messageBody =
            jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
        await generate(req);
      }
      try {
        await req.response.close();
      } catch (_) {}
    });
  }

  Future<void> emit(String type, Map<String, dynamic> props) async {
    events!.add(
      utf8.encode(
        'data: ${jsonEncode({
          'type': type,
          'properties': {'sessionID': 'ses_own', ...props},
        })}\n\n',
      ),
    );
  }

  Future<void> assistant({String kind = 'text', String text = ''}) async {
    await emit('message.updated', {
      'info': {'id': 'msg_own', 'role': 'assistant'},
    });
    await emit('message.part.updated', {
      'part': {
        'id': 'prt_own',
        'messageID': 'msg_own',
        'type': kind,
        'text': text,
      },
    });
  }

  Future<void> delta(String text) => emit('message.part.delta', {
    'messageID': 'msg_own',
    'partID': 'prt_own',
    'field': 'text',
    'delta': text,
  });

  Stream<String> chat() => api.chat(
    model: 'big-pickle',
    messages: [
      {'role': 'user', 'content': 'hi'},
    ],
  );

  Future<void> dispose() async {
    api.close();
    if (!finished.isCompleted) finished.complete();
    await server.close(force: true);
  }
}

void main() {
  late CliFixture cli;
  late Duration initial, idle, grace;
  setUp(() async {
    initial = OpenCodeApi.stallTimeout;
    idle = OpenCodeApi.generationIdleTimeout;
    grace = OpenCodeApi.completionGrace;
    OpenCodeApi.stallTimeout = const Duration(milliseconds: 500);
    OpenCodeApi.generationIdleTimeout = const Duration(milliseconds: 1000);
    OpenCodeApi.completionGrace = const Duration(milliseconds: 100);
    cli = CliFixture();
    await cli.start();
  });
  tearDown(() async {
    await cli.dispose();
    OpenCodeApi.stallTimeout = initial;
    OpenCodeApi.generationIdleTimeout = idle;
    OpenCodeApi.completionGrace = grace;
  });

  test(
    'delta generation exceeds initial deadline and deduplicates final snapshot',
    () async {
      cli.generate = (req) async {
        await cli.assistant();
        for (final word in ['one', ' two', ' three', ' four']) {
          await cli.delta(word);
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
        await cli.assistant(text: 'one two three four');
        await cli.emit('session.idle', {});
        req.response.write(
          '{"info":{"tokens":{"input":4,"output":8}},"parts":[]}',
        );
      };
      expect(await cli.chat().join(), 'one two three four');
      expect(cli.api.lastUsage.output, 8);
      expect(cli.cleanup, ['delete']);
      expect(cli.sessionBody!['permission'], [
        {'permission': '*', 'pattern': '*', 'action': 'deny'},
      ]);
      expect(
        (cli.messageBody!['tools'] as Map).values.every((v) => v == false),
        isTrue,
      );
      expect(cli.messageBody!['tools']['mcp_custom'], isFalse);
    },
  );

  test(
    'reasoning delta refreshes generation window without leaking thoughts',
    () async {
      cli.generate = (req) async {
        await cli.assistant(kind: 'reasoning');
        for (var i = 0; i < 4; i++) {
          await cli.delta('private thought');
          await Future<void>.delayed(const Duration(milliseconds: 350));
        }
        await cli.emit('message.part.updated', {
          'part': {
            'id': 'answer',
            'messageID': 'msg_own',
            'type': 'text',
            'text': 'OK',
          },
        });
        await cli.emit('session.idle', {});
        req.response.write('{"info":{},"parts":[]}');
      };
      expect(await cli.chat().join(), 'OK');
    },
  );

  test('pause after first text may exceed initial deadline', () async {
    cli.generate = (req) async {
      await cli.assistant(text: 'first');
      await Future<void>.delayed(const Duration(milliseconds: 650));
      await cli.delta(' last');
      await cli.emit('session.idle', {});
      req.response.write('{"info":{},"parts":[]}');
    };
    expect(await cli.chat().join(), 'first last');
  });

  test(
    'repeated snapshots and busy events do not conceal a real stall',
    () async {
      Timer? timer;
      cli.generate = (req) async {
        await cli.assistant(text: 'partial');
        timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
          unawaited(
            cli.emit('session.status', {
              'status': {'type': 'busy'},
            }),
          );
          unawaited(
            cli.emit('message.part.updated', {
              'part': {
                'id': 'prt_own',
                'messageID': 'msg_own',
                'type': 'text',
                'text': 'partial',
              },
            }),
          );
        });
        await cli.finished.future;
        timer?.cancel();
      };
      final received = <String>[];
      try {
        await expectLater(
          cli.chat().map((v) {
            received.add(v);
            return v;
          }).drain<void>(),
          throwsA(
            isA<OpenCodeUpstreamError>().having(
              (e) => e.isStall,
              'stall',
              isTrue,
            ),
          ),
        );
        await cli.deleted.future.timeout(const Duration(seconds: 3));
        expect(received.join(), 'partial');
        expect(cli.cleanup, ['abort', 'delete']);
      } finally {
        timer?.cancel();
      }
    },
  );

  test(
    'permission wait fails immediately and actually aborts before delete',
    () async {
      cli.generate = (req) async {
        await cli.assistant(text: 'checking');
        await cli.emit('permission.v2.asked', {'id': 'per_hidden'});
        await cli.finished.future;
      };
      await expectLater(
        cli.chat().drain<void>(),
        throwsA(
          isA<OpenCodeUpstreamError>().having(
            (e) => e.message,
            'reason',
            contains('权限'),
          ),
        ),
      );
      await cli.deleted.future.timeout(const Duration(seconds: 3));
      expect(cli.cleanup, ['abort', 'delete']);
    },
  );

  test('consumer cancellation aborts and releases session promptly', () async {
    cli.generate = (req) async {
      await cli.assistant(text: 'first');
      await cli.finished.future;
    };
    final it = StreamIterator(cli.chat());
    expect(await it.moveNext(), isTrue);
    await it.cancel();
    await cli.deleted.future.timeout(const Duration(seconds: 3));
    expect(cli.cleanup, ['abort', 'delete']);
  });

  test('idle ends request even if synchronous HTTP never returns', () async {
    cli.generate = (req) async {
      await cli.assistant(text: 'OK');
      await cli.emit('message.updated', {
        'info': {
          'id': 'msg_own',
          'role': 'assistant',
          'tokens': {
            'input': 2,
            'output': 1,
            'cache': {'read': 3, 'write': 4},
          },
        },
      });
      await cli.emit('session.idle', {});
      await cli.finished.future;
    };
    expect(await cli.chat().join().timeout(const Duration(seconds: 3)), 'OK');
    expect(cli.api.lastUsage.input, 9);
    expect(cli.api.cachedReadTokens, 3);
    expect(cli.cleanup, ['delete']);
  });
}
