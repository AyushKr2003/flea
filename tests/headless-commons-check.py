#!/usr/bin/env python3
"""Reject direct OEM links and exercise the shared headless fixture contract."""
import os
from pathlib import Path
import re
import subprocess
import sys

# External-stub callers must finish promptly even if a loop's refusal guard regresses.
CALLER_TIMEOUT_SECONDS = 10


def direct_sources(root):
    bad = []
    sources = ('ui/boot/' + 'Commons', 'ui/' + 'Commons', '/usr/share/omarchy/shell/' + 'Commons')
    for path in sorted(root.glob('*.sh')):
        if path.name == 'headless-commons.sh':
            continue
        for n, line in enumerate(path.read_text().splitlines(), 1):
            # Sample input: ln -s "$(readlink -f ui/boot/Commons/)" "$root/config/Commons" also links the live OEM source.
            if not line.lstrip().startswith('#') and any(re.search(r'(?<![\w$])' + re.escape(source) + r'(?!\w)', line) for source in sources):
                bad.append(f'{path}:{n}: use headless_commons instead of a direct OEM Commons source')
    return bad


def call_scopes(source):
    depth = 0
    cases = []
    scopes = {}
    quoted = False
    substitutions = []
    heredocs = []
    arithmetic = []
    groups = []
    closed_calls = set()
    pipe_next = False
    command_start = True
    word_start = True
    unmatched_tail = False
    unknown_pipeline = False
    compound_ends = {'{': '}', 'if': 'fi', 'for': 'done', 'while': 'done', 'until': 'done', 'select': 'done', 'case': 'esac'}
    # Sample input: prepare() { and function prepare { are supported literal function headers, not brace arguments.
    function_head = re.compile(r'(?:^|[;{}])\s*(?:function\s+)?\w+\s*\(\s*\)\s*$|(?:^|[;{}])\s*function\s+\w+\s*$')
    words = re.compile(r'\w+|;;&|;;|;&|&&|\|\||\|&|[();{}!|&]')
    delimiters = re.compile(r'(?<!<)<<-?(?!<)[ \t]*[\'"]?([A-Za-z_]\w*)[\'"]?')
    at = 0
    while at < len(source):
        char = source[at]
        if char == '\\':
            if source[at + 1:at + 2] != '\n':
                command_start = False
                word_start = False
            at += 2
            continue
        if char == '\n' and heredocs:
            at += 1
            for delimiter in heredocs:
                while at < len(source):
                    end = source.find('\n', at)
                    end = len(source) if end < 0 else end + 1
                    line = source[at:end].strip()
                    at = end
                    if line == delimiter:
                        break
            heredocs.clear()
            command_start = True
            word_start = True
            continue
        if char == '"':
            quoted = not quoted
            command_start = False
            word_start = False
            at += 1
            continue
        if source.startswith('$(', at):
            if source.startswith('$((', at):
                arithmetic.append(depth)
            substitutions.append((depth, quoted))
            quoted = False
            command_start = True
            word_start = True
            depth += 1
            at += 2
            continue
        if quoted:
            at += 1
            continue
        # Sample input: $'it\'s' keeps escapes, ordinary single quotes do not; backticks run a child and hide no accepted call.
        if char in "'`":
            command_start = False
            word_start = False
            ansi = char == '`' or at > 0 and source[at - 1] == '$'
            pattern = re.escape(char) + (r'(?:\\.|[^' + re.escape(char) + r'\\])*' if ansi else "[^']*") + re.escape(char)
            literal = re.compile(pattern, re.S).match(source, at)
            at = len(source) if literal is None else literal.end()
            continue
        # Sample input: (# comment ) starts a comment; $(printf x)#suffix and \)#suffix continue the current shell word.
        if char == '#' and word_start:
            end = source.find('\n', at)
            at = len(source) if end < 0 else end
            continue
        # Sample input: cat <<'TEXT' skips its body; cat <<<ready is a here-string, never a heredoc at either trailing <<.
        heredoc = delimiters.match(source, at) if not arithmetic else None
        if heredoc:
            heredocs.append(heredoc[1])
            at += len(heredoc[0])
            continue
        if source.startswith('((', at):
            arithmetic.append(depth)
        token = words.match(source, at)
        if token is None:
            if char == '\n':
                command_start = True
                closed_calls.clear()
                unmatched_tail = False
            elif not char.isspace():
                command_start = False
            word_start = char.isspace() or char in '<>'
            at += 1
            continue
        word = token[0]
        line = source.count('\n', 0, at) + 1
        pattern_close = word == ')' and cases and cases[-1] == 'pattern'
        # Sample input: } &>out, } &>>out and } 2>&1 redirect a parent group; } & starts a background child.
        redirect_amp = word == '&' and (source[token.end():token.end() + 1] == '>' or token.start() > 0 and source[token.start() - 1] in '<>')
        # Sample input: echo } is an argument; fi | cat closes a compound command only at a reserved-word position.
        separated = token.end() == len(source) or source[token.end()].isspace() or source[token.end()] in '();|&<>'
        keyword = command_start and word_start and separated
        in_pattern = cases and cases[-1] == 'pattern'
        opens_brace = word == '{' and not in_pattern and word_start and separated and (command_start or function_head.search(source[:at].rsplit('\n', 1)[-1]))
        opens_compound = opens_brace or keyword and word in compound_ends and not in_pattern
        closes_compound = keyword and (word in ('}', 'fi', 'done') and not in_pattern or word == 'esac' and not re.match(r'\s*\)', source[token.end():]))
        joins_word = False
        at += len(word)
        # Sample input: (\n headless_commons "$root" || exit 1\n) exits only a child; case x in x) is not a subshell close.
        if word == 'headless_commons':
            scopes[line] = max(depth, int(any(piped for _, piped, _ in groups)))
            for _, _, calls in groups:
                calls.add(line)
        elif word == 'case' and keyword and (not cases or cases[-1] == 'body'):
            cases.append('subject')
        elif word == 'in' and word_start and separated and cases and cases[-1] == 'subject':
            cases[-1] = 'pattern'
        elif word == 'esac' and keyword and cases and not re.match(r'\s*\)', source[at:]):
            cases.pop()
        elif cases and cases[-1] == 'pattern':
            if word == ')':
                cases[-1] = 'body'
        elif word in (';;', ';&', ';;&') and cases:
            cases[-1] = 'pattern'
        elif word == '(':
            depth += 1
        elif word == ')':
            depth = max(0, depth - 1)
            if arithmetic and depth == arithmetic[-1]:
                arithmetic.pop()
            if substitutions and depth == substitutions[-1][0]:
                _, quoted = substitutions.pop()
                joins_word = True
        # Sample input: if true; then\n headless_commons "$root" || exit 1\nfi | cat is an unsupported compound pipeline.
        if opens_compound:
            groups.append((compound_ends[word], pipe_next, set()))
            closed_calls.clear()
            unmatched_tail = False
        elif closes_compound:
            if groups and groups[-1][0] == word:
                _, _, closed_calls = groups.pop()
            else:
                closed_calls.clear()
                unmatched_tail = True
        elif word in ('|', '|&', '&') and not redirect_amp:
            for call in closed_calls:
                scopes[call] = max(scopes[call], 1)
            closed_calls.clear()
            unknown_pipeline |= unmatched_tail
        elif word in (';', ';;', ';&', ';;&', '&&', '||'):
            closed_calls.clear()
            unmatched_tail = False
        if word not in ('!', 'time'):
            pipe_next = word in ('|', '|&')
        # Sample input: echo if case in esac keeps argument words; ; case and a case arm's ) start commands.
        word_start = not joins_word and word in (';', ';;', ';&', ';;&', '&&', '||', '|', '|&', '&', '(', ')')
        command_start = (word in (';', ';;', ';&', ';;&', '&&', '||', '|', '|&', '&', '(') or bool(pattern_close) or bool(opens_brace)
                         or command_start and word in ('if', 'elif', 'while', 'until', 'then', 'else', 'do', 'time', '!'))
    if unknown_pipeline:
        scopes = {line: max(scope, 1) for line, scope in scopes.items()}
    return scopes


