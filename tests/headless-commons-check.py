#!/usr/bin/env python3
"""Reject direct OEM links and exercise the shared headless fixture contract."""
import os
from pathlib import Path
import re
import subprocess
import sys


def direct_sources(root):
    bad = []
    sources = ('ui/boot/' + 'Commons', 'ui/' + 'Commons', '/usr/share/omarchy/shell/' + 'Commons')
    for path in sorted(root.glob('*.sh')):
        if path.name == 'headless-commons.sh':
            continue
        for n, line in enumerate(path.read_text().splitlines(), 1):
            # Sample input: ln -s "$(readlink -f ui/boot/Commons)" "$root/config/Commons" links the live OEM source.
            if not line.lstrip().startswith('#') and any(re.search(r'(?<![\w$])' + re.escape(source) + r'(?![\w/])', line) for source in sources):
                bad.append(f'{path}:{n}: use headless_commons instead of a direct OEM Commons source')
    return bad


def unchecked_calls(root):
    bad = []
    for path in sorted(root.glob('*.sh')):
        if path.name == 'headless-commons.sh':
            continue
        for n, line in enumerate(path.read_text().splitlines(), 1):
            # Sample input: headless_commons "$root" must carry an exit guard even when the suite uses set -e.
            if line.lstrip().startswith('#') or not re.search(r'\bheadless_commons\b', line):
                continue
            # Sample input: headless_commons "$root" || exit 1; thumbs also keeps its sandbox_remove cleanup before exit.
            if not re.fullmatch(r'\s*headless_commons\s+[^;&|]+\s+\|\|\s+(?:exit\s+1|\{\s*sandbox_remove\s+[^;&|{}]+;\s*exit\s+1;\s*\})\s*', line):
                bad.append(f'{path}:{n}: headless_commons refusal must abort the suite with || exit 1')
    return bad


