#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# uburoot-doctor: what UbuRoot needs from this phone and what it found.
# Usage: doctor.sh [--redact] [--app-version V]
#   --redact  replace identifiers (IP addresses, user names, host names, serial
#             numbers) with <redacted>; the app shares this version by default.
# Read-only: it mounts, installs and changes nothing. The DNS and mirror checks
# run inside Ubuntu, so only while it is mounted.
set -u
UBU_BIN_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$UBU_BIN_DIR/common.sh"

ubu_require_root
ubu_init
ubu_load_config

REDACT=0
APP_VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --redact) REDACT=1 ;;
        --app-version) APP_VERSION=${2:-}; shift ;;
        *) ubu_die "unknown option: $1" ;;
    esac
    shift
done

R=$ROOTFS
NFAIL=0
NWARN=0

sec() { printf '\n== %s ==\n' "$1"; }
# A blank label continues the previous item.
kv() {
    case "$1" in
        *[!\ ]*) printf '%-24s %s\n' "$1:" "$2" ;;
        *) printf '%-24s %s\n' "" "$2" ;;
    esac
}
ok() { kv "$1" "[ok] $2"; }
warn() { kv "$1" "[warn] $2"; NWARN=$((NWARN + 1)); }
fail() { kv "$1" "[FAIL] $2"; NFAIL=$((NFAIL + 1)); }
# An identifier, or <redacted>.
ident() { if [ "$REDACT" = 1 ]; then printf '<redacted>'; else printf '%s' "$1"; fi; }
prop() { getprop "$1" 2>/dev/null; }

MOUNTED=0
ubu_is_mounted "$R/proc" && MOUNTED=1
CHROOT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# in_chroot SECS CMD...: inside Ubuntu as root, with a time limit.
in_chroot() {
    _t=$1
    shift
    bb timeout "$_t" chroot "$R" /usr/bin/env -i HOME=/root LANG=C.UTF-8 PATH="$CHROOT_PATH" "$@"
}

# --- Kernel config -------------------------------------------------------------------
CFG=""
if [ -r /proc/config.gz ]; then
    CFG=$(bb zcat /proc/config.gz 2>/dev/null | bb grep -E '^CONFIG_[A-Z0-9_]+=')
fi
# kcfg NAME: y, m or n (unset options are often not listed at all).
kcfg() {
    printf '%s\n' "$CFG" | bb awk -F= -v k="CONFIG_$1" '$1 == k { v = $2 } END { print (v == "" ? "n" : v) }'
}
# shellcheck disable=SC2317,SC2329 # used as a probe command by cap()
in_fs() { bb grep -qw "$1" /proc/filesystems 2>/dev/null; }
CONFIGFS=$(ubu_fs_mount configfs /sys/kernel/config)

# cap LABEL CONFIG_NAME [PROBE...]: from the kernel config when there is one,
# else from the probe command (if any).
cap() {
    _label=$1
    _key=$2
    shift 2
    if [ -n "$CFG" ]; then
        case "$(kcfg "$_key")" in
            y) kv "$_label" "yes" ;;
            m) kv "$_label" "module" ;;
            *) kv "$_label" "no" ;;
        esac
    elif [ $# -gt 0 ]; then
        if "$@" 2>/dev/null; then kv "$_label" "yes (probed)"; else kv "$_label" "not found (probed)"; fi
    else
        kv "$_label" "unknown (no /proc/config.gz)"
    fi
}

# shellcheck disable=SC2317,SC2329 # used as a probe command by cap()
tracing_file() { [ -e "/sys/kernel/tracing/$1" ] || [ -e "/sys/kernel/debug/tracing/$1" ]; }

