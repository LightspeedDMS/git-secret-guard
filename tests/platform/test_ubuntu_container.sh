#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/gitup.sh"

# ^ external the container script wraps the apt module, Linux package-manager code; Windows has its own module and test file
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Linux package manager flows"; fi

BAD_FPR=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
NOBLE_STOCK="1:2.43.0-1ubuntu7.3"
NOBLE_PPA="1:2.56.0-0ppa1~ubuntu24.04.2"

apt_calls() { gu_log | grep -E '^(apt-get|add-apt-repository) ' | grep -v -- '--help' | sed -E 's/ -o DPkg::Lock::Timeout=[0-9]+//'; }
ppa_files() { find "$GU_ROOT/etc/apt" -name 'git-core*ppa*' | LC_ALL=C sort; }

# ^ invariant gua_container_ppa runs install_git_ppa of the container script (the wrapper over the product) against the stand-ins; RC and OUT hold its result
# shellcheck disable=SC2016
gua_container_ppa() {
    mkdir -p -- "$SANDBOX/ctr-log" || return 1
    printf '#!/bin/sh\nprintf "1:2.56.0-0ppa1~ubuntu24.04.2"\n' >"$SANDBOX/pathbin/dpkg-query" && chmod 755 "$SANDBOX/pathbin/dpkg-query" || return 1
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" bash -c 'source "$1"; LOGDIR="$2"; install_git_ppa; rc=$?; printf "desc=%s\n" "$GIT_SOURCE_DESC"; exit $rc' \
        _ "$GSG_PROJECT/tests/platform/ubuntu-container.sh" "$SANDBOX/ctr-log"
}

test_the_container_wrapper_returns_0_when_the_ppa_gives_git_and_records_where_it_came_from() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gua_container_ppa
    assert_rc 0 "the product route ran through the wrapper"
    assert_contains "$OUT" "desc=PPA ppa:git-core/ppa, package 1:2.56.0-0ppa1~ubuntu24.04.2" "the summary line names the PPA and the package"
    assert_eq "$(apt_calls | sed -E 's/ \| .*//')" $'add-apt-repository -y -n ppa:git-core/ppa\napt-get update\napt-get install -y --no-install-recommends git' "the product order"
}

test_the_container_wrapper_returns_1_after_a_mismatch_and_2_when_the_ppa_cannot_be_removed() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_fixture sources "$BAD_FPR" || return 1
    gua_container_ppa
    assert_rc 1 "a key that is not the pinned one is a soft failure, the PPA is gone"
    assert_empty "$(ppa_files)" "the files are removed"
    assert_eq "$(apt_calls | tail -n 1 | sed -E 's/ \| .*//')" "apt-get update" "and the last apt call refreshed the lists"
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_fixture sources "$BAD_FPR" || return 1
    printf 'rm -f' >"$SANDBOX/sudo.failon" || return 1
    gua_container_ppa
    assert_rc 2 "files that cannot be removed: the PPA may still be enabled"
    assert_contains "$OUT" "cannot remove the git-core PPA" "the failure is named"
    assert_not_contains "$(apt_calls)" "install" "nothing was installed"
}

run_file_tests
