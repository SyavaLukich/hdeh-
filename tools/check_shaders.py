#!/usr/bin/env python3
"""Достаёт GLSL из паскалевских модулей и прогоняет через glslangValidator.

Валидатор ставится так:
    npm i glslang-validator-prebuilt-predownloaded
Путь можно задать переменной GLSLANG.
"""
import io, os, re, subprocess, sys, glob, tempfile

SOURCES = ['src/urender.pas', 'src/ufox.pas']

def extract(path):
    s = io.open(path, encoding='utf-8').read()
    out = {}
    for m in re.finditer(r"^\s*(VS_[A-Z0-9_]+|FS_[A-Z0-9_]+)\s*=\s*", s, re.M):
        name = m.group(1)
        # собираем выражение до строки, оканчивающейся на ';'
        i = m.end()
        expr, depth = [], 0
        while i < len(s):
            j = s.find('\n', i)
            if j < 0: j = len(s)
            line = s[i:j]
            expr.append(line)
            if line.rstrip().endswith(';') and not line.rstrip().endswith('+ #10 +'):
                break
            i = j + 1
        expr = '\n'.join(expr)
        text = ''
        for tok in re.finditer(r"'((?:[^']|'')*)'|#10", expr):
            if tok.group(0) == '#10':
                text += '\n'
            else:
                text += tok.group(1).replace("''", "'")
        if text.strip().startswith('#version'):
            out[name] = text
    return out

def main():
    val = os.environ.get('GLSLANG')
    if not val:
        for c in glob.glob('**/glslangValidator.linux', recursive=True) + \
                 glob.glob(os.path.expanduser('~/tools/glsl/**/glslangValidator.linux'), recursive=True):
            val = c
            break
    shaders = {}
    for src in SOURCES:
        if os.path.exists(src):
            shaders.update(extract(src))
    print(f'найдено шейдеров: {len(shaders)}')
    if not val:
        print('glslangValidator не найден -- проверка пропущена')
        print('  npm i glslang-validator-prebuilt-predownloaded')
        return 0
    bad = 0
    tmp = tempfile.mkdtemp()
    for name, text in sorted(shaders.items()):
        ext = 'vert' if name.startswith('VS') else 'frag'
        p = os.path.join(tmp, f'{name.lower()}.{ext}')
        io.open(p, 'w', encoding='utf-8').write(text)
        r = subprocess.run([val, p], capture_output=True, text=True)
        if r.returncode != 0:
            bad += 1
            print(f'  ОШИБКА {name}:')
            print('   ', r.stdout.strip().replace('\n', '\n    '))
        else:
            print(f'  ok   {name} ({len(text)} байт)')
    print(f'итого: {len(shaders) - bad} в порядке, {bad} с ошибками')
    return 1 if bad else 0

sys.exit(main())
