
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/opencode.dart';
import 'package:zeroapi/gateway/opencode_api.dart';
import 'package:zeroapi/gateway/ocruntime.dart';

void main() {
  group('OpenCodeRuntime 运行时定位', () {
    test('候选路径含按需下载位与 npm 全局位，且按优先级排列', () {
      final paths = OpenCodeRuntime.candidatePaths();
      expect(paths, isNotEmpty);
      expect(paths.first, contains('zeroapi'));
      // Linux 候选以 /opencode 结尾；Windows 以 opencode.exe 结尾
      if (Platform.isWindows) {
        expect(paths.any((p) => p.contains('opencode.exe')), true);
      } else {
        expect(paths.any((p) => p.endsWith('/opencode')), true);
      }
    });

    test('平台包名随架构变化', () {
      final pkg = OpenCodeRuntime.platformPackage;
      if (Platform.isWindows) {
        expect(pkg, startsWith('opencode-windows-'));
        expect(pkg, anyOf(endsWith('arm64'), endsWith('x64')));
      }
    });

    test('下载地址指向 npm registry 的钉定版本', () {
      final url = OpenCodeRuntime.downloadUrl;
      if (OpenCodeRuntime.platformPackage == null) {
        expect(url, isNull);
      } else {
        expect(url, contains('registry.npmjs.org'));
        expect(url, contains('-${OpenCodeRuntime.pinnedVersion}.tgz'));
      }
    });

    test('本机有 CLI 时 findExecutable 命中（开发机装了 zengate 依赖）', () {
      final exe = OpenCodeRuntime.findExecutable();
      if (exe != null) {
        expect(File(exe).existsSync(), true);
      }
      // 找不到也合法：说明这台机器没装过 CLI，走按需下载路径
    });
  });

  group('OpenCode 供应商定义', () {
    test('seed 生成 managed 定义：serve 参数、隔离 env、health 地址', () {
      if (OpenCodeRuntime.findExecutable() == null) return;
      final def = OpenCode.seed(port: 4321);
      expect(def, isNotNull);
      expect(def!.type, 'managed');
      expect(def.baseUrl, 'http://127.0.0.1:4321');
      expect(def.command, isNotNull);
      expect(def.args, ['serve', '--hostname', '127.0.0.1', '--port', '4321']);
      expect(def.healthUrl, 'http://127.0.0.1:4321/global/health');
      // 关键实测结论：设了 SERVER_PASSWORD 会让 POST message 挂住——env 里不能有
      expect(def.env.containsKey('OPENCODE_SERVER_PASSWORD'), false);
      // 隔离 HOME：不读用户真实凭证
      expect(def.env['HOME'], contains('zeroapi'));
      expect(def.env['OPENCODE_DISABLE_AUTOUPDATE'], '1');
    });

    test('免费档清单：7 个可用、2 个标注原因且互斥', () {
      expect(OpenCode.freeModels.length, 7);
      expect(OpenCode.unavailableFreeModels.length, 2);
      expect(
          OpenCode.freeModels
              .toSet()
              .intersection(OpenCode.unavailableFreeModels.keys.toSet()),
          isEmpty);
    });
  });

  group('消息扁平化', () {
    test('多轮消息按 role 标注拼接', () {
      final out = OpenCodeApi.chatMessages([
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'a'},
        {'role': 'assistant', 'content': 'b'},
        {'role': 'user', 'content': 'c'},
      ]);
      expect(out, contains('sys'));
      expect(out.indexOf('sys') < out.indexOf('User: a'), true);
      expect(out.indexOf('Assistant: b') < out.indexOf('User: c'), true);
    });

    test('多模态 content 数组取 text 段', () {
      final out = OpenCodeApi.chatMessages([
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'hello'},
            {'type': 'image_url', 'image_url': {'url': 'x'}},
          ]
        },
      ]);
      expect(out, contains('hello'));
    });

    test('空消息回落 hi', () {
      expect(OpenCodeApi.chatMessages([]), 'hi');
    });
  });
}
