#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2119,SC2120
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup.sh"
# shellcheck source=tests/gitup_macos.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup_macos.sh"
# shellcheck source=tests/smartgit.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/smartgit.sh"
# shellcheck source=tests/smartgit_windows.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/smartgit_windows.sh"

# ^ invariant sw_classify EXEC ABS INSTALLS... prints "<choice>|<git path>" of smartgit_classify for kind windows; INSTALLS are the SG_INST_PATH entries
sw_classify() {
    local exec="$1" abs="$2"
    shift 2
    sw_run 'SGP_EXEC="$1" SGP_ABS="$2"; shift 2; SG_INST_PATH=("$@"); smartgit_classify windows 26.1; printf "%s|%s" "$SGP_CHOICE" "$SGP_GITPATH"' "$exec" "$abs" "$@"
}

test_a_windows_settings_root_reports_the_older_major_as_left_over() {
    local base="$SANDBOX/appdata-left/syntevo/SmartGit" m
    rm -rf -- "$SANDBOX/appdata-left" || return 1
    for m in 25.1 26.1; do
        mkdir -p -- "$base/$m" && cp -- "$GSG_PROJECT/tests/fixtures/smartgit/windows-26.1/preferences.yml" "$base/$m/" && : >"$base/$m/startup" || return 1
    done
    set_env GSG_SMARTGIT_SETTINGS_BASE="$base"
    sw_run 'status_line() { printf "%s: %s\n" "$1" "$2"; }; status_problem() { echo PROBLEM; }; smartgit_status_lines'
    assert_rc 0 "status lines"
    assert_contains "$OUT" "SmartGit settings: $base/25.1 (25.1): left over, SmartGit uses the newer 26.1 here; this directory is not edited or counted and can be deleted once SmartGit 25.1 is no longer used" "one info line for 25.1"
    assert_not_contains "$OUT" "26.1): left over" "26.1 is the live one"
}

test_the_no_startup_refusal_with_an_untellable_process_check_gives_no_pgrep_advice_on_windows() {
    sw_run 'SG_SET_KIND=(windows) SG_SET_MAJOR=(26.1) SG_SET_DIR=(/c/x/26.1); smartgit_is_running() { return 2; }; smartgit_refuse_no_startup 0'
    assert_rc 1 "refused"
    assert_contains "$ERR" "(ps -W is missing or failed)" "names the Windows tool"
    assert_contains "$ERR" "no startup file" "names the missing setup"
    assert_not_contains "$ERR" "install pgrep" "pgrep is not a Windows tool"
}

test_the_wizard_state_is_bundled_and_its_git_is_read_from_executable_absolute() {
    sw_classify '${smartgit.install}\git\bin\git.exe' 'C:\Program Files\SmartGit\git\bin\git.exe'
    assert_rc 0 "classify"
    assert_eq "$OUT" "bundled|/c/Program Files/SmartGit/git/bin/git.exe" "backslash form, git path from executable.absolute converted to a POSIX path"
}

test_a_bundled_setting_without_executable_absolute_uses_the_only_install_found() {
    sw_classify '${smartgit.install}\git\bin\git.exe' '' '/c/Program Files/SmartGit'
    assert_eq "$OUT" "bundled|/c/Program Files/SmartGit/git/bin/git.exe" "the rest of the setting is appended below the install"
    sw_classify '${smartgit.install}\git\bin\git.exe' '' '/c/Program Files/SmartGit' '/c/Users/u/AppData/Local/Programs/SmartGit'
    assert_eq "$OUT" "bundled|" "two installs, no version to tell them apart: the git path stays unknown"
    sw_classify '${smartgit.install}\git\bin\git.exe' ''
    assert_eq "$OUT" "bundled|" "no install: the git path stays unknown"
}

# ^ why D:\Tools\Git in these tests, not C:\Program Files\Git; Git Bash maps its own install to /, and the real cygpath answers /cmd/git.exe there
test_the_form_smartgit_writes_itself_is_another_git_without_executable_absolute() {
    sw_classify 'D:\Tools\Git\cmd\git.exe' ''
    assert_eq "$OUT" "other|/d/Tools/Git/cmd/git.exe" "plain scalar with backslashes"
}

