# Feature 02: Lifecycle (install, upgrade, uninstall)

## Objective
One command sets up the whole machine: pinned and verified scanners, the config hook, and the migration
away from a global `core.hooksPath`. A second command reverses exactly that.

## Architecture
| Item | Location |
|---|---|
| hook, libs, CLI target | `${XDG_DATA_HOME:-~/.local/share}/git-secret-guard/` |
| CLI | `~/.local/bin/git-secret-guard` (symlink) |
| state | `${XDG_STATE_HOME:-~/.local/state}/git-secret-guard/state` (previous hooksPath or "unset", version, tools installed by us, backup path) |
| tools | `~/.local/bin/trufflehog`, `~/.local/bin/gitleaks` (pinned by `tools.lock`) |
| git config (global) | `hook.git-secret-guard.event=pre-commit`, `hook.git-secret-guard.command=<abs path>`; global `core.hooksPath` unset |

All git writes go through `git config --global`, so `GIT_CONFIG_GLOBAL` isolates the tests.

## Dependencies
- Feature 01 (it installs the hook that Feature 01 builds).

## Stories (implementation order)
- [x] 01_Story_InstallUpgradeUninstall
