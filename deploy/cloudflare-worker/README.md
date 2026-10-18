# ZeroApi × OpenCode Zen 出口代理（Cloudflare Worker）

Zen 免费层按**出口 IP** 做滥用检测：家宽固定 IP、单个机场/机房节点都容易被
打标封禁（403 abusive traffic）。Cloudflare Workers 的出口是海量 anycast IP
池，OpenCode 无法整体封锁——把 zen 流量改走本 Worker，上游看到的就是
Cloudflare 的 IP。

## 部署（一次性，约 2 分钟）

```bash
cd deploy/cloudflare-worker
npm install -g --allow-scripts=workerd,esbuild wrangler   # 已装可跳过
wrangler login        # 弹浏览器登录你的 Cloudflare 账号（免费计划即可）
wrangler deploy       # 输出 https://zeroapi-opencode-zen.<你的用户名>.workers.dev
```

## 接入 ZeroApi

部署成功后，在 ZeroApi「供应商」页编辑 **OpenCode Zen Free**，把 Base URL 从
`https://opencode.ai/inference/v1` 改为：

```
https://zeroapi-opencode-zen.<你的用户名>.workers.dev/inference/v1
```

保存即可。目录（/models）与补全（/chat/completions）都会经 Worker 转发到
opencode.ai，本机 IP 不再出现在上游视野里。

> 说明：Worker 只做透传+拟人加固（轮换 UA、剥离暴露身份的浏览器头、0–50ms
> 抖动、补齐 x-opencode-* 会话头），不缓存、不记录内容。若 workers.dev 域名
> 也被上游针对，可在 Cloudflare 后台绑定自有域名。
