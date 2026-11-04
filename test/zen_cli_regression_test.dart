import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/opencode_api.dart';

void main() {
  test('CLI egress is configurable while local hub control stays direct', () {
    final cli = UpstreamDef(
      id: 'zen',
      type: 'managed',
      label: 'Zen',
      baseUrl: 'http://127.0.0.1:4097',
    );
    final hub = UpstreamDef(
      id: 'workbuddy',
      type: 'managed',
      label: 'Hub',
      baseUrl: 'http://127.0.0.1:8788',
    );
    expect(cli.supportsUpstreamEgress, isTrue);
    expect(hub.supportsUpstreamEgress, isFalse);
  });

  test(
    'nested session events are isolated and completed session is deleted',
    () async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      final api = OpenCodeApi('http://127.0.0.1:${server.port}');
      HttpResponse? events;
      final deleted = Completer<void>();
      final eventsSent = Completer<void>();
      final trace = <String>[];
      void emit(String type, Map<String, dynamic> properties) {
        trace.add('emit:$type');
        events!.add(
          utf8.encode(
            'data: ${jsonEncode({'type': type, 'properties': properties})}\n\n',
          ),
        );
      }

      server.listen((req) async {
        trace.add('${req.method} ${req.uri.path}');
        if (req.uri.path == '/experimental/tool/ids') {
          req.response.headers.contentType = ContentType.json;
          req.response.write('["bash","read","question"]');
          await req.response.close();
          return;
        }
        if (req.uri.path == '/event') {
          events = req.response;
          events!.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          events!.write(
            'data: {"type":"server.connected","properties":{}}\n\n',
          );
          await events!.flush();
          await eventsSent.future;
          await events!.close();
          return;
        }
        await req.drain<void>();
        req.response.headers.contentType = ContentType.json;
        if (req.method == 'DELETE') {
          deleted.complete();
          req.response.write('{}');
        } else if (req.uri.path == '/session') {
          req.response.write('{"id":"own"}');
        } else {
          emit('message.updated', {
            'info': {
              'sessionID': 'other',
              'id': 'foreign',
              'role': 'assistant',
            },
          });
          emit('message.part.updated', {
            'part': {
              'sessionID': 'other',
              'id': 'bad',
              'messageID': 'foreign',
              'type': 'text',
              'text': 'LEAK',
            },
          });
          emit('message.updated', {
            'info': {'sessionID': 'own', 'id': 'answer', 'role': 'assistant'},
          });
          emit('message.part.updated', {
            'part': {
              'sessionID': 'own',
              'id': 'good',
              'messageID': 'answer',
              'type': 'text',
              'text': 'OK',
            },
          });
          emit('session.idle', {'sessionID': 'own'});
          await events!.flush();
          eventsSent.complete();
          req.response.write('{"info":{"tokens":{"input":3,"output":1}}}');
        }
        await req.response.close();
      });
      try {
        final answer = await api
            .chat(
              model: 'big-pickle',
              messages: [
                {'role': 'user', 'content': 'ping'},
              ],
            )
            .join();
        expect(answer, 'OK', reason: 'mock request/event trace: $trace');
        await deleted.future.timeout(const Duration(seconds: 3));
      } finally {
        api.close();
        await server.close(force: true);
      }
    },
  );
}
