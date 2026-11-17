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
# Usage: x11.sh status                 x11=missing|stopped|running, wm=NAME|none|missing,
#                                      switch=yes|no, desktop=missing|ready|running,
#                                      audio=missing|bridge-off|ready, firefox=installed|missing
#        x11.sh start                  mount, start the server (+ a window manager)
#        x11.sh stop                   stop the server (umount.sh does it too)
#        x11.sh apps [USER]            ID|NAME|ICON for each GUI .desktop entry
#        x11.sh icons [USER]           ID|BASE64 of each entry's PNG icon (if any)
#        x11.sh run USER ID            start, then open the entry ID as USER; if it already
#                                      has a window, bring that window to the front
#        x11.sh windows [USER]         WINDOW|ID|TITLE of each open window (ID: its entry)
#        x11.sh focus|close WINDOW     bring a window to the front / ask it to close
#        x11.sh desktop USER           the XFCE desktop session (replaces the app mode WM)
#        x11.sh setup [desktop]        install the window tools, or the desktop (apt)
#        x11.sh mozilla                add Mozilla's APT repository (for Firefox)
#        x11.sh firefox                mozilla, then apt install firefox
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

# Processes running Ubuntu's /usr/bin/NAME.
pids_of() { # NAME
    # shellcheck disable=SC2012 # symlink targets of /proc/*/exe
    ls -l /proc/[0-9]*/exe 2>/dev/null | bb awk -v n="$1" -v r="$R" '
        $(NF - 1) == "->" && ($NF == r "/usr/bin/" n || $NF == "/usr/bin/" n) { split($(NF - 2), a, "/"); print a[3] }'
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
        # A session bus per user (no systemd/logind here): GNOME/KDE apps need one,
        # and single-instance apps use it to reopen their window.
        echo 'if [ -n "${XDG_RUNTIME_DIR:-}" ] && command -v dbus-daemon >/dev/null; then'
        echo '    _b="$XDG_RUNTIME_DIR/bus"'
        echo '    if ! kill -0 "$(cat "$_b.pid" 2>/dev/null)" 2>/dev/null; then'
        echo '        rm -f "$_b"'
        echo '        dbus-daemon --session --address="unix:path=$_b" --fork --print-pid >"$_b.pid" 2>/dev/null'
        echo '    fi'
        echo '    export DBUS_SESSION_BUS_ADDRESS="unix:path=$_b"'
        echo 'fi'
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

start() { # [USER [nowm]]
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
    [ "${2:-}" = nowm ] || start_wm "${1:-${DEFAULT_USER:-root}}"
}

# A command against the X server, as root inside Ubuntu (a running server means
# start() mounted Ubuntu).
xrun() {
    if ! running || [ ! -e "$R/proc/self" ]; then return 1; fi
    bb chroot "$R" /usr/bin/env -i DISPLAY=:0 PATH=/usr/bin:/bin HOME=/root "$@" 2>/dev/null
}

# Open windows (wmctrl, EWMH; matchbox and xfwm4 both support it), each matched to
# the desktop entry it belongs to: by StartupWMClass, entry id, the Exec program or
# the id's last part, against WM_CLASS (wmctrl prints "instance.class"). Panels and
# the desktop itself (sticky, desktop -1) are left out.
windows() { # USER -> WINDOW|ID|TITLE
    [ -x "$R/usr/bin/wmctrl" ] || return 0
    _wl=$(xrun wmctrl -l -x) || return 0
    [ -n "$_wl" ] || return 0
    { entries "$1"; echo '#windows'; printf '%s\n' "$_wl"; } | bb awk '
        function m(cls, s) {
            if (length(s) < 3) return 0
            if (cls == s || index(cls, s ".") == 1) return 1
            return length(cls) > length(s) && substr(cls, length(cls) - length(s)) == "." s
        }
        $0 == "#windows" { w = 1; next }
        !w {
            split($0, f, "|"); n++; eid[n] = f[1]
            c[n, 1] = tolower(f[4]); c[n, 2] = tolower(f[1])
            ex = $0; for (i = 0; i < 5; i++) ex = substr(ex, index(ex, "|") + 1)
            split(ex, a, " "); x = a[1]; sub(/.*\//, "", x)
            if (x ~ /^(env|sh|bash|python3?|java|flatpak)$/ || x ~ /=/) x = ""
            c[n, 3] = tolower(x)
            l = f[1]; sub(/.*\./, "", l); c[n, 4] = tolower(l)
            next
        }
        {
            split($0, f, " ")
            if (f[2] == "-1" || f[1] !~ /^0x[0-9a-f]+$/) next
            cls = tolower(f[3]); t = $0
            for (i = 0; i < 4; i++) sub(/^[^ ]+ +/, "", t)
            gsub(/\|/, "/", t)
            app = ""
            for (k = 1; k <= 4 && app == ""; k++)
                for (i = 1; i <= n; i++) if (m(cls, c[i, k])) { app = eid[i]; break }
            print f[1] "|" app "|" t
        }'
}

window_cmd() { # -a|-c WINDOW
    case "$2" in 0x*) ;; *) ubu_die "invalid window: $2" ;; esac
    case "${2#0x}" in '' | *[!0-9a-fA-F]*) ubu_die "invalid window: $2" ;; esac
    [ -x "$R/usr/bin/wmctrl" ] || ubu_die "wmctrl is missing in Ubuntu: x11.sh setup"
    xrun wmctrl -i "$1" "$2" || ubu_die "no window $2"
}

