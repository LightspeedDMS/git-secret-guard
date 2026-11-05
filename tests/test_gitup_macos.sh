#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup.sh"
# shellcheck source=tests/gitup_macos.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup_macos.sh"

# ^ external the macOS module drives Homebrew; Windows has its own module and test file
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Homebrew flows"; fi
GU_PTY_BSD=1

test_a_mac_with_an_old_git_installs_the_homebrew_git_and_goes_on_when_the_flag_says_yes() {
    gm_setup 2.40.0 || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "install --upgrade-git on a Mac with an old git"
    assert_contains "$OUT" "installing git with Homebrew: brew install git" "the module announces the command"
    assert_contains "${OUT%%installing git with Homebrew*}" "route: brew install git" "the plan is printed before brew runs"
    assert_eq "$(gm_calls)" "install git" "brew install git ran, not an upgrade"
    assert_eq "$("$GM_PREFIX/bin/git" --version)" "git version 2.56.0" "the Homebrew git is in the prefix"
    assert_file "$LC_STATE/state" "install ran to the end"
    assert_not_contains "$(gu_log)" "sudo" "no sudo ran"
}

test_a_mac_with_an_old_git_installs_the_homebrew_git_when_the_user_answers_yes_at_the_prompt() {
    gm_setup 2.40.0 || return 1
    gsg_pty $'y\n' install
    assert_rc 0 "yes at the prompt"
    assert_contains "$OUT" "route: brew install git" "the plan names the route before the question"
    assert_eq "$(gm_calls)" "install git" "brew install git ran"
}

test_an_old_homebrew_git_is_upgraded_with_brew_upgrade_not_install() {
    local src
    gm_setup "" || return 1
    gm_brew_git 2.40.0 || return 1
    src="$(gm_git_script 2.56.0)" || return 1
    printf '%s' "$src" >"$SANDBOX/brew.upgrade_src" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "an old Homebrew git is upgraded"
    assert_contains "$OUT" "route: brew upgrade git" "the plan names the upgrade"
    assert_eq "$(gm_calls)" "upgrade git" "brew upgrade git ran and brew install git did not"
    assert_eq "$("$GM_PREFIX/bin/git" --version)" "git version 2.56.0" "git is the upgraded one"
}

test_a_new_homebrew_git_that_is_not_first_on_path_gets_the_exact_path_line_and_nothing_else() {
    local f
    gm_setup 2.40.0 || return 1
    gm_brew_git 2.56.0 || return 1
    set_env PATH="$SANDBOX/pathbin:$GM_PREFIX/bin:$TEST_BASE_PATH"
    gsg install --upgrade-git </dev/null
    assert_rc 1 "a new git that is not first on PATH"
    assert_contains "$ERR" "export PATH=\"$GM_PREFIX/bin:\$PATH\"" "the exact PATH line"
    assert_contains "$ERR" "no shell profile was edited" "says no profile is touched"
    for f in .zshrc .zprofile .zshenv .bashrc .bash_profile .profile; do assert_no_file "$LC_HOME/$f" "no $f written"; done
    gm_nothing_installed "path fix"
}

test_apple_git_that_qualifies_means_no_offer_and_no_brew_call_for_git() {
    gm_setup 2.54.0 || return 1
    gsg install </dev/null
    assert_rc 0 "install with a qualifying git first on PATH"
    assert_not_contains "$OUT$ERR" "git upgrade plan" "no offer"
    assert_not_contains "$OUT$ERR" "[y/N]" "no prompt"
    assert_eq "$(gm_calls)" "" "brew was not called at all"
}

test_take_over_system_git_on_a_mac_says_it_cannot_be_done_changes_nothing_and_install_continues() {
    gm_setup 2.54.0 || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "install continues"
    assert_contains "$OUT$ERR" "cannot be replaced on macOS" "says the system git cannot be replaced"
    assert_contains "$OUT$ERR" "/usr/bin/git" "names it"
    assert_file "$LC_STATE/state" "install finished"
    assert_eq "$(gm_calls)" "" "no brew call"
}

# shellcheck disable=SC2016
test_the_old_apple_git_is_explained_when_the_homebrew_git_is_in_use() {
    gm_setup "" || return 1
    gm_brew_git 2.56.0 || return 1
    gm_stub "$SANDBOX/root/usr/bin/git" 'if [ "$1" = --version ]; then echo "git version 2.39.5 (Apple Git-154)"; exit 0; fi
exit 1' || return 1
    set_env GSG_GITUP_ROOT="$SANDBOX/root" PATH="$GM_PREFIX/bin:$SANDBOX/pathbin:$SANDBOX/root/usr/bin:$TEST_BASE_PATH"
    gsg install </dev/null
    assert_rc 0 "install with the Homebrew git in use"
    assert_contains "$ERR" "$SANDBOX/root/usr/bin/git is git 2.39.5" "names the old git"
    assert_contains "$ERR" "GUI clients" "explains GUI clients"
    assert_contains "$ERR" "/usr/bin:/bin" "and tools starting with that PATH"
    assert_contains "$ERR" "not scanned" "and says they are not scanned"
}

