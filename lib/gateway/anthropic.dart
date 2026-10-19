import 'dart:convert';

/// Anthropic Messages API (/v1/messages) ⇄ OpenAI Chat Completions 双向转换。
/// 网关对上游仍走 OpenAI 格式，这里只做协议翻译。
class AnthropicAdapter {
  /// Anthropic 请求体 → OpenAI chat/completions 请求体
  static Map<String, dynamic> toOpenAIRequest(Map<String, dynamic> body) {
    final out = <String, dynamic>{
      if (body['model'] != null) 'model': body['model'],
      'messages': _toOpenAIMessages(body),
    };
    if (body['max_tokens'] != null) out['max_tokens'] = body['max_tokens'];
    if (body['temperature'] != null) out['temperature'] = body['temperature'];
    if (body['top_p'] != null) out['top_p'] = body['top_p'];
    if (body['stop_sequences'] != null) {
      out['stop'] = (body['stop_sequences'] as List).cast<String>();
    }
    if (body['stream'] != null) out['stream'] = body['stream'];
    final tools = body['tools'] as List?;
    if (tools != null && tools.isNotEmpty) {
      out['tools'] = tools
          .map((t) => {
                'type': 'function',
                'function': {
                  'name': t['name'],
                  if (t['description'] != null) 'description': t['description'],
                  if (t['input_schema'] != null)
                    'parameters': t['input_schema'],
                }
              })
          .toList();
    }
    final tc = body['tool_choice'];
    if (tc is Map) {
      out['tool_choice'] = switch (tc['type']) {
        'auto' => 'auto',
        'any' => 'required',
        'tool' => {
            'type': 'function',
            'function': {'name': tc['name']}
          },
        _ => 'auto',
      };
    }
    return out;
  }

  static List<dynamic> _toOpenAIMessages(Map<String, dynamic> body) {
    final msgs = <dynamic>[];
    final system = body['system'];
    if (system != null) {
      final text = system is String
          ? system
          : (system as List)
              .map((b) => (b as Map)['text'] as String? ?? '')
              .join('\n');
      if (text.isNotEmpty) msgs.add({'role': 'system', 'content': text});
    }
    for (final m in (body['messages'] as List? ?? const [])) {
      final msg = m as Map<String, dynamic>;
      final role = msg['role'] as String? ?? 'user';
      final content = msg['content'];
      if (content is String) {
        msgs.add({'role': role, 'content': content});
        continue;
      }
      final blocks = (content as List? ?? const []).cast<Map>();
      final textParts = <String>[];
      final imageParts = <Map<String, dynamic>>[];
      final toolCalls = <Map<String, dynamic>>[];
      final toolResults = <Map<String, dynamic>>[];
      final reasoningParts = <String>[];
      for (final b in blocks) {
        switch (b['type']) {
          case 'text':
            textParts.add(b['text'] as String? ?? '');
            break;
          case 'thinking':
            // Claude Code 等会把上一轮思考以 thinking 块回传；DeepSeek 系
            // thinking 模式要求 assistant 历史必须带回 reasoning_content，
            // 这里映射回去，从源头满足回传要求（而非丢弃后等上游 400）
            reasoningParts.add(b['thinking'] as String? ?? '');
            break;
          case 'image':
            final src = b['source'] as Map?;
            if (src != null) {
              final url = src['type'] == 'url'
                  ? src['url'] as String
                  : 'data:${src['media_type']};base64,${src['data']}';
              imageParts.add({
                'type': 'image_url',
                'image_url': {'url': url}
              });
            }
            break;
          case 'tool_use':
            toolCalls.add({
              'id': b['id'],
              'type': 'function',
              'function': {
                'name': b['name'],
                'arguments': jsonEncode(b['input'] ?? {})
              }
            });
            break;
          case 'tool_result':
            toolResults.add({
              'role': 'tool',
              'tool_call_id': b['tool_use_id'],
              'content': _toolResultText(b),
            });
            break;
          case 'document':
            break; // 透传不支持的块类型忽略
        }
      }
      // tool_result 实际以 user role 出现，需拆成独立 tool message
      msgs.addAll(toolResults);
      final hasBody = textParts.isNotEmpty || imageParts.isNotEmpty;
      final reasoning = reasoningParts.join('');
      if (role == 'assistant') {
        msgs.add({
          'role': 'assistant',
          'content': hasBody ? _contentOf(textParts, imageParts) : (toolCalls.isNotEmpty ? '' : null),
          if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
          if (reasoning.isNotEmpty) 'reasoning_content': reasoning,
        });
      } else if (hasBody) {
        msgs.add({'role': role, 'content': _contentOf(textParts, imageParts)});
      }
    }
    return msgs;
  }

