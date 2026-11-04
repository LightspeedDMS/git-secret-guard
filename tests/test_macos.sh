#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

CONFIG_BEFORE=""
snapshot_config() { CONFIG_BEFORE="$(gitx config --global --list)"; }

nothing_changed() {
    assert_no_file "$LC_STATE" "$1: no state dir"
    assert_no_file "$LC_DATA" "$1: no share dir"
    assert_no_file "$LC_BIN" "$1: no bin dir"
    assert_eq "$(gitx config --global --list)" "$CONFIG_BEFORE" "$1: global git config unchanged"
}

test_install_without_homebrew_on_macos_refuses_before_any_change() {
    lc_begin && as_macos && lc_path_without brew || return 1
    snapshot_config
    gsg install
    assert_rc 1 "no brew"
    assert_contains "$ERR" "Homebrew (brew) was not found on PATH" "says what is missing"
    assert_contains "$ERR" "https://brew.sh" "says how to install it"
    assert_contains "$ERR" "nothing was changed" "says nothing changed"
    nothing_changed "no brew"
}

brew_prefix() { (cd -- "$SANDBOX" && pwd -P) | sed 's|$|/brewprefix|'; }
setting_of() { sed -n "s/^$1=//p" "$LC_DATA/settings"; }
brew_calls() { grep -v '^--prefix' "$SANDBOX/brew.log" 2>/dev/null; }

test_install_runs_brew_install_for_exactly_the_missing_prerequisites() {
    local prefix jq
    lc_begin && as_macos && lc_brew_reset && lc_make_fixtures && lc_use_fixtures || return 1
    prefix="$(brew_prefix)"
    jq="$(env -i PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" bash -c 'type -P jq' </dev/null)" || {
        printf 'test setup: jq is not on the test PATH\n' >&2
        return 1
    }
    gsg install
    assert_rc 0 "install with missing brew prerequisites"
    assert_eq "$(brew_calls)" "install bash coreutils util-linux" "one brew install for exactly the missing formulae"
    assert_contains "$OUT$ERR" "brew install bash coreutils util-linux" "the list is printed before brew runs"
    assert_eq "$(setting_of BASH_BIN)" "$prefix/bin/bash" "bash recorded"
    assert_eq "$(setting_of GNUBIN_DIR)" "$prefix/opt/coreutils/libexec/gnubin" "the GNU coreutils directory recorded"
    assert_eq "$(setting_of TIMEOUT_BIN)" "$prefix/opt/coreutils/libexec/gnubin/timeout" "timeout recorded"
    assert_eq "$(setting_of SETSID_BIN)" "$prefix/opt/util-linux/bin/setsid" "setsid from the keg recorded"
    assert_eq "$(setting_of JQ_BIN)" "$jq" "jq found on PATH is recorded, brew does not install it"
}

test_nothing_missing_runs_no_brew_install() {
    lc_begin && as_macos && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install with every prerequisite present"
    assert_eq "$(brew_calls)" "" "no brew install"
    assert_not_contains "$OUT$ERR" "brew install" "nothing is announced"
    assert_eq "$(setting_of BASH_BIN)" "$(brew_prefix)/bin/bash" "bash still recorded"
}

test_only_the_missing_formula_is_installed() {
    lc_begin && as_macos && lc_brew_reset && lc_brew_have bash coreutils jq && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install with util-linux missing"
    assert_eq "$(brew_calls)" "install util-linux" "only util-linux"
    assert_eq "$(setting_of SETSID_BIN)" "$(brew_prefix)/opt/util-linux/bin/setsid" "setsid from the keg"
}

test_a_failing_brew_install_refuses_and_changes_nothing_else() {
    lc_begin && as_macos && lc_brew_reset && lc_make_fixtures && lc_use_fixtures || return 1
    : >"$SANDBOX/brew.fail"
    snapshot_config
    gsg install
    assert_rc 1 "brew fails"
    assert_contains "$ERR" "Error: injected brew failure" "brew's own message reaches the user"
    assert_contains "$ERR" "brew install bash coreutils util-linux failed" "says which command failed"
    assert_contains "$ERR" "Homebrew may have installed part of bash coreutils util-linux" "says what brew may have done"
    assert_not_contains "$ERR" "nothing else was changed" "no claim that nothing changed"
    nothing_changed "brew failed"
}

test_a_brew_that_installs_nothing_is_refused_by_path() {
    lc_begin && as_macos && lc_brew_reset && lc_make_fixtures && lc_use_fixtures || return 1
    : >"$SANDBOX/brew.nopopulate"
    snapshot_config
    gsg install
    assert_rc 1 "brew installs nothing"
    assert_contains "$ERR" "still missing: bash coreutils util-linux" "names what is still missing"
    assert_contains "$ERR" "$(brew_prefix)/bin/bash" "names where it looked"
    nothing_changed "brew installed nothing"
}

