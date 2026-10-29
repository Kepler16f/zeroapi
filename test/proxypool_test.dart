import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/proxypool.dart';
import 'package:zeroapi/gateway/socksrelay.dart';

// 测试向量：base64 / base64url 无填充，与真实分享链接一致
const _ssSip002 =
    'Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwdzEyMw'; // chacha20-ietf-poly1305:pw123
const _ssLegacy = 'YWVzLTI1Ni1nY206cGFzczk5QGxnLnNzLmV4YW1wbGUuY29tOjgzODg=';
const _ssr =
    'anAuc3NyLmV4YW1wbGUuY29tOjgzODg6b3JpZ2luOmNoYWNoYTIwLWlldGY6dGxzMS4yX3RpY2tldF9hdXRoOmMzTnljR0Z6Y3c9PS8/b2Jmc3BhcmFtPSZwcm90b3BhcmFtPSZyZW1hcmtzPTVwZWw1cHlzNklxQzU0SzU=';
const _vmess =
    'eyJ2IjoiMiIsInBzIjoiSEstVk1FU1MiLCJhZGQiOiJoay52bS5leGFtcGxlLmNvbSIsInBvcnQiOiI0NDMiLCJpZCI6IjBlNjUyOTFiLTliNTQtNGM0ZC1iMDYyLTQ2ZDFmODljODJkOCIsImFpZCI6IjAiLCJzY3kiOiJhdXRvIiwibmV0Ijoid3MiLCJ0eXBlIjoibm9uZSIsImhvc3QiOiIiLCJwYXRoIjoiL3dzLXBhdGgiLCJ0bHMiOiJ0bHMiLCJzbmkiOiJoay52bS5leGFtcGxlLmNvbSIsImVuY3J5cHRpb24iOiJub25lIn0';

/// 内核兼容性校验用的分享链接：每种加密协议一条，逐个单协议导入（LinkedHashMap
/// 插入序即校验顺序，端口取 21001+j）。
const _coreKernelLinks = <String, String>{
  'ss': 'ss://$_ssSip002@ss.example.com:8388#S',
  'ssr': 'ssr://$_ssr',
  'vmess': 'vmess://$_vmess',
  'vless': 'vless://uuid@v.example.com:443/?encryption=none&security=tls#V',
  'trojan': 'trojan://pw@t.example.com:443/?security=tls&sni=t.example.com#T',
  'hysteria2':
      'hysteria2://pw@h.example.com:443/?sni=h.example.com&insecure=1#H',
  'tuic': 'tuic://uuid:pw@tuic.example.com:443/?sni=tuic.example.com&alpn=h3#U',
};

/// coreConfigYaml 生成的 YAML 被内核拒绝的协议 → 内核报错关键串。
///
/// 均为 lib 层 YAML 映射缺陷（任务约束：不改 lib），此处固化现状以便缺陷可见：
/// - ssr：`_parseSsr` 把 `method` 原样写出，而 Clash/mihomo 的 ssr 字段是
///   `cipher`，内核报 "unset fields: cipher"；
/// - tuic：`_writeProxyYaml` 把 `alpn` 写成标量，而 mihomo 要求 list，
///   内核报 "'alpn' is not a slice"。
/// 修复 lib 后，这两条应从本表移除，改由通用断言要求 exit 0。
const _coreKernelKnownDefects = <String, String>{};

const _coreKernelBin = 'vendor/proxy-core/mihomo.exe';

/// 任务给定的 Clash 样例：流式（flow mapping）ss 节点 + 块式 vmess 节点，
/// 后者带 ws-opts.headers。
const _clashYaml = '''
proxies:
  - {name: 日本SS, type: ss, server: jp.ss.example.com, port: 8388, cipher: aes-256-gcm, password: sspw}
  - name: HK-VMESS-WS
    type: vmess
    server: hk.vm.example.com
    port: 443
    uuid: 0e65291b-9b54-4c4d-b062-46d1f89c82d8
    alterId: 0
    cipher: auto
    tls: true
    sni: hk.vm.example.com
    ws-opts:
      path: /ws-path
      headers:
        Host: hk.vm.example.com
proxy-groups:
  - name: 自动
    type: url-test
    proxies:
      - 日本SS
      - HK-VMESS-WS
''';

