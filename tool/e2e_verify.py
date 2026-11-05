"""真机端到端自检：从本机配置读网关地址与 key，打一次模型目录与一次
Anthropic 非流式调用，打印元数据与结果。

用法：python tool/e2e_verify.py [model]
（配置路径按平台取 %APPDATA% / ~/.config，不写死个人目录。）
"""
import json, os, sys, urllib.request


def config_path():
    if os.name == 'nt':
        base = os.environ.get('APPDATA') or '.'
    else:
        base = os.path.join(os.environ.get('HOME', '.'), '.config')
    return os.path.join(base, 'zeroapi', 'config.json')


cfg = json.load(open(config_path(), encoding='utf-8'))
key = cfg['gateway']['apiKey']
base = 'http://127.0.0.1:%d' % cfg['gateway']['port']
model = sys.argv[1] if len(sys.argv) > 1 else 'zen/big-pickle'

def req(path, data=None, headers=None):
    h = {'Authorization': 'Bearer ' + key}
    if headers: h.update(headers)
    body = json.dumps(data).encode() if data is not None else None
    if body: h['Content-Type'] = 'application/json'
    r = urllib.request.Request(base + path, data=body, headers=h,
                               method='POST' if data else 'GET')
    with urllib.request.urlopen(r, timeout=180) as resp:
        return resp.status, json.loads(resp.read().decode('utf-8'))

st, models = req('/v1/models')
z = [m for m in models['data'] if m['id'] == model][0].get('zeroapi', {})
print('metadata now:', {k: z.get(k) for k in ('context_window', 'max_output_tokens', 'input_modalities', 'reasoning', 'free')})

# anthropic 非流式（x-api-key 头）
try:
    st, j = req('/v1/messages',
        {'model': model, 'max_tokens': 64,
         'messages': [{'role': 'user', 'content': 'reply with just the word OK'}]},
        headers={'x-api-key': key, 'anthropic-version': '2023-06-01', 'Authorization': ''})
    print('anthropic:', st, '| type=', j.get('type'), '| stop=', j.get('stop_reason'),
          '| text=', (j.get('content') or [{}])[0].get('text', '')[:30], '| usage=', j.get('usage'))
except Exception as e:
    print('anthropic ERR:', e)