# shellcheck disable=SC2016
test_load_settings_discards_inherited_bash_and_gnubin() {
    printf 'JQ_BIN=/x\n' >"$SANDBOX/s" || return 1
    run_cap env -i BASH_BIN=/inherited GNUBIN_DIR=/inherited bash -c \
        'source "$1/lib/common.sh" && load_settings "$2" && printf "[%s][%s]" "${BASH_BIN:-}" "${GNUBIN_DIR:-}"' _ "$GSG_PROJECT" "$SANDBOX/s"
    assert_eq "$OUT" "[][]" "an inherited BASH_BIN or GNUBIN_DIR is dropped before the settings are read"
}

test_an_old_git_refuses_before_brew_installs_anything() {
    lc_begin && as_macos && lc_brew_reset && lc_fake_git 2.52.0 && lc_make_fixtures && lc_use_fixtures || return 1
    snapshot_config
    gsg install
    assert_rc 1 "old git"
    assert_contains "$ERR" "git 2.52.0" "names the git problem"
    assert_eq "$(brew_calls)" "" "brew install is not run for a machine install will refuse anyway"
    nothing_changed "old git"
}

test_with_timer_on_macos_installs_the_launch_agent_after_the_one_brew_install() {
    lc_begin && as_macos && lc_brew_reset && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install --with-timer
    assert_rc 0 "--with-timer on macOS with every Homebrew prerequisite missing"
    assert_eq "$(brew_calls)" "install bash coreutils util-linux" "one brew install for exactly the missing formulae"
    assert_file "$LC_HOME/Library/LaunchAgents/com.lightspeeddms.git-secret-guard.doctor.plist" "the LaunchAgent plist is written"
    assert_contains "$(<"$LC_DATA/settings")" "LAUNCHCTL_BIN=$SANDBOX/pathbin/launchctl" "launchctl is recorded"
}

test_linux_install_never_calls_brew_and_writes_no_macos_settings() {
    lc_begin && lc_fake_uname Linux x86_64 && lc_brew_reset && lc_make_fixtures && lc_use_fixtures || return 1
    set_env PATH="$SANDBOX/pathbin:$TEST_BASE_PATH:${TEST_SETSID%/*}"
    gsg install
    assert_rc 0 "a Linux install"
    assert_no_file "$SANDBOX/brew.log" "brew is never called on Linux"
    assert_eq "$(setting_of BASH_BIN)" "" "no BASH_BIN line on Linux"
    assert_eq "$(setting_of GNUBIN_DIR)" "" "no GNUBIN_DIR line on Linux"
}

test_the_hook_command_names_the_recorded_bash_and_status_accepts_it() {
    lc_begin && as_macos && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install"
    assert_eq "$(gitx config --global --get hook.git-secret-guard.command)" "'$(brew_prefix)/bin/bash' '$LC_DATA/hooks/secret-scan'" \
        "the command starts the hook under the recorded bash"
    gsg status
    assert_rc 0 "status"
    assert_contains "$OUT" "global config: matches" "status accepts the macOS command form"
}

# shellcheck disable=SC2016
test_the_cli_puts_the_recorded_gnu_directory_first_on_PATH() {
    local bash_bin="${TEST_BASH:-$BASH}" gnubin
    lc_begin && as_macos && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install"
    gnubin="$(brew_prefix)/opt/coreutils/libexec/gnubin"
    run_cap env -i PATH="$SANDBOX/pathbin:/usr/bin:/bin" "$bash_bin" -c \
        'source "$1/lib/common.sh" && source "$1/lib/brew.sh" && GSG_ROOT="$2" && brew_use_gnubin && printf "%s" "$PATH"' _ "$GSG_PROJECT" "$LC_DATA"
    assert_rc 0 "an installed copy"
    assert_eq "${OUT%%:*}" "$gnubin" "the GNU directory recorded in the share's settings comes first"
    run_cap env -i PATH="$SANDBOX/pathbin:/usr/bin:/bin" "$bash_bin" -c \
        'source "$1/lib/common.sh" && source "$1/lib/brew.sh" && GSG_ROOT="$1" && brew_use_gnubin && printf "%s" "$PATH"' _ "$GSG_PROJECT"
    assert_rc 0 "a checkout without settings"
    assert_eq "${OUT%%:*}" "$gnubin" "brew's own gnubin comes first when nothing is installed yet"
}

test_doctor_accepts_the_macos_command_form_and_checks_the_recorded_bash() {
    local roots="$SANDBOX/roots"
    lc_begin && as_macos && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install"
    mkdir -p -- "$roots" && gitx init -q "$roots/r" && gitx -C "$roots/r" commit -q --allow-empty --no-verify -m init || return 1
    gsg doctor --roots "$roots"
    assert_rc 0 "a healthy macOS machine"
    assert_not_contains "$OUT" "PROBLEM" "nothing wrong"
    assert_contains "$OUT" "  ok       bash: $(brew_prefix)/bin/bash" "the recorded bash is checked"
    assert_contains "$OUT" "command='$(brew_prefix)/bin/bash' '$LC_DATA/hooks/secret-scan' (executable)" "the command form install wrote is the wanted one"
    sed -i "s#^BASH_BIN=.*#BASH_BIN=/nonexistent/bash#" "$LC_DATA/settings" || return 1
    gsg doctor --roots "$roots"
    assert_rc 1 "a recorded bash that does not exist"
    assert_contains "$OUT" "PROBLEM  bash: " "names bash"
}