test_a_forward_slash_drive_path_and_a_single_quoted_one_are_another_git() {
    sw_classify 'D:/Tools/Git/cmd/git.exe' 'D:/Tools/Git/cmd/git.exe'
    assert_eq "$OUT" "other|/d/Tools/Git/cmd/git.exe" "forward slashes (measured accepted)"
    sw_classify "'D:\\Tools\\Git\\cmd\\git.exe'" ''
    assert_eq "$OUT" "other|/d/Tools/Git/cmd/git.exe" "single quotes are dropped"
}

test_executable_wins_over_a_stale_executable_absolute_for_another_git() {
    sw_classify 'D:\Tools\Git\cmd\git.exe' 'C:\Program Files\SmartGit\git\bin\git.exe'
    assert_eq "$OUT" "other|/d/Tools/Git/cmd/git.exe" "measured: SmartGit runs executable:, not the stale absolute line"
}

test_a_form_that_is_not_recorded_stays_unknown() {
    sw_classify 'git.exe' ''
    assert_eq "$OUT" "unknown|" "a bare name"
    sw_classify '\\server\share\git.exe' ''
    assert_eq "$OUT" "unknown|" "a UNC path"
    sw_classify '${smartgit.install}/git/bin/git.exe' ''
    assert_eq "$OUT" "unknown|" "the slash form after the install variable was not measured"
    sw_classify '"D:\\Tools\\Git\\cmd\\git.exe"' ''
    assert_eq "$OUT" "unknown|" "a double-quoted scalar is not parsed"
}

# ^ invariant sw_target DIR prints "<windows target>|<posix git run>" for GSG_GIT = DIR/ucrt64/bin/git.exe; rc and ERR are those of smartgit_win_target
sw_target() {
    sw_run 'GSG_GIT="$1/ucrt64/bin/git.exe"; smartgit_win_target || exit 1; printf "%s|%s" "$SMARTGIT_WIN_TARGET" "$SMARTGIT_WIN_GIT"' "$1"
}

test_the_target_is_cmd_git_exe_of_the_git_for_windows_in_use_when_it_reports_the_same_version() {
    sw_gfw "$SANDBOX/gfw" || return 1
    sw_target "$SANDBOX/gfw"
    assert_rc 0 "target"
    assert_eq "${OUT%%|*}" "$(sw_w "$SANDBOX/gfw")\\cmd\\git.exe" "the Windows spelling of cmd\\git.exe, backslashes"
    assert_eq "${OUT#*|}" "$SANDBOX/gfw/cmd/git.exe" "and the POSIX path that is run"
}

test_the_target_is_the_git_in_use_when_cmd_git_exe_is_missing_or_reports_another_version() {
    sw_gfw "$SANDBOX/gfw-nocmd" - || return 1
    sw_target "$SANDBOX/gfw-nocmd"
    assert_eq "${OUT%%|*}" "$(sw_w "$SANDBOX/gfw-nocmd")\\ucrt64\\bin\\git.exe" "no cmd\\git.exe: the git in use itself"
    assert_eq "${OUT#*|}" "$SANDBOX/gfw-nocmd/ucrt64/bin/git.exe" "and it is the one run"
    sw_gfw "$SANDBOX/gfw2" 2.55.0 2.56.0 || return 1
    sw_target "$SANDBOX/gfw2"
    assert_eq "${OUT%%|*}" "$(sw_w "$SANDBOX/gfw2")\\ucrt64\\bin\\git.exe" "another version in cmd\\git.exe: the git in use itself"
}

test_a_target_with_a_character_a_plain_yaml_scalar_cannot_hold_is_refused() {
    sw_gfw "$SANDBOX/gfw#x" || return 1
    sw_target "$SANDBOX/gfw#x"
    assert_rc 1 "a # in the path"
    assert_contains "$ERR" "is not a Windows path made of" "says what the rule is"
    assert_contains "$ERR" "SmartGit was not changed" "and that nothing changed"
}

