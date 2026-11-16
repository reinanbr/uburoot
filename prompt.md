# UbuRoot — next milestone: NetHunter-level platform, full kernel and hardware access, Linux GUI apps

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
VNC/HDMI/cast) with audio, native Android front-ends for tools (Nmap Scan, Searchsploit,
MAC Changer...), a status home screen (interfaces, HID status), kernel and module
management, USB gadget control, settings backup, an update channel, a supported device
list and a porting/testing checklist.

## Goal
Make UbuRoot the most complete Linux-on-Android platform for rooted phones: NetHunter's
level of installation, lifecycle management and diagnostics, and beyond it in three
primary goals.

1. **Full kernel access.** From inside Ubuntu, root can do everything the kernel allows on
   this device: kernel filesystems (debugfs, tracefs, bpffs, configfs, cgroups, pstore...),
   modules, kernel logs, tracing and eBPF, tunables, out-of-tree modules built against the
   running kernel, the root manager's kernel extension points, and backing up, flashing
   and restoring kernels.
2. **Full hardware access.** Every piece of hardware the kernel exposes is reachable from
   Ubuntu with normal Linux tools (CPU/GPU, display, input, audio, camera, sensors, Wi-Fi,
   Bluetooth, NFC, USB host/gadget, LEDs, battery, buses). Where an Android HAL/daemon owns
   the device, UbuRoot offers either a **bridge** (Android API → Linux interface) or a
   **takeover** (stop the Android owner, hand the device to Ubuntu, restore afterwards).
3. **Linux GUI apps on the phone.** Wireshark, GIMP, gqrx, Ghidra, IDEs and any other
   X11/Wayland program run in windows on the phone (and on an external display), with GPU
   acceleration where the hardware allows, audio, touch/keyboard/mouse input and launcher
   shortcuts per app. On top of that, **native Android front-ends** for command-line tools,
   defined declaratively so the community can add them without Kotlin.

Where the kernel, the hardware or Android blocks something (module signature enforcement,
GKI symbol protection, SELinux, missing BTF, a HAL-only device, no open GPU driver...),
detect it, explain it in the app and document the workaround. Never pretend it works.

## Non-goals (do not implement)
- Offensive modules: HID/BadUSB payloads, DuckHunter, rogue AP / captive portal, WPS
  attacks, payload generators. Users install security tools with `apt`; UbuRoot provides
  the platform, the access and the GUI, not the attacks.
- An app store, or hosting our own rootfs tarballs. The only rootfs source stays
  Canonical (`cdimage.ubuntu.com`) or a file the user picks.
- systemd as PID 1.
- Writing to modem NV/EFS, IMEI, or calibration partitions. The modem is report-only.

## Constraints (inherited, non-negotiable)
- CRITICAL SAFETY RULE from `CLAUDE.md`: every recursive deletion under `UBU_BASE` goes
  through `ubu_safe_rm`. Every new feature that touches the rootfs or adds mounts (backup,
  restore, move, upgrade, remove, kernel filesystems, device binds, X11 sockets) must come
  with a test that sabotages the unmount and proves the abort path
  (`tests/test_reset_guard.sh` style + the Docker suite).
- System logic in POSIX `sh` scripts under `app/src/main/assets/uburoot/bin/`, testable via
  `adb shell su --mount-master -c ...` without the app; `shellcheck -s sh` clean; no
  bashisms (mksh/busybox/toybox).
- Always `su --mount-master`, command as one string.
- No Google/proprietary dependencies, no analytics, no new network endpoints except
  Canonical mirrors, GitHub releases (only where stated below) and what the user configures.
- **Licensing:** from Phase 0b on, UbuRoot is **GPL-3.0-or-later**. GPLv3 code (e.g.
  Termux:X11) can now be embedded; Apache-2.0 code (Termux terminal libs, libsu) stays
  compatible with GPLv3. GPL-2.0-only code is **not** compatible with GPLv3: check the
  license of anything you embed and record every third-party component in `NOTICE`.
