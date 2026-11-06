#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup.sh"

# ^ external the upgrade offer is Linux package-manager code; macOS and Windows get their own modules and their own test files
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Linux package manager flows"; fi

test_the_os_class_table_detects_every_planned_class() {
    local row id like want
    lc_begin || return 1
    for row in "${GU_CLASS_TABLE[@]}"; do
        IFS='|' read -r id like want <<<"$row"
        EXTRA_ENV=()
        gu_os_release "ID=$id" "ID_LIKE=\"$like\"" || return 1
        gu_reply gitup_os_class
        assert_eq "$OUT" "$want" "ID=$id ID_LIKE=[$like]"
    done
}

test_a_missing_or_unreadable_os_release_is_the_class_other() {
    local target
    lc_begin || return 1
    for target in "$SANDBOX/no-such-os-release" "$SANDBOX"; do
        EXTRA_ENV=()
        set_env GSG_OS_RELEASE="$target"
        gu_reply gitup_os_class
        assert_eq "$OUT" other "os-release [$target]"
        assert_empty "$ERR" "no shell error text for [$target]"
    done
}

test_macos_and_windows_are_detected_from_uname_before_os_release() {
    lc_begin || return 1
    gu_os_release 'ID=ubuntu' || return 1
    lc_fake_uname Darwin arm64 || return 1
    gu_reply gitup_os_class
    assert_eq "$OUT" macos "uname Darwin"
    lc_fake_uname MINGW64_NT-10.0-26200 x86_64 || return 1
    gu_reply gitup_os_class
    assert_eq "$OUT" windows "Git for Windows bash"
}

# shellcheck disable=SC2016
test_the_registry_maps_rpm_to_its_module_and_has_one_line_of_its_own_for_every_class() {
    local class mod
    local -a classes=()
    lc_begin || return 1
    gu_reply gitup_registry rpm
    assert_eq "$OUT" rpm "rpm has a module"
    gu_run 'printf "%s\n" "${GITUP_CLASSES[@]}"'
    mapfile -t classes <<<"$OUT"
    for class in rpm ubuntu debian macos windows other; do
        assert_contains " ${classes[*]} " " $class " "the library lists the planned class $class (order does not matter)"
    done
    for class in "${classes[@]}"; do
        assert_eq "$(grep -cE "^[[:space:]]+$class\\) REPLY=" "$GSG_PROJECT/lib/gitup.sh")" 1 "class $class has exactly one registry line of its own"
        gu_reply gitup_registry "$class"
        assert_rc 0 "registry lookup of $class"
        mod="$OUT"
        if [ -n "$mod" ]; then assert_file "$GSG_PROJECT/lib/gitup_$mod.sh" "the module $mod named for $class exists"; fi
    done
}

test_a_registry_class_nobody_knows_is_an_error_not_a_module() {
    lc_begin || return 1
    gu_call gitup_registry plan9
    assert_rc 1 "unknown class"
}

test_the_stand_in_tools_come_first_on_the_lifecycle_path_and_sudo_runs_inside_the_sandbox() {
    local tool
    lc_begin || return 1
    for tool in sudo dnf restorecon; do
        # shellcheck disable=SC2016
        assert_eq "$(env -i "${LC_ENV[@]}" bash -c 'type -P "$1"' _ "$tool" </dev/null)" "$SANDBOX/pathbin/$tool" "the $tool stand-in is first on the lifecycle PATH"
    done
    run_cap env -i "${LC_ENV[@]}" sudo -- touch "$SANDBOX/made-by-sudo"
    assert_rc 0 "the sudo stand-in"
    assert_file "$SANDBOX/made-by-sudo" "ran the command it was given"
    assert_contains "$(<"$SANDBOX/gitup.log")" "sudo -- touch $SANDBOX/made-by-sudo" "and recorded it"
}