test_the_windows_plain_scalar_rule_accepts_program_files_and_refuses_quotes_colons_hashes_and_edge_spaces() {
    local p ok=(
        'C:\Program Files\Git\cmd\git.exe' 'D:\Tools\Git (x86)\cmd\git.exe' 'C:\Users\a.b-c_d+e@f%g\git.exe'
    ) bad=(
        'C:\Program Files\Git\cmd\git.exe ' ' C:\Program Files\Git\cmd\git.exe' 'C:\Program Files\Git #1\cmd\git.exe'
        "C:\\Program Files\\Git's\\git.exe" 'C:\Program Files\"Git"\git.exe' 'C:\Program Files\Git:x\git.exe' 'C:/Program Files/Git/cmd/git.exe'
        'cmd\git.exe' "C:\\" 'C:\a\..\git.exe' '\\server\share\git.exe' 'C:\Program Files\ Git\git.exe' 'C:\Program Files\Git \git.exe'
    )
    for p in "${ok[@]}"; do
        sw_run 'smartgit_win_target_is_plain "$1"' "$p"
        assert_rc 0 "accepted [$p]"
    done
    for p in "${bad[@]}"; do
        sw_run 'smartgit_win_target_is_plain "$1"' "$p"
        assert_rc 1 "refused [$p]"
    done
}

sw_running() { sw_run 'smartgit_kind_running windows; echo "rc=$?"'; }

test_a_process_running_smartgit_exe_or_smartgitc_exe_in_any_case_counts_as_running() {
    local l
    for l in '  4711  1  4711  4711  ? 0 10:00:00 C:\Program Files\SmartGit\bin\smartgit.exe' \
        '  4711  1  4711  4711  ? 0 10:00:00 C:\Program Files\SmartGit\bin\smartgitc.exe' \
        '  4711  1  4711  4711  ? 0 10:00:00 D:\Apps\SMARTGIT\BIN\SmartGit.EXE'; do
        sw_ps '  1  0  1  4  ? 0 Nov  6 System' "$l" || return 1
        sw_running
        assert_contains "$OUT" "rc=0" "running: $l"
    done
    assert_eq "$(<"$SANDBOX/ps.log")" "-W" "the listing is asked with ps -W, which shows Windows processes"
}

test_other_processes_with_a_similar_name_do_not_count_as_smartgit() {
    sw_ps '  1  0  1  4  ? 0 Nov  6 System' '  2  1  2  2  ? 0 10:00:00 C:\Program Files\SmartGit\bin\smartgit-updater.exe' \
        '  3  1  3  3  ? 0 10:00:00 C:\Tools\notsmartgit.exe' '  4  1  4  4  ? 0 10:00:00 C:\Users\u\smartgit.exe.bak' \
        '  5  1  5  5  ? 0 10:00:00 C:\Program Files\Git\usr\bin\bash.exe' || return 1
    sw_running
    assert_contains "$OUT" "rc=1" "not running"
}

test_a_failing_empty_or_missing_process_listing_cannot_tell() {
    sw_ps || return 1
    : >"$SANDBOX/ps.fail"
    sw_running
    assert_contains "$OUT" "rc=2" "ps -W failed"
    rm -f -- "$SANDBOX/ps.fail"
    : >"$SANDBOX/ps.out"
    sw_running
    assert_contains "$OUT" "rc=2" "an empty listing"
    rm -f -- "$SANDBOX/pathbin/ps"
    sw_running
    assert_contains "$OUT" "rc=2" "no ps at all"
}

# ^ invariant sw_installed = sw_setup followed by a plain install (fixture scanners); the preferences file is untouched by it
sw_installed() {
    sw_setup || return 1
    gsg install </dev/null
    assert_rc 0 "plain install on the SmartGit machine"
}

test_status_reports_the_bundled_git_of_a_windows_smartgit_as_a_problem_with_the_command() {
    sw_installed || return 1
    gsg status
    assert_rc 1 "status with a SmartGit that commits with git 2.53.0"
    assert_contains "$OUT" "SmartGit install: $SW_APP (version unknown)" "the install is listed, its version is not read on Windows"
    assert_contains "$OUT" "SmartGit settings: $SG_SETTINGS (26.1): bundled git, git 2.53.0" "the bundled git is read through executable.absolute and run"
    assert_contains "$OUT" "commits are NOT scanned MISMATCH: run: git-secret-guard install --configure-smartgit" "names the fix command"
}

