#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup.sh"

# ^ external the apt module is Linux package-manager code; Windows has its own module and test file
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Linux package manager flows"; fi

BAD_FPR=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
PINNED_FPR=F911AB184317630C59970973E363C90F8F1B6217
NOBLE_STOCK="1:2.43.0-1ubuntu7.3"
NOBLE_PPA="1:2.56.0-0ppa1~ubuntu24.04.2"

apt_calls() { gu_log | grep -E '^(apt-get|add-apt-repository) ' | grep -v -- '--help' | sed -E 's/ -o DPkg::Lock::Timeout=[0-9]+//'; }
ppa_files() { find "$GU_ROOT/etc/apt" -name 'git-core*ppa*' | LC_ALL=C sort; }

# ^ invariant gua_mismatch FORM leaves a machine whose PPA key is not the pin, in the file form FORM
gua_mismatch() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" && gu_apt_fixture "$1" "$BAD_FPR"
}

test_a_ppa_that_cannot_be_disabled_stops_the_upgrade_without_a_source_build_or_a_root_apt_install() {
    local form
    for form in sources list; do
        gua_mismatch "$form" || return 1
        printf 'rm -f' >"$SANDBOX/sudo.failon" || return 1
        gsg install --upgrade-git </dev/null
        assert_rc 1 "[$form] a key mismatch and files that cannot be removed"
        assert_contains "$ERR" "cannot remove the git-core PPA" "[$form] the removal failure is named"; assert_contains "$ERR" "may still be enabled" "[$form] and the message says the PPA may still be enabled"
        assert_contains "$ERR" "git-core-ubuntu-ppa" "[$form] and names what to remove by hand"
        assert_not_contains "$(gu_log)" "make " "[$form] no source build"
        assert_not_contains "$(apt_calls)" "build-essential" "[$form] no root apt install of the build dependencies"
        assert_not_contains "$(apt_calls)" "update | ppa-files=1" "[$form] no update ran with the unchecked PPA"
        assert_not_contains "$(apt_calls)" "no-install-recommends git" "[$form] nothing was installed"
        [ -n "$(ppa_files)" ] || fail "[$form] control: the files really stayed"
        assert_no_file "$LC_STATE" "[$form] install did not go on"
    done
}

test_a_refresh_that_fails_after_the_removal_also_stops_the_upgrade() {
    gua_mismatch sources || return 1
    printf 'clean' >"$SANDBOX/apt.update.fail" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "the files are gone but apt cannot refresh its lists without the PPA"
    assert_contains "$ERR" "could not refresh" "the failure is named, and it does not claim the PPA may still be enabled"
    assert_empty "$(ppa_files)" "control: the files were removed"
    assert_not_contains "$(gu_log)" "make " "no source build"
    assert_not_contains "$(apt_calls)" "build-essential" "and no root apt install of the build dependencies"
}

test_a_failing_add_apt_repository_that_left_files_behind_removes_them_before_any_apt_call() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    printf '1' >"$SANDBOX/apt.add.rc" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows"
    assert_contains "$ERR" "add-apt-repository failed" "the output says why"
    assert_empty "$(ppa_files)" "the files the failed add left are removed"
    assert_not_contains "$(apt_calls)" "update | ppa-files=1" "no apt update ran while they existed"
    assert_not_contains "$(apt_calls)" "no-install-recommends git" "nothing was installed from the PPA"
    assert_contains "$(apt_calls)" "apt-get update | ppa-files=0" "the lists were refreshed without it"
}

test_a_failing_add_apt_repository_that_wrote_nothing_needs_no_removal_and_no_refresh() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    : >"$SANDBOX/apt.add.nowrite" && printf '1' >"$SANDBOX/apt.add.rc" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows"
    assert_contains "$ERR" "add-apt-repository failed" "the output says why"
    assert_not_contains "$(gu_log)" "sudo -- $SANDBOX/pathbin/rm" "no removal was needed, so none was attempted"
    assert_eq "$(apt_calls | grep -c "apt-get update")" 1 "nothing was added or fetched, so the only update is the one of the source route"
    assert_contains "$(gu_log)" "make " "the source route followed"
}

test_a_failing_apt_install_from_the_ppa_disables_it_and_reports_the_partial_change() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    printf 'no-install-recommends git' >"$SANDBOX/apt.fail" || return 1
    : >"$SANDBOX/make.fail" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "the PPA install fails, then the source build fails too"
    assert_empty "$(ppa_files)" "the PPA is disabled"
    assert_contains "$ERR" "apt-get install git failed" "the PPA failure is named"
    assert_contains "$ERR" "apt-get install git was started and failed" "and said to have maybe changed packages"
    assert_contains "$ERR" "the git-core PPA files this run added were removed again" "and the add and removal are reported"
    assert_contains "$ERR" "the build dependencies were installed" "and so is the dependency install of the fallback"
    assert_not_contains "$ERR" "nothing was changed" "no refusal claims that nothing changed"
}

