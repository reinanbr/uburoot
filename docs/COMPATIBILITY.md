# Compatibility

UbuRoot needs an **arm64** phone with a root manager (Magisk, KernelSU or APatch) that
gives **full root**: uid 0 with every capability, no seccomp filter, no `no_new_privs`,
and `su --mount-master` reaching the init mount namespace. The app checks this before
installing and refuses a restricted root (for example a KernelSU App Profile with fewer
capabilities) with the reason. Everything else (kernel features, hardware) is reported
by the doctor, and what's missing is explained rather than assumed.

## Tested devices

Add a row when you test a device (see the checklist below), and link the redacted doctor
report (a gist, or the issue/PR where you posted it).

| Device | SoC | ROM | Android | Kernel | Root manager | UbuRoot | Result | Doctor report |
|--------|-----|-----|---------|--------|--------------|---------|--------|---------------|
| Samsung Galaxy S9 (SM-G9600, `starqltechn`) | Snapdragon 845 / Adreno 630 | LineageOS 19.1 | 12 | 4.9 (vendor, not GKI) | Magisk 31.1 | 0.3.0-dev | Everything in the checklist passes. Not tested: recovery install, FBE boot wait (`/data` is unencrypted) | maintainer's runs, summarized in `CLAUDE.md` |

Not tested on any device yet: KernelSU, APatch, Android 13 or newer, GKI kernels,
Mali GPUs, encrypted (FBE) `/data` with boot start.

## Device testing checklist

Modelled on Kali NetHunter's. Each item names the automated check where there is one.
Commands run from a computer with `adb` and the repository checked out.

### 1. Root and preflight
- [ ] Root manager and version, Android version, ROM noted.
- [ ] Doctor (Settings → Diagnostics → Run diagnostics) shows `full root: [ok]` and
      `mount namespace: [ok] global`. Save the redacted report for the table.
- [ ] The app asked for root once and the preflight passed.

### 2. Install
- [ ] Online install: discover → download → SHA256 → extract → setup → terminal.
- [ ] Turn the screen off, or switch apps, during the download: the install
      continues (wake lock; the screen stays on while the app is open).
- [ ] Kill the app during extraction, then reopen it: it resumes, or starts over cleanly.
- [ ] Offline install (*Advanced* in the install form): a `.tar.gz` or `.tar.xz` from
      `cdimage.ubuntu.com` picked from storage, with and without its SHA256.
- [ ] An existing install from an older UbuRoot is migrated on start (doctor:
      `integration schema: [ok] 1`).

### 3. Automated suites
- [ ] `tests/device/run.sh -s SERIAL`: mounts and propagation, wrappers, the user's
      sudo/network/storage, a sabotaged reset, umount back to the baseline, root
      quality and doctor. It needs a finished install (the app's is fine).
- [ ] `tests/device/session-test.sh` inside an app terminal (usage in its header): tty
      and job control, sudo, DNS/apt/HTTPS/ICMP, storage groups, read-only Android
      partitions, binder tools, package database checks.
- [ ] Optional: `tests/device/advanced-test.sh` (developer and network tools).

### 4. Terminal
- [ ] Tabs, root session, extra keys (sticky CTRL), links, themes, font size.
- [ ] Hardware keyboard: Ctrl+Shift+C/V/T.
- [ ] Closing a tab ends its processes (`ps` in another tab).
- [ ] *Stop all* closes every session and unmounts in a few seconds.

### 5. Android integration
- [ ] `uburoot-notify`, `uburoot-toast`, `uburoot-vibrate`, `uburoot-clip`,
      `uburoot-open FILE|URL`, as the user and as root, with the app in the background.
- [ ] Share a file and a text to *Open in UbuRoot*.
- [ ] `am`, `pm`, `settings get`, `dumpsys battery` through `sudo`.

### 6. Boot module
- [ ] Install the APK as a module from the root manager, enable *Start at boot*, put a
      script in `/etc/uburoot-boot.d/`, reboot: it ran (`/data/local/uburoot/boot.log`).
- [ ] On an encrypted phone, it waits for the first unlock.

### 7. Host integrity (the safety rule)
- [ ] After *Stop all*, `adb shell su -c 'cat /proc/1/mountinfo'` matches the snapshot
      taken before the first session (the device suite checks this automatically).
- [ ] Android's Wi-Fi, Bluetooth, camera and audio still work afterwards.

### 8. Report
- [ ] Add a row to the table above (or open an issue with the doctor report and the
      checklist results).
