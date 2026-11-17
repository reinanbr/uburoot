#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Linux GUI apps: the X server and the app list (docs/GUI.md).
#
# The X server is Termux:X11's (com.termux.x11, a companion app): its CmdEntryPoint
# runs here as root through app_process, with TMPDIR at the rootfs's /tmp, so the
# socket is /tmp/.X11-unix/X0 inside Ubuntu (DISPLAY=:0); the Termux:X11 activity
# shows the screen. This is the chroot recipe of its README ("Using with chroot
# environment").
#
# Usage: x11.sh status                 x11=missing|stopped|running, wm=NAME|none|missing
#        x11.sh start                  mount, start the server (+ a window manager)
#        x11.sh stop                   stop the server (umount.sh does it too)
#        x11.sh apps [USER]            ID|NAME|ICON for each GUI .desktop entry
#        x11.sh icons [USER]           ID|BASE64 of each entry's PNG icon (if any)
#        x11.sh run USER ID            start, then open the entry ID as USER
#        x11.sh setup                  install the window manager (apt)
set -u
UBU_BIN_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$UBU_BIN_DIR/common.sh"

ubu_require_root
ubu_init
ubu_load_config

R=$ROOTFS
PKG=com.termux.x11
PIDF="$UBU_STATE/x11.pid"
SOCK="$R/tmp/.X11-unix/X0"
# Window managers we recognise as already running; matchbox opens every window
# full screen, as Android apps are, and is the one setup installs.
WMS="matchbox-window-manager openbox xfwm4 icewm fluxbox twm i3 awesome kwin_x11 metacity marco mutter lxqt-session xfce4-session"
WM=matchbox-window-manager

apk() {
    if [ -n "${UBU_X11_APK:-}" ]; then
        printf '%s\n' "$UBU_X11_APK"
        return
    fi
    /system/bin/pm path "$PKG" 2>/dev/null | bb sed -n 's/^package://p' | bb grep 'base\.apk$' | head -n 1
}

running() {
    _p=$(cat "$PIDF" 2>/dev/null) || return 1
    [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && bb grep -q uburoot-x11 "/proc/$_p/cmdline" 2>/dev/null
}

# The running window manager's name, if any (processes inside the rootfs).
wm_running() {
    # shellcheck disable=SC2012 # symlink targets of /proc/*/exe
    ls -l /proc/[0-9]*/exe 2>/dev/null | bb awk -v names="$WMS" '
        BEGIN { n = split(names, w, " ") }
        $(NF - 1) == "->" { for (i = 1; i <= n; i++) if ($NF ~ ("/usr/bin/" w[i] "$")) { print w[i]; exit } }'
}

user_ok() {
    case "$1" in
        root) return 0 ;;
        [a-z_]*) ;;
        *) ubu_die "invalid user name: $1" ;;
    esac
    case "$1" in *[!a-z0-9_-]*) ubu_die "invalid user name: $1" ;; esac
    bb awk -F: -v u="$1" '$1 == u { f = 1 } END { exit !f }' "$R/etc/passwd" || ubu_die "no user $1 in Ubuntu"
}

