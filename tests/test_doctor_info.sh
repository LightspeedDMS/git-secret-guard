#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/doctor.sh"

test_a_pre_commit_config_without_the_framework_hook_is_info_and_keeps_exit_0() {
    dr_begin && dr_repo fw || return 1
    printf 'repos: []\n' >"$DR_ROOTS/fw/.pre-commit-config.yaml" || return 1
    doctor
    assert_rc 0 "info alone does not change the exit status"
    assert_contains "$OUT" "  $DR_REAL/fw
    info     .pre-commit-config.yaml is present but $DR_REAL/fw/.git/hooks/pre-commit is not the pre-commit framework's hook (pre-commit install not run)" "listed as info"
    assert_contains "$OUT" "summary: 1 repos, 1 covered" "still covered"
    assert_not_contains "$OUT" "    WARNING" "and not a warning on the repository"
}

test_the_real_pre_commit_install_removes_the_info() {
    command -v pre-commit >/dev/null 2>&1 || [ -x "$REAL_HOME/.local/bin/pre-commit" ] || skip_test "pre-commit is not installed"
    dr_begin && dr_repo fw || return 1
    printf 'repos: []\n' >"$DR_ROOTS/fw/.pre-commit-config.yaml" || return 1
    (cd -- "$DR_ROOTS/fw" && env -i "${GSG_ENV[@]}" pre-commit install >/dev/null) || { fail "pre-commit install failed"; return 1; }
    doctor
    assert_rc 0 "the framework hook is installed"
    assert_not_contains "$OUT" "repos with findings" "nothing to list"
}

test_a_hook_file_that_is_not_the_framework_shim_still_counts_as_not_installed() {
    dr_begin && dr_repo custom || return 1
    printf 'repos: []\n' >"$DR_ROOTS/custom/.pre-commit-config.yaml" || return 1
    printf '#!/bin/sh\nexit 0\n' >"$DR_ROOTS/custom/.git/hooks/pre-commit" && chmod +x "$DR_ROOTS/custom/.git/hooks/pre-commit" || return 1
    doctor
    assert_contains "$OUT" "info     .pre-commit-config.yaml is present but" "a custom hook is not the framework"
}

test_a_repo_local_hooks_path_is_listed_as_info() {
    dr_begin && dr_repo husky || return 1
    gitx -C "$DR_ROOTS/husky" config core.hooksPath .husky/_ || return 1
    doctor
    assert_rc 0 "harmless for config hooks"
    assert_contains "$OUT" "  $DR_REAL/husky
    info     core.hooksPath=.husky/_ in local config ($DR_REAL/husky/.git/config); harmless, config hooks run whatever it says" "listed so the user can see it"
    assert_contains "$OUT" "summary: 1 repos, 1 covered" "covered"
    assert_not_contains "$OUT" "PROBLEM" "no machine problem"
}

# ^ invariant a value doctor cuts ends with "…" (U+2026), a fitting value stays whole => nobody reads cut text as a complete path
test_a_cut_hooks_path_value_ends_with_a_visible_marker() {
    local long exact
    dr_begin && dr_repo wide && dr_repo fits || return 1
    long="$(printf 'a%.0s' $(seq 1 145))"
    exact="$(printf 'b%.0s' $(seq 1 120))"
    gitx -C "$DR_ROOTS/wide" config core.hooksPath "$long" || return 1
    gitx -C "$DR_ROOTS/fits" config core.hooksPath "$exact" || return 1
    doctor
    assert_rc 0 "info alone"
    assert_contains "$OUT" "info     core.hooksPath=${long:0:120}… in local config ($DR_REAL/wide/.git/config)" "the first 120 characters, then the marker"
    assert_not_contains "$OUT" "${long:0:121}" "and nothing past the cut"
    assert_contains "$OUT" "info     core.hooksPath=$exact in local config ($DR_REAL/fits/.git/config)" "a value of exactly the limit is printed whole"
    assert_not_contains "$OUT" "${exact}…" "without a marker"
}

run_file_tests
