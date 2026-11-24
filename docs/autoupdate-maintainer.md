# Maintainer notes: auto-update

Behaviour: [Auto-update](install.md#auto-update---auto-update-and-update). Internals only here. The cycle is `lib/autoupdate/autoupdate.sh` (entry
`autoupdate_run`), the install side `lib/autoupdate/install_timer.sh` (`install_prepare_update`, `install_enable_update`), the unit text
`lib/autoupdate/timer.sh`, the removal `lib/install/uninstall.sh`. All are lifecycle libraries: none is in `GSG_HOOK_LIBS`, and `autoupdate` is in
`GSG_LIFECYCLE_RE` (`test_the_hook_never_loads_the_install_time_libraries`).

- **Every doubtful case is a skip, never a guess.** A skip sets the outcome and returns before anything is changed; exit 0 is
  for `current`, `updated` and `skipped`, 1 for `failed` (`autoupdate_finish`). The skip tests compare the share files, the
  state file and the checkout's refs, `HEAD` and status before and after. One test runs every group in turn, each removing its
  obstacle again, and ends in one control run that installs once every obstacle is gone
  (`test_every_doubtful_case_is_skipped_and_nothing_changes`). The owner's checks keep their order, shallow,
  no origin, not on `main`, dirty (`autoupdate_owner_checks`). `bad-version` for the installed version is judged in
  `autoupdate_prepare`, before the fetch, so that skip leaves the refs alone too.
- **The off check comes before the lock.** `autoupdate_run` reads the state, and with `auto_update` not `yes` prints the one
  line and returns: no lock, no record (the off group of `test_every_doubtful_case_is_skipped_and_nothing_changes`). With the lock first, a held lock
  plus `auto_update=no` would write a `locked` record. Under the lock the state is read again (`autoupdate_cycle`), so an
  install that finished a moment ago is seen.
- **The role is a pure function of the two paths** (`autoupdate_role`: `[ -O co ] && [ -O co/.git ]`; rc 1 when `.git` is no
  directory). It has no seam: `test_the_role_is_a_pure_function_of_the_two_paths` uses a `.git` that is a link to the
  root-owned `/usr`, and the follower
  tests replace the function in the test shell and run git with `GIT_TEST_ASSUME_DIFFERENT_OWNER=1`, under which every git
  call on the checkout fails unless it carries the follower's `safe.directory`
  (`test_a_follower_installs_from_the_tag_export_and_never_fetches`). A follower owned by a real second user runs only in the
  container (`tests/platform/autoupdate.sh`, `autoupdate-e2e.sh`, and the probe `autoupdate-probes.sh`).
- **Every git call** goes through `AU_GIT` (`autoupdate_git_init`): `-c core.fsmonitor=false --no-optional-locks`, for a
  follower `-c safe.directory=<checkout>` (the exact path, command line only), then `-C <checkout>`. `autoupdate_git_env`
  unsets git's repository-local variables (a calling hook's `GIT_DIR` cannot redirect the cycle) and exports
  `GIT_TERMINAL_PROMPT=0`. Each call runs in the foreground into `git.out` and `git.err` of the work dir and its `$?` is
  taken, never a process substitution.
- **The fetch refspecs** (`autoupdate_fetch`): `'+refs/heads/main:refs/remotes/origin/main' 'refs/tags/v*:refs/tags/v*'` with
  `--no-recurse-submodules`. The `+` is on the branch only; **tags are never forced**, which is what turns a tag moved on
  `origin` into a non-zero fetch with the local tag unchanged (`test_a_moved_tag_is_a_failed_fetch_and_the_local_tag_stays`).
  The fetch is not atomic: with a rejected tag `refs/remotes/origin/main` still advances (observed); `HEAD`, the tags and the
  install do not. It runs as
  `timeout -k 10 120 setsid git ...` with stdin from `/dev/null`: `setsid` leaves git without a controlling terminal, so ssh
  cannot prompt, and `timeout` **without** `--foreground` signals the whole group. This is the opposite of the scan adapters
  and `hooklist_bind_timeout`, which keep `--foreground`: do not "align" them.
- **Tag selection** (`autoupdate_pick_tag`): `git tag --list 'v*' --sort=-v:refname --merged refs/remotes/origin/main`, read
  with a bound (`GSG_UPDATE_MAX_TAGS`, 1000). The order of git's list is not trusted: a tag replaces the best one only when
  `autoupdate_newer` says so. Versions pass the strict `x.y.z` regex first and are compared by `gitup_version_at_least`, never
  in `$(( ))` (a leading `08` is an error there; alone, `gitup_version_at_least` reads a missing part as 0 and would take
  `1.0` for `1.0.0`).