test_a_refusal_after_the_offer_names_the_homebrew_install_of_git() {
    gm_setup 2.40.0 || return 1
    lc_brew_reset || return 1
    lc_brew_have bash coreutils jq || return 1
    printf 'util-linux' >"$SANDBOX/brew.failon" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "the later brew install of util-linux fails"
    assert_eq "$(gm_calls)" $'install git\ninstall util-linux' "git first, then the other formulae in their own call"
    assert_contains "$ERR" "Homebrew installed git at $GM_PREFIX/bin/git" "names what changed"
    assert_not_contains "$ERR" "install of git" "and does not call it an install twice"
    assert_not_contains "$ERR" "(upgraded)" "and has no upgrade marker"
    assert_not_contains "$ERR" "nothing was changed" "never claims nothing changed"
}

test_a_failing_brew_install_of_git_shows_brews_message_refuses_and_says_what_may_have_changed() {
    gm_setup 2.40.0 || return 1
    printf 'git' >"$SANDBOX/brew.failon" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "brew install git fails"
    assert_contains "$ERR" "Error: injected brew failure" "brew's own message"
    assert_contains "$ERR" "Homebrew may have installed part of git" "says Homebrew may have installed part of it"
    assert_contains "$ERR" "install refused" "install refuses"
    assert_eq "$(grep -o 'install refused' <<<"$ERR" | wc -l | tr -d ' ')" 1 "and only the core says so, once"
    assert_not_contains "$ERR" "nothing was changed" "and does not claim nothing changed"
    assert_no_file "$LC_STATE" "no state"
}

test_a_failing_brew_upgrade_of_git_shows_brews_message_and_says_what_may_have_changed() {
    gm_setup "" || return 1
    gm_brew_git 2.40.0 || return 1
    printf 'upgrade' >"$SANDBOX/brew.failon" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "brew upgrade git fails"
    assert_contains "$ERR" "Error: injected brew failure" "brew's own message"
    assert_contains "$ERR" "brew upgrade git failed" "names the command"
    assert_contains "$ERR" "Homebrew may have installed part of" "says what brew may have done"
    assert_eq "$(grep -o 'install refused' <<<"$ERR" | wc -l | tr -d ' ')" 1 "only the core refuses, once"
    assert_not_contains "$ERR" "nothing was changed" "no claim that nothing changed"
}

test_the_weekly_agent_gets_the_homebrew_git_directory_first_after_the_upgrade() {
    local plist
    gm_setup 2.40.0 || return 1
    gsg install --upgrade-git --with-timer </dev/null
    assert_rc 0 "install --upgrade-git --with-timer"
    plist="$LC_HOME/Library/LaunchAgents/com.lightspeeddms.git-secret-guard.doctor.plist"
    assert_file "$plist" "the agent plist is written"
    assert_contains "$(<"$plist")" "<string>$GM_PREFIX/bin:" "the PATH starts with the Homebrew git's directory"
}

test_an_old_git_without_a_terminal_and_without_the_flag_refuses_names_the_flag_and_installs_nothing() {
    gm_setup 2.40.0 || return 1
    gsg install </dev/null
    assert_rc 1 "no terminal, no flag"
    assert_contains "$ERR" "install --upgrade-git" "names the flag"
    assert_contains "$ERR" "nothing was changed" "says nothing changed"
    gm_nothing_installed "non-interactive"
}

test_the_hint_for_an_old_git_on_macos_names_upgrade_git_and_homebrew() {
    gm_setup 2.40.0 || return 1
    gsg install </dev/null
    assert_contains "$ERR" "install --upgrade-git; it installs or upgrades git with Homebrew" "the macOS hint"
}

test_brew_is_never_run_as_root() {
    gm_setup 2.40.0 || return 1
    gm_pretend_root || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "root"
    assert_contains "$ERR" "never as root" "says brew is not run as root"
    assert_eq "$(gm_calls)" "" "no brew call"
}

# shellcheck disable=SC2016
test_the_plan_without_brew_returns_the_brew_refusal() {
    gm_setup 2.40.0 && lc_path_without brew || return 1
    gu_run 'source "$GSG_ROOT/lib/gitup_macos.sh" && gitup_macos_plan upgrade'
    assert_rc 1 "no brew"
    assert_contains "$ERR" "Homebrew (brew) was not found on PATH" "the brew.sh refusal"
    assert_contains "$ERR" "https://brew.sh" "and where to get it"
}

# shellcheck disable=SC2016
test_the_refresh_plan_has_nothing_to_offer_because_homebrew_only_has_the_latest() {
    gm_setup 2.56.0 || return 1
    gu_run 'source "$GSG_ROOT/lib/gitup_macos.sh" && gitup_macos_plan refresh'
    assert_rc 1 "nothing stale"
    assert_empty "$OUT$ERR" "and nothing printed"
}

