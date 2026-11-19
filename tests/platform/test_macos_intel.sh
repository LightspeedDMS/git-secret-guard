#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/gitup.sh"
# shellcheck source=tests/support/gitup_macos.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/gitup_macos.sh"

# ^ external the Intel Mac paths; a fake uname answers Darwin x86_64 or arm64 and brew is the recording stand-in, no real brew runs
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Homebrew flows"; fi

INTEL_BREW_REFUSAL="Homebrew (brew) was not found on PATH; install it from https://brew.sh (and open a new terminal so brew is on PATH), then run install again; on an Intel Mac Homebrew's installer may refuse to run: see \"Homebrew on an Intel Mac\" in docs/platforms.md for the manual steps; nothing was changed"
ARM_BREW_REFUSAL="Homebrew (brew) was not found on PATH; install it from https://brew.sh (and open a new terminal so brew is on PATH), then run install again; nothing was changed"

test_an_intel_mac_without_homebrew_is_pointed_to_the_manual_steps() {
    lc_begin && as_macos && lc_fake_uname Darwin x86_64 && lc_path_without brew || return 1
    gsg install </dev/null
    assert_rc 1 "no brew on an Intel Mac"
    assert_contains "$ERR" "git-secret-guard: $INTEL_BREW_REFUSAL" "the Intel refusal, ending in the unchanged claim"
    gm_nothing_installed "intel, no brew"
}

test_an_intel_mac_without_homebrew_gets_the_same_pointer_with_the_upgrade_flag() {
    lc_begin && as_macos && lc_fake_uname Darwin x86_64 && lc_path_without brew || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "no brew on an Intel Mac, with the flag"
    assert_contains "$ERR" "git-secret-guard: $INTEL_BREW_REFUSAL" "the Intel refusal, ending in the unchanged claim"
    gm_nothing_installed "intel, no brew, flag"
}

test_an_arm64_mac_without_homebrew_keeps_the_refusal_text_unchanged() {
    lc_begin && as_macos && lc_fake_uname Darwin arm64 && lc_path_without brew || return 1
    gsg install </dev/null
    assert_rc 1 "no brew on an arm64 Mac"
    assert_contains "$ERR" "git-secret-guard: $ARM_BREW_REFUSAL" "the text of before, byte for byte"
    assert_not_contains "$ERR" "Intel" "no Intel pointer"
    gm_nothing_installed "arm64, no brew"
}

INTEL_BUILD_NOTICE="git-secret-guard: on an Intel Mac Homebrew may build these formulae from source (no bottles); this can take an hour or more"
# ^ invariant a cap for the scan of intel_notices, far above any count a run can print
INTEL_NOTICE_SCAN_MAX=20

# ^ invariant intel_notices prints how many times the build notice appears in the output of the last run
intel_notices() {
    local rest="$OUT$ERR" n=0
    while [[ $rest == *"$INTEL_BUILD_NOTICE"* ]] && [ "$n" -lt "$INTEL_NOTICE_SCAN_MAX" ]; do
        rest="${rest#*"$INTEL_BUILD_NOTICE"}"
        n=$((n + 1))
    done
    printf '%s' "$n"
}

# ^ invariant prereq_install_on ARCH runs install with every Homebrew formula missing on a fake Mac of this CPU and checks the one brew install
prereq_install_on() {
    lc_begin && as_macos && lc_fake_uname Darwin "$1" && lc_brew_reset && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install </dev/null
    assert_rc 0 "install with missing prerequisites on $1"
    assert_eq "$(grep -v '^--prefix' "$SANDBOX/brew.log")" "install bash coreutils util-linux" "one brew install on $1"
}