void main() {
  _subscriptionTests();
  _tlsLinkTests();
  _coreConfigTests();
  _coreKernelCompatTests();
  group('分享链接解析（每种协议一条）', () {
    test('socks5://user:pass@host:port#名字', () {
      final n = ProxyPool.parseShareLink('socks5://u:p@1.2.3.4:1080#东京-S');
      expect(n, isNotNull);
      expect(n!.type, 'socks5');
      expect(n.host, '1.2.3.4');
      expect(n.port, 1080);
      expect(n.username, 'u');
      expect(n.password, 'p');
      expect(n.name, '东京-S');
    });

    test('http / https 直连节点', () {
      final h = ProxyPool.parseShareLink('http://10.0.0.1:3128');
      expect(h, isNotNull);
      expect(h!.type, 'http');
      expect(h.port, 3128);
      expect(h.dartDirective, 'PROXY 10.0.0.1:3128');

      final s = ProxyPool.parseShareLink('https://u:p@10.0.0.2:8443#TLS');
      expect(s, isNotNull);
      expect(s!.type, 'https');
      expect(s.dartDirective, 'PROXY u:p@10.0.0.2:8443');
    });

    test('ss SIP002（base64url 无填充，method:password@host:port）', () {
      final n = ProxyPool.parseShareLink(
        'ss://$_ssSip002@ss.example.com:8388?plugin=obfs-local&plugin-opt=obfs%3Dtls#SS-01',
      );
      expect(n, isNotNull);
      expect(n!.type, 'ss');
      expect(n.host, 'ss.example.com');
      expect(n.port, 8388);
      expect(n.password, 'pw123');
      expect(n.name, 'SS-01');
      expect(n.extras['cipher'], 'chacha20-ietf-poly1305');
      expect(n.extras['plugin'], 'obfs-local');
      expect(n.extras['plugin-opt'], 'obfs=tls');
    });

    test('ss 旧式（base64(method:password@host:port)）', () {
      final n = ProxyPool.parseShareLink('ss://$_ssLegacy#SS-OLD');
      expect(n, isNotNull);
      expect(n!.type, 'ss');
      expect(n.host, 'lg.ss.example.com');
      expect(n.port, 8388);
      expect(n.password, 'pass99');
      expect(n.extras['cipher'], 'aes-256-gcm');
    });

    test('ssr（remarks 为中文 base64，解码成展示名）', () {
      final n = ProxyPool.parseShareLink('ssr://$_ssr');
      expect(n, isNotNull);
      expect(n!.type, 'ssr');
      expect(n.host, 'jp.ssr.example.com');
      expect(n.port, 8388);
      expect(n.password, 'ssrpass');
      expect(n.name, '日本节点', reason: '无 #fragment 时 remarks 就是节点名');
      expect(
        n.extras.containsKey('remarks'),
        isFalse,
        reason: '已作为展示名，不重复进 extras',
      );
      expect(n.extras['protocol'], 'origin');
      expect(n.extras['method'], 'chacha20-ietf');
      expect(n.extras['obfs'], 'tls1.2_ticket_auth');
    });

    test('ssr 的 #fragment 优先于 remarks', () {
      final n = ProxyPool.parseShareLink('ssr://$_ssr#手改的名字');
      expect(n, isNotNull);
      expect(n!.name, '手改的名字');
    });

    test('vmess（base64url 无填充的 JSON）', () {
      final n = ProxyPool.parseShareLink('vmess://$_vmess');
      expect(n, isNotNull);
      expect(n!.type, 'vmess');
      expect(n.host, 'hk.vm.example.com');
      expect(n.port, 443);
      expect(n.name, 'HK-VMESS');
      expect(n.extras['uuid'], '0e65291b-9b54-4c4d-b062-46d1f89c82d8');
      expect(n.extras['alterId'], '0');
      expect(n.extras['cipher'], 'auto');
      expect(n.extras['network'], 'ws');
      expect(n.extras['path'], '/ws-path');
      expect(n.extras['tls'], 'true');
      expect(n.extras['sni'], 'hk.vm.example.com');
      expect(n.extras['encryption'], 'none');
    });

    test('vless（带齐全部 query 字段）', () {
      final n = ProxyPool.parseShareLink(
        'vless://b26e521b-9b54-4c4d-b062-46d1f89c82d8@vless.example.com:443?encryption=none&security=tls&sni=vless.example.com&type=ws&host=vless.example.com&path=%2Fapi%2Fws&fp=chrome&flow=xtls-rprx-vision#HW%20Node',
      );
      expect(n, isNotNull);
      expect(n!.type, 'vless');
      expect(n.host, 'vless.example.com');
      expect(n.port, 443);
      expect(n.name, 'HW Node', reason: 'fragment 里的 %20 是空格');
      expect(n.extras['uuid'], 'b26e521b-9b54-4c4d-b062-46d1f89c82d8');
      expect(n.extras['encryption'], 'none');
      expect(n.extras['security'], 'tls');
      expect(n.extras['sni'], 'vless.example.com');
      expect(n.extras['type'], 'ws');
      expect(n.extras['host'], 'vless.example.com');
      expect(n.extras['path'], '/api/ws');
      expect(n.extras['fp'], 'chrome');
      expect(n.extras['flow'], 'xtls-rprx-vision');
    });

    test('fragment 里的 + 是字面加号，不做 query 式空格解码', () {
      expect(
        ProxyPool.parseShareLink('trojan://pw@t.example.com:443#a+b')!.name,
        'a+b',
      );
      expect(
        ProxyPool.parseShareLink('trojan://pw@t.example.com:443#A%20B')!.name,
        'A B',
      );
    });

    test('trojan://password@host:port?security=tls&sni=x', () {
      final n = ProxyPool.parseShareLink(
        'trojan://topsecret@tr.example.com:443?security=tls&sni=tr.example.com&type=tcp#TR-01',
      );
      expect(n, isNotNull);
      expect(n!.type, 'trojan');
      expect(n.host, 'tr.example.com');
      expect(n.port, 443);
      expect(n.password, 'topsecret');
      expect(n.name, 'TR-01');
      expect(n.extras['tls'], 'true', reason: 'security=tls 归一为 tls 开关');
      expect(n.extras['sni'], 'tr.example.com');
    });

    test('hysteria2:// 与 hy2:// 别名等价', () {
      final h = ProxyPool.parseShareLink(
        'hysteria2://hypass@hy.example.com:443?sni=hy.example.com&insecure=1#HY2-01',
      );
      expect(h, isNotNull);
      expect(h!.type, 'hysteria2');
      expect(h.host, 'hy.example.com');
      expect(h.port, 443);
      expect(h.password, 'hypass');
      expect(h.extras['sni'], 'hy.example.com');
      expect(h.extras['skip-cert-verify'], 'true');

      final alias = ProxyPool.parseShareLink(
        'hy2://pw@hy2.example.com:8443?sni=hy2.example.com',
      );
      expect(alias, isNotNull);
      expect(alias!.type, 'hysteria2');
      expect(alias.host, 'hy2.example.com');
    });

    test('tuic://uuid:pass@host:port?alpn=h3', () {
      final n = ProxyPool.parseShareLink(
        'tuic://d31a9d56-9b07-11ec-851e-3a5c4c005d3d:tuicpass@tuic.example.com:443?sni=tuic.example.com&alpn=h3&concurrency=32#TUIC-01',
      );
      expect(n, isNotNull);
      expect(n!.type, 'tuic');
      expect(n.host, 'tuic.example.com');
      expect(n.port, 443);
      expect(n.password, 'tuicpass');
      expect(n.extras['uuid'], 'd31a9d56-9b07-11ec-851e-3a5c4c005d3d');
      expect(n.extras['alpn'], 'h3');
      expect(n.extras['concurrency'], '32');
      expect(n.name, 'TUIC-01');
    });
  });

  group('findProxy 指令安全性', () {
    test('全协议扫描：只有 http/https 出 PROXY 指令，其余一律出 null', () {
      final links = [
        'http://10.0.0.1:3128',
        'https://u:p@10.0.0.2:8443',
        'socks5://u:p@1.2.3.4:1080',
        'socks://1.2.3.4:1080',
        'ss://$_ssSip002@ss.example.com:8388',
        'ssr://$_ssr',
        'vmess://$_vmess',
        'vless://uuid@v.example.com:443?encryption=none&security=tls',
        'trojan://pw@t.example.com:443?security=tls',
        'hysteria2://pw@h.example.com:443?sni=h.example.com',
        'hy2://pw@h.example.com:443?sni=h.example.com',
        'tuic://uuid:pw@tuic.example.com:443?sni=tuic.example.com&alpn=h3',
        '1.2.3.4:3128',
      ];
      for (final l in links) {
        final n = ProxyPool.parseShareLink(l);
        expect(n, isNotNull, reason: '应能解析：$l');
        expect(
          n!.dartDirective?.contains('SOCKS5') ?? false,
          isFalse,
          reason: '$l 绝不能产出 SOCKS5 前缀（Dart 会抛 HttpException）',
        );
        if (n.type == 'http' || n.type == 'https') {
          expect(n.dartDirective, startsWith('PROXY '), reason: l);
          expect(n.dartUsable, isTrue, reason: l);
        } else {
          expect(n.dartUsable, isFalse, reason: l);
          expect(n.dartDirective, isNull, reason: l);
        }
      }
    });

    test('socks5 节点带认证也仍是 null，不降级成 PROXY', () {
      final n = ProxyPool.parseShareLink('socks5://u:p@1.2.3.4:1080')!;
      expect(n.dartUsable, isFalse);
      expect(n.dartDirective, isNull);
    });
  });

  group('Clash YAML 导入', () {
    test('2 节点 + 1 分组，extras 字段落位', () {
      final pool = ProxyPool();
      expect(pool.importFromText(_clashYaml), 2);

      expect(pool.allNodes.length, 2);
      expect(pool.groups.length, 1);
      expect(pool.groups.single.name, '自动');
      expect(pool.groups.single.strategy, 'latency', reason: 'url-test 按延迟');
      expect(pool.groups.single.nodes.length, 2);

      final ss = pool.allNodes.firstWhere((n) => n.type == 'ss');
      expect(ss.name, '日本SS');
      expect(ss.host, 'jp.ss.example.com');
      expect(ss.port, 8388);
      expect(ss.password, 'sspw');
      expect(ss.extras['cipher'], 'aes-256-gcm');

      final vm = pool.allNodes.firstWhere((n) => n.type == 'vmess');
      expect(vm.name, 'HK-VMESS-WS');
      expect(vm.host, 'hk.vm.example.com');
      expect(vm.port, 443);
      expect(vm.extras['uuid'], '0e65291b-9b54-4c4d-b062-46d1f89c82d8');
      expect(vm.extras['alterId'], '0');
      expect(vm.extras['cipher'], 'auto');
      expect(vm.extras['tls'], 'true');
      expect(vm.extras['sni'], 'hk.vm.example.com');
      expect(vm.extras['path'], '/ws-path', reason: 'ws-opts.path 扁平化');
      expect(
        vm.extras['hostHeader'],
        'hk.vm.example.com',
        reason: 'ws-opts.headers.Host 归一到 hostHeader',
      );

      // 加密协议不可直接拨号，必须提示，不允许静默入池
      expect(pool.warnings, isNotEmpty);
    });

    test('无 proxy-groups 时归入默认组', () {
      final yaml = _clashYaml.split('proxy-groups:').first;
      final pool = ProxyPool();
      pool.importFromText(yaml);
      expect(pool.groups.length, 1);
      expect(pool.groups.single.name, '导入');
      expect(pool.allNodes.length, 2);
    });

    test('未引用的节点不丢，单独归入默认组', () {
      final yaml = '''
proxies:
  - name: A
    type: http
    server: 1.1.1.1
    port: 3128
  - name: B
    type: http
    server: 2.2.2.2
    port: 3128
proxy-groups:
  - name: G
    type: select
    proxies:
      - A
''';
      final pool = ProxyPool();
      pool.importFromText(yaml);
      expect(pool.groups.length, 2);
      final g = pool.groups.firstWhere((x) => x.name == 'G');
      expect(g.nodes.length, 1);
      expect(g.strategy, 'round-robin');
      final d = pool.groups.firstWhere((x) => x.name == '导入');
      expect(d.nodes.length, 1);
      expect(d.nodes.single.name, 'B');
    });
  });

  group('纯文本与容错导入', () {
    test('host:port 默认 http；user:pass@host:port 带认证', () {
      final pool = ProxyPool();
      pool.importFromText('10.1.1.1:3128');
      final a = pool.allNodes.single;
      expect(a.type, 'http');
      expect(a.host, '10.1.1.1');
      expect(a.port, 3128);
      expect(a.name, '10.1.1.1:3128', reason: '无名时退回 host:port');
      expect(a.dartDirective, 'PROXY 10.1.1.1:3128');

      final pool2 = ProxyPool();
      pool2.importFromText('user:pass@10.1.1.2:3128');
      final b = pool2.allNodes.single;
      expect(b.type, 'http');
      expect(b.username, 'user');
      expect(b.password, 'pass');
      expect(b.dartDirective, 'PROXY user:pass@10.1.1.2:3128');
    });

    test('空行与 # 注释跳过；失败行进 parseErrors，不拖垮整批', () {
      final pool = ProxyPool();
      pool.importFromText('''
# 订阅说明
http://10.0.0.1:3128#good

1.2.3.4:99999
vmess://not-base64!!!
socks://1.2.3.4:1080#s
''');
      expect(pool.allNodes.length, 2, reason: 'good http + socks');
      expect(pool.parseErrors.length, 2);
      expect(pool.parseErrors, contains('1.2.3.4:99999'));
      expect(pool.parseErrors, contains('vmess://not-base64!!!'));
    });

    test('socks5 入池必须写 warnings（Dart 拨不了，不能静默丢弃）', () {
      final pool = ProxyPool();
      pool.importFromText('socks5://u:p@1.2.3.4:1080#S');
      expect(pool.allNodes.single.dartUsable, isFalse);
      expect(pool.warnings, isNotEmpty);
      expect(pool.warnings.join('\n'), contains('SOCKS5'));
    });
  });

  group('轮换策略', () {
    test('3 节点 round-robin 依次取出并回绕', () {
      final pool = ProxyPool();
      pool.importFromText('''
http://10.0.0.1:3128#A
http://10.0.0.2:3128#B
http://10.0.0.3:3128#C
''');
      pool.assign(ProxyPool.pRealm('cn'), '导入');
      expect(pool.pickDirective(ProxyPool.pRealm('cn')), 'PROXY 10.0.0.1:3128');
      expect(pool.pickDirective(ProxyPool.pRealm('cn')), 'PROXY 10.0.0.2:3128');
      expect(pool.pickDirective(ProxyPool.pRealm('cn')), 'PROXY 10.0.0.3:3128');
      expect(
        pool.pickDirective(ProxyPool.pRealm('cn')),
        'PROXY 10.0.0.1:3128',
        reason: '回绕到第一个',
      );
    });

    test('latency 策略按延迟升序取，未知延迟排最后且重复取最优', () {
      final pool = ProxyPool();
      pool.importFromText('''
http://10.0.0.1:3128#A
http://10.0.0.2:3128#B
http://10.0.0.3:3128#C
''', groupName: '快');
      pool.groups.single.strategy = 'latency';
      final p = ProxyPool.pRealm('intl');
      pool.assign(p, '快');
      final ids = pool.allNodes.map((n) => n.id).toList();
      pool.report(ids[0], true, latencyMs: 200);
      pool.report(ids[1], true, latencyMs: 50);
      expect(pool.pickDirective(p), 'PROXY 10.0.0.2:3128', reason: '50ms 最优');
      expect(pool.pickDirective(p), 'PROXY 10.0.0.2:3128', reason: '不轮询，重复取最优');
    });

    test('连续 3 次失败进入冷却被跳过；一次成功即恢复', () {
      final pool = ProxyPool();
      pool.importFromText('http://10.0.0.9:3128#only');
      final p = ProxyPool.pThirdParty;
      pool.assign(p, '导入');
      final id = pool.allNodes.single.id;
      expect(pool.pickDirective(p), 'PROXY 10.0.0.9:3128');

      pool.report(id, false);
      expect(pool.pickDirective(p), isNotNull, reason: '第 1 次失败仍可用');
      pool.report(id, false);
      pool.report(id, false);
      expect(pool.pickDirective(p), isNull, reason: '3 连败进入冷却期');

      pool.report(id, true, latencyMs: 30);
      expect(pool.health[id]!.failCount, 0);
      expect(pool.health[id]!.latencyMs, 30);
      expect(pool.pickDirective(p), 'PROXY 10.0.0.9:3128', reason: '成功即恢复');
    });

    test('noteEgress：失败累计进冷却；成功清零；无变化时不广播', () {
      final pool = ProxyPool();
      pool.importFromText('http://10.0.0.9:3128#only');
      final p = ProxyPool.pThirdParty;
      pool.assign(p, '导入');
      final id = pool.allNodes.single.id;

      // 高频成功不广播（请求路径不该拖着整页 UI 重建）
      var notified = 0;
      pool.addListener(() => notified++);
      pool.noteEgress(id, true);
      pool.noteEgress(id, true);
      expect(notified, 0, reason: '成功且无失败计数 → 静默');
      expect(pool.health[id]!.failCount, 0);

      // 失败总是广播（冷却状态可能变化）
      pool.noteEgress(id, false);
      expect(notified, 1);
      pool.noteEgress(id, false);
      pool.noteEgress(id, false);
      expect(pool.health[id]!.failCount, 3);
      expect(pool.pickDirective(p), isNull, reason: '3 连败进冷却，与 report 一致');

      // 成功清零失败计数 → 恢复，且此时会广播一次（状态真变化）
      notified = 0;
      pool.noteEgress(id, true);
      expect(notified, 1);
      expect(pool.health[id]!.failCount, 0);
      expect(pool.pickDirective(p), 'PROXY 10.0.0.9:3128');
    });

    test('混合组：加密节点不参与轮换，只出 http 指令', () {
      final pool = ProxyPool();
      pool.importFromText('''
socks5://u:p@1.2.3.4:1080#S
http://10.0.0.1:3128#A
http://10.0.0.2:3128#B
vmess://$_vmess
''');
      final p = ProxyPool.pUpstream('claudeai');
      pool.assign(p, '导入');
      final picked = <String?>[
        pool.pickDirective(p),
        pool.pickDirective(p),
        pool.pickDirective(p),
        pool.pickDirective(p),
      ];
      expect(picked, everyElement(isNotNull), reason: '每次都应拿到可用指令');
      final out = picked.whereType<String>().toSet();
      expect(out.length, 2, reason: '只有 2 个 http 节点参与轮换');
      expect(out.contains('PROXY 10.0.0.1:3128'), isTrue);
      expect(out.contains('PROXY 10.0.0.2:3128'), isTrue);
    });

    test('设置 relayHub 后 socks5 节点经本地中转参与轮换', () async {
      final hub = SocksRelayHub();
      final pool = ProxyPool();
      pool.importFromText('''
socks5://u:p@1.2.3.4:1080#S
http://10.0.0.1:3128#A
''');
      final p = ProxyPool.pRealm('cn');
      pool.assign(p, '导入');
      final socksRaw = 'socks5://u:p@1.2.3.4:1080';
      // 未预热：socks5 被跳过，只轮转出 http 指令（组内唯一 http 反复取到）
      expect(pool.pickDirective(p), 'PROXY 10.0.0.1:3128');
      expect(
        pool.pickDirective(p),
        'PROXY 10.0.0.1:3128',
        reason: '未预热时 socks5 不入选，两次都应是 http',
      );

      pool.relayHub = hub;
      expect(
        pool.directiveOf(pool.allNodes.firstWhere((n) => n.type == 'socks5')),
        isNull,
        reason: '设了 hub 但未预热仍跳过',
      );
      await pool.prepareRelays();
      expect(hub.directiveFor(socksRaw), isNotNull, reason: '预热后有本地中转指令');

      final seen = <String?>[pool.pickDirective(p), pool.pickDirective(p)];
      expect(seen, contains('PROXY 10.0.0.1:3128'));
      final socksPick = seen.firstWhere((d) => d != 'PROXY 10.0.0.1:3128')!;
      expect(
        socksPick,
        startsWith('PROXY 127.0.0.1:'),
        reason: 'socks5 指令指向本地中转，绝不是 SOCKS5 前缀',
      );
      expect(hub.directiveFor('socks5://u:p@1.2.3.4:1080'), socksPick);
      await hub.stopAll();
    });

    test('组内全是不可用节点时 pickDirective 返回 null', () {
      final pool = ProxyPool();
      pool.importFromText('socks5://u:p@1.2.3.4:1080#S\nvmess://$_vmess');
      final p = ProxyPool.pSignin('projA');
      pool.assign(p, '导入');
      expect(pool.groupFor(p), '导入');
      expect(pool.pickDirective(p), isNull, reason: '无 Dart 可用节点 → 走直连');
    });
  });

  group('用途绑定与开关', () {
    test('用途键常量', () {
      expect(ProxyPool.pThirdParty, 'net:thirdparty');
      expect(ProxyPool.pUpstream('claudeai'), 'upstream:claudeai');
      expect(ProxyPool.pRealm('cn'), 'realm:cn');
      expect(ProxyPool.pRealm('intl'), 'realm:intl');
      expect(ProxyPool.pSignin('b'), 'signin:b');
      expect(ProxyPool.realmCn, 'cn');
      expect(ProxyPool.realmIntl, 'intl');
    });

    test('assign / groupFor 往返；assign(null) 清除绑定；未绑定走直连', () {
      final pool = ProxyPool();
      pool.importFromText('http://10.0.0.1:3128#A');
      final p = ProxyPool.pRealm('cn');
      expect(pool.groupFor(p), isNull);
      expect(pool.pickDirective(p), isNull, reason: '没分配分组 → 直连');

      pool.assign(p, '导入');
      expect(pool.groupFor(p), '导入');
      expect(pool.pickDirective(p), 'PROXY 10.0.0.1:3128');

      pool.assign(p, null);
      expect(pool.groupFor(p), isNull);
      expect(pool.pickDirective(p), isNull);
    });

    test('绑定到不存在的分组视为未绑定', () {
      final pool = ProxyPool();
      pool.assign('realm:cn', '幽灵组');
      expect(pool.groupFor('realm:cn'), isNull);
      expect(pool.pickDirective('realm:cn'), isNull);
    });

    test('逐用途开关：缺省启用，关闭后 pickDirective 返回 null', () {
      final pool = ProxyPool();
      pool.importFromText('http://10.0.0.1:3128#A');
      final p = ProxyPool.pThirdParty;
      pool.assign(p, '导入');

      expect(pool.isEnabled(p), isTrue, reason: '缺省视为启用');
      expect(pool.pickDirective(p), 'PROXY 10.0.0.1:3128');

      pool.setEnabled(p, false);
      expect(pool.isEnabled(p), isFalse);
      expect(pool.pickDirective(p), isNull, reason: '关闭后走直连');

      pool.setEnabled(p, true);
      expect(pool.pickDirective(p), 'PROXY 10.0.0.1:3128');
      expect(
        pool.toJson()['enabledFlags'],
        isNull,
        reason: '全部启用时不落盘 enabledFlags，保持 JSON 干净',
      );
    });

    test('两个 realm 出口互不影响', () {
      final pool = ProxyPool();
      pool.importFromText('http://10.0.0.1:3128#CN\nhttp://10.0.0.2:3128#INTL');
      pool.assign(ProxyPool.pRealm('cn'), '导入');
      pool.assign(ProxyPool.pRealm('intl'), '导入');
      pool.setEnabled(ProxyPool.pRealm('cn'), false);

      expect(pool.pickDirective(ProxyPool.pRealm('cn')), isNull);
      expect(pool.pickDirective(ProxyPool.pRealm('intl')), isNotNull);
    });

    test('removeGroup 清理绑定；renameGroup 同步改写绑定', () {
      final pool = ProxyPool();
      pool.importFromText('http://10.0.0.1:3128#A', groupName: '旧名');
      final p = ProxyPool.pRealm('cn');
      pool.assign(p, '旧名');
      pool.renameGroup('旧名', '新名');
      expect(pool.groupFor(p), '新名');
      expect(pool.pickDirective(p), 'PROXY 10.0.0.1:3128');
      pool.removeGroup('新名');
      expect(pool.groups, isEmpty);
      expect(pool.allNodes, isEmpty);
      expect(pool.groupFor(p), isNull);
    });

    test('removeNode 移除节点，无人引用时连带清健康度', () {
      final pool = ProxyPool();
      pool.importFromText('http://10.0.0.1:3128#A\nhttp://10.0.0.2:3128#B');
      final p = ProxyPool.pRealm('cn');
      pool.assign(p, '导入');
      final a = pool.allNodes.first.id;
      pool.report(a, true, latencyMs: 10);
      expect(pool.health[a], isNotNull);

      pool.removeNode('导入', a);
      expect(pool.allNodes.map((n) => n.id).contains(a), isFalse);
      expect(pool.health[a], isNull, reason: '池中再无引用则清健康度');
      expect(pool.pickDirective(p), 'PROXY 10.0.0.2:3128');
    });
  });

  group('序列化', () {
    test('toJson / fromJson 往返（含 health 与 enabledFlags）', () {
      final pool = ProxyPool();
      pool.importFromText('''
http://10.0.0.1:3128#A
socks5://u:p@1.2.3.4:1080#S
''', groupName: '主组');
      pool.assign('realm:cn', '主组');
      pool.assign(ProxyPool.pThirdParty, '主组');
      pool.setEnabled('realm:intl', false);
      final ids = pool.allNodes.map((n) => n.id).toList();
      pool.report(ids[0], true, latencyMs: 42);
      pool.report(ids[1], false);

      final j = pool.toJson();
      expect((j['nodes'] as List).length, 2, reason: '节点去重后只存一份');
      expect((j['groups'] as List).length, 1);
      expect(j['enabledFlags'], {'realm:intl': false});
      final back = ProxyPool.fromJson(j);

      expect(
        back.allNodes.map((n) => n.id).toList(),
        pool.allNodes.map((n) => n.id).toList(),
      );
      expect(
        back.groups.map((g) => g.name).toList(),
        pool.groups.map((g) => g.name).toList(),
      );
      expect(back.groups.single.strategy, 'round-robin');
      expect(
        back.groups.single.nodes.map((n) => n.id).toList(),
        pool.groups.single.nodes.map((n) => n.id).toList(),
      );
      expect(back.assignments, pool.assignments);
      expect(back.enabledFlags, pool.enabledFlags);
      expect(back.isEnabled('realm:intl'), isFalse);
      expect(back.isEnabled('realm:cn'), isTrue);
      expect(back.health[ids[0]]?.latencyMs, 42);
      expect(back.health[ids[0]]?.failCount, 0);
      expect(back.health[ids[0]]?.lastChecked, isNotNull);
      expect(back.health[ids[1]]?.failCount, 1);
      expect(
        back.pickDirective('realm:cn'),
        'PROXY 10.0.0.1:3128',
        reason: '同组混有 socks 节点，只出 http 指令',
      );
      expect(
        back.pickDirective('realm:intl'),
        isNull,
        reason: 'realm:intl 被关掉 → 直连',
      );
    });

    test('同节点被两个分组引用时 toJson 只存一份副本', () {
      final pool = ProxyPool();
      pool.importFromText('http://10.0.0.1:3128#A', groupName: 'g1');
      pool.importFromText('http://10.0.0.1:3128#A', groupName: 'g2');
      expect(pool.allNodes.length, 1, reason: '同 id 去重');
      final j = pool.toJson();
      expect((j['nodes'] as List).length, 1);
      expect((j['groups'] as List).length, 2);
      // 两个分组各自只引用同一个 nodeId，没有第二份节点副本
      final id = pool.allNodes.single.id;
      for (final g in (j['groups'] as List).cast<Map>()) {
        expect(g['nodeIds'], [id]);
      }
      final back = ProxyPool.fromJson(j);
      expect(back.allNodes.length, 1);
      expect(back.groups.length, 2);
      expect(back.groups[0].nodes.single.id, back.groups[1].nodes.single.id);
    });

    test('重复导入同批节点不重复添加，返回新增数 0', () {
      final pool = ProxyPool();
      expect(pool.importFromText('http://10.0.0.1:3128#A'), 1);
      expect(pool.importFromText('http://10.0.0.1:3128#A'), 0);
      expect(pool.allNodes.length, 1);
      expect(pool.groups.single.nodes.length, 1, reason: '同组内也不重复');
    });
  });

  group('落盘', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('proxypool_test_');
    });

    tearDown(() {
      dir.deleteSync(recursive: true);
    });

    test('save / load 走注入路径（临时目录）', () {
      final pool = ProxyPool();
      pool.importFromText(
        'http://10.0.0.1:3128#A\nsocks5://u:p@1.2.3.4:1080#S',
        groupName: '测试组',
      );
      pool.assign(ProxyPool.pSignin('projA'), '测试组');
      pool.setEnabled('realm:cn', false);
      final id = pool.allNodes.first.id;
      pool.report(id, true, latencyMs: 88);
      pool.save(path: '${dir.path}/proxies.json');
      expect(File('${dir.path}/proxies.json').existsSync(), isTrue);

      final back = ProxyPool.load(path: '${dir.path}/proxies.json');
      expect(back.allNodes.length, 2);
      expect(back.groups.single.name, '测试组');
      expect(back.groupFor(ProxyPool.pSignin('projA')), '测试组');
      expect(back.isEnabled('realm:cn'), isFalse);
      expect(back.isEnabled('realm:intl'), isTrue);
      expect(back.health[id]?.latencyMs, 88);
      expect(
        back.pickDirective(ProxyPool.pSignin('projA')),
        'PROXY 10.0.0.1:3128',
      );
    });

    test('load 不存在的文件返回空池', () {
      final p = ProxyPool.load(path: '${dir.path}/nope.json');
      expect(p.allNodes, isEmpty);
      expect(p.groups, isEmpty);
      expect(p.assignments, isEmpty);
    });

    test('load 遇到损坏的 JSON 不抛异常', () {
      final f = File('${dir.path}/bad.json');
      f.writeAsStringSync('{"nodes": [oops not json');
      final p = ProxyPool.load(path: f.path);
      expect(p.allNodes, isEmpty);
    });
  });

  group('导出 Clash 配置', () {
    test('exportConfigText 结构完整，type 用 url-test', () {
      final pool = ProxyPool();
      pool.importFromText(_clashYaml);
      final text = pool.exportConfigText();
      expect(text, contains('proxies:'));
      expect(text, contains('proxy-groups:'));
      expect(text, contains('type: url-test'));
      expect(text, contains('server: "hk.vm.example.com"'));
      expect(text, contains('Host: "hk.vm.example.com"'));
      expect(text, contains('port: 443'));
    });

    test('导出 → 再导入往返：节点数、分组名、协议字段一致', () {
      final a = ProxyPool();
      a.importFromText(_clashYaml);
      final exported = a.exportConfigText();

      final b = ProxyPool();
      b.importFromText(exported);

      expect(b.allNodes.length, a.allNodes.length);
      expect(
        b.allNodes.map((n) => n.id).toList(),
        a.allNodes.map((n) => n.id).toList(),
      );
      expect(
        b.groups.map((g) => g.name).toList(),
        a.groups.map((g) => g.name).toList(),
      );
      expect(b.groups.single.strategy, a.groups.single.strategy);
      expect(b.groups.single.nodes.length, a.groups.single.nodes.length);

      final vma = a.allNodes.firstWhere((n) => n.type == 'vmess');
      final vmb = b.allNodes.firstWhere((n) => n.type == 'vmess');
      expect(vmb.extras['path'], '/ws-path');
      expect(vmb.extras['hostHeader'], 'hk.vm.example.com');
      expect(vmb.extras['tls'], 'true');
      expect(vmb.extras['alterId'], '0');
      expect(vmb.extras['cipher'], 'auto');
      expect(vmb.extras['sni'], vma.extras['sni']);
      expect(vmb.extras['uuid'], vma.extras['uuid']);

      final ssa = a.allNodes.firstWhere((n) => n.type == 'ss');
      final ssb = b.allNodes.firstWhere((n) => n.type == 'ss');
      expect(ssb.extras['cipher'], ssa.extras['cipher']);
      expect(ssb.password, ssa.password);
    });

    test('混合协议组也能导出再导入', () {
      final pool = ProxyPool();
      pool.importFromText('''
http://10.0.0.1:3128#直连HTTP
socks5://u:p@1.2.3.4:1080#SOCKS
vmess://$_vmess
''');
      final b = ProxyPool();
      b.importFromText(pool.exportConfigText());
      expect(b.allNodes.length, 3);
      expect(b.groups.single.name, '导入');
      final vm = b.allNodes.firstWhere((n) => n.type == 'vmess');
      expect(vm.extras['path'], '/ws-path');
      expect(vm.extras['network'], 'ws');
    });
  });
}

