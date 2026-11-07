#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/doctor.sh"

test_a_healthy_machine_exits_0_and_shows_the_machine_section() {
    local want
    dr_begin || return 1
    want="$(<"$GSG_PROJECT/VERSION")" || return 1
    doctor
    assert_rc 0 "healthy machine"
    assert_contains "$OUT" "machine:" "the machine section comes first"
    assert_contains "$OUT" "  ok       installed: version $want" "installed"
    assert_contains "$OUT" "  ok       hook: hook.git-secret-guard.event=pre-commit, command=$LC_DATA/hooks/secret-scan (executable)" "hook config"
    assert_contains "$OUT" "  ok       trufflehog: $LC_BIN/trufflehog$LC_EXE 3.99.2 (pinned 3.99.2)" "trufflehog at the pin"
    assert_contains "$OUT" "  ok       betterleaks: $LC_BIN/betterleaks$LC_EXE 1.9.0 (pinned 1.9.0)" "betterleaks at the pin"
    assert_contains "$OUT" "  ok       jq: $(lc_expected_jq)" "jq"
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then assert_contains "$OUT" "  ok       taskkill: " "process tool"; else assert_contains "$OUT" "  ok       setsid: $(dr_which setsid)" "setsid"; fi
    assert_contains "$OUT" "  ok       timeout: $(dr_which timeout)" "timeout"
    assert_contains "$OUT" "  ok       core.hooksPath: no global value" "no leftover hooksPath"
    assert_contains "$OUT" "summary: 0 repos, 0 covered" "the summary line"
    assert_not_contains "$OUT" "PROBLEM" "nothing wrong"
    assert_eq "$ERR" "git-secret-guard: note: GIT_CONFIG_GLOBAL is set; the global git config used is $SANDBOX/gitconfig" "stderr is only the one-line note"
}

test_a_doctor_that_cannot_run_exits_2_and_says_why() {
    dr_begin || return 1
    gsg doctor --roots "$SANDBOX/no-such-dir"
    assert_rc 2 "a root that is not a directory"
    assert_contains "$ERR" "git-secret-guard: root $SANDBOX/no-such-dir is not a directory" "names the root"
    assert_empty "$OUT" "and prints no report"
    set_env HOME="$SANDBOX/no-home"
    gsg doctor
    assert_rc 2 "the default root, the home directory, does not exist"
    assert_contains "$ERR" "default root $SANDBOX/no-home is not a directory; pass --roots DIR" "says how to fix it"
    set_env HOME="$LC_HOME"
    lc_fake_git 2.40.0 || return 1
    doctor
    assert_rc 2 "the git first on PATH is too old to evaluate config hooks"
    assert_contains "$ERR" "doctor needs git >= 2.54 to see config-based hooks" "says why doctor cannot judge"
    assert_empty "$OUT" "and no report is printed"
}

test_a_missing_hook_config_is_a_problem_that_says_what_to_do() {
    dr_begin || return 1
    gitx config --global --remove-section hook.git-secret-guard || return 1
    doctor
    assert_rc 1 "no hook config"
    assert_contains "$OUT" "  PROBLEM  hook: hook.git-secret-guard.event is [unset], want exactly [pre-commit]; run git-secret-guard install" "event"
    assert_contains "$OUT" "  PROBLEM  hook: hook.git-secret-guard.command is [unset], want exactly [$LC_DATA/hooks/secret-scan]; run git-secret-guard install" "command"
    assert_not_contains "$OUT" "  ok       hook:" "and no ok line for the hook"
}

test_a_hook_command_that_is_missing_or_not_executable_is_a_problem() {
    dr_begin || return 1
    chmod -x "$LC_DATA/hooks/secret-scan" || return 1
    doctor
    assert_rc 1 "not executable"
    assert_contains "$OUT" "  PROBLEM  hook: hook command is missing or not executable ($LC_DATA/hooks/secret-scan); run git-secret-guard install" "named"
    rm -f -- "$LC_DATA/hooks/secret-scan" || return 1
    doctor
    assert_rc 1 "missing"
    assert_contains "$OUT" "hook command is missing or not executable" "also when the file is gone"
}