# ^ invariant the core scenarios use the test module on the class "other"
gu_core_setup() {
    lc_begin && gu_old_git "${1:-2.43.0}" && lc_make_fixtures && lc_use_fixtures && gu_module_env || return 1
    gu_tree_with_module testmod other <<<"$GU_MODULE_OK" || return 1
    GU_BIN="$GU_TREE/bin/git-secret-guard" GU_RUN_ROOT="$GU_TREE"
}

gu_nothing_installed() {
    assert_no_file "$LC_STATE" "$1: no state"
    assert_no_file "$LC_DATA" "$1: no share dir"
    assert_eq "$(gitx config --global --get-regexp '^hook\.git-secret-guard\.' | wc -l)" 0 "$1: no hook config"
}

test_a_new_os_module_plugs_in_without_touching_the_core() {
    gu_core_setup || return 1
    gsg_tree install --upgrade-git
    assert_rc 0 "install with the test module"
    assert_contains "$OUT" "testmod plan (upgrade)" "the module's plan was printed"
    assert_contains "$OUT" "as root: testmod-upgrade-git --as-root" "with its privileged command named"
    assert_eq "$(<"$SANDBOX/testmod.log")" apply "apply ran once"
    assert_contains "$OUT" "installed git-secret-guard" "and install went on to the end"
    assert_eq "$(diff "$GSG_PROJECT/lib/gitup.sh" "$GU_TREE/lib/gitup.sh" | grep -c '^[<>]')" 2 "one registry line is the only difference in lib/gitup.sh"
}

test_every_registered_module_implements_the_contract() {
    lc_begin || return 1
    gu_call gitup_check_registered_modules
    assert_rc 0 "the modules in the registry"
    assert_contains "$OUT" "rpm" "the rpm module is checked"
}

test_the_contract_check_names_the_module_and_the_missing_function() {
    lc_begin || return 1
    gu_tree_with_module badmod other <<'EOF' || return 1
gitup_badmod_plan() { GITUP_ROUTE=x; }
gitup_badmod_takeover_supported() { return 0; }
EOF
    GU_RUN_ROOT="$GU_TREE"
    gu_call gitup_check_registered_modules
    assert_rc 1 "a module without apply"
    assert_contains "$OUT$ERR" "badmod" "names the module"
    assert_contains "$OUT$ERR" "gitup_badmod_apply" "names the missing required function"
    assert_contains "$OUT$ERR" "gitup_badmod_takeover_plan" "and a takeover capability that is only half there"
}

test_install_refuses_a_registered_module_that_breaks_the_contract() {
    lc_begin && gu_old_git 2.43.0 && lc_make_fixtures && lc_use_fixtures || return 1
    gu_tree_with_module badmod other <<'EOF' || return 1
gitup_badmod_plan() { GITUP_ROUTE=x; }
EOF
    gsg_tree install --upgrade-git
    assert_rc 1 "install with a broken module"
    assert_contains "$ERR" "gitup_badmod_apply" "names the missing function"
    gu_nothing_installed "broken module"
}

test_a_module_can_hand_off_and_install_stops_without_claiming_an_upgrade() {
    gu_core_setup || return 1
    set_env GU_TM_APPLY_RC=2 "GU_TM_NEXT=finish in a new window with: testmod-finish"
    gsg_tree install --upgrade-git
    assert_rc 3 "a hand-off stops install with its own exit code"
    assert_contains "$OUT$ERR" "finish in a new window with: testmod-finish" "the module's next step is printed"
    assert_not_contains "$OUT$ERR" "upgraded" "and git is not claimed to be upgraded"
    gu_nothing_installed "hand-off"
}

test_a_failed_apply_refuses_and_says_what_changed() {
    gu_core_setup || return 1
    set_env GU_TM_APPLY_RC=1 "GU_TM_CHANGED=the test module wrote /somewhere/half"
    gsg_tree install --upgrade-git
    assert_rc 1 "apply failed"
    assert_contains "$ERR" "the git upgrade failed" "says what failed"
    assert_contains "$ERR" "the test module wrote /somewhere/half" "and what had changed by then"
    gu_nothing_installed "failed apply"
}

