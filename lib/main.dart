import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'account_page.dart';
import 'gateway/service.dart';
import 'pages.dart';

void main() {
  final service = GatewayService();
  service.start();
  runApp(ZeroApiApp(service));
}

class ZeroApiApp extends StatelessWidget {
  final GatewayService service;
  const ZeroApiApp(this.service, {super.key});

  /// 主题缓存：service 通知（代理探测、健康轮询等，频率高）每次都会重建
  /// MaterialApp——ThemeData 每次新建是全量合成，代价大且会让继承主题的
  /// 深比较（即使 identical 短路前也要走一遍字段）变贵。按亮度只建一次，
  /// 之后重建 MaterialApp 时拿到 identical 实例，InheritedTheme 直接跳过
  /// 整棵子树的重样式（花屏/闪屏的放大器之一）。
  static final Map<Brightness, ThemeData> _themes = {
    Brightness.light: ThemeData(
      useMaterial3: true,
      fontFamily: 'LXGWWenKaiLite',
      colorSchemeSeed: const Color(0xFF4F6BED),
      brightness: Brightness.light,
    ),
    Brightness.dark: ThemeData(
      useMaterial3: true,
      fontFamily: 'LXGWWenKaiLite',
      colorSchemeSeed: const Color(0xFF4F6BED),
      brightness: Brightness.dark,
    ),
  };

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) => MaterialApp(
        title: 'ZeroApi',
        debugShowCheckedModeBanner: false,
        theme: _themes[Brightness.light]!,
        darkTheme: _themes[Brightness.dark]!,
        themeMode: switch (service.config.themeMode) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        home: HomePage(service: service),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  final GatewayService service;
  const HomePage({super.key, required this.service});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _index = 0;
  bool _banPromptOpen = false;
  DateTime _lastBanPrompt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 各页懒挂载 + 常驻：`IndexedStack` 让访问过的页**保持 State**（滚动位置、
  /// 展开状态不丢），切页不再销毁重建——旧实现切页=旧 State 销毁+新 State
  /// 从头 build，视觉上就是一次「整页闪一下回到顶部」（闪屏来源之一）。
  /// 首次访问才真正挂载（`_visited`），启动时不一次性建满 6 个页。
  final Set<int> _visited = {0};

  /// 页面列表只建一次：service 每次 notifyListeners 都会触发本 State 的
  /// build，若在 build 里 new 出六个页，所有子孙 Element 每次都要做
  /// canUpdate 比对+重建 widget 树。缓存实例后，重建路径只剩当前页的
  /// 内容 build（那部分是状态驱动的，必须重建）。
  late final List<Widget> _pages = [
    UpstreamsPage(service: widget.service),
    ModelsPage(service: widget.service),
    UsagePage(service: widget.service),
    AccountPage(service: widget.service),
    ProxyPoolPage(service: widget.service),
    SettingsPage(service: widget.service),
  ];

  /// 原生 → Dart 通道：托盘菜单的「重启网关」由此进来
  static const _hostChannel = MethodChannel('zeroapi/host');

  @override
  void initState() {
    super.initState();
    _hostChannel.setMethodCallHandler((call) async {
      if (call.method == 'restartGateway') {
        await _restartGateway();
      }
      return null;
    });
    // 出口 IP 被封时（每次封锁只问一次）：征询用户启用出口代理/部署 Worker
    widget.service.onIpBanDetected = (upstreamId) {
      if (_banPromptOpen || !mounted) return;
      // 经代理链路时 403 是「随机坏节点」性质的偶发事件，别频繁弹窗：
      // 同一会话内最多 10 分钟问一次
      if (DateTime.now().difference(_lastBanPrompt).inMinutes < 10) return;
      _lastBanPrompt = DateTime.now();
      final zen = widget.service.config.upstreams
          .where((u) => u.type == 'zen')
          .toList();
      final u = zen.isEmpty ? null : zen.first;
      // 已启用出口代理时：还没切 Worker 才建议部署；都配齐了不再打扰
      final viaWorker = u != null && !u.baseUrl.contains('opencode.ai');
      if (u == null || (u.proxyEnabled && viaWorker)) return;
      _banPromptOpen = true;
      // 等当前帧结束再弹（回调来自网关 isolate 事件）
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('出口 IP 被上游临时封锁'),
            content: Text(
              u.proxyEnabled
                  ? '已开启出口代理但当前出口仍被 OpenCode 标记。\n\n'
                        '建议「一键部署 Cloudflare Worker」：流量走 Cloudflare 的'
                        '海量边缘 IP 池，OpenCode 封不完，比机场固定节点更稳'
                        '（免费账号即可；workers.dev 域名仍需借助当前代理可达）。'
                        '或者在代理端换一个干净的节点/地区。'
                  : 'OpenCode 检测到本机出口 IP 的滥用流量，免费通道暂时不可用'
                        '（与账号无关，多为短时风控）。\n\n要开启「出口换 IP」吗？'
                        '两种方式任选其一：\n'
                        '· 设置 → 出口代理：填本地代理地址（如 Clash 的 127.0.0.1:7890），'
                        '经代理换干净 IP\n'
                        '· 一键部署 Cloudflare Worker：流量走 Cloudflare 的海量边缘 IP，'
                        '最稳（免费账号即可；workers.dev 域名需借助代理可达）',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('暂不处理'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('去设置'),
              ),
            ],
          ),
        );
        _banPromptOpen = false;
        if (go == true && mounted) {
          // 「账号」页插在「用量」之后，设置页下标由 4 变成 5
          setState(() => _index = 5); // 切到「设置」tab（出口代理/一键部署都在那）
        }
      });
    };
  }

  @override
  void dispose() {
    widget.service.onIpBanDetected = null;
    _hostChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _restartGateway() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在重启网关…'), duration: Duration(seconds: 2)),
    );
    await widget.service.restartServer();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.service.running
              ? '网关已重启'
              : '网关重启失败：${widget.service.startError ?? '未知原因'}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                const Text(
                  'ZeroApi',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: s.running
                        ? cs.secondaryContainer
                        : cs.errorContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        s.running ? Icons.check_circle : Icons.error,
                        size: 14,
                        color: s.running ? Colors.green : cs.error,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        s.running ? '网关运行中' : '未运行',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: '重启网关',
                icon: const Icon(Icons.restart_alt),
                onPressed: _restartGateway,
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() {
                  _index = i;
                  _visited.add(i);
                }),
                labelType: NavigationRailLabelType.all,
                extended: MediaQuery.of(context).size.width > 900,
                minExtendedWidth: 150,
                destinations: const [
                  NavigationRailDestination(
                    icon: Icon(Icons.dns_outlined),
                    selectedIcon: Icon(Icons.dns),
                    label: Text('供应商'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.view_list_outlined),
                    selectedIcon: Icon(Icons.view_list),
                    label: Text('模型'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.query_stats_outlined),
                    selectedIcon: Icon(Icons.query_stats),
                    label: Text('用量'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.manage_accounts_outlined),
                    selectedIcon: Icon(Icons.manage_accounts),
                    label: Text('账号'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.alt_route_outlined),
                    selectedIcon: Icon(Icons.alt_route),
                    label: Text('代理'),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: Text('设置'),
                  ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: IndexedStack(
                  index: _index,
                  children: [
                    // 未访问过的页先占位：首次切过去才真正挂载（省启动开销）
                    for (var i = 0; i < _pages.length; i++)
                      _visited.contains(i)
                          ? _pages[i]
                          : const SizedBox.shrink(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
