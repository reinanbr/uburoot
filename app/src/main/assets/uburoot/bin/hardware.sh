#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# uburoot-hw: the phone's hardware from Ubuntu, with every change to device state
# recorded in the same change log as uburoot-kernel (Stop all reverts both).
#
# The same file runs on both sides, like kernel.sh:
#   Android: /data/local/uburoot/bin/hardware.sh (the app, adb)
#   Ubuntu:  /usr/local/sbin/uburoot-hw (mount.sh installs it with HARDWARE_ACCESS=1)
#
# Usage: uburoot-hw [-y] COMMAND
#   list                       every class: route, nodes, who uses them
#   info CLASS                 nodes, owners, the route and its limits
#   status                     key=value summary (machine-readable, for the app)
#   grant CLASS USER           USER may use CLASS without root (group membership;
#                              serial/hidraw: also a permission rule for new devices)
#   revoke CLASS USER
#   takeover wifi              stop Android's Wi-Fi so Ubuntu can use wlan0
#   release wifi               give it back (Stop all does it too)
#   cpu                        CPU policies, governors, frequencies, online cores
#   cpu governor POLICY|all GOV
#   cpu min|max POLICY FREQ    a frequency from scaling_available_frequencies
#   cpu online CPU 0|1         never cpu0
#   wakelock on|off            keep the phone from suspending
#   set PATH VALUE             an LED (/sys/class/leds/NAME/brightness|trigger)
#   allow NODE                 a bus node (i2c, spi, gpiochip) for group uburoot-bus
#   apply                      apply the permission rules once (root)
#   watch                      apply them every 2 s (started by mount.sh / grant)
#   -y                         don't ask for confirmation (the app asks)
# Classes: gpu input uinput audio camera usb serial hidraw wifi bluetooth nfc
#          sensors leds power cpu thermal buses modem
#
# Safety floor (no option changes it): thermal trips, charger and battery settings
# and voltages are read-only; PMIC/charger/regulator bus nodes are refused; the
# modem is report-only.
set -u

_self=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
if [ -f "$_self/common.sh" ]; then
    MODE=android
    # shellcheck source=common.sh
    . "$_self/common.sh"
    ubu_detect_busybox
    ubu_load_config
    STATE=$UBU_STATE
    ACCESS=$HARDWARE_ACCESS
    RF=$ROOTFS
else
    MODE=ubuntu
    bb() { "$@"; }
    STATE=${UBU_STATE:-/run/uburoot/state}
    RF=""
fi
die() { printf 'uburoot-hw: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
_lib="$_self/changes.sh"
[ -f "$_lib" ] || _lib=/usr/local/lib/uburoot/changes.sh
[ -f "$_lib" ] || die "missing $_lib"
# shellcheck source=changes.sh
. "$_lib"
[ "$MODE" = ubuntu ] && ACCESS=$(ubuntu_access HARDWARE_ACCESS)
# Test-only: a fake /dev and /sys tree.
HW=${UBU_HW_ROOT:-}
RULES="$RF/etc/uburoot/hw-rules"
PIDFILE="$RF/run/uburoot/hw-watch.pid"

YES=0
if [ "${1:-}" = -y ]; then
    YES=1
    shift
fi

confirm() {
    [ "$YES" = 1 ] && return 0
    [ -t 0 ] || die "refusing without confirmation (no terminal); pass -y"
    printf '%s [y/N] ' "$1" >&2
    read -r _a || return 1
    case "$_a" in y | Y | yes | YES) return 0 ;; esac
    die "cancelled"
}
need_root() { [ "$(id -u)" = 0 ] || [ "${UBU_ALLOW_NONROOT:-0}" = 1 ] || die "must run as root (sudo uburoot-hw ...)"; }
need_access() {
    need_root
    [ "$ACCESS" = 1 ] && return 0
    if [ "$MODE" = ubuntu ]; then
        die "hardware access is off. Turn on Settings > Hardware access in the app, then Repair mounts."
    fi
    die "hardware access is off (HARDWARE_ACCESS=0 in uburoot.conf)"
}
# Run a command inside Ubuntu (usermod, groupadd...).
in_ubuntu() {
    if [ "$MODE" = android ]; then
        bb chroot "$RF" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin "$@"
    else
        "$@"
    fi
}

