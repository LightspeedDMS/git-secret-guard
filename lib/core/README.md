# lib/core: the shared kernel

Used by the hook and the CLI. Holds `common.sh` (constants, `load_settings`, the hook file lists `GSG_HOOK_LIBS` and
`GSG_HOOK_FILES`, the `ui_*` helpers), `proc.sh` (process groups, supervisor), `state.sh` (the state record) and `message.sh`
(the commit message check).

- **May depend on:** nothing outside `lib/core/`. A core file never `source`s a file of another context. The one reference
  outward is a run target, not a source: `proc.sh` starts `lib/scan/run-scanner.sh` by path.
- **Hook loading:** `hooks/secret-scan` sources `core/common.sh` first, then each entry of `GSG_HOOK_LIBS` (`core/proc.sh` and
  `core/message.sh` among them). Everything the hook loads sits under `lib/core/` or `lib/scan/`.
- **Enforced by:** `tests/project/test_quality.sh` (`test_lib_core_sources_nothing_outside_lib_core`,
  `test_the_hook_lists_name_only_files_under_lib_core_and_lib_scan`).
