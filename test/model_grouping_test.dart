import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/proxy.dart';
import 'package:zeroapi/pages.dart';

void main() {
  test('logicalModelName 去掉末尾 -free（忽略大小写），保留展示大小写', () {
    expect(logicalModelName('deepseek-v4.1-flash-free'), 'deepseek-v4.1-flash');
    expect(logicalModelName('GLM-5.3-Flash-FREE'), 'GLM-5.3-Flash');
    expect(logicalModelName('glm-5.3-flash'), 'glm-5.3-flash');
    // 只处理末尾后缀，中间/开头的 free 不误伤
    expect(logicalModelName('free-model'), 'free-model');
    expect(logicalModelName('-free'), '-free');
  });

  test('mergeFreeUsageVariants 把 -free 变体合并到同一逻辑模型', () {
    final s = UsageStats();
    s.add('deepseek-v4.1-flash-free', 10, 5, false);
    s.add('deepseek-v4.1-flash', 20, 10, false);
    s.add('GLM-5.3-Flash-FREE', 1, 2, false);
    final m = mergeFreeUsageVariants(s);

    expect(m.requests, 3);
    expect(m.promptTokens, 31);
    expect(m.completionTokens, 17);
    expect(m.byModel['deepseek-v4.1-flash'], 2);
    expect(m.byModel['GLM-5.3-Flash'], 1);
    expect(m.byModelTokens['deepseek-v4.1-flash'], 45);
    expect(m.byModelTokens['GLM-5.3-Flash'], 3);
    expect(m.byModelTokens.containsKey('deepseek-v4.1-flash-free'), isFalse);
    expect(m.byModelTokens.containsKey('GLM-5.3-Flash-FREE'), isFalse);
  });
}
