# UbuRoot

[![CI](https://github.com/reinanbr/uburoot/actions/workflows/ci.yml/badge.svg)](https://github.com/reinanbr/uburoot/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/reinanbr/uburoot)](https://github.com/reinanbr/uburoot/releases/latest)
[![License](https://img.shields.io/github/license/reinanbr/uburoot)](LICENSE)

**A full Ubuntu (arm64) on your rooted Android phone, with a real terminal.**

UbuRoot installs the official Ubuntu Base rootfs and runs it in a `chroot` using the
root you already have (Magisk, KernelSU or APatch). This is not proot emulation: programs
run natively on the phone's kernel at full speed, with real `sudo`, `apt`, compilers,
servers and network tools. Your shared storage and Android's own commands (`pm`, `am`,
`cmd`, `settings`...) are available inside Ubuntu.

It targets AOSP/LineageOS-style ROMs and has **no Google dependencies**: no Play
Services, Firebase or analytics. The only network calls are the Ubuntu servers
(`cdimage.ubuntu.com`, `ports.ubuntu.com`) and whatever you run yourself.

> **Status: early (v0.2.0).** Everything planned works: installer, terminal tabs, settings,
> the Android commands and start at boot. It has been tested on one device so far (see [Tested on](#tested-on)). Expect rough edges, and read
> the [safety warning](#safety-warning) before you use it.

## Download

| | File | |
|---|---|---|
| **App (APK)** | [uburoot.apk](https://github.com/reinanbr/uburoot/releases/latest/download/uburoot.apk) | install it like any app |
| **Root module (zip)** | [uburoot-module.zip](https://github.com/reinanbr/uburoot/releases/latest/download/uburoot-module.zip) | Magisk / KernelSU / APatch → Modules → *Install from storage* |
| Checksums | [SHA256SUMS](https://github.com/reinanbr/uburoot/releases/latest/download/SHA256SUMS) | |

Both links always point to the latest release. They are **the same file** under two
names, so install either one. All versions and release notes are on the
[releases page](https://github.com/reinanbr/uburoot/releases). See
[Install](#install) for the details.

## Screenshots

<p>
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/1_setup.png" width="240" alt="Setup: root manager, busybox, architecture, free space and namespace, plus the user form">
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/2_installing.png" width="240" alt="Setting up Ubuntu with the live log">
</p>
<p>
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/3_terminal.png" width="490" alt="Terminal: Ubuntu 26.04.1 LTS on the phone, with gcc, Python, Node, Go, Rust, Java and git">
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/4_android.png" width="490" alt="Android commands inside Ubuntu: getprop, pm, cmd wifi, settings; /sdcard; /system is read-only">
</p>

*Setup, installing, the terminal with a development toolchain, and Android's own commands
from Ubuntu. The UI is in English and follows the system language; these screenshots
come from a phone set to Brazilian Portuguese.*

## Features

Available now:

- **Root check**: detects Magisk, KernelSU or APatch and makes sure commands run in
  Android's global mount namespace, so every session sees the same mounts.
- **Installer**: finds the newest Ubuntu LTS automatically (currently 26.04.1), downloads
  it (resumable), checks it against Ubuntu's `SHA256SUMS`, then sets up DNS, apt
  sources, `sudo` and your user.
- **Terminal**: a real PTY with job control, 256 colors and UTF-8 (Termux's terminal
  view).
- **Android integration**: `/sdcard`, `/data` and the system partitions are available
  inside Ubuntu. `am`, `pm`, `cmd`, `settings`, `dumpsys`, `getprop`, `wm`, `input`,
  `content`, `svc` and `appops` run Android's own binaries; `android <command>` runs any
  other one.
- **One file, three install methods**: the APK is also a root-manager module and a
  Magisk recovery zip (see [Install](#install)).
- **Sessions in tabs**: `+` opens a session as your user, the menu also opens a root
  session. A foreground service keeps them running in the background; its notification
  shows how many are running and offers *New session*, *Stop all* (closes everything and
  releases every mount) and an optional wake lock for long jobs with the screen off.
- **Extra keys**: ESC, CTRL, ALT, TAB, arrows, HOME/END, PgUp/PgDn, `/ - | ~` (CTRL and
  ALT stay pressed for the next key; hold a key to repeat it).
- **Terminal comforts**: pinch to zoom (remembered), themes (dark, light, Solarized dark
  and light), copy and paste, tap a link to open it, and hardware keyboard shortcuts:
  Ctrl+Shift+C / V to copy / paste, Ctrl+Shift+T for a new tab.
- **Settings**: default user, startup command, `/sdcard` and Android-integration mounts,
  DNS servers, *Repair mounts*, and *Reset Ubuntu*, which asks you to type a
  confirmation word and never deletes anything while something is still mounted.

- **Talk to Android from Ubuntu**:

  | Command | Does |
  |---------|------|
  | `uburoot-notify TITLE [TEXT]` | shows an Android notification (e.g. `make; uburoot-notify "build done"`) |
  | `uburoot-toast TEXT` | shows a short message |
  | `uburoot-vibrate [MS]` | vibrates (default 300 ms) |
  | `uburoot-clip [TEXT]` | copies TEXT, or its input (`git log -1 \| uburoot-clip`), to Android's clipboard |
  | `uburoot-open FILE\|URL`, `xdg-open` | opens a file or a link in an Android app |

  They work in the background too. Files are read with your own permissions, so you can
  only open what you can read.
- **Open in UbuRoot**: share a file from any app to open a session in its folder. Files
  outside the phone's shared storage are copied to `~/Shared` first.

- **Start at boot** (needs the module, see [Install](#install)): Settings → *Start Ubuntu
  at boot* mounts Ubuntu when the phone starts and runs, as root, every executable script
  in `/etc/uburoot-boot.d/` in name order. Names may only use letters, digits, `_` and
  `-`, like `run-parts`. For example, `/etc/uburoot-boot.d/10-sshd`:

  ```sh
  #!/bin/sh
  mkdir -p /run/sshd
  exec /usr/sbin/sshd -p 8022   # sshd forks into the background by itself
  ```

  Each script gets 60 seconds (`BOOT_SCRIPT_TIMEOUT` in `uburoot.conf`). One still
  running after that is left running and the next one starts. When `/sdcard` is mounted,
  the start waits for the first unlock, because shared storage stays encrypted until
  then. The log goes to `/data/local/uburoot/boot.log`. *Run boot scripts now* in
  Settings does the same without a reboot, e.g. after *Stop all*, which also stops them.

## Requirements

- An **arm64** (`arm64-v8a`) phone with **Android 8.0+**.
- **Root** with Magisk, KernelSU or APatch. Their busybox is used for the mounts.
- About **3 GB free** in `/data` for the install. It grows with what you install, and a
  full development setup takes a few GB more.
- Internet access to download Ubuntu.

### Tested on

| Device | ROM | Root | Result |
|--------|-----|------|--------|
| Samsung Galaxy S9 (SM-G9600) | LineageOS 19.1 (Android 12) | Magisk 31.1 | all device suites pass |

KernelSU, APatch and Android 13+ are supported in the code but **not tested on a device
yet**. How the three root managers differ (and what UbuRoot does about it) is in
[docs/ROOT_IMPLEMENTATIONS.md](docs/ROOT_IMPLEMENTATIONS.md). Reports are very welcome. Please include the device, ROM, Android version and root
manager (with version).

## Install

Get the files from [Download](#download) (or any version from
[Releases](https://github.com/reinanbr/uburoot/releases)). The `.apk` and the
`-module.zip` are **the same file**, published twice because some root managers' file
pickers only list `.zip`.

Use one of these:

| Method | Works with | What happens |
|--------|-----------|--------------|
| Install the `.apk` | any root | a normal app install |
| Root manager → Modules → *Install from storage* (`-module.zip`) | Magisk, KernelSU, APatch | installs the module and the app right away |
| Flash the `-module.zip` in a custom recovery (TWRP) | **Magisk only** | installs the module; the app is installed on the next boot |

The module installs the app and, if *Start Ubuntu at boot* is on, starts Ubuntu at boot.
Removing the module never deletes Ubuntu. Recovery flashing is implemented but not
tested yet. KernelSU and APatch modules can't be flashed from
recovery (their docs say so), and the installer stops with a message.

Optional: verify the release signature.

```sh
apksigner verify --print-certs uburoot.apk
# Signer #1 certificate SHA-256 digest:
# b2fbab8052e8bc9ee7cb01bc26f309ce972d16fdda34a52bdb15b2628d2ab53d
```

## First run

1. Open UbuRoot and allow root access when your root manager asks.
2. The app shows what it found (root manager, busybox, architecture, free space,
   namespace).
3. Choose a user name (lowercase, e.g. `ana`), an optional password and whether `sudo`
   should ask for it.
4. Tap install. The app downloads about 35 MB, extracts Ubuntu to
   `/data/local/uburoot/rootfs`, configures it (this runs `apt-get update`) and opens
   the terminal as your user.

If the app says there is no root but you never saw a prompt, open your root manager's
superuser list and allow UbuRoot by hand. On the test phone, Magisk once rejected the app
without showing its prompt.

## Using it

It's a normal Ubuntu: `sudo apt install ...` works.

```sh
# a typical development setup
sudo apt install build-essential cmake git gdb python3-venv python3-pip \
    nodejs npm golang-go rustc cargo default-jdk-headless openssh-server tmux
```

- **Files**: `/sdcard` is your phone's shared storage. Files you create there belong to
  the group `media_rw`, so Android apps can still read and write them. The Gallery may
  need a media rescan to show new files.
- **Android commands**: `pm list packages`, `cmd wifi status`, `getprop`... Some of them
  (`settings`, `dumpsys`, `am get-current-user`) need Android permissions that only root
  has, so run them with `sudo`.
- **No systemd**: Android's `init` is PID 1, so services don't start by themselves, and
  package installs never auto-start daemons. Start them by hand. For example, an SSH
  server for VS Code Remote or `scp`:

  ```sh
  sudo mkdir -p /run/sshd && sudo ssh-keygen -A
  sudo /usr/sbin/sshd -p 8022        # listens on every interface: use keys, not passwords
  ```

  Then, from your computer: `ssh -p 8022 <user>@<phone-ip>`.
- **File watchers**: UbuRoot raises `fs.inotify.max_user_watches` to 524288 (Android's
  default, 8192, is too low for VS Code and webpack). This is a kernel-wide setting that
  is only ever raised, and a reboot resets it.
- **Network tools**: `nmap`, `tcpdump`, `scapy`, `iw`... work with `sudo`. Your user
  can't capture packets or change the network without `sudo`; see [Security
  model](#security-model).
- **iptables** inside Ubuntu edits the **phone's** firewall. UbuRoot switches Ubuntu to
  `iptables-legacy`, which is the backend Android uses.
- **scapy**: Android keeps its default route in per-network routing tables, which
  confuses scapy's routing. Fix scapy's own table (not the kernel's) first:

  ```python
  from scapy.all import conf
  gw = "192.168.1.1"  # from: ip route show table all | grep '^default via'
  conf.route.routes = [r for r in conf.route.routes
                       if r[4] != "0.0.0.0" and not (r[0] == 0 and r[1] == 0)]
  conf.route.invalidate_cache()
  conf.route.add(net="0.0.0.0/0", gw=gw, dev="wlan0")
  ```
- **Wi-Fi monitor mode** depends on your phone's Wi-Fi driver. Run `iw phy` to see the
  supported interface modes. The test phone (Qualcomm) has none.

## Safety warning

> **Never delete `/data/local/uburoot/rootfs` yourself.**
>
> While Ubuntu is mounted, the phone's real `/data` and `/sdcard` are *inside* that
> folder. Deleting it with `rm -rf` or a file manager would **erase your phone's data
> and photos**.

To remove Ubuntu, use the reset script. It stops Ubuntu's processes, unmounts
everything, and refuses to delete anything if a single mount is left:

```sh
su --mount-master -c '/data/local/uburoot/bin/reset.sh --yes'
```

Then uninstall the app, and remove the module in your root manager if you installed it.
The few KB of scripts and config left in `/data/local/uburoot` are harmless.

### Security model

A chroot isolates the file system and nothing else. Ubuntu shares the kernel, the network
and the processes with Android:

- **Root inside Ubuntu is root on your phone.** It can read every app's data, change the
  network or break Android. Use `sudo` as carefully as you would `su`.
- Your user gets **uid 9000**, not Ubuntu's usual 1000. On Android, uid 1000 is the
  `system` user (system_server), and uids from 10000 up are apps, whose network Android
  blocks in some power-saving modes. 9000 is unused by Android and not an app uid.
- Your user is in `aid_inet` (network access) and `aid_media_rw` (shared storage). It is
  **not** in `aid_net_raw`/`aid_net_admin`: on Android kernels those groups grant raw
  sockets and network administration. A user in them could capture all of the phone's
  traffic without `sudo`. If you want that anyway:
  `sudo usermod -aG aid_net_raw,aid_net_admin <user>`.
- `/system`, `/vendor` and `/apex` are mounted read-only, even for root.

## How it works

The app is small. The real work is done by POSIX shell scripts in
[`app/src/main/assets/uburoot/bin/`](app/src/main/assets/uburoot/bin), which the app
copies to `/data/local/uburoot/bin/` and runs with `su --mount-master`. They can be used
and tested without the app.

| Script | Does |
|--------|------|
| `install.sh` | checks space and architecture, verifies the SHA256, extracts the tarball |
| `setup.sh` | DNS, hosts, apt sources, groups, `sudo`, the user |
| `mount.sh` | mounts `proc`, `sys`, `/dev`, `/dev/pts`, `/dev/shm`, `/run`, `/sdcard`, `/data` and the Android partitions; safe to run again |
| `enter.sh` | mounts, then enters Ubuntu with a clean environment as root or as the user |
| `umount.sh` | unmounts everything, deepest first |
| `reset.sh` | the only path that deletes the rootfs (see the safety warning) |
| `android-env` | captures Android's environment and creates the wrappers for its commands |

Mount design, in short: the rootfs is bind-mounted onto itself and made *private*, and
every mount inside it is made *slave*. Changes on the Android side (like APEX updates)
still show up in Ubuntu, but nothing done in Ubuntu propagates back. Unmounting Ubuntu's
copy of `/apex` or `/system` can never unmount the real ones. Mounts are not persistent:
opening a terminal re-creates whatever is missing, e.g. after a reboot.

[CLAUDE.md](CLAUDE.md) has the full architecture, every design decision and what was
verified on the device.

## Build from source

You need a JDK 21 (with `javac`) and the Android SDK (compileSdk 37).

```sh
./gradlew assembleDebug testDebugUnitTest
# app/build/outputs/apk/debug/app-debug.apk
```

Release builds are signed only when `UBUROOT_KEYSTORE`, `UBUROOT_KEYSTORE_PASSWORD`,
`UBUROOT_KEY_ALIAS` and `UBUROOT_KEY_PASSWORD` are set in the environment; otherwise the
release APK is unsigned. Keystores never go into the repository.

### Tests

| Command | Needs | Covers |
|---------|-------|--------|
| `tests/run-all.sh` | Docker | shellcheck, the reset safety guard, a real-mount suite in a privileged container (install → setup with real apt → enter → umount → reset) |
| `tests/device/run.sh [--reset]` | rooted phone over adb, Ubuntu installed | real mounts and propagation, network, wrappers, a sabotaged reset, umount back to the original state |
| `tests/device/session-test.sh` | run it inside the app's terminal | tty and job control, sudo, network, storage, read-only partitions, package integrity |
| `tests/device/advanced-test.sh` | run inside Ubuntu as root, dev packages installed | network and Wi-Fi tools, compilers and runtimes, debuggers, sshd |

The [CI](.github/workflows/ci.yml) runs the first row plus the build and unit tests on
every push. Tags `v*` publish a signed release.

## FAQ

**Why chroot and not proot (like Termux's proot-distro)?**
proot works without root but intercepts every system call, which is slow and doesn't
fully emulate the kernel. A chroot runs at native speed with real root, real mounts and
raw sockets, at the cost of needing root.

**Does it survive a reboot?**
Ubuntu itself, yes: it lives in `/data/local/uburoot`. The mounts don't, and they are
re-created the next time you open the terminal, or at boot with *Start Ubuntu at boot*
and the module, which can also start services (see [Features](#features)).

**Can I run Docker or systemd services?**
Not currently. There is no systemd, and container runtimes are untested.

**Does it work without Google Play Services?**
Yes. It was built for de-Googled ROMs.

**Which Ubuntu version do I get?**
The newest LTS, discovered at install time from `cdimage.ubuntu.com`. Nothing is
hardcoded.

## Privacy and F-Droid

- No analytics, tracking or ads, and no proprietary libraries (no Google Play Services,
  Firebase or Play Core).
- The app itself only talks to `cdimage.ubuntu.com`: the release listing, `SHA256SUMS`
  and the Ubuntu Base download. Everything else is what you run inside Ubuntu (for
  example, `apt` uses `ports.ubuntu.com`, set up as Ubuntu's normal package source).
- **Anti-features: none apply.**
  - *NonFreeNet* doesn't apply: Ubuntu Base is free software, downloaded once from
    Canonical's public image server, which is not a non-free network service.
  - *NonFreeDep* / *NonFreeAdd* / *Tracking* / *Ads*: none.
  - Root is required. That's not an anti-feature, but the app does nothing without it.
- Release builds come from the source by CI and are signed with the key whose
  fingerprint is listed in [Install](#install).

## Contributing

Bug reports from untested devices help a lot, and so do pull requests. See
[CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Report
security problems privately, as described in [SECURITY.md](SECURITY.md). Changes are
listed in the [CHANGELOG](CHANGELOG.md).

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for the third-party components
(Termux `terminal-view`/`terminal-emulator`, libsu).

Ubuntu is a trademark of Canonical Ltd. This project is not affiliated with or endorsed
by Canonical.
