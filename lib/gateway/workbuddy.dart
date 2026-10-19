import 'dart:io';
import 'dart:math';

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
  static const hubVersion = '1.7.16';

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

  /// 管理面板地址：baseUrl 去掉 `/v1` 后的 origin。
  static String panelUrl(UpstreamDef d) {
    final uri = Uri.parse(d.baseUrl);
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port/';
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
  static Future<void> openPanel(UpstreamDef d) async {
    final url = panelUrl(d);
    if (Platform.isWindows) {
      await Process.start('cmd.exe', ['/c', 'start', '', url],
          mode: ProcessStartMode.detached);
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
    final accounts = Directory('${root.path}/accounts')..createSync(recursive: true);
    final usage = Directory('${root.path}/usage')..createSync(recursive: true);
    final catalog = Directory('${root.path}/catalog')..createSync(recursive: true);

    final apiKey = _token('sk-zb-', 40);
    final panelPassword = _token('', 16);

    final def = UpstreamDef(
      id: id,
      type: 'managed',
      label: 'WorkBuddy 号池（腾讯 CodeBuddy）',
      baseUrl: 'http://127.0.0.1:$port/v1',
      apiKey: apiKey,
      command: '{{wbdir}}/python/pythonw.exe',
      args: [
        '{{wbdir}}/wb_proxy.py',
        '--host', '127.0.0.1',
        '--port', '$port',
        // 固定 --api-key，面板里改 key 不会影响已接入的 ZeroApi
        '--api-key', apiKey,
        // 每次启动重申密码，保证卡片上的「复制面板密码」长期有效
        '--panel-password', panelPassword,
        '--accounts-dir', accounts.path,
        '--usage-dir', usage.path,
      ],
      env: {
        'WB_PROXY_CATALOG_DIR': catalog.path,
        'PYTHONUTF8': '1',
        'PYTHONDONTWRITEBYTECODE': '1',
      },
      healthUrl: 'http://127.0.0.1:$port/health',
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

  static String _token(String prefix, int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random.secure();
    return '$prefix${List.generate(length, (_) => chars[r.nextInt(chars.length)]).join()}';
  }
}
