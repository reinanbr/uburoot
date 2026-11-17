#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Post-install configuration of the Ubuntu rootfs. Safe to re-run.
# Usage: setup.sh [options]
#   --user NAME        create this user (with sudo)
#   --uid N            UID/GID for the user (default: first free from 9000; must be < 10000, see CLAUDE.md)
#   --nopasswd         passwordless sudo for the user
#   --password-stdin   read the user's password from the first line of stdin
#   --dns "A B"        DNS servers (default: DNS_SERVERS from config)
#   --hostname NAME    hostname (default: UBU_HOSTNAME from config)
#   --no-apt           skip apt-get update / package installation (offline)
#   --dns-only         only rewrite /etc/resolv.conf (the app's DNS setting), then exit
#   --sources-only     only rewrite the APT sources (the app's mirror setting), then exit
#   --migrate          only bring the integration files of an installed rootfs up to
#                      this version (numbered migrations, see migrate_N below), then exit
#
# /etc/uburoot-release records SCHEMA (integration version, UBU_SCHEMA in
# common.sh), INSTALLED (first setup) and UBUNTU (VERSION_ID codename).
set -u
UBU_BIN_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$UBU_BIN_DIR/common.sh"

ubu_require_root
ubu_init
ubu_load_config
ubu_rootfs_installed || ubu_die "no Ubuntu rootfs at $ROOTFS (run install.sh first)"

R=$ROOTFS
NEW_USER=""
NEW_UID=""
NOPASSWD=0
PASSWORD_STDIN=0
DNS=$DNS_SERVERS
HOST=$UBU_HOSTNAME
DO_APT=1
DNS_ONLY=0
SOURCES_ONLY=0
MIGRATE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --user) NEW_USER=${2:-}; shift ;;
        --uid) NEW_UID=${2:-}; shift ;;
        --nopasswd) NOPASSWD=1 ;;
        --password-stdin) PASSWORD_STDIN=1 ;;
        --dns) DNS=${2:-}; shift ;;
        --hostname) HOST=${2:-}; shift ;;
        --no-apt) DO_APT=0 ;;
        --dns-only) DNS_ONLY=1 ;;
        --sources-only) SOURCES_ONLY=1 ;;
        --migrate) MIGRATE=1 ;;
        *) ubu_die "unknown option: $1" ;;
    esac
    shift
done

if [ -n "$NEW_USER" ]; then
    case "$NEW_USER" in
        root) ubu_die "--user must not be root" ;;
        [a-z_]*) ;;
        *) ubu_die "invalid user name: $NEW_USER" ;;
    esac
    case "$NEW_USER" in
        *[!a-z0-9_-]*) ubu_die "invalid user name: $NEW_USER" ;;
    esac
    if [ -n "$NEW_UID" ]; then
        case "$NEW_UID" in
            *[!0-9]*) ubu_die "invalid uid: $NEW_UID" ;;
        esac
        [ "$NEW_UID" -ge 1000 ] || ubu_die "uid must be >= 1000"
    fi
fi
case "$HOST" in
    '' | *[!a-zA-Z0-9-]*) ubu_die "invalid hostname: $HOST" ;;
esac
[ -n "$DNS" ] || ubu_die "no DNS servers"
for _s in $DNS; do
    case "$_s" in
        *[!0-9a-fA-F.:]*) ubu_die "invalid DNS server: $_s" ;;
    esac
done

USER_PW=""
if [ "$PASSWORD_STDIN" = 1 ]; then
    IFS= read -r USER_PW || [ -n "$USER_PW" ] || ubu_die "no password on stdin"
fi

write_resolv_conf() {
    rm -f "$R/etc/resolv.conf"
    {
        printf '# Written by UbuRoot setup.sh (DNS configurable in the app)\n'
        for _s in $DNS; do printf 'nameserver %s\n' "$_s"; done
    } >"$R/etc/resolv.conf" || ubu_die "cannot write resolv.conf"
}

