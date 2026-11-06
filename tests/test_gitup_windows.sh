#!/usr/bin/env bash
# shellcheck source=tests/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup_windows.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup_windows.sh"

# ^ invariant the entries at the root of the file system when this file was loaded (on Git Bash the Git for Windows install); the last test compares them
WU_ROOT_NAMES="$(wu_names /)"

# ^ why a uname function, not lc_begin; the module runs on Git for Windows itself and everywhere else through the same fake as tests/test_windows.sh
# ^ security every Windows tool the module reaches (reg.exe, whoami.exe, winget, curl) is a stand-in in the sandbox => no test can touch the real machine

test_the_git_for_windows_installer_is_named_located_and_pinned() {
    wu 'tools_tarball_name git-for-windows 2.56.0.4 windows_amd64'
    assert_eq "$OUT" Git-2.56.0.4-64-bit.exe "asset name"
    wu 'tools_release_url git-for-windows 2.56.0.4 windows_amd64'
    assert_eq "$OUT" https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.4/Git-2.56.0.4-64-bit.exe "tag is v<a.b.c>.windows.<n>"
    wu 'tools_lock_lookup "$GSG_ROOT/tools.lock" git-for-windows windows_amd64'
    assert_rc 0 "the lock has the row"
    assert_eq "$OUT" "2.56.0.4 4961a4a8cc778d8b6e00a5819e5fe4d078b754555aff7aedc2d77a5d74c2de80" "version and the vendor digest"
    wu 'printf "%s\n" "${GSG_TOOL_NAMES[@]}"'
    assert_not_contains "$OUT" git-for-windows "the installer is not a scanner"
}

test_the_windows_class_has_a_module_that_implements_the_contract() {
    wu 'gitup_registry windows; printf "%s" "$REPLY"'
    assert_eq "$OUT" windows "the windows line of the registry"
    wu 'gitup_check_registered_modules'
    assert_rc 0 "every registered module loads"
    assert_contains "$OUT" "checked the git upgrade module windows (class windows)" "the windows module is checked"
}

test_the_plan_without_winget_names_the_pinned_installer_and_what_runs_after_this_process() {
    wu_begin machine 2.52.0.1 || return 1
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade; echo "rc=$? route=$GITUP_ROUTE"' "$WU_GIT"
    assert_contains "$OUT" "rc=0 route=installer" "the installer route"
    assert_contains "$OUT" "Git-2.56.0.4-64-bit.exe /VERYSILENT /NORESTART /NOCANCEL /SP-" "the installer and its flags"
    assert_contains "$OUT" "SHA-256" "the digest check is named"
    assert_contains "$OUT" "tools.lock" "against the lock"
    assert_contains "$OUT" "machine-wide" "scope"
    assert_contains "$OUT" 'C:\Program Files\Git' "the existing install directory"
    assert_contains "$OUT" "2.52.0.1" "the version that is installed"
    assert_contains "$OUT" "winget was not found" "why not winget"
    assert_contains "$OUT" "after this process has ended" "nothing runs inside the bash it replaces"
    assert_contains "$OUT" "IDEs and GUI clients" "the bundled git warning stays"
    assert_not_contains "$OUT" "as root:" "no privileged command of the POSIX kind"
}

test_the_plan_with_winget_names_winget_and_its_command() {
    wu_begin machine 2.52.0.1 || return 1
    wu_winget
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade; echo "rc=$? route=$GITUP_ROUTE"' "$WU_GIT"
    assert_contains "$OUT" "rc=0 route=winget" "the winget route"
    assert_contains "$OUT" "upgrade --id Git.Git --exact --silent" "the command that will run"
    assert_not_contains "$OUT" "SHA-256" "winget checks its own manifest hash, no installer is downloaded here"
    assert_not_contains "$OUT" "Git-2.56.0.4-64-bit.exe" "no installer"
    assert_no_file "$WU_DIR/winget.log" "planning ran no winget"
}

test_a_per_user_install_is_planned_as_per_user_and_an_elevated_prompt_is_refused_for_it() {
    wu_begin user 2.52.0.1 || return 1
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade; echo "rc=$? route=$GITUP_ROUTE"' "$WU_GIT"
    assert_contains "$OUT" "rc=0 route=installer" "planned"
    assert_contains "$OUT" "per-user" "scope"
    assert_contains "$OUT" "not elevated" "no administrator rights are used"
    wu_elevated yes
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "rc=1" "refused"
    assert_contains "$OUT" "elevated" "says why"
    assert_contains "$OUT" "nothing was changed" "and that nothing changed"
}

test_an_install_that_cannot_be_matched_to_the_git_on_path_is_not_touched() {
    wu_begin machine 2.52.0.1 || return 1
    wu 'gitup_select; GSG_GIT="/c/Other/Git/cmd/git.exe"; gitup_windows_plan upgrade; echo "rc=$?"'
    assert_contains "$OUT" "rc=1" "another git is not upgraded"
    assert_contains "$OUT" "is not inside the Git for Windows install" "says so"
    rm -f -- "$WU_DIR/reg.hklm"
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "rc=1" "no setup record"
    assert_contains "$OUT" "no Git for Windows setup record" "says so"
    wu 'gitup_select; GSG_GIT=""; gitup_windows_plan upgrade; echo "rc=$?"'
    assert_contains "$OUT" "rc=1" "no git at all"
    assert_contains "$OUT" "git-scm.com/download/win" "where to get one"
}

test_a_refresh_plan_has_nothing_to_do_because_windows_has_no_build_of_ours() {
    wu_begin machine 2.56.0.4 || return 1
    wu 'gitup_select; gitup_windows_plan refresh; echo "rc=$?"'
    assert_eq "$OUT" "rc=1" "silent"
}

test_apply_downloads_verifies_and_hands_off_without_running_the_installer() {
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture good || return 1
    wu_elevated yes
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade >/dev/null; gitup_windows_apply; echo "rc=$?"; printf "NEXT=%s\n" "$GITUP_NEXT"' "$WU_GIT"
    assert_contains "$OUT" "rc=2" "the module hands off"
    assert_file "$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" "the verified installer is in the private directory"
    assert_eq "$(wu_field route)" installer "route in the hand-off"
    assert_eq "$(wu_field scope)" machine "scope in the hand-off"
    assert_eq "$(wu_field version)" 2.56.0.4 "version"
    assert_eq "$(grep -c "^sha256" "$WU_STATE_HANDOFF")" 0 "the hand-off holds no digest, the runner takes it from tools.lock"
    assert_eq "$(wu_field installer)" "$(wu_w "$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe")" "the installer path, Windows form"
    assert_no_file "$WU_DIR/installer.ran" "the installer was not run by bash"
    assert_contains "$OUT" "NEXT=" "a next step is set"
}

test_a_tampered_installer_stops_before_anything_runs_and_leaves_nothing_behind() {
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture tampered || return 1
    wu_elevated yes
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade >/dev/null; gitup_windows_apply; echo "rc=$?"; echo "CHANGED=[$GITUP_CHANGED]"' "$WU_GIT"
    assert_contains "$OUT" "rc=1" "apply fails"
    assert_contains "$ERR" "SHA-256 mismatch" "says why"
    assert_contains "$OUT" "CHANGED=[]" "nothing changed on the machine"
    assert_no_file "$WU_HANDOFF_DIR/handoff.txt" "no hand-off"
    assert_no_file "$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" "the bad download is removed"
}

test_install_started_from_git_bash_stops_with_exact_powershell_and_cmd_instructions() {
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture good || return 1
    wu_elevated yes
    wu 'GSG_GIT="$1"; GITUP_PENDING=1; gitup_offers 1 0; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "rc=3" "install stops with the hand-off status"
    assert_contains "$OUT" "must be finished outside this process" "the core says so"
    assert_contains "$OUT" "close every Git Bash window" "the shell that is replaced is closed first"
    assert_contains "$OUT" 'powershell -NoProfile -ExecutionPolicy Bypass -File "' "the PowerShell command"
    assert_contains "$OUT" 'gsg-gitup.ps1" "' "with the runner and the hand-off file"
    assert_contains "$OUT" 'git-secret-guard.cmd" install' "and the command to run after it"
    assert_file "$WU_STATE_HANDOFF" "the hand-off is in the state directory when no front end gave a place"
    assert_no_file "$WU_DIR/installer.ran" "the installer did not run from inside bash"
}

