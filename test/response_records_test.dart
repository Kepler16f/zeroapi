import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroapi/gateway/response_records.dart';
import 'package:zeroapi/gateway/wbdata.dart';

void main() {
  test(
    'gateway JSONL preserves provider, unknown fields and skips invalid lines',
    () async {
      final dir = await Directory.systemTemp.createTemp('response-records');
      addTearDown(() => dir.delete(recursive: true));
      await File('${dir.path}/usage-2026-01-01.jsonl').writeAsString(
        '{"ts":"2026-01-01T10:00:00","model":"m-free","upstream":"vendor","prompt":12,"completion":7,"error":false,"elapsed_ms":42}\ninvalid\n',
      );
      await File('${dir.path}/usage-2026-01-01.jsonl.bak').writeAsString('{}');
      final rows = await ResponseRecordRepository.readGateway(dir.path);
      expect(rows, hasLength(1));
      expect(rows.single.provider, 'vendor');
      expect(rows.single.input, 12);
      expect(rows.single.elapsedMs, 42);
      expect(rows.single.cached, isNull);
      expect(rows.single.success, isTrue);
    },
  );

  test('cache read and write are preserved independently', () {
    final row = ResponseRecord.fromGatewayJson({
      'ts': '2026-01-01T10:00:00',
      'model': 'm',
      'prompt': 100,
      'completion': 10,
      'cached': 20,
      'cache_write': 30,
    })!;
    expect(row.input, 100);
    expect(row.cached, 20);
    expect(row.cacheWrite, 30);
    final legacy = ResponseRecord.fromGatewayJson({
      'ts': '2026-01-01T10:00:00',
      'model': 'm',
      'cached': 0,
    })!;
    expect(legacy.cacheWrite, isNull);
  });

  test('WorkBuddy missing usage remains unknown and is separately sourced', () {
    final row = WbUsageRow(
      ts: DateTime(2026),
      model: 'm',
      account: 'a',
      realm: 'cn',
      prompt: 9,
      completion: 2,
      cached: 1,
      total: 11,
      elapsedMs: 5,
      ttftMs: 0,
      outcome: 'completed',
      ok: true,
      usageMissing: true,
    );
    final stats = WbUsageStats()..add(row);
    expect(stats.rows.single, same(row));
    final record = ResponseRecord.fromWorkBuddy(row);
    expect(record.source, 'WorkBuddy 历史');
    expect(record.input, isNull);
    expect(record.cached, isNull);
  });
  test(
    'only shared request IDs deduplicate; hub-only and legacy rows remain',
    () {
      ResponseRecord row(
        String source,
        String? id, {
        String provider = 'WorkBuddy',
      }) => ResponseRecord(
        time: DateTime(2026),
        model: 'm',
        provider: provider,
        source: source,
        requestId: id,
      );
      final gateway = [
        row('网关', 'same'),
        row('网关', 'other', provider: 'other'),
      ];
      final hub = [
        row('WorkBuddy 历史', 'same'),
        row('WorkBuddy 历史', 'hub-only'),
        row('WorkBuddy 历史', null),
        row('WorkBuddy 历史', 'other'),
      ];
      final merged = ResponseRecordRepository.mergeSources(gateway, hub);
      expect(merged.length, 5);
      expect(merged.where((r) => r.requestId == 'same').length, 1);
      expect(merged.where((r) => r.requestId == 'other').length, 2);
      expect(merged.any((r) => r.requestId == 'hub-only'), isTrue);
      expect(merged.any((r) => r.requestId == null), isTrue);
    },
  );

  test('同一请求合并后保留号池的实际成本', () {
    ResponseRecord row(String source, String? id, {double? cost}) =>
        ResponseRecord(
          time: DateTime(2026),
          model: 'm',
          provider: 'WorkBuddy',
          source: source,
          requestId: id,
          costCny: cost,
        );
    final merged = ResponseRecordRepository.mergeSources(
      [row('网关', 'same')],
      [row('WorkBuddy 历史', 'same', cost: 0.42)],
    );
    expect(merged.length, 1);
    expect(merged.single.source, '网关');
    expect(merged.single.costCny, 0.42);
  });
}