test_a_command_that_needs_the_gnu_tools_refuses_when_their_directory_is_missing() {
    local gnubin
    lc_begin && as_macos && lc_make_fixtures && lc_use_fixtures || return 1
    gnubin="$(brew_prefix)/opt/coreutils/libexec/gnubin"
    gsg install
    assert_rc 0 "install"
    if [ ! -d "$gnubin" ] || [ -L "$gnubin" ]; then
        fail "test setup: $gnubin is not a plain directory"
        return 1
    fi
    rm -rf -- "$gnubin" || return 1
    gsg status
    assert_rc 1 "status of an installed copy whose GNU directory is gone"
    assert_contains "$ERR" "$gnubin" "names the missing directory"
    assert_contains "$ERR" "brew install coreutils" "names the formula"
    lc_begin && as_macos && lc_brew_reset && lc_make_fixtures && lc_use_fixtures || return 1
    gsg status
    assert_rc 1 "status of a checkout without the GNU directory"
    assert_contains "$ERR" "$gnubin" "names the directory brew would use"
    assert_contains "$ERR" "brew install coreutils" "names the formula"
    gsg version
    assert_rc 0 "version needs no GNU tool"
    gsg help
    assert_rc 0 "help needs no GNU tool"
    gsg install
    assert_rc 0 "install is not refused for the missing directory, it installs coreutils"
}

MIN_BASH_MAJOR=4 MIN_BASH_MINOR=4
NO_OLD_BASH="/bin/bash is $MIN_BASH_MAJOR.$MIN_BASH_MINOR or newer on this host"

# ^ external macOS /bin/bash is 3.2; a host whose /bin/bash is new enough has no old bash to start the CLI with
old_system_bash() {
    [ -x /bin/bash ] && /bin/bash -c "[ \"\${BASH_VERSINFO[0]}\" -lt $MIN_BASH_MAJOR ] || { [ \"\${BASH_VERSINFO[0]}\" -eq $MIN_BASH_MAJOR ] && [ \"\${BASH_VERSINFO[1]}\" -lt $MIN_BASH_MINOR ]; }"
}
oldgsg() { run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" /bin/bash "$GSG_PROJECT/bin/git-secret-guard" "$@"; }

test_the_cli_started_by_the_system_bash_runs_again_under_the_homebrew_bash() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    lc_begin && as_macos || return 1
    oldgsg version
    assert_rc 0 "version under bash 3.2"
    assert_eq "$OUT" "git-secret-guard $(<"$GSG_PROJECT/VERSION")" "the CLI answered"
    assert_contains "$(<"$SANDBOX/brew.log")" "--prefix" "the bootstrap asked Homebrew where its bash is"
    assert_eq "$(brew_calls)" "" "nothing was installed"
}

test_the_cli_started_by_the_system_bash_installs_the_missing_formulae_through_brew() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    lc_begin && as_macos && lc_brew_reset && lc_make_fixtures && lc_use_fixtures || return 1
    oldgsg install
    assert_rc 0 "install under bash 3.2 with every Homebrew prerequisite missing"
    assert_eq "$(brew_calls)" "install bash
install coreutils util-linux" "bash alone in the bootstrap, then one install of the rest"
    assert_eq "$(setting_of BASH_BIN)" "$(brew_prefix)/bin/bash" "the Homebrew bash is recorded"
}

test_the_cli_started_by_the_system_bash_refuses_without_homebrew_and_changes_nothing() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    lc_begin && as_macos && lc_path_without brew || return 1
    snapshot_config
    oldgsg install
    assert_rc 1 "no brew under bash 3.2"
    assert_contains "$ERR" "Homebrew (brew) was not found on PATH" "says what is missing"
    assert_contains "$ERR" "https://brew.sh" "says how to install it"
    nothing_changed "no brew under bash 3.2"
}

test_the_cli_started_by_the_system_bash_without_a_homebrew_bash_says_so_for_other_commands() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    lc_begin && as_macos && lc_brew_reset || return 1
    oldgsg status
    assert_rc 1 "status under bash 3.2 without a Homebrew bash"
    assert_contains "$ERR" "bash $MIN_BASH_MAJOR.$MIN_BASH_MINOR" "names the bash it needs"
    assert_contains "$ERR" "brew install bash" "says how to get it"
    assert_eq "$(brew_calls)" "" "only install may run brew install"
}