test_a_failing_software_properties_install_falls_back_to_the_source_route_and_says_why() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_without_sps || return 1
    printf 'software-properties-common' >"$SANDBOX/apt.fail" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows"
    assert_contains "$ERR" "installing software-properties-common and gnupg failed" "the output says why"
    assert_not_contains "$(gu_log)" "add-apt-repository -y" "the PPA was never added"
    assert_contains "$(gu_log)" "make " "the source route followed"
}

test_a_missing_gpg_fails_closed_before_any_update() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_without_sps || return 1
    rm -f -- "$SANDBOX/apt.sps-template/gpg" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows"
    assert_contains "$ERR" "gpg was not found in the system path" "the key could not be checked, and the output says so"
    assert_not_contains "$(apt_calls)" "update | ppa-files=1" "no update ran with the unchecked PPA"
    assert_empty "$(ppa_files)" "the PPA is disabled"
}

test_a_key_file_with_two_keys_or_an_oversized_one_is_not_the_pin() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" "$NOBLE_PPA" || return 1
    gu_apt_fixture list || return 1
    printf 'STUBKEY:%s\nSTUBKEY:%s\n' "$PINNED_FPR" "$BAD_FPR" >"$SANDBOX/apt.fixture/list/trusted.gpg.d/git-core-ubuntu-ppa.gpg" || return 1
    gsg install --upgrade-git </dev/null
    assert_contains "$ERR" "not the pinned one" "a second key beside the pin is refused"
    assert_not_contains "$(apt_calls)" "update | ppa-files=1" "no update ran"
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" "$NOBLE_PPA" || return 1
    gu_apt_fixture list || return 1
    head -c 1100000 /dev/zero >"$SANDBOX/apt.fixture/list/trusted.gpg.d/git-core-ubuntu-ppa.gpg" || return 1
    gsg install --upgrade-git </dev/null
    assert_contains "$ERR" "is larger than" "an oversized key file is refused unread"
}

test_a_sources_file_with_a_signed_by_path_and_no_embedded_key_is_not_the_pin() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/git-core/ppa/ubuntu/\nSuites: noble\nComponents: main\nSigned-By: /usr/share/keyrings/other.gpg\n' \
        >"$SANDBOX/apt.fixture/sources/sources.list.d/git-core-ubuntu-ppa-noble.sources" || return 1
    gsg install --upgrade-git </dev/null
    assert_contains "$ERR" "gpg failed" "no embedded key gives gpg nothing to read, which is a failure and not a match"
    assert_empty "$(ppa_files)" "the file is removed"
}

test_a_list_file_without_its_trusted_gpg_d_key_is_refused() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" "$NOBLE_PPA" || return 1
    gu_apt_fixture list || return 1
    rm -f -- "$SANDBOX/apt.fixture/list/trusted.gpg.d/git-core-ubuntu-ppa.gpg" || return 1
    gsg install --upgrade-git </dev/null
    assert_contains "$ERR" "names the PPA but no key file" "a .list file without its key cannot pass"
    assert_empty "$(ppa_files)" "the .list file is removed"
}

test_a_machine_with_no_ppa_files_after_the_add_is_not_a_pass() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    : >"$SANDBOX/apt.add.nowrite" || return 1
    gsg install --upgrade-git </dev/null
    assert_contains "$ERR" "no git-core PPA .sources or .list file found" "an add that wrote nothing cannot be checked, so it fails"
    assert_not_contains "$(apt_calls)" "no-install-recommends git" "nothing was installed from it"
}