# A vendor kernel module (.ko) of this ROM, for its vermagic.
vendor_module() {
    for _d in "$(ubu_module_dir 2>/dev/null)" /vendor_dlkm/lib/modules /vendor/lib/modules /system_dlkm/lib/modules /odm/lib/modules; do
        if [ -z "$_d" ] || [ ! -d "$_d" ]; then continue; fi
        for _f in "$_d"/*.ko; do
            [ -f "$_f" ] && { printf '%s' "$_f"; return 0; }
        done
    done
    return 1
}
# The vermagic string from a module's .modinfo (NUL-separated key=value).
ko_vermagic() {
    bb tr '\000' '\n' <"$1" 2>/dev/null | bb awk '/^vermagic=/ { print substr($0, 10); exit }'
}

# --- Hardware inventory ----------------------------------------------------------------
# Device nodes held open by processes: "NODE comm,comm,..." lines, one ls for
# every process (a readlink per fd would fork thousands of times).
OWNERS=""
load_owners() {
    OWNERS=$(bb ls -l /proc/[0-9]*/fd 2>/dev/null | bb awk '
        # App processes (uid >= 10000) are just "app": their names would list
        # the installed apps.
        function name(pid,   f, c, l, u) {
            f = "/proc/" pid "/status"
            while ((getline l <f) > 0) {
                if (l ~ /^Name:/) { c = l; sub(/^Name:[ \t]*/, "", c) }
                if (l ~ /^Uid:/) { split(l, u, /[ \t]+/); break }
            }
            close(f)
            return (u[2] + 0 >= 10000) ? "app" : c
        }
        /^\/proc\/[0-9]+\/fd:$/ { split($0, a, "/"); pid = a[3]; next }
        / -> \/dev\// {
            t = $NF
            if (!((t, pid) in seen)) {
                seen[t, pid] = 1
                if (!(pid in comm)) comm[pid] = name(pid)
                if (!((t, comm[pid]) in named)) { named[t, comm[pid]] = 1; o[t] = o[t] (o[t] == "" ? "" : ",") comm[pid] }
            }
        }
        END { for (t in o) print t, o[t] }')
}
# owners NODE: who holds it open, or "free".
owners() {
    _o=$(printf '%s\n' "$OWNERS" | bb awk -v n="$1" '$1 == n { print $2; exit }')
    printf '%s' "${_o:-free}"
}
# node LABEL PATH...: each existing device node with its owners.
node() {
    _l=$1
    shift
    _any=0
    for _n in "$@"; do
        [ -e "$_n" ] || continue
        kv "$_l" "$_n [$(owners "$_n")]"
        _l="  "
        _any=1
    done
    [ "$_any" = 1 ] || kv "$_l" "none"
}
# names DIR FILE: the FILE of every entry of a sysfs class, comma-separated.
names() {
    _out=""
    for _e in "$1"/*; do
        [ -d "$_e" ] || continue
        _v=$(head -n 1 "$_e/$2" 2>/dev/null)
        _out="$_out${_out:+, }${_e##*/}${_v:+ ($_v)}"
    done
    printf '%s' "${_out:-none}"
}