test_a_refusal_after_the_upgrade_says_what_changed() {
    gu_core_setup || return 1
    printf 'trufflehog 3.99.2 %s %s\nbetterleaks 1.9.0 %s %s\n' "$(lc_platform trufflehog)" "$(printf '0%.0s' {1..64})" "$(lc_platform betterleaks)" "$(printf '0%.0s' {1..64})" >"$LC_FIX/fixture.lock"
    set_env "GU_TM_CHANGED=the test module placed a git"
    gsg_tree install --upgrade-git
    assert_rc 1 "a tampered scanner download"
    assert_contains "$ERR" "SHA-256 mismatch" "the later refusal"
    assert_contains "$ERR" "the test module placed a git" "says the upgrade had happened"
    assert_not_contains "$ERR" "nothing was changed" "and does not claim otherwise"
}

test_a_successful_apply_that_reports_no_change_is_still_recorded() {
    gu_core_setup || return 1
    printf 'trufflehog 3.99.2 %s %s\nbetterleaks 1.9.0 %s %s\n' "$(lc_platform trufflehog)" "$(printf '0%.0s' {1..64})" "$(lc_platform betterleaks)" "$(printf '0%.0s' {1..64})" >"$LC_FIX/fixture.lock"
    gsg_tree install --upgrade-git
    assert_rc 1 "a tampered scanner download"
    assert_contains "$ERR" "the testmod module upgraded git" "the core records the upgrade itself when the module said nothing"
}

test_no_terminal_and_no_flag_means_no_prompt_no_hang_and_no_privileged_command() {
    gu_core_setup || return 1
    gsg_tree install </dev/null
    assert_rc 1 "an old git, no terminal, no flag"
    assert_contains "$ERR" "config-based hooks need git >= 2.54, install refused" "refuses as today"
    assert_contains "$ERR" "install --upgrade-git" "names the flag"
    assert_no_file "$SANDBOX/testmod.log" "apply never ran"
    assert_no_file "$SANDBOX/gitup.log" "no sudo, dnf or restorecon call"
    gu_nothing_installed "no terminal"
}

test_the_prompt_defaults_to_no() {
    gu_core_setup || return 1
    gsg_pty $'\n' install
    assert_rc 1 "Enter at the prompt"
    assert_contains "$OUT" "[y/N]" "the prompt shows its default"
    assert_contains "$OUT" "testmod plan" "the plan was shown before asking"
    assert_contains "$OUT" "install --upgrade-git" "the refusal names the flag"
    assert_no_file "$SANDBOX/testmod.log" "apply never ran"
    gu_nothing_installed "answer no"
}

test_answering_yes_at_the_prompt_upgrades_and_install_continues() {
    gu_core_setup || return 1
    gsg_pty $'y\n' install
    assert_rc 0 "yes at the prompt"
    assert_eq "$(<"$SANDBOX/testmod.log")" apply "apply ran once"
    assert_contains "$OUT" "installed git-secret-guard" "install went on"
}

test_a_rerun_with_a_qualifying_git_prompts_for_nothing_and_calls_no_module() {
    gu_core_setup || return 1
    gsg_tree install --upgrade-git
    assert_rc 0 "first run upgrades"
    rm -f -- "$SANDBOX/testmod.log" "$SANDBOX/gitup.log"
    gsg_tree install --upgrade-git
    assert_rc 0 "second run, with the flag"
    assert_not_contains "$OUT" "testmod plan" "no plan"
    gsg_pty $'\n' install
    assert_rc 0 "second run in a terminal"
    assert_not_contains "$OUT" "[y/N]" "no prompt"
    assert_no_file "$SANDBOX/testmod.log" "the module was not called"
    assert_no_file "$SANDBOX/gitup.log" "and nothing privileged ran"
}

