#!/usr/bin/env bash
# shellcheck source=tests/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# ^ why a uname function, not lc_begin; lc_begin needs setsid, this file also has to run on Git for Windows itself
WIN_PRELUDE='set -u
GSG_ROOT="$1"
GSG_NAME=git-secret-guard
GSG_UNINSTALL_ACTIONS=0
uname() { if [ "${1:-}" = -m ]; then echo x86_64; else echo MINGW64_NT-10.0-26200; fi; }
for lib in brew common state tools hookspath exempt timer launchd install install_tools uninstall status doctor doctor_repos doctor_findings proc; do
    source "$1/lib/$lib.sh" || exit 9
done
shift
'

win() {
    local code="$1"
    shift
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c "$WIN_PRELUDE$code" _ "$GSG_PROJECT" "$@"
    OUT="$(<"$SANDBOX/.out")"
    ERR="$(<"$SANDBOX/.err")"
}

sha_of() { sha256sum -- "$1" | cut -d' ' -f1; }

test_the_jq_asset_is_named_and_located_like_the_jqlang_release() {
    win 'tools_platform_key jq MINGW64_NT-10.0-26200 x86_64'
    assert_eq "$OUT" windows_amd64 "platform key"
    win 'tools_tarball_name jq 1.8.2 windows_amd64'
    assert_eq "$OUT" jq-windows-amd64.exe "asset name"
    win 'tools_release_url jq 1.8.2 windows_amd64'
    assert_eq "$OUT" https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-windows-amd64.exe "tag is jq-<version>"
    win 'tools_release_url betterleaks 1.9.0 windows_x64'
    assert_eq "$OUT" https://github.com/betterleaks/betterleaks/releases/download/v1.9.0/betterleaks_1.9.0_windows_x64.zip "scanners keep the v tag"
}

test_the_lock_has_a_jq_row_for_windows_only() {
    win 'tools_lock_lookup "$GSG_ROOT/tools.lock" jq windows_amd64'
    assert_rc 0 "windows row"
    assert_contains "$OUT" "1.8.2 " "the pinned version"
    win 'tools_lock_lookup "$GSG_ROOT/tools.lock" jq linux_amd64'
    assert_rc 1 "no linux row, jq stays a prerequisite there"
}

test_the_jq_version_text_matches_with_its_crlf_and_only_as_a_whole_word() {
    win 'tools_version_matches "$1" 1.8.2' $'jq-1.8.2\r\n'
    assert_rc 0 "native jq.exe output"
    win 'tools_version_matches "$1" 1.8.2' 'jq-1.8.20'
    assert_rc 1 "a longer version"
    win 'tools_version_matches "$1" 1.8.2' 'notjq-1.8.2'
    assert_rc 1 "another name"
}

test_the_bare_jq_executable_is_copied_not_unpacked() {
    mkdir -p "$SANDBOX/dl" "$SANDBOX/out" || return 1
    printf 'bytes\n' >"$SANDBOX/dl/jq-windows-amd64.exe" || return 1
    win 'tools_extract_binary "$1" jq "$2"' "$SANDBOX/dl/jq-windows-amd64.exe" "$SANDBOX/out"
    assert_rc 0 "copied"
    assert_eq "$(<"$SANDBOX/out/jq.exe")" bytes "the same bytes, under the .exe name"
    [ -x "$SANDBOX/out/jq.exe" ] || fail "jq.exe is executable"
}

test_a_missing_jq_is_no_refusal_on_windows_and_asks_for_a_download() {
    local bin="$SANDBOX/only"
    mkdir -p "$bin" || return 1
    printf '#!/bin/sh\n' >"$bin/taskkill" && printf '#!/bin/sh\n' >"$bin/timeout" || return 1
    chmod 755 "$bin/taskkill" "$bin/timeout" || return 1
    win 'PATH="$1"; GSG_SHARE=/s; install_resolve_bins; echo "rc=$? jq=[$INSTALL_JQ_BIN]"; install_downloads_needed; echo "needed=$?"' "$bin"
    assert_contains "$OUT" "rc=0 jq=[]" "not counted as missing"
    assert_contains "$OUT" "needed=0" "curl is then required"
    assert_empty "$ERR" "no hint is printed"
}

