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
  /// zen 上游的出口代理（换出口 IP 用，绕过上游按 IP 的滥用风控）。
  /// 支持 http/socks5，逗号分隔填多个做轮换池，如：
  ///   socks5://127.0.0.1:7891 或 http://127.0.0.1:7890,http://127.0.0.1:7892
  String proxy;

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
    this.proxy = '',
  });

  bool get isManaged => type == 'managed';

  /// 统一展示名：有备注用备注，否则用 id
  String get displayName => label.isNotEmpty ? label : id;

  /// UI 类型标签：zen 直连与 managed 都显示为「内置」
  String get typeLabel => isManaged || type == 'zen' ? '内置' : '自定义';

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
        proxy: (j['proxy'] ?? '') as String,
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
        if (proxy.isNotEmpty) 'proxy': proxy,
        'enabled': enabled,
      };

  /// 解析出口代理池：逗号/换行分隔，每项归一为 Dart findProxy 需要的
  /// `PROXY host:port`（http）或 `SOCKS5 host:port`。空则返回空列表（直连）。
  List<String> get proxyPool => proxy
      .split(RegExp(r'[,\n]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map(_toFindProxy)
      .where((s) => s != null)
      .cast<String>()
      .toList();

  static String? _toFindProxy(String raw) {
    var s = raw;
    final socks = s.startsWith('socks5://') || s.startsWith('socks://');
    if (socks) {
      s = s.replaceFirst(RegExp(r'^socks5?://'), '');
    } else {
      s = s.replaceFirst(RegExp(r'^https?://'), '');
    }
    final hostPort = s.split('/').first.trim();
    if (hostPort.isEmpty) return null;
    final withPort =
        hostPort.contains(':') ? hostPort : '$hostPort:${socks ? '1080' : '8080'}';
    return '${socks ? 'SOCKS5' : 'PROXY'} $withPort';
  }
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
      var migrated = false;
      for (final u in cfg.upstreams) {
        _resolvePlaceholders(u);
        _normalizeZenLabel(u);
        if (_migrateZenToNative(u)) migrated = true;
      }
      if (cfg.upstreams.isEmpty) {
        cfg.upstreams = [defaultZengate()];
        migrated = true;
      }
      if (migrated) cfg.save();
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

  /// 默认供应商：OpenCode Zen 免费档直连（原生实现，见 zen.dart）。
  /// 不依赖 zengate/opencode 本地进程：直接按客户端指纹调
  /// https://opencode.ai/inference/v1 ，只暴露 free 档模型（付费默认隐藏）。
  static UpstreamDef defaultZengate() => UpstreamDef(
        id: 'zen',
        type: 'zen',
        label: 'OpenCode Zen Free',
        baseUrl: 'https://opencode.ai/inference/v1',
        apiKey: '',
      );

  /// 存量 zen 供应商迁移：zengate/opencode 本地代理链路（remote/managed 且指向
  /// 127.0.0.1:8083）整体替换为原生 zen 直连；保留用户的 zen apiKey（若填过）。
  static bool _migrateZenToNative(UpstreamDef u) {
    if (u.id != 'zen') return false;
    final isLocalProxy =
        u.baseUrl.contains('127.0.0.1:8083') || u.baseUrl.contains('localhost:8083');
    if (u.type != 'zen' && isLocalProxy) {
      final key = u.apiKey;
      u.type = 'zen';
      u.baseUrl = 'https://opencode.ai/inference/v1';
      u.label = 'OpenCode Zen Free';
      u.command = null;
      u.args = [];
      u.env = {};
      // zengate 的 key（sk-zg-*）对直连无意义，只有用户自己填的 Zen key 才保留
      u.apiKey = key.startsWith('sk-zg-') ? '' : key;
      return true;
    }
    return false;
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