test_an_intel_mac_is_told_once_before_the_prerequisite_install_that_brew_may_build_from_source() {
    prereq_install_on x86_64 || return 1
    assert_contains "$OUT" "$INTEL_BUILD_NOTICE" "the notice is on stdout, with brew's announcement"
    assert_eq "$(intel_notices)" 1 "the notice is printed once"
    assert_contains "${OUT%%"$INTEL_BUILD_NOTICE"*}" "brew install bash coreutils util-linux" "after the announcement of the install, before the build"
}

test_an_arm64_mac_gets_no_build_notice_for_the_prerequisite_install() {
    prereq_install_on arm64 || return 1
    assert_eq "$(intel_notices)" 0 "no notice"
    assert_not_contains "$OUT$ERR" "build these formulae from source" "no trace of it"
}

# ^ invariant bootstrap_on ARCH runs brew_cli_bootstrap as a CLI started by a bash older than 4.4 with no Homebrew bash; the check is redefined
# ^ invariant the re-exec target is a one-line script; only the bootstrap's own brew install bash runs, real bash 3.2 is the macOS-only test
# shellcheck disable=SC2016
bootstrap_on() {
    lc_begin && as_macos && lc_fake_uname Darwin "$1" && lc_brew_reset && lc_make_fixtures && lc_use_fixtures || return 1
    printf 'echo reexeced\n' >"$SANDBOX/self.sh" || return 1
    gu_run 'brew_running_bash_ok() { return 1; }; brew_cli_bootstrap "$1" install' "$SANDBOX/self.sh"
    assert_rc 0 "the bootstrap on $1"
    assert_contains "$OUT" reexeced "the CLI was started again under the Homebrew bash"
    assert_eq "$(grep -v '^--prefix' "$SANDBOX/brew.log")" "install bash" "the bootstrap installed bash and nothing else on $1"
}

test_an_intel_mac_is_told_once_before_the_bootstraps_brew_install_of_bash() {
    bootstrap_on x86_64 || return 1
    assert_eq "$(intel_notices)" 1 "the notice is printed once"
    assert_contains "${OUT%%"$INTEL_BUILD_NOTICE"*}" "brew install bash" "after the announcement of the install"
}

test_an_arm64_mac_gets_no_build_notice_for_the_bootstrap() {
    bootstrap_on arm64 || return 1
    assert_eq "$(intel_notices)" 0 "no notice"
}

# ^ invariant gm_setup_on ARCH [OLD] is gm_setup for a fake Mac of this CPU; the scanner fixtures are rebuilt for its platform row
gm_setup_on() {
    gm_setup "${2:-}" && lc_fake_uname Darwin "$1" && lc_make_fixtures && lc_use_fixtures
}

test_an_intel_mac_is_told_once_before_the_brew_install_of_git() {
    gm_setup_on x86_64 2.40.0 || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the git upgrade on an Intel Mac"
    assert_eq "$(gm_calls)" "install git" "brew install git ran"
    assert_eq "$(intel_notices)" 1 "the notice is printed once"
    assert_contains "${OUT%%"$INTEL_BUILD_NOTICE"*}" "installing git with Homebrew: brew install git" "after the announcement of the command"
}

test_an_intel_mac_is_told_once_before_the_brew_upgrade_of_git_because_it_builds_from_source_too() {
    local src
    gm_setup_on x86_64 && gm_brew_git 2.40.0 || return 1
    src="$(gm_git_script 2.56.0)" || return 1
    printf '%s' "$src" >"$SANDBOX/brew.upgrade_src" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the git upgrade of a Homebrew git on an Intel Mac"
    assert_eq "$(gm_calls)" "upgrade git" "brew upgrade git ran"
    assert_eq "$(intel_notices)" 1 "the notice is printed once"
}

test_an_arm64_mac_gets_no_build_notice_for_the_brew_install_of_git() {
    gm_setup_on arm64 2.40.0 || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the git upgrade on an arm64 Mac"
    assert_eq "$(gm_calls)" "install git" "brew install git ran"
    assert_eq "$(intel_notices)" 0 "no notice"
}

run_file_tests
