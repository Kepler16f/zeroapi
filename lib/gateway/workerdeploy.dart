import 'package:flutter/services.dart' show rootBundle;

import 'cf_api.dart';

/// 应用内「一键部署 Zen 出口 Worker」流程：token 校验 → 选账号 →
/// 上传 worker 代码 → 返回 workers.dev URL。
/// Worker 源码是应用内 asset（deploy/cloudflare-worker/index.js），
/// 与仓库内同一文件，不存在双份漂移。
class CfWorkerDeployer {
  /// 校验 token 并返回账号列表（顺带确认 token 有 Workers 写权限）。
  static Future<List<CfAccount>> verify(String token) async {
    final api = CloudflareApi(token);
    try {
      return await api.listAccounts();
    } finally {
      api.close();
    }
  }

  /// 部署并把 zen 供应商指向新 URL，返回最终 Worker 根地址。
  static Future<String> deploy({
    required String token,
    required String accountId,
  }) async {
    final api = CloudflareApi(token);
    try {
      final code = await rootBundle.loadString(
        'deploy/cloudflare-worker/index.js',
      );
      await api.deployScript(
        accountId: accountId,
        code: code,
        compatibilityDate: '2026-10-01',
      );
      final sub = await api.subdomain(accountId);
      return 'https://${CloudflareApi.scriptName}.$sub.workers.dev';
    } finally {
      api.close();
    }
  }
}
