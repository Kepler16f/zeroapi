import 'dart:convert';
import 'dart:io';

/// WorkBuddy 号池的「写操作」封装（区别于 accountdata/wbdata 的只读数据层）。
///
/// 目前只有一件事：一键签到。hub（本地免密，由本应用以 --host 127.0.0.1
/// 拉起）提供
/// `POST {hubBase}/accounts/checkin`：
///   * body 传 `{}` —— 对所有国内版（cn realm）账号逐个签到；
///   * 传 `{"uid": "..."}` —— 只签指定账号。
/// 响应形如
/// ```json
/// {"results": [
///    {"uid": "...", "nickname": "...", "ok": true,  "msg": "签到成功"},
///    {"uid": "...", "nickname": "...", "ok": false, "error": "今天已签到"}
///  ], "accounts": [...]}
/// ```
/// 注意失败条目带的是 `error` 字段、成功条目带的是 `msg` 字段（hub 侧
/// `checkin()` 的返回形状，见 vendor 的 wb_accounts.py）。
class HubActions {
  HubActions._();

  /// 单次签到请求的整体超时：hub 要逐个账号打上游（每号最多 15s），
  /// 20s 够小池跑完一轮，又不至于让 UI 干等。
  static const _timeout = Duration(seconds: 20);

  /// 汇总签到响应为一句人类可读结果。
  ///
  /// 例：`签到成功 3 个、失败 1 个（账号A：已达上限）`；
  /// 全成功只出现成功数；`results` 缺失/非列表/为空一律
  /// `没有可签到的账号`。纯函数，不抛异常——结构再怪也只降级成文案。
  static String summarizeCheckin(Map<String, dynamic> json) {
    final raw = json['results'];
    if (raw is! List) return '没有可签到的账号';
    final results = raw.whereType<Map>().toList();
    if (results.isEmpty) return '没有可签到的账号';

    String s(Object? v) {
      final t = v?.toString().trim() ?? '';
      return t;
    }

    var ok = 0;
    final fails = <String>[];
    for (final r in results) {
      if (r['ok'] == true) {
        ok++;
        continue;
      }
      // 名称取 nickname，缺失时回落 uid 前 8 位（与 hub 自己记日志的口径
      // 一致）；原因取 error，缺失回落 msg（hub 把「今天已签到」按成功处理
      // 时也才放 msg，这里两条路都兜住）。
      final nick = s(r['nickname']);
      final uid = s(r['uid']);
      final name = nick.isNotEmpty
          ? nick
          : (uid.isNotEmpty
                ? uid.substring(0, uid.length < 8 ? uid.length : 8)
                : '未知账号');
      final err = s(r['error']);
      final msg = s(r['msg']);
      final reason = err.isNotEmpty ? err : (msg.isNotEmpty ? msg : '未知原因');
      fails.add('$name：$reason');
    }
    return fails.isEmpty
        ? '签到成功 $ok 个'
        : '签到成功 $ok 个、失败 ${fails.length} 个（${fails.join('；')}）';
  }

  /// 向 hub 发一键签到（`POST {hubBase}/accounts/checkin`，body `{}`
  /// 即全部国内账号），整体 20s 超时。
  ///
  /// [hubBase] 允许带末尾斜杠（如面板地址 `http://127.0.0.1:8788/`），
  /// 内部会归一。成功返回 [summarizeCheckin] 的文案；地址为空、网络失败、
  /// 超时、非 200、响应不是 JSON 对象都抛异常（UI 直接显示原因）。
  static Future<String> checkinAll(String hubBase) async {
    var root = hubBase.trim();
    while (root.endsWith('/')) {
      root = root.substring(0, root.length - 1);
    }
    if (root.isEmpty) {
      throw const FormatException('未配置 WorkBuddy 号池地址');
    }
    final uri = Uri.parse('$root/accounts/checkin');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.write('{}');
      final resp = await req.close().timeout(_timeout);
      final bytes = await resp
          .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
          .timeout(_timeout);
      final body = utf8.decode(bytes, allowMalformed: true);
      if (resp.statusCode != 200) {
        throw HttpException('签到请求失败：HTTP ${resp.statusCode}（号池服务可能未启动）');
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('签到响应不是 JSON 对象');
      }
      return summarizeCheckin(decoded);
    } finally {
      client.close(force: true);
    }
  }
}
