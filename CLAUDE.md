# UbuRoot — project guide

Android app (Kotlin, package `com.reinanbr.uburoot`) that installs and runs a full
Ubuntu arm64 rootfs in a **chroot** using root (Magisk / KernelSU / APatch), with a real
PTY terminal (Termux `TerminalView`) and deep Android integration. The full spec is in
`prompt.md`; this file records architecture, paths and decisions. Keep it updated.

Target: AOSP/LineageOS without GApps. **Forbidden:** Firebase, Google Play Services,
Play Core, or any proprietary Google dependency.

## Phase status

| Phase | Scope | Status |
|------:|-------|--------|
| 1 | Shell scripts + shellcheck + critical-rule tests | done (Docker 70/70; device 53/53 on Magisk, LineageOS 19.1 / Android 12) |
| 2 | App MVP: root check, installer, one terminal session | todo |
| 3 | Multiple sessions, foreground service, extra keys, settings | todo |
| 4 | Android integration (receiver, `uburoot-*` commands) | todo |
| 5 | Boot module (Magisk/KSU/APatch zip) | todo |

## Core principle: system logic lives in shell scripts

The app only copies the scripts from `app/src/main/assets/uburoot/bin/` to the device,
runs them through `su`, and shows the terminal. Everything is testable with
`adb shell su -c ...` without the app (`tools/adb-push-scripts.sh` pushes them).