# ^ external bug #10 starts with a GUI-like PATH without brew; the installed copy knows its bash from its own settings file
# ^ invariant $@ = settings lines written as given; the share copy is laid out like an install (bin, lib, hooks, VERSION, tools.lock, settings)
installed_copy() {
    local share="$SANDBOX/instshare"
    rm -rf -- "$share" && mkdir -p -- "$share/bin" || return 1
    cp -R -- "$GSG_PROJECT/lib" "$GSG_PROJECT/hooks" "$GSG_PROJECT/VERSION" "$GSG_PROJECT/tools.lock" "$share/" || return 1
    cp -- "$GSG_PROJECT/bin/git-secret-guard" "$share/bin/" || return 1
    { printf 'GNUBIN_DIR=%q\n' "$TEST_GNUBIN"; if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; fi; } >"$share/settings"
}
baregsg() { run_cap env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin /bin/bash "$SANDBOX/instshare/bin/git-secret-guard" "$@"; }

REEXEC_TEST_TIMEOUT_SECONDS=20

assert_command_fitting_refusal() {
    assert_rc 1 "$1: refused"
    assert_contains "$ERR" "needs bash $MIN_BASH_MAJOR.$MIN_BASH_MINOR or newer" "$1: says what is missing"
    assert_contains "$ERR" "brew install bash" "$1: says how to fix it"
    assert_not_contains "$ERR" "run install again" "$1: no install wording"
    assert_not_contains "$ERR" "nothing was changed" "$1: no install claim"
}

test_the_installed_cli_under_the_system_bash_reexecs_under_the_recorded_bash() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    lc_begin || return 1
    installed_copy "BASH_BIN=$(printf '%q' "$TEST_BASH")" || return 1
    baregsg version
    assert_rc 0 "version under bash 3.2 without brew on PATH"
    assert_eq "$OUT" "git-secret-guard $(<"$GSG_PROJECT/VERSION")" "the CLI answered"
}

test_an_unusable_recorded_bash_is_refused_with_text_that_fits_the_command() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    lc_begin || return 1
    local label line
    for label in missing relative old-bash empty; do
        case "$label" in
            missing) line="BASH_BIN=/nonexistent/bin/bash" ;;
            relative) line="BASH_BIN=bash" ;;
            old-bash) line="BASH_BIN=/bin/bash" ;;
            empty) line="BASH_BIN=" ;;
        esac
        installed_copy "$line" || return 1
        baregsg status
        assert_command_fitting_refusal "$label"
        assert_contains "$ERR" "BASH_BIN recorded in $SANDBOX/instshare/settings" "$label: names the recorded setting"
    done
}

test_a_recorded_bash_that_needs_shell_quoting_or_expansion_is_ignored_as_data_and_never_run() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    lc_begin || return 1
    local pwned="$SANDBOX/pwned" line
    for line in "BASH_BIN=/tmp/a\\ b/bash" "BASH_BIN='$TEST_BASH'" "BASH_BIN=\$(touch $pwned)" "BASH_BIN=\$'$TEST_BASH'" "BASH_BIN=/tmp/x;touch $pwned"; do
        installed_copy "$line" || return 1
        baregsg version
        assert_command_fitting_refusal "[$line]"
        assert_not_contains "$ERR" "$pwned" "the odd value is never echoed"
    done
    assert_no_file "$pwned" "the settings file was read as data, never executed under bash 3.2"
}

test_settings_without_a_recorded_bash_refuse_with_text_that_fits_the_command() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    lc_begin || return 1
    installed_copy || return 1
    baregsg doctor
    assert_command_fitting_refusal "no BASH_BIN"
    assert_not_contains "$ERR" "recorded in" "nothing was recorded, so nothing is blamed"
}

test_a_recorded_bash_that_is_really_bash_3_2_is_refused_after_one_exec_not_looped() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    lc_begin || return 1
    local fake="$SANDBOX/fakebash"
    # shellcheck disable=SC2016
    printf '%s\n' '#!/bin/bash' 'if [ "${1:-}" = -c ]; then printf 4.4; exit 0; fi' 'exec /bin/bash "$@"' >"$fake" && chmod 755 "$fake" || return 1
    assert_fake_bash_is_refused "$fake"
}

# ^ invariant arg 1 is a recorded bash claiming 4.4 without being it; the CLI must refuse inside the timeout, 124 means it looped
assert_fake_bash_is_refused() {
    installed_copy "BASH_BIN=$1" || return 1
    run_cap env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin "$TEST_TIMEOUT" "$REEXEC_TEST_TIMEOUT_SECONDS" /bin/bash "$SANDBOX/instshare/bin/git-secret-guard" version
    assert_rc 1 "refused, not killed by the timeout (124)"
    assert_contains "$ERR" "still" "says the bash it got is still too old"
    assert_contains "$ERR" "brew install bash" "says how to fix it"
}

test_a_recorded_bash_wrapper_that_runs_bash_as_a_child_is_refused_by_the_depth_bound_not_looped() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    lc_begin || return 1
    local fake="$SANDBOX/childbash"
    # shellcheck disable=SC2016
    printf '%s\n' '#!/bin/bash' 'if [ "${1:-}" = -c ]; then printf 4.4; exit 0; fi' '/bin/bash "$@"' 'exit $?' >"$fake" && chmod 755 "$fake" || return 1
    assert_fake_bash_is_refused "$fake"
}

