// 内置代理轮换池。
//
// 用途：把 Clash 订阅（YAML 配置）或各类分享链接嗅探成结构化节点，按「用途」
// 绑定到分组，取用时按策略轮换出 Dart HttpClient.findProxy 可直接用的指令。
//
// 关键约束（Flutter 3.47.2 VM 实测，非推测）：Dart SDK 的 _ProxyConfiguration
// 只识别 "PROXY " 与 "DIRECT" 两个前缀，整个 lib/_http/ 目录没有任何 SOCKS 分支。
// findProxy 返回 "SOCKS5 host:port" 会在首次使用该 client 时抛
// HttpException("Invalid proxy configuration SOCKS5 127.0.0.1:9")，不是静默降级。
// 因此 ProxyNode.dartDirective 只对 http/https 节点返回非 null；SOCKS 前缀
// 绝不进入轮换输出，也绝不产出会抛异常的字符串。
//
// socks5 节点仍然可用：拨号时经 socksrelay.SocksRelayHub 起进程内
// HTTP→SOCKS5 本地中转（端到端已实测），findProxy 指向该中转的
// PROXY 127.0.0.1:<临时端口>。前提：调用方设置 pool.relayHub 并先 await
// prepareRelays() 预热；未预热/预热失败时 socks5 节点被轮换跳过。
//
// ss/vmess/trojan 等加密协议仍需外置 HTTP 混合口（xray/sing-box/mihomo；
// mihomo 默认 HTTP 7890 / SOCKS 7891——导入 Clash 配置时取 HTTP 口），再把
// http://127.0.0.1:<port> 当节点入池；这类节点导入时写入 ProxyPool.warnings。
//
// 持久化：默认 %APPDATA%\zeroapi\proxies.json（非 Windows 走 ~/.config/zeroapi），
// ProxyPool.load / ProxyPool.save 可传 path 覆盖，便于测试。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:yaml/yaml.dart' show YamlList, loadYaml;

import 'hostnet.dart';
import 'socksrelay.dart';

// ---------------------------------------------------------------------------
// 全局接入点
// ---------------------------------------------------------------------------

/// 当前生效的代理池。由 GatewayService.start() 加载并设置、dispose 时清空，
/// 网关出口链路（config.dart 的 UpstreamDef.directives）读取它把池绑定的
/// 节点并入出口轮换。未接入（如独立跑单元测试）时为 null——那时 directives
/// 行为与池存在前完全一致。proxypool.dart 自身不 import config/service，
/// 不构成循环。
ProxyPool? activePool;

// ---------------------------------------------------------------------------
// 节点
// ---------------------------------------------------------------------------

/// 单个代理节点。字段语义对齐 Clash 配置，便于导入/导出对称。
class ProxyNode {
  /// 稳定 id：host:port:type 的确定性短 hash（同节点重复导入仍稳定，可用于
  /// 健康度关联与去重）。
  final String id;

  /// 展示名（#name / ps / remarks；无名时退回 host:port）。
  final String name;

  /// http | https | socks5 | ss | ssr | vmess | vless | trojan | hysteria2 | tuic
  final String type;
  final String host;
  final int port;

  /// socks5/http 认证用户名（其他协议留空）。
  final String username;

  /// socks5/http 认证密码；ss/ssr/trojan/hysteria2 的连接密码也放这里
  /// （与 Clash 的 password 字段一致）。
  final String password;

  /// 其余协议字段：uuid / cipher / alterId / sni / network / path / tls /
  /// hostHeader / flow / alpn … 统一扁平化，bool 归一为 'true'/'false'。
  final Map<String, String> extras;

  ProxyNode({
    required this.type,
    required this.host,
    required this.port,
    String name = '',
    this.username = '',
    this.password = '',
    Map<String, String>? extras,
    String? id,
  }) : id = id == null || id.isEmpty ? _stableId(host, port, type) : id,
       name = name.isEmpty ? '$host:$port' : name,
       extras = extras ?? const {};

  /// Dart [HttpClient.findProxy] 可直接用的指令。
  ///
  /// **只支持 http/https**（`PROXY host:port`，带认证时 `PROXY user:pass@host:port`）。
  /// socks5 及其他加密协议返回 null——Dart 引擎不认 SOCKS 前缀，返回会抛异常，
  /// 见文件头注释。
  String? get dartDirective {
    final t = type.toLowerCase();
    if (t != 'http' && t != 'https') return null;
    final auth = username.isEmpty
        ? ''
        : '${password.isEmpty ? username : '$username:$password'}@';
    return 'PROXY $auth$host:$port';
  }

  /// 是否可作为 findProxy 指令进入轮换池。
  bool get dartUsable => dartDirective != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'host': host,
    'port': port,
    if (username.isNotEmpty) 'username': username,
    if (password.isNotEmpty) 'password': password,
    if (extras.isNotEmpty) 'extras': Map<String, String>.from(extras),
  };

  factory ProxyNode.fromJson(Map<String, dynamic> j) => ProxyNode(
    type: _s(j['type']),
    host: _s(j['host']),
    port: _i(j['port']),
    name: _s(j['name']),
    username: _s(j['username']),
    password: _s(j['password']),
    extras: _strMap(j['extras']),
    id: _s(j['id']),
  );
}

/// 分组：一组节点 + 轮换策略。
class ProxyGroup {
  String name;
  List<ProxyNode> nodes;

  /// 'round-robin' | 'latency'（默认 round-robin）
  String strategy;

  /// 订阅链接（来源）：非空时支持「刷新订阅」重新拉取替换节点。
  /// 机场会轮换节点地址/凭据——Clash 客户端定期更新订阅所以一直可用，
  /// 静态导入的池不刷新就会整组失联。
  String sourceUrl;

  /// 最近一次订阅刷新时间（本地）；从未刷新为 null。
  DateTime? lastRefreshAt;

  /// 自动刷新开关（手动刷新不受此影响）。自动 = 定时 + 健康探测
  /// 大面积失败时提前触发。
  bool autoRefresh;

  /// 自动刷新间隔（小时）。按组设置；默认 6 小时。
  int refreshIntervalHours;

  /// 手动钉住的节点 id：非空时该组出口只用这个节点（健康冷却中除外）。
  String? pinnedNodeId;

  /// 用户手动删掉的节点 id：订阅刷新时跳过，机场下次又下发同一节点也不再
  /// 刷回来。手动导入（[ProxyPool._merge]）同一节点时自动解除排除。
  final Set<String> excludedNodeIds;

  ProxyGroup({
    required this.name,
    List<ProxyNode>? nodes,
    this.strategy = 'round-robin',
    this.sourceUrl = '',
    this.lastRefreshAt,
    this.autoRefresh = true,
    this.refreshIntervalHours = 6,
    this.pinnedNodeId,
    Set<String>? excludedNodeIds,
  }) : nodes = nodes ?? [],
       excludedNodeIds = excludedNodeIds ?? {};

  /// 组内不可用比例（failCount 达到冷却阈值），供「大面积失败优先刷新订阅」判断。
  double failedRatio(ProxyPool pool) {
    if (nodes.isEmpty) return 0;
    final failed = nodes
        .where(
          (n) => (pool.health[n.id]?.failCount ?? 0) >= ProxyPool.failLimit,
        )
        .length;
    return failed / nodes.length;
  }
}

/// 节点健康度：延迟与连续失败计数，供轮换时避开坏节点。
class NodeHealth {
  int latencyMs = -1;
  int failCount = 0;
  DateTime? lastChecked;

  /// 该节点当天（UTC 日期，yyyy-MM-dd）被判定 zen 免费额度耗尽：
  /// 额度按出口 IP × 天计、UTC 零点重置，标记后当天不再选它，跨天自动翻篇。
  String? quotaDay;

  NodeHealth();

  Map<String, dynamic> toJson() => {
    'latencyMs': latencyMs,
    'failCount': failCount,
    if (lastChecked != null) 'lastChecked': lastChecked!.toIso8601String(),
    if (quotaDay != null) 'quotaDay': quotaDay,
  };

  factory NodeHealth.fromJson(Map<String, dynamic> j) {
    final h = NodeHealth();
    if (j['latencyMs'] is num) h.latencyMs = _i(j['latencyMs']);
    if (j['failCount'] is num) h.failCount = _i(j['failCount']);
    h.lastChecked = DateTime.tryParse(_s(j['lastChecked']));
    final qd = _s(j['quotaDay']);
    h.quotaDay = qd.isEmpty ? null : qd;
    return h;
  }
}

// ---------------------------------------------------------------------------
// 池
// ---------------------------------------------------------------------------

/// 代理轮换池。[ChangeNotifier] 子类，供 UI 直接监听增删改。
class ProxyPool extends ChangeNotifier {
  /// 全部分组。节点只存一份：多个分组可引用同一 [ProxyNode] 实例，toJson 不重复。
  final List<ProxyGroup> groups;

