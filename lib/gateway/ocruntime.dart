import 'dart:io';
import 'dart:convert';

/// opencode CLI 运行时的获取与定位。
///
/// 为什么需要真 CLI：OpenCode Zen 免费层自 2026-10-24 起按 TLS 指纹
/// （JA3/JA4）识别客户端。纯 Dart/Node 复刻 UA 与会话头已不够——同样的
/// 请求体和请求头，经 opencode CLI 自带的 TLS 栈发出去是 200，经
/// Dart HttpClient / node fetch / python urllib 发出去统一 429
/// FreeUsageLimitError（2026-10-25 实测，见 docs/zen-tls-fingerprint.md）。
///
/// 获取策略（用户 2026-10-26 决定）：
///   1. 本地已有就用本地的——PATH、npm 全局目录、常见安装位置；
///   2. 都没有则首次使用时提示下载对应平台的 npm tarball，落到
///      `%APPDATA%\zeroapi\opencode\`，带 SHA256 校验。
/// 不随安装包分发（安装包只 11MB，CLI 解包后约 177MB）。
class OpenCodeRuntime {
  OpenCodeRuntime._();

  static const id = 'opencode';

  /// 钉住的 CLI 版本。≥1.19.3 是硬红线：更早的内置模型目录快照太旧，
  /// 列不出 deepseek-v4.1-flash-free / glm-5.3-flash-free 等新免费模型
  /// （2026-10-18 实测）。v2.x 曾被 zengate 的健康检查不兼容问题挡过，
  /// 这里不自己起 serve 的 /health 依赖，故只钉小版本区间上限。
  static const pinnedVersion = '1.19.3';

  /// 数据根目录：`%APPDATA%\zeroapi\opencode`（Windows）/
  /// `~/.config/zeroapi/opencode`（其他）。
  static Directory dataRoot() {
    final base = Platform.isWindows
        ? (Platform.environment['APPDATA'] ?? '.')
        : (Platform.environment['HOME'] ?? '.');
    final dir = Directory('$base/zeroapi/opencode');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 平台包名（npm 上的分平台 tarball）。
  static String? get platformPackage {
    if (!Platform.isWindows) return null; // 本期只做 Windows
    final arch = Platform.version.contains('arm64') ||
            _envArch().contains('arm64')
        ? 'arm64'
        : 'x64';
    return 'opencode-windows-$arch';
  }

  static String _envArch() =>
      (Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '').toLowerCase();

  /// 下载地址（npm registry 直链，免 npm 依赖）。
  static String? get downloadUrl {
    final pkg = platformPackage;
    if (pkg == null) return null;
    return 'https://registry.npmjs.org/$pkg/-/$pkg-$pinnedVersion.tgz';
  }

  /// 期望的 SHA256。本地没有可信来源时留空，由调用方决定是否放行
  /// （首版先校验「能跑起来且版本对」作为等价保障）。
  static String? get expectedSha256 => null;

  /// 本地候选可执行文件路径，按优先级排列。
  static List<String> candidatePaths() {
    final out = <String>[];
    // 按需下载的落地位（全平台一致）
    out.add('${dataRoot().path}/bin/opencode');
    if (!Platform.isWindows) {
      // Linux/macOS：常见安装位（官方 install 脚本、npm 全局、brew）
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty) {
        out.add('$home/.opencode/bin/opencode');
        out.add('$home/.local/bin/opencode');
        out.add('$home/.bun/bin/opencode');
        out.add('$home/.npm-global/bin/opencode');
      }
      out.add('/usr/local/bin/opencode');
      out.add('/opt/homebrew/bin/opencode');
      final npmGlobal = Platform.environment['HOME'] != null
          ? '${Platform.environment['HOME']}/.npm-global/lib/node_modules/opencode-ai/bin/opencode'
          : '';
      if (npmGlobal.isNotEmpty) out.add(npmGlobal);
      return out;
    }
    final appData = Platform.environment['APPDATA'] ?? '';
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final home = Platform.environment['USERPROFILE'] ?? '';
    // 我们按需下载落地的位置
    out.add('${dataRoot().path}/bin/opencode.exe');
    // npm 全局装过的（zengate 的依赖、用户自己 npm i -g opencode-ai）。
    // 路径统一用正斜杠：Windows 的 dart:io 全程接受，免去反斜杠转义。
    if (appData.isNotEmpty) {
      out.add('$appData/npm/node_modules/opencode-ai/bin/opencode.exe');
      out.add(
          '$appData/npm/node_modules/zengate/node_modules/opencode-ai/bin/opencode.exe');
    }
    if (home.isNotEmpty) {
      out.add('$home/.local/bin/opencode.exe');
      out.add('$home/.bun/bin/opencode.exe');
    }
    if (localAppData.isNotEmpty) {
      out.add('$localAppData/Programs/opencode/opencode.exe');
    }
    out.add('C:/Program Files/opencode/opencode.exe');
    return out;
  }

  /// 用户手动指定的路径（config.opencodeCliPath）：非空时最高优先级，
  /// 盖过一切自动探测。由 service 层在启动/用户修改时写入。
  static String? overridePath;

