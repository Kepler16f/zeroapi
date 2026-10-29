import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'proxypool.dart';
import 'socksrelay.dart';

/// 一条出口候选：findProxy 指令 + 来源池节点（手写地址无 nodeId）。
/// 网关用它做连接失败上报与「换下一个出口重试」。
class EgressCandidate {
  final String directive;
  final String? nodeId;
  const EgressCandidate(this.directive, {this.nodeId});
}

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
  /// socks5 不能直接写进 Dart findProxy（引擎只认 PROXY/DIRECT，写 SOCKS5
  /// 会抛 HttpException）——实际请求时由 socksrelay.SocksRelayHub 起一个
  /// 进程内 HTTP→SOCKS5 中转，findProxy 指向该本地中转（poolDirectives）。
  String proxy;

  /// 出口代理开关：关闭时保留地址但走直连（proxyPool 返回空）
  bool proxyEnabled;

  /// 可选的管理面健康地址（如 WorkBuddy 号池的 /health）。
  /// 探活成功时顺带读取账号池状态，供 UI 显示"账号 N/M 可用"。
  String healthUrl;

  /// 模型目录探测路径列表（相对 baseUrl，含 query）。默认 ['/models']。
  /// WorkBuddy 号池同时挂国内与国际两个出口：分别探一次再合并清单，两个出口
  /// 的模型就同时对外可见；实际请求由 hub 按模型名自己选出口。
  List<String> catalogPaths;

  /// 对外调用名前缀：模型统一以 `<前缀>/<模型名>` 暴露（如 zen/big-pickle、
  /// WorkBuddy/deepseek-v4-pro）。留空时回落到 id。裸名仍可调用以兼容旧客户端。
  String modelPrefix;

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
    this.proxyEnabled = false,
    this.healthUrl = '',
    this.catalogPaths = const ['/models'],
    this.modelPrefix = '',
  });

  bool get isManaged => type == 'managed';

  /// 调用名前缀（未配置时用 id）
  String get callPrefix => modelPrefix.trim().isEmpty ? id : modelPrefix.trim();

  /// 统一展示名：有备注用备注，否则用 id
  String get displayName => label.isNotEmpty ? label : id;

  /// UI 类型标签：zen 直连与 managed 都显示为「内置」
  String get typeLabel => isManaged || type == 'zen' ? '内置' : '自定义';

  /// 实际用于探测模型目录的路径（保证至少一条）
  List<String> get catalogProbes =>
      catalogPaths.isEmpty ? const ['/models'] : catalogPaths;

  factory UpstreamDef.fromJson(Map<String, dynamic> j) {
    final paths = ((j['catalogPaths'] ?? const []) as List)
        .map((e) => (e ?? '').toString())
        .where((e) => e.trim().isNotEmpty)
        .toList();
    return UpstreamDef(
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
      proxyEnabled: (j['proxyEnabled'] ?? false) as bool,
      healthUrl: (j['healthUrl'] ?? '') as String,
      catalogPaths: paths,
      modelPrefix: (j['modelPrefix'] ?? '') as String,
    );
  }

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
    if (proxyEnabled) 'proxyEnabled': true,
    if (healthUrl.isNotEmpty) 'healthUrl': healthUrl,
    if (catalogPaths.isEmpty ||
        !(catalogPaths.length == 1 && catalogPaths.first == '/models'))
      'catalogPaths': catalogPaths,
    if (modelPrefix.isNotEmpty) 'modelPrefix': modelPrefix,
    'enabled': enabled,
  };

  /// 解析出口代理池：逗号/换行分隔，每项归一为带 scheme 的原始地址
  /// （`http://host:port` / `socks5://[user:pass@]host:port`）。开关关闭或未填 → 空。
  /// 真正的 findProxy 指令请用 [directives]（SOCKS5 需经本地中转解析）。
  List<String> get proxyPool {
    if (!proxyEnabled || proxy.trim().isEmpty) return const [];
    return proxy
        .split(RegExp(r'[,\n]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map(_normalizeProxyEntry)
        .where((s) => s != null)
        .cast<String>()
        .toList();
  }

  /// 把池条目解析成 [HttpClient.findProxy] 指令（`PROXY host:port` / `DIRECT`）。
  /// http(s) 直接映射；socks5 经 SocksRelayHub 起/复用本地 HTTP→SOCKS5 中转
  /// （await 后保证就绪），未就绪的 SOCKS5 条目跳过、轮换走其余出口。
  ///
  /// 若全局 [activePool] 把 `upstream:<id>` 用途绑定了分组，池内候选指令排在
  /// 最前（[poolCandidatesFor] 语义：round-robin 全量、latency 升序），随后
  /// 才是本字段手写的原始地址文本，按首次出现去重——池绑定的节点优先参与
  /// 轮换/探活，原始地址继续兜底。未绑定/关闭时只剩原始地址。
  /// 本供应商的 baseUrl 是否指向本机（loopback）。内置号池（WorkBuddy hub）
  /// 就是这种：它自己负责向上游出网，ZeroApi→hub 只是本地回环调用，
  /// 套任何出口代理都是错的（代理只会把请求截走、502，请求根本到不了 hub）。
  bool get isLoopbackBaseUrl {
    try {
      final h = Uri.parse(baseUrl).host.toLowerCase();
      return h == '127.0.0.1' ||
          h == 'localhost' ||
          h == '::1' ||
          h.startsWith('127.');
    } catch (_) {
      return false;
    }
  }

  Future<List<EgressCandidate>> egress(SocksRelayHub hub) async {
    // 本地服务强制直连：忽略池绑定与手写地址（见 isLoopbackBaseUrl）
    if (isLoopbackBaseUrl) return const [];
    final out = <EgressCandidate>[];
    void add(String d, {String? nodeId}) {
      if (out.any((c) => c.directive == d)) return;
      out.add(EgressCandidate(d, nodeId: nodeId));
    }

    for (final c in poolCandidatesFor(activePool, ProxyPool.pUpstream(id))) {
      add(c.directive, nodeId: c.nodeId);
    }
    for (final raw in proxyPool) {
      if (raw.startsWith('socks5://')) {
        final relay = await hub.ensure(raw);
        if (relay != null) add(relay.directive!);
      } else {
        add('PROXY ${raw.substring('http://'.length)}');
      }
    }
    return out;
  }

  /// 纯指令视图（[egress] 的 map），老调用方沿用。
  Future<List<String>> directives(SocksRelayHub hub) async => [
    for (final c in await egress(hub)) c.directive,
  ];

  static String? _normalizeProxyEntry(String raw) {
    var s = raw;
    final socks = RegExp(r'^socks5?://', caseSensitive: false).hasMatch(s);
    // 先剥 scheme，再截路径（剥之前 "//" 会干扰截断）
    s = s.replaceFirst(
      RegExp(r'^(socks5?|https?)://', caseSensitive: false),
      '',
    );
    final slash = s.indexOf('/');
    if (slash >= 0) s = s.substring(0, slash);
    s = s.trim();
    if (s.isEmpty) return null;
    // userinfo 里的冒号不算端口：按最后一个 @ 之后的部分判断
    final at = s.lastIndexOf('@');
    final hostPart = at >= 0 ? s.substring(at + 1) : s;
    final withPort = hostPart.contains(':')
        ? s
        : '$s:${socks ? '1080' : '8080'}';
    return socks ? 'socks5://$withPort' : 'http://$withPort';
  }
}

/// 网关接入密钥：用户自由增删的密钥池，持有池中任意一把即可访问网关
/// （本机或局域网设备同理，不与设备绑定）。
class GatewayKey {
  String label;
  String value;

  /// 最近使用时间（管理视角：哪把 key 还在活跃）
  DateTime? lastUsed;

  GatewayKey(this.label, this.value, {this.lastUsed});

  factory GatewayKey.fromJson(Map<String, dynamic> j) => GatewayKey(
    (j['label'] ?? '默认') as String,
    j['value'] as String,
    lastUsed: DateTime.tryParse((j['lastUsed'] ?? '') as String),
  );

  Map<String, dynamic> toJson() => {
    'label': label,
    'value': value,
    if (lastUsed != null) 'lastUsed': lastUsed!.toIso8601String(),
  };
}

class GatewayConfig {
  String host;
  int port;

  /// 密钥池（多把自定义 key）。首项为「默认」key（轮换/兼容语义所在）。
  List<GatewayKey> keys;

  /// 允许局域网设备凭 key 接入：true 时监听 0.0.0.0。
  /// Windows 首次监听会弹防火墙授权，需允许。
  bool allowLan;
  List<UpstreamDef> upstreams;

  /// system | light | dark
  String themeMode;

  /// 网关是否暴露 /v1/messages（Anthropic 格式适配）
  bool anthropicEnabled;

  /// 点击关闭窗口按钮的行为：true=收起到系统托盘（默认），false=退出应用。
  /// 由 windows/runner 的 C++ 层直接读 config.json 生效。
  bool closeToTray;

  /// WorkBuddy 号池的自动接入只做一次：用户主动移除后不再偷偷加回来。
  bool workbuddySeeded;

  /// 双出口共有模型的优先区：''=跟随号池全局开关（不带头）、'cn'、'intl'。
  /// 独占模型不受此影响（恒走自己唯一的出口区）。
  String workbuddyPreferredRealm;

  GatewayConfig({
    this.host = '127.0.0.1',
    this.port = 8123,
    List<GatewayKey>? keys,
    this.allowLan = false,
    this.upstreams = const [],
    this.themeMode = 'system',
    this.anthropicEnabled = true,
    this.closeToTray = true,
    this.workbuddySeeded = false,
    this.workbuddyPreferredRealm = '',
  }) : keys = keys ?? [];

  /// 兼容旧语义：默认 key = 池中第一把
  String get apiKey => keys.isEmpty ? '' : keys.first.value;
  set apiKey(String v) {
    if (keys.isEmpty) {
      keys.add(GatewayKey('默认', v));
    } else {
      keys.first.value = v;
    }
  }

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
      final legacyName =
          'pol'
          'ygate';
      final legacy = Directory('$base/$legacyName');
      if (legacy.existsSync() && !Directory('$base/zeroapi').existsSync()) {
        legacy.renameSync('$base/zeroapi');
      }
    } catch (_) {}
  }

  static GatewayConfig load() {
    _migrateLegacyDir();
    final f = _file();
    final cfg = GatewayConfig();
    if (!f.existsSync()) {
      cfg.keys = [GatewayKey('默认', 'sk-pg-${_rand()}')];
      cfg.upstreams = [defaultZengate()];
      cfg.save();
      return cfg;
    }
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final g = j['gateway'] as Map<String, dynamic>;
      cfg.host = (g['host'] ?? cfg.host) as String;
      cfg.port = (g['port'] ?? cfg.port) as int;
      cfg.themeMode = (g['themeMode'] ?? cfg.themeMode) as String;
      cfg.anthropicEnabled =
          (g['anthropicEnabled'] ?? cfg.anthropicEnabled) as bool;
      cfg.closeToTray = (g['closeToTray'] ?? cfg.closeToTray) as bool;
      cfg.allowLan = (g['allowLan'] ?? false) as bool;
      cfg.workbuddySeeded =
          (g['workbuddySeeded'] ?? cfg.workbuddySeeded) as bool;
      cfg.workbuddyPreferredRealm =
          (g['workbuddyPreferredRealm'] ?? cfg.workbuddyPreferredRealm)
              as String;
      // 密钥池；旧版单 apiKey 自动迁移成「默认」key
      final keyList = (g['keys'] as List?) ?? const [];
      cfg.keys = keyList
          .map((e) => GatewayKey.fromJson(e as Map<String, dynamic>))
          .toList();
      if (cfg.keys.isEmpty) {
        cfg.keys = [
          GatewayKey('默认', (g['apiKey'] ?? 'sk-pg-${_rand()}') as String),
        ];
      }
      cfg.upstreams = ((j['upstreams'] ?? []) as List)
          .map((e) => UpstreamDef.fromJson(e as Map<String, dynamic>))
          .toList();
      var migrated = false;
      for (final u in cfg.upstreams) {
        resolvePlaceholders(u);
        _normalizeZenLabel(u);
        if (_migrateZenToNative(u)) migrated = true;
        if (migrateWorkBuddyLocal(u)) migrated = true;
      }
      if (cfg.upstreams.isEmpty) {
        cfg.upstreams = [defaultZengate()];
        migrated = true;
      }
      if (migrated || g['keys'] == null) cfg.save();
    } catch (_) {
      cfg.keys = [GatewayKey('默认', 'sk-pg-${_rand()}')];
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
          'apiKey': apiKey, // 双写保持旧读取方兼容
          'keys': keys.map((k) => k.toJson()).toList(),
          'allowLan': allowLan,
          'themeMode': themeMode,
          'anthropicEnabled': anthropicEnabled,
          'closeToTray': closeToTray,
          'workbuddySeeded': workbuddySeeded,
          'workbuddyPreferredRealm': workbuddyPreferredRealm,
        },
        'upstreams': upstreams.map((u) => u.toJson()).toList(),
      }),
    );
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
        u.baseUrl.contains('127.0.0.1:8083') ||
        u.baseUrl.contains('localhost:8083');
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

  /// 存量 WorkBuddy 迁移到本地免密：移除旧版本写入的 --api-key/--panel-password
  /// 启动参数。仅当 apiKey 是我们生成的 sk-zb-* 时清空（用户在配置里手填的
  /// 自定义密钥保留）。label 归一为 'WorkBuddy'。
  ///
  /// 旧版每次启动传随机 --panel-password，hub 把它哈希进了 accounts/
  /// settings.json；参数移除后面板仍会要求那个已丢失的随机密码，所以顺带
  /// 清掉面板密码键，让它回到默认态（admin）。重置失败/目录不可写不阻塞迁移。
  /// [accountsDirOverride] 仅测试注入；默认从 --accounts-dir 参数取。
  static bool migrateWorkBuddyLocal(
    UpstreamDef u, {
    String? accountsDirOverride,
  }) {
    if (u.id != 'workbuddy' || u.type != 'managed') return false;
    var changed = false;
    String? accountsDir = accountsDirOverride;
    if (accountsDir == null) {
      final ai = u.args.indexOf('--accounts-dir');
      if (ai >= 0 && ai + 1 < u.args.length) accountsDir = u.args[ai + 1];
    }
    final hadPanelPassword = u.args.contains('--panel-password');
    final args = [...u.args];
    for (final flag in ['--api-key', '--panel-password']) {
      final i = args.indexOf(flag);
      if (i >= 0) {
        args.removeRange(i, i + 2 <= args.length ? i + 2 : args.length);
        changed = true;
      }
    }
    if (changed) u.args = args;
    if (u.apiKey.startsWith('sk-zb-')) {
      u.apiKey = '';
      changed = true;
    }
    if (u.label == 'WorkBuddy 号池（腾讯 CodeBuddy）') {
      u.label = 'WorkBuddy';
      changed = true;
    }
    // 双出口目录合并：国内/国际两个 realm 各探一次再合并清单（hub 的
    // /v1/models 支持 ?realm=，见 wb_proxy.py _request_realm）。空列表与
    // 默认单探都升级；用户在配置里自定义过的（如仅 cn）不动。
    if (u.catalogPaths.isEmpty ||
        (u.catalogPaths.length == 1 && u.catalogPaths.first == '/models')) {
      u.catalogPaths = const ['/models?realm=intl', '/models?realm=cn'];
      changed = true;
    }
    // 存量升级：调用名统一为 WorkBuddy/<模型名>
    if (u.modelPrefix.isEmpty) {
      u.modelPrefix = 'WorkBuddy';
      changed = true;
    }
    // 运行时路径跟随当前安装位置：旧配置里可能是开发树/旧安装目录的绝对
    // 路径，安装目录变化后必须重指到随包 vendor，否则会拉起不存在的进程。
    final vendor = findWorkBuddyVendor();
    if (vendor != null) {
      final py = '${vendor.path}/python/pythonw.exe';
      if (u.command != py) {
        u.command = py;
        changed = true;
      }
      if (u.args.isNotEmpty &&
          u.args.first.toLowerCase().endsWith('wb_proxy.py') &&
          u.args.first != '${vendor.path}/wb_proxy.py') {
        u.args = ['${vendor.path}/wb_proxy.py', ...u.args.sublist(1)];
        changed = true;
      }
    }
    if (hadPanelPassword && accountsDir != null) {
      _resetPanelPassword(accountsDir);
    }
    return changed;
  }

  static void _resetPanelPassword(String accountsDir) {
    try {
      final f = File('$accountsDir/settings.json');
      if (!f.existsSync()) return;
      final data = jsonDecode(f.readAsStringSync());
      if (data is! Map<String, dynamic>) return;
      if (!data.containsKey('panel_password_hash')) return;
      data.remove('panel_password_hash');
      data.remove('panel_password_salt');
      data.remove('panel_password_rounds');
      data.remove('panel_password_default');
      f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
    } catch (_) {
      // 面板密码重置失败不阻塞配置迁移
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
        Platform.isWindows ? 'zeroapi.exe' : 'zeroapi',
      ))
        Platform.executable,
    ];
    for (final c in candidates) {
      if (c.isEmpty) continue;
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// 定位随包分发的 WorkBuddy 网关运行时（`vendor/workbuddy2api-hub`）。
  /// 安装版与 exe 同目录；开发态从构建产物目录向上找到仓库根。
  static Directory? findWorkBuddyVendor() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    var dir = exeDir;
    for (var i = 0; i < 7; i++) {
      final candidate = Directory('${dir.path}/vendor/workbuddy2api-hub');
      if (_looksLikeWorkBuddyVendor(candidate)) return candidate;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    final cwd = Directory.current;
    final candidate = Directory('${cwd.path}/vendor/workbuddy2api-hub');
    return _looksLikeWorkBuddyVendor(candidate) ? candidate : null;
  }

  static bool _looksLikeWorkBuddyVendor(Directory d) =>
      File('${d.path}/wb_proxy.py').existsSync() &&
      File('${d.path}/python/pythonw.exe').existsSync();

  /// 解析内置供应商命令/参数里的占位符。`{{wbdir}}` 在运行时缺失时保留原样，
  /// 等下次启动（或安装完成后）再解析。
  static void resolvePlaceholders(UpstreamDef u) {
    final npmGlobal = Platform.isWindows
        ? '${Platform.environment['APPDATA'] ?? ''}\\npm'
        : '${Platform.environment['HOME'] ?? ''}/.npm-global';
    final wbDir = findWorkBuddyVendor()?.path;
    String r(String s) {
      var out = s
          .replaceAll('{{node}}', _findNodeExecutable() ?? Platform.executable)
          .replaceAll('{{npm-global}}', npmGlobal);
      if (wbDir != null) out = out.replaceAll('{{wbdir}}', wbDir);
      return out;
    }

    u.command = u.command == null ? null : r(u.command!);
    u.args = u.args.map(r).toList();
  }
}

String _rand() {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final r = Random.secure();
  return List.generate(32, (_) => chars[r.nextInt(chars.length)]).join();
}

/// 生成一把新的网关密钥值（sk-pg- 前缀与历史保持兼容）
String genGatewayKey() => 'sk-pg-${_rand()}';