# Desktop mode: an XFCE session (docs/GUI.md: XFCE over LXQt). It takes over from the
# app mode's matchbox; the windows already open stay open.
desktop_state() {
    if [ -n "$(pids_of xfce4-session)" ]; then
        echo running
    elif [ -x "$R/usr/bin/startxfce4" ]; then
        echo ready
    else
        echo missing
    fi
}

desktop() { # USER
    user_ok "$1"
    [ -x "$R/usr/bin/startxfce4" ] || ubu_die "the desktop is not installed (x11.sh setup desktop)"
    start "$1" nowm
    if [ "$(desktop_state)" = running ]; then
        ubu_log "the desktop is running"
        return 0
    fi
    _p=$(pids_of "$WM")
    # shellcheck disable=SC2086 # a list of pids
    [ -z "$_p" ] || kill $_p 2>/dev/null
    start_audio "$1"
    as_user_bg "$1" startxfce4 || ubu_die "could not start the desktop"
    ubu_log "desktop started as $1"
}

# Firefox: Ubuntu's firefox deb only installs the snap (blocked by setup.sh's
# 80uburoot-no-snap), so it comes from Mozilla's own APT repository, added only when
# the user asks for it. Key: https://packages.mozilla.org/apt/repo-signing-key.gpg,
# fingerprint 35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3 as Mozilla publishes it (checked
# 2026-11-16; it has no expiry). Its Packages lists arm64 and amd64.
MOZ_KEY=etc/apt/keyrings/packages.mozilla.org.asc
MOZ_SRC=etc/apt/sources.list.d/mozilla.sources
MOZ_PIN=etc/apt/preferences.d/80uburoot-mozilla

safe_dir() { # DIR inside the rootfs, resolving to itself (no symlink out of it)
    mkdir -p "$R/$1" || return 1
    _rp=$(readlink -f "$R/$1") || return 1
    [ "$_rp" = "$(readlink -f "$R")/$1" ]
}

put() { # FILE (stdin -> $R/FILE, root 0644)
    cat >"$R/$1.new" && chown 0:0 "$R/$1.new" && chmod 644 "$R/$1.new" && mv -f "$R/$1.new" "$R/$1"
}

