#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# GPU acceleration for Linux apps (docs/GUI.md). On Adreno, Mesa's Turnip (Vulkan) built
# with the KGSL backend, the kernel driver Android uses (tools/gpu/build-turnip.sh):
# Ubuntu's own Turnip has only the upstream "msm" backend and finds no GPU on Android.
# OpenGL then runs on it through Zink (MESA_LOADER_DRIVER_OVERRIDE=zink, set for login
# shells by the profile hook from /etc/uburoot/gpu.env).
#
# Usage: gpu.sh status               gpu=adreno|none, model=, driver=installed|missing,
#                                    mesa=VERSION, zink=on|off
#        gpu.sh install FILE SHA256  the release's turnip-kgsl-arm64.tar.gz (zink on)
#        gpu.sh remove
#        gpu.sh zink on|off
#        gpu.sh renderer USER        vulkan=DEVICE, opengl=RENDERER (as USER; needs
#                                    vulkan-tools / mesa-utils, OpenGL needs the display)
set -u
UBU_BIN_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)
# shellcheck source=common.sh
. "$UBU_BIN_DIR/common.sh"

ubu_require_root
ubu_init
ubu_load_config

R=$ROOTFS
KGSL_DEV=${UBU_KGSL_DEV:-/dev/kgsl-3d0}
KGSL_SYS=${UBU_KGSL_SYS:-/sys/class/kgsl/kgsl-3d0}
GPU_DIR=usr/local/lib/uburoot/gpu
LIB=$GPU_DIR/libvulkan_freedreno_kgsl.so
INFO=$GPU_DIR/BUILDINFO
ICD=usr/local/share/vulkan/icd.d/uburoot_freedreno_kgsl_icd.json
ENVF="$R/etc/uburoot/gpu.env"

installed() { [ -f "$R/$LIB" ] && [ -f "$R/$ICD" ]; }

status() {
    if [ -e "$KGSL_DEV" ] && [ -d "$KGSL_SYS" ]; then
        echo "gpu=adreno"
        echo "model=$(cat "$KGSL_SYS/gpu_model" 2>/dev/null)"
    else
        echo "gpu=none"
    fi
    if installed; then
        echo "driver=installed"
        echo "mesa=$(bb sed -n 's/^mesa=//p' "$R/$INFO" 2>/dev/null)"
    else
        echo "driver=missing"
    fi
    if [ -f "$ENVF" ] && bb grep -q zink "$ENVF"; then echo "zink=on"; else echo "zink=off"; fi
}

# The directory must resolve to itself inside the rootfs: no symlink out of it.
safe_dir() {
    mkdir -p "$R/$1" || return 1
    _rp=$(readlink -f "$R/$1") || return 1
    [ "$_rp" = "$(readlink -f "$R")/$1" ]
}

zink() { # on|off
    case "$1" in
        on)
            installed || ubu_die "the GPU driver is not installed"
            safe_dir etc/uburoot || ubu_die "unsafe /etc/uburoot"
            {
                echo "# Written by UbuRoot (gpu.sh zink on|off): OpenGL on the GPU's Vulkan driver."
                echo "export MESA_LOADER_DRIVER_OVERRIDE=zink"
            } >"$ENVF.new" && chmod 644 "$ENVF.new" && mv -f "$ENVF.new" "$ENVF"
            ;;
        off) rm -f "$ENVF" ;;
        *) ubu_die "usage: gpu.sh zink on|off" ;;
    esac
}

# Only these regular files (and their directories) may be in the archive.
WANT="usr/ usr/local/ usr/local/lib/ usr/local/lib/uburoot/ $GPU_DIR/ $LIB $INFO
usr/local/share/ usr/local/share/vulkan/ usr/local/share/vulkan/icd.d/ $ICD"

