# Story: Install, upgrade, uninstall

**Feature:** 02_Feat_Lifecycle

## Overview
As the **owner of this machine**, I want `git-secret-guard install` to set everything up with verified
tools, and `git-secret-guard uninstall` to put back exactly what was there before, **so that** I can
adopt, upgrade or remove the guard safely and repeatably.

**Value after this story:** from a checkout, `bin/git-secret-guard install` makes every commit on the
machine scanned. `status` shows what is installed, and `uninstall` reverts it.

## Acceptance Criteria

```gherkin
Scenario: Fresh install
  Given git >= 2.54 on PATH, jq present and no global core.hooksPath
  When I run git-secret-guard install
  Then the hook files are copied to the share dir and the CLI symlink is created in ~/.local/bin
  And global config has exactly one hook.git-secret-guard.event=pre-commit and one .command=<absolute path>
  And trufflehog 3.99.2 and gitleaks 8.30.1 are present in ~/.local/bin (downloaded only if missing or the wrong version)
  And state records the previous core.hooksPath as "unset" and which tools install itself downloaded

Scenario: Install is idempotent and is the upgrade
  Given an existing installation
  When I run install again (same or newer checkout)
  Then the files are replaced, the config keys stay single-valued (no duplicate event entries)
  And the recorded previous core.hooksPath is NOT overwritten

Scenario: Existing global core.hooksPath requires explicit takeover
  Given global core.hooksPath is set (e.g. ~/.config/git/hooks)
  When I run install without --replace-hooks-path
  Then install refuses, prints the current value and changes nothing
  When I run install --replace-hooks-path
  Then the value is recorded verbatim, the directory it resolves to is backed up as a tarball in the state dir
  And global core.hooksPath is unset; the old directory is left in place

Scenario: Old git is refused
  Given the git on PATH is older than 2.54
  When I run install
  Then install refuses and explains that config-based hooks need git >= 2.54
  And when another reachable git is older than 2.54 (e.g. /usr/bin/git) install warns but proceeds

Scenario: Tool download is verified
  Given a tool must be downloaded
  When the tarball's SHA-256 does not match tools.lock for this platform
  Then install refuses, removes the download and installs nothing
  When it matches
  Then only the tool binary is extracted into ~/.local/bin and its --version is checked against the pin

Scenario: Uninstall restores the previous state
  Given an installation recorded with previous core.hooksPath = X (or "unset")
  When I run git-secret-guard uninstall
  Then the hook.git-secret-guard section is removed from global config
  And global core.hooksPath is restored to X verbatim (or left unset)
  And the share dir, CLI symlink, timer units (if any) and state are removed
  And trufflehog and gitleaks are left in place
  When I run uninstall --remove-tools
  Then only the tools that state says install downloaded are removed
  When I run uninstall again
  Then it reports nothing to do and exits 0

Scenario: status and version
  When I run git-secret-guard status
  Then it shows the installed version, hook command path, tool versions, and the recorded previous hooksPath
```

