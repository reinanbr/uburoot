#!/system/bin/sh
# Post-install configuration of the Ubuntu rootfs. Safe to re-run.
# Usage: setup.sh [options]
#   --user NAME        create this user (with sudo)
#   --uid N            UID/GID for the user (default 9000, must be < 10000; see CLAUDE.md)
#   --nopasswd         passwordless sudo for the user
#   --password-stdin   read the user's password from the first line of stdin
#   --dns "A B"        DNS servers (default: DNS_SERVERS from config)
#   --hostname NAME    hostname (default: UBU_HOSTNAME from config)
#   --no-apt           skip apt-get update / package installation (offline)
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
NEW_UID=9000
NOPASSWD=0
PASSWORD_STDIN=0
DNS=$DNS_SERVERS
HOST=$UBU_HOSTNAME
DO_APT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --user) NEW_USER=${2:-}; shift ;;
        --uid) NEW_UID=${2:-}; shift ;;
        --nopasswd) NOPASSWD=1 ;;
        --password-stdin) PASSWORD_STDIN=1 ;;
        --dns) DNS=${2:-}; shift ;;
        --hostname) HOST=${2:-}; shift ;;
        --no-apt) DO_APT=0 ;;
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
    case "$NEW_UID" in
        '' | *[!0-9]*) ubu_die "invalid uid: $NEW_UID" ;;
    esac
    [ "$NEW_UID" -ge 1000 ] || ubu_die "uid must be >= 1000"
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

"$UBU_SH" "$UBU_BIN_DIR/mount.sh" || ubu_die "mount.sh failed"

CHROOT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
in_chroot() {
    bb chroot "$R" /usr/bin/env -i HOME=/root LANG=C.UTF-8 PATH="$CHROOT_PATH" \
        DEBIAN_FRONTEND=noninteractive "$@"
}

# --- Network files -------------------------------------------------------
ubu_log "writing resolv.conf, hosts, hostname"
rm -f "$R/etc/resolv.conf"
{
    printf '# Written by UbuRoot setup.sh (DNS configurable in the app)\n'
    for _s in $DNS; do printf 'nameserver %s\n' "$_s"; done
} >"$R/etc/resolv.conf" || ubu_die "cannot write resolv.conf"
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

# --- Locale / services -------------------------------------------------------
printf 'LANG=C.UTF-8\n' >"$R/etc/default/locale"
cat >"$R/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
# UbuRoot: no init system in the chroot; never auto-start daemons on install.
exit 101
EOF
chmod 755 "$R/usr/sbin/policy-rc.d"
ubu_ensure_profile_hook "$R" || ubu_warn "could not write profile hook"

# --- Android paranoid-network groups --------------------------------------
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
G_INET=$(ensure_group aid_inet 3003) || ubu_die "cannot create group aid_inet"
G_RAW=$(ensure_group aid_net_raw 3004) || ubu_die "cannot create group aid_net_raw"
G_ADMIN=$(ensure_group aid_net_admin 3005) || ubu_die "cannot create group aid_net_admin"
AID_GROUPS="$G_INET,$G_RAW,$G_ADMIN"
ubu_log "network groups: $AID_GROUPS"
# /sdcard is usually /data/media/0 (media_rw:media_rw 2770); see mount.sh.
G_MEDIA=$(ensure_group aid_media_rw 1023) || ubu_die "cannot create group aid_media_rw"

in_chroot usermod -a -G "$AID_GROUPS" root || ubu_warn "usermod root failed"
if grep -q '^_apt:' "$R/etc/passwd"; then
    # APT drops privileges with setgroups(1, &pw_gid): only the PRIMARY group
    # survives, so _apt needs aid_inet as its primary group.
    in_chroot usermod -g "$G_INET" -a -G "$AID_GROUPS" _apt || ubu_warn "usermod _apt failed"
fi

# --- APT sources ---------------------------------------------------------------
_osr="$R/usr/lib/os-release"
[ -f "$_osr" ] || _osr="$R/etc/os-release"
CODENAME=$(bb awk -F= '$1 == "VERSION_CODENAME" { gsub(/"/, "", $2); print $2 }' "$_osr")
[ -n "$CODENAME" ] || ubu_die "cannot determine Ubuntu codename"
ARCH=$(in_chroot dpkg --print-architecture) || ubu_die "dpkg not working in chroot"
case "$ARCH" in
    amd64 | i386)
        MAIN_URI=http://archive.ubuntu.com/ubuntu/
        SEC_URI=http://security.ubuntu.com/ubuntu/
        ;;
    *)
        MAIN_URI=http://ports.ubuntu.com/ubuntu-ports/
        SEC_URI=http://ports.ubuntu.com/ubuntu-ports/
        ;;
esac
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
    in_chroot apt-get install -y --no-install-recommends sudo || ubu_die "apt-get install sudo failed"
fi

# --- User ------------------------------------------------------------------------
# netd's BPF firewall exempts only uid < 10000 (AID_APP_START). Higher uids are
# app uids and get dropped whenever an allowlist chain (restricted networking,
# doze, powersave) is on; 20000+ is also the SDK sandbox range since Android 13.
ubu_uid_ok() {
    case "$1" in '' | *[!0-9]*) return 1 ;; esac
    [ "$1" -ge 8000 ] && [ "$1" -le 9996 ]
}
if [ -n "$NEW_USER" ]; then
    ubu_uid_ok "$NEW_UID" ||
        ubu_warn "uid $NEW_UID is outside 8000-9996: network may be blocked or it may clash with an Android AID"
    if grep -q "^$NEW_USER:" "$R/etc/passwd"; then
        ubu_log "user $NEW_USER already exists"
        _cur=$(bb awk -F: -v u="$NEW_USER" '$1 == u { print $3; exit }' "$R/etc/passwd")
        ubu_uid_ok "$_cur" ||
            ubu_warn "existing user $NEW_USER has uid $_cur (outside 8000-9996); network may be blocked"
    else
        if ! grep -q "^$NEW_USER:" "$R/etc/group"; then
            in_chroot groupadd -g "$NEW_UID" "$NEW_USER" || ubu_die "groupadd $NEW_USER failed"
        fi
        in_chroot useradd -m -u "$NEW_UID" -g "$NEW_USER" -s /bin/bash "$NEW_USER" ||
            ubu_die "useradd $NEW_USER failed"
        ubu_log "created user $NEW_USER (uid $NEW_UID)"
    fi
    _groups="$AID_GROUPS,$G_MEDIA"
    grep -q '^sudo:' "$R/etc/group" && _groups="sudo,$_groups"
    in_chroot usermod -a -G "$_groups" "$NEW_USER" || ubu_warn "usermod $NEW_USER failed"
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
ubu_log "setup complete"
exit 0