# ^ invariant the stand-in add-apt-repository writes the files and sleeps => an INT there must disable the unchecked PPA
test_an_interrupt_before_the_key_check_disables_the_ppa() {
    local pid
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    printf 'x' >"$SANDBOX/apt.add.hang" || return 1
    (setsid env --default-signal=INT env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" install --upgrade-git \
        >"$SANDBOX/int.out" 2>&1 </dev/null & echo $! >"$SANDBOX/int.pid")
    pid="$(<"$SANDBOX/int.pid")"
    gu_poll "$GU_STALL_WAIT_TICKS" test -e "$SANDBOX/apt.add.started" || { kill -KILL -- "-$pid" 2>/dev/null; fail "add-apt-repository never started"; return 1; }
    [ -n "$(ppa_files)" ] || fail "control: the PPA files existed when the interrupt came"
    kill -INT -- "-$pid" 2>/dev/null
    gu_poll "$GU_EXIT_WAIT_TICKS" gu_pid_gone "$pid" || { kill -KILL -- "-$pid" 2>/dev/null; fail "install did not end after SIGINT"; return 1; }
    OUT="$(<"$SANDBOX/int.out")"
    assert_empty "$(ppa_files)" "the unchecked PPA is disabled again"
    assert_contains "$(apt_calls)" "apt-get update | ppa-files=0" "and apt was refreshed without it"
    assert_not_contains "$(apt_calls)" "no-install-recommends git" "nothing was installed"
    assert_contains "$OUT" "interrupted" "the interrupt says what changed"
}

# ^ invariant the real gpg reads both file forms; the stand-in only proves the module's calls, this proves the parser against the colon format of the real tool
# shellcheck disable=SC2016
test_real_gpg_reads_the_fingerprint_of_both_ppa_file_forms() {
    local gh="$SANDBOX/gnupg" fpr real
    local -a gpg
    real="$(type -P gpg)" || skip_test "gpg is not installed"
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    cp -- "$real" "$SANDBOX/pathbin/gpg" || return 1
    gpg=(env -i HOME="$SANDBOX/home" GNUPGHOME="$gh" PATH="/usr/local/bin:/usr/bin:/bin" "$real" --batch --quiet)
    mkdir -m 700 "$gh" || return 1
    "${gpg[@]}" --pinentry-mode loopback --passphrase '' --quick-generate-key 'gsg test <t@example.invalid>' default default never 2>/dev/null || skip_test "gpg cannot make a key here"
    fpr="$("${gpg[@]}" --with-colons --list-keys | awk -F: '$1 == "fpr" { print $10; exit }')"
    {
        printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/git-core/ppa/ubuntu/\nSuites: noble\nComponents: main\nSigned-By:\n'
        "${gpg[@]}" --armor --export | awk '{ if ($0 == "") print " ."; else print " " $0 }'
    } >"$GU_ROOT/etc/apt/sources.list.d/git-core-ubuntu-ppa-noble.sources"
    env -i GNUPGHOME="$gh" gpgconf --kill gpg-agent 2>/dev/null
    gua_run 'gitup_apt_init || exit 9; GITUP_APT_PPA_FPR="$1"; gitup_apt_ppa_key_matches; rc=$?; printf "%s" "$GITUP_APT_WHY"; exit $rc' "$fpr"
    assert_rc 0 "the armored key embedded in a .sources file has the expected primary fingerprint"
    gua_run 'gitup_apt_init || exit 9; gitup_apt_ppa_key_matches; rc=$?; printf "%s" "$GITUP_APT_WHY"; exit $rc'
    assert_rc 1 "another pinned fingerprint is refused"
    assert_contains "$OUT" "$fpr" "and the fingerprint found is named"
    rm -f -- "$GU_ROOT/etc/apt/sources.list.d/git-core-ubuntu-ppa-noble.sources" || return 1
    printf 'deb https://ppa.launchpadcontent.net/git-core/ppa/ubuntu jammy main\n' >"$GU_ROOT/etc/apt/sources.list.d/git-core-ubuntu-ppa-jammy.list" || return 1
    "${gpg[@]}" --export >"$GU_ROOT/etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg" || return 1
    env -i GNUPGHOME="$gh" gpgconf --kill gpg-agent 2>/dev/null
    gua_run 'gitup_apt_init || exit 9; GITUP_APT_PPA_FPR="$1"; gitup_apt_ppa_key_matches; rc=$?; printf "%s" "$GITUP_APT_WHY"; exit $rc' "$fpr"
    assert_rc 0 "the binary keyring of the .list form has the expected primary fingerprint"
    gua_run 'gitup_apt_init || exit 9; gitup_apt_ppa_key_matches; rc=$?; printf "%s" "$GITUP_APT_WHY"; exit $rc'
    assert_rc 1 "and another pin is refused for it too"
}

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

# shellcheck disable=SC2016
test_the_pinned_fingerprint_is_the_one_in_the_docs_and_the_module() {
    gua_run 'printf "%s" "$GITUP_APT_PPA_FPR"'
    assert_eq "$OUT" F911AB184317630C59970973E363C90F8F1B6217 "the module pins the fingerprint of the PPA"
    assert_contains "$(<"$GSG_PROJECT/docs/platforms.md")" "F911AB184317630C59970973E363C90F8F1B6217" "and the docs state it"
}

run_file_tests