## Implementation Status
- [x] `tools.lock` with pinned versions and vendor SHA-256 (below); all four Linux rows re-verified against the real tarballs (`test_install_network.sh`)
- [x] install (prechecks, tools, copy, config, state, hooksPath takeover with backup), `lib/install.sh`, `lib/tools.sh`, `lib/state.sh`
- [x] uninstall (`--remove-tools`), idempotent, `lib/uninstall.sh`
- [x] status, version, help; `bin/git-secret-guard`, `lib/status.sh`, `lib/usage.md`
- [x] Download base URL overridable for tests (`GSG_TOOLS_BASE_URL`, `GSG_TOOLS_LOCK`), never in production defaults; verification cannot be skipped
- [x] Tests in a sandbox (scratch HOME and XDG dirs, GIT_CONFIG_GLOBAL)
- [x] Hardening from the story 01.01 review: `SETSID_BIN` and `TIMEOUT_BIN` come from the settings file (hook, adapters, gitleaks pre-flight), absolute and executable or the commit is blocked
- [x] README: install, upgrade, uninstall, backups, `--replace-hooks-path`, `--remove-tools`, test overrides, the `/usr/bin/git` 2.52 warning
- [x] Code review round 1 fixes (the review rejected the story for these; each has a test that failed before the fix):
  - [x] F1 uninstall order: `core.hooksPath` is restored first, the hook section removed second, a clear message on failure; install order pinned (`test_uninstall_restores_core_hooks_path_before_removing_the_hook_config`, `test_install_keeps_scanning_when_the_final_hooks_path_unset_fails`)
  - [x] F2 a user's scanner is moved aside (`<tool>.gsg-replaced-<UTC stamp>`), recorded with a hash, never "ours to delete", put back by every uninstall (`test_a_different_version_tool_of_the_user_is_moved_aside_recorded_and_never_ours`, `test_install_refuses_when_the_aside_name_is_taken_and_changes_nothing`, `test_uninstall_puts_the_users_replaced_tool_back_byte_identical`, `test_uninstall_leaves_a_tool_changed_since_install_and_keeps_the_original_aside`, `..._does_not_overwrite_a_symlink_...`, `..._reports_a_missing_original_...`, `..._ignores_tampered_replaced_entries`, `test_remove_tools_never_deletes_an_original_it_just_restored`, `test_status_lists_the_originals_install_moved_aside`, state tests)
  - [x] F3 a second takeover with a different recorded value is refused, nothing changed (`test_a_second_takeover_with_a_different_value_is_refused_and_changes_nothing`)
  - [x] F4 a `core.hooksPath` in the XDG config or an included file (include, includeIf hasconfig and gitdir) is detected, install refuses naming the file, uninstall leaves it, status reports the effective value; install never writes into an included file and a symlinked `~/.gitconfig` stays a symlink (`tests/test_hookspath.sh`, run without `GIT_CONFIG_GLOBAL`)
  - [x] F5 README no longer claims "no PATH lookup" (`test_the_readme_does_not_claim_the_hook_has_no_PATH_lookup`); the shebang is deliberately unchanged (git runs the hook file directly, so the shebang is resolved before any settings are read, and rewriting it to an absolute bash in the installed copy would break the verbatim-copy contract asserted by `test_fresh_install_copies_the_package_into_the_share_dir_and_links_the_cli`)
  - [x] F6 failed copy leaves no `git-secret-guard.new.*`; the old-tree `rm -rf` is checked and no longer aborts the install through its exit status (`test_a_failed_copy_leaves_no_staging_dir_beside_the_share_dir`, `test_a_leftover_old_tree_that_cannot_be_removed_is_reported`)
  - [x] F7 `curl -q` (`test_curl_is_run_with_q_first_so_the_users_curlrc_is_ignored`)
  - [x] F8 status judges versions with `tools_version_matches` (`test_status_judges_versions_exactly_like_install_does`)
  - [x] F9 `lifecycle_read_hooks_path` in `lib/hookspath.sh` replaces `install_read_hooks_path` for uninstall and status (`test_uninstall_reads_core_hooks_path_without_touching_the_install_globals`)
  - [x] F10 backup bounds: `/`, the home directory, over 50 MB, over 10000 files are refused before any change (`test_replace_hooks_path_refuses_the_home_dir_and_directories_over_the_backup_bounds`, `test_the_resolver_refuses_root_before_anything_could_back_it_up`)
- [x] Code review round 2 fixes (re-review rejected F2 only; tests in `tests/test_upgrade.sh` unless noted, each failed before the fix):
  - [x] P1 a pin bump no longer treats install's own tools as the user's: the state records the SHA-256 of every placed file (`tools_placed`), an existing file with that hash is replaced in place (`test_a_pin_bump_replaces_install_own_tools_in_place_and_remove_tools_deletes_them`)
  - [x] P2 a pin bump over a user original keeps one aside and uninstall restores the user's first original, never an intermediate (`test_a_pin_bump_on_top_of_a_user_original_still_restores_the_users_file`, `test_chained_pin_bumps_keep_the_first_original_and_the_clean_removal`, `test_a_missing_first_original_never_lets_a_later_record_be_restored`)
  - [x] P3 asides and hashes are written to the state before any file is moved; a rerun drops records whose aside is gone (`test_a_state_that_cannot_be_written_leaves_the_users_tool_where_it_was`, `test_a_failure_placing_the_second_tool_still_lets_uninstall_restore_both_originals`, `test_a_rerun_after_a_failure_placing_the_second_tool_ends_with_both_originals_restorable`)
  - [x] LOW git's stderr is no longer dropped and `GIT_CONFIG` is named (`tests/test_hookspath.sh: test_a_failing_global_config_read_shows_git_s_reason_and_names_GIT_CONFIG`)
  - [x] LOW a one-line note names the file when `GIT_CONFIG_GLOBAL` is set (`test_a_note_names_the_global_config_file_when_GIT_CONFIG_GLOBAL_is_set`, `test_status_shows_the_installation`)
  - [x] LOW the share dir is rolled back when the final rename fails (`tests/test_install.sh: test_a_failed_swap_of_the_share_dir_rolls_back_to_the_old_tree`)
  - [x] LOW README documents the include-walk limits (`~user/`, `%(prefix)/`, symlinked include base directory)