  static dynamic _contentOf(List<String> textParts, List<Map<String, dynamic>> images) {
    final text = textParts.join('');
    if (images.isEmpty) return text;
    return [
      if (text.isNotEmpty) {'type': 'text', 'text': text},
      ...images,
    ];
  }

  static String _toolResultText(Map b) {
    final c = b['content'];
    if (c is String) return c;
    if (c is List) {
      return c
          .map((p) => p is Map && p['type'] == 'text' ? (p['text'] ?? '') : '')
          .join('\n');
    }
    return '';
  }

  /// OpenAI chat/completions 非流式响应 → Anthropic message
  static Map<String, dynamic> toAnthropicResponse(Map<String, dynamic> oai) {
    final choice = (oai['choices'] as List?)?.firstOrNull as Map?;
    final msg = (choice?['message'] ?? const {}) as Map;
    final content = <Map<String, dynamic>>[];
    final text = msg['content'];
    if (text is String && text.isNotEmpty) {
      content.add({'type': 'text', 'text': text});
    } else if (text is List) {
      final t = text
          .map((p) => p is Map && p['type'] == 'text' ? (p['text'] ?? '') : '')
          .join();
      if (t.isNotEmpty) content.add({'type': 'text', 'text': t});
    }
    for (final tc in (msg['tool_calls'] as List? ?? const [])) {
      final f = (tc as Map)['function'] as Map?;
      content.add({
        'type': 'tool_use',
        'id': tc['id'] ?? 'toolu_${DateTime.now().microsecondsSinceEpoch}',
        'name': f?['name'],
        'input': _tryDecode(f?['arguments']),
      });
    }
    final us = oai['usage'] as Map?;
    return {
      'id': 'msg_${oai['id']?.toString().replaceFirst('chatcmpl-', '') ?? DateTime.now().microsecondsSinceEpoch}',
      'type': 'message',
      'role': 'assistant',
      'content': content,
      'model': oai['model'] ?? '',
      'stop_reason': _stopReason(choice?['finish_reason']),
      'stop_sequence': null,
      'usage': {
        'input_tokens': (us?['prompt_tokens'] ?? 0),
        'output_tokens': (us?['completion_tokens'] ?? 0),
      },
    };
  }

  /// OpenAI 流式 chunk → Anthropic SSE 事件序列（有状态流转换器）
  static AnthropicStreamTransformer streamTransformer(String model) =>
      AnthropicStreamTransformer._(model);

  static Map<String, dynamic>? _tryDecode(dynamic s) {
    if (s == null) return {};
    if (s is Map) return s.cast<String, dynamic>();
    try {
      return jsonDecode(s as String) as Map<String, dynamic>;
    } catch (_) {
      return {'_raw': s};
    }
  }

  static String? _stopReason(dynamic finish) => switch (finish) {
        'stop' => 'end_turn',
        'length' => 'max_tokens',
        'tool_calls' => 'tool_use',
        'function_call' => 'tool_use',
        'content_filter' => 'end_turn',
        _ => null,
      };
}

/// 有状态转换：把 OpenAI chat SSE chunk 逐条转成 Anthropic 事件。
/// 每个输出元素是 (event, data)；调用方负责加 SSE 帧格式。
class AnthropicStreamTransformer {
  final String model;
  bool _started = false;
  int _textBlockIndex = -1;
  final Map<int, int> _toolBlockIndex = {}; // openai tc index -> anthropic content index
  int _nextBlock = 0;
  int _inputTokens = 0;
  int _outputTokens = 0;
  String? _finish;
  final List<(String, Map<String, dynamic>)> _pending = [];