test_a_duplicated_or_disabled_hook_config_is_a_problem() {
    dr_begin || return 1
    gitx config --global --add hook.git-secret-guard.event pre-push || return 1
    doctor
    assert_rc 1 "two events"
    assert_contains "$OUT" "hook.git-secret-guard.event has 2 values (global $SANDBOX/gitconfig; global $SANDBOX/gitconfig), 1 of them pre-commit, want exactly one, pre-commit; run git-secret-guard install" "count, scope and file, never the values"
    assert_not_contains "$OUT" "pre-push" "the foreign value is not printed"
    gitx config --global --replace-all hook.git-secret-guard.event pre-commit || return 1
    gitx config --global --add hook.git-secret-guard.command /elsewhere/secret-scan || return 1
    doctor
    assert_rc 1 "two commands"
    assert_contains "$OUT" "hook.git-secret-guard.command has 2 values (global $SANDBOX/gitconfig; global $SANDBOX/gitconfig), 1 of them the installed hook, want exactly one, the installed hook [$LC_DATA/hooks/secret-scan]; run git-secret-guard install" "count, scope and file, and whether one is the installed hook"
    assert_not_contains "$OUT" "/elsewhere/secret-scan" "the foreign value is not printed"
    gitx config --global --replace-all hook.git-secret-guard.command "$LC_DATA/hooks/secret-scan" || return 1
    gitx config --global hook.git-secret-guard.enabled false || return 1
    doctor
    assert_rc 1 "disabled in the global config"
    assert_contains "$OUT" "hook.git-secret-guard.enabled=false in the global config ($SANDBOX/gitconfig) switches the hook off everywhere; remove it" "names the file"
}

test_the_machine_section_judges_enabled_by_gits_own_parser_and_names_a_valueless_key() {
    local v
    dr_begin || return 1
    for v in 00 0k 0x0 -0; do
        gitx config --global hook.git-secret-guard.enabled "$v" || return 1
        doctor
        assert_rc 1 "[$v] is false for git"
        assert_contains "$OUT" "hook.git-secret-guard.enabled=$v in the global config" "[$v] named"
    done
    gitx config --global hook.git-secret-guard.enabled true || return 1
    gitx config --global hook.pre-commit.enabled 0k || return 1
    doctor
    assert_contains "$OUT" "hook.pre-commit.enabled=0k in the global config" "the event key too"
    gitx config --global --unset hook.pre-commit.enabled || return 1
    printf '[hook "git-secret-guard"]\n\tenabled\n' >>"$SANDBOX/gitconfig" || return 1
    doctor
    assert_rc 1 "a key without a value"
    assert_contains "$OUT" "PROBLEM  hook: hook.git-secret-guard.enabled has no value in the global config ($SANDBOX/gitconfig); git commands fail until" "a PROBLEM"
}

# shellcheck disable=SC2016
test_the_machine_section_judges_the_event_key_only_from_git_2_55_and_warns_about_a_non_boolean_value() {
    dr_begin || return 1
    gitx config --global hook.pre-commit.enabled false || return 1
    printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.54.0"; exit 0; fi\nexec %s "$@"\n' "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git"
    doctor
    assert_not_contains "$OUT" "hook.pre-commit.enabled=false" "git 2.54 does not read it"
    gitx config --global --unset hook.pre-commit.enabled || return 1
    rm -f -- "$SANDBOX/pathbin/git"
    gitx config --global hook.git-secret-guard.enabled maybe || return 1
    doctor
    assert_contains "$OUT" "WARNING  hook: hook.git-secret-guard.enabled=maybe in the global config" "a value git does not read as off is said"
    assert_contains "$OUT" "the hook stays on" "and that the hook stays on"
}