mozilla() {
    ubu_rootfs_installed || ubu_die "Ubuntu is not installed"
    "$UBU_BIN_DIR/mount.sh" >/dev/null 2>&1 || ubu_die "mount.sh failed"
    # HTTPS needs the CA list, which Ubuntu Base doesn't have.
    if [ ! -f "$R/etc/ssl/certs/ca-certificates.crt" ]; then
        "$UBU_BIN_DIR/enter.sh" root "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates" ||
            ubu_die "could not install ca-certificates"
    fi
    for _d in etc/apt/keyrings etc/apt/sources.list.d etc/apt/preferences.d; do
        safe_dir "$_d" || ubu_die "unsafe directory /$_d in Ubuntu"
    done
    put "$MOZ_KEY" <<'EOF' || ubu_die "cannot write /$MOZ_KEY"
-----BEGIN PGP PUBLIC KEY BLOCK-----

xsBNBGCRt7MBCADkYJHHQQoL6tKrW/LbmfR9ljz7ib2aWno4JO3VKQvLwjyUMPpq
/SXXMOnx8jXwgWizpPxQYDRJ0SQXS9ULJ1hXRL/OgMnZAYvYDeV2jBnKsAIEdiG/
e1qm8P4W9qpWJc+hNq7FOT13RzGWRx57SdLWSXo0KeY38r9lvjjOmT/cuOcmjwlD
T9XYf/RSO+yJ/AsyMdAr+ZbDeQUd9HYJiPdI04lGaGM02MjDMnx+monc+y54t+Z+
ry1WtQdzoQt9dHlIPlV1tR+xV5DHHsejCZxu9TWzzSlL5wfBBeEz7R/OIzivGJpW
QdJzd+2QDXSRg9q2XYWP5ZVtSgjVVJjNlb6ZABEBAAHNVEFydGlmYWN0IFJlZ2lz
dHJ5IFJlcG9zaXRvcnkgU2lnbmVyIDxhcnRpZmFjdC1yZWdpc3RyeS1yZXBvc2l0
b3J5LXNpZ25lckBnb29nbGUuY29tPsLAjgQTAQoAOBYhBDW6oLM+nrOW9ZyoOMC6
XObcYxWjBQJgkbezAhsDBQsJCAcCBhUKCQgLAgQWAgMBAh4BAheAAAoJEMC6XObc
YxWj+igIAMFh6DrAYMeq9sbZ1ZG6oAMrinUheGQbEqe76nIDQNsZnhDwZ2wWqgVC
7DgOMqlhQmOmzm7M6Nzmq2dvPwq3xC2OeI9fQyzjT72deBTzLP7PJok9PJFOMdLf
ILSsUnmMsheQt4DUO0jYAX2KUuWOIXXJaZ319QyoRNBPYa5qz7qXS7wHLOY89IDq
fHt6Aud8ER5zhyOyhytcYMeaGC1g1IKWmgewnhEq02FantMJGlmmFi2eA0EPD02G
C3742QGqRxLwjWsm5/TpyuU24EYKRGCRm7QdVIo3ugFSetKrn0byOxWGBvtu4fH8
XWvZkRT+u+yzH1s5yFYBqc2JTrrJvRU=
=QnvN
-----END PGP PUBLIC KEY BLOCK-----
EOF
    put "$MOZ_SRC" <<EOF || ubu_die "cannot write /$MOZ_SRC"
# Added by UbuRoot (x11.sh mozilla) at the user's request: Firefox from Mozilla.
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /$MOZ_KEY
EOF
    # Only Mozilla's own packages: the repository can't replace anything else.
    put "$MOZ_PIN" <<'EOF' || ubu_die "cannot write /$MOZ_PIN"
Explanation: UbuRoot: Firefox from Mozilla's repository (x11.sh mozilla)
Package: firefox*
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
    "$UBU_BIN_DIR/enter.sh" root "apt-get update" || ubu_die "apt-get update failed"
    ubu_log "Mozilla's repository added"
}

firefox_state() {
    if [ -e "$R/usr/lib/firefox/firefox" ]; then echo installed; else echo missing; fi
}

firefox() {
    mozilla
    "$UBU_BIN_DIR/enter.sh" root "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends firefox" ||
        ubu_die "could not install Firefox"
}