All scripts are POSIX `sh` (they run under Android's mksh `/system/bin/sh`). No `local`,
no bashisms; `shellcheck -s sh` must pass.

### Device paths

| Path | What |
|------|------|
| `/data/local/uburoot/` | `UBU_BASE` |
| `/data/local/uburoot/bin/` | scripts (`UBU_BIN`) |
| `/data/local/uburoot/rootfs/` | Ubuntu rootfs (`ROOTFS`) |
| `/data/local/uburoot/uburoot.conf` | config (shell vars, written by the app, sourced by scripts) |
| `$ROOTFS/etc/android.env` | captured Android environment |
| `$ROOTFS/usr/local/bin/{am,pm,cmd,settings,dumpsys,getprop,android}` | wrappers |
| `$ROOTFS/etc/profile.d/uburoot.sh` | applies `UBU_CWD` / `UBU_INIT` on login |

### Scripts (`app/src/main/assets/uburoot/bin/`)

| Script | Purpose |
|--------|---------|
| `common.sh` | sourced by all: paths, config, busybox detection, root-impl detection, mount helpers, `ubu_safe_rm` (critical rule) |
| `mount.sh` | idempotent mounts (checks `/proc/self/mounts` before each one) |
| `umount.sh [--kill]` | unmounts everything under `ROOTFS`, deepest first; `umount -l` fallback; exit 1 if anything is left |
| `enter.sh [user] [cmd]` | `mount.sh`, then `chroot` with a clean env (`env -i`) into `bash -l` or `su - user` |
| `android-env` | captures Android env into `$ROOTFS/etc/android.env` and writes the wrappers |
| `install.sh <tar.gz> [sha256]` | checks arch/space, verifies SHA256, extracts with busybox tar into `rootfs.partial`, then renames it |
| `setup.sh [--user N] ...` | post-install: DNS, hosts, hostname, AID groups, apt sources, locale, sudo, user |
| `reset.sh --yes` | the only deletion path: `umount.sh --kill`, then `ubu_safe_rm` |
| `rootinfo.sh` | prints `impl=`, `version=`, `mount_master_flag=`, `busybox=` (used by the app) |

Config keys (`uburoot.conf`): `MOUNT_SDCARD`, `ANDROID_INTEGRATION`, `DNS_SERVERS`,
`DEFAULT_USER`, `INIT_COMMAND`, `UBU_HOSTNAME`, `SDCARD_SOURCE` (optional override).

Test-only env overrides (never set by the app): `UBU_BASE`, `ROOTFS`, `UBU_MOUNTS_FILE`,
`UBU_BB` (`none` = plain commands), `UBU_ALLOW_NONROOT=1`, `UBU_ALLOW_ANY_ARCH=1`.

## CRITICAL SAFETY RULE: never `rm -rf` the rootfs while anything is mounted under it

With `/data` and `/sdcard` bind-mounted inside the rootfs, `rm -rf rootfs` **deletes
the phone's real data**. All recursive deletion under `UBU_BASE` goes through
`ubu_safe_rm` in `common.sh`, and nothing else may run `rm -r` there. It:

1. refuses any path that is not strictly inside `UBU_BASE`;
2. aborts if `/proc/self/mounts` lists any mountpoint equal to or below the path;
3. `rmdir`s the known bind targets (`data sdcard system vendor product system_ext odm
   apex linkerconfig`). `rmdir` cannot delete content, so a non-empty dir aborts;
4. aborts if live-mount markers exist (`proc/self`, `sys/kernel`, `dev/block`);
5. checks the mounts again right before `rm -rf`.

`reset.sh` runs `umount.sh --kill` first and aborts if it fails. In the app,
"Reset do Ubuntu" must also require typing `APAGAR`. Tests: `tests/test_reset_guard.sh`
(fake mounts table, no root) and `tests/docker/` (real mounts, sabotaged umount).

## Mount design

- `ROOTFS` is self-bind-mounted and made **private**. `/data` is a shared mount on
  Android (init does `MS_REC|MS_SHARED` on `/`). Without this, every mount under the
  rootfs would propagate to peer namespaces. `/data` is also `nosuid`, which the
  self-bind inherits and which breaks sudo. So `mount.sh` remounts it with
  `remount,bind,nodev`. A remount replaces every per-mount flag, so `nodev` has to
  be passed again.
- Every bind (`/dev`, `/dev/pts`, `/sdcard`, Android partitions, `/data`) is made
  **rslave** immediately: host changes (APEX updates, etc.) still arrive, but nothing
  goes back. This matters most for **rbind** (`/apex`, `/system`, ...). Without it,
  unmounting the copy would propagate and unmount the real `/apex/*` (the classic
  `umount -R` bug that `arch-chroot` works around with `--make-rslave`). The Docker
  suite's control experiment reproduces this hazard on a real kernel. If the
  busybox/toybox in use can't set propagation flags, `mount.sh` aborts.
- `umount.sh` first runs `--make-rprivate` on everything under `ROOTFS`, then unmounts
  deepest first. This way no umount can propagate out.
- Mounts: `proc`, `sysfs`, `/dev` (bind), `/dev/pts` (bind), `/dev/shm` (tmpfs),
  `/run` (tmpfs); `[MOUNT_SDCARD]` `/sdcard` (bind); `[ANDROID_INTEGRATION]`
  `/system /vendor /product /system_ext /odm /apex /linkerconfig` (rbind, same paths;
  if the host path is a symlink, the same symlink is created instead) and `/data`
  (non-recursive bind).
- `/sdcard` source: `SDCARD_SOURCE`, else the first of `/data/media/0`,
  `/storage/emulated/0`, `/mnt/user/0/emulated/0` that looks real (has `Android/` or
  `Download/`). `/data/media/0` comes first because the FUSE view returns **EFAULT**
  to every non-root uid that isn't an app (MediaProvider can't map it to a
  package; verified on the device for uid 9000 with groups 9997/1023/1015/1028).
  `/data/media/0` is `media_rw:media_rw 2770` (setgid). The user gets
  `aid_media_rw` (1023), and Ubuntu's pam_umask gives it umask 002, so its files are
  `9000:1023 664`, labelled `media_rw_data_file`, and still writable by MediaProvider.
  The cost: MediaStore isn't notified (Gallery needs a rescan).
- Turning a toggle off doesn't unmount a live mount. That happens on "Parar tudo" or
  "Reparar mounts" (`umount.sh` + `mount.sh`).
- `/dev` is the real Android `/dev`. Creating `dev/shm` or `dev/fd` there creates them
  on the device's `/dev` tmpfs (harmless, lost at reboot).

## Root implementations and mount namespaces (verified in source, 2026-11)

Mounts must be visible in every session. So every `su` call from the app must run in
the **global (init) mount namespace**.

