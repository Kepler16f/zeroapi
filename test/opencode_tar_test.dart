// tar 流式解包回归（2026-11-05）：
// 旧实现用十进制解析 tar 头的 size 字段，而 tar 的 size 是**八进制**——
// 259169160 字节（八进制 "1734515610"）被读成 17 亿，解包必崩，
// 应用内「下载运行时」按钮 100% 失败。
//
// 这里用手工构造的 tar 覆盖：
// 1. 八进制 size 正确解析（含跨 chunk 的大文件）；
// 2. 目录项被跳过、文件内容逐字节还原（对齐补零正确处理）；
// 3. 只取需要的条目，其余条目内容正确跳过（不写盘、不越界）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/opencode_tar.dart';

String _header({
  required String name,
  required int size,
  String typeFlag = '0',
}) {
  final b = List<int>.filled(512, 0);
  void put(int start, String s) {
    final bytes = latin1.encode(s);
    for (var i = 0; i < bytes.length && i < s.length; i++) {
      b[start + i] = bytes[i];
    }
  }

  put(0, name);
  put(100, '0000644');
  put(108, '0000000');
  put(116, '0000000');
  // size：八进制，右对齐 11 位 + NUL
  final oct = size.toRadixString(8).padLeft(11, '0');
  put(124, oct);
  put(136, '00000000000');
  put(148, '00000000000');
  b[156] = typeFlag.codeUnitAt(0);
  put(257, 'ustar  ');
  put(263, '00');
  return latin1.decode(b);
}

List<int> _entry(String name, List<int> content, {String typeFlag = '0'}) {
  final h = utf8.encode(_header(name: name, size: content.length, typeFlag: typeFlag));
  final padded = List<int>.from(content);
  while (padded.length % 512 != 0) {
    padded.add(0);
  }
  return [...h, ...padded];
}

void main() {
  late Directory dest;

  setUp(() {
    dest = Directory.systemTemp.createTempSync('zeroapi-tar-');
  });
  tearDown(() {
    if (dest.existsSync()) dest.deleteSync(recursive: true);
  });

  test('八进制 size 正确解析（不是十进制）', () async {
    // 10,000,000 字节：八进制 "4645440"——按十进制读会变成 4.6MB → 解出
    // 的文件被截断。真实 2.x 的 exe 是 259,169,160（八进制 1734515610，
    // 按十进制读成 17 亿直接 RangeError）；这里用小尺寸让测试跑得快，
    // 暴露的是同一个解析 bug。
    const size = 10000000;
    final content = List<int>.filled(size, 65);
    final tgz = File('${dest.path}/pkg.tgz');
    final raw = <int>[
      ..._entry('package/bin/opencode.exe', content),
      ..._entry('package/package.json', utf8.encode('{"name":"x"}')),
    ];
    tgz.writeAsBytesSync(gzip.encode(raw));

    final out = Directory('${dest.path}/out');
    await TarStreamWriter.extract(tgz, out);

    final exe = File('${out.path}/bin/opencode.exe');
    expect(exe.existsSync(), isTrue, reason: '大文件必须被正确解出');
    expect(exe.lengthSync(), size);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('目录项跳过、文件内容逐字节还原', () async {
    final tgz = File('${dest.path}/pkg.tgz');
    final payload = List<int>.generate(1500, (i) => i % 256);
    final raw = <int>[
      ..._entry('package/', const <int>[], typeFlag: '5'),
      ..._entry('package/bin/opencode.exe', payload),
      ..._entry('package/package.json', utf8.encode('{"ok":true}')),
      // 不需要的条目：node_modules 里的东西，必须正确跳过而不写盘
      ..._entry('package/node_modules/x/index.js', utf8.encode('nope')),
    ];
    tgz.writeAsBytesSync(gzip.encode(raw));

    final out = Directory('${dest.path}/out');
    await TarStreamWriter.extract(tgz, out);

    final exe = File('${out.path}/bin/opencode.exe');
    expect(exe.existsSync(), isTrue);
    expect(exe.readAsBytesSync(), payload);
    expect(
      File('${out.path}/package.json').readAsStringSync(),
      '{"ok":true}',
    );
    expect(
      File('${out.path}/node_modules/x/index.js').existsSync(),
      isFalse,
      reason: '不需要的条目不该落盘',
    );
  });

  test('内容跨 chunk 边界时仍正确拼接', () async {
    final tgz = File('${dest.path}/pkg.tgz');
    final payload = List<int>.generate(5000, (i) => (i * 7) % 256);
    tgz.writeAsBytesSync(gzip.encode(_entry('package/bin/opencode.exe', payload)));

    final out = Directory('${dest.path}/out');
    await TarStreamWriter.extract(tgz, out);
    expect(
      File('${out.path}/bin/opencode.exe').readAsBytesSync(),
      payload,
    );
  });
}
