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
| 2 | App MVP: root check, installer, one terminal session | done (unit 17/17; on device: clean install discover→download→SHA256→extract→setup→terminal, resume after a kill, apt as the user; device suite 59/59 incl. real reset; in-app session suite 35/35, host root identical to baseline after umount; dev/network suite 54/54; R8 release build verified on device) |
| 3 | Multiple sessions, foreground service, extra keys, settings | done (unit 22/22, Docker 90/90, device 53/53; on device: tabs, extra keys incl. sticky CTRL, links, themes, notification actions, wake lock, settings save/DNS/repair, Stop all in ~5 s, preflight waits for Stop all) |
| 4 | Android integration (receiver, `uburoot-*` commands, share target) | done (unit 26/26, Docker 116/116; on device: every command as a sudoer and as a non-sudoer, in the background and with the app force-stopped, file/URL open, errors back in the terminal, share of a document/text) |
| 5 | Boot module (Magisk/KSU/APatch zip) | done (unit 26/26, Docker 138/138, device 53/53; on device: module installed with `magisk --install-module`, toggle saved from Settings, after a reboot `service.sh` → `boot.sh` mounted and ran the script 1 s after `boot_completed`; *Run now*; module removed afterwards) |

### Milestone 2: NetHunter-level platform (`prompt.md`)

The spec is `prompt.md` (full kernel access, full hardware access, Linux GUI apps, tool
front-ends, chroot manager, kernel manager). The gap analysis and the phase list are in
`docs/NETHUNTER_PARITY.md`. Each phase stops for the owner's review.

| Phase | Scope | Status |
|------:|-------|--------|
| 0 | Gap analysis (`docs/NETHUNTER_PARITY.md`) | done |
| 0b | Relicense to GPL-3.0-or-later, SPDX headers, About screen | done (released in 0.3.0) |
| 1 | Doctor (kernel report + hardware inventory), full-root gate, rootfs schema + migrations, wake lock / mirror / offline install, `docs/COMPATIBILITY.md` | done (unit 29/29, Docker 182/182, device 60/60; CI release build of `c57688b` on the S9: the preflight passed the full-root gate and migrated a 0.2.x rootfs to SCHEMA 1 (INSTALLED kept), the terminal opened, host mounts identical to the baseline after `umount.sh --kill`. **Not tested in the UI:** the Diagnostics screen (Share/Copy), the install form's mirror/offline fields and an actual offline install. The phone now has a PIN lock, so UI tests need the owner to unlock it) |
| 2 | Full kernel access (`KERNEL_ACCESS`) | scripts + app done (unit 33/33, guard 17/17, Docker 223/223; S9 over adb: binds, `uburoot-kernel` devmode/selinux/revert, signed-module refusal, trace-cmd, simpleperf, host mounts identical after Stop all). CI release APK of `a7e5b2d` on the S9: preflight → terminal; Settings → Kernel access: the warning appears only when turning it on, Cancel keeps 0, Save writes `KERNEL_ACCESS='0'` with the "applies after Repair mounts" notice. on again through the warning + Save + *Repair mounts* (8 kernel binds); Kernel screen: state, developer mode (kptr 2→1, recorded), SELinux switch with its dialog (Permissive), *Revert changes* with its dialog (Enforcing, kptr 2, 0 changes), `dmesg -w` root tab (closing it left no process) |
| 4 | Linux GUI apps | gate done (`docs/GUI.md`); owner chose Termux:X11 companion now, embedded later. Part 3 (switching apps, XFCE desktop, Firefox from Mozilla): unit 42/42, Docker 299/299, `docs/GUI.md`; S9 over adb: wmctrl raises/closes under matchbox, `run` of an open app raises it (0.8 s), XFCE started in 4.8 s (199 MB RSS), Firefox 160 arm64 from packages.mozilla.org (seccomp on its children, no user namespaces). Part 2 (GPU Turnip KGSL + Zink, sound, session bus, no-snap pins): unit 40/40, Docker 294/294. CI run of `bc5584d` (manual, with the new `turnip` job): its tarball installed by `gpu.sh` on the S9 (SHA256 checked), its release APK: GPU card shows `vulkan=Turnip Adreno (TM) 630` / `opengl=zink …`, Zink switch off/on rewrites `gpu.env`, *Remove*, and *Install* says "turnip-kgsl-arm64.tar.gz is not in the latest release yet" (0.3.0 predates it). The CI tarball differs from a local build (not bit-reproducible yet). Afterwards: Stop all, `HARDWARE_ACCESS` 0, 0 mounts, 1068 host mounts, 0 changes; `ana` stays in `wireshark` (owner's request); the driver stays installed. Part 1: unit 38/38, Docker 282/282. CI release APK of `4cd4713` on the S9: menu → *Linux apps* lists Wireshark with its icon; *Stop the display*; tap → fresh server + Wireshark full screen in 10 s (no frozen frame); hold → launcher pin dialog → shortcut with the app icon; with the display stopped, the shortcut opened Wireshark in 9 s (SELinux enforcing). `x11.sh`, *Linux apps* screen, launcher shortcuts, DISPLAY in login shells (schema 2). Wireshark opened and captured on the S9 (SELinux enforcing). Not yet: GPU, audio in sessions, desktop mode, clipboard, embedding |
| 3 | Full hardware access (`HARDWARE_ACCESS`) | 3a (unit 35/35, guard 17/17, Docker 259/259) scripts + app: classes, grants, permission rules + watcher, Wi-Fi takeover, CPU/LED/wake lock/bus nodes, Hardware screen (`docs/HARDWARE.md`). CI release APK of `ed25f12` on the S9: Settings warning + Save + *Repair mounts*; `uburoot-hw` list/info/cpu/grant; Wi-Fi takeover with Ubuntu's real `wpa_supplicant` and *Give back* from the screen; revert from the screen (CPU, governors, wake lock); terminal menu stable; S9 restored (host mounts identical, 0 changes, Hardware access off). 3b (unit 35/35, guard 17/17, Docker 274/274): USB gadget (NCM/ACM/HID/storage) tested on the S9 over adb after a kernel panic redesign (below); bridges (audio, camera, sensors, location) scripts + app, Docker (fake app over perl); CI release APKs of `4088af0` and `5e133b6` on the S9: every bridge from the screen, in front and in the background, gadget NCM from the screen, *Stop all* reverted all; S9 restored (Hardware access off, 0 changes, 1068 host mounts, the test's permissions revoked) |

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
| `$ROOTFS/usr/local/bin/{am,pm,cmd,settings,dumpsys,getprop,wm,input,content,svc,appops,android}` | wrappers (only for tools present in `/system/bin`) |
| `$ROOTFS/usr/local/lib/uburoot/android-run` | runner used by the wrappers (`--pipes` / `--tty`) |
| `$ROOTFS/etc/profile.d/uburoot.sh` | applies `UBU_CWD` / `UBU_INIT` on login |
| `$ROOTFS/usr/local/lib/uburoot/uburoot-{send,cmd}` | bridge helpers (from `chroot-send.sh` / `chroot-cmd.sh`), root:root 755 |
| `$ROOTFS/usr/local/bin/{uburoot-notify,uburoot-toast,uburoot-vibrate,uburoot-clip,uburoot-open,xdg-open}` | symlinks to `uburoot-cmd` |
| `$ROOTFS/etc/sudoers.d/80-uburoot` | `ALL ALL=(root) NOPASSWD: /usr/local/lib/uburoot/uburoot-send` (0440) |
| `$ROOTFS/var/lib/uburoot/outbox/` | root-only (0700) staging for `uburoot-open` files |

### Scripts (`app/src/main/assets/uburoot/bin/`)

| Script | Purpose |
|--------|---------|
| `common.sh` | sourced by all: paths, config, busybox detection, root-impl detection, mount helpers, `ubu_safe_rm` (critical rule) |
| `mount.sh` | idempotent mounts (checks `/proc/self/mounts` before each one) |
| `umount.sh [--kill]` | unmounts everything under `ROOTFS`, deepest first; `umount -l` fallback; exit 1 if anything is left |
| `enter.sh [user] [cmd]` | `mount.sh`, then `chroot` with a clean env (`env -i`) into `bash -l` or `su - user` |
| `android-env` | captures Android env into `$ROOTFS/etc/android.env` and writes the wrappers |
| `install.sh <tar.gz\|tar.xz> [sha256]` | checks arch/space, verifies SHA256 (64 hex, any case), picks gzip/xz from the magic bytes (a SAF file arrives under a cache name), extracts with busybox tar into `rootfs.partial`, requires `usr/bin/env` + `usr/bin/dpkg` and that dpkg's ELF arch is the CPU's (always, even with `UBU_ALLOW_ANY_ARCH`), then renames it |
| `setup.sh [--user N] ...` | post-install: DNS, hosts, hostname, AID groups, apt sources, locale, sudo, user, `/etc/uburoot-release`. `--dns-only` rewrites just `resolv.conf` (Settings → DNS); `--sources-only` just the APT sources (Settings → mirror); `--migrate` runs the numbered migrations `migrate_N` from the rootfs's schema up to `UBU_SCHEMA` (the app runs it on every preflight; refused before setup; a newer rootfs is left alone) |
| `doctor.sh [--redact] [--app-version V]` | read-only report: Root (full-root verdict, caps, seccomp, SELinux context, mount ns), Android, Kernel (config or probes: namespaces, overlayfs, tun, binfmt_misc, gadget functions, GKI, module signing/`sig_enforce`, modversions, vendor `vermagic`, BTF, kprobes/uprobes, restrict sysctls, `security.perf_harden`, host kernel filesystems, Wi-Fi monitor), Hardware (SoC, CPU policies, GPU and DRM/fb nodes, input, ALSA, V4L2, IIO, Wi-Fi, BT HCI, NFC, UDC, USB host, LEDs, power supplies, thermal zones, I2C/SPI/GPIO/serial/modem node counts, and **who holds each node open**: one `ls -l /proc/*/fd`; app processes (uid >= 10000) show as `app`), Storage, Mounts, Network (DNS + mirror TCP only while mounted), Config. `--redact` = `ident()` plus a whole-word awk pass over every identifier. ~11 s on the S9 |
| `hangup.sh PID` | SIGHUP+SIGCONT to the chroot processes whose controlling tty is PID's stdin (the app passes a session's `su` client when its tab closes) |
| `reset.sh --yes` | the only deletion path: `umount.sh --kill`, then `ubu_safe_rm` |
| `boot.sh [--now\|--status]` | run by the module's `service.sh`. Without `BOOT_START=1` it does nothing. Waits for shared storage to decrypt (if `MOUNT_SDCARD`, up to 6 h), runs `mount.sh`, then each executable `/etc/uburoot-boot.d/NAME` (`[A-Za-z0-9_-]+`, no symlinks) through `enter.sh root`. A script still running after `BOOT_SCRIPT_TIMEOUT` (60 s) is left running. `--now` skips the wait and `BOOT_START`; `--status` prints `module=enabled\|disabled\|removing\|pending\|missing` (`/data/adb/modules{,_update}/uburoot`, the same for all three managers) and `boot_start=` |
| `kernel.sh` | `uburoot-kernel` (Ubuntu side, installed by mount.sh) and the app's backend (Android side, sources common.sh): `status`, `sysctl NAME [V]`, `devmode on\|off`, `selinux [enforcing\|permissive]` (asks; `-y`), `module list\|load\|unload`, `lastlog`, `revert`. Every change goes to `$UBU_STATE/changes` (`sysctl NAME ORIG`, `selinux - ORIG`, `module NAME -`; first change only; `boot_id` stamp; `.lock` dir); revert is newest first. As `uburoot-kmod`, args become `module ...` |
| `changes.sh` | sourced by `kernel.sh` and `hardware.sh` (inside Ubuntu: `/usr/local/lib/uburoot/changes.sh`): the change log (`lock`/`lock_try`, `rec_*`), `revert_one` for every record type (`sysctl`, `selinux`, `module`, `file`, `node`, `wakelock`, `takeover`), `revert` (newest first), `acmd` (Android tools; through the bionic wrappers inside Ubuntu), `kill_ubuntu_exe` (exe under Ubuntu's `/usr/{s,}bin` only), `ubuntu_access KEY` (`/run/uburoot/access`) |
| `hardware.sh` | `uburoot-hw` (Ubuntu side, installed by mount.sh with `HARDWARE_ACCESS=1`) and the app's backend: `list`, `info CLASS`, `status` (`access=`, `class=NAME\|ROUTE\|STATE\|NODES\|GROUP\|USERS`, `cpu=`, `battery=`, `wakelock=`, `rules=`, `changes=`), `grant\|revoke CLASS USER`, `takeover\|release wifi`, `cpu governor\|min\|max\|online`, `wakelock on\|off`, `set` (LEDs only), `allow NODE` (bus nodes, PMIC/charger names refused), `apply`/`watch` (permission rules in `$ROOTFS/etc/uburoot/hw-rules`, watcher pid in `run/uburoot/hw-watch.pid`, stopped by `umount.sh`), `gadget on ncm\|acm\|hid\|storage IMAGE [rw]\|off\|status` (links `uburoot.*` into the bound gadget's config; record `takeover gadget GADGET:UDC`), `bridge publish NAME SOCKET` (token on stdin → `$ROOTFS/run/uburoot-bridge/NAME`, `root:GROUP 0640`) / `unpublish NAME\|all`; status adds `bridge=NAME\|on\|off` and `gadget=FUNCS\|UDC` |
| `hwbridge.sh` + `bridge-client` | installed by mount.sh (`HARDWARE_ACCESS=1`) as `/usr/local/lib/uburoot/{hwbridge,bridge-client}`, with the links `uburoot-audio|camera|sensors|gps` → `hwbridge` (dispatch on `$0`). `bridge-client NAME CMD ARGS` (perl-base: Ubuntu Base has no python/socat) reads `/run/uburoot-bridge/NAME` (`socket=`, `token=`), connects to the app's abstract socket, sends `TOKEN CMD ARGS\n`, expects `OK [info]`/`ERR msg`, then streams (`play`: stdin → app, half-close, wait for the app to close) |
| `x11.sh` | Linux GUI apps through Termux:X11 (docs/GUI.md): `status` (`x11=missing\|stopped\|running`, `wm=NAME\|none\|missing`), `start` (closes Termux:X11's activity, runs its `CmdEntryPoint` as root via `app_process` with `TMPDIR=$ROOTFS/tmp`, first-start preferences, matchbox WM as the user), `stop`, `apps [USER]`/`icons [USER]` (`.desktop` entries, PNG base64; files must resolve inside the rootfs), `run USER ID` (detached as the user, `DISPLAY=:0`, launcher in root-owned `/run/uburoot-x11`; an app with an open window gets that window raised instead), `windows USER` (`WINDOW\|ID\|TITLE`: `wmctrl -l -x` matched to entries by WM_CLASS), `focus\|close WINDOW`, `desktop USER` (kills matchbox, `startxfce4` as the user), `setup [desktop]` (apt: matchbox-window-manager, xkb-data, wmctrl; or xfce4, xfce4-terminal), `mozilla` / `firefox` (Mozilla's APT repo: embedded key, deb822 source, `firefox*` pin at 1000; then apt install). `umount.sh` stops the server |
| `gpu.sh` | GPU for Linux apps (docs/GUI.md): `status` (`gpu=adreno\|none`, `model=`, `driver=installed\|missing`, `mesa=`, `zink=on\|off`), `install FILE SHA256` (Turnip KGSL tarball from `tools/gpu/build-turnip.sh`: only 3 regular files allowed, each written by us via `tar -O`, root-owned; turns Zink on), `remove`, `zink on\|off` (`/etc/uburoot/gpu.env`, read by the login hook), `renderer USER` (`vulkan=`/`opengl=` as the user) |
| `kbuild.sh` | `uburoot-kbuild check\|prepare SRC\|build DIR`: GKI/vendor, expected vermagic from `/proc/config.gz`, signing/modversions verdict; `prepare` sets `LOCALVERSION` so `make kernelrelease` = `uname -r` |
| `rootinfo.sh` | prints `impl=`, `version=`, `mount_master_flag=`, `busybox=`, `schema=`/`schema_current=`, and the root report: `cap_last_cap=`, `cap_eff=`, `cap_bnd=`, `no_new_privs=`, `seccomp=`, `full_root=yes\|no`, `selinux=` (used by the app) |
| `chroot-send.sh` | runs **inside** the chroot as root (installed as `uburoot-send`): `notify TITLE [TEXT]`, `toast TEXT`, `vibrate [MS]`, `clip [TEXT]` (stdin), `open FILE\|URL` → `am broadcast` to the app, prints the app's error |
| `chroot-cmd.sh` | installed as `uburoot-cmd`; dispatches on `$0` (`uburoot-notify`... / `xdg-open`) to `uburoot-send`, through `sudo -n` unless root |
| `bridge.sh` | app side: `take ID DEST` (outbox file → the app's cache file), `import SRC NAME` (into the default user's `~/Shared`, as that user inside the chroot), `cwd DIR` (exit 0 if the default user can enter DIR) |

