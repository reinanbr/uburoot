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

## Part 2: GPU, sound, clipboard, packages (2026-11-16)

### GPU: Turnip with the KGSL backend (`gpu.sh`, `tools/gpu/build-turnip.sh`)

- Ubuntu 26.04's Mesa (26.0.8-1ubuntu0.3) has Turnip, but only with the upstream `msm`
  kernel backend: `debian/rules` doesn't set `freedreno-kmds`, and Mesa's default is
  `['msm']` (`meson.options:223`), so `tu_knl_kgsl.cc` isn't built
  (`src/freedreno/vulkan/meson.build:116`). Android's Adreno driver is KGSL
  (`/dev/kgsl-3d0`, `system:system 0666` on the S9). Result before: `vulkaninfo` and
  `glxinfo` showed only llvmpipe, and Zink said "failed to choose pdev".
- `tools/gpu/build-turnip.sh` cross-compiles only Turnip from Ubuntu's own source
  package (`apt-get source mesa`, same version and patches) with
  `-Dfreedreno-kmds=kgsl`, in an amd64 `ubuntu:26.04` container (2.5 min locally). It
  ships as a Vulkan ICD of its own: `/usr/local/lib/uburoot/gpu/libvulkan_freedreno_kgsl.so`
  and `/usr/local/share/vulkan/icd.d/uburoot_freedreno_kgsl_icd.json`. No dpkg file is
  touched. CI builds it for tags (and manual runs) and publishes
  `turnip-kgsl-arm64.tar.gz` with the release, listed in `SHA256SUMS`.
- **SONAME pitfall:** Ubuntu's `freedreno_icd.json` names its library by the bare
  `libvulkan_freedreno.so`. With our copy loaded under that same SONAME, glibc handed
  ours back for it, and every app saw the GPU twice. `patchelf --set-soname` fixes it.
- `gpu.sh install FILE SHA256` checks the hash and that the archive holds only those
  regular files, then writes each one itself (`tar -O`), root-owned. It turns Zink on
  (`/etc/uburoot/gpu.env` = `MESA_LOADER_DRIVER_OVERRIDE=zink`, read by the login hook).
  The *Linux apps* screen downloads the release's file after a tap and checks it
  against `SHA256SUMS`. It can also turn Zink off, show the renderer and remove the driver.
- S9 (Adreno 630, kernel 4.9): `vulkaninfo` → "Turnip Adreno (TM) 630", Vulkan 1.3.335,
  conformance 1.2.7.1. `glxinfo -B` → "zink Vulkan 1.3(Turnip Adreno (TM) 630
  (MESA_TURNIP))", OpenGL 4.6.
- glmark2 2023.01 on the S9:

  | Run | llvmpipe | Zink on Turnip |
  |-|-|-|
  | Off-screen 1280x720 (terrain/refract/shadow/jellyfish) | 24 | **223** (terrain 2 → 88 FPS) |
  | Full screen 720x1420 (terrain/refract/jellyfish) | 9 | **36** (terrain 3 → 38 FPS) |
  | Window 640x480 (simple scenes) | 51 | 43 |

  On screen every frame is copied into the X server by the CPU (no DRI3 path to
  Termux:X11; `MIT-SHM` is missing too: Android kernels have no SysV IPC, "shmget():
  Function not implemented"), which caps it near 40–45 FPS. Heavy 3D still runs about
  10× faster. Light 2D apps don't gain. vkcube: 300 frames in 6.4 s.
- Other GPUs (Mali, PowerVR…): no KGSL, so `gpu=none` and llvmpipe. Panfrost needs the
  upstream kernel driver, which Android kernels don't have. Not researched further
  without such a device.

### Sound

- `x11.sh run` starts the user's PulseAudio (`pulseaudio --start`, no systemd needed)
  with `uburoot-audio pulse` (Phase 3: a pipe sink "android" made the default) when
  PulseAudio is installed and the app's audio bridge is on (Hardware > Bridges, with
  the user granted `audio`). `x11.sh status` says `audio=missing|bridge-off|ready`.
  Ubuntu 26.04 defaults to PipeWire, whose daemons expect a systemd user session.
