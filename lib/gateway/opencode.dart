import 'dart:io';
import 'dart:math';

import 'config.dart';
import 'ocruntime.dart';


/// OpenCode Zen 的「真 CLI」接入。
///
/// 背景：OpenCode Zen 免费层自 2026-10-24 起按 TLS 指纹（JA3/JA4）识别客户端。
/// 纯 Dart 复刻 UA + ses_/msg_ 会话头 + Bearer public 已不够——同样的请求体
/// 和请求头，经 opencode CLI 自带 TLS 栈发出是 200，经 Dart HttpClient /
/// node fetch / python urllib 发出统一 429 FreeUsageLimitError（2026-10-25
/// A/B 实测：把 CLI 请求原样交给 node 的 TLS 栈转发，上游同样 429）。
///
/// 因此这里 spawn 真 CLI：`opencode serve` 起一个本地 HTTP 服务，
/// ZeroApi 把 OpenAI/Anthropic 请求翻译成它的 session+message 协议，
/// 流式增量由 SSE 事件（message.part.updated）回传。
///
/// 与旧的「zen 直连」（lib/gateway/zen.dart）并存：旧的保留（付费 key 用户
/// 仍可用），新的对外前缀 `OpenCode/`。
///
/// 运行时获取：本地已有（PATH / npm 全局 / 常见安装位）优先；都没有则
/// 首次使用时按需下载对应平台 tarball 到 %APPDATA%\zeroapi\opencode\。
class OpenCode {
  OpenCode._();

  /// 占用原「zen 直连」这个槽位：id 保持 zen，模型前缀仍是 `zen/模型名`，
  /// 用户在 ZCode 里配的模型名不用改；label 显示为「OpenCode Zen Free」。
  static const id = 'zen';

  static const label = 'OpenCode Zen Free';

  /// hub 默认端口；被占用时顺延（最多试 11 个）。
  static const defaultPort = 4097;

  /// 免费档模型（2026-11-04 实测：上游现返回 9 个；10-25 的 7 个之后新增
  /// crouton-alpha-free、pulse-alpha-free）。这只是静态兜底清单，运行时
  /// 以 serve 探测为准。beam-free 上游按国家拒绝（"not available in your
  /// country"）、jev-1.13-free 上游自身 500——标注后 UI 置灰，用户不白点。
  static const freeModels = <String>[
    'deepseek-v4.1-flash-free',
    'glm-5.3-flash-free',
    'big-pickle',
    'flint-40b-free',
    'mimo-v2.6-flash-free',
    'nemotron-3.5-lightning-free',
    'nemotron-3.5-super-vl-free',
    'crouton-alpha-free',
    'pulse-alpha-free',
  ];

  /// 已知暂不可用的免费模型 + 原因（UI 展示用）。
  static const unavailableFreeModels = <String, String>{
    'beam-free': '上游按地区限制（当前出口国家不可用）',
    'jev-1.13-free': '上游服务故障（Unexpected server error）',
  };

  static bool isOpenCode(UpstreamDef d) => d.id == id;

  /// v2 serve 的 Basic 密码存放处（子进程 env）。serve 会强制
  /// `opencode:<该值>` 的 HTTP Basic 鉴权；我们探活/转发都从这里读，
  /// 保证「写入 env → 子进程拿到 → 客户端用同一个」三方一致。
  static const serverPasswordEnv = 'OPENCODE_SERVER_PASSWORD';

  /// 按当前 CLI 大版本把托管供应商 def 鉴权/端点调成对应线协议形态
  /// （幂等；服务启动与更新 CLI 路径时调用，早于子进程第一次 spawn）。
  ///
  /// - v2（@opencode/cli 2.x，现行）：必须有密码否则 /api/* 全部 401；
  ///   健康 GET /api/info（返回 {version,pid,...} JSON），目录 GET /api/model
  ///   （扁平 data 数组）。
  /// - v1（opencode-ai 1.x）：**绝不能设** OPENCODE_SERVER_PASSWORD——实测
  ///   设了会让 POST /session/{id}/message 挂住不返回。健康 /global/health、
  ///   目录 /config/providers。
  static bool reconcileAuth(UpstreamDef def, {required bool v2}) {
    final uri = Uri.tryParse(def.baseUrl);
    final host = uri?.host.isNotEmpty == true ? uri!.host : '127.0.0.1';
    final port = uri != null && uri.hasPort ? uri.port : defaultPort;
    var changed = false;
    final env = Map<String, String>.from(def.env);
    if (v2) {
      if ((env[serverPasswordEnv] ?? '').isEmpty) {
        final rnd = Random.secure();
        final pw = List.generate(16, (_) => rnd.nextInt(256))
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        env[serverPasswordEnv] = pw;
        changed = true;
      }
    } else if (env.remove(serverPasswordEnv) != null) {
      changed = true;
    }
    if (changed) def.env = env;
    final wantHealth = 'http://$host:$port/${v2 ? 'api/info' : 'global/health'}';
    final wantCatalog = [v2 ? '/api/model' : '/config/providers'];
    if (def.healthUrl != wantHealth) {
      def.healthUrl = wantHealth;
      changed = true;
    }
    if (def.catalogPaths.join() != wantCatalog.join()) {
      def.catalogPaths = wantCatalog;
      changed = true;
    }
    return changed;
  }