test_install_with_timer_under_the_system_bash_bootstraps_like_a_plain_install() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    lc_begin && as_macos && lc_brew_reset && lc_make_fixtures && lc_use_fixtures || return 1
    oldgsg install --with-timer
    assert_rc 0 "--with-timer under bash 3.2 with every Homebrew prerequisite missing"
    assert_eq "$(brew_calls)" "install bash
install coreutils util-linux" "bash alone in the bootstrap, then one install of the rest"
    assert_file "$LC_HOME/Library/LaunchAgents/com.lightspeeddms.git-secret-guard.doctor.plist" "the LaunchAgent plist is written"
}

BOOTSTRAP_NOTE="the only change made was the Homebrew install of bash"

# ^ invariant a macOS sandbox with an empty Homebrew prefix and the fixtures; option hooks sets a core.hooksPath, git=VERSION a fake git; sets CONFIG_BEFORE
brew_less_fixture() {
    local opt
    lc_begin && as_macos && lc_brew_reset || return 1
    for opt in "$@"; do
        case "$opt" in
            hooks) mkdir -p -- "$SANDBOX/hooks-dir" && gitx config --global core.hooksPath "$SANDBOX/hooks-dir" || return 1 ;;
            git=*) lc_fake_git "${opt#git=}" || return 1 ;;
            *) return 1 ;;
        esac
    done
    lc_make_fixtures && lc_use_fixtures || return 1
    snapshot_config
}

# ^ invariant after a brew install no message claims an unchanged machine and only Homebrew changed; no state dir, same global config
assert_only_brew_changed() {
    assert_not_contains "$ERR" "nothing was changed" "$1: no claim that nothing changed"
    assert_not_contains "$ERR" "nothing else was changed" "$1: no claim that nothing else changed"
    assert_no_file "$LC_STATE" "$1: no state dir"
    assert_eq "$(gitx config --global --list)" "$CONFIG_BEFORE" "$1: global git config unchanged"
}

test_the_system_bash_bootstrap_installs_only_bash_and_the_refusal_says_so() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    brew_less_fixture git=2.52.0 || return 1
    oldgsg install
    assert_rc 1 "old git under bash 3.2"
    assert_eq "$(brew_calls)" "install bash" "the bootstrap installs bash and nothing else"
    assert_contains "$ERR" "git 2.52.0" "the git refusal is still printed"
    assert_contains "$OUT$ERR" "installing the missing prerequisites with Homebrew: brew install bash" "the install is announced plainly"
    assert_contains "$ERR" "$BOOTSTRAP_NOTE" "the refusal states what was changed"
    assert_only_brew_changed "old git"
}

test_a_set_hooks_path_refuses_before_any_prerequisite_formula_is_installed() {
    brew_less_fixture hooks || return 1
    gsg install
    assert_rc 1 "core.hooksPath set, bash 4.4 or newer"
    assert_eq "$(brew_calls)" "" "no brew install runs for a refused install"
    assert_contains "$ERR" "core.hooksPath" "names the reason"
    assert_contains "$ERR" "changes nothing" "nothing ran, so this claim is true"
    assert_contains "$OUT$ERR" "bash coreutils util-linux" "the missing formulae are listed with the prerequisites"
    nothing_changed "hooksPath refusal"
}

test_a_set_hooks_path_under_the_system_bash_leaves_only_the_bootstrap_install_and_says_so() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    brew_less_fixture hooks || return 1
    oldgsg install
    assert_rc 1 "core.hooksPath set, bash 3.2"
    assert_eq "$(brew_calls)" "install bash" "only the bootstrap installed bash; coreutils, util-linux and jq were not"
    assert_contains "$ERR" "core.hooksPath" "names the reason"
    assert_contains "$ERR" "$BOOTSTRAP_NOTE" "the refusal states what was changed"
    assert_not_contains "$ERR" "changes nothing" "no claim of nothing after the bootstrap"
    assert_only_brew_changed "hooksPath under bash 3.2"
}

test_the_system_bash_install_runs_bash_first_and_then_one_install_of_the_rest() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    brew_less_fixture || return 1
    oldgsg install
    assert_rc 0 "install under bash 3.2"
    assert_eq "$(brew_calls)" "install bash
install coreutils util-linux" "bash alone first, then one install of the other missing formulae"
    assert_eq "$(setting_of BASH_BIN)" "$(brew_prefix)/bin/bash" "the Homebrew bash is recorded"
    assert_eq "$(setting_of TIMEOUT_BIN)" "$(brew_prefix)/opt/coreutils/libexec/gnubin/timeout" "the brewed timeout is recorded"
}

