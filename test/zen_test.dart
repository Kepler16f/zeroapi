import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/zen.dart';
import 'package:zeroapi/gateway/config.dart';

void main() {
  group('出口代理池解析', () {
    test('开关关/空→直连；http/socks5 归一为 findProxy 格式；逗号分隔成池', () {
      UpstreamDef mk(String p, {bool on = true}) => UpstreamDef(
          id: 'z', baseUrl: 'https://x/v1', proxy: p, proxyEnabled: on);
      expect(mk('').proxyPool, isEmpty);
      expect(mk('http://127.0.0.1:7890', on: false).proxyPool, isEmpty);
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

  group('400 自愈 healBody', () {
    test('未知字段：递归剥离顶层与 messages 内字段', () {
      final body = <String, dynamic>{
        'model': 'm',
        'enable_thinking': true,
        'messages': [
          {'role': 'user', 'content': 'hi', 'cache_tag': 'x'},
        ],
      };
      final fix = Zen.healBody(
          'invalid request body: json: unknown field "enable_thinking"', body);
      expect(fix, contains('enable_thinking'));
      expect(body.containsKey('enable_thinking'), false);
      final fix2 =
          Zen.healBody('json: unknown field "cache_tag"', body);
      expect(fix2, contains('cache_tag'));
      expect(
          (body['messages'] as List).first.containsKey('cache_tag'), false);
      // 字段不存在时不谎报修复
      expect(Zen.healBody('json: unknown field "nope"', body), isNull);
    });

    test('reasoning_content 回传：为缺失的 assistant 注入空串', () {
      final body = <String, dynamic>{
        'messages': [
          {'role': 'user', 'content': 'hi'},
          {'role': 'assistant', 'content': 'hello'},
          {'role': 'assistant', 'content': 'x', 'reasoning_content': 'kept'},
        ],
      };
      final fix = Zen.healBody(
          'The `reasoning_content` in the thinking mode must be passed back to the API.',
          body);
      expect(fix, contains('reasoning_content'));
      final msgs = body['messages'] as List;
      expect(msgs[1]['reasoning_content'], '');
      expect(msgs[2]['reasoning_content'], 'kept');
    });

    test('tool_call arguments 归一化为合法 JSON 对象字符串', () {
      final body = <String, dynamic>{
        'messages': [
          {
            'role': 'assistant',
            'tool_calls': [
              {
                'function': {'name': 'f', 'arguments': ''}
              },
              {
                'function': {'name': 'g', 'arguments': '{"a":1}'}
              },
              {
                'function': {'name': 'h', 'arguments': '[1,2]'}
              },
            ]
          },
        ],
      };
      final fix = Zen.healBody(
          'Assistant tool call function.arguments must be a JSON object', body);
      expect(fix, contains('arguments'));
      final tcs = ((body['messages'] as List).first['tool_calls'] as List);
      expect(tcs[0]['function']['arguments'], '{}');
      expect(tcs[1]['function']['arguments'], '{"a":1}');
      expect(tcs[2]['function']['arguments'], '{}');
    });

    test('不相关错误不触发修正', () {
      expect(Zen.healBody('some other error', {'messages': []}), isNull);
    });
  });

  group('工具名截断与回映', () {
    final longName = 'mcp__plugin__${'x' * 57}'; // 70 字符
    final shortTool = {
      'type': 'function',
      'function': {'name': 'bash', 'parameters': {}}
    };
    Map<String, dynamic> mkBody() => {
          'model': 'big-pickle',
          'tools': [
            {
              'type': 'function',
              'function': {'name': longName, 'parameters': {}}
            },
            shortTool,
          ],
        };

    test('超长名截断为 前缀#hash6（恰 64），短名原样保留不入 map', () {
      expect(longName.length, 70);
      final body = mkBody();
      final origList = body['tools'];
      final map = Zen.shortenToolNames(body);
      final tools = body['tools'] as List;
      expect(tools.length, 2);

      final sn = (tools[0]['function'] as Map)['name'] as String;
      expect(sn.length, 64);
      expect(sn, matches(RegExp(r'#[0-9a-f]{6}$')));
      expect(sn.startsWith('mcp__plugin__'), true);
      expect(map[sn], longName);

      // copy-on-write：有改动才换 list，未改的工具项复用原对象
      expect(body['tools'], isNot(same(origList)));
      expect(tools[1], same(shortTool));
      expect((tools[1]['function'] as Map)['name'], 'bash');
      expect(map.values, isNot(contains('bash')));

      // 无超长名 → 返回空 map 且不动原 list
      final flatList = <Object>[shortTool];
      final flat = <String, dynamic>{'tools': flatList};
      expect(Zen.shortenToolNames(flat), isEmpty);
      expect(flat['tools'], same(flatList));
    });

    test('确定性：两个独立 body 的截断名完全一致', () {
      final a = Zen.shortenToolNames(mkBody());
      final b = Zen.shortenToolNames(mkBody());
      expect(a.keys.length, 1);
      expect(a, b);
      expect((b.keys.single).length, 64);
    });

    test('历史 tool_calls 与 tool_choice 同步改写为同一截断名', () {
      final body = mkBody();
      body['messages'] = [
        {
          'role': 'assistant',
          'tool_calls': [
            {'id': 'c1', 'function': {'name': longName, 'arguments': '{}'}}
          ]
        },
      ];
      body['tool_choice'] = {'type': 'function', 'function': {'name': longName}};

      final map = Zen.shortenToolNames(body);
      final sn = map.keys.single;

      final tc = ((body['messages'] as List).first['tool_calls'] as List).first;
      expect(tc['id'], 'c1');
      final tcFn = tc['function'] as Map;
      expect(tcFn['name'], sn);
      expect(tcFn['arguments'], '{}');

      final tcf = body['tool_choice'] as Map;
      expect(tcf['type'], 'function');
      expect((tcf['function'] as Map)['name'], sn);
    });

    test('restore 把流式 delta 与非流式 message 的 tool_calls 换回原名', () {
      final map = Zen.shortenToolNames(mkBody());
      final sn = map.keys.single;

      final chunk = {
        'choices': [
          {
            'index': 0,
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'c1',
                  'function': {'name': sn, 'arguments': '{'}
                }
              ]
            }
          }
        ]
      };
      Zen.restoreToolNames(chunk, map);
      final dFn = (((chunk['choices'] as List).first['delta'] as Map)['tool_calls']
          as List)
          .first['function'] as Map;
      expect(dFn['name'], longName);
      expect(dFn['arguments'], '{');

      final msgChunk = {
        'choices': [
          {
            'index': 0,
            'message': {
              'role': 'assistant',
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'c2',
                  'function': {'name': sn, 'arguments': '{}'}
                }
              ]
            }
          }
        ]
      };
      Zen.restoreToolNames(msgChunk, map);
      final mFn = (((msgChunk['choices'] as List).first['message'] as Map)['tool_calls']
          as List)
          .first['function'] as Map;
      expect(mFn['name'], longName);
    });

    test('空 map 不动内容，坏 chunk 不抛异常，未知名字保持原名', () {
      final map = Zen.shortenToolNames(mkBody());
      final sn = map.keys.single;

      final frozen = {
        'choices': [
          {
            'index': 0,
            'delta': {
              'tool_calls': [
                {'index': 0, 'function': {'name': sn}}
              ]
            }
          }
        ]
      };
      Zen.restoreToolNames(frozen, {});
      final fFn = (((frozen['choices'] as List).first['delta'] as Map)['tool_calls']
          as List)
          .first['function'] as Map;
      expect(fFn['name'], sn);

      expect(
          () => Zen.restoreToolNames({'foo': 1}, {'a': 'b'}), returnsNormally);
      expect(
          () => Zen.restoreToolNames({'choices': 'nope'}, {'a': 'b'}),
          returnsNormally);
      expect(
          () => Zen.restoreToolNames({'choices': [null, 5, 3.14]}, {'a': 'b'}),
          returnsNormally);

      final unknown = {
        'choices': [
          {
            'index': 0,
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'function': {'name': 'other_tool', 'arguments': '{}'}
                }
              ]
            }
          }
        ]
      };
      Zen.restoreToolNames(unknown, map);
      final uFn = (((unknown['choices'] as List).first['delta'] as Map)['tool_calls']
          as List)
          .first['function'] as Map;
      expect(uFn['name'], 'other_tool');
      expect(uFn['arguments'], '{}');
    });
  });
}