  /// 探测本机 CLI 的大版本并把 def 调成对应线协议（见 [reconcileAuth]）。
  /// 找不到可执行文件或版本解析不出来时按 v1 处理——v1 的旧端点行为
  /// 与「未升级」一致，不会比现状更差。返回是否改动过 def（调用方落盘）。
  ///
  /// 同时**把 command 重新解析到当前最好的 CLI**：配置里的 command 是当初
  /// 接入时写死的，升级 CLI（1.x → 2.x）后不会自动跟随——实测升级后网关
  /// 仍在 spawn 旧路径的 1.19.3，UA 被拉黑 → 拿不到额度。这里按
  /// 「用户手动指定 > v2 落地位 > 原路径」的顺序纠正。
  static Future<bool> reconcileProtocol(UpstreamDef def) async {
    var exe = def.command;
    var v2 = false;
    if (exe != null && exe.isNotEmpty) {
      final ver = await OpenCodeRuntime.probeVersion(exe);
      v2 = ver != null && OpenCodeRuntime.isV2(ver);
    }
    final changed = reconcileAuth(def, v2: v2);
    if (!v2) {
      // 当前这个不是 2.x：看看有没有 2.x 可用（用户手动指定优先）。
      final picked = await _bestCliPath();
      if (picked != null && picked != exe) {
        def.command = picked;
        final ver2 = await OpenCodeRuntime.probeVersion(picked);
        final v2b = ver2 != null && OpenCodeRuntime.isV2(ver2);
        reconcileAuth(def, v2: v2b);
        return true;
      }
    }
    return changed;
  }

  /// 当前机器上最好的 CLI 路径：用户手动指定 > v2 落地位 > 其余候选。
  /// 找不到 2.x 时返回 null（保持现状，不动用户配置）。
  static Future<String?> _bestCliPath() async {
    final override = OpenCodeRuntime.overridePath;
    if (override != null && override.isNotEmpty && File(override).existsSync()) {
      return override;
    }
    for (final p in OpenCodeRuntime.candidatePaths()) {
      if (p.isEmpty || !File(p).existsSync()) continue;
      final ver = await OpenCodeRuntime.probeVersion(p);
      if (ver != null && OpenCodeRuntime.isV2(ver)) return p;
    }
    return null;
  }