test_the_machine_section_lets_the_last_valid_value_decide() {
    dr_begin || return 1
    gitx config -f "$SANDBOX/system.cfg" hook.git-secret-guard.enabled false || return 1
    set_env GIT_CONFIG_NOSYSTEM=0 "GIT_CONFIG_SYSTEM=$SANDBOX/system.cfg"
    gitx config --global hook.git-secret-guard.enabled maybe || return 1
    doctor
    assert_rc 1 "system false, global maybe: the hook does not run"
    assert_contains "$OUT" "PROBLEM  hook: hook.git-secret-guard.enabled=false in the system config" "a PROBLEM naming the deciding value"
    assert_contains "$OUT" "git ignores it" "the later maybe is called ignored"
    assert_not_contains "$OUT" "stays on" "and the hook is not said to stay on beside a PROBLEM"
}

# shellcheck disable=SC2016
test_the_machine_section_makes_a_failing_bool_probe_a_problem_not_a_yes() {
    dr_begin || return 1
    gitx config --global hook.git-secret-guard.enabled false || return 1
    printf '#!/bin/sh\nfor a in "$@"; do case "$a" in gsg.probe=*) echo "fatal: simulated failure" >&2; exit 128 ;; esac; done\nexec %s "$@"\n' "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git"
    doctor
    assert_rc 1 "a probe that fails for another reason"
    assert_contains "$OUT" "PROBLEM  hook: hook.git-secret-guard.enabled could not be judged" "a PROBLEM"
}

test_the_machine_section_never_prints_a_hook_config_value() {
    local marker
    dr_begin || return 1
    marker="$(new_marker)"
    gitx config --global --add hook.git-secret-guard.command "/bin/true --token=$marker" || return 1
    gitx config --global --add hook.git-secret-guard.event "pre-push-$marker" || return 1
    doctor
    assert_rc 1 "a polluted global hook config"
    assert_contains "$OUT" "hook.git-secret-guard.command has 2 values" "reported by count"
    assert_contains "$OUT" "hook.git-secret-guard.event has 2 values" "also the event"
    no_leak "$marker"
    gitx config --global --replace-all hook.git-secret-guard.command "/bin/true --token=$marker" || return 1
    doctor
    assert_contains "$OUT" "hook.git-secret-guard.command has 1 value (global $SANDBOX/gitconfig), 0 of them the installed hook" "a single wrong value is described, not shown"
    no_leak "$marker"
}

test_a_tool_that_is_missing_or_at_the_wrong_version_is_a_problem() {
    dr_begin || return 1
    rm -f -- "$LC_BIN/betterleaks$LC_EXE" || return 1
    printf '#!/bin/sh\necho "trufflehog 3.0.0"\n' >"$LC_BIN/trufflehog$LC_EXE" || return 1
    doctor
    assert_rc 1 "a missing and a stale tool"
    assert_contains "$OUT" "  PROBLEM  betterleaks: betterleaks is missing or not executable ($LC_BIN/betterleaks); run git-secret-guard install" "missing"
    assert_contains "$OUT" "  PROBLEM  trufflehog: $LC_BIN/trufflehog$LC_EXE reports 3.0.0, the pin is 3.99.2; run git-secret-guard install" "wrong version"
    assert_not_contains "$OUT" "  ok       trufflehog:" "no ok line for a tool at the wrong version"
    printf '#!/bin/sh\necho "trufflehog 3.99.2.1"\n' >"$LC_BIN/trufflehog$LC_EXE" || return 1
    doctor
    assert_contains "$OUT" "trufflehog: $LC_BIN/trufflehog$LC_EXE reports 3.99.2.1, the pin is 3.99.2" "a longer version is not the pin, as install judges it"
}

test_an_unusable_jq_timeout_or_settings_file_is_a_problem() {
    dr_begin || return 1
    sed -i 's#^JQ_BIN=.*#JQ_BIN=/nonexistent/jq#' "$LC_DATA/settings" || return 1
    doctor
    assert_rc 1 "jq cannot run"
    assert_contains "$OUT" "  PROBLEM  jq: jq is missing or not executable (/nonexistent/jq); run git-secret-guard install" "jq named"
    sed -i 's#^TIMEOUT_BIN=.*#TIMEOUT_BIN=relative/timeout#' "$LC_DATA/settings" || return 1
    doctor
    assert_rc 1 "timeout is relative"
    assert_contains "$OUT" "timeout: timeout must be an absolute path, got [relative/timeout]; run git-secret-guard install" "timeout named"
    assert_contains "$OUT" "trufflehog: $LC_BIN/trufflehog$LC_EXE version not checked, timeout is unusable" "versions cannot be probed without it"
    rm -f -- "$LC_DATA/settings" || return 1
    doctor
    assert_rc 1 "no settings file"
    assert_contains "$OUT" "  PROBLEM  settings: settings file is missing or unreadable: $LC_DATA/settings; run git-secret-guard install" "settings named"
}