test_jq_is_managed_only_when_absent_or_already_ours() {
    local show='install_manage_jq; echo "[${GSG_TOOL_NAMES[*]}] [$INSTALL_JQ_BIN] [$INSTALL_JQ_WRAPPER]"'
    local base='GSG_BIN_DIR=/b GSG_SHARE=/s INSTALL_JQ_WRAPPER=""'
    win "$base INSTALL_JQ_BIN=/u/jq ST_PLACED=''; INSTALL_JQ_WRAPPER=/s/jq; $show"
    assert_eq "$OUT" "[trufflehog betterleaks] [/u/jq] [/s/jq]" "a jq of the user's stays in use"
    win "$base INSTALL_JQ_BIN='' ST_PLACED=''; $show"
    assert_eq "$OUT" "[trufflehog betterleaks jq] [/b/jq.exe] [/s/jq]" "none on PATH"
    win "$base INSTALL_JQ_BIN=/b/jq ST_PLACED='trufflehog:aa jq:bb'; $show"
    assert_eq "$OUT" "[trufflehog betterleaks jq] [/b/jq.exe] [/s/jq]" "a recorded one stays managed on a rerun"
    win "uname() { echo Linux; }; $base INSTALL_JQ_BIN='' ST_PLACED=''; $show"
    assert_eq "$OUT" "[trufflehog betterleaks] [] []" "other platforms never manage it"
}

test_a_managed_jq_writes_no_version_key_to_the_settings() {
    win 'GSG_BIN_DIR=/b GSG_TOOL_NAMES+=(jq) GSG_TOOL_VER=(1 2 3) INSTALL_JQ_BIN=/b/jq.exe INSTALL_JQ_WRAPPER=/s/jq
INSTALL_TIMEOUT_BIN=/t INSTALL_BASH_BIN="" INSTALL_GNUBIN_DIR="" INSTALL_TIMER_BIN=""
install_write_settings "$1" && cat -- "$1"' "$SANDBOX/settings"
    assert_rc 0 "settings written"
    assert_contains "$OUT" "JQ_BIN=/s/jq" "the wrapper"
    assert_contains "$OUT" "BETTERLEAKS_VERSION=2" "the scanners keep theirs"
    assert_not_contains "$OUT" "JQ_VERSION" "the load_settings unset list has no such key"
}

test_uninstall_removes_the_exe_it_placed_and_keeps_another() {
    local bin="$SANDBOX/bin" sha
    mkdir -p "$bin" || return 1
    printf 'ours\n' >"$bin/jq.exe" && printf 'theirs\n' >"$bin/trufflehog.exe" || return 1
    sha="$(sha_of "$bin/jq.exe")"
    win 'GSG_BIN_DIR="$1" ST_EXISTS=1 ST_TOOLS="jq trufflehog" UN_HANDLED=" " ST_PLACED="jq:$2 trufflehog:$2"
uninstall_read_placed && uninstall_tools' "$bin" "$sha"
    assert_rc 0 "uninstall_tools"
    assert_no_file "$bin/jq.exe" "the file install placed goes"
    assert_file "$bin/trufflehog.exe" "a file with another hash stays"
    assert_contains "$ERR" "$bin/trufflehog.exe is not the file install put there" "and is named with its real name"
}

test_uninstall_restores_a_moved_aside_original_onto_the_exe_name() {
    local bin="$SANDBOX/bin-restore" aside=jq.gsg-replaced-20260101T000000Z sha
    mkdir -p "$bin" || return 1
    printf 'ours\n' >"$bin/jq.exe" && printf 'original\n' >"$bin/$aside" || return 1
    sha="$(sha_of "$bin/jq.exe")"
    win 'GSG_BIN_DIR="$1" ST_PLACED="jq:$3" ST_REPLACED="$2:$3"
uninstall_read_placed && uninstall_restore_replaced' "$bin" "$aside" "$sha"
    assert_rc 0 "restored"
    assert_eq "$(<"$bin/jq.exe")" original "the original is back under jq.exe"
    assert_eq "$(ls -- "$bin")" jq.exe "never under the bare name"
}

test_uninstall_removes_the_cli_wrapper_and_keeps_any_other_file() {
    local bin="$SANDBOX/bin-cli"
    mkdir -p "$bin" || return 1
    win 'GSG_BIN_DIR="$1" GSG_SHARE=/s; install_cli_wrapper_text >"$1/git-secret-guard" && uninstall_cli_link' "$bin"
    assert_rc 0 "removed"
    assert_no_file "$bin/git-secret-guard" "install's wrapper goes"
    printf 'mine\n' >"$bin/git-secret-guard" || return 1
    win 'GSG_BIN_DIR="$1" GSG_SHARE=/s; uninstall_cli_link' "$bin"
    assert_file "$bin/git-secret-guard" "a file of the user's stays"
    assert_contains "$ERR" "is not the link install created" "and says so"
}

