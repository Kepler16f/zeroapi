import 'dart:convert';
import 'dart:io';

import 'config.dart';

/// WorkBuddy（腾讯 CodeBuddy）本地号池接入。
///
/// 运行时来自随包的 `vendor/workbuddy2api-hub`（上游 workbuddy2api-hub 的
/// Windows 便携版，含裁剪 Python，MIT）。ZeroApi 只负责：
///   * 首次启动把内置供应商写进配置（用户移除后不再自动加回）；
///   * 拉起/守护 hub 进程（走通用的 managed 生命周期）；
///   * 把 hub 的 /v1 挂进聚合网关；
///   * 提供管理面板入口与面板密码。
/// 账号、用量、模型缓存全部落在 `%APPDATA%\zeroapi\workbuddy`，升级/卸载
/// 安装目录不会丢数据。
class WorkBuddy {
  static const id = 'workbuddy';
  static const hubVersion = '1.7.30';

  /// hub 的默认端口；被占用时顺延（最多试 11 个）。
  static const defaultPort = 8788;

  static bool isWorkBuddy(UpstreamDef d) => d.id == id;

  static Directory dataRoot() {
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']!
        : '${Platform.environment['HOME']}/.config';
    final dir = Directory('$base/zeroapi/workbuddy');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 读取号池已缓存的模型目录（`catalog/product-config-{realm}.json`）。
  ///
  /// 号池引擎从零启动时要拉取远端目录才能回答 `/models`，实测这一段可达
  /// 数十秒；期间模型页是空的。目录本身已经缓存在本地，先用它把模型清单
  /// 填上，引擎就绪后再由真实探测覆盖。
  ///
  /// 返回：模型 id → 出口区（cn/intl），以及两区都有的模型（共有模型）。
  ///
  /// [root] 可覆盖号池数据根目录（测试用临时目录，避免往真实用户数据
  /// 目录写假目录、污染本机号池的模型列表）。
  static Future<({Map<String, String> realms, Set<String> shared})>
      cachedCatalog({Directory? root}) async {
    final dir = Directory('${(root ?? dataRoot()).path}/catalog');
    final realms = <String, String>{};
    final shared = <String>{};
    for (final realm in const ['cn', 'intl']) {
      final file = File('${dir.path}/product-config-$realm.json');
      if (!file.existsSync()) continue;
      List<String> ids;
      try {
        final json = jsonDecode(await file.readAsString());
        if (json is! Map) continue;
        final data = json['data'];
        if (data is! Map) continue;
        final models = data['models'];
        if (models is! List) continue;
        ids = [
          for (final m in models)
            if (m is Map && m['id'] is String) m['id'] as String,
        ];
      } catch (_) {
        continue;
      }
      for (final id in ids) {
        final prev = realms[id];
        if (prev != null && prev != realm) {
          shared.add(id);
          // 共有模型不归单一区：从区映射里移除，只留在 shared 集合中。
          realms.remove(id);
        } else {
          realms[id] = realm;
        }
      }
    }
    return (realms: realms, shared: shared);
  }

  /// 管理面板地址：baseUrl 去掉 `/v1` 后的 origin。
  /// 传入 [token] 时带 `?panel_token=`：本机打开不必再输密码（面板页把它
  /// 存进 sessionStorage 后从地址栏抹掉）。
  static String panelUrl(UpstreamDef d, {String? token}) {
    final uri = Uri.parse(d.baseUrl);
    final port = uri.hasPort ? ':${uri.port}' : '';
    final base = '${uri.scheme}://${uri.host}$port/';
    if (token == null || token.isEmpty) return base;
    return '$base?panel_token=${Uri.encodeQueryComponent(token)}';
  }

  /// hub 的管理面板密码（由 ZeroApi 生成，存在启动参数里）。
  static String panelPassword(UpstreamDef d) {
    final i = d.args.indexOf('--panel-password');
    if (i >= 0 && i + 1 < d.args.length) return d.args[i + 1];
    return 'admin';
  }

  static String accountSummary(int? total, int? ready) {
    if (total == null) return '账号池状态未知';
    if (total == 0) return '未添加账号';
    return '账号 ${ready ?? 0}/$total 可用';
  }

  /// 用系统默认浏览器打开号池管理面板。
  ///
  /// Windows 用 explorer.exe 而不是 `cmd.exe /c start`：cmd 是控制台子系统
  /// 进程，从本应用（GUI 子系统）拉起时会闪一下黑窗；explorer 是 GUI 进程。
  static Future<void> openPanel(UpstreamDef d, {String? token}) async {
    final url = panelUrl(d, token: token);
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [
        url,
      ], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await Process.start('open', [url], mode: ProcessStartMode.detached);
    } else {
      await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
    }
  }

