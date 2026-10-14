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
            if not line.lstrip().startswith('#') and any(re.search(r'(?<![\w$])' + re.escape(source) + r'(?![\w/])', line) for source in sources):
                bad.append(f'{path}:{n}: use headless_commons instead of a direct OEM Commons source')
    return bad


def controls(box):
    fixture = box / 'headless-commons-controls'
    fixture.mkdir()
    scanner = fixture / 'scan'
    scanner.mkdir()
    direct = scanner / 'new-suite.sh'
    for source in ('ui/boot/' + 'Commons', 'ui/' + 'Commons', '/usr/share/omarchy/shell/' + 'Commons'):
        for line in (f'ln -s "$(readlink -f {source})" "$root/config/Commons"', f'commons={source}\nln -s "$commons" "$target"'):
            direct.write_text(line)
            assert len(direct_sources(scanner)) == 1 and 'new-suite.sh:1:' in direct_sources(scanner)[0]
    direct.write_text('# ui/boot/' + 'Commons is supplied by the helper\nheadless_commons "$root"\ncp -a "$flea_ui/boot/Commons" "$target"\n')
    assert not direct_sources(scanner)
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
    shell = '. "$3/tools/flea-sandbox-guard"; . "$3/tests/headless-commons.sh"; headless_commons "$1" "$2"'
    targets = [(root, root / name) for name in ('config/Commons', 'config-KEYS/Commons', 'config/boot/Commons')]
    targets.append((root / 'work', root / 'work/pane/config/Commons'))
    for owner, target in targets:
        owner.mkdir(exist_ok=True)
        result = subprocess.run(['bash', '-c', shell, 'control', str(owner), str(target), str(repo)], cwd=source_root, env=env, capture_output=True, text=True)
        assert result.returncode == 0 and (target / 'Style.qml').is_file() and not (target / 'Style.qml').is_symlink(), result
    sibling = Path(env['FLEA_FIXTURE_ROOT']) / 'unowned/Commons'
    result = subprocess.run(['bash', '-c', shell, 'control', str(root), str(sibling), str(repo)], cwd=source_root, env=env, capture_output=True, text=True)
    assert result.returncode == 1 and not sibling.exists(), result
    print('HEADLESS_COMMONS_CONTROLS direct sources=6 reader drift=4 targets=5 passed')


if __name__ == '__main__':
    errors = direct_sources(Path('tests'))
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
