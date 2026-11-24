"""ビルドで書き出された訳す文の一覧 (.stringsdata) を集め、訳の抜けを調べる。

使い方: python3 scripts/collect_loc_keys.py <DerivedData のフォルダ> <出力フォルダ>

出力:
  keys.json     表 (Localizable など) ごとの、訳す文 (キー) の一覧
  missing.json  言語ごとの、訳がない文の一覧 (<言語>.lproj/<表>.strings にないもの)
  unused.json   言語ごとの、コードにない訳 (文を変えて使われなくなった訳)
"""
import glob
import json
import os
import plistlib
import re
import sys

STRINGS_RE = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.S)


def unescape(s):
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), s)


def load_strings(path):
    text = open(path, encoding='utf-8').read()
    return {unescape(k): unescape(v) for k, v in STRINGS_RE.findall(text)}


def load_stringsdata(path):
    raw = open(path, 'rb').read()
    try:
        return json.loads(raw)
    except ValueError:
        return plistlib.loads(raw)


def main():
    build, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    tables = {}
    files = glob.glob(os.path.join(build, '**', '*.stringsdata'), recursive=True)
    for path in files:
        data = load_stringsdata(path)
        for table, entries in (data.get('tables') or {}).items():
            for entry in entries:
                key = entry.get('key') if isinstance(entry, dict) else entry
                if key is not None:
                    tables.setdefault(table, set()).add(key)
    if files:
        # 形式を確かめられるよう、1 つだけそのまま残す
        with open(os.path.join(out, 'sample.stringsdata'), 'wb') as f:
            f.write(open(files[0], 'rb').read())
    keys = {t: sorted(k) for t, k in tables.items()}
    json.dump(keys, open(os.path.join(out, 'keys.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)

    missing, unused = {}, {}
    for lproj in sorted(glob.glob(os.path.join('SnoreAlarm', '*.lproj'))):
        lang = os.path.basename(lproj)[:-len('.lproj')]
        if lang == 'ja':
            continue
        for table, table_keys in keys.items():
            path = os.path.join(lproj, table + '.strings')
            have = load_strings(path) if os.path.exists(path) else {}
            lost = [k for k in table_keys if k not in have]
            if lost:
                missing.setdefault(lang, {})[table] = lost
            extra = [k for k in have if k not in tables[table]]
            if extra:
                unused.setdefault(lang, {})[table] = extra
    json.dump(missing, open(os.path.join(out, 'missing.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    json.dump(unused, open(os.path.join(out, 'unused.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print('stringsdata files:', len(files))
    print('keys:', {t: len(k) for t, k in keys.items()})
    print('missing:', {l: {t: len(k) for t, k in m.items()} for l, m in missing.items()})
    print('unused:', {l: {t: len(k) for t, k in m.items()} for l, m in unused.items()})


main()