test_a_mac_without_developer_tools_never_runs_the_git_shim_and_still_shows_the_offer() {
    gm_setup "" || return 1
    lc_path_without git || return 1
    gm_stub "$SANDBOX/root/usr/bin/git" "echo ran >>\"$SANDBOX/shim.log\"
sleep $GM_SHIM_SLEEP_SECONDS
exit 1" || return 1
    gm_stub "$SANDBOX/root/usr/bin/xcode-select" 'echo "xcode-select: error: unable to get active developer directory" >&2
exit 2' || return 1
    rm -f -- "$SANDBOX/shim.log" || return 1
    set_env GSG_GITUP_ROOT="$SANDBOX/root" PATH="$SANDBOX/root/usr/bin:$GM_PREFIX/bin:$SANDBOX/pathfarm-git"
    SECONDS=0
    gsg install </dev/null
    assert_rc 1 "no consent"
    [ "$SECONDS" -lt "$GM_MAX_INSTALL_SECONDS" ] || fail "install took $SECONDS seconds, it waited for the shim"
    assert_no_file "$SANDBOX/shim.log" "the shim that opens the install dialog never ran"
    assert_contains "$OUT$ERR" "git upgrade plan" "the offer still appears"
    assert_contains "$OUT$ERR" "install --upgrade-git" "and names the flag"
}

# shellcheck disable=SC2016
test_a_declined_offer_after_the_bash_bootstrap_names_the_brew_install_of_bash() {
    gm_setup 2.40.0 || return 1
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$TEST_BASH" -c 'export GSG_BREW_BOOTSTRAPPED="$$:bash"; exec "$0" "$@"' \
        "$GSG_PROJECT/bin/git-secret-guard" install </dev/null
    assert_rc 1 "no terminal, no flag, after the bootstrap installed bash"
    assert_contains "$ERR" "the only change made was the Homebrew install of bash" "the refusal names the bash install"
    assert_contains "$ERR" "install --upgrade-git" "and still names the flag"
    assert_not_contains "$ERR" "nothing was changed" "no false claim"
    assert_eq "$(gm_calls)" "" "no brew call in this process"
}

# shellcheck disable=SC2016
test_the_apple_git_sentence_is_not_printed_for_an_old_git_elsewhere_and_only_once_for_usr_bin() {
    gm_setup "" || return 1
    gm_brew_git 2.56.0 || return 1
    gm_stub "$SANDBOX/oldbin/git" 'if [ "$1" = --version ]; then echo "git version 2.30.0"; exit 0; fi
exit 1' || return 1
    set_env GSG_GITUP_ROOT="$SANDBOX/root" PATH="$GM_PREFIX/bin:$SANDBOX/pathbin:$SANDBOX/oldbin:$TEST_BASE_PATH"
    gsg install </dev/null
    assert_rc 0 "install with an old git in a user directory"
    assert_contains "$ERR" "$SANDBOX/oldbin/git is git 2.30.0" "the old git is named"
    assert_not_contains "$ERR" "GUI clients" "no Apple Git sentence for a git that is not /usr/bin/git"
    gm_stub "$SANDBOX/root/usr/bin/git" 'if [ "$1" = --version ]; then echo "git version 2.39.5 (Apple Git-154)"; exit 0; fi
exit 1' || return 1
    set_env PATH="$GM_PREFIX/bin:$SANDBOX/pathbin:$SANDBOX/oldbin:$SANDBOX/root/usr/bin:$TEST_BASE_PATH"
    gsg install </dev/null
    assert_rc 0 "install with the old Apple Git as well"
    assert_eq "$(grep -c 'GUI clients' <<<"$ERR")" 1 "the sentence is printed once"
}

# ^ external a dead proxy makes trufflehog's verification fail => result "unknown" (online, a fake credential is "unverified" and hidden)
test_after_the_accepted_install_a_commit_with_a_fake_key_is_blocked() {
    local token
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    [ -x "$REAL_BETTERLEAKS" ] || skip_test "betterleaks not found at $REAL_BETTERLEAKS"
    gm_setup 2.40.0 && lc_seed_real_tools || return 1
    set_env HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9
    gsg install --upgrade-git </dev/null
    assert_rc 0 "install with the real scanners after the offer"
    new_repo leak || return 1
    token="$(fake_github_token)"
    stage_file src/leak.txt one "token = \"$token\"" || return 1
    commit_cap "leak"
    assert_rc 1 "the commit is blocked"
    assert_contains "$ERR" "trufflehog" "trufflehog reported"
    assert_contains "$ERR" "betterleaks" "betterleaks reported"
    assert_contains "$ERR" "src/leak.txt:2" "real file and line"
    no_leak "$token"
    assert_eq "$(gitx rev-parse -q --verify HEAD 2>/dev/null | wc -l | tr -d ' ')" 0 "no commit was created"
}

run_file_tests