test_a_cmd_front_end_names_the_hand_off_file_and_gets_a_next_step_it_runs_itself() {
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture good || return 1
    wu_elevated yes
    set_env GSG_HANDOFF="$(wu_w "$WU_FRONT_DIR/git-upgrade/handoff.txt")"
    wu 'GSG_GIT="$1"; GITUP_PENDING=1; gitup_offers 1 0; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "rc=3" "hand-off"
    assert_file "$WU_FRONT_DIR/git-upgrade/handoff.txt" "the place the front end named"
    assert_file "$WU_FRONT_DIR/git-upgrade/Git-2.56.0.4-64-bit.exe" "and the installer beside it"
    assert_not_contains "$OUT" "close every Git Bash window" "the front end carries on by itself"
    assert_contains "$OUT" "git-secret-guard.cmd runs the verified installer next" "says what happens"
    assert_no_file "$WU_STATE_HANDOFF" "the state directory is not used"
}

test_a_hand_off_place_outside_the_profile_or_with_other_names_is_refused() {
    local bad
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture good || return 1
    wu_elevated yes
    for bad in "$WU_DIR/home/AppData/Local/notours/git-upgrade/handoff.txt" "$SANDBOX/elsewhere/git-upgrade/handoff.txt" "$WU_FRONT_DIR/other/handoff.txt" "$WU_FRONT_DIR/git-upgrade/x.txt" "$WU_FRONT_DIR/git-upgrade/../git-upgrade/handoff.txt"; do
        EXTRA_ENV=()
        wu_env
        set_env GSG_HANDOFF="$bad"
        wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade >/dev/null; gitup_windows_apply; echo "rc=$?"' "$WU_GIT"
        assert_contains "$OUT" "rc=1" "refused: $bad"
        assert_contains "$ERR" "GSG_HANDOFF" "names the variable: $bad"
        assert_not_exists_any "$SANDBOX/elsewhere" "$WU_FRONT_DIR/other"
    done
}

test_a_rerun_with_a_qualifying_git_prompts_for_nothing_downloads_nothing_and_calls_no_winget() {
    wu_begin machine 2.56.0.4 || return 1
    wu_winget
    wu_fixture good || return 1
    wu_curl_recorder
    wu 'GSG_GIT="$1"; GITUP_PENDING=0; gitup_offers 0 0 </dev/null; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "rc=0" "install goes on"
    assert_not_contains "$OUT$ERR" "[y/N]" "no prompt"
    assert_no_file "$WU_DIR/winget.log" "no winget call"
    assert_no_file "$WU_DIR/curl.log" "no download"
    assert_no_file "$WU_STATE_HANDOFF" "no hand-off"
}

test_with_no_terminal_and_no_flag_the_upgrade_is_refused_naming_the_flag_and_changing_nothing() {
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture good || return 1
    wu_curl_recorder
    wu_winget
    wu 'GSG_GIT="$1"; GITUP_PENDING=1; gitup_offers 0 0 </dev/null; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "rc=1" "refused"
    assert_contains "$ERR" "install --upgrade-git" "the flag is named"
    assert_contains "$ERR" "no terminal to ask on" "and why it was not asked"
    assert_no_file "$WU_DIR/curl.log" "nothing downloaded"
    assert_no_file "$WU_DIR/winget.log" "no winget"
    assert_no_file "$WU_STATE_HANDOFF" "no hand-off"
}

test_the_hint_for_an_old_git_names_the_upgrade_flag() {
    wu 'install_git_hint'
    assert_contains "$ERR" "install --upgrade-git" "the flag"
    assert_contains "$ERR" "winget" "winget stays a way"
    assert_contains "$ERR" "new terminal" "and a new terminal"
}

test_the_plan_flags_and_the_runner_flags_are_the_same_list() {
    wu 'gitup_select; printf "%s " "${GITUP_WIN_FLAGS[@]}"'
    assert_eq "$OUT" "/VERYSILENT /NORESTART /NOCANCEL /SP- " "the module"
    assert_contains "$(<"$GSG_PROJECT/bin/gsg-gitup.ps1")" "'/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-'" "the runner"
}

test_every_batch_and_runner_file_of_the_hand_off_is_crlf_or_lf_as_its_kind_requires() {
    local f
    for f in git-secret-guard.cmd gsg-bash.cmd; do
        assert_eq "$(tr -cd '\r' <"$GSG_PROJECT/bin/$f" | wc -c | tr -d ' ')" "$(wc -l <"$GSG_PROJECT/bin/$f" | tr -d ' ')" "$f has CRLF on every line"
    done
    assert_eq "$(tr -cd '\r' <"$GSG_PROJECT/bin/gsg-gitup.ps1" | wc -c | tr -d ' ')" 0 "the runner is LF like every file that is not a batch file"
    assert_eq "$(LC_ALL=C tr -d '\000-\177' <"$GSG_PROJECT/bin/gsg-gitup.ps1" | wc -c | tr -d ' ')" 0 "and plain ASCII, which Windows PowerShell 5.1 reads without a byte order mark"
}


test_the_runner_verifies_the_digest_again_and_starts_the_installer_with_the_silent_flags() {
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 0 "the runner finished"
    assert_eq "$(wu_installer_log)" "/VERYSILENT /NORESTART /NOCANCEL /SP-" "the installer was started once with exactly the story's flags"
    assert_contains "$OUT" "verified" "the digest check is reported"
}

test_a_tampered_installer_never_runs_when_it_is_swapped_after_the_download_was_verified() {
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    printf 'swapped after the download was verified\n' >>"$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 10 "the digest no longer matches"
    assert_contains "$ERR" "was NOT run" "says so"
    assert_contains "$ERR" "install --upgrade-git" "and how to retry"
    assert_eq "$(wu_installer_log)" "" "the installer never ran"
}

test_a_missing_installer_or_a_failing_one_is_reported_with_how_to_retry() {
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    cp -- "$WU_STATE_HANDOFF" "$WU_DIR/handoff.copy" || return 1
    printf '3' >"$WU_DIR/standin/exit.txt" || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 12 "the installer's own failure"
    assert_contains "$ERR" "returned 3" "its exit code"
    assert_contains "$ERR" "git --version" "what to check"
    cp -- "$WU_DIR/handoff.copy" "$WU_STATE_HANDOFF" || return 1
    rm -f -- "$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 10 "no installer file"
    assert_contains "$ERR" "nothing was run" "nothing ran"
}

test_a_hand_off_that_is_not_ours_or_names_another_installer_is_refused_before_anything_runs() {
    local h
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    h="$WU_HANDOFF_DIR/other.txt"
    printf 'hello\n' >"$h" || return 1
    wu_runner "$h"
    assert_rc 13 "not a hand-off"
    sed "s|^installer=.*|installer=$(cygpath -w "$SANDBOX/standin/standin.exe")|" "$WU_STATE_HANDOFF" >"$h" || return 1
    wu_runner "$h"
    assert_rc 13 "an installer elsewhere"
    assert_contains "$ERR" "beside the hand-off" "says why"
    sed "s|^route=.*|route=curl|" "$WU_STATE_HANDOFF" >"$h" || return 1
    wu_runner "$h"
    assert_rc 13 "an unknown route"
    wu_runner "$WU_HANDOFF_DIR/missing.txt"
    assert_rc 13 "no file"
    assert_eq "$(wu_installer_log)" "" "nothing ran in any of the cases"
}

test_a_per_user_hand_off_is_refused_by_an_elevated_runner_and_nothing_runs() {
    wu_need_windows_runner
    wu_prepare_handoff user || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 14 "refused"
    assert_contains "$ERR" "could install machine-wide" "says why"
    assert_eq "$(wu_installer_log)" "" "the installer never ran"
}

