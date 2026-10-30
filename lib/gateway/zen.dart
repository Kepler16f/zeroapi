import 'dart:convert';
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
    final cooldown =
        retryAfter ??
        Duration(milliseconds: n < 3 ? 1000 : (min(60, 5 * n) * 1000));
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

  /// 免费额度耗尽的判定。上游文案：
  ///   "Free usage limit reached. Subscribe to OpenCode Go to keep going: …"
  /// 这是账号级硬配额（不是 IP 限流）：换出口 IP、退避重试都救不了，
  /// 只能如实告知并引导订阅，或者换别的免费模型。
  static bool isQuotaExhausted(String msg) {
    final m = msg.toLowerCase();
    if (m.isEmpty) return false;
    // 上游有两种文案：
    //   补全返回 "Free usage limit reached. Subscribe to OpenCode Go…"
    //   CLI 重试事件里是 "Free usage exceeded, subscri…"
    // 两者都是账号级额度耗尽，换出口/退避都救不了，只能如实报错。
    return m.contains('free usage limit') ||
        m.contains('free usage exceeded') ||
        (m.contains('usage limit') && m.contains('subscribe')) ||
        (m.contains('quota') && m.contains('exceed'));
  }

  /// 地理屏蔽判定。上游文案（2026-10-22 实测，经 workers.dev 出口时偶发）：
  ///   "This model is not available in your country"
  /// Cloudflare 按连接落在不同国家机房，同一模型换个出口就可能可用——
  /// 与额度同类，属于「换出口重试」而非「等冷却」。
  static bool isGeoBlocked(String msg) =>
      msg.toLowerCase().contains('not available in your country');

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

  /// 一次调用的指纹头。session 每次新建（per-request）——参考项目 jcleng
  /// 的实测结论：per-request 是 safest 模式，sticky 复用单个 ses_ 反而会让
  /// 一个会话短时内堆积大量请求、坐实机器人特征。request id 本就逐次唯一。
  static Map<String, String> headers(String apiKey) {
    final rnd = Random.secure();
    final now = DateTime.now().millisecondsSinceEpoch;
    final sid = 'ses_${_id(now, true, rnd.nextInt(64), rnd)}';
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
                'p': {'type': 'string'},
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

  /// Zen 上游 Go 严格解码（DisallowUnknownFields）实测会拒的客户端扩展字段，
  /// 转发前预剥离。清单之外由 400 自愈机制兜底（unknownFieldOf/stripKeyDeep）。
  static const strictDropFields = {
    'thinking',
    'enable_thinking',
    'reasoning',
    'thinking_budget',
  };

  /// 从上游 400 错误体提取被拒字段名（Go: json: unknown field "X"）
  static final _unknownFieldRe = RegExp(r'unknown field "([^"]+)"');
  static String? unknownFieldOf(String body) =>
      _unknownFieldRe.firstMatch(body)?.group(1);

  /// 400 自愈：按上游报错修正请求体，返回修正说明（无可修正项返回 null）。
  /// 覆盖三类实测坑（jcleng/opencode-free-provider 同款经验）：
  /// 1. unknown field "X" —— 客户端扩展字段被 Go 严格解码拒绝 → 递归剥离
  /// 2. reasoning_content must be passed back —— thinking 模式要求 assistant
  ///    历史带回推理内容（ZCode 不回传）→ 缺失的注入空串占位
  /// 3. tool call function.arguments must be a JSON object —— 空串/坏 JSON
  ///    参数 → 归一化为合法 JSON 对象字符串
  static String? healBody(String err, Map<String, dynamic> body) {
    final field = unknownFieldOf(err);
    if (field != null) {
      return stripKeyDeep(body, field) ? '剥离未知字段 "$field"' : null;
    }
    final lower = err.toLowerCase();
    if (lower.contains('reasoning_content') &&
        lower.contains('must be passed back')) {
      var n = 0;
      for (final m in (body['messages'] as List? ?? const [])) {
        if (m is Map &&
            m['role'] == 'assistant' &&
            m['reasoning_content'] == null) {
          m['reasoning_content'] = '';
          n++;
        }
      }
      return n > 0 ? '为 $n 条 assistant 注入空 reasoning_content' : null;
    }
    if (lower.contains('arguments') && lower.contains('json object')) {
      var n = 0;
      for (final m in (body['messages'] as List? ?? const [])) {
        if (m is Map && m['tool_calls'] is List) {
          for (final tc in (m['tool_calls'] as List)) {
            if (tc is Map && tc['function'] is Map) {
              final fn = tc['function'] as Map;
              final norm = normalizeToolArguments(fn['arguments']);
              if (norm != fn['arguments']) {
                fn['arguments'] = norm;
                n++;
              }
            }
          }
        }
      }
      return n > 0 ? '归一化 $n 个 tool_call arguments' : null;
    }
    return null;
  }

  /// tool_call arguments 归一化（OpenAI 规范：必须是 JSON 对象字符串）
  static String normalizeToolArguments(Object? args) {
    if (args is String) {
      final s = args.trim();
      if (s.isEmpty) return '{}';
      try {
        final p = jsonDecode(s);
        return (p is Map) ? s : '{}';
      } catch (_) {
        return '{}';
      }
    }
    if (args is Map) return jsonEncode(args);
    return '{}';
  }

  static String _hash6(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0').substring(0, 6);
  }

  /// 上游工具名只接受 `[A-Za-z0-9_-]`：实测 `#`、`.`、空格、`:`、`/` 一律
  /// 400（错误体还是空的，客户端只能看到「HTTP 400」）。长度上限虽未实测
  /// 触发（100 字符仍可用），仍按 64 截断兜底。发送前把「超长或含非法字符」
  /// 的名字确定性改写为 `前缀-hash6`，返回 改写名→原名 映射；响应侧用
  /// restoreToolNames 换回，客户端全程无感知。多轮回传历史里的 assistant
  /// tool_calls / tool_choice 同步改写（哈希确定性保证跨请求一致）。
  static final _legalToolName = RegExp(r'^[A-Za-z0-9_-]+$');

  static Map<String, String> shortenToolNames(
    Map<String, dynamic> body, {
    int maxLen = 64,
  }) {
    final map = <String, String>{};
    final tools = body['tools'];
    if (tools is! List) return map;
    // 原样保留（合法且不超长）的名字先占位，改写产物不得与它们撞名
    final used = <String>{};
    for (final t in tools) {
      if (t is Map && t['function'] is Map) {
        final n = (t['function'] as Map)['name']?.toString() ?? '';
        if (n.length <= maxLen && _legalToolName.hasMatch(n)) used.add(n);
      }
    }
    final keep = maxLen - 7; // '-' + 6 位 hash
    String shortOf(String name) {
      final clean = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
      final prefix = clean.length > keep ? clean.substring(0, keep) : clean;
      // hash 只剩 24 位，撞名时按盐递增；同一工具表下结果确定
      for (var salt = 0; ; salt++) {
        final sn = '$prefix-${_hash6(salt == 0 ? name : '$name#$salt')}';
        if (used.add(sn)) return sn;
      }
    }

    var changed = false;
    final rebuilt = <Object>[];
    for (final t in tools) {
      if (t is Map && t['function'] is Map) {
        final fn = t['function'] as Map;
        final name = fn['name']?.toString() ?? '';
        if (name.length > maxLen || !_legalToolName.hasMatch(name)) {
          final sn = shortOf(name);
          map[sn] = name;
          rebuilt.add({
            ...t,
            'function': {...fn, 'name': sn},
          });
          changed = true;
          continue;
        }
      }
      rebuilt.add(t);
    }
    if (changed) body['tools'] = rebuilt;
    if (map.isEmpty) return map;
    final reverse = {for (final e in map.entries) e.value: e.key};
    final msgs = body['messages'];
    if (msgs is List) {
      var mChanged = false;
      final rebuiltMsgs = <Object>[];
      for (final m in msgs) {
        var touched = false;
        if (m is Map && m['tool_calls'] is List) {
          final newTcs = (m['tool_calls'] as List).map((tc) {
            if (tc is Map && tc['function'] is Map) {
              final fn = tc['function'] as Map;
              final sn = reverse[fn['name']?.toString()];
              if (sn != null) {
                touched = true;
                return {
                  ...tc,
                  'function': {...fn, 'name': sn},
                };
              }
            }
            return tc;
          }).toList();
          if (touched) {
            mChanged = true;
            rebuiltMsgs.add({...m, 'tool_calls': newTcs});
            continue;
          }
        }
        rebuiltMsgs.add(m);
      }
      if (mChanged) body['messages'] = rebuiltMsgs;
    }
    final tcf = body['tool_choice'];
    if (tcf is Map && tcf['function'] is Map) {
      final fn = tcf['function'] as Map;
      final sn = reverse[fn['name']?.toString()];
      if (sn != null) {
        body['tool_choice'] = {
          ...tcf,
          'function': {...fn, 'name': sn},
        };
      }
    }
    return map;
  }

  /// 响应回映：把 chunk（delta/message 的 tool_calls）里的截断工具名换回原名
  static void restoreToolNames(
    Map<String, dynamic> chunk,
    Map<String, String> map,
  ) {
    if (map.isEmpty) return;
    final choices = chunk['choices'];
    if (choices is! List) return;
    for (final c in choices) {
      if (c is! Map) continue;
      for (final key in ['delta', 'message']) {
        final m = c[key];
        if (m is Map && m['tool_calls'] is List) {
          for (final tc in (m['tool_calls'] as List)) {
            if (tc is Map && tc['function'] is Map) {
              final fn = tc['function'] as Map;
              final orig = map[fn['name']?.toString()];
              if (orig != null) fn['name'] = orig;
            }
          }
        }
      }
    }
  }

  /// 递归剥离指定 key（顶层与 messages/tools 内任意深度），返回是否有删除
  static bool stripKeyDeep(Object? node, String key) {
    var removed = false;
    if (node is Map) {
      if (node.containsKey(key)) {
        node.remove(key);
        removed = true;
      }
      for (final v in node.values) {
        removed = stripKeyDeep(v, key) || removed;
      }
    } else if (node is List) {
      for (final v in node) {
        removed = stripKeyDeep(v, key) || removed;
      }
    }
    return removed;
  }

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
    Map<String, dynamic> chunk,
    Set<String> injected, {
    Map<int, bool>? decoyIndex,
  }) {
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
            final isDecoy =
                _isDecoyEntry(tc) || (idx is int && dm[idx] == true);
            if (idx is int && !dm.containsKey(idx)) {
              dm[idx] =
                  _isDecoyEntry(tc) ||
                  (tc is Map &&
                      tc['function'] is Map &&
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
      final emptyDelta =
          d is Map && d.isEmpty; // content/reasoning/tool_calls 都被摘除
      if (!(emptyDelta && cm['finish_reason'] == null)) newChoices.add(cm);
    }
    if (newChoices.isEmpty && chunk['usage'] == null) return null;
    chunk['choices'] = newChoices;
    return chunk;
  }

  /// 非流式客户端：把上游 SSE（强制 stream:true）聚合成一个 completion 对象。
  /// 诱饵工具调用（injected/decoy）在聚合结果 message 里整体丢弃。
  static Map<String, dynamic> aggregate(
    List<Map<String, dynamic>> chunks,
    String model,
    Set<String> injected,
  ) {
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
      if (j['usage'] is Map) {
        usage = Map<String, dynamic>.from(j['usage'] as Map);
      }
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
          final idx = (tc['index'] is int)
              ? tc['index'] as int
              : toolCallsByIndex.length;
          final fn = tc['function'];
          final isDecoy =
              _isDecoyEntry(tc) ||
              (fn is Map && injected.contains('${fn['name']}')) ||
              decoyIdx.contains(idx);
          if (isDecoy) {
            decoyIdx.add(idx);
            continue;
          }
          final slot = toolCallsByIndex.putIfAbsent(
            idx,
            () => <String, dynamic>{
              'id': tc['id'],
              'type': 'function',
              'function': {'name': null, 'arguments': ''},
            },
          );
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
    if (reasoning.isNotEmpty) {
      message['reasoning_content'] = reasoning.toString();
    }
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
          'finish_reason':
              finish ?? (toolCallsByIndex.isNotEmpty ? 'tool_calls' : 'stop'),
        },
      ],
      'usage': ?usage,
    };
  }
}
