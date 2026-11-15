# Project: UbuRoot — rooted Ubuntu ARM64 chroot terminal, deeply integrated with Android

## Goal
An open-source native Android app (Kotlin) that installs and runs a full Ubuntu arm64
system in a chroot using root (Magisk, KernelSU or APatch), with a real PTY terminal and
deep Android integration: Ubuntu can call Android binaries (am, pm, cmd, settings),
access /sdcard, /data and /system, post notifications, and open files/URLs in Android.
Target device: de-Googled Android (LineageOS/AOSP, no GApps). Forbidden: Firebase,
Google Play Services, Play Core, or any proprietary/Google dependency. The app must be
eligible for F-Droid inclusion.

Everything in English: code, comments, commit messages, docs, UI strings, scripts.

## Stack (decided — do not change)
- Kotlin, Jetpack Compose for setup/settings screens; terminal via Termux's `TerminalView`
  embedded with `AndroidView`.
- Terminal: `com.github.termux.termux-app:terminal-view` and `terminal-emulator` via JitPack
  (Apache 2.0). Check the latest stable tag before pinning.
- Root: `com.github.topjohnwu.libsu:core` (persistent root shell).
- minSdk 26, latest stable targetSdk, arm64-v8a only.
- Package: com.reinanbr.uburoot. Gradle Kotlin DSL + version catalog.
- Minimal dependencies. No Hilt/Room/Retrofit — DownloadManager or HttpURLConnection is
  enough to fetch the rootfs.

## Architecture
System logic lives in SHELL SCRIPTS (assets), not Kotlin. The app copies the scripts,
runs them via su, and displays the terminal. Everything must be testable through
`adb shell su` without the app.

Rootfs at `/data/local/uburoot/rootfs`; scripts at `/data/local/uburoot/bin/`:
- `common.sh` — detects busybox (/data/adb/magisk/busybox, /data/adb/ksu/bin/busybox,
  /data/adb/ap/bin/busybox) with toybox fallback; shared variables (ROOTFS, etc.).
- `mount.sh` — idempotent (check /proc/mounts before every mount):
  - /proc (proc), /sys (sysfs), /dev (bind), /dev/pts (bind), /dev/shm (tmpfs)
  - /sdcard → rootfs/sdcard (bind) [toggle]
  - Android integration [toggle]: bind /system, /vendor, /product, /apex, /linkerconfig,
    /data at the SAME paths inside the rootfs so Android binaries (bionic, linker64) run
    inside the chroot.
- `umount.sh` — unmounts everything under ROOTFS in reverse depth order by parsing
  /proc/mounts; falls back to `umount -l`. Exits non-zero if any mount remains.
- `enter.sh [user] [cmd]` — calls mount.sh, then
  `exec chroot $ROOTFS /usr/bin/env -i HOME=... TERM=xterm-256color LANG=C.UTF-8 PATH=... /bin/bash -l`
  (or `su - user` inside the chroot).
- `android-env` — on first enter, captures the Android environment (BOOTCLASSPATH,
  ANDROID_ROOT, ANDROID_DATA, DEX2OATBOOTCLASSPATH, SYSTEMSERVERCLASSPATH, etc.) into
  rootfs/etc/android.env. Wrappers in /usr/local/bin (`am`, `pm`, `cmd`, `settings`,
  `dumpsys`, `getprop`) source it and exec /system/bin/<x>.

Mount namespace: mounts must be visible across sessions. Detect the root implementation
and use the matching mount-master flag (Magisk: `su --mount-master`; for KernelSU and
APatch check their current docs/source for the equivalent — do not guess). Document each
implementation's behavior in CLAUDE.md and docs/ROOT_IMPLEMENTATIONS.md.

## CRITICAL SAFETY RULE
Never run `rm -rf` on the rootfs (reset/uninstall) while anything is mounted under it —
with /data and /sdcard bind-mounted, that WIPES THE PHONE'S REAL DATA.
Mandatory removal flow: umount.sh → verify via /proc/mounts that nothing under ROOTFS is
still mounted → abort with an error if anything is → only then `rm -rf`. Cover this with
an automated test using dummy directories that proves the abort path works.

## Installer (first run)
1. Check root (`Shell.isAppGrantedRoot()`), arm64 ABI, root implementation, free space
   (require ≥ 3 GB).
2. Download Ubuntu Base arm64 for the latest LTS from cdimage.ubuntu.com/ubuntu-base/releases/
   (discover the current URL; do not hardcode an old release). Verify SHA256 against the
   official SHA256SUMS. Progress bar, resumable.