test_doctor_reports_that_bundled_git_of_a_windows_smartgit_as_a_problem() {
    sw_installed || return 1
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 1 "doctor with a SmartGit on git 2.53.0"
    assert_contains "$OUT" "PROBLEM  SmartGit 26.1 ($SG_SETTINGS): Git Executable is the bundled git 2.53.0" "a PROBLEM for the old bundled git"
    assert_contains "$OUT" "run: git-secret-guard install --configure-smartgit" "with the fix command"
}

test_status_reads_the_form_smartgit_writes_itself_and_calls_a_git_of_2_56_scanned() {
    sw_installed || return 1
    sw_set_exec "$(cygpath -w "$SW_GFW")\\cmd\\git.exe" || return 1
    gsg status
    assert_contains "$OUT" "SmartGit settings: $SG_SETTINGS (26.1): $(sw_target_w), git 2.56.0; commits are scanned" "the drive path is read, run and shown in the Windows form"
}

test_the_windows_launch_path_is_the_git_directory_then_the_system_directories() {
    sw_run 'SYSTEMROOT="C:\\Windows"; smartgit_lfs_launch_path "/d/Tools/Git/cmd/git.exe"'
    assert_rc 0 "an absolute git path"
    assert_eq "$OUT" "/d/Tools/Git/cmd:/c/Windows/System32:/c/Windows" "the git directory first, then System32 and the Windows directory"
    sw_run 'SYSTEMROOT="C:\\Windows"; GSG_SMARTGIT_LAUNCH_PATH=/x/y smartgit_lfs_launch_path "/d/Tools/Git/cmd/git.exe"'
    assert_eq "$OUT" "/x/y" "the test override replaces the PATH only"
    sw_run 'unset SYSTEMROOT; smartgit_lfs_launch_path "/d/Tools/Git/cmd/git.exe"'
    assert_rc 1 "no SYSTEMROOT, no system directories"
    assert_contains "$ERR" "SYSTEMROOT is not set" "says why"
}

test_a_missing_git_lfs_on_windows_is_never_installed_only_repair_advice_is_given() {
    sw_run 'GSG_GIT=/d/Tools/Git/cmd/git.exe; smartgit_lfs_plan_route'
    assert_rc 1 "refused"
    assert_contains "$ERR" "repair Git for Windows (it ships Git LFS)" "says what to do"
    assert_contains "$ERR" "SmartGit was not changed" "and that nothing changed"
}

# ^ invariant sw_configure = sw_setup, the real scanners, and install --configure-smartgit without a terminal; sw_target_w is the value it writes
sw_configure() {
    sw_setup || return 1
    sg_real_tools || return 1
    gsg install --configure-smartgit </dev/null
}
sw_target_w() { printf '%s\\cmd\\git.exe' "$(cygpath -w "$SW_GFW")"; }

# ^ invariant sw_refused TEXT = install --configure-smartgit was refused with TEXT and nothing of SmartGit changed
sw_refused() {
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "refused"
    assert_contains "$ERR" "$1" "says why"
    assert_contains "$ERR" "SmartGit was not changed" "and that nothing changed"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are byte-identical"
    assert_no_file "$SG_BACKUPS" "no backup or manifest"
}

test_configure_writes_the_windows_form_into_the_two_executable_lines_and_leaves_every_other_byte() {
    sw_configure || return 1
    assert_rc 0 "install --configure-smartgit on a Windows SmartGit on its bundled git"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$(sw_target_w)" "executable: is cmd\\git.exe of the Git for Windows in use, with backslashes"
    assert_eq "$(sg_git_value executable.absolute "$SG_PREFS")" "$(sw_target_w)" "executable.absolute: too"
    assert_eq "$(sg_others "$SG_PREFS")" "$(sg_others "$SANDBOX/prefs.orig")" "every other line is byte for byte the same"
    assert_eq "$(wc -l <"$SG_PREFS")" "$(wc -l <"$SANDBOX/prefs.orig")" "no line was added or removed"
    assert_eq "$(tr -cd '\r' <"$SG_PREFS" | wc -c | tr -d ' ')" 0 "no carriage return came in"
    assert_contains "$OUT" "SmartGit plan" "the plan was printed"
    assert_contains "$OUT" "a fake-token commit in a scratch repository must be blocked and a clean commit must print the summary line" "the then line names both commits"
    assert_contains "$OUT" "Git Executable: bundled git, git 2.53.0 -> $(sw_target_w) (git 2.56.0)" "the plan names the Windows target"
    assert_contains "$OUT" "checked through $(sw_target_w): git lfs works, a fake-token commit was blocked and a clean commit printed the summary line" "the verify step ran"
    assert_contains "$OUT" "start SmartGit again" "tells the user to restart SmartGit"
}

