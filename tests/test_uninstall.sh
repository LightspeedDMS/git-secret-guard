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

hooks_path_is_unset() {
    gitx config --global --get core.hooksPath >/dev/null
    [ "$?" -eq 1 ]
}

test_uninstall_removes_what_install_added_and_keeps_the_tools() {
    fresh_install
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_eq "$(gitx config --global --get-regexp '^hook\.git-secret-guard\.' | wc -l)" 0 "no hook.git-secret-guard keys"
    assert_not_contains "$(cat -- "$SANDBOX/gitconfig")" "git-secret-guard" "the section header is gone too"
    assert_contains "$(cat -- "$SANDBOX/gitconfig")" "Test User" "the rest of the global config is intact"
    hooks_path_is_unset || fail "core.hooksPath is not unset"
    assert_no_file "$LC_DATA" "share dir removed"
    assert_no_file "$LC_BIN/git-secret-guard" "CLI link removed"
    assert_no_file "$LC_STATE" "state removed (no backup, so the state dir goes too)"
    assert_eq "$("$LC_BIN/trufflehog" --version)" "trufflehog 3.99.2" "trufflehog left in place"
    assert_eq "$("$LC_BIN/gitleaks" --version)" "gitleaks version 8.30.1" "gitleaks left in place"
}

test_uninstall_twice_reports_nothing_to_do() {
    fresh_install
    gsg uninstall
    assert_rc 0 "first uninstall"
    local cfg
    cfg="$(cat -- "$SANDBOX/gitconfig")"
    gsg uninstall
    assert_rc 0 "second uninstall"
    assert_contains "$OUT" "nothing to do" "says so"
    gsg uninstall --remove-tools
    assert_rc 0 "third, with --remove-tools"
    assert_contains "$OUT" "nothing to do" "says so again"
    assert_eq "$(cat -- "$SANDBOX/gitconfig")" "$cfg" "the config is not touched by the repeat runs"
    assert_eq "$("$LC_BIN/trufflehog" --version)" "trufflehog 3.99.2" "and the tools are still there: no state, no record of what to remove"
}

seed_old_hooks() {
    mkdir -p -- "$1/sub" && printf '#!/bin/sh\necho old pre-commit\n' >"$1/pre-commit" && chmod 755 "$1/pre-commit" \
        && printf 'nested\n' >"$1/sub/data.txt"
}