- UI strings in `values/strings.xml` (English) **and** `values-pt-rBR/strings.xml`.
- **Opt-in power, always reversible.** *Kernel access* (`KERNEL_ACCESS`) and *Hardware
  access* (`HARDWARE_ACCESS`) are toggles in `uburoot.conf`, each behind a warning screen
  that says plainly that root in Ubuntu then controls the phone's kernel/hardware. Every
  action that changes kernel or device state (tunable, module, SELinux mode, CPU governor,
  stopped Android daemon, USB gadget config, takeover) records the original state in
  `/data/local/uburoot/state/` and is reverted by *Stop all*, by a *Revert changes* button
  and, where possible, is naturally lost at reboot. Nothing persists across reboots unless
  the user makes it a boot script.
- **Hardware safety floor** (no toggle disables it): never disable thermal shutdown or
  the charger's safety limits, never raise voltages, never write block devices except in
  the Phase 10 flash/restore flow (verified backup of the exact partition + typed
  confirmation word), never write modem NV.
- Never invent flags, APIs, URLs, device paths or library versions: verify at the source
  (kernel, AOSP, Mesa, project repos) and record the evidence (file, line, date) in
  `CLAUDE.md`.
- Everything in English: code, comments, commits, docs.

## Phase 0 — gap analysis (no code)
1. Read the NetHunter pages above and the current UbuRoot code.
2. Write `docs/NETHUNTER_PARITY.md`: one table, one row per NetHunter capability, with
   columns *NetHunter*, *UbuRoot today*, *Planned UbuRoot equivalent*, *Phase*, *Out of
   scope (why)*. Add rows for the three primary goals that go beyond NetHunter.
3. Propose changes to the phase list below if the analysis justifies them (order, split,
   drop). **Stop and show me the table and the final phase list before Phase 1.**

## Phase 0b — relicense to GPL-3.0-or-later (do this right after Phase 0 is approved)
Context: every commit so far is by the maintainer (reinanbr, with Claude as co-author),
so he can relicense alone. Verify that first (`git log --format='%an %ae'`, merged PRs
from other people, `Co-Authored-By` trailers); if anyone else contributed code, stop and
tell me who.
1. Replace `LICENSE` with the verbatim GPLv3 text from gnu.org.
2. `NOTICE`: UbuRoot copyright + GPL-3.0-or-later; keep the third-party section (Termux
   `terminal-view`/`terminal-emulator` and libsu are Apache-2.0, whose NOTICE terms still
   apply) and add each new component as it is embedded.
3. SPDX headers (`SPDX-License-Identifier: GPL-3.0-or-later`) in our own Kotlin, shell
   and Gradle files. Never touch third-party files (`gradlew`, `gradlew.bat`, the Gradle
   wrapper keep their own Apache-2.0 headers).
4. Update every place that says Apache: README (badge, License section, FAQ if needed),
   `CONTRIBUTING.md` (contributions are accepted under GPL-3.0-or-later, inbound =
   outbound, no CLA), `CLAUDE.md`, `prompt.md`, `tools/fdroid/com.reinanbr.uburoot.yml`
   (`License: GPL-3.0-or-later`), fastlane text if it mentions the license, an *About /
   Licenses* screen in the app if there is one (add it if not: app license + third-party
   licenses).
5. `CHANGELOG.md`: under Unreleased → *Changed*: relicensed from Apache-2.0 to
   GPL-3.0-or-later; releases up to and including v0.2.1 remain available under
   Apache-2.0. Ship it as the next minor version (v0.3.0).
6. `grep -rni apache` at the end must only hit third-party notices and Gradle files.

## Phases (ranked by value/dependency; stop at the end of each and show the result)