# ^ invariant wu_e2e_setup copies the product to $SANDBOX/proj with a stand-in CLI running the REAL gitup core and module for an old git
# ^ why a stand-in CLI, not install; the bash.exe of Git for Windows puts its own git first on PATH, no fake old git wins in a bash the .cmd file starts
# ^ invariant the stand-in installer creates a marker file; the second run of the CLI answers "done", as a new git would let install go on
WU_PROJ=""
wu_e2e_setup() {
    wu_need_windows_runner
    wu_begin machine 2.43.0 || return 1
    wu_fixture_exe || return 1
    WU_PROJ="$SANDBOX/proj"
    mkdir -p -- "$WU_PROJ" "$WU_DIR/oldgit" "$WU_DIR/home/AppData/Local" || return 1
    cp -R -- "$GSG_PROJECT/bin" "$GSG_PROJECT/lib" "$GSG_PROJECT/tools.lock" "$GSG_PROJECT/VERSION" "$WU_PROJ/" || return 1
    cp -- "$WU_RT/bin/gsg-gitup.ps1" "$WU_PROJ/bin/gsg-gitup.ps1" && cp -- "$WU_LOCK" "$WU_PROJ/tools.lock" || return 1
    printf '#!/bin/sh\necho "git version 2.43.0"\n' >"$WU_DIR/oldgit/git" && chmod 755 "$WU_DIR/oldgit/git" || return 1
    printf '    Inno Setup: App Path    REG_SZ    %s\n    DisplayVersion    REG_SZ    2.43.0\n' "$(cygpath -w "$WU_DIR/oldgit")" >"$WU_DIR/reg.hklm" || return 1
    printf '%s|%s' "$(cygpath -w "$GSG_PROJECT/VERSION")" "$(cygpath -w "$WU_DIR/standin/new-git-installed")" >"$WU_DIR/standin/copy.txt" || return 1
    # ^ external a native cmd.exe mangles an environment value shaped like a URL or path => the CLI exports what it needs itself
    {
        printf '#!/usr/bin/env bash\nset -u\n'
        printf 'export GSG_TOOLS_BASE_URL=%q GSG_TOOLS_LOCK=%q GSG_GITUP_ROOT=%q GU_E2E_DONE=%q GU_E2E_GIT=%q GSG_STANDIN_DIR=%q GU_E2E_NOWRITE=%q\n' \
            "file:///$(cygpath -m "$WU_DIR/fix")" "$WU_LOCK" "$WU_DIR/root" "$WU_DIR/standin/new-git-installed" "$WU_DIR/oldgit/git" "$(cygpath -w "$WU_DIR/standin")" "$WU_DIR/e2e.nowrite"
        cat <<'CLI'
GSG_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
GSG_NAME=git-secret-guard
if [ -f "$GU_E2E_NOWRITE" ]; then exit 3; fi
if [ -f "$GU_E2E_DONE" ]; then
    echo "second run done: $* upgraded=${GSG_GIT_UPGRADED:-}"
    exit 0
fi
for lib in brew common state tools hookspath install install_tools gitup gitup_source; do source "$GSG_ROOT/lib/$lib.sh" || exit 9; done
INSTALL_TIMEOUT_BIN="$(type -P timeout)"
GSG_GIT="$GU_E2E_GIT"
GITUP_PENDING=1
gitup_offers 1 0
exit $?
CLI
    } >"$WU_PROJ/bin/git-secret-guard" || return 1
    chmod 755 "$WU_PROJ/bin/git-secret-guard" || return 1
    set_env LOCALAPPDATA="$(cygpath -w "$WU_DIR/home/AppData/Local")" GSG_STANDIN_DIR="$(cygpath -w "$WU_DIR/standin")" ProgramFiles="$PROGRAMFILES"
}

# ^ external MSYS turns /c into a path for a native cmd.exe, and an environment switch would reach the bash below => //c
wu_cmd() {
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$TEST_SYSTEM32/cmd.exe" //c "$(cygpath -w "$WU_PROJ/bin/git-secret-guard.cmd")" "$@"
    OUT="$(<"$SANDBOX/.out")"
    ERR="$(<"$SANDBOX/.err")"
}

test_the_cmd_front_end_runs_the_verified_installer_after_bash_has_ended_and_then_runs_the_command_again() {
    wu_e2e_setup || return 1
    wu_cmd install --upgrade-git </dev/null
    assert_rc 0 "the command after the upgrade"
    assert_contains "$OUT" "git upgrade plan for this windows system" "the plan was printed first"
    assert_contains "$OUT" "must be finished outside this process" "bash stopped for the hand-off"
    assert_contains "$OUT" "verified" "the runner checked the digest again"
    assert_eq "$(wu_installer_log)" "/VERYSILENT /NORESTART /NOCANCEL /SP-" "the installer ran once, with the story's flags"
    assert_contains "$OUT" "second run done: install --upgrade-git" "the command ran again with its own arguments"
    assert_contains "$OUT" "upgraded=1" "the run after the hand-off knows that git was upgraded just before"
    assert_no_file "$WU_DIR/home/AppData/Local/git-secret-guard/git-upgrade/handoff.txt" "the hand-off was consumed"
    assert_no_file "$WU_DIR/home/AppData/Local/git-secret-guard/git-upgrade/Git-2.56.0.4-64-bit.exe" "and the installer deleted after its success"
}

test_the_cmd_front_end_passes_a_failing_runner_exit_code_on_and_does_not_run_the_command_again() {
    wu_e2e_setup || return 1
    printf '5' >"$WU_DIR/standin/exit.txt" || return 1
    wu_cmd install --upgrade-git </dev/null
    assert_rc 12 "the runner's status"
    assert_contains "$ERR" "returned 5" "its message"
    assert_not_contains "$OUT" "second run done" "the command did not run again"
}

test_a_tampered_download_stops_the_cmd_front_end_before_any_installer_starts() {
    wu_e2e_setup || return 1
    printf 'tampered\n' >>"$WU_DIR/fix/Git-2.56.0.4-64-bit.exe" || return 1
    wu_cmd install --upgrade-git </dev/null
    assert_rc 1 "bash refuses the download itself"
    assert_contains "$ERR" "SHA-256 mismatch" "says why"
    assert_eq "$(wu_installer_log)" "" "nothing ran"
    assert_not_contains "$OUT" "second run done" "and nothing followed"
}

test_the_installed_cmd_wrapper_hands_off_the_same_way_as_the_one_in_the_checkout() {
    wu_e2e_setup || return 1
    mkdir -p -- "$SANDBOX/instbin" || return 1
    wu 'GSG_SHARE="$1"; install_cli_cmd_text >"$2"' "$WU_PROJ" "$SANDBOX/instbin/git-secret-guard.cmd"
    assert_rc 0 "the wrapper text is written"
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$TEST_SYSTEM32/cmd.exe" //c "$(cygpath -w "$SANDBOX/instbin/git-secret-guard.cmd")" install --upgrade-git </dev/null
    OUT="$(<"$SANDBOX/.out")"
    assert_rc 0 "the command after the upgrade"
    assert_contains "$OUT" "verified" "the runner of the share dir checked the digest"
    assert_eq "$(wu_installer_log)" "/VERYSILENT /NORESTART /NOCANCEL /SP-" "the installer ran once"
    assert_contains "$OUT" "second run done: install --upgrade-git" "and the command ran again"
    assert_file "$SANDBOX/instbin/git-secret-guard.cmd" "the wrapper stays while the share dir exists"
}

test_with_winget_the_hand_off_carries_no_installer_and_the_runner_runs_winget_with_the_planned_arguments() {
    wu_need_windows_runner
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture_exe || return 1
    mkdir -p -- "$WU_DIR/standin" || return 1
    cp -- "$SANDBOX/standin/standin.exe" "$WU_DIR/pathbin/winget.exe" || return 1
    set_env GSG_STANDIN_DIR="$(cygpath -w "$WU_DIR/standin")"
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade >/dev/null; echo "route=$GITUP_ROUTE"; gitup_windows_apply; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "route=winget" "winget was found on PATH"
    assert_contains "$OUT" "rc=2" "handed off"
    assert_eq "$(wu_field route)" winget "route in the hand-off"
    assert_eq "$(wu_field installer)" "" "no installer in it"
    assert_eq "$(ls "$WU_HANDOFF_DIR")" handoff.txt "and nothing downloaded"
    cp -- "$WU_STATE_HANDOFF" "$WU_DIR/handoff.copy" || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 0 "the runner finished"
    assert_eq "$(wu_installer_log)" "upgrade --id Git.Git --exact --silent --accept-source-agreements --accept-package-agreements --scope machine" "winget ran with the planned arguments and scope"
    cp -- "$WU_DIR/handoff.copy" "$WU_STATE_HANDOFF" || return 1
    printf '7' >"$WU_DIR/standin/exit.txt" || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 12 "a failing winget"
    assert_contains "$ERR" "winget returned 7" "its exit code"
}


