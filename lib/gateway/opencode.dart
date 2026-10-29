import 'dart:io';

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

  /// 免费档模型（2026-10-25 实测：9 个中 7 个可用）。
  /// beam-free 上游按国家拒绝（"not available in your country"）、
  /// jev-1.13-free 上游自身 500——标注后 UI 置灰，用户不白点。
  static const freeModels = <String>[
    'deepseek-v4.1-flash-free',
    'glm-5.3-flash-free',
    'big-pickle',
    'flint-40b-free',
    'mimo-v2.6-flash-free',
    'nemotron-3.5-lightning-free',
    'nemotron-3.5-super-vl-free',
  ];

  /// 已知暂不可用的免费模型 + 原因（UI 展示用）。
  static const unavailableFreeModels = <String, String>{
    'beam-free': '上游按地区限制（当前出口国家不可用）',
    'jev-1.13-free': '上游服务故障（Unexpected server error）',
  };

  static bool isOpenCode(UpstreamDef d) => d.id == id;

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
