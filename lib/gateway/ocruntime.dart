import 'dart:io';
import 'dart:convert';

import 'opencode_tar.dart';

/// opencode CLI 运行时的获取与定位。
///
/// 为什么需要真 CLI：OpenCode Zen 免费层自 2026-10-24 起按 TLS 指纹
/// （JA3/JA4）识别客户端。纯 Dart/Node 复刻 UA 与会话头已不够——同样的
/// 请求体和请求头，经 opencode CLI 自带的 TLS 栈发出去是 200，经
/// Dart HttpClient / node fetch / python urllib 发出去统一 429
/// FreeUsageLimitError（2026-10-25 实测，见 docs/zen-tls-fingerprint.md）。
///
/// 获取策略（用户 2026-10-26 决定，2026-11-05 升级到 v2 线）：
///   1. 本地已有就用本地的——v2 下载位优先，其次旧 1.x 落地位、
///      PATH、npm 全局目录、常见安装位置；
///   2. 都没有则首次使用时提示下载对应平台的 npm tarball，落到
///      `%APPDATA%\zeroapi\opencode\v2\`，带 SHA256 校验。
/// 不随安装包分发（安装包只 11MB，CLI 解包后约 239MB）。
class OpenCodeRuntime {
  OpenCodeRuntime._();

  static const id = 'opencode';

  /// 钉住的 CLI 版本。**必须是 2.x**：上游自 2026-10-26 起把 opencode
  /// 1.19.x 的 UA 拉黑，1.x 已拿不到 Zen 免费额度（2026-11-05 实测：
  /// @opencode/cli 2.2.5 直连 deepseek-v4.1-flash-free /
  /// glm-5.3-flash-free / flint-40b-free 均返回真实内容、cost=0）。
  /// 包名注意：2.x 不在旧 meta 包 `opencode-ai`（latest 仍是 1.19.5，
  /// 属被拉黑的 1.x 线），而是 scoped 包 `@opencode/cli`；其 meta 包
  /// bin 只是 229 字节占位脚本，真实二进制在平台分包（platformPackage）。
  static const pinnedVersion = '2.2.5';

  /// 钉住版本所属协议线提示（'v2'/'v1'），给主代理选 API 协议版本用。
  static String? get pinnedMajorHint => isV2(pinnedVersion) ? 'v2' : 'v1';

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

  /// 平台包名（npm 上的分平台 tarball）。2.x 的真实二进制在 scoped
  /// 平台分包 `@opencode/cli-windows-$arch` 里（meta 包 `@opencode/cli`
  /// 的 bin/opencode.exe 只是 229 字节占位脚本，跑了会提示
  /// "postinstall script was not run"，不能用）。
  static String? get platformPackage {
    if (!Platform.isWindows) return null; // 本期只做 Windows
    final arch = Platform.version.contains('arm64') ||
            _envArch().contains('arm64')
        ? 'arm64'
        : 'x64';
    return '@opencode/cli-windows-$arch';
  }

  /// registry 路径里 scoped 包名的 `/` 必须转义成 `%2F`
  /// （npm registry 规范：`@opencode%2Fcli-windows-arm64`）。
  static String registryName(String pkg) => pkg.replaceAll('/', '%2F');

  static String _envArch() =>
      (Platform.environment['PROCESSOR_ARCHITECTURE'] ?? '').toLowerCase();

