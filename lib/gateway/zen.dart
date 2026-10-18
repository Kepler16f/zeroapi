import 'dart:math';

/// 单模型熔断器：某免费模型被 429/5xx 命中后，在冷却窗口内直接快速失败，
/// 避免高并发下每个请求都去撞坏端点（重试风暴会放大限流）。
class ModelBreaker {
  final Map<String, DateTime> _blockedUntil = {};
  final Map<String, int> _failures = {};

  /// 该模型当前是否处于冷却（熔断打开）
  bool isOpen(String model) =>
      (_blockedUntil[model]?.isAfter(DateTime.now())) ?? false;

  /// 记一次失败：连败达到阈值即打开熔断，冷却随连败次数增长（封顶 60s）
  void onFailure(String model, {Duration? retryAfter}) {
    final n = (_failures[model] ?? 0) + 1;
    _failures[model] = n;
    final cooldown = retryAfter ??
        Duration(
            milliseconds: n < 3 ? 1000 : (min(60, 5 * n) * 1000));
    final until = DateTime.now().add(cooldown);
    final cur = _blockedUntil[model];
    if (cur == null || until.isAfter(cur)) _blockedUntil[model] = until;
  }

  void onSuccess(String model) {
    _failures.remove(model);
    _blockedUntil.remove(model);
  }
}

/// OpenCode Zen 免费层「直连」支持：不 spawn opencode 二进制，按同类高星项目
/// （jcleng/opencode-free-provider 实测）复刻免费层要求的客户端指纹，直接调
/// https://opencode.ai/inference/v1 。只暴露免费档模型（big-pickle / *-free），
/// 其余付费模型（claude-*、gpt-*、gemini-*、grok-* 等）一律不注册、默认隐藏。
class Zen {
  static const base = 'https://opencode.ai/inference/v1';
  static const _ua = 'opencode/latest/2.0.22/cli';
  static const _b62 =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

  /// 免费档模型判定：内置 big-pickle，或 id 含 -free。上游免费门只认这批；
  /// 付费 id 虽在 /models 里返回但补全会被拒，故这里直接过滤掉、不对客户端展示。
  static bool isFreeModel(String id) =>
      id == 'big-pickle' || (id.contains('-free') && !id.contains('['));

  /// opencode 的降序标识符：12 位小写 hex + 14 位 base62。
  /// hex = (~(ts*0x1000+counter)) 的低 48 位；服务端只校验低 12 位 counter<=63
  /// （无校验和）。counter 取 0..63 均可，这里用随机小值贴近真机分布。
  static String _id(int ts, bool descending, int counter, Random rnd) {
    final cur = BigInt.from(ts) * BigInt.from(0x1000) + BigInt.from(counter);
    final mask = (BigInt.one << 48) - BigInt.one;
    final v = descending ? (~cur & mask) : (cur & mask);
    final sb = StringBuffer(v.toRadixString(16).padLeft(12, '0'));
    for (var i = 0; i < 14; i++) {
      sb.write(_b62[rnd.nextInt(_b62.length)]);
    }
    return sb.toString();
  }

  /// 一次调用的指纹头。关键拟人点：会话 ID 跨请求复用（真实 opencode 一整段
  /// 对话只有一个 ses_，只有 request 逐次新建）——每请求换新 session 是机器
  /// 流量特征，会触发上游「Detect Abuse Traffic」403。滚动窗口：10 分钟或
  /// 100 次请求换一次会话，贴近真人开新对话的节奏。
  static String? _sid;
  static DateTime? _sidAt;
  static int _sidUse = 0;

  static String _sessionId(Random rnd, int now) {
    final stale = _sid == null ||
        DateTime.now().difference(_sidAt!) > const Duration(minutes: 10) ||
        _sidUse >= 100;
    if (stale) {
      _sid = 'ses_${_id(now, true, rnd.nextInt(64), rnd)}';
      _sidAt = DateTime.now();
      _sidUse = 0;
    }
    _sidUse++;
    return _sid!;
  }

  static Map<String, String> headers(String apiKey) {
    final rnd = Random.secure();
    final now = DateTime.now().millisecondsSinceEpoch;
    final sid = _sessionId(rnd, now);
    final rid = 'msg_${_id(now, false, rnd.nextInt(64), rnd)}';
    return {
      'user-agent': _ua,
      'x-opencode-session': sid,
      'x-opencode-session-id': sid,
      'x-opencode-request': rid,
      'x-opencode-client': 'cli',
      'x-opencode-project': 'global',
      'accept': 'text/event-stream, application/json',
      'authorization': 'Bearer ${apiKey.isEmpty ? 'public' : apiKey}',
    };
  }

  /// 免费层强制要求 tools 含 bash/glob/grep/read（各恰好一次），缺则 403。
  /// 返回补齐后的 tools；injected 记录本代理补进去的工具名（回传时据此丢弃
  /// 模型对这些"诱饵工具"的调用，避免把客户端没声明的工具塞回它）。
  static List ensureFreeTools(Object? raw, Set<String> injected) {
    final list = <Map<String, dynamic>>[];
    final have = <String>{};
    if (raw is List) {
      for (final t in raw) {
        if (t is Map && t['function'] is Map) {
          have.add('${(t['function'] as Map)['name']}');
        }
        list.add(Map<String, dynamic>.from(t as Map));
      }
    }
    for (final name in ['bash', 'glob', 'grep', 'read']) {
      if (!have.contains(name)) {
        injected.add(name);
        list.add({
          'type': 'function',
          'function': {
            'name': name,
            'description': name,
            'parameters': {
              'type': 'object',
              'properties': {
                'p': {'type': 'string'}
              },
              'required': ['p'],
            },
          },
        });
      }
    }
    return list;
  }

