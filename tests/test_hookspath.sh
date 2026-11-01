#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

seed_old_hooks() {
    mkdir -p -- "$1" && printf '#!/bin/sh\necho old pre-commit\n' >"$1/pre-commit" && chmod 755 "$1/pre-commit"
}

tree_digest() { (cd -- "$1" && find . -type f -o -type l | LC_ALL=C sort | xargs -d '\n' sha256sum 2>&1 | sha256sum); }

# ^ security these tests run WITHOUT GIT_CONFIG_GLOBAL on a scratch HOME => git's own lookup of ~/.gitconfig, XDG and includes is what is under test
assert_refused_and_untouched() {
    local before="$1" file="$2" value="$3" what="$4"
    assert_rc 1 "$what"
    assert_contains "$ERR" "$file" "$what: names the file the value lives in"
    assert_contains "$ERR" "$value" "$what: and the value"
    assert_contains "$ERR" "nothing was changed" "$what: says nothing happened"
    assert_eq "$(tree_digest "$LC_HOME")" "$before" "$what: no file under HOME changed"
    assert_no_file "$LC_DATA" "$what: no share dir"
    assert_no_file "$LC_STATE" "$what: no state"
    assert_no_file "$LC_BIN" "$what: no tools"
}

test_install_refuses_a_hooks_path_that_lives_in_an_included_file() {
    local flag before
    for flag in "" --replace-hooks-path; do
        lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
        printf '[user]\n\tname = T\n[include]\n\tpath = extra.conf\n' >"$LC_HOME/.gitconfig" || return 1
        printf '[core]\n\thooksPath = /inc/hooks\n' >"$LC_HOME/extra.conf" || return 1
        before="$(tree_digest "$LC_HOME")"
        gsg install ${flag:+"$flag"}
        assert_refused_and_untouched "$before" "$LC_HOME/extra.conf" "/inc/hooks" "include, flag [$flag]"
    done
}

test_install_refuses_a_hooks_path_in_the_xdg_config_when_a_gitconfig_exists() {
    local flag before
    for flag in "" --replace-hooks-path; do
        lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
        printf '[user]\n\tname = T\n' >"$LC_HOME/.gitconfig" || return 1
        printf '[core]\n\thooksPath = /xdg/hooks\n' >"$LC_HOME/.config/git/config" || return 1
        before="$(tree_digest "$LC_HOME")"
        gsg install ${flag:+"$flag"}
        assert_refused_and_untouched "$before" "$LC_HOME/.config/git/config" "/xdg/hooks" "xdg, flag [$flag]"
    done
}

test_install_refuses_a_hooks_path_in_a_conditional_include() {
    local cond before flag
    for cond in 'hasconfig:remote.*.url:https://example.invalid/**' "gitdir:$SANDBOX/home/work/"; do
        for flag in "" --replace-hooks-path; do
            lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
            printf '[user]\n\tname = T\n[remote "o"]\n\turl = https://example.invalid/x\n[includeIf "%s"]\n\tpath = %s/cond.conf\n' \
                "$cond" "$LC_HOME" >"$LC_HOME/.gitconfig" || return 1
            printf '[core]\n\thooksPath = /cond/hooks\n' >"$LC_HOME/cond.conf" || return 1
            before="$(tree_digest "$LC_HOME")"
            gsg install ${flag:+"$flag"}
            assert_refused_and_untouched "$before" "$LC_HOME/cond.conf" "/cond/hooks" "includeIf [$cond] flag [$flag]"
        done
    done
}

test_install_takes_over_a_hooks_path_when_the_xdg_file_is_the_only_global_file() {
    lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
    seed_old_hooks "$LC_HOME/xh" || return 1
    printf '[core]\n\thooksPath = %s/xh\n' "$LC_HOME" >"$LC_HOME/.config/git/config" || return 1
    gsg install
    assert_rc 1 "plain install refuses the value git --global itself reads"
    assert_contains "$ERR" "core.hooksPath is set to [$LC_HOME/xh]" "with the existing message"
    gsg install --replace-hooks-path
    assert_rc 0 "takeover"
    assert_eq "$(state_value previous_hooks_path)" "$LC_HOME/xh" "recorded"
    assert_empty "$(gitreal config --get-all core.hooksPath)" "and gone from the effective config"
    assert_eq "$(gitreal config --global --get hook.git-secret-guard.event)" pre-commit "the hook config is in the XDG file git --global edits"
    assert_no_file "$LC_HOME/.gitconfig" "no second global file was created"
}

test_install_writes_the_hook_config_into_the_global_file_never_into_an_included_one() {
    local inc_before
    lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
    printf '[user]\n\tname = T\n[include]\n\tpath = extra.conf\n' >"$LC_HOME/.gitconfig" || return 1
    printf '[user]\n\temail = t@example.invalid\n' >"$LC_HOME/extra.conf" || return 1
    inc_before="$(sha256sum <"$LC_HOME/extra.conf")"
    gsg install
    assert_rc 0 "install next to an include that sets no hooksPath"
    assert_eq "$(sha256sum <"$LC_HOME/extra.conf")" "$inc_before" "the included file is byte-identical"
    assert_eq "$(gitreal config --file "$LC_HOME/.gitconfig" --get hook.git-secret-guard.event)" pre-commit "the hook config is in ~/.gitconfig"
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_eq "$(sha256sum <"$LC_HOME/extra.conf")" "$inc_before" "the included file is still byte-identical"
    assert_contains "$(<"$LC_HOME/.gitconfig")" "path = extra.conf" "and the include line survives in ~/.gitconfig"
}

