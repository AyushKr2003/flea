#!/usr/bin/env bash
# Issue #257: kernel NFS/CIFS mounts gio lists as file:// become share rows when mountinfo
# names a network fstype there. Fake gio text and fake mountinfo into the real
# NetworkMounts.rebuild; the stub gio logs every call, so the run proves the listing classified
# from text alone, the open went straight to the path, and the unmount took the one release path.
set -u
. "$(dirname "$0")/../tools/flea-sandbox-guard"
cd "$(dirname "$0")/.." || exit 1

test_root="$FIXTURE_ROOT/flea-network-kernel-mounts-$$"
sandbox_make "$test_root"
cleanup() { sandbox_remove "$test_root"; }
trap cleanup EXIT

mkdir -p "$test_root/bin" "$test_root/home" "$test_root/config"
ln -s "$PWD/ui/NetworkMounts.qml" "$test_root/config/NetworkMounts.qml"
ln -s "$PWD/ui/MountListing.qml" "$test_root/config/MountListing.qml"
ln -s "$PWD/ui/NetworkPlaces.qml" "$test_root/config/NetworkPlaces.qml"
ln -s "$PWD/ui/GvfsBridge.qml" "$test_root/config/GvfsBridge.qml"
ln -s "$PWD/ui/js" "$test_root/config/js"
ln -s "$PWD/tests/network-kernel-mounts.qml" "$test_root/config/shell.qml"
gio_log="$test_root/gio.log"
fuse_log="$test_root/fuse.log"

cat > "$test_root/bin/gio" <<'EOS'
#!/bin/sh
echo "$*" >> "$FLEA_TEST_GIO_LOG"
case "$1 $2" in
  "mount -u") exit 0 ;;
  "mount -li") exit 0 ;;
esac
exit 64
EOS
chmod +x "$test_root/bin/gio"

cat > "$test_root/bin/fusermount3" <<'EOS'
#!/bin/sh
echo "$*" >> "$FLEA_TEST_FUSE_LOG"
exit 0
EOS
chmod +x "$test_root/bin/fusermount3"

output=$(env \
    FLEA_TEST_GIO_LOG="$gio_log" \
    FLEA_TEST_FUSE_LOG="$fuse_log" \
    HOME="$test_root/home" \
    PATH="$test_root/bin:/usr/bin:/bin" \
    QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic \
    QT_FORCE_STDERR_LOGGING=1 \
    timeout 15 qs -p "$test_root/config" 2>&1)

pass_count=$(printf '%s\n' "$output" | grep -c 'NETWORK_KERNEL_MOUNTS DONE checks=19')
fail_count=$(printf '%s\n' "$output" | grep -c 'NETWORK_KERNEL_MOUNTS FAIL')
if [ "$pass_count" -ne 1 ] || [ "$fail_count" -ne 0 ]; then
    printf 'FAIL kernel mounts did not list, open and unmount\n%s\n' "$output"
    exit 1
fi
# One gio call in the whole run, the cifs unmount itself, and one fusermount3 call, the
# rclone unmount: the listing classified from text alone and both opens went straight ahead.
calls=$(cat "$gio_log" 2>/dev/null || true)
if [ "$calls" != "mount -u file:///mnt/kmount-iso" ]; then
    printf 'FAIL gio heard more than the one unmount:\n%s\n%s\n' "$calls" "$output"
    exit 1
fi
fuse_calls=$(cat "$fuse_log" 2>/dev/null || true)
want_fuse="$(printf -- '-u /mnt/kmount-rclone\n-u %s/gdrive' "$test_root/home")"
if [ "$fuse_calls" != "$want_fuse" ]; then
    printf 'FAIL fusermount3 heard more than the one unmount:\n%s\n%s\n' "$fuse_calls" "$output"
    exit 1
fi

printf 'network-kernel-mounts: gio rows join mountinfo rows, open direct, unmount once\n'