def controls(box):
    fixture = box / 'headless-commons-controls'
    fixture.mkdir()
    scanner = fixture / 'tests'
    scanner.mkdir()
    direct = scanner / 'new-suite.sh'
    for source in ('ui/boot/' + 'Commons', 'ui/' + 'Commons', '/usr/share/omarchy/shell/' + 'Commons'):
        for line in (f'ln -s "$(readlink -f {source})" "$root/config/Commons"', f'commons={source}\nln -s "$commons" "$target"'):
            direct.write_text(line)
            assert len(direct_sources(scanner)) == 1 and 'new-suite.sh:1:' in direct_sources(scanner)[0]
    direct.write_text('# ui/boot/' + 'Commons is supplied by the helper\nheadless_commons "$root" || exit 1\ncp -a "$flea_ui/boot/Commons" "$target"\n')
    assert not direct_sources(scanner)
    assert not unchecked_calls(scanner)
    checker = Path('tests/headless-commons-check.py').resolve()
    for call in ('headless_commons "$root"', 'headless_commons "$root" || true',
                 'headless_commons "$root" | cat', '(headless_commons "$root" || exit 1)',
                 'copy=$(headless_commons "$root" || exit 1)', 'if headless_commons "$root"; then :; fi'):
        direct.write_text(call + '\nqs -p "$root/config"\n')
        assert len(unchecked_calls(scanner)) == 1 and 'new-suite.sh:1:' in unchecked_calls(scanner)[0], call
        result = subprocess.run([sys.executable, '-B', str(checker), str(box)], cwd=fixture, capture_output=True, text=True)
        assert result.returncode == 1 and 'refusal must abort the suite' in result.stderr, (call, result)
    calls = 0
    for path in sorted(Path('tests').glob('*.sh')):
        for line in path.read_text().splitlines():
            if line.lstrip().startswith('headless_commons '):
                result = subprocess.run(['bash', '-c', 'headless_commons() { return 1; }; sandbox_remove() { :; }; ' + line + '; printf "QS_REACHED\\n"'], capture_output=True, text=True)
                assert result.returncode == 1 and 'QS_REACHED' not in result.stdout, (path, line, result)
                calls += 1
    # Sample input: python3 - "$target/Style.qml" <<'PY' followed by Python lines and a bare PY closing delimiter.
    helper = Path('tests/headless-commons.sh').read_text().split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
    original = 'import Quickshell.Hyprland\nQtObject {\n  id: root\n  Connections {\n    target: Hyprland\n  }\n}\n'
    variants = {
        'whitespace': original.replace('import Quickshell.', 'import  Quickshell.').replace('    target:', '  target :'),
        'alias': original.replace('import Quickshell.Hyprland', 'import Quickshell.Hyprland as Compositor').replace('target: Hyprland', 'target: Compositor'),
        'qualified': original.replace('import Quickshell.Hyprland\n', 'import Quickshell\n').replace('target: Hyprland', 'target: Quickshell.Hyprland'),
        'extra-read': original.replace('  Connections {', '  property var extra: Hyprland\n  Connections {'),
    }
    comments = '// Hyprland rounding\n/* Hyprland config */\n'
    for name, before in {'current': comments + 'QtObject {\n  id: root\n}\n', 'dev': comments + original, **variants}.items():
        path = fixture / f'{name}.qml'
        path.write_text(before)
        result = subprocess.run(['python3', '-', str(path)], input=helper, text=True, capture_output=True)
        if name in variants:
            assert result.returncode == 1 and 'reader changed' in result.stderr and path.read_text() == before, (name, result)
        else:
            assert result.returncode == 0, (name, result)
            assert path.read_text() == before if name == 'current' else path.read_text().startswith(comments) and 'target: root.headlessEvents' in path.read_text()
    env = dict(os.environ, HOME=str(fixture / 'home'), FLEA_FIXTURE_ROOT=str(fixture / 'fixtures'))
    root = Path(env['FLEA_FIXTURE_ROOT']) / 'owned'
    root.mkdir(parents=True)
    (root / '.flea-test-sandbox').touch()
    source_root = fixture / 'source'
    commons = source_root / 'ui/boot/Commons'
    commons.mkdir(parents=True)
    (commons / 'Style.qml').write_text(original)
    repo = Path.cwd()
    shell = '. "$3/tools/flea-sandbox-guard"; . "$3/tests/headless-commons.sh"; headless_commons "$1" "$2" || exit 1; printf "QS_REACHED\\n"'
    targets = [(root, root / name) for name in ('config/Commons', 'config-KEYS/Commons', 'config/boot/Commons')]
    targets.append((root / 'work', root / 'work/pane/config/Commons'))
    for owner, target in targets:
        owner.mkdir(exist_ok=True)
        result = subprocess.run(['bash', '-c', shell, 'control', str(owner), str(target), str(repo)], cwd=source_root, env=env, capture_output=True, text=True)
        assert result.returncode == 0 and (target / 'Style.qml').is_file() and not (target / 'Style.qml').is_symlink(), result
    sibling = Path(env['FLEA_FIXTURE_ROOT']) / 'unowned/Commons'
    result = subprocess.run(['bash', '-c', shell, 'control', str(root), str(sibling), str(repo)], cwd=source_root, env=env, capture_output=True, text=True)
    assert result.returncode == 1 and not sibling.exists(), result
    (commons / 'Style.qml').write_text(variants['whitespace'])
    result = subprocess.run(['bash', '-c', shell, 'control', str(root), str(root / 'refused/Commons'), str(repo)], cwd=source_root, env=env, capture_output=True, text=True)
    assert result.returncode == 1 and 'reader changed' in result.stderr and 'QS_REACHED' not in result.stdout, result
    print('HEADLESS_COMMONS_CONTROLS direct sources=6 reader drift=4 targets=5 passed')
    print(f'HEADLESS_COMMONS_CALL_CONTROLS unchecked=6 rejected exit=1; callers={calls} abort; reader refusal exit=1 qs=not-started')


if __name__ == '__main__':
    errors = direct_sources(Path('tests')) + unchecked_calls(Path('tests'))
    if errors:
        raise SystemExit('FAIL headless Commons rule: ' + '\n'.join(errors))
    box = Path(sys.argv[1])
    if not box.is_absolute() or not (box / '.flea-test-sandbox').is_file():
        raise SystemExit('FAIL headless Commons controls need an absolute marked fixture')
    try:
        controls(box)
    except AssertionError as error:
        raise SystemExit(f'FAIL headless Commons controls: {error}')
    print('HEADLESS_COMMONS_RULE every suite uses the shared fixture')
