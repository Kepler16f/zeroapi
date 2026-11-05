import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// tar 解包的状态：等头 / 读内容 / 跳补零 / 已结束
enum _TarPhase { header, content, padding, done }

/// 流式 tar 解包器（只取需要的文件）。
///
/// 为什么不用现成实现：项目不引第三方依赖，而 npm tarball 需要「边读边写」
/// ——2.x 平台分包里的 opencode.exe 有 259MB，整包读进内存峰值会到 800MB，
/// 用户机器上会直接卡死。
///
/// 三个必须做对的点（2026-11-05 实测）：
/// 1. **tar 的 size 字段是八进制**（不是十进制）。用十进制解析会把 259MB
///    读成 17 亿，解包必崩——应用内「下载运行时」按钮 100% 失败。
/// 2. **条目内容按 512 字节块对齐**：内容之后有补零，读完 size 字节还要
///    跳过补零才是下一个头。漏跳会把补零当成下一个头（名字为空）→ 误判
///    归档结束，后面的文件全丢。
/// 3. 目录项 typeFlag='5'（size 0），要跳过但不能当成结束标记。
///
/// 只取 `package/bin/`、`package/package.json`、`package/README.md`、
/// `package/LICENSE`；其余（node_modules 等）正确跳过、不落盘。
class TarStreamWriter {
  TarStreamWriter(this.dest);

  /// 解压一个 .tgz 到 [dest]（只取 bin/ 与几个元文件）。
  ///
  /// 流式：gzip 边解码边扫 tar 头，命中需要的条目就写出——259MB 的
  /// opencode.exe 不会整包进内存。
  static Future<void> extract(File tgz, Directory dest) async {
    final out = TarStreamWriter(dest);
    try {
      await for (final chunk in tgz.openRead().transform(gzip.decoder)) {
        await out.feed(chunk);
      }
      await out.finish();
    } finally {
      await out.dispose();
    }
  }

  final Directory dest;

  static const _block = 512;

  /// 状态：等头 / 读内容 / 跳补零


  _TarPhase _phase = _TarPhase.header;

  /// 累积中的 tar 头（512 字节）
  final _header = BytesBuilder(copy: false);
  int _headerLen = 0;

  /// 当前条目的剩余内容字节数
  int _remaining = 0;

  /// 当前条目内容之后的补零字节数（512 对齐）
  int _skip = 0;

  /// 当前正在写的目标文件（null = 跳过该条目）
  IOSink? _sink;

  /// tar 头里的八进制数字字段（size 等）。
  static int _octal(List<int> header, int start, int len) {
    var s = '';
    for (var i = start; i < start + len && i < header.length; i++) {
      final c = header[i];
      if (c == 0 || c == 32) {
        // 结尾的 NUL / 空格：八进制串到此为止
        if (s.isNotEmpty) break;
        continue;
      }
      s += String.fromCharCode(c);
    }
    if (s.isEmpty) return 0;
    return int.tryParse(s, radix: 8) ?? 0;
  }

  static String _str(List<int> header, int start, int len) {
    var end = start;
    while (end < start + len && end < header.length && header[end] != 0) {
      end++;
    }
    return latin1.decode(header.sublist(start, end));
  }

  /// 喂入一段解压后的 tar 数据。
  Future<void> feed(List<int> chunk) async {
    var data = chunk;
    while (data.isNotEmpty) {
      switch (_phase) {
        case _TarPhase.header:
          final need = _block - _headerLen;
          final take = data.length < need ? data.length : need;
          _header.add(data.sublist(0, take));
          _headerLen += take;
          data = data.sublist(take);
          if (_headerLen < _block) return;
          final header = _header.toBytes();
          _header.clear();
          _headerLen = 0;
          await _startEntry(header);
        case _TarPhase.content:
          final take = data.length < _remaining ? data.length : _remaining;
          if (_sink != null) _sink!.add(data.sublist(0, take));
          _remaining -= take;
          data = data.sublist(take);
          if (_remaining == 0) {
            await _closeSink();
            // 内容之后还有 512 对齐的补零，必须跳过
            _skip = (_block - (_contentSize % _block)) % _block;
            _phase = _skip > 0 ? _TarPhase.padding : _TarPhase.header;
          }
        case _TarPhase.padding:
          final take = data.length < _skip ? data.length : _skip;
          _skip -= take;
          data = data.sublist(take);
          if (_skip == 0) _phase = _TarPhase.header;
        case _TarPhase.done:
          return;
      }
    }
  }

  /// 当前条目声明的内容长度（用于算补零）
  int _contentSize = 0;

  Future<void> _startEntry(List<int> header) async {
    final name = _str(header, 0, 100);
    if (name.isEmpty) {
      // 空块 = 归档结束（真实 tar 是连续两个空块，一个即可判定）
      _phase = _TarPhase.done;
      return;
    }
    final size = _octal(header, 124, 12);
    final typeFlag = String.fromCharCode(header[156]);
    _contentSize = size;
    _remaining = size;
    _sink = null;
    if (typeFlag != '5' && typeFlag != '0') {
      // 非普通文件（链接/长名等）：跳过即可
      _phase = size > 0 ? _TarPhase.content : _TarPhase.header;
      _skip = (_block - (size % _block)) % _block;
      if (_skip > 0) _phase = _TarPhase.padding;
      return;
    }
    final normalized = name.replaceFirst('package/', '');
    final want = normalized.startsWith('bin/') ||
        normalized == 'package.json' ||
        normalized == 'README.md' ||
        normalized == 'LICENSE';
    if (want && typeFlag != '5') {
      final target = File('${dest.path}/$normalized');
      await target.parent.create(recursive: true);
      _sink = target.openWrite();
    }
    _phase = size > 0 ? _TarPhase.content : _TarPhase.header;
    if (size == 0) {
      // 零长条目（目录）：没有内容，直接跳到下一个头
      _skip = 0;
    }
  }

  Future<void> _closeSink() async {
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      await sink.flush();
      await sink.close();
    }
  }

  /// 归档结束：关闭未完的写入。
  Future<void> finish() async {
    await _closeSink();
  }

  Future<void> dispose() async {
    final sink = _sink;
    _sink = null;
    try {
      await sink?.close();
    } catch (_) {
      // 已经关过
    }
  }
}
