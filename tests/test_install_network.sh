#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

need_network() {
    curl -fsI --max-time 15 -o /dev/null \
        "https://github.com/betterleaks/betterleaks/releases/download/v1.9.0/betterleaks_1.9.0_linux_x64.tar.gz" 2>/dev/null \
        || skip_test "offline: GitHub release downloads are not reachable"
}

# shellcheck disable=SC2016
tl() { run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c 'set -u; source "$1/lib/common.sh" && source "$1/lib/tools.sh" && shift && "$@"' _ "$GSG_PROJECT" "$@"; }

# ^ invariant drops the git upgrade overrides lc_begin puts into LC_ENV (os-release, system paths, build PATH, query timeout); a real run has none
without_gitup_overrides() {
    local e
    local -a keep=()
    for e in "${LC_ENV[@]}"; do
        case "$e" in GSG_OS_RELEASE=* | GSG_GITUP_*) ;; *) keep+=("$e") ;; esac
    done
    LC_ENV=("${keep[@]}")
}

test_real_install_downloads_and_verifies_the_pinned_tarballs_from_github() {
    need_network
    lc_begin || return 1
    without_gitup_overrides
    if [ "$TEST_OS" = Darwin ]; then lc_real_uname || return 1; fi
    gsg install
    assert_rc 0 "install from the vendor URLs, verified against the shipped tools.lock"
    assert_not_contains "$ERR" "TEST OVERRIDE" "no override was active"
    assert_contains "$("$LC_BIN/trufflehog$LC_EXE" --version 2>&1)" "3.99.2" "the real trufflehog runs at the pinned version"
    assert_contains "$("$LC_BIN/betterleaks$LC_EXE" version 2>&1)" "1.9.0" "the real betterleaks runs at the pinned version"
    assert_eq "$(state_value tools_installed_by_us)" "trufflehog betterleaks" "both were downloaded by install"
    gsg status
    assert_rc 0 "status is clean after a real install"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    assert_eq "$(find "$LC_BIN" -mindepth 1 | wc -l)" 0 "the downloaded tools are removed again"
}

# ^ why a fake uname, not the host's; the .exe name and the tar choice follow the host, a linux or darwin archive holds a plain name
# ^ invariant arguments tool version platform archive-sha256 dir; fetch, extract and binary check as install runs them, against the lock's fifth column
# shellcheck disable=SC2016
tl_target() {
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c 'set -u
uname() { echo Linux; }
source "$1/lib/common.sh" && source "$1/lib/tools.sh" && source "$1/lib/install_tools.sh" || exit 9
tool="$2" ver="$3" plat="$4" sha="$5" dir="$6"
tarball="$(tools_fetch_verified "$tool" "$ver" "$plat" "$sha" "$dir")" || exit 1
mkdir -p -- "$dir/out-$plat" && tools_extract_binary "$tarball" "$tool" "$dir/out-$plat" || exit 2
want="$(tools_lock_binary_sha "$1/tools.lock" "$tool" "$plat")" || exit 3
if [ -z "$want" ]; then echo "no binary hash for $tool $plat" >&2; exit 4; fi
install_check_binary_sha "$tool" "$dir/out-$plat/$tool" "$want" || exit 5' _ "$GSG_PROJECT" "$@"
}

test_the_other_platform_rows_of_the_lock_match_the_real_tarballs() {
    need_network
    lc_begin || return 1
    local lock="$GSG_PROJECT/tools.lock" dest="$SANDBOX/real-dl" tool plat ver sha mine
    mkdir -p -- "$dest" || return 1
    for tool in trufflehog betterleaks; do
        mine="$(lc_platform "$tool")" || return 1
        while read -r _ ver plat sha _; do
            if [ "$plat" = "$mine" ]; then continue; fi
            tl_target "$tool" "$ver" "$plat" "$sha" "$dest"
            assert_rc 0 "$tool $ver $plat: the archive and the extracted binary match their row in tools.lock"
            rm -rf -- "$dest" && mkdir -p -- "$dest" || return 1
        done < <(grep -E "^$tool [0-9.]+ (linux|darwin)_" "$lock")
    done
}

run_file_tests
