#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016
# ^ why SC2016 off for the file, not per call; every gu_run body is single-quoted for the child shell to expand, as in tests/support/gitup.sh
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/gitup.sh"

# ^ external the refusals read unix owners and modes and the registry loads module files; Windows has its own module and test files
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="unix owners and modes, Linux package manager flows"; fi

# ^ invariant gur_sysbin sets up a sandbox system directory holding a dnf stand-in of mode 755, a marker file records each run
gur_sysbin() {
    lc_begin || return 1
    mkdir -p -- "$SANDBOX/sysbin" || return 1
    printf '#!/bin/sh\necho ran >>"%s/dnf.ran"\n' "$SANDBOX" >"$SANDBOX/sysbin/dnf" && chmod 755 "$SANDBOX/sysbin/dnf" || return 1
    set_env GSG_GITUP_ROOT="$SANDBOX/root" GSG_GITUP_BUILD_PATH="$SANDBOX/sysbin"
}

test_a_tool_owned_by_someone_other_than_the_trusted_user_is_not_a_system_tool() {
    gur_sysbin || return 1
    gu_run 'gitup_system_bin dnf; rc=$?; printf "rc=%s reply=[%s]\n" "$rc" "$REPLY"'
    assert_contains "$OUT" "rc=0 reply=[$SANDBOX/sysbin/dnf]" "control: the owner of the sandbox is the trusted user, so the tool is found"
    gu_run 'gitup_trusted_uid() { echo 12345; }; gitup_system_bin dnf; rc=$?; printf "rc=%s reply=[%s]\n" "$rc" "$REPLY"'
    assert_contains "$OUT" "rc=1 reply=[]" "the same file owned by another uid than the trusted one is not accepted and leaves no reply"
}

test_the_elevation_of_a_tool_owned_by_someone_other_than_the_trusted_user_is_refused_and_runs_nothing() {
    gur_sysbin || return 1
    gu_run 'gitup_is_root() { return 0; }; gitup_trusted_uid() { echo 12345; }; gitup_elevate dnf install -y git'
    assert_rc 1 "the only dnf in the system path has another owner"
    assert_contains "$ERR" "dnf was not found in the system path ($SANDBOX/sysbin) or is not owned by root; nothing was run" "says why"
    assert_no_file "$SANDBOX/dnf.ran" "the tool never ran"
    gu_run 'gitup_is_root() { return 0; }; gitup_elevate dnf install -y git'
    assert_rc 0 "control: with the real trusted owner the same call runs the tool"
    assert_file "$SANDBOX/dnf.ran" "and the tool ran"
}

test_a_root_override_that_is_relative_or_holds_a_control_character_is_refused_and_the_value_is_shown_safely() {
    local r shown
    lc_begin || return 1
    for r in "relative/dir" "a" $'rel\tative' $'/abs\tolute' $'/abs\nolute' $'/abs\x1bolute'; do
        shown="${r//[[:cntrl:]]/?}"
        gu_run 'GSG_GITUP_ROOT="$1"; gitup_paths; rc=$?; printf "rc=%s prefix=[%s]\n" "$rc" "${GITUP_PREFIX:-}"' "$r"
        assert_contains "$OUT" "rc=1 prefix=[]" "refused and no path variable set for [$shown]"
        assert_contains "$ERR" "GSG_GITUP_ROOT must be an absolute path without control characters, got [$shown]" "says why, control characters shown as ?"
        assert_eq "$(printf '%s' "$ERR" | LC_ALL=C tr -d '[:print:]' | wc -c | tr -d ' ')" 0 "no control character reaches the terminal for [$shown]"
    done
}

# ^ invariant gur_tree_with_name NAME gives GU_TREE a registry whose class other names the module NAME, no module file of NAME exists
gur_tree_with_name() {
    lc_begin && gu_tree_with_module probe other </dev/null || return 1
    # ^ why | as the sed delimiter, not /; a name with slashes is the case under test
    sed -i "s|^\\( *\\)other) REPLY=probe ;;\$|\\1other) REPLY=\"\$GUR_NAME\" ;;|" "$GU_TREE/lib/gitup/gitup.sh" || return 1
    grep -q 'other) REPLY="\$GUR_NAME" ;;' "$GU_TREE/lib/gitup/gitup.sh" || return 1
    rm -f -- "$GU_TREE/lib/gitup/gitup_probe.sh"
    set_env GUR_NAME="$1" GUR_MARK="$SANDBOX/sourced.marker"
    GU_RUN_ROOT="$GU_TREE"
}

test_a_registry_that_names_a_module_with_an_invalid_name_is_refused_and_nothing_is_sourced() {
    local n
    for n in '../x' 'Upper' '9lives' 'a-b' 'a.b' 'x y'; do
        gur_tree_with_name "$n" || return 1
        # ^ why a directory named gitup_.. holding x.sh, not a missing path; the path of ../x exists and only the name check keeps it unsourced
        mkdir -p -- "$GU_TREE/lib/gitup/gitup_.." || return 1
        printf 'printf sourced >"$GUR_MARK"\n' >"$GU_TREE/lib/gitup/gitup_../x.sh" || return 1
        printf 'printf sourced >"$GUR_MARK"\n' >"$GU_TREE/lib/gitup/gitup_$n.sh" 2>/dev/null || true
        gu_run 'gitup_check_registered_modules'
        assert_rc 1 "the registry names [$n]"
        assert_contains "$ERR" "the registry names the invalid git upgrade module [$n]" "says which name is invalid"
        assert_not_contains "$OUT" "(class other)" "no module is reported as checked for the class"
        assert_no_file "$SANDBOX/sourced.marker" "nothing was sourced for [$n]"
    done
}

test_a_registry_that_names_a_module_whose_file_is_missing_is_refused() {
    gur_tree_with_name ghost || return 1
    gu_run 'gitup_check_registered_modules'
    assert_rc 1 "the registry names a module that is not there"
    assert_contains "$ERR" "the registry names the git upgrade module ghost but $GU_TREE/lib/gitup/gitup_ghost.sh does not exist" "says which file is missing"
    assert_not_contains "$OUT" "(class other)" "no module is reported as checked"
    printf 'gitup_ghost_never() { :; }\n' >"$GU_TREE/lib/gitup/gitup_ghost.sh" || return 1
    gu_run 'gitup_check_registered_modules'
    assert_rc 1 "control: a file that exists is sourced and then fails the contract check instead"
    assert_not_contains "$ERR" "does not exist" "so the missing-file refusal is not what said no"
}

run_file_tests