  /// 生成本机供应商定义。找不到 CLI 时返回 null（调用方提示下载）。
  ///
  /// [port] 由调用方选定（pickPort）：serve 用固定端口，baseUrl 里写死。
  static UpstreamDef? seed({int? port, String? proxyUrl}) {
    final exe = OpenCodeRuntime.findExecutable();
    if (exe == null) return null;
    final p = port ?? defaultPort;
    final root = OpenCodeRuntime.dataRoot();

    // serve 的隔离环境：不读用户真实 HOME（避免继承用户的 minimax 等凭证、
    // 项目配置、agent 定义），也不读可能已过期/无效的 OPENCODE_API_KEY。
    // 注意：不要设 OPENCODE_SERVER_PASSWORD —— 实测设了之后
    // POST /session/{id}/message 会挂住不返回（1.19.3）。本机回环监听 +
    // 隔离 HOME 已经够，端口由 pickPort 选在 4097+ 避开常用服务。
    final env = <String, String>{
      // 显式置空覆盖继承值：Dart 的 environment 与宿主 env 合并，
      // 只删不写会把用户级（可能已过期）的 key 漏给子进程 →
      // 上游报 "Invalid credential"（2026-10-26 实测）
      'OPENCODE_API_KEY': '',
      'OPENCODE_DISABLE_AUTOUPDATE': '1',
      'OPENCODE_DISABLE_SHARE': '1',
      'OPENCODE_DISABLE_LSP_DOWNLOAD': '1',
      'OPENCODE_DISABLE_PROJECT_CONFIG': '1',
      'OPENCODE_DISABLE_CLAUDE_CODE': '1',
      'OPENCODE_DISABLE_EXTERNAL_SKILLS': '1',
      'OPENCODE_DISABLE_DEFAULT_PLUGINS': '1',
      'OPENCODE_CONFIG_CONTENT': '{"permission":{"*":"deny"}}',
      'OPENCODE_DISABLE_EMBEDDED_WEB_UI': '1',
      'PYTHONUTF8': '1',
      // CLI 自己出网到 opencode.ai。走代理池里的节点时把该节点的 HTTP
      // 代理写进环境变量——免费额度按「最终到达 opencode.ai 的出口 IP × 天」
      // 计，走不同节点等于把额度分摊到多个 IP，而不是全压在家宽 IP 上。
      // 没有可用节点时显式清空：宿主里可能残留已失效的本地代理
      // （如 FlClash 关掉后的 127.0.0.1:7890），继承下来会连不上上游。
      'HTTP_PROXY': proxyUrl ?? '',
      'HTTPS_PROXY': proxyUrl ?? '',
      'ALL_PROXY': '',
      'http_proxy': proxyUrl ?? '',
      'https_proxy': proxyUrl ?? '',
      'all_proxy': '',
      'NO_PROXY': 'localhost,127.0.0.1,::1',
      'no_proxy': 'localhost,127.0.0.1,::1',
    };
    final isolated = '${root.path}/home';
    if (Platform.isWindows) {
      env['HOME'] = isolated;
      env['USERPROFILE'] = isolated;
      env['APPDATA'] = '$isolated/AppData/Roaming';
      env['LOCALAPPDATA'] = '$isolated/AppData/Local';
    } else {
      env['HOME'] = isolated;
      env['XDG_DATA_HOME'] = '$isolated/.local/share';
      env['XDG_CONFIG_HOME'] = '$isolated/.config';
      env['XDG_CACHE_HOME'] = '$isolated/.cache';
      env['XDG_STATE_HOME'] = '$isolated/.local/state';
    }

    final def = UpstreamDef(
      id: id,
      type: 'managed',
      label: label,
      baseUrl: 'http://127.0.0.1:$p',
      apiKey: '',
      command: exe,
      args: ['serve', '--hostname', '127.0.0.1', '--port', '$p'],
      env: env,
      healthUrl: 'http://127.0.0.1:$p/global/health',
      // serve 无 OpenAI 目录端点（/v1/models 返回 HTML），模型清单走
      // /config/providers，由 upstream.dart 的 _probeOpenCode 解析
      catalogPaths: const ['/config/providers'],
      // 前缀沿用 zen/<model>：老配置与客户端里的模型名无需改动
      modelPrefix: 'zen',
      enabled: true,
    );
    GatewayConfig.resolvePlaceholders(def);
    return def;
  }

  /// 选一个本机可绑定的端口；4097 起顺延，避开已有服务。
  static Future<int> pickPort() async {
    for (var p = defaultPort; p < defaultPort + 11; p++) {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
        await s.close();
        return p;
      } catch (_) {
        // 被占用，试下一个
      }
    }
    return defaultPort;
  }
}

/// 配置迁移：把旧的「zen 直连」条目替换成 CLI 通路。
///
/// 旧条目 type=zen（直连 opencode.ai / workers.dev）自 2026-10-24 起
/// 因上游改按 TLS 指纹识别而全量 429，已不可用；新的 CLI 通路复用
/// id=zen、modelPrefix=zen，客户端里的模型名（`zen/模型名`）无需改动。
/// 用户手动移除过该供应商时不自动复活（与 WorkBuddy 的 seeded 语义一致）。
class OpenCodeMigration {
  OpenCodeMigration._();

  /// 返回是否发生了替换。
  static Future<bool> migrate(GatewayConfig config) async {
    final idx = config.upstreams.indexWhere((u) => u.id == OpenCode.id);
    if (idx < 0) return false;
    final cur = config.upstreams[idx];
    // 已经是 CLI 通路（或用户换成了自定义 remote）→ 不动
    if (cur.type == 'managed') return false;
    final def = OpenCode.seed(port: await OpenCode.pickPort());
    if (def == null) {
      // 本机没有 CLI：保留旧条目但停用，别让用户以为还能用
      cur.enabled = false;
      config.save();
      return false;
    }
    config.upstreams[idx] = def;
    config.save();
    return true;
  }
}
