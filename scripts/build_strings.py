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
    'de': {
        'CFBundleDisplayName': 'Schnarchalarm',
        'NSMicrophoneUsageDescription': 'Das Mikrofon erkennt Schnarchen im Schlaf. Nur die wenigen als Schnarchen erkannten Sekunden werden auf dem Gerät aufgenommen (in den Einstellungen abschaltbar) und nach 1 Woche automatisch gelöscht. Nichts verlässt das Gerät.',
        'NSAlarmKitUsageDescription': 'Damit zur Schlafenszeit ein Wecker wie in der Uhr-App klingelt, wenn die Überwachung noch nicht läuft.',
    },
    'fr': {
        'CFBundleDisplayName': 'Alarme Ronflement',
        'NSMicrophoneUsageDescription': 'Le micro sert à détecter les ronflements pendant votre sommeil. Seules les quelques secondes jugées comme ronflement sont enregistrées sur l’appareil (désactivable dans Réglages) et supprimées automatiquement après 1 semaine. Rien ne quitte l’appareil.',
        'NSAlarmKitUsageDescription': 'Pour faire sonner une alarme comme celle de l’app Horloge à l’heure du coucher si la surveillance n’a pas démarré.',
    },
    'es': {
        'CFBundleDisplayName': 'Alarma Ronquidos',
        'NSMicrophoneUsageDescription': 'El micrófono se usa para detectar ronquidos mientras duermes. Solo se graban en el dispositivo los pocos segundos considerados ronquido (puedes desactivarlo en Ajustes), y se eliminan automáticamente al cabo de 1 semana. Nada sale del dispositivo.',
        'NSAlarmKitUsageDescription': 'Para hacer sonar una alarma como la de la app Reloj a la hora de dormir si la vigilancia no ha empezado.',
    },
    'pt-BR': {
        'CFBundleDisplayName': 'Alarme de Ronco',
        'NSMicrophoneUsageDescription': 'O microfone é usado para detectar o ronco enquanto você dorme. Só os poucos segundos considerados ronco são gravados no aparelho (dá para desativar em Ajustes) e apagados automaticamente após 1 semana. Nada sai do aparelho.',
        'NSAlarmKitUsageDescription': 'Para tocar um alarme igual ao do app Relógio na hora de dormir se o monitoramento não tiver começado.',
    },
    'ko': {
        'CFBundleDisplayName': '코골이 알람',
        'NSMicrophoneUsageDescription': '자는 동안 코골이를 감지하는 데 마이크를 사용합니다. 코골이로 판정한 몇 초만 기기 안에 녹음하며(설정에서 끌 수 있습니다), 1주일 뒤 자동으로 삭제합니다. 기기 밖으로는 보내지 않습니다.',
        'NSAlarmKitUsageDescription': '취침 시간에 아직 모니터링을 시작하지 않았을 때 시계 앱의 알람과 같은 알람을 울리는 데 사용합니다.',
    },
    'zh-Hans': {
        'CFBundleDisplayName': '打鼾提醒',
        'NSMicrophoneUsageDescription': '麦克风用于在睡眠时检测打鼾。仅将判定为打鼾的几秒钟录在设备内（可在设置中关闭），并在 1 周后自动删除。不会发送到设备外。',
        'NSAlarmKitUsageDescription': '用于在睡觉时间尚未开始监测时，响起与时钟 App 相同的闹钟。',
    },
    'zh-Hant': {
        'CFBundleDisplayName': '打鼾提醒',
        'NSMicrophoneUsageDescription': '麥克風用於在睡眠時偵測打鼾。僅將判定為打鼾的幾秒鐘錄在裝置內（可在設定中關閉），並在 1 週後自動刪除。不會傳送到裝置外。',
        'NSAlarmKitUsageDescription': '用於在睡覺時間尚未開始監測時，響起與時鐘 App 相同的鬧鐘。',
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