Config keys (`uburoot.conf`): `MOUNT_SDCARD`, `ANDROID_INTEGRATION`, `DNS_SERVERS`,
`DEFAULT_USER`, `INIT_COMMAND`, `UBU_HOSTNAME`, `SDCARD_SOURCE` (optional override),
`INOTIFY_MAX_WATCHES` (default 524288; `mount.sh` raises
`fs.inotify.max_user_watches` to it, never lowers it; 0 = leave alone), `BOOT_START`
(0/1, Settings → Start at boot), `BOOT_SCRIPT_TIMEOUT` (default 60 s, hand edit only),
`APT_MIRROR` (empty = `ports.ubuntu.com/ubuntu-ports/`, or `archive.ubuntu.com` for
amd64; `http://host/path/` only, checked by `ubu_valid_mirror` and
`UbuConfig.isValidMirror`; only the release suites, `-security` always comes from
Canonical), `KERNEL_ACCESS` (0/1, Settings → Kernel access; `mount.sh` section 1b),
`HARDWARE_ACCESS` (0/1, Settings → Hardware access; no mounts: `mount.sh` section 1c
writes `/run/uburoot/access`, binds the change log and installs `uburoot-hw`).

Test-only env overrides (never set by the app): `UBU_MODULES` (default `/data/adb`), `UBU_BASE`, `ROOTFS`, `UBU_MOUNTS_FILE`,
`UBU_INOTIFY_FILE` (Docker: the container's `/proc/sys` is the host's),
`UBU_BB` (`none` = plain commands), `UBU_ALLOW_NONROOT=1`, `UBU_ALLOW_ANY_ARCH=1`,
`UBU_STATE`; kernel.sh: `UBU_SYSCTL_DIR`, `UBU_SELINUX_ENFORCE`, `UBU_PROC_MODULES`,
`UBU_BOOT_ID_FILE`, `UBU_INSMOD`, `UBU_RMMOD`, `UBU_MODPROBE`, `UBU_ACCESS_FILE`;
hardware.sh/changes.sh: `UBU_HW_ROOT` (fake `/dev` + `/sys` prefix), `UBU_POWER_DIR`,
`UBU_ACMD` (fake `cmd`/`settings`), `UBU_ALLOW_NONROOT`, `UBU_GADGET_DIR` (fake `usb_gadget` dir); kbuild.sh: `UBU_KCONFIG`,
`UBU_KBUILD_STATE`, `UBU_KBUILD_MAKEFLAGS`; x11.sh: `UBU_X11_APK` (skips `pm`, `am`), `UBU_APP_PROCESS` (fake X server); gpu.sh: `UBU_KGSL_DEV`, `UBU_KGSL_SYS`.

## CRITICAL SAFETY RULE: never `rm -rf` the rootfs while anything is mounted under it

With `/data` and `/sdcard` bind-mounted inside the rootfs, `rm -rf rootfs` **deletes
the phone's real data**. All recursive deletion under `UBU_BASE` goes through
`ubu_safe_rm` in `common.sh`, and nothing else may run `rm -r` there. It:

1. refuses any path that is not strictly inside `UBU_BASE`;
2. aborts if `/proc/self/mounts` lists any mountpoint equal to or below the path;
3. `rmdir`s the known bind targets (`data sdcard system vendor product system_ext odm
   apex linkerconfig`). `rmdir` cannot delete content, so a non-empty dir aborts;
