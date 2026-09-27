#!/usr/bin/env python3
"""Читает сохранение Tabletop Simulator и пишет targets.mk (цели для make) и manifest.csv.

Каждая колода в TTS — это один-два листа-картинки (лицо/рубашка) с сеткой карт.
Скрипт обходит все объекты стола (в том числе вложенные в мешки), собирает уникальные
URL листов и раздаёт им понятные имена файлов:
    <группа>/<NNN>_<колода>[_plusK]_<face|back>_<id листа>.jpg
где группа — объект верхнего уровня (мешок «Древние», «Активы»…). Имена — транслитом
в ASCII: make на Windows передаёт кириллицу в shell в ANSI-кодировке, и папки на диске
выходят кракозябрами. Русские названия остаются в manifest.csv.

targets.mk: переменная IMAGES (все файлы) и на каждый файл — URL и список имён,
под которыми этот лист мог бы лежать в кэше TTS (Mods/Images): TTS называет кэш как
URL без спецсимволов + расширение по содержимому (.jpg/.png), по СЫРОМУ URL из
сохранения (обычно http://, иногда с хвостом {Unique}) — поэтому вариантов несколько.
manifest.csv: какая колода на каком листе, сетка и занятые ячейки.

Использование: python gen_targets.py <save.json> <out_dir>
"""
import csv
import json
import re
import sys
from collections import OrderedDict

json_path, out_dir = sys.argv[1], sys.argv[2]
save = json.load(open(json_path, encoding='utf-8'))

_TRANSLIT = dict(zip(
    'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
    ['a', 'b', 'v', 'g', 'd', 'e', 'yo', 'zh', 'z', 'i', 'y', 'k', 'l', 'm', 'n', 'o', 'p', 'r', 's', 't',
     'u', 'f', 'h', 'ts', 'ch', 'sh', 'sch', '', 'y', '', 'e', 'yu', 'ya'],
))


def translit(s):
    out = []
    for ch in s:
        low = ch.lower()
        if low in _TRANSLIT:
            t = _TRANSLIT[low]
            out.append(t.capitalize() if ch != low else t)
        else:
            out.append(ch)
    return ''.join(out)


def clean(s, n=60):
    # Кириллица — в латиницу; всё, что ломает имена файлов или синтаксис make
    # ($ # % & ; скобки кавычки), — в пробел; прочее не-ASCII — вон.
    s = translit(s or '')
    s = re.sub(r'[\\/:*?"<>|#$%&;()\[\]{}!\']', ' ', s)
    s = re.sub(r'[^\x20-\x7e]', '', s)
    s = re.sub(r'\s+', '_', s.strip())
    return s[:n]


def strip_url(u):
    """Нормализованный URL для скачивания: без {Unique}, imgur — по https."""
    u = re.sub(r'\{Unique\}$', '', u)
    return u.replace('http://i.imgur.com', 'https://i.imgur.com')


def sheet_id(u):
    m = re.search(r'imgur\.com/([A-Za-z0-9]+)', u) or re.search(r'[?&]id=([A-Za-z0-9_\-]+)', u)
    return m.group(1) if m else re.sub(r'[^A-Za-z0-9]', '', u)[-16:]


def cache_names(raw_url):
    """Возможные имена файла в кэше TTS для этого листа."""
    variants = {raw_url, re.sub(r'\{Unique\}$', '', raw_url)}
    variants |= {v.replace('https://', 'http://') for v in list(variants)}
    variants |= {v.replace('http://', 'https://') for v in list(variants)}
    out = []
    for v in sorted(variants):
        stem = re.sub(r'[^A-Za-z0-9]', '', v)
        for ext in ('.jpg', '.png'):
            if stem + ext not in out:
                out.append(stem + ext)
    return out


rows = []


def walk(obj, path):
    nick = clean(obj.get('Nickname'))
    label = nick or f"[{obj['Name']}]"
    p = path + [label]
    slots = {}
    if obj['Name'] in ('Deck', 'DeckCustom'):
        for cid in obj.get('DeckIDs', []):
            slots.setdefault(str(cid // 100), []).append(cid % 100)
    elif obj['Name'] == 'Card' and 'CardID' in obj:
        slots[str(obj['CardID'] // 100)] = [obj['CardID'] % 100]
    if obj.get('CustomDeck') and obj['Name'] in ('Deck', 'DeckCustom', 'Card'):
        for key, cd in obj['CustomDeck'].items():
            face_raw = cd.get('FaceURL', '') or ''
            back_raw = cd.get('BackURL', '') or ''
            rows.append(dict(
                path=' / '.join(p), deck=label, group=path[0] if path else 'table',
                deck_ru=(obj.get('Nickname') or '').strip() or label,
                cards=len(obj.get('DeckIDs', [])) or 1,
                grid=f"{cd.get('NumWidth')}x{cd.get('NumHeight')}",
                slots=' '.join(map(str, sorted(set(slots.get(key, []))))),
                face=strip_url(face_raw), face_raw=face_raw,
                back=strip_url(back_raw) if back_raw else '', back_raw=back_raw,
                unique=bool(cd.get('UniqueBack')),
            ))
    if obj['Name'] not in ('Deck', 'DeckCustom'):
        for c in obj.get('ContainedObjects', []) or []:
            walk(c, p)


for o in save['ObjectStates']:
    walk(o, [])

images = OrderedDict()
for r in rows:
    for side in ('face', 'back'):
        u = r[side]
        if not u:
            continue
        img = images.setdefault(u, dict(url=u, raw=r[side + '_raw'], side=side, decks=[], group=r['group']))
        if r['deck'] not in img['decks']:
            img['decks'].append(r['deck'])

for n, img in enumerate(images.values(), 1):
    named = [d for d in img['decks'] if not d.startswith('[')] or img['decks']
    tag = named[0] + (f"_plus{len(named) - 1}" if len(named) > 1 else '')
    img['file'] = f"{clean(img['group'])}/{n:03d}_{clean(tag)}_{img['side']}_{sheet_id(img['url'])}.jpg"

with open('targets.mk', 'w', encoding='utf-8', newline='\n') as f:
    f.write('IMAGES := \\\n' + ''.join(f"  $(OUT)/{i['file']} \\\n" for i in images.values()) + '\n')
    for i in images.values():
        f.write(f"$(OUT)/{i['file']}: URL := {i['url']}\n")
        f.write(f"$(OUT)/{i['file']}: CACHE_NAMES := {' '.join(cache_names(i['raw']))}\n")

with open('manifest.csv', 'w', encoding='utf-8-sig', newline='') as f:
    w = csv.writer(f, delimiter=';')
    w.writerow(['Путь', 'Колода', 'Карт', 'Сетка', 'Ячейки листа', 'Файл лицо', 'Файл рубашка',
                'Уникальные рубашки', 'FaceURL', 'BackURL'])
    for r in rows:
        w.writerow([r['path'], r['deck_ru'], r['cards'], r['grid'], r['slots'],
                    images[r['face']]['file'], images[r['back']]['file'] if r['back'] else '',
                    r['unique'], r['face'], r['back']])

print(f"decks x sheets: {len(rows)}, unique images: {len(images)}", file=sys.stderr)
