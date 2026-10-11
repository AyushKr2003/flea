#!/usr/bin/env bash
# The capture sweep's chooser process finds the compositor through its private runtime, as the shipped chooser does under the desktop's own; offscreen qs, fake Hyprland sockets.
set -u
. "$(dirname "$0")/../tools/flea-sandbox-guard"
cd "$(dirname "$0")/.." || exit 1

if ! command -v qs >/dev/null; then
    echo "sweep-picker-env.sh: qs is not installed, cannot start the chooser double"
    exit 1
fi

# A marked sandbox of its own under the fixture root, so cleanup deletes only what this run owns.
test_root=$(mktemp -d "$FIXTURE_ROOT/flea-sweep-picker-env-XXXXXX") || exit 1
# The allocated path must be absolute and non-empty before the sandbox trusts it.
case $test_root in
  /*/*) ;;
  *) echo "FAIL: mktemp -d gave '$test_root', which is not an absolute path two components deep"; exit 1 ;;
esac
sandbox_require "$test_root" || exit 1
: > "$test_root/$SANDBOX_MARKER" || exit 1
cleanup() { sandbox_remove "$test_root"; }
trap cleanup EXIT

mkdir -p "$test_root/config" "$test_root/home" || exit 1
cat > "$test_root/config/shell.qml" <<'EOF'
//@ pragma ShellId flea-sweep-picker-env-test
import Quickshell
import Quickshell.Hyprland
import QtQuick

// Reading a Hyprland property is what makes Quickshell look for the compositor, as every Flea shell does through qs.Commons.
ShellRoot {
    readonly property var monitor: Hyprland.focusedMonitor
    Timer { interval: 1500; running: true; onTriggered: Qt.quit() }
}
EOF

python3 -I - "$PWD/tests/ui-captures-sweep-picker.py" "$test_root" <<'PY'
import ast
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading

script, root = Path(sys.argv[1]), Path(sys.argv[2])
source = script.read_text()
failed = False


def check(label, good, detail=""):
    global failed
    print(f"{'ok  ' if good else 'FAIL'} {label}{'' if good else ': ' + detail}", flush=True)
    failed = failed or not good


# Sample input: the picker script's own HYPRLAND_ALIAS constant and hyprland_environment function, cut out by name.
wanted = {"HYPRLAND_ALIAS", "hyprland_environment"}
namespace = {"Path": Path}
for node in ast.parse(source).body:
    name = node.name if isinstance(node, ast.FunctionDef) else next((t.id for t in getattr(node, "targets", []) if isinstance(t, ast.Name)), None)
    if name in wanted:
        exec(ast.get_source_segment(source, node), namespace)
        wanted.discard(name)
if wanted:
    print(f"FAIL the picker script lacks {sorted(wanted)}")
    sys.exit(1)

call = "picker_env.update(hyprland_environment(runtime, drive_env))"
check("the picker script hands its environment the Hyprland instance once", source.count(call) == 1,
      f"{source.count(call)} calls of {call}")

# Sample input: a real signature, a 40-hex commit, a unix time and a 9-digit number joined by underscores.
signature = "0123456789abcdef0123456789abcdef01234567_1760000000_123456789"
real = root / "real"
instance = real / "hypr" / signature
instance.mkdir(parents=True)
real.chmod(0o700)
drive_env = {"XDG_RUNTIME_DIR": str(real), "HYPRLAND_INSTANCE_SIGNATURE": signature}

REQUEST_BYTES = 4096


def serve(name, answer):
    # The real path is too long for sockaddr_un, so each server binds by a relative name from inside the instance directory.
    previous = os.getcwd()
    os.chdir(instance)
    try:
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(name)
        listener.listen(8)
    finally:
        os.chdir(previous)

    def loop():
        while True:
            try:
                connection, _ = listener.accept()
            except OSError:
                return
            with connection:
                request = connection.recv(REQUEST_BYTES)
                if answer:
                    connection.sendall(answer(request))
                else:
                    threading.Event().wait(2)

    threading.Thread(target=loop, daemon=True).start()


# Sample input: b"j/monitors", the command Quickshell sends; every list command gets an empty answer.
serve(".socket.sock", lambda request: b"{}" if request.endswith(b"status") else b"[]")
serve(".socket2.sock", None)

runtime = root / "runtime"
runtime.mkdir(mode=0o700)
reachable = f"{runtime}/hypr/{signature}/.socket2.sock"
check("the real signature would push the socket path past sockaddr_un", len(os.fsencode(reachable)) > 107,
      f"{len(os.fsencode(reachable))} bytes")


def chooser_log(environment):
    base = {"HOME": str(root / "home"), "PATH": os.environ["PATH"], "QT_QPA_PLATFORM": "offscreen",
            "QT_QPA_PLATFORMTHEME": "generic", "QT_FORCE_STDERR_LOGGING": "1"}
    done = subprocess.run(["timeout", "30", "qs", "-p", str(root / "config")], env={**base, **environment},
                          text=True, capture_output=True, stdin=subprocess.DEVNULL)
    return done.stdout + done.stderr


CONNECTION_FAULTS = ("Unable to find hyprland socket", "Unable to connect to hyprland event socket", "Error making request")

# The chooser as the sweep started it before: a private runtime with no hypr directory in it.
control = chooser_log({"XDG_RUNTIME_DIR": str(runtime), "HYPRLAND_INSTANCE_SIGNATURE": signature})
check("a private runtime with no hypr directory makes Quickshell warn it cannot find the socket",
      "Unable to find hyprland socket" in control, control)

picker_env = {"XDG_RUNTIME_DIR": str(runtime), "HYPRLAND_INSTANCE_SIGNATURE": signature}
picker_env.update(namespace["hyprland_environment"](runtime, drive_env))
shipped = chooser_log(picker_env)
faults = [line for line in shipped.splitlines() if any(fault in line for fault in CONNECTION_FAULTS)]
check("the chooser environment the script builds reaches both Hyprland sockets", not faults, "\n".join(faults))
check("the chooser environment names the alias, which fits the socket path",
      picker_env["HYPRLAND_INSTANCE_SIGNATURE"] == namespace["HYPRLAND_ALIAS"]
      and len(os.fsencode(f"{runtime}/hypr/{namespace['HYPRLAND_ALIAS']}/.socket2.sock")) <= 107)

missing = root / "missing"
missing.mkdir(mode=0o700)
try:
    namespace["hyprland_environment"](runtime, {"XDG_RUNTIME_DIR": str(missing), "HYPRLAND_INSTANCE_SIGNATURE": signature})
    refused = False
except AssertionError as error:
    refused = "the Hyprland instance directory is missing" in str(error)
check("a desktop with no Hyprland instance directory is refused, not warned about later", refused)

if failed:
    sys.exit(1)
print("SWEEPPICKERENV DONE")
PY