4. aborts if live-mount markers exist (`proc/self`, `sys/kernel`, `sys/fs`, `dev/block`,
   `dev/binder`, `run/uburoot`); the module bind targets `usr/lib/modules/*/uburoot/*`
   are `rmdir`ed like the other bind targets;
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
- `umount.sh` first runs `--make-rprivate` on everything under `ROOTFS`, then detaches
  each Android-partition rbind tree with one `umount -l` (`MNT_DETACH` is recursive), then
  unmounts the rest deepest first. This way no umount can propagate out. The lazy
  detach matters with **Magisk Zygisk**: magic mount puts a tmpfs over `/system/lib` and
  `/system/lib64` and binds every original file back. On the test phone that meant 1068
  host mounts and 1010 under the rootfs. One-by-one unmounting took 127 s, the detach
  takes 1 s, and the host table stayed identical. `ubu_is_mounted` is a single `awk`
  now; the old shell `read` loop over ~2000 lines per call was the real cost.
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

## App (Phases 2–4)

Build: AGP 9.5.1 with **built-in Kotlin** (never apply `org.jetbrains.kotlin.android`;
only `org.jetbrains.kotlin.plugin.compose`), Kotlin 2.4.21, Gradle wrapper 9.9.1
(AGP 9.5 needs >= 9.6.0), compile/targetSdk 37, Compose BOM 2026.09.00, termux
`v0.118.3` (newer tags are betas), libsu 6.0.0. Versions were checked against
maven-metadata.xml / JitPack on 2026-11-15. Gradle needs a JDK with `javac`: on the
dev machine the default `java-25` is a JRE, so build with
`JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 ./gradlew assembleDebug testDebugUnitTest`.

| File (`app/src/main/java/com/reinanbr/uburoot/`) | Role |
|------|------|
| `UbuRootApp` | libsu default builder: `FLAG_MOUNT_MASTER` |
| `root/RootShell` | coroutine wrapper. Every command runs as `( cmd ) 2>&1`: a subshell, so `set -e`/`exit` can't kill libsu's shared shell |
| `root/ScriptDeployer` | assets → `/data/local/uburoot/bin`, replaced via temp file + `mv` (a running sh reads its script incrementally); `rootinfo.sh` |
| `root/RootInfo` | parses `rootinfo.sh` (`setup=done|pending` added for resuming installs) |
| `install/ReleaseDiscovery` | newest LTS from the cdimage listing (+ fallback to an older series without arm64), SHA256SUMS |
| `install/Downloader` | resumable (`Range`, restarts if the server answers 200, re-fetches once on checksum mismatch), `.part` → rename after SHA256 |
| `install/UbuConfig` | renders `uburoot.conf`, every value single-quoted (it is sourced as root) |
| `install/InstallViewModel` | preflight → form → discover/download/`install.sh`/config/`setup.sh` → terminal |
| `install/ConfigStore` | reads/writes `uburoot.conf` through su (written to `.new`, then `mv`); lists users (uid 1000..59999) from the rootfs `passwd`. `UbuConfig.parse` keeps unknown keys |
| `terminal/SessionManager` | every `TerminalSession` of the process (`su --mount-master -c "enter.sh [user]"`, app env + `TERM`); one delegating `TerminalSessionClient` forwards to the visible activity. `close()` runs `hangup.sh <client pid>` and then kills the client |
| `terminal/SessionService` | foreground service (`specialUse`), started with the first session, stops after the last; notification with count + *New session* / *Stop all* / wake lock (partial wake lock + `WIFI_MODE_FULL_HIGH_PERF` lock, as Termux). *Stop all* = close sessions + `umount.sh --kill`; `stopping` flow makes the preflight wait |
| `terminal/TerminalActivity` | `singleTask`; one `TerminalView`, tabs re-`attachSession`; menu (new/root session, close, themes, wake lock, settings, stop all); Back = `moveTaskToBack`; Enter on the last finished tab → `MainActivity` |
| `terminal/ExtraKeys`, `TerminalTheme`, `TerminalPrefs`, `Links` | extra keys rows (pointer input, so the IME keeps focus; hold to repeat), color schemes into `TerminalColors.COLOR_SCHEME`, SharedPreferences (theme, font sp), URL in the tapped word |
| `bridge/CommandReceiver` | exported receiver for `com.reinanbr.uburoot.CMD`, guarded by the signature permission `com.reinanbr.uburoot.permission.CMD`; notify (channel `messages`), toast, vibrate, clip, open URL / file (`bridge.sh take` into `cache/open/<id>/<name>`, FileProvider `${applicationId}.files`, `goAsync`). Answers `RESULT_OK` or 1 + message |
| `bridge/ShareActivity` + `SharedPaths` | *Open in UbuRoot* (SEND `*/*`, text too): maps the shared item to its dir inside Ubuntu (externalstorage/downloads doc ids, MediaStore `RELATIVE_PATH`/`_data`, `file://`), checks it with `bridge.sh cwd`, else `bridge.sh import`; then a session with `UBU_CWD` |
| `ui/SettingsActivity` + `settings/SettingsViewModel` | `uburoot.conf` editor (mirror → `setup.sh --sources-only`), *Repair mounts* (`umount.sh --kill && mount.sh`), *Reset Ubuntu* (`reset.sh --yes`, exit 3 = refused), *Diagnostics* (`doctor.sh`, redacted unless the box is ticked; Share/Copy) |
| `ui/KernelActivity` + `kernel/KernelViewModel`, `KernelStatus` | Kernel screen: everything through `kernel.sh` (with `-y`, the app confirms itself): state, devmode, SELinux switch (strongest warning), recorded changes + *Revert changes*, module list with unload for ours, `dmesg -w` / `lastlog` as root tabs (`SessionManager.create(command=)` → `enter.sh USER CMD`), doctor's Kernel section |
| `ui/HardwareActivity` + `hardware/HardwareViewModel`, `HardwareStatus` | Hardware screen: `hardware.sh status` parsed; grant/revoke per class for `DEFAULT_USER`, Wi-Fi takeover (confirm dialog)/release, CPU policies + battery, wake lock, *Revert changes* (`kernel.sh -y revert`, the same as Stop all); tap a class for `hardware.sh info` |
| `hwbridge/BridgeService`, `BridgeServer`, `Bridges` | bridges (Hardware screen → Bridges): foreground service (types camera/microphone/location only with the permission held, else specialUse) while a bridge is on; per bridge a `LocalServerSocket` (abstract, `uburoot.<16 hex>.NAME`) and a 32-hex token published with `echo TOKEN \| hardware.sh bridge publish` (echo is a builtin: the token is in no argv). Peer uid must be 0 or 8000–9996. Audio: AudioTrack/AudioRecord s16le; camera: Camera2 → ImageReader JPEG (TEMPLATE_PREVIEW, repeating); sensors: SensorManager (≤ 200 Hz); location: NMEA listener + GPS updates, or one fix. Stop all / Repair / Reset call `BridgeService.stopAll` |
| `ui/LinuxAppsActivity` + `gui/LinuxAppsViewModel`, `LinuxApps`, `LaunchActivity` | *Linux apps* (terminal menu): Termux:X11 missing → link to its GitHub releases; WM missing → install button; list with icons, tap = `x11.sh run` + open `com.termux.x11/.MainActivity`, hold = pinned shortcut (`ShortcutManagerCompat`) to `LaunchActivity` (translucent, no window: deploy scripts, run, open Termux:X11). `<queries>` names `com.termux.x11` |
| `ui/AboutActivity` | app version, license, source link, NOTICE / GPL / Apache texts from `assets/licenses/` |

- libsu: `FLAG_MOUNT_MASTER` **silently falls back** to plain `su`, then `sh`
  (`BuilderImpl`). So preflight compares `mnt_ns` with `init_mnt_ns` and refuses if they
  differ. libsu also caches the main shell: after a denial the cache holds the `sh`
  fallback, so `RootShell.isRoot()` closes a cached non-root shell before retrying.
- Magisk on the test device rejected the app's `su` **without showing a prompt**
  (`su: request rejected (10121)` in logcat, no `SuRequest` activity started). Settings
  were default (prompt) and app and daemon were both 31.1. Root was granted with
  `magisk --sqlite "INSERT OR REPLACE INTO policies ... VALUES(<uid>,2,0,1,1)"`. The
  cause is unknown.
- **Controlling TTY:** Magisk's `su` passes the terminal's pts straight to the root
  process but `setsid()`s it without making the pts its controlling terminal
  (`tty_nr=0`). bash then says "no job control", and Ctrl+C reaches the su client's
  process group instead. `enter.sh` therefore runs `setsid --ctty --wait` (util-linux:
  `setsid()` then `ioctl(0, TIOCSCTTY, 1)`, a forced steal, allowed for root) when stdin
  is a tty. Verified via `/proc/<pid>/stat`: bash is session leader of the pts and the
  foreground job owns `tpgid`. Not covered by the suites, which have no tty.
- Recovery: a run killed after `install.sh` resumes as "rootfs installed, setup
  pending" (the atomic `rootfs.partial` rename makes that safe), and preflight deletes
  a leftover tarball. When the session ends, Enter goes back through `MainActivity`
  (preflight), never straight into `enter.sh` (the rootfs may have been reset).
- Termux v0.118.3 details (javap): `TerminalView.inputCodePoint(cp, ctrl, alt)` itself
  calls `readControlKey()/readAltKey()`, `handleKeyCode(keyCode, mod)` does not, so the
  extra keys pass `KeyHandler.KEYMOD_*` for coded keys. `TerminalView.onKeyDown` stops the
  text selection *before* asking the client, so Ctrl+Shift+C/V/T are caught in an
  `OnKeyListener` (overriding `ComponentActivity.dispatchKeyEvent` trips lint
  RestrictedApi). `TerminalColorScheme.updateWith()` starts with `reset()`, so the dark
  theme is an empty map; each emulator's `mColors.reset()` copies the global scheme. A
  session's process only starts on the first `attachSession` (size known).
- **Closing a tab must hang up the session itself.** Killing the app-side `su` client and
  closing the pty master left `su`+`bash` running in the chroot (tty_nr unchanged, so
  no hangup reached them): the session leader is util-linux `su -`, which blocks SIGHUP
  (SigBlk `fffffffefffb9eff`), and bash is in another process group. `hangup.sh` finds the
  pty from `/proc/<client>/fd/0` (`stat -L`, so it works across mount namespaces) and
  HUPs the chroot processes with that `tty_nr`. Verified on the device and in Docker
  (`script(1)` gives a real pty).
