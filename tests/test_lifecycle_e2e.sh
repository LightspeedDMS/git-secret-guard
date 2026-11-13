#!/usr/bin/env bash
# ^ external a dead proxy makes trufflehog's verification fail => result "unknown" (online, a fake credential is "unverified" and hidden)
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

DEAD_PROXY=(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9)

# ^ why an oracle, not a fixed answer; Windows seeds copies of the pinned binaries and install adopts those (#101), Linux seeds links, never adopted
# ^ invariant prints the seeded scanners, regular files only, whose SHA-256 is the lock's binary hash, space separated
seeded_pinned_scanners() {
    local scn plat want got seeded=""
    for scn in trufflehog betterleaks; do
        plat="$(lc_platform "$scn")" || return 1
        want="$(lc_lock_binary_sha "$scn" "$plat")" || return 1
        if [ -f "$LC_BIN/$scn$LC_EXE" ] && [ ! -L "$LC_BIN/$scn$LC_EXE" ]; then
            got="$(sha256sum -- "$LC_BIN/$scn$LC_EXE" | cut -d' ' -f1)" || return 1
            if [ -n "$want" ] && [ "$got" = "$want" ]; then seeded+="${seeded:+ }$scn"; fi
        fi
    done
    printf '%s\n' "$seeded"
}

commit_secret() {
    new_repo "$1" || return 1
    stage_file src/leak.txt one "token = \"$(fake_github_token)\"" || return 1
    commit_cap "leak $1"
}

assert_blocked_by_both_scanners() {
    local token
    token="$(fake_github_token)"
    assert_rc 1 "$1: the commit is blocked"
    assert_contains "$ERR" "trufflehog" "$1: trufflehog reported"
    assert_contains "$ERR" "betterleaks" "$1: betterleaks reported"
    assert_contains "$ERR" "src/leak.txt:2" "$1: real file and line"
    no_leak "$token"
    no_leak "${token:4}"
    assert_eq "$(gitx rev-parse -q --verify HEAD 2>/dev/null | wc -l)" 0 "$1: no commit was created"
}

test_install_block_upgrade_uninstall_and_uninstall_again_with_the_real_scanners() {
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    [ -x "$REAL_BETTERLEAKS" ] || skip_test "betterleaks not found at $REAL_BETTERLEAKS"
    lc_begin && lc_seed_real_tools || return 1
    local adopted
    adopted="$(seeded_pinned_scanners)" || return 1
    set_env "${DEAD_PROXY[@]}"

    commit_secret before
    assert_rc 0 "control: before install nothing scans the commit"

    gsg install
    assert_rc 0 "install with the real scanners"
    assert_eq "$(state_value tools_installed_by_us)" "$adopted" "both tools were already at the pin, nothing was downloaded; only a copy of the pinned binary is adopted as ours"
    commit_secret installed
    assert_blocked_by_both_scanners "after install"

    new_repo clean || return 1
    stage_file src/ok.txt "hello" "nothing secret" || return 1
    commit_cap "clean"
    assert_rc 0 "a clean commit passes through the installed hook"
    assert_empty "$OUT" "stdout stays empty"
    assert_pass_line_only "$ERR" "one pass line"
    assert_contains "$ERR" "(trufflehog 3.99.2, betterleaks 1.9.0): no findings" "the versions install recorded"

    gsg install
    assert_rc 0 "upgrade (second install)"
    commit_secret upgraded
    assert_blocked_by_both_scanners "after the upgrade"

    gsg uninstall
    assert_rc 0 "uninstall"
    assert_eq "$(gitx config --global --get-regexp '^hook\.git-secret-guard\.' | wc -l)" 0 "the hook config is gone"
    commit_secret removed
    assert_rc 0 "after uninstall the commit is no longer scanned"

    gsg uninstall
    assert_rc 0 "uninstall again"
    assert_contains "$OUT" "nothing to do" "reports nothing to do"
}

run_file_tests
