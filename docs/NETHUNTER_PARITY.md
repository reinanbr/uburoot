# NetHunter parity

What Kali NetHunter offers for installing and managing its chroot, and what UbuRoot has or
plans instead. UbuRoot is a general-purpose Ubuntu for rooted, de-Googled phones (F-Droid),
not a pentest distribution: it provides the platform, and users install tools with `apt`.

**Edition:** UbuRoot is **root-only, with full kernel access**. It requires a root that
really is root, and it gives Ubuntu's root the kernel interfaces that root has on the host.
In NetHunter terms it sits between *Lite* (any Magisk-rooted phone, stock kernel) and
*Full* (but it never builds or flashes kernels). There is no rootless edition.

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
| Pre-built image per device (custom kernel + chroot) | One APK for every arm64 device | — | — | out | No custom kernels (non-goal). The app adapts to the stock kernel and reports what it supports. |
| Generic installer zip per architecture (arm64, armhf, i386, amd64) | arm64 Ubuntu Base only | armhf and amd64 where the device ABI allows it, arm64 stays the default | 6 | planned | i386: to check in Phase 6 whether Canonical still publishes an i386 Ubuntu Base. |
| Magisk module ("new and recommended") | The APK is also a module: Magisk, KernelSU, APatch (`customize.sh`); verified with Magisk 31.1 | Keep | — | done | |
| Recovery (TWRP) zip | The same file flashes in TWRP for Magisk (`update-binary` → `install_module`) | Keep | — | partial | Not tested on a device. The S9 has TWRP, but the user chose to skip the test because the Magisk path works. |
| Rootless edition (Termux + proot, NetHunter Store) | None | None | — | out | The user decided UbuRoot requires root with full kernel access. Without root, the mounts, `/sdcard` and `/data` binds, raw sockets, iptables, boot start and the Android bridge don't work. That would be a different app. |
| Pre-install guidance (unlock, root, developer options, disable force encryption) | README: root manager, arm64 | `docs/INSTALLING.md`. No step to disable encryption: UbuRoot works on encrypted `/data`, and the boot script waits for the first unlock | 8 | planned | |
| SHA256 check of the download | `SHA256SUMS` from cdimage, checked after download, one re-fetch | Keep | — | done | |
| "Keep the screen awake while installing, Android may kill the app" | No wake lock during install (only sessions have one); resumes after a kill | Wake lock + `FLAG_KEEP_SCREEN_ON` during download/extract | 1 | planned | |
| Install from local storage | Download only | Local `.tar.gz` / `.tar.xz` picked with SAF, optional SHA256 | 1 | planned | |
| Mirror choice | Fixed `ports.ubuntu.com` | Choose a `ports.ubuntu.com` mirror | 1 | planned | |
| Full vs minimal chroot (kalifs-full / kalifs-minimal) | Ubuntu Base (minimal) + `setup.sh` | Profiles applied with `apt` after install (minimal, development, network tools, desktop); lists in a versioned asset | 2 | planned | |
| Update channels (quarterly release, weekly, daily builds; Store for the app) | GitHub releases; per-commit CI artifacts; F-Droid recipe ready (MR pending) | Optional update check in a non-F-Droid flavor, off by default | 8 | planned | |
| **Root and kernel** | | | | | |
| Lite needs Magisk root; Full needs a device kernel | Needs root in the init mount namespace (preflight compares `mnt_ns`) | **Require full root**: uid 0, `CapEff` = every capability up to `cap_last_cap`, `NoNewPrivs 0`, `Seccomp 0`, init mount namespace, and a domain that can mount. Refuse with an explanation otherwise (e.g. a restricted KernelSU App Profile; to verify in its source) | 1 | planned | |
| Kernel interfaces available to Kali root | Not visible in the chroot (see the gap above) | Ubuntu's root gets the host's configfs (`/config` → `/sys/kernel/config`), debugfs, tracefs, bpffs and `/lib/modules/$(uname -r)` (module dirs of the ROM), as rslave binds covered by `umount.sh` and the host-identical check | 1 | planned | |
| Kernel features (HID, OTG Wi-Fi, CD-ROM emulation, SDR, y-cable charging, kexec) | — | `uburoot-doctor` kernel capability report (`/proc/config.gz`, or probing) | 1 | planned | Adding features to the kernel = building kernels (non-goal). |
| Kernel: search, download, flash | — | — | — | out | Non-goal (building/flashing kernels). |
| Modules: load modules | Root can run `insmod` by hand | List loaded/available modules; `modprobe` works in Ubuntu (Phase 1 `/lib/modules`); app action behind the advanced warning | 7 | planned | |
| SELinux status toggle (Settings) | Doctor-to-be reports it | Report only | 1 | out (toggle) | `setenforce 0` lowers the whole phone's security, and UbuRoot doesn't need it (the root domain already passes). Ubuntu's root can still run it. |
| **Chroot manager** | | | | | |
| Download and install | Discover newest LTS, download, verify, extract, `setup.sh`, resume after a kill | Keep | — | done | |
| Backup | — | `backup.sh` (unmounted, or one-file-system with every bind excluded), numeric owners, xattrs, compression choice, SAF target, manifest + SHA256 | 2 | planned | |
| Restore | — | `restore.sh`: verify manifest, extract to `rootfs.partial`, atomic rename, old rootfs only through `ubu_safe_rm` | 2 | planned | |
| Remove | *Reset Ubuntu* (`reset.sh --yes`, typed `DELETE`/`APAGAR`, `ubu_safe_rm`) | Keep, move to the manager screen | 2 | done | |
| Install metapackages | `apt` by hand | Profiles (see above) | 2 | planned | |
| — (no NetHunter equivalent) | — | Verify (`dpkg --verify` report), move to another ext4/f2fs location, release upgrade to the next LTS | 2 | planned | |
| Rootfs versioning / upgrades of integration files | `setup.sh` reruns are idempotent | `/etc/uburoot-release` + numbered migrations | 1 | planned | |
| **Services and commands** | | | | | |
| Kali Services: start/stop SSH, Apache, OpenVPN…, enable at boot | `/etc/uburoot-boot.d/` scripts run by the boot module | `uburoot-svc` (pidfiles, logs, definitions in `/etc/uburoot/services.d/`), `enable` = the boot.d mechanism; Services screen | 3 | planned | |
| Default `toor` password warning | No default password: the user picks one in the install form (or passwordless sudo, opt-in) | sshd example service requires a key or the user's own password | 3 | done | |
| Custom Commands (buttons, preconfigured examples) | — | User commands in a new tab or in the background with a result notification; launcher shortcuts and a Quick Settings tile | 3 | planned | |
| **App screens** | | | | | |
| Home screen: external/internal IPs, HID interface status | Preflight → terminal | Status home: mounted state, sessions, services, interfaces and addresses, rootfs disk use, kernel capability summary, quick actions | 4 | planned | HID status: only as part of the capability summary (no HID features). |
| "Attacks greyed out if the chroot is not running" | — | Home actions reflect the mounted state | 4 | planned | |
| Terminal: Kali chroot, Android shell, Android root shell | Chroot sessions as the user or as root; tabs, extra keys, themes | Add *Android shell* and *Android root shell* session types | 4 | planned | |
| Hacker's Keyboard | Extra keys rows (ESC, CTRL, ALT, arrows…), hardware keyboard shortcuts | Keep | — | done | |
| Settings: terminal style | Themes, font size | Keep | — | done | |
| Settings: backup/restore `nh_files` | — | Export/import app settings + `uburoot.conf` + services + custom commands | 8 | planned | |
| Settings: custom boot animation | — | — | — | out | Changes the ROM's look, unrelated to the chroot. |
| **Desktop and audio** | | | | | |
| KeX: VNC desktop with password, start/stop, custom resolution, HDMI/cast | — | `uburoot-desktop`: lightweight desktop + TigerVNC on 127.0.0.1, password required, resolution/DPI; LAN opt-in with a warning | 5 | planned | |
| KeX client (in-app) | — | Hand off to an F-Droid VNC client by intent; explain when none is installed | 5 | planned | Own VNC client: duplicating AVNC/bVNC adds maintenance and nothing for F-Droid users. |
| Audio (stream to KeX, 127.0.0.1:8000) | — | Research PulseAudio/PipeWire → Android output; ship only what works on the test phone | 5 | planned | |
| HDMI / cast, Termux:X11 | — | Research notes only, then a decision | 5 | planned | |
| **Hardware** | | | | | |
| USB Arsenal: USB function selector (RNDIS…), image mounter (mass storage) | — | configfs gadget: NCM (S9 kernel has no RNDIS), ACM serial, mass storage of an image; Android's own gadget config saved and restored | 7 | planned | |
| OTG wireless / SDR / Bluetooth adapters | `/dev` is bound, root sees it | `/dev/bus/usb`, `ttyUSB*`/`ttyACM*` access for the user, documented | 7 | planned | |
| MAC changer | Root can run `ip link set address` (shared netns) | — | — | out | Android 10+ already randomizes the Wi-Fi MAC per network, and changing it under `wpa_supplicant` drops the connection. A UI adds risk for little gain. |
| **Offensive modules** | | | | | |
| HID keyboard attacks, DuckHunter, BadUSB MITM | — | — | — | out | Non-goal (HID/BadUSB payloads). |
| Mana, EvilTwin, Wifipumpkin, WPS attacks, Pineapple connector | — | — | — | out | Non-goal (rogue AP / captive portal / WPS). |
| Metasploit Payload Generator, SET, Searchsploit, Nmap scan screens | — | — | — | out | Non-goal (payload generators) or tool front-ends: `apt install nmap exploitdb …` works in Ubuntu. |
| Bluetooth Arsenal, CARsenal, Wardriving | — | — | — | out | Tool front-ends. The doctor reports BT/CAN support, and the tools come from `apt`. |
| Wi-Fi injection (custom kernel) | — | Doctor lists monitor-capable phys (`iw phy`) | 1 | planned (report) | Injection support needs kernel patches (non-goal). The S9's driver has no monitor mode. |
| **Store, devices, testing** | | | | | |
| NetHunter Store | — | — | — | out | Non-goal (app store). F-Droid and GitHub releases. |
| Supported device list (CI-generated kernel/image reports) | Tested: S9 / LineageOS 19.1 / Magisk 31.1 (CLAUDE.md) | `docs/COMPATIBILITY.md`: device, ROM, Android, root manager + version, result, doctor bundle | 1 | planned | |
| Testing checklist (boot, apps, kernel version, HID, Metasploit, external Wi-Fi) | Device suites: `checks.sh`, `session-test.sh`, `advanced-test.sh` | Checklist in `docs/` built from the suites, with doctor output | 1 | planned | |
| Porting (kernel builder, patches) | — | — | — | out | Kernel work (non-goal). |