# --- Classes --------------------------------------------------------------------------
# class_def CLASS sets: NODES (globs), GROUP (name:gid, empty = root only),
# RULE (1 = UbuRoot sets group+mode on new nodes), ROUTE, NOTE.
CLASSES="gpu input uinput audio camera usb serial hidraw wifi bluetooth nfc sensors leds power cpu thermal buses modem"
class_def() {
    NODES=""
    GROUP=""
    RULE=0
    ROUTE=direct
    NOTE=""
    case "$1" in
        gpu)
            NODES="/dev/kgsl-3d0 /dev/dri/* /dev/graphics/fb*"
            GROUP=aid_graphics:1003
            NOTE="Adreno: /dev/kgsl-3d0 (Mesa freedreno/Turnip); others: /dev/dri, /dev/mali0. Used by Linux GUI apps (Phase 4)."
            ;;
        input)
            NODES="/dev/input/event*"
            GROUP=aid_input:1004
            NOTE="evdev: touchscreen, keys, sensors-as-input, USB/Bluetooth keyboards and mice. Android reads the same events."
            ;;
        uinput)
            NODES="/dev/uinput /dev/uhid"
            GROUP=aid_uhid:3011
            NOTE="Virtual keyboards, mice and gamepads. Their events reach Android too: a grantee can type into the phone."
            ;;
        audio)
            NODES="/dev/snd/*"
            GROUP=aid_audio:1005
            ROUTE=bridge
            NOTE="audioserver and the audio HAL hold the sound card; the bridge to Android audio (PulseAudio/PipeWire) and the ALSA takeover are Phase 3b. USB audio cards appear here too."
            ;;
        camera)
            NODES="/dev/video* /dev/media* /dev/v4l-subdev*"
            GROUP=aid_camera:1006
            ROUTE=bridge
            NOTE="Vendor camera drivers need the camera HAL: plain V4L2 tools can't drive them. The Camera2 bridge is Phase 3b."
            ;;
        usb)
            NODES="/dev/bus/usb/*/*"
            GROUP=aid_usb:1018
            NOTE="USB host (OTG): libusb devices (SDR dongles, programmers, NFC readers, adapters). Nodes appear when a device is plugged in."
            ;;
        serial)
            NODES="/dev/ttyACM* /dev/ttyUSB*"
            GROUP=dialout:20
            RULE=1
            NOTE="USB serial adapters and boards (needs the kernel driver: CONFIG_USB_ACM, _FTDI_SIO, _PL2303, _CP210X, _CH341...). Android leaves them root-only; UbuRoot sets group dialout on new ones."
            ;;
        hidraw)
            NODES="/dev/hidraw*"
            GROUP=plugdev:46
            RULE=1
            NOTE="Raw HID (security keys, controllers). Android leaves them root-only; UbuRoot sets group plugdev on new ones."
            ;;
        wifi)
            ROUTE=takeover
            NOTE="Diagnostics (iw) work alongside Android. takeover wifi stops Android's Wi-Fi and Wi-Fi scanning, then wlan0 is Ubuntu's (wpa_supplicant, hostapd). Monitor mode only if the phy lists it."
            ;;
        bluetooth)
            NODES="/dev/ttyHS0"
            ROUTE=none
            NOTE="BlueZ needs an HCI transport in the kernel (CONFIG_BT_HCIUART for the internal chip, CONFIG_BT_HCIBTUSB for USB dongles)."
            ;;
        nfc)
            NODES="/dev/nq-nci /dev/pn54* /dev/pn55* /dev/sec-nfc /dev/st21nfc"
            GROUP=aid_nfc:1027
            ROUTE=none
            NOTE="Phone NFC controllers are vendor chardevs used by the NFC HAL; libnfc/nfcpy can't drive them. USB readers (ACR122U...) work through the usb class."
            ;;
        sensors)
            ROUTE=bridge
            NOTE="Direct only when the sensors are on the kernel's IIO bus (/sys/bus/iio). Otherwise the SensorManager/LocationManager bridge is Phase 3b."
            ;;
        leds)
            ROUTE=direct
            NOTE="/sys/class/leds: read freely; writes with uburoot-hw set (recorded)."
            ;;
        power)
            ROUTE="read"
            NOTE="Battery and chargers: read-only (safety floor). wakelock on/off keeps the phone awake."
            ;;
        cpu)
            ROUTE=direct
            NOTE="cpufreq governors and limits within the hardware table, cores online/offline (not cpu0); recorded. Vendor power daemons may change them back."
            ;;
        thermal)
            ROUTE="read"
            NOTE="Thermal zones and trip points: read-only. Shutdown trips are never changed."
            ;;
        buses)
            NODES="/dev/i2c-* /dev/spidev* /dev/gpiochip*"
            GROUP=uburoot-bus:
            ROUTE="read"
            NOTE="Read-only by default. uburoot-hw allow NODE opens one node to group uburoot-bus (recorded); PMIC, charger and regulator nodes are refused."
            ;;
        modem)
            ROUTE="read"
            NOTE="Report only: data interfaces (rmnet*) can be captured; no AT command or NV path."
            ;;
        *) die "unknown class: $1 (one of: $CLASSES)" ;;
    esac
}

