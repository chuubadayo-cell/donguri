#!/usr/bin/env python3
"""Syntax-checks the JavaScript embedded in Swift string literals.

Every `static let name = \"\"\" ... \"\"\"` script must use only escapes Swift
knows (\\n, \\t, \\\\, \\"…; `\\d` or `\\/` fail the build), and is read with Swift's
escapes applied (so `\\n` in the Swift source is a real line break, which
inside a JS string is a syntax error) and run through `node --check` (or, without node, macOS's own
JavaScriptCore via `osascript`, which only defines the function),
wrapped in an async function so callAsyncJavaScript bodies pass too.
Interpolated literals are skipped.

    python3 tools/check-page-scripts.py
"""
import os, re, shutil, subprocess, sys, tempfile

# The wrapper only defines the function, so evaluating it is a syntax check.
CHECK = ['node', '--check'] if shutil.which('node') else ['osascript', '-l', 'JavaScript']

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
            # Swift only knows \n \t \r \0 \\ \" \' \u{…}; anything else (\d, \/, \s…)
            # fails the build with "invalid escape sequence".
            bad = [m for m in re.finditer(r'\\(.)', body) if m.group(1) not in 'nrt0\\"\'u']
            if bad:
                failed += 1
                line = body.count('\n', 0, bad[0].start()) + 1
                print('FAIL', os.path.relpath(path, root), script, f'invalid Swift escape \\{bad[0].group(1)} on line {line} of the script')
                continue
            body = re.sub(r'\\(.)', lambda m: ESCAPES.get(m.group(1), '\\' + m.group(1)), body)
            with tempfile.NamedTemporaryFile('w', suffix='.js', delete=False) as f:
                f.write('(async function () {\n' + body + '\n});\n')
            result = subprocess.run(CHECK + [f.name], capture_output=True, text=True)
            os.unlink(f.name)
            label = f'{os.path.relpath(path, root)} {script}'
            if result.returncode:
                failed += 1
                print('FAIL', label)
                print('\n'.join(result.stderr.splitlines()[:6]))
            else:
                print('ok  ', label)
sys.exit(1 if failed else 0)
