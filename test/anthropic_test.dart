import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/anthropic.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/modelsdev.dart';
import 'package:zeroapi/gateway/proxy.dart';
import 'package:zeroapi/gateway/upstream.dart';

void main() {
  group('AnthropicAdapter 请求转换', () {
    test('system + 多轮消息 → OpenAI messages', () {
      final oai = AnthropicAdapter.toOpenAIRequest({
        'model': 'm',
        'system': '你是助手',
        'max_tokens': 100,
        'messages': [
          {'role': 'user', 'content': '你好'},
          {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': '回答'},
            ],
          },
          {'role': 'user', 'content': '继续'},
        ],
      });
      expect(oai['model'], 'm');
      expect(oai['max_tokens'], 100);
      final msgs = oai['messages'] as List;
      expect(msgs.first, {'role': 'system', 'content': '你是助手'});
      expect(msgs[1], {'role': 'user', 'content': '你好'});
      expect(msgs[2]['content'], '回答');
      expect(msgs.length, 4);
    });

    test('tool_use / tool_result 块 → OpenAI tool_calls / tool 消息', () {
      final oai = AnthropicAdapter.toOpenAIRequest({
        'model': 'm',
        'messages': [
          {
            'role': 'assistant',
            'content': [
              {
                'type': 'tool_use',
                'id': 't1',
                'name': 'get_weather',
                'input': {'city': 'Beijing'},
              },
            ],
          },
          {
            'role': 'user',
            'content': [
              {'type': 'tool_result', 'tool_use_id': 't1', 'content': '晴'},
            ],
          },
        ],
      });
      final msgs = oai['messages'] as List;
      final asst = msgs.firstWhere((m) => m['role'] == 'assistant');
      expect(asst['tool_calls'][0]['function']['name'], 'get_weather');
      expect(jsonDecode(asst['tool_calls'][0]['function']['arguments']), {
        'city': 'Beijing',
      });
      final tool = msgs.firstWhere((m) => m['role'] == 'tool');
      expect(tool['tool_call_id'], 't1');
      expect(tool['content'], '晴');
    });

    test('tools 定义 + stop_sequences → OpenAI tools/stop', () {
      final oai = AnthropicAdapter.toOpenAIRequest({
        'model': 'm',
        'messages': [
          {'role': 'user', 'content': 'x'},
        ],
        'tools': [
          {
            'name': 'f',
            'description': 'd',
            'input_schema': {'type': 'object'},
          },
        ],
        'stop_sequences': ['END'],
      });
      final tool = (oai['tools'] as List).first as Map;
      expect(tool['type'], 'function');
      expect(tool['function']['name'], 'f');
      expect(tool['function']['parameters'], {'type': 'object'});
      expect(oai['stop'], ['END']);
    });

    test('assistant thinking 块 → 映射为 reasoning_content 回传', () {
      final oai = AnthropicAdapter.toOpenAIRequest({
        'model': 'm',
        'messages': [
          {'role': 'user', 'content': 'hi'},
          {
            'role': 'assistant',
            'content': [
              {'type': 'thinking', 'thinking': '内部推理'},
              {'type': 'text', 'text': '回答'},
            ],
          },
        ],
      });
      final msgs = oai['messages'] as List;
      final assistant = msgs.last as Map;
      expect(assistant['role'], 'assistant');
      expect(assistant['content'], '回答');
      expect(assistant['reasoning_content'], '内部推理');
    });
  });

  group('AnthropicAdapter 响应转换', () {
    test('OpenAI 文本响应 → Anthropic message', () {
      final a = AnthropicAdapter.toAnthropicResponse({
        'id': 'chatcmpl-abc',
        'model': 'm',
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'Hi'},
            'finish_reason': 'stop',
          },
        ],
        'usage': {'prompt_tokens': 5, 'completion_tokens': 2},
      });
      expect(a['type'], 'message');
      expect(a['role'], 'assistant');
      expect(a['id'], startsWith('msg_'));
      expect((a['content'] as List).first['type'], 'text');
      expect((a['content'] as List).first['text'], 'Hi');
      expect(a['stop_reason'], 'end_turn');
      expect(a['usage'], {'input_tokens': 5, 'output_tokens': 2});
    });

    test('OpenAI tool_calls 响应 → Anthropic tool_use 块', () {
      final a = AnthropicAdapter.toAnthropicResponse({
        'id': 'x',
        'model': 'm',
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': null,
              'tool_calls': [
                {
                  'id': 'c1',
                  'type': 'function',
                  'function': {'name': 'f', 'arguments': '{"a":1}'},
                },
              ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
        'usage': {'prompt_tokens': 1, 'completion_tokens': 1},
      });
      final block = (a['content'] as List).first as Map;
      expect(block['type'], 'tool_use');
      expect(block['name'], 'f');
      expect(block['input'], {'a': 1});
      expect(a['stop_reason'], 'tool_use');
    });

    test('finish_reason length → max_tokens', () {
      final a = AnthropicAdapter.toAnthropicResponse({
        'id': 'x',
        'model': 'm',
        'choices': [
          {
            'message': {'content': 't'},
            'finish_reason': 'length',
          },
        ],
        'usage': {},
      });
      expect(a['stop_reason'], 'max_tokens');
    });
  });

  test('Anthropic 流式转换器产出合法事件序列', () {
    final t = AnthropicAdapter.streamTransformer('m');
    final e1 = t.feed(
      jsonEncode({
        'choices': [
          {
            'delta': {'content': 'Hel'},
          },
        ],
      }),
    );
    final e2 = t.feed(
      jsonEncode({
        'choices': [
          {
            'delta': {'content': 'lo'},
          },
        ],
      }),
    );
    final e3 = t.finish();
    final all = [...e1, ...e2, ...e3].join();
    expect(all, contains('message_start'));
    expect(all, contains('content_block_start'));
    expect(all, contains('"text_delta","text":"Hel"'));
    expect(all, contains('"text_delta","text":"lo"'));
    expect(all, contains('content_block_stop'));
    expect(all, contains('message_delta'));
    expect(all, contains('message_stop'));
    // 首事件必须是 message_start
    expect(e1.first, startsWith('event: message_start'));
  });

  group('/v1/messages 端到端', () {
    late HttpServer fake;
    late ProxyServer proxy;
    late String baseUrl;
    late Directory usageDir;
    final client = HttpClient();

    setUp(() async {
      usageDir = await Directory.systemTemp.createTemp('zeroapi-ant-test-');
      fake = await HttpServer.bind('127.0.0.1', 0);
      baseUrl = 'http://127.0.0.1:${fake.port}/v1';
      fake.listen((req) async {
        final path = req.uri.path;
        if (path.endsWith('/models')) {
          req.response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'data': [
                  {'id': 'mm', 'owned_by': 'opencode'},
                ],
              }),
            );
        } else if (path.endsWith('/chat/completions')) {
          final body = jsonDecode(await utf8.decodeStream(req));
          req.response
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'id': 'chatcmpl-1',
                'model': body['model'],
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content':
                          'echo:${(body['messages'] as List).last['content']}',
                    },
                    'finish_reason': 'stop',
                  },
                ],
                'usage': {'prompt_tokens': 3, 'completion_tokens': 4},
              }),
            );
        }
        await req.response.close();
      });
      final rt = UpstreamRuntime(UpstreamDef(id: 'fake', baseUrl: baseUrl));
      await rt.probe();
      proxy = ProxyServer(
        '127.0.0.1',
        0,
        'sk-gw',
        ModelRegistry()..rebuild([rt]),
        usageDir: usageDir.path,
      );
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
      await fake.close(force: true);
      try {
        usageDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('非流式 messages 请求返回 Anthropic 结构', () async {
      final req = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:${proxy.boundPort}/v1/messages'),
      );
      req.headers.set('x-api-key', 'sk-gw');
      req.headers.set('anthropic-version', '2023-06-01');
      req.headers.contentType = ContentType.json;
      req.add(
        utf8.encode(
          jsonEncode({
            'model': 'fake/mm',
            'max_tokens': 50,
            'messages': [
              {'role': 'user', 'content': 'hi'},
            ],
          }),
        ),
      );
      final resp = await req.close();
      expect(resp.statusCode, 200);
      final j =
          jsonDecode(await utf8.decodeStream(resp)) as Map<String, dynamic>;
      expect(j['type'], 'message');
      expect(j['role'], 'assistant');
      expect((j['content'] as List).first['type'], 'text');
      expect((j['content'] as List).first['text'], 'echo:hi');
      expect(j['usage'], {'input_tokens': 3, 'output_tokens': 4});
    });

    test('anthropicEnabled=false 时 /v1/messages 返回 404', () async {
      final rt = UpstreamRuntime(UpstreamDef(id: 'x', baseUrl: baseUrl));
      final p2 = ProxyServer(
        '127.0.0.1',
        0,
        'k',
        ModelRegistry()..rebuild([rt]),
        anthropicEnabled: false,
        usageDir: usageDir.path,
      );
      await p2.start();
      final req = await client.openUrl(
        'POST',
        Uri.parse('http://127.0.0.1:${p2.boundPort}/v1/messages'),
      );
      req.headers.set('Authorization', 'Bearer k');
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'model': 'x/mm', 'messages': []})));
      final resp = await req.close();
      await resp.drain();
      expect(resp.statusCode, 404);
      await p2.stop();
    });
  });

  test('ModelInfo.fromMaps 合并上游字段优先与 models.dev 兜底', () {
    final info = ModelInfo.fromMaps(
      {'id': 'mm'},
      ModelsDev.instance.lookup('opencode', 'nonexistent-model') ??
          {
            'limit': {'context': 200000, 'output': 8000},
            'modalities': {
              'input': ['text', 'image'],
            },
            'reasoning': true,
            'cost': {'input': 0, 'output': 0},
          },
    );
    expect(info.contextWindow, 200000);
    expect(info.maxOutputTokens, 8000);
    expect(info.inputModalities, containsAll(['text', 'image']));
    expect(info.reasoning, true);
    expect(info.free, true);
  });
}
