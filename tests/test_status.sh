#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

fresh_install() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install"
}

lc_which() {
    # shellcheck disable=SC2016
    env -i HOME="$SANDBOX/home" PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" bash -c 'type -P "$1"' _ "$1" </dev/null
}

test_status_reports_not_installed_with_exit_1() {
    lc_begin || return 1
    gsg status
    assert_rc 1 "status before install"
    assert_contains "$OUT" "not installed" "says so"
    assert_no_file "$LC_STATE" "and creates nothing"
    assert_no_file "$LC_DATA" "not even the share dir"
}

test_status_shows_the_installation() {
    fresh_install
    gsg status
    assert_rc 0 "status after install"
    assert_contains "$OUT" "installed version: $(<"$GSG_PROJECT/VERSION")" "version"
    assert_contains "$OUT" "hook command: $LC_DATA/hooks/secret-scan" "hook command path"
    assert_contains "$OUT" "global config: matches" "config matches"
    assert_contains "$OUT" "previous core.hooksPath: unset" "recorded hooksPath"
    assert_contains "$OUT" "tools installed by us: trufflehog betterleaks" "which tools install downloaded"
    assert_contains "$OUT" "trufflehog: $LC_BIN/trufflehog$LC_EXE 3.99.2 (pinned 3.99.2) ok" "trufflehog path and version"
    assert_contains "$OUT" "betterleaks: $LC_BIN/betterleaks$LC_EXE 1.9.0 (pinned 1.9.0) ok" "betterleaks path and version"
    assert_contains "$OUT" "jq: $(lc_expected_jq)" "jq path"
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then assert_contains "$OUT" "taskkill: " "process tool"; else assert_contains "$OUT" "setsid: $(lc_which setsid)" "setsid path"; fi
    assert_contains "$OUT" "timeout: $(lc_which timeout)" "timeout path"
    assert_eq "$ERR" "git-secret-guard: note: GIT_CONFIG_GLOBAL is set; the global git config used is $SANDBOX/gitconfig" "stderr is only the one-line note"
}

test_status_shows_the_recorded_hooks_path_and_backup() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$LC_HOME/.config/git/hooks" && printf 'x\n' >"$LC_HOME/.config/git/hooks/pre-commit" || return 1
    # shellcheck disable=SC2088
    git_literal_config --global core.hooksPath '~/.config/git/hooks' || return 1
    gsg install --replace-hooks-path
    assert_rc 0 "takeover"
    gsg status
    assert_rc 0 "status"
    assert_contains "$OUT" "previous core.hooksPath: ~/.config/git/hooks" "verbatim, not expanded"
    assert_contains "$OUT" "hooks backup: $(state_value backup_path)" "backup location"
}

test_status_flags_every_kind_of_drift_and_exits_1() {
    fresh_install
    git_literal_config --global --replace-all hook.git-secret-guard.command /elsewhere/secret-scan || return 1
    gsg status
    assert_rc 1 "a changed command"
    assert_contains "$OUT" "global config: MISMATCH" "flagged"
    assert_contains "$OUT" "command=[/elsewhere/secret-scan]" "shows what is configured"
    assert_contains "$OUT" "want [$LC_DATA/hooks/secret-scan]" "and what is expected"

    fresh_install
    gitx config --global --add hook.git-secret-guard.event commit-msg || return 1
    gsg status
    assert_rc 1 "a second event"
    assert_contains "$OUT" "global config: MISMATCH" "flagged"

    fresh_install
    rm -f -- "$LC_DATA/hooks/secret-scan" || return 1
    gsg status
    assert_rc 1 "a missing hook script"
    assert_contains "$OUT" "hook command: $LC_DATA/hooks/secret-scan (MISSING or not executable)" "flagged"

    fresh_install
    printf '#!/bin/sh\necho "trufflehog 3.0.0"\n' >"$LC_BIN/trufflehog$LC_EXE" || return 1
    gsg status
    assert_rc 1 "a tool at another version"
    assert_contains "$OUT" "trufflehog: $LC_BIN/trufflehog$LC_EXE 3.0.0 (pinned 3.99.2) MISMATCH" "flagged with both versions"
    assert_contains "$OUT" "betterleaks: $LC_BIN/betterleaks$LC_EXE 1.9.0 (pinned 1.9.0) ok" "the other tool is still ok"

    fresh_install
    rm -f -- "$LC_BIN/betterleaks$LC_EXE" || return 1
    gsg status
    assert_rc 1 "a missing tool"
    assert_contains "$OUT" "betterleaks: $LC_BIN/betterleaks$LC_EXE (MISSING or not executable)" "flagged"

    fresh_install
    rm -f -- "$LC_DATA/settings" || return 1
    gsg status
    assert_rc 1 "missing settings"
    assert_contains "$OUT" "settings: $LC_DATA/settings (MISSING or unreadable)" "flagged"
}

test_status_lists_the_originals_install_moved_aside() {
    fresh_install
    gsg status
    assert_contains "$OUT" "originals moved aside: none" "a clean install moved nothing"
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$LC_BIN" && printf '#!/bin/sh\necho "betterleaks version 8.18.4"\n' >"$LC_BIN/betterleaks$LC_EXE" && chmod 755 "$LC_BIN/betterleaks$LC_EXE" || return 1
    gsg install
    assert_rc 0 "install over the user's betterleaks"
    gsg status
    assert_rc 0 "status"
    assert_contains "$OUT" "originals moved aside: betterleaks.gsg-replaced-" "the aside file is named"
}

test_status_judges_versions_exactly_like_install_does() {
    fresh_install
    printf '#!/bin/sh\necho "betterleaks version 1.9.0-rc1"\n' >"$LC_BIN/betterleaks$LC_EXE" || return 1
    printf '#!/bin/sh\necho "trufflehog 3.99.2.1"\n' >"$LC_BIN/trufflehog$LC_EXE" || return 1
    gsg status
    assert_rc 1 "a pre-release and a four-part version are not the pin"
    assert_contains "$OUT" "betterleaks: $LC_BIN/betterleaks$LC_EXE 1.9.0-rc1 (pinned 1.9.0) MISMATCH" "betterleaks 1.9.0-rc1"
    assert_contains "$OUT" "trufflehog: $LC_BIN/trufflehog$LC_EXE 3.99.2.1 (pinned 3.99.2) MISMATCH" "trufflehog 3.99.2.1"
    printf '#!/bin/sh\necho "betterleaks version v1.9.0"\n' >"$LC_BIN/betterleaks$LC_EXE" || return 1
    printf '#!/bin/sh\necho "trufflehog 3.99.2"\n' >"$LC_BIN/trufflehog$LC_EXE" || return 1
    gsg status
    assert_rc 0 "install's own accepted spellings (v-prefix) are ok"
    assert_contains "$OUT" "(pinned 1.9.0) ok" "ok"
}

test_status_flags_an_unusable_timeout_in_the_settings() {
    fresh_install
    sed -i 's#^TIMEOUT_BIN=.*#TIMEOUT_BIN=/nonexistent/timeout#' "$LC_DATA/settings" || return 1
    gsg status
    assert_rc 1 "a timeout that cannot run"
    assert_contains "$OUT" "timeout: /nonexistent/timeout (MISSING or not executable)" "flagged"
}

run_file_tests
