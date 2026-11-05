#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup.sh"

# ^ external the contract tests drive the Linux flows of the rpm module and a test module; macOS and Windows have their own modules and test files
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Linux package manager flows"; fi

test_a_root_override_that_is_only_slashes_is_refused_and_the_os_release_override_is_announced() {
    gu_rpm_setup || return 1
    set_env GSG_GITUP_ROOT=//
    gsg install --upgrade-git </dev/null
    assert_rc 1 "a root override of only slashes"
    assert_contains "$ERR" "GSG_GITUP_ROOT must name a directory below /" "says why"
    set_env GSG_GITUP_ROOT="$GU_ROOT"
    gsg install </dev/null
    assert_contains "$ERR" "GSG_OS_RELEASE=[$SANDBOX/os-release]" "the os-release override is announced"
    assert_contains "$ERR" "the current user counts as the trusted owner" "and the announcement is truthful about what the override changes"
}

test_root_runs_the_system_dnf_not_the_one_first_on_the_users_path() {
    gu_rpm_setup || return 1
    mkdir -p -- "$SANDBOX/userbin" || return 1
    printf '#!/bin/sh\necho poisoned >>"%s/poison.log"\nexit 0\n' "$SANDBOX" >"$SANDBOX/userbin/dnf" && chmod 755 "$SANDBOX/userbin/dnf" || return 1
    set_env PATH="$SANDBOX/userbin:$GU_ROOT/usr/local/bin:$SANDBOX/pathbin:$TEST_BASE_PATH"
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route with a poisoned dnf first on PATH"
    assert_no_file "$SANDBOX/poison.log" "the user's dnf never ran"
    assert_contains "$OUT" "as root: $SANDBOX/pathbin/dnf install -y" "the plan prints the full path of the dnf root will run"
    assert_contains "$(gu_log)" "sudo -- $SANDBOX/pathbin/dnf install -y" "and root ran that one"
    gu_rpm_setup || return 1
    chmod 777 "$SANDBOX/pathbin/dnf" || return 1
    set_env GSG_GITUP_BUILD_PATH="$SANDBOX/pathbin"
    gsg install --upgrade-git </dev/null
    assert_rc 1 "a dnf that others can write is not accepted"
    assert_contains "$OUT$ERR" "dnf was not found in the system path" "and the plan says so"
}

test_the_plan_says_that_dnf_y_can_import_a_repository_key() {
    gu_rpm_setup || return 1
    gsg install </dev/null
    assert_contains "$OUT" "signing key import" "the source route plan says it"
    gu_rpm_setup || return 1
    printf '2.55.0\n' >"$SANDBOX/dnf.candidate"
    gsg install </dev/null
    assert_contains "$OUT" "route: package" "the package route"
    assert_contains "$OUT" "signing key import" "says it too"
    assert_contains "$OUT" "the read-only query above imported none" "and what the query did not do"
}

# ^ invariant gu_contract_setup [GIT_VERSION] reads the test module on stdin, puts it on class other in a copied tree; the sandbox git reports GIT_VERSION
gu_contract_setup() {
    lc_begin && gu_old_git "${1:-2.43.0}" && lc_make_fixtures && lc_use_fixtures && gu_module_env || return 1
    gu_tree_with_module testmod other || return 1
    GU_BIN="$GU_TREE/bin/git-secret-guard" GU_RUN_ROOT="$GU_TREE"
}

# ^ invariant the test module plus its own elevation (Windows UAC stands for it) and a hook running one privileged command from apply
gu_mod_elev() {
    printf '%s\n' "$GU_MODULE_OK"
    cat <<'EOF'
gitup_testmod_can_elevate() { [ -f "${GU_TM_ELEV:-/nonexistent}" ]; }
gitup_testmod_elevate() { printf 'elevate %s\n' "$*" >>"$GU_TM_LOG"; "$@"; }
gitup_testmod_hook() { gitup_elevate touch "$GU_TM_MARK"; }
EOF
}

