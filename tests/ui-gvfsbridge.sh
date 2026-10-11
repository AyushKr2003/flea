# The GVFS bridge's Starting and failure lines, staged through the FLEA_GVFS_FUSE seam; runs only by name (ui:gvfsbridge).
case_gvfsbridge() {
    local dir="$fixture_root/gvfsbridge"
    sandbox_scratch "$dir"
    mkdir -p "$dir/bin"
    : > "$dir/one.txt"
    local fixture_home="$fixture_root/gvfsbridge-home"
    fixture_home_make "$fixture_home"
    local state="$fixture_root/gvfsbridge-state"
    local runtime="$fixture_root/gvfsbridge-runtime"
    sandbox_scratch "$runtime"
    mkdir -p "$runtime/gvfs"
    local leaf_slow="smb-share:server=bridge-slow.test,share=data"
    local leaf_fail="smb-share:server=bridge-fail.test,share=data"

    # Every runtime entry but gvfs is linked through, so the sockets resolve and the bridge dir starts unserved.
    local real_runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if [[ -d "$real_runtime" ]]; then
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
mkdir -p "\$2/$leaf_slow"
printf 'served\n' > "\$2/$leaf_slow/alpha.txt"
EOS
    chmod +x "$dir/bin/flea-gvfs-fuse-slow"
    # The failing bridge: serves nothing, so the whole-ensure 15 s deadline fails the wait.
    cat > "$dir/bin/flea-gvfs-fuse-fail" <<EOS
#!/bin/sh
exit 1
EOS
    chmod +x "$dir/bin/flea-gvfs-fuse-fail"

    seed_ui_state "$state" '{"view":"list","keys":"default","places":{"favourites":[{"label":"Bridge slow","path":"smb://bridge-slow.test/data"},{"label":"Bridge fail","path":"smb://bridge-fail.test/data"}]}}'
    local real_home="$HOME" saved_path="$PATH"
    export PATH="$dir/bin:$PATH"
    export HOME="$fixture_home"
    export XDG_RUNTIME_DIR="$runtime"
    export YDOTOOL_SOCKET="$real_runtime/.ydotool_socket"
    export FLEA_GVFS_FUSE="$dir/bin/flea-gvfs-fuse-slow"
    launch "$dir"
    export HOME="$real_home"
    export XDG_RUNTIME_DIR="$real_runtime"
    wait_listing 1
    wait_rail_label "Bridge slow"

    local slow_index
    slow_index=$(ipc railEntries | jq -r 'map(.label) | index("Bridge slow")')
    [[ "$slow_index" != null ]] || fail "gvfsbridge: no rail row labelled Bridge slow"
    click_rail_row "$slow_index" left
    local seen_sticky=""
    for _attempt in $(seq 1 200); do
        seen_sticky=$(ipc stickyMessage)
        [[ "$seen_sticky" == "Starting the GVFS bridge for Bridge slow" ]] && break
        sleep 0.05
    done
    [[ "$seen_sticky" == "Starting the GVFS bridge for Bridge slow" ]] \
        || fail "gvfsbridge: the Starting line never stood, sticky says $seen_sticky"
    shot gvfsbridge-starting
    wait_path "$runtime/gvfs/$leaf_slow"
    printf 'GVFSBRIDGE slow=started-opened\n'

    # The fail flight swaps only the fuse stub, carried in by the launch below.
    export HOME="$fixture_home"
    export XDG_RUNTIME_DIR="$runtime"
    export FLEA_GVFS_FUSE="$dir/bin/flea-gvfs-fuse-fail"
    launch "$dir"
    export HOME="$real_home"
    export XDG_RUNTIME_DIR="$real_runtime"
    wait_listing 1
    wait_rail_label "Bridge fail"
    local fail_index
    fail_index=$(ipc railEntries | jq -r 'map(.label) | index("Bridge fail")')
    [[ "$fail_index" != null ]] || fail "gvfsbridge: no rail row labelled Bridge fail"
    click_rail_row "$fail_index" left
    wait_message "Bridge fail needs the GVFS bridge, and it would not start · waiting for the folder timed out"
    [[ "$(ipc statusError)" == "true" ]] || fail "gvfsbridge: the failure line is not in the error role"
    shot gvfsbridge-failed
    printf 'GVFSBRIDGE fail=error-line\n'

    unset FLEA_GVFS_FUSE
    export PATH="$saved_path"
    kill_flea
    sandbox_remove "$fixture_home"
}