test_the_backup_and_manifest_of_a_windows_run_hold_the_original_and_name_the_kind() {
    local mf bk
    sw_configure || return 1
    assert_rc 0 "configure"
    mf="$(echo "$SG_BACKUPS"/*.manifest)"
    bk="$(echo "$SG_BACKUPS"/*.preferences.yml)"
    assert_eq "$(sg_hash "$bk")" "$(sg_hash "$SANDBOX/prefs.orig")" "the backup is the original file"
    assert_contains "$(<"$mf")" "status=final" "the manifest is final"
    assert_contains "$(<"$mf")" "kind=windows" "it names the kind"
    assert_contains "$(<"$mf")" 'orig_executable=${smartgit.install}\git\bin\git.exe' "it names the original setting"
    assert_contains "$(<"$mf")" "new_executable=$(sw_target_w)" "and the new one"
}

test_the_checks_run_the_written_git_under_a_path_of_its_directory_and_the_system_directories() {
    local line sys n=0
    sw_configure || return 1
    assert_rc 0 "configure"
    assert_file "$SW_GFW/cmd/env.log" "the written cmd\\git.exe was run"
    sys="$(cygpath -u "$SYSTEMROOT")"
    while IFS= read -r line; do
        if [[ $line != *"path=[$SW_GFW/cmd:"* ]]; then continue; fi
        n=$((n + 1))
        assert_contains "$line" "path=[$SW_GFW/cmd:$sys/System32:$sys]" "the git directory first, then the Windows system directories and nothing of the installer's PATH"
    done <"$SW_GFW/cmd/env.log"
    if [ "$n" -lt 5 ]; then fail "the checks ran the written git only $n times with the SmartGit path"; fi
}

test_a_running_windows_smartgit_refuses_before_any_change() {
    sw_setup || return 1
    sw_ps '  1  0  1  4  ? 0 Nov  6 System' '  4711  1  4711  4711  ? 0 10:00:00 C:\Program Files\SmartGit\bin\smartgit.exe' || return 1
    sw_refused "SmartGit (of any user on this machine) is running"
    assert_contains "$ERR" "Repository, Exit" "tells the user how to exit it"
}

test_a_process_listing_that_fails_refuses_before_any_change() {
    sw_setup || return 1
    : >"$SANDBOX/ps.fail"
    sw_refused "it cannot be told whether SmartGit is running (ps -W is missing or failed)"
}

test_a_windows_settings_directory_whose_setup_never_finished_is_refused() {
    sw_setup || return 1
    rm -f -- "$SG_SETTINGS/startup" || return 1
    sw_refused "SmartGit is not set up yet here (no startup file)"
}

test_a_git_for_windows_path_a_plain_yaml_scalar_cannot_hold_is_refused_before_any_change() {
    sw_setup || return 1
    sw_gfw "$SANDBOX/gfw#x" || return 1
    set_env PATH="$SANDBOX/gfw#x/ucrt64/bin:$SANDBOX/pathbin:$TEST_BASE_PATH"
    sw_refused "is not a Windows path made of"
}

test_a_git_without_git_lfs_is_refused_with_the_repair_advice_and_nothing_is_installed() {
    sw_setup || return 1
    : >"$SW_GFW/cmd/lfs.missing" || return 1
    sw_refused "repair Git for Windows (it ships Git LFS)"
    assert_eq "$(gitx config --global --get-regexp '^filter\.lfs\.' | wc -l | tr -d ' ')" 0 "no filter was written"
}

test_git_lfs_install_runs_only_when_no_filter_is_set_and_is_recorded() {
    sw_configure || return 1
    assert_rc 0 "configure"
    assert_contains "$OUT" "Git LFS: git lfs version works through $(sw_target_w); nothing is installed" "nothing is installed"
    assert_eq "$(gitx config --global --get filter.lfs.required)" true "git lfs install wrote the filter because none existed"
    assert_eq "$(<"$SG_BACKUPS/lfs.record")" filter_added=yes "and recorded that it added it"
}