if [ "$DNS_ONLY" = 1 ]; then
    [ -d "$R/etc" ] || ubu_die "no rootfs at $R"
    write_resolv_conf
    ubu_log "resolv.conf: $DNS"
    exit 0
fi

# --- APT sources -----------------------------------------------------------------
# The architecture comes from dpkg's ELF header: no chroot (and no mounts) needed.
write_sources() {
    _osr="$R/usr/lib/os-release"
    [ -f "$_osr" ] || _osr="$R/etc/os-release"
    CODENAME=$(bb awk -F= '$1 == "VERSION_CODENAME" { gsub(/"/, "", $2); print $2 }' "$_osr")
    [ -n "$CODENAME" ] || ubu_die "cannot determine Ubuntu codename"
    ARCH=$(ubu_elf_arch "$R/usr/bin/dpkg") || ubu_die "cannot determine the rootfs architecture"
    # APT_MIRROR serves the release suites; security updates always come from
    # Canonical (security.ubuntu.com, or the ports archive for non-x86).
    case "$ARCH" in
        amd64 | i386)
            _def=http://archive.ubuntu.com/ubuntu/
            SEC_URI=http://security.ubuntu.com/ubuntu/
            ;;
        *)
            _def=$UBU_PORTS_MIRROR_DEFAULT
            SEC_URI=$UBU_PORTS_MIRROR_DEFAULT
            ;;
    esac
    MAIN_URI=${APT_MIRROR:-$_def}
    ubu_valid_mirror "$MAIN_URI" || ubu_die "invalid APT_MIRROR: $MAIN_URI (http://host/path/)"
    ubu_log "apt sources: $CODENAME/$ARCH -> $MAIN_URI"
    mkdir -p "$R/etc/apt/sources.list.d"
    cat >"$R/etc/apt/sources.list.d/ubuntu.sources" <<EOF
# Written by UbuRoot setup.sh
Types: deb
URIs: $MAIN_URI
Suites: $CODENAME $CODENAME-updates $CODENAME-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $SEC_URI
Suites: $CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    printf '# UbuRoot: sources are in /etc/apt/sources.list.d/ubuntu.sources\n' >"$R/etc/apt/sources.list"
}

if [ "$SOURCES_ONLY" = 1 ]; then
    write_sources
    exit 0
fi

if [ "$MIGRATE" = 1 ]; then
    [ -f "$R/etc/uburoot-setup.done" ] || ubu_die "setup has not run yet: nothing to migrate"
    FROM=$(ubu_rootfs_schema)
    if [ "$FROM" -ge "$UBU_SCHEMA" ]; then
        [ "$FROM" -eq "$UBU_SCHEMA" ] ||
            ubu_warn "rootfs schema $FROM is newer than these scripts ($UBU_SCHEMA); leaving it alone"
        ubu_log "integration files are up to date (schema $FROM)"
        exit 0
    fi
fi

"$UBU_SH" "$UBU_BIN_DIR/mount.sh" || ubu_die "mount.sh failed"

CHROOT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
in_chroot() {
    bb chroot "$R" /usr/bin/env -i HOME=/root LANG=C.UTF-8 PATH="$CHROOT_PATH" \
        DEBIAN_FRONTEND=noninteractive "$@"
}

# --- Network files (full setup only) ---------------------------------------
write_network_files() {
    ubu_log "writing resolv.conf, hosts, hostname"
    write_resolv_conf
    printf '%s\n' "$HOST" >"$R/etc/hostname"
    cat >"$R/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOST
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
    # The kernel hostname is Android's (shared UTS namespace); keep it resolvable.
    _kh=$(cat /proc/sys/kernel/hostname 2>/dev/null) || _kh=""
    if [ -n "$_kh" ] && [ "$_kh" != "$HOST" ] && [ "$_kh" != localhost ]; then
        printf '127.0.1.1   %s\n' "$_kh" >>"$R/etc/hosts"
    fi
}

