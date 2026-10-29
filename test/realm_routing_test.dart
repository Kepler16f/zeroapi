// WorkBuddy 号池「国内/国际双出口」路由测试：
//  1) _probeCatalog 按 ?realm= 记录单区独占模型的出口区（两区共有的不记，
//     交给 hub 的全局开关判定）；
//  2) 转发独占模型时带 X-Realm，共有模型不带；
//  3) /v1/models 的 zeroapi.realm 暴露出口区。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/config.dart';
import 'package:zeroapi/gateway/proxy.dart';
import 'package:zeroapi/gateway/upstream.dart';

void main() {
  late HttpServer hub;
  late UpstreamRuntime runtime;
  late ProxyServer proxy;
  late List<String?> seenRealms; // 每次 chat 请求收到的 X-Realm
  // 并发测试用：非 null 时挂住 chat 响应，等两个请求都到齐再一起放行
  Completer<void>? barrier;
  var barrierCount = 0;
  // 模拟号池在 cn 区把共有模型限流一次（带 Retry-After: 60）
  var failCnHy3Once = false;
  // 模拟号池当日额度耗尽：429 且 Retry-After 以小时计（超过 75s 上限 → 如实返回）
  var quota429 = false;
  final client = HttpClient();

  // 模拟号池目录：intl 独有 gpt-5.5 / gemini-3.5-flash；cn 独有 deepseek-v4-pro；
  // hy3 两区共有。
  const intlModels = ['hy3', 'gpt-5.5', 'gemini-3.5-flash'];
  const cnModels = ['hy3', 'deepseek-v4-pro'];

  setUp(() async {
    seenRealms = [];
    failCnHy3Once = false;
    quota429 = false;
    hub = await HttpServer.bind('127.0.0.1', 0);
    hub.listen((req) async {
      final path = req.uri.path;
      if (path.endsWith('/models')) {
        final realm = req.uri.queryParameters['realm'];
        final ids = switch (realm) {
          'intl' => intlModels,
          'cn' => cnModels,
          _ => <String>[],
        };
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'data': [
                for (final id in ids) {'id': id},
              ],
            }),
          );
        await req.response.close();
        return;
      }
      if (path.endsWith('/chat/completions')) {
        final realm = req.headers.value('X-Realm');
        seenRealms.add(realm);
        final body = jsonDecode(await utf8.decodeStream(req));
        if (quota429 && realm == 'cn') {
          // 号池账号当日额度耗尽的形态：429 + Retry-After 以小时计
          req.response
            ..statusCode = 429
            ..headers.set('Retry-After', '18000')
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'error': {'message': 'credit limit reached; resets at midnight'},
              }),
            );
          await req.response.close();
          return;
        }
        if (failCnHy3Once && realm == 'cn') {
          failCnHy3Once = false;
          req.response
            ..statusCode = 429
            ..headers.set('Retry-After', '60')
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'error': {
                  'message': 'upstream rate limit reached for this model',
                },
              }),
            );
          await req.response.close();
          return;
        }
        final b = barrier;
        if (b != null) {
          if (++barrierCount >= 2 && !b.isCompleted) b.complete();
          await b.future;
        }
        req.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'ok ${body['model']}'},
                },
              ],
              'usage': {'prompt_tokens': 1, 'completion_tokens': 1},
            }),
          );
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    final def = UpstreamDef(
      id: 'workbuddy',
      type: 'managed',
      label: 'WorkBuddy',
      baseUrl: 'http://127.0.0.1:${hub.port}/v1',
      catalogPaths: const ['/models?realm=intl', '/models?realm=cn'],
    );
    runtime = UpstreamRuntime(def);
    final ok = await runtime.probe();
    expect(ok, isTrue);
    proxy = ProxyServer(
      '127.0.0.1',
      0,
      'sk-gw',
      ModelRegistry()..rebuild([runtime]),
    );
    await proxy.start();
  });

  tearDown(() async {
    await proxy.stop();
    await hub.close(force: true);
  });

  Future<HttpClientResponse> chat(String model, {String content = 'hi'}) async {
    final req = await client.openUrl(
      'POST',
      Uri.parse('http://127.0.0.1:${proxy.boundPort}/v1/chat/completions'),
    );
    req.headers.set('Authorization', 'Bearer sk-gw');
    req.headers.contentType = ContentType.json;
    req.add(
      utf8.encode(
        jsonEncode({
          'model': model,
          'messages': [
            {'role': 'user', 'content': content},
          ],
        }),
      ),
    );
    return req.close();
  }

  test('探测记录单区独占模型的出口区；两区共有的不记', () {
    expect(runtime.modelRealms['gpt-5.5'], 'intl');
    expect(runtime.modelRealms['gemini-3.5-flash'], 'intl');
    expect(runtime.modelRealms['deepseek-v4-pro'], 'cn');
    expect(
      runtime.modelRealms.containsKey('hy3'),
      isFalse,
      reason: '两区目录都出现 → 不强加 X-Realm，交给 hub 全局开关',
    );
  });

  test('转发国际独占模型带 X-Realm: intl', () async {
    final resp = await chat('workbuddy/gpt-5.5');
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    expect(seenRealms, ['intl']);
  });

  test('转发国内独占模型带 X-Realm: cn', () async {
    final resp = await chat('workbuddy/deepseek-v4-pro');
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    expect(seenRealms, ['cn']);
  });

  test('共有模型不带 X-Realm（跟随号池全局开关）', () async {
    final resp = await chat('workbuddy/hy3');
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    expect(seenRealms, [null]);
  });

  test('只有一区有可用账号：共有模型明确指到该区', () async {
    runtime.readyRealms = {'cn'};
    runtime.readyAccounts = {'cn': 1};
    final resp = await chat('workbuddy/hy3');
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    expect(seenRealms, ['cn'], reason: '单账号时别赌 hub 全局开关（指向空区必挂）');
  });

  test('两区都有可用账号：同模型并发请求分散到不同区', () async {
    runtime.readyRealms = {'cn', 'intl'};
    runtime.readyAccounts = {'cn': 1, 'intl': 1};
    barrier = Completer<void>();
    barrierCount = 0;
    final rs = await Future.wait([
      chat('workbuddy/hy3', content: 'conversation-A'),
      chat('workbuddy/hy3', content: 'conversation-B'),
    ]);
    for (final r in rs) {
      expect(r.statusCode, 200);
      await r.drain<void>();
    }
    expect(seenRealms.toSet(), {
      'cn',
      'intl',
    }, reason: '两个会话并行调同一模型，必须分到两个出口区（两个账号池）');
  });

  test('两区都有可用账号：同一会话连续请求保持同一区', () async {
    runtime.readyRealms = {'cn', 'intl'};
    runtime.readyAccounts = {'cn': 1, 'intl': 1};
    var resp = await chat('workbuddy/hy3', content: 'same-conversation');
    await resp.drain<void>();
    resp = await chat('workbuddy/hy3', content: 'same-conversation');
    await resp.drain<void>();
    expect(seenRealms.length, 2);
    expect(seenRealms[0], isNotNull);
    expect(seenRealms[1], seenRealms[0], reason: '同会话粘一区，保住上游前缀缓存');
  });

  test('偏好区已饱和：新会话溢出到另一区（而不是排队撞 429）', () async {
    runtime.readyRealms = {'cn', 'intl'};
    runtime.readyAccounts = {'cn': 1, 'intl': 1};
    proxy.workbuddyPreferredRealm = 'cn';
    barrier = Completer<void>();
    barrierCount = 0;
    final rs = await Future.wait([
      chat('workbuddy/hy3', content: 'pref-conversation-A'),
      chat('workbuddy/hy3', content: 'pref-conversation-B'),
    ]);
    for (final r in rs) {
      expect(r.statusCode, 200);
      await r.drain<void>();
    }
    expect(seenRealms.first, 'cn', reason: '新会话先走偏好区');
    expect(seenRealms.toSet(), {
      'cn',
      'intl',
    }, reason: '偏好区一个账号只有一个并发槽，第二个会话必须溢出到国际区');
  });

  test('共有模型撞 429：换到另一区立刻重试，不等 60s 冷却', () async {
    runtime.readyRealms = {'cn', 'intl'};
    runtime.readyAccounts = {'cn': 1, 'intl': 1};
    proxy.workbuddyPreferredRealm = 'cn';
    failCnHy3Once = true;
    final sw = Stopwatch()..start();
    final resp = await chat('workbuddy/hy3', content: 'throttled-conversation');
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    sw.stop();
    expect(seenRealms, ['cn', 'intl'], reason: 'cn 429 后应换到 intl 重试');
    expect(
      sw.elapsed.inSeconds,
      lessThan(5),
      reason: '另一区健康时不该陪冷却区等满 60s',
    );
  });

  test('某区 429 冷却期内：新会话改走另一区', () async {
    runtime.readyRealms = {'cn', 'intl'};
    runtime.readyAccounts = {'cn': 1, 'intl': 1};
    proxy.workbuddyPreferredRealm = 'cn';
    failCnHy3Once = true;
    var resp = await chat('workbuddy/hy3', content: 'cooling-A');
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    // 冷却期内偏好仍是 cn，但新会话必须避开它（否则又要等 429 退避）
    resp = await chat('workbuddy/hy3', content: 'cooling-B');
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    expect(seenRealms, ['cn', 'intl', 'intl']);
  });

  test('号池当日额度 429（小时级 Retry-After）：换另一区重试，不挂连接干等', () async {
    runtime.readyRealms = {'cn', 'intl'};
    runtime.readyAccounts = {'cn': 1, 'intl': 1};
    proxy.workbuddyPreferredRealm = 'cn';
    quota429 = true;
    final sw = Stopwatch()..start();
    final resp = await chat('workbuddy/hy3', content: 'quota-conversation');
    final body = await utf8.decoder.bind(resp).join();
    sw.stop();
    expect(resp.statusCode, 200, reason: 'cn 疑似当日额度耗尽，应换 intl 成功');
    expect(jsonDecode(body)['choices'][0]['message']['content'], contains('hy3'));
    expect(seenRealms, ['cn', 'intl']);
    expect(sw.elapsed.inSeconds, lessThan(5), reason: '绝不陪小时级冷却干等');
  });

  test('单区额度 429 且另一区不可用：如实返回 429（不伪造结果）', () async {
    runtime.readyRealms = {'cn'};
    runtime.readyAccounts = {'cn': 1};
    quota429 = true;
    final resp = await chat('workbuddy/hy3', content: 'quota-single-realm');
    expect(resp.statusCode, 429);
    final body = jsonDecode(await utf8.decoder.bind(resp).join());
    expect(
      body['error']['message'],
      contains('credit limit'),
      reason: '错误体只能被消费一次，透传必须完整（Stream 重读回归）',
    );
  });

  test('偏好区=国际：共有模型带 X-Realm: intl，独占模型不受影响', () async {
    proxy.workbuddyPreferredRealm = 'intl';
    var resp = await chat('workbuddy/hy3');
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    expect(seenRealms.last, 'intl', reason: '共有模型按偏好走国际');

    resp = await chat('workbuddy/deepseek-v4-pro');
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    expect(seenRealms.last, 'cn', reason: '国内独占模型恒走国内，偏好不覆盖');

    resp = await chat('workbuddy/gpt-5.5');
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    expect(seenRealms.last, 'intl');
  });

  test('偏好区=国内：共有模型带 X-Realm: cn', () async {
    proxy.workbuddyPreferredRealm = 'cn';
    final resp = await chat('workbuddy/hy3');
    expect(resp.statusCode, 200);
    await resp.drain<void>();
    expect(seenRealms.last, 'cn');
  });

  test('/v1/models 暴露 realm 元数据', () async {
    final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:${proxy.boundPort}/v1/models'),
    );
    req.headers.set('Authorization', 'Bearer sk-gw');
    final resp = await req.close();
    final j = jsonDecode(await utf8.decodeStream(resp)) as Map<String, dynamic>;
    final byId = {
      for (final m in (j['data'] as List).cast<Map<String, dynamic>>())
        m['id']: m,
    };
    final intlEntry = byId['workbuddy/gpt-5.5'];
    expect(intlEntry, isNotNull);
    expect((intlEntry!['zeroapi'] as Map)['realm'], 'intl');
    final shared = byId['workbuddy/hy3'];
    expect((shared!['zeroapi'] as Map).containsKey('realm'), isFalse);
  });
}
