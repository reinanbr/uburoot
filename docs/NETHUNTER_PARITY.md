# NetHunter parity

What Kali NetHunter offers for installing and managing its chroot, and what UbuRoot has or
plans instead. UbuRoot is a general-purpose Ubuntu for rooted, de-Googled phones (F-Droid),
not a pentest distribution: it provides the platform, and users install tools with `apt`.

**Edition:** UbuRoot is **root-only**. It requires a root that really is root (full
capabilities, no seccomp, init mount namespace), and it goes beyond NetHunter in three
goals (see `prompt.md`): **full kernel access**, **full hardware access** and **Linux GUI
apps**. The kernel and hardware powers are opt-in toggles (`KERNEL_ACCESS`,
`HARDWARE_ACCESS`) behind warning screens, every change is recorded and reverted by *Stop
all* / *Revert changes*, and a hardware safety floor (thermal, charger, voltages, block
devices, modem NV) never moves. In NetHunter terms it covers *Lite* (any rooted phone,
stock kernel) and reaches into *Full* through the stock kernel's own interfaces and a
kernel manager for user-provided kernels.

Sources (read 2026-11-16): kali.org/docs/nethunter/ (updated 2026-06-23), and these pages
under it: installing-nethunter, nethunter-chroot-manager, nethunter-kex-manager,
nethunter-components, nethunter-home-screen, nethunter-kali-services,
nethunter-custom-commands, nethunter-settings, nethunter-kernel, nethunter-modules,
nethunter-audio, nethunter-usbarsenal, nethunter-mac-changer, nethunter-rootless,
testing-checklist, nethunter-terminal. Several pages are mostly screenshots. Where the text
doesn't say something (e.g. which VNC server KeX uses), the table doesn't claim it.

Status: **done** (in a release), **partial**, **planned**, **out** (out of scope).

## Measured on the test phone (S9, LineageOS 19.1, kernel 4.9.337, Magisk 31.1)

- `su -M`, on the host and as root inside the chroot: uid 0, context `u:r:magisk:s0`,
  `CapEff`/`CapBnd` `0000003fffffffff` (all 38 capabilities of a 4.9 kernel), `Seccomp: 0`.
  SELinux is enforcing; the `magisk` domain is what lets root through.
- `/proc/config.gz` is present (6145 lines). It has `MODULES USER_NS PID_NS NET_NS
  OVERLAY_FS TUN CONFIGFS_FS USB_CONFIGFS USB_CONFIGFS_F_HID USB_CONFIGFS_NCM
  USB_CONFIGFS_MASS_STORAGE USB_CONFIGFS_ACM CFG80211 WIREGUARD BPF_SYSCALL IP_NF_IPTABLES
  BLK_DEV_LOOP USB_SERIAL USB_ACM BT F2FS_FS`. It lacks `BINFMT_MISC`, `MAC80211`, `CAN`,
  `NF_TABLES`, `USB_CONFIGFS_RNDIS`, `SQUASHFS` and `KVM`. No modules are loaded
  (`/proc/modules` is empty).
- configfs is mounted at **`/config`** (old Android path, with `usb_gadget`), debugfs at
  `/sys/kernel/debug`, tracefs at `/sys/kernel/tracing`.
- **Gap:** inside the chroot, `/sys/kernel/config`, `/sys/kernel/debug`,
  `/sys/kernel/tracing` and `/sys/fs/bpf` are **empty**. The chroot's fresh `sysfs` mount
  has none of the host's submounts. Ubuntu's root can't see configfs, debugfs, tracefs or
  bpffs today, and there is no `/lib/modules/$(uname -r)` for `modprobe`.

## Table