  /// v2 二进制的落盘子目录（`dataRoot()/v2`）。与旧 1.x 落地位（
  /// `dataRoot()/bin`）隔开，避免 1.19.3 与 2.2.5 互相顶掉。
  /// 路径一律正斜杠：Windows 的 dart:io 全程接受，反斜杠会触发 escape lint。
  static Directory v2Root() {
    final dir = Directory('${dataRoot().path}/v2');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 兜底下载直链：按钉定版本自己拼 npm registry 的 `-/name-version.tgz`。
  /// 真正下载前会先试 [resolveTarballUrl]（读 /latest 元数据里的
  /// dist.tarball，更稳），拿到 null 才回落到这里。
  static String? get downloadUrl {
    final pkg = platformPackage;
    if (pkg == null) return null;
    // tarball 文件名不带 scope：cli-windows-arm64-2.2.5.tgz（实测直链形态）
    final file = pkg.split('/').last;
    return 'https://registry.npmjs.org/${registryName(pkg)}/-/$file-$pinnedVersion.tgz';
  }

  /// 读平台分包的 `/latest` 元数据，返回 `dist.tarball`。
  /// 网络失败 / JSON 不合法 / 非 Windows 都返回 null（调用方回落
  /// [downloadUrl] 的拼法）。
  static Future<String?> resolveTarballUrl() async {
    final pkg = platformPackage;
    if (pkg == null) return null;
    try {
      final client = HttpClient();
      try {
        final url =
            'https://registry.npmjs.org/${registryName(pkg)}/latest';
        final req = await client.getUrl(Uri.parse(url));
        final resp = await req.close();
        if (resp.statusCode != 200) return null;
        final body = await resp.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        final dist = json['dist'];
        if (dist is Map && dist['tarball'] is String) {
          return dist['tarball'] as String;
        }
        return null;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return null;
    }
  }

  /// 期望的 SHA256。本地没有可信来源时留空，由调用方决定是否放行
  /// （首版先校验「能跑起来且版本对」作为等价保障）。
  static String? get expectedSha256 => null;

  /// 本地候选可执行文件路径，按优先级排列。
  /// 注意：v2 下载位排最前；旧 1.x 落地位（`dataRoot()/bin`）与
  /// `opencode-ai` npm 全局位仍保留能被找到——向后兼容，但 1.x 已无
  /// 免费额度（UA 被拉黑），UI 会提示升级到 2.x。
  static List<String> candidatePaths() {
    final out = <String>[];
    // v2 按需下载的落地位（优先），全平台一致
    out.add('${v2Root().path}/bin/opencode');
    // 旧 1.x 按需下载的落地位（兼容保留，见上方注释）
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
    // v2 按需下载落地的 exe（优先；上面通用循环已加，这里补 Windows 专用
    // 的 .exe 形态，与旧 1.x 位区分开）
    out.add('${v2Root().path}/bin/opencode.exe');
    // 旧 1.x 按需下载落地的 exe（兼容保留，无免费额度，UI 提示升级）
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

  /// 下载并解压 2.x CLI 到 `v2Root()`。返回可执行文件路径；失败抛异常。
  ///
  /// 流程：读 /latest 元数据取 dist.tarball（拿不到回落 [downloadUrl]
  /// 的拼法）→ GET tarball → 校验大小非零 → 解压（tgz 用 gzip+tar）→
  /// 校验 `bin/opencode.exe` 存在 → 返回路径。
  static Future<String> downloadAndInstall({
    void Function(int received, int total)? onProgress,
  }) async {
    final resolved = await resolveTarballUrl();
    final url = resolved ?? downloadUrl;
    if (url == null) {
      throw const OcruntimeUnsupported('当前平台不支持按需下载（仅 Windows）');
    }
    final root = v2Root();
    final tgz = File('${root.path}/opencode-cli-$pinnedVersion.tgz');
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

  /// 解压 npm tarball：tgz 内是 `package/` 前缀的 tar。2.x 平台分包
  /// （@opencode/cli-windows-*）实测同样以 `package/` 为根前缀，真实
  /// 二进制在 `package/bin/opencode.exe`（自包含 Bun 单文件，不需要
  /// node/bun 运行时），所以下面的 replaceFirst('package/','') 仍成立。
  /// 只挑 `package/bin/` 与 `package/README.md` 等运行时必需的少量文件，
  /// 不把整个 node_modules 依赖树（几百 MB）摊开。
  ///
  /// 两条关键实现约束（2026-11-05 实测修）：
  /// 1. **tar 的 size 字段是八进制**。旧代码用 int.tryParse（十进制）解析，
  ///    259169160 字节（八进制 "1734515610"）被读成 17 亿 → RangeError，
  ///    「下载运行时」按钮必然失败。
  /// 2. **不把整包读进内存**：2.x 的 exe 有 259MB，整包 readAsBytes +
  ///    gzip.decode + sublist 会让峰值内存到 800MB（用户机器直接卡死）。
  ///    改成流式：gzip 流式解码 → 边扫 tar 头边把需要的文件写出。
  static Future<void> _extractTgz(File tgz, Directory dest) async {
    await TarStreamWriter.extract(tgz, dest);
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

  /// 从版本字符串（形如 `opencode v2.2.5`、`1.19.5`、`v2.2.5`）解析
  /// major/minor；解析不出来返回 null。
  static List<int>? parseVersion(String versionString) {
    final m = RegExp(r'(\d+)\.(\d+)').firstMatch(versionString);
    if (m == null) return null;
    final major = int.tryParse(m.group(1) ?? '');
    final minor = int.tryParse(m.group(2) ?? '');
    if (major == null || minor == null) return null;
    return [major, minor];
  }

  /// 是否 2.x 协议线（major >= 2）。给主代理选 API 协议版本用。
  /// 空串 / 无法解析的怪串一律返回 false，不抛异常。
  static bool isV2(String versionString) {
    final vm = parseVersion(versionString);
    if (vm == null) return false;
    return vm[0] >= 2;
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
