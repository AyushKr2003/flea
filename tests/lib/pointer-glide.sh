# Sourced by native captures: moves the pointer through ydotool's uinput device, because a compositor move gives Qt no pointer frame.
# Sample input: pointer_glide 640 360 (absolute layout pixels); answers 1 when the pointer cannot get within 2 px.
pointer_glide() {
    [[ $# -eq 2 && "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] || return 1
    local step x y
    for step in $(seq 1 32); do
        read -r x y < <(hyprctl cursorpos | tr -d ',')
        [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]] || return 1
        (( x >= $1 - 2 && x <= $1 + 2 && y >= $2 - 2 && y <= $2 + 2 )) && return 0
        # Half the gap per step, so libinput's acceleration cannot carry the pointer past the target.
        YDOTOOL_SOCKET="$XDG_RUNTIME_DIR/.ydotool_socket" ydotool mousemove -x "$((($1 - x) / 2))" -y "$((($2 - y) / 2))" >/dev/null 2>&1 || return 1
        sleep 0.05
    done
    return 1
}
