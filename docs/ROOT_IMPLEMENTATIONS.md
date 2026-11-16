# Root implementations: Magisk, KernelSU, APatch

UbuRoot supports the three main root managers. This page records how they differ in
the details that matter for a chroot: how `su` is provided, how to reach the global
mount namespace, where busybox lives and how modules install. Everything here was
**checked in each project's source code** (2026-11), not guessed. If you find that a
newer version behaves differently, please open an issue.

Only Magisk has been tested on a real device so far (Magisk 31.1, LineageOS 19.1 /
Android 12). The KernelSU and APatch paths follow from their source code and are
untested.

## Why the mount namespace matters

UbuRoot mounts `/proc`, `/dev`, `/sdcard`, `/data`, `/system`... under the rootfs. Every
terminal session and every script must see the **same** mounts. If one `su` call runs in
a private mount namespace, its mounts are invisible to the others, and an unmount there
can't release mounts made elsewhere. So every root call from UbuRoot has to run in the
**global (init) mount namespace**.

## Comparison

| | Magisk | KernelSU | APatch |
|-|--------|----------|--------|
| `su -v` prints | `<version>:MAGISKSU` | `<version>:KernelSU` | `<version>:APatch` |
| Global-namespace flag | `-M` / `--mount-master` (also `-mm`) | `-M` / `--mount-master` | `-M` / `--mount-master` |
| Where it is implemented | `native/src/core/su/su.cpp` (`"mount-master"`, `'M'`; `-mm` is rewritten) | `userspace/ksud/src/su.rs` (`optflag("M", "mount-master")` → `switch_mnt_ns(1)`) | `apd/src/apd.rs` (`optflag("M", "mount-master")` → `switch_mnt_ns(1)`) |
| How `su` is provided | a real `su` binary served by `magiskd` | the kernel's sucompat redirects `/system/bin/su` to `ksud`, which sees `argv[0] = su` (`cli.rs`) | KernelPatch redirects `su`/`kp` to `apd` (`cli.rs`, `arg0.ends_with("su")`) |
| Global namespace without the flag | per-app "Mount Namespace Mode" in Magisk settings (default: inherit) | per-app profile `namespace` (0 inherit, 1 global, 2 individual) | global if `/data/adb/.global_namespace_enable` contains `1` |
| `su -c` with several arguments | joins the arguments after `-c` | takes only the value of `-c` | takes only the value of `-c` |
| Busybox | `/data/adb/magisk/busybox` | `/data/adb/ksu/bin/busybox` | `/data/adb/ap/bin/busybox` |
| Module install from the manager | yes | yes | yes |
| Module flash from custom recovery | yes (`update-binary` → `install_module`) | no (per its docs) | no (per its docs) |

## What UbuRoot does with this

- **Always `--mount-master`.** All three accept it, so there's no per-implementation
  branching. libsu builds it with `Shell.FLAG_MOUNT_MASTER` (see `UbuRootApp`).
- **Never trusts the flag blindly.** libsu silently falls back to plain `su`, and then to
  `sh`, when `su --mount-master` fails. Preflight compares `/proc/self/ns/mnt` with init's
  (`/proc/1/ns/mnt`) and refuses to continue when they differ.
- **The command is one string**: terminal sessions run
  `su --mount-master -c "/data/local/uburoot/bin/enter.sh <user>"`, because ksud and apd
  only read the value of `-c`.
- **Detection** (`common.sh`, reported by `rootinfo.sh`): the `su -v` suffix first, then
  the `/data/adb/{magisk,ksu,ap}` directories as a fallback.
- **Busybox** comes from the root manager's path above. Without one, the scripts fall back
  to toybox/plain commands; that path is untested, and every root manager ships a
  busybox.

## Module (the APK is also a module)

The release APK carries `module.prop`, `customize.sh`, `service.sh` and
`META-INF/com/google/android/{update-binary,updater-script}` at its root.

- **From the manager** (all three): `customize.sh` uses `SKIPUNZIP=1` and extracts only
  `module.prop` and `service.sh`, never the app's dex or libraries. It keeps a copy of
  the APK and installs it with `pm install -r` right away (`BOOTMODE=true`). With
  `SKIPUNZIP=1`, Magisk doesn't copy `module.prop` by itself (see `install_module` in its
  `util_functions.sh`), which is why `customize.sh` extracts it.
- **From TWRP** (Magisk only): `update-binary` sources
  `/data/adb/magisk/util_functions.sh` and calls `install_module`, the same thing
  Magisk's own `module_installer.sh` does. `service.sh` then installs the app after
  `sys.boot_completed`. On KernelSU/APatch it prints that recovery isn't supported and
  exits 1.

## SELinux domain and kernel extensions

All three put root in a **permissive** SELinux domain: Magisk `u:r:magisk:s0`
(`permissive([proc])` in `native/src/sepolicy/rules.rs`), KernelSU `u:r:ksu:s0`
(`ksu_permissive` in `kernel/selinux/rules.c`), and APatch uses `u:r:magisk:s0` with
Magisk's policy. So SELinux doesn't block Ubuntu's root even on an enforcing phone.
KernelSU (`ksud insmod`) and APatch (`apd insmod`) can load modules without the
vermagic/CRC checks; APatch also has KPM, KernelPatch's own module format. UbuRoot
uses plain `insmod` only. Details and source references are in [KERNEL.md](KERNEL.md).

## Known quirks

- **Magisk sometimes rejects without a prompt.** On the test device, Magisk 31.1 logged
  `su: request rejected (<uid>)` and never showed its dialog, even with default settings.
  The fix was allowing the app by hand in Magisk's superuser list. The cause is unknown.
- **No controlling terminal (Magisk).** Magisk's `su` gives the root process the
  terminal's pts but calls `setsid()` without making it the controlling terminal. Bash
  then has no job control, and Ctrl+C goes to the wrong process group. `enter.sh` runs
  util-linux `setsid --ctty` to take the tty over. Whether ksud/apd behave the same is
  not known yet; the fix is harmless if they don't.
