# tests/project: gates on the repository itself

Tests that guard the repository, not one `lib/` context: `test_quality.sh` (shellcheck, the comment lint, the dependency rules
of `lib/` and the structure rules of `tests/`), `test_runner.sh` (how `tests/run.sh` picks files and folders, and its parallel
mode), `test_ci_plan.sh` (the CI plan: docs-only detection, the file list of the docs job, the job names), `test_dco.sh`,
`test_macos_ci.sh`, `test_mac_runner.sh` and the `test_platform*.sh` files that check the container and VM launchers of
`tests/platform/`.

- **Covers:** the whole tree: `lib/`, `tests/`, `.github/`, `docs/`.
- **Helpers owned:** none. The tests load `tests/support/lib.sh`.
- **Runs:** `tests/run.sh tests/project`.
