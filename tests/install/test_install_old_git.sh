#!/usr/bin/env bash
# ^ coupled install refuses a git older than 2.54 on PATH and warns about the other old gits it can reach (test_install_other_gits.sh pins the unit)
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

assert_untouched() {
    assert_no_file "$LC_STATE" "$1: no state dir"
    assert_no_file "$LC_DATA" "$1: no share dir"
    assert_no_file "$LC_BIN" "$1: no bin dir"
    assert_eq "$(cat -- "$SANDBOX/gitconfig")" "$GITCONFIG_BEFORE" "$1: global config unchanged"
}

GITCONFIG_BEFORE=""
snapshot_config() { GITCONFIG_BEFORE="$(cat -- "$SANDBOX/gitconfig")"; }

# ^ invariant make_old_git PATH VERSION writes an executable stand-in at PATH answering --version with VERSION
make_old_git() {
    mkdir -p -- "$(dirname -- "$1")" || return 1
    printf '#!/bin/sh\necho "git version %s"\n' "$2" >"$1" || return 1
    chmod 755 -- "$1"
}

# ^ invariant a fresh sandbox with the fixture tools, the state every install round of the warning test starts from
fresh_sandbox() { lc_begin && lc_make_fixtures && lc_use_fixtures; }

test_install_refuses_when_the_git_on_PATH_is_older_than_2_54() {
    local ver
    lc_begin || return 1
    snapshot_config
    for ver in 2.52.0 2.53.9 1.9.0; do
        lc_fake_git "$ver" || return 1
        gsg install
        assert_rc 1 "git $ver is too old"
        assert_contains "$ERR" "is git $ver; config-based hooks need git >= 2.54, install refused" "names the version found and why [$ver]"
        assert_untouched "git $ver"
    done
}

test_install_warns_but_proceeds_for_other_reachable_old_gits() {
    fresh_sandbox || return 1
    make_old_git "$SANDBOX/oldbin/git" 2.52.0 && make_old_git "$SANDBOX/oldbin2/git" 2.30.2 || return 1
    set_env PATH="$SANDBOX/pathbin:$TEST_BASE_PATH:$SANDBOX/oldbin:$SANDBOX/oldbin2:$SANDBOX/oldbin"
    gsg install
    assert_rc 0 "install proceeds"
    assert_contains "$ERR" "warning: $SANDBOX/oldbin/git is git 2.52.0" "warns about the first old git"
    assert_contains "$ERR" "warning: $SANDBOX/oldbin2/git is git 2.30.2" "and about the second"
    assert_contains "$ERR" "commits made with it are not scanned" "says what it means"
    assert_eq "$(grep -c "warning: $SANDBOX/oldbin/git" <<<"$ERR")" 1 "one warning per binary, though it is on PATH twice"
    assert_not_contains "$ERR" "warning: $GIT " "the git being used is not warned about"
    assert_file "$LC_STATE/state" "the install completed"
    # ^ why a stand-in root, not the host's /usr/bin/git; a host git of 2.54 or newer never ran the branch this replaces
    # ^ external lc_begin sets no GSG_GITUP_ROOT on Windows, Git for Windows has no /usr/bin/git and a link is a copy under MSYS
    if [ "$TEST_IS_WINDOWS" -ne 1 ]; then
        fresh_sandbox || return 1
        make_old_git "$SANDBOX/linkroot/usr/bin/git" 2.52.0 && ln -s usr/bin "$SANDBOX/linkroot/bin" || return 1
        set_env GSG_GITUP_ROOT="$SANDBOX/linkroot" PATH="$SANDBOX/pathbin:$TEST_BASE_PATH:$SANDBOX/linkroot/bin"
        gsg install
        assert_rc 0 "install with an old git behind /bin that links to /usr/bin"
        assert_contains "$ERR" "warning: $SANDBOX/linkroot/" "the old git is reported"
        assert_eq "$(grep -c "warning: $SANDBOX/linkroot/" <<<"$ERR")" 1 "once, though bin/git and usr/bin/git are the same file"
    fi
    fresh_sandbox || return 1
    lc_path_without git_none || return 1
    make_old_git "$SANDBOX/root/usr/bin/git" 2.52.0 || return 1
    gsg install
    assert_rc 0 "with a clean PATH"
    # ^ why the sandbox root, not the real /usr/bin; lc_begin points GSG_GITUP_ROOT at it on Linux and macOS, and sets none on Windows
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then
        assert_not_contains "$ERR" "warning: $SANDBOX/root/usr/bin/git" "a stand-in outside the real /usr/bin is not a checked position"
        return
    fi
    assert_contains "$ERR" "warning: $SANDBOX/root/usr/bin/git is git 2.52.0" "the always-checked /usr/bin position is checked even when it is not the first git on PATH"
}

run_file_tests