def unchecked_calls(root):
    bad = []
    for path in sorted(root.glob('*.sh')):
        if path.name == 'headless-commons.sh':
            continue
        source = path.read_text()
        if 'headless_commons' not in source:
            continue
        scopes = call_scopes(source)
        for n, line in enumerate(source.splitlines(), 1):
            # Sample input: headless_commons "$root" must carry an exit guard even when the suite uses set -e.
            if line.lstrip().startswith('#') or not re.search(r'\bheadless_commons\b', line):
                continue
            # Sample input: headless_commons "$root" || exit 1; thumbs also keeps its sandbox_remove cleanup before exit.
            if scopes.get(n) != 0 or not re.fullmatch(r'\s*headless_commons\s+[^;&|]+\s+\|\|\s+(?:exit\s+1|\{\s*sandbox_remove\s+[^;&|{}]+;\s*exit\s+1;\s*\})\s*', line):
                bad.append(f'{path}:{n}: headless_commons refusal must abort the suite with || exit 1 in the parent shell')
    return bad


def controls(box):
    fixture = box / 'headless-commons-controls'
    fixture.mkdir()
    scanner = fixture / 'tests'
    scanner.mkdir()
    direct = scanner / 'new-suite.sh'
    direct_controls = 0
    for source in ('ui/boot/' + 'Commons', 'ui/' + 'Commons', '/usr/share/omarchy/shell/' + 'Commons'):
        for suffix in ('', '/', '/.', '/Style.qml'):
            for line in (f'ln -s "$(readlink -f {source}{suffix})" "$root/config/Commons"', f'commons={source}{suffix}\nln -s "$commons" "$target"'):
                direct.write_text(line)
                assert len(direct_sources(scanner)) == 1 and 'new-suite.sh:1:' in direct_sources(scanner)[0]
                direct_controls += 1
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
    calls = sum(len(call_scopes(path.read_text())) for path in Path('tests').glob('*.sh') if path.name != 'headless-commons.sh')
    # Sample input: python3 - "$target/Style.qml" <<'PY' followed by Python lines and a bare PY closing delimiter.
    helper = Path('tests/headless-commons.sh').read_text().split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
    original = 'import Quickshell.Hyprland\nQtObject {\n  id: root\n  Connections {\n    target: Hyprland\n  }\n}\n'
    variants = {
        'whitespace': original.replace('import Quickshell.', 'import  Quickshell.').replace('    target:', '  target :'),
        'alias': original.replace('import Quickshell.Hyprland', 'import Quickshell.Hyprland as Compositor').replace('target: Hyprland', 'target: Compositor'),
        'qualified': original.replace('import Quickshell.Hyprland\n', 'import Quickshell\n').replace('target: Hyprland', 'target: Quickshell.Hyprland'),
        'extra-read': original.replace('  Connections {', '  property var extra: Hyprland\n  Connections {'),
        'template-url': original.replace('  Connections {', '  property string url: `http://example`; property var live: Hyprland\n  Connections {'),
        'template-interpolation': original.replace('  Connections {', '  property string url: `file://${Hyprland}`\n  Connections {'),
        'multiline-template': original.replace('  Connections {', '  property string url: `http://example\n${Hyprland}`\n  Connections {'),
    }
    comments = '// Hyprland rounding\n/* Hyprland config */\n'
    tokens = '  property string url: `http://example`\n  property string other: "/* literal */ // data"\n'
    for name, before in {'current': comments + 'QtObject {\n  id: root\n' + tokens + '}\n', 'dev': comments + original.replace('  Connections {', tokens + '  Connections {'), **variants}.items():
        path = fixture / f'{name}.qml'
        path.write_text(before)
        result = subprocess.run(['python3', '-B', '-', str(path)], input=helper, text=True, capture_output=True)
        if name in variants:
            assert result.returncode == 1 and 'reader changed' in result.stderr and path.read_text() == before, (name, result)
        else:
            assert result.returncode == 0, (name, result)
            expected = before if name == 'current' else before.replace('import Quickshell.Hyprland\n', '').replace('  id: root\n', '  id: root\n  property QtObject headlessEvents: QtObject { signal rawEvent(var event) }\n').replace('    target: Hyprland\n', '    target: root.headlessEvents\n')
            assert path.read_text() == expected, name
    env = dict(os.environ, HOME=str(fixture / 'home'), FLEA_FIXTURE_ROOT=str(fixture / 'fixtures'))
    root = Path(env['FLEA_FIXTURE_ROOT']) / 'owned'
    root.mkdir(parents=True)
    (root / '.flea-test-sandbox').touch()
    source_root = fixture / 'source'
    commons = source_root / 'ui/boot/Commons'
    commons.mkdir(parents=True)
    (commons / 'Style.qml').write_text(original)
    repo = Path.cwd()
    (source_root / 'tests').mkdir()
    (source_root / 'tests/staticgates.py').symlink_to(repo / 'tests/staticgates.py')
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
    prologue = '. "$3/tools/flea-sandbox-guard"\n. "$3/tests/headless-commons.sh"\nqs() { printf "QS_REACHED\\n"; }\n'
    call = 'headless_commons "$1" "$2" || exit 1\n'
    parents = {
        'root': call,
        'function': 'prepare() {\n' + call + '}\nprepare "$@"\n',
        'loop': 'for leg in current; do\n' + call + 'done\n',
        'case': 'case current in\ncurrent)\n' + call + ';;\nesac\n',
        'literal-parentheses': 'printf "%s\\n" "("\ncat <<\'TEXT\'\n( sample data\nTEXT\n' + call,
        'nested-quotes': 'out=ready\nprintf "%s\\n" "$(printf "%s" "$out" | grep \'ready\')"\n' + call,
        'arithmetic-shift': 'bits=2\nvalue=$((1 << bits))\n' + call,
        'keyword-arguments': 'printf "%s\\n" if case in esac\n' + call,
    }
    children = {
        'subshell': '(\n' + call + ')\n',
        'substitution': 'copy=$(\n' + call + ')\n',
        'quoted-substitution': 'copy="$(\n' + call + ')"\n',
        'subshell-case': '(\ncase current in\ncurrent)\n' + call + ';;\nesac\n)\n',
        'subshell-keywords': 'printf "%s\\n" if case in\n(\ncase current in\ncurrent)\nprintf "%s\\n" esac\n' + call + ';;\nesac\n)\n',
    }
    extra_parents = {
        'brace': '{\n' + call + '}\n',
        'brace-prefix-comment': '{ # comment ) | (\n' + call + '}\n',
        'parent-prefix-comment': ':;# comment ( | { }\n' + call,
        'here-string': 'cat <<<ready\n' + call,
        'here-string-quoted': 'cat <<<"ready ) | { #"\n' + call,
        'here-string-spaced': "cat <<< 'ready ( | #'\n" + call,
        'unrelated-pipe': 'printf "ready\\n" | cat\n' + call,
        'literal-pipes': 'printf "%s\\n" "|" "{ }"\n' + call,
        'multiline-comments': '# |\n# {\n# (\n' + call,
    }
    extra_children = {
        'pipeline-left': '{\n' + call + '} | cat\n',
        'pipeline-right': 'printf "" | {\n' + call + '}\n',
        'pipeline-left-prefix-comment': '{\n# comment ) |\n' + call + '} |# comment } (\ncat\n',
        'pipeline-right-prefix-comment': 'printf "" |# comment ) {\n{ # comment )\n' + call + '}\n',
        'pipeline-both': 'printf "" | {\n' + call + '} | cat\n',
        'pipeline-nested': '{\n{\n' + call + '}\n} | cat\n',
        'pipeline-left-stderr': '{\n' + call + '} |& cat\n',
        'pipeline-right-stderr': 'printf "" |& {\n' + call + '}\n',
        'pipeline-redirect': '{\n' + call + '} 2>&1 | cat\n',
        'background-brace': '{\n' + call + '} &\n',
        'comment-after-paren': '(# comment )\n' + call + ')\n',
        'comment-multiline': '(\n# comment )\n' + call + ')\n',
        'comment-after-semi': '(:;# comment )\n' + call + ')\n',
        'comment-after-pipe': 'printf "" | (# comment )\n' + call + ')\n',
    }
    for name, body in {**parents, **children, **extra_parents, **extra_children}.items():
        direct.write_text(prologue + body + 'qs -p "$2"\n')
        child = name in children or name in extra_children
        assert bool(unchecked_calls(scanner)) == child, name
        syntax = subprocess.run(['bash', '-n', str(direct)], capture_output=True, text=True)
        assert syntax.returncode == 0, (name, syntax)
        result = subprocess.run(['bash', str(direct), str(root), str(root / name / 'Commons'), str(repo)], cwd=source_root, env=env, capture_output=True, text=True)
        assert 'reader changed' in result.stderr + result.stdout, (name, result)
        if child:
            assert result.returncode == 0 and 'QS_REACHED' in result.stdout, (name, result)
            gate = subprocess.run([sys.executable, '-B', str(checker), str(box)], cwd=fixture, capture_output=True, text=True)
            assert gate.returncode == 1 and 'parent shell' in gate.stderr, (name, gate)
        else:
            assert result.returncode == 1 and 'QS_REACHED' not in result.stdout, (name, result)
    for file in ('tests/framegap.sh', 'tests/headless-commons.sh', 'tests/framegap-picker.py',
                 'tests/framegap.qml', 'ui/PickerWindow.qml', 'ui/PickerAnswers.qml', 'ui/PickerFilter.qml', 'tools/flea-sandbox-guard'):
        target = source_root / file
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(repo / file)
    bin_dir = fixture / 'bin'
    bin_dir.mkdir()
    fake_qs = bin_dir / 'qs'
    fake_qs.write_text('#!/bin/sh\nprintf "QS_REACHED\\n"\n')
    fake_qs.chmod(0o755)
    for cwd, script in ((repo, str(source_root / 'tests/framegap.sh')), (source_root / 'tests', 'framegap.sh')):
        result = subprocess.run(['bash', script], cwd=cwd, env=dict(env, PATH=str(bin_dir) + os.pathsep + env['PATH']), capture_output=True, text=True)
        assert result.returncode == 1 and 'reader changed' in result.stderr and 'QS_REACHED' not in result.stdout, result
    helper_stub = bin_dir / 'headless_commons'
    helper_stub.write_text('#!/bin/sh\ncase "$1" in /?*) [ -f "$1/.flea-test-sandbox" ] || exit 2;; *) exit 2;; esac\nprintf "HELPER_REFUSED\\n" >> "$1/refusals"\nexit 1\n')
    helper_stub.chmod(0o755)
    contract_env = dict(env, PATH=str(bin_dir) + os.pathsep + env['PATH'])
    contract_call = 'headless_commons "$root" || exit 1\n'
    contract_parents = {
        'redirect-truncate': '{\n' + contract_call + '} &>"$root/output"\n',
        'redirect-append': '{\n' + contract_call + '} &>>"$root/output"\n',
        'redirect-compact': '{\n' + contract_call + '}&>"$root/output"\n',
        'redirect-descriptor': '{\n' + contract_call + '} 2>&1\n',
        'substitution-suffix-parent': 'printf "%s\\n" $(printf x)#suffix\n' + contract_call,
        'escaped-suffix-parent': 'printf "%s\\n" \\)#suffix\n' + contract_call,
        'quoted-suffix-parent': 'printf "%s\\n" ")"#suffix\n' + contract_call,
        'brace-arguments-parent': 'printf "%s\\n" } {\n' + contract_call,
        'if-parent': 'if true; then\n' + contract_call + 'fi\n',
        'unrelated-if-pipeline': 'if true; then printf "ready\\n"; fi | cat\n' + contract_call,
        'unrelated-for-pipeline': 'for leg in current; do printf "ready\\n"; done | cat\n' + contract_call,
        'unrelated-case-pipeline': 'case "{" in {) printf "ready\\n";; esac | cat\n' + contract_call,
        'keyword-arguments-parent': 'printf "%s\\n" if fi done esac\n' + contract_call,
    }
    contract_children = {
        'substitution-suffix-child': 'printf "%s\\n" $(printf x)#suffix; (\n' + contract_call + ')\n',
        'nested-suffix-child': 'printf "%s\\n" $(printf "$(printf x)")#suffix; (\n' + contract_call + ')\n',
        'escaped-suffix-child': 'printf "%s\\n" \\)#suffix; (\n' + contract_call + ')\n',
        'if-left': 'if true; then\n' + contract_call + 'fi | cat\n',
        'if-right': 'printf "" | if true; then\n' + contract_call + 'fi\n',
        'if-stderr': 'if true; then\n' + contract_call + 'fi |& cat\n',
        'if-background': 'if true; then\n' + contract_call + 'fi &\n',
        'if-nested': 'if true; then\nif true; then\n' + contract_call + 'fi\nfi | cat\n',
        'for-left': 'for leg in current; do\n' + contract_call + 'done | cat\n',
        'for-right': 'printf "" | for leg in current; do\n' + contract_call + 'done\n',
        'while-left': 'while true; do\n' + contract_call + 'done | cat\n',
        'until-right': 'printf "" | until false; do\n' + contract_call + 'done\n',
        'case-left': 'case current in current)\n' + contract_call + ';; esac | cat\n',
        'case-right': 'printf "" | case current in current)\n' + contract_call + ';; esac\n',
        'brace-argument-left': '{\necho }\n' + contract_call + '} | cat\n',
        'brace-arguments-right': 'printf "" | {\nprintf "%s\\n" } }\n' + contract_call + '}\n',
        'brace-open-argument': '{\necho {\n' + contract_call + '} | cat\n',
        'if-brace-argument': 'if true; then\necho }\n' + contract_call + 'fi | cat\n',
    }
    for name, body in {**contract_parents, **contract_children}.items():
        owner = root / ('external-' + name)
        owner.mkdir()
        (owner / '.flea-test-sandbox').touch()
        direct.write_text('root=$1\n' + body + 'qs -p "$root"\n')
        syntax = subprocess.run(['bash', '-n', str(direct)], capture_output=True, text=True)
        assert syntax.returncode == 0, (name, syntax)
        child = name in contract_children
        errors = unchecked_calls(scanner)
        assert bool(errors) == child, (name, errors)
        result = subprocess.run(['bash', str(direct), str(owner)], cwd=source_root, env=contract_env,
                                capture_output=True, text=True, timeout=CALLER_TIMEOUT_SECONDS)
        assert (owner / 'refusals').read_text() == 'HELPER_REFUSED\n', (name, result)
        assert result.returncode == (0 if child else 1) and ('QS_REACHED' in result.stdout) == child, (name, result)
        if child:
            gate = subprocess.run([sys.executable, '-B', str(checker), str(box)], cwd=fixture, capture_output=True,
                                  text=True, timeout=CALLER_TIMEOUT_SECONDS)
            assert gate.returncode == 1 and 'parent shell' in gate.stderr, (name, gate)
        print(f'HEADLESS_COMMONS_EXTERNAL_CALLER {name} bash_n=0 scan_errors={len(errors)} caller_exit={result.returncode} qs={int(child)}')
    print(f'HEADLESS_COMMONS_CONTROLS direct sources={direct_controls} reader drift={len(variants)} targets=5 passed; OEM token bytes preserved')
    print(f'HEADLESS_COMMONS_CALL_CONTROLS unchecked=6 rejected exit=1; callers={calls} scope-checked')
    print(f'HEADLESS_COMMONS_WHOLE_CALLERS parents={len(parents)} refusal exit=1 qs=not-started; children={len(children)} reach qs but gate rejects exit=1')
    print(f'HEADLESS_COMMONS_PIPE_COMMENT_CONTROLS parents={len(extra_parents)} refusal exit=1 qs=not-started; children={len(extra_children)} gate rejects exit=1')
    print('HEADLESS_COMMONS_ACTUAL_CALLER unmodified framegap.sh from repo and tests: refusal exit=1 qs=not-started')
    print(f'HEADLESS_COMMONS_EXTERNAL_CONTROLS parents={len(contract_parents)} refusal exit=1 qs=not-started; children={len(contract_children)} gate rejects exit=1')


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
