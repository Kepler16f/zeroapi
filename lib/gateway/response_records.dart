import 'dart:convert';
import 'dart:io';

import 'wbdata.dart';

/// A provider-independent response record. Null means the source omitted it.
class ResponseRecord {
  final DateTime time;
  final String model, provider, source;
  final String? requestId, keyLabel, mode;
  final bool? stream;
  final bool? success;
  final int? elapsedMs, input, output, cached, cacheWrite;
  /// 已折算成人民币的本次成本（号池行来自号池自己的账或本地价表估算）。
  final double? costCny;
  const ResponseRecord({
    required this.time,
    required this.model,
    required this.provider,
    required this.source,
    this.requestId,
    this.keyLabel,
    this.mode,
    this.stream,
    this.success,
    this.elapsedMs,
    this.input,
    this.output,
    this.cached,
    this.cacheWrite,
    this.costCny,
  });

  ResponseRecord copyWith({double? costCny}) => ResponseRecord(
        time: time,
        model: model,
        provider: provider,
        source: source,
        requestId: requestId,
        keyLabel: keyLabel,
        mode: mode,
        stream: stream,
        success: success,
        elapsedMs: elapsedMs,
        input: input,
        output: output,
        cached: cached,
        cacheWrite: cacheWrite,
        costCny: costCny ?? this.costCny,
      );

  static ResponseRecord? fromGatewayJson(Map<String, dynamic> json) {
    final time = DateTime.tryParse('${json['ts'] ?? ''}');
    final model = json['model'];
    if (time == null || model is! String || model.isEmpty) return null;
    int? number(String key) =>
        (json[key] is num) ? (json[key] as num).toInt() : null;
    final error = json['error'];
    return ResponseRecord(
      time: time,
      model: model,
      provider: '${json['upstream'] ?? '未知'}',
      source: '网关',
      requestId: json['request_id'] as String?,
      keyLabel: json['key_label'] as String?,
      mode: json['mode'] as String?,
      stream: json['stream'] is bool ? json['stream'] as bool : null,
      success: error is bool ? !error : null,
      elapsedMs: number('elapsed_ms'),
      input: number('prompt'),
      output: number('completion'),
      cached: number('cached'),
      cacheWrite: number('cache_write'),
    );
  }

  factory ResponseRecord.fromWorkBuddy(WbUsageRow row) => ResponseRecord(
    time: row.ts,
    model: row.model,
    provider: 'WorkBuddy',
    source: 'WorkBuddy 历史',
    requestId: row.requestId,
    success: row.ok,
    elapsedMs: row.elapsedMs > 0 ? row.elapsedMs : null,
    input: row.usageMissing ? null : row.prompt.round(),
    output: row.usageMissing ? null : row.completion.round(),
    cached: row.usageMissing ? null : row.cached.round(),
    costCny: row.billedCny,
  );
}

class ResponseRecordRepository {
  /// Only a shared request ID proves identity. Legacy records stay separate.
  static List<ResponseRecord> mergeSources(
    List<ResponseRecord> gateway,
    List<ResponseRecord> hub,
  ) {
    final ids = gateway
        .where(
          (r) =>
              r.provider.toLowerCase() == 'workbuddy' &&
              r.requestId != null &&
              r.requestId!.isNotEmpty,
        )
        .map((r) => r.requestId)
        .toSet();
    // 号池行与网关行指向同一请求时合并成一条：保留网关侧的耗时/模式等
    // 字段，同时把号池侧的成本带过来（号池才知道实际扣费）。
    final hubById = <String, ResponseRecord>{
      for (final r in hub)
        if (r.requestId != null && r.requestId!.isNotEmpty)
          r.requestId!: r,
    };
    final result = <ResponseRecord>[];
    for (final r in gateway) {
      final twin = r.requestId == null ? null : hubById[r.requestId];
      result.add(twin?.costCny != null ? r.copyWith(costCny: twin!.costCny) : r);
    }
    result.addAll(
      hub.where(
        (r) =>
            r.requestId == null ||
            r.requestId!.isEmpty ||
            !ids.contains(r.requestId),
      ),
    );
    result.sort((a, b) => b.time.compareTo(a.time));
    return result;
  }

  static Future<List<ResponseRecord>> readGateway(
    String directory, {
    int? days,
  }) async {
    final dir = Directory(directory);
    if (!await dir.exists()) return [];
    final now = DateTime.now();
    final cutoff = days == null
        ? null
        : DateTime(
            now.year,
            now.month,
            now.day,
          ).subtract(Duration(days: days - 1));
    final records = <ResponseRecord>[];
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File ||
          !RegExp(r'usage-\d{4}-\d{2}-\d{2}\.jsonl$').hasMatch(entry.path)) {
        continue;
      }
      try {
        await for (final line
            in entry
                .openRead()
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          try {
            final json = jsonDecode(line);
            if (json is! Map<String, dynamic>) continue;
            final row = ResponseRecord.fromGatewayJson(json);
            if (row != null &&
                (cutoff == null || !row.time.toLocal().isBefore(cutoff))) {
              records.add(row);
            }
          } catch (_) {
            /* Ignore malformed or incomplete lines. */
          }
        }
      } on FileSystemException {
        /* A rotated file may disappear during reading. */
      }
    }
    records.sort((a, b) => b.time.compareTo(a.time));
    return records;
  }
}