  /// 诱饵工具名集合（与 ensureFreeTools 注入的对应）。
  static const decoyTools = {'bash', 'glob', 'grep', 'read'};

  /// 判断某 tool_call 条目是否为诱饵工具（按 function.name）。
  static bool _isDecoyEntry(Object? tc) {
    if (tc is! Map) return false;
    final fn = tc['function'];
    return fn is Map && decoyTools.contains('${fn['name']}');
  }

  /// 转发流式响应给客户端时剔除诱饵工具调用：
  /// 维护 index→是否诱饵 映射；诱饵条目自身返回 null 表示"该行应整行丢弃"，
  /// 非诱饵条目返回可能被修剪过（去掉误入的诱饵增量）的行。
  /// chunkJson 为已解码的 chunk Map；injected 为本代理补加的工具名集合。
  static Map<String, dynamic>? filterDecoyChunk(
      Map<String, dynamic> chunk, Set<String> injected,
      {Map<int, bool>? decoyIndex}) {
    if (injected.isEmpty) return chunk;
    final dm = decoyIndex ?? <int, bool>{};
    final choices = chunk['choices'];
    if (choices is! List) return chunk;
    final newChoices = <Object>[];
    for (final c in choices) {
      if (c is! Map) {
        newChoices.add(c);
        continue;
      }
      final cm = Map<String, dynamic>.from(c);
      for (final key in ['delta', 'message']) {
        final m = cm[key];
        if (m is Map && m['tool_calls'] is List) {
          final kept = <Object>[];
          for (final tc in (m['tool_calls'] as List)) {
            final idx = tc is Map ? tc['index'] : null;
            final isDecoy = _isDecoyEntry(tc) ||
                (idx is int && dm[idx] == true);
            if (idx is int && !dm.containsKey(idx)) {
              dm[idx] = _isDecoyEntry(tc) ||
                  (tc is Map && tc['function'] is Map &&
                      injected.contains('${(tc['function'] as Map)['name']}'));
            }
            if (isDecoy) continue;
            kept.add(tc);
          }
          if (kept.isEmpty) {
            m.remove('tool_calls');
          } else {
            m['tool_calls'] = kept;
          }
        }
      }
      // 若 delta/message 已空且 finish_reason 也为空，整条 choice 可丢
      final d = cm['delta'];
      final emptyDelta = d is Map &&
          d.isEmpty; // content/reasoning/tool_calls 都被摘除
      if (!(emptyDelta && cm['finish_reason'] == null)) newChoices.add(cm);
    }
    if (newChoices.isEmpty && chunk['usage'] == null) return null;
    chunk['choices'] = newChoices;
    return chunk;
  }

  /// 非流式客户端：把上游 SSE（强制 stream:true）聚合成一个 completion 对象。
  /// 诱饵工具调用（injected/decoy）在聚合结果 message 里整体丢弃。
  static Map<String, dynamic> aggregate(List<Map<String, dynamic>> chunks,
      String model, Set<String> injected) {
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final toolCallsByIndex = <int, Map<String, dynamic>>{};
    final decoyIdx = <int>{};
    Map<String, dynamic>? usage;
    String? finish;
    String? id;
    int? created;
    for (final j in chunks) {
      id ??= j['id'] as String?;
      created ??= j['created'] as int?;
      if (j['usage'] is Map) usage = Map<String, dynamic>.from(j['usage'] as Map);
      for (final c in (j['choices'] as List? ?? const [])) {
        if (c is! Map) continue;
        if (c['finish_reason'] != null) finish = c['finish_reason'] as String?;
        final delta = c['delta'];
        if (delta is! Map) continue;
        if (delta['content'] is String) text.write(delta['content']);
        if (delta['reasoning_content'] is String) {
          reasoning.write(delta['reasoning_content']);
        }
        for (final tc in (delta['tool_calls'] as List? ?? const [])) {
          if (tc is! Map) continue;
          final idx = (tc['index'] is int) ? tc['index'] as int : toolCallsByIndex.length;
          final fn = tc['function'];
          final isDecoy = _isDecoyEntry(tc) ||
              (fn is Map && injected.contains('${fn['name']}')) ||
              decoyIdx.contains(idx);
          if (isDecoy) {
            decoyIdx.add(idx);
            continue;
          }
          final slot = toolCallsByIndex.putIfAbsent(idx, () => <String, dynamic>{
                'id': tc['id'],
                'type': 'function',
                'function': {'name': null, 'arguments': ''},
              });
          slot['id'] ??= tc['id'];
          if (fn is Map) {
            if (fn['name'] != null) {
              slot['function']['name'] = fn['name'];
              if (injected.contains('${fn['name']}')) {
                decoyIdx.add(idx);
                toolCallsByIndex.remove(idx);
                continue;
              }
            }
            if (fn['arguments'] is String) {
              slot['function']['arguments'] =
                  '${slot['function']['arguments']}${fn['arguments']}';
            }
          }
        }
      }
    }
    final message = <String, dynamic>{
      'role': 'assistant',
      'content': text.isEmpty ? null : text.toString(),
    };
    if (reasoning.isNotEmpty) message['reasoning_content'] = reasoning.toString();
    if (toolCallsByIndex.isNotEmpty) {
      final ordered = (toolCallsByIndex.keys.toList()..sort())
          .map((i) => toolCallsByIndex[i]!)
          .toList();
      message['tool_calls'] = ordered;
    }
    return {
      'id': id ?? 'chatcmpl-zen',
      'object': 'chat.completion',
      'created': created ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'model': model,
      'choices': [
        {
          'index': 0,
          'message': message,
          'finish_reason': finish ?? (toolCallsByIndex.isNotEmpty ? 'tool_calls' : 'stop'),
        }
      ],
      'usage': ?usage,
    };
  }
}
