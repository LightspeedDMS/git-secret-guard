# Story: Doctor coverage report

**Feature:** 03_Feat_CoverageAssurance

## Overview
As the **owner of this machine**, I want `git-secret-guard doctor` to tell me which repositories are not
protected and why, and optionally to run that check on a schedule, **so that** gaps never stay hidden.
The hook cannot report a repo where it never runs.

**Value after this story:** `git-secret-guard doctor` prints a machine section plus only the problem
repos, with the config file responsible for each problem, and returns an exit code a timer can act on.

## Acceptance Criteria

```gherkin
Scenario: Healthy machine and repos
  Given the guard is installed and every repo under ~/Dev runs the hook
  When I run git-secret-guard doctor
  Then the machine section shows hook ✔, tools ✔ (pinned versions), jq ✔
  And no repo is listed; a summary line shows "N repos, N covered"
  And the exit status is 0

Scenario: Machine-level problems
  Given any of: hook.git-secret-guard missing; command path missing or not executable; a tool missing or at
        the wrong version; jq missing; a leftover global core.hooksPath
  When I run doctor
  Then each problem is listed with what to do, and the exit status is 1

Scenario: Old git reachable
  Given /usr/bin/git (or any git on PATH) is older than 2.54
  When I run doctor
  Then it warns that commits made with that git are NOT scanned, naming the path and version

Scenario: Repo disables or overrides the hook
  Given a repo with local hook.git-secret-guard.enabled=false, OR hook.pre-commit.enabled=false,
        OR a repo-level hook.git-secret-guard.command
  When I run doctor
  Then that repo is listed as "disabled in local config" / "command overridden", naming the config file
       it comes from (--show-origin)
  And the exit status is 1

Scenario: Exemption file problems
  Given a repo whose HEAD .secret-scan-ignore has a line without a reason, or a catch-all pattern
  When I run doctor
  Then the repo is listed with the line number and problem (catch-all as a warning)

Scenario: Informational findings
  Given a repo with .pre-commit-config.yaml but no installed framework hook
  When I run doctor
  Then it is listed as info ("pre-commit install not run"); info alone does not change the exit status

Scenario: Roots and bounds
  When I run doctor --roots DIR [DIR...]
  Then only repos under those roots are checked, searched at most 3 levels deep, skipping node_modules
  And worktrees are reported once, under their main repository

Scenario: Doctor never changes anything
  Given any machine state
  When doctor runs
  Then no file and no git config is modified (verified by checksumming config files before and after)

Scenario: Optional weekly timer
  When I run git-secret-guard install --with-timer
  Then a systemd user service + timer running doctor weekly are installed and enabled
  And uninstall disables and removes them
  And without --with-timer no unit is installed
```

## Implementation Status
- [x] Machine checks (`lib/doctor.sh`)
- [x] Repo discovery (roots, depth bound, node_modules skip, worktree dedup) (`lib/doctor_repos.sh`)
- [x] Per-repo checks (`git hook list`, `--show-origin` for enabled/command, ignore-file validation, pre-commit info)
- [x] Output format and exit codes (0 covered, 1 findings, 2 doctor error)
- [x] systemd user units + install/uninstall wiring (`lib/timer.sh`, `install --with-timer`, `uninstall`)
- [x] Tests (`tests/test_doctor*.sh`, `tests/test_timer.sh`, mutation-checked)
- [x] Three cosmetic follow-ups from 02.01: `tools_placed` words deduplicated, `--remove-tools` wording for an invalid entry, one `could not place` line without the raw coreutils line
- [x] Review round 1 fixes, each with a test that failed on the previous code (details in `CLAUDE.md`, "Review round 1"):
  H1 doctor ran repository-configured commands and could write (fsmonitor, lazy fetch); H2 a hook disabled in one linked worktree's own config read as covered;
  H3 one unreadable directory made every run exit 2; M1 no time bound (FIFO include, gitleaks, oneshot unit); M2 the machine section printed config values;
  M3 an invalid nested `.git` was credited to its parent; L1 the unit lacked the install-time XDG and `GIT_CONFIG_GLOBAL`; L2 a plain install re-enabled the timer;
  L3 uninstall left a dangling enable link. Cosmetic: a visible `…` wherever doctor cuts a value, no duplicate `PATH` entries in the unit, "hook not reached: the global hook config is incomplete" per repository.
- [x] code-reviewer approval (APPROVE on round 2 after H1-H3/M1-M3/L1-L3), manual-test-executor run against sandbox repos (PASS twice; 23-repo sandbox, read-only proof, negative controls)

**Where the implementation differs from the text above (decisions, evidence in `CLAUDE.md` and `README.md`):**
- Only a PROBLEM changes the exit status. WARNING (old git, catch-all, built-in rules off, unfinished placement) and info do not, and "N covered" counts repos without a PROBLEM. `/usr/bin/git` 2.52 is reachable on this machine for good, so a warning that exited 1 would make the "healthy machine, exit 0" scenario impossible here.
- The machine section uses `ok` instead of a check mark (the output goes to a journal and to terminals of any locale).
- `git hook list pre-commit` exits 1 with "no hooks found" when nothing is configured; doctor treats that as an empty list (the hook is not reached), not as a failure.
- The `.command` override is reported by scope and file (`--show-scope --show-origin`), never by value, because a command string can hold anything. A local command equal to the installed script is not an override.
- Doctor drops every variable `git rev-parse --local-env-vars` lists (including `GIT_CONFIG_PARAMETERS`): it reports config files, not the caller's shell.
- An unreadable directory under a root is a PROBLEM line (`not searched:`) and exit 1, not a doctor error: on the real `~/Dev` one `.postgres-data` directory would otherwise make every default and timer run exit 2 with no report.
- A plain `install` over an installed timer keeps it recorded but never enables it, never calls `systemctl` and rewrites only changed units of its own (a disabled timer stays disabled); only `--with-timer` enables. Units carry a marker line and a unit with the same name that install did not write is never overwritten or removed; `systemctl` is looked up once (`type -P`, `lib/install.sh`) and recorded as `SYSTEMCTL_BIN`; state key `timer_installed`.
- Extra machine checks beyond the story text: state record sanity (`tools_placed`, `tools_replaced`, `tools_installed_by_us`), a global `enabled=false`, and the timer's unit files when the state says one is installed.

## Technical Requirements (pseudocode only)
```
doctor [--roots ...]:
  machine: check hook keys, command exists+exec, pinned tools, jq, no global core.hooksPath,
           every git in (PATH ∪ /usr/bin/git) has version >= 2.54 else warn
  repos = bounded discovery under roots (depth <= 3, prune node_modules), dedup by --git-common-dir
  for repo in repos:
    "git-secret-guard" in `git hook list pre-commit`?     else → problem with origin of the disabling key
    origin of hook.git-secret-guard.command != global file → problem "overridden"
    HEAD:.secret-scan-ignore → same validator as the hook (shared code, not duplicated)
    .pre-commit-config.yaml and no framework shim in common-dir/hooks/pre-commit → info
  print machine section, problem repos, summary; exit code
```

## Testing Requirements
- One sandbox repo per scenario. A fake old `git` on PATH for the warning test. Config files are
  checksummed before and after to prove doctor is read-only. Unit files are checked with
  `systemd-analyze --user verify`. The timer is never enabled during tests.

## Definition of Done
- All scenarios pass, code-reviewer approves, manual-test-executor runs doctor against sandbox repos with
  evidence. The README documents the output and exit codes.