test_a_filter_that_exists_already_is_left_alone_and_not_recorded() {
    sw_setup || return 1
    sg_real_tools || return 1
    gitx config --global filter.lfs.required true || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "configure"
    assert_contains "$OUT" "filter.lfs.* is already set; git lfs install is not run" "the plan says so"
    assert_no_file "$SG_BACKUPS/lfs.record" "nothing is recorded"
    gsg restore-smartgit
    assert_rc 0 "restore"
    assert_eq "$(gitx config --global --get filter.lfs.required)" true "the user's own filter stays"
}

test_a_second_configure_run_reports_nothing_to_change() {
    sw_configure || return 1
    assert_rc 0 "first configure"
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "second configure"
    assert_contains "$OUT" "nothing to change" "nothing to do the second time"
}

test_status_after_configure_calls_the_written_git_scanned() {
    sw_configure || return 1
    assert_rc 0 "configure"
    gsg status
    assert_contains "$OUT" "SmartGit settings: $SG_SETTINGS (26.1): $(sw_target_w), git 2.56.0; commits are scanned" "the written value is read back, run and shown as written"
}

test_a_failed_verify_restores_the_original_preferences_and_says_what_was_changed() {
    sw_setup || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "the fixture scanners cannot pass the verify commit"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are byte-identical to the original again"
    assert_contains "$ERR" "SmartGit was restored from its backup" "says the restore happened"
}

# ^ invariant sw_pending_state edited|original = a configure stopped before its final manifest (file edited) or before the edit (file original)
sw_pending_state() {
    local mf bk
    sw_configure || return 1
    assert_rc 0 "configure"
    mf="$(echo "$SG_BACKUPS"/*.manifest)"
    bk="$(echo "$SG_BACKUPS"/*.preferences.yml)"
    sed -i 's/^status=final$/status=pending/' "$mf" || return 1
    assert_contains "$(<"$mf")" "status=pending" "the manifest says the change is pending"
    if [ "$1" = original ]; then cp -- "$bk" "$SG_PREFS" || return 1; fi
}

test_a_stop_after_the_edit_but_before_the_final_manifest_is_undone_by_restore() {
    sw_pending_state edited || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "rerun with the edit in place"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$(sw_target_w)" "the edit stays"
    gsg restore-smartgit
    assert_rc 0 "restore of a pending manifest"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are the original"
    assert_no_file "$SG_BACKUPS" "manifest, backup and record are gone"
}

test_a_stop_after_the_pending_manifest_but_before_the_edit_is_finished_by_a_rerun_and_by_restore() {
    sw_pending_state original || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "rerun with the original file"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$(sw_target_w)" "the edit is done"
    assert_contains "$(cat "$SG_BACKUPS"/*.manifest)" "status=final" "and the manifest is final"
    sw_pending_state original || return 1
    gsg restore-smartgit
    assert_rc 0 "restore of a pending manifest on the original file"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are the original"
    assert_no_file "$SG_BACKUPS" "manifest, backup and record are gone"
}

test_a_manual_steps_refusal_on_windows_names_the_cmd_git_exe_not_the_msys_path() {
    sw_setup || return 1
    mv -- "$SG_SETTINGS" "$SANDBOX/appdata/syntevo/SmartGit/26.2" || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "SmartGit 26.2 was never recorded"
    assert_contains "$ERR" "was not recorded" "says so"
    assert_contains "$ERR" "enter $(sw_target_w)," "the step names the Windows target"
    assert_not_contains "$ERR" "enter $SW_GFW/ucrt64" "and not the MSYS path of the git in use"
}

test_the_scratch_commits_of_the_verify_print_no_crlf_warning_and_name_no_leak_file() {
    sw_setup || return 1
    sg_real_tools || return 1
    gitx config --global core.autocrlf true || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "configure with core.autocrlf=true in the global config"
    assert_not_contains "$OUT$ERR" "LF will be replaced" "the scratch repository sets core.autocrlf=false"
    assert_not_contains "$OUT$ERR" "leak.txt" "and the scratch files have neutral names"
}

