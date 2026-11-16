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
| `install.sh <tar.gz> [sha256]` | checks arch/space, verifies SHA256, extracts with busybox tar into `rootfs.partial`, then renames it |
| `setup.sh [--user N] ...` | post-install: DNS, hosts, hostname, AID groups, apt sources, locale, sudo, user. `--dns-only` rewrites just `resolv.conf` (Settings → DNS) |
| `hangup.sh PID` | SIGHUP+SIGCONT to the chroot processes whose controlling tty is PID's stdin (the app passes a session's `su` client when its tab closes) |
| `reset.sh --yes` | the only deletion path: `umount.sh --kill`, then `ubu_safe_rm` |
| `boot.sh [--now\|--status]` | run by the module's `service.sh`. Without `BOOT_START=1` it does nothing. Waits for shared storage to decrypt (if `MOUNT_SDCARD`, up to 6 h), runs `mount.sh`, then each executable `/etc/uburoot-boot.d/NAME` (`[A-Za-z0-9_-]+`, no symlinks) through `enter.sh root`. A script still running after `BOOT_SCRIPT_TIMEOUT` (60 s) is left running. `--now` skips the wait and `BOOT_START`; `--status` prints `module=enabled\|disabled\|removing\|pending\|missing` (`/data/adb/modules{,_update}/uburoot`, the same for all three managers) and `boot_start=` |
| `rootinfo.sh` | prints `impl=`, `version=`, `mount_master_flag=`, `busybox=` (used by the app) |
| `chroot-send.sh` | runs **inside** the chroot as root (installed as `uburoot-send`): `notify TITLE [TEXT]`, `toast TEXT`, `vibrate [MS]`, `clip [TEXT]` (stdin), `open FILE\|URL` → `am broadcast` to the app, prints the app's error |
| `chroot-cmd.sh` | installed as `uburoot-cmd`; dispatches on `$0` (`uburoot-notify`... / `xdg-open`) to `uburoot-send`, through `sudo -n` unless root |
| `bridge.sh` | app side: `take ID DEST` (outbox file → the app's cache file), `import SRC NAME` (into the default user's `~/Shared`, as that user inside the chroot), `cwd DIR` (exit 0 if the default user can enter DIR) |

Config keys (`uburoot.conf`): `MOUNT_SDCARD`, `ANDROID_INTEGRATION`, `DNS_SERVERS`,
`DEFAULT_USER`, `INIT_COMMAND`, `UBU_HOSTNAME`, `SDCARD_SOURCE` (optional override),
`INOTIFY_MAX_WATCHES` (default 524288; `mount.sh` raises
`fs.inotify.max_user_watches` to it, never lowers it; 0 = leave alone), `BOOT_START`
(0/1, Settings → Start at boot), `BOOT_SCRIPT_TIMEOUT` (default 60 s, hand edit only).

Test-only env overrides (never set by the app): `UBU_MODULES` (default `/data/adb`), `UBU_BASE`, `ROOTFS`, `UBU_MOUNTS_FILE`,
`UBU_INOTIFY_FILE` (Docker: the container's `/proc/sys` is the host's),
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
| `ui/SettingsActivity` + `settings/SettingsViewModel` | `uburoot.conf` editor, *Repair mounts* (`umount.sh --kill && mount.sh`), *Reset Ubuntu* (`reset.sh --yes`, exit 3 = refused) |

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

- `tests/run-all.sh`: everything below. Now: shellcheck 28 files, guard 13/13, Docker
  138/138 (Phase 1 result: 17 files, 13/13, 70/70).
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
  LICENSE (Apache-2.0, official text), NOTICE, CONTRIBUTING, CODE_OF_CONDUCT (Contributor
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
