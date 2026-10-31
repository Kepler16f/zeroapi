import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/opencode.dart';
import 'package:zeroapi/gateway/ocruntime.dart';
import 'package:zeroapi/gateway/proxy.dart';
import 'package:zeroapi/gateway/upstream.dart';

/// 真机端到端：拉起真 opencode serve，经 ProxyServer 的 OpenAI 入口
/// 真实调用免费模型（验证 managed 探活 + 协议翻译 + 记账全链路）。
/// 需要本机有 CLI 且能出网（连 opencode.ai）；否则自动跳过。
void main() {
  final exe = OpenCodeRuntime.findExecutable();
  group('真机 e2e（需 CLI + 网络）', () {
    final client = HttpClient();

    test('serve → 网关 chat/completions 出真实内容', () async {
      final def = OpenCode.seed();
      expect(def, isNotNull, reason: '本机未找到 opencode CLI');
      // --port 0：serve 自选端口并打印到 stdout。不用 pickPort——两个
      // e2e 文件并行时「先 bind 再放开」的端口会被对方抢占
      final proc = await Process.start(
          def!.command!, ['serve', '--hostname', '127.0.0.1', '--port', '0'],
          environment: def.env);
      addTearDown(() {
        try {
          proc.kill();
        } catch (_) {}
      });
      final bound = Completer<String>();
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) {
        final m = RegExp(r'127\.0\.0\.1:(\d+)').firstMatch(l);
        if (m != null && !bound.isCompleted) bound.complete(m.group(1)!);
      });
      final port = await bound.future.timeout(const Duration(seconds: 30));
      def
        ..baseUrl = 'http://127.0.0.1:$port'
        ..healthUrl = 'http://127.0.0.1:$port/global/health'
        ..command = ''; // serve 已在跑：managed 生命周期不再重复拉起
      final runtime = UpstreamRuntime(def);
      var healthy = false;
      for (var i = 0; i < 40 && !healthy; i++) {
        await Future.delayed(const Duration(milliseconds: 750));
        healthy = await runtime.probe();
      }
      expect(healthy, true, reason: 'serve 未就绪：${runtime.lastError}');
      expect(runtime.models, contains('deepseek-v4.1-flash-free'));

      final registry = ModelRegistry()..rebuild([runtime]);
      final usageDir = await Directory.systemTemp.createTemp('zeroapi-e2e-');
      final proxy = ProxyServer('127.0.0.1', 0, 'sk-gw', registry,
          usageDir: usageDir.path);
      await proxy.start();
      try {
        final req = await client.openUrl('POST', Uri.parse(
            'http://127.0.0.1:${proxy.boundPort}/v1/chat/completions'));
        req.headers.set('Authorization', 'Bearer sk-gw');
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode({
          'model': 'zen/big-pickle',
          'messages': [
            {'role': 'user', 'content': 'reply with the single word OK'}
          ],
          'stream': false,
        })));
        HttpClientResponse resp;
        try {
          resp = await req.close().timeout(const Duration(seconds: 150));
        } on TimeoutException {
          // 上游额度/网络在波动（免费层按出口 IP × 天计，CF 共享池被他人
          // 流量摊薄）。这是上游状态，不是本机回归——跳过而不是判失败。
          markTestSkipped('上游超时（免费额度/网络波动）');
          return;
        }
        final raw = await utf8.decodeStream(resp);
        final body = jsonDecode(raw) as Map<String, dynamic>;
        if (resp.statusCode == 429) {
          // 上游免费额度被 CF 共享池里的流量烧穿（波动，与本机无关）：
          // 额度按出口 IP × 天计、UTC 零点重置。跳过而不是判失败。
          markTestSkipped('上游免费额度暂时耗尽：${raw.length > 200 ? raw.substring(0, 200) : raw}');
          return; // markTestSkipped 只记录不中断
        }
        if (resp.statusCode == 502) {
          // 上游 5xx/网络失败同样是上游侧状态，不算本机回归
          markTestSkipped('上游暂时不可用：${raw.length > 200 ? raw.substring(0, 200) : raw}');
          return;
        }
        expect(resp.statusCode, 200, reason: raw);
        final content =
            ((body['choices'] as List).first as Map)['message']['content']
                as String;
        expect(content.trim().isNotEmpty, true);
      } finally {
        await proxy.stop();
        runtime.stop();
        try {
          usageDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    },
        timeout: const Timeout(Duration(minutes: 6)),
        skip: exe == null ? '本机无 opencode CLI' : false);
  });
}