test_a_brew_failure_after_the_checks_says_what_was_installed() {
    old_system_bash || skip_test "$NO_OLD_BASH"
    brew_less_fixture || return 1
    printf 'coreutils' >"$SANDBOX/brew.failon" || return 1
    oldgsg install
    assert_rc 1 "the second brew install fails"
    assert_eq "$(brew_calls)" "install bash
install coreutils util-linux" "both installs were tried"
    assert_contains "$ERR" "Error: injected brew failure" "brew's own message reaches the user"
    assert_contains "$ERR" "brew install coreutils util-linux failed" "names the failed command"
    assert_contains "$ERR" "$BOOTSTRAP_NOTE" "names what the bootstrap installed"
    assert_contains "$ERR" "may have installed part of coreutils util-linux" "says the failed install may be partial"
    assert_not_contains "$ERR" "changes nothing" "no claim of nothing"
    assert_only_brew_changed "second install failed"
}

# ^ external gsg starts through the shebang under the suite's own bash 4.4 or newer; the bootstrap does not run here
test_a_brew_failure_under_the_current_bash_says_it_may_have_installed_part() {
    brew_less_fixture || return 1
    : >"$SANDBOX/brew.fail"
    gsg install
    assert_rc 1 "brew fails"
    assert_contains "$ERR" "brew install bash coreutils util-linux failed" "names the failed command"
    assert_contains "$ERR" "may have installed part of bash coreutils util-linux" "says the failed install may be partial"
    assert_not_contains "$ERR" "changes nothing" "no claim of nothing"
    assert_only_brew_changed "brew failed"
}

BREW_ALL_NOTE="the only change made was the Homebrew install of bash coreutils util-linux"

# ^ invariant a refusal after brew names the formulae brew installed and never claims nothing was changed or installed; no state dir, config unchanged
assert_refusal_names_brew() {
    assert_contains "$ERR" "$BREW_ALL_NOTE" "$1: the refusal names what brew installed"
    assert_not_contains "$ERR" "nothing installed" "$1: no claim that nothing was installed"
    assert_not_contains "$ERR" "nothing was changed" "$1: no claim that nothing was changed"
    assert_only_brew_changed "$1"
}

test_a_tampered_download_after_the_brew_install_names_the_brew_packages() {
    local tar
    brew_less_fixture || return 1
    for tar in "$LC_FIX"/trufflehog_*.tar.gz; do printf 'x' >>"$tar" || return 1; done
    gsg install
    assert_rc 1 "tampered tarball on a Mac without coreutils"
    assert_eq "$(brew_calls)" "install bash coreutils util-linux" "no coreutils, so brew ran before the download"
    assert_contains "$ERR" "SHA-256 mismatch for trufflehog" "the mismatch is reported"
    assert_refusal_names_brew "sha mismatch"
}

test_a_scanner_reporting_another_version_after_the_brew_install_names_the_brew_packages() {
    local plat tar
    brew_less_fixture || return 1
    plat="$(lc_platform betterleaks)"
    tar="$LC_FIX/betterleaks_1.9.0_$plat.tar.gz"
    printf '#!/bin/sh\necho "betterleaks version 8.0.0"\n' >"$LC_FIX/src/betterleaks/betterleaks" || return 1
    tar -czf "$tar" -C "$LC_FIX/src/betterleaks" betterleaks LICENSE README.md || return 1
    sed -i "s/^betterleaks 1.9.0 $plat .*/betterleaks 1.9.0 $plat $(sha256sum -- "$tar" | cut -d' ' -f1)/" "$LC_FIX/fixture.lock" || return 1
    gsg install
    assert_rc 1 "a verified tarball whose binary says 8.0.0"
    assert_contains "$ERR" "does not report version 1.9.0" "the version mismatch is reported"
    assert_refusal_names_brew "version mismatch"
}

test_a_download_that_cannot_be_fetched_after_the_brew_install_names_the_brew_packages() {
    brew_less_fixture || return 1
    set_env GSG_TOOLS_BASE_URL="file://$SANDBOX/no-such-fixture-dir"
    gsg install
    assert_rc 1 "download failure on a Mac without coreutils"
    assert_contains "$ERR" "downloading" "the failed download is reported"
    assert_refusal_names_brew "download failure"
}

CLAIM_REGEX='nothing (was )?(changed|installed)|changes nothing|no change (was )?made|unchanged|nothing else'

# ^ invariant $1 = one joined statement, true when it uses brew_unchanged_text with no literal claim, or equals a line unreachable after brew
# ^ external the exact lines are the claim text (brew.sh) and the pre-brew default of the hooksPath refusal (a BREW_INSTALLED test follows it)
claim_line_is_allowed() {
    local without="${1//brew_unchanged_text/}"
    case "$1" in
        *brew_unchanged_text*)
            if grep -q -i -E "$CLAIM_REGEX" <<<"$without"; then return 1; fi
            return 0 ;;
        "printf 'nothing was changed'") return 0 ;;
        'claim="install changes nothing and refuses"') return 0 ;;
    esac
    return 1
}