- **Root shells started by the app share its cgroup** (the same reason `am force-stop`
  kills them). In the background a fork costs far more: the old `ubu_chroot_pids`
  (a `readlink` per process, ~650 processes) took ~0.75 s from adb but ~12 s per call
  from the app, and *Stop all* took ~40 s. It is now one `ls -l /proc/*/root | awk`.
  `umount.sh` also runs `--make-rprivate` only on the topmost mounts (it is recursive;
  `ubu_any_shared_under` still aborts if anything stays shared) and HUPs before TERM
  (interactive bash ignores TERM). Full unmount of 54 mounts: 18 s → 1.7 s; *Stop all*
  with a session: ~5 s.
- Foreground service type: `specialUse` with `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`
  (no other type fits a terminal). The typed `startForeground` path (API 34+) and the
  POST_NOTIFICATIONS request (API 33+) are untested: the test phone is Android 12.
  Hardware keyboard shortcuts were verified with a virtual keyboard: a Python script in
  the chroot (as root) creates a `/dev/uinput` device (Android 12's `input` has no
  `keycombination`). Ctrl+Shift+V pasted and Ctrl+Shift+T opened a tab. **Ctrl+Shift+C
  never copied** (found 2026-11-16, selection made with `input swipe X Y X Y 1200`):
  the keyboard sends Ctrl/Shift as key events of their own, and `TerminalView.onKeyDown`
  calls `stopTextSelectionMode()` for any key while `isSelectingText()` (javap of
  v0.118.3). `onShortcut` now consumes modifier-only events while selecting; verified on
  the S9 with the CI release build of `43f1f15` (copied `selectme42`, pasted back). Test
  pitfall: plugging in a keyboard (uinput device) is a `keyboard` config change and
  also ends the selection, so connect it first and long-press afterwards. Still
  untested: pinch-to-zoom (no multi-touch over adb).
- User names: `[a-z_][a-z0-9_-]{0,31}`, minus the accounts that already exist in
  Ubuntu Base (`setup.sh` would reuse them and grant sudo). Without `--uid`, `setup.sh`
  takes the first id >= 9000 that is free as both uid and gid.
- UI strings: English by default in `values/strings.xml` (as `prompt.md` asks, for F-Droid
  and community translations), Brazilian Portuguese in `values-pt-rBR/strings.xml`.
  Every new string goes into both. The reset confirmation word is a string too: `DELETE`
  in English, `APAGAR` in pt-BR. No Ubuntu logo: the icon is a plain `>_` prompt.

## Android bridge (Phase 4)

- **A chroot user can't broadcast.** `am broadcast` as uid 9000 fails (rc 255, verified
  on the device): the uid holds no Android permission. As root it works, and root (uid 0)
  passes every permission check, including the receiver's signature permission (which
  keeps other apps and adb's shell uid out). So the `uburoot-*` commands go through
  **one sudo rule** for one root helper (`uburoot-send`). The helper re-validates every
  argument, caps text at 100 kB (one binder transaction) and only sends fixed extras.
