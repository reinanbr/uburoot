#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# uburoot-kbuild: build out-of-tree kernel modules for the phone's running kernel,
# inside Ubuntu (installed by mount.sh as /usr/local/sbin/uburoot-kbuild with
# KERNEL_ACCESS=1).
#
# Usage:
#   uburoot-kbuild check          what a module must match to load on this kernel
#   uburoot-kbuild prepare SRC    set up the kernel source tree SRC for the running
#                                 kernel: /proc/config.gz, LOCALVERSION so that
#                                 `make kernelrelease` = `uname -r`, modules_prepare
#   uburoot-kbuild build DIR      build the module in DIR against the prepared tree
# Extra make arguments (e.g. LLVM=1 for kernels built with clang) go in
# UBU_KBUILD_MAKEFLAGS. The source must be the exact kernel the phone runs.
set -u
KCONFIG=${UBU_KCONFIG:-/proc/config.gz}
STATE_DIR=${UBU_KBUILD_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/uburoot}
SRC_FILE="$STATE_DIR/kbuild-src"
MAKEFLAGS_EXTRA=${UBU_KBUILD_MAKEFLAGS:-}

die() { printf 'uburoot-kbuild: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

config() { # the running kernel's .config on stdout
    [ -r "$KCONFIG" ] || return 1
    gzip -dc "$KCONFIG" 2>/dev/null
}
opt() { # NAME -> y, m or n
    config | awk -F= -v k="CONFIG_$1" '$1 == k { v = $2 } END { print (v == "" ? "n" : v) }'
}

check() {
    _kr=$(uname -r)
    say "kernel release:     $_kr ($(uname -m))"
    case "$_kr" in
        *-android[0-9]*-*)
            _a=$(printf '%s' "$_kr" | sed 's/.*-\(android[0-9]*\)-.*/\1/')
            _v=$(printf '%s' "$_kr" | cut -d. -f1-2)
            say "kernel type:        GKI ($_a-$_v)"
            say "source:             Android Common Kernel, branch $_a-$_v"
            say "                    (https://android.googlesource.com/kernel/common; the g<hash> in"
            say "                    the release names the exact commit)"
            ;;
        *)
            say "kernel type:        vendor kernel (not GKI)"
            say "source:             the phone vendor's or the ROM's kernel source for this device,"
            say "                    at the exact version above"
            ;;
    esac
    if ! config >/dev/null; then
        say "config:             no $KCONFIG: the kernel's configuration is unknown,"
        say "                    so a matching build can't be prepared"
        return 0
    fi
    say "config:             $KCONFIG"
    _vm="$_kr "
    [ "$(opt SMP)" = y ] && _vm="${_vm}SMP "
    case "$(opt PREEMPT_RT):$(opt PREEMPT)" in
        y:*) _vm="${_vm}preempt_rt " ;;
        *:y) _vm="${_vm}preempt " ;;
    esac
    [ "$(opt MODULE_UNLOAD)" = y ] && _vm="${_vm}mod_unload "
    [ "$(opt MODVERSIONS)" = y ] && _vm="${_vm}modversions "
    case "$(uname -m)" in
        aarch64) _vm="${_vm}aarch64" ;;
        *) _vm="${_vm% }" ;;
    esac
    say "expected vermagic:  $_vm"
    if [ "$(opt MODULES)" != y ]; then
        say "verdict:            this kernel has no loadable module support (CONFIG_MODULES=n)"
        return 0
    fi
    _ok=1
    if [ "$(opt MODULE_SIG_FORCE)" = y ]; then
        say "module signing:     ENFORCED (CONFIG_MODULE_SIG_FORCE=y): only modules signed with the"
        say "                    key this kernel was built with load. Vendors don't publish it, so"
        say "                    out-of-tree modules can't be loaded unless you build the kernel."
        _ok=0
    elif [ "$(opt MODULE_SIG)" = y ]; then
        say "module signing:     on, not enforced: unsigned modules load and taint the kernel"
    else
        say "module signing:     off"
    fi
    if [ "$(opt MODVERSIONS)" = y ]; then
        say "symbol versions:    CONFIG_MODVERSIONS=y: every symbol's CRC must match the running"
        say "                    kernel's build; a mismatch shows as 'disagrees about version of"
        say "                    symbol' in dmesg. Build against the exact source and config."
    fi
    case "$_kr" in
        *-android[0-9]*-*)
            say "GKI symbols:        unsigned modules may only use the symbols GKI exports to vendor"
            say "                    modules; others fail with 'Unknown symbol'"
            ;;
    esac
    if [ "$_ok" = 1 ]; then say "verdict:            modules built for this exact kernel can load"; else say "verdict:            loading out-of-tree modules is blocked by signature enforcement"; fi
}

