import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/zen.dart';
import 'package:zeroapi/gateway/config.dart';

void main() {
  group('出口代理池解析', () {
    test('空→直连；http/socks5 归一为 findProxy 格式；逗号分隔成池', () {
      UpstreamDef mk(String p) =>
          UpstreamDef(id: 'z', baseUrl: 'https://x/v1', proxy: p);
      expect(mk('').proxyPool, isEmpty);
      expect(mk('socks5://127.0.0.1:7891').proxyPool, ['SOCKS5 127.0.0.1:7891']);
      expect(mk('http://127.0.0.1:7890').proxyPool, ['PROXY 127.0.0.1:7890']);
      expect(mk('127.0.0.1:7890, socks5://1.2.3.4:1080').proxyPool,
          ['PROXY 127.0.0.1:7890', 'SOCKS5 1.2.3.4:1080']);
    });
  });

  group('Zen 免费档判定', () {
    test('big-pickle 与 *-free 保留，付费模型过滤', () {
      expect(Zen.isFreeModel('big-pickle'), true);
      expect(Zen.isFreeModel('deepseek-v4.1-flash-free'), true);
      expect(Zen.isFreeModel('glm-5.3-flash-free'), true);
      expect(Zen.isFreeModel('claude-opus-4-8'), false);
      expect(Zen.isFreeModel('gpt-5.3-codex'), false);
      expect(Zen.isFreeModel('glm-5.3-flash'), false); // 无 -free 后缀=付费
    });
  });

  group('客户端指纹', () {
    test('会话 id 形状：ses_ + 12 小写hex + 14 base62，低12位 counter≤63', () {
      for (var i = 0; i < 20; i++) {
        final h = Zen.headers('');
        final sid = h['x-opencode-session']!;
        expect(sid.startsWith('ses_'), true);
        final body = sid.substring(4);
        expect(body.length, 26);
        expect(RegExp(r'^[0-9a-f]{12}').hasMatch(body), true);
        expect(
            RegExp(r'^[0-9A-Za-z]{14}$').hasMatch(body.substring(12)), true);
        final low12 = int.parse(body.substring(8, 12), radix: 16) & 0xfff;
        // low12 = 0xfff - counter，counter ∈ [0,63] → low12 ≥ 0xfc0
        expect(low12 >= 0xfc0, true, reason: 'counter>63: $sid');
        expect(h['x-opencode-session-id'], sid);
        expect(h['x-opencode-request']!.startsWith('msg_'), true);
        expect(h['authorization'], 'Bearer public');
      }
    });
    test('自定义 key 覆盖 public', () {
      expect(Zen.headers('sk-xx')['authorization'], 'Bearer sk-xx');
    });
    test('per-request 会话：session 与 request 均逐次唯一（jcleng safest）', () {
      final h1 = Zen.headers('');
      final h2 = Zen.headers('');
      // per-request 模式：每次调用都是全新 ses_（避免单会话堆积请求）
      expect(h1['x-opencode-session'] != h2['x-opencode-session'], true);
      expect(h1['x-opencode-request'] != h2['x-opencode-request'], true);
    });
  });

  group('诱饵工具补齐', () {
    test('空 tools 补齐四个且去重客户端已有的', () {
      final injected = <String>{};
      final list = Zen.ensureFreeTools([
        {
          'type': 'function',
          'function': {'name': 'bash', 'parameters': {}}
        }
      ], injected);
      final names =
          list.map((t) => (t['function'] as Map)['name']).toList();
      expect(names, ['bash', 'glob', 'grep', 'read']);
      expect(injected, {'glob', 'grep', 'read'});
    });
  });

  group('SSE 聚合与非流式还原', () {
    test('文本/推理/usage 聚合，诱饵工具调用整体丢弃', () {
      final chunks = [
        {
          'id': 'c1',
          'created': 1,
          'choices': [
            {
              'index': 0,
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_a',
                    'function': {'name': 'read', 'arguments': '{"p'}
                  }
                ]
              }
            }
          ]
        },
        {
          'choices': [
            {
              'index': 0,
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': '"x"}'}
                  },
                  {
                    'index': 1,
                    'id': 'call_b',
                    'function': {'name': 'my_tool', 'arguments': '{}'}
                  }
                ]
              }
            }
          ]
        },
        {
          'choices': [
            {'index': 0, 'delta': {'content': 'he'}, 'finish_reason': null},
            {'index': 0, 'delta': {'content': 'llo'}},
            {'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'}
          ]
        },
        {
          'usage': {'prompt_tokens': 7, 'completion_tokens': 3}
        },
      ];
      final agg = Zen.aggregate(chunks, 'big-pickle', {'glob', 'grep', 'read'});
      final msg = (agg['choices'] as List).first['message'] as Map;
      expect(msg['content'], 'hello');
      final tcs = msg['tool_calls'] as List;
      expect(tcs.length, 1);
      expect((tcs.first['function'] as Map)['name'], 'my_tool');
      expect((tcs.first['function'] as Map)['arguments'], '{}');
      expect((agg['choices'] as List).first['finish_reason'], 'tool_calls');
      expect(agg['usage'], {'prompt_tokens': 7, 'completion_tokens': 3});
    });
  });

  group('流式诱饵过滤', () {
    test('诱饵增量被丢弃，正常工具与 content 透传', () {
      final injected = {'glob', 'grep', 'read'};
      final decoy = <int, bool>{};
      final c1 = Zen.filterDecoyChunk({
        'choices': [
          {
            'index': 0,
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'x',
                  'function': {'name': 'grep', 'arguments': ''}
                }
              ]
            }
          }
        ]
      }, injected, decoyIndex: decoy);
      expect(c1, isNull); // 整条都是诱饵 → 丢弃
      final c2 = Zen.filterDecoyChunk({
        'choices': [
          {
            'index': 0,
            'delta': {
              'content': 'hi',
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'arguments': '{"p"'} // grep 的后续增量
                },
                {
                  'index': 1,
                  'id': 'y',
                  'function': {'name': 'client_tool', 'arguments': '{}'}
                }
              ]
            }
          }
        ]
      }, injected, decoyIndex: decoy);
      expect(c2, isNotNull);
      final d = (c2!['choices'] as List).first['delta'] as Map;
      expect(d['content'], 'hi');
      expect((d['tool_calls'] as List).length, 1);
      expect(((d['tool_calls'] as List).first['function'] as Map)['name'],
          'client_tool');
    });
  });
}