| NetHunter | UbuRoot today | Planned UbuRoot equivalent | Phase | Status | Out of scope (why) |
|---|---|---|---|---|---|
| **Install channels** | | | | | |
| Pre-built image per device (custom kernel + chroot) | One APK for every arm64 device | One APK; kernels only as files the user picks (kernel manager) | 10 | out (images) | We host no images or kernels (non-goal: no store, no hosted rootfs). |
| Generic installer zip per architecture (arm64, armhf, i386, amd64) | arm64 Ubuntu Base only | armhf and amd64 where the device ABI allows it, arm64 stays the default | 9 | planned | i386: to check in Phase 9 whether Canonical still publishes an i386 Ubuntu Base. |
| Magisk module ("new and recommended") | The APK is also a module: Magisk, KernelSU, APatch (`customize.sh`); verified with Magisk 31.1 | Keep | — | done | |
| Recovery (TWRP) zip | The same file flashes in TWRP for Magisk (`update-binary` → `install_module`) | Keep | — | partial | Not tested on a device. The S9 has TWRP, but the user chose to skip the test because the Magisk path works. |
| Rootless edition (Termux + proot, NetHunter Store) | None | Decision document only (`docs/ROOTLESS.md`) | optional | planned (research) | UbuRoot requires root with full kernel access. Without root, the mounts, binds, raw sockets, iptables, boot start, bridge and every kernel/hardware feature are gone: likely a separate app. |
| Pre-install guidance (unlock, root, developer options, disable force encryption) | README: root manager, arm64 | `docs/INSTALLING.md`. No step to disable encryption: UbuRoot works on encrypted `/data`, and the boot script waits for the first unlock | 11 | planned | |
| SHA256 check of the download | `SHA256SUMS` from cdimage, checked after download, one re-fetch | Keep | — | done | |
| "Keep the screen awake while installing, Android may kill the app" | Partial wake lock (1 h cap) + screen kept on while installing; resumes after a kill | Wake lock + `FLAG_KEEP_SCREEN_ON` during download/extract | 1 | done | |
| Install from local storage | *Advanced*: local `.tar.gz`/`.tar.xz` via SAF, optional SHA256; format from the magic bytes, rootfs CPU checked | Local `.tar.gz` / `.tar.xz` picked with SAF, optional SHA256 | 1 | done | |
| Mirror choice | `APT_MIRROR` (install form and Settings), `http://` only; security updates stay on Canonical | Choose a `ports.ubuntu.com` mirror | 1 | done | |
| Full vs minimal chroot (kalifs-full / kalifs-minimal) | Ubuntu Base (minimal) + `setup.sh` | Profiles applied with `apt` after install (minimal, development, network tools, desktop, hardware/SDR, kernel dev); lists in a versioned asset | 6 | planned | |
| Update channels (quarterly release, weekly, daily builds; Store for the app) | GitHub releases; per-commit CI artifacts; F-Droid recipe ready (MR pending) | Optional update check in a non-F-Droid flavor, off by default | 11 | planned | |
| **Root and kernel** | | | | | |
| Lite needs Magisk root; Full needs a device kernel | Preflight refuses a restricted root (`rootinfo.sh` `full_root=`), with the reason | **Require full root**: uid 0, `CapEff` and `CapBnd` = every capability up to `cap_last_cap`, no seccomp, no `NoNewPrivs`, init mount namespace. Refuse with an explanation otherwise (e.g. a KernelSU App Profile with fewer capabilities: verified in `kernel/policy/app_profile.c`) | 1 | done | |
| Kernel interfaces available to Kali root | `KERNEL_ACCESS=1` (Settings, with a warning): host binds, new instances only where the host has none; host mount table identical after Stop all (S9, Docker) | `KERNEL_ACCESS=1`: bind the host's configfs, tracefs, bpffs, cgroups, pstore; new instances only where the host has none (debugfs, binfmt_misc, securityfs, fusectl); `ubu_safe_rm` markers; Docker host-identical check | 2 | done | |
| Kernel features (HID, OTG Wi-Fi, CD-ROM emulation, SDR, y-cable charging, kexec) | Doctor kernel report (config or probes) + hardware inventory with device owners | Doctor kernel report (config or probing: GKI, module signing, vermagic, BTF, kprobes, sysctls); build guide for kernels with extra options | 1, 10 | done (report); planned (build guide) | Building kernels in the app: no (a docs/CI guide instead). |
| Kernel: search, download, flash | — | Kernel manager: backup of every boot-chain partition first, flash a user-provided AK3 zip or image, keep root (re-patch per manager), restore. Each device run only with the owner's approval | 10 | planned | No kernel catalog hosted by us. |
| Modules: load modules | ROM module dirs bound read-only under `/usr/lib/modules/$KV/uburoot/` + `depmod`; `uburoot-kmod` with revert; `uburoot-kbuild` check/prepare/build. S9: signing enforced, so only signed modules load | `/lib/modules/$(uname -r)` from the ROM's module dirs (read-only) + `depmod` into a rootfs overlay; `uburoot-kmod` load/unload with revert; out-of-tree builds (`uburoot-kbuild`) | 2 | done | |
| SELinux status toggle (Settings) | Kernel screen switch and `uburoot-kernel selinux`, strongest warning, reverted by Stop all. Root's domain is already permissive under all three managers | Mode and root context in the doctor; targeted policy fixes first, then a temporary permissive switch with the strongest warning, reverted by *Stop all* | 1, 2 | done | Never permanent. |
| Kernel logs, tracing, eBPF, tunables | `dmesg -w` tab, previous boot's log (pstore/`last_kmsg`), trace-cmd, simpleperf/perf, BPF fs; recorded sysctls; bpftool limited on kernels < 4.13, no BTF on the S9 | `dmesg`/kmsg/pstore viewer, ftrace/trace-cmd, bpftool/bpftrace where BTF exists, perf/simpleperf, tunables with recorded originals | 2 | done | |
| Root manager kernel extensions (KPM, KernelSU LKM) | Documented in `docs/KERNEL.md` (`ksud insmod`, `apd insmod`, KPM); not wrapped (manager-specific, superkey) | Research and expose; differences in `docs/ROOT_IMPLEMENTATIONS.md` | 2 | done (documented) | |
| **Chroot manager** | | | | | |
| Download and install | Discover newest LTS, download, verify, extract, `setup.sh`, resume after a kill | Keep | — | done | |
| Backup | — | `backup.sh` (unmounted, or one-file-system with every bind excluded), numeric owners, xattrs, compression choice, SAF target, manifest + SHA256 | 6 | planned | |
| Restore | — | `restore.sh`: verify manifest, extract to `rootfs.partial`, atomic rename, old rootfs only through `ubu_safe_rm` | 6 | planned | |
| Remove | *Reset Ubuntu* (`reset.sh --yes`, typed `DELETE`/`APAGAR`, `ubu_safe_rm`) | Keep, move to the manager screen | 6 | done | |
| Install metapackages | `apt` by hand | Profiles (see above) | 6 | planned | |
| — (no NetHunter equivalent) | — | Verify (`dpkg --verify` report), move to another ext4/f2fs location, release upgrade to the next LTS | 6 | planned | |
| Rootfs versioning / upgrades of integration files | `/etc/uburoot-release` (SCHEMA 1), `setup.sh --migrate`, run by the app on start | `/etc/uburoot-release` + numbered migrations | 1 | done | |
| **Services and commands** | | | | | |
| Kali Services: start/stop SSH, Apache, OpenVPN…, enable at boot | `/etc/uburoot-boot.d/` scripts run by the boot module | `uburoot-svc` (pidfiles, logs, definitions in `/etc/uburoot/services.d/`), `enable` = the boot.d mechanism; Services screen | 7 | planned | |
| Default `toor` password warning | No default password: the user picks one in the install form (or passwordless sudo, opt-in) | sshd example service requires a key or the user's own password | 7 | done | |
| Custom Commands (buttons, preconfigured examples) | — | Quick commands in a new tab or in the background with a result notification; launcher shortcuts and a Quick Settings tile | 7 | planned | |
| Nmap Scan, Searchsploit, MAC Changer screens (native tool front-ends) | — | Declarative tool definitions (`/etc/uburoot/tools.d/`, argv templates, typed parameters, parsers) rendered as forms; bundled defensive/diagnostic examples (nmap → table, tcpdump → Wireshark, iperf3, mtr, iw scan…) | 5 | planned | Offensive front-ends stay out (see below). |
| **App screens** | | | | | |
| Home screen: external/internal IPs, HID interface status | Preflight → terminal | Status home: mounted state, sessions, services, interfaces and addresses, rootfs disk use, kernel/hardware access state with *Revert changes*, GPU renderer, quick actions | 8 | planned | |
| "Attacks greyed out if the chroot is not running" | — | Home actions reflect the mounted state | 8 | planned | |
| Terminal: Kali chroot, Android shell, Android root shell | Chroot sessions as the user or as root; tabs, extra keys, themes | Add *Android shell* and *Android root shell* session types | 8 | planned | |
| Hacker's Keyboard | Extra keys rows (ESC, CTRL, ALT, arrows…), hardware keyboard shortcuts | Keep | — | done | |
| Settings: terminal style | Themes, font size | Keep | — | done | |
| Settings: backup/restore `nh_files` | — | Export/import app settings + `uburoot.conf` + services + custom commands + tool presets | 11 | planned | |
| Settings: custom boot animation | — | — | — | out | Changes the ROM's look, unrelated to the chroot. |
| **Desktop and audio** | | | | | |
| KeX: VNC desktop with password, start/stop, custom resolution, HDMI/cast | — | Desktop mode (XFCE or LXQt, researched) over the display path chosen in `docs/GUI.md`; localhost by default, LAN opt-in with a password | 4 | planned | |
| KeX client (in-app) | — | Research gate: Termux:X11 companion, an embedded X/Wayland server (GPL-3.0 now allows embedding Termux:X11 code), or Xvnc + an F-Droid VNC client as the fallback | 4 | planned | |
| Audio (stream to KeX, 127.0.0.1:8000) | — | Bridge (PulseAudio/PipeWire → AAudio/OpenSL in the app) by default, ALSA takeover as route B; wired into GUI sessions | 3, 4 | planned | |
| HDMI / cast, Termux:X11 | — | Part of the Phase 4 display research | 4 | planned | |
| — (beyond NetHunter) **Linux GUI apps** | — | App mode (one Linux app per Android window where possible), GPU acceleration (Turnip + Zink on Adreno; others researched), input/IME/clipboard, `.desktop` apps pinned as launcher shortcuts; acceptance: Wireshark live capture, GIMP, a browser, gqrx, Ghidra, an editor, glmark2/vkcube | 4 | planned | |
| **Hardware** | | | | | |
| USB Arsenal: USB function selector (RNDIS…), image mounter (mass storage) | — | configfs gadget: NCM/RNDIS where the kernel has them (S9: NCM, no RNDIS), ACM serial, mass storage of an image, generic HID keyboard/mouse as an input device; Android's gadget config saved and restored | 3 | planned | HID *payloads* stay out. |
| OTG wireless / SDR / Bluetooth adapters | `/dev` is bound, root sees it | `/dev/bus/usb`, `ttyUSB*`/`ttyACM*` for the user through the device access model (`uburoot-hw grant`) | 3 | planned | |
| MAC changer | Root can run `ip link set address` (shared netns) | A tool definition (Phase 5) with a warning that changing the MAC under Android's Wi-Fi drops the connection | 5 | planned | No dedicated screen. |
| — (beyond NetHunter) **Full hardware access** | — | `HARDWARE_ACCESS=1`: per class direct / bridge / takeover, documented in `docs/HARDWARE.md`: CPU/power/thermal (read thermal, never disable trips), GPU/display, input, audio, camera (Camera2 → V4L2/socket), sensors and location (→ IIO-like/gpsd), Wi-Fi (takeover + monitor where the phy supports it), Bluetooth, NFC, USB, buses read-only by default; `uburoot-hw` CLI and a Hardware screen | 3 | planned | Modem: report only, never AT/NV writes. |
| — (beyond NetHunter) **Full kernel access** | `KERNEL_ACCESS`, `uburoot-kernel`/`-kmod`/`-kbuild`, Kernel screen, change log reverted by Stop all | See the *Root and kernel* rows: kernel filesystems, modules, logs, tracing/eBPF, tunables, SELinux, out-of-tree modules, root-manager extensions, a Kernel screen | 2 | done | |
| **Offensive modules** | | | | | |
| HID keyboard attacks, DuckHunter, BadUSB MITM | — | — | — | out | Non-goal (HID/BadUSB payloads). |
| Mana, EvilTwin, Wifipumpkin, WPS attacks, Pineapple connector | — | — | — | out | Non-goal (rogue AP / captive portal / WPS). |
| Metasploit Payload Generator, SET | — | — | — | out | Non-goal (payload generators, social engineering). |
| Searchsploit, Nmap scan screens | — | Generic tool definitions (Phase 5); nmap bundled as an example | 5 | planned | |
| Bluetooth Arsenal, CARsenal, Wardriving | — | No dedicated screens; hardware access (Phase 3) and tool definitions (Phase 5) cover the platform side | 3, 5 | planned (platform) | Attack front-ends stay out. |
| Wi-Fi injection (custom kernel) | Doctor lists Wi-Fi phys and monitor support (S9: none) | Doctor lists monitor-capable phys; Wi-Fi takeover with monitor mode where the phy supports it; kernel build guide for drivers | 1, 3, 10 | done (report); planned | The S9's internal driver has no monitor mode. |
| **Store, devices, testing** | | | | | |
| NetHunter Store | — | — | — | out | Non-goal (app store). F-Droid and GitHub releases. |
| Supported device list (CI-generated kernel/image reports) | `docs/COMPATIBILITY.md` (S9 row) | `docs/COMPATIBILITY.md`: device, ROM, Android, root manager + version, result, doctor bundle | 1 | done | |
| Testing checklist (boot, apps, kernel version, HID, Metasploit, external Wi-Fi) | Checklist in `docs/COMPATIBILITY.md`; device suite runs the doctor | Checklist in `docs/` built from the suites, with doctor output | 1 | done | |
| Porting (kernel builder, patches) | — | Kernel build guide (docs + optional CI recipe) | 10 | planned | Not in the app. |

