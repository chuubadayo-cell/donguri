#!/usr/bin/env python3
"""Syntax-checks the JavaScript embedded in Swift string literals.

Every `static let name = \"\"\" ... \"\"\"` script is read with Swift's
escapes applied (so `\\n` in the Swift source is a real line break, which
inside a JS string is a syntax error) and run through `node --check`,
wrapped in an async function so callAsyncJavaScript bodies pass too.
Interpolated literals are skipped.

    python3 tools/check-page-scripts.py
"""
import os, re, subprocess, sys, tempfile

ESCAPES = {'n': '\n', 't': '\t', '\\': '\\', '"': '"', "'": "'", '0': '\0', 'r': '\r'}
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Donguri')
failed = 0
for folder, _, files in os.walk(root):
    for name in files:
        if not name.endswith('.swift'):
            continue
        path = os.path.join(folder, name)
        source = open(path, encoding='utf-8').read()
        for match in re.finditer(r'static (?:let|var) (\w+)(?:: String)? = """\n(.*?)\n\s*"""', source, re.S):
            script, body = match.group(1), match.group(2)
            if '\\(' in body:
                continue
            body = re.sub(r'\\(.)', lambda m: ESCAPES.get(m.group(1), '\\' + m.group(1)), body)
            with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False) as f:
                f.write('(async function () {\n' + body + '\n});\n')
            result = subprocess.run(['node', '--check', f.name], capture_output=True, text=True)
            os.unlink(f.name)
            label = f'{os.path.relpath(path, root)} {script}'
            if result.returncode:
                failed += 1
                print('FAIL', label)
                print('\n'.join(result.stderr.splitlines()[:6]))
            else:
                print('ok  ', label)
sys.exit(1 if failed else 0)