test_uninstall_restores_the_recorded_hooks_path_verbatim_and_keeps_the_backup() {
    local value dir backup
    # shellcheck disable=SC2088
    for value in '~/.config/git/hooks' "$SANDBOX/home/my hooks" ''; do
        lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
        dir="$LC_HOME/.config/git/hooks"
        case "$value" in /*) dir="$value" ;; esac
        seed_old_hooks "$dir" || return 1
        gitx config --global core.hooksPath "$value" || return 1
        gsg install --replace-hooks-path
        assert_rc 0 "takeover of [$value]"
        backup="$(state_value backup_path)"
        gsg uninstall
        assert_rc 0 "uninstall after the takeover of [$value]"
        assert_eq "$(gitx config --global --get core.hooksPath)" "$value" "core.hooksPath is back, verbatim"
        assert_eq "$(cfg_all_count core.hooksPath)" 1 "and single-valued"
        assert_no_file "$LC_STATE/state" "state file removed"
        if [ -n "$backup" ]; then
            assert_file "$backup" "the backup tarball is kept"
            assert_contains "$OUT" "$backup" "and its location is printed"
            assert_file "$dir/pre-commit" "the old hooks dir is untouched"
        fi
    done
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    gsg uninstall
    hooks_path_is_unset || fail "an 'unset' record leaves core.hooksPath unset"
}

test_uninstall_restores_core_hooks_path_before_removing_the_hook_config() {
    local old
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    old="$LC_HOME/old hooks"
    seed_old_hooks "$old" || return 1
    gitx config --global core.hooksPath "$old" || return 1
    gsg install --replace-hooks-path
    assert_rc 0 "takeover"
    # shellcheck disable=SC2016
    lc_git_wrapper '[ "$1" = config ] && [ "$3" = core.hooksPath ] && [ "$#" -eq 4 ]' || return 1
    gsg uninstall
    assert_rc 1 "git refuses to write core.hooksPath"
    assert_contains "$ERR" "core.hooksPath not restored" "says what failed"
    assert_contains "$ERR" "run uninstall again" "and what to do"
    assert_eq "$(gitx config --global --get hook.git-secret-guard.event)" pre-commit "the hook config is still there: commits stay scanned"
    assert_file "$LC_DATA/hooks/secret-scan" "the hook it points to is still there"
    assert_file "$LC_STATE/state" "the record is kept so the second run knows the old value"
    rm -f -- "$SANDBOX/pathbin/git"
    gsg uninstall
    assert_rc 0 "second run without the failure"
    assert_eq "$(gitx config --global --get core.hooksPath)" "$old" "core.hooksPath is back"
    assert_eq "$(gitx config --global --get-regexp '^hook\.git-secret-guard\.' | wc -l)" 0 "and the hook config is gone"
    assert_no_file "$LC_DATA" "share dir removed"
}

seed_tool() {
    mkdir -p -- "$LC_BIN" || return 1
    printf '#!/bin/sh\necho "%s"\n' "$2" >"$LC_BIN/$1" || return 1
    chmod 755 "$LC_BIN/$1"
}

test_remove_tools_removes_only_what_install_downloaded() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    seed_tool trufflehog "trufflehog 3.99.2" || return 1
    gsg install
    assert_rc 0 "install: trufflehog is the user's, gitleaks is downloaded"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    assert_no_file "$LC_BIN/gitleaks" "the downloaded gitleaks is removed"
    assert_file "$LC_BIN/trufflehog" "the user's trufflehog stays"
    assert_contains "$OUT" "removed $LC_BIN/gitleaks" "and the removal is reported"

    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    gsg uninstall --remove-tools
    assert_rc 0 "both downloaded"
    assert_eq "$(find "$LC_BIN" -mindepth 1 | wc -l)" 0 "both are removed, nothing else was in ~/.local/bin"

    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    gsg uninstall
    assert_file "$LC_BIN/trufflehog" "without the flag trufflehog stays"
    assert_file "$LC_BIN/gitleaks" "and so does gitleaks"
}

ORIG_SHA="" ORIG_MODE=""
replaced_install() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$LC_BIN" || return 1
    printf '#!/bin/sh\necho "gitleaks version 8.18.4"\n# user build\n' >"$LC_BIN/gitleaks" || return 1
    chmod 750 "$LC_BIN/gitleaks" || return 1
    ORIG_SHA="$(sha256sum <"$LC_BIN/gitleaks")" || return 1
    ORIG_MODE="$(stat -c %a "$LC_BIN/gitleaks")" || return 1
    gsg install
    assert_rc 0 "install over the user's gitleaks"
}

assert_original_is_back() {
    assert_eq "$(sha256sum <"$LC_BIN/gitleaks")" "$ORIG_SHA" "$1: the user's gitleaks is byte-identical"
    assert_eq "$(stat -c %a "$LC_BIN/gitleaks")" "$ORIG_MODE" "$1: and has its mode"
    assert_empty "$(find "$LC_BIN" -name '*.gsg-replaced-*')" "$1: the aside file was consumed by the restore"
}

test_uninstall_puts_the_users_replaced_tool_back_byte_identical() {
    replaced_install || return 1
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_original_is_back "plain uninstall"
    assert_contains "$OUT" "restored $LC_BIN/gitleaks" "says so"
    assert_file "$LC_BIN/trufflehog" "the tool install downloaded onto an empty path stays without --remove-tools"
    assert_no_file "$LC_STATE" "state removed"

    replaced_install || return 1
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    assert_original_is_back "with --remove-tools"
    assert_no_file "$LC_BIN/trufflehog" "the tool that was ours is removed"
}

test_uninstall_leaves_a_tool_changed_since_install_and_keeps_the_original_aside() {
    replaced_install || return 1
    printf 'newer file of the user\n' >"$LC_BIN/gitleaks" || return 1
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall"
    assert_contains "$ERR" "is not the file install put there" "says why it did not restore"
    assert_eq "$(<"$LC_BIN/gitleaks")" "newer file of the user" "the newer file is untouched, also with --remove-tools"
    assert_eq "$(find "$LC_BIN" -name 'gitleaks.gsg-replaced-*' | wc -l)" 1 "the original stays aside"
    assert_contains "$ERR" "gitleaks.gsg-replaced-" "and its location is printed"
}

test_uninstall_reads_core_hooks_path_without_touching_the_install_globals() {
    local old
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    old="$LC_HOME/old hooks"
    seed_old_hooks "$old" || return 1
    gitx config --global core.hooksPath "$old" || return 1
    gsg install --replace-hooks-path
    assert_rc 0 "takeover"
    # shellcheck disable=SC2016
    run_cap env -i "${LC_ENV[@]}" bash -c '
        for l in common state tools hookspath install uninstall; do source "$1/lib/$l.sh" || exit 10; done
        GSG_ROOT="$1"; GSG_UNINSTALL_ACTIONS=0; GSG_PREV_SET=sentinel-set; GSG_PREV=sentinel-value
        paths_init && lifecycle_require_git && state_read && uninstall_restore_hooks_path || exit 11
        printf "%s|%s\n" "$GSG_PREV_SET" "$GSG_PREV"' _ "$GSG_PROJECT"
    assert_rc 0 "uninstall_restore_hooks_path"
    assert_contains "$OUT" "sentinel-set|sentinel-value" "GSG_PREV_SET and GSG_PREV belong to install and are left alone"
    assert_eq "$(gitx config --global --get core.hooksPath)" "$old" "and the recorded value was restored"
}

test_uninstall_does_not_overwrite_a_symlink_the_user_put_at_the_tool_path() {
    replaced_install || return 1
    cp -p -- "$LC_BIN/gitleaks" "$LC_HOME/mine" || return 1
    rm -f -- "$LC_BIN/gitleaks" && ln -s "$LC_HOME/mine" "$LC_BIN/gitleaks" || return 1
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_eq "$(readlink -- "$LC_BIN/gitleaks")" "$LC_HOME/mine" "the symlink stays"
    assert_contains "$ERR" "is not the file install put there" "and the user is told"
    assert_eq "$(find "$LC_BIN" -name 'gitleaks.gsg-replaced-*' | wc -l)" 1 "the original stays aside"
}

test_uninstall_reports_a_missing_original_and_leaves_the_tool() {
    replaced_install || return 1
    rm -f -- "$LC_BIN"/gitleaks.gsg-replaced-* || return 1
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall"
    assert_contains "$ERR" "is missing" "says the original is gone"
    assert_eq "$("$LC_BIN/gitleaks" --version)" "gitleaks version 8.30.1" "the tool at the path is left, not deleted"
}

test_remove_tools_never_deletes_an_original_it_just_restored() {
    replaced_install || return 1
    sed -i 's#^tools_installed_by_us=.*#tools_installed_by_us=trufflehog gitleaks#' "$LC_STATE/state" || return 1
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools with gitleaks in both lists"
    assert_original_is_back "both lists"
    assert_no_file "$LC_BIN/trufflehog" "the tool that is only ours is removed"
}

test_remove_tools_keeps_a_same_version_build_that_replaced_installs_file() {
    fresh_install
    printf '#!/bin/sh\n# my own build\necho "gitleaks version 8.30.1"\n' >"$LC_BIN/gitleaks" || return 1
    chmod 755 "$LC_BIN/gitleaks" || return 1
    gsg install
    assert_rc 0 "install keeps a build that already reports the pinned version"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    assert_file "$LC_BIN/gitleaks" "the user's build is still there"
    assert_contains "$(<"$LC_BIN/gitleaks")" "my own build" "byte for byte the user's file"
    assert_contains "$ERR" "$LC_BIN/gitleaks is not the file install put there; left in place" "and the user is told why"
    assert_not_contains "$OUT" "removed $LC_BIN/gitleaks" "it is not claimed as removed"
    assert_no_file "$LC_BIN/trufflehog" "the file install placed and nobody touched is removed"
}

test_remove_tools_keeps_a_symlink_at_the_tool_path() {
    fresh_install
    cp -p -- "$LC_BIN/gitleaks" "$LC_HOME/mine" || return 1
    rm -f -- "$LC_BIN/gitleaks" && ln -s "$LC_HOME/mine" "$LC_BIN/gitleaks" || return 1
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    assert_eq "$(readlink -- "$LC_BIN/gitleaks")" "$LC_HOME/mine" "the symlink stays"
    assert_file "$LC_HOME/mine" "and so does its target"
    assert_contains "$ERR" "$LC_BIN/gitleaks is not the file install put there; left in place" "with the reason"
    assert_no_file "$LC_BIN/trufflehog" "the regular file install placed is removed"
}

test_remove_tools_keeps_every_tool_when_the_state_has_no_tools_placed() {
    fresh_install
    sed -i '/^tools_placed=/d;/^tools_replaced=/d' "$LC_STATE/state" || return 1
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools with a state written before tools_placed existed"
    assert_file "$LC_BIN/trufflehog" "trufflehog cannot be proved to be install's, so it stays"
    assert_file "$LC_BIN/gitleaks" "and so does gitleaks"
    assert_contains "$ERR" "$LC_BIN/gitleaks has no recorded hash of a file install placed (state written by an older install); left in place" "the reason is printed"
    assert_not_contains "$OUT" "downloaded by install" "nothing is claimed as removed"
}

test_remove_tools_says_the_tools_placed_entry_is_invalid_when_the_key_exists_but_is_malformed() {
    local good
    fresh_install
    good="$(sha256sum -- "$LC_BIN/trufflehog" | cut -d' ' -f1)" || return 1
    sed -i "s#^tools_placed=.*#tools_placed=gitleaks:not-a-hash trufflehog:$good#" "$LC_STATE/state" || return 1
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    assert_contains "$ERR" "invalid tools_placed entry [gitleaks:not-a-hash] in the state file; ignored" "the bad entry is reported, as before"
    assert_contains "$ERR" "the tools_placed entry for gitleaks in the state file is invalid or missing; $LC_BIN/gitleaks left in place" "and the tool's line says so"
    assert_not_contains "$ERR" "older install" "a malformed entry is not blamed on an older install"
    assert_file "$LC_BIN/gitleaks" "gitleaks stays"
    assert_no_file "$LC_BIN/trufflehog" "the valid entry still allows the removal"
}

test_uninstall_ignores_tampered_replaced_entries() {
    replaced_install || return 1
    printf 'precious\n' >"$LC_HOME/.local/escape" || return 1
    sed -i 's#^tools_replaced=.*#tools_replaced=../escape:0000000000000000000000000000000000000000000000000000000000000000 git.gsg-replaced-20260101T000000Z:00#' "$LC_STATE/state" || return 1
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_contains "$ERR" "invalid tools_replaced entry [../escape:" "reports the first bad entry"
    assert_contains "$ERR" "invalid tools_replaced entry [git.gsg-replaced-" "and the second"
    assert_eq "$(<"$LC_HOME/.local/escape")" precious "nothing outside the recorded names was touched"
    assert_eq "$("$LC_BIN/gitleaks" --version)" "gitleaks version 8.30.1" "and no restore happened"
}

test_remove_tools_ignores_names_it_does_not_know_and_explains_a_missing_state() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    sed -i 's#^tools_installed_by_us=.*#tools_installed_by_us=../escape gitleaks git#' "$LC_STATE/state" || return 1
    printf 'precious\n' >"$LC_HOME/.local/escape"
    printf 'precious\n' >"$LC_BIN/git"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall"
    assert_contains "$ERR" "unknown tool [../escape]" "an unknown name in the state is reported"
    assert_contains "$ERR" "unknown tool [git]" "also a plausible-looking one"
    assert_no_file "$LC_BIN/gitleaks" "the known tool is removed"
    assert_file "$LC_BIN/trufflehog" "the one not listed stays"
    assert_file "$LC_HOME/.local/escape" "nothing outside ~/.local/bin was touched"
    assert_file "$LC_BIN/git" "and a file named like an unknown tool stays"

    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    rm -f -- "$LC_STATE/state"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall without a state file"
    assert_contains "$ERR" "no state file: cannot tell which tools install downloaded; none removed" "explains why no tool was removed"
    assert_file "$LC_BIN/trufflehog" "trufflehog stays"
    assert_no_file "$LC_DATA" "but the rest is removed"
}

test_uninstall_keeps_what_the_user_changed_since_install() {
    local other
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    seed_old_hooks "$LC_HOME/old hooks" || return 1
    gitx config --global core.hooksPath "$LC_HOME/old hooks" || return 1
    gsg install --replace-hooks-path
    assert_rc 0 "takeover"
    other="$LC_HOME/newer hooks"
    gitx config --global core.hooksPath "$other" || return 1
    gitx config --global hook.other.command /bin/true || return 1
    gitx config --global hook.other.event pre-push || return 1
    rm -f -- "$LC_BIN/git-secret-guard" && ln -s /bin/true "$LC_BIN/git-secret-guard" || return 1
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_eq "$(gitx config --global --get core.hooksPath)" "$other" "a newer core.hooksPath is not overwritten by the recorded one"
    assert_contains "$ERR" "left as it is" "and the user is told"
    assert_eq "$(gitx config --global --get hook.other.command)" /bin/true "other hook sections are untouched"
    assert_eq "$(readlink -- "$LC_BIN/git-secret-guard")" /bin/true "a link that is not ours is left in place"
    assert_contains "$ERR" "is not the link install created" "and reported"
    assert_no_file "$LC_STATE/state" "state removed"
}

test_uninstall_refuses_a_malformed_state_and_changes_nothing() {
    fresh_install
    printf 'garbage\n' >"$LC_STATE/state" || return 1
    local cfg
    cfg="$(cat -- "$SANDBOX/gitconfig")"
    gsg uninstall
    assert_rc 1 "malformed state"
    assert_contains "$ERR" "is malformed" "says why"
    assert_eq "$(cat -- "$SANDBOX/gitconfig")" "$cfg" "config unchanged"
    assert_file "$LC_DATA/hooks/secret-scan" "share dir unchanged"
    assert_file "$LC_BIN/git-secret-guard" "link unchanged"
}

test_uninstall_without_a_state_file_still_removes_the_rest_and_leaves_hooks_path_alone() {
    fresh_install
    rm -f -- "$LC_STATE/state" || return 1
    gitx config --global core.hooksPath /somewhere/else || return 1
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_no_file "$LC_DATA" "share dir removed"
    assert_no_file "$LC_BIN/git-secret-guard" "link removed"
    assert_eq "$(gitx config --global --get-regexp '^hook\.git-secret-guard\.' | wc -l)" 0 "hook section removed"
    assert_eq "$(gitx config --global --get core.hooksPath)" /somewhere/else "core.hooksPath is unknown without a record, so it is not touched"
}

test_the_share_dir_removal_refuses_a_path_that_is_not_ours() {
    lc_begin || return 1
    mkdir -p -- "$SANDBOX/precious" "$SANDBOX/relative/git-secret-guard" && printf 'keep\n' >"$SANDBOX/precious/file" \
        && printf 'keep\n' >"$SANDBOX/relative/git-secret-guard/file" || return 1
    local share
    for share in "$SANDBOX/precious" "relative/git-secret-guard"; do
        # shellcheck disable=SC2016
        run_cap env -i "${GSG_ENV[@]}" bash -c \
            'source "$1/lib/common.sh" && source "$1/lib/uninstall.sh" && GSG_SHARE="$2" && GSG_UNINSTALL_ACTIONS=0 && uninstall_share_dir' _ "$GSG_PROJECT" "$share"
        assert_rc 1 "[$share]"
        assert_contains "$ERR" "refusing to remove" "says why"
    done
    assert_file "$SANDBOX/precious/file" "an absolute path with the wrong name was not removed"
    assert_file "$SANDBOX/relative/git-secret-guard/file" "a relative path with the right name was not removed"
}

cfg_all_count() { gitx config --global --get-all "$1" | wc -l; }

run_file_tests