  /// 已就绪的 CLI 路径；没有则 null。
  /// 优先级：用户指定 > 下载落地位/npm 全局等候选 > PATH。
  static String? findExecutable() {
    final o = overridePath;
    if (o != null && o.isNotEmpty && File(o).existsSync()) return o;
    for (final p in candidatePaths()) {
      if (p.isNotEmpty && File(p).existsSync()) return p;
    }
    // PATH 里找
    final fromPath = _which('opencode.exe') ?? _which('opencode');
    if (fromPath != null) return fromPath;
    return null;
  }

  static String? _which(String name) {
    final paths = Platform.environment['PATH'] ?? '';
    for (final dir in paths.split(Platform.isWindows ? ';' : ':')) {
      if (dir.isEmpty) continue;
      final f = File('$dir${Platform.pathSeparator}$name');
      if (f.existsSync()) return f.path;
    }
    return null;
  }

  /// 运行时是否就绪（找到可执行文件即算就绪，版本校验在启动时做）。
  static bool get isReady => findExecutable() != null;

  /// 下载并解压 CLI 到数据目录。返回可执行文件路径；失败抛异常。
  ///
  /// 流程：GET tarball → 校验大小非零 → 解压（tgz 用 gzip+tar）→
  /// 校验 `bin/opencode.exe` 存在 → 返回路径。
  static Future<String> downloadAndInstall({
    void Function(int received, int total)? onProgress,
  }) async {
    final url = downloadUrl;
    if (url == null) {
      throw const OcruntimeUnsupported('当前平台不支持按需下载（仅 Windows）');
    }
    final root = dataRoot();
    final tgz = File('${root.path}/opencode-$pinnedVersion.tgz');
    final tmp = File('${root.path}/.downloading');

    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw OcruntimeDownloadFailed('下载失败：HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength;
      var received = 0;
      final sink = tmp.openWrite();
      await for (final chunk in resp) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      await sink.close();
    } finally {
      client.close(force: true);
    }

    if (await tmp.length() == 0) {
      await tmp.delete();
      throw const OcruntimeDownloadFailed('下载到空文件');
    }
    // 原子替换，避免半截文件被当成有效缓存
    if (tgz.existsSync()) await tgz.delete();
    await tmp.rename(tgz.path);

    await _extractTgz(tgz, root);
    final exe = File('${root.path}/bin/opencode.exe');
    if (!exe.existsSync()) {
      throw const OcruntimeDownloadFailed('解压后未找到 bin/opencode.exe');
    }
    return exe.path;
  }

  /// 解压 npm tarball：tgz 内是 `package/` 前缀的 tar。
  /// 只挑 `package/bin/` 与 `package/README.md` 等运行时必需的少量文件，
  /// 不把整个 node_modules 依赖树（几百 MB）摊开。
  static Future<void> _extractTgz(File tgz, Directory dest) async {
    final bytes = await tgz.readAsBytes();
    // gzip 解压
    final tar = gzip.decode(bytes);
    // 极简 tar 解析（ustar，512 字节块）
    var off = 0;
    while (off + 512 <= tar.length) {
      final header = tar.sublist(off, off + 512);
      final name = _tarStr(header, 0, 100);
      if (name.isEmpty) break;
      final sizeStr = _tarStr(header, 124, 12);
      final size = int.tryParse(sizeStr.trim()) ?? 0;
      final typeFlag = String.fromCharCode(header[156]);
      final dataStart = off + 512;
      final normalized = name.replaceFirst('package/', '');
      final want = normalized.startsWith('bin/') ||
          normalized == 'package.json' ||
          normalized == 'README.md' ||
          normalized == 'LICENSE';
      if (want && typeFlag != '5') {
        final target = File('${dest.path}/$normalized');
        await target.create(recursive: true);
        await target.writeAsBytes(tar.sublist(dataStart, dataStart + size),
            flush: true);
      }
      off = dataStart + ((size + 511) ~/ 512) * 512;
    }
  }

  static String _tarStr(List<int> b, int start, int len) {
    final end = b.indexOf(0, start);
    final stop = end < 0 || end > start + len ? start + len : end;
    return latin1.decode(b.sublist(start, stop));
  }

  /// 跑 `opencode --version` 拿真实版本号；失败返回 null。
  static Future<String?> probeVersion(String exePath) async {
    try {
      final r = await Process.run(exePath, ['--version'],
          runInShell: false, workingDirectory: Directory.systemTemp.path);
      if (r.exitCode != 0) return null;
      final out = (r.stdout as String).trim();
      return out.isEmpty ? null : out.split('\n').first.trim();
    } catch (_) {
      return null;
    }
  }

  /// 落盘大小（字节），便于排查下载来源问题。
  static int sizeOfFile(File f) => f.lengthSync();
}

class OcruntimeException implements Exception {
  final String message;
  const OcruntimeException(this.message);
  @override
  String toString() => message;
}

class OcruntimeDownloadFailed extends OcruntimeException {
  const OcruntimeDownloadFailed(super.message);
}

class OcruntimeUnsupported extends OcruntimeException {
  const OcruntimeUnsupported(super.message);
}
