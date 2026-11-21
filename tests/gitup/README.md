# tests/gitup: the git upgrade

Tests of `lib/gitup/`, one file per area:

- the shared core and the module contract: `test_gitup.sh`, `test_gitup_contract.sh` (with the registry merge test),
  `test_gitup_refusals.sh` (refusals of a tool another user owns, a bad root override and a bad registry module) and
  `test_gitup_messages.sh` (refusal and status wording of product functions, which also runs on Windows);
- the module of each operating system: `test_gitup_apt.sh`, `test_gitup_apt_ppa.sh`, `test_gitup_apt_state.sh`, `test_gitup_rpm.sh`,
  `test_gitup_source_route.sh` (the build from source and what can stop it), `test_gitup_macos.sh`, `test_gitup_windows.sh` and
  `test_gitup_windows_cmd.sh` (the Windows `.cmd` front ends);
- the takeover of a foreign git: `test_gitup_takeover.sh`, `test_gitup_partial.sh` (partly applied and broken states) and
  `test_gitup_plan_and_restore.sh` (the plan against what runs, interrupted and by-hand restores).

Most of them skip on Windows; read the skip count.

- **Covers:** `lib/gitup/`.
- **Helpers owned:** none. Four helpers live in `tests/support/` because other folders load them too: `gitup.sh` (also `tests/autoupdate/`, `tests/platform/`, `tests/install/` and `tests/integrations/smartgit/`), `product_call.sh` (product functions in a bare shell, bundled-git stand-ins; also `tests/install/` and `tests/inspect/`), `gitup_macos.sh` (also `tests/platform/`, `tests/install/` and `tests/integrations/smartgit/`) and `gitup_windows.sh` (also `tests/install/` only).
- **Not here:** a test of install, the CLI, doctor, the timer or the platform launchers goes in the folder of that code, even when it needs the git upgrade sandbox; the harness self-test of `gitup_windows.sh` is `tests/project/test_windows_harness_safety.sh`.
- **Runs:** `tests/run.sh tests/gitup`.