void _subscriptionTests() {
  group('订阅响应体解包', () {
    const links =
        'socks5://u:p@1.2.3.4:1080#S\nhttp://5.6.7.8:3128#A\nvmess://eyJ2IjoiMiJ9';

    test('明文分享链接原样返回', () {
      expect(unwrapSubscriptionBody(links), links);
    });

    test('Clash YAML 原样返回', () {
      const yaml = 'proxies:\n  - name: A\n    type: http\n    server: 1.2.3.4';
      expect(unwrapSubscriptionBody(yaml), yaml);
    });

    test('标准 base64 订阅解出明文', () {
      final b64 = base64.encode(utf8.encode(links));
      // 机场常见：整段 base64 带换行
      final wrapped = '${b64.substring(0, 20)}\n${b64.substring(20)}';
      expect(unwrapSubscriptionBody(wrapped), links);
    });

    test('URL-safe 无填充 base64 也能解', () {
      final b64 = base64
          .encode(utf8.encode(links))
          .replaceAll('+', '-')
          .replaceAll('/', '_')
          .replaceAll('=', '');
      expect(unwrapSubscriptionBody(b64), links);
    });

    test('无效 base64 原样返回，不抛异常', () {
      expect(
        unwrapSubscriptionBody('not a subscription'),
        'not a subscription',
      );
    });
  });
}