  /// 用途 → 分组名。用途键约定（[pUpstream] / [pRealm] / [pSignin] / [pThirdParty]）：
  ///
  /// - `upstream:<供应商id>` 该供应商的上游出口
  /// - `realm:cn` / `realm:intl` WorkBuddy 号池的国内出口 / 国际出口
  /// - `signin:<项目id>` 登录/授权流程（打开官网链接、device auth 回跳等第一步）
  /// - `net:thirdparty` 第三方站点访问（models.dev、github 下载等第二步）
  final Map<String, String> assignments;

  /// 用途 → 是否启用代理。缺省视为启用；false 时 [pickDirective] 返回 null（直连）。
  /// 只落 false 项，保持 JSON 干净。
  final Map<String, bool> enabledFlags;

  /// nodeId → 健康度。
  final Map<String, NodeHealth> health;

  /// 最近一次 [importFromText] 中解析失败的行（不让整批失败）。
  final List<String> parseErrors;

  /// 最近一次 [importFromText] 的风险提示：节点已入池但不宜直接拨号
  /// （如 socks5 节点——Dart 不认 SOCKS 前缀，需经内置中转或外置 HTTP 转发）。
  final List<String> warnings;

  /// SOCKS5 本地中转集线器（可选，运行态不序列化）。设置并 await
  /// [prepareRelays] 后，socks5 节点经进程内 HTTP→SOCKS5 中转参与轮换。
  SocksRelayHub? relayHub;

  /// 节点的 findProxy 指令：http/https 用原生 [ProxyNode.dartDirective]；
  /// socks5 查 [relayHub] 里对应端点的本地中转（未设置或未预热返回 null，
  /// 轮换时该节点被跳过——绝不产出会抛异常的 SOCKS5 前缀）。
  String? directiveOf(ProxyNode n) {
    // 地址只有 IPv6 的节点：宿主没有 IPv6 出口时必然连不上（mihomo 日志里
    // 表现为 write udp [::] -> [2400:...]:8443 无响应），提前跳过省掉
    // 每轮探活的时间开销。宿主 IPv6 可用时照常参与。
    if (isIpv6Only(n.host) && !HostNetwork.hasIpv6Egress) return null;
    final d = n.dartDirective;
    if (d != null) return d;
    final raw = _socksRaw(n);
    if (raw != null) return relayHub?.directiveFor(raw);
    // 加密协议：由内置 mihomo 内核为每个节点起独立 HTTP listener
    final port = corePorts[n.id];
    if (port != null && port > 0) return 'PROXY 127.0.0.1:$port';
    return null;
  }

  /// 地址是否只给了 IPv6（无 IPv4 可用）。
  static bool isIpv6Only(String host) {
    final h = host.trim();
    if (!h.contains(':')) return false;
    // [ipv6] 形式或裸 IPv6 都算
    return true;
  }

  /// 内置内核（mihomo）为加密协议节点分配的本地 HTTP 端口：nodeId → port。
  /// 运行态，不序列化；由 ProxyCore.sync() 写入。
  Map<String, int> corePorts = {};

  /// 该节点的协议是否依赖内置内核转发。
  static bool needsCore(ProxyNode n) => const {
    'ss',
    'ssr',
    'vmess',
    'vless',
    'trojan',
    'hysteria2',
    'tuic',
  }.contains(n.type.toLowerCase());

  /// 预热全部 socks5 节点的本地中转（设置 [relayHub] 后调用一次）。
  Future<void> prepareRelays() async {
    final hub = relayHub;
    if (hub == null) return;
    for (final n in allNodes) {
      final raw = _socksRaw(n);
      if (raw != null) await hub.ensure(raw);
    }
  }

  static String? _socksRaw(ProxyNode n) {
    final t = n.type.toLowerCase();
    if (t != 'socks5' && t != 'socks') return null;
    final cred = n.username.isEmpty
        ? ''
        : '${n.password.isEmpty ? n.username : '${n.username}:${n.password}'}@';
    return 'socks5://$cred${n.host}:${n.port}';
  }

  /// 每个用途的轮换游标（不序列化，纯运行态）。
  final Map<String, int> _cursor;

  /// 连续失败多少次后进入冷却。
  static const int failLimit = 3;

  /// 冷却时长：冷却未过且失败达标的节点被轮换跳过。
  /// 5 分钟（原 10）：配合 [startAutoProbe] 的自动巡检，坏节点被探活
  /// 成功即时解禁，短窗口不会让好节点长时间躺冷。
  static const Duration cooldown = Duration(minutes: 5);

  ProxyPool({
    List<ProxyGroup>? groups,
    Map<String, String>? assignments,
    Map<String, bool>? enabledFlags,
    Map<String, NodeHealth>? health,
  }) : groups = groups ?? [],
       assignments = assignments ?? {},
       enabledFlags = enabledFlags ?? {},
       health = health ?? {},
       parseErrors = [],
       warnings = [],
       _cursor = {};

  // ---- 用途键 ----

  /// 第三方站点访问（models.dev、github 下载等第二步代理）。
  static const String pThirdParty = 'net:thirdparty';

  /// WorkBuddy 号池国内出口。
  static const String realmCn = 'cn';

  /// WorkBuddy 号池国际出口。
  static const String realmIntl = 'intl';

  static String pUpstream(String vendorId) => 'upstream:$vendorId';
  static String pRealm(String realm) => 'realm:$realm';
  static String pSignin(String projectId) => 'signin:$projectId';

  /// 池中全部节点（按分组出现顺序去重，id 首次出现者为准）。
  List<ProxyNode> get allNodes {
    final seen = <String>{};
    final out = <ProxyNode>[];
    for (final g in groups) {
      for (final n in g.nodes) {
        if (seen.add(n.id)) out.add(n);
      }
    }
    return out;
  }

  ProxyGroup? _groupNamed(String name) {
    for (final g in groups) {
      if (g.name == name) return g;
    }
    return null;
  }

  // ---- 导入 ----

  /// 嗅探导入。text 是 Clash YAML（含 `proxies:` 键）就按 YAML 解析，否则逐行当
  /// 分享链接 / 纯文本 `host:port`。同 id 节点去重，池中已有的不重复添加。
  ///
  /// 返回本次**新增**节点数。失败行进 [parseErrors]，风险节点进 [warnings]。
  int importFromText(String text, {String? groupName}) {
    parseErrors.clear();
    warnings.clear();
    final defaultGroup = groupName == null || groupName.trim().isEmpty
        ? '导入'
        : groupName.trim();
    final nodes = <ProxyNode>[];
    final groups2 = <ProxyGroup>[];
    final y = _yaml(text);
    if (y != null && y.containsKey('proxies')) {
      _importClash(y, defaultGroup, nodes, groups2);
      if (groupName != null && groupName.trim().isNotEmpty) {
        // 用户点名了批次分组：忽略订阅自带的小组结构，整批归入该组，
        // 保证「不同次导入明确分开」。
        groups2
          ..clear()
          ..add(ProxyGroup(name: defaultGroup, nodes: nodes));
      }
    } else {
      _importLinks(text, nodes);
      if (nodes.isNotEmpty) {
        groups2.add(ProxyGroup(name: defaultGroup, nodes: nodes));
      }
    }
    if (nodes.isEmpty) return 0;
    _noteWarnings(nodes);
    return _merge(nodes, groups2);
  }

  /// 解析订阅/分享文本为节点清单（供 [replaceGroupFromText] 预览与刷新）。
  /// 失败行进 [parseErrors]。YAML 里自带的分组结构被忽略，只取节点。
  List<ProxyNode> parseNodesFromText(String text) {
    parseErrors.clear();
    final nodes = <ProxyNode>[];
    final y = _yaml(text);
    if (y != null && y.containsKey('proxies')) {
      final groups2 = <ProxyGroup>[];
      _importClash(y, '刷新', nodes, groups2);
    } else {
      _importLinks(text, nodes);
    }
    _noteWarnings(nodes);
    return nodes;
  }

