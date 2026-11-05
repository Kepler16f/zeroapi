/// opencode `serve` 线协议适配器的公共契约。
///
/// 为什么需要两代协议：
/// - v1 = `opencode-ai` 1.x（POST /session、同步 POST /session/{id}/message、
///   GET /event）。2026-10-26 起其 UA 被上游免费层拉黑，已拿不到额度。
/// - v2 = `@opencode/cli` 2.x（POST /api/session、异步 prompt + wait、
///   GET /api/event、Basic 鉴权、结构化额度错误）。现行可用通路。
///
/// 网关（proxy.dart）按探活协商出的 `UpstreamRuntime.openCodeV2` 在两者间
/// 二选一，转发主链路（流式增量、额度换出口重试、看门狗）只依赖本接口。
abstract class OpenCodeServeApi {
  /// CLI 软限流（v1 session.status=retry / v2 session.retry.scheduled）回调。
  /// **只记日志用**：CLI 会自行退避重试，常 17–71s 后自愈，绝不能当烧穿掐死。
  void Function(String message)? get onRetry;
  set onRetry(void Function(String message)? cb);

  /// 生成进展（首个增量、思考、工具活动）回调：刷新看门狗 + 日志。
  void Function(String message)? get onActivity;
  set onActivity(void Function(String message)? cb);

  /// 是否已产出过任何有效输出（已提交/已开始的判定，错误换出口的前提）。
  bool get generationStarted;

  /// 本轮真实 token 用量（v1 info.tokens / v2 session.usage.updated）。
  ({int input, int output}) get lastUsage;
  int get cachedReadTokens;
  int get cachedWriteTokens;

  /// 结构化 429 的重试间隔（秒）；上游没给时机就是 null，**绝不瞎猜**。
  /// v1 没有该能力（恒 null）。
  int? get retryAfterSeconds;

  /// OpenAI 形态 messages → serve 会话协议，流式吐**助手文本增量**。
  /// 出错时 stream 抛异常（约定为 OpenCodeUpstreamError 或其子类）。
  Stream<String> chat({
    required String model,
    required List<Map<String, dynamic>> messages,
    int? maxTokens,
  });

  /// 释放 SSE 订阅与 HttpClient，不泄漏。
  void close();
}