# --- Integration files ------------------------------------------------------------
# Everything below is UbuRoot's own and safe to rewrite: full setup and the
# migrations call these functions.
write_service_files() {
    printf 'LANG=C.UTF-8\n' >"$R/etc/default/locale"
    cat >"$R/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
# UbuRoot: no init system in the chroot; never auto-start daemons on install.
exit 101
EOF
    chmod 755 "$R/usr/sbin/policy-rc.d"
    ubu_write_profile_hook "$R" || ubu_warn "could not write profile hook"
}

# --- Android paranoid-network groups --------------------------------------
# On Android kernels (CONFIG_ANDROID_PARANOID_NETWORK) these groups are more
# than socket permissions: membership in aid_net_raw acts as CAP_NET_RAW and
# aid_net_admin as CAP_NET_ADMIN. Seen on a device: a user in them could
# tcpdump the whole phone's traffic and add links in the host netns without
# sudo. So only root gets them; the user and _apt get aid_inet (sockets) only.
# Ping needs neither: Android's init.rc sets ping_group_range to all gids.
# Opt in by hand with: sudo usermod -aG aid_net_raw,aid_net_admin <user>
# Prints the group name that owns GID $2 (creating $1 with that GID if needed).
ensure_group() {
    _owner=$(bb awk -F: -v g="$2" '$3 == g { print $1; exit }' "$R/etc/group")
    if [ -n "$_owner" ]; then
        printf '%s' "$_owner"
        return 0
    fi
    in_chroot groupadd -g "$2" "$1" || return 1
    printf '%s' "$1"
}
# Removes $1 from group $2 if it is a member (older setups added it).
drop_from_group() {
    if bb awk -F: -v g="$2" -v u="$1" '$1 == g { n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] == u) f = 1 } END { exit !f }' "$R/etc/group"; then
        in_chroot gpasswd -d "$1" "$2" >/dev/null && ubu_log "removed $1 from $2"
    fi
}
write_groups() {
    G_INET=$(ensure_group aid_inet 3003) || ubu_die "cannot create group aid_inet"
    G_RAW=$(ensure_group aid_net_raw 3004) || ubu_die "cannot create group aid_net_raw"
    G_ADMIN=$(ensure_group aid_net_admin 3005) || ubu_die "cannot create group aid_net_admin"
    AID_GROUPS="$G_INET,$G_RAW,$G_ADMIN"
    ubu_log "network groups: $AID_GROUPS (root), $G_INET (users)"
    # /sdcard is usually /data/media/0 (media_rw:media_rw 2770); see mount.sh.
    G_MEDIA=$(ensure_group aid_media_rw 1023) || ubu_die "cannot create group aid_media_rw"

    in_chroot usermod -a -G "$AID_GROUPS" root || ubu_warn "usermod root failed"
    if grep -q '^_apt:' "$R/etc/passwd"; then
        # APT drops privileges with setgroups(1, &pw_gid): only the PRIMARY group
        # survives, so _apt needs aid_inet as its primary group.
        in_chroot usermod -g "$G_INET" _apt || ubu_warn "usermod _apt failed"
        drop_from_group _apt "$G_RAW"
        drop_from_group _apt "$G_ADMIN"
    fi
}

# --- iptables backend ---------------------------------------------------------
# The chroot shares Android's network namespace, so iptables in Ubuntu edits
# the phone's firewall. Ubuntu defaults to iptables-nft, but Android's netd
# uses the legacy xtables (and kernels like 4.9 have no nf_tables at all), so
# point iptables/ip6tables at whichever backend holds Android's tables. An apt
# hook re-runs this after every dpkg run (iptables may be installed later);
# a choice the user made by hand (manual mode) is left alone.
write_iptables_select() {
    mkdir -p "$R/usr/local/sbin"
    cat >"$R/usr/local/sbin/uburoot-iptables-select" <<'EOF'
#!/bin/sh
# UbuRoot: use the iptables backend that holds Android's rules (see setup.sh).
for t in iptables ip6tables; do
    [ -x "/usr/sbin/$t-legacy" ] || continue
    case "$t" in
        iptables) names=/proc/net/ip_tables_names ;;
        *) names=/proc/net/ip6_tables_names ;;
    esac
    # /proc files report size 0, so read them. Empty: Android is not on legacy.
    [ -n "$(cat "$names" 2>/dev/null)" ] || continue
    update-alternatives --query "$t" 2>/dev/null | grep -qx 'Status: auto' || continue
    update-alternatives --set "$t" "/usr/sbin/$t-legacy" >/dev/null &&
        echo "uburoot: $t -> $t-legacy (Android's tables; rules apply to the whole phone)"