  /// 订阅刷新：用新文本整组替换 [groupName] 的节点清单（追加/合并语义会
  /// 永远留着机场已下线的死节点——刷新必须能删）。id 是内容稳定哈希，同
  /// host:port:type 的节点刷新前后 id 相同，健康度与用途绑定自动延续。
  /// 返回 (新增数, 移除数)；组不存在返回 (-1, -1)。置空 [text] 视为清组。
  (int, int) replaceGroupFromText(String groupName, String text) {
    final g = _groupNamed(groupName);
    if (g == null) return (-1, -1);
    // 用户手动删掉的节点不再随订阅刷新回来（id 是 host:port:type 的稳定哈希）
    final incoming =
        (text.trim().isEmpty ? <ProxyNode>[] : parseNodesFromText(text))
            .where((n) => !g.excludedNodeIds.contains(n.id))
            .toList();
    final byId = <String, ProxyNode>{for (final n in allNodes) n.id: n};
    final fresh = <ProxyNode>[];
    final seen = <String>{};
    var added = 0;
    for (final n in incoming) {
      if (!seen.add(n.id)) continue;
      final old = byId[n.id];
      if (old == null) {
        fresh.add(n);
        added += 1;
      } else {
        fresh.add(old);
      }
    }
    final freshIds = seen;
    final removed = g.nodes.where((n) => !freshIds.contains(n.id)).length;
    g.nodes
      ..clear()
      ..addAll(fresh);
    // 钉住的节点被订阅移除时解除钉住
    if (g.pinnedNodeId != null && !g.nodes.any((n) => n.id == g.pinnedNodeId)) {
      g.pinnedNodeId = null;
    }
    notifyListeners();
    return (added, removed);
  }

  /// 钉住/解除分组出口节点：非空时该组出口只用该节点（冷却中除外）。
  /// 返回 false 表示节点不在组内。
  bool pinNode(String groupName, String? nodeId) {
    final g = _groupNamed(groupName);
    if (g == null) return false;
    if (nodeId != null && nodeId.trim().isNotEmpty) {
      final id = nodeId.trim();
      if (!g.nodes.any((n) => n.id == id)) return false;
      g.pinnedNodeId = id;
    } else {
      g.pinnedNodeId = null;
    }
    notifyListeners();
    return true;
  }

  /// 记录分组订阅来源与刷新时间（导入/刷新成功后调用，落盘由监听完成）。
  void setGroupSource(String groupName, String url) {
    final g = _groupNamed(groupName);
    if (g == null) return;
    g
      ..sourceUrl = url.trim()
      ..lastRefreshAt = DateTime.now();
    notifyListeners();
  }

  int _merge(List<ProxyNode> freshNodes, List<ProxyGroup> freshGroups) {
    final existing = <String, ProxyNode>{};
    for (final n in allNodes) {
      existing.putIfAbsent(n.id, () => n);
    }
    final resolved = <String, ProxyNode>{};
    var added = 0;
    for (final n in freshNodes) {
      final old = existing[n.id];
      if (old == null) {
        existing[n.id] = n;
        added += 1;
      }
      resolved[n.id] = old ?? n;
    }
    for (final g in freshGroups) {
      final seen = <String>{};
      final members = <ProxyNode>[];
      for (final n in g.nodes) {
        final r = resolved[n.id];
        if (r != null && seen.add(r.id)) members.add(r);
      }
      if (members.isEmpty) continue;
      final target = _groupNamed(g.name);
      if (target == null) {
        groups.add(
          ProxyGroup(name: g.name, nodes: members, strategy: g.strategy),
        );
      } else {
        final have = {for (final n in target.nodes) n.id};
        for (final n in members) {
          if (have.add(n.id)) target.nodes.add(n);
          // 手动导入即视为用户主动要这个节点：解除删除时的排除
          target.excludedNodeIds.remove(n.id);
        }
      }
    }
    notifyListeners();
    return added;
  }

