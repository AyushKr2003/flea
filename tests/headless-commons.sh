# Sourced by offscreen suites: OEM tokens stay real; only the compositor reload source is inert in the marked fixture.
headless_commons() {
    local root=$1 source
    sandbox_require "$root" || return 1
    sandbox_owned "$SANDBOX_PATH" || { printf 'FAIL headless Commons needs a marked fixture\n'; return 1; }
    source=$(readlink -f ui/boot/Commons) || return 1
    mkdir -p "$SANDBOX_PATH/config/Commons" || return 1
    cp -a "$source/." "$SANDBOX_PATH/config/Commons/" || return 1
    python3 - "$SANDBOX_PATH/config/Commons/Style.qml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
if path.is_symlink() or not path.is_file():
    raise SystemExit('FAIL headless Commons: Style.qml must be a copied regular file')
source = path.read_text()
import_line = 'import Quickshell.Hyprland\n'
target_line = '    target: Hyprland\n'
root_line = '  id: root\n'
guarded = source.count(target_line)
if import_line in source or guarded:
    if source.count(import_line) != 1 or guarded != 1 or source.count(root_line) != 1:
        raise SystemExit('FAIL headless Commons: the OEM Hyprland reader changed; update the fixture contract')
    source = source.replace(import_line, '')
    source = source.replace(root_line, root_line + '  property QtObject headlessEvents: QtObject { signal rawEvent(var event) }\n')
    source = source.replace(target_line, '    target: root.headlessEvents\n')
    path.write_text(source)
print(f'HEADLESS_COMMONS inert_reload_sources={guarded}')
PY
}
