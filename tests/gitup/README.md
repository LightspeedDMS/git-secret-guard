# tests/gitup: the git upgrade

Tests of `lib/gitup/`: the module of each operating system (apt, rpm, macOS, Windows), the module contract, the takeover of a
foreign git, partly applied states and the Windows `.cmd` front ends. Most of them skip on Windows; read the skip count.

- **Covers:** `lib/gitup/`.
- **Helpers owned:** none. Three helpers live in `tests/support/` because other folders load them too: `gitup.sh` (also `tests/autoupdate/`, `tests/platform/`, `tests/install/` and `tests/integrations/smartgit/`), `gitup_macos.sh` (also `tests/platform/`, `tests/install/` and `tests/integrations/smartgit/`) and `gitup_windows.sh` (also `tests/install/` only).
- **Runs:** `tests/run.sh tests/gitup`.
