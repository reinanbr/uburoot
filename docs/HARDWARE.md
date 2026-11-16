# Hardware access

`HARDWARE_ACCESS=1` (Settings → *Hardware access*, behind a warning) gives Ubuntu the
phone's hardware where the kernel allows it. It is off by default. It adds **no
mounts**: `/dev` and `/sys` are already the phone's own (see the mount design in
`CLAUDE.md`). What it adds:

- `uburoot-hw` inside Ubuntu (and `hardware.sh` on the Android side, used by the app):
  per-class reports, group grants, permission rules for hot-plugged devices, the Wi-Fi
  takeover, CPU limits, a wake lock, LEDs and bus nodes;
- the Hardware screen (terminal menu → *Hardware*).

Every change goes to the same change log as `uburoot-kernel`
(`/data/local/uburoot/state/changes`, `/run/uburoot/state/changes` inside Ubuntu).
*Stop all*, *Revert changes* (Kernel or Hardware screen) and a reboot undo it.

## Safety floor

No option changes these:

- thermal trip points, charger and battery settings and voltages are read-only
  (`uburoot-hw set` only accepts `/sys/class/leds/NAME/brightness|trigger`);
- bus nodes whose device name looks like a PMIC, charger, regulator, fuel gauge or
  battery are refused by `uburoot-hw allow`;
- the modem is report-only (no AT or NV writes);
- `cpu online` never takes `cpu0` offline, and frequencies must come from
  `scaling_available_frequencies`.

## Routes

| Route | Meaning |
|-------|---------|
| direct | the kernel interface is free: Ubuntu uses the device node or sysfs file itself |
| bridge | Android owns the device through a HAL; Ubuntu gets it through the app (see Bridges) |
| takeover | Android is asked to stop using it, then Ubuntu uses the kernel interface |
| read | report only |
| none | no kernel interface on this phone |

## Classes

`uburoot-hw list` prints every class, `uburoot-hw info CLASS` its nodes, their owners and
which processes hold them open.

| Class | Route | Group (grant) | Notes |
|-------|-------|---------------|-------|
| gpu | direct | `aid_graphics` 1003 | `/dev/kgsl-3d0`, `/dev/dri/*`, `fb*`. A GPU driver for Ubuntu (Mesa freedreno on Adreno) is Phase 4 |
| input | direct | `aid_input` 1004 | `/dev/input/event*`. Reading them sees every touch and key, Android's too |
| uinput | direct | `aid_uhid` 3011 | `/dev/uinput`, `/dev/uhid`: virtual keyboards/mice |
| audio | bridge | `aid_audio` 1005 | `/dev/snd/*` is held by Android's audio HAL: `uburoot-audio`. USB audio cards work directly (ALSA) |
| camera | bridge | `aid_camera` 1006 | `video*`/`media*`/`v4l-subdev*` are the ISP's, held by the camera HAL: `uburoot-camera` |
| usb | direct | `aid_usb` 1018 | `/dev/bus/usb/*` (OTG host). ueventd gives them `root:usb 0660` |
| serial | direct | `dialout` 20 | `ttyACM*`, `ttyUSB*`: ueventd has no rule (root 0600), so a grant adds a **permission rule** |
| hidraw | direct | `plugdev` 46 | `hidraw*`: same, a permission rule |
| wifi | takeover | — | see below |
| bluetooth | none / bridge | — | see below |
| nfc | none | `aid_nfc` 1027 | see below |
| sensors | bridge | `uburoot-sensors` | Android's sensor HAL: `uburoot-sensors` |
| location | bridge | `uburoot-location` | Android's GNSS HAL: `uburoot-gps` |
| leds | direct | — | `uburoot-hw set /sys/class/leds/NAME/brightness V` (recorded) |
| cpu | direct | — | `uburoot-hw cpu governor|min|max|online` (recorded) |
| power, thermal, modem | read | — | battery, thermal zones and trips, modem nodes |
| buses | read | `uburoot-bus` | `i2c-*`, `spidev*`, `gpiochip*`: `uburoot-hw allow NODE` opens one (recorded) |

A grant is group membership (`usermod -aG`), so it applies to new sessions. Revoking
the last user of a rule class drops its rule.