test_the_place_is_checked_against_localappdata_not_home_and_without_regard_to_case() {
    local w upper
    wu_begin machine 2.52.0.1 || return 1
    w="$(wu_w "$WU_DIR/home/AppData/Local")"
    upper="${w^^}"
    EXTRA_ENV=()
    wu_env
    set_env HOME="$WU_DIR/elsewhere" GSG_HANDOFF="$w\\git-secret-guard\\git-upgrade\\handoff.txt"
    wu 'gitup_select; gitup_windows_handoff_place; echo "rc=$? front=$GITUP_WIN_FRONT"'
    assert_contains "$OUT" "rc=0 front=1" "a HOME that is not above LOCALAPPDATA does not matter"
    set_env GSG_HANDOFF="$upper\\git-secret-guard\\git-upgrade\\handoff.txt"
    wu 'gitup_select; gitup_windows_handoff_place; echo "rc=$?"'
    assert_contains "$OUT" "rc=0" "upper case in the path is the same place"
    set_env LOCALAPPDATA=
    wu 'gitup_select; gitup_windows_handoff_place; echo "rc=$?"'
    assert_contains "$OUT" "rc=1" "without LOCALAPPDATA there is no place to trust"
    assert_contains "$ERR" "GSG_HANDOFF" "and the variable is named"
}

test_the_state_route_gets_the_same_place_checks_and_a_link_on_the_way_is_refused() {
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture good || return 1
    wu_elevated yes
    mkdir -p -- "$WU_DIR/real/git-upgrade" || return 1
    printf 'precious\n' >"$WU_DIR/real/git-upgrade/handoff.txt" || return 1
    ln -s "$WU_DIR/real" "$WU_DIR/xdg/state/git-secret-guard" || return 1
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade >/dev/null; gitup_windows_apply; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "rc=1" "refused"
    assert_contains "$ERR" "symbolic link or junction" "says why"
    assert_eq "$(<"$WU_DIR/real/git-upgrade/handoff.txt")" precious "nothing behind the link was cleaned or replaced"
    assert_eq "$(ls "$WU_DIR/real/git-upgrade")" handoff.txt "and nothing was downloaded into it"
}

test_a_state_directory_without_the_expected_names_is_refused_on_the_default_route() {
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture good || return 1
    wu_elevated yes
    wu 'gitup_select; state_dir_path() { printf "/tmp/../x"; }; GSG_GIT="$1"; gitup_windows_plan upgrade >/dev/null; gitup_windows_apply; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "rc=1" "a .. component is refused on this route too"
    assert_contains "$ERR" "XDG_STATE_HOME" "and the variable is named"
}

test_apply_removes_stale_hand_offs_and_installers_but_nothing_else() {
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture good || return 1
    wu_elevated yes
    mkdir -p -- "$WU_HANDOFF_DIR" || return 1
    printf 'old\n' >"$WU_HANDOFF_DIR/Git-1.0.0.1-64-bit.exe" && printf 'old\n' >"$WU_HANDOFF_DIR/handoff.txt" \
        && printf 'old\n' >"$WU_HANDOFF_DIR/handoff.txt.123" && printf 'mine\n' >"$WU_HANDOFF_DIR/keep.txt" || return 1
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade >/dev/null; gitup_windows_apply; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "rc=2" "handed off"
    assert_no_file "$WU_HANDOFF_DIR/Git-1.0.0.1-64-bit.exe" "the stale installer is gone"
    assert_no_file "$WU_HANDOFF_DIR/handoff.txt.123" "and the stale temp file"
    assert_eq "$(wu_field version)" 2.56.0.4 "the hand-off is the new one"
    assert_eq "$(<"$WU_HANDOFF_DIR/keep.txt")" mine "a file of the user's stays"
}

test_the_winget_command_carries_the_scope_of_the_plan() {
    wu_begin user 2.52.0.1 || return 1
    wu_winget
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade; echo "route=$GITUP_ROUTE"' "$WU_GIT"
    assert_contains "$OUT" "route=winget" "winget"
    assert_contains "$OUT" "--accept-package-agreements --scope user" "the per-user plan asks winget for the user scope"
    assert_contains "$OUT" "not tested here" "and does not promise what was not tested"
    assert_not_contains "$OUT" "checks the hash of its own manifest" "no claim about winget's own checks"
    wu_begin machine 2.52.0.1 || return 1
    wu_winget
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade >/dev/null; echo "route=$GITUP_ROUTE"; gitup_windows_apply; echo "NEXT=$GITUP_NEXT"' "$WU_GIT"
    assert_contains "$OUT" "NEXT=close every Git Bash window" "the Git Bash next step"
    set_env GSG_HANDOFF="$(wu_w "$WU_FRONT_DIR/git-upgrade/handoff.txt")"
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade >/dev/null; gitup_windows_apply; echo "NEXT=$GITUP_NEXT"' "$WU_GIT"
    assert_contains "$OUT" "runs winget next" "the front end next step names winget, not an installer"
    assert_not_contains "$OUT" "verified installer" "which was not downloaded"
}

test_the_hint_after_a_refused_plan_does_not_recommend_the_flag_that_would_refuse_too() {
    wu_begin machine 2.52.0.1 || return 1
    printf '#!/bin/sh\necho "git version 2.43.0"\n' >"$WU_DIR/pathbin/git" && chmod 755 "$WU_DIR/pathbin/git" || return 1
    wu 'install_find_git; GITUP_PENDING=1; gitup_offers 1 0 </dev/null; echo "rc=$?"'
    assert_contains "$OUT" "rc=1" "refused"
    assert_contains "$ERR" "yourself" "the user is told to update it"
    assert_not_contains "$ERR" "install --upgrade-git" "the flag is not recommended after a refused plan"
}

test_a_refusal_in_the_run_after_the_hand_off_does_not_claim_nothing_changed() {
    wu 'brew_unchanged_text'
    assert_eq "$OUT" "nothing was changed" "an ordinary run"
    wu 'GSG_GIT_UPGRADED=1 brew_unchanged_text'
    assert_not_contains "$OUT" "nothing was changed" "after the hand-off"
    assert_contains "$OUT" "Git for Windows was upgraded just before this run" "says what changed"
    assert_contains "$(<"$GSG_PROJECT/bin/git-secret-guard.cmd")" 'set "GSG_GIT_UPGRADED=1"' "the checkout .cmd sets it for the second run"
    wu 'GSG_SHARE=/c/U/share; install_cli_cmd_text'
    assert_contains "$OUT" 'set "GSG_GIT_UPGRADED=1"' "and so does the installed one"
}

test_the_git_bash_next_step_keeps_the_flags_of_the_install_that_stopped() {
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture good || return 1
    wu_elevated yes
    wu 'GSG_INSTALL_FLAGS=" --replace-hooks-path"; GSG_GIT="$1"; GITUP_PENDING=1; gitup_offers 1 0; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "rc=3" "hand-off"
    assert_contains "$OUT" 'git-secret-guard.cmd" install --replace-hooks-path' "the flag is in the command to run after the upgrade"
}

test_uninstall_removes_the_hand_off_files_in_both_places_and_nothing_else() {
    wu_begin machine 2.52.0.1 || return 1
    mkdir -p -- "$WU_HANDOFF_DIR" "$WU_FRONT_DIR/git-upgrade" || return 1
    printf 'x\n' >"$WU_HANDOFF_DIR/handoff.txt" && printf 'x\n' >"$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" || return 1
    printf 'x\n' >"$WU_FRONT_DIR/git-upgrade/handoff.txt" && printf 'x\n' >"$WU_FRONT_DIR/git-upgrade/Git-2.56.0.4-64-bit.exe" || return 1
    wu 'GSG_STATE_DIR="$XDG_STATE_HOME/git-secret-guard"; uninstall_gitup_handoff; echo "rc=$?"'
    assert_contains "$OUT" "rc=0" "done"
    assert_contains "$OUT" "removed the files of a git upgrade hand-off" "said"
    assert_no_file "$WU_HANDOFF_DIR" "the state side is gone"
    assert_no_file "$WU_FRONT_DIR" "and the LocalAppData side"
    mkdir -p -- "$WU_FRONT_DIR/git-upgrade" || return 1
    printf 'mine\n' >"$WU_FRONT_DIR/git-upgrade/other.txt" || return 1
    printf 'x\n' >"$WU_FRONT_DIR/git-upgrade/handoff.txt" || return 1
    wu 'GSG_STATE_DIR="$XDG_STATE_HOME/git-secret-guard"; uninstall_gitup_handoff; echo "rc=$?"'
    assert_eq "$(<"$WU_FRONT_DIR/git-upgrade/other.txt")" mine "a file that is not ours stays, and so does its directory"
    assert_no_file "$WU_FRONT_DIR/git-upgrade/handoff.txt" "ours went"
}

