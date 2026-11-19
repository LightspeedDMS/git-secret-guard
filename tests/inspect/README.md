# tests/inspect: status and doctor

Tests of `lib/inspect/`: `status`, and `doctor` with its findings record, repositories, home handling, read-only mode, exemptions
and betterleaks checks, plus the severity levels and the status output shown by the UI.

- **Covers:** `lib/inspect/`.
- **Helpers owned:** none. `tests/support/doctor.sh` is shared with `tests/platform/` and `tests/scan/`, so it lives in `tests/support/`.
- **Runs:** `tests/run.sh tests/inspect`.
