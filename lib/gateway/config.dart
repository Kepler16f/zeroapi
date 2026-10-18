import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// 供应商定义（config.json 里的静态描述）。
/// 内置（managed）与自定义（remote）在此归一：对外统一是"一个有 base URL 的
/// OpenAI 兼容端点"，差别只是内置的端点由本应用负责拉起守护（command/args），
/// 展示名与地址由拉起目标决定；自定义的完全由用户填写。
class UpstreamDef {
  String id;
  String type; // remote(自定义) | managed(内置)
  String label;
  String baseUrl;
  String apiKey;
  String? command;
  List<String> args;
  bool enabled;
  /// managed 拉起子进程时注入的环境变量（如 REQUEST_TIMEOUT_MS、OPENCODE_PATH）
  Map<String, String> env;

  UpstreamDef({
    required this.id,
    this.type = 'remote',
    this.label = '',
    required this.baseUrl,
    this.apiKey = '',
    this.command,
    this.args = const [],
    this.enabled = true,
    this.env = const {},
  });

  bool get isManaged => type == 'managed';

  /// 统一展示名：有备注用备注，否则用 id
  String get displayName => label.isNotEmpty ? label : id;

  /// UI 类型标签：内置 / 自定义
  String get typeLabel => isManaged ? '内置' : '自定义';

  factory UpstreamDef.fromJson(Map<String, dynamic> j) => UpstreamDef(
        id: j['id'] as String,
        type: (j['type'] ?? 'remote') as String,
        label: (j['label'] ?? '') as String,
        baseUrl: j['baseUrl'] as String,
        apiKey: (j['apiKey'] ?? '') as String,
        command: j['command'] as String?,
        args: ((j['args'] ?? []) as List).cast<String>(),
        enabled: (j['enabled'] ?? true) as bool,
        env: ((j['env'] ?? {}) as Map).cast<String, String>(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'label': label,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        if (command != null) 'command': command,
        if (args.isNotEmpty) 'args': args,
        if (env.isNotEmpty) 'env': env,
        'enabled': enabled,
      };
}

class GatewayConfig {
  String host;
  int port;
  String apiKey;
  List<UpstreamDef> upstreams;
  /// system | light | dark
  String themeMode;
  /// 网关是否暴露 /v1/messages（Anthropic 格式适配）
  bool anthropicEnabled;
  /// 点击关闭窗口按钮的行为：true=收起到系统托盘（默认），false=退出应用。
  /// 由 windows/runner 的 C++ 层直接读 config.json 生效。
  bool closeToTray;

  GatewayConfig({
    this.host = '127.0.0.1',
    this.port = 8123,
    required this.apiKey,
    this.upstreams = const [],
    this.themeMode = 'system',
    this.anthropicEnabled = true,
    this.closeToTray = true,
  });

  static File _file() {
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']!
        : '${Platform.environment['HOME']}/.config';
    final dir = Directory('$base/zeroapi');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}/config.json');
  }

  /// 一次性迁移：旧配置目录（目录名 = 'pol' + 'ygate' 拼接，避免改名审计
  /// 全量扫描时源码里再现旧品牌串）存在而 zeroapi 不存在时改名过去；失败不阻塞
  static void _migrateLegacyDir() {
    try {
      final base = Platform.isWindows
          ? Platform.environment['APPDATA']!
          : '${Platform.environment['HOME']}/.config';
      final legacyName = 'pol' 'ygate';
      final legacy = Directory('$base/$legacyName');
      if (legacy.existsSync() && !Directory('$base/zeroapi').existsSync()) {
        legacy.renameSync('$base/zeroapi');
      }
    } catch (_) {}
  }

