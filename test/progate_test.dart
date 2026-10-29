// ProGate：上游按账号类型拒绝 → 标「仅 Pro」；成功调用 → 解除；持久化往返。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/progate.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('progate-');
    ProGate.setFileForTest(File('${tmp.path}/progate.json'));
    ProGate.instance.resetForTest();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('isUserTypeRejection 认 11158 与文案', () {
    expect(
      ProGate.isUserTypeRejection(
        '{"code":11158,"msg":"model [gpt-5.5] is not allowed for user type [personal_free_user]"}',
      ),
      isTrue,
    );
    expect(ProGate.isUserTypeRejection('当前账号类型暂不支持该模型。'), isTrue);
    expect(
      ProGate.isUserTypeRejection('upstream 429 too many requests'),
      isFalse,
    );
  });

  test('mark / isPro / clear', () {
    expect(ProGate.instance.isPro('workbuddy', 'gpt-5.5'), isFalse);
    ProGate.instance.mark('workbuddy', 'gpt-5.5');
    expect(ProGate.instance.isPro('workbuddy', 'gpt-5.5'), isTrue);
    expect(ProGate.instance.proModels('workbuddy'), {'gpt-5.5'});
    ProGate.instance.clear('workbuddy', 'gpt-5.5');
    expect(ProGate.instance.isPro('workbuddy', 'gpt-5.5'), isFalse);
  });

  test('持久化：mark 后重载仍在；重复 mark 不重复存', () {
    ProGate.instance.mark('workbuddy', 'gpt-5.5');
    ProGate.instance.mark('workbuddy', 'gpt-5.5');
    expect(File('${tmp.path}/progate.json').existsSync(), isTrue);
    ProGate.instance.resetForTest();
    expect(ProGate.instance.isPro('workbuddy', 'gpt-5.5'), isFalse);
    // 重新从磁盘加载
    ProGate.setFileForTest(File('${tmp.path}/progate.json'));
    expect(ProGate.instance.isPro('workbuddy', 'gpt-5.5'), isTrue);
    expect(ProGate.instance.proModels('workbuddy').length, 1);
  });
}