# ^ invariant prints file.sh:line:statement for refused printf/echo/claim= in ROOT/lib; missing files too
# ^ external awk joins backslash-continued lines first; comment lines skipped
claim_sweep() {
    local root="$1" f hit text
    for f in install install_tools tools state hookspath brew; do
        if [ ! -f "$root/lib/$f.sh" ]; then
            printf '%s.sh: missing\n' "$f"
            continue
        fi
        while IFS= read -r hit; do
            text="${hit#*:}"
            text="${text#"${text%%[![:space:]]*}"}"
            if ! claim_line_is_allowed "$text"; then printf '%s.sh:%s\n' "$f" "$hit"; fi
        done < <(awk '
            { line = $0; if (buf != "") sub(/^[ \t]+/, "", line) }
            line ~ /\\$/ { if (buf == "") start = NR; sub(/\\$/, "", line); buf = buf line; next }
            { if (buf == "") start = NR; print start ":" buf line; buf = "" }
            END { if (buf != "") print start ":" buf }
        ' "$root/lib/$f.sh" | grep -v -E '^[0-9]+:[[:space:]]*#' | grep -E '(printf|echo|claim=)' | grep -i -E "$CLAIM_REGEX")
    done
}

test_every_install_refusal_wording_is_honest_after_a_brew_install() {
    local bad
    bad="$(claim_sweep "$GSG_PROJECT")" || return 1
    assert_eq "$bad" "" "no refusal statement outside the allow-list claims that nothing changed"
}

test_the_claim_sweep_catches_each_planted_false_claim() {
    local root="$SANDBOX/planted" out
    rm -rf -- "$root" && mkdir -p -- "$root/lib" || return 1
    cp -- "$GSG_PROJECT"/lib/{install,install_tools,tools,state,hookspath,brew}.sh "$root/lib/" || return 1
    assert_eq "$(claim_sweep "$root")" "" "the unmodified copy is clean"
    cat >>"$root/lib/tools.sh" <<'EOF' || return 1
printf 'planted one: nothing installed\n' >&2
printf '%s: planted two\n' \
    "nothing was changed" >&2
echo "planted three: changes nothing"
claim="planted four: no change was made"
printf '%s: planted five; nothing else\n' "$(brew_unchanged_text)" >&2
EOF
    out="$(claim_sweep "$root")" || return 1
    assert_eq "$(grep -c . <<<"$out")" 5 "five statements are flagged"
    assert_contains "$out" "planted one" "the one-line printf"
    assert_contains "$out" "planted two" "the claim on a continuation line"
    assert_contains "$out" "planted three" "the echo"
    assert_contains "$out" "planted four" "the claim= form with another phrase"
    assert_contains "$out" "planted five" "a literal claim next to brew_unchanged_text"
}

test_a_lock_without_the_platform_rows_refuses_before_brew_runs() {
    brew_less_fixture || return 1
    printf '# no rows\n' >"$SANDBOX/empty.lock" || return 1
    set_env GSG_TOOLS_LOCK="$SANDBOX/empty.lock"
    gsg install
    assert_rc 1 "a lock without a row for this platform"
    assert_contains "$ERR" "no row for trufflehog" "names the missing row"
    assert_eq "$(brew_calls)" "" "brew did not run"
    nothing_changed "lock without rows"
}

test_a_malformed_lock_refuses_before_brew_runs() {
    brew_less_fixture || return 1
    printf 'this is not a lock row\n' >"$SANDBOX/bad.lock" || return 1
    set_env GSG_TOOLS_LOCK="$SANDBOX/bad.lock"
    gsg install
    assert_rc 1 "a malformed lock"
    assert_contains "$ERR" "malformed" "says what is wrong"
    assert_eq "$(brew_calls)" "" "brew did not run"
    nothing_changed "malformed lock"
}

# ^ invariant a curl first on PATH logs before-brew or after-brew to $SANDBOX/curl.log, judged by brew.log, and runs the real curl
curl_order_recorder() {
    local real
    real="$(type -P curl)" || return 1
    rm -f -- "$SANDBOX/curl.log" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nd="$(cd "${0%%/*}/.." && pwd -P)" || exit 1\nif grep -q "^install" "$d/brew.log" 2>/dev/null; then echo after-brew; else echo before-brew; fi >>"$d/curl.log"\nexec %s "$@"\n' "$real" >"$SANDBOX/pathbin/curl" || return 1
    chmod 755 "$SANDBOX/pathbin/curl"
}

# ^ invariant a Mac whose prefix already has coreutils runs plan, download, verify and version check before the one brew install
coreutils_only_fixture() {
    lc_begin && as_macos && lc_brew_reset && lc_brew_have coreutils && lc_make_fixtures && lc_use_fixtures && curl_order_recorder || return 1
    snapshot_config
}

test_with_coreutils_present_a_tampered_download_refuses_before_brew_runs() {
    local tar
    coreutils_only_fixture || return 1
    for tar in "$LC_FIX"/trufflehog_*.tar.gz; do printf 'x' >>"$tar" || return 1; done
    gsg install
    assert_rc 1 "tampered tarball, GNU timeout present"
    assert_contains "$ERR" "SHA-256 mismatch for trufflehog" "the mismatch is reported"
    assert_eq "$(brew_calls)" "" "brew did not run: the download was checked first"
    assert_contains "$ERR" "nothing was changed" "the claim is true here"
    nothing_changed "tampered download, coreutils present"
}

test_with_coreutils_present_a_good_install_downloads_before_brew_and_installs_only_the_rest() {
    coreutils_only_fixture || return 1
    gsg install
    assert_rc 0 "install with coreutils present"
    assert_eq "$(brew_calls)" "install bash util-linux" "brew installs what is still missing, not coreutils"
    assert_eq "$(sort -u "$SANDBOX/curl.log")" "before-brew" "every download happened before the brew install"
    assert_eq "$(setting_of TIMEOUT_BIN)" "$(brew_prefix)/opt/coreutils/libexec/gnubin/timeout" "the timeout found is recorded"
}

test_without_coreutils_the_download_waits_for_the_brew_install() {
    brew_less_fixture && curl_order_recorder || return 1
    gsg install
    assert_rc 0 "install on a Mac without coreutils"
    assert_eq "$(brew_calls)" "install bash coreutils util-linux" "one brew install of everything missing"
    assert_eq "$(sort -u "$SANDBOX/curl.log")" "after-brew" "no bounded timeout exists before brew, so every download followed it"
}

test_a_command_that_needs_the_gnu_tools_refuses_when_no_gnu_directory_is_known() {
    local cmd
    lc_begin && as_macos && lc_path_without brew || return 1
    for cmd in status uninstall; do
        gsg "$cmd"
        assert_rc 1 "$cmd of a checkout with no brew on PATH"
        assert_contains "$ERR" "git-secret-guard: cannot find the GNU coreutils directory" "$cmd: says what is missing"
        assert_contains "$ERR" "brew install coreutils" "$cmd: names the formula"
    done
    for cmd in version help; do
        gsg "$cmd"
        assert_rc 0 "$cmd needs no GNU tool"
    done
}

test_an_installed_copy_whose_settings_name_no_gnu_directory_refuses_to_run_status() {
    lc_begin && as_macos && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install"
    grep -v '^GNUBIN_DIR=' "$LC_DATA/settings" >"$SANDBOX/settings.new" && mv -- "$SANDBOX/settings.new" "$LC_DATA/settings" || return 1
    lc_path_without brew || return 1
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "${TEST_BASH:-bash}" "$LC_DATA/bin/git-secret-guard" status
    assert_rc 1 "status of an installed copy without GNUBIN_DIR"
    assert_contains "$ERR" "git-secret-guard: cannot find the GNU coreutils directory" "says what is missing"
    assert_contains "$ERR" "GNUBIN_DIR" "names the missing setting"
    assert_contains "$ERR" "brew install coreutils" "names the formula"
}

# ^ external on a fresh Mac nothing GNU is on PATH before brew ran; $TEST_BREW_PREFIX/bin only supplies jq and curl, never the gnubin directory
bsd_only_path() { printf '%s' "$SANDBOX/pathbin:$TEST_BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"; }

ONE_MIB=1048576
# ^ coupled lib/install.sh GSG_BACKUP_MAX_BYTES is 50 MiB; OVERSIZE_MIB must stay above it or the refusal test passes for the wrong reason
OVERSIZE_MIB=60

test_a_takeover_install_with_only_the_bsd_tools_on_path_succeeds_and_runs_brew_once() {
    [ "$TEST_OS" = Darwin ] || skip_test "the BSD tools exist on macOS only"
    brew_less_fixture hooks || return 1
    printf 'x\n' >"$SANDBOX/hooks-dir/pre-commit" || return 1
    set_env PATH="$(bsd_only_path)"
    gsg install --replace-hooks-path
    assert_rc 0 "takeover install with BSD tools only"
    assert_eq "$(brew_calls)" "install bash coreutils util-linux" "one brew install of everything missing"
    assert_contains "$(ls "$LC_STATE"/hooks-path-backup-*.tar.gz 2>/dev/null)" "hooks-path-backup-" "the hooks directory was backed up"
}

test_an_oversize_hooks_dir_is_refused_with_only_the_bsd_tools_on_path_and_before_any_brew_call() {
    [ "$TEST_OS" = Darwin ] || skip_test "the BSD tools exist on macOS only"
    brew_less_fixture hooks || return 1
    dd if=/dev/zero of="$SANDBOX/hooks-dir/big" bs="$ONE_MIB" count=0 seek="$OVERSIZE_MIB" 2>/dev/null || return 1
    set_env PATH="$(bsd_only_path)"
    gsg install --replace-hooks-path
    assert_rc 1 "a hooks directory over the size bound"
    assert_contains "$ERR" "larger than" "names the bound"
    assert_eq "$(brew_calls)" "" "brew did not run"
    nothing_changed "oversize hooks dir"
}

run_file_tests
