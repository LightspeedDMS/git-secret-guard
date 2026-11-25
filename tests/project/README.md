# tests/project: gates on the repository itself

Tests that guard the repository, not one `lib/` context: `test_quality.sh` (shellcheck, the comment lint, the dependency rules
of `lib/` and the structure rules of `tests/`), `test_runner.sh` (how `tests/run.sh` picks files and folders, and its parallel
mode with the start order by cost), `test_cost_list.sh` (`tests/test-costs.list` names every test file once and no other), `test_ci_plan.sh` (the CI plan: docs-only detection, the file list of the docs job, the job names), `test_release_page.sh` (the rules of `.github/scripts/release-notes.sh`, the Release page of a tag, and the least-privilege shape of `release.yml`), `test_coverage_paths.sh` (`tests/coverage.awk` maps a trace to the files of a checkout in any directory, a worktree included), `test_dco.sh`,
`test_macos_ci.sh`, `test_mac_runner.sh` and the `test_platform*.sh` files that check the container and VM launchers of
`tests/platform/`. Three files test the test harness of `tests/support/` itself: `test_betterleaks_lookup.sh` (which betterleaks the harness
picks), `test_harness_assertions.sh` (the head, cut marker and tail of a failure message, knobs `GSG_TEST_DETAIL` and
`GSG_TEST_DETAIL_TAIL`) and `test_windows_harness_safety.sh` (the safety nets of `gitup_windows.sh`).

- **Covers:** the whole tree: `lib/`, `tests/`, `.github/`, `docs/`.
- **Helpers owned:** none. The tests load `tests/support/lib.sh`.
- **Runs:** `tests/run.sh tests/project`.
