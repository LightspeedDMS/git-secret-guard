#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

need_network() {
    curl -fsI --max-time 15 -o /dev/null \
        "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz" 2>/dev/null \
        || skip_test "offline: GitHub release downloads are not reachable"
}

# shellcheck disable=SC2016
tl() { run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c 'set -u; source "$1/lib/common.sh" && source "$1/lib/tools.sh" && shift && "$@"' _ "$GSG_PROJECT" "$@"; }

test_real_install_downloads_and_verifies_the_pinned_tarballs_from_github() {
    need_network
    lc_begin || return 1
    if [ "$TEST_OS" = Darwin ]; then lc_real_uname || return 1; fi
    gsg install
    assert_rc 0 "install from the vendor URLs, verified against the shipped tools.lock"
    assert_not_contains "$ERR" "TEST OVERRIDE" "no override was active"
    assert_contains "$("$LC_BIN/trufflehog" --version 2>&1)" "3.99.2" "the real trufflehog runs at the pinned version"
    assert_contains "$("$LC_BIN/gitleaks" version 2>&1)" "8.30.1" "the real gitleaks runs at the pinned version"
    assert_eq "$(state_value tools_installed_by_us)" "trufflehog gitleaks" "both were downloaded by install"
    gsg status
    assert_rc 0 "status is clean after a real install"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    assert_eq "$(find "$LC_BIN" -mindepth 1 | wc -l)" 0 "the downloaded tools are removed again"
}

test_the_other_platform_rows_of_the_lock_match_the_real_tarballs() {
    need_network
    lc_begin || return 1
    local lock="$GSG_PROJECT/tools.lock" dest="$SANDBOX/real-dl" tool plat ver sha mine
    mkdir -p -- "$dest" || return 1
    for tool in trufflehog gitleaks; do
        mine="$(lc_platform "$tool")" || return 1
        while read -r _ ver plat sha; do
            if [ "$plat" = "$mine" ]; then continue; fi
            tl tools_fetch_verified "$tool" "$ver" "$plat" "$sha" "$dest"
            assert_rc 0 "$tool $ver $plat matches its row in tools.lock"
            rm -f -- "$OUT" || return 1
        done < <(grep -E "^$tool [0-9.]+ (linux|darwin)_" "$lock")
    done
}

run_file_tests