**Permission rules.** Android's ueventd creates the nodes; the S9's `ueventd.rc` has no
rule for `ttyACM*`, `ttyUSB*` or `hidraw*`, so they are `root 0600`. A rule class's
nodes get its group and `0660` (each node's original owner and mode is recorded). A
watcher inside Ubuntu (`uburoot-hw watch`, every 2 s, started by `mount.sh` and by a
grant) does the same for devices plugged in later. `umount.sh` stops it, and the revert
puts every node back.

## Wi-Fi

Without a takeover Android keeps `wlan0` and `wpa_supplicant`; `iw dev`, `iw phy` and
`iw scan` (as root) still work beside it.

`uburoot-hw takeover wifi` records Android's state (`takeover wifi WIFI:SCAN`), then runs
`cmd wifi set-scan-always-available disabled` and `cmd wifi set-wifi-enabled disabled`
and waits for Android's Wi-Fi to stop. `wlan0` is then Ubuntu's: `ip link set wlan0 up`,
`iw dev wlan0 scan`, `wpa_supplicant`, `hostapd` (the S9's phy supports AP mode).
`uburoot-hw release wifi` (or *Stop all*) stops Ubuntu's `wpa_supplicant`, `hostapd`,
`dhclient`, `dhcpcd` and `iwd` (only processes whose executable is Ubuntu's, never
Android's `/vendor` binaries) and restores both settings.

S9 (2026-11-16): after the two `cmd wifi` calls `wlan0` went down, Android's
`/vendor/bin/hw/wpa_supplicant` exited and `phy0` stayed; Ubuntu's `ip link set wlan0 up`
and `iw dev wlan0 scan` saw the nearby networks. Supported interface modes: IBSS,
managed, AP, P2P. **No monitor mode** on this phone.

Tested on the S9 (2026-11-16) from the CLI and from the Hardware screen: Ubuntu's own
`wpa_supplicant` ran on `wlan0` after the takeover, and *Give back* stopped it; Android
then started its own again and Wi-Fi came back.

## Bluetooth and NFC (S9)

- **Bluetooth:** the chip (Broadcom BCM4361) sits on `ttyHS0` (the BT UART) and is
  driven by Android's Bluetooth stack in userspace. The kernel has no `BT_HCIUART`,
  `BT_HCIBTUSB` or `BT_HCIVHCI`, so BlueZ has no HCI device to use and a takeover is
  impossible. A bridge would have to go through Android's Bluetooth APIs (later). A USB
  Bluetooth dongle needs `BT_HCIBTUSB`, which is missing too.
- **NFC:** `/dev/sec-nfc` (Samsung driver) exists, but `CONFIG_NFC` is off: there is no
  kernel NFC subsystem for `neard`/libnfc. Report only.

## Bridges

Android keeps the speaker, microphone, cameras, sensors and GNSS receiver; the app
serves them to Ubuntu. Turn a bridge on in the Hardware screen (*Bridges*): the app asks
for the Android permission it needs (microphone, camera, location) and runs a foreground
service with a notification while any bridge is on. *Stop all*, *Repair mounts* and the
notification's *Turn off* end them.

| Command | What |
|---------|------|
| `uburoot-audio play [FILE]` | raw s16le PCM to the speaker (`UBU_RATE`, default 48000; `UBU_CHANNELS`, default 2) |
| `uburoot-audio record` | the microphone as raw s16le (mono by default) |
| `uburoot-audio pulse [--mic]` / `pulse off` | a PulseAudio sink `android` (and source `android_mic`) through `module-pipe-sink`/`-source` |
| `uburoot-camera list` | camera ids, facing, JPEG sizes |
| `uburoot-camera snap FILE.jpg [ID] [WxH]` | one photo (1.5 s of frames first, so exposure settles) |
| `uburoot-camera mjpeg [ID] [WxH]` | JPEG frames to stdout (`ffmpeg -f mjpeg -i -`) |
| `uburoot-sensors list` / `read KEY` / `stream KEY [HZ]` | `TIME_NS VALUE...` per reading; at most 200 Hz |
| `uburoot-gps nmea` / `fix` | NMEA sentences (for gpsd), or one position |

Examples:

```sh
ffmpeg -i song.mp3 -f s16le -ar 48000 -ac 2 - | uburoot-audio play
uburoot-audio record | ffmpeg -f s16le -ar 48000 -ac 1 -i - mic.wav
uburoot-camera mjpeg 0 640x480 | ffmpeg -f mjpeg -i - -c:v libx264 video.mp4
socat PTY,link=/tmp/gps0,raw EXEC:'uburoot-gps nmea' & gpsd -N /tmp/gps0
```

How it works: each bridge is an abstract Unix socket with a random name, opened by the
app. `hardware.sh bridge publish` writes its name and a random token to
`/run/uburoot-bridge/NAME` inside Ubuntu, `root:GROUP 0640` (GROUP = the class's:
`aid_audio`, `aid_camera`, `uburoot-sensors`, `uburoot-location`). So root and the users
granted the class (`sudo uburoot-hw grant camera ana`, new session) can read the token;
others are told to ask for the grant. The app also checks the caller's uid: root or a
chroot user (8000–9996), never another Android app. The client
(`/usr/local/lib/uburoot/bridge-client`) is perl-base, which Ubuntu Base has. Abstract
sockets live in the network namespace that Android and the chroot share. A Unix socket
avoids localhost TCP: netd drops uids ≥ 10000 (the app's) in restricted networking mode.

No virtual V4L2 camera: `v4l2loopback` would be an unsigned module, and the S9 has
`MODULE_SIG_FORCE=y`. MJPEG on stdout covers ffmpeg, OpenCV (`cv2.VideoCapture` on a
pipe through ffmpeg) and streaming.

## USB gadget

`uburoot-hw gadget on ncm|acm|hid|storage IMAGE [rw]`, `gadget off`, `gadget status`
(also on the Hardware screen, except storage). UbuRoot links functions into the config of
the gadget Android has bound, next to adb's `f1`, as `uburoot.ncm`, `uburoot.acm`,
`uburoot.hidkbd` + `uburoot.hidmouse` and `uburoot.storage`. It unbinds and rebinds the
UDC around each change (recorded as `takeover gadget GADGET:UDC`). Off, *Revert
changes* and *Stop all* remove the links, eject the image and bind again.

| Function | Phone side | Computer side |
|----------|-----------|---------------|
| ncm | `usb0` (`ip addr add 10.42.0.1/24 dev usb0; ip link set usb0 up`) | a CDC NCM Ethernet interface |
| acm | `/dev/ttyGS<port_num>` | `/dev/ttyACM*` |
| hid | `/dev/hidg0` keyboard (boot protocol, 8-byte reports), `/dev/hidg1` mouse (4 bytes) | a keyboard and a mouse |
| storage | an image file (read-only unless `rw`); never a block device | a USB disk |

**Never removes a function instance.** On the S9 (2026-11-16) the first version created
its own `ncm.uburoot` instance and removed it with `rmdir` at the end: the kernel
panicked (pstore `dmesg-ramoops-0`: `Unable to handle kernel NULL pointer dereference`,
`PC is at ncm_free_inst+0x1c/0x70`, call trace `ncm_free_inst ← ncm_attr_release ←
configfs_rmdir`, task `rmdir`; `sys.boot.reason=kernel_panic`). At the same moment init
was re-running its `sys.usb.config=adb` action (the UDC unbind restarts adbd's
FunctionFS), which removes `f1..f9`. So UbuRoot now uses Android's own instances
(`ncm.0`, `acm.0`, `mass_storage.0`: the S9's g1 has them) and only adds and removes
links. HID has no Android instance: `hid.uburootkbd`/`hid.uburootmouse` are created once
and stay, unlinked and inert, until a reboot. If `mass_storage.0` already exports a file
for Android, `storage` refuses. After the change: two full on/off cycles of
ncm + acm + hid + storage (an 8 MB image) with no panic; the computer saw CDC NCM, CDC
ACM, two HID interfaces, the read-only disk and ADB at once, and only ADB afterwards. adb
over USB stayed connected throughout.

The HID gadget is a keyboard and mouse for your own computer; UbuRoot ships no payloads
or scripts that type on their own.

## Other S9 findings (2026-11-16)

- GPU/display: `/dev/kgsl-3d0` `system:system 0666`, `/dev/dri/*` `root:graphics 0666`,
  `fb0` `root:graphics 0660`.
- Audio: 116 `/dev/snd/*` nodes, `system:audio`. Camera: `video*`, `media*`,
  `v4l-subdev*` `system:camera`. No UVC (`MEDIA_USB_SUPPORT` is off), so a USB webcam
  won't work.
- USB host drivers in the kernel: `USB_ACM`, `USB_SERIAL_FTDI_SIO`, `USB_SERIAL_PL2303`
  (no CP210x, no CH341), `SND_USB_AUDIO`, CDC/NCM/AX88179 Ethernet, `HIDRAW`, `UHID`,
  `INPUT_UINPUT`. `I2C_CHARDEV`, `SPI_SPIDEV`, `GPIO_SYSFS` are on; IIO is on but has no
  devices.
- CPU: `policy0` (cpus 0–3, 576–1766 MHz) and `policy4` (cpus 4–7, 826–2803 MHz),
  `schedutil`. Android's power HAL (`vendor.qti.hardware.perf@2.0-service`) and
  `thermal-engine` may change limits back.
- Battery: Samsung's driver exposes many `batt_tune_*` and voltage files: read-only by
  design.
- `rfkill` lists the BCM4361 Bluetooth, `phy0` and `brcmfmac-wifi`.

## Change log types

Besides `sysctl`, `selinux` and `module` (see `KERNEL.md`):

| Line | Revert |
|------|--------|
| `file PATH VALUE` | writes VALUE back (skipped if the file is gone: an offline CPU, an unplugged device) |
| `node PATH UID:GID:MODE` | `chown` + `chmod` back (skipped if the node is gone) |
| `wakelock NAME -` | writes NAME to `/sys/power/wake_unlock` |
| `takeover wifi W:S` | stops Ubuntu's Wi-Fi daemons, restores scanning and Wi-Fi |
| `takeover gadget GADGET:UDC` | unbinds, removes the `uburoot.*` links (ejects the image), binds the UDC again |