nodes() { # CLASS -> existing nodes, one per line
    class_def "$1"
    for _g in $NODES; do
        for _n in $HW$_g; do
            [ -e "$_n" ] && printf '%s\n' "$_n"
        done
    done
}
# Who holds a node open: "pid/name" list (one ls of every fd).
holders() { # NODE...
    [ $# -gt 0 ] || return 0
    bb ls -l /proc/[0-9]*/fd 2>/dev/null | bb awk -v want=" $* " '
        /^\/proc\// { p = $0; sub("^/proc/", "", p); sub("/fd:$", "", p); next }
        { t = $NF; if (index(want, " " t " ") && !(p in seen)) { seen[p] = 1; print p } }' |
        while read -r _p; do
            printf '%s/%s ' "$_p" "$(cat "/proc/$_p/comm" 2>/dev/null)"
        done
}
group_users() { # NAME -> comma-separated members
    bb awk -F: -v g="$1" '$1 == g { print $4; exit }' "$RF/etc/group" 2>/dev/null
}

# Kernel config check for a class that depends on drivers. 0 = has it or unknown.
kconfig() { # NAME -> y|m|n|? (unknown)
    if [ -r /proc/config.gz ]; then
        _v=$(bb zcat /proc/config.gz 2>/dev/null | bb awk -F= -v k="CONFIG_$1" '$1 == k { print $2 }')
        printf '%s' "${_v:-n}"
    else
        printf '?'
    fi
}
class_state() { # CLASS -> available|missing|taken|unsupported
    class_def "$1"
    case "$1" in
        wifi)
            if rec_get takeover wifi >/dev/null 2>&1; then
                say taken
            elif [ -n "$(ls "$HW/sys/class/ieee80211" 2>/dev/null)" ]; then
                say available
            else
                say missing
            fi
            return
            ;;
        bluetooth)
            case "$(kconfig BT_HCIUART)$(kconfig BT_HCIBTUSB)$(kconfig BT_HCIVHCI)" in
                *y* | *m* | *'?'*) say available ;;
                *) say unsupported ;;
            esac
            return
            ;;
        nfc | modem | power | thermal | leds | cpu) say available; return ;;
        sensors)
            if [ -n "$(ls "$HW/sys/bus/iio/devices" 2>/dev/null)" ]; then say available; else say bridge; fi
            return
            ;;
    esac
    if [ -n "$(nodes "$1" | head -n 1)" ]; then say available; else say missing; fi
}

# --- Groups ---------------------------------------------------------------------------
ensure_group() { # NAME:GID -> group name to use
    _name=${1%%:*}
    _gid=${1#*:}
    if bb awk -F: -v g="$_name" '$1 == g { f = 1 } END { exit !f }' "$RF/etc/group"; then
        printf '%s' "$_name"
        return 0
    fi
    if [ -n "$_gid" ]; then
        # The gid may already exist under another name: use that group.
        _other=$(bb awk -F: -v i="$_gid" '$3 == i { print $1; exit }' "$RF/etc/group")
        if [ -n "$_other" ]; then
            printf '%s' "$_other"
            return 0
        fi
        in_ubuntu groupadd -g "$_gid" "$_name" || return 1
    else
        in_ubuntu groupadd -r "$_name" || return 1
    fi
    printf '%s' "$_name"
}
valid_user() { # NAME
    case "$1" in '' | [!a-z_]* | *[!a-z0-9_-]*) die "invalid user name: $1" ;; esac
    bb awk -F: -v u="$1" '$1 == u { f = 1 } END { exit !f }' "$RF/etc/passwd" || die "no user $1 in Ubuntu"
}

