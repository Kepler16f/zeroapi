import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) => MaterialApp(
        title: 'ZeroApi',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'LXGWWenKaiLite',
          colorSchemeSeed: const Color(0xFF4F6BED),
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          fontFamily: 'LXGWWenKaiLite',
          colorSchemeSeed: const Color(0xFF4F6BED),
          brightness: Brightness.dark,
        ),
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

  @override
  void initState() {
    super.initState();
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
      final viaWorker =
          u != null && !u.baseUrl.contains('opencode.ai');
      if (u == null || (u.proxyEnabled && viaWorker)) return;
      _banPromptOpen = true;
      // 等当前帧结束再弹（回调来自网关 isolate 事件）
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('出口 IP 被上游临时封锁'),
            content: Text(u.proxyEnabled
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
                    '最稳（免费账号即可；workers.dev 域名需借助代理可达）'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('暂不处理')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('去设置')),
            ],
          ),
        );
        _banPromptOpen = false;
        if (go == true && mounted) {
          setState(() => _index = 3); // 切到「设置」tab（出口代理/一键部署都在那）
        }
      });
    };
  }

  @override
  void dispose() {
    widget.service.onIpBanDetected = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.service;
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final pages = [
          UpstreamsPage(service: s),
          ModelsPage(service: s),
          UsagePage(service: s),
          SettingsPage(service: s),
        ];
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                const Text('ZeroApi',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 12),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color:
                        s.running ? cs.secondaryContainer : cs.errorContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(children: [
                    Icon(s.running ? Icons.check_circle : Icons.error,
                        size: 14,
                        color: s.running ? Colors.green : cs.error),
                    const SizedBox(width: 6),
                    Text(s.running ? '网关运行中' : '未运行',
                        style: const TextStyle(fontSize: 12)),
                  ]),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: '立即刷新供应商与路由',
                icon: const Icon(Icons.refresh),
                onPressed: () => s.refreshRoutesNow(),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
                labelType: NavigationRailLabelType.all,
                extended: MediaQuery.of(context).size.width > 900,
                minExtendedWidth: 150,
                destinations: const [
                  NavigationRailDestination(
                      icon: Icon(Icons.dns_outlined),
                      selectedIcon: Icon(Icons.dns),
                      label: Text('供应商')),
                  NavigationRailDestination(
                      icon: Icon(Icons.view_list_outlined),
                      selectedIcon: Icon(Icons.view_list),
                      label: Text('模型')),
                  NavigationRailDestination(
                      icon: Icon(Icons.query_stats_outlined),
                      selectedIcon: Icon(Icons.query_stats),
                      label: Text('用量')),
                  NavigationRailDestination(
                      icon: Icon(Icons.settings_outlined),
                      selectedIcon: Icon(Icons.settings),
                      label: Text('设置')),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: pages[_index]),
            ],
          ),
        );
      },
    );
  }
}