- **The merge target is the peeled commit**, `git merge --ff-only refs/tags/<tag>^{commit}`, after
  `merge-base --is-ancestor HEAD <tag>^{commit}` and followed by the assertion that `HEAD` is that commit
  (`autoupdate_at_commit` peels both sides, so an annotated tag is compared by its commit). The fast-forward makes no merge
  commit (`test_the_owner_moves_to_the_newest_released_tag_and_installs_from_its_export`). Nothing turns the owner's hooks off.
- **The version-gap rule** (`autoupdate_needs_install`). `install_write_state` records the new `version` before
  `install_copy_share` runs, so after a failed copy the state names a version that is not installed. "Needs install" is
  therefore: newer than the state's `version` **or** newer than `$GSG_SHARE/VERSION`, and an installed copy without a
  `VERSION` file always needs it. The same function serves tag selection and the install decision
  (`test_needs_install_compares_with_the_state_and_with_the_installed_copy`,
  `test_a_state_ahead_of_the_installed_copy_still_installs`). Comparing with the state alone would leave such a machine
  stuck on the old copy for ever.
- **The export is `git archive` of the tag, not the work tree** (`autoupdate_export`): `git archive --format=tar refs/tags/vX`
  into `export.tar`, then `tar -xf` into `<work dir>/tree`, each in the foreground with its status taken, then a check that
  `tree/bin/git-secret-guard` is an executable file. An untracked work tree file never reaches the share
  (`test_the_owner_moves_to_the_newest_released_tag_and_installs_from_its_export`). `git archive` runs the filters the
  checkout's configuration names and applies `export-subst` and `export-ignore`
  (`test_archive_filter_and_export_attributes_observation`); the trust section of the user docs states this, keep the two in
  step. `X` comes from `git show HEAD:VERSION`, never from the work tree file.
- **The child install runs in the foreground, with no flags** (`autoupdate_child_install`):
  `GSG_UPDATE_LOCK_PID=$$ env -u CLICOLOR_FORCE timeout -k 30 1800 <work dir>/tree/bin/git-secret-guard install "${GSG_UPDATE_INSTALL_ARGS[@]}" </dev/null`, stdout and stderr into
  files, `$?` taken, the files then copied to the run's own stdout and stderr (`CLICOLOR_FORCE` is dropped because a line of
  `install.err` goes into the record `status` shows, and escape codes must not). No flag means no `--upgrade-git`,
  `--take-over-system-git` or `--replace-hooks-path`, and no terminal means no prompt. It does mean the automatic SmartGit and
  Desktop steps of a plain install (`preferences.yml`, the Desktop launcher and hooks directory; no package manager and no
  Flatpak sandbox removal without a terminal). **The one switch** is the array `GSG_UPDATE_INSTALL_ARGS` in
  `lib/autoupdate/autoupdate.sh`, empty: `--dont-configure-smartgit` and `--dont-link-desktop-git` there turn both steps off for
  every update run, which then only reports. The tree has no `.git`, so that
  install keeps the recorded `source_checkout`, and as a plain install over `auto_update=yes` it refreshes the units and
  enables nothing. **Nothing is sourced after the child returns:** the installer has replaced the share tree the running
  shell's libraries came from. `updated` needs exit 0 **and** `$GSG_SHARE/VERSION` equal to `X`
  (`test_an_installer_that_exits_0_without_installing_is_a_failure_and_a_sound_release_recovers`); the old copy keeps
  scanning after a failure (`test_a_failed_child_install_keeps_the_old_copy_and_the_next_run_retries`: the installed files, the
  state, the global hook config and the tool files are byte-identical). bash runs a trap only after its foreground child
  returns, so a signal during the child install waits for it, at most the 1800 second bound.
- **The lock and its let-in rule** (`autoupdate_lock_take`: 0 taken or let in, 1 held by a live run or a directory in the
  way, see [doctor.md maintainer notes](doctor.md), 2 the lock could not be made). The lock is `doctor_rec_lock` with a
  path (`lib/inspect/doctor_findings.sh`, whose defaults are still the findings lock): one attempt, a live holder refuses unless
  the link is older than `GSG_UPDATE_LOCK_MAX_AGE_MIN` (120; a run holds it for about 33 minutes at its bounds, the
  findings lock for milliseconds). A process is **let in without taking the lock** only when
  the lock names `GSG_UPDATE_LOCK_PID` and that pid is its parent or its grandparent (`autoupdate_is_ancestor`). The
  grandparent is needed because the child install's parent is `timeout`; `$PPID` alone lets nobody in. A process let in
  never releases the lock (`AU_LOCK_HELD` stays 0). A wrong or missing `GSG_UPDATE_LOCK_PID` is refused
  (`test_a_child_of_the_lock_holder_is_let_in_and_leaves_the_lock`, `test_the_child_install_of_an_update_run_is_let_in`).
  Where `ps -o ppid= -p` does not work nobody is let in. `install` takes the lock only when the state dir exists
  (`install_update_lock`): `autoupdate_lock_take` creates that directory, which on a first install would be a lasting change
  before the last refusable step, and without it no update run of that user can exist. Its EXIT trap is
  `install_cleanup; autoupdate_lock_release`, `install_cleanup` first because it reads the exit status. `uninstall_run` takes
  the update lock, then the findings lock, and releases both on every return path
  (`test_install_takes_the_update_lock_and_refuses_while_another_run_holds_it`,
  `test_uninstall_refuses_while_the_update_lock_is_held`).
