#!/usr/bin/env python3
"""Читает сохранение Tabletop Simulator и пишет targets.mk (цели для make) и манифесты.

Что забираем:
  • листы колод — CustomDeck у Deck/DeckCustom/Card: один-два листа (лицо/рубашка) с
    сеткой карт. На листе лежит ВСЯ колода, сколько бы карт ни было в стопке на момент
    сохранения (в TTS часть карт раздана/сброшена — стопка меньше листа, лист полный);
  • плоские «модели» — Custom_Model с текстурой (DiffuseURL): планшеты сыщиков и
    Древних, жетоны навыков/билетов. Геометрию (MeshURL) не качаем — это .obj;
  • тайлы/жетоны/доска — Custom_Tile, Custom_Token, Custom_Board (ImageURL и, если есть,
    ImageSecondaryURL — оборот): врата, улики, жетоны слухов, карта мира.

Имена файлов:
    <группа>/<NNN>_<название>[_plusK]_<face|back|model|tile|token|board>_<id>.<ext>
где группа — объект верхнего уровня (мешок «Древние», «Карточки сыщиков»…). Всё
транслитом в ASCII: make на Windows передаёт кириллицу в shell в ANSI-кодировке, и
папки на диске выходят кракозябрами. Русские названия остаются в манифестах.

targets.mk: переменная IMAGES и на каждый файл — URL и список имён, под которыми этот
файл мог бы лежать в кэше TTS (Mods/Images): TTS называет кэш как URL без спецсимволов
+ расширение по содержимому (.jpg/.png), по СЫРОМУ URL из сохранения (обычно http://,
иногда с хвостом {Unique}) — поэтому вариантов несколько.
manifest.csv — колоды: колода → лист, сетка, занятые ячейки.
manifest_sheets.csv — модели/тайлы/жетоны: объект → файл.

Использование: python gen_targets.py <save.json> <out_dir>
"""
import csv
import json
import re
import sys
from collections import OrderedDict

json_path, out_dir = sys.argv[1], sys.argv[2]
save = json.load(open(json_path, encoding='utf-8'))

# Хосты, откуда качать бессмысленно: обои для декоративных коробок и подобное.
SKIP_HOSTS = ('w-dog.ru',)

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
    """Нормализованный URL для скачивания: без {Unique}, imgur — по https; старый хост
    Steam Cloud (cloud-3.steamusercontent.com) отдаёт 403 — TTS сам ходит на зеркало
    steamusercontent-a.akamaihd.net, идём туда же."""
    u = re.sub(r'\{Unique\}$', '', u or '')
    u = u.replace('http://i.imgur.com', 'https://i.imgur.com')
    return re.sub(r'^https?://cloud-3\.steamusercontent\.com/', 'https://steamusercontent-a.akamaihd.net/', u)


def sheet_id(u):
    m = (re.search(r'imgur\.com/([A-Za-z0-9]+)', u) or re.search(r'[?&]id=([A-Za-z0-9_\-]+)', u)
         or re.search(r'/ugc/(\d+)/', u) or re.search(r'dropbox\.com/s/([A-Za-z0-9]+)/', u))
    return m.group(1)[-24:] if m else re.sub(r'[^A-Za-z0-9]', '', u)[-16:]


def ext_of(u, default='.jpg'):
    m = re.search(r'\.(png|jpe?g)(?:[?#]|$)', u, re.I)
    return '.' + m.group(1).lower().replace('jpeg', 'jpg') if m else default


def cache_names(raw_url):
    """Возможные имена файла в кэше TTS для этой картинки."""
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


def skip(u):
    return not u or any(h in u for h in SKIP_HOSTS)


rows = []      # колоды: deck × лист
extras = []    # модели/тайлы/жетоны/доска


