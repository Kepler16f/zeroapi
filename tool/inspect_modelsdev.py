import json

d = json.load(open('/tmp/modelsdev.json'))
prov = d.get('providers', {})
print('provider count:', len(prov))
ks = [k for k in prov if 'opencode' in k.lower() or 'zen' in k.lower()]
print('matching keys:', ks[:10])
op = prov.get('opencode')
if op:
    ms = op.get('models', {})
    print('model count:', len(ms))
    print('sample ids:', list(ms)[:8])
    for name in ('big-pickle', 'beam-free', 'glm-5.3-flash-free'):
        m = ms.get(name)
        if not m:
            print(name, 'ABSENT')
            continue
        print(name, json.dumps({
            'limit': m.get('limit'),
            'modalities': m.get('modalities'),
            'supports': {k: v for k, v in (m.get('supports') or {}).items()},
            'release_date': m.get('release_date'),
        }, ensure_ascii=False)[:300])
