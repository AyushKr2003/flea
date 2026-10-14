#!/usr/bin/env python3
"""Exercise the actual capture runner and Trash teardown with isolated process groups."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

repo, parent, marker = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
if not parent.is_absolute() or not (parent / marker).is_file():
    raise SystemExit("FAIL capture-lifecycle: missing absolute owned fixture root")
root = Path(tempfile.mkdtemp(prefix="lifecycle-", dir=parent))
(root / marker).touch()
checks = 0
failed = 0


def check(ok, name, detail=""):
    global checks, failed
    checks += 1
    failed += not ok
    print(f"{'CAPTURELIFECYCLE PASS' if ok else 'FAIL capture-lifecycle'} {name}: {detail}", flush=True)


def await_condition(condition, seconds=3):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if condition():
            return True
        time.sleep(0.02)
    return condition()


def running(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[0] != "Z"
    except FileNotFoundError:
        return False


def members(group):
    found = []
    for path in Path("/proc").iterdir():
        if path.name.isdigit():
            try:
                if os.getpgid(int(path.name)) == group and running(int(path.name)):
                    found.append(int(path.name))
            except ProcessLookupError:
                pass
    return found


def send_group(group, sig):
    assert group > 1 and group != os.getpgrp(), "refusing own or invalid process group"
    try:
        os.killpg(group, sig)
    except ProcessLookupError:
        pass


def stop(process):
    send_group(process.pid, signal.SIGKILL)
    process.wait(timeout=3)


def launch(script, case, *args, env=None):
    with (case / "runner.log").open("w") as log:
        return subprocess.Popen(["bash", str(script), str(case), *args], stdout=log,
                                stderr=subprocess.STDOUT, start_new_session=True, env=env)


source = subprocess.run(["bash", "-c", '. "$1/tests/ui-captures-cohesion.sh"; '
                         'declare -f coh_bounded coh_surface_work coh_release_held', "bash", str(repo)],
                        env={**os.environ, "repo": str(repo)}, capture_output=True, text=True, check=True).stdout
actual = root / "actual.sh"
actual.write_text(source)
runner = root / "signal-runner.sh"
runner.write_text('''set -u
case_root=$1
. "$(dirname "$0")/actual.sh"
coh_theme=signal-proof coh_budget_s=60 coh_teardown_s=1 coh_poll_s=0.02 coh_usec_per_s=1000000
coh_deadline=$((SECONDS + 60))
coh_held=0
coh_ydotool() {
    printf 'RELEASE_BEGIN\\n'
    command sleep 0.1
    printf '%s\\n' "$*" >> "$case_root/release"
    printf 'RELEASE_DONE\\n'
}
trap 'printf "ORIGINAL HUP\\n"; exit 129' HUP
trap 'printf "ORIGINAL INT\\n"; exit 130' INT
trap 'printf "ORIGINAL TERM\\n"; exit 143' TERM
coh_run_surface() {
    set -x
    coh_held=1
    printf '%s\\n' "$BASHPID" > "$case_root/worker.pid"
    bash -c 'trap "" TERM; printf "%s\\n" "$BASHPID" > "$1"; exec sleep 60' bash "$case_root/child.pid" &
    local child=$!
    while [[ ! -s "$case_root/child.pid" ]]; do command sleep 0.01; done
    : > "$case_root/ready"
    wait "$child"
}
coh_bounded signal 60 coh_surface_work
printf 'UNEXPECTED_RETURN %s\\n' "$?"
''')

for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    for target in ("pid", "group"):
        label = f"{sig.name}/{target}"
        case = root / f"{sig.name}-{target}"
        case.mkdir()
        (case / marker).touch()
        sentinel = subprocess.Popen(["sleep", "60"], start_new_session=True)
        process = launch(runner, case)
        groups = []
        try:
            ready = await_condition(lambda: (case / "ready").exists() or process.poll() is not None)
            assert ready and (case / "ready").exists(), "surface did not become ready"
            worker = int((case / "worker.pid").read_text())
            child = int((case / "child.pid").read_text())
            def children_ready():
                children = Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text().split()
                groups[:] = [int(pid) for pid in children]
                return len(groups) == 2
            assert await_condition(children_ready), "worker/watchdog groups unavailable"
            assert worker in groups and all(os.getpgid(pid) == pid for pid in groups), "groups are not owned children"
            check(os.getpgid(child) == worker, f"{label} descendant belongs to the worker")
            if target == "pid":
                os.kill(process.pid, sig)
            else:
                send_group(process.pid, sig)
            stopped = await_condition(lambda: not any(members(group) for group in groups))
            status = process.wait(timeout=3)
            released = (case / "release").read_text().splitlines() if (case / "release").exists() else []
            log = (case / "runner.log").read_text()
            if not stopped or released != ["click 0x80"]:
                print(f"CAPTURELIFECYCLE TRACE {label}\n{log}", flush=True)
            check(stopped, f"{label} worker and watchdog descendants stop", f"remaining={[members(g) for g in groups]}")
            check(released == ["click 0x80"], f"{label} held button releases once", str(released))
            check(status == 128 + sig and f"ORIGINAL {sig.name[3:]}" in log,
                  f"{label} original caller trap runs after cleanup", f"exit={status}")
            check(sentinel.poll() is None, f"{label} unrelated process survives")
        except Exception as error:
            check(False, f"{label} probe completed", str(error))
        finally:
            for group in groups:
                send_group(group, signal.SIGKILL)
            stop(process)
            stop(sentinel)

normal = root / "normal-runner.sh"
normal.write_text('''set -u
case_root=$1
. "$(dirname "$0")/actual.sh"
coh_theme=normal-proof coh_budget_s=60 coh_teardown_s=1 coh_poll_s=0.02 coh_usec_per_s=1000000
coh_deadline=$((SECONDS + 60))
trap 'printf "ORIGINAL HUP\\n"' HUP
trap 'printf "ORIGINAL INT\\n"' INT
trap 'printf "ORIGINAL TERM\\n"' TERM
trap 'printf "ORIGINAL EXIT\\n"' EXIT
[[ "$2" != monitor ]] || set -m
before=$(trap -p HUP INT TERM EXIT)
before_options=$-
case "$3" in
    success) coh_bounded normal 1 true ;;
    failed) coh_bounded normal 1 bash -c 'exit 7' ;;
    timeout) coh_bounded normal 1 command sleep 60 ;;
esac
status=$?
[[ "$(trap -p HUP INT TERM EXIT)" == "$before" && "$-" == "$before_options" ]] || exit 9
for signal in HUP INT TERM; do kill -"$signal" "$BASHPID"; done
printf 'RETURN %s RESTORED\\n' "$status"
''')
for monitor in ("plain", "monitor"):
    for kind, expected in (("success", 0), ("failed", 7), ("timeout", 124)):
        case = root / f"normal-{monitor}-{kind}"
        case.mkdir()
        (case / marker).touch()
        process = launch(normal, case, monitor, kind)
        try:
            status = process.wait(timeout=5)
            log = (case / "runner.log").read_text()
            check(status == 0 and f"RETURN {expected} RESTORED" in log and
                  all(f"ORIGINAL {name}" in log for name in ("HUP", "INT", "TERM", "EXIT")),
                  f"normal/{monitor}/{kind} retains status, traps and job control", f"exit={status}")
        except Exception as error:
            check(False, f"normal/{monitor}/{kind} probe completed", str(error))
        finally:
            stop(process)

trash_source = subprocess.run(["bash", "-c", '. "$1/tests/ui-trash.sh"; '
                               'declare -f trash_cleanup trash_private_pids trash_owned_pid', "bash", str(repo)],
                              capture_output=True, text=True, check=True).stdout
(root / "trash-actual.sh").write_text(trash_source)
trash_runner = root / "trash-runner.sh"
trash_runner.write_text('''set -u
trash_box=$1 SANDBOX_MARKER=$2 trash_bus_address=$3
export XDG_DATA_HOME="$trash_box/data"
trash_private_bus_id=stand-in trash_checks=0 trash_bus_pid=""
. "$(dirname "$0")/trash-actual.sh"
kill_flea() { : > "$trash_box/touched"; }
trash_cleanup 0
''')
for kind in ("renamed", "missing", "bad-bus"):
    case = root / f"trash-{kind}"
    case.mkdir()
    custom_marker = ".capture-owned-marker"
    (case / (custom_marker if kind != "missing" else marker)).touch()
    bus = f"unix:path={case}/bus"
    env = {**os.environ, "DBUS_SESSION_BUS_ADDRESS": bus, "XDG_DATA_HOME": str(case / "data")}
    private = subprocess.Popen(["sleep", "60"], env=env, start_new_session=True)
    sentinel = subprocess.Popen(["sleep", "60"], env={**env, "XDG_DATA_HOME": str(case / "other-data")},
                                start_new_session=True)
    process = launch(trash_runner, case, custom_marker, bus if kind != "bad-bus" else bus + "-other")
    try:
        status = process.wait(timeout=5)
        accepted = kind == "renamed"
        check(status == (0 if accepted else 1), f"Trash/{kind} marker and bus guard", f"exit={status}")
        check((case / "touched").exists() == accepted, f"Trash/{kind} refuses before candidate cleanup")
        check(running(private.pid) != accepted, f"Trash/{kind} only accepted teardown stops its private process")
        check(sentinel.poll() is None, f"Trash/{kind} unrelated process survives")
    except Exception as error:
        check(False, f"Trash/{kind} probe completed", str(error))
    finally:
        stop(process)
        stop(private)
        stop(sentinel)

print(f"CAPTURELIFECYCLE DONE checks={checks} failed={failed}")
sys.exit(bool(failed))