grant() { # CLASS USER
    class_def "$1"
    [ -n "$GROUP" ] || die "$1 has no device group to grant (route: $ROUTE)"
    valid_user "$2"
    need_access
    _g=$(ensure_group "$GROUP") || die "cannot create group ${GROUP%%:*}"
    in_ubuntu usermod -aG "$_g" "$2" || die "usermod failed"
    say "$2 is now in group $_g ($1). It applies to new logins (open a new session)."
    if [ "$RULE" = 1 ]; then
        mkdir -p "${RULES%/*}"
        bb grep -qx "$1" "$RULES" 2>/dev/null || printf '%s\n' "$1" >>"$RULES"
        apply
        start_watch
    fi
    case "$1" in
        uinput) say "Note: virtual input devices created by $2 reach Android too." ;;
    esac
}
revoke() { # CLASS USER
    class_def "$1"
    [ -n "$GROUP" ] || die "$1 has no device group"
    valid_user "$2"
    need_root
    _g=$(bb awk -F: -v i="${GROUP#*:}" -v n="${GROUP%%:*}" '$1 == n || (i != "" && $3 == i) { print $1; exit }' "$RF/etc/group")
    [ -n "$_g" ] || { say "$2 had no $1 access"; return 0; }
    in_ubuntu gpasswd -d "$2" "$_g" >/dev/null 2>&1 || say "$2 was not in group $_g"
    if [ "$RULE" = 1 ] && [ -z "$(group_users "$_g")" ] && [ -f "$RULES" ]; then
        bb grep -vx "$1" "$RULES" >"$RULES.tmp"
        mv -f "$RULES.tmp" "$RULES"
    fi
    say "$2 removed from group $_g ($1)"
}

