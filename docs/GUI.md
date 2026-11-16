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