## Phase list (`prompt.md`, with the changes proposed here)

0. Gap analysis (this file). **0b.** Relicense to GPL-3.0-or-later (v0.3.0).
1. **Install hardening and diagnostics**: doctor with kernel report and hardware inventory
   (and who owns each device), rootfs schema + migrations, wake lock / mirror / offline
   install, `COMPATIBILITY.md` + testing checklist. **Plus** the full-root gate in the
   preflight (the user's "require full kernel access"): a restricted root is refused with
   the reason, instead of failing later.
2. **Full kernel access** (`KERNEL_ACCESS`): kernel filesystems, modules, logs,
   tracing/eBPF, tunables, SELinux, out-of-tree modules, root-manager extensions, Kernel
   screen. The binds measured as missing above land here, behind the toggle (not always
   on, as an earlier draft of this file proposed).
3. **Full hardware access** (`HARDWARE_ACCESS`), `docs/HARDWARE.md`, Hardware screen.
4. **Linux GUI apps**: research gate (`docs/GUI.md`) first, then app/desktop modes, GPU,
   audio, input, launcher shortcuts, acceptance apps.
5. **Native tool front-ends** (declarative).
6. **Chroot manager**: backup, restore, verify, move, profiles, release upgrade.
7. **Services and custom commands.**
8. **Status home screen**, plus *Android shell* / *Android root shell* session types.
9. **Architectures and Android versions.**
10. **Kernel manager** (backup, flash, keep root, restore), each device run approved first.
11. **Updates, settings backup, documentation.**
- Optional: rootless decision document. Given that the user requires full kernel access,
  the expected outcome is "a separate app, not this one". Kept short.