test_a_leftover_global_hooks_path_is_a_problem_also_from_an_included_file() {
    dr_begin || return 1
    git_literal_config --global core.hooksPath /old/hooks || return 1
    doctor
    assert_rc 1 "a value in the global file"
    assert_contains "$OUT" "  PROBLEM  core.hooksPath: [/old/hooks] is still set in $SANDBOX/gitconfig; remove it (git config --global --unset-all core.hooksPath)" "own file"
    gitx config --global --unset-all core.hooksPath || return 1
    printf '[core]\n\thooksPath = /included/hooks\n' >"$SANDBOX/included.conf" || return 1
    gitx config --global include.path "$SANDBOX/included.conf" || return 1
    doctor
    assert_rc 1 "a value in an included file"
    assert_contains "$OUT" "  PROBLEM  core.hooksPath: [/included/hooks] is set in $SANDBOX/included.conf; remove it there" "foreign file named"
}

test_a_machine_without_install_or_with_a_broken_state_is_a_problem() {
    dr_begin || return 1
    printf 'garbage\n' >"$LC_STATE/state" || return 1
    doctor
    assert_rc 1 "a malformed state"
    assert_contains "$OUT" "  PROBLEM  state: the state file $LC_STATE/state is malformed at [garbage]; fix or remove it" "state named"
    rm -f -- "$LC_STATE/state" || return 1
    doctor
    assert_rc 1 "no state file"
    assert_contains "$OUT" "  PROBLEM  installed: not installed (no state file at $LC_STATE/state); run git-secret-guard install" "not installed"
}

test_an_old_git_reachable_on_PATH_or_at_usr_bin_is_a_warning_naming_path_and_version() {
    local sys_ver
    dr_begin || return 1
    mkdir -p -- "$SANDBOX/oldgit" "$SANDBOX/junkgit" || return 1
    printf '#!/bin/sh\necho "git version 2.30.1"\n' >"$SANDBOX/oldgit/git" && chmod 755 "$SANDBOX/oldgit/git" || return 1
    printf '#!/bin/sh\necho "not a version"\n' >"$SANDBOX/junkgit/git" && chmod 755 "$SANDBOX/junkgit/git" || return 1
    set_env PATH="$SANDBOX/pathbin:$TEST_BASE_PATH:$SANDBOX/oldgit:$SANDBOX/junkgit"
    doctor
    assert_rc 0 "a warning does not change the exit status"
    assert_contains "$OUT" "  ok       git: $GIT $("$GIT" --version | sed -n 's/^git version \([0-9][0-9.]*[0-9]\).*/\1/p')" "the git that commits use is fine"
    assert_contains "$OUT" "  WARNING  git: $SANDBOX/oldgit/git is git 2.30.1; it ignores config-based hooks without any message, so commits made with it are NOT scanned" "old git by path and version"
    assert_contains "$OUT" "  WARNING  git: $SANDBOX/junkgit/git is git of unknown version;" "a git that reports no version is warned about too"
    sys_ver="$(/usr/bin/git --version | sed -n 's/^git version \([0-9]*\.[0-9]*\).*/\1/p')" || return 1
    if [ "$(printf '%s\n' 2.54 "$sys_ver" | sort -V | head -n 1)" != 2.54 ]; then
        assert_contains "$OUT" "  WARNING  git: /usr/bin/git is git $sys_ver" "/usr/bin/git is always checked and this one is older than 2.54"
    else
        assert_contains "$OUT" "  ok       git: /usr/bin/git $sys_ver" "/usr/bin/git is new enough here"
    fi
    assert_contains "$OUT" "warnings: " "the summary counts the warnings"
}

