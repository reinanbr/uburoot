# UbuRoot — next milestone: NetHunter-level installation and management

## Context
You are working on UbuRoot (`com.reinanbr.uburoot`), an Android app that installs and runs
an Ubuntu Base rootfs in a chroot using root (Magisk / KernelSU / APatch), with a real PTY
terminal and deep Android integration. Phases 1–5 of `prompt.md` are done (v0.2.1).

**Read `CLAUDE.md` in full before anything else.** It is the source of truth for
architecture, paths, mount design, the critical safety rule, root-manager differences and
everything already verified on the device. Do not re-derive or contradict it; extend it.

The reference for this milestone is Kali NetHunter's installation and management layer:
- https://www.kali.org/docs/nethunter/installing-nethunter/
- https://www.kali.org/docs/nethunter/ (editions, components)
- https://www.kali.org/docs/nethunter/nethunter-chroot-manager/
- https://www.kali.org/docs/nethunter/nethunter-kex-manager/
- https://www.kali.org/docs/nethunter/nethunter-components/

NetHunter offers: several install channels (pre-built per device, generic installers per
architecture, recovery zip, Magisk module), editions by capability (Rootless / Lite /
Full), minimal and full chroots, a chroot manager (install, backup, restore, remove), a
services manager with run-at-boot, custom commands in the launcher, a desktop (KeX over
VNC/HDMI/cast) with audio, a status home screen (interfaces, HID status), kernel and
module management, USB gadget control, settings backup, an update channel, a supported
device list and a porting/testing checklist.

## Goal
Bring UbuRoot to the same level of **installation, lifecycle management, diagnostics and
platform integration**, adapted to what UbuRoot is: a general-purpose Ubuntu for rooted,
de-Googled phones, eligible for F-Droid.

## Non-goals (do not implement)
- Offensive modules: HID/BadUSB payloads, DuckHunter, rogue AP / captive portal, WPS
  attacks, payload generators. Users install security tools with `apt`; UbuRoot provides
  the platform, not the attacks.
- Building or flashing kernels. Detecting and reporting kernel capabilities is in scope.
- An app store, or hosting our own rootfs tarballs. The only rootfs source stays
  Canonical (`cdimage.ubuntu.com`) or a file the user picks.
- systemd as PID 1.

## Constraints (inherited, non-negotiable)
- CRITICAL SAFETY RULE from `CLAUDE.md`: every recursive deletion under `UBU_BASE` goes
  through `ubu_safe_rm`. Every new feature that touches the rootfs (backup, restore, move,
  upgrade, remove) must come with a test that sabotages the unmount and proves the abort
  path (`tests/test_reset_guard.sh` style + the Docker suite).
- System logic in POSIX `sh` scripts under `app/src/main/assets/uburoot/bin/`, testable via
  `adb shell su --mount-master -c ...` without the app; `shellcheck -s sh` clean; no
  bashisms (mksh/busybox/toybox).
- Always `su --mount-master`, command as one string.
- No Google/proprietary dependencies, no analytics, no new network endpoints except
  Canonical mirrors, GitHub releases (only where stated below) and what the user configures.
- UI strings in `values/strings.xml` (English) **and** `values-pt-rBR/strings.xml`.
- Never invent flags, APIs, URLs or library versions: verify at the source and record the
  evidence (file, line, date) in `CLAUDE.md`.
- Everything in English: code, comments, commits, docs.

## Phase 0 — gap analysis (no code)
1. Read the NetHunter pages above and the current UbuRoot code.
2. Write `docs/NETHUNTER_PARITY.md`: one table, one row per NetHunter capability, with
   columns *NetHunter*, *UbuRoot today*, *Planned UbuRoot equivalent*, *Phase*, *Out of
   scope (why)*.
3. Propose changes to the phase list below if the analysis justifies them (order, split,
   drop). **Stop and show me the table and the final phase list before Phase 1.**

## Phases (ranked by value/risk; stop at the end of each and show the result)

### Phase 1 — install hardening and diagnostics
1. `uburoot-doctor` (script + Settings button): root manager/version, mount namespace,
   SELinux mode, Android/kernel version, FBE state, free space, mount table health,
   iptables backend, DNS, apt reachability and a **kernel capability report** from
   `/proc/config.gz` or probing when absent (namespaces, overlayfs, tun, binfmt_misc,
   USB gadget configfs, HID gadget, cfg80211/monitor-capable phys via `iw phy`, CAN,
   wireguard). Output: human-readable plus a redacted bundle (no IPs, MACs, serials or
   user names unless the user opts in) that can be shared from the app, and an issue
   template field that asks for it.
2. Rootfs versioning: `/etc/uburoot-release` (schema version + install date + Ubuntu
   release). `setup.sh` gets numbered, idempotent migrations so a new app version can
   upgrade an old rootfs's integration files safely. Test old → new in Docker.
3. Install robustness: hold a wake lock and keep the screen on during download/extract
   (NetHunter warns Android kills the installer otherwise); mirror choice for
   `ports.ubuntu.com`; **offline install from a local `.tar.gz` / `.tar.xz`** picked with
   SAF, with optional SHA256.
4. `docs/COMPATIBILITY.md`: device table (device, ROM, Android, root manager + version,
   result, doctor bundle link) and a device testing checklist modelled on NetHunter's.

### Phase 2 — chroot manager
New "Ubuntu" management screen + scripts:
1. **Backup** (`backup.sh`): only with everything unmounted (`umount.sh --kill` first,
   abort if it fails) or with `--one-file-system` and an explicit exclude list of every
   bind target; `tar` with numeric owners, permissions and xattrs; compression choice;
   output to a SAF location; manifest with SHA256 and `/etc/uburoot-release`.
