## What and why

<!-- What does this change, and why? Link the issue if there is one. -->

## How it was tested

<!-- Which suites ran (tests/run-all.sh, unit tests, device suites)? If you ran it on a
phone: device, ROM, Android version, root manager and version. -->

## Checklist

- [ ] Scripts stay POSIX `sh` and `tests/shellcheck.sh` passes
- [ ] Nothing deletes under `/data/local/uburoot` except through `ubu_safe_rm` (the critical safety rule)
- [ ] No proprietary Google dependencies or analytics
- [ ] Tests added or updated
- [ ] CLAUDE.md updated if a design decision changed, and CHANGELOG.md under *Unreleased*
