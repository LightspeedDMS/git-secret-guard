# Story: Migrate this machine

**Feature:** 04_Feat_MachineRollout

## Overview
As the **owner of this machine**, I want the hand-built global hook replaced by git-secret-guard, with a
backup and a coverage report, **so that** every repository is scanned by both tools, including husky
repos that were previously skipped, and I can see exactly what is still uncovered.

**Value after this story:** the real machine is protected by git-secret-guard, the old setup is backed
up, and I have a doctor report for `~/Dev` plus a README that explains install, coverage, limits and
exemptions.

## Acceptance Criteria

```gherkin
Scenario: Gate on approved results
  Given features 01-03 are done
  Then the full test-suite output and shellcheck output are shown to the user
  And nothing on the real machine changes until the user approves

Scenario: Backup and install
  Given the user approved
  When ~/.config/git/hooks and ~/.config/git/hooks-passthrough are backed up (tarball, path reported)
  And git-secret-guard install --replace-hooks-path runs for real
  Then global config has the hook and no core.hooksPath
  And state records "~/.config/git/hooks" verbatim as the previous value
  And the old directories still exist (uninstall target; the cidx-server drop-in still resolves)

Scenario: Real-machine smoke test
  Given the real installation
  When a commit with a runtime-built fake secret is attempted in a scratch repo under ~/.tmp (no remote)
  Then it is blocked by both scanners without printing the value
  And a clean commit in the same scratch repo succeeds; the scratch repo is then deleted
  And a commit in tdd-guard's environment is NOT made (no changes to real repos); coverage is shown via
      `git -C ~/Dev/tdd-guard hook list pre-commit` listing git-secret-guard

Scenario: cidx-server is scanned (decision B)
  Given cidx-server's environment (from systemctl show)
  When a scratch-repo commit is run under that environment
  Then both scanners run (no exemption applies)

Scenario: Coverage report
  When git-secret-guard doctor runs over ~/Dev
  Then its full output is shown to the user with a short summary of each finding
  And no repository config is changed; any per-repo action (e.g. pre-commit install in code-indexer) is
      proposed and done only after explicit per-repo approval

Scenario: Documentation complete
  Then README.md covers: install, upgrade, uninstall; how coverage works (config hooks, git >= 2.54);
       exemptions (.secret-scan-ignore, native markers, .gitleaks.toml/.gitleaksignore, local disable,
       GIT_CONFIG_PARAMETERS, --no-verify); doctor and the timer; limits (binary files, auto-merges/rebases/
       cherry-picks skip pre-commit, offline gives unknown which blocks, ~2 s per commit, /usr/bin/git 2.52
       unscanned, repo hooks still run when the scan blocks, test harnesses copying ~/.gitconfig must
       disable the hook); Linux only
```

## Implementation Status
- [x] Results shown and approved (user approved the migration on 2026-11-01 after the story 04.01 results)
- [x] Backup taken
- [x] Real install
- [x] Smoke tests (scratch repo, service environment)
- [x] doctor report delivered
- [x] README complete

**Evidence (2026-11-01).**
- **Backup.**
  - `~/.local/state/git-secret-guard-premigration/config-git-hooks-20261101T153036Z.tar.gz` holds `hooks` and `hooks-passthrough`. The same directory has a copy of `~/.gitconfig` and the old `core.hooksPath` value.
  - Install took its own backup: `~/.local/state/git-secret-guard/hooks-path-backup-20261101T153048Z.KqEHA2.tar.gz`.
- **Install.** `install --replace-hooks-path` exited 0 and printed `core.hooksPath [~/.config/git/hooks] recorded verbatim and unset`.
  - trufflehog 3.99.2 was kept: it was already the pinned binary, SHA-256 `aba71aa8…`.
  - gitleaks 8.30.1 was downloaded and verified.
  - `status` exited 0. It shows the global config matching, `previous core.hooksPath: ~/.config/git/hooks`, and the effective `core.hooksPath` unset.
  - Both old directories are still in place, byte-identical.
- **Smoke tests**, run by manual-test-executor in `~/.tmp` scratch repos with a fake AWS key built at runtime and a dead proxy:
  - The fake-key commit was blocked, exit 1. gitleaks reported `aws-access-token` and `generic-api-key`, and trufflehog reported `AWS (unknown)`. 0 value hits in the output.
  - A clean commit passed (2.04 s). `--no-verify` bypassed the scan.
  - `git -C ~/Dev/tdd-guard hook list pre-commit` lists `git-secret-guard` (global scope) and `hook from hookdir`. tdd-guard was not changed.
  - Under cidx-server's real `GIT_CONFIG_PARAMETERS`, compared with the running process as `MATCH` and never printed, and with the service's `PATH` (git 2.56 first): the fake key was blocked by both scanners, and the repo's own pre-commit hook still ran through `hooks-passthrough`. A clean commit passed.
  - With `/usr/bin/git` 2.52, the fake key committed unscanned. This is a documented limit.
  - Before and after fingerprints of `~/.gitconfig`, the hook directories and tdd-guard are identical.
- **doctor `~/Dev`.** `summary: 54 repos, 54 covered`, exit 1. The output is saved at `~/.local/state/git-secret-guard-premigration/doctor-Dev-20261101T153119Z.txt`.
  - **PROBLEM:** `~/Dev/llm-creds-provider/.postgres-data` cannot be read. It is a postgres data directory owned by the container user.
  - **WARNING:** `/bin/git` 2.52 is reachable on this machine.
  - **WARNING:** keycloak's `.gitleaks.toml` turns off gitleaks' built-in rules.
  - **Info:**
    - code-indexer has a `.pre-commit-config.yaml` but `pre-commit install` was never run.
    - A local `core.hooksPath` is set in claude-pace-maker (and its 2 worktrees), claude-usage-reporting, code-indexer-master and tdd-guard. This is harmless: config hooks run anyway.
  - No repository was changed.
- **README.** The limits were checked on the real install and added: cherry-pick and rebase skip pre-commit; a commit takes about 2.0–2.2 s; the repository's own hooks still run when the scan blocks; test harnesses that copy `~/.gitconfig` run the hook. `tests/test_quality.sh` passed 21/21.

## Definition of Done
- Every scenario is met with evidence shown to the user. No other repository was modified without approval.