# Sound: with PulseAudio installed in Ubuntu and the app's audio bridge on (Hardware >
# Bridges, HARDWARE_ACCESS), the user's PulseAudio plays on the phone through
# `uburoot-audio pulse` (a pipe sink). Best effort: nothing happens otherwise.
audio_state() {
    if [ ! -x "$R/usr/bin/pulseaudio" ] || [ ! -x "$R/usr/bin/pactl" ]; then
        echo missing
    elif [ ! -e "$R/run/uburoot-bridge/audio" ] || [ ! -x "$R/usr/local/bin/uburoot-audio" ]; then
        echo bridge-off
    else
        echo ready
    fi
}

start_audio() { # USER
    [ "$(audio_state)" = ready ] || return 0
    # shellcheck disable=SC2016 # expanded by the user's shell
    as_user_bg "$1" 'sh -c "pulseaudio --check || pulseaudio --start --exit-idle-time=-1; sleep 1; pactl list short modules | grep -q module-pipe-sink || uburoot-audio pulse"'
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

# Desktop entries of type Application, not hidden, not terminal programs, not limited
# to some desktop (OnlyShowIn, e.g. XFCE's settings dialogs: this list isn't one); the
# user's ~/.local/share/applications overrides the system's (same id).
entries() { # USER -> ID|NAME|ICON|WMCLASS|FILE|EXEC (Exec last: it may hold a "|")
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
            if (id != "" && type == "Application" && nod != "true" && hid != "true" && term != "true" && only == "" && exec != "" && name != "")
                e[id] = id "|" name "|" icon "|" wmc "|" file "|" exec
            else if (id != "" && (nod == "true" || hid == "true" || only != "")) delete e[id]
        }
        FNR == 1 {
            if (NR > 1) flush()
            file = FILENAME; id = FILENAME; sub(/.*\//, "", id); sub(/\.desktop$/, "", id)
            sec = ""; type = name = icon = exec = nod = hid = term = wmc = only = ""
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
        /^OnlyShowIn=/ { only = substr($0, 12) }
        /^StartupWMClass=/ { wmc = substr($0, 16); gsub(/\|/, "", wmc) }
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
    _x=$(printf '%s\n' "$_e" | bb awk '{ for (i = 0; i < 5; i++) $0 = substr($0, index($0, "|") + 1); print }' |
        bb sed -e 's/%[fFuUdDnNickvm]//g' -e 's/%%/%/g')
    # Like an Android app: if it already has a window, show that one.
    if running; then
        _w=$(windows "$1" | bb awk -F'|' -v id="$2" '$2 == id { w = $1 } END { if (w != "") print w }')
        if [ -n "$_w" ] && xrun wmctrl -i -a "$_w"; then
            ubu_log "switched to $2"
            return 0
        fi
    fi
    start "$1"
    start_audio "$1"
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
    if [ -x "$R/usr/bin/wmctrl" ]; then echo "switch=yes"; else echo "switch=no"; fi
    echo "desktop=$(desktop_state)"
    echo "audio=$(audio_state)"
    echo "firefox=$(firefox_state)"
}

setup() { # [desktop]
    case "${1:-}" in
        '') _p="$WM xkb-data wmctrl" ;;
        desktop) _p="xfce4 xfce4-terminal xkb-data wmctrl" ;;
        *) ubu_die "usage: x11.sh setup [desktop]" ;;
    esac
    "$UBU_BIN_DIR/mount.sh" >/dev/null 2>&1 || ubu_die "mount.sh failed"
    "$UBU_BIN_DIR/enter.sh" root "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $_p"
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
    windows)
        _u=${2:-${DEFAULT_USER:-root}}
        user_ok "$_u"
        windows "$_u"
        ;;
    focus) window_cmd -a "${2:-}" ;;
    close) window_cmd -c "${2:-}" ;;
    desktop) desktop "${2:-${DEFAULT_USER:-root}}" ;;
    setup) setup "${2:-}" ;;
    mozilla) mozilla ;;
    firefox) firefox ;;
    *) ubu_die "usage: x11.sh status|start|stop|apps [USER]|icons [USER]|run USER ID|windows [USER]|focus|close WINDOW|desktop USER|setup [desktop]|mozilla|firefox" ;;
esac