test_the_runner_consumes_the_hand_off_and_deletes_the_installer_after_success() {
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    cp -- "$WU_STATE_HANDOFF" "$WU_DIR/handoff.copy" || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 0 "first run"
    assert_no_file "$WU_STATE_HANDOFF" "the hand-off is deleted"
    assert_no_file "$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" "and the installer after its success"
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 13 "running the same hand-off again finds nothing"
    assert_contains "$ERR" "used once" "says why"
    cp -- "$WU_DIR/handoff.copy" "$WU_STATE_HANDOFF" || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 10 "an old copy of the hand-off finds no installer to downgrade with"
    assert_eq "$(wu_installer_log)" "/VERYSILENT /NORESTART /NOCANCEL /SP-" "the installer ran exactly once"
}

test_the_digest_comes_from_tools_lock_so_a_hand_off_cannot_vouch_for_a_swapped_installer() {
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    printf 'swapped\n' >>"$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" || return 1
    printf 'sha256=%s\n' "$(sha256sum -- "$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" | cut -d' ' -f1)" >>"$WU_STATE_HANDOFF" || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 13 "a digest in the hand-off is not even a known key"
    assert_contains "$ERR" "unknown key" "says so"
    sed -i '/^sha256=/d' "$WU_STATE_HANDOFF" || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 10 "the swapped installer fails the tools.lock pin"
    assert_contains "$ERR" "tools.lock pin" "says so"
    assert_eq "$(wu_installer_log)" "" "nothing ran"
    assert_no_file "$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" "the refused file is deleted"
}

test_the_cmd_front_end_does_not_run_a_stale_hand_off_that_this_run_did_not_write() {
    local d
    wu_e2e_setup || return 1
    : >"$WU_DIR/e2e.nowrite"
    d="$WU_DIR/home/AppData/Local/git-secret-guard/git-upgrade"
    mkdir -p -- "$d" || return 1
    cp -- "$SANDBOX/standin/standin.exe" "$d/Git-2.56.0.4-64-bit.exe" || return 1
    printf 'gsg-git-upgrade-handoff 1\nroute=installer\nscope=machine\nversion=2.56.0.4\ninstaller=%s\n' "$(cygpath -w "$d/Git-2.56.0.4-64-bit.exe")" >"$d/handoff.txt" || return 1
    wu_cmd install --upgrade-git </dev/null
    assert_rc 3 "bash stopped with 3 and wrote no hand-off"
    assert_eq "$(wu_installer_log)" "" "the stale one was not run"
    assert_no_file "$d/handoff.txt" "and the .cmd deleted it"
    mkdir -p -- "$SANDBOX/instbin" || return 1
    printf 'gsg-git-upgrade-handoff 1\nroute=installer\nscope=machine\nversion=2.56.0.4\ninstaller=%s\n' "$(cygpath -w "$d/Git-2.56.0.4-64-bit.exe")" >"$d/handoff.txt" || return 1
    wu 'GSG_SHARE="$1"; install_cli_cmd_text >"$2"' "$WU_PROJ" "$SANDBOX/instbin/git-secret-guard.cmd"
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$TEST_SYSTEM32/cmd.exe" //c "$(cygpath -w "$SANDBOX/instbin/git-secret-guard.cmd")" install --upgrade-git </dev/null
    assert_rc 3 "the installed .cmd: bash stopped with 3"
    assert_eq "$(wu_installer_log)" "" "the stale one was not run by the installed .cmd either"
}


test_the_runner_reads_no_environment_variable() {
    assert_eq "$(grep -c '\$env:' "$GSG_PROJECT/bin/gsg-gitup.ps1")" 0 "no environment variable is read, so none can weaken a check"
    assert_eq "$(grep -c 'gsg-signer git-for-windows' "$GSG_PROJECT/tools.lock")" 1 "the signer is data in tools.lock next to the digest row"
}

test_an_installer_that_is_unsigned_or_signed_by_another_signer_is_refused_though_its_digest_is_pinned() {
    local re
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    cp -- "$SANDBOX/standin/standin-unsigned.exe" "$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" || return 1
    wu_write_lock "$(sha256sum -- "$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" | cut -d' ' -f1)" || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 10 "unsigned"
    assert_contains "$ERR" "NotSigned" "the status is named"
    re='NotSigned, expected UnknownError \(.+\)'
    [[ $ERR =~ $re ]] || fail "the refusal carries the status message Windows gives: [${ERR:0:300}]"
    assert_contains "$ERR" "will not help" "and the user is told that a rerun does not help"
    assert_contains "$ERR" "git-scm.com/download/win" "and what to do instead"
    assert_not_contains "$ERR" "Run: git-secret-guard install --upgrade-git" "not the same command again"
    assert_eq "$(wu_installer_log)" "" "nothing ran"
    assert_file "$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" "a file that matches its pin is not deleted"
    assert_no_file "$WU_STATE_HANDOFF" "the hand-off is used up"
    wu_prepare_handoff machine || return 1
    wu_write_lock "$WU_SHA" "CN=Someone Else" || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 10 "a signer that is not the one the lock names"
    assert_contains "$ERR" "the signer of" "says so"
    assert_contains "$ERR" "is the pin of tools.lock" "names the pin as the thing to look at"
    assert_not_contains "$ERR" "cannot validate the vendor signature" "and does not blame the machine when the signature is Valid"
    assert_not_contains "$ERR" "will not help" "a rerun text belongs to a failed status only"
    assert_eq "$(wu_installer_log)" "" "nothing ran"
}

test_a_junction_in_the_two_directories_install_made_is_refused_and_a_good_installer_stays() {
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    wu_mklink "$WU_DIR/jx" "$WU_HANDOFF_DIR" || return 1
    printf 'gsg-git-upgrade-handoff 1\nroute=installer\nscope=machine\nversion=2.56.0.4\ninstaller=%s\n' "$(cygpath -w "$WU_DIR/jx")\\Git-2.56.0.4-64-bit.exe" >"$WU_STATE_HANDOFF" || return 1
    wu_runner "$WU_DIR/jx/handoff.txt"
    wu_rmlink "$WU_DIR/jx"
    assert_rc 10 "refused"
    assert_contains "$ERR" "junction or symbolic link" "says why"
    assert_contains "$ERR" "Remove or replace that directory link" "and what to do"
    assert_eq "$(wu_installer_log)" "" "nothing ran"
    assert_file "$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" "the installer, which matched its pin, was not deleted"
}

test_a_junction_above_the_profile_root_is_accepted_by_bash_and_by_the_runner() {
    wu_need_windows_runner
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture_exe || return 1
    wu_elevated no
    mkdir -p -- "$WU_DIR/pjreal/Local" || return 1
    wu_mklink "$WU_DIR/pj" "$WU_DIR/pjreal" || return 1
    set_env LOCALAPPDATA="$(cygpath -w "$WU_DIR/pj")\\Local" GSG_HANDOFF="$(cygpath -w "$WU_DIR/pj")\\Local\\git-secret-guard\\git-upgrade\\handoff.txt"
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade >/dev/null; gitup_windows_apply; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "rc=2" "bash accepts a place behind a moved profile"
    wu_runner "$WU_DIR/pj/Local/git-secret-guard/git-upgrade/handoff.txt"
    wu_rmlink "$WU_DIR/pj"
    assert_rc 0 "and so does the runner"
    assert_eq "$(wu_installer_log)" "/VERYSILENT /NORESTART /NOCANCEL /SP-" "the installer ran"
}