test_another_refusal_stops_the_upgrade_from_starting() {
    gu_core_setup || return 1
    lc_path_without jq || return 1
    gsg_tree install --upgrade-git
    assert_rc 1 "an old git and no jq"
    assert_contains "$ERR" "jq is required but was not found on PATH" "names the other problem"
    assert_no_file "$SANDBOX/testmod.log" "nothing was upgraded"
    gu_nothing_installed "missing jq"
    gu_core_setup || return 1
    gitx config --global core.hooksPath "$SANDBOX/some-hooks" || return 1
    gsg_tree install --upgrade-git
    assert_rc 1 "an old git and a core.hooksPath"
    assert_contains "$ERR" "--replace-hooks-path" "names the second problem"
    assert_no_file "$SANDBOX/testmod.log" "nothing was upgraded"
}

test_a_class_with_no_module_keeps_todays_refusal_and_offers_nothing() {
    local id
    for id in alpine archlinux; do
        lc_begin && gu_old_git 2.43.0 && gu_os_release "ID=$id" || return 1
        gsg install </dev/null
        assert_rc 1 "old git on $id"
        assert_contains "$ERR" "config-based hooks need git >= 2.54, install refused" "today's refusal on $id"
        assert_not_contains "$OUT$ERR" "upgrade plan" "no plan on $id"
        assert_not_contains "$ERR" "install --upgrade-git" "no flag named on $id, there is no module"
    done
}

test_a_plan_with_no_route_prints_its_reason_and_the_usual_refusal() {
    gu_core_setup || return 1
    set_env GU_TM_PLAN_RC=1
    gsg_tree install --upgrade-git
    assert_rc 1 "no route"
    assert_contains "$ERR" "config-based hooks need git >= 2.54, install refused" "today's refusal follows"
    assert_no_file "$SANDBOX/testmod.log" "apply never ran"
}

test_a_qualifying_git_that_is_not_first_on_path_gets_the_exact_path_fix_and_no_profile_is_edited() {
    gu_core_setup || return 1
    mkdir -p "$SANDBOX/newgit" && printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/newgit/git" && chmod 755 "$SANDBOX/newgit/git" || return 1
    set_env GU_TM_ROUTE=path-fix "GU_TM_FOUND=$SANDBOX/newgit/git"
    gsg_tree install --upgrade-git
    assert_rc 1 "a new git exists but is not first"
    assert_contains "$ERR" "put $SANDBOX/newgit first on PATH, for example: export PATH=\"$SANDBOX/newgit:\$PATH\"" "the exact fix"
    assert_no_file "$SANDBOX/testmod.log" "nothing was rebuilt"
    assert_no_file "$LC_HOME/.bashrc" "no profile edited"
    assert_no_file "$LC_HOME/.profile" "no profile edited"
    assert_no_file "$LC_HOME/.zshrc" "no profile edited"
    assert_no_file "$LC_HOME/.bash_profile" "no profile edited"
}

test_without_root_or_sudo_install_prints_the_commands_for_root_and_changes_nothing() {
    gu_core_setup || return 1
    rm -f -- "$SANDBOX/pathbin/sudo" || return 1
    gsg_tree install --upgrade-git
    assert_rc 1 "neither root nor sudo"
    assert_contains "$ERR" "neither root nor sudo is available" "says why"
    assert_contains "$ERR" "testmod-upgrade-git --as-root" "prints the commands to run as root"
    assert_no_file "$SANDBOX/testmod.log" "apply never ran"
    gu_nothing_installed "no way to elevate"
}

test_elevation_runs_directly_as_root_and_through_sudo_otherwise() {
    lc_begin || return 1
    set_env GSG_GITUP_ROOT="$SANDBOX/root"
    # shellcheck disable=SC2016
    gu_run 'gitup_is_root() { return 0; }; gitup_elevate touch "$1"' "$SANDBOX/as-root"
    assert_rc 0 "as root"
    assert_file "$SANDBOX/as-root" "the command ran"
    assert_no_file "$SANDBOX/gitup.log" "without sudo"
    gu_call gitup_elevate touch "$SANDBOX/as-user"
    assert_rc 0 "as a user"
    assert_contains "$(<"$SANDBOX/gitup.log")" "sudo -- $SANDBOX/pathbin/touch $SANDBOX/as-user" "through sudo, by the full path of the system touch"
}

run_file_tests