test_a_module_can_supply_its_own_elevation_when_there_is_no_sudo() {
    gu_contract_setup < <(gu_mod_elev) || return 1
    rm -f -- "$SANDBOX/pathbin/sudo" || return 1
    set_env GU_TM_MARK="$SANDBOX/elevated-marker" GU_TM_ELEV="$SANDBOX/elev.ok"
    gsg_tree install --upgrade-git
    assert_rc 1 "no sudo and the module says it cannot elevate"
    assert_contains "$ERR" "neither root nor sudo is available" "says why"
    assert_no_file "$SANDBOX/testmod.log" "apply never ran"
    : >"$SANDBOX/elev.ok"
    gsg_tree install --upgrade-git
    assert_rc 0 "the module can elevate"
    assert_file "$SANDBOX/elevated-marker" "the privileged command ran"
    assert_contains "$(<"$SANDBOX/testmod.log")" "elevate touch $SANDBOX/elevated-marker" "through the module's own elevate"
    assert_not_contains "$(gu_log)" "sudo" "and not through sudo"
}

test_a_module_with_half_of_the_elevation_capability_is_refused_by_name() {
    lc_begin || return 1
    gu_tree_with_module halfmod other <<'EOF' || return 1
gitup_halfmod_plan() { GITUP_ROUTE=x; }
gitup_halfmod_apply() { return 0; }
gitup_halfmod_can_elevate() { return 0; }
EOF
    GU_RUN_ROOT="$GU_TREE"
    gu_call gitup_check_registered_modules
    assert_rc 1 "a module with can_elevate and no elevate"
    assert_contains "$OUT$ERR" "has part of the elevation capability but lacks gitup_halfmod_elevate" "names the module and the missing function"
}

test_a_module_can_delegate_its_plan_to_another_class_and_add_notes() {
    gu_contract_setup <<'EOF' || return 1
gitup_testmod_plan() { printf '  outer plan (%s)\n' "$1"; gitup_delegate synthinner plan "$1" || return 1; gitup_plan_note "outer note: the inner class is synthinner"; }
gitup_testmod_apply() { gitup_delegate synthinner apply; }
EOF
    gu_tree_add_class synthinner innermod || return 1
    gu_tree_add_class synthempty || return 1
    cat >"$GU_TREE/lib/gitup_innermod.sh" <<'EOF' || return 1
gitup_innermod_plan() { GITUP_ROUTE=inner; printf '  inner plan (%s)\n' "$1"; gitup_plan_priv "inner-cmd --as-root"; }
gitup_innermod_apply() {
    printf 'inner-apply\n' >>"$GU_TM_LOG"
    printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.56.0"; exit 0; fi\nexec %s "$@"\n' "$GU_TM_REAL_GIT" >"$GU_TM_NEWGIT"
    chmod 755 "$GU_TM_NEWGIT"
}
EOF
    gsg_tree install --upgrade-git
    assert_rc 0 "install through a delegating module"
    assert_contains "$OUT" "outer plan (upgrade)" "the outer module's line"
    assert_contains "$OUT" "inner plan (upgrade)" "the inner module's plan"
    assert_contains "$OUT" "as root: inner-cmd --as-root" "its privileged command"
    assert_contains "$OUT" "note: outer note: the inner class is synthinner" "and the outer module's note"
    assert_eq "$(<"$SANDBOX/testmod.log")" inner-apply "the inner apply ran"
    gu_call gitup_delegate synthempty plan upgrade
    assert_rc 1 "delegating to a class without a module"
    assert_contains "$OUT$ERR" "no git upgrade module is registered for the class synthempty" "says so"
}

test_a_module_can_say_the_takeover_cannot_be_done_and_let_the_install_continue() {
    gu_contract_setup 2.56.0 < <(printf '%s\n%s\n' "$GU_MODULE_OK" "gitup_testmod_takeover_unavailable() { printf 'this platform has no system git to take over'; }") || return 1
    gsg_tree install --take-over-system-git
    assert_rc 0 "install goes on"
    assert_contains "$OUT" "--take-over-system-git cannot be done here: this platform has no system git to take over" "the module's reason is printed"
    assert_contains "$OUT" "installed git-secret-guard" "and install finished"
}