### Phase 1 — install hardening and diagnostics
1. `uburoot-doctor` (script + Settings button): root manager/version, mount namespace,
   SELinux mode and the root shell's context, Android/kernel version, FBE state, free
   space, mount table health, iptables backend, DNS, apt reachability.
   - **Kernel report** from `/proc/config.gz` or probing: namespaces, overlayfs, tun,
     binfmt_misc, configfs/USB gadget, HID gadget, CAN, wireguard, GKI or not
     (`uname -r`), `CONFIG_MODULES`, module signature enforcement, `vermagic`/modversions
     of vendor modules, BTF (`/sys/kernel/btf/vmlinux`), kprobes/uprobes,
     `kptr_restrict`, `dmesg_restrict`, `perf_event_paranoid`, `unprivileged_bpf_disabled`.
   - **Hardware inventory**: SoC, CPU clusters/governors, GPU and its device node
     (`/dev/kgsl-3d0`, `/dev/mali0`, DRM nodes), display/DRM/fbdev, input devices, ALSA
     cards, V4L2 nodes, IIO sensors, Wi-Fi phys and supported modes (`iw phy`), Bluetooth
     HCI, NFC node, USB controllers and gadget UDC, LEDs, power supplies, thermal zones,
     I²C/SPI/GPIO/serial nodes, and **who owns each device** (which Android
     process holds it open, from `/proc/*/fd`).
   - Output: human-readable plus a redacted bundle (no IPs, MACs, serials, IMEI or user
     names unless the user opts in), shareable from the app, and an issue template field
     that asks for it.
2. Rootfs versioning: `/etc/uburoot-release` (schema version + install date + Ubuntu
   release). `setup.sh` gets numbered, idempotent migrations so a new app version can
   upgrade an old rootfs's integration files safely. Test old → new in Docker.
3. Install robustness: hold a wake lock and keep the screen on during download/extract
   (NetHunter warns Android kills the installer otherwise); mirror choice for
   `ports.ubuntu.com`; **offline install from a local `.tar.gz` / `.tar.xz`** picked with
   SAF, with optional SHA256.
4. `docs/COMPATIBILITY.md`: device table (device, ROM, Android, root manager + version,
   result, doctor bundle link) and a device testing checklist modelled on NetHunter's.