  void _importLinks(String text, List<ProxyNode> out) {
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final n = parseShareLink(line);
      if (n == null) {
        parseErrors.add(
          line.length > 120 ? '${line.substring(0, 120)}…' : line,
        );
      } else {
        out.add(n);
      }
    }
  }

  /// 入池后对「不可直接拨号的节点」给出明确提示——不静默丢弃，也不产出会抛
  /// 异常的 findProxy 指令（Dart 只认 PROXY，见文件头实测结论）。
  void _noteWarnings(List<ProxyNode> nodes) {
    var socks = 0;
    var unusable = 0;
    for (final n in nodes) {
      final t = n.type.toLowerCase();
      if (t == 'socks5' || t == 'socks') socks++;
      if (!n.dartUsable) unusable++;
    }
    if (socks > 0) {
      warnings.add(
        '$socks 个 SOCKS5 节点已入池：Dart 的 HttpClient 不认 SOCKS 前缀，'
        '需经内置 HTTP→SOCKS5 中转（设置 relayHub 并 await prepareRelays 预热后'
        '即参与轮换；未预热时跳过，不产出会抛异常的指令）',
      );
    }
    if (unusable > socks) {
      warnings.add(
        '${unusable - socks} 个加密协议节点（ss / ssr / vmess / vless / '
        'trojan / hysteria2 / tuic）已入池：由随包 mihomo 内核逐个建立 127.0.0.1 '
        '本地出口后参与轮换；若内核缺失，请外置 HTTP 混合口（mihomo HTTP 7890，'
        '不是 SOCKS 7891）再导入 http://127.0.0.1:<端口>',
      );
    }
  }

  void _importClash(
    Map y,
    String defaultGroup,
    List<ProxyNode> outNodes,
    List<ProxyGroup> outGroups,
  ) {
    final proxies = y['proxies'];
    if (proxies is! YamlList) return;
    final byName = <String, ProxyNode>{};
    for (final item in proxies) {
      final m = item is Map ? item : null;
      if (m == null) continue;
      final n = _nodeFromClash(m);
      if (n == null) continue;
      outNodes.add(n);
      byName.putIfAbsent(n.name, () => n);
    }
    final pgs = y['proxy-groups'];
    if (pgs is YamlList && pgs.isNotEmpty) {
      final referenced = <String>{};
      for (final item in pgs) {
        final m = item is Map ? item : null;
        if (m == null) continue;
        final name = _s(m['name']);
        if (name.isEmpty) continue;
        final names = m['proxies'] is List
            ? m['proxies'] as List
            : const <Object>[];
        final members = <ProxyNode>[];
        for (final nm in names) {
          final n = byName[_s(nm)];
          if (n != null) {
            referenced.add(n.id);
            members.add(n);
          }
        }
        if (members.isEmpty) continue;
        outGroups.add(
          ProxyGroup(
            name: name,
            nodes: members,
            strategy: _clashStrategy(_s(m['type'])),
          ),
        );
      }
      // 没被任何组引用的节点归入默认组，避免丢节点
      final orphan = [
        for (final n in outNodes)
          if (!referenced.contains(n.id)) n,
      ];
      if (orphan.isNotEmpty) {
        outGroups.add(ProxyGroup(name: defaultGroup, nodes: orphan));
      }
    } else if (outNodes.isNotEmpty) {
      outGroups.add(ProxyGroup(name: defaultGroup, nodes: outNodes));
    }
  }

  /// Clash 组类型 → 本模块策略：url-test/fallback/delay-test 按延迟，其余轮询。
  static String _clashStrategy(String type) {
    switch (type.toLowerCase()) {
      case 'url-test':
      case 'fallback':
      case 'delay-test':
        return 'latency';
      default:
        return 'round-robin';
    }
  }

  static ProxyNode? _nodeFromClash(Map item) {
    final type = _s(item['type']);
    final server = _s(item['server']);
    final hostKey = _s(item['host']);
    final host = server.isEmpty
        ? (hostKey.isEmpty ? _s(item['address']) : hostKey)
        : server;
    final port = _i(item['port']);
    if (type.isEmpty || host.isEmpty || port <= 0) return null;
    final extras = <String, String>{};
    _collectExtras(item, extras);
    // Clash 里 server 存在时 host 是 ws Host 头，归一到 hostHeader
    if (server.isNotEmpty && hostKey.isNotEmpty) {
      extras.putIfAbsent('hostHeader', () => hostKey);
    }
    return ProxyNode(
      type: type,
      host: host,
      port: port,
      name: _s(item['name']),
      username: _s(item['username']),
      password: _s(item['password']),
      extras: extras,
    );
  }

  /// Clash 节点里除结构性字段外的全部键：标量直接进 extras，嵌套映射（ws-opts /
  /// grpc-opts / plugin-opts / headers）扁平化为 `a.b` 点分键。
  static void _collectExtras(Map item, Map<String, String> out) {
    for (final e in item.entries) {
      final key = e.key.toString();
      if (_clashSkipKeys.contains(key)) continue;
      final v = e.value;
      if (v == null) continue;
      if (v is Map) {
        _flattenOpts(key, v, out);
      } else {
        out[key] = v.toString();
      }
    }
  }

  static void _flattenOpts(String prefix, Map m, Map<String, String> out) {
    for (final e in m.entries) {
      final key = e.key.toString();
      final v = e.value;
      if (v is Map) {
        _flattenOpts('$prefix.$key', v, out);
        continue;
      }
      if (v == null) continue;
      var k = '$prefix.$key';
      if (k == 'ws-opts.path') k = 'path';
      if (k == 'ws-opts.headers.Host') k = 'hostHeader';
      out[k] = v.toString();
    }
  }

  static final Set<String> _clashSkipKeys = {
    'name',
    'type',
    'server',
    'host',
    'address',
    'port',
    'password',
    'username',
    'udp',
    'udp-port',
  };

  // ---- 分享链接解析 ----

  /// 解析单行分享链接，无法识别返回 null。供 UI 逐条粘贴/测试复用。
  ///
  /// 支持：socks5(5h)/socks/http/https、ss（SIP002 与旧式）、ssr、vmess、
  /// vless、trojan、hysteria2/hy2、tuic，以及纯文本 `host:port`、
  /// `user:pass@host:port`（默认 http）。
  static ProxyNode? parseShareLink(String line) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) return null;

    // 分离 #fragment（节点名）。fragment 里的 + 是字面加号不是空格，只做百分号解码。
    var name = '';
    var body = t;
    final hashAt = t.indexOf('#');
    if (hashAt >= 0) {
      name = _uriDecode(t.substring(hashAt + 1)).trim();
      body = t.substring(0, hashAt);
    }

    final m = _schemeRe.firstMatch(body);
    if (m == null) return _plainEndpoint(body, name);

    final scheme = m.group(1)!.toLowerCase();
    var rest = m.group(2) ?? '';
    var query = <String, String>{};
    final qAt = rest.indexOf('?');
    if (qAt >= 0) {
      query = _parseQuery(rest.substring(qAt + 1));
      rest = rest.substring(0, qAt);
    }

    switch (scheme) {
      case 'socks5':
      case 'socks5h':
      case 'socks':
      case 'http':
      case 'https':
        final a = _authority(rest, defaultPort: _defaultPorts[scheme] ?? 0);
        if (a == null) return null;
        return ProxyNode(
          type: scheme == 'socks' ? 'socks5' : scheme,
          host: a.host,
          port: a.port,
          name: name,
          username: a.user,
          password: a.pass,
        );
      case 'ss':
        return _parseSs(rest, name, query);
      case 'ssr':
        return _parseSsr(rest, name);
      case 'vmess':
        return _parseVm(rest, name);
      case 'vless':
        return _parseVless(rest, name, query);
      case 'trojan':
        return _parseTrojan(rest, name, query);
      case 'hysteria2':
      case 'hy2':
        return _parseHy2(rest, name, query);
      case 'tuic':
        return _parseTuic(rest, name, query);
    }
    return null;
  }

  static final RegExp _schemeRe = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://(.*)$');

  static final Map<String, int> _defaultPorts = {
    'http': 8080,
    'https': 8443,
    'socks5': 1080,
    'socks5h': 1080,
    'socks': 1080,
  };

  static ProxyNode? _plainEndpoint(String s, String name) {
    final a = _authority(s.trim(), defaultPort: 8080);
    if (a == null) return null;
    return ProxyNode(
      type: 'http',
      host: a.host,
      port: a.port,
      name: name,
      username: a.user,
      password: a.pass,
    );
  }

  static ProxyNode? _parseSs(
    String rest,
    String name,
    Map<String, String> query,
  ) {
    if (rest.isEmpty) return null;
    // SIP002: base64(method:password)@host:port ；旧式: base64(method:password@host:port)
    var hp = _hostPort(rest.substring(rest.lastIndexOf('@') + 1));
    String dec;
    if (rest.contains('@')) {
      dec = _b64decode(rest.substring(0, rest.lastIndexOf('@'))) ?? '';
    } else {
      dec = _b64decode(rest) ?? '';
    }
    if (dec.isEmpty) return null;
    final colon = dec.indexOf(':');
    if (colon < 0) return null;
    final cipher = dec.substring(0, colon);
    var tail = dec.substring(colon + 1);
    final at = tail.indexOf('@');
    if (at >= 0) {
      hp ??= _hostPort(tail.substring(at + 1));
      tail = tail.substring(0, at);
    }
    if (hp == null) return null;
    return ProxyNode(
      type: 'ss',
      host: hp.$1,
      port: hp.$2,
      name: name,
      password: tail,
      extras: {'cipher': cipher, ...query},
    );
  }

  static ProxyNode? _parseSsr(String rest, String name) {
    final dec = _b64decode(rest);
    if (dec == null) return null;
    // host:port:protocol:method:obfs:base64(password)/?query
    var slash = dec.indexOf('/');
    while (slash >= 0 && dec.substring(0, slash).split(':').length < 6) {
      slash = dec.indexOf('/', slash + 1);
    }
    final head = slash < 0 ? dec : dec.substring(0, slash);
    final tail = slash < 0 ? '' : dec.substring(slash + 1);
    final parts = head.split(':');
    if (parts.length < 6) return null;
    final port = int.tryParse(parts[1]);
    if (port == null || parts[0].isEmpty) return null;
    final extras = <String, String>{
      'protocol': parts[2],
      'method': parts[3],
      'obfs': parts[4],
    };
    final q = _parseQuery(tail);
    // remarks 就是 Clash 的节点名：没有 #fragment 时直接当展示名，不重复进 extras
    final remarks = q.remove('remarks');
    final nm = (name.isEmpty && remarks != null)
        ? (_b64decode(remarks) ?? remarks)
        : name;
    extras.addAll(q);
    return ProxyNode(
      type: 'ssr',
      host: parts[0],
      port: port,
      name: nm,
      password: _b64decode(parts[5]) ?? '',
      extras: extras,
    );
  }

  static ProxyNode? _parseVm(String rest, String name) {
    final obj = _jsonMap(_b64decode(rest));
    if (obj == null) return null;
    final add = _s(obj['add']);
    final server = _s(obj['server']);
    final host = add.isEmpty ? server : add;
    final port = _i(obj['port']);
    if (host.isEmpty || port <= 0) return null;
    final extras = <String, String>{};
    void put(String k, Object? v) {
      if (v == null) return;
      final s = _s(v);
      if (s.isNotEmpty) extras[k] = s;
    }

    put('uuid', obj['id']);
    put('alterId', obj['aid']);
    put('cipher', obj['scy'] ?? obj['cipher']);
    put('network', obj['net'] ?? obj['network']);
    put('type', obj['type']);
    put('tls', _boolStr(obj['tls']));
    put('sni', obj['sni']);
    put('encryption', obj['encryption']);
    put('flow', obj['flow']);
    put('headerType', obj['headerType']);
    put('headerValue', obj['headerValue']);
    put('serviceName', obj['serviceName']);
    put('hostHeader', obj['host']);
    put('path', obj['path']);
    return ProxyNode(
      type: 'vmess',
      host: host,
      port: port,
      name: name.isEmpty ? _s(obj['ps']) : name,
      extras: extras,
    );
  }

  static ProxyNode? _parseVless(
    String rest,
    String name,
    Map<String, String> query,
  ) {
    final at = rest.lastIndexOf('@');
    if (at < 0) return null;
    final uuid = _uriDecode(rest.substring(0, at)).trim();
    final hp = _hostPort(rest.substring(at + 1), defaultPort: 443);
    if (uuid.isEmpty || hp == null) return null;
    return ProxyNode(
      type: 'vless',
      host: hp.$1,
      port: hp.$2,
      name: name,
      extras: {'uuid': uuid, ...query},
    );
  }

  static ProxyNode? _parseTrojan(
    String rest,
    String name,
    Map<String, String> query,
  ) {
    final at = rest.lastIndexOf('@');
    if (at < 0) return null;
    final hp = _hostPort(rest.substring(at + 1), defaultPort: 443);
    if (hp == null) return null;
    return ProxyNode(
      type: 'trojan',
      host: hp.$1,
      port: hp.$2,
      name: name,
      password: _uriDecode(rest.substring(0, at)),
      extras: _withTls(query),
    );
  }

  static ProxyNode? _parseHy2(
    String rest,
    String name,
    Map<String, String> query,
  ) {
    final at = rest.lastIndexOf('@');
    if (at < 0) return null;
    final hp = _hostPort(rest.substring(at + 1), defaultPort: 443);
    if (hp == null) return null;
    final extras = Map<String, String>.from(query);
    final insecure = extras['insecure'];
    if (insecure != null) {
      extras['skip-cert-verify'] = _boolStr(insecure) == 'true'
          ? 'true'
          : insecure;
    }
    return ProxyNode(
      type: 'hysteria2',
      host: hp.$1,
      port: hp.$2,
      name: name,
      password: _uriDecode(rest.substring(0, at)),
      extras: extras,
    );
  }

  static ProxyNode? _parseTuic(
    String rest,
    String name,
    Map<String, String> query,
  ) {
    final at = rest.lastIndexOf('@');
    if (at < 0) return null;
    final hp = _hostPort(rest.substring(at + 1), defaultPort: 443);
    if (hp == null) return null;
    final info = rest.substring(0, at);
    final colon = info.indexOf(':');
    final uuid = _uriDecode(colon < 0 ? info : info.substring(0, colon));
    final pass = _uriDecode(colon < 0 ? '' : info.substring(colon + 1));
    return ProxyNode(
      type: 'tuic',
      host: hp.$1,
      port: hp.$2,
      name: name,
      password: pass,
      extras: {'uuid': uuid, ...query},
    );
  }

  static Map<String, String> _withTls(Map<String, String> query) {
    final q = Map<String, String>.from(query);
    final sec = _s(q['security']).toLowerCase();
    if (sec == 'tls' || sec == 'reality') q['tls'] = 'true';
    if (sec == 'none') q['tls'] = 'false';
    return q;
  }

  // ---- 管理 ----

  /// 删除分组，并清理指向它的用途绑定。
  void removeGroup(String name) {
    groups.removeWhere((g) => g.name == name);
    assignments.removeWhere((_, v) => v == name);
    notifyListeners();
  }

  /// 从指定分组移除节点；池中再无引用时连带清掉健康度。
  /// 同时记入该组排除名单：之后订阅刷新不会把这个节点再加回来。
  void removeNode(String groupName, String nodeId) {
    for (final g in groups) {
      if (g.name != groupName) continue;
      g.nodes.removeWhere((n) => n.id == nodeId);
      g.excludedNodeIds.add(nodeId);
      if (g.pinnedNodeId == nodeId) g.pinnedNodeId = null;
    }
    if (!allNodes.any((n) => n.id == nodeId)) health.remove(nodeId);
    notifyListeners();
  }

  /// 设置分组自动刷新间隔（小时，1–168）。
  void setGroupRefreshInterval(String groupName, int hours) {
    final g = _groupNamed(groupName);
    if (g == null) return;
    g.refreshIntervalHours = hours.clamp(1, 168);
    notifyListeners();
  }

  /// 重命名分组，同步改写指向旧名的用途绑定。
  void renameGroup(String oldName, String newName) {
    if (oldName == newName) return;
    for (final g in groups) {
      if (g.name == oldName) g.name = newName;
    }
    // MapEntry 不可变，先收集要改写的键再统一覆盖
    final fixes = <String, String>{};
    for (final e in assignments.entries) {
      if (e.value == oldName) fixes[e.key] = newName;
    }
    assignments.addAll(fixes);
    notifyListeners();
  }

  /// 设置分组轮换策略（'round-robin' | 'latency'，其余值按 round-robin 处理）。
  void setStrategy(String name, String strategy) {
    final g = _groupNamed(name);
    if (g == null) return;
    final s = strategy == 'latency' ? 'latency' : 'round-robin';
    if (g.strategy == s) return;
    g.strategy = s;
    notifyListeners();
  }

  /// 绑定用途到分组；groupName 为 null 或空白时清除绑定。
  void assign(String purpose, String? groupName) {
    if (groupName == null || groupName.trim().isEmpty) {
      assignments.remove(purpose);
    } else {
      assignments[purpose] = groupName.trim();
    }
    _cursor.remove(purpose);
    notifyListeners();
  }

  /// 用途当前指向的分组名；未绑定或分组已不存在时返回 null。
  String? groupFor(String purpose) {
    final name = assignments[purpose];
    if (name == null) return null;
    return _groupNamed(name) == null ? null : name;
  }

  /// 设置用途是否走代理。true 时从 enabledFlags 移除（缺省即启用），保持 JSON 干净。
  void setEnabled(String purpose, bool enabled) {
    if (enabled) {
      enabledFlags.remove(purpose);
    } else {
      enabledFlags[purpose] = false;
    }
    notifyListeners();
  }

  /// 用途是否启用代理，缺省 true。
  bool isEnabled(String purpose) => enabledFlags[purpose] ?? true;

  // ---- 轮换 ----

  /// 轮换取一个 findProxy 指令。
  ///
  /// 依次判定：用途开关关闭 → null；未绑定分组或分组不存在 → null；组内无可
  /// 拨节点 → null。跳过 [failLimit] 次失败且 [cooldown] 未过的节点。
  /// 组内按 strategy 取：round-robin 轮询，latency 始终取最优；除游标推进外
  /// 无其他副作用（不 notifyListeners）。
  /// 组内钉了节点（[ProxyGroup.pinnedNodeId]）时只出该节点——手动指定出口，
  /// 钉的节点冷却中则回退全组轮换。
  ///
  /// 返回的指令可直接赋给 `HttpClient.findProxy`：http/https 节点为原生指令；
  /// socks5 节点需 [relayHub] 已预热（[prepareRelays]），此时出本地中转指令。
  String? pickDirective(String purpose) {
    if (!isEnabled(purpose)) return null;
    final name = groupFor(purpose);
    if (name == null) return null;
    final group = _groupNamed(name);
    if (group == null) return null;

    final now = DateTime.now();
    final cand = <ProxyNode>[];
    for (final n in group.nodes) {
      if (directiveOf(n) == null) continue;
      if (_inCooldown(n, now)) continue;
      cand.add(n);
    }
    if (cand.isEmpty) return null;

    // 手动钉节点：只出它（不可拨/冷却时回退全组轮换）
    final pin = group.pinnedNodeId;
    if (pin != null) {
      for (final n in cand) {
        if (n.id == pin) return directiveOf(n);
      }
    }

    if (group.strategy == 'latency') {
      // 对齐 Clash url-test 语义：始终走最优节点，不做轮询；
      // 未探到延迟的节点排最后（等探活结果回来再决定）
      cand.sort((a, b) => _latencyOf(a).compareTo(_latencyOf(b)));
      return directiveOf(cand.first);
    }
    final idx = (_cursor[purpose] ?? 0) % cand.length;
    _cursor[purpose] = (_cursor[purpose] ?? 0) + 1;
    return directiveOf(cand[idx]);
  }

  bool _inCooldown(ProxyNode n, DateTime now) {
    final h = health[n.id];
    if (h == null || h.failCount < failLimit) return false;
    final last = h.lastChecked;
    if (last == null) return false;
    return now.difference(last) < cooldown;
  }

  int _latencyOf(ProxyNode n) {
    final v = health[n.id]?.latencyMs;
    return (v == null || v < 0) ? _sortLatencyMax : v;
  }

  /// 上报一次探测结果。ok=true 时清零失败计数并记录延迟；ok=false 累计失败数。
  void report(String nodeId, bool ok, {int? latencyMs}) {
    final h = health.putIfAbsent(nodeId, () => NodeHealth());
    h.lastChecked = DateTime.now();
    if (ok) {
      h.failCount = 0;
      if (latencyMs != null) h.latencyMs = latencyMs;
    } else {
      h.failCount += 1;
    }
    notifyListeners();
  }

  /// 网关请求路径的健康度上报。与 [report] 的差别在广播频率：请求成功是
  /// 高频事件，只在真的清零了失败计数时才 notify（否则每个请求都会让
  /// 监听池的整页 UI 无谓重建）；失败总是广播（冷却状态可能变化）。
  void noteEgress(String nodeId, bool ok) {
    final h = health.putIfAbsent(nodeId, () => NodeHealth());
    h.lastChecked = DateTime.now();
    if (ok) {
      if (h.failCount > 0) {
        h.failCount = 0;
        notifyListeners();
      }
    } else {
      h.failCount += 1;
      notifyListeners();
    }
  }

  /// 当前 UTC 日期（额度重置口径）：yyyy-MM-dd。
  static String quotaToday() {
    final d = DateTime.now().toUtc();
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  /// 标记节点当天 zen 免费额度耗尽（按出口 IP × 天计，UTC 零点自动翻篇）。
  void markQuotaSpent(String nodeId) {
    final h = health.putIfAbsent(nodeId, () => NodeHealth());
    if (h.quotaDay == quotaToday()) return;
    h.quotaDay = quotaToday();
    notifyListeners();
  }

  /// 清除某节点今天的额度标记（池里全部拉黑后重头轮换用）。
  void clearQuotaSpent(String nodeId) {
    final h = health[nodeId];
    if (h == null || h.quotaDay == null) return;
    h.quotaDay = null;
    notifyListeners();
  }

  /// 节点今天（UTC）是否已被判定额度耗尽。
  bool isQuotaSpent(String nodeId) =>
      health[nodeId]?.quotaDay == quotaToday();

  // ---- 自动巡检 ----

  Timer? _autoProbe;
  bool _autoProbing = false;

  /// 启动后台可达性巡检：每 [interval] 并发拨一遍全池节点（cp.cloudflare
  /// 的 generate_204，8s 超时），成功即清零失败计数、解禁冷却。用户不再
  /// 需要手动「逐个刷新」——坏节点几秒内被轮换跳过，修好后一分钟内自动
  /// 回到候选里。并发上限 8：22+ 节点串行要 3 分钟，太慢；全并发又可能
  /// 瞬时打爆本机上行。重复调用安全（已在跑则忽略）。
  void startAutoProbe({Duration interval = const Duration(seconds: 60)}) {
    if (_autoProbe != null) return;
    _autoProbe = Timer.periodic(interval, (_) => unawaited(autoProbeOnce()));
  }

  void stopAutoProbe() {
    _autoProbe?.cancel();
    _autoProbe = null;
  }

  @override
  void dispose() {
    stopAutoProbe();
    super.dispose();
  }

  /// 立即巡检一轮（首启/池变化时可主动调）；并发中重入直接跳过。
  Future<void> autoProbeOnce() async {
    if (_autoProbing) return;
    _autoProbing = true;
    try {
      final seen = <String>{};
      final targets = <ProxyNode>[];
      for (final g in groups) {
        for (final n in g.nodes) {
          if (!seen.add(n.id)) continue;
          if (directiveOf(n) == null) continue;
          targets.add(n);
        }
      }
      for (var i = 0; i < targets.length; i += 8) {
        final batch = targets.skip(i).take(8);
        final results = await Future.wait([
          for (final n in batch) _probeReachable(n),
        ]);
        for (var j = 0; j < batch.length; j++) {
          final n = batch.elementAt(j);
          final (ok, ms) = results[j];
          // 巡检成功清零失败计数并记延迟（冷却随之解除）。不走 report()：
          // 它每节点都 notify 一次，22+ 节点会连发 20 多次 UI 重建
          final hh = health.putIfAbsent(n.id, () => NodeHealth());
          hh.lastChecked = DateTime.now();
          if (ok) {
            hh.failCount = 0;
            hh.latencyMs = ms;
          }
          // 巡检失败只记时间戳，不累加 failCount：瞬时抖动不该把正在服务
          // 的节点踢出轮换；真坏了的节点由请求路径 noteEgress 计数
        }
      }
      // 巡检刷新了延迟/解禁冷却：广播让 UI 的可达性圆点即时更新；
      // 生产环境里 _onPoolChanged 监听器会顺带落盘，这里不显式 save()
      // （避免测试没有注入 savePath 时误写真实 proxies.json）。
      if (targets.isNotEmpty) {
        notifyListeners();
      }
    } finally {
      _autoProbing = false;
    }
  }

  /// 可达性探测目标：默认走 Cloudflare 的 generate_204（轻量、无副作用、
  /// 任何出口都能判活）。测试注入本地假上游以离线验证；运行态不序列化。
  static String probeTarget = 'http://cp.cloudflare.com/generate_204';

  Future<(bool, int)> _probeReachable(ProxyNode n) async {
    final directive = directiveOf(n);
    if (directive == null) return (false, -1);
    final sw = Stopwatch()..start();
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 6)
        ..findProxy = (_) => directive;
      final req = await client.getUrl(Uri.parse(probeTarget));
      final resp = await req.close().timeout(const Duration(seconds: 8));
      await resp.drain<void>();
      sw.stop();
      client.close(force: true);
      return (resp.statusCode == 204, sw.elapsedMilliseconds);
    } catch (_) {
      sw.stop();
      return (false, -1);
    }
  }

  // ---- 序列化 ----

  /// 序列化。节点去重后存一份，分组只存 nodeIds 引用，不重复存副本。
  Map<String, dynamic> toJson() => {
    'nodes': [for (final n in allNodes) n.toJson()],
    'groups': [
      for (final g in groups)
        {
          'name': g.name,
          'strategy': g.strategy,
          'nodeIds': [for (final n in g.nodes) n.id],
          if (g.sourceUrl.isNotEmpty) 'sourceUrl': g.sourceUrl,
          if (g.lastRefreshAt != null)
            'lastRefreshAt': g.lastRefreshAt!.toIso8601String(),
          if (!g.autoRefresh) 'autoRefresh': false,
          if (g.refreshIntervalHours != 6)
            'refreshIntervalHours': g.refreshIntervalHours,
          if (g.pinnedNodeId != null) 'pinnedNodeId': g.pinnedNodeId,
          if (g.excludedNodeIds.isNotEmpty)
            'excludedNodeIds': g.excludedNodeIds.toList(),
        },
    ],
    'assignments': Map<String, dynamic>.from(assignments),
    if (enabledFlags.isNotEmpty)
      'enabledFlags': Map<String, dynamic>.from(enabledFlags),
    'health': {for (final e in health.entries) e.key: e.value.toJson()},
  };

  factory ProxyPool.fromJson(Map<String, dynamic> j) {
    final nodeById = <String, ProxyNode>{};
    for (final e in _list(j['nodes'])) {
      final m = e is Map ? e : null;
      if (m == null) continue;
      final n = ProxyNode.fromJson(_strKeys(m));
      nodeById[n.id] = n;
    }
    final groups = <ProxyGroup>[];
    for (final e in _list(j['groups'])) {
      final m = e is Map ? e : null;
      if (m == null) continue;
      final name = _s(m['name']);
      if (name.isEmpty) continue;
      final ids = _list(m['nodeIds']);
      final nodes = <ProxyNode>[];
      for (final id in ids) {
        final n = nodeById[_s(id)];
        if (n != null) nodes.add(n);
      }
      if (nodes.isEmpty) continue;
      final strategy = _s(m['strategy']);
      groups.add(
        ProxyGroup(
          name: name,
          nodes: nodes,
          strategy: strategy.isEmpty ? 'round-robin' : strategy,
          sourceUrl: _s(m['sourceUrl']),
          lastRefreshAt: DateTime.tryParse(_s(m['lastRefreshAt'])),
          autoRefresh: m['autoRefresh'] != false,
          refreshIntervalHours:
              (m['refreshIntervalHours'] as num?)?.toInt() ?? 6,
          pinnedNodeId: _s(m['pinnedNodeId']).isEmpty
              ? null
              : _s(m['pinnedNodeId']),
          excludedNodeIds: {
            for (final id in _list(m['excludedNodeIds'])) _s(id),
          }..removeWhere((id) => id.isEmpty),
        ),
      );
    }
    final pool = ProxyPool(groups: groups);
    for (final e in _strKeys(_map(j['assignments']) ?? const {}).entries) {
      pool.assignments[e.key] = e.value;
    }
    for (final e
        in _map(j['enabledFlags'])?.entries ??
            const <MapEntry<String, dynamic>>[]) {
      pool.enabledFlags[e.key] = e.value == true;
    }
    for (final e
        in _map(j['health'])?.entries ?? const <MapEntry<String, dynamic>>[]) {
      final m = e.value is Map ? e.value as Map : null;
      if (m == null) continue;
      pool.health[e.key] = NodeHealth.fromJson(_strKeys(m));
    }
    return pool;
  }

  // ---- 落盘 ----

  /// 默认配置文件路径：%APPDATA%\zeroapi\proxies.json（非 Windows：~/.config/zeroapi/）。
  static String defaultPath() => '${_dataDir().path}/proxies.json';

  static Directory _dataDir() {
    final base = Platform.isWindows
        ? Platform.environment['APPDATA']
        : '${Platform.environment['HOME'] ?? '.'}/.config';
    return Directory('${base ?? '.'}/zeroapi');
  }

  /// 从 JSON 文件加载。文件不存在或内容损坏时返回空池，不抛异常。
  static ProxyPool load({String? path}) {
    final f = File(path == null || path.isEmpty ? defaultPath() : path);
    if (!f.existsSync()) return ProxyPool();
    try {
      return ProxyPool.fromJson(
        _map(jsonDecode(f.readAsStringSync())) ?? const {},
      );
    } catch (_) {
      return ProxyPool();
    }
  }

  /// 保存为缩进 JSON，自动创建父目录。未显式传 path 时写入 [savePath]
  /// （运行态注入，不序列化；测试用它隔离到临时目录，生产为 null → 默认路径）。
  String? savePath;

  void save({String? path}) {
    final p = path == null || path.isEmpty ? (savePath ?? defaultPath()) : path;
    final f = File(p);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
  }

  // ---- 导出 ----

  /// 导出为 Clash YAML 文本（`proxies:` + `proxy-groups:`），可直接拷回用户的
  /// clash/mihomo 客户端。与本模块的 YAML 导入解析器对称：extras 里 `path` /
  /// `hostHeader` / `a.b` 点分键还原回 ws-opts / grpc-opts / plugin-opts 嵌套。
  String exportConfigText() {
    final sb = StringBuffer();
    sb.write('proxies:\n');
    for (final n in allNodes) {
      _writeProxyYaml(sb, n, n.name);
    }
    sb.write('proxy-groups:\n');
    for (final g in groups) {
      sb.write('  - name: ${_yval(g.name)}\n');
      sb.write('    type: url-test\n');
      sb.write('    proxies:\n');
      for (final n in g.nodes) {
        sb.write('      - ${_yval(n.name)}\n');
      }
    }
    return sb.toString();
  }

  /// 内置内核配置：每个加密协议节点独占一个本地 HTTP listener，只绑
  /// 127.0.0.1（不影响系统代理、不对局域网暴露）。listener 的 `proxy`
  /// 指向对应节点，因此 ProxyPool 的逐节点轮换仍然成立。
  /// [serverOverrides] 是 nodeId→真实 IP：开着 Clash TUN 时系统 DNS 会返回
  /// fake-ip，由调用方先用 DoH 解析好，这里直接写 IP（sni 保留原域名）。
  String coreConfigYaml(
    Map<String, int> ports, {
    Map<String, String> serverOverrides = const {},
    String? bindInterface,
  }) {
    final sb = StringBuffer();
    sb.write('allow-lan: false\n');
    sb.write('mode: global\n');
    // 绑定物理网卡：宿主自己开着 TUN（FlClash 等）时，TUN 虚拟网卡会抢走
    // 默认路由，内核出站被二次套代理 → 加密类节点握手超时、整池不可用。
    // 网卡名不存在时 mihomo 启动即报错，故只在探测到真实网卡时才写。
    if (bindInterface != null && bindInterface.isNotEmpty) {
      sb.write('interface-name: ${_yval(bindInterface)}\n');
    }
    sb.write('log-level: warning\n');
    // ipv6 保持开启：实测关掉后可用节点反而略少（部分 IPv6 节点在宿主
    // 有 IPv6 通路时是可用的）。宿主完全没有 IPv6 出口时，由 directiveOf()
    // 提前跳过纯 IPv6 节点（见 HostNetwork.hasIpv6Egress）——那条路更准。
    sb.write('ipv6: true\n');
    sb.write('proxies:\n');
    final picked = <ProxyNode>[];
    for (final n in allNodes) {
      final port = ports[n.id];
      if (port == null || port <= 0) continue;
      picked.add(n);
      // QUIC 类协议（hysteria2/tuic）必须开 udp：listener 出站走的是
      // DialContext 的 UDP 路径，写 udp: false 会让 listener 一律
      // "context deadline exceeded"（mixed-port 却正常，实测 v1.19.32）。
      final quic = const {'hysteria2', 'tuic'}.contains(n.type.toLowerCase());
      _writeProxyYaml(
        sb,
        n,
        'n_${n.id}',
        server: serverOverrides[n.id],
        extraLines: [quic ? 'udp: true' : 'udp: false'],
      );
    }
    sb.write('listeners:\n');
    for (final n in picked) {
      sb.write('  - name: ${_yval('l_${n.id}')}\n');
      sb.write('    type: http\n');
      sb.write('    listen: 127.0.0.1\n');
      sb.write('    port: ${ports[n.id]}\n');
      sb.write('    proxy: ${_yval('n_${n.id}')}\n');
    }
    return sb.toString();
  }

  /// 写一个 Clash `proxies` 条目（导出与内置内核共用同一套字段规则）。
  /// [server] 给内置内核用：把域名换成 DoH 解析出的真实 IP；此时若节点没写
  /// sni，补上原域名，否则 TLS/QUIC 握手会拿 IP 当 SNI 直接被服务端拒掉。
  void _writeProxyYaml(
    StringBuffer sb,
    ProxyNode n,
    String name, {
    List<String> extraLines = const [],
    String? server,
  }) {
    final host = server ?? n.host;
    sb.write('  - name: ${_yval(name)}\n');
    sb.write('    type: ${_yval(n.type)}\n');
    sb.write('    server: ${_yval(host)}\n');
    sb.write('    port: ${n.port}\n');
    if (host != n.host && _needsSni(n)) {
      sb.write('    sni: ${_yval(n.host)}\n');
    }
    if (n.username.isNotEmpty) sb.write('    username: ${_yval(n.username)}\n');
    if (n.password.isNotEmpty) sb.write('    password: ${_yval(n.password)}\n');
    // ws/grpc 的 path 必须落在 ws-opts / grpc-opts 下（Clash 不认顶层 path）
    final net = _s(n.extras['network'] ?? n.extras['type']).toLowerCase();
    final optsPrefix = net == 'ws'
        ? 'ws-opts'
        : (net == 'grpc' ? 'grpc-opts' : null);
    final opts = <String, Map<String, String>>{};
    for (final e in n.extras.entries) {
      final key = e.key;
      if (key == 'hostHeader' || (key == 'host' && net == 'ws')) {
        // Clash 用 ws-opts.headers.Host 表达 ws 的 Host 头
        opts.putIfAbsent('ws-opts', () => <String, String>{})['Host'] = e.value;
      } else if (key == 'path' && optsPrefix != null) {
        opts.putIfAbsent(optsPrefix, () => <String, String>{})['path'] =
            e.value;
      } else if (_clashSkipKeys.contains(key)) {
        // vmess/vless 的 header type 等字段 Clash 没有对应顶层键，写出来会和
        // 上面的 type: <协议> 撞成重复键，整份 YAML 会解析失败——只能丢弃
        continue;
      } else if (key == 'alpn') {
        // mihomo 要求 alpn 是字符串数组；分享链接里是逗号分隔（如 h3,h2）
        final items = e.value
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .map(_yval)
            .join(', ');
        sb.write('    alpn: [$items]\n');
      } else if (key == 'method' && n.type.toLowerCase() == 'ssr') {
        // SSR 分享链接里叫 method，Clash/mihomo 的字段名是 cipher
        sb.write('    cipher: ${_yval(e.value)}\n');
      } else {
        final dot = key.indexOf('.');
        if (dot > 0 && dot < key.length - 1) {
          opts.putIfAbsent(
            key.substring(0, dot),
            () => <String, String>{},
          )[key.substring(dot + 1)] = e.value;
        } else {
          sb.write('    ${_yamlKey(key)}: ${_yval(e.value)}\n');
        }
      }
    }
    for (final o in opts.entries) {
      sb.write('    ${_yamlKey(o.key)}:\n');
      final headers = <String, String>{};
      for (final e in o.value.entries) {
        if (e.key == 'Host' && o.key == 'ws-opts') {
          headers[e.key] = e.value;
        } else {
          sb.write('      ${_yamlKey(e.key)}: ${_yval(e.value)}\n');
        }
      }
      if (headers.isNotEmpty) {
        sb.write('      headers:\n');
        for (final e in headers.entries) {
          sb.write('        ${_yamlKey(e.key)}: ${_yval(e.value)}\n');
        }
      }
    }
    for (final line in extraLines) {
      sb.write('    $line\n');
    }
  }

  /// 把域名换成 IP 后，TLS 类节点需要显式 sni 才能正常握手。
  static bool _needsSni(ProxyNode n) {
    if (n.extras.containsKey('sni') || n.extras.containsKey('servername')) {
      return false;
    }
    final type = n.type.toLowerCase();
    if (const {'trojan', 'hysteria2', 'tuic'}.contains(type)) return true;
    if (_s(n.extras['tls']).toLowerCase() == 'true') return true;
    final sec = _s(n.extras['security']).toLowerCase();
    return sec == 'tls' || sec == 'reality';
  }

  static final RegExp _yamlKeyRe = RegExp(r'^[A-Za-z_][A-Za-z0-9_-]*$');

  static String _yamlKey(String k) => _yamlKeyRe.hasMatch(k) ? k : _yval(k);

  static String _yval(String v) {
    if (v == 'true' || v == 'false' || v == 'null') return v;
    if (int.tryParse(v) != null || double.tryParse(v) != null) return v;
    return jsonEncode(v);
  }
}