CMD_CYGPATH='cygpath() { case "$1:$2" in -w:/) printf "%s\n" "C:\\Program Files\\Git\\" ;; -w:*) printf "%s\n" "C:\\U\\100%\\share" ;; -m:*) printf "%s\n" "C:/U/100%/share" ;; esac; }'

test_the_cmd_wrapper_runs_gits_login_bash_and_deletes_itself_when_the_share_is_gone() {
    win "$CMD_CYGPATH; GSG_SHARE=/c/U/share; install_cli_cmd_text"
    assert_rc 0 "written"
    assert_contains "$OUT" '"C:\Program Files\Git\bin\bash.exe" "C:/U/100%%/share/bin/git-secret-guard" %*' "bin\\bash.exe sets up PATH, and a percent sign is doubled"
    assert_contains "$OUT" 'if not exist "C:\U\100%%\share\bin\git-secret-guard" (goto) 2>nul & del "%~f0"' "self delete"
    assert_contains "$OUT" 'exit /b %GSG_RC%' "the exit code survives"
    assert_contains "$OUT" $'@echo off\r\n' "CRLF"
}

test_uninstall_removes_the_cmd_wrapper_unless_it_is_the_one_running() {
    local bin="$SANDBOX/bin-cmd" setup="$CMD_CYGPATH; GSG_SHARE=/c/U/share GSG_BIN_DIR=\"\$1\""
    mkdir -p "$bin" || return 1
    win "$setup; install_cli_cmd_text >\"\$1/git-secret-guard.cmd\" && install_cli_cmd_is_ours \"\$1/git-secret-guard.cmd\"" "$bin"
    assert_rc 0 "a written wrapper counts as ours"
    win "$setup; GSG_CMD_ENTRY='C:\\x.cmd' uninstall_cli_cmd" "$bin"
    assert_file "$bin/git-secret-guard.cmd" "the running wrapper is left to delete itself"
    assert_contains "$OUT" "removes itself" "and says so"
    win "$setup; uninstall_cli_cmd" "$bin"
    assert_no_file "$bin/git-secret-guard.cmd" "from Git Bash it is removed"
    printf '@echo off\r\nrem mine\r\n' >"$bin/git-secret-guard.cmd" || return 1
    win "$setup; uninstall_cli_cmd" "$bin"
    assert_file "$bin/git-secret-guard.cmd" "a file of the user's stays"
    assert_contains "$ERR" "is not the wrapper install created" "and is named"
}

test_install_refuses_a_cmd_file_it_did_not_write() {
    local bin="$SANDBOX/bin-refuse"
    mkdir -p "$bin" || return 1
    printf '@echo off\r\nrem mine\r\n' >"$bin/git-secret-guard.cmd" || return 1
    win 'GSG_BIN_DIR="$1"; install_check_cli_link' "$bin"
    assert_rc 1 "refused before anything changes"
    assert_contains "$ERR" "git-secret-guard.cmd exists and is not the wrapper install writes" "says why"
}

test_every_batch_file_is_crlf_and_every_entry_point_has_one() {
    local f
    for f in bin/gsg-bash.cmd bin/git-secret-guard.cmd tests/run.cmd; do
        assert_file "$GSG_PROJECT/$f" "$f ships"
        assert_eq "$(grep -c $'\r$' "$GSG_PROJECT/$f")" "$(wc -l <"$GSG_PROJECT/$f")" "$f has CRLF on every line"
    done
    assert_contains "$(<"$GSG_PROJECT/.gitattributes")" "*.cmd text eol=crlf" "and keeps it in every checkout"
}

test_the_findings_lock_is_taken_although_its_target_does_not_exist() {
    win 'GSG_FINDINGS_LOCK="$1/findings.lock"; doctor_rec_try_lock; echo "first=$?"; readlink -- "$GSG_FINDINGS_LOCK"; echo "$$"; doctor_rec_try_lock; echo "second=$?"' "$SANDBOX"
    local -a got=()
    mapfile -t got <<<"$OUT"
    assert_eq "${got[0]:-}" first=0 "the lock is taken"
    assert_eq "${got[1]:-}" "${got[2]:-}" "and names its holder"
    assert_eq "${got[3]:-}" second=1 "a second attempt is refused"
}