tools_missing() {
    _miss=""
    command -v make >/dev/null || _miss="$_miss make"
    command -v gcc >/dev/null || command -v clang >/dev/null || _miss="$_miss gcc"
    for _t in bc flex bison; do command -v "$_t" >/dev/null || _miss="$_miss $_t"; done
    printf '%s' "$_miss"
}

prepare() { # SRC
    _src=$(cd -P -- "$1" 2>/dev/null && pwd -P) || die "no such directory: $1"
    grep -q '^VERSION *=' "$_src/Makefile" 2>/dev/null || die "$_src is not a kernel source tree"
    [ "$(id -u)" = 0 ] || [ -w "$_src" ] || die "cannot write to $_src"
    _m=$(tools_missing)
    [ -z "$_m" ] || die "missing tools:$_m (sudo apt install build-essential bc flex bison libssl-dev libelf-dev)"
    config >/dev/null || die "no $KCONFIG: the running kernel's configuration is unknown"
    _base=$(awk -F' *= *' '
        $1 == "VERSION" { v = $2 } $1 == "PATCHLEVEL" { p = $2 }
        $1 == "SUBLEVEL" { s = $2 } $1 == "EXTRAVERSION" { e = $2 }
        END { printf "%s.%s.%s%s", v, p, s, e }' "$_src/Makefile")
    _kr=$(uname -r)
    case "$_kr" in
        "$_base"*) _lv=${_kr#"$_base"} ;;
        *) die "the source is $_base but the phone runs $_kr: use the exact source" ;;
    esac
    for _f in "$_src"/localversion*; do
        [ -e "$_f" ] && say "warning: $_f adds to the version; remove it if kernelrelease doesn't match" >&2
    done
    [ -f "$_src/.config" ] && cp -f "$_src/.config" "$_src/.config.uburoot-old"
    config | sed -e '/^CONFIG_LOCALVERSION=/d' -e '/^CONFIG_LOCALVERSION_AUTO=/d' -e '/^# CONFIG_LOCALVERSION_AUTO is not set/d' >"$_src/.config" ||
        die "cannot write $_src/.config"
    printf 'CONFIG_LOCALVERSION="%s"\n# CONFIG_LOCALVERSION_AUTO is not set\n' "$_lv" >>"$_src/.config"
    say "config from $KCONFIG, LOCALVERSION=\"$_lv\""
    # shellcheck disable=SC2086 # extra make arguments, split on purpose
    make -C "$_src" $MAKEFLAGS_EXTRA olddefconfig modules_prepare || die "make modules_prepare failed"
    # shellcheck disable=SC2086
    _got=$(make -s -C "$_src" $MAKEFLAGS_EXTRA kernelrelease 2>/dev/null)
    [ "$_got" = "$_kr" ] || die "kernelrelease is '$_got', the phone runs '$_kr' (vermagic would not match)"
    mkdir -p "$STATE_DIR" && printf '%s\n' "$_src" >"$SRC_FILE"
    say "prepared $_src for $_kr"
    [ -f "$_src/Module.symvers" ] || say "note: no Module.symvers in the tree; with CONFIG_MODVERSIONS the module will carry no CRCs for kernel symbols"
}

build() { # DIR
    _src=$(cat "$SRC_FILE" 2>/dev/null) || die "no prepared tree: run uburoot-kbuild prepare SRC first"
    [ -d "$_src" ] || die "the prepared tree $_src is gone"
    _dir=$(cd -P -- "$1" 2>/dev/null && pwd -P) || die "no such directory: $1"
    # shellcheck disable=SC2086
    make -C "$_src" $MAKEFLAGS_EXTRA M="$_dir" modules || die "build failed"
    for _ko in "$_dir"/*.ko; do
        [ -f "$_ko" ] || continue
        say "built $_ko"
        command -v modinfo >/dev/null && say "  vermagic: $(modinfo -F vermagic "$_ko")"
        say "  load it with: sudo uburoot-kmod load $_ko"
    done
}

case "${1:-}" in
    check) check ;;
    prepare)
        [ $# -ge 2 ] || die "usage: uburoot-kbuild prepare SRC"
        prepare "$2"
        ;;
    build)
        [ $# -ge 2 ] || die "usage: uburoot-kbuild build DIR"
        build "$2"
        ;;
    *) die "usage: uburoot-kbuild check | prepare SRC | build DIR" ;;
esac