test_a_symlinked_global_gitconfig_stays_a_symlink_through_install_and_uninstall() {
    lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$LC_HOME/dotfiles" && printf '[user]\n\tname = T\n' >"$LC_HOME/dotfiles/gitconfig" \
        && ln -s dotfiles/gitconfig "$LC_HOME/.gitconfig" || return 1
    gsg install
    assert_rc 0 "install"
    [ -L "$LC_HOME/.gitconfig" ] || fail "the global .gitconfig is no longer a symlink after install"
    assert_eq "$(readlink -- "$LC_HOME/.gitconfig")" dotfiles/gitconfig "and still points at the same target"
    assert_eq "$(gitreal config --file "$LC_HOME/dotfiles/gitconfig" --get hook.git-secret-guard.event)" pre-commit "the hook config went into the target"
    gsg uninstall
    assert_rc 0 "uninstall"
    [ -L "$LC_HOME/.gitconfig" ] || fail "the global .gitconfig is no longer a symlink after uninstall"
    assert_eq "$(gitreal config --file "$LC_HOME/dotfiles/gitconfig" --get-regexp '^hook\.' | wc -l)" 0 "the hook config left the target"
}

test_status_reports_the_effective_core_hooks_path() {
    lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install"
    gsg status
    assert_rc 0 "status"
    assert_contains "$OUT" "core.hooksPath (effective): unset" "nothing set"
    printf '[include]\n\tpath = extra.conf\n' >>"$LC_HOME/.gitconfig" || return 1
    printf '[core]\n\thooksPath = /inc/hooks\n' >"$LC_HOME/extra.conf" || return 1
    gsg status
    assert_rc 0 "status is informational about the effective value"
    assert_contains "$OUT" "core.hooksPath (effective): /inc/hooks ($LC_HOME/extra.conf)" "a value from an included file"
    gitreal config --global core.hooksPath /own/hooks || return 1
    gsg status
    assert_contains "$OUT" "/own/hooks ($LC_HOME/.gitconfig)" "and one from the global file itself"
    assert_contains "$OUT" "/inc/hooks ($LC_HOME/extra.conf)" "both are listed"
}

test_uninstall_does_not_restore_over_a_value_that_is_set_in_another_file() {
    local old
    lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
    old="$LC_HOME/old hooks"
    seed_old_hooks "$old" || return 1
    printf '[user]\n\tname = T\n[core]\n\thooksPath = %s\n' "$old" >"$LC_HOME/.gitconfig" || return 1
    gsg install --replace-hooks-path
    assert_rc 0 "takeover"
    printf '[include]\n\tpath = extra.conf\n' >>"$LC_HOME/.gitconfig" || return 1
    printf '[core]\n\thooksPath = /inc/hooks\n' >"$LC_HOME/extra.conf" || return 1
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_contains "$ERR" "$LC_HOME/extra.conf" "names the file that sets core.hooksPath"
    assert_contains "$ERR" "left as it is" "and leaves it"
    assert_empty "$(gitreal config --file "$LC_HOME/.gitconfig" --get core.hooksPath)" "nothing was written into ~/.gitconfig"
}

test_install_refuses_when_there_are_more_included_files_than_it_will_read() {
    local n before
    lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
    printf '[user]\n\tname = T\n' >"$LC_HOME/.gitconfig" || return 1
    for n in $(seq 1 65); do
        printf '[user]\n\temail = %s@example.invalid\n' "$n" >"$LC_HOME/inc$n.conf" || return 1
        printf '[includeIf "gitdir:/no/such/place/%s/"]\n\tpath = inc%s.conf\n' "$n" "$n" >>"$LC_HOME/.gitconfig" || return 1
    done
    before="$(tree_digest "$LC_HOME")"
    gsg install
    assert_rc 1 "65 include targets"
    assert_contains "$ERR" "more than 64 included git config files" "says why it cannot decide"
    assert_eq "$(tree_digest "$LC_HOME")" "$before" "nothing changed"
    assert_no_file "$LC_STATE" "no state"
}

test_a_failing_global_config_read_shows_git_s_reason_and_names_GIT_CONFIG() {
    local cmd
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    printf '[broken\n' >"$SANDBOX/gitconfig" || return 1
    for cmd in install uninstall; do
        gsg "$cmd"
        assert_rc 1 "$cmd over a broken global config"
        assert_contains "$ERR" "cannot read the global git config" "$cmd: says what failed"
        assert_contains "$ERR" "bad config" "$cmd: and carries git's own reason"
    done
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "a clean install first"
    set_env GIT_CONFIG="$SANDBOX/anything"
    for cmd in status uninstall install; do
        gsg "$cmd"
        assert_rc 1 "$cmd with GIT_CONFIG in the environment"
        assert_contains "$ERR" "GIT_CONFIG is set in the environment" "$cmd: names the variable that git config --global refuses"
    done
}

test_a_note_names_the_global_config_file_when_GIT_CONFIG_GLOBAL_is_set() {
    local cmd
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    for cmd in install status uninstall; do
        gsg "$cmd"
        assert_contains "$ERR" "note: GIT_CONFIG_GLOBAL is set; the global git config used is $SANDBOX/gitconfig" "$cmd prints the note"
    done
    lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install without GIT_CONFIG_GLOBAL"
    assert_not_contains "$ERR" "GIT_CONFIG_GLOBAL" "no note when the variable is not set"
}

run_file_tests