3. Extract as root: `tar -xpf --numeric-owner` using busybox.
4. Post-install (`setup.sh`):
   - /etc/resolv.conf (1.1.1.1, 9.9.9.9; configurable), /etc/hosts, hostname.
   - Android networking (CONFIG_ANDROID_PARANOID_NETWORK): create groups aid_inet(3003),
     aid_net_raw(3004), aid_net_admin(3005); add root, the created user and `_apt` to
     them (or set `APT::Sandbox::User "root";`). Ensure `apt update` works.
   - sources.list pointing to ports.ubuntu.com/ubuntu-ports.
   - C.UTF-8 locale, install sudo, create default user (name chosen in setup) with
     optional passwordless sudo.
5. Open the terminal.

## Android ↔ Ubuntu integration
- Exported BroadcastReceiver protected by a signature permission, action
  "com.reinanbr.uburoot.CMD"; Ubuntu-side commands use `am broadcast`:
  - `uburoot-notify "title" "text"` → notification
  - `uburoot-open <file|url>` → VIEW intent (resolve /sdcard paths, use FileProvider);
    also installed as `xdg-open`
  - `uburoot-clip [text]` → copy to clipboard (read stdin when no argument)
  - `uburoot-toast`, `uburoot-vibrate <ms>`
- "Open in UbuRoot" share target that opens a session in the shared file's directory.

## Terminal / UI
- Multiple sessions as tabs; each session = TerminalSession running
  `su <mount-master-flag> -c /data/local/uburoot/bin/enter.sh <user>`.
- Foreground service keeps sessions alive; notification shows session count with actions
  "New session", "Stop all" (close sessions + umount.sh) and a wake-lock toggle.
- Extra keys row: ESC, CTRL, ALT, TAB, arrows, HOME/END, PgUp/PgDn, | ~ / -.
- Pinch-to-zoom font size, themes (light/dark/Solarized), copy/paste, clickable links,
  hardware keyboard support (Ctrl+Shift+C/V, Ctrl+Shift+T new tab).
- Settings: default user, startup command, mount toggles (sdcard, Android integration),
  DNS, "Repair mounts" button, "Reset Ubuntu" button (enforces the critical rule and
  requires typing "DELETE" to confirm).
- All UI strings in res/values/strings.xml (English) so the community can add translations.

## Extra phase (only after everything else works): autostart on boot
The app generates a Magisk/KernelSU/APatch-compatible module zip whose `service.sh` runs
mount.sh at boot and executes /etc/uburoot-boot.d/* inside the chroot (e.g. sshd).

## Open-source deliverables
- LICENSE: Apache-2.0 (compatible with Termux terminal libs and libsu). Add NOTICE
  crediting termux terminal-emulator/terminal-view and libsu with their licenses.
- README.md: what it is, screenshots placeholder, requirements (root, arm64), install,
  build from source, how the chroot/mounts work, security warning about bind mounts,
  FAQ, trademark disclaimer ("Ubuntu is a trademark of Canonical Ltd. This project is not
  affiliated with or endorsed by Canonical." — no Ubuntu logo in the app or icon).
- CONTRIBUTING.md, CODE_OF_CONDUCT.md (Contributor Covenant), SECURITY.md (how to report
  vulnerabilities), CHANGELOG.md (Keep a Changelog format).
- .github/: issue templates (bug report incl. device/ROM/root implementation/Android
  version fields, feature request), PR template.
- GitHub Actions CI: build debug APK, run unit tests, shellcheck on all scripts, ktlint
  (or detekt). Release workflow building a signed release APK from tags (signing via repo
  secrets; never commit keystores).
- F-Droid readiness: fastlane/metadata/android/en-US/ (title, short/full description,
  changelogs, screenshots folder), no proprietary deps, no network calls except Ubuntu
  mirrors and user-configured ones, no analytics/tracking. Document anti-features if any
  (e.g. "NonFreeNet" does not apply; root required).
- .gitignore, .editorconfig.

## Execution plan (follow phases; stop at the end of each and show me the result)
1. Shell scripts + shellcheck + critical-rule test with dummy directories. Scripts must
   work via `adb shell su -c` without the app.
2. App MVP: root check, installer, one working terminal session.
3. Multiple sessions, foreground service, extra keys, settings.
4. Android integration (wrappers, receiver, uburoot-* commands).
5. Open-source deliverables + CI.
6. Boot module.

## Working rules
- Before coding: create CLAUDE.md with architecture, paths, decisions and
  Magisk/KSU/APatch differences. Keep it updated.
- If a device is available via `adb devices`, test on it every phase (install APK, run
  scripts, collect logcat). If not, state clearly what was left untested.
- Never invent flags/APIs: when unsure (su flags, library versions, Ubuntu URLs), verify
  at the source first.
- Small commits per phase using Conventional Commits (feat:, fix:, docs:, ci:...).