# FILE is inside the rootfs once every symlink is resolved (a user's symlink could
# otherwise make root read Android's files).
inside() {
    _rp=$(readlink -f "$1" 2>/dev/null) || return 1
    case "$_rp" in "$R"/*) return 0 ;; *) return 1 ;; esac
}

home_of() { bb awk -F: -v u="$1" '$1 == u { print $6; exit }' "$R/etc/passwd"; }

# Run CMD as USER inside Ubuntu, detached: nothing of ours stays attached to it.
as_user_bg() { # USER CMD
    # Root-owned and 0755: the user reads the launcher, nobody else can plant one.
    _f="$R/run/uburoot-x11/run.$$"
    if ! { mkdir -p "$R/run/uburoot-x11" && chown 0:0 "$R/run/uburoot-x11" && chmod 755 "$R/run/uburoot-x11"; }; then
        return 1
    fi
    {
        echo 'cd "$HOME" 2>/dev/null || cd /'
        echo 'export DISPLAY=:0'
        echo 'mkdir -p "$HOME/.cache" 2>/dev/null'
        printf '( setsid %s </dev/null >>"$HOME/.cache/uburoot-x11.log" 2>&1 & )\n' "$2"
    } >"$_f" || return 1
    chmod 644 "$_f"
    "$UBU_BIN_DIR/enter.sh" "$1" "sh /run/uburoot-x11/run.$$" </dev/null >/dev/null 2>&1
    _rc=$?
    rm -f "$_f"
    return "$_rc"
}

# First start only: a resolution scaled to the screen's density (X apps assume 96 dpi;
# Android's baseline is 160) and touch as a pointer that clicks where you tap.
# Later the user's own choices in Termux:X11's preferences are left alone.
first_prefs() {
    [ -f "$UBU_STATE/x11.prefs" ] && return 0
    _d=$(/system/bin/wm density 2>/dev/null | bb awk '{ v = $NF } END { print v + 0 }')
    [ "${_d:-0}" -gt 0 ] || _d=320
    _s=$(((_d * 100 / 240 + 5) / 10 * 10))
    [ "$_s" -lt 100 ] && _s=100
    [ "$_s" -gt 300 ] && _s=300
    # touchMode 2 = "Simulated touchscreen" (values in its res/values/arrays.xml).
    /system/bin/am broadcast -a com.termux.x11.CHANGE_PREFERENCE -p "$PKG" \
        -e displayResolutionMode scaled -e displayScale "$_s" -e touchMode 2 >/dev/null 2>&1 &&
        mkdir -p "$UBU_STATE" && : >"$UBU_STATE/x11.prefs"
}

start_wm() { # USER
    [ -n "$(wm_running)" ] && return 0
    [ -x "$R/usr/bin/$WM" ] || return 0
    as_user_bg "$1" "$WM -use_titlebar no"
}

start() { # [USER]
    ubu_rootfs_installed || ubu_die "Ubuntu is not installed"
    _apk=$(apk)
    [ -n "$_apk" ] || ubu_die "Termux:X11 is not installed (https://github.com/termux/termux-x11/releases)"
    "$UBU_BIN_DIR/mount.sh" >/dev/null 2>&1 || ubu_die "mount.sh failed"
    [ -d "$R/usr/share/X11/xkb" ] || ubu_die "xkb-data is missing in Ubuntu: sudo apt install xkb-data"
    # From now on, login shells get DISPLAY=:0 (the profile hook checks this file).
    mkdir -p "$R/etc/uburoot" && : >"$R/etc/uburoot/x11"
    if ! running; then
        first_prefs
        # An activity still attached to an earlier server keeps that surface: the new
        # server then fails eglCreateWindowSurface ("already connected") and the screen
        # freezes on the old frame (seen on the S9). Close it; it reconnects when opened.
        if [ -z "${UBU_X11_APK:-}" ]; then
            /system/bin/am broadcast -a com.termux.x11.ACTION_STOP -p "$PKG" >/dev/null 2>&1
        fi
        # A killed server leaves its lock and socket behind; it refuses to start then.
        rm -f "$R/tmp/.X0-lock" "$SOCK"
        mkdir -p "$UBU_STATE"
        (
            exec </dev/null >"$UBU_STATE/x11.log" 2>&1
            export TMPDIR="$R/tmp" XKB_CONFIG_ROOT="$R/usr/share/X11/xkb" CLASSPATH="$_apk"
            exec "${UBU_APP_PROCESS:-/system/bin/app_process}" / --nice-name=uburoot-x11 com.termux.x11.CmdEntryPoint :0
        ) &
        echo "$!" >"$PIDF"
        _i=0
        while [ ! -S "$SOCK" ] && [ "$_i" -lt 20 ]; do
            sleep 0.5
            _i=$((_i + 1))
        done
        [ -S "$SOCK" ] || ubu_die "the X server did not start (log: $UBU_STATE/x11.log)"
    fi
    start_wm "${1:-${DEFAULT_USER:-root}}"
}

stop() {
    _p=$(cat "$PIDF" 2>/dev/null)
    if running; then kill "$_p" 2>/dev/null; fi
    rm -f "$PIDF" "$R/tmp/.X0-lock" "$SOCK"
    if [ -z "${UBU_X11_APK:-}" ]; then
        /system/bin/am broadcast -a com.termux.x11.ACTION_STOP -p "$PKG" >/dev/null 2>&1
    fi
    return 0
}

# Desktop entries of type Application, not hidden, not terminal programs; the
# user's ~/.local/share/applications overrides the system's (same id).
entries() { # USER -> ID|NAME|ICON|EXEC|FILE
    _h=$(home_of "$1")
    _dirs="$R/usr/share/applications"
    [ -n "$_h" ] && _dirs="$_dirs $R$_h/.local/share/applications"
    set --
    for _d in $_dirs; do
        for _f in "$_d"/*.desktop; do
            if [ -f "$_f" ] && inside "$_f"; then set -- "$@" "$_f"; fi
        done
    done
    [ $# -gt 0 ] || return 0
    bb awk '
        function flush() {
            if (id != "" && type == "Application" && nod != "true" && hid != "true" && term != "true" && exec != "" && name != "")
                e[id] = id "|" name "|" icon "|" exec "|" file
            else if (id != "" && (nod == "true" || hid == "true")) delete e[id]
        }
        FNR == 1 {
            if (NR > 1) flush()
            file = FILENAME; id = FILENAME; sub(/.*\//, "", id); sub(/\.desktop$/, "", id)
            sec = ""; type = name = icon = exec = nod = hid = term = ""
        }
        /^\[/ { sec = $0; next }
        sec != "[Desktop Entry]" { next }
        /^Type=/ { type = substr($0, 6) }
        /^Name=/ { name = substr($0, 6); gsub(/\|/, "/", name) }
        /^Icon=/ { icon = substr($0, 6) }
        /^Exec=/ && exec == "" { exec = substr($0, 6) }
        /^NoDisplay=/ { nod = substr($0, 11) }
        /^Hidden=/ { hid = substr($0, 8) }
        /^Terminal=/ { term = substr($0, 10) }
        END { if (NR > 0) flush(); for (k in e) print e[k] }
    ' "$@" 2>/dev/null | bb grep -v '^$'
}

apps() { # USER
    entries "$1" | bb awk -F'|' '{ print $1 "|" $2 "|" $3 }' | sort -t'|' -k2,2f
}

# The PNG for an Icon= value, inside the rootfs only. SVG-only icons get none.
icon_file() {
    case "$1" in
        '') return 1 ;;
        /*.png)
            case "$1" in *..*) return 1 ;; esac
            [ -f "$R$1" ] && printf '%s\n' "$R$1"
            return
            ;;
        */* | *..*) return 1 ;;
    esac
    for _s in 48x48 64x64 96x96 128x128 32x32 256x256 512x512; do
        if [ -f "$R/usr/share/icons/hicolor/$_s/apps/$1.png" ]; then
            printf '%s\n' "$R/usr/share/icons/hicolor/$_s/apps/$1.png"
            return 0
        fi
    done
    if [ -f "$R/usr/share/pixmaps/$1.png" ]; then printf '%s\n' "$R/usr/share/pixmaps/$1.png"; fi
}

