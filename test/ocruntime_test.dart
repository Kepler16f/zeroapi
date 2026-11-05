import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/ocruntime.dart';

void main() {
  group('isV2 版本解析', () {
    test('2.x 判定为 v2', () {
      expect(OpenCodeRuntime.isV2('opencode v2.2.5'), true);
      expect(OpenCodeRuntime.isV2('2.2.5'), true);
      expect(OpenCodeRuntime.isV2('v2.0.0'), true);
      expect(OpenCodeRuntime.isV2('opencode 10.1.0'), true);
    });

    test('1.x 判定为非 v2', () {
      expect(OpenCodeRuntime.isV2('1.19.3'), false);
      expect(OpenCodeRuntime.isV2('opencode v1.19.5'), false);
      expect(OpenCodeRuntime.isV2('0.9.9'), false);
    });

    test('空串/怪串返回 false 且不抛', () {
      expect(OpenCodeRuntime.isV2(''), false);
      expect(OpenCodeRuntime.isV2('opencode'), false);
      expect(OpenCodeRuntime.isV2('not-a-version'), false);
      expect(OpenCodeRuntime.isV2('v2'), false); // 缺 minor，解析不出
      expect(OpenCodeRuntime.isV2('..'), false);
    });

    test('parseVersion 提取 major/minor', () {
      expect(OpenCodeRuntime.parseVersion('opencode v2.2.5'), [2, 2]);
      expect(OpenCodeRuntime.parseVersion('1.19.3'), [1, 19]);
      expect(OpenCodeRuntime.parseVersion('junk'), isNull);
    });
  });

  group('版本常量', () {
    test('pinnedVersion 钉在 2.x 线（1.19.x UA 已被免费层拉黑）', () {
      expect(OpenCodeRuntime.pinnedVersion.startsWith('2.'), true);
    });

    test('pinnedMajorHint 为 v2', () {
      expect(OpenCodeRuntime.pinnedMajorHint, 'v2');
    });
  });

  group('平台包名与 registry URL', () {
    test('Windows 上 platformPackage 是 @opencode/cli-windows- 分包', () {
      if (!Platform.isWindows) {
        markTestSkipped('本期只做 Windows，非 Windows 跳过');
        return; // markTestSkipped 只记录不中断，必须显式 return
      }
      final pkg = OpenCodeRuntime.platformPackage;
      expect(pkg, isNotNull);
      expect(pkg, startsWith('@opencode/cli-windows-'));
      expect(pkg, anyOf(endsWith('arm64'), endsWith('x64')));
    });

    test('非 Windows 平台 platformPackage 为 null', () {
      if (Platform.isWindows) return;
      expect(OpenCodeRuntime.platformPackage, isNull);
    });

    test('registryName 把 scoped 包名的 / 转义成 %2F', () {
      expect(
        OpenCodeRuntime.registryName('@opencode/cli-windows-arm64'),
        '@opencode%2Fcli-windows-arm64',
      );
      expect(OpenCodeRuntime.registryName('no-scope-pkg'), 'no-scope-pkg');
    });

    test('downloadUrl 用转义后的 scoped 名，且钉到 pinnedVersion', () {
      final url = OpenCodeRuntime.downloadUrl;
      if (OpenCodeRuntime.platformPackage == null) {
        expect(url, isNull);
        return;
      }
      expect(url, contains('registry.npmjs.org'));
      expect(url, contains('%2F'));
      expect(url, startsWith(
          'https://registry.npmjs.org/@opencode%2Fcli-windows-'));
      expect(url, contains('-${OpenCodeRuntime.pinnedVersion}.tgz'));
      // tarball 文件名不带 scope：cli-windows-arm64-2.2.5.tgz 形态
      expect(url, contains('/-/cli-windows-'));
    });
  });

  group('落盘目录', () {
    test('dataRoot 存在；v2Root 在其下且带 v2 段', () {
      final root = OpenCodeRuntime.dataRoot();
      expect(root.existsSync(), true);
      final v2 = OpenCodeRuntime.v2Root();
      expect(v2.existsSync(), true);
      expect(v2.path, contains('zeroapi'));
      expect(v2.path, contains('/v2'));
      expect(v2.path.startsWith(root.path), true);
      // 库自己拼接的段必须是正斜杠（APPDATA 环境变量原值可能自带
      // 反斜杠，那是运行时值、不触发 escape lint；关键是我们拼的分隔符）
      expect(v2.path.contains('zeroapi/opencode'), true);
      expect(v2.path.contains('/v2'), true);
    });

    test('candidatePaths 里 v2 位排在旧 1.x 下载位之前，旧位保留', () {
      final paths = OpenCodeRuntime.candidatePaths();
      expect(paths, isNotEmpty);
      final v2Idx =
          paths.indexWhere((p) => p.contains('/v2/bin/opencode'));
      final legacyIdx = paths.indexWhere((p) =>
          RegExp(r'/bin/opencode(\.exe)?$').hasMatch(p) &&
          !p.contains('/v2/'));
      expect(v2Idx, greaterThanOrEqualTo(0));
      expect(legacyIdx, greaterThanOrEqualTo(0));
      expect(v2Idx, lessThan(legacyIdx));
      if (Platform.isWindows) {
        expect(paths.any((p) => p.endsWith('v2/bin/opencode.exe')), true);
      }
    });

    test('Windows 候选路径的库内拼接段全用正斜杠', () {
      if (!Platform.isWindows) {
        markTestSkipped('仅 Windows 检查正斜杠约定');
        return;
      }
      // 注意：APPDATA/LOCALAPPDATA/USERPROFILE 环境变量原值自带反斜杠，
      // 那是运行时值，dart:io 接受，也不触发 lint；这里校验的是库内
      // 自己拼接的分隔符（字面量必须正斜杠，反斜杠字面量会触发 escape lint）。
      final envValues = [
        Platform.environment['APPDATA'] ?? '',
        Platform.environment['LOCALAPPDATA'] ?? '',
        Platform.environment['USERPROFILE'] ?? '',
      ].where((v) => v.isNotEmpty);
      for (final p in OpenCodeRuntime.candidatePaths()) {
        var rest = p;
        for (final e in envValues) {
          rest = rest.replaceAll(e, '');
        }
        expect(rest.contains(r'\'), false, reason: p);
      }
      // 硬编码常量位单独确认是正斜杠形态
      expect(OpenCodeRuntime.candidatePaths()
          .any((p) => p == 'C:/Program Files/opencode/opencode.exe'), true);
    });
  });
}