// ---------------------------------------------------------------------------
// 出口链路接入
// ---------------------------------------------------------------------------

/// 某用途在池中的全部可拨指令（供 def.directives 合并）。
///
/// round-robin 组返回组内全量候选（跳过冷却中/无指令节点，保持组内顺序，
/// 让调用方自己的轮换游标跨节点转动）；latency 组按延迟升序返回。
/// 未绑定/关闭/无候选 → 空列表。
///
/// 与 [ProxyPool.pickDirective] 同源同规则：socks5 节点只有 [relayHub] 已
/// 设置且预热过时才带出本地中转指令（[ProxyPool.directiveOf] 返回 null 即
/// 跳过），绝不产出会抛异常的 SOCKS5 前缀。
List<String> poolDirectivesFor(ProxyPool? pool, String purpose) => [
  for (final c in poolCandidatesFor(pool, purpose)) c.directive,
];

/// 一条出口候选：findProxy 指令 + 来源节点 id（网关连接失败时按 id 上报
/// 健康度，坏节点很快进冷却被跳过；手写地址没有 nodeId，上报不了）。
class PoolCandidate {
  final String directive;
  final String? nodeId;
  const PoolCandidate(this.directive, [this.nodeId]);
}

/// [poolDirectivesFor] 的带节点版本，语义完全一致。组内钉了节点时只出
/// 该节点（不可拨/冷却中回退全组）。
List<PoolCandidate> poolCandidatesFor(ProxyPool? pool, String purpose) {
  if (pool == null || !pool.isEnabled(purpose)) return const [];
  final name = pool.groupFor(purpose);
  if (name == null) return const [];
  final group = pool._groupNamed(name);
  if (group == null) return const [];
  final now = DateTime.now();
  final cand = <ProxyNode>[];
  for (final n in group.nodes) {
    if (pool.directiveOf(n) == null) continue;
    if (pool._inCooldown(n, now)) continue;
    cand.add(n);
  }
  if (cand.isEmpty) return const [];
  final pin = group.pinnedNodeId;
  if (pin != null) {
    for (final n in cand) {
      if (n.id == pin) return [PoolCandidate(pool.directiveOf(n)!, n.id)];
    }
  }
  if (group.strategy == 'latency') {
    cand.sort((a, b) => pool._latencyOf(a).compareTo(pool._latencyOf(b)));
  }
  return [for (final n in cand) PoolCandidate(pool.directiveOf(n)!, n.id)];
}