done
exit 0
EOF
    chmod 755 "$R/usr/local/sbin/uburoot-iptables-select"
    cat >"$R/etc/apt/apt.conf.d/80uburoot-iptables" <<'EOF'
// Written by UbuRoot setup.sh: keep iptables on Android's backend.
DPkg::Post-Invoke { "if [ -x /usr/local/sbin/uburoot-iptables-select ]; then /usr/local/sbin/uburoot-iptables-select || true; fi"; };
EOF
    in_chroot /usr/local/sbin/uburoot-iptables-select || ubu_warn "uburoot-iptables-select failed"
}

# --- /etc/uburoot-release -------------------------------------------------------
write_release() {
    _f="$R/etc/uburoot-release"
    _inst=$(bb awk -F= '$1 == "INSTALLED" { print $2; exit }' "$_f" 2>/dev/null)
    if [ -z "$_inst" ]; then
        # A rootfs set up before this file existed: the setup marker's date.
        _inst=$(bb date -r "$R/etc/uburoot-setup.done" +%Y-%m-%d 2>/dev/null) || _inst=$(date +%Y-%m-%d)
    fi
    _osr="$R/usr/lib/os-release"
    [ -f "$_osr" ] || _osr="$R/etc/os-release"
    _ubu=$(bb awk -F= '$1 == "VERSION_ID" || $1 == "VERSION_CODENAME" { gsub(/"/, "", $2); v = v (v == "" ? "" : " ") $2 } END { print v }' "$_osr")
    {
        printf '# Written by UbuRoot setup.sh. SCHEMA = version of the integration files.\n'
        printf 'SCHEMA=%s\n' "$UBU_SCHEMA"
        printf 'INSTALLED=%s\n' "$_inst"
        printf 'UBUNTU=%s\n' "$_ubu"
    } >"$_f.new" || ubu_die "cannot write $_f"
    mv "$_f.new" "$_f" || ubu_die "cannot write $_f"
}

# --- Migrations ---------------------------------------------------------------------
# migrate_N brings a rootfs from schema N-1 to N. Each must be idempotent and
# touch only UbuRoot's own files (never apt sources, users or packages).
# 0 -> 1: rootfs set up by 0.1.x/0.2.x, before /etc/uburoot-release existed.
# shellcheck disable=SC2317,SC2329 # called as "migrate_$_n" below (SC2317 in older shellcheck)
migrate_1() {
    write_service_files
    write_groups
    write_iptables_select
}
# 1 -> 2: the profile hook sets DISPLAY=:0 for Linux GUI apps (x11.sh).
# shellcheck disable=SC2317,SC2329
migrate_2() {
    ubu_write_profile_hook "$R"
}

if [ "$MIGRATE" = 1 ]; then
    _n=$((FROM + 1))
    while [ "$_n" -le "$UBU_SCHEMA" ]; do
        ubu_log "migration $_n"
        "migrate_$_n" || ubu_die "migration $_n failed"
        _n=$((_n + 1))
    done
    write_release
    ubu_log "integration files: schema $FROM -> $UBU_SCHEMA"
    exit 0
fi

write_network_files
write_service_files
write_groups
write_iptables_select
write_sources