test_a_repository_is_recognised_when_git_answers_in_windows_form() {
    local setup='cygpath() { printf "C:/Users/me/repo\n"; }; fakegit() { printf "%s\n" "$FAKE_TOP"; }; GSG_GIT=fakegit DR_WORK="$1"'
    win "$setup; FAKE_TOP=C:/Users/me/repo; doctor_resolves_here /c/Users/me/repo C:/Users/me/repo/.git" "$SANDBOX"
    assert_rc 0 "the top level, in the form of git"
    win "$setup; FAKE_TOP=C:/Users/me; doctor_resolves_here /c/Users/me/repo C:/Users/me/.git" "$SANDBOX"
    assert_rc 1 "an empty .git makes git answer for the parent"
    assert_contains "$(<"$SANDBOX/rev.err")" "git resolves it to C:/Users/me" "and the message names it"
}

test_a_config_origin_has_one_spelling_whatever_form_git_printed() {
    win 'cygpath() { printf "/c/repo/.git/config\n"; }; doctor_origin_text file:C:/repo/.git/config; printf "%s\n" "$REPLY"'
    assert_eq "$OUT" /c/repo/.git/config "a drive letter is an absolute path, not relative to the cwd"
    win 'cd /usr && doctor_origin_text file:.git/config; printf "%s\n" "$REPLY"'
    assert_eq "$OUT" /usr/.git/config "a relative origin still joins the cwd"
}

test_a_hooks_path_git_expands_to_a_drive_letter_is_absolute() {
    mkdir -p "$SANDBOX/hp" || return 1
    win 'cygpath() { printf "%s\n" "$HP_DIR"; }; fakegit() { printf "C:/hooks\n"; }; GSG_GIT=fakegit HP_DIR="$1"
GSG_PREV_SET=yes GSG_PREV="~/hooks" GSG_HOOKS_DIR_SEEN=""; install_resolve_hooks_dir; echo "rc=$? dir=[$GSG_PREV_DIR]"' "$SANDBOX/hp"
    assert_contains "$OUT" "rc=0" "not refused as relative"
    assert_not_contains "$ERR" "is relative" "no such message"
}

test_a_drive_letter_path_from_native_git_or_a_windows_user_becomes_posix() {
    win 'cygpath() { printf "/c/state\n"; }; printf "%s|%s|%s" "$(gsg_posix_path "C:/state")" "$(gsg_posix_path "C:\state")" "$(gsg_posix_path /already/posix)"'
    assert_eq "$OUT" '/c/state|/c/state|/already/posix' "every spelling gives one form"
    win 'cygpath() { printf "/c/state\n"; }; XDG_STATE_HOME=C:/state; state_dir_path'
    assert_eq "$OUT" /c/state/git-secret-guard "the hook finds the record when native git handed it the variable"
    win 'cygpath() { printf "/c/data\n"; }; HOME=/h XDG_DATA_HOME="C:\data"; paths_init; echo "rc=$? $GSG_SHARE"'
    assert_eq "$OUT" "rc=0 /c/data/git-secret-guard" "install accepts what a Windows user types"
    win 'uname() { echo Linux; }; gsg_posix_path "C:/state"'
    assert_eq "$OUT" "C:/state" "elsewhere it is an ordinary relative name"
}

test_an_install_from_the_installed_copy_never_renames_the_directory_it_runs_from() {
    local share="$SANDBOX/share-copy"
    mkdir -p "$share" || return 1
    printf 'old\n' >"$share/settings" || return 1
    win 'GSG_ROOT="$1" GSG_SHARE="$1" GSG_BIN_DIR=/b GSG_TOOL_VER=(1 2) INSTALL_JQ_BIN=/b/jq.exe INSTALL_JQ_WRAPPER="$1/jq"
INSTALL_TIMEOUT_BIN=/t INSTALL_BASH_BIN="" INSTALL_GNUBIN_DIR="" INSTALL_TIMER_BIN=""; install_copy_share; echo "rc=$?"' "$share"
    assert_contains "$OUT" "rc=0" "no rename is attempted"
    assert_contains "$(<"$share/settings")" "JQ_BIN=" "the settings are rewritten in place"
    assert_file "$share/jq" "and so is the jq wrapper"
    assert_eq "$(find "$SANDBOX" -maxdepth 1 -name 'share-copy.*' | wc -l)" 0 "nothing is left beside it"
}

