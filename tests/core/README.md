# tests/core: the shared kernel

Tests of `lib/core/`: `test_common.sh` (settings, paths, the `ui_*` helpers), `test_platform_fill.sh` (the once-per-process `uname` answers) and
`test_state.sh` (the state file).

- **Covers:** `lib/core/`.
- **Helpers owned:** none. The tests load only `tests/support/lib.sh`.
- **Runs:** `tests/run.sh tests/core`.
