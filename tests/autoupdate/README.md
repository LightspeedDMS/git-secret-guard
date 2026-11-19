# tests/autoupdate: the update cycle and the doctor timer

Tests of `lib/autoupdate/`: the update run on Linux, macOS and Windows, its probes and report, the systemd units, the Task
Scheduler task, the doctor timer and the update output shown by the UI.

- **Covers:** `lib/autoupdate/`.
- **Helpers owned:** `autoupdate.sh` (a local bare origin with real tags, for the update tests). `tests/support/autoupdate_units.sh` is shared with `tests/platform/`, so it lives in `tests/support/`.
- **Runs:** `tests/run.sh tests/autoupdate`.