test_the_lock_wait_on_windows_ends_before_a_live_holder_counts_as_old() {
    win 'echo "$GSG_FINDINGS_LOCK_WAIT_SECONDS_WINDOWS $GSG_FINDINGS_LOCK_MAX_AGE_MIN"'
    local seconds minutes
    read -r seconds minutes <<<"$OUT"
    assert_eq "$((seconds < minutes * 60))" 1 "the wait stops before the lock of a live holder counts as old"
    assert_eq "$((seconds >= 30))" 1 "and leaves a queued run the same time as the 300 attempts elsewhere"
    win 'GSG_FINDINGS_LOCK="$1/findings.lock" GSG_FINDINGS_LOCK_WAIT_SECONDS_WINDOWS=0; sleep 300 & h=$!; MSYS=winsymlinks:sys ln -s "$h" "$GSG_FINDINGS_LOCK"; doctor_rec_lock; rc=$?; kill "$h"; echo "rc=$rc"' "$SANDBOX"
    assert_contains "$OUT" "rc=1" "once the time is up the lock is refused"
}

test_the_reminder_starts_without_setsid_on_windows() {
    assert_not_contains "$(<"$GSG_PROJECT/hooks/secret-scan")" 'exec "$SETSID_BIN"' "SETSID_BIN is not in the Windows settings and the hook runs under set -u"
}

test_the_process_tree_follows_msys_parents_and_the_current_windows_pids() {
    local t="$SANDBOX/proctable" row pid ppid win
    for row in 10:1:1000 11:10:1100 12:11:1200 13:12:1300 20:1:2000 21:20:2100 30:10:notanumber; do
        IFS=: read -r pid ppid win <<<"$row"
        mkdir -p "$t/$pid" && printf '%s\n' "$ppid" >"$t/$pid/ppid" && printf '%s\n' "$win" >"$t/$pid/winpid" || return 1
    done
    mkdir -p "$t/40" || return 1
    win 'proc_windows_tree 10 "$1"' "$t"
    assert_eq "$OUT" $'1000\n1100\n1200\n1300' "the runner and each descendant, nothing of another tree, nothing unreadable"
    win 'proc_windows_tree 99 "$1"' "$t"
    assert_empty "$OUT" "a pid that is gone names nothing"
}

ping_count() { "$TEST_SYSTEM32/tasklist.exe" //FI "IMAGENAME eq PING.EXE" 2>/dev/null | grep -c -i 'ping\.exe'; }

test_windows_only_an_interrupted_scan_leaves_no_native_process_and_no_work_dir() {
    [ "$TEST_IS_WINDOWS" -eq 1 ] || skip_test "needs native Windows processes"
    local stub="$SANDBOX/ping-scanner" i pid commit_pid
    printf '#!/usr/bin/env bash\n%q -n 90 127.0.0.1 >/dev/null\n' "$TEST_SYSTEM32/PING.EXE" >"$stub" || return 1
    chmod 755 "$stub" || return 1
    write_settings "$stub" "$stub" "$TEST_JQ"
    new_repo interrupted && stage_file a.txt one || return 1
    gitx commit -q -m interrupted >"$SANDBOX/.interrupted" 2>&1 &
    commit_pid=$!
    for ((i = 0; i < 90; i++)); do
        if [ "$(ping_count)" -ge 2 ]; then break; fi
        sleep 1
    done
    assert_eq "$(ping_count)" 2 "both scanners run a native process"
    # shellcheck disable=SC2009
    pid="$(ps -ef | grep -F "${SANDBOX##*/}/share/hooks/secret-scan" | grep -v grep | awk '{print $2}' | head -n 1)"
    [ -n "$pid" ] || fail "the hook process was found"
    kill -TERM "$pid" || return 1
    wait "$commit_pid"
    assert_eq "$?" 1 "the commit is blocked"
    assert_eq "$(ping_count)" 0 "no native process outlives the hook"
    assert_empty "$(find "$TEST_WORK_BASE" -mindepth 1 -maxdepth 1 2>/dev/null)" "the work dir holding the staged lines is gone"
    assert_not_contains "$(<"$SANDBOX/.interrupted")" "could not remove the temporary scan directory" "and the hook says nothing about it"
}

run_file_tests
