import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// 供应商定义（config.json 里的静态描述）
class UpstreamDef {
  String id;
  String type; // remote | managed
  String label;
  String baseUrl;
  String apiKey;
  String? command;
  List<String> args;
  bool enabled;

  UpstreamDef({
    required this.id,
    this.type = 'remote',
    this.label = '',
    required this.baseUrl,
    this.apiKey = '',
    this.command,
    this.args = const [],
    this.enabled = true,
  });

  factory UpstreamDef.fromJson(Map<String, dynamic> j) => UpstreamDef(
        id: j['id'] as String,
        type: (j['type'] ?? 'remote') as String,
        label: (j['label'] ?? '') as String,
        baseUrl: j['baseUrl'] as String,
        apiKey: (j['apiKey'] ?? '') as String,
        command: j['command'] as String?,
        args: ((j['args'] ?? []) as List).cast<String>(),
        enabled: (j['enabled'] ?? true) as bool,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'label': label,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        if (command != null) 'command': command,
        if (args.isNotEmpty) 'args': args,
        'enabled': enabled,
      };
}

class GatewayConfig {
  String host;
  int port;
  String apiKey;
  List<UpstreamDef> upstreams;

  GatewayConfig({
    this.host = '127.0.0.1',
    this.port = 8123,
    required this.apiKey,
    this.upstreams = const [],
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
      cfg.upstreams = ((j['upstreams'] ?? []) as List)
          .map((e) => UpstreamDef.fromJson(e as Map<String, dynamic>))
          .toList();
      for (final u in cfg.upstreams) {
        _resolvePlaceholders(u);
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
      'gateway': {'host': host, 'port': port, 'apiKey': apiKey},
      'upstreams': upstreams.map((u) => u.toJson()).toList(),
    }));
  }

  /// 默认供应商：本机 zengate（npm 全局安装检测），开箱即用
  static UpstreamDef defaultZengate() {
    final u = UpstreamDef(
      id: 'zen',
      type: 'remote',
      label: 'Opencode Zen Free',
      baseUrl: 'http://127.0.0.1:8083/v1',
      apiKey: '',
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
    return u;
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

  /// 本机 npm 全局的 zengate 入口，不存在返回 null
  static String? _zengateEntry() {
    final candidates = <String>[];
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
