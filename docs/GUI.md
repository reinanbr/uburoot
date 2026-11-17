# Linux GUI apps: display server research (Phase 4 gate)

Goal (`prompt.md`, Phase 4): open Wireshark (and GIMP, a browser, gqrx, Ghidra, an
editor) from the Android launcher and get a usable window, later with GPU acceleration,
audio, touch/keyboard/IME input and an external display.

Today Ubuntu has no display server at all: `wireshark` is installed on the S9 but Qt
finds no `DISPLAY` and exits. Something has to provide an X11 (or Wayland) server and
show it on the phone. Facts below were checked on 2026-11-16.

## Options

### (a) Termux:X11 as a companion app

- `termux/termux-x11`, **GPL-3.0**, active (last push 2026-11-16, nightly
  `1.03.01`, 5.1k stars). Distributed from GitHub releases only: **not on F-Droid**
  (`f-droid.org/api/v1/packages/com.termux.x11` → NOT_FOUND).
- A real X.Org server (`xserver` submodule, "lorie") runs in a process started with
  `app_process` from the app's APK; the Android activity shows its screen. Its README,
  section *Using with chroot environment*, documents exactly our case: run as root,
  `TMPDIR=<chroot>/tmp` (the X socket then appears as `/tmp/.X11-unix/X0` inside),
  `XKB_CONFIG_ROOT=<chroot>/usr/share/X11/xkb`, then
  `CLASSPATH=$(pm path com.termux.x11 | cut -d: -f2) app_process / com.termux.x11.CmdEntryPoint :0`.
  It also says "do not forget to disable SELinux" (`setenforce 0`); on our root, the
  root domain is already permissive (`u:r:magisk:s0`), so whether the activity can use
  the server's descriptors with SELinux enforcing has to be tested on the S9.
- Latency: shared memory + Android surface, no network, no encoding: the best of the
  three. Fullscreen display (one X screen), preferences for touch-as-mouse, extra keys,
  IME, `-legacy-drawing` for devices that show only a black screen.
- GPU: X server is software (pixman) on the Android side; Ubuntu clients can use Mesa
  (Turnip/Zink on Adreno) and present through DRI3 where the server supports it: to be
  researched in step 3 of Phase 4.
- External display: the activity can be moved to a secondary display (Android desktop
  mode / HDMI), as any activity.
- UbuRoot work: start/stop the server as root, `DISPLAY=:0` in sessions, a *Linux apps*
  screen and launcher shortcuts. The user installs a second APK.

### (b) The same X server embedded in UbuRoot

- Since 0.3.0 UbuRoot is GPL-3.0-or-later, so Termux:X11's code (GPL-3.0) can be forked
  into the app: the `lorie` Gradle module (native, NDK + CMake) and the activity.
- Build cost: ~16 C submodules (`xserver`, `libx11`, `pixman`, `libepoxy`, `xkbcomp`,
  `libxfont`, `libxtrans`, `xorgproto`, `libtirpc`, `bzip2`, …, see its `.gitmodules`)
  compiled for arm64 on every CI build and by F-Droid's builder (needs the NDK). Their
  updates must be followed (X server security fixes).
- Same runtime as (a), same `app_process` start, but `CLASSPATH` is UbuRoot's own APK:
  one app, F-Droid can ship it, no second signature. The Ubuntu side of (a) is reused
  unchanged, so (a) can be the first step towards (b).

### (c) TigerVNC (Xvnc) + an F-Droid VNC client

- Ubuntu 26.04 arm64 has `tigervnc-standalone-server` 1.15.0 (Xvnc), `xfce4` 4.20.1,
  `lxqt-core`, `xwayland` 24.1.10, `dbus-x11` (checked with `apt-cache policy` on the S9).
- Client: AVNC (`com.gaurav.avnc`, GPL-3.0, F-Droid 3.3.1) handles `vnc://` links
  (its manifest has `<data android:scheme="vnc" />`), so UbuRoot can open
  `vnc://127.0.0.1:5901` after starting Xvnc on localhost with a password.
- Latency and quality: encoding and a TCP round trip, noticeably worse for scrolling
  and video; no GPU path on the display (Mesa still works for off-screen rendering).
- Universal: works on every device, and from a computer on the LAN (opt-in, with a
  password) — the KeX equivalent.
- **On the S9 `restricted_networking_mode` is 1**: netd drops traffic of uids ≥ 10000
  that are not allowlisted. A VNC client app connecting to `127.0.0.1` may be blocked
  unless loopback is exempt; not tested yet.

## Comparison