def walk(obj, path):
    nick_raw = (obj.get('Nickname') or '').strip()
    nick = clean(nick_raw)
    label = nick or f"[{obj['Name']}]"
    p = path + [label]
    group = path[0] if path else 'table'
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
                path=' / '.join(p), deck=label, deck_ru=nick_raw or label, group=group,
                cards=len(obj.get('DeckIDs', [])) or 1,
                grid=f"{cd.get('NumWidth')}x{cd.get('NumHeight')}",
                cells=int(cd.get('NumWidth') or 0) * int(cd.get('NumHeight') or 0),
                slots=' '.join(map(str, sorted(set(slots.get(key, []))))),
                face=strip_url(face_raw), face_raw=face_raw,
                back=strip_url(back_raw) if back_raw else '', back_raw=back_raw,
                unique=bool(cd.get('UniqueBack')),
            ))
    if obj['Name'] == 'Custom_Model':
        u = (obj.get('CustomMesh') or {}).get('DiffuseURL', '')
        if not skip(u):
            extras.append(dict(path=' / '.join(p), name=label, name_ru=nick_raw or label, group=group,
                               kind='model', url=strip_url(u), raw=u))
    if obj['Name'] in ('Custom_Tile', 'Custom_Token', 'Custom_Board'):
        ci = obj.get('CustomImage') or {}
        kind = obj['Name'].split('_')[1].lower()
        for key in ('ImageURL', 'ImageSecondaryURL'):
            u = ci.get(key, '')
            if not skip(u):
                extras.append(dict(path=' / '.join(p), name=label, name_ru=nick_raw or label, group=group,
                                   kind=kind if key == 'ImageURL' else kind + '_back', url=strip_url(u), raw=u))
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
        img = images.setdefault(u, dict(url=u, raw=r[side + '_raw'], kind=side, names=[], group=r['group']))
        if r['deck'] not in img['names']:
            img['names'].append(r['deck'])
for e in extras:
    img = images.setdefault(e['url'], dict(url=e['url'], raw=e['raw'], kind=e['kind'], names=[], group=e['group']))
    if e['name'] not in img['names']:
        img['names'].append(e['name'])

for n, img in enumerate(images.values(), 1):
    named = [d for d in img['names'] if not d.startswith('[')] or img['names']
    tag = named[0] + (f"_plus{len(named) - 1}" if len(named) > 1 else '')
    ext = '.jpg' if img['kind'] in ('face', 'back') else ext_of(img['url'])
    img['file'] = f"{clean(img['group'])}/{n:03d}_{clean(tag)}_{img['kind']}_{sheet_id(img['url'])}{ext}"

with open('targets.mk', 'w', encoding='utf-8', newline='\n') as f:
    f.write('IMAGES := \\\n' + ''.join(f"  $(OUT)/{i['file']} \\\n" for i in images.values()) + '\n')
    for i in images.values():
        f.write(f"$(OUT)/{i['file']}: URL := {i['url']}\n")
        f.write(f"$(OUT)/{i['file']}: CACHE_NAMES := {' '.join(cache_names(i['raw']))}\n")

with open('manifest.csv', 'w', encoding='utf-8-sig', newline='') as f:
    w = csv.writer(f, delimiter=';')
    w.writerow(['Путь', 'Колода', 'Карт в стопке (на момент сохранения)', 'Сетка листа', 'Ячеек на листе',
                'Занятые ячейки', 'Файл лицо', 'Файл рубашка', 'Уникальные рубашки', 'FaceURL', 'BackURL'])
    for r in rows:
        w.writerow([r['path'], r['deck_ru'], r['cards'], r['grid'], r['cells'], r['slots'],
                    images[r['face']]['file'], images[r['back']]['file'] if r['back'] else '',
                    r['unique'], r['face'], r['back']])

with open('manifest_sheets.csv', 'w', encoding='utf-8-sig', newline='') as f:
    w = csv.writer(f, delimiter=';')
    w.writerow(['Путь', 'Объект', 'Тип', 'Файл', 'URL'])
    for e in extras:
        w.writerow([e['path'], e['name_ru'], e['kind'], images[e['url']]['file'], e['url']])

decks_n = sum(1 for i in images.values() if i['kind'] in ('face', 'back'))
print(f"decks x sheets: {len(rows)}, deck sheets: {decks_n}, models/tiles/tokens: {len(images) - decks_n}, "
      f"total unique images: {len(images)}", file=sys.stderr)