# --- Permission rules (udev-like, no udevd) -----------------------------------------------
# For each enabled rule class, new nodes get the class group and mode 0660; the
# original owner and mode are recorded, so Stop all restores them.
apply() {
    [ -s "$RULES" ] || return 0
    _todo=""
    for _c in $(bb awk 'NF { print $1 }' "$RULES"); do
        case " $CLASSES " in *" $_c "*) ;; *) continue ;; esac
        class_def "$_c"
        [ "$RULE" = 1 ] || continue
        _gid=${GROUP#*:}
        for _n in $(nodes "$_c"); do
            [ -c "$_n" ] || continue
            _st=$(bb stat -c '%g %a' "$_n" 2>/dev/null) || continue
            _cg=${_st%% *}
            _m=${_st#* }
            # Group digit of the mode (660 -> 6): read+write = 6 or 7.
            _gd=$(printf '%s' "$_m" | bb awk '{ print substr($0, length($0) - 1, 1) }')
            if [ "$_cg" = "$_gid" ] && { [ "$_gd" = 6 ] || [ "$_gd" = 7 ]; }; then
                continue
            fi
            _todo="$_todo $_n:$_gid"
        done
    done
    [ -n "$_todo" ] || return 0
    lock_try || return 0
    for _t in $_todo; do
        _n=${_t%:*}
        rec_add node "$_n" "$(bb stat -c '%u:%g:%a' "$_n")"
        if chgrp "${_t##*:}" "$_n" && chmod 0660 "$_n"; then
            say "rule: $_n -> group ${_t##*:}, 0660"
        fi
    done
    # Records of unplugged devices: nothing to restore any more.
    bb awk '$1 == "node" { print $2 }' "$CHANGES" | while read -r _n; do
        [ -e "$_n" ] || rec_del node "$_n"
    done
    unlock
}
watch_running() {
    _p=$(cat "$PIDFILE" 2>/dev/null) || return 1
    [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null
}
start_watch() {
    watch_running && return 0
    [ -s "$RULES" ] || return 0
    if [ "$MODE" = android ]; then
        bb chroot "$RF" /usr/bin/env -i PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
            /usr/local/sbin/uburoot-hw watch </dev/null >/dev/null 2>&1 &
    else
        "$0" watch </dev/null >/dev/null 2>&1 &
    fi
}
watch_loop() {
    need_access
    mkdir -p "${PIDFILE%/*}"
    printf '%s\n' "$$" >"$PIDFILE"
    while [ -s "$RULES" ]; do
        apply >/dev/null 2>&1
        sleep 2
    done
    rm -f "$PIDFILE"
}

# --- Wi-Fi takeover ---------------------------------------------------------------------
wifi_takeover() {
    need_access
    lock
    rec_get takeover wifi >/dev/null && { say "Wi-Fi is already Ubuntu's"; return 0; }
    case "$(acmd cmd wifi status 2>/dev/null | head -n 1)" in
        *enabled*) _w=1 ;;
        *disabled*) _w=0 ;;
        *) die "cannot read Android's Wi-Fi state (cmd wifi status)" ;;
    esac
    _s=$(acmd settings get global wifi_scan_always_enabled 2>/dev/null)
    [ "$_s" = 1 ] || _s=0
    confirm "Turn off Android's Wi-Fi (and Wi-Fi scanning) so Ubuntu can use wlan0? The phone loses Wi-Fi until release, Stop all or a reboot."
    rec_add takeover wifi "$_w:$_s"
    acmd cmd wifi set-scan-always-available disabled >/dev/null 2>&1
    acmd cmd wifi set-wifi-enabled disabled >/dev/null 2>&1
    # Android's wpa_supplicant leaves once Wi-Fi and scanning are off.
    _i=0
    while [ "$_i" -lt 15 ] && acmd cmd wifi status 2>/dev/null | head -n 1 | bb grep -q enabled; do
        sleep 1
        _i=$((_i + 1))
    done
    say "Wi-Fi is Ubuntu's now (was: wifi=$_w scan=$_s). Next, as root in Ubuntu:"
    say "  ip link set wlan0 up; iw dev wlan0 scan | grep SSID"
    say "  wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf; dhclient wlan0  (or hostapd for an access point)"
    say "uburoot-hw release wifi (or Stop all) gives it back to Android."
}
wifi_back() {
    need_root
    lock
    _st=$(rec_get takeover wifi) || { say "Wi-Fi is not taken over"; return 0; }
    wifi_release "$_st" || die "could not give Wi-Fi back to Android"
    rec_del takeover wifi
    say "Wi-Fi given back to Android"
}