| | Magisk | KernelSU | APatch |
|-|--------|----------|--------|
| `su -v` output | `<ver>:MAGISKSU` | `<ver>:KernelSU` | `<ver>:APatch` |
| Mount-master flag | `-M` / `--mount-master` (also `-mm`) | `-M` / `--mount-master` | `-M` / `--mount-master` |
| Source | `native/src/core/su/su.cpp` (`"mount-master"`, `'M'`; `-mm` rewritten) | `userspace/ksud/src/su.rs` (`optflag("M","mount-master")` → `switch_mnt_ns(1)`) | `apd/src/apd.rs` (`optflag("M","mount-master")` → `switch_mnt_ns(1)`) |
| How `su` is provided | real `su` binary from magiskd | kernel sucompat redirects `/system/bin/su` to `ksud`, which sees `argv[0]=su` (`cli.rs`) | KernelPatch redirects `su`/`kp` to `apd` (`cli.rs`, `arg0.ends_with("su")`) |
| Global ns by default | per-app "Mount Namespace Mode" setting in Magisk (default: inherit) | per-app profile `namespace` (0 inherit, 1 global, 2 individual) | global if `/data/adb/.global_namespace_enable` contains `1`, else only with `-M` |
| Busybox | `/data/adb/magisk/busybox` | `/data/adb/ksu/bin/busybox` | `/data/adb/ap/bin/busybox` |

**Decision:** always pass `--mount-master`. It is accepted by all three, so there's no
per-implementation branching, but `rootinfo.sh` still reports the implementation.
libsu: `Shell.Builder.setFlags(Shell.FLAG_MOUNT_MASTER)`. Terminal sessions run
`su --mount-master -c "/data/local/uburoot/bin/enter.sh <user>"`, with the command as
**one string**: Magisk joins the trailing args after `-c`, but ksud/apd take only the
value of `-c`.

Detection order in `common.sh`: `su -v` suffix first, then `/data/adb/{magisk,ksu,ap}`
directories as a fallback.

## Ubuntu side decisions

- Release: newest **LTS** (`YY.04`, even `YY`) found in
  `https://cdimage.ubuntu.com/ubuntu-base/releases/`. As of 2026-11 that's
  `26.04.1` "resolute": `releases/26.04/release/ubuntu-base-26.04.1-base-arm64.tar.gz`,
  validated against `SHA256SUMS` in the same directory. The app must discover this
  dynamically and must not hardcode a version. Since 2024 the tar entries have no
  leading `./`.
- The arm64 tarball's `ubuntu.sources` already points to ports. `setup.sh` rewrites it
  anyway: `ports.ubuntu.com/ubuntu-ports` for non-x86, `archive/security.ubuntu.com`
  for amd64 (Docker tests).
- Paranoid network (`CONFIG_ANDROID_PARANOID_NETWORK`): groups `aid_inet` 3003,
  `aid_net_raw` 3004, `aid_net_admin` 3005. root, the user and `_apt` are added. APT
  drops privileges with `setgroups(1, &pw_gid)`, so it keeps **only the primary group**.
  So `_apt` gets primary group `aid_inet`. If `apt-get update` still fails,
  `setup.sh` writes `APT::Sandbox::User "root";` and retries.
- Default user UID/GID = **9000**, not 1000. Ubuntu UIDs share the kernel with
  Android: UID 1000 is `AID_SYSTEM` (system_server!). A chroot user with UID 1000 could
  kill Android system processes and acts as system over binder. The UID must be
  **< 10000** (`AID_APP_START`). netd's BPF `bpf_owner_match` exempts only "system"
  uids. Android 12 `system/netd/bpf_progs/netd.c` checks `0 <= uid <= 9999`
  (`UidConstants.h`), and main `packages/modules/Connectivity/bpf/progs/netd.h`
  checks `uid % AID_USER_OFFSET < AID_APP_START`. Any other uid gets **dropped**
  (connect hangs) whenever an allowlist chain is on: restricted networking mode,
  doze, powersave. On the test device `restricted_networking_mode=1` blocked uid
  20000 and every uid ≥ 10000 tested, while 0/2000/9999 worked. Main also defines
  `AID_SDK_SANDBOX_PROCESS_START 20000`. `android_filesystem_config.h` (12 and main)
  defines nothing in 8000–9996. The reserved ranges end at
  `AID_SYSTEM_EXT_RESERVED_END 7999`, then come `AID_EVERYBODY 9997`, `AID_MISC 9998`
  and `AID_NOBODY 9999`. OEM `config.fs` AIDs must sit in the reserved ranges.
  `setup.sh` warns for a `--uid` or an existing user outside 8000–9996.
