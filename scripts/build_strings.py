"""訳の表 (scripts/translations/<言語>.json) から <言語>.lproj の .strings を作る。

使い方: python scripts/build_strings.py <keys.json> <言語> [<言語> ...]

keys.json は CI の loc-report (collect_loc_keys.py) が書き出した、コードの中の訳す文 (キー) の一覧。
訳の表は、キーの書式指定 (%@、%lld など) を {1}, {2} ... に置き換えた日本語の文で引く。
訳の中の {1}, {2} ... は、キーの n 番目の書式指定に番号付きで戻す (英語で語順が変わっても値を取り違えない)。
訳がない文は、そのまま日本語で出るため、一覧にして知らせる。
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = re.compile(r'%(?:(\d+)\$)?([-+ 0#]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j|L)?[@dDuUxXoOfeEgGcCsSpaA])|\$\{applicationName\}')

# Info.plist の訳 (InfoPlist.strings)
INFO_PLIST = {
    'en': {
        'CFBundleDisplayName': 'Snore Alarm',
        'NSMicrophoneUsageDescription': 'The microphone is used to detect snoring while you sleep. Only the few seconds judged to be snoring are recorded on the device (you can turn this off in Settings) and deleted automatically after 1 week. Nothing is sent off the device.',
        'NSAlarmKitUsageDescription': 'Used to ring an alarm like the Clock app’s when it’s bedtime and monitoring hasn’t started.',
    },
}


def normalize(key):
    """キーの書式指定を {1}, {2} ... にし、書式指定の並びも返す"""
    specs = []

    def repl(m):
        if m.group(0) == '${applicationName}':
            specs.append(m.group(0))
        else:
            specs.append(m.group(2))
        return '{%d}' % len(specs)

    return SPEC.sub(repl, key.replace('%%', '\0')).replace('\0', '%'), specs


def denormalize(text, specs):
    def repl(m):
        n = int(m.group(1))
        spec = specs[n - 1]
        return spec if spec == '${applicationName}' else '%%%d$%s' % (n, spec)

    return re.sub(r'\{(\d+)\}', repl, text.replace('%', '%%'))


def escape(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')


def main():
    keys = json.load(open(sys.argv[1], encoding='utf-8'))
    for lang in sys.argv[2:]:
        table = json.load(open(os.path.join(ROOT, 'scripts', 'translations', lang + '.json'), encoding='utf-8'))
        lproj = os.path.join(ROOT, 'SnoreAlarm', lang + '.lproj')
        os.makedirs(lproj, exist_ok=True)
        missing = []
        for name, table_keys in sorted(keys.items()):
            lines = ['/* %s の %s の訳。scripts/build_strings.py で作る (手で直さず scripts/translations/%s.json を直す) */' % (lang, name, lang), '']
            for key in table_keys:
                norm, specs = normalize(key)
                if norm not in table:
                    missing.append((name, key))
                    continue
                if len(re.findall(r'\{\d+\}', table[norm])) and max(int(n) for n in re.findall(r'\{(\d+)\}', table[norm])) > len(specs):
                    raise SystemExit('placeholder mismatch: %r -> %r' % (key, table[norm]))
                lines.append('"%s" = "%s";' % (escape(key), escape(denormalize(table[norm], specs))))
            with open(os.path.join(lproj, name + '.strings'), 'w', encoding='utf-8', newline='\n') as f:
                f.write('\n'.join(lines) + '\n')
        if lang in INFO_PLIST:
            with open(os.path.join(lproj, 'InfoPlist.strings'), 'w', encoding='utf-8', newline='\n') as f:
                f.write('/* %s の Info.plist の訳。scripts/build_strings.py で作る */\n\n' % lang)
                for k, v in INFO_PLIST[lang].items():
                    f.write('"%s" = "%s";\n' % (k, escape(v)))
        print(lang, 'missing:', len(missing))
        for name, key in missing:
            print('  [%s] %r' % (name, key))


main()
