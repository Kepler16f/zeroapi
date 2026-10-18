import json, shutil
p = 'C:/Users/胡天泽/AppData/Roaming/zeroapi/config.json'
shutil.copy(p, p + '.bak-label')
d = json.load(open(p, encoding='utf-8'))
for u in d['upstreams']:
    if u.get('id') == 'zen':
        print('before:', u.get('label'))
        u['label'] = 'OpenCode Zen Free'
json.dump(d, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print('after: OpenCode Zen Free')