void _tlsLinkTests() {
  group('TLS 类分享链接：斜杠路径与默认端口', () {
    test('hysteria2：端口后带 /? 查询串（订阅最常见写法）', () {
      final n = ProxyPool.parseShareLink(
        'hysteria2://pass@example.com:443/?sni=example.com&insecure=1#HK',
      );
      expect(n, isNotNull);
      expect(n!.type, 'hysteria2');
      expect(n.host, 'example.com');
      expect(n.port, 443);
      expect(n.password, 'pass');
      expect(n.extras['sni'], 'example.com');
      expect(n.extras['skip-cert-verify'], 'true');
      expect(n.name, 'HK');
    });

    test('hy2 别名 + 自定义端口 + 百分号编码密码', () {
      final n = ProxyPool.parseShareLink('hy2://p%40ss@h.example.com:8443/#东京');
      expect(n, isNotNull);
      expect(n!.type, 'hysteria2');
      expect(n.port, 8443);
      expect(n.password, 'p@ss');
      expect(n.name, '东京');
    });

    test('hysteria2 省略端口时默认 443', () {
      final n = ProxyPool.parseShareLink(
        'hysteria2://pass@h.example.com/?sni=x',
      );
      expect(n!.port, 443);
    });

    test('trojan / vless / tuic 同样支持带斜杠写法', () {
      final t = ProxyPool.parseShareLink(
        'trojan://pw@t.example.com:443/?security=tls&sni=t.example.com#T',
      );
      expect(t, isNotNull);
      expect(t!.type, 'trojan');
      expect(t.port, 443);
      expect(t.password, 'pw');

      final v = ProxyPool.parseShareLink(
        'vless://uuid-1@v.example.com:443/?encryption=none&security=tls#V',
      );
      expect(v, isNotNull);
      expect(v!.host, 'v.example.com');
      expect(v.extras['uuid'], 'uuid-1');

      final u = ProxyPool.parseShareLink(
        'tuic://uuid:pw@tuic.example.com:443/?sni=tuic.example.com#U',
      );
      expect(u, isNotNull);
      expect(u!.type, 'tuic');
      expect(u.password, 'pw');
    });

    test('IPv6 字面量 + 斜杠路径', () {
      final n = ProxyPool.parseShareLink(
        'hysteria2://pass@[2001:db8::1]:443/?sni=x#V6',
      );
      expect(n, isNotNull);
      expect(n!.host, '2001:db8::1');
      expect(n.port, 443);
    });
  });
}

