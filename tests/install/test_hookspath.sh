#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

seed_old_hooks() {
    mkdir -p -- "$1" && printf '#!/bin/sh\necho old pre-commit\n' >"$1/pre-commit" && chmod 755 "$1/pre-commit"
}

# ^ why find -exec sha256sum, not the xargs delimiter option; BSD xargs (macOS) lacks it and its usage text was what got hashed (#48)
# ^ invariant prints one digest of every file and symlink target (sha256sum follows links) under $1; rc 1 and no output when find or sha256sum fails
# ^ coupled tests/install/test_install.sh keeps an identical copy and the same test of it
tree_digest() {
    local sums
    sums="$(cd -- "$1" && find . \( -type f -o -type l \) -exec sha256sum {} +)" || return 1
    printf '%s\n' "$sums" | LC_ALL=C sort | sha256sum
}

test_the_tree_digest_changes_with_a_file_and_fails_loudly_on_an_unreadable_one() {
    local d1 d2 d3
    mkdir -p -- "$SANDBOX/dg/sub" && printf 'one\n' >"$SANDBOX/dg/sub/f" || return 1
    d1="$(tree_digest "$SANDBOX/dg")" || return 1
    assert_eq "$(tree_digest "$SANDBOX/dg")" "$d1" "the same tree digests the same"
    printf 'two\n' >"$SANDBOX/dg/sub/f" || return 1
    d2="$(tree_digest "$SANDBOX/dg")" || return 1
    [ "$d2" != "$d1" ] || fail "a changed file did not change the digest"
    printf 'two\n' >"$SANDBOX/dg/sub/g" || return 1
    d3="$(tree_digest "$SANDBOX/dg")" || return 1
    [ "$d3" != "$d2" ] || fail "an added file did not change the digest"
    ln -s "$SANDBOX/dg/nowhere" "$SANDBOX/dg/dangling" || return 1
    if tree_digest "$SANDBOX/dg" >/dev/null 2>&1; then fail "a link sha256sum cannot read still produced a digest"; fi
}

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
        before="$(tree_digest "$LC_HOME")" || return 1
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
        before="$(tree_digest "$LC_HOME")" || return 1
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
            before="$(tree_digest "$LC_HOME")" || return 1
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
    assert_eq "$(gitreal config --global --get-all hook.git-secret-guard.event | tr '\n' ' ')" "pre-commit commit-msg " "the hook config is in the XDG file git --global edits"
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
    assert_eq "$(gitreal config --file "$LC_HOME/.gitconfig" --get-all hook.git-secret-guard.event | tr '\n' ' ')" "pre-commit commit-msg " "the hook config is in ~/.gitconfig"
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
    assert_eq "$(gitreal config --file "$LC_HOME/dotfiles/gitconfig" --get-all hook.git-secret-guard.event | tr '\n' ' ')" "pre-commit commit-msg " "the hook config went into the target"
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
    before="$(tree_digest "$LC_HOME")" || return 1
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
        assert_no_file "$LC_DATA" "$cmd: no share dir"
        assert_no_file "$LC_BIN" "$cmd: no tools"
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

# ^ external BSD realpath (macOS) has no -m; the stand-in refuses it and runs the real realpath for every other call, in a directory put first on PATH
bsd_realpath_dir() {
    local real dir="$SANDBOX/bsdbin"
    real="$(type -P realpath)" || return 1
    mkdir -p -- "$dir" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = -m ]; then echo "realpath: illegal option -- m" >&2; exit 1; fi\nfor last in "$@"; do :; done\nif [ "$last" != -- ] && [ ! -e "$last" ]; then echo "realpath: $last: No such file or directory" >&2; exit 1; fi\ncase "$last" in *.noreal) echo "realpath: $last: Permission denied" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$real" >"$dir/realpath" || return 1
    chmod 755 "$dir/realpath" || return 1
    printf '%s' "$dir"
}

test_an_include_pointing_at_a_dangling_symlink_is_skipped_like_git_does() {
    local fake
    lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
    fake="$(bsd_realpath_dir)" || return 1
    ln -s "$SANDBOX/deleted-dotfiles/gitconfig.local" "$LC_HOME/.gitconfig.local" || return 1
    printf '[user]\n\tname = T\n[include]\n\tpath = ~/.gitconfig.local\n' >"$LC_HOME/.gitconfig" || return 1
    EXTRA_ENV+=(PATH="$fake:$SANDBOX/pathbin:$TEST_BASE_PATH")
    gsg install
    assert_rc 0 "install with an include whose target is a dangling symlink, BSD realpath"
    assert_not_contains "$ERR" "No such file or directory" "no raw realpath error reaches the user"
}

test_a_dangling_include_does_not_hide_a_later_include_that_sets_core_hooks_path() {
    local fake
    lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
    fake="$(bsd_realpath_dir)" || return 1
    printf '[core]\n\thooksPath = /foreign-hooks\n' >"$LC_HOME/second.conf" || return 1
    printf '[includeIf "gitdir:/a/"]\n\tpath = dangling.conf\n[includeIf "gitdir:/b/"]\n\tpath = second.conf\n' >"$LC_HOME/.gitconfig" || return 1
    EXTRA_ENV+=(PATH="$fake:$SANDBOX/pathbin:$TEST_BASE_PATH")
    gsg install --replace-hooks-path
    assert_rc 1 "a skipped dangling include must not stop the walk, BSD realpath"
    assert_contains "$ERR" "/foreign-hooks" "the value set by the later include is seen and named"
    assert_no_file "$LC_BIN" "nothing was installed"
}