# ^ invariant the test module plus a takeover capability for the file named in GU_TM_TK_TARGET; GU_TM_TK_STATE (none, active, undone) is what the module reports
gu_mod_tk() {
    printf '%s\n' "$GU_MODULE_OK"
    cat <<'EOF'
gitup_testmod_takeover_supported() { [ "$1" = "${GU_TM_TK_TARGET:-}" ]; }
gitup_testmod_takeover_plan() { printf '  takeover plan of testmod for %s\n' "$1"; gitup_plan_priv "testmod-takeover --as-root"; }
gitup_testmod_takeover_apply() { printf 'takeover-apply\n' >>"$GU_TM_LOG"; }
gitup_testmod_takeover_restore() { printf 'takeover-restore\n' >>"$GU_TM_LOG"; echo "testmod restored"; }
gitup_testmod_takeover_status() {
    GITUP_TK_STATE=${GU_TM_TK_STATE:-none} GITUP_TK_TEXT="testmod takeover ${GU_TM_TK_STATE:-none}" GITUP_TK_HOWTO="undo by hand: testmod-undo" GITUP_TK_TARGET=${GU_TM_TK_TARGET:-}
}
EOF
}

test_a_module_with_the_takeover_capability_gets_the_offer_the_status_the_restore_and_the_uninstall_guard() {
    gu_contract_setup 2.56.0 < <(gu_mod_tk) || return 1
    mkdir -p -- "$SANDBOX/oldbin" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.43.0"; exit 0; fi\nexec %s "$@"\n' "$GIT" >"$SANDBOX/oldbin/git" && chmod 755 "$SANDBOX/oldbin/git" || return 1
    set_env PATH="$SANDBOX/pathbin:$TEST_BASE_PATH:$SANDBOX/oldbin" "GU_TM_TK_TARGET=$SANDBOX/oldbin/git"
    gsg_pty $'\n' install
    assert_rc 0 "Enter at the takeover prompt"
    assert_contains "$OUT" "takeover plan of testmod for $SANDBOX/oldbin/git" "the module's plan is shown"
    assert_contains "$OUT" "[y/N]" "with the default No"
    assert_not_contains "$(cat "$SANDBOX/testmod.log" 2>/dev/null)" "takeover-apply" "nothing was taken over"
    gsg_tree install </dev/null
    assert_contains "$ERR" "install --take-over-system-git can point it at the new git" "the other-git warning offers the takeover"
    gsg_tree install --take-over-system-git
    assert_rc 0 "the flag"
    assert_contains "$(<"$SANDBOX/testmod.log")" "takeover-apply" "the module's takeover ran"
    set_env GU_TM_TK_STATE=active
    gsg_tree status
    assert_rc 0 "status with an active takeover"
    assert_contains "$OUT" "testmod takeover active" "has the module's line"
    set_env GU_TM_TK_STATE=undone
    gsg_tree status
    assert_rc 1 "an undone takeover is a problem"
    assert_contains "$OUT" "MISMATCH testmod takeover undone" "and says so"
    set_env GU_TM_TK_STATE=active
    gsg_tree uninstall
    assert_rc 1 "uninstall stops while the takeover is active"
    assert_contains "$ERR" "restore-system-git" "and names the fix"
    gsg_tree restore-system-git
    assert_rc 0 "restore-system-git"
    assert_contains "$OUT" "testmod restored" "runs the module's restore"
    gsg_tree uninstall --keep-system-git
    assert_rc 0 "uninstall --keep-system-git"
    assert_contains "$OUT" "undo by hand: testmod-undo" "prints the module's by-hand text"
}

test_a_module_without_the_takeover_capability_is_refused_cleanly_by_the_flag() {
    gu_contract_setup 2.56.0 <<<"$GU_MODULE_OK" || return 1
    gsg_tree install --take-over-system-git
    assert_rc 1 "the flag on a module without the capability"
    assert_contains "$ERR" "--take-over-system-git is not available on a system of class other" "says so"
    assert_no_file "$SANDBOX/testmod.log" "no module function ran"
    gsg_tree restore-system-git
    assert_rc 0 "restore-system-git on such a module"
    assert_contains "$OUT" "nothing to restore" "has nothing to do"
}