void _coreConfigTests() {
  group('内置内核（mihomo）配置', () {
    test('加密节点分配本地端口后才出指令；配置含 listener/proxy 绑定', () {
      final pool = ProxyPool();
      pool.importFromText('''
ss://$_ssSip002@ss.example.com:8388#SS-节点
vmess://$_vmess
hysteria2://pw@h.example.com:443/?sni=h.example.com#HY2
http://10.0.0.1:3128#HTTP
''', groupName: '内核组');
      final ss = pool.allNodes.firstWhere((n) => n.type == 'ss');
      expect(ProxyPool.needsCore(ss), isTrue);
      expect(pool.directiveOf(ss), isNull, reason: '未分配端口前不可用');

      pool.corePorts = {ss.id: 20001};
      expect(pool.directiveOf(ss), 'PROXY 127.0.0.1:20001');

      final http = pool.allNodes.firstWhere((n) => n.type == 'http');
      expect(pool.directiveOf(http), 'PROXY 10.0.0.1:3128');

      final yamlText = pool.coreConfigYaml({ss.id: 20001});
      expect(yamlText, contains('allow-lan: false'));
      expect(yamlText, contains('listeners:'));
      expect(yamlText, contains('type: http'));
      expect(yamlText, contains('listen: 127.0.0.1'));
      expect(yamlText, contains('port: 20001'));
      expect(yamlText, contains('proxy: "n_${ss.id}"'));
      expect(
        yamlText,
        isNot(contains('type: "http"\n    server: 10.0.0.1')),
        reason: 'http 节点不该进内核配置',
      );

      // 落盘供 mihomo -t 实际校验（手动/CI 可选消费）
      final out = File('${Directory.systemTemp.path}/zeroapi_corecfg.yaml')
        ..writeAsStringSync(yamlText);
      expect(out.existsSync(), isTrue);
    });

    test('DoH 覆盖：写真实 IP，TLS 节点保留/补上 sni', () {
      final pool = ProxyPool();
      pool.importFromText('''
hysteria2://pw@h.example.com:443/?sni=h.example.com#HY2
trojan://pw@t.example.com:443#TROJAN
ss://$_ssSip002@ss.example.com:8388#SS
''', groupName: '覆盖组');
      final hy2 = pool.allNodes.firstWhere((n) => n.type == 'hysteria2');
      final trojan = pool.allNodes.firstWhere((n) => n.type == 'trojan');
      final ss = pool.allNodes.firstWhere((n) => n.type == 'ss');
      final yamlText = pool.coreConfigYaml(
        {hy2.id: 20001, trojan.id: 20002, ss.id: 20003},
        serverOverrides: {
          hy2.id: '1.1.1.1',
          trojan.id: '2.2.2.2',
          ss.id: '3.3.3.3',
        },
      );

      final hy2Block = yamlText.substring(
        yamlText.indexOf('name: "n_${hy2.id}"'),
        yamlText.indexOf('name: "n_${trojan.id}"'),
      );
      expect(hy2Block, contains('server: "1.1.1.1"'));
      expect(
        hy2Block,
        contains('sni: "h.example.com"'),
        reason: '原 sni 保留，且不能因覆盖变成 IP',
      );
      expect('sni:'.allMatches(hy2Block).length, 1);

      final trojanBlock = yamlText.substring(
        yamlText.indexOf('name: "n_${trojan.id}"'),
        yamlText.indexOf('name: "n_${ss.id}"'),
      );
      expect(trojanBlock, contains('server: "2.2.2.2"'));
      expect(
        trojanBlock,
        contains('sni: "t.example.com"'),
        reason: 'trojan 原本没写 sni，换成 IP 后必须补原域名',
      );

      final ssBlock = yamlText.substring(
        yamlText.indexOf('name: "n_${ss.id}"'),
      );
      expect(ssBlock, contains('server: "3.3.3.3"'));
      expect(ssBlock, isNot(contains('sni:')), reason: 'ss 不是 TLS，不该补 sni');
    });

    test('没有覆盖时仍写原域名', () {
      final pool = ProxyPool();
      pool.importFromText('trojan://pw@t.example.com:443#T', groupName: '原始组');
      final t = pool.allNodes.single;
      final yamlText = pool.coreConfigYaml({t.id: 20011});
      expect(yamlText, contains('server: "t.example.com"'));
      expect(yamlText, isNot(contains('sni:')));
    });
  });
}