hardware() {
    sec Hardware
    load_owners
    _soc=$(prop ro.soc.model)
    [ -n "$_soc" ] || _soc=$(bb awk -F': ' '/^Hardware/ { print $2; exit }' /proc/cpuinfo 2>/dev/null)
    kv SoC "${_soc:-unknown} (platform $(prop ro.board.platform))"
    for _p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$_p" ] || continue
        _mx=$(cat "$_p/cpuinfo_max_freq" 2>/dev/null)
        case "$_mx" in '' | *[!0-9]*) _mx=0 ;; esac
        kv "  CPU ${_p##*/}" "cpus $(cat "$_p/related_cpus" 2>/dev/null), $(cat "$_p/scaling_governor" 2>/dev/null), max $((_mx / 1000)) MHz"
    done
    kv "  CPUs online" "$(cat /sys/devices/system/cpu/online 2>/dev/null)"
    _gpu=$(cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null)
    [ -n "$_gpu" ] && kv GPU "$_gpu"
    node "GPU node" /dev/kgsl-3d0 /dev/mali0 /dev/dri/renderD128 /dev/dri/card0
    node framebuffer /dev/graphics/fb0 /dev/fb0
    kv DRM "$(names /sys/class/drm status)"
    _in=$(bb awk '
        /^N: Name=/ { n = substr($0, 10); gsub(/"/, "", n) }
        /^H: Handlers=/ { for (i = 2; i <= NF; i++) if ($i ~ /^event[0-9]+$/) printf "%s%s=%s", (c++ ? ", " : ""), $i, n }
        ' /proc/bus/input/devices 2>/dev/null)
    kv input "${_in:-none}"
    node uinput /dev/uinput
    kv "ALSA cards" "$(bb awk '/^ *[0-9]+ \[/ { sub(/^ */, ""); printf "%s%s", (c++ ? ", " : ""), $0 }' /proc/asound/cards 2>/dev/null)"
    node "ALSA control" /dev/snd/controlC0
    kv V4L2 "$(names /sys/class/video4linux name)"
    kv "IIO sensors" "$(names /sys/bus/iio/devices name)"
    kv "Wi-Fi (sysfs)" "$(names /sys/class/ieee80211 -)"
    kv "Bluetooth HCI" "$(names /sys/class/bluetooth name)"
    _nfc=""
    for _n in /dev/nq-nci /dev/pn5* /dev/pn54* /dev/sec-nfc /dev/nfc* /dev/st21nfc /dev/bcm2079x*; do
        [ -e "$_n" ] && _nfc="$_nfc $_n"
    done
    # shellcheck disable=SC2086 # word splitting intended: a list of nodes
    if [ -n "$_nfc" ]; then node NFC $_nfc; else kv NFC "$(names /sys/class/nfc name)"; fi
    kv "USB gadget UDC" "$(names /sys/class/udc state)"
    _usb=$(cd /sys/bus/usb/devices 2>/dev/null && bb ls -d usb* 2>/dev/null | tr '\n' ' ' | bb sed 's/ $//')
    kv "USB host buses" "${_usb:-none (no host controller active: OTG idle)}"
    kv LEDs "$(cd /sys/class/leds 2>/dev/null && bb ls | tr '\n' ' ' | bb sed 's/ $//')"
    kv "power supplies" "$(names /sys/class/power_supply type)"
    _tz=0
    for _t in /sys/class/thermal/thermal_zone*; do [ -d "$_t" ] && _tz=$((_tz + 1)); done
    kv "thermal zones" "$_tz (read-only for UbuRoot)"
    for _c in i2c-:I2C spidev:SPI gpiochip:GPIO ttyHS:"serial (HS)" ttyMSM:"serial (MSM)" ttyUSB:"USB serial" ttyACM:"USB ACM" smd:"modem (SMD, report only)" mhi_:"modem (MHI, report only)"; do
        _pre=${_c%%:*}
        _cnt=0
        for _n in /dev/"$_pre"*; do [ -e "$_n" ] && _cnt=$((_cnt + 1)); done
        [ "$_cnt" -gt 0 ] && kv "${_c#*:}" "$_cnt node(s) (/dev/$_pre*)"
    done
}

report() {
    printf 'UbuRoot doctor\n'
    kv date "$(date +%Y-%m-%d)"
    kv app "${APP_VERSION:-unknown}"
    kv "scripts schema" "$UBU_SCHEMA"
    if [ "$REDACT" = 1 ]; then kv redacted yes; else kv redacted no; fi

    sec Root
    ubu_detect_root_impl
    kv manager "$UBU_ROOT_IMPL ${UBU_ROOT_VERSION}"
    kv busybox "${BB:-none} ($BB_KIND)"
    _rr=$(ubu_root_report)
    _rv() { printf '%s\n' "$_rr" | bb awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }'; }
    if [ "$(_rv full_root)" = yes ]; then
        ok "full root" "all capabilities (cap_last_cap $(_rv cap_last_cap)), no seccomp, no no_new_privs"
    else
        fail "full root" "restricted (a root manager profile?): see below"
    fi
    kv "CapEff" "$(_rv cap_eff)"
    kv "CapBnd" "$(_rv cap_bnd)"
    kv "Seccomp" "$(_rv seccomp)"
    kv "NoNewPrivs" "$(_rv no_new_privs)"
    kv "SELinux context" "$(_rv selinux)"
    if [ "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)" ]; then
        ok "mount namespace" "global (init)"
    else
        fail "mount namespace" "private: su is not running with --mount-master"
    fi

    sec Android
    kv device "$(prop ro.product.manufacturer) $(prop ro.product.model) ($(prop ro.product.device))"
    kv android "$(prop ro.build.version.release) (SDK $(prop ro.build.version.sdk))"
    _rom=$(prop ro.lineage.version)
    kv rom "${_rom:-$(prop ro.build.display.id)}"
    kv "security patch" "$(prop ro.build.version.security_patch)"
    kv selinux "$(getenforce 2>/dev/null || echo unknown)"
    _cs=$(prop ro.crypto.state)
    _ct=$(prop ro.crypto.type)
    kv encryption "${_cs:-unknown}${_ct:+ ($_ct)}"
    kv "user 0 unlocked" "$(prop sys.user.0.ce_available)"

    sec Kernel
    kv kernel "$(uname -r) $(uname -m)"
    if [ -n "$CFG" ]; then kv config "/proc/config.gz"; else kv config "absent: features below are probed"; fi
    cap "user namespaces" USER_NS test -e /proc/self/ns/user
    cap overlayfs OVERLAY_FS in_fs overlay
    cap fuse FUSE_FS in_fs fuse
    cap "tun/tap" TUN sh -c '[ -e /dev/tun ] || [ -e /dev/net/tun ]'
    cap wireguard WIREGUARD test -d /sys/module/wireguard
    cap binfmt_misc BINFMT_MISC in_fs binfmt_misc
    cap "loop devices" BLK_DEV_LOOP sh -c '[ -e /dev/loop-control ] || [ -e /dev/block/loop0 ]'
    cap kvm KVM test -e /dev/kvm
    cap "bpf syscall" BPF_SYSCALL in_fs bpf
    cap "iptables (xtables)" IP_NF_IPTABLES test -e /proc/net/ip_tables_names
    cap nf_tables NF_TABLES
    cap configfs CONFIGFS_FS in_fs configfs
    cap "USB gadget (configfs)" USB_CONFIGFS test -d "${CONFIGFS:-/nonexistent}/usb_gadget"
    cap "  gadget: NCM" USB_CONFIGFS_NCM
    cap "  gadget: RNDIS" USB_CONFIGFS_RNDIS
    cap "  gadget: ACM serial" USB_CONFIGFS_ACM
    cap "  gadget: mass storage" USB_CONFIGFS_MASS_STORAGE
    cap "  gadget: HID" USB_CONFIGFS_F_HID
    cap "USB serial (OTG)" USB_SERIAL test -d /sys/bus/usb-serial
    cap "USB ACM (OTG)" USB_ACM
    cap cfg80211 CFG80211 test -d /sys/class/ieee80211
    cap mac80211 MAC80211
    cap bluetooth BT test -d /sys/class/bluetooth
    cap CAN CAN test -e /proc/net/can
    cap "loadable modules" MODULES test -e /proc/modules
    kv "modules loaded" "$(bb wc -l </proc/modules 2>/dev/null | tr -d ' ')"
    _md=$(ubu_module_dir) || _md="none found"
    kv "ROM module dir" "$_md"
    case "$(uname -r)" in
        *-android[0-9]*-*) kv GKI "yes ($(uname -r | bb sed 's/.*-\(android[0-9]*\)-.*/\1/'))" ;;
        *) kv GKI "no (vendor kernel)" ;;
    esac
    cap "module signing" MODULE_SIG
    cap "  signature enforced" MODULE_SIG_FORCE
    _se=$(cat /sys/module/module/parameters/sig_enforce 2>/dev/null)
    [ -n "$_se" ] && kv "  sig_enforce (runtime)" "$_se"
    cap modversions MODVERSIONS
    _ko=$(vendor_module) && kv "vendor vermagic" "$(ko_vermagic "$_ko") (${_ko##*/})"
    if [ -e /sys/kernel/btf/vmlinux ]; then kv BTF "yes (/sys/kernel/btf/vmlinux)"; else cap BTF DEBUG_INFO_BTF; fi
    cap kprobes KPROBES tracing_file kprobe_events
    cap uprobes UPROBES tracing_file uprobe_events
    cap ftrace FTRACE tracing_file trace
    kv namespaces "$(bb ls /proc/self/ns 2>/dev/null | tr '\n' ' ' | bb sed 's/ $//')"
    for _s in kptr_restrict dmesg_restrict perf_event_paranoid unprivileged_bpf_disabled; do
        _v=$(cat "/proc/sys/kernel/$_s" 2>/dev/null) || _v="absent"
        kv "$_s" "$_v"
    done
    _ph=$(prop security.perf_harden)
    [ -n "$_ph" ] && kv "security.perf_harden" "$_ph"
    for _k in $UBU_KERNEL_FS; do
        _p=$(ubu_fs_mount "${_k%%:*}" "${_k#*:}")
        kv "host ${_k%%:*}" "${_p:-not mounted}"
    done
    if [ "$MOUNTED" = 1 ] && [ -x "$R/usr/sbin/iw" ]; then
        _phys=$(in_chroot 10 iw phy 2>/dev/null | bb awk '
            /^Wiphy / { p = $2; m[p] = "no"; inmodes = 0; next }
            /Supported interface modes:/ { inmodes = 1; next }
            inmodes && /^\t\t\* / { if ($2 == "monitor") m[p] = "yes"; next }
            inmodes { inmodes = 0 }
            END { for (p in m) printf "%s monitor=%s ", p, m[p] }' | bb sed 's/ $//')
        kv "Wi-Fi phys" "${_phys:-none}"
    else
        kv "Wi-Fi phys" "unknown (needs Ubuntu mounted and: apt install iw)"
    fi

    hardware

    sec Storage
    _free=$(bb df -Pk /data 2>/dev/null | bb awk 'NR == 2 { print $4 }')
    case "$_free" in
        '' | *[!0-9]*) warn "free on /data" "unknown" ;;
        *)
            if [ "$_free" -lt 1048576 ]; then
                warn "free on /data" "$((_free / 1024)) MB"
            else
                ok "free on /data" "$((_free / 1024)) MB"
            fi
            ;;
    esac
    if ubu_rootfs_installed; then
        ok rootfs "installed at $R"
        _osr="$R/usr/lib/os-release"
        [ -f "$_osr" ] || _osr="$R/etc/os-release"
        kv ubuntu "$(bb awk -F= '$1 == "PRETTY_NAME" { gsub(/"/, "", $2); print $2 }' "$_osr" 2>/dev/null)"
        kv "rootfs arch" "$(ubu_elf_arch "$R/usr/bin/dpkg" || echo unknown)"
        if [ -f "$R/etc/uburoot-setup.done" ]; then ok setup "done"; else warn setup "pending"; fi
        _sch=$(ubu_rootfs_schema)
        if [ "$_sch" -lt "$UBU_SCHEMA" ]; then
            warn "integration schema" "$_sch, scripts have $UBU_SCHEMA (the app migrates it on start)"
        else
            ok "integration schema" "$_sch"
        fi
        kv installed "$(bb awk -F= '$1 == "INSTALLED" { print $2 }' "$R/etc/uburoot-release" 2>/dev/null)"
    else
        warn rootfs "not installed"
    fi

    sec Mounts
    if [ "$MOUNTED" = 1 ]; then
        ok state "mounted ($(ubu_count_mounts_under "$R") mounts under the rootfs)"
        _want="/proc /sys /dev /dev/pts /run"
        [ "$MOUNT_SDCARD" = 1 ] && _want="$_want /sdcard"
        [ "$ANDROID_INTEGRATION" = 1 ] && _want="$_want /data /system"
        _miss=""
        for _m in $_want; do ubu_is_mounted "$R$_m" || _miss="$_miss $_m"; done
        if [ -z "$_miss" ]; then ok expected "all present"; else fail expected "missing:$_miss (Settings > Repair mounts)"; fi
        if ubu_any_shared_under "$R"; then fail propagation "a mount under the rootfs is shared"; else ok propagation "nothing shared"; fi
        _ki=""
        for _k in $UBU_KERNEL_FS; do ubu_is_mounted "$R${_k#*:}" && _ki="$_ki ${_k%%:*}"; done
        ubu_is_mounted "$R/usr/lib/modules/$(uname -r)" && _ki="$_ki modules"
        kv "kernel interfaces" "${_ki# }"
        kv "chroot processes" "$(ubu_chroot_pids | bb wc -l | tr -d ' ')"
    else
        kv state "not mounted (opening a terminal mounts it)"
    fi

    sec Network
    if [ -x /system/bin/ip ]; then
        /system/bin/ip -o addr show 2>/dev/null | bb awk '$2 != "lo" { print $2, $3, $4 }' |
            while read -r _if _fam _addr; do
                kv "  $_if" "$_fam $(ident "$_addr")"
            done
    fi
    if [ -f "$R/etc/resolv.conf" ]; then
        _dns=""
        for _s in $(bb awk '$1 == "nameserver" { print $2 }' "$R/etc/resolv.conf"); do _dns="$_dns $(ident "$_s")"; done
        kv "DNS servers" "${_dns# }"
    fi
    if [ -n "$(cat /proc/net/ip_tables_names 2>/dev/null)" ]; then
        kv "Android firewall" "legacy xtables"
    else
        kv "Android firewall" "no legacy tables (nftables or none)"
    fi
    if [ "$MOUNTED" = 1 ]; then
        _ipt=$(in_chroot 10 update-alternatives --query iptables 2>/dev/null | bb awk '$1 == "Value:" { print $2 }')
        kv "Ubuntu iptables" "${_ipt:-not installed}"
        _arch=$(ubu_elf_arch "$R/usr/bin/dpkg") || _arch=""
        case "$_arch" in
            amd64 | i386) _mirror=${APT_MIRROR:-http://archive.ubuntu.com/ubuntu/} ;;
            *) _mirror=${APT_MIRROR:-$UBU_PORTS_MIRROR_DEFAULT} ;;
        esac
        _host=${_mirror#http://}
        _host=${_host%%/*}
        _hostname=${_host%%:*}
        _port=${_host#"$_hostname"}
        _port=${_port#:}
        kv "apt mirror" "$_mirror"
        if in_chroot 10 getent hosts "$_hostname" >/dev/null 2>&1; then
            ok "DNS lookup" "$_hostname resolves"
            if in_chroot 10 bash -c ": >/dev/tcp/$_hostname/${_port:-80}" 2>/dev/null; then
                ok "mirror reachable" "TCP ${_port:-80} open"
            else
                fail "mirror reachable" "cannot connect to $_hostname:${_port:-80}"
            fi
        else
            fail "DNS lookup" "$_hostname does not resolve (Settings > DNS)"
        fi
    else
        kv "DNS / mirror" "not checked (Ubuntu not mounted)"
    fi

    sec Config
    kv MOUNT_SDCARD "$MOUNT_SDCARD"
    kv ANDROID_INTEGRATION "$ANDROID_INTEGRATION"
    kv DEFAULT_USER "$(ident "$DEFAULT_USER")"
    kv APT_MIRROR "${APT_MIRROR:-default}"
    kv BOOT_START "$BOOT_START"
    kv INOTIFY_MAX_WATCHES "$INOTIFY_MAX_WATCHES (now $(cat "$UBU_INOTIFY_FILE" 2>/dev/null))"
    kv "boot module" "$("$UBU_SH" "$UBU_BIN_DIR/boot.sh" --status 2>/dev/null | bb awk -F= '$1 == "module" { print $2 }')"

    printf '\nsummary: %s failed, %s warnings\n' "$NFAIL" "$NWARN"
}

# Identifiers that must not appear in a redacted report, one per line: the
# safety net for anything that slips past ident().
identifiers() {
    for _p in ro.serialno ro.boot.serialno; do prop "$_p"; echo; done
    cat /proc/sys/kernel/hostname 2>/dev/null
    printf '%s\n%s\n' "$UBU_HOSTNAME" "$DEFAULT_USER"
    bb awk -F: '$3 >= 1000 && $3 < 60000 { print $1 }' "$R/etc/passwd" 2>/dev/null
    if [ -x /system/bin/ip ]; then
        /system/bin/ip -o addr show 2>/dev/null | bb awk '{ sub(/\/.*/, "", $4); print $4 }'
    fi
    bb awk '$1 == "nameserver" { print $2 }' "$R/etc/resolv.conf" 2>/dev/null
}

if [ "$REDACT" = 1 ]; then
    _ids=$(identifiers | bb awk 'length($0) > 0 && $0 != "localhost" && $0 != "uburoot" && $0 != "127.0.0.1" && $0 != "::1"' | bb sort -u)
    # Whole words only (a user called "ana" must not turn "analysis" into garbage).
    report | bb awk -v ids="$_ids" '
        BEGIN { n = split(ids, id, "\n") }
        function word(c) { return c ~ /[A-Za-z0-9_:-]/ }
        function red(s, x,   out, i, pre, post) {
            out = ""
            while ((i = index(s, x)) > 0) {
                pre = i > 1 ? substr(s, i - 1, 1) : ""
                post = substr(s, i + length(x), 1)
                if (!word(pre) && !word(post)) out = out substr(s, 1, i - 1) "<redacted>"
                else out = out substr(s, 1, i + length(x) - 1)
                s = substr(s, i + length(x))
            }
            return out s
        }
        { for (k = 1; k <= n; k++) if (id[k] != "") $0 = red($0, id[k]); print }'
else
    report
fi
exit 0
