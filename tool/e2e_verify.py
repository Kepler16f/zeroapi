import json, urllib.request

cfg = json.load(open('C:/Users/胡天泽/AppData/Roaming/zeroapi/config.json'))
key = cfg['gateway']['apiKey']
base = 'http://127.0.0.1:%d' % cfg['gateway']['port']

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
z = [m for m in models['data'] if m['id'] == 'zen/big-pickle'][0]['zeroapi']
print('metadata now:', {k: z.get(k) for k in ('context_window', 'max_output_tokens', 'input_modalities', 'reasoning', 'free')})

# anthropic 非流式（x-api-key 头）
try:
    st, j = req('/v1/messages',
        {'model': 'zen/big-pickle', 'max_tokens': 64,
         'messages': [{'role': 'user', 'content': 'reply with just the word OK'}]},
        headers={'x-api-key': key, 'anthropic-version': '2023-06-01', 'Authorization': ''})
    print('anthropic:', st, '| type=', j.get('type'), '| stop=', j.get('stop_reason'),
          '| text=', (j.get('content') or [{}])[0].get('text', '')[:30], '| usage=', j.get('usage'))
except Exception as e:
    print('anthropic ERR:', e)
