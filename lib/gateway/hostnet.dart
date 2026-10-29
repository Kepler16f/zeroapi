import 'dart:io';
import 'dart:convert';

/// 宿主网卡探测：找出「物理网卡」并检测是否有 TUN/虚拟网卡抢占默认路由。
///
/// 背景：用户电脑上自己开着代理软件（FlClash 等）的 TUN 模式时，TUN 虚拟
/// 网卡会抢走默认路由（实测 FlClash Meta Tunnel 的 route metric=0，物理 WLAN
/// 是 35）。本应用内建的 mihomo 出站（mihomo → 节点服务器）走宿主默认路由，
/// 于是被 TUN 二次套一层代理 —— 加密类节点（hysteria2 的 QUIC）握手直接超时，
/// 表现为「池里节点全部连不上」。
///
/// 解法：给 mihomo 配 `interface-name: <物理网卡>`，把它的出站 socket 绑定
/// 到物理网卡，绕开宿主 TUN 的路由。
class HostNetwork {
  HostNetwork._();

  /// 常见 TUN/虚拟网卡名特征（小写匹配）。
  static const _tunHints = <String>[
    'tun',
    'tap',
    'utun',
    'meta',
    'clash',
    'singbox',
    'sing-box',
    'v2ray',
    'wg',
    'wireguard',
    'wintun',
    'wintun',
    'loopback',
    'virtual',
    'hyper-v',
    'tailscale',
    'zerotier',
    'npcap',
    'radmin',
  ];

  /// 网卡信息：显示名 + 描述
  static List<({String name, String description})> _adapters() {
    if (!Platform.isWindows) return const [];
    final ps = "Get-NetAdapter | Where-Object {\$_.Status -eq 'Up'} | "
        'Select-Object Name,InterfaceDescription | ConvertTo-Json -Compress';
    final r = Process.runSync('powershell',
        ['-NoProfile', '-Command', ps],
        stdoutEncoding: utf8, stderrEncoding: utf8);
    if (r.exitCode != 0) return const [];
    final out = (r.stdout as String).trim();
    if (out.isEmpty) return const [];
    try {
      final j = jsonDecode(out);
      final list = j is List ? j : [j];
      final result = <({String name, String description})>[];
      for (final e in list) {
        if (e is! Map) continue;
        result.add((
          name: (e['Name'] ?? '').toString(),
          description: (e['InterfaceDescription'] ?? '').toString(),
        ));
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  /// 物理网卡名（用于 mihomo 的 interface-name）。
  /// 排除 TUN/虚拟网卡；找不到返回 null（保持原行为，不写该配置项）。
  static String? physicalInterface() {
    final ads = _adapters();
    if (ads.isEmpty) return null;
    for (final a in ads) {
      final blob = '${a.name} ${a.description}'.toLowerCase();
      if (_tunHints.any(blob.contains)) continue;
      return a.name;
    }
    return null;
  }

  /// 宿主是否具备可用的 IPv6 出口。
  ///
  /// 实测（本机 FlClash TUN 开启）：IPv6 请求全部超时，只有 IPv4 能出网。
  /// 订阅里那批地址写成 IPv6 字面量的节点（hysteria2 尤其多）在这种环境下
  /// 必然连不上——mihomo 日志里是 `write udp [::] -> [2400:...]:8443` 无响应。
  /// 所以要按实际能力决定：IPv6 不可用时，这些节点直接跳过，别浪费探活时间。
  static bool? _ipv6Ok;
  static bool get hasIpv6Egress {
    if (_ipv6Ok != null) return _ipv6Ok!;
    if (!Platform.isWindows) {
      _ipv6Ok = true;
      return true;
    }
    // 连一个 IPv6-only 的公共 DNS：成功即说明有 IPv6 出口
    final r = Process.runSync(
      'powershell',
      ['-NoProfile', '-Command', 'try {(Invoke-WebRequest -Uri "https://api64.ipify.org" -TimeoutSec 5 -UseBasicParsing).Content} catch {""}'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    final body = (r.stdout as String).trim();
    _ipv6Ok = body.contains(':');
    return _ipv6Ok!;
  }
  /// 宿主是否开着 TUN/虚拟网卡（用于 UI 提示与自动绑定）。
  static bool hasTunnelAdapter() {
    for (final a in _adapters()) {
      final blob = '${a.name} ${a.description}'.toLowerCase();
      if (_tunHints.any(blob.contains)) return true;
    }
    return false;
  }
}
