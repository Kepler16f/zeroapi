/**
 * ZeroApi — OpenCode Zen 出口代理（Cloudflare Worker）
 * ---------------------------------------------------------------
 * 学自 jcleng / EkoSaputro14 / Maicon501a 等同类项目的关键经验：
 * OpenCode Zen 免费层会按「出口 IP」做滥用检测（403 abusive traffic）。
 * 家庭宽带 / 单个机场节点是固定 IP，很容易被打标封掉；而 Cloudflare
 * Workers 的出口是海量 anycast IP 池，OpenCode 无法整体封锁——把流量
 * 从 Worker 走一遍，上游看到的就是 Cloudflare 的 IP，绕开本机 IP 封锁。
 *
 * 用法（ZeroApi 侧）：把内置供应商「OpenCode Zen Free」的 Base URL 改成
 *   https://<你的项目>.workers.dev/inference/v1
 * 目录（/models）与补全（/chat/completions）都会经本 Worker 转发到
 *   https://opencode.ai/inference/v1/...
 *
 * 本 Worker 是「透传 + 指纹加固」：
 *   - 完整转发 ZeroApi 注入的 x-opencode-* / authorization 等指纹头
 *   - 轮换 User-Agent（多个 opencode CLI 版本）增加客户端多样性
 *   - 剥离会暴露真实客户端的 Sec-CH-UA / 各家 *identity 头
 *   - 0–50ms 抖动打散 burst 特征
 *   - 流式 SSE 原样透传（不缓冲）
 */

const TARGET_HOST = 'opencode.ai';

// opencode CLI 版本轮换（格式必须是 opencode/latest/<ver>/cli，否则 403）
const UAS = [
  'opencode/latest/2.0.22/cli',
  'opencode/latest/1.18.34/cli',
  'opencode/latest/1.18.30/cli',
  'opencode/latest/1.18.29/cli',
  'opencode/latest/1.18.18/cli',
];

// 绝不能透传给上游：会暴露真实 client / 工具链身份，触发拒绝
const BLOCK = new Set([
  'user-agent', 'sec-ch-ua', 'sec-ch-ua-mobile', 'sec-ch-ua-platform',
  'x-deepseek-identity', 'x-dsh-identity', 'x-app-identity', 'x-harness-identity',
  'host', 'connection', 'content-length', 'keep-alive', 'upgrade', 'transfer-encoding',
]);

// 允许透传的请求头（含 Zen 免费门必需的 x-opencode-*）
const ALLOW = new Set([
  'content-type', 'accept', 'accept-language', 'accept-encoding',
  'authorization', 'x-api-key', 'anthropic-version',
  'x-opencode-client', 'x-opencode-project', 'x-opencode-session',
  'x-opencode-session-id', 'x-opencode-request',
]);

const pick = (a) => a[(Math.random() * a.length) | 0];

export default {
  async fetch(request) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: cors() });
    }

    // 健康检查
    const inUrl = new URL(request.url);
    if (request.method === 'GET' && (inUrl.pathname === '/' || inUrl.pathname === '/health')) {
      return new Response(JSON.stringify({ ok: true, proxy: 'zeroapi-opencode-zen', target: TARGET_HOST }), {
        headers: { ...cors(), 'content-type': 'application/json' },
      });
    }

    await new Promise((r) => setTimeout(r, (Math.random() * 50) | 0)); // burst 抖动

    const target = new URL(request.url);
    target.hostname = TARGET_HOST;
    target.port = '';
    target.protocol = 'https:';

    const h = new Headers();
    for (const [k, v] of request.headers.entries()) {
      const lk = k.toLowerCase();
      if (BLOCK.has(lk) || !ALLOW.has(lk)) continue;
      h.set(k, v);
    }

    // 覆盖为轮换的 opencode CLI UA；补齐上游免费门必需的会话头（若客户端没带）
    const clientUA = request.headers.get('user-agent') || '';
    h.set('user-agent', clientUA.startsWith('opencode/') ? clientUA : pick(UAS));
    // SSE 透传要求上游不压缩：压缩体经 Cloudflare 自动解压后，
    // content-encoding 头若仍被拷贝给客户端会解码失败
    h.set('accept-encoding', 'identity');
    h.set('origin', `https://${TARGET_HOST}`);
    h.set('referer', `https://${TARGET_HOST}/`);
    if (!h.has('x-opencode-client')) h.set('x-opencode-client', 'cli');
    if (!h.has('x-opencode-project')) h.set('x-opencode-project', 'global');
    if (!h.has('x-opencode-session')) {
      const sid = sesId();
      h.set('x-opencode-session', sid);
      h.set('x-opencode-session-id', sid);
    } else if (!h.has('x-opencode-session-id')) {
      // 上游要求二者相等，缺失时镜像过来
      h.set('x-opencode-session-id', h.get('x-opencode-session'));
    }
    if (!h.has('x-opencode-request')) h.set('x-opencode-request', msgId());

    const upstream = await fetch(new Request(target.toString(), {
      method: request.method,
      headers: h,
      body: request.method === 'GET' || request.method === 'HEAD' ? null : request.body,
      redirect: 'follow',
    }));

    const rh = new Headers(upstream.headers);
    // body 已是解压后的明文：删除长度/编码声明，避免客户端按旧值解码
    rh.delete('content-encoding');
    rh.delete('content-length');
    for (const [k, v] of Object.entries(cors())) rh.set(k, v);
    rh.delete('cf-ray');
    rh.delete('cf-cache-status');
    rh.delete('server');
    // 原样透传流式 body（Worker 不缓冲 SSE）
    return new Response(upstream.body, { status: upstream.status, statusText: upstream.statusText, headers: rh });
  },
};

function cors() {
  return {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET,HEAD,POST,OPTIONS',
    'access-control-allow-headers': 'Content-Type, Authorization, X-Api-Key, Anthropic-Version, X-Requested-With',
    'access-control-max-age': '86400',
  };
}

// 与 opencode CLI 同款的降序/升序 id（上游只校验低 12 位 counter ≤ 63）
function encodedId(descending) {
  const cur = BigInt(Date.now()) * 4096n + BigInt((Math.random() * 64) | 0);
  const mask = (1n << 48n) - 1n;
  const v = descending ? ~cur & mask : cur & mask;
  return v.toString(16).padStart(12, '0').slice(-12) + randB62(14);
}
function sesId() { return 'ses_' + encodedId(true); }
function msgId() { return 'msg_' + encodedId(false); }

function randB62(n) {
  const a = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  let s = '';
  for (let i = 0; i < n; i++) s += a[(Math.random() * a.length) | 0];
  return s;
}