- `enter.sh` uses `env -i`. The root shell goes through `setpriv --init-groups` so it
  gets the `aid_*` supplementary groups. Users go through `su -w UBU_CWD,UBU_INIT,COLORTERM - user`.
  `UBU_CWD` / `UBU_INIT` are applied (then unset) by `/etc/profile.d/uburoot.sh`. This
  avoids `su -c`'s `setsid()`, which would kill job control in interactive shells.
- The kernel hostname is shared with Android (same UTS namespace) and is never
  changed. `mount.sh`/`setup.sh` add it to the chroot's `/etc/hosts`, because sudo
  warns on every call otherwise. `/etc/hostname` is cosmetic.
- `/usr/sbin/policy-rc.d` returns 101, so package installs don't auto-start daemons.
- Android env capture: current env, then `/data/system/environ/classpath`
  (derive_classpath, Android 12+), then `init.environ.rc`. It is recaptured when
  `ro.build.fingerprint` changes (OTA). The wrappers run `/system/bin/<x>` via
  `env -i /system/bin/sh -c '. /etc/android.env; exec ...'`, so no glibc env leaks
  into bionic.

## Testing

- `tests/run-all.sh`: everything below. Phase 1 result: shellcheck clean (17 files),
  guard 13/13, Docker 70/70.
- `tests/shellcheck.sh`: `shellcheck -s sh` from PATH, else the `koalaman/shellcheck:v0.11.0`
  image. `.shellcheckrc` disables SC2016 (awk programs are single-quoted).
- `tests/test_reset_guard.sh`: critical rule with dummy dirs, a fake mounts table and a
  sabotaged fake busybox. No root needed. It was mutation-checked: disabling the guards
  makes 6 cases fail.
- `tests/docker/run.sh`: privileged `ubuntu:26.04` container. mksh is
  `/system/bin/sh` and busybox sits at `/data/adb/magisk/busybox`. Fake Android
  partitions use a shared `/apex` with submounts. It uses a real x86_64 Ubuntu Base
  rootfs and runs `install → setup (real apt) → enter → wrappers → umount → reset`.
  It checks that the original `/apex` submounts survive umount and that a sabotaged
  umount makes reset abort with the dummy "phone data" intact. It also checks that
  reset `--kill`s a live chroot session.
- `tools/adb-push-scripts.sh`: pushes the scripts to a device for `adb shell su -M -c` tests.
- `tests/device/run.sh [--reset] [-s SERIAL]`: pushes the scripts and runs
  `tests/device/checks.sh` on a rooted phone (under nohup, logging to
  `/data/local/tmp/uburoot-device-tests.log`). It needs `install.sh` and
  `setup.sh --user tester --nopasswd` to have run already. It covers real mounts and
  propagation, paranoid network, bionic wrappers, the user's sudo/network/`/sdcard`
  access, a sabotaged reset and umount back to baseline. `--reset` also runs the real
  reset with a live session. Not part of `run-all.sh`.
- Ubuntu 26.04's rust-coreutils (`env` etc.) **panics without `/proc`** (rustix reads
  `/proc/self/auxv`). Never `chroot` into the rootfs before `mount.sh`.
- Paths not covered by the suite: the toybox-only fallback (no root manager ships without
  busybox) and plain util-linux.
- Tested only on Magisk 31.1 / Android 12 so far. KernelSU, APatch and Android 13+
  have not been run on a device yet.

## Work rules

- Code and comments in English; UI strings in pt-BR via `strings.xml`.
- Don't invent flags/APIs/versions: verify in the source first and note it here.
- Minimal deps: no Hilt/Room/Retrofit. Terminal: `com.github.termux.termux-app:terminal-view`
  + `terminal-emulator` (JitPack, check the latest stable tag). Root: `com.github.topjohnwu.libsu:core`.
- minSdk 26, latest stable targetSdk, `arm64-v8a` only, Gradle Kotlin DSL + version catalog.
- Small commits per phase.