  /// 首次启动自动接入。runtime 不存在（源码树尚未 provision）时不动配置，
  /// 下次启动再试；用户手动接入成功后靠 [GatewayConfig.workbuddySeeded]
  /// 保证不会在移除后自动复活。
  static Future<bool> seedIfNeeded(GatewayConfig config) async {
    if (config.workbuddySeeded) return false;
    if (!config.upstreams.any((u) => u.id == id)) {
      final def = await buildDef();
      if (def == null) return false;
      config.upstreams.add(def);
    }
    config.workbuddySeeded = true;
    config.save();
    return true;
  }

  /// 构造一个可直接交给 UpstreamRuntime 的 WorkBuddy 供应商定义。
  /// vendor 运行时缺失时返回 null。
  static Future<UpstreamDef?> buildDef() async {
    final vendor = GatewayConfig.findWorkBuddyVendor();
    if (vendor == null) return null;

    final port = await _pickPort();
    final root = dataRoot();
    final accounts = Directory('${root.path}/accounts')
      ..createSync(recursive: true);
    final usage = Directory('${root.path}/usage')..createSync(recursive: true);
    final catalog = Directory('${root.path}/catalog')
      ..createSync(recursive: true);

    // 本地免密：只监听 127.0.0.1，不传 --api-key/--panel-password。
    // hub 的 auth_required() 在无启动器密钥且面板未配置密钥时为 False，
    // 网关也不发 Authorization（见 proxy.dart 的 apiKey.isNotEmpty 判定）；
    // 面板回落默认密码 admin，「复制面板密码」仍拿到正确值。
    // 引擎入口优先用带请求追踪的 launcher：它给号池 usage 行补上网关侧的
    // request_id，同一请求在两边可关联/去重。找不到 launcher 时退回上游
    // wb_proxy.py，功能不变，只是失去跨源关联。
    final launcher = GatewayConfig.findWorkBuddyLauncher();
    final script = launcher ?? '${vendor.path}/wb_proxy.py';
    final def = UpstreamDef(
      id: id,
      type: 'managed',
      label: 'WorkBuddy',
      baseUrl: 'http://127.0.0.1:$port/v1',
      apiKey: '',
      command: '{{wbdir}}/python/pythonw.exe',
      args: [
        script,
        '--host',
        '127.0.0.1',
        '--port',
        '$port',
        '--accounts-dir',
        accounts.path,
        '--usage-dir',
        usage.path,
      ],
      env: {
        'WB_PROXY_CATALOG_DIR': catalog.path,
        'PYTHONUTF8': '1',
        'PYTHONDONTWRITEBYTECODE': '1',
        if (launcher != null) 'ZEROAPI_WORKBUDDY_HUB': '${vendor.path}/wb_proxy.py',
      },
      healthUrl: 'http://127.0.0.1:$port/health',
      // 对外调用名统一为 WorkBuddy/<模型名>（如 WorkBuddy/deepseek-v4-pro）
      modelPrefix: 'WorkBuddy',
      // 双出口目录合并：国内与国际两个 realm 各探一次再合并清单，
      // 两个出口的模型同时对外可见；实际请求由 hub 按模型名自动选出口
      // （detect_model_realm），不受 CURRENT_REALM 影响。
      catalogPaths: const ['/models?realm=intl', '/models?realm=cn'],
      enabled: true,
    );
    // 立即把 {{wbdir}} 解析成绝对路径：seed 发生在 load() 之后，运行时
    // 不会再经过一次占位符解析。
    GatewayConfig.resolvePlaceholders(def);
    return def;
  }

  /// 选一个本机可绑定的端口；8788 起顺延，避开已有服务。
  static Future<int> _pickPort() async {
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
