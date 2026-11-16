# Kernel access

UbuRoot can give root inside Ubuntu the phone kernel's own interfaces. It's off by
default. Turn it on in **Settings → Kernel → Kernel access** (a warning explains what it
allows), then **Repair mounts**. Users without `sudo` get nothing new.

Everything here works on the running kernel only. UbuRoot never flashes or changes the
kernel image (that is the separate kernel manager, a later phase).

## What you get

With `KERNEL_ACCESS=1`, `mount.sh` adds, inside Ubuntu:

| Path in Ubuntu | What | How |
|---|---|---|
| `/sys/kernel/config` | configfs (USB gadget, …) | bind of the host's (Android 12 mounts it at `/config`) |
| `/sys/kernel/debug` | debugfs | bind of the host's, else a new instance |
| `/sys/kernel/tracing` | tracefs (ftrace) | bind, else new |
| `/sys/fs/bpf` | BPF filesystem (netd's pinned maps are there) | bind, else new |
| `/sys/fs/cgroup` | cgroup v2 | bind |
| `/dev/{cpuset,cpuctl,memcg,stune,blkio,freezer}` | cgroup v1 controllers | bind, at the same paths as Android |
| `/sys/fs/pstore` | previous boot's console / panic log | bind, else new |
| `/sys/fs/selinux` | selinuxfs | bind |
| `/sys/kernel/security`, `/sys/fs/fuse/connections`, `/proc/sys/fs/binfmt_misc` | securityfs, fusectl, binfmt_misc | bind, else new, only if the kernel has it |
| `/usr/lib/modules/$(uname -r)/uburoot/…` | the ROM's kernel modules (`/vendor/lib/modules`, `/vendor_dlkm`, `/system_dlkm`, `/odm`, `/lib/modules`) | read-only binds, then `depmod` into the rootfs |
| `/usr/local/sbin/uburoot-kernel`, `uburoot-kmod`, `uburoot-kbuild` | the tools below | |

A bind is the host's instance: what you change there changes Android too (a USB gadget,
a cgroup, a tracing buffer). Every bind is a slave mount, so unmounting it in Ubuntu
never unmounts it on the host. *Stop all* and *Repair mounts* leave the host's mount
table exactly as it was (the device suite and the Docker suite check this).

## `uburoot-kernel`

Run it as root (`sudo uburoot-kernel …`). Every change is **recorded** with the value it
replaced, in `/data/local/uburoot/state/changes`, and undone by:

- `uburoot-kernel revert` (or *Revert changes* on the Kernel screen),
- *Stop all*,
- a reboot (nothing is written to persistent storage; a log from an earlier boot is
  discarded).

Only the first change of each setting is recorded, so a revert goes back to the value
from before UbuRoot touched it. Changes are undone newest first.

| Command | Does |
|---|---|
| `status` | access on/off, SELinux mode, the restrict sysctls, recorded changes |
| `sysctl NAME [VALUE]` | read, or set and record, `/proc/sys/NAME` |
| `devmode on\|off` | `kernel.kptr_restrict` down to 1 (root can read kernel addresses) |
| `selinux [enforcing\|permissive]` | switch SELinux for the **whole phone** (asks first; `-y` skips) |
| `module list` | loaded modules; `*` = loaded through UbuRoot |
| `module load FILE.ko\|NAME [ARGS]` | `insmod` a file, or `modprobe` a ROM module by name (inside Ubuntu); recorded |
| `module unload NAME [--force]` | `rmmod` |
| `lastlog` | the previous boot's kernel log (pstore, `/proc/last_kmsg`) |
| `revert` | undo every recorded change |

`uburoot-kmod ARGS` is `uburoot-kernel module ARGS`.

Changes made **by hand** (`echo … > /proc/sys/…`, plain `insmod`, `setenforce`) are not
recorded and are not undone by *Stop all*. They still go away at the next reboot.

## The Kernel screen

Menu → **Kernel**: the current state, developer mode, the SELinux switch (with the
strongest warning), recorded changes with *Revert changes*, loaded modules (unload for
the ones loaded through UbuRoot), the live kernel log (`dmesg -w` in a root tab), the
previous boot's log, and the kernel part of the doctor report.

## Building modules: `uburoot-kbuild`

```
sudo apt install build-essential bc flex bison libssl-dev libelf-dev kmod
uburoot-kbuild check            # what this kernel accepts
uburoot-kbuild prepare ~/linux  # the exact source of the running kernel
uburoot-kbuild build ~/mymod
sudo uburoot-kmod load ~/mymod/mymod.ko
```

