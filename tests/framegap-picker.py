#!/usr/bin/env python3
"""Keep framegap's picker mock aligned with the answer strip's real owner."""
import re
from pathlib import Path
from staticgates import masked


def object_body(source, name):
    code = masked(source, '.qml', fill=' ')
    # Sample input: QtObject { id: mockPicker; Item { property bool saving: false } } keeps the whole balanced mock block.
    match = re.search(r'\bid\s*:\s*' + re.escape(name) + r'\b', code)
    if match is None:
        raise ValueError(f'{name} was not found')
    stack = []
    for at, char in enumerate(code[:match.start()]):
        if char == '{':
            stack.append(at)
        elif char == '}':
            stack.pop()
    start = stack[-1]
    depth = 1
    for at in range(start + 1, len(code)):
        depth += (code[at] == '{') - (code[at] == '}')
        if depth == 0:
            return code[start + 1:at]
    raise ValueError(f'{name} has no closing brace')


def members(source):
    code = masked(source, '.qml', fill=' ')
    depths = []
    depth = 0
    for char in code:
        depths.append(depth)
        depth += (char == '{') - (char == '}')
    # Sample input: property bool saving: false; Item { property bool child: false } declares only saving on the owner.
    properties = re.finditer(r'\bproperty\s+\w+\s+(\w+)\s*:', code)
    # Sample input: function accept() {}; Item { function child() {} } declares only accept on the owner.
    functions = re.finditer(r'\bfunction\s+(\w+)\s*\(', code)
    return {m[1] for group in (properties, functions) for m in group if depths[m.start()] == 0}


def contract(owner, harness, readers):
    # FloatingWindow supplies contentItem; the other members belong to the window with id win.
    provided = members(object_body(owner, 'win')) | {'contentItem'}
    mocked = members(object_body(harness, 'mockPicker'))
    required = set()
    for file, source in readers.items():
        # Sample input: enabled: !root.picker.saving reads saving from the picker owner's root.
        used = set(re.findall(r'\broot\.picker\.(\w+)', masked(source, '.qml', fill=' ')))
        required |= used
        if used - provided:
            raise ValueError(f'{file} has no owner member: {", ".join(sorted(used - provided))}')
        if used - mocked:
            raise ValueError(f'mockPicker lacks {file} member: {", ".join(sorted(used - mocked))}')
    return required


def controls():
    owner = 'ShellRoot { FloatingWindow { id: win; property bool saving: false; function accept() {} } }'
    mock = 'QtObject { id: mockPicker; property bool saving: false; function accept() {} }'
    readers = {'control.qml': 'enabled: root.picker.saving; onClicked: root.picker.accept()'}
    assert contract(owner, mock, readers) == {'saving', 'accept'}
    for declaration in ('property bool saving: false', 'function accept() {}'):
        for replacement in ('Item { ' + declaration + ' }', '// ' + declaration + '\n', '/* ' + declaration + ' */'):
            for subject in ('owner', 'mock'):
                try:
                    contract(owner.replace(declaration, replacement) if subject == 'owner' else owner,
                             mock.replace(declaration, replacement) if subject == 'mock' else mock, readers)
                except ValueError:
                    continue
                raise AssertionError(f'{subject} accepted a child or commented declaration: {replacement}')
    print('FRAMEGAP PICKER_CONTROLS 12 missing root declarations rejected')


if __name__ == '__main__':
    try:
        controls()
        required = contract(Path('ui/PickerWindow.qml').read_text(), Path('tests/framegap.qml').read_text(),
                            {file: Path(file).read_text() for file in ('ui/PickerAnswers.qml', 'ui/PickerFilter.qml')})
    except (ValueError, AssertionError) as error:
        raise SystemExit(f'FAIL framegap picker contract: {error}')
    print(f'FRAMEGAP PICKER_CONTRACT members={len(required)} owner=PickerWindow.qml mock=mockPicker')