- S9: a 440 Hz tone from `pacat` as `ana` became an active AudioFlinger track of the
  UbuRoot process (48 kHz stereo).

### Clipboard and keyboard

- Termux:X11 syncs the clipboard itself (`clipboardEnable=true`). Android → X:
  `uburoot-clip` text came out of `xclip -o -selection clipboard`. X → Android: the
  activity logged "Clipboard content (16 symbols) is x11-to-android-2".
- `input text` (Android key events) typed into Mousepad.

### Session bus and runtime dir

- No systemd/logind means no `XDG_RUNTIME_DIR` and no session bus. GNOME apps failed
  ("Failed to execute child process dbus-launch"). The login hook now sets
  `XDG_RUNTIME_DIR=~/.cache/uburoot/run` (0700). `x11.sh run` starts one
  `dbus-daemon --session` per user there (`bus`, `bus.pid`), and the hook exports
  `DBUS_SESSION_BUS_ADDRESS` while it is alive.

### Packages that can't work in a chroot

- **Snaps.** Ubuntu's `firefox`, `chromium-browser` and `thunderbird` are `1:1snap1…`
  debs. They Pre-Depend on snapd, and their preinst runs `snap install`. Without
  systemd it retries the store every minute for 30 minutes, then exits 1. `setup.sh`
  (and migration 3) writes `/etc/apt/preferences.d/80uburoot-no-snap`: version `/snap/`
  of those three and every snapd at priority -1. So `apt install firefox` says "no
  installation candidate" at once. Version pins need package names (`Package: *` takes
  only release/origin pins), and a trailing `*` makes APT do a prefix match
  (`*snap*` matched nothing), hence the `/snap/` regex.
- **Browser sandboxes.** The kernel refuses new user namespaces to a chrooted process
  (`create_user_ns` checks `current_chrooted()`): on the S9 `unshare -U true` fails
  inside Ubuntu even as root and works outside. bubblewrap-based sandboxes therefore
  can't start: Epiphany/WebKitGTK stops with "bwrap: No permissions to create a new
  namespace". Running a browser without its sandbox is the user's decision
  (`WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1` for WebKitGTK); UbuRoot doesn't set it.
  Firefox from Mozilla's own APT repository (a source the user adds) is the usual
  alternative: not tested here.

### Acceptance apps (S9)

| App | Result |
|-|-|
| Wireshark 4.6.4 | live capture on wlan0 as `ana` (group `wireshark`) |
| GIMP 3.2.2 | full screen, tools/brushes/layers usable by touch |
| Mousepad 0.7.0 | full screen, typing from Android works |
| glmark2 / vkcube | GPU path, numbers above |
| Epiphany 49.2 | blocked by its sandbox (above) |
| Firefox 160 (Mozilla's repository) | runs; HTTPS page loaded; content processes under seccomp (part 3) |
| Ghidra | not packaged by Ubuntu (upstream zip + JDK 21): not tested |
| gqrx 2.17.7 | needs an RTL-SDR dongle: not tested |

### Still open

- DRI3/zero-copy presentation, embedding Termux:X11 (one Android task per Linux app).

## Part 3: switching apps, desktop mode, Firefox (2026-11-16)

### Switching between open apps

- matchbox shows one window at a time and has no switcher of its own once its title
  bar is off. It does implement EWMH: `_NET_CLIENT_LIST`, and `_NET_ACTIVE_WINDOW` /
  `_NET_CLOSE_WINDOW` sent to the root window (`ewmh_handle_root_message` in
  matchbox-window-manager 1.2.3's `src/ewmh.c`). So `wmctrl` (now installed by
  `x11.sh setup`) lists, raises and closes windows. xfwm4 supports the same.
- `x11.sh windows USER` lists the open windows as `WINDOW|ID|TITLE`. Each one is matched
  to its desktop entry by WM_CLASS against the entry's `StartupWMClass`, its id, its
  Exec program, then the id's last part. On the S9: Wireshark, Mousepad, GIMP (and its
  welcome dialog), Firefox all matched.