test_the_refresh_offer_runs_through_the_test_module() {
    gu_contract_setup 2.56.0 <<<"$GU_MODULE_OK" || return 1
    set_env GU_TM_REFRESH=1
    gsg_tree install </dev/null
    assert_rc 0 "no flag and no terminal: the install goes on"
    assert_contains "$OUT" "the test build is older than the pin" "the refresh plan was shown"
    assert_contains "$OUT" "git was left as it is" "and declined by default"
    assert_no_file "$SANDBOX/testmod.log" "apply never ran"
    gsg_tree install --upgrade-git
    assert_rc 0 "with the flag"
    assert_eq "$(<"$SANDBOX/testmod.log")" apply "apply ran once"
    rm -f -- "$SANDBOX/testmod.log"
    gsg_pty $'y\n' install
    assert_rc 0 "yes at the prompt"
    assert_eq "$(<"$SANDBOX/testmod.log")" apply "apply ran once more"
    rm -f -- "$SANDBOX/testmod.log"
    set_env GU_TM_APPLY_RC=2 "GU_TM_NEXT=finish elsewhere"
    gsg_tree install --upgrade-git
    assert_rc 3 "a hand-off from a refresh exits 3"
    assert_contains "$OUT$ERR" "finish elsewhere" "and prints the next step"
    set_env GU_TM_APPLY_RC=0 GU_TM_PLAN_RC=2
    gsg_tree install </dev/null
    assert_rc 0 "a refresh that cannot be done now does not stop a plain install"
    gsg_tree install --upgrade-git
    assert_rc 1 "but the flag asked for it, so the install is refused"
    assert_contains "$ERR" "cannot be done now" "and says why"
}

test_a_good_git_that_is_not_first_on_path_after_the_apply_gets_an_export_line() {
    gu_contract_setup <<<"$GU_MODULE_OK" || return 1
    set_env "GU_TM_NEWGIT=$SANDBOX/elsewhere/git"
    gsg_tree install --upgrade-git
    assert_rc 1 "the module put the new git where PATH does not look"
    # shellcheck disable=SC2016
    assert_contains "$ERR" "export PATH=\"$SANDBOX/elsewhere:\$PATH\"" "the refusal gives the exact line"
    assert_contains "$ERR" "no shell profile was edited" "and says no profile was touched"
}

test_the_refusal_without_sudo_prints_no_command_that_cannot_be_run() {
    gu_rpm_setup || return 1
    rm -f -- "$SANDBOX/pathbin/sudo" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "neither root nor sudo"
    assert_contains "$ERR" "$SANDBOX/pathbin/dnf install -y" "the dnf command can be typed by hand"
    assert_not_contains "$ERR" "cp -dR" "the copy command with its <build dir> is not printed"
    assert_contains "$ERR" "cannot be typed by hand" "and the reason is said"
    assert_contains "$ERR" "run the whole install as root" "with the way out"
}

test_the_per_repository_retry_stops_when_its_total_time_budget_is_used_up() {
    local n
    gu_rpm_setup || return 1
    set_env GSG_GITUP_QUERY_TIMEOUT=1
    printf 'a\nb\nc\nd\ne\nf\n' >"$SANDBOX/dnf.repos"
    printf '*' >"$SANDBOX/dnf.hang"
    gsg install </dev/null
    assert_contains "$OUT" "the other repositories were not tried: the retry budget of 2s was used up" "the plan says the retry stopped"
    n="$(grep -c 'could not be queried' <<<"$OUT")"
    if [ "$n" -ge 6 ]; then fail "all six repositories were tried ($n lines) although the budget was two seconds"; fi
}

test_the_warning_explains_what_stays_unscanned_and_names_the_git_in_use() {
    gu_tk_start || return 1
    gsg install </dev/null
    assert_rc 0 "install without the takeover flag"
    assert_contains "$ERR" "(the git in use is $GU_ROOT/usr/local/bin/git, git 2.56.0)" "the warning names the git in use"
    assert_contains "$ERR" "cron jobs and scripts that call $GU_ROOT/usr/bin/git by its full path are not scanned either" "and what stays unscanned"
    assert_contains "$ERR" "install --take-over-system-git can point it at the new git" "and how to fix it"
}

run_file_tests