- **Files are read as the caller** (`setpriv --reuid=$SUDO_UID --regid=$SUDO_GID
  --init-groups`), never as root, and copied into the root-only outbox under a random
  16-hex id. The app then pre-creates `cache/open/<id>/<name>` itself (so the file has the
  app's owner and SELinux label) and runs `bridge.sh take`, which only fills that file.
  Viewers get a `content://` URI with a read grant. Outbox leftovers older than a day are
  deleted on the next open; the app's copies after a day.
- `am broadcast` is ordered (serialized), so the receiver's result code/data comes back:
  `result=-1` = done, else `data="<message>"` is printed in the terminal.
- **Background activity starts:** Android 10+ blocks them, so `open` passes
  `--allow-background-activity-starts` (present in Android 12's `am`; only the broadcast
  sender's privilege matters) and the receiver keeps the broadcast open with `goAsync`
  until the viewer has started (≤ 8 s of the foreground broadcast's 10 s).
- **Import runs as the user inside the chroot** (`setpriv` + `chroot`), so a symlinked
  `~/Shared` can't make root write outside it (Docker test with `~/Shared -> /hostonly`).
- Verified on the device (Magisk 31.1, Android 12): every command as `ana` (a sudoer)
  and as a user outside `sudo`, with the app in the background and force-stopped (a
  cold start takes 0.75 s, `open` of a file 1.1 s). `/etc/shadow` and another user's
  file are refused. The copy in `cache/open` is `u0_a123` with label `app_data_file`. The
  receiver's error text reaches the terminal (`no app can open nosuchscheme://x`).
  Sharing an externalstorage document opened a session in `/sdcard/Download`, and
  sharing text opened one in `~/Shared`.
- The MediaStore branch of `ShareActivity.locate` can't be tested from adb: a
  `--grant-read-uri-permission` from `am` (shell or root) doesn't give the app access
  (`SecurityException ... has no access to content://media/...`). A real share does.
  On 2026-11-16 the user shared a photo from the gallery (uid 10073,
  `content://media/external/images/media/<id>`). The session opened in
  `/sdcard/Pictures/Screenshots`, with no import and no error.
- `ShareActivity` has `taskAffinity=""`. Otherwise a share started with `NEW_TASK`
  became the root of the terminal's task, and the next identical share only brought
  that task to the front (no new activity).
- Reading the clipboard with `service call clipboard` as root **clears it** ("Could
  not grant permission to primary clip. Clearing clipboard"). Check a clip by pasting
  into the terminal instead.
- Boot test on the device (2026-11-16): the S9's `/data` is **unencrypted**
  (`ro.crypto.state=unencrypted`), so the wait for the first unlock never happened.
  That path is untested on a device. On FBE phones `sys.user.0.ce_available` turns
  `true` after the unlock, and `boot.sh` checks the shared-storage directories, which
  also works in Docker. Processes started at boot run as `u:r:magisk:s0` and outside
  the app's cgroup, so a force-stop of the app doesn't kill them, but *Stop all*
  (`umount.sh --kill`) does.
- Toybox `sed` doesn't understand `\x27`; write config lines with plain values (`KEY=0`
  is valid shell and `ShellAssignments` reads it).
- KDoc gotcha: Kotlin block comments nest, so a comment containing
  `/etc/uburoot-boot.d/*` opens a nested comment that swallows the code after it
  (the compiler only reports "unresolved reference"). Don't write `/*` inside comments.
- Docker's fake `/system/bin/am` must only use mksh builtins (`print -r`): the Android
  `PATH` in the chroot has no `printf`.

## One file: APK + root module + Magisk recovery zip

An APK is a ZIP, so the same signed file also carries the module files.
`app/src/module/` goes to the APK root as Java resources (`ModuleFilesTask` in
`app/build.gradle.kts`, with `@VERSION_NAME@/@VERSION_CODE@` filled in). It is inside
the v2 signature: `apksigner verify` passes and Android installs the file normally.
Magisk itself does the same (its APK has `META-INF/com/google/android/update-binary`).

| How | Works with | What happens |
|-----|-----------|--------------|
| Install as APK | any | normal app |
| Root manager "Install from storage" | Magisk, KernelSU, APatch | `customize.sh` (`SKIPUNZIP=1`) extracts only `module.prop` + `service.sh` (never dex/libs), keeps a copy of the APK and installs it with `pm install -r` right away (`BOOTMODE=true`) |
| Custom recovery (TWRP) | **Magisk only** | `update-binary` sources `/data/adb/magisk/util_functions.sh` and calls `install_module` (Magisk's documented module installer). The app is installed by `service.sh` after `sys.boot_completed`. KernelSU and APatch docs say their modules are NOT recovery-compatible, so the script says so and exits 1 |

- Verified on the device (Magisk 31.1): `magisk --install-module uburoot.zip` → module
  "UbuRoot by reinanbr", app reinstalled by `customize.sh`, module dir = `module.prop` +
  `service.sh`. With `SKIPUNZIP=1`, Magisk does NOT copy `module.prop` itself
  (`install_module` in util_functions.sh), so `customize.sh` must extract it.
  The test module was removed afterwards. Recovery flashing has not been tested: the
  S9 has TWRP (Omni-based `starqltechn` build, 2022), but on 2026-11-16 the user chose
  to skip it, since installing through Magisk already works.
- Managers' file pickers may not list `*.apk` (not confirmed in source). Publish the
  same bytes also as `.zip`, or tell users to rename. Magisk's own docs do this for
  its APK.
- `service.sh` (late_start, global mount namespace, non-blocking) installs the app copy
  if there is one, then runs `bin/boot.sh` (log `boot.log`, the previous one
  `boot.log.old`). It does so only if `/data/local/uburoot`, `bin` and `boot.sh` are
  owned by root and not writable by group or others. Magisk, KernelSU and APatch run
  module scripts with their busybox `sh`, so `stat -c` is available. There is
  deliberately **no `uninstall.sh`**: removing the module never touches the rootfs
  (critical rule).
- Magisk guide: "DO NOT add custom logic in update-binary" (the Magisk app replaces it).
  Ours only hands over to `install_module`, the same thing Magisk's
  `module_installer.sh` does.

## Milestone 2 decisions and evidence

- **Full-root gate.** `ubu_root_report` (common.sh) reads `/proc/$$/status`: full root =
  `CapEff` and `CapBnd` equal to every capability up to `cap_last_cap`, `Seccomp 0`,
  `NoNewPrivs` 0 or absent (the line only exists since Linux 4.10; the S9's 4.9 has
  none). The preflight refuses otherwise (`Problem.RESTRICTED_ROOT`). Why: KernelSU's
  App Profile sets `CapEff/CapPrm/CapBnd` from its `capabilities.effective` field
  (default `CAP_FULL_SET`) and can switch the SELinux domain (default `u:r:ksu:s0`),
  in `kernel/policy/app_profile.c` `escape_with_root_profile` and
  `uapi/app_profile.h`, checked 2026-11-16; it always disables seccomp, and
  `FLAG_KSU_NO_NEW_PRIVS` is KernelSU's own flag, not the kernel's. APatch's `SuProfile`
  has only `uid`, `to_uid`, `scontext`. On the S9 (Magisk 31.1) root has
  `CapEff=CapBnd=0x3fffffffff` (`cap_last_cap` 37), Seccomp 0, `u:r:magisk:s0`,
  enforcing. Docker: `setpriv --bounding-set -sys_module` and `--no-new-privs` both give
  `full_root=no`.
- **Rootfs schema.** `UBU_SCHEMA` in common.sh (now 3: 2 = the profile hook sets `DISPLAY=:0` once `/etc/uburoot/x11` exists; 3 = the hook sets `XDG_RUNTIME_DIR=~/.cache/uburoot/run`, the session bus and `/etc/uburoot/gpu.env`, and `/etc/apt/preferences.d/80uburoot-no-snap`). `/etc/uburoot-release` holds
  `SCHEMA`, `INSTALLED` (mtime of `uburoot-setup.done`) and `UBUNTU`. A migration may
  only rewrite UbuRoot's own files (profile hook, policy-rc.d, AID groups, the iptables
  selector), never APT sources, users or packages (Docker compares `passwd` and the
  sources before and after). To add one: bump `UBU_SCHEMA`, write `migrate_N`, extend
  the Docker "old rootfs" case.
- **Kernel filesystem binds were moved to Phase 2** (behind `KERNEL_ACCESS`), so Phase 1
  adds no mounts. On the S9 the host has configfs at **`/config`** (Android 12 init,
  with `usb_gadget`), debugfs at `/sys/kernel/debug`, tracefs at `/sys/kernel/tracing`,
  bpffs at `/sys/fs/bpf`; inside the chroot all of them are empty today. No ROM module
  directory exists and no modules are loaded; `MODULE_SIG_FORCE=y`, `MODVERSIONS=y`.
  Config: `USER_NS OVERLAY_FS TUN CONFIGFS USB_CONFIGFS{,_NCM,_ACM,_MASS_STORAGE,_F_HID}
  CFG80211 WIREGUARD BPF_SYSCALL BT` = y; `BINFMT_MISC MAC80211 CAN NF_TABLES
  USB_CONFIGFS_RNDIS SQUASHFS KVM KPROBES UPROBES DEBUG_INFO_BTF` = n. Sysctls:
  `kptr_restrict 4`, `dmesg_restrict 0`, `perf_event_paranoid 3`,
  `unprivileged_bpf_disabled 0`, `security.perf_harden=1`.
- **Phase 2 kernel access, evidence (S9, 2026-11-16).**
  - Host kernel mounts: configfs `/config`, debugfs, tracefs `/sys/kernel/tracing`, bpf
    `/sys/fs/bpf` (38 netd/clatd pins), cgroup2 `/sys/fs/cgroup`, cgroup v1
    `/dev/{blkio,cpuctl,cpuset,memcg,stune,freezer}`, pstore (`console-ramoops-0`),
    selinuxfs, fusectl. No securityfs or binfmt_misc. `/proc/last_kmsg` exists.
  - `mount.sh` binds the host's instance where there is one, makes it rslave, and
    mounts a new instance only where the host has none and the type is in
    `/proc/filesystems`. It never `mkdir`s inside sysfs/proc: it binds only where the
    target exists.
  - **Root is already in a permissive domain.** `u:r:magisk:s0` denials log
    `permissive=1`. Sources (2026-11-16): Magisk `native/src/sepolicy/rules.rs`
    `permissive([proc])` (commit `70d233cae2`); KernelSU `kernel/selinux/rules.c:92`
    `ksu_permissive(db, KERNEL_SU_DOMAIN)` (`019a3c0103`); KernelPatch `scdefs.h`
    `ALL_ALLOW_SCONTEXT_MAGISK "u:r:magisk:s0"`. So `selinux permissive` is rarely
    needed.
  - **kptr_restrict.** The S9 boots with 4, a vendor value: writes accept only 0–2
    (`echo 3/4` fails). So `revert` writes 2 when the original is > 2 and can't be
    written back (same effect: hidden even from root). Android init:
    `on property:security.lower_kptr_restrict=1` writes 0, `=0` writes 2
    (`/system/etc/init/hw/init.rc:1247`). `simpleperf record` toggles that property
    (seen: the prop went from empty to `0`); `simpleperf stat`, trace-cmd and bpftool
    don't touch it. Once during testing it read 0 with the property unset; the cause
    was not found.
  - **`simpleperf` leaves `security.perf_harden=0`** (seen after the tests:
    `perf_event_paranoid` -1, `sys.init.perf_lsm_hooks` empty; init.rc:1228 would write
    1, so something else wrote -1, not found). `setprop security.perf_harden 1` brought
    back 3. Documented in `docs/KERNEL.md`; not recorded by kernel.sh (a property).
  - Modules: `MODULE_SIG_FORCE=y`, so an unsigned `.ko` fails with "Required key not
    available" and `uburoot-kmod` explains it. The ROM has no module directories.
  - bpftool fails on 4.9 ("can't get next program": ID iteration and
    `BPF_OBJ_GET_INFO_BY_FD` need 4.13). trace-cmd recorded 1060 `sched_switch` events
    and set `tracing_on` back to 0. `simpleperf stat` works as root.
  - With a session open, `selinux permissive` + `devmode on`, then `umount.sh --kill;
    kernel.sh -y revert` (what *Stop all* runs) took 4 s. Afterwards: Enforcing,
    kptr_restrict 2, `/proc/1/mountinfo` outside the rootfs identical to the baseline
    (1068 lines), the USB gadget UDC still bound, the 38 BPF pins intact.
  - Manager module loaders (`ksud insmod`, `apd insmod`, APatch KPM) are documented in
    `docs/KERNEL.md`, not wrapped: they are manager-specific, and KPM needs the
    superkey.
- **Phase 3 hardware access, evidence (S9, 2026-11-16).** User-facing: `docs/HARDWARE.md`.
  - AIDs from AOSP 12 `android_filesystem_config.h`: SYSTEM 1000, BLUETOOTH 1002,
    GRAPHICS 1003, INPUT 1004, AUDIO 1005, CAMERA 1006, WIFI 1010, USB 1018, MEDIA_RW
    1023, NFC 1027, UHID 3011. Grants create `aid_*` groups with those gids (an
    existing group with the gid is reused under its name). Ubuntu's own groups:
    dialout 20, plugdev 46.
  - Nodes: `/dev/kgsl-3d0` 1000:1000 0666, `/dev/dri/*` root:1003 0666, `fb0`
    root:1003 0660, `input/event*` root:1004 0660, `/dev/uinput` 3011:3011 0660,
    `snd/*` 1000:1005 (116), `video*`/`media*`/`v4l-subdev*` 1000:1006, `ttyHS0`
    1002:1002 (BT UART), `sec-nfc` 1027, `gpiochip*` and `rfkill` root 0600, no
    `/dev/bus/usb` until OTG. ueventd: `/dev/bus/usb/*` 0660 root usb; no rule for
    `ttyACM*`/`ttyUSB*`/`hidraw*` (root 0600), hence the permission rules.
  - Kernel config: no `BT_HCIUART`/`BT_HCIBTUSB`/`BT_HCIVHCI` (no Bluetooth takeover
    possible), `NFC` off, `MEDIA_USB_SUPPORT` off (no UVC), IIO on without devices;
    `USB_ACM`, `USB_SERIAL_FTDI_SIO`, `USB_SERIAL_PL2303` (no CP210X/CH341),
    `SND_USB_AUDIO`, `HIDRAW`, `UHID`, `INPUT_UINPUT`, `I2C_CHARDEV`, `SPI_SPIDEV`,
    `GPIO_SYSFS` on.
  - Wi-Fi takeover: `cmd wifi set-scan-always-available disabled` + `cmd wifi
    set-wifi-enabled disabled` → `wlan0` down, `/vendor/bin/hw/wpa_supplicant` exits,
    `phy0` stays; Ubuntu's `ip link set wlan0 up` + `iw dev wlan0 scan` worked. `cmd wifi
    status` first line is `Wifi is enabled|disabled`; scan-always is `settings get
    global wifi_scan_always_enabled`. Modes IBSS/managed/AP/P2P, no monitor.
  - cpufreq: policy0 (0-3, 576000-1766400), policy4 (4-7, 825600-2803200), schedutil;
    `vendor.qti.hardware.perf@2.0-service` and `thermal-engine` may change limits back.
    `/sys/power/wake_lock` exists. The battery driver exposes `batt_tune_*` voltage
    knobs: read-only by design (`set` accepts only LED files).
  - Tools installed into the rootfs run with Ubuntu's `/bin/sh` (`ubu_install_tool`
    rewrites the `#!/system/bin/sh` line): `/system/bin/sh` exists inside only with
    `ANDROID_INTEGRATION`.
  - **Writes to sysfs/proc: one `write()`, so `wr VALUE FILE` (changes.sh) = the
    shell's builtin `echo`, never `printf`.** mksh has no builtin printf, and toybox's
    writes `2803200` and `\n` separately (Ubuntu's strace on `/system/bin/printf` on the
    S9); sysfs stores each write, so the lone `\n` fails with EINVAL. Seen as Stop all
    leaving `file` records of the CPU max and an LED. Phase 2 hid it: its values were
    one digit. `mount.sh` already used `echo` for inotify.
  - policy4's `cpuinfo_max_freq` 2803200 (boost) is not in
    `scaling_available_frequencies` (ends at 2649600): `cpu min|max` also accepts the
    `cpuinfo_min/max_freq` values. Samsung's `led_b` ignores writes (reads back 0);
    `led_r`/`led_g` show Android's notification LED.
  - **Device test (CI release APK of `4eb727e` + the fixes pushed with
    `adb-push-scripts.sh`, 2026-11-16).** Settings: the warning appears when turning it
    on, Save writes `HARDWARE_ACCESS='1'`, *Repair mounts* installs `uburoot-hw` (`#!/bin/sh`)
    and binds the log. Inside Ubuntu: `list`/`info`/`cpu`/`status`; out-of-table frequency,
    `cpu0` offline and a battery file refused; `grant uinput ana` → `aid_uhid` 3011.
    Takeover from the CLI and from the Hardware screen (dialog), Ubuntu's real
    `wpa_supplicant` on `wlan0`; *Give back* stopped it and Android started its own
    (`-g@android:wpa_wlan0`), Wi-Fi and scanning back to 1. The revert from the screen
    and from `kernel.sh -y revert` restored policy4 max, policy0 governor, `led_r` and the
    wake lock. From adb: `status` 2.1 s, takeover 1.0 s, release 0.5 s (`kill_ubuntu_exe`
    is one `ls -l /proc/*/exe | awk`; the readlink loop made a release from the app ~20 s).
  - **Terminal menu jumped under the finger.** With the keyboard up, opening the menu
    hides the IME (the popup takes the focus; `mInputShown` true → false), the window
    resizes (`adjustResize`) and the open popup moved 120 px down 1–3 s later (dumps at
    t1/t2/t3: *Hardware* at y 1584, then 1704). Taps planned on the first layout opened
    *Kernel* or *About*. Now ⋮ hides the keyboard first and opens the menu once
    `WindowInsets.isImeVisible` is false (1.5 s fallback). "Close session" is also always
    in the menu (disabled without a session). An earlier guess, that the item was
    inserted while the menu was open, was wrong: the dumps had it both times.
  - **Change-log lock and SIGPIPE.** Under dash, `uburoot-kernel status | grep -q ...`
    left `state/.lock` forever: grep exits early, dash dies of SIGPIPE and runs no EXIT
    trap (mksh did, so the suite only saw it once the tools ran with Ubuntu's `/bin/sh`).
    `_lock` now traps PIPE too, writes its pid to `.lock/pid`, and breaks a lock whose
    owner is gone (`kill -0`; Android and the chroot share the pid namespace).
- **Phase 3b USB gadget, evidence (S9, 2026-11-16).** configfs at `/config/usb_gadget`
  (g1 bound to UDC `a600000.dwc3`, g2 idle); `configs/b.1/f1 -> functions/ffs.adb`,
  VID:PID 04e8:6860; `sys.usb.config=adb`, `sys.usb.configfs=1`. Instances already in g1
  include `ncm.0` (ifname `usb0`), `acm.0` (`/dev/ttyGS0`), `mass_storage.0` (`lun.0`),
  `gsi.rndis`, `ffs.adb`, `mtp.gs0`. Init rules: `/system/etc/init/hw/init.usb.configfs.rc`
  and `/vendor/etc/init/hw/init.msm.usb.configfs.rc:45-55` (the adb action `rm`s
  `f1..f9`, symlinks `f1`, writes the UDC).
  - **Kernel panic.** The first version mkdir'ed `ncm.uburoot`/`acm.uburoot` and at
    `gadget off` unbound, unlinked and `rmdir`ed them. The add worked (host: CDC NCM +
    CDC ACM + ADB, adb stayed up), the removal panicked the phone: pstore
    `/sys/fs/pstore/dmesg-ramoops-0` showed `[rmdir] Unable to handle kernel NULL
    pointer dereference at virtual address 0000029f`, `PC is at ncm_free_inst+0x1c/0x70`,
    `LR is at usb_put_function_instance+0x20`, trace `ncm_free_inst ← ncm_attr_release ←
    configfs_rmdir`; `sys.boot.reason=kernel_panic`. Init was running its
    `sys.usb.config=adb && sys.usb.ffs.ready=1` action at the same time (the unbind
    restarts adbd's FunctionFS; "symlink f1: File exists", UDC write EBUSY).
  - **Fix: never rmdir an instance.** Reuse Android's (`ncm.0`, `acm.0`,
    `mass_storage.0`), add/remove only `uburoot.*` links; HID instances
    (`hid.uburootkbd`/`hid.uburootmouse`) are created once and left until reboot.
    `gadget_bind` retries the UDC write for 10 s and accepts init having bound it.
    Two on/off cycles (ncm + acm + hid + an 8 MB read-only image) passed: host saw CDC NCM
    (`enx…`), `/dev/ttyACM0`, two HID interfaces (6 hidraw), `sda 8M ro`, ADB; afterwards
    only ADB, `mass_storage.0` file empty, same boot_id (no panic), change log empty.
  - HID report descriptors: boot keyboard 63 bytes, boot mouse 52 bytes (`hid_desc`).
    Binary attributes are written through a temp file + `cat` (one write).
- **Background jobs and mksh's saved fds.** `bb chroot ... >/dev/null 2>&1 &` (bb is a
  shell function) left the backgrounded subshell holding the caller's stdout: a
  redirection on a function call saves the original fd (kept open while the function
  runs). So `$(enter.sh root CMD)` hung forever once a rule watcher was started by
  `mount.sh` (found by the Docker bridge tests), and every session started another
  watcher. Now `( exec </dev/null >/dev/null 2>&1; bb chroot ... ) &`, and `watch`
  exits when a live watcher already holds the pidfile.
- **Phase 3b bridges, design.** The app serves (abstract `LocalServerSocket`), Ubuntu
  connects. Not localhost TCP: netd's allowlist chains drop uid ≥ 10000 (the app)
  in restricted networking mode. Abstract sockets have no permissions, so a token
  (published in a 0640 file for the class's group) plus a peer-uid check (0 or
  8000–9996). perl-base has `Socket`/`IO::Select` in Ubuntu Base 26.04
  (`/usr/lib/aarch64-linux-gnu/perl-base/Socket.pm`, checked on the S9); socat and
  python3 are not in Ubuntu Base. Background camera/microphone/location (Android 11+)
  need a foreground service of that type started while the app is in front: the Hardware
  screen starts it. `LocationListener`'s other methods are abstract before API 30, so the
  listener implements all four. Sensors above 200 Hz need `HIGH_SAMPLING_RATE_SENSORS`
  (Android 12+): capped at 200.
- **Phase 3b bridges, device test (CI release APK of `4088af0`, S9, 2026-11-16).**
  Turning each bridge on asked for its permission ("While using the app") and
  published `/run/uburoot-bridge/{audio,camera,sensors,location}` (groups audio 1005,
  camera 1006, `uburoot-sensors`/`uburoot-location` created by `groupadd -r`: 988/996).
  As root inside Ubuntu: 30 sensors, `read accelerometer` (4 fields), `stream … 50`
  gave 100 lines in 2 s; cameras 0 back, 1 and 2 front; `snap` 640x480 in 3.2 s
  (valid JPEG); 1 s 440 Hz tone played; 2 s of microphone = 172032 bytes, not silent;
  NMEA flowed indoors ($GPGSV only, no fix). uid 9000 with gid 1005 was served, without
  it got "Permission denied … grant", a wrong token got `ERR refused`. **With the app in
  the background (HOME)** camera, microphone (peak 1526, not zeroed), sensors and NMEA
  kept working (the foreground service types). The front camera's frames came with
  the HAL's whole buffer (~1.6 MB of zeros after EOI at 640x480; the back camera's
  ended at `FF D9`), so frames are cut after the last EOI (`Bridges.jpegOnly`).
  Gadget NCM from the screen (dialog → host sees NCM + ADB, 1 change), then *Stop all*
  from the menu: BridgeService and SessionService gone, 0 mounts under the rootfs,
  gadget ADB only, 0 changes, token files gone. CI APK of `5e133b6`: front camera MJPEG
  640x480 = 2.1 MB in 4 s (was 142 MB), frames end in `FF D9`.
- **Phase 4 GUI (Termux:X11 companion), evidence (S9, Termux:X11 nightly 1.03.01,
  2026-11-16).** Details in `docs/GUI.md`.
  - The server runs as root via `app_process` with **SELinux enforcing** (no denial;
    the activity logged "XCB connection is successfull").
  - Defaults were unusable on a phone: native 1440x2960 at 96 dpi and touch as a
    trackpad. `x11.sh` sets these once through `am broadcast -a
    com.termux.x11.CHANGE_PREFERENCE -p com.termux.x11 -e KEY VALUE` (`-e list null`
    lists the keys): `displayResolutionMode=scaled`, `displayScale` = density×100/240
    (480 dpi → 200), `touchMode=2` (simulated touchscreen).
  - matchbox (`-use_titlebar no`) makes every window full screen.
  - `ACTION_STOP` (`am broadcast -a com.termux.x11.ACTION_STOP -p com.termux.x11`)
    closes the activity. A restarted server whose activity was still attached to the
    previous one failed with "BufferQueueProducer … already connected" /
    `eglCreateWindowSurface failed` and the screen froze on the old frame, so `start`
    closes the activity first.
  - `/run/uburoot` is 0700, so the user's launcher lives in `/run/uburoot-x11` (0755).
  - Pitfall: `pkill -f uburoot-x11` inside `su -c '…uburoot-x11…'` kills that shell
    itself (exit 143); use `pidof`.
  - Wireshark 4.6.4: `dumpcap` is `root:wireshark 0754` with
    `cap_net_admin,cap_net_raw=eip`. File caps work on this kernel. With `usermod -aG
    wireshark ana` (done on the S9 at the owner's request) ana captured on wlan0. Not
    granted by setup.sh: it exposes the whole phone's traffic, the same reason
    `aid_net_raw` isn't granted.
- **Phase 4 part 2 (S9, 2026-11-16).** Details and numbers in `docs/GUI.md`.
  - **GPU.** Ubuntu's Turnip is built with Mesa's default `freedreno-kmds=['msm']`
    (`meson.options:223`; `debian/rules` doesn't change it), so on Android only
    llvmpipe appears. `tools/gpu/build-turnip.sh` builds Turnip with `kgsl` from Ubuntu's
    source package as a separate ICD. On the S9: "Turnip Adreno (TM) 630" Vulkan 1.3;
    Zink OpenGL 4.6. glmark2 full screen: 36 vs llvmpipe 9; off-screen 223 vs 24.
  - **SONAME pitfall.** Ubuntu's ICD json has the bare `libvulkan_freedreno.so`. Our
    copy under that SONAME was returned for it by glibc, so the GPU was listed twice.
    Now `patchelf --set-soname libvulkan_freedreno_kgsl.so`.
  - On-screen presentation is a CPU copy (no DRI3 to Termux:X11; no SysV shm on Android
    kernels: `shmget()` ENOSYS, so no MIT-SHM). This caps it near 40–45 FPS.
  - **Sound.** `x11.sh run` starts PulseAudio + `uburoot-audio pulse` when PulseAudio is
    installed and the audio bridge is on. A `pacat` tone became an active
    AudioFlinger track of the app.
  - **Clipboard.** Termux:X11's own sync works both ways (`clipboardEnable=true`).
  - **Session bus.** GNOME apps needed one ("dbus-launch" missing).
    `XDG_RUNTIME_DIR=~/.cache/uburoot/run` comes from the hook; `x11.sh` starts
    `dbus-daemon --session` there.
  - **Snaps.** `firefox`/`chromium-browser`/`thunderbird` are snap transitional debs
    (Pre-Depends snapd; their preinst retries the store for 30 min, then fails).
    APT pins: `Pin: version /snap/` for those names and `snapd` at -1. Pitfalls: version
    pins don't work with `Package: *`, and a trailing `*` is a prefix match in apt's
    `versionmatch.cc`, so `*snap*` matched nothing.
  - **User namespaces.** The kernel refuses `CLONE_NEWUSER` to chrooted processes
    (`current_chrooted()` in `create_user_ns`). `unshare -U` fails inside even as root
    and works outside. So bwrap sandboxes can't run (Epiphany). Disabling a browser
    sandbox is the user's call; the app doesn't do it.
  - Acceptance on the S9: Wireshark (capture), GIMP 3.2.2, Mousepad (typing from
    Android). Not tested: Ghidra (not in Ubuntu), gqrx (no RTL-SDR dongle), a working
    browser.
- **Phase 4 part 3 (S9, 2026-11-16).**
  - matchbox 1.2.3 handles `_NET_ACTIVE_WINDOW`/`_NET_CLOSE_WINDOW` on the root window
    (`src/ewmh.c` `ewmh_handle_root_message`), so `wmctrl -i -a|-c` works. A first test
    looked like a failure: the raised Mousepad window was a small session-restore
    dialog below the screenshot's crop. Check `_NET_CLIENT_LIST_STACKING` with `xprop`.
  - `wmctrl -l -x` prints WM_CLASS as `instance.class` (both may contain dots), so the
    matcher accepts `s`, `s.*` or `*.s`. GIMP: `Exec=gimp-3.2`, `StartupWMClass=gimp`;
    Firefox: `StartupWMClass=firefox`.
  - XFCE vs LXQt sizes from a clean `ubuntu:26.04` (`apt-get install --print-uris
    --no-install-recommends`): 211 pkgs/90 MB vs 318/156 MB.
  - Mozilla: fingerprint from hacks.mozilla.org (2023-11 post), `InRelease` checked with
    `gpgv`. SUMO's article is behind a JS challenge (not readable by tools).
    `Package: firefox*` with an origin pin is fine (the glob problem was only version
    pins). Ubuntu Base has no CA list: `ca-certificates` first.
  - Time zone: Ubuntu Base has no tzdata and no `/etc/localtime` (UTC). `setup.sh` now
    installs `tzdata`; `mount.sh` section 5 links `/etc/localtime` to Android's
    `persist.sys.timezone` (S9: `America/Sao_Paulo`) on every mount, and records it in
    `/etc/uburoot/timezone`. Only a missing link, the default `Etc/UTC` or the zone it
    wrote last is replaced, so a zone picked with `dpkg-reconfigure tzdata` stays.
    Older rootfs without tzdata: `sudo apt install tzdata` (a migration may not install
    packages). Docker's fake `getprop` reads the zone from `/tmp/android-tz`.
  - XFCE adds ~25 entries with `OnlyShowIn=XFCE;` (its settings dialogs, About, Run…):
    `x11.sh apps` leaves out any entry with `OnlyShowIn` (the list isn't a desktop).
  - CI release APK of `70c2d22` on the S9: *Linux apps* listed the 5 open windows with
    app icons; a tap raised Wireshark inside the XFCE session, ✕ closed GIMP's welcome
    dialog, *Open the desktop* showed it. The *Install the desktop* / *Install Firefox*
    buttons were not tapped (both installed from adb; they stream like *Install the
    window tools*). Afterwards `umount.sh --kill`: 0 mounts, 1068 host mounts, 0 changes.
- **Offline install / xz.** Magisk's busybox 1.36.1.1 `tar` has `-J` (checked on the
  S9). Ubuntu Base has no `ca-certificates`, so mirrors are `http://` only (apt checks
  the archive signatures anyway). The app copies a SAF file into its cache, then
  `install.sh` reads the format from the content.
- **Install wake lock.** A partial wake lock with a 1 h cap during download/extract and
  `FLAG_KEEP_SCREEN_ON` while the install screen is working (NetHunter's installer
  warns that Android kills it otherwise).
- **License.** GPL-3.0-or-later since the commit after v0.2.1 (all earlier commits were
  by the maintainer, with Claude as co-author; the only PR, #1, is his). `LICENSE` is
  the gnu.org text (SHA-256 `3972dc97…`), `LICENSES/Apache-2.0.txt` covers Termux's
  libraries, libsu and AndroidX. `LicenseAssetsTask` copies `LICENSE`, `NOTICE` and
  `LICENSES/Apache-2.0.txt` into `assets/licenses/` for the About screen. SPDX headers
  are on our Kotlin, shell and Gradle files, never on `gradlew*` or the wrapper.

## Root implementations and mount namespaces (verified in source, 2026-11)

User-facing version: [docs/ROOT_IMPLEMENTATIONS.md](docs/ROOT_IMPLEMENTATIONS.md) (keep both
in sync).

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
  `aid_net_raw` 3004, `aid_net_admin` 3005. **Only root** gets all three; the user
  and `_apt` get `aid_inet` only (a re-run of `setup.sh` removes older memberships).
  On Android kernels `aid_net_raw`/`aid_net_admin` act as CAP_NET_RAW/CAP_NET_ADMIN:
  on the device a user in them ran `tcpdump -i wlan0` (the whole phone's traffic),
  `nmap --privileged -sS` and `ip link add` without sudo. Ping needs neither
  (AOSP init.rc sets `ping_group_range` to `0 2147483647`). Packet tools go through
  `sudo`; opt in by hand with `usermod -aG aid_net_raw,aid_net_admin <user>`. APT
  drops privileges with `setgroups(1, &pw_gid)`, so it keeps **only the primary group**.
  So `_apt` gets primary group `aid_inet`. If `apt-get update` still fails,
  `setup.sh` writes `APT::Sandbox::User "root";` and retries.
- iptables: the chroot shares Android's netns, so its rules are the phone's. Android
  (netd) uses legacy xtables; Ubuntu defaults to `iptables-nft`, which can't see them
  (and kernel 4.9 has no nf_tables). `setup.sh` installs
  `/usr/local/sbin/uburoot-iptables-select` plus an apt `DPkg::Post-Invoke` hook
  (`80uburoot-iptables`): when `/proc/net/ip{,6}_tables_names` is non-empty and the
  alternative is still in auto mode, it switches to `*-legacy`. Not hardcoded, so a
  future Android on nft keeps nft; a manual choice is never overridden. Ubuntu's
  iptables warns `Can't find library for match 'quota2'` (Android-only xt_quota2
  in netd's chains); listing still works.
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
- **Binder tools must not get the app's pty.** `cmd`/`pm`/`am`/`settings`/`dumpsys`
  pass their fds to system_server, and SELinux denies it the app's terminal
  (`avc: denied { read write } scontext=u:r:system_server
  tcontext=u:object_r:untrusted_app_all_devpts`), so in the app they failed with
  `Failed transaction (2147483646)` while working over adb. `android-run --pipes`
  gives them `/dev/null` as stdin and pipes stdout/stderr through `/system/bin/cat`
  (mksh `set -o pipefail`, so the exit status survives). `android <cmd>` uses pipes
  for the wrapped binder tools and the tty for everything else. `android.env` is
  stamped `# wrappers=N` (`WRAP_VERSION`); `--if-needed` regenerates wrappers when it
  changes. As uid 9000, `settings`/`dumpsys`/`am get-current-user` are refused by
  Android permissions (`INTERACT_ACROSS_USERS`, `DUMP`): expected, use `sudo`.

## Testing

- `tests/run-all.sh`: everything below. Now: shellcheck 38 files, guard 17/17, Docker
  303/303 (Phase 1 result: 17 files, 13/13, 70/70). The CI runner's older shellcheck
  (0.9.0) must pass too: no `A && B || C`, `head -n 1 file` instead of `cat | head`,
  and `disable=SC2317,SC2329` together.
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
  `setup.sh --user <name> --nopasswd` to have run already (the app installer counts; the user comes from `TEST_USER`, else `DEFAULT_USER`, else `tester`). It covers real mounts and
  propagation, paranoid network, bionic wrappers, the user's sudo/network/`/sdcard`
  access, a sabotaged reset and umount back to baseline. `--reset` also runs the real
  reset with a live session. Not part of `run-all.sh`.
- `tests/device/session-test.sh`: runs **inside an app terminal session** as the
  user (usage in its header; the rootfs's `/tmp` is `$ROOTFS/tmp` on the host). It
  covers what only a real session has: tty and job control, sudo, DNS/apt/HTTPS/ICMP,
  `/sdcard` group media_rw, `/system`/`/vendor`/`/apex` read-only even for root,
  binder tools with the pty as stdin, `dpkg --audit`/`apt-get check`/`dpkg -V`
  (ignoring `path-exclude` files and conffiles). Result on the SM-G9600: 34/34.
- Host integrity method (manual): snapshot of the init namespace's mounts outside the
  rootfs (`/proc/1/mountinfo` with propagation), SELinux enforce, sha256 of
  `/system/bin/sh`, `linker64`, both `build.prop`, `framework-res.apk`, and sentinel
  files in `/data` and `/data/media/0`. Taken before entering, with a session open,
  and after `exit` + `umount.sh`: the outside part never changed and after umount
  it was identical to the baseline (112 mounts). Don't name a sentinel
  `/data/local/tmp/uburoot-sentinel`: `checks.sh` owns that path and deletes it.
- `tests/device/advanced-test.sh <user>`: runs inside the chroot as root
  (`enter.sh root 'sh /tmp/uburoot-advanced-test.sh ana'`) and checks a full dev
  setup: network state, IPv4/IPv6, DNS, traceroute, Wi-Fi (`iw`, `cmd wifi`), nmap
  (SYN/UDP/connect/ARP), tcpdump, scapy, ports, read-only iptables, gcc/g++/cmake/
  gdb/strace, venv+pip, multiprocessing (fork/spawn/forkserver), node+npm, Go, Rust,
  Java, git, sqlite3, tmux and sshd on 8022 with key login. It needs `build-essential
  cmake git gdb python3-pip python3-venv python3-dev nodejs npm golang-go
  default-jdk-headless rustc cargo openssh-server sqlite3 tmux iproute2 iw nmap
  tcpdump netcat-openbsd dnsutils traceroute iptables python3-scapy strace curl`.
  Result on the SM-G9600: 54/54 (after the fixes below). Findings (2026-11-15):
  - (Fixed in `setup.sh`, see "Ubuntu side decisions") The user's
    `aid_net_raw`/`aid_net_admin` groups acted as **CAP_NET_RAW and
    CAP_NET_ADMIN without sudo** (Android paranoid-network kernel): `ana` ran
    `tcpdump -i wlan0` (sniffs the whole phone's traffic), `nmap --privileged -sS`
    and `ip link add` (host netns). `iw scan` (nl80211) was still refused. Ping does
    not need them: `net.ipv4.ping_group_range` is `0 2147483647`.
  - (Fixed: legacy selector) The kernel (4.9) has no nf_tables (`nf_tables_newtable` absent from kallsyms),
    but Ubuntu's `iptables` alternative is `iptables-nft`; only `iptables-legacy`
    sees Android's tables. Any rule applies to the whole phone (shared netns).
  - Android keeps default routes in per-network tables (`ip route` main table has
    only the subnet). scapy 2.7 imports all tables, picks table 1003's
    `default dev dummy0` and routes with source `0.0.0.0`; the script's recipe fixes
    scapy's own table.
  - `/proc` hides other users' processes from `ana` (sees 4); root sees all.
  - No systemd (PID 1 is Android init): start daemons by hand (`/usr/sbin/sshd -p 8022`
    after `mkdir -p /run/sshd; ssh-keygen -A`). policy-rc.d blocks auto-starts.
  - `fs.inotify.max_user_watches` is 8192 (global kernel sysctl shared with Android;
    too low for VS Code/webpack; now raised by `mount.sh`). nofile: soft 1024, hard 32768.
  - Wi-Fi driver modes: IBSS, managed, AP, P2P; **no monitor mode** on this phone.
  - multiprocessing fails only when the cwd is unreadable for the user (spawned
    workers `chdir()` to it), e.g. `runuser` from `/root`.
- Session process lifetime (observed): `am force-stop` of the app kills the whole
  chain (`su`, `setsid`, `bash`), since they stay in the app's process cgroup; the
  mounts stay. Earlier, an app killed during reinstall left 5 chroot processes
  that `umount.sh --kill` had to stop. The foreground service keeps the process alive;
  a reinstall or force-stop still ends every session (the mounts stay).
- Ubuntu 26.04's rust-coreutils (`env` etc.) **panics without `/proc`** (rustix reads
  `/proc/self/auxv`). Never `chroot` into the rootfs before `mount.sh`.
- Paths not covered by the suite: the toybox-only fallback (no root manager ships without
  busybox) and plain util-linux.
- Tested only on Magisk 31.1 / Android 12 so far. KernelSU, APatch and Android 13+
  have not been run on a device yet.

## CI and releases

`.github/workflows/ci.yml` (action majors checked against their latest releases on
2026-11-15: checkout v7, setup-java v6, gradle/actions v6, upload-artifact v7,
download-artifact v8):
- `scripts`: `tests/shellcheck.sh`, `tests/test_reset_guard.sh`, `tests/docker/run.sh`
  (privileged Docker works on GitHub's ubuntu runners).
- `build`: JDK 21, `spotlessCheck` (ktlint), `assembleDebug assembleRelease testDebugUnitTest`, then
  `tools/ci-package.sh dist` → `uburoot-<ver>[-g<sha>]-{debug,release}.apk`, the same
  bytes as `-module.zip`, and `SHA256SUMS`. The script fails unless each APK passes
  `apksigner verify` and carries `module.prop` (version filled in), `customize.sh`,
  `service.sh` and `META-INF/com/google/android/{update-binary,updater-script}`.
- `release` (tags `v*`): GitHub release with the signed release APK + module zip.
- Release signing only from the environment (`UBUROOT_KEYSTORE`,
  `UBUROOT_KEYSTORE_PASSWORD`, `UBUROOT_KEY_ALIAS`, `UBUROOT_KEY_PASSWORD`; in CI from
  secrets, the keystore as `UBUROOT_KEYSTORE_BASE64`). Without them the release APK
  is unsigned and not published; the debug APK uses the runner's throwaway key.
- Tag builds also publish version-less `uburoot.apk` / `uburoot-module.zip` (README links
  use `releases/latest/download/<name>`); the release's `SHA256SUMS` lists only the
  published files.
- Repo docs: README (screenshots come from
  `fastlane/metadata/android/en-US/images/phoneScreenshots/`, shared with F-Droid),
  LICENSE (GPL-3.0-or-later since 0.3.0, the verbatim gnu.org text, SHA-256 `3972dc97…`;
  0.1.0–0.2.1 were Apache-2.0, whose text is kept in `LICENSES/Apache-2.0.txt` for the
  third-party libraries), NOTICE, CONTRIBUTING, CODE_OF_CONDUCT (Contributor
  Covenant 2.1, official text; contact = GitHub private reporting, which is enabled),
  SECURITY, CHANGELOG (Keep a Changelog), issue forms, PR template, `.editorconfig`.
- v0.2.0 (2026-11-16): CI's signed release APK of `1d634d2` was tested on the S9 before
  tagging (preflight, terminal, every `uburoot-*` command, share, Settings), and so was
  the published file. The tag build and the main build had identical zip entries,
  headers and order; only AGP's dependency-metadata block (`0x504b4453`, encrypted with
  a Google key) differed. It is now off (`dependenciesInfo`), so builds of one commit
  should match. F-Droid also flags that block.
- v0.2.1 (2026-11-16, the Ctrl+Shift+C fix): CI's release APK of `bd21dc8` was tested on
  the S9 (terminal, `uburoot-toast`, Ctrl+Shift+C) and is **byte-identical** to the
  published one (same SHA-256), so the reproducibility fix works.
- v0.3.0 (2026-11-16, GPL relicense + Milestone 2 Phase 1): CI's release APK of `bc755cf`
  was tested on the S9 over adb (the phone has a PIN, so no UI): preflight to terminal,
  `uburoot-toast`/`uburoot-notify` through the app, doctor 0 failed / 0 warnings, host
  back to 1068 mounts after `umount.sh --kill`. The published APK is byte-identical
  (`a73ead7e…`), and `tools/fdroid-check.sh 4` built it from source identically.
- Magisk keeps an uninstalled app's root policy. After uninstalling the debug build,
  uid 10123 still had `policy=2`, and a future app with that uid would get root
  silently. Delete stale rows (`magisk --sqlite "DELETE FROM policies WHERE uid=N"`)
  after switching between debug and release builds.
- The R8 release build (1.3 MB vs 11.4 MB debug) was installed on the device:
  preflight, deploy, terminal and the session suite (35/35) passed.

## F-Droid (checked 2026-11-16)

- Recipe for fdroiddata: `tools/fdroid/com.reinanbr.uburoot.yml`. Categories are
  Development and System. `Binaries:` points at the GitHub release APK,
  `AllowedAPKSigningKeys` is the release key, and checkupdates follows tags
  `^v\d+\.\d+\.\d+$`. The text comes from `fastlane/metadata` in this repo.
- `tools/fdroid-check.sh [VERSIONCODE]` runs fdroidserver from PyPI in a temp venv:
  `lint`, `rewritemeta` (must not change the file), then `fdroid build` from the tag,
  compared with the published APK (set `JAVA_HOME` to JDK 21: the default `java-25`
  here is a JRE and Gradle fails). 0.2.0 and 0.2.1 passed: lint clean, scanner clean (it only
  removes `gradle-wrapper.jar`), "compared built binary to supplied reference binary
  successfully". So F-Droid can ship our own signed APK.
- Policy (current English Inclusion Policy): JitPack.io is a listed trusted Maven repo
  for FLOSS binaries (Termux's libs and libsu are Apache-2.0). Termux itself is on
  F-Droid with no AntiFeatures. Downloading executables needs explicit user consent:
  ours is the install form's button.
- The buildserver is Debian trixie, so the recipe installs `openjdk-21-jdk-headless`
  with `sudo:`. Gradle 9.9.1 is in F-Droid's gradle-transparency-log with the same
  SHA-256 as our wrapper.
- fdroidserver 2.4.5 local-mode quirks (worked around in the script): the PyPI
  package has no `gradlew-fdroid` (`gradle:` in config.yml points at the wrapper's
  distribution); it reads `SOURCE_DATE_EPOCH` before cloning (pre-clone into
  `build/<appid>`); categories.yml needs its icons (stripped).
- For each release: keep the asset name `uburoot-<ver>-release.apk`. After tagging,
  update the recipe in fdroiddata (new `Builds` entry, `CurrentVersion*`; checkupdates
  can do it) and run the check script.
- The merge request to gitlab.com/fdroid/fdroiddata needs the owner's GitLab account
  (fork, add the recipe, use the MR template). It is not opened from here.

## Work rules

- Code, comments and docs in English; UI strings in English (`values/`) with the pt-BR
  translation in `values-pt-rBR/`.
- Kotlin style: ktlint 1.8.0 through Spotless 8.11.0 (`./gradlew spotlessApply`;
  CI runs `spotlessCheck`). Rules in `.editorconfig` (android_studio style, 120 columns,
  trailing commas kept: the two `ij_kotlin_allow_trailing_comma*` keys are also passed
  as `editorConfigOverride` in `build.gradle.kts`, because with them only in
  `.editorconfig` the commas were stripped).
- Don't invent flags/APIs/versions: verify in the source first and note it here.
- Minimal deps: no Hilt/Room/Retrofit. Terminal: `com.github.termux.termux-app:terminal-view`
  + `terminal-emulator` (JitPack, check the latest stable tag). Root: `com.github.topjohnwu.libsu:core`.
- minSdk 26, latest stable targetSdk, `arm64-v8a` only, Gradle Kotlin DSL + version catalog.
- Small commits per phase.
