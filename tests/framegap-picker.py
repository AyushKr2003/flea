#!/usr/bin/env python3
"""Keep framegap's picker mock aligned with the answer strip's real owner."""
import re
from pathlib import Path


def members(source):
    properties = re.findall(r'\bproperty\s+\w+\s+(\w+)\s*:', source)
    functions = re.findall(r'\bfunction\s+(\w+)\s*\(', source)
    return set(properties + functions)


owner = Path('ui/PickerWindow.qml').read_text()
harness = Path('tests/framegap.qml').read_text()
mock = re.search(r'\bid: mockPicker\b(.*?)^        }', harness, re.M | re.S)
if mock is None:
    raise SystemExit('FAIL framegap picker contract: mockPicker was not found')
# FloatingWindow supplies contentItem; the other members are declared by the real owner.
provided = members(owner) | {'contentItem'}
mocked = members(mock.group(1))
required = set()
for file in ('ui/PickerAnswers.qml', 'ui/PickerFilter.qml'):
    used = set(re.findall(r'\broot\.picker\.(\w+)', Path(file).read_text()))
    required |= used
    if used - provided:
        raise SystemExit(f'FAIL framegap picker contract: {file} has no owner member: {", ".join(sorted(used - provided))}')
    if used - mocked:
        raise SystemExit(f'FAIL framegap picker contract: mockPicker lacks {file} member: {", ".join(sorted(used - mocked))}')
print(f'FRAMEGAP PICKER_CONTRACT members={len(required)} owner=PickerWindow.qml mock=mockPicker')