- [x] Code review round 3 fixes (tests in `tests/test_upgrade.sh` unless noted, each failed before the fix):
  - [x] P5 a failed placement during an upgrade no longer turns install's own file into the user's original: the state holds old AND new hash of a tool until placement succeeds (`install_write_state pending` / `final`), ownership and the uninstall guards accept any recorded hash (`test_a_failed_placement_of_the_second_tool_in_a_pin_bump_keeps_installs_own_file_installs_own`, `test_a_failed_placement_of_the_first_tool_in_a_pin_bump_keeps_installs_own_file_installs_own`, `test_uninstall_after_a_failed_bump_accepts_any_recorded_hash_and_restores_the_users_original`)
  - [x] P6 `--remove-tools` deletes a tool only when it is a regular file with a recorded hash; a same-version build of the user's, a symlink and a legacy state without hashes stay (`tests/test_uninstall.sh: test_remove_tools_keeps_a_same_version_build_that_replaced_installs_file`, `test_remove_tools_keeps_a_symlink_at_the_tool_path`, `test_remove_tools_keeps_every_tool_when_the_state_has_no_tools_placed`)
  - [x] cosmetic a directory in the way of the staging file fails once (`install -T`), no "Is a directory" from the cleanup (asserted in the P5 second-tool test)
  - [x] E2E message 1: a state dir that cannot be created prints `git-secret-guard: cannot create the state dir <path> (<reason>); nothing was changed` (`test_a_state_dir_that_cannot_be_created_is_reported_with_the_reason_and_nothing_changed`, `test_a_state_dir_that_cannot_be_created_during_a_takeover_is_reported_the_same_way`)
  - [x] E2E message 2: a record whose aside was never created is reported as `the planned move of <path> never happened; it is still in place`, a genuinely missing original keeps `is missing` (`test_a_failure_placing_the_second_tool_still_lets_uninstall_restore_both_originals`, `test_uninstall_reports_a_missing_original_and_leaves_the_tool`)
- [x] code-reviewer approval (APPROVE on round 4, after rejections for F1-F10, then P1-P3, then P5/P6)
- [x] manual-test-executor: install, upgrade, uninstall, reinstall in a sandbox with evidence (all 7 scenarios plus every fix re-verified; final round 61/61 checks)

### Decisions where the spec left room
- "record prev verbatim (only if state has none yet)": a recorded **value** is never overwritten; a state that says `previous_hooks_path_set=no` is replaced when a later `--replace-hooks-path` takes over a real value, otherwise uninstall would forget it.
- Uninstall removes the state **file** but keeps the state directory while it holds `hooks-path-backup-*.tar.gz`; the tarballs are never deleted by install or uninstall.
- Uninstall restores `core.hooksPath` only when it is currently unset; a newer value is kept with a notice. Without a state file `core.hooksPath` is left alone.
- `install` refuses macOS and architectures other than x86_64 and arm64; the darwin rows of `tools.lock` are data only.
- Added beyond the pseudocode: a write probe of the global git config before anything is downloaded or copied (`git config --list` exits 128 for a missing file, so it cannot be used), a summary of what install did, and `status` exits 1 when anything is missing or mismatched.
- `--with-timer` and timer units belong to story 03.01 and are not implemented.

## Technical Requirements (pseudocode only)
```
install [--replace-hooks-path] [--with-timer]:
  require git version >= 2.54 (git on PATH); warn for each other reachable git < 2.54
  require jq
  prev = git config --global --get core.hooksPath (may be absent)
  if prev present and not --replace-hooks-path → refuse
  for tool in trufflehog, gitleaks:
    if ~/.local/bin/<tool> --version == pinned → keep
    else download tarball for platform; sha256 != lock → refuse; extract binary only; record "installed-by-us"
  copy hooks/, lib/, bin/ → share dir; write tool absolute paths into share dir settings
    (also resolve setsid and timeout to absolute paths at install time and record them; the hook
     calls those instead of resolving through PATH — hardening from the story 01.01 review)
  set hook.git-secret-guard.event (replace-all) and .command (replace-all)
  if prev present: backup tar of its resolved dir; record prev verbatim (only if state has none yet); unset core.hooksPath
  symlink CLI; write state
uninstall [--remove-tools]: reverse each recorded step; missing items are fine (idempotent)
```

Pinned values (vendor-published checksums, fetched 2026-10-30):

| Tool | Version | Platform | SHA-256 |
|---|---|---|---|
| trufflehog | 3.99.2 | linux_amd64 | 3c7b0d1dc4278294269bfdd7594bca8bb28c78da0a4a06ad202ded37b48deca4 |
| trufflehog | 3.99.2 | linux_arm64 | 929b81efffca752eafd58bf6f17bf725d354f338636a7bbbee65c086d2f9ddf3 |
| trufflehog | 3.99.2 | darwin_amd64 | c23a1b10522b8b84cfd04dc88a3a8819d3dc23b20f15e23540ba442b4b2fbeed |
| trufflehog | 3.99.2 | darwin_arm64 | b612143d840b4c75d41fe40436c5932efead001951283f18c87013c4145e1675 |
| gitleaks | 8.30.1 | linux_x64 | 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb |
| gitleaks | 8.30.1 | linux_arm64 | e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080 |
| gitleaks | 8.30.1 | darwin_x64 | dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709 |
| gitleaks | 8.30.1 | darwin_arm64 | b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 |

The darwin rows are pinned for later use only: macOS is not tested and not claimed.

## Testing Requirements
- Sandbox with a scratch HOME (so `~/.local` and `~/.config` are scratch), scratch XDG dirs,
  `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_NOSYSTEM=1`.
- Mismatch test: a local fake tarball served through the base-URL override must be refused.
- One real-download test, network only (reported as SKIPPED offline), verifying the real tarballs against `tools.lock`.
- Old-git test: a fake `git` reporting 2.52 placed first on PATH.

## Definition of Done
- All scenarios pass, code-reviewer approves, manual-test-executor verifies install → upgrade → uninstall
  → reinstall in a sandbox with evidence. The README covers install, upgrade and uninstall.