# --- CPU, power, thermal --------------------------------------------------------------------
CPUF="$HW/sys/devices/system/cpu"
policies() { ls -d "$CPUF"/cpufreq/policy* 2>/dev/null; }
cpu_show() {
    for _p in $(policies); do
        say "${_p##*/}: cpus $(cat "$_p/related_cpus") governor $(cat "$_p/scaling_governor") min $(cat "$_p/scaling_min_freq") max $(cat "$_p/scaling_max_freq") (hw $(cat "$_p/cpuinfo_min_freq")-$(cat "$_p/cpuinfo_max_freq") kHz)"
        say "  governors: $(cat "$_p/scaling_available_governors" 2>/dev/null)"
        say "  frequencies: $(cat "$_p/scaling_available_frequencies" 2>/dev/null)"
    done
    say "online: $(cat "$CPUF/online" 2>/dev/null)"
}
set_file() { # PATH VALUE (recorded)
    _o=$(cat "$1" 2>/dev/null) || die "cannot read $1"
    [ "$_o" = "$2" ] && { say "${1#"$HW"} = $2 (unchanged)"; return 0; }
    wr "$2" "$1" 2>/dev/null || die "the kernel refused ${1#"$HW"} = $2"
    _n=$(cat "$1" 2>/dev/null)
    if _r=$(rec_get file "$1"); then
        [ "$_n" = "$_r" ] && rec_del file "$1"
    else
        rec_add file "$1" "$_o"
    fi
    say "${1#"$HW"} = $_n (was $_o)"
}
policy_dirs() { # POLICY|all
    if [ "$1" = all ]; then
        policies
    else
        case "$1" in policy[0-9]*) ;; *) die "invalid policy: $1 (policy0, policy4... or all)" ;; esac
        [ -d "$CPUF/cpufreq/$1" ] || die "no such policy: $1"
        printf '%s\n' "$CPUF/cpufreq/$1"
    fi
}
cpu_cmd() {
    [ $# -gt 0 ] || { cpu_show; return; }
    need_access
    case "$1" in
        governor)
            [ $# = 3 ] || die "usage: uburoot-hw cpu governor POLICY|all GOVERNOR"
            lock
            for _p in $(policy_dirs "$2"); do
                bb grep -qw -- "$3" "$_p/scaling_available_governors" || die "${_p##*/} has no governor $3"
                set_file "$_p/scaling_governor" "$3"
            done
            ;;
        min | max)
            [ $# = 3 ] || die "usage: uburoot-hw cpu $1 POLICY|all FREQ_KHZ"
            lock
            for _p in $(policy_dirs "$2"); do
                # The table can leave out the boost frequency (S9 policy4: cpuinfo_max_freq
                # 2803200, the table ends at 2649600), so the hardware limits count too.
                if ! bb grep -qw -- "$3" "$_p/scaling_available_frequencies" &&
                    [ "$3" != "$(cat "$_p/cpuinfo_max_freq" 2>/dev/null)" ] &&
                    [ "$3" != "$(cat "$_p/cpuinfo_min_freq" 2>/dev/null)" ]; then
                    die "${_p##*/}: $3 is not one of its frequencies ($(cat "$_p/scaling_available_frequencies"))"
                fi
                set_file "$_p/scaling_$1_freq" "$3"
            done
            ;;
        online)
            [ $# = 3 ] || die "usage: uburoot-hw cpu online CPU 0|1"
            case "$2" in '' | *[!0-9]*) die "invalid CPU: $2" ;; esac
            [ "$2" != 0 ] || die "cpu0 stays online"
            case "$3" in 0 | 1) ;; *) die "online takes 0 or 1" ;; esac
            [ -f "$CPUF/cpu$2/online" ] || die "cpu$2 can't be switched"
            lock
            set_file "$CPUF/cpu$2/online" "$3"
            ;;
        *) die "usage: uburoot-hw cpu [governor|min|max|online ...]" ;;
    esac
}
wakelock() {
    need_access
    lock
    case "${1:-}" in
        on)
            wr uburoot_hw "$POWER/wake_lock" 2>/dev/null || die "cannot take a wake lock"
            rec_add wakelock uburoot_hw -
            say "wake lock held: the phone won't suspend (wakelock off, Stop all or a reboot releases it)"
            ;;
        off)
            wr uburoot_hw "$POWER/wake_unlock" 2>/dev/null
            rec_del wakelock uburoot_hw
            say "wake lock released"
            ;;
        *) die "usage: uburoot-hw wakelock on|off" ;;
    esac
}
power_show() {
    for _s in "$HW"/sys/class/power_supply/*; do
        [ -d "$_s" ] || continue
        _l="${_s##*/}:"
        for _k in type online status capacity health temp voltage_now current_now charge_type; do
            [ -r "$_s/$_k" ] && _l="$_l $_k=$(cat "$_s/$_k" 2>/dev/null)"
        done
        say "$_l"
    done
}
thermal_show() {
    for _z in "$HW"/sys/class/thermal/thermal_zone*; do
        [ -d "$_z" ] || continue
        _l="${_z##*/} $(cat "$_z/type" 2>/dev/null) $(cat "$_z/temp" 2>/dev/null)"
        for _t in "$_z"/trip_point_*_type; do
            [ -f "$_t" ] || continue
            [ "$(cat "$_t" 2>/dev/null)" = critical ] && _l="$_l critical=$(cat "${_t%_type}_temp" 2>/dev/null)"
        done
        say "$_l"
    done
}