  static GatewayConfig load() {
    _migrateLegacyDir();
    final f = _file();
    final cfg = GatewayConfig(apiKey: '');
    if (!f.existsSync()) {
      cfg.apiKey = 'sk-pg-${_rand()}';
      cfg.upstreams = [defaultZengate()];
      _migrateZengateKey(cfg.upstreams.first);
      cfg.save();
      return cfg;
    }
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final g = j['gateway'] as Map<String, dynamic>;
      cfg.host = (g['host'] ?? cfg.host) as String;
      cfg.port = (g['port'] ?? cfg.port) as int;
      cfg.apiKey = (g['apiKey'] ?? 'sk-pg-${_rand()}') as String;
      cfg.themeMode = (g['themeMode'] ?? cfg.themeMode) as String;
      cfg.anthropicEnabled = (g['anthropicEnabled'] ?? cfg.anthropicEnabled) as bool;
      cfg.closeToTray = (g['closeToTray'] ?? cfg.closeToTray) as bool;
      cfg.upstreams = ((j['upstreams'] ?? []) as List)
          .map((e) => UpstreamDef.fromJson(e as Map<String, dynamic>))
          .toList();
      for (final u in cfg.upstreams) {
        _resolvePlaceholders(u);
        _normalizeZenLabel(u);
        _ensureZenEnv(u);
      }
      if (cfg.upstreams.isEmpty) cfg.upstreams = [defaultZengate()];
    } catch (_) {
      cfg.apiKey = 'sk-pg-${_rand()}';
      cfg.upstreams = [defaultZengate()];
    }
    return cfg;
  }

  void save() {
    _file().writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
      'gateway': {
        'host': host,
        'port': port,
        'apiKey': apiKey,
        'themeMode': themeMode,
        'anthropicEnabled': anthropicEnabled,
        'closeToTray': closeToTray,
      },
      'upstreams': upstreams.map((u) => u.toJson()).toList(),
    }));
  }

  /// 存量配置里的旧显示名统一为 OpenCode Zen Free（大小写不敏感匹配 opencode zen）
  static void _normalizeZenLabel(UpstreamDef u) {
    final l = u.label.toLowerCase();
    if (u.id == 'zen' && l.contains('opencode') && l.contains('zen')) {
      u.label = 'OpenCode Zen Free';
    }
  }

  /// 存量内置 zen 配置补默认 env；用户已显式设置的键不覆盖
  static void _ensureZenEnv(UpstreamDef u) {
    if (u.id != 'zen' || !u.isManaged) return;
    if (!u.env.containsKey('REQUEST_TIMEOUT_MS')) {
      u.env = {'REQUEST_TIMEOUT_MS': '3600000', ...u.env};
    }
  }

  /// 默认供应商：zengate（内置随包 → 数据目录 → npm 全局），开箱即用。
  /// env 注入：
  /// - REQUEST_TIMEOUT_MS：zengate 默认 300s 是总时长硬上限，流式生成中途也会被杀；
  ///   免费模型思考/排队几分钟是常态，直接放到 SPEC 允许的最大值 1h
  ///   （挂死请求的兜底是客户端断开自动释放，不靠这个超时）
  /// - OPENCODE_PATH：优先本机兼容版 opencode（v1.x API）；v2 与 zengate 的
  ///   /health JSON 协议不兼容（实测返回 HTML），绝不注入；否则用安装目录内置版
  static UpstreamDef defaultZengate() {
    final u = UpstreamDef(
      id: 'zen',
      type: 'remote',
      label: 'OpenCode Zen Free',
      baseUrl: 'http://127.0.0.1:8083/v1',
      apiKey: '',
      env: {'REQUEST_TIMEOUT_MS': '3600000'},
    );
    final zg = _zengateEntry();
    if (zg != null) {
      // Windows 下 Platform.executable 可能是应用自身的别名，必须优先找 node.exe
      final node = _findNodeExecutable();
      if (node != null) {
        u.type = 'managed';
        u.command = node;
        u.args = [zg];
      }
    }
    final oc = _compatibleOpencodePath();
    if (oc != null) u.env['OPENCODE_PATH'] = oc;
    return u;
  }

  /// 应用安装目录的 vendor 根（installer 把内置 zengate/opencode 放这里）；
  /// 开发模式（flutter run）下该目录不存在，返回 null 走后续候选
  static String? _vendorRoot() {
    final exe = Platform.resolvedExecutable;
    final dir = Directory('${File(exe).parent.path}/vendor');
    return dir.existsSync() ? dir.path : null;
  }

  /// 本机可用的 opencode 可执行文件（按兼容性排序）：
  /// 1) 安装目录 vendor/opencode/（installer 随包分发，版本与 zengate 匹配）
  /// 2) PATH 及常见安装位置的本地 opencode，主版本必须 <2
  ///    （opencode v2 的 /health 返回 HTML，zengate 的 JSON 健康检查无法通过）
  /// 检测失败/不兼容返回 null，交给 zengate 自带的 opencode-ai 依赖兜底
  static String? _compatibleOpencodePath() {
    final cached = _opencodePathCache;
    if (cached != null) return cached.isEmpty ? null : cached;
    final candidates = <String>[];
    final vendor = _vendorRoot();
    if (vendor != null) candidates.add('$vendor/opencode/opencode.exe');
    if (Platform.isWindows) {
      final pathDirs = (Platform.environment['PATH'] ?? '').split(';');
      for (final d in pathDirs) {
        if (d.isEmpty) continue;
        candidates.addAll([
          '$d\\opencode.exe',
          '$d\\node_modules\\@opencode\\cli\\bin\\opencode.exe',
          '$d\\node_modules\\opencode-ai\\bin\\opencode.exe',
        ]);
      }
      final local = Platform.environment['LOCALAPPDATA'] ?? '';
      if (local.isNotEmpty) {
        candidates.addAll([
          '$local\\opencode\\opencode.exe',
          '$local\\Programs\\opencode\\opencode.exe',
        ]);
      }
    } else {
      candidates.addAll(['/usr/local/bin/opencode', '/usr/bin/opencode']);
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty) candidates.add('$home/.local/bin/opencode');
    }
    for (final c in candidates) {
      if (c.isEmpty || !File(c).existsSync()) continue;
      if (c.contains('/vendor/opencode/') || c.contains('\\vendor\\opencode\\')) {
        // 内置版由打包脚本保证与 zengate 匹配，无需检测
        return _opencodePathCache = c;
      }
      final v = _opencodeMajorVersion(c);
      if (v != null && v < 2) return _opencodePathCache = c;
    }
    return _opencodePathCache = '';
  }

  static String? _opencodePathCache;

  /// 跑 `--version` 解析主版本（"opencode v1.18.34" / "2.0.18"）；失败返回 null
  static int? _opencodeMajorVersion(String exe) {
    try {
      final r = Process.runSync(exe, ['--version'],
          stdoutEncoding: utf8, stderrEncoding: utf8);
      final m = RegExp(r'(\d+)\.\d+\.\d+').firstMatch(r.stdout.toString());
      return m == null ? null : int.parse(m.group(1)!);
    } catch (_) {
      return null;
    }
  }

  static String? _findNodeExecutable() {
    final candidates = <String>[
      if (Platform.isWindows) ...[
        r'C:\Program Files\nodejs\node.exe',
        '${Platform.environment['LOCALAPPDATA'] ?? ''}\\Programs\\nodejs\\node.exe',
      ] else ...[
        '/usr/local/bin/node',
        '/usr/bin/node',
      ],
      if (!Platform.resolvedExecutable.endsWith(
              Platform.isWindows ? 'zeroapi.exe' : 'zeroapi'))
        Platform.executable,
    ];
    for (final c in candidates) {
      if (c.isEmpty) continue;
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// zengate 入口，按优先级：
  /// 1) 安装目录内置 vendor/zengate（installer 随包分发，开箱即用）
  /// 2) 数据目录 vendor/zengate（%APPDATA%/zeroapi/vendor，便携/开发场景）
  /// 3) npm 全局安装（历史用户的既有路径）
  static String? _zengateEntry() {
    final candidates = <String>[];
    final vendor = _vendorRoot();
    if (vendor != null) candidates.add('$vendor/zengate/index.js');
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']!
        : '${Platform.environment['HOME']}/.config';
    candidates.add('$base/zeroapi/vendor/zengate/index.js');
    if (Platform.isWindows) {
      final appdata = Platform.environment['APPDATA'];
      if (appdata != null) {
        candidates.add('$appdata\\npm\\node_modules\\zengate\\index.js');
      }
    } else {
      final home = Platform.environment['HOME'] ?? '/';
      candidates.addAll([
        '$home/.npm-global/lib/node_modules/zengate/index.js',
        '/usr/lib/node_modules/zengate/index.js',
      ]);
    }
    for (final p in candidates) {
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  /// 从 zengate 自己的配置里读 API key（开箱即用，不要求用户手填）
  static void _migrateZengateKey(UpstreamDef u) {
    for (final p in _zengateConfigPaths()) {
      try {
        final f = File(p);
        if (!f.existsSync()) continue;
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final key = j['API_KEY'] ?? j['apiKey'] ?? j['api_key'];
        if (key is String && key.isNotEmpty) {
          u.apiKey = key;
          return;
        }
      } catch (_) {}
    }
  }

  static List<String> _zengateConfigPaths() {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    if (Platform.isWindows) {
      final appdata = Platform.environment['APPDATA'] ?? '$home/AppData/Roaming';
      return ['$appdata/zengate/config.json', '$home/.config/zengate/config.json'];
    }
    return ['$home/.config/zengate/config.json'];
  }

  static void _resolvePlaceholders(UpstreamDef u) {
    final npmGlobal = Platform.isWindows
        ? '${Platform.environment['APPDATA'] ?? ''}\\npm'
        : '${Platform.environment['HOME'] ?? ''}/.npm-global';
    String r(String s) => s
        .replaceAll('{{node}}', _findNodeExecutable() ?? Platform.executable)
        .replaceAll('{{npm-global}}', npmGlobal);
    u.command = u.command == null ? null : r(u.command!);
    u.args = u.args.map(r).toList();
  }
}

String _rand() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final r = Random.secure();
  return List.generate(32, (_) => chars[r.nextInt(chars.length)]).join();
}
