# tests/platform: operating-system code and the platform launchers

Two kinds of file live here. `test_*.sh` files are run by `tests/run.sh` like any other: `test_launchd.sh` and
`test_launchd_update.sh` (the macOS LaunchAgent), `test_macos.sh`, `test_macos_intel.sh` and `test_macos_path.sh` (the startup-file block for the CLI folder), `test_windows.sh`, `test_windows_path.sh` (Windows only: the real `bin/gsg-path.ps1` in Windows PowerShell 5.1 over a file-backed user `Path`) and `test_wsl.sh`,
and `test_ubuntu_container.sh` (the PPA wrapper of `ubuntu-container.sh` over the apt module, which loads the gitup helper of `tests/support/`).
The other scripts (`ubuntu-container.sh`, `rocky-container.sh`, `mac-linux.sh`, `wsl-ci.sh` and their phases) are the container and
VM launchers that CI calls by path; `run.sh` does not run them ([platform-testing.md](../../docs/platform-testing.md)).

- **Covers:** `lib/platform/`.
- **Helpers owned:** none for the tests. The launchers are not helpers of the tests.
- **Runs:** `tests/run.sh tests/platform`.