# --- LEDs and bus nodes -----------------------------------------------------------------
set_led() { # PATH VALUE
    need_access
    case "$1" in
        /sys/class/leds/*/brightness | /sys/class/leds/*/trigger) ;;
        *) die "only /sys/class/leds/NAME/brightness or trigger can be set" ;;
    esac
    case "$1" in *..*) die "invalid path: $1" ;; esac
    case "$2" in *[!A-Za-z0-9_-]* | '') die "invalid value: $2" ;; esac
    lock
    set_file "$HW$1" "$2"
}
# PMIC, charger, regulator and fuel-gauge parts stay out of reach (safety floor).
DENY='pmic|pmi[0-9]|pm[0-9]+|pm8|smb[0-9]|qpnp|charger|regulator|fuel|battery|max777|s2m|bq2[0-9]|sm5|mfc'
bus_label() { # NODE -> what is behind it
    _b=${1##*/}
    case "$_b" in
        gpiochip*) cat "$HW/sys/bus/gpio/devices/$_b/label" "$HW/sys/class/gpio/$_b/label" 2>/dev/null | head -n 1 ;;
        i2c-*) cat "$HW/sys/bus/i2c/devices/${_b#i2c-}"-*/name "$HW/sys/class/i2c-dev/$_b/name" 2>/dev/null | tr '\n' ' ' ;;
        spidev*) cat "$HW/sys/class/spidev/$_b/device/modalias" 2>/dev/null ;;
    esac
}
allow_node() { # NODE
    need_access
    case "$1" in
        /dev/i2c-[0-9]* | /dev/spidev[0-9]* | /dev/gpiochip[0-9]*) ;;
        *) die "allow takes /dev/i2c-N, /dev/spidevN.M or /dev/gpiochipN" ;;
    esac
    [ -c "$HW$1" ] || die "no such device: $1"
    _lab=$(bus_label "$1")
    if printf '%s' "$_lab" | bb grep -qiE "$DENY"; then
        die "$1 ($_lab) belongs to power management (PMIC/charger/regulator): refused"
    fi
    confirm "Give group uburoot-bus read/write access to $1 ($_lab)? A wrong write can hang or damage what is on that bus."
    _g=$(ensure_group uburoot-bus:) || die "cannot create group uburoot-bus"
    _gid=$(bb awk -F: -v g="$_g" '$1 == g { print $3 }' "$RF/etc/group")
    lock
    rec_add node "$HW$1" "$(bb stat -c '%u:%g:%a' "$HW$1")"
    if ! { chgrp "$_gid" "$HW$1" && chmod 0660 "$HW$1"; }; then
        die "cannot change $1"
    fi
    say "$1 ($_lab): group $_g, 0660 until Stop all or a reboot. Grant users with: uburoot-hw grant buses USER"
}