## Proposed phase list (changes from `prompt.md`)

1. **Phase 1: install hardening, diagnostics and full kernel access.** As in the spec
   (doctor, `/etc/uburoot-release` + migrations, install wake lock / mirror / offline
   install, `COMPATIBILITY.md`), **plus**:
   - a root-quality gate in preflight and the doctor (full capability set, no seccomp,
     no `NoNewPrivs`, init mount namespace, a domain that can mount), so a restricted
     root is refused with a clear reason instead of failing later;
   - the host's kernel interfaces inside the chroot: configfs (`/config` on older Android,
     `/sys/kernel/config` on newer), debugfs, tracefs, bpffs, and `/lib/modules/$(uname -r)`
     pointing at the ROM's module directories. These are rslave binds, unmounted by
     `umount.sh` and covered by the Docker suite and the host-identical check;
   - the testing checklist (from the existing device suites) next to `COMPATIBILITY.md`.
2. **Phase 2: chroot manager.** Unchanged. *Remove* already exists, so it only moves.
3. **Phase 3: services and custom commands.** Unchanged.
4. **Phase 4: status home screen**, plus *Android shell* / *Android root shell* session
   types (NetHunter Terminal parity, small).
5. **Phase 5: desktop.** Unchanged.
6. **Phase 6: architectures and Android versions.** Unchanged.
7. **Phase 7: hardware.** The kernel-interface binds and `/lib/modules` move to Phase 1.
   This phase keeps the module list, the explicit `modprobe` action, USB gadget (NCM
   instead of RNDIS where the kernel lacks it) and OTG access.
8. **Phase 8: updates, settings backup, docs.** Unchanged (plus `docs/INSTALLING.md`).
9. **Rootless research: dropped.** UbuRoot requires root with full kernel access, and the
   reasons are recorded in the table. No `docs/ROOTLESS.md`.
