# Contributing to UbuRoot

Thanks for helping! Bug reports from devices we haven't tested are just as valuable as
code. KernelSU, APatch and Android 13+ in particular still need real-device reports.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Security
problems go through [SECURITY.md](SECURITY.md), not public issues.

## Reporting bugs

Use the bug report form. It asks for the device, ROM, Android version and root manager,
which matter a lot here. Helpful extras:

```sh
su --mount-master -c /data/local/uburoot/bin/rootinfo.sh
```

## Before you write code

Read [CLAUDE.md](CLAUDE.md): it is the architecture guide, and it records why things are
the way they are (mount propagation, uid 9000, the network groups...). Most of them were
learned the hard way on a real device.

Ground rules:

1. **The critical safety rule.** Nothing may run `rm -r` under `/data/local/uburoot`
   except `ubu_safe_rm` in `common.sh`. With `/data` and `/sdcard` bind-mounted inside the
   rootfs, a careless delete wipes the phone. Changes near deletion or unmounting must
   keep `tests/test_reset_guard.sh` and the Docker suite green.
2. **System logic lives in the shell scripts** (`app/src/main/assets/uburoot/bin/`), not
   in Kotlin. They are POSIX `sh` that runs under Android's mksh: no `local`, no
   bashisms, `shellcheck -s sh` clean.
3. **No proprietary Google dependencies** (Play Services, Firebase, Play Core) and no
   analytics. Keep dependencies minimal: no Hilt, Room or Retrofit.
4. **Don't guess flags, APIs or versions.** Check them in the source or the docs, and note
   what you checked in CLAUDE.md.
5. Code, comments, commit messages, docs and the default UI strings
   (`res/values/strings.xml`) are in English. Translations are welcome as
   `values-<lang>/strings.xml`; Brazilian Portuguese (`values-pt-rBR`) is kept complete,
   so add new strings there too.

## Development setup

- JDK 21 with `javac`, plus the Android SDK (compileSdk 37).
- Docker, for the real-mount suite.
- Optional: a rooted arm64 phone with adb.

```sh
./gradlew spotlessApply                     # format Kotlin (ktlint; CI runs spotlessCheck)
./gradlew assembleDebug testDebugUnitTest   # app + unit tests
tests/run-all.sh                            # shellcheck, reset guard, Docker suite
tools/adb-push-scripts.sh                   # push the scripts to a phone
tests/device/run.sh                         # device suite (needs Ubuntu installed)
```

The device suites are described in the [README](README.md#tests).

## Pull requests

- Keep them small and focused, with one topic per PR.
- Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`,
  `docs:`, `test:`, `ci:`, `chore:`...).
- Add or update tests with the change: Docker checks for script behavior, unit tests for
  Kotlin, device checks for anything only a phone can show.
- Say how you tested it. If you ran it on a device, name the device, ROM and root manager.
- Update CLAUDE.md when you change a design decision, and CHANGELOG.md under
  *Unreleased*.

By contributing, you agree that your contributions are licensed under the
[Apache License 2.0](LICENSE).