test_the_installer_and_its_directories_cannot_be_changed_between_the_checks_and_its_start() {
    local inst pid n=0 w d rn rd rp
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    inst="$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe"
    set_env GSG_TEST_HOLD="$(cygpath -w "$WU_DIR/hold")"
    wu_shadow_script
    env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" GSG_TEST_VERBLOG="$(cygpath -w "$WU_DIR/verbs.log")" GSG_TEST_RUNNER="$(cygpath -w "$WU_RT/bin/gsg-gitup.ps1")" \
        GSG_TEST_HANDOFF="$(cygpath -w "$WU_STATE_HANDOFF")" "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass \
        -File "$(cygpath -w "$WU_DIR/shadow.ps1")" ok >"$WU_DIR/run.out" 2>"$WU_DIR/run.err" &
    pid=$!
    while [ ! -e "$WU_DIR/hold.held" ] && [ "$n" -lt 150 ]; do
        sleep 0.2
        n=$((n + 1))
    done
    assert_file "$WU_DIR/hold.held" "the runner reached the point between the checks and the start"
    assert_no_file "$WU_STATE_HANDOFF" "the hand-off is consumed before the start"
    printf 'x' >>"$inst" 2>/dev/null
    w=$?
    rm -f -- "$inst" 2>/dev/null
    d=$?
    mv -- "$inst" "$inst.moved" 2>/dev/null
    rn=$?
    mv -- "$WU_HANDOFF_DIR" "$WU_HANDOFF_DIR.x" 2>/dev/null
    rd=$?
    mv -- "${WU_HANDOFF_DIR%/*}" "${WU_HANDOFF_DIR%/*}.x" 2>/dev/null
    rp=$?
    assert_eq "$([ "$w" -ne 0 ] && echo refused || echo SUCCEEDED)" refused "writing to the installer"
    assert_eq "$([ "$d" -ne 0 ] && echo refused || echo SUCCEEDED)" refused "deleting the installer"
    assert_eq "$([ "$rn" -ne 0 ] && echo refused || echo SUCCEEDED)" refused "renaming the installer"
    assert_eq "$([ "$rd" -ne 0 ] && echo refused || echo SUCCEEDED)" refused "renaming its directory"
    assert_eq "$([ "$rp" -ne 0 ] && echo refused || echo SUCCEEDED)" refused "renaming the directory above"
    : >"$WU_DIR/hold.go"
    wait "$pid"
    assert_eq "$?" 0 "the runner finished"
    assert_eq "$(wu_installer_log)" "/VERYSILENT /NORESTART /NOCANCEL /SP-" "and started the installer that was checked"
}

test_a_machine_wide_upgrade_from_a_normal_prompt_asks_for_elevation_and_the_exit_code_comes_back() {
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    wu_runner_elevation false || return 1
    printf '7' >"$WU_DIR/standin/exit.txt" || return 1
    wu_runner_shadow ok "$WU_STATE_HANDOFF"
    assert_rc 12 "the installer's exit code 7 came back through RunAs"
    assert_eq "$(wu_verbs)" "verb=RunAs" "RunAs was requested"
    assert_eq "$(wu_installer_log)" "/VERYSILENT /NORESTART /NOCANCEL /SP-" "and the installer ran with the held file"
}

test_no_elevation_is_requested_when_the_prompt_is_elevated_or_the_install_is_per_user() {
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    wu_runner_elevation true || return 1
    wu_runner_shadow ok "$WU_STATE_HANDOFF"
    assert_rc 0 "elevated machine-wide"
    assert_eq "$(wu_verbs)" "verb=" "no verb"
    wu_prepare_handoff user || return 1
    wu_runner_elevation false || return 1
    wu_runner_shadow ok "$WU_STATE_HANDOFF"
    assert_rc 0 "per-user from a normal prompt"
    assert_eq "$(wu_verbs)" "verb=" "no verb either"
}

test_a_declined_elevation_prompt_stops_the_upgrade_with_nothing_changed() {
    local mode
    wu_need_windows_runner
    for mode in decline wrapped; do
        wu_prepare_handoff machine || return 1
        wu_runner_elevation false || return 1
        wu_runner_shadow "$mode" "$WU_STATE_HANDOFF"
        assert_rc 11 "declined [$mode]"
        assert_contains "$ERR" "was declined" "says so [$mode]"
        assert_contains "$ERR" "nothing was changed" "and that nothing changed [$mode]"
        assert_contains "$ERR" "install --upgrade-git" "and how to retry [$mode]"
        assert_eq "$(wu_verbs)" "verb=RunAs" "the prompt was asked for [$mode]"
        assert_eq "$(wu_installer_log)" "" "nothing ran [$mode]"
    done
}

test_a_start_failure_other_than_a_declined_prompt_is_not_called_a_decline() {
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    wu_runner_elevation false || return 1
    wu_runner_shadow other "$WU_STATE_HANDOFF"
    assert_rc 15 "its own status"
    assert_contains "$ERR" "could not be started" "says what happened"
    assert_not_contains "$ERR" "declined" "and does not call it a decline"
}

test_real_the_pinned_installer_passes_every_production_check_and_is_never_started() {
    local ver cached prod installed want_rc
    if [ "$TEST_IS_WINDOWS" -ne 1 ]; then skip_test "checks the real Windows installer with Windows PowerShell"; fi
    ver="$(awk '$1 == "git-for-windows" && $3 == "windows_amd64" { print $2 }' "$GSG_PROJECT/tools.lock")"
    cached="${TEST_TOOLS_CACHE:-}/Git-$ver-64-bit.exe"
    if [ ! -f "$cached" ]; then
        if [ -n "${CI:-}" ]; then fail "CI is set and $cached is missing; the fetch of the pinned installer failed"; return 1; fi
        skip_test "$cached is missing; tests/run.sh fetches the installer the lock names when it is absent (tests/fetch-test-tools.sh does it by hand)"
    fi
    wu_runner_starts_only_through_the_shadowed_calls "$GSG_PROJECT/bin/gsg-gitup.ps1" || { fail "the runner has a start path the shadow wrapper does not cover; this test would start the real installer"; return 1; }
    WU_NEVER_START=1
    installed="$(MSYS2_ARG_CONV_EXCL='*' "$TEST_SYSTEM32/reg.exe" query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Git_is1' /v DisplayVersion 2>/dev/null | tr -d '\r' | awk '$1 == "DisplayVersion" { print $3 }')"
    want_rc=0
    if [ -n "$installed" ] && [ "$(printf '%s\n%s\n' "$ver" "$installed" | sort -V | tail -1)" = "$installed" ]; then want_rc=17; fi
    wu_begin machine 2.52.0.1 || return 1
    mkdir -p -- "$WU_DIR/prod/bin" "$WU_DIR/prod/hand" || return 1
    cp -- "$GSG_PROJECT/bin/gsg-gitup.ps1" "$WU_DIR/prod/bin/" && cp -- "$GSG_PROJECT/tools.lock" "$WU_DIR/prod/" || return 1
    cp -- "$cached" "$WU_DIR/prod/hand/Git-$ver-64-bit.exe" && wu_deny_execute "$WU_DIR/prod/hand/Git-$ver-64-bit.exe" || return 1
    printf 'gsg-git-upgrade-handoff 1\nroute=installer\nscope=machine\nversion=%s\ninstaller=%s\n' "$ver" "$(cygpath -w "$WU_DIR/prod/hand/Git-$ver-64-bit.exe")" >"$WU_DIR/prod/hand/handoff.txt" || return 1
    prod="$WU_DIR/prod/bin/gsg-gitup.ps1"
    cmp -s "$prod" "$GSG_PROJECT/bin/gsg-gitup.ps1" || { fail "the runner under test is the product's"; return 1; }
    WU_RUNNER="$prod"
    wu_runner_shadow norun "$WU_DIR/prod/hand/handoff.txt"
    WU_RUNNER=""
    assert_rc "$want_rc" "the production runner, lock, signer and status accept the real asset (installed here: [${installed:-none}])"
    assert_contains "$OUT" "SHA-256 and signature of Git-$ver-64-bit.exe verified" "all checks passed, before the version check"
    if [ "$want_rc" -eq 0 ]; then
        assert_contains "$(<"$WU_DIR/verbs.log")" "args=/VERYSILENT /NORESTART /NOCANCEL /SP-" "the start line was reached with the story's flags, and replaced by a stand-in"
    else
        assert_contains "$ERR" "nothing is needed" "this host already has the pinned Git for Windows, so the runner refuses the stale start"
        assert_no_file "$WU_DIR/verbs.log" "and never reached the start"
    fi
    rm -f -- "$WU_DIR/prod/hand/Git-$ver-64-bit.exe" && cp -- "$cached" "$WU_DIR/prod/hand/Git-$ver-64-bit.exe" && printf 'x' >>"$WU_DIR/prod/hand/Git-$ver-64-bit.exe" && wu_deny_execute "$WU_DIR/prod/hand/Git-$ver-64-bit.exe" || return 1
    printf 'gsg-git-upgrade-handoff 1\nroute=installer\nscope=machine\nversion=%s\ninstaller=%s\n' "$ver" "$(cygpath -w "$WU_DIR/prod/hand/Git-$ver-64-bit.exe")" >"$WU_DIR/prod/hand/handoff.txt" || return 1
    WU_RUNNER="$prod"
    wu_runner_shadow norun "$WU_DIR/prod/hand/handoff.txt"
    WU_RUNNER=""
    assert_rc 10 "one appended byte is refused"
    assert_contains "$ERR" "the tools.lock pin is" "it is the digest that refuses it"
    assert_not_contains "$ERR" "is missing" "and the file was there"
}

