import 'dart:io';

/// 「允许局域网连接」配套工具：枚举本机局域网 IPv4 地址，并生成给其他
/// 设备填写的接入地址提示文本。网关绑定 0.0.0.0 后，界面调用这两个函数
/// 展示 http://<本机IP>:<端口>/v1 列表，方便手机/内网机器直接复制。

final RegExp _ipv4Pattern = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');

/// 本机所有非回环 IPv4 地址，如 `192.168.1.5`。去重、保持网卡枚举顺序。
Future<List<String>> localIPv4Addresses() async {
  final ips = <String>{};
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  for (final iface in interfaces) {
    for (final addr in iface.addresses) {
      // Windows 偶发返回带前缀或异常的 address 字符串，正则兜底过滤
      if (_ipv4Pattern.hasMatch(addr.address)) ips.add(addr.address);
    }
  }
  return ips.toList();
}

/// 把地址列表与端口拼成多行提示文本，一行一个接入 URL；
/// 列表为空（未连 Wi-Fi/网线）时返回排查提示。
String lanHintText(List<String> ips, int port) {
  if (ips.isEmpty) {
    return '未检测到局域网 IPv4 地址（检查 Wi-Fi/网线连接）';
  }
  return ips.map((ip) => 'http://$ip:$port/v1').join('\n');
}