| | (a) Termux:X11 companion | (b) embedded | (c) Xvnc + AVNC |
|-|-|-|-|
| Latency | best | best | worst (encoding, TCP) |
| Second app | yes (GitHub only) | no | yes (F-Droid) |
| F-Droid for UbuRoot | yes (nothing embedded) | yes, heavy native build | yes |
| Work in UbuRoot | small | large (fork + native build + upkeep) | small |
| GPU path | DRI3 to research | same | off-screen only |
| External display / LAN | secondary display | secondary display | LAN client, any display |
| Risk on the S9 | SELinux with enforcing (test) | same | restricted networking (test) |

## Recommendation

(a) now, then (b): the Ubuntu side, the start/stop scripts, `DISPLAY`, the *Linux apps*
screen and the shortcuts are the same for both; embedding later only changes where the
`CLASSPATH` points. (c) stays as the optional desktop for a computer on the LAN.

Not decided here: Desktop mode (XFCE vs LXQt), GPU (Phase 4 step 3), Wireshark capture
for a non-root user (`dumpcap` is `root:wireshark 0754` with file capabilities; how they
combine with `aid_net_raw`/`aid_net_admin` on an Android kernel is to be verified).

## Decision (owner, 2026-11-16): (a) now, (b) later

### What UbuRoot does (`x11.sh`, *Linux apps* screen)

- `x11.sh start`: mounts Ubuntu, finds Termux:X11 with `pm path com.termux.x11`, and
  runs its `CmdEntryPoint` as root with `TMPDIR=$ROOTFS/tmp` and
  `XKB_CONFIG_ROOT=$ROOTFS/usr/share/X11/xkb` (`--nice-name=uburoot-x11`, pid in
  `state/x11.pid`, log `state/x11.log`). It closes an open Termux:X11 activity first
  (`ACTION_STOP`): an activity still attached to an earlier server keeps that surface,
  the new server fails `eglCreateWindowSurface` ("BufferQueueProducer … already
  connected") and the screen freezes on the old frame (seen on the S9).
- On the first start only, Termux:X11's preferences are set for a phone
  (`am broadcast -a com.termux.x11.CHANGE_PREFERENCE`): `displayResolutionMode=scaled`,
  `displayScale` = density × 100 / 240 (S9: 480 dpi → 200, an X screen of 720×1420), and
  `touchMode=2` ("Simulated touchscreen": a tap is a click where you tap). The defaults
  (native 1440×2960 at 96 dpi, touch as a trackpad) made Wireshark tiny and hard to use.
  Later changes in Termux:X11's own preferences are kept.
- A window manager makes each app full screen, like an Android app:
  `matchbox-window-manager -use_titlebar no` (Ubuntu 1.2.3), installed by the screen's
  button (`x11.sh setup`, apt) and started as the user with the server. Without one, X
  windows open at their own size in the top-left corner and can't be moved.
- `x11.sh apps|icons|run`: GUI `.desktop` entries (system + the user's
  `~/.local/share/applications`; no `NoDisplay`, `Hidden` or `Terminal`), PNG icons from
  `hicolor`/`pixmaps`, and `run USER ID` (field codes stripped, started detached as the
  user with `DISPLAY=:0`). Every file read is checked to be inside the rootfs after
  symlinks. The launcher script lives in root-owned `/run/uburoot-x11` (0755).
- Login shells get `DISPLAY=:0` once the display has been used (`/etc/uburoot/x11`,
  profile hook, rootfs schema 2).
- `umount.sh` (Stop all, Repair mounts) stops the server: it lives outside the chroot
  but listens in its `/tmp`.
- App: menu → *Linux apps* (tap to open, hold to pin to the home screen with the app's
  icon). The shortcut opens `LaunchActivity` (no window), which runs `x11.sh run` and
  shows Termux:X11.

### Evidence (S9, LineageOS 19.1, Termux:X11 nightly 1.03.01, 2026-11-16)

- SELinux stayed **enforcing**: no denial; the activity logged "XCB connection is
  successfull" and the server "new surface applied". So the README's `setenforce 0` is
  not needed with Magisk (root runs in the permissive `u:r:magisk:s0`).
- Wireshark 4.6.4 opened as `ana`, full screen at 200 %, taps worked.
- Capture as a user: `dumpcap` is `root:wireshark 0754` with
  `cap_net_admin,cap_net_raw=eip` (Ubuntu's `wireshark-common/install-setuid=true`).
  File capabilities work on this Android kernel: after `usermod -aG wireshark ana` (a new
  login) `dumpcap -D` listed wlan0, rmnet*, any, lo… and captured 9 packets on wlan0;
  Wireshark showed live traffic per interface. Membership in `wireshark` means the user
  can sniff every app's traffic on the phone (Android and Ubuntu share the network
  namespace): the app does not add it by itself.
- The S9's Wi-Fi has no monitor mode (Phase 3): Wireshark sees this phone's own traffic,
  not other devices' Wi-Fi frames.