2. **Restore** (`restore.sh`): verify manifest and checksum, extract into
   `rootfs.partial`, atomic rename; the old rootfs is only removed through `ubu_safe_rm`.
3. **Verify** (`dpkg --verify`-based integrity report) and **remove** (existing reset flow).
4. **Move location** (e.g. to an ext4 adoptable/external partition), if the target
   filesystem supports ownership, device nodes are not needed and `suid` is possible;
   refuse FAT/exFAT/FUSE with a clear message.
5. **Profiles** (NetHunter's minimal/full, done the Ubuntu way): after install, optional
   package sets applied with `apt` (e.g. *minimal*, *development*, *network tools*,
   *desktop*). Lists live in a versioned file in assets, not hardcoded in Kotlin.
6. **Release upgrade** to the next LTS (`do-release-upgrade` or sources rewrite + full
   upgrade; research which one works without systemd), with a mandatory backup prompt.

### Phase 3 — services and custom commands
1. `uburoot-svc` (POSIX sh, no systemd): `start|stop|restart|status|enable|disable|logs
   NAME`, pidfiles in `/run/uburoot/`, logs in `/var/log/uburoot/`, definitions in
   `/etc/uburoot/services.d/NAME` (command, user, optional readiness check). `enable`
   integrates with the existing `/etc/uburoot-boot.d/` mechanism; do not create a second
   boot path. Ship examples: sshd, a VNC desktop (Phase 5).
2. Services screen: list, status, start/stop, run-at-boot toggle, log tail.
3. Custom commands (NetHunter's "Custom Commands"): user-defined commands that run in a
   new tab or in the background with a result notification; pinnable as launcher
   shortcuts (`ShortcutManager`) and as a Quick Settings tile.

### Phase 4 — status home screen
Replace the bare preflight-to-terminal flow with a home screen once installed: Ubuntu
state (mounted / not), sessions, services, network interfaces and addresses, disk usage
of the rootfs, kernel capability summary from Phase 1, quick actions (terminal, root
terminal, stop all, repair mounts, doctor). Keep the current preflight logic underneath.

### Phase 5 — desktop (KeX equivalent)
1. `uburoot-desktop` script: installs on demand a lightweight desktop (research XFCE vs
   LXQt on arm64 Ubuntu LTS) and a VNC server (TigerVNC), binds to **127.0.0.1 by
   default**, password required, configurable resolution/DPI; exposing it to the LAN is an
   explicit opt-in with a warning.
2. App: start/stop, then hand off to an F-Droid VNC client through an intent (e.g.
   `vnc://127.0.0.1:5901`; verify which clients — AVNC, bVNC — accept which URI);
   detect "no client installed" and explain.
3. Audio: research PulseAudio/PipeWire to Android output inside a chroot (TCP sink,
   AAudio/OpenSL bridge) and implement only what works on the test device.
4. Research gate (write findings, do not implement without my approval): Termux:X11 as
   an alternative display, HDMI/cast notes.

### Phase 6 — architectures and Android versions
1. Support `armhf` and `amd64` Ubuntu Base where the device ABI allows it
   (`ReleaseDiscovery`, `install.sh` arch check, `setup.sh` sources). Keep arm64 default.
2. Android 13–16: typed `startForeground` (API 34+), POST_NOTIFICATIONS (33+), any new
   restriction on `--mount-master`, background starts or broadcasts. Verify in AOSP source.
3. CI: research running the device suite on a rootable x86_64 Android emulator image so
   amd64 and newer Android are exercised on every push.

### Phase 7 — hardware integration (advanced, opt-in, behind a warning screen)
Only where Phase 1 detects support; always save and restore the original state:
1. USB gadget via configfs: NCM/RNDIS (phone as USB network to a laptop), ACM serial,
   mass storage of an image file. Restore Android's own gadget config on stop.
2. USB OTG devices inside Ubuntu: `/dev/bus/usb` and serial (`ttyUSB*`, `ttyACM*`)
   access for the user, documented (SDR dongles, microcontrollers, USB Wi-Fi adapters).
3. Kernel modules: read-only list of loaded and available vendor modules; `modprobe`
   of an available module only as an explicit advanced action.

### Phase 8 — updates, settings backup, documentation
1. Optional update check against GitHub releases, in a separate build flavor that is
   **not** used for F-Droid (F-Droid updates the app itself). Off by default.
2. Export/import of app settings + `uburoot.conf` + services + custom commands (NetHunter
   backs up `nh_files`).
3. Docs in `docs/` organised like NetHunter's: installing, first run, chroot manager,
   services, desktop, hardware, troubleshooting, compatibility, porting/testing
   checklist. Keep README short and link out. pt-BR versions where the README section
   already exists in English.

### Optional research — rootless edition (decision document only)
Evaluate a proot-based fallback for unrooted phones (NetHunter Rootless): what breaks
(mounts, raw sockets, iptables, boot), performance, maintenance cost, whether it belongs
in this app or a separate one. Write `docs/ROOTLESS.md`; implement nothing.

## Definition of done for every phase
- Scripts shellcheck-clean; Docker suite extended and green; unit tests for new Kotlin.
- Device test on the Samsung Galaxy S9 / LineageOS 19.1 / Magisk 31.1 when `adb devices`
  shows it; otherwise list precisely what is untested (and on which Android/root manager).
- Host mount table identical to the baseline after `umount.sh` (as the existing suites do).
- `CLAUDE.md` (decisions + evidence), `README.md`, `CHANGELOG.md` (Unreleased),
  `docs/NETHUNTER_PARITY.md` (status column) updated.
- Small Conventional Commits. Stop and show me the result before the next phase.
