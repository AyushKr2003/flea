# Quickshell binds its IPC socket under XDG_RUNTIME_DIR, and a unix socket path has a fixed byte limit.
gvfsbridge_runtime_fits() {
    # sun_path holds 108 bytes with its NUL, so a socket path holds 107.
    local socket sun_path_max=107
    # Sample input: /tmp/flea-ui-run.ZyXqhjfz/gvfsbridge-rt; instance ids have run to 11 characters, so the sample id has 16.
    for socket in "$1/quickshell/by-id/0123456789abcdef/ipc.sock" "$1/${WAYLAND_DISPLAY:-wayland-1}"; do
        (( ${#socket} <= sun_path_max )) || fail "gvfsbridge: the socket path $socket is ${#socket} bytes, past the $sun_path_max a unix socket path holds, so the runtime directory needs a shorter root"
    done
}

# Only Flea takes the fixture's HOME, runtime dir and bridge stub, so kill_flea, hyprctl and omarchy-drive keep the operator's.
gvfsbridge_launch() {
    local dir="$1" fixture_home="$2" runtime="$3" fuse="$4"
    local -a flea_launch_wrap=(env "HOME=$fixture_home" "XDG_RUNTIME_DIR=$runtime" "PATH=$dir/bin:$PATH" "FLEA_GVFS_FUSE=$fuse")
    launch "$dir"
}

# The GVFS bridge's Starting and failure lines, staged through the FLEA_GVFS_FUSE seam; runs only by name (ui:gvfsbridge).
case_gvfsbridge() {
    local dir="$fixture_root/gvfsbridge"
    sandbox_scratch "$dir"
    mkdir -p "$dir/bin"
    : > "$dir/one.txt"
    local fixture_home="$fixture_root/gvfsbridge-home"
    fixture_home_make "$fixture_home"
    local state="$fixture_root/gvfsbridge-state"
    # Under the run root, whose /tmp name is short enough for Quickshell's IPC socket path.
    local runtime="$run_root/gvfsbridge-rt"
    mkdir -m 700 "$runtime" || fail "gvfsbridge: cannot create the runtime directory $runtime"
    : > "$runtime/.flea-test-sandbox"
    gvfsbridge_runtime_fits "$runtime"
    mkdir "$runtime/gvfs"
    local leaf_slow="smb-share:server=bridge-slow.test,share=data"
    local leaf_fail="smb-share:server=bridge-fail.test,share=data"

    # Every runtime entry but gvfs is linked through, so the sockets resolve and the bridge dir starts unserved.
    local real_runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if [[ -d "$real_runtime" ]]; then
        # Quickshell registers the instance under the runtime dir, so the restored client only sees it through this link; a directory made here goes again at exit.
        [[ -d "$real_runtime/quickshell" ]] || trap "rmdir -- ${real_runtime@Q}/quickshell 2>/dev/null || true" EXIT
        mkdir -p "$real_runtime/quickshell"
        local entry base
        shopt -s nullglob dotglob
        for entry in "$real_runtime"/*; do
            base="${entry##*/}"
            [[ "$base" == . || "$base" == .. || "$base" == gvfs ]] && continue
            ln -s "$entry" "$runtime/$base"
        done
        shopt -u nullglob dotglob
    fi

    # Empty listing, instant mount claim and info under the sandboxed bridge dir; trash keeps the real gio.
    cat > "$dir/bin/gio" <<EOS
#!/bin/sh
case "\$*" in
"info --attributes=trash::item-count trash:///"|"monitor --dir=trash:///") exec /usr/bin/gio "\$@" ;;
esac
case "\$1 \${2:-}" in
"mount -li") exit 0 ;;
"mount --anonymous") printf '%s\n' "\$*" >> "$dir/mount-calls" ;;
"info smb://bridge-slow.test/data") printf 'local path: %s\n' "$runtime/gvfs/$leaf_slow" ;;
"info smb://bridge-fail.test/data") printf 'local path: %s\n' "$runtime/gvfs/$leaf_fail" ;;
*) exit 0 ;;
esac
EOS
    chmod +x "$dir/bin/gio"
    : > "$dir/mount-calls"
    # Sample input: "<fusebin> <bridgedir> -f"; serves the leaf only after the 250 ms Starting line stands.
    cat > "$dir/bin/flea-gvfs-fuse-slow" <<EOS
#!/bin/sh
sleep 2
mkdir -p "\$1/$leaf_slow"
printf 'served\n' > "\$1/$leaf_slow/alpha.txt"
EOS
    chmod +x "$dir/bin/flea-gvfs-fuse-slow"
    # The failing bridge: serves nothing, so the whole-ensure 15 s deadline fails the wait.
    cat > "$dir/bin/flea-gvfs-fuse-fail" <<EOS
#!/bin/sh
exit 1
EOS
    chmod +x "$dir/bin/flea-gvfs-fuse-fail"

    seed_ui_state "$state" '{"view":"list","keys":"default","places":{"favourites":[{"label":"Bridge slow","path":"smb://bridge-slow.test/data"},{"label":"Bridge fail","path":"smb://bridge-fail.test/data"}]}}'
    gvfsbridge_launch "$dir" "$fixture_home" "$runtime" "$dir/bin/flea-gvfs-fuse-slow"
    wait_listing 3
    wait_rail_label "Bridge slow"

    local slow_index
    slow_index=$(ipc railEntries | jq -r 'map(.label) | index("Bridge slow")')
    [[ "$slow_index" != null ]] || fail "gvfsbridge: no rail row labelled Bridge slow"
    click_rail_row "$slow_index" left
    local seen_sticky=""
    for _attempt in $(seq 1 200); do
        seen_sticky=$(ipc stickyMessage)
        [[ "$seen_sticky" == "Opening Bridge slow" ]] && break
        sleep 0.05
    done
    [[ "$seen_sticky" == "Opening Bridge slow" ]] \
        || fail "gvfsbridge: the Starting line never stood, sticky says $seen_sticky"
    [[ "$(ipc statusBusy)" == "true" ]] || fail "gvfsbridge: the busy mark did not walk while the Starting line stood"
    shot gvfsbridge-starting
    wait_path "$runtime/gvfs/$leaf_slow"
    printf 'GVFSBRIDGE slow=started-opened\n'

    # The fail flight swaps only the fuse stub.
    gvfsbridge_launch "$dir" "$fixture_home" "$runtime" "$dir/bin/flea-gvfs-fuse-fail"
    wait_listing 3
    wait_rail_label "Bridge fail"
    local fail_index
    fail_index=$(ipc railEntries | jq -r 'map(.label) | index("Bridge fail")')
    [[ "$fail_index" != null ]] || fail "gvfsbridge: no rail row labelled Bridge fail"
    click_rail_row "$fail_index" left
    wait_message "Bridge fail could not be opened because a system service did not start · waiting for the folder timed out"
    [[ "$(ipc statusError)" == "true" ]] || fail "gvfsbridge: the failure line is not in the error role"
    [[ "$(ipc statusBusy)" == "false" ]] || fail "gvfsbridge: the busy mark still walks after the bridge failed"
    shot gvfsbridge-failed
    printf 'GVFSBRIDGE fail=error-line\n'

    kill_flea
    sandbox_remove "$fixture_home"
    # The runtime dir holds links into the operator's, and rm does not follow them.
    [[ "$runtime" == /?* && "$runtime" == "$run_root"/?* && -f "$runtime/.flea-test-sandbox" && -f "$run_root/.flea-test-sandbox" ]] \
        || fail "gvfsbridge: $runtime is not a marked directory inside the run root, so it stays"
    rm -rf -- "$runtime"
}