test_restore_says_so_when_smartgit_set_our_own_git_again_and_dropped_the_absolute_line() {
    local h
    sw_configure || return 1
    assert_rc 0 "configure"
    grep -v '^  executable.absolute: ' "$SG_PREFS" >"$SANDBOX/prefs.noabs" && cp -- "$SANDBOX/prefs.noabs" "$SG_PREFS" || return 1
    h="$(sg_hash "$SG_PREFS")"
    gsg restore-smartgit
    assert_rc 0 "restore"
    assert_contains "$OUT" "SmartGit rewrote its Git Executable setting" "names what happened"
    assert_contains "$OUT" "same git, the executable.absolute line differs or is gone" "and why it was left alone"
    assert_not_contains "$OUT" "was changed after this tool set it" "no contradiction with our own value"
    assert_eq "$(sg_hash "$SG_PREFS")" "$h" "the file was left alone"
    assert_eq "$(sg_hash "$(echo "$SG_BACKUPS"/*.preferences.yml)")" "$(sg_hash "$SANDBOX/prefs.orig")" "the backup is kept"
}

test_status_and_doctor_show_the_git_in_the_windows_form() {
    sw_configure || return 1
    assert_rc 0 "configure"
    gsg status
    assert_contains "$OUT" "(26.1): $(sw_target_w), git 2.56.0" "status shows C:\\ ... \\cmd\\git.exe"
    assert_not_contains "$OUT" "$SW_GFW/cmd/git.exe, git" "not the Git Bash form"
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg doctor --roots "$SANDBOX/roots"
    assert_contains "$OUT" "Git Executable is $(sw_target_w) (git 2.56.0)" "doctor shows the Windows form"
}

test_the_report_helpers_show_a_windows_kind_git_in_the_c_drive_form_and_other_kinds_as_they_are() {
    sw_run 'SG_SET_CHOICE=(other other) SG_SET_KIND=(windows linux) SG_SET_VER=(2.56.0 2.56.0) SG_SET_GIT=(/d/Tools/Git/cmd/git.exe /d/Tools/Git/cmd/git.exe)
smartgit_choice_text 0; echo; smartgit_what 0; echo; smartgit_choice_text 1'
    assert_eq "$OUT" 'D:\Tools\Git\cmd\git.exe, git 2.56.0
D:\Tools\Git\cmd\git.exe (git 2.56.0)
/d/Tools/Git/cmd/git.exe, git 2.56.0' "windows converted, linux untouched"
}

test_a_rerun_finishes_a_configure_whose_file_the_user_reverted_to_the_backup() {
    local mf bk
    sw_configure || return 1
    assert_rc 0 "configure"
    mf="$(echo "$SG_BACKUPS"/*.manifest)"
    bk="$(echo "$SG_BACKUPS"/*.preferences.yml)"
    cp -- "$bk" "$SG_PREFS" || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "rerun after the file went back to the original while the manifest stayed"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$(sw_target_w)" "the edit is in place again"
    assert_file "$mf" "one manifest"
}

test_restore_smartgit_puts_the_original_back_byte_for_byte_and_refuses_while_smartgit_runs() {
    sw_configure || return 1
    assert_rc 0 "configure"
    sw_ps '  4711  1  4711  4711  ? 0 10:00:00 C:\Program Files\SmartGit\bin\smartgitc.exe' || return 1
    gsg restore-smartgit
    assert_rc 1 "SmartGit is running"
    assert_contains "$ERR" "SmartGit (of any user on this machine) is running" "says so, for any user"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$(sw_target_w)" "nothing changed"
    sw_ps || return 1
    gsg restore-smartgit
    assert_rc 0 "restore once SmartGit is closed"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are the original"
    assert_no_file "$SG_BACKUPS" "the manifest, backup and record are gone"
    assert_eq "$(gitx config --global --get-regexp '^filter\.lfs\.' | wc -l | tr -d ' ')" 0 "the filter that git lfs install added is gone"
}

test_uninstall_restores_a_windows_smartgit() {
    sw_configure || return 1
    assert_rc 0 "configure"
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "SmartGit is back on its original setting"
    assert_no_file "$SG_BACKUPS" "no manifest or backup is left"
}

run_file_tests