test_doctor_accepts_the_gitleaks_entries_of_a_state_the_previous_build_wrote() {
    local h1
    dr_begin || return 1
    h1="$(printf '%064d' 1)"
    sed -i "s#^tools_installed_by_us=.*#tools_installed_by_us=trufflehog gitleaks#; s#^tools_placed=.*#tools_placed=trufflehog:$h1 gitleaks:$h1#" "$LC_STATE/state" || return 1
    doctor
    assert_not_contains "$OUT" "PROBLEM  state:" "gitleaks is a tool the previous build recorded, not an unknown one"
    assert_contains "$OUT" "state records: 2 placed hash(es)" "its hash is counted"
}

test_the_state_records_are_checked_for_validity_unfinished_placements_and_missing_originals() {
    local h1 h2 aside
    dr_begin || return 1
    h1="$(printf '%064d' 1)" h2="$(printf '%064d' 2)" aside="betterleaks.gsg-replaced-20261031T101500Z"
    doctor
    assert_contains "$OUT" "  ok       state records: 2 placed hash(es), 0 original(s) moved aside" "a fresh install is consistent"

    sed -i "s#^tools_placed=.*#tools_placed=betterleaks:xyz git:$h1 trufflehog:$h1#" "$LC_STATE/state" || return 1
    doctor
    assert_rc 1 "invalid placed entries"
    assert_contains "$OUT" "  PROBLEM  state: tools_placed entry [betterleaks:xyz] is invalid (want <tool>:<sha256>)" "bad hash"
    assert_contains "$OUT" "  PROBLEM  state: tools_placed entry [git:$h1] is invalid (want <tool>:<sha256>)" "unknown tool"

    sed -i "s#^tools_placed=.*#tools_placed=betterleaks:$h1 betterleaks:$h2 betterleaks:$h2 trufflehog:$h1#" "$LC_STATE/state" || return 1
    doctor
    assert_rc 0 "an unfinished placement is a warning"
    assert_contains "$OUT" "  WARNING  state: tools_placed holds 2 hashes for betterleaks, an install did not finish placing it; run git-secret-guard install again" "two different hashes, the repeat is not counted"
    assert_not_contains "$OUT" "for trufflehog" "one hash is fine"

    sed -i "s#^tools_installed_by_us=.*#tools_installed_by_us=trufflehog ../escape#" "$LC_STATE/state" || return 1
    doctor
    assert_rc 1 "a name that is not a tool"
    assert_contains "$OUT" "  PROBLEM  state: tools_installed_by_us names [../escape], not a tool install manages" "unknown tool"
    longname="$(printf 'z%.0s' $(seq 1 100))"
    sed -i "s#^tools_installed_by_us=.*#tools_installed_by_us=$longname#" "$LC_STATE/state" || return 1
    doctor
    assert_contains "$OUT" "  PROBLEM  state: tools_installed_by_us names [${longname:0:80}…], not a tool install manages" "a long entry is cut at 80 characters and marked"
    assert_not_contains "$OUT" "${longname:0:81}" "and nothing past the cut (81 z in a row would mean no cut)"
    sed -i "s#^tools_installed_by_us=.*#tools_installed_by_us=trufflehog ../escape#" "$LC_STATE/state" || return 1

    sed -i "s#^tools_replaced=.*#tools_replaced=$aside:$h1 ../x:$h1#" "$LC_STATE/state" || return 1
    doctor
    assert_rc 1 "an invalid replaced entry"
    assert_contains "$OUT" "  PROBLEM  state: tools_replaced entry [../x:$h1] is invalid" "bad aside name"
    assert_contains "$OUT" "  WARNING  state: tools_replaced records $aside but $LC_BIN/$aside is missing; a rerun of install drops a record of a move that never happened, otherwise your original cannot be restored" "a valid entry whose file is gone"
    printf 'mine\n' >"$LC_BIN/$aside" || return 1
    doctor
    assert_not_contains "$OUT" "is missing; a rerun" "present once the file is there"
}