test_an_include_that_realpath_cannot_resolve_is_refused_with_a_message_of_ours() {
    local fake
    lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
    fake="$(bsd_realpath_dir)" || return 1
    printf '[user]\n\temail = t@example.invalid\n' >"$LC_HOME/inc.noreal" || return 1
    printf '[user]\n\tname = T\n[include]\n\tpath = ~/inc.noreal\n' >"$LC_HOME/.gitconfig" || return 1
    EXTRA_ENV+=(PATH="$fake:$SANDBOX/pathbin:$TEST_BASE_PATH")
    gsg install
    assert_rc 1 "an existing include that realpath cannot resolve"
    assert_contains "$ERR" "git-secret-guard: cannot resolve the include path $LC_HOME/inc.noreal" "our own line names the path"
    assert_contains "$ERR" "nothing was changed" "the claim is true: nothing ran yet"
    assert_no_file "$LC_BIN" "no tool installed"
    assert_no_file "$LC_STATE" "no state dir"
}

test_the_global_config_read_does_not_need_a_realpath_that_knows_dash_m() {
    local fake before
    lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
    fake="$(bsd_realpath_dir)" || return 1
    printf '[user]\n\tname = T\n[include]\n\tpath = extra.conf\n' >"$LC_HOME/.gitconfig" || return 1
    printf '[core]\n\thooksPath = /inc/hooks\n' >"$LC_HOME/extra.conf" || return 1
    EXTRA_ENV+=(PATH="$fake:$SANDBOX/pathbin:$TEST_BASE_PATH")
    before="$(tree_digest "$LC_HOME")" || return 1
    gsg install
    assert_refused_and_untouched "$before" "$LC_HOME/extra.conf" "/inc/hooks" "the include was walked without realpath -m, so the value in it is seen"
    printf '[user]\n\temail = t@example.invalid\n' >"$LC_HOME/extra.conf" || return 1
    gsg install
    assert_rc 0 "install on a machine whose realpath has no -m, with an include in the global config"
    assert_file "$LC_DATA/hooks/secret-scan" "installed"
}

test_lifecycle_realpath_m_normalizes_a_missing_tail_and_resolves_a_symlinked_ancestor() {
    local fake base
    lc_begin || return 1
    fake="$(bsd_realpath_dir)" || return 1
    base="$(cd -- "$SANDBOX" && pwd -P)/rp" || return 1
    mkdir -p -- "$base/target" && ln -s target "$base/link" || return 1
    # shellcheck disable=SC2016
    run_cap env -i "${LC_ENV[@]}" PATH="$fake:$SANDBOX/pathbin:$TEST_BASE_PATH" bash -c \
        'source "$1/lib/core/common.sh" && source "$1/lib/install/hookspath.sh" && lifecycle_realpath_m "$2"' _ "$GSG_PROJECT" "$base/link/new/./sub/../x//y"
    assert_rc 0 "a path below a symlink with a missing tail"
    assert_eq "$OUT" "$base/target/new/x/y" "symlink resolved, dot, dotdot and double slash normalized"
    # shellcheck disable=SC2016
    run_cap env -i "${LC_ENV[@]}" PATH="$fake:$SANDBOX/pathbin:$TEST_BASE_PATH" bash -c \
        'source "$1/lib/core/common.sh" && source "$1/lib/install/hookspath.sh" && lifecycle_realpath_m "$2"' _ "$GSG_PROJECT" "relative/path"
    assert_rc 1 "a relative path is refused"
}