install_gpu() { # FILE SHA256
    [ -f "$1" ] || ubu_die "no file $1"
    case "$2" in *[!0-9a-fA-F]* | '') ubu_die "invalid SHA256: $2" ;; esac
    [ ${#2} = 64 ] || ubu_die "invalid SHA256: $2"
    ubu_rootfs_installed || ubu_die "Ubuntu is not installed"
    _sum=$(bb sha256sum "$1" | bb awk '{ print $1 }')
    [ "$_sum" = "$(echo "$2" | tr 'A-F' 'a-f')" ] || ubu_die "SHA256 mismatch ($_sum)"
    # Every entry: a directory or a regular file from the list above.
    _bad=$(bb tar tvzf "$1" 2>/dev/null | bb awk -v want="$WANT" '
        BEGIN { n = split(want, w, /[ \n]+/); for (i = 1; i <= n; i++) ok[w[i]] = 1 }
        { t = substr($1, 1, 1); name = $NF; sub(/^\.\//, "", name)
          if ((t != "-" && t != "d") || !(name in ok)) { print name; exit } }
        END { if (NR == 0) print "(empty or unreadable archive)" }')
    [ -z "$_bad" ] || ubu_die "unexpected entry in the archive: $_bad"
    for _d in "$GPU_DIR" usr/local/share/vulkan/icd.d; do
        safe_dir "$_d" || ubu_die "unsafe directory /$_d in Ubuntu"
    done
    # Each file through stdout: we choose where it is written, never the archive.
    for _f in "$LIB" "$INFO" "$ICD"; do
        bb tar xzOf "$1" "$_f" >"$R/$_f.new" 2>/dev/null || {
            rm -f "$R/$_f.new"
            ubu_die "cannot extract $_f"
        }
        chown 0:0 "$R/$_f.new"
        chmod 644 "$R/$_f.new"
    done
    chmod 755 "$R/$LIB.new"
    for _f in "$LIB" "$INFO" "$ICD"; do mv -f "$R/$_f.new" "$R/$_f" || ubu_die "cannot install $_f"; done
    zink on
    ubu_log "GPU driver installed: Mesa $(bb sed -n 's/^mesa=//p' "$R/$INFO")"
}

remove() {
    rm -f "$R/$LIB" "$R/$INFO" "$R/$ICD" "$ENVF"
    rmdir "$R/$GPU_DIR" 2>/dev/null
    ubu_log "GPU driver removed"
}

# What the user's apps get: run as USER in a login shell (so gpu.env applies).
renderer() { # USER
    case "$1" in root) ;; [a-z_]*) case "$1" in *[!a-z0-9_-]*) ubu_die "invalid user name: $1" ;; esac ;; *) ubu_die "invalid user name: $1" ;; esac
    bb awk -F: -v u="$1" '$1 == u { f = 1 } END { exit !f }' "$R/etc/passwd" || ubu_die "no user $1 in Ubuntu"
    "$UBU_BIN_DIR/mount.sh" >/dev/null 2>&1 || ubu_die "mount.sh failed"
    safe_dir run/uburoot-gpu || ubu_die "unsafe /run/uburoot-gpu"
    chown 0:0 "$R/run/uburoot-gpu" && chmod 755 "$R/run/uburoot-gpu"
    cat >"$R/run/uburoot-gpu/probe" <<'EOF'
export DISPLAY=:0
if command -v vulkaninfo >/dev/null; then
    timeout 20 vulkaninfo --summary 2>/dev/null | awk -F'= ' '/deviceName/ { print "vulkan=" $2; exit }'
else
    echo "vulkan=?"
fi
if ! command -v glxinfo >/dev/null; then
    echo "opengl=?"
elif [ -S /tmp/.X11-unix/X0 ]; then
    timeout 20 glxinfo -B 2>/dev/null | sed -n 's/^OpenGL renderer string: /opengl=/p'
else
    echo "opengl=-"
fi
EOF
    chmod 644 "$R/run/uburoot-gpu/probe"
    "$UBU_BIN_DIR/enter.sh" "$1" "sh /run/uburoot-gpu/probe" </dev/null 2>/dev/null | bb grep -E '^(vulkan|opengl)='
}

case "${1:-}" in
    status) status ;;
    install)
        [ $# = 3 ] || ubu_die "usage: gpu.sh install FILE SHA256"
        install_gpu "$2" "$3"
        ;;
    remove) remove ;;
    zink) zink "${2:-}" ;;
    renderer) renderer "${2:-${DEFAULT_USER:-root}}" ;;
    *) ubu_die "usage: gpu.sh status|install FILE SHA256|remove|zink on|off|renderer [USER]" ;;
esac
