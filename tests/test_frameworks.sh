#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

CALLS="" MARKER=""
begin() {
    new_repo "$1" || return 1
    CALLS="$SANDBOX/calls-$1"
    MARKER="$(new_marker)"
    set_env STUB_LOG="$CALLS" STUB_MARKER="$MARKER"
}
count_calls() { local n=0; if [ -f "$CALLS" ]; then n="$(grep -c "^$1 " "$CALLS")"; fi; printf '%s' "$n"; }
assert_no_commit() { if gitx rev-parse -q --verify HEAD >/dev/null 2>&1; then fail "a commit was created"; fi; }

make_husky() {
    local h
    local -a hooks=(pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit applypatch-msg pre-applypatch
        post-applypatch pre-rebase post-rewrite post-checkout post-merge pre-push pre-auto-gc)
    mkdir -p .husky/_ || return 1
    cp -- "$GSG_PROJECT/tests/fixtures/husky/h" .husky/_/h || return 1
    printf '*' >.husky/_/.gitignore
    for h in "${hooks[@]}"; do
        # shellcheck disable=SC2016
        printf '#!/usr/bin/env sh\n. "$(dirname "$0")/h"' >".husky/_/$h" && chmod 755 ".husky/_/$h" || return 1
    done
    printf '%s\n' "$1" >.husky/pre-commit
    gitx config core.hooksPath .husky/_
}

test_husky_clean_commit_runs_the_scan_and_the_husky_hook() {
    begin husky1 || return 1
    make_husky "echo ran >>'$SANDBOX/husky-ran'"
    stage_file a.txt one
    commit_cap "a"
    assert_rc 0 commit
    assert_eq "$(count_calls trufflehog)$(count_calls gitleaks)" 11 "both tools ran"
    assert_file "$SANDBOX/husky-ran" "the husky pre-commit hook ran"
}

test_husky_repo_finding_is_blocked_by_the_scan() {
    begin husky2 || return 1
    make_husky "echo ran >>'$SANDBOX/husky-ran2'"
    stage_file a.txt one two
    set_env STUB_GL_FINDINGS="generic-api-key|a.txt|2"
    commit_cap "a"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "a.txt:2" "finding reported"
    no_leak "$MARKER"
    assert_no_commit
}

test_husky_failing_hook_still_blocks() {
    begin husky3 || return 1
    make_husky "exit 1"
    stage_file a.txt one
    commit_cap "a"
    assert_rc 1 "blocked by husky"
    assert_contains "$ERR" "husky - pre-commit script failed (code 1)" "husky's own message"
    assert_eq "$(count_calls trufflehog)" 1 "the scan ran as well"
}

test_husky_disabled_with_HUSKY_0_does_not_disable_the_scan() {
    begin husky4 || return 1
    make_husky "echo ran >>'$SANDBOX/husky-ran4'"
    stage_file a.txt one
    set_env HUSKY=0 STUB_TF_FINDINGS="AWS|true|a.txt|1"
    commit_cap "a"
    assert_rc 1 "blocked by the scan"
    assert_no_file "$SANDBOX/husky-ran4" "husky skipped itself"
    assert_eq "$(count_calls trufflehog)" 1 "the scan still ran"
}

test_scan_runs_when_repo_hooks_path_points_at_a_missing_directory() {
    begin missinghp || return 1
    gitx config core.hooksPath "$SANDBOX/does/not/exist"
    stage_file a.txt one
    commit_cap "a"
    assert_rc 0 commit
    assert_eq "$(count_calls trufflehog)$(count_calls gitleaks)" 11 "both tools ran"
}

test_pre_commit_framework_installs_and_both_its_checks_and_the_scan_run() {
    begin fw || return 1
    printf '#!/bin/sh\ntouch "%s/framework-ran"\n' "$SANDBOX" >"$SANDBOX/framework-check.sh"
    chmod +x "$SANDBOX/framework-check.sh"
    cat >.pre-commit-config.yaml <<EOF
repos:
  - repo: local
    hooks:
      - id: sandbox-check
        name: sandbox-check
        entry: $SANDBOX/framework-check.sh
        language: system
        pass_filenames: false
        always_run: true
EOF
    run_cap env -i "${GSG_ENV[@]}" pre-commit install
    assert_rc 0 "pre-commit install"
    assert_file .git/hooks/pre-commit "framework shim installed"
    stage_file a.txt one
    gitx add .pre-commit-config.yaml
    commit_cap "a"
    assert_rc 0 commit
    assert_file "$SANDBOX/framework-ran" "the framework check ran"
    assert_eq "$(count_calls trufflehog)$(count_calls gitleaks)" 11 "both tools ran"
}

test_pre_commit_framework_repo_finding_is_blocked_by_the_scan() {
    begin fw2 || return 1
    printf '#!/bin/sh\ntouch "%s/framework-ran2"\n' "$SANDBOX" >"$SANDBOX/framework-check2.sh"
    chmod +x "$SANDBOX/framework-check2.sh"
    printf 'repos:\n  - repo: local\n    hooks:\n      - id: c\n        name: c\n        entry: %s/framework-check2.sh\n        language: system\n        pass_filenames: false\n        always_run: true\n' "$SANDBOX" >.pre-commit-config.yaml
    run_cap env -i "${GSG_ENV[@]}" pre-commit install
    assert_rc 0 "pre-commit install"
    stage_file a.txt one
    gitx add .pre-commit-config.yaml
    set_env STUB_TF_FINDINGS="AWS|false|a.txt|1"
    commit_cap "a"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "a.txt:1" "finding reported"
    assert_no_commit
}

test_service_environment_reaches_both_scanners_and_is_decided_by_findings() {
    begin svc || return 1
    service_prepare
    service_env
    assert_eq "$(env -i PATH="$SVC_PATH" git --version)" "git version 2.56.0" "the unit's PATH resolves the config-hook-capable git"
    stage_file a.txt one
    run_cap env -i "${SVC_ENV[@]}" git commit -q -m clean
    assert_rc 0 "clean commit in the service environment"
    assert_eq "$(count_calls trufflehog)$(count_calls gitleaks)" 11 "both scanners reached"
    stage_file b.txt two
    set_env STUB_GL_FINDINGS="generic-api-key|b.txt|1"
    service_env
    run_cap env -i "${SVC_ENV[@]}" git commit -q -m leak
    assert_rc 1 "finding blocks in the service environment"
    assert_contains "$ERR" "b.txt:1" "decided by the finding"
    assert_not_contains "$ERR" "not executable" "no environment error"
    assert_not_contains "$ERR" "settings" "no environment error"
    no_leak "$MARKER"
}

run_file_tests