hp_records_probe() {
    # shellcheck disable=SC2016
    run_cap env -i "${LC_ENV[@]}" PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" GSG_GIT="$1" bash -c \
        'set -u; source "$1/lib/core/common.sh" && source "$1/lib/install/hookspath.sh"; hp_records a b; rc=$?; printf "rc=%s n=%s err=[%s]\n" "$rc" "${#GSG_HP_OUT[@]}" "$GSG_HP_ERR"; printf "<%s>\n" "${GSG_HP_OUT[@]}"; exit "$rc"' _ "$GSG_PROJECT"
}

test_hp_records_returns_git_s_own_status_and_reads_nul_records_without_a_wait() {
    local fake
    lc_begin || return 1
    fake="$SANDBOX/fakegit"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nprintf "one\\0two words\\0"\necho "boom $*" >&2\nexit "${FAKE_RC:-0}"\n' >"$fake" && chmod 755 "$fake" || return 1
    hp_records_probe "$fake"
    assert_rc 0 "git succeeded"
    assert_contains "$OUT" "rc=0 n=2 err=[boom a b]" "two records, first stderr line"
    assert_contains "$OUT" "<two words>" "NUL separated records are intact"
    # shellcheck disable=SC2016
    run_cap env -i "${LC_ENV[@]}" FAKE_RC=7 PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" GSG_GIT="$fake" bash -c \
        'source "$1/lib/core/common.sh" && source "$1/lib/install/hookspath.sh"; hp_records x; exit "$?"' _ "$GSG_PROJECT"
    assert_rc 7 "git's own exit status, whatever it is"
    assert_eq "$(sed -n '/^hp_records()/,/^}/p' "$GSG_PROJECT/lib/install/hookspath.sh" | grep -cE 'wait |< <\(')" "0" \
        "hp_records neither waits nor reads a process substitution (the wait raced with bash's reaping)"
}

# ^ why gitdir:/no/such/place/ as the condition, not a matching one; git lists no target of it, the static walk of ours alone reads them
test_install_refuses_a_hooks_path_two_includes_deep() {
    local variant flag before
    for variant in plain conditional; do
        for flag in "" --replace-hooks-path; do
            lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
            if [ "$variant" = plain ]; then
                printf '[user]\n\tname = T\n[include]\n\tpath = a.conf\n' >"$LC_HOME/.gitconfig" || return 1
            else
                printf '[user]\n\tname = T\n[includeIf "gitdir:/no/such/place/"]\n\tpath = a.conf\n' >"$LC_HOME/.gitconfig" || return 1
            fi
            printf '[include]\n\tpath = b.conf\n' >"$LC_HOME/a.conf" || return 1
            printf '[core]\n\thooksPath = /nested/hooks\n' >"$LC_HOME/b.conf" || return 1
            before="$(tree_digest "$LC_HOME")" || return 1
            gsg install ${flag:+"$flag"}
            assert_refused_and_untouched "$before" "$LC_HOME/b.conf" "/nested/hooks" "$variant include of an include, flag [$flag]"
        done
    done
}

test_install_ends_when_two_included_files_include_each_other() {
    lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
    printf '[user]\n\tname = T\n[includeIf "gitdir:/no/such/place/"]\n\tpath = a.conf\n' >"$LC_HOME/.gitconfig" || return 1
    printf '[include]\n\tpath = b.conf\n' >"$LC_HOME/a.conf" || return 1
    printf '[include]\n\tpath = a.conf\n' >"$LC_HOME/b.conf" || return 1
    run_cap "$TEST_TIMEOUT" 120 env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" install
    assert_rc 0 "an include cycle that sets no hooksPath: the walk ends and the install goes through (a timeout would be 124)"
    assert_not_contains "$ERR" "more than" "the include limit is not what stopped the walk"
    assert_file "$LC_DATA/hooks/secret-scan" "installed"
}

# ^ why git is asked in a matching repository, not at /; the unreadable file could apply only there
unreadable_include_setup() {
    local kind="$1"
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then skip_test "NTFS has no unix modes"; fi
    if [ "$(id -u)" -eq 0 ]; then skip_test "root reads a file of mode 000"; fi
    lc_begin && lc_real_lookup && lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$LC_HOME/work/repo" || return 1
    gitreal init -q "$LC_HOME/work/repo" || return 1
    if [ "$kind" = plain ]; then
        printf '[user]\n\tname = T\n[include]\n\tpath = secret.conf\n' >"$LC_HOME/.gitconfig" || return 1
    else
        printf '[user]\n\tname = T\n[includeIf "gitdir:%s/work/"]\n\tpath = secret.conf\n' "$LC_HOME" >"$LC_HOME/.gitconfig" || return 1
    fi
    printf '[core]\n\thooksPath = /hidden/hooks\n' >"$LC_HOME/secret.conf" || return 1
}

test_install_refuses_when_a_plain_include_is_unreadable() {
    local flag before
    for flag in "" --replace-hooks-path; do
        unreadable_include_setup plain || return 1
        before="$(tree_digest "$LC_HOME")" || return 1
        chmod 000 "$LC_HOME/secret.conf" || return 1
        gsg install ${flag:+"$flag"}
        chmod 644 "$LC_HOME/secret.conf" || return 1
        assert_rc 1 "an unreadable included file, flag [$flag]"
        assert_contains "$ERR" "$LC_HOME/secret.conf" "names the unreadable file"
        assert_contains "$ERR" "Permission denied" "with git's own reason"
        assert_no_file "$LC_DATA" "no share dir"
        assert_no_file "$LC_STATE" "no state"
        assert_eq "$(tree_digest "$LC_HOME")" "$before" "no file under HOME changed"
    done
}

test_an_unreadable_conditional_include_cannot_apply_a_hooks_path_in_silence() {
    unreadable_include_setup conditional || return 1
    chmod 000 "$LC_HOME/secret.conf" || return 1
    gsg install
    assert_rc 0 "install: git reads the file only inside a matching repository"
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GIT" -C "$LC_HOME/work/repo" config --get core.hooksPath
    chmod 644 "$LC_HOME/secret.conf" || return 1
    assert_rc 128 "git in the matching repository dies, so the unreadable core.hooksPath is never applied silently"
    assert_contains "$ERR" "$LC_HOME/secret.conf" "and names the file"
}

run_file_tests