test_the_real_cli_started_from_git_bash_hands_off_with_exit_3_changes_nothing_else_and_uninstall_cleans_up() {
    wu_need_windows_runner
    wu_begin machine 2.43.0 || return 1
    lc_begin || return 1
    wu_build_standin || return 1
    lc_make_fixtures || return 1
    lc_use_fixtures || return 1
    cp -- "$SANDBOX/standin/standin.exe" "$LC_FIX/Git-2.56.0.4-64-bit.exe" || return 1
    printf '# gsg-signer git-for-windows 2.56.0.4 CN=Fixture Signer\ngit-for-windows 2.56.0.4 windows_amd64 %s\n' "$(sha256sum -- "$LC_FIX/Git-2.56.0.4-64-bit.exe" | cut -d' ' -f1)" >>"$LC_FIX/fixture.lock" || return 1
    printf '    Inno Setup: App Path    REG_SZ    %s\n    DisplayVersion    REG_SZ    2.43.0\n' "$(cygpath -w "$SANDBOX")" >"$WU_DIR/reg.hklm" || return 1
    printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.43.0"; exit 0; fi\nexec %q "$@"\n' "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git" || return 1
    set_env GSG_GITUP_ROOT="$WU_DIR/root" GSG_STANDIN_DIR="$(cygpath -w "$WU_DIR/standin")"
    gsg install --upgrade-git --replace-hooks-path </dev/null
    assert_rc 3 "the hand-off status of the real CLI"
    assert_contains "$OUT" "git upgrade plan for this windows system" "the plan"
    assert_contains "$OUT" "close every Git Bash window" "the next step"
    assert_contains "$OUT" 'git-secret-guard.cmd" install --replace-hooks-path' "with the flags of this run"
    assert_no_file "$LC_DATA" "no share dir"
    assert_no_file "$LC_BIN/trufflehog.exe" "no scanner"
    assert_no_file "$LC_STATE/state" "no state"
    assert_eq "$(wu_installer_log)" "" "no installer ran"
    assert_file "$LC_STATE/git-upgrade/handoff.txt" "the hand-off waits"
    assert_file "$LC_STATE/git-upgrade/Git-2.56.0.4-64-bit.exe" "with the verified installer"
    gsg uninstall </dev/null
    assert_rc 0 "uninstall"
    assert_no_file "$LC_STATE" "removes the leftovers of the hand-off and the empty state directory"
}

wu_store_counts() {
    "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -Command '
        $s = "CN=GSG Test Signer"
        $n = 0
        foreach ($st in "My", "CA", "Root", "TrustedPublisher") { $n += @(Get-ChildItem "Cert:\CurrentUser\$st" | Where-Object { $_.Subject -eq $s }).Count }
        "certs=$n keys=" + @(Get-ChildItem "$env:APPDATA\Microsoft\Crypto\Keys" -Force).Count' | tr -d '\r'
}

test_building_the_signed_stand_in_leaves_no_certificate_and_no_key_behind() {
    local cache before after
    wu_need_windows_runner
    cache="$(wu_standin_cache)" || return 1
    wu_build_standin || return 1
    before="$(wu_store_counts)"
    mv -- "$cache" "$cache.aside" || return 1
    wu_build_standin
    after="$(wu_store_counts)"
    rm -f -- "$cache.aside"/standin.exe "$cache.aside"/standin-unsigned.exe
    rmdir -- "$cache.aside"
    assert_file "$cache/standin.exe" "the stand-in was built again"
    assert_eq "$after" "$before" "the user's stores hold the same certificates and key files as before"
    assert_contains "$before" "certs=0" "and none of ours"
}

