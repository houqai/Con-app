#!/usr/bin/env python3
import io, json, re, sys, os
here = os.path.dirname(os.path.abspath(__file__))
core = os.path.join(here, '..', '..', 'Sources', 'SoleCore')
out = os.path.join(core, 'Translations') + os.sep
names = {'ru': ('russian', 'Russian'), 'de': ('german', 'German'), 'fr': ('french', 'French'), 'es': ('spanish', 'Spanish'), 'it': ('italian', 'Italian'),
         'pt': ('portuguese', 'Portuguese (Brazil)'), 'pl': ('polish', 'Polish'), 'ja': ('japanese', 'Japanese'),
         'ko': ('korean', 'Korean'), 'zh': ('chinese', 'Chinese (Simplified)')}
pairs = json.load(io.open(here + '/texts.json', encoding='utf-8'))
failed = False
for code in sys.argv[1:]:
    lines = io.open('%s/tr-%s.txt' % (here, code), encoding='utf-8').read().split('\n')
    if lines and lines[-1] == '': lines.pop()
    problems = []
    if len(lines) != len(pairs): problems.append('%d lines, %d texts' % (len(lines), len(pairs)))
    values = []
    for i, line in enumerate(lines[:len(pairs)]):
        index, _, text = line.partition('|')
        english = pairs[i][1:-1]
        if index != str(i): problems.append('line %d is numbered %s' % (i, index)); continue
        if text.count('%@') != english.count('%@'): problems.append('%d: %d places for values, English has %d' % (i, text.count('%@'), english.count('%@')))
        if text.count('\\n') != english.count('\\n'): problems.append('%d: line breaks differ' % i)
        if re.search(r'(?<!\\)"', text) or re.search(r'\\(?!n)', text): problems.append('%d: a quote or a backslash' % i)
        if not text.strip(): problems.append('%d: empty' % i)
        if (english[:1] in ' ,.') != (text[:1] in ' ,.，。、'): problems.append('%d: begins differently from the English fragment' % i)
        if english.endswith(' ') != text.endswith(' '): problems.append('%d: ends differently' % i)
        values.append(text)
    if problems:
        failed = True
        print(code, 'NOT written:', len(problems), 'problems'); print('\n'.join('  ' + p for p in problems[:25])); continue
    property, title = names[code]
    body = ''.join('        %s: "%s",\n' % (pairs[i], values[i]) for i in range(len(pairs)))
    os.makedirs(out, exist_ok=True)
    io.open('%s%sTexts.swift' % (out, title.split(' ')[0]), 'w', encoding='utf-8').write(
        'extension Translations {\n    static let %s: [String: String] = [\n%s    ]\n}\n' % (property, body))
    print(code, 'written:', len(values), 'texts')
sys.exit(1 if failed else 0)