`check` names the kernel type (GKI, which is the Android Common Kernel branch
`androidNN-X.Y`, or a vendor kernel) and the vermagic a module needs. It also says
whether signing, symbol versions or GKI's symbol list will stop an out-of-tree module.
`prepare` takes the config from `/proc/config.gz` and sets `LOCALVERSION`, so that
`make kernelrelease` equals `uname -r`. It refuses otherwise.

## SELinux

Under Magisk, KernelSU and APatch, root's own SELinux domain is already permissive, so
SELinux doesn't block Ubuntu's root even when the phone is enforcing:

- Magisk: `magisk_rules()` calls `permissive([proc])` for `u:r:magisk:s0`
  (`native/src/sepolicy/rules.rs`, commit `70d233cae2`, 2026-11-10). On the S9 the
  kernel logs `permissive=1` on the denials that domain hits.
- KernelSU: `ksu_permissive(db, KERNEL_SU_DOMAIN)` plus `allow ALL ALL ALL` for
  `u:r:ksu:s0` (`kernel/selinux/rules.c` lines 92 and 103, commit `019a3c0103`,
  2026-11-06).
- APatch: its su runs as `u:r:magisk:s0` by default (`ALL_ALLOW_SCONTEXT_MAGISK` in
  KernelPatch `kernel/patch/include/uapi/scdefs.h`) and applies Magisk's policy.

So `selinux permissive` is almost never what you need: it turns SELinux off for every
app and service on the phone. It exists for the rare case where a tool talks to an
Android service that refuses it. It is always temporary.

## Limits (measured on the S9: kernel 4.9, vendor, LineageOS 19.1)

- **Module signing is enforced** (`CONFIG_MODULE_SIG_FORCE=y`). An unsigned module fails
  with `Required key not available`, and `uburoot-kmod` explains why. Vendors don't
  publish the signing key, so out-of-tree modules need a kernel you build yourself.
  The S9's ROM ships no loadable modules either.
- **bpftool** can't list programs or maps on kernels older than 4.13 (no
  `BPF_OBJ_GET_INFO_BY_FD` or ID iteration). Loading BPF programs and the pinned maps in
  `/sys/fs/bpf` still work. bpftrace and CO-RE need BTF (`CONFIG_DEBUG_INFO_BTF`), which
  this kernel lacks.
- **trace-cmd** works (tracefs). **simpleperf** (Android's, as a wrapper) and **perf**
  work as root (`perf_event_paranoid` is 3 with `security.perf_harden=1`, which only
  restricts non-root users).
- **kptr_restrict** can be above 2 on some kernels (the S9 booted with 4, a vendor
  extension). The kernel only accepts 0–2 from a write, so a revert of 4 writes 2,
  which hides addresses from everyone, root included, as 4 did. Android's init also
  writes it: `security.lower_kptr_restrict=1` sets 0, and `=0` sets 2
  (`/system/etc/init/hw/init.rc`). `simpleperf record` does this while it runs.
- cgroup v1 controllers are at `/dev/*` as on Android, not at `/sys/fs/cgroup/<name>`.

## Root manager extensions

UbuRoot loads modules with the kernel's `insmod`/`init_module` only. The managers'
own mechanisms are not used, but here is what they do (sources checked 2026-11-16):

- **KernelSU** `ksud insmod MODULE [PARAMS]` resolves the module's undefined symbols
  through KernelSU (or `/proc/kallsyms`) and calls `init_module(2)`
  (`userspace/ksud/src/debug.rs`). Also `ksud sepolicy`, `ksud feature`, profiles.
- **APatch** `apd insmod` is "load a kernel module without version check": it resolves
  symbols from `/proc/kallsyms` (setting `kptr_restrict` to 1 meanwhile), which skips
  the vermagic and CRC checks, then calls `init_module(2)` (`apd/src/insmod.rs`). As far
  as their code shows, both still reach the kernel's own signature check.
  **KPM** (KernelPatch modules) are a different format, loaded by KernelPatch's own
  loader (`kp_load_module_path` in `lkm/kpm/kpm.c`) through a supercall that needs the
  superkey. They are managed from the APatch app.
- **Magisk** has no kernel module loader. `magiskpolicy` patches SELinux rules live.

These are manager-specific (and the superkey must stay with its owner), so UbuRoot
documents them rather than wrapping them.