- **The record** (`autoupdate_record_write`): seven keys, a temp file `update-tmp.XXXXXX` beside it and a rename; the temp
  name is not `update.XXXXXX`, so no sweep can match the record itself. A run kept out by the lock writes its record without
  the lock; the rename makes two writers safe. The detail is cut at `GSG_UPDATE_DETAIL_MAX` (159) plus the cut mark, 160 in
  all (`DETAIL_MAX` in `tests/autoupdate/test_autoupdate.sh`). `result=failed` with an empty reason is deliberate for failures the
  reason list has no word for. Under the lock `autoupdate_work_make` removes every `update-work.??????` (only the lock
  holder makes them) and a temp record older than a minute; `uninstall_update_record`, which also runs under the lock,
  removes the record, every `update-tmp.??????` file and every `update-work.??????` that is a real directory (never through
  a link), so the state dir's `rmdir` succeeds (`test_uninstall_removes_the_update_units_the_record_and_the_state_dir`).
- **The update log** (macOS and Windows; Linux writes the journal and never reaches this code). The log is the job's own stdout and stderr on both
  platforms (launchd `StandardOutPath` and `StandardErrorPath`, the Windows wrapper's `>> update.log 2>&1`), so `update` itself stamps it: no plist
  change, no reload, and an existing macOS install is stamped from the first run of the new version. `autoupdate_run` asks `autoupdate_log_target`
  right after `paths_init`: true only when **both** stdout and stderr are the file `GSG_UPDATE_LOG`, so merging stderr into the stamped stream never moves an error line where it
  did not go before. The test asks the open descriptors, not a path: `{ out="$(stat -c '%d:%i' - <&3)" && err="$(stat -c '%d:%i' - <&4)"; } 4>&2 2>/dev/null 3>&1` (the order is not free: redirections run left to right and a closed stdout makes `3>&1` fail, which bash would print on the real stderr, possibly the log; `test_a_closed_stdout_leaves_no_redirection_error_from_the_detection`; GNU `stat` on
  `-` is an fstat of stdin; the group makes fds 3 and 4 copies of the original stdout and stderr) against `stat -L -c '%d:%i' -- "$GSG_UPDATE_LOG"`. The first
  version tested `[ /dev/stdout -ef "$GSG_UPDATE_LOG" ]`: it was proven on Windows (all 23 tests of `test_autoupdate_schtasks` passed under real `cmd`, stamped runs
  included) and failed only on macOS (nothing stamped, no start line, no rotation), so a path through `/dev/stdout` is not trusted there. The descriptor method has
  Linux evidence so far; its Windows and macOS evidence comes from the next CI run. `stat` comes from `PATH` like the other tools of `update` (`wc`, `mv`, `ps`): `brew_use_gnubin` puts GNU coreutils first on a Mac, and Linux
  and Git for Windows ship it; a BSD `stat`, a missing one or a closed descriptor fails the test, which is the unstamped behaviour of a run without this feature
  (`test_a_stat_that_fails_means_not_the_log_and_the_run_stays_unstamped`, `test_the_log_is_known_by_the_identity_of_the_open_descriptors`). When a logged-form test
  fails, its message carries `ul_report`: the bash `-ef` results, the `stat` of fd 1, of fd 2 and of the path, and what `autoupdate_log_target` answered, so the CI
  log itself shows what each method saw. A pipe (the journal), a
  terminal or another file is unchanged byte for byte (`test_a_run_whose_output_is_not_the_update_log_is_unchanged`).
  - **The shape** (`autoupdate_run_logged`): the parent runs `"$BASH" "$GSG_ROOT/bin/$GSG_NAME" update 2>&1 | autoupdate_stamp "$from"` and returns
    `${PIPESTATUS[0]}`, the child's status. The child is **a fresh bash, not a subshell**: the lock records `$$` and `autoupdate_is_ancestor` lets the
    child install in only when the lock holder is its parent or grandparent; in a `( ... ) |` subshell `$$` would be the parent's pid and the child
    install would be locked out (`test_a_logged_update_that_installs_stamps_the_installer_output_and_ends_with_the_result` installs through it). The
    child is started as `GSG_UPDATE_LOGGED_CHILD=1 "$BASH" ...` (the marker is set for that one command): `autoupdate_run` reads it, unsets it (the child install never sees it)
    and runs the plain update, so the logged path is one level whatever the detection answers; the pipe makes the detection false there as well, but termination does not
    rest on that (`test_a_detection_that_is_always_true_still_logs_one_level_only` forces the detection true under a timeout, `test_the_logged_child_marker_does_not_reach_the_child_install`). On Windows
    the parent already runs from the private copy (`GSG_UPDATE_COPY` is inherited), so the child skips the re-exec and nothing pins the share.
  - **`autoupdate_stamp`** prints one start line, `<UTC time> git-secret-guard: update: run started, <version> is installed` (`nothing` for an empty
    version), then every input line behind its time (`YYYY-MM-DDTHH:MM:SSZ`, the form of the record's `checked_at`, taken with `printf -v` and no fork per line);
    a last line without a newline is kept. It ignores HUP, INT and TERM first and always reads to the end, a failed write ignored: the run feeding it must
    never get SIGPIPE and its last lines must not be lost (`test_the_stamp_filter_drains_its_input_when_it_cannot_write`). No here-string, no process substitution.
  - **Signals.** Bash runs a trap only after its foreground command returns, and GNU `timeout` (every step runs under it) gives its step a process group of its
    own. So a signal to the process group (Ctrl-C, `timeout` of an outer caller) reaches the parent and the child but not the running step, and is acted on when
    that step returns, as one during the child install always was: the child's traps remove the lock and the work dir, and the parent's trap
    (`autoupdate_stop`) prints one stamped line `<UTC time> git-secret-guard: update: stopped by TERM (exit 143)` to the log and exits with the signal's code (129, 130,
    143) after the child returned. A signal to the parent's pid alone lets the run finish, with its record and its result line, and only then exits the parent the
    same way. How launchd stops a job is not verified here and nothing relies on it. The filter ignores the three signals and drains to the end
    (`test_a_logged_update_stopped_by_term_ends_cleanly_with_143`, `..._int_..._130`, `..._hup_..._129`, each also asserting the stopped line, so none of
    them passes without the parent's trap; skipped on Windows, which has no process groups).
  - **The bound.** `GSG_UPDATE_LOG_MAX` (1 MiB). On macOS the parent rotates before the run (`autoupdate_log_rotate`): a larger log is moved to `update.log.1`
    (an older one replaced; a directory there is refused, `mv` would move the log into it) and `exec >>"$GSG_UPDATE_LOG" 2>&1` reopens the streams, because launchd
    opened the file for append and its descriptor follows the rename; the reopened stdout starts the new log. A failure prints one line and the run goes on, the
    outcome is never changed (`test_a_log_over_the_bound_is_rotated_to_one_previous_file_and_a_smaller_one_is_appended_to`,
    `test_a_rotation_that_cannot_happen_is_said_and_the_run_goes_on`). On Windows the wrapper holds the log open during the run and Windows refuses to rename an open
    file, so `schtasks_cmd_text` rotates in `cmd` **after** the run, when the log is closed (macOS rotates at the start of a run, in bash). The wrapper is the old one
    with the update line changed from `>` to `>>` (exactly one byte longer) and everything new after it: `set "GSG_RC=%errorlevel%"`, then
    `if exist "<log>" for %%F in ("<log>") do if %%~zF GTR <max> move /y "<log>" "<log>.1" >nul 2>&1` (`if exist` first: for a missing file `%%~zF` is empty and the
    `if` is a syntax error), then `exit /b %GSG_RC%`, so the wrapper exits with update's status whether the log was rotated or not. **Why this layout:** an install made
    earlier has the old wrapper, and the first auto-update to this version runs it; its child install rewrites `update-task.cmd` (`schtasks_refresh`, a rename over
    the file) while `cmd` still reads it, and `cmd` reopens a batch file by name and seeks to the byte offset it saved after the update line. With every header line
    and the update line in place, that offset lands on the last byte of the new update line (a bare newline) and `cmd` goes on with the `set` line: the transition
    run neither runs update twice nor loses its status. A line placed before the update line would put the offset inside new text. The one-byte argument assumes the header is unchanged: a wrapper variable (`XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CONFIG_HOME`, `GIT_CONFIG_GLOBAL`) set at the new install but not at the old one adds a header line and shifts the offset for that one transition run (rare).
    `test_an_old_wrapper_resumes_on_the_final_newline_of_the_new_update_line` pins the offset on Linux (the old text is built from the new by the inverse change),
    `test_a_wrapper_rewritten_while_cmd_runs_it_runs_update_once_and_keeps_its_status` runs it through real `cmd` and
    `test_the_new_wrapper_exits_with_the_status_of_update_with_and_without_a_rotation` pins the status; the `set` variable is `GSG_RC`, which nothing else uses.
    After the refresh the next hourly run appends and rotates (`test_a_refresh_rewrites_the_wrapper_an_earlier_version_wrote`,
    `test_a_plain_install_rewrites_a_wrapper_that_still_truncates_the_log`). **Hazard, no code for it:** a directory at `update.log.1` on Windows defeats the rotation: `cmd`'s `move` would
    put the log inside the directory instead of replacing `update.log.1`. Remove the directory. The macOS side refuses it and says so.
    `uninstall` removes `update.log.1` with the log (`uninstall_update_record`, `uninstall_agent update`; a regular file only).
  - **Lines that can be unstamped:** what runs before the run reaches the filter. The rotation's own failure line, a bash that cannot start, the failure of
    `winupdate_failed` before its re-exec (no private copy could be made) and the `paths_init` failures. The text of those is unchanged on purpose. The
    `stopped by` line of `autoupdate_stop` is stamped by the parent itself, as the start line is stamped by the filter.
- **Install side.** `install_prepare_update pre` runs before `gitup_offers` (a refusal after an accepted git upgrade would
  not be "before any change") and again without `pre` after `install_prepare_timer`, with the final git directory. The
  manager check (`install_update_manager_reachable`, a read-only `systemctl --user show --property=Version`) comes last in
  the precheck, after every check that starts no process. `INSTALL_TIMER_BIN` is set when a timer **or** auto-update is
  wanted or recorded, so the one `SYSTEMCTL_BIN` settings key serves both; a plain install over a recorded auto-update needs
  no `systemctl` (`test_a_plain_install_over_auto_update_does_not_need_systemctl`). The state is written with
  `auto_update=yes` before the units exist, so an interrupted install can be uninstalled. The flag travels as the global
  `AUTO_UPDATE_FLAG` (`cmd_install`), like `DESKTOP_GIT_FLAG`.
- **Units.** `timer_unit_set doctor|update` names a pair (flag, marker, unit names, message words); `install_refresh_units`,
  `install_enable_units` and `uninstall_units` take that word. Each pair has its own marker, so a unit with the doctor
  marker at an update path is not ours (`test_a_unit_with_the_doctor_marker_at_an_update_unit_path_is_not_ours`), and the
  doctor units are byte-identical to before (`test_the_doctor_unit_text_is_byte_identical_to_before`). The update service
  alone carries `GSG_UPDATE_ENV_NAMES` (`GSG_TEST_UPDATE_INTERVAL_SECONDS`): without it the child install, which has only the
  unit's environment, would write the timer back to `1h`
  (`test_the_update_service_carries_the_test_interval_only_when_it_is_set`,
  `test_an_install_with_the_interval_of_the_service_keeps_the_timer`). The timer sets no `AccuracySec`, so systemd's default
  of one minute applies and a 20 second test timer can fire late: give a poll loop room for it. The units are parsed by the
  real `systemd-analyze` where it exists (`test_the_update_units_pass_systemd_analyze_verify`).
- **Windows** adds `lib/platform/schtasks.sh` (the adapter), `lib/platform/winupdate.sh` (re-exec, ownership probe) and four small branches in
  `lib/autoupdate/autoupdate.sh`, each behind `tools_is_windows` and each answering a probe made on Windows Server 2019 with Git for Windows:
  - **`autoupdate_is_ancestor`** reads `/proc/<pid>/ppid` because the MSYS `ps` has no `-o` (`ps: unknown option -- o`); without
    it the grandparent test fails and the child install is refused the lock. `exec` keeps the MSYS pid (the Windows pid
    changes), so a lock named after `$$` stays valid across the re-exec (`test_a_child_of_the_lock_holder_is_let_in_and_leaves_the_lock`).
  - **`autoupdate_role`** calls `winupdate_role`: `git -c safe.directory= -C <co> rev-parse --git-dir` with the `GIT_*` repository
    variables unset (`GIT_DIR` in the environment redirects the probe) and `GIT_CEILING_DIRECTORIES` set to the checkout's parent in the
    `C:/dir` form native git reads, so git cannot walk up to a repository around an empty `.git`. The empty `safe.directory` resets a
    user-level `*`. Git exits 128 both for dubious ownership and for no repository, so the answer must be `.git`: that is `owner`. Otherwise the
    probe is repeated with `-c safe.directory=<co>`; its `.git` is `follower`, anything else is no repository and the role is rc 1, the
    skip `not-a-plain-checkout` (its detail says `<co>/.git is not a directory or no repository`, on every platform). git checks the worktree and the `.git` directory, so a
    checkout half owned by another account is a follower
    (`test_the_role_is_owner_for_my_checkout_and_follower_for_another_accounts_checkout`, which gives a clone to SYSTEM with
    `icacls /setowner *S-1-5-18 /T` and skips, saying why, where icacls is refused;
    `test_a_checkout_that_is_no_repository_has_no_role_and_is_skipped`). The probe has no limit: it runs before the
    settings, and their `timeout`, are loaded.
  - **`autoupdate_fetch`** has no `setsid` word and `autoupdate_prepare` does not ask for one. GNU `timeout -k 10 120 git fetch` ends
    git, `git remote-http`, `git-remote-http` and `ssh` (probed against a listener that never answers, interactively and inside a
    scheduled task); `taskkill` is not needed. Git Credential Manager (`credential.helper=manager`) ignores `GIT_TERMINAL_PROMPT=0`
    and ran a probe fetch to its limit, so `winupdate_run` exports `GCM_INTERACTIVE=never` before it decides whether to re-exec (a run by
    hand from the checkout makes no copy and needs it too). It also unsets `MSYS_NO_PATHCONV` and `MSYS2_ARG_CONV_EXCL`: inherited, they hand native git `/c/dir` paths and the role probe finds no repository (`test_an_inherited_no_path_conversion_does_not_break_the_role_or_the_run`)
    (`test_a_fetch_against_a_hanging_origin_is_bounded_and_leaves_no_process`, `test_update_tells_credential_manager_never_to_prompt`,
    `test_a_run_by_hand_that_does_not_re_exec_still_tells_credential_manager_never_to_prompt`).
  - **The share is replaced by `install` with two renames, and Windows refuses to rename a directory** holding a running script, an
    open script or a working directory (probed; a non-`exec` child leaves the parent holding it). `bin/git-secret-guard` runs
    `winupdate_run` for `update`: when it runs from the share and auto-update is on, it copies `bin lib VERSION settings` to
    `<state dir>/update-copy.XXXXXX`, moves the working directory to the state dir, exports `GSG_UPDATE_COPY` and `exec`s the copy.
    The copy takes the lock, makes the work dir and writes the record as on Linux, and removes itself when `autoupdate_run`
    returns (a running script's directory can be deleted on Windows, only renamed not). `GSG_UPDATE_COPY` is trusted only when
    this process runs from that very directory (`GSG_ROOT -ef`): an inherited value naming anything else neither skips the re-exec nor
    removes anything (`test_an_inherited_copy_variable_neither_skips_the_re_exec_nor_deletes_anything`). A copy that cannot be made
    is a recorded `result=failed` with an empty reason and the cause as detail, written by the record writer of `lib/autoupdate/autoupdate.sh`,
    so `status` shows it and the run exits 1 (`test_a_failed_copy_for_the_re_exec_is_recorded_as_a_failed_run`). A copy a signal left behind is swept by
    the next run once it is a day old, and by `uninstall`. The child install still comes from the `git archive` export of the tag,
    never from the copy (`test_an_update_started_from_the_share_replaces_it_and_leaves_no_copy`,
    `test_an_update_started_inside_the_share_dir_replaces_it`, `test_a_copy_left_by_a_killed_run_is_swept_when_old_and_kept_when_young`).
- **The Windows task** (`lib/platform/schtasks.sh`): `schtasks_check_target` refuses a value the wrapper cannot carry, a `/TR` over 261 characters, a foreign wrapper, a foreign task and a failed query; it lists all tasks (`/Query /FO CSV /NH`),
  runs `/Query /TN <name> /FO CSV /NH /V` only when our exact name is listed, and takes a task as ours when its action holds `\update-task.cmd` (schtasks prints the action in the console code page),
  `schtasks_enable` (wrapper first, then `/Create ... /SC HOURLY /TR "<wrapper>" /F`), `schtasks_refresh`,
  `schtasks_uninstall`. Every call goes through `SCHTASKS_BIN` of the settings with `MSYS_NO_PATHCONV=1`. `install_update_check_target` (its second argument is the schtasks path) and
  `install_enable_update` branch on `tools_is_windows`; `status`/`doctor` read the wrapper through the Windows branch of `autoupdate_report_job` (file, marker test `schtasks_cmd_is_ours`, reader `autoupdate_report_task_seconds` = the fixed hour). run.sh
  never registers a task: `lc_schtasks_standin` (`tests/support/lifecycle.sh`) records the arguments in `schtasks.log` and keeps the tasks as
  files, and `tests/autoupdate/test_autoupdate_schtasks.sh` drives install, status, doctor and uninstall through it; the task name is read from
  `lib/core/state.sh`, not typed in a test. Probed with the real scheduler: `/RU <user> /NP` asks for a password, and without `/F` an existing task is a Y/N question.
- **Not run for real:** an SSH origin without an agent (the `fetch-failed` test uses an unreachable `file://` origin); more
  than 1000 tags; the real Task Scheduler in run.sh (only the manual end-to-end runs of the next note register a task; the all-tasks `/Query` was verified only as
  Administrator, a standard user is unverified). A real `launchctl` is not run by the update tests either: the
  lifecycle stand-in records calls (it keeps one loaded flag per label, so the tests assert the exact call logs); only `plutil -lint` on the update plist is
  Mac-only (`tests/macos-only.list`).
- **The real Task Scheduler, run by hand (2026-11-23).** Two runs on a Windows Server 2019 test machine (build 17763, Git for Windows 2.56.0,
  an account in Administrators, driven over ssh with a key), each from a clean profile: a clone over HTTPS with `main` at `v1.2.0`,
  `install --auto-update`, `v1.3.0` the newest tag of the origin. The table is in
  [platform-testing.md](platform-testing.md#auto-update-through-the-real-task-scheduler).
  - **The task as install creates it:** principal `LogonType Interactive`, `RunLevel Limited` (schtasks prints `Logon Mode: Interactive only`), one
    trigger that starts at the minute of the install and repeats every `PT1H`, `Last Result` 267011 (0x41303) until a first run.
  - **Run 1, the user logged on at the console** (logon type Interactive): `schtasks /Run` moved the install from 1.2.0 to 1.3.0, 8 s from
    `run started` to `updated` in `update.log`, record `role=owner`, `result=updated`, the checkout at `v1.3.0^{commit}` and not past it.
    With the trigger replaced (once, then every 5 minutes) the scheduler started the task by itself and the run answered `current`.
  - **Run 2, nobody logged on** (`query user` lists no session; an ssh key login is a network logon), logon type Interactive: `schtasks /Run`
    prints `SUCCESS: Attempted to run the scheduled task` and exits 0, and nothing starts. `Last Run Time` and `Last Result` 267011 do not change,
    no `update.log` and no record are written. The same at two times of a replaced trigger. Each time the Task Scheduler operational log (disabled on
    that machine until the run enabled it) holds event 332, `Task Scheduler did not launch task ... because user ... was not logged on when the
    launching conditions were met`. 13 minutes after install, both with exit 0: `status` `ok` without a `last check:` line, `doctor` `ok` with
    `no update run is recorded yet`.
  - **Logon type S4U, an observation and not a supported setup** (no product decision yet). In run 2 the same task with only its principal replaced
    (`LogonType S4U`, `RunLevel Limited`, the same user, no stored password; `Set-ScheduledTask -Principal`) ran with nobody logged on: `/Run`
    updated 1.2.0 to 1.3.0 in the same 8 s with result 0, and a replaced trigger started it twice (`current`); log lines, record and checkout equal
    those of run 1. In the ssh session `USERDOMAIN` was `WORKGROUP`, and an account name built from it was refused (`No mapping between account
    names and security IDs was done.`); the name built from `COMPUTERNAME` was accepted.
  - **The wrapper was not rewritten** by the child install of either update (same text, same modification time), and the child install left the
    S4U principal as it was. **`uninstall`** deleted the task in both runs, in run 2 with its principal and its trigger changed (event 141).
  - **Not run:** S4U set by a standard user or without elevation, or through `schtasks.exe`; a stored-password logon type and the SYSTEM account;
    `install --auto-update` again over a task switched to S4U (`/Create ... /F` may put the principal back); the hourly trigger as install writes
    it firing at its own hour, and a reboot; the age findings of `status` and `doctor` for a task that never ran; an origin that needs
    credentials under S4U; a machine on battery.
- **macOS adapter** (`lib/platform/launchd.sh`). `launchd_job_set doctor|update` fills the `LJ_*` table (job word = last
  program argument, flag, message words, label, plist path, log path, marker, extra variable names); every plist function
  takes the job as an optional last argument, default `doctor`, so the doctor callers and texts are unchanged
  (`test_the_doctor_plist_text_is_unchanged` in `test_launchd_update.sh` compares the text with the output of `main`). The update
  job differs in the marker (`install auto-update`, no double hyphen in an XML comment; `launchd_plist_is_ours FILE [MARKER]`),
  `StartInterval` with `RunAtLoad` true in place of `StartCalendarInterval` (the interval comes from `INSTALL_UPDATE_INTERVAL`
  through `timer_interval_seconds` of `lib/autoupdate/timer.sh`, the one parser and constant of the grammar `1h` or `<n>s`, also used by the
  report; anything else fails closed), `update.log`, `GSG_UPDATE_ENV_NAMES` in the plist environment as the Linux update service
  carries them, and the shared update `PATH` (`timer_update_path`, see the next note; on macOS it puts the directory of the
  recorded bash right after the git directory, `test_the_update_agent_path_holds_the_recorded_bash_dir_after_the_git_dir`). The run `RunAtLoad` starts at load meets the update
  lock install still holds when the state dir existed before (a reinstall) and is then recorded as `skipped locked`; on a first
  install no lock exists yet and it runs for real (to be confirmed in the manual end-to-end test). The labels and paths are
  `GSG_LAUNCHD_UPDATE_LABEL`, `GSG_UPDATE_AGENT_PLIST` and `GSG_UPDATE_AGENT_LOG` in `lib/core/state.sh`. Install side:
  one `install_update_precheck` for both platforms (the WSL check and the user manager probe are the Linux-only steps) and one
  `install_update_check_target`, used by the precheck and again by `install_prepare_update`; `install_enable_update` calls
  `launchd_enable update <enable flag>` on macOS. The messages have the Linux shape (`LJ_VERB` gives `could not enable`, the update
  success line is `auto-update timer enabled (<plist>); read its output with: cat <log>`); only the doctor agent keeps its own words.
  Uninstall: `uninstall_agents` (update first) calls `uninstall_agent <job> <recorded yes|no>`. `lib/autoupdate/autoupdate.sh` is untouched.
  Report library (`tests/autoupdate/test_autoupdate_report.sh`, the `*_on_macos_*` tests): `autoupdate_report_job` is the one table of the
  job files, schedule key, marker, reader and output hint per platform; `autoupdate_report_is_ours` and the two readers
  (`autoupdate_report_unit_seconds`, `autoupdate_report_plist_seconds`, both set `REPLY` to seconds) are the only other
  platform spots; `autoupdate_report_interval`, `autoupdate_doctor_units`, `autoupdate_doctor_age` and the status lines are one
  path for both. The timers.target.wants link check and the linger warning are Linux-only. 3600 seconds shows as `1h` on both
  platforms, so a Linux `OnUnitActiveSec=3600s` (only the test knob writes it) now shows `every 1h` as well.
- **Update job PATH, both platforms.** The child install of an update run starts from a tag export, which has no settings
  file, and finds `jq`, `setsid` and `timeout` (and on macOS `bash` through `env`, `brew` through `PATH`) by `type -P`
  (`install_resolve_bins`, `brew_find`). With only the git directory and `/usr/local/bin:/usr/bin:/bin` on the `PATH` of the
  job, a tool kept elsewhere (`~/.local/bin`, Linuxbrew, `/opt`) made that install fail with `install-failed` every hour.
  `timer_update_path` of `lib/autoupdate/timer.sh` builds the job `PATH`: the git directory, the directory of each tool named in
  `GSG_UPDATE_PATH_NAMES` (the install-time `INSTALL_BASH_BIN`, `INSTALL_JQ_BIN`, `INSTALL_SETSID_BIN`, `INSTALL_TIMEOUT_BIN`,
  never a new lookup) once each, then the fixed directories; a tool directory that is one of the fixed ones is skipped, so
  with the usual tools in `/usr/bin` the text is what it always was. Only `timer_update_service_text` and the update plist use
  it; the doctor service and plist keep `timer_unit_path` (`test_the_doctor_unit_text_is_byte_identical_to_before`,
  `test_the_doctor_plist_text_is_unchanged`). The tool paths are checked like the other values (`timer_check_target`,
  `install_refresh_units`, `launchd_check_values`). The git directory comes first, so a copy of a tool in it may win over the
  recorded one; `awk` and `curl` are not recorded by install and stay with the fixed directories.
  Tests: `test_the_update_service_path_holds_the_dirs_of_the_recorded_tools_and_the_doctor_service_does_not`,
  `test_the_update_service_path_finds_the_recorded_tools_for_the_child_install` (the lookups under the unit `PATH`, not a whole
  update run), `test_the_update_plist_path_follows_the_shared_update_path`.
  **Effect on an existing Linux install:** the update service text changes only where a tool lives outside the fixed
  directories. The next plain `install` then rewrites the service and prints `updated the auto-update timer units in <dir>; the
  timer is left as it was, run systemctl --user daemon-reload to make systemd read them`; nothing is enabled, `systemctl` is
  not called, nothing fails, and the old unit keeps running until the reload
  (`test_an_update_service_with_the_old_path_is_rewritten_by_a_plain_install_with_the_reload_hint_only`).
