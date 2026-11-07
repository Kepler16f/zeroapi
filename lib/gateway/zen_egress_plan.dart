/// zen 出口三级轮换状态机（2026-11-07，用户指定顺序）：
///
/// **Worker（CF 边缘 IP）→ 机场节点 → 直连**
///
/// 设计依据：
/// - 免费额度按「客户端身份 × 最终到达 opencode.ai 的出口 IP × 天」计。
/// - Worker 通路：出口 = CF 边缘 IP，**同一机场节点断开重连即换 CF IP**
///   （10-22 实测：同节点连开 12 条新连接全 200）——换 IP 成本最低，
///   且不消耗机场节点的额度桶，放第一档。
/// - 机场通路：出口 = 节点 IP，换 IP 必须换节点 + 重启 CLI。
/// - 直连：出口 = 家宽/FlClash IP，独立的额度桶，最后兜底。
///
/// 各档对失败类型的处理不同：
/// - **额度耗尽（free-limit）**：Worker 档 → 重连换 CF IP（新连接≠旧 IP，
///   retryAfter 只描述旧 IP）；机场档 → 该节点当天冷却，换下一节点；
///   直连档 → 全部桶耗尽，记录恢复时刻。
/// - **传输失败（连不上）**：Worker 档 → 该节点到 workers.dev 不通，
///   同节点重连无意义 → 直接降到机场档；机场档 → 换下一节点；
///   直连档 → 如实报错。
/// - **停滞（挂死）**：视同传输失败（出口死了）。
enum ZenEgressTier { worker, airport, direct }

enum ZenEgressAction {
  /// 同节点重启 CLI（Worker 档）：新连接 = 新 CF 边缘 IP。
  workerReconnect,

  /// 换池内下一个节点（机场档）。
  airportNext,

  /// 切直连（无代理）。
  direct,

  /// 三档全部耗尽：报整池烧穿（附恢复时刻）。
  exhausted,
}

class ZenEgressPlan {
  ZenEgressPlan();

  ZenEgressTier tier = ZenEgressTier.worker;
  int workerAttempts = 0;
  int airportAttempts = 0;
  bool directTried = false;

  /// 机场档在本轮的尝试预算（ Worker 2 次 + 机场 3 次 + 直连 1 次 = 6 轮，
  /// 与既有「最多 6 个出口」的总预算一致）。
  static const workerBudget = 2;
  static const airportBudget = 3;

  /// 失败后决定下一步动作。
  ///
  /// [lastFailureKind]：'quota'（额度耗尽）/ 'transport'（连不上或挂死）。
  /// [airportHasCandidate]：机场档是否还有没试过的池节点。
  /// [directUsable]：直连是否值得试（如家宽出口健康）。
  ZenEgressAction next({
    required String lastFailureKind,
    required bool airportHasCandidate,
    bool directUsable = true,
  }) {
    if (tier == ZenEgressTier.worker) {
      // 额度耗尽 → 重连换 CF IP；传输失败 → 该节点到不了 workers.dev，
      // 重连无意义，直接降档。
      if (lastFailureKind == 'quota' && workerAttempts < workerBudget) {
        workerAttempts++;
        return ZenEgressAction.workerReconnect;
      }
      tier = ZenEgressTier.airport;
    }
    if (tier == ZenEgressTier.airport) {
      if (airportAttempts < airportBudget && airportHasCandidate) {
        airportAttempts++;
        return ZenEgressAction.airportNext;
      }
      tier = ZenEgressTier.direct;
    }
    if (tier == ZenEgressTier.direct && !directTried && directUsable) {
      directTried = true;
      return ZenEgressAction.direct;
    }
    return ZenEgressAction.exhausted;
  }

  /// 是否已经离开 Worker 档（切档时需要还原 baseURL 注入）。
  bool get leftWorker => tier != ZenEgressTier.worker;
}
