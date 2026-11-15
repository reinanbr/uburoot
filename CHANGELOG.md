# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- README, LICENSE (Apache-2.0), NOTICE, CONTRIBUTING, CODE_OF_CONDUCT, SECURITY and this
  changelog.
- Issue forms (bug report, feature request), a pull request template and `.editorconfig`.
- F-Droid metadata in `fastlane/metadata/android/en-US/`, with screenshots (also shown in
  the README).
- Releases also publish `uburoot.apk` and `uburoot-module.zip`, so
  `releases/latest/download/...` links stay stable across versions.

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

[Unreleased]: https://github.com/reinanbr/uburoot/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/reinanbr/uburoot/releases/tag/v0.1.0