  AnthropicStreamTransformer._(this.model);

  static String _ev((String, Map<String, dynamic>) e) =>
      'event: ${e.$1}\ndata: ${jsonEncode(e.$2)}\n\n';

  List<String> feed(String dataLine) {
    Map<String, dynamic> chunk;
    try {
      chunk = jsonDecode(dataLine) as Map<String, dynamic>;
    } catch (_) {
      return const [];
    }
    final us = chunk['usage'] as Map?;
    if (us != null) {
      _inputTokens = (us['prompt_tokens'] ?? _inputTokens) as int;
      _outputTokens = (us['completion_tokens'] ?? _outputTokens) as int;
    }
    final choices = (chunk['choices'] as List?) ?? const [];
    if (choices.isEmpty) return const [];
    final c = choices.first as Map<String, dynamic>;
    final delta = (c['delta'] ?? const {}) as Map<String, dynamic>;
    _finish ??= c['finish_reason'] as String?;

    _pending.clear();
    _ensureStart();

    final content = delta['content'];
    if (content is String && content.isNotEmpty) {
      _ensureTextBlock();
      _pending.add(('content_block_delta', {
        'type': 'content_block_delta',
        'index': _textBlockIndex,
        'delta': {'type': 'text_delta', 'text': content},
      }));
    }
    for (final raw in (delta['tool_calls'] as List? ?? const [])) {
      final t = raw as Map<String, dynamic>;
      final oi = (t['index'] ?? 0) as int;
      final fn = t['function'] as Map?;
      final blockIdx = _toolBlockIndex.putIfAbsent(oi, () {
        final idx = _nextBlock++;
        _pending.add(('content_block_start', {
          'type': 'content_block_start',
          'index': idx,
          'content_block': {
            'type': 'tool_use',
            'id': t['id'] ?? 'toolu_${DateTime.now().microsecondsSinceEpoch}_$oi',
            'name': fn?['name'] ?? '',
            'input': <String, dynamic>{},
          },
        }));
        return idx;
      });
      final argDelta = fn?['arguments'] as String?;
      if (argDelta != null && argDelta.isNotEmpty) {
        _pending.add(('content_block_delta', {
          'type': 'content_block_delta',
          'index': blockIdx,
          'delta': {'type': 'input_json_delta', 'partial_json': argDelta},
        }));
      }
    }

    final out = _pending.map(_ev).toList();
    return out;
  }

  /// OpenAI [DONE] 时调用，产出收尾事件
  List<String> finish() {
    _pending.clear();
    _ensureStart();
    if (_textBlockIndex >= 0 || _toolBlockIndex.isNotEmpty) {
      for (final i in [
        if (_textBlockIndex >= 0) _textBlockIndex,
        ..._toolBlockIndex.values,
      ]) {
        _pending.add(('content_block_stop', {'type': 'content_block_stop', 'index': i}));
      }
    }
    _pending.add(('message_delta', {
      'type': 'message_delta',
      'delta': {'stop_reason': AnthropicAdapter._stopReason(_finish) ?? 'end_turn', 'stop_sequence': null},
      'usage': {'output_tokens': _outputTokens},
    }));
    _pending.add(('message_stop', {'type': 'message_stop'}));
    return _pending.map(_ev).toList();
  }

  void _ensureStart() {
    if (_started) return;
    _started = true;
    _pending.add(('message_start', {
      'type': 'message_start',
      'message': {
        'id': 'msg_${DateTime.now().microsecondsSinceEpoch}',
        'type': 'message',
        'role': 'assistant',
        'content': <dynamic>[],
        'model': model,
        'stop_reason': null,
        'stop_sequence': null,
        'usage': {'input_tokens': _inputTokens, 'output_tokens': 0},
      },
    }));
    _pending.add(('ping', {'type': 'ping'}));
  }

  void _ensureTextBlock() {
    if (_textBlockIndex >= 0) return;
    _textBlockIndex = _nextBlock++;
    _pending.add(('content_block_start', {
      'type': 'content_block_start',
      'index': _textBlockIndex,
      'content_block': {'type': 'text', 'text': ''},
    }));
  }
}