icons() { # USER
    entries "$1" | while IFS='|' read -r _id _n _icon _rest; do
        _f=$(icon_file "$_icon") || continue
        if [ -z "$_f" ] || ! inside "$_f"; then continue; fi
        # Skip big files: a launcher icon, not a picture.
        [ "$(bb stat -L -c %s "$_f" 2>/dev/null || echo 0)" -le 262144 ] || continue
        printf '%s|%s\n' "$_id" "$(bb base64 "$_f" | tr -d '\n')"
    done
}

run() { # USER ID
    user_ok "$1"
    case "$2" in '' | *[!A-Za-z0-9._+-]*) ubu_die "invalid application id: $2" ;; esac
    _e=$(entries "$1" | bb awk -F'|' -v id="$2" '$1 == id { print; exit }')
    [ -n "$_e" ] || ubu_die "no application $2"
    # Exec field codes (%f %U ...) are for files/URLs we don't pass; %% is a %.
    _x=$(printf '%s\n' "$_e" | bb awk -F'|' '{ print $4 }' | bb sed -e 's/%[fFuUdDnNickvm]//g' -e 's/%%/%/g')
    start "$1"
    as_user_bg "$1" "$_x" || ubu_die "could not start $2"
    ubu_log "started $2 as $1"
}

status() {
    if [ -z "$(apk)" ]; then
        echo "x11=missing"
    elif running; then
        echo "x11=running"
    else
        echo "x11=stopped"
    fi
    _w=$(wm_running)
    if [ -n "$_w" ]; then
        echo "wm=$_w"
    elif [ -x "$R/usr/bin/$WM" ]; then
        echo "wm=none"
    else
        echo "wm=missing"
    fi
}

setup() {
    "$UBU_BIN_DIR/mount.sh" >/dev/null 2>&1 || ubu_die "mount.sh failed"
    "$UBU_BIN_DIR/enter.sh" root "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $WM xkb-data"
}

case "${1:-}" in
    status) status ;;
    start) start ;;
    stop) stop ;;
    apps)
        _u=${2:-${DEFAULT_USER:-root}}
        user_ok "$_u"
        apps "$_u"
        ;;
    icons)
        _u=${2:-${DEFAULT_USER:-root}}
        user_ok "$_u"
        icons "$_u"
        ;;
    run)
        [ $# = 3 ] || ubu_die "usage: x11.sh run USER ID"
        run "$2" "$3"
        ;;
    setup) setup ;;
    *) ubu_die "usage: x11.sh status|start|stop|apps [USER]|icons [USER]|run USER ID|setup" ;;
esac
