#!/usr/bin/env bash
# shellcheck disable=SC2016
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

test_the_reminder_starts_without_setsid_on_windows() {
    assert_not_contains "$(<"$GSG_PROJECT/hooks/secret-scan")" 'exec "$SETSID_BIN"' "SETSID_BIN is not in the Windows settings and the hook runs under set -u"
    win 'proc_group_of 999999999'
    assert_rc 1 "no Windows pid for a pid that is gone"
    win 'uname() { echo Linux; }; proc_group_of 4242'
    assert_rc 0 "a setsid job"
    assert_eq "$OUT" 4242 "is its own group"
}

run_file_tests