# --- Packages ----------------------------------------------------------------
if [ "$DO_APT" = 1 ]; then
    ubu_log "apt-get update"
    # Retry once with the _apt sandbox first: failures are often transient
    # (seen on a real device), and running downloads as root is the fallback.
    if ! in_chroot apt-get update && ! { sleep 3 && in_chroot apt-get update; }; then
        ubu_warn "apt-get update failed twice with the _apt sandbox; retrying as root"
        printf 'APT::Sandbox::User "root";\n' >"$R/etc/apt/apt.conf.d/01uburoot-sandbox"
        in_chroot apt-get update || ubu_die "apt-get update failed (network/DNS?)"
    fi
    ubu_log "installing sudo"
    in_chroot apt-get install -y --no-install-recommends sudo kmod || ubu_die "apt-get install sudo kmod failed"
fi

# --- User ------------------------------------------------------------------------
# netd's BPF firewall exempts only uid < 10000 (AID_APP_START). Higher uids are
# app uids and get dropped whenever an allowlist chain (restricted networking,
# doze, powersave) is on; 20000+ is also the SDK sandbox range since Android 13.
ubu_uid_ok() {
    case "$1" in '' | *[!0-9]*) return 1 ;; esac
    [ "$1" -ge 8000 ] && [ "$1" -le 9996 ]
}
# First id >= 9000 that is free both as a uid and as a gid.
ubu_free_id() {
    _id=9000
    while [ "$_id" -le 9996 ]; do
        if ! bb awk -F: -v i="$_id" '$3 == i { f = 1 } END { exit !f }' "$R/etc/passwd" "$R/etc/group"; then
            printf '%s' "$_id"
            return 0
        fi
        _id=$((_id + 1))
    done
    return 1
}
if [ -n "$NEW_USER" ]; then
    if grep -q "^$NEW_USER:" "$R/etc/passwd"; then
        ubu_log "user $NEW_USER already exists"
        _cur=$(bb awk -F: -v u="$NEW_USER" '$1 == u { print $3; exit }' "$R/etc/passwd")
        ubu_uid_ok "$_cur" ||
            ubu_warn "existing user $NEW_USER has uid $_cur (outside 8000-9996); network may be blocked"
    else
        if [ -z "$NEW_UID" ]; then
            NEW_UID=$(ubu_free_id) || ubu_die "no free uid/gid in 9000-9996"
        fi
        ubu_uid_ok "$NEW_UID" ||
            ubu_warn "uid $NEW_UID is outside 8000-9996: network may be blocked or it may clash with an Android AID"
        if ! grep -q "^$NEW_USER:" "$R/etc/group"; then
            in_chroot groupadd -g "$NEW_UID" "$NEW_USER" || ubu_die "groupadd $NEW_USER failed"
        fi
        in_chroot useradd -m -u "$NEW_UID" -g "$NEW_USER" -s /bin/bash "$NEW_USER" ||
            ubu_die "useradd $NEW_USER failed"
        ubu_log "created user $NEW_USER (uid $NEW_UID)"
    fi
    _groups="$G_INET,$G_MEDIA"
    grep -q '^sudo:' "$R/etc/group" && _groups="sudo,$_groups"
    in_chroot usermod -a -G "$_groups" "$NEW_USER" || ubu_warn "usermod $NEW_USER failed"
    drop_from_group "$NEW_USER" "$G_RAW"
    drop_from_group "$NEW_USER" "$G_ADMIN"
    if [ -n "$USER_PW" ]; then
        printf '%s:%s\n' "$NEW_USER" "$USER_PW" | bb chroot "$R" /usr/bin/env -i \
            PATH="$CHROOT_PATH" chpasswd || ubu_warn "setting the password failed"
    fi
    _sudoers="$R/etc/sudoers.d/90-uburoot-$NEW_USER"
    if [ "$NOPASSWD" = 1 ]; then
        mkdir -p "$R/etc/sudoers.d"
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$NEW_USER" >"$_sudoers" && chmod 440 "$_sudoers"
    else
        rm -f "$_sudoers"
    fi
fi

date >"$R/etc/uburoot-setup.done" 2>/dev/null
write_release
ubu_log "setup complete"
exit 0
