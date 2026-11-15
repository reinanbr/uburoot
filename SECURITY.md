# Security policy

UbuRoot runs as root and bind-mounts the phone's `/data` and `/sdcard` into a chroot,
so bugs here can destroy user data or break Android. Security reports are taken
seriously.

## Supported versions

Only the latest release gets fixes.

## Reporting a vulnerability

**Please do not open a public issue.** Report privately through GitHub:

<https://github.com/reinanbr/uburoot/security/advisories/new>

Include what you can of:

- the UbuRoot version (or commit), device, ROM, Android version, and root manager with its
  version;
- what happens and what you expected;
- steps or a script to reproduce it.

You should get an answer within a week. Once a fix is released, the advisory is published
with credit to you, unless you prefer not to be named.

## What counts

Examples of what we want to hear about:

- any way for UbuRoot to delete or corrupt data outside the rootfs, e.g. a path where
  `reset.sh` or anything else removes files while `/data` or `/sdcard` is still mounted
  inside the rootfs;
- mounts leaking back into Android: a `umount` or mount change inside the chroot that
  affects Android's own mounts (`/apex`, `/system`, ...);
- privilege escalation from the chroot's non-root user to root, or to Android
  permissions it should not have;
- code execution through the app's config file, scripts, downloads or intents;
- a release APK whose signature does not match the published certificate.

Out of scope: what root inside the chroot can do. Root in Ubuntu is root on the phone by
design (see the security model in the [README](README.md#security-model)).

Release APKs are signed with the certificate whose SHA-256 digest is
`b2fbab8052e8bc9ee7cb01bc26f309ce972d16fdda34a52bdb15b2628d2ab53d`.