// ---------------------------------------------------------------------------
// 内部工具
// ---------------------------------------------------------------------------

/// latency 策略下未探到延迟的节点排到队尾。
const int _sortLatencyMax = 1 << 31;

/// 确定性短 hash（FNV-1a 32）：host:port:type → 8 位 hex，跨导入稳定。
String _stableId(String host, int port, String type) {
  final s = '$host:$port:${type.toLowerCase()}';
  var h = 0x811c9dc5;
  for (var i = 0; i < s.length; i++) {
    h ^= s.codeUnitAt(i);
    h = (h * 0x01000193) & 0x7fffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

String _s(Object? v) => (v ?? '').toString().trim();

int _i(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(_s(v)) ?? 0;
}

String _boolStr(Object? v) {
  if (v == null) return '';
  if (v is bool) return v ? 'true' : 'false';
  final s = _s(v).toLowerCase();
  switch (s) {
    case 'tls':
    case 'true':
    case '1':
    case 'on':
      return 'true';
    case 'none':
    case 'false':
    case '0':
    case 'off':
      return 'false';
    case '':
      return '';
  }
  return _s(v);
}

Map<String, String> _strMap(Object? v) {
  final m = _map(v);
  if (m == null) return const {};
  final out = <String, String>{};
  for (final e in m.entries) {
    if (e.value == null) continue;
    out[e.key] = e.value.toString();
  }
  return out;
}

Map<String, dynamic>? _map(Object? v) {
  if (v is! Map) return null;
  final out = <String, dynamic>{};
  for (final e in v.entries) {
    out[e.key.toString()] = e.value;
  }
  return out;
}

Map<String, dynamic> _strKeys(Map m) {
  final out = <String, dynamic>{};
  for (final e in m.entries) {
    out[e.key.toString()] = e.value;
  }
  return out;
}

List<Object> _list(Object? v) => v is List ? List<Object>.from(v) : const [];

/// 百分号解码（fragment 语义：`+` 是字面加号，不当空格），失败时原样返回。
String _uriDecode(String s) {
  final t = s.trim();
  if (t.isEmpty || !t.contains('%')) return t;
  try {
    return Uri.decodeComponent(t);
  } on FormatException {
    return t;
  }
}

Map<String, String> _parseQuery(String q) {
  final out = <String, String>{};
  // 容忍开头的 ? / ;（ssr 载荷里 query 紧跟在 / 之后，不带剥离）
  var s = q.trimLeft();
  while (s.isNotEmpty && (s.startsWith('?') || s.startsWith(';'))) {
    s = s.substring(1);
  }
  for (final pair in s.split('&')) {
    if (pair.isEmpty) continue;
    final eq = pair.indexOf('=');
    if (eq < 0) {
      out[_uriDecode(pair)] = '';
    } else {
      out[_uriDecode(pair.substring(0, eq))] = _uriDecode(
        pair.substring(eq + 1),
      );
    }
  }
  return out;
}

/// base64 单轮解码：字节按 UTF-8 还原，容错非标字符。失败返回 null。
String? _tryBase64(String s) {
  try {
    return utf8.decode(base64.decode(s), allowMalformed: true);
  } on FormatException {
    return null;
  }
}

/// base64 / base64url 解码：先补齐 `=`，urlsafe 字符归一后依次尝试解码。
/// 解码失败或空输入返回 null。
String? _b64decode(String s) {
  var t = s.trim().replaceAll(RegExp(r'\s'), '');
  if (t.isEmpty) return null;
  while (t.length % 4 != 0) {
    t += '=';
  }
  // 依次尝试 urlsafe→标准 与 原样，命中即返回
  return _tryBase64(t.replaceAll('-', '+').replaceAll('_', '/')) ??
      _tryBase64(t);
}

Map<String, dynamic>? _jsonMap(String? s) {
  if (s == null) return null;
  try {
    final o = jsonDecode(s);
    return o is Map ? _strKeys(o) : null;
  } on FormatException {
    return null;
  }
}

Map? _yaml(String text) {
  try {
    final y = loadYaml(text);
    return y is Map ? y : null;
  } on Exception {
    return null;
  }
}

/// 解析 `[user[:pass]@]host:port`，host 支持 `[ipv6]`。缺端口且给了 [defaultPort]
/// 时补默认端口。
({String user, String pass, String host, int port})? _authority(
  String s, {
  int defaultPort = 0,
}) {
  var user = '';
  var pass = '';
  var addr = s.trim();
  final at = addr.lastIndexOf('@');
  if (at >= 0) {
    final info = addr.substring(0, at);
    addr = addr.substring(at + 1);
    final colon = info.indexOf(':');
    if (colon < 0) {
      user = _uriDecode(info);
    } else if (colon > 0) {
      user = _uriDecode(info.substring(0, colon));
      pass = _uriDecode(info.substring(colon + 1));
    } else {
      pass = _uriDecode(info.substring(1));
    }
  }
  final hp = _hostPort(addr, defaultPort: defaultPort);
  if (hp == null) return null;
  return (user: user, pass: pass, host: hp.$1, port: hp.$2);
}

/// 解析 `host:port` 或 `[ipv6]:port`。
(String, int)? _hostPort(String s, {int defaultPort = 0}) {
  var t = s.trim();
  if (t.isEmpty) return null;
  // 分享链接常写成 `host:443/?sni=...`（端口后跟斜杠路径）。查询串已在
  // parseShareLink 里剥离，这里再剥掉路径段，否则端口会解析成 "443/" 而
  // 整条节点被丢弃（hysteria2 订阅几乎全部是这种写法）。
  final slash = t.indexOf('/');
  if (slash >= 0) t = t.substring(0, slash).trim();
  if (t.isEmpty) return null;
  String host;
  String portStr;
  if (t.startsWith('[')) {
    final end = t.indexOf(']');
    if (end < 0) return null;
    host = t.substring(1, end);
    portStr = t.substring(end + 1);
    if (portStr.startsWith(':')) portStr = portStr.substring(1);
  } else {
    final colon = t.lastIndexOf(':');
    if (colon <= 0) {
      return defaultPort > 0 ? (t, defaultPort) : null;
    }
    host = t.substring(0, colon);
    portStr = t.substring(colon + 1);
  }
  final parsed = int.tryParse(portStr.trim());
  final port =
      parsed ?? (portStr.isEmpty && defaultPort > 0 ? defaultPort : null);
  if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
  return (host, port);
}

/// 解包订阅响应体：机场订阅通常是整段 base64（可能 URL-safe、缺填充、
/// 带换行），解出来才是逐行分享链接；也兼容直接返回明文分享链接或
/// Clash YAML 的订阅。判定标准是「能解出含 :// 的行」，避免把明文
/// 误当 base64 再解出乱码。
String unwrapSubscriptionBody(String body) {
  final text = body.trim();
  bool looksPlain(String s) =>
      s.contains('://') ||
      s.contains('proxies:') ||
      s.contains('proxy-groups:');
  if (looksPlain(text)) return text;

  // 去掉所有空白，统一 URL-safe 字母表，补齐到 4 的倍数
  var b64 = text.replaceAll(RegExp(r'\s'), '');
  b64 = b64.replaceAll('-', '+').replaceAll('_', '/');
  final pad = b64.length % 4;
  if (pad == 1) return text; // 不可能合法，原样交回让解析器报错
  if (pad > 0) b64 = b64.padRight(b64.length + (4 - pad), '=');
  try {
    final decoded = utf8.decode(base64.decode(b64));
    return looksPlain(decoded) ? decoded.trim() : text;
  } catch (_) {
    return text;
  }
}