test_a_tools_lock_without_a_pin_row_is_a_problem_for_each_scanner() {
    dr_begin || return 1
    : >"$SANDBOX/empty.lock" || return 1
    set_env GSG_TOOLS_LOCK="$SANDBOX/empty.lock"
    doctor
    assert_rc 1 "no pinned version to compare with"
    assert_contains "$OUT" "  PROBLEM  trufflehog: tools.lock has no pinned version for this platform" "trufflehog"
    assert_contains "$OUT" "  PROBLEM  betterleaks: tools.lock has no pinned version for this platform" "betterleaks"
}

test_a_git_config_that_cannot_be_read_is_a_doctor_error() {
    dr_begin || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = -C ] && [ "$2" = / ]; then echo "fatal: injected failure" >&2; exit 128; fi\nexec %s "$@"\n' "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git" || return 1
    doctor
    assert_rc 2 "the machine-level git config reads fail with exit 128"
    assert_contains "$OUT" "  PROBLEM  hook: cannot read the git config (git config exit 128: fatal: injected failure)" "the machine section says so"
    assert_contains "$ERR" "git-secret-guard: cannot read the global git config" "and so does the error"
    assert_not_contains "$OUT" "summary:" "no summary claims coverage"
}

test_doctor_exits_2_when_it_cannot_make_its_temp_dir() {
    dr_begin || return 1
    set_env TMPDIR="$SANDBOX/no-such-tmp"
    doctor
    assert_rc 2 "mktemp has nowhere to go"
    assert_contains "$ERR" "git-secret-guard: cannot create a temp directory" "says so"
    assert_empty "$OUT" "and prints no report"
}

test_doctor_exits_2_when_git_is_not_on_PATH() {
    dr_begin || return 1
    lc_path_without git || return 1
    doctor
    assert_rc 2 "no git at all"
    assert_contains "$ERR" "git-secret-guard: git is not on PATH" "says so"
    assert_empty "$OUT" "and prints no report"
}

test_a_syntactically_broken_global_config_stops_doctor_with_one_clear_error() {
    dr_begin || return 1
    printf '[core\n\tbroken = (\n' >>"$SANDBOX/gitconfig" || return 1
    doctor
    assert_rc 2 "git cannot parse the global config"
    assert_contains "$ERR" "git-secret-guard: git cannot start the checks (fatal: bad config line " "doctor says what failed, in its own words"
    assert_empty "$OUT" "nothing is printed before the checks can run"
}

test_doctor_checks_the_timer_only_when_the_state_says_one_is_installed() {
    local units tmr=git-secret-guard-doctor.timer svc=git-secret-guard-doctor.service
    dr_begin || return 1
    units="$LC_HOME/.config/systemd/user"
    doctor
    assert_not_contains "$OUT" "timer:" "no timer, no timer line"
    gsg install --with-timer
    assert_rc 0 "install --with-timer"
    doctor
    assert_rc 0 "a healthy timer"
    assert_contains "$OUT" "  ok       timer: $tmr and $svc are in $units; systemctl $SANDBOX/pathbin/systemctl" "ok line"
    rm -f -- "$units/$svc" || return 1
    doctor
    assert_rc 1 "a unit file is gone"
    assert_contains "$OUT" "  PROBLEM  timer: $units/$svc is missing; run git-secret-guard install --with-timer" "named"
    printf '[Timer]\n' >"$units/$svc" || return 1
    doctor
    assert_contains "$OUT" "  PROBLEM  timer: $units/$svc was not written by git-secret-guard; move it away and run git-secret-guard install --with-timer" "a foreign unit"
    rm -f -- "$units/$svc" || return 1
    gsg install --with-timer
    assert_rc 0 "install --with-timer repairs the missing unit"
    sed -i 's#^SYSTEMCTL_BIN=.*#SYSTEMCTL_BIN=/nonexistent/systemctl#' "$LC_DATA/settings" || return 1
    doctor
    assert_rc 1 "systemctl cannot run"
    assert_contains "$OUT" "  PROBLEM  systemctl: systemctl is missing or not executable (/nonexistent/systemctl); run git-secret-guard install --with-timer" "uninstall would fail the same way"
}

run_file_tests