# --- Reports ------------------------------------------------------------------------------
list() {
    printf '%-10s %-9s %-11s %s\n' CLASS ROUTE STATE "NODES / USED BY"
    for _c in $CLASSES; do
        _st=$(class_state "$_c")
        _ns=$(nodes "$_c" | bb wc -l | tr -d ' ')
        class_def "$_c"
        _u=""
        # shellcheck disable=SC2046 # one argument per node
        [ "$_ns" -gt 0 ] && _u=$(holders $(nodes "$_c" | head -n 20))
        printf '%-10s %-9s %-11s %s\n' "$_c" "$ROUTE" "$_st" "$_ns ${_u:+($_u)}"
    done
}
info() { # CLASS
    class_def "$1"
    say "class:  $1"
    say "route:  $ROUTE"
    say "state:  $(class_state "$1")"
    if [ -n "$GROUP" ]; then
        _gid=${GROUP#*:}
        say "group:  ${GROUP%%:*}${_gid:+ (gid $_gid)}; users: $(group_users "${GROUP%%:*}")"
    fi
    say "notes:  $NOTE"
    _list=$(nodes "$1")
    if [ -n "$_list" ]; then
        say "nodes:"
        for _n in $_list; do
            _l="  $(bb stat -c '%n %U:%G %a' "$_n" 2>/dev/null)"
            case "$1" in buses) _l="$_l $(bus_label "$_n")" ;; esac
            say "$_l"
        done
        # shellcheck disable=SC2086 # one argument per node
        _h=$(holders $_list)
        [ -n "$_h" ] && say "used by: $_h"
    fi
    case "$1" in
        cpu) cpu_show ;;
        power) power_show ;;
        thermal) thermal_show ;;
        leds) for _l in "$HW"/sys/class/leds/*; do [ -d "$_l" ] && say "  ${_l##*/} brightness=$(cat "$_l/brightness" 2>/dev/null) max=$(cat "$_l/max_brightness" 2>/dev/null)"; done ;;
        wifi)
            for _p in "$HW"/sys/class/ieee80211/*; do [ -d "$_p" ] && say "  phy ${_p##*/}"; done
            command -v iw >/dev/null 2>&1 && iw list 2>/dev/null | bb awk '/Supported interface modes/ { f = 1; next } f && /^\t\t \* / { printf "  mode %s\n", $2; next } f { f = 0 }'
            ;;
        bluetooth) say "  kernel: BT_HCIUART=$(kconfig BT_HCIUART) BT_HCIBTUSB=$(kconfig BT_HCIBTUSB) BT_HCIVHCI=$(kconfig BT_HCIVHCI)" ;;
        nfc) say "  kernel: NFC=$(kconfig NFC)" ;;
        sensors)
            _l=""
            for _d in "$HW"/sys/bus/iio/devices/*; do [ -e "$_d" ] && _l="$_l ${_d##*/}"; done
            say "  IIO devices:${_l:- none}"
            ;;
        modem)
            _l=""
            for _d in "$HW"/sys/class/net/rmnet* "$HW"/sys/class/net/ccmni* "$HW"/sys/class/net/wwan*; do
                [ -e "$_d" ] && _l="$_l ${_d##*/}"
            done
            say "  data interfaces:${_l:- none}"
            say "  telephony: $(acmd getprop gsm.version.baseband 2>/dev/null)"
            ;;
    esac
}
status() {
    if [ "$ACCESS" = 1 ]; then say "access=on"; else say "access=off"; fi
    for _c in $CLASSES; do
        class_def "$_c"
        _g=${GROUP%%:*}
        printf 'class=%s|%s|%s|%s|%s|%s\n' "$_c" "$ROUTE" "$(class_state "$_c")" "$(nodes "$_c" | bb wc -l | tr -d ' ')" "$_g" "$( [ -n "$_g" ] && group_users "$_g")"
    done
    for _p in $(policies); do
        say "cpu=${_p##*/}|$(cat "$_p/related_cpus")|$(cat "$_p/scaling_governor")|$(cat "$_p/scaling_min_freq")|$(cat "$_p/scaling_max_freq")|$(cat "$_p/cpuinfo_max_freq")"
    done
    _b="$HW/sys/class/power_supply/battery"
    [ -d "$_b" ] && say "battery=$(cat "$_b/capacity" 2>/dev/null)|$(cat "$_b/status" 2>/dev/null)|$(cat "$_b/temp" 2>/dev/null)"
    if rec_get wakelock uburoot_hw >/dev/null 2>&1; then say "wakelock=on"; else say "wakelock=off"; fi
    if watch_running; then say "rules=running"; elif [ -s "$RULES" ]; then say "rules=stopped"; else say "rules=none"; fi
    say "changes=$(rec_count)"
}

[ $# -ge 1 ] || die "usage: uburoot-hw [-y] list|info|status|grant|revoke|takeover|release|cpu|wakelock|set|allow ..."
_cmd=$1
shift
case "$_cmd" in
    list) list ;;
    info)
        [ $# = 1 ] || die "usage: uburoot-hw info CLASS"
        info "$1"
        ;;
    status) status ;;
    grant | revoke)
        [ $# = 2 ] || die "usage: uburoot-hw $_cmd CLASS USER"
        "$_cmd" "$1" "$2"
        ;;
    takeover | release)
        [ "${1:-}" = wifi ] || die "usage: uburoot-hw $_cmd wifi (other classes: see uburoot-hw info CLASS)"
        if [ "$_cmd" = takeover ]; then wifi_takeover; else wifi_back; fi
        ;;
    cpu) cpu_cmd "$@" ;;
    wakelock) wakelock "$@" ;;
    set)
        [ $# = 2 ] || die "usage: uburoot-hw set /sys/class/leds/NAME/brightness VALUE"
        set_led "$1" "$2"
        ;;
    allow)
        [ $# = 1 ] || die "usage: uburoot-hw allow /dev/NODE"
        allow_node "$1"
        ;;
    apply)
        need_access
        apply
        ;;
    watch) watch_loop ;;
    *) die "unknown command: $_cmd" ;;
esac
