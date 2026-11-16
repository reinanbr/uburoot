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
| bridge | Android owns the device through a HAL; Ubuntu gets it through the app (Phase 3b) |
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
| audio | bridge | `aid_audio` 1005 | `/dev/snd/*` is held by Android's audio HAL |
| camera | bridge | `aid_camera` 1006 | `video*`/`media*`/`v4l-subdev*` are the ISP's, held by the camera HAL |
| usb | direct | `aid_usb` 1018 | `/dev/bus/usb/*` (OTG host). ueventd gives them `root:usb 0660` |
| serial | direct | `dialout` 20 | `ttyACM*`, `ttyUSB*`: ueventd has no rule (root 0600), so a grant adds a **permission rule** |
| hidraw | direct | `plugdev` 46 | `hidraw*`: same, a permission rule |
| wifi | takeover | — | see below |
| bluetooth | none / bridge | — | see below |
| nfc | none | `aid_nfc` 1027 | see below |
| sensors | bridge | — | Android's sensor HAL (Phase 3b) |
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