void _coreKernelCompatTests() {
  group('内核配置逐协议校验', () {
    late Directory tmpDir;

    setUpAll(() {
      tmpDir = Directory.systemTemp.createTempSync('zeroapi_core_');
    });

    tearDownAll(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    for (var j = 0; j < _coreKernelLinks.length; j++) {
      final type = _coreKernelLinks.keys.elementAt(j);
      final link = _coreKernelLinks[type]!;
      final port = 21001 + j;
      // 已知 lib 缺陷的协议，测试名直接标出预期结论，便于在结果里一眼看出
      final kernelExpectation = _coreKernelKnownDefects[type] == null
          ? '内核校验通过'
          : '内核拒绝（已知 lib 缺陷）';

      test('$type：coreConfigYaml 含 proxies / listeners / proxy 绑定', () {
        final pool = ProxyPool();
        expect(pool.importFromText(link), 1, reason: '单协议导入应入池 1 个节点：$link');
        expect(pool.parseErrors, isEmpty, reason: '解析不应报错：$link');

        final node = pool.allNodes.single;
        expect(node.type, type);
        expect(ProxyPool.needsCore(node), isTrue);

        final yaml = pool.coreConfigYaml({node.id: port});
        expect(yaml, contains('proxies:'));
        expect(yaml, contains('listeners:'));
        expect(
          yaml,
          contains('proxy: "n_${node.id}"'),
          reason: 'listener 必须绑定到本节点的 proxy 条目',
        );
      });

      test('$type：mihomo -t $kernelExpectation（127.0.0.1:$port）', () async {
        final bin = File(_coreKernelBin);
        if (!bin.existsSync()) {
          markTestSkipped('未找到内置内核 $_coreKernelBin，跳过内核校验');
        }

        final pool = ProxyPool();
        pool.importFromText(link);
        final node = pool.allNodes.single;
        final yaml = pool.coreConfigYaml({node.id: port});
        final cfg = File('${tmpDir.path}/zeroapi_core_$type.yaml')
          ..writeAsStringSync(yaml);
        expect(cfg.existsSync(), isTrue);

        final r = await Process.run(bin.path, [
          '-t',
          '-d',
          tmpDir.path,
          '-f',
          cfg.path,
        ]);
        final out = '${r.stdout}\n${r.stderr}'.trim();
        final detail =
            '$type exit=${r.exitCode}\n'
            '--- config: ${cfg.path} ---\n'
            '$yaml'
            '--- mihomo output ---\n'
            '$out';
        stdout.writeln('[内核校验] $type exit=${r.exitCode}\n$out');

        final defect = _coreKernelKnownDefects[type];
        if (defect == null) {
          expect(
            r.exitCode,
            0,
            reason: '内核应接受 $type 配置（coreConfigYaml 协议兼容性缺陷）：\n$detail',
          );
          expect(out, contains('test is successful'), reason: detail);
        } else {
          // lib 层已知缺陷（_coreKernelKnownDefects 有注释）：固化「内核仍拒绝」
          // 的现状而不改 lib。lib 修好后本断言会失败，提示把该协议移出缺陷表。
          expect(
            r.exitCode,
            isNot(0),
            reason: '$type 仍应被内核拒绝（lib 缺陷未修，非回归）：\n$detail',
          );
          expect(out, contains(defect), reason: '应命中已知缺陷特征，而非其它报错：\n$detail');
        }
      });
    }
  });
}
