import os, sys, unicodedata

chars = set()
for root, dirs, files in os.walk(os.path.join(os.path.dirname(__file__), '..', 'lib')):
    for f in files:
        if f.endswith('.dart'):
            with open(os.path.join(root, f), encoding='utf-8', errors='replace') as fh:
                chars.update(fh.read())

special = sorted(c for c in chars if ord(c) > 127 and not (0x4E00 <= ord(c) <= 0x9FFF))
out = []
for c in special:
    try:
        name = unicodedata.name(c)
    except ValueError:
        name = '?'
    out.append('U+%04X %s %s' % (ord(c), c, name))
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'special_chars.txt'), 'w', encoding='utf-8') as fh:
    fh.write('\n'.join(out))
print(len(special), 'distinct non-CJK non-ASCII chars')