### Phase 2 — full kernel access (runtime)
Today `mount.sh` mounts only a fresh `proc` and `sysfs`, so `/sys/kernel/debug`,
`/sys/kernel/tracing`, `/sys/fs/bpf`, `/sys/kernel/config` and `/sys/fs/cgroup` are empty
inside Ubuntu. With `KERNEL_ACCESS=1`:
1. **Kernel filesystems.** Where Android already mounted one (cgroup hierarchies, bpffs
   with netd's pinned maps, configfs with the USB gadget, tracefs, pstore), **bind the
   host mount** (made `rslave`, like the other binds) so Ubuntu sees the same objects;
   only mount a new instance where the host has none (debugfs, binfmt_misc, securityfs,
   fusectl). Same paths as on a normal Linux. `umount.sh` handles them in the existing
   private/detach/deepest-first order, and `ubu_safe_rm` gains markers for them. Docker
   suite: mount/umount with the host table identical afterwards.
2. **Modules.** Make `/lib/modules/$(uname -r)` work inside Ubuntu: bind the module
   directories that exist on the device (`/vendor/lib/modules`, `/vendor_dlkm`,
   `/system_dlkm`, others found in research) read-only and generate `modules.dep` with
   `depmod` into a writable overlay dir in the rootfs (never write to vendor). Then
   `lsmod`, `modinfo`, `modprobe`, `insmod`, `rmmod` work as usual. `uburoot-kmod`
   wraps load/unload with a confirmation and records what it loaded for revert.
3. **Kernel logs.** `dmesg`, `dmesg -w`, `/dev/kmsg`, and the previous boot's log from
   pstore (`/sys/fs/pstore`) or `last_kmsg`; a log viewer in the app.
4. **Tracing and eBPF.** ftrace/`trace-cmd` over tracefs; `bpftool`, `bpftrace` and bcc
   where BTF or matching headers exist (report clearly when they don't); `perf` built for
   the running kernel, or Android's `simpleperf` through the existing wrapper mechanism.
5. **Kernel tunables (developer mode).** One-tap relax/revert, with originals recorded:
   `kptr_restrict`, `dmesg_restrict`, `perf_event_paranoid` (Android drives it through
   the `security.perf_harden` property: verify), sysctls under `/proc/sys`. Prefer
   granting access to Ubuntu root only over relaxing it globally for every app.
6. **SELinux.** Show the mode and the root shell's context; a temporary
   enforcing→permissive switch (`setenforce 0`) with the strongest warning in the app,
   auto-revert on *Stop all*, and a note that it weakens every app on the phone. Before
   offering it, find out what actually fails under enforcing for Ubuntu root (Magisk's
   `magisk` domain, KernelSU's and APatch's domains) and fix those cases with targeted
   policy (`magiskpolicy`/`ksud sepolicy`/APatch equivalent) instead, if they exist.
7. **Out-of-tree modules.** `uburoot-kbuild`: prepare a build tree for the running kernel
   (`/proc/config.gz` + the exact source: Android Common Kernel tag derived from
   `uname -r` for GKI, OEM GPL source for vendor kernels), `make modules_prepare`, build
   a module with Ubuntu's `gcc`/`clang`. Document and detect the loading limits:
   `vermagic`, modversions CRCs, `CONFIG_MODULE_SIG_FORCE`, GKI protected symbols.
8. **Root-manager kernel extensions.** Research and expose what exists: APatch
   KernelPatch modules (KPM), KernelSU LKM/GKI mode features, anything Magisk offers.
   Verify in source; record differences in `docs/ROOT_IMPLEMENTATIONS.md`.
9. A *Kernel* screen: capability report, loaded modules, tunables with current/original
   values, SELinux, *Revert changes*.

### Phase 3 — full hardware access
With `HARDWARE_ACCESS=1`. For each class below, research the device node, the Android
owner and the conflicts, then pick the route: **direct** (the kernel interface is free),
**bridge** (an Android API feeds a Linux interface) or **takeover** (stop the owner via
`svc`/`cmd`/`stop <service>`, hand the device over, restore on stop). Document the
result per class in `docs/HARDWARE.md` and show it in a *Hardware* screen.

1. **Device access model.** Ubuntu groups mapped to the Android AIDs/device nodes
   (`audio`, `video`, `input`, `plugdev`, `dialout`, `render`, `bluetooth`...), udev-like
   rules applied by a script (no systemd-udevd), so the user can opt into each class
   without becoming root. `uburoot-hw` CLI: `list`, `info CLASS`, `grant CLASS USER`,
   `takeover CLASS`, `release CLASS`, `status`.
2. **CPU, power and thermal.** cpufreq governors/limits, core online/offline, cpusets,
   thermal zones (read; never disable shutdown trips), battery and charger status,
   charge limit where the driver exposes it, wakelocks and suspend control. Recorded and
   reverted like kernel tunables.
3. **GPU and display.** Expose the GPU node to Ubuntu (`/dev/kgsl-3d0` for Adreno,
   `/dev/mali0`/DRM for others), DRM/KMS and fbdev read access, brightness. Used by
   Phase 4 for acceleration.
4. **Input.** `/dev/input/event*` and `/dev/uinput` (already used in tests) for evdev
   tools, virtual keyboards/mice/gamepads, and external USB/Bluetooth input in Ubuntu.
5. **Audio.** Route A (bridge, default): PulseAudio/PipeWire in Ubuntu with an output and
   input module that reaches Android audio (AAudio/OpenSL through a small native helper
   in the app, or a socket to the app). Route B (takeover): ALSA/tinyalsa on `/dev/snd`
   with audioserver stopped. Pick by what works on the test device.
6. **Camera.** Bridge: Camera2 in the app → frames to Ubuntu as a V4L2 device
   (v4l2loopback if the kernel has or can load it) or an MJPEG/raw socket, so `ffmpeg`,
   OpenCV and GUI apps can use it. Direct V4L2 only where the vendor driver allows it.
7. **Sensors and location.** Bridge: SensorManager → IIO-like files or a socket/D-Bus
   service in Ubuntu (`uburoot-sensors`); LocationManager → `gpsd` feed. Direct IIO where
   sensors are on the kernel's IIO bus.
8. **Wi-Fi.** `iw`/nl80211 diagnostics in place; takeover mode stops Android Wi-Fi and
   runs `wpa_supplicant`/`hostapd` in Ubuntu; monitor mode where the phy supports it
   (internal or USB adapters, with the firmware path the kernel actually searches).
9. **Bluetooth.** Research whether BlueZ can get an HCI socket with Android's stack
   disabled (vendor HCI transport, `/dev/ttyHS*`, hci_uart, USB dongles), and implement
   takeover only if it works; otherwise USB Bluetooth dongles in Ubuntu.
10. **NFC.** Report the node; takeover with libnfc/nfcpy only if the controller is
    accessible; otherwise USB readers (e.g. ACR122U) in Ubuntu.
11. **USB.** Host: `/dev/bus/usb` and serial (`ttyUSB*`, `ttyACM*`) for the user (SDR
    dongles, microcontrollers, adapters). Gadget via configfs: NCM/RNDIS (phone as USB
    network to a laptop), ACM serial, mass storage of an image file, generic HID
    keyboard/mouse as an input device; Android's own gadget config saved and restored.
12. **Buses and misc.** I²C, SPI, GPIO (`gpiochip`, libgpiod), LEDs, vibrator, IR
    blaster, all **read-only by default**, with write access as an explicit per-node
    opt-in and a denylist for PMIC/charger/regulator nodes.
13. **Modem.** Report-only: modem type, interfaces, `rmnet` data interfaces usable for
    capture. No AT command or NV write path.

### Phase 4 — Linux GUI apps
Goal: open Wireshark from the Android launcher and get a usable window, with capture on
`wlan0`/`rmnet*`/USB adapters working for the user (dumpcap with the right
capabilities/groups on an Android kernel: verify how file capabilities interact with
`aid_net_raw`/`aid_net_admin`).
1. **Display server — research gate first** (write `docs/GUI.md`, then stop for my
   choice): compare (a) Termux:X11 as an external companion app, connected through a
   shared X socket in the chroot; (b) an X server or Wayland compositor **embedded in
   UbuRoot** rendering into a `SurfaceView` — with the GPL relicense, Termux:X11's code
   (GPL-3.0) is a candidate to embed or fork; also check Xwayland/wlroots licenses and
   arm64 build cost; (c) Xvnc/TigerVNC + an F-Droid VNC client (AVNC, bVNC) as the universal
   fallback. Criteria: latency, GPU path, per-app windows vs full desktop, external
   display (HDMI/USB-C DP, cast), maintenance, license.
2. **Modes.** *App mode*: one Linux app per Android window/task where the chosen
   display path supports it (rootless X or a per-app surface); *Desktop mode*: a full
   lightweight desktop (research XFCE vs LXQt on arm64 LTS) — the KeX equivalent. Bind
   to localhost only by default; LAN exposure is an explicit opt-in with a password.
3. **GPU acceleration.** Adreno: Mesa Turnip (Vulkan, KGSL backend) + Zink (OpenGL on
   Vulkan); verify the Mesa version and build flags Ubuntu ships and build/package our
   own only if needed. Mali and others: research (panfrost needs an upstream kernel
   driver Android kernels usually lack; virgl/venus through Android's driver; llvmpipe as
   the fallback). Report the active renderer (`glxinfo -B`, `vulkaninfo`) in the app.
4. **Audio** from Phase 3 wired into the session; **input**: touch as mouse with
   gestures (right click, scroll, drag), on-screen extra keys, hardware keyboard/mouse,
   IME text input, clipboard sync with Android (reuse `uburoot-clip`).
5. **Launcher integration.** Scan `/usr/share/applications/*.desktop` (and `~/.local`),
   list them in a *Linux apps* screen with their icons, and pin any of them as an Android
   launcher shortcut (`ShortcutManager`) that starts the display path + the app.
   `uburoot-open`/`xdg-open` keep working in both directions.
6. **Packaging pitfalls.** Ubuntu's `firefox`/`chromium` debs are snap transitions and
   snaps need systemd: detect and point to working alternatives (Mozilla's APT repo,
   Flatpak if it works without systemd — research). Same check for any app in the
   acceptance list.
7. **Acceptance apps** (tested on the device, results in `docs/GUI.md`): Wireshark (live
   capture), GIMP, a browser, gqrx with an RTL-SDR dongle (USB from Phase 3 + audio),
   Ghidra (Java), a code editor, glmark2/vkcube (GPU path).

### Phase 5 — native tool front-ends (NetHunter's Nmap Scan, generalized)
1. **Declarative tool definitions**: root-owned files in `/etc/uburoot/tools.d/*.json`
   (or TOML; pick one and document a schema with a version field): name, description,
   icon, category, `run_as` (user/root), **argv template** (an array, never a shell
   string), typed parameters (text, number, boolean, choice, file/dir picker via SAF,
   network interface/USB device/target pickers populated by a command), output mode
   (new terminal tab, streaming log, table via a parser — JSON/XML/CSV/regex —, or a
   result file opened with `uburoot-open` or a GUI app).
2. **Renderer**: a Compose screen that builds the form from the schema, validates input,
   shows the exact command before running, keeps a history and lets the user save
   presets and pin a tool as a launcher shortcut.
3. **Security**: only root-owned, non-writable definition files are loaded; parameters
   are passed as separate argv entries; root tools need a confirmation; schema
   validation with clear errors. Unit tests for the template expansion (injection
   attempts included).
4. **Bundled definitions** (examples, all defensive/diagnostic): nmap scan with XML →
   table, tcpdump capture to a pcap → open in Wireshark (Phase 4), iperf3, ping /
   traceroute / mtr, `iw` scan, apt update/upgrade, `uburoot-doctor`, `uburoot-hw`
   info, dmesg follow. A `docs/TOOLS.md` guide so the community can add more.

### Phase 6 — chroot manager
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
   *desktop*, *hardware/SDR*, *kernel dev*). Lists live in a versioned file in assets,
   not hardcoded in Kotlin.
6. **Release upgrade** to the next LTS (`do-release-upgrade` or sources rewrite + full
   upgrade; research which one works without systemd), with a mandatory backup prompt.

### Phase 7 — services and custom commands
1. `uburoot-svc` (POSIX sh, no systemd): `start|stop|restart|status|enable|disable|logs
   NAME`, pidfiles in `/run/uburoot/`, logs in `/var/log/uburoot/`, definitions in
   `/etc/uburoot/services.d/NAME` (command, user, optional readiness check). `enable`
   integrates with the existing `/etc/uburoot-boot.d/` mechanism; do not create a second
   boot path. Ship examples: sshd, the desktop/display server (Phase 4), the audio and
   sensor bridges (Phase 3).
2. Services screen: list, status, start/stop, run-at-boot toggle, log tail.
3. Custom commands (NetHunter's "Custom Commands"): quick commands that run in a new tab
   or in the background with a result notification; pinnable as launcher shortcuts and
   as a Quick Settings tile. (Tools with parameters belong to Phase 5.)

### Phase 8 — status home screen
Replace the bare preflight-to-terminal flow with a home screen once installed: Ubuntu
state (mounted / not), sessions, services, network interfaces and addresses, disk usage
of the rootfs, kernel and hardware access state (what is granted/taken over, with
*Revert changes*), GPU renderer, quick actions (terminal, root terminal, Linux apps,
tools, stop all, repair mounts, doctor). Keep the current preflight logic underneath.

### Phase 9 — architectures and Android versions
1. Support `armhf` and `amd64` Ubuntu Base where the device ABI allows it
   (`ReleaseDiscovery`, `install.sh` arch check, `setup.sh` sources). Keep arm64 default.
2. Android 13–16: typed `startForeground` (API 34+), POST_NOTIFICATIONS (33+), any new
   restriction on `--mount-master`, background starts, broadcasts, camera/mic/sensor
   access from a background service (foreground-service types `camera`, `microphone`,
   etc. for the Phase 3 bridges). Verify in AOSP source.
3. CI: research running the device suite on a rootable x86_64 Android emulator image so
   amd64 and newer Android are exercised on every push.

### Phase 10 — kernel manager (NetHunter's "Kernel: search, download, flash")
Highest-risk phase. Nothing here runs on the test device without my explicit approval
each time.
1. **Backup first, always.** Identify the boot chain partitions of this device and slot
   (`boot`, `init_boot`, `vendor_boot`, `dtbo`, `vendor_dlkm`... via
   `/dev/block/by-name` and `ro.boot.slot_suffix`), dump them with SHA256 to a SAF
   location, and keep a manifest (device codename, build fingerprint, slot, kernel
   version). Flashing is refused without a verified backup of every partition it writes.
2. **Flash** a user-provided kernel: AnyKernel3 zips (verify how AK3 runs from a booted
   system) or raw images; check the device codename and partition sizes before writing;
   on A/B devices research flashing the inactive slot so the bootloader can fall back.
3. **Keep root.** A new boot/init_boot image loses Magisk/KernelSU/APatch: research and
   implement re-patching per manager (Magisk's boot patch script, KernelSU GKI/LKM,
   APatch's patcher), or stop with clear instructions.
4. **Restore** from a backup in the app, plus a documented fastboot/recovery path for
   when the phone no longer boots.
5. Kernel sources are only a file the user picks or a URL the user types; no catalog
   hosted by us.
6. Build guide (docs + optional CI recipe, not in-app): building a kernel for a device
   with extra options (USB gadget/HID, monitor-mode Wi-Fi drivers, CAN, v4l2loopback,
   BTF/kprobes, module signing off) from GKI or OEM source.

### Phase 11 — updates, settings backup, documentation
1. Optional update check against GitHub releases, in a separate build flavor that is
   **not** used for F-Droid (F-Droid updates the app itself). Off by default.
2. Export/import of app settings + `uburoot.conf` + services + custom commands + tool
   presets (NetHunter backs up `nh_files`).
3. Docs in `docs/` organised like NetHunter's: installing, first run, chroot manager,
   services, kernel access, hardware access, Linux GUI apps, tools, kernel manager,
   troubleshooting, compatibility, porting/testing checklist. Keep README short and link
   out. pt-BR versions where the README section already exists in English.

### Optional research — rootless edition (decision document only)
Evaluate a proot-based fallback for unrooted phones (NetHunter Rootless): what breaks
(mounts, raw sockets, iptables, boot, kernel and hardware access), performance,
maintenance cost, whether it belongs in this app or a separate one. Write
`docs/ROOTLESS.md`; implement nothing.

## Definition of done for every phase
- Scripts shellcheck-clean; Docker suite extended and green; unit tests for new Kotlin.
- Device test on the Samsung Galaxy S9 / LineageOS 19.1 / Magisk 31.1 when `adb devices`
  shows it; otherwise list precisely what is untested (and on which Android/root
  manager/SoC — the S9 is Snapdragon 845/Adreno 630, so Mali paths stay untested).
- Host mount table identical to the baseline after `umount.sh` (as the existing suites
  do), and every kernel/hardware change (tunable, module, SELinux, governor, takeover,
  gadget) back to the recorded original after *Revert changes* and after *Stop all*;
  Android's own Wi-Fi/Bluetooth/audio/camera work normally afterwards.
- `CLAUDE.md` (decisions + evidence), `README.md`, `CHANGELOG.md` (Unreleased),
  `docs/NETHUNTER_PARITY.md` (status column) updated.
    - Small Conventional Commits. Stop and show me the result before the next phase.