- Like an Android app, opening an app that already has a window brings that window to
  the front instead of starting it again: `x11.sh run` does it for the *Linux apps*
  screen and the home screen shortcuts alike (0.8 s on the S9).
- The *Linux apps* screen lists the open windows (tap: front, ✕: close; the app may
  still ask to save).
- One Android task per Linux app (the spec's "app mode" ideal) needs a display path
  with a surface per window. Termux:X11 has one surface, so it waits for embedding.

### Desktop mode: XFCE

- XFCE over LXQt. On a clean Ubuntu 26.04 rootfs, without recommends:
  `xfce4 xfce4-terminal` = 211 packages, 90 MB to download; `lxqt-core qterminal` =
  318 packages, 156 MB. XFCE is GTK, like GIMP, Mousepad and Wireshark's own deps
  already pull in. On the S9 (with GIMP installed) it was 46 packages, 8 MB. The running
  session took 9 processes, 199 MB RSS.
- `x11.sh setup desktop` installs it; `x11.sh desktop USER` stops matchbox and runs
  `startxfce4` as the user (with the session bus from part 2, so it starts no
  `dbus-launch` of its own). The windows already open stay open: they show up in the
  panel's window list. Apps opened from the *Linux apps* screen meanwhile appear as
  windows (no matchbox is started while another WM runs). *Stop the display* ends it.
  Started in 4.8 s on the S9.
- Localhost only: the X server listens on a Unix socket inside the rootfs, never on the
  network. LAN access (VNC with a password, as the spec allows as an opt-in) is not
  done.
- The panel clock shows UTC: Ubuntu's `/etc/localtime` is UTC and Android's time zone
  (`persist.sys.timezone`) isn't carried over yet.

### Firefox from Mozilla's repository

- `x11.sh mozilla` (or `x11.sh firefox`, which also installs it) runs only when the user
  asks (the *Linux apps* screen's button). It installs `ca-certificates` (Ubuntu Base has
  none, and the repository is HTTPS-only), then writes:
  - `/etc/apt/keyrings/packages.mozilla.org.asc`: the key from
    `https://packages.mozilla.org/apt/repo-signing-key.gpg`, embedded in the script.
    Fingerprint `35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3`, as Mozilla's post
    "Firefox Developer Edition and Beta: Try out Mozilla's .deb package!" (hacks.mozilla.org,
    2023-11) publishes it; RSA 2048 from 2021, no expiry. `gpgv` verified the repository's
    `InRelease` with it (2026-11-16).
  - `/etc/apt/sources.list.d/mozilla.sources`: `https://packages.mozilla.org/apt`,
    suite `mozilla`, component `main` (the `Release` file lists `all amd64 arm64`).
  - `/etc/apt/preferences.d/80uburoot-mozilla`: `firefox*` from that origin at 1000, so
    the repository can't replace anything but Mozilla's own packages.
- S9: `firefox 160.0~build1` arm64, 84 MB, from packages.mozilla.org; Ubuntu 26.04's apt
  accepted the key. Firefox opened full screen. Its sandbox logged
  `CanCreateUserNamespace() clone() failure: EPERM` and went on without that layer: the
  8 child processes run with a seccomp filter (`Seccomp: 2`), the main process doesn't
  (as anywhere). A headless run in a throwaway profile loaded `https://example.com/`.
  The first-run screen asks to accept Mozilla's terms: left to the user.
- CJK text shows as boxes until a font such as `fonts-noto-cjk` is installed.
- To remove it: `apt remove firefox`, then delete the three files above.