test_the_certificate_sweep_removes_what_an_aborted_build_leaves() {
    local before planted after
    if [ "$TEST_IS_WINDOWS" -ne 1 ]; then skip_test "uses the Windows certificate stores"; fi
    before="$(wu_store_counts)"
    wu_plant_signer_cert
    planted="$(wu_store_counts)"
    wu_sweep_signer_certs
    after="$(wu_store_counts)"
    "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -Command '
        foreach ($st in "My", "CA") { foreach ($x in @(Get-ChildItem "Cert:\CurrentUser\$st" | Where-Object { $_.Subject -eq "CN=GSG Test Signer" })) { Remove-Item -LiteralPath ("Cert:\CurrentUser\$st\" + $x.Thumbprint) -DeleteKey -Force } }'
    assert_not_contains "$planted" "certs=0" "the planted certificate is in the stores"
    assert_eq "$after" "$before" "the sweep removed the planted certificates and the key file"
}

test_the_tools_cache_check_wants_the_installer_named_by_the_lock_not_any_installer() {
    local d="$SANDBOX/cache-check" t
    if [ "$TEST_IS_WINDOWS" -ne 1 ]; then skip_test "the check lists the Windows tool set"; fi
    mkdir -p -- "$d" || return 1
    for t in jq trufflehog betterleaks; do printf '#!/bin/sh\n' >"$d/$t.exe" && chmod 755 "$d/$t.exe" || return 1; done
    : >"$d/Git-2.55.0.1-64-bit.exe"
    run_cap bash "$GSG_PROJECT/tests/fetch-test-tools.sh" --check "$d"
    assert_rc 3 "an older installer in the cache does not satisfy the pin"
    assert_contains "$OUT$ERR" "Git-2.56.0.4-64-bit.exe" "the missing pinned file is named"
    : >"$d/Git-2.56.0.4-64-bit.exe"
    run_cap bash "$GSG_PROJECT/tests/fetch-test-tools.sh" --check "$d"
    assert_rc 0 "the pinned name satisfies it"
}

test_a_junction_on_the_git_secret_guard_level_is_refused_too() {
    local top real
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    top="$WU_DIR/top" real="$WU_DIR/greal"
    mkdir -p -- "$top" "$real/git-upgrade" || return 1
    cp -- "$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" "$real/git-upgrade/" || return 1
    wu_mklink "$top/git-secret-guard" "$real" || return 1
    printf 'gsg-git-upgrade-handoff 1\nroute=installer\nscope=machine\nversion=2.56.0.4\ninstaller=%s\n' "$(cygpath -w "$top/git-secret-guard/git-upgrade")\Git-2.56.0.4-64-bit.exe" >"$real/git-upgrade/handoff.txt" || return 1
    wu_runner "$top/git-secret-guard/git-upgrade/handoff.txt"
    wu_rmlink "$top/git-secret-guard"
    assert_rc 10 "refused"
    assert_contains "$ERR" "junction or symbolic link" "says why"
    assert_eq "$(wu_installer_log)" "" "nothing ran"
    assert_file "$real/git-upgrade/Git-2.56.0.4-64-bit.exe" "the installer stays"
}

test_the_start_path_denylist_accepts_the_runner_and_refuses_known_extra_ways_to_start_a_program() {
    local f="$SANDBOX/guard.ps1" line
    wu_runner_starts_only_through_the_shadowed_calls "$GSG_PROJECT/bin/gsg-gitup.ps1" || fail "the product runner passes its own guard"
    for line in 'Microsoft.PowerShell.Management\Start-Process @params' '[System.Diagnostics.Process]::Start($path)' '& $path /VERYSILENT' 'Invoke-Item $path' 'Start-Process -FilePath x'; do
        cp -- "$GSG_PROJECT/bin/gsg-gitup.ps1" "$f" || return 1
        printf '%s\n' "$line" >>"$f"
        if wu_runner_starts_only_through_the_shadowed_calls "$f"; then fail "the guard accepted an extra start path: $line"; fi
    done
}


test_the_shadow_wrapper_fails_closed_for_an_unknown_mode_and_for_a_never_start_test() {
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    wu_runner_shadow bogus "$WU_STATE_HANDOFF"
    assert_rc 15 "an unknown mode ends in a start failure, not in a real start"
    assert_contains "$ERR" "unknown shadow mode bogus" "and names the mode"
    assert_eq "$(wu_installer_log)" "" "nothing ran"
    wu_prepare_handoff machine || return 1
    wu_shadow_script
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" GSG_TEST_NEVER_START=1 GSG_TEST_VERBLOG="$(cygpath -w "$WU_DIR/verbs.log")" GSG_TEST_RUNNER="$(cygpath -w "$WU_RT/bin/gsg-gitup.ps1")" \
        GSG_TEST_HANDOFF="$(cygpath -w "$WU_STATE_HANDOFF")" "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$WU_DIR/shadow.ps1")" ok
    assert_rc 15 "mode ok under the never-start switch is refused inside the wrapper too"
    assert_eq "$(wu_installer_log)" "" "nothing ran"
}

test_the_signer_is_compared_with_case() {
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    wu_write_lock "$WU_SHA" "cn=gsg test signer" || return 1
    wu_runner "$WU_STATE_HANDOFF"
    assert_rc 10 "a pin that differs in case only is another pin"
    assert_contains "$ERR" "the signer of" "says so"
    assert_eq "$(wu_installer_log)" "" "nothing ran"
}

test_a_lock_without_the_signer_line_is_refused_before_the_download() {
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture good || return 1
    wu_elevated yes
    wu_curl_recorder
    printf 'git-for-windows 2.56.0.4 windows_amd64 %s\n' "$WU_SHA" >"$WU_DIR/fixture.lock" || return 1
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade >/dev/null; echo "plan=$?"; gitup_windows_apply; echo "apply=$?"' "$WU_GIT"
    assert_not_contains "$OUT" "apply=2" "no hand-off"
    assert_contains "$ERR" "gsg-signer" "the missing line is named"
    assert_no_file "$WU_DIR/curl.log" "nothing was downloaded"
}

test_a_broken_shadow_cannot_start_the_stand_in_when_execute_is_denied() {
    local inst pin standin_sha standin_size
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    inst="$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe"
    standin_sha="$(sha256sum -- "$SANDBOX/standin/standin.exe" | cut -d' ' -f1)"
    standin_size="$(stat -c %s -- "$SANDBOX/standin/standin.exe")"
    pin="$(awk '$1 == "git-for-windows" && $3 == "windows_amd64" { print $4 }' "$GSG_PROJECT/tools.lock")"
    assert_eq "$(sha256sum -- "$inst" | cut -d' ' -f1)" "$standin_sha" "the file under test is the stand-in" || return 1
    assert_eq "$(stat -c %s -- "$inst")" "$standin_size" "with the size of the stand-in" || return 1
    [ "$standin_sha" != "$pin" ] || { fail "the stand-in must never be the real asset"; return 1; }
    [ "$standin_size" -lt 1000000 ] || { fail "the stand-in is far smaller than the real asset"; return 1; }
    wu_runner_broken "$WU_STATE_HANDOFF"
    assert_eq "$(wu_installer_log)" "/VERYSILENT /NORESTART /NOCANCEL /SP-" "without the deny a broken shadow lets the stand-in start, which is the danger"
    rm -f -- "$WU_DIR/standin/installer.log"
    wu_prepare_handoff machine || return 1
    wu_deny_execute "$inst" || return 1
    wu_runner_broken "$WU_STATE_HANDOFF"
    assert_rc 15 "with execute denied the start fails"
    assert_eq "$(wu_installer_log)" "" "and nothing started"
    wu_allow_execute "$inst"
}

test_a_hand_off_run_when_git_is_already_at_or_past_the_pin_is_refused_before_anything_starts() {
    local have
    wu_need_windows_runner
    for have in 2.56.0.4 2.57.1.1; do
        wu_prepare_handoff machine || return 1
        wu_runner_installed "$have" || return 1
        wu_runner "$WU_STATE_HANDOFF"
        assert_rc 17 "installed $have is not older than the pin"
        assert_contains "$ERR" "nothing is needed" "says nothing is needed [$have]"
        assert_contains "$ERR" "$have" "names the installed version [$have]"
        assert_eq "$(wu_installer_log)" "" "nothing ran [$have]"
        assert_no_file "$WU_STATE_HANDOFF" "the stale hand-off is used up [$have]"
        assert_no_file "$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe" "and its installer deleted [$have]"
    done
}

test_an_older_or_unknown_installed_version_does_not_stop_the_upgrade() {
    local have
    wu_need_windows_runner
    for have in 2.55.9.9 ""; do
        wu_prepare_handoff machine || return 1
        wu_runner_installed "$have" || return 1
        wu_runner "$WU_STATE_HANDOFF"
        assert_rc 0 "installed [$have] goes on"
        assert_eq "$(wu_installer_log)" "/VERYSILENT /NORESTART /NOCANCEL /SP-" "the installer ran [$have]"
    done
}

test_the_next_step_agrees_with_the_plan_about_the_uac_prompt() {
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture good || return 1
    set_env GSG_HANDOFF="$(wu_w "$WU_FRONT_DIR/git-upgrade/handoff.txt")"
    wu_elevated yes
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade; gitup_windows_apply; echo "NEXT=$GITUP_NEXT"' "$WU_GIT"
    assert_contains "$OUT" "already elevated, no prompt will appear" "the plan on an elevated prompt"
    assert_contains "$OUT" "NEXT=git-secret-guard.cmd runs the verified installer next (no UAC prompt is expected" "and the next step says the same"
    wu_elevated no
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade; gitup_windows_apply; echo "NEXT=$GITUP_NEXT"' "$WU_GIT"
    assert_contains "$OUT" "a Windows UAC prompt should appear" "the plan on a normal prompt"
    assert_contains "$OUT" "next (a UAC prompt should appear" "and the next step says the same"
}

test_an_installed_version_that_cannot_be_read_as_a_version_stops_the_upgrade_before_it_starts() {
    local have
    wu_need_windows_runner
    for have in garbage 2.57.0-rc1 2.56.0.windows.4; do
        wu_prepare_handoff machine || return 1
        wu_runner_installed "$have" || return 1
        wu_runner "$WU_STATE_HANDOFF"
        assert_rc 18 "[$have] is refused"
        assert_contains "$ERR" "[$have]" "the value is named [$have]"
        assert_contains "$ERR" "git-scm.com/download/win" "with the way out [$have]"
        assert_eq "$(wu_installer_log)" "" "nothing ran [$have]"
        assert_no_file "$WU_STATE_HANDOFF" "the hand-off is used up [$have]"
    done
}

test_the_path_helpers_refuse_an_empty_or_outside_path_and_create_nothing() {
    local before after
    before="$(wu_names /)"
    WU_DIR=""
    if wu_sandbox_path "$WU_DIR/top" 2>/dev/null; then fail "an empty WU_DIR gave an accepted path"; fi
    if wu_sandbox_path "/tmp/outside" 2>/dev/null; then fail "a path outside the sandbox was accepted"; fi
    if wu_sandbox_path "$SANDBOX/a/../../outside" 2>/dev/null; then fail "a .. path was accepted"; fi
    wu_sandbox_path "$SANDBOX/inside/x" || fail "a path in the sandbox was refused"
    if wu_mklink "$WU_DIR/greal" "$WU_DIR/top" 2>/dev/null; then fail "wu_mklink accepted empty paths"; fi
    after="$(wu_names /)"
    assert_eq "$after" "$before" "nothing was created at the root"
}

test_the_stray_file_check_sees_a_new_entry_in_a_directory() {
    local d="$SANDBOX/names" before
    wu_sandbox_path "$d" || return 1
    mkdir -p -- "$d" && : >"$d/a" || return 1
    before="$(wu_names "$d")"
    : >"$d/stray" || return 1
    [ "$(wu_names "$d")" != "$before" ] || fail "a new entry went unseen"
}

test_zz_nothing_was_created_at_the_root_of_the_file_system() {
    assert_eq "$(wu_names /)" "$WU_ROOT_NAMES" "no test of this file created an entry at the root (on Git Bash the Git for Windows install)"
}

run_file_tests
