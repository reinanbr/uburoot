# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The APK no longer carries AGP's encrypted dependency-metadata block, so two builds of
  the same commit match (and F-Droid doesn't flag it).

## [0.2.0] - 2026-11-16

### Added

- Start at boot: with the root module installed and *Start Ubuntu at boot* on, the module
  mounts Ubuntu at boot and runs `/etc/uburoot-boot.d/*` inside it as root (`boot.sh`, log
  in `/data/local/uburoot/boot.log`). Settings shows the module's state and can run the
  boot scripts on demand.
- Android bridge: `uburoot-notify`, `uburoot-toast`, `uburoot-vibrate`, `uburoot-clip` and
  `uburoot-open` (also installed as `xdg-open`) inside Ubuntu. They reach the app through a
  receiver guarded by a signature permission.
- *Open in UbuRoot* share target: a new session in the shared file's folder (files from
  outside the shared storage are copied to `~/Shared`).
- Several terminal sessions in tabs, kept alive by a foreground service. Its notification
  shows the number of sessions and has *New session*, *Stop all* and a wake-lock toggle.
- Extra keys (ESC, CTRL, ALT, TAB, arrows, HOME/END, PgUp/PgDn, `/ - | ~`), themes (dark,
  light, Solarized dark/light), clickable links, remembered font size, Ctrl+Shift+C/V/T.
- Settings screen: default user, startup command, mount toggles, DNS, *Repair mounts*
  and *Reset Ubuntu* (type `DELETE` to confirm).
- `setup.sh --dns-only` rewrites only `/etc/resolv.conf`; `hangup.sh` hangs up one
  session's processes when its tab is closed.
- README, LICENSE (Apache-2.0), NOTICE, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY and this
  changelog.
- Issue forms (bug report, feature request), a pull request template and `.editorconfig`.
- F-Droid metadata in `fastlane/metadata/android/en-US/`, with screenshots (also shown in
  the README).
- Releases also publish `uburoot.apk` and `uburoot-module.zip`, so
  `releases/latest/download/...` links stay stable across versions.

### Fixed

- Unmounting took about 2 minutes on phones with Magisk's Zygisk enabled: its magic
  mount puts about 1000 per-file mounts under `/system/lib*`, and they were unmounted one
  at a time. Each Android partition tree is now detached at once; it takes 1 s.

- Closing a session left its shell running inside Ubuntu: util-linux `su`, the session
  leader, blocks SIGHUP. `hangup.sh` now signals the session's processes.
- *Stop all* took about 40 s on the test phone; now about 5 s. Finding the chroot's
  processes forked once per process, which is slow from the app's background cgroup, and
  `umount.sh` made every mount private one by one although the operation is recursive.
  Interactive shells, which ignore SIGTERM, now also get SIGHUP.

## [0.1.0] - 2026-11-15

First release.

### Added

- Root check for Magisk, KernelSU and APatch. Every command runs in Android's global mount
  namespace (`su --mount-master`), and the app refuses to continue if it doesn't.
- Installer: finds the newest Ubuntu LTS (Ubuntu Base arm64), downloads it with resume,
  verifies it against `SHA256SUMS`, extracts it and sets it up (DNS, hosts, apt sources,
  `sudo`, user). It resumes after an interrupted run.
- Terminal: a real PTY (Termux terminal view) with job control, as root or as your user.
- Android integration: `/sdcard`, `/data` and the system partitions inside Ubuntu,
  wrappers for `am`, `pm`, `cmd`, `settings`, `dumpsys`, `getprop`, `wm`, `input`,
  `content`, `svc`, `appops`, and `android <command>` for any other Android binary.
- One file, three install methods: the APK is also a Magisk/KernelSU/APatch module and a
  Magisk recovery zip.
- `INOTIFY_MAX_WATCHES` (default 524288): raises the inotify limit for IDEs and file
  watchers. The limit is only ever raised.
- CI: shellcheck, the reset safety guard, a real-mount Docker suite, build and unit tests,
  signed releases from tags.

### Security

- The default user gets uid 9000, never 1000 (Android's `system` uid) and never ≥ 10000
  (app uids, whose network netd blocks in restricted modes).
- `reset.sh` is the only way to delete the rootfs. It unmounts first and aborts if
  anything is still mounted, so the phone's `/data` and `/sdcard` can't be deleted through
  the bind mounts.
- Mounts inside the rootfs are private/slave, so unmounting Ubuntu's copy of `/apex` or
  `/system` never affects Android's.
- Only root is in `aid_net_raw`/`aid_net_admin`. On Android kernels those groups grant
  raw sockets and network administration, so the user and `_apt` get only `aid_inet`.

### Fixed

- Android binder commands (`pm`, `cmd`, `am`, ...) failed in the app terminal because
  system_server may not use the app's pty. They now get pipes.
- `iptables` inside Ubuntu now uses the backend that holds Android's rules (legacy on
  current Android) instead of `iptables-nft`.

[Unreleased]: https://github.com/reinanbr/uburoot/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/reinanbr/uburoot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/reinanbr/uburoot/releases/tag/v0.1.0
