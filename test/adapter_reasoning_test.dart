import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/anthropic.dart';

void main() {
  test('Anthropic 流式转换：reasoning_content 不得混入正文输出', () {
    final t = AnthropicAdapter.streamTransformer('m');
    final events = <String>[];
    events.addAll(t.feed('{"choices":[{"index":0,"delta":{"reasoning_content":"内部思考ABC"}}]}'));
    events.addAll(t.feed('{"choices":[{"index":0,"delta":{"content":"正式回答"}}]}'));
    events.addAll(t.finish());
    final all = events.join('');
    expect(all, contains('正式回答'));
    expect(all.contains('内部思考ABC'), false, reason: 'reasoning 不应泄漏到 anthropic 正文');
  });
}
