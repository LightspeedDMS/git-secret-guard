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
VENDOR_FPR=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
NOBLE_STOCK="1:2.43.0-1ubuntu7.3"
NOBLE_PPA="1:2.56.0-0ppa1~ubuntu24.04.2"

# ^ invariant these tests cover PPA state older than the run (files, keys, entries under other names) and what a failure may touch
apt_calls() { gu_log | grep -E '^(apt-get|add-apt-repository) ' | grep -v -- '--help' | sed -E 's/ -o DPkg::Lock::Timeout=[0-9]+//'; }
ppa_files() { find "$GU_ROOT/etc/apt" -name 'git-core*ppa*' | LC_ALL=C sort; }
aside_dir() { find "$GU_ROOT/var/lib/git-secret-guard" -maxdepth 1 -name 'ppa-aside-*' 2>/dev/null | head -n 1; }

test_a_verified_ppa_that_was_there_before_stays_when_the_install_from_it_fails() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" "$NOBLE_PPA" || return 1
    gu_apt_preexisting list || return 1
    printf 'no-install-recommends git' >"$SANDBOX/apt.fail" || return 1
    : >"$SANDBOX/make.fail" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "the PPA install fails and so does the build that follows"
    assert_eq "$(ppa_files | wc -l | tr -d ' ')" 3 "the user's .list file, key and key backup are still there"
    assert_not_contains "$(gu_log)" "add-apt-repository -y" "a verified PPA is kept, add-apt-repository is not run again"
    assert_not_contains "$(gu_log)" "sudo -- $SANDBOX/pathbin/rm" "nothing was removed"
    assert_not_contains "$OUT$ERR" "was added" "the output never says this run added what was already there"
    assert_not_contains "$OUT$ERR" "files this run added were removed" "and never says it removed it"
    assert_contains "$OUT$ERR" "kept" "the output says the existing PPA was kept"
}

test_a_pre_existing_ppa_with_a_wrong_key_is_moved_aside_and_named_not_deleted() {
    local aside
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_preexisting list "$BAD_FPR" || return 1
    gu_apt_fixture sources || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the fresh PPA route finishes"
    aside="$(aside_dir)"
    [ -n "$aside" ] || { fail "no aside directory below var/lib/git-secret-guard"; return 1; }
    assert_file "$aside/sources.list.d/git-core-ubuntu-ppa-jammy.list" "the old list file is kept in the aside directory"
    assert_file "$aside/trusted.gpg.d/git-core-ubuntu-ppa.gpg" "and so is its key"
    assert_contains "$OUT$ERR" "$aside" "the output names the location"
    assert_eq "$(path_git)" "git version 2.56.0" "git came from the PPA after the fresh check"
    assert_not_contains "$OUT$ERR" "files this run added were removed" "nothing is claimed as removed"
}

path_git() { "$SANDBOX/pathbin/git" --version; }

test_an_older_key_next_to_the_pin_is_not_the_pin_and_is_set_aside() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" "$NOBLE_PPA" || return 1
    gu_apt_preexisting list || return 1
    printf 'STUBKEY:%s\n' "$BAD_FPR" >>"$GU_ROOT/etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg" || return 1
    gu_apt_fixture list || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the route finishes with a fresh keyring"
    assert_contains "$OUT$ERR" "not the pinned one" "a keyring holding the pin and another key is refused: apt trusts every key in it"
    [ -n "$(aside_dir)" ] || fail "the old files were not set aside"
    assert_eq "$(grep -c STUBKEY "$GU_ROOT/etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg")" 1 "the new keyring holds the pin only"
}

test_the_stand_in_imports_into_an_existing_keyring_like_the_real_tool() {
    gu_apt_setup 2.34.1 ubuntu || return 1
    gu_apt_preexisting list "$BAD_FPR" || return 1
    gu_apt_fixture list || return 1
    run_cap env -i PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" "$SANDBOX/pathbin/add-apt-repository" -y -n ppa:git-core/ppa
    assert_eq "$(grep -c STUBKEY "$GU_ROOT/etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg")" 2 "the second import adds a key, it does not replace"
}

test_an_entry_under_another_file_name_is_found_by_its_content() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    printf 'deb https://ppa.launchpadcontent.net/git-core/ppa/ubuntu noble main\n' >"$GU_ROOT/etc/apt/sources.list.d/git-core-ppa-noble.list" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "an entry whose key cannot be checked stops the route"
    assert_contains "$OUT$ERR" "git-core-ppa-noble.list" "the file is named"
    assert_empty "$(apt_calls)" "no apt call ran"
    assert_no_file "$LC_STATE" "nothing was installed"
}

# ^ invariant an rm in front of the sandbox one leaving the file add-apt-repository wrote under another name => only the content scan sees it
# shellcheck disable=SC2016
rm_keeps_extra() {
    printf '#!/bin/sh
for a; do shift; case "$a" in *git-core-ppa-extra*) ;; *) set -- "$@" "$a" ;; esac; done
exec /bin/rm "$@"
' >"$SANDBOX/pathbin/rm" && chmod 755 "$SANDBOX/pathbin/rm"
}

test_a_removal_is_proved_by_content_not_by_file_name() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_fixture sources "$BAD_FPR" || return 1
    : >"$SANDBOX/apt.add.extra" || return 1
    rm_keeps_extra || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "an entry under another name stays after the disable"
    assert_contains "$ERR" "git-core-ppa-extra.list" "the surviving file is named"
    assert_contains "$ERR" "may still be enabled" "and the PPA may really still be enabled"
    assert_not_contains "$(apt_calls)" "build-essential" "no root apt install of the build dependencies"
    assert_not_contains "$(gu_log)" "make " "no source build"
}

test_the_trusted_key_is_checked_in_the_sources_form_too() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    printf 'STUBKEY:%s\n' "$BAD_FPR" >"$SANDBOX/apt.fixture/sources/trusted.gpg.d/git-core-ubuntu-ppa.gpg" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows"
    assert_contains "$ERR" "not the pinned one" "a foreign trusted.gpg.d key beside a pinned .sources file is refused"
    assert_not_contains "$(apt_calls)" "update | ppa-files=1" "no update ran with it trusted"
    assert_empty "$(ppa_files)" "and the key is removed"
}

test_a_wrong_key_and_a_new_enough_candidate_do_not_take_the_package_route() {
    gu_apt_setup 2.43.0 ubuntu "1:2.56.0-0ppa1~ubuntu24.04.2" "$NOBLE_PPA" || return 1
    gu_apt_preexisting sources "$BAD_FPR" || return 1
    printf 'https://ppa.launchpadcontent.net/git-core/ppa/ubuntu noble/main' >"$SANDBOX/apt.origin" || return 1
    gsg install </dev/null
    assert_not_contains "$OUT" "route: package" "the candidate of an unchecked PPA is not trusted"
    assert_contains "$OUT" "route: ppa" "the PPA route is planned"
    assert_contains "$OUT" "moved aside" "and the plan says the old files go aside first"
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the route finishes"
    assert_contains "$(gu_log)" "gpg --batch" "the key was checked before anything was installed from it"
    assert_not_contains "$OUT$ERR" "the distribution's repositories" "no credit to the distribution"
}

test_the_package_route_names_where_the_candidate_comes_from() {
    gu_apt_setup 2.43.0 ubuntu "1:2.55.0-1ubuntu1" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "package route"
    assert_contains "$OUT" "from http://archive.ubuntu.com/ubuntu" "the plan names the origin of the candidate"
    gu_apt_setup 2.43.0 ubuntu "1:2.55.0-1ubuntu1" || return 1
    gu_apt_preexisting sources || return 1
    printf 'https://ppa.launchpadcontent.net/git-core/ppa/ubuntu noble/main' >"$SANDBOX/apt.origin" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "package route over a verified PPA"
    assert_contains "$OUT$ERR" "ppa.launchpadcontent.net" "a candidate from the PPA says so"
    assert_not_contains "$OUT$ERR" "distribution's repositories" "and is not credited to the distribution"
}

test_without_sudo_the_ppa_route_says_to_run_install_as_root_instead_of_listing_commands() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    if [ "$(id -u)" -eq 0 ]; then skip_test "root can elevate"; fi
    rm -f -- "$SANDBOX/pathbin/sudo" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "neither root nor sudo"
    assert_contains "$ERR" "install --upgrade-git" "the way out is named"
    assert_contains "$ERR" "as root" "and it is to run install as root"
    assert_not_contains "$ERR" "add-apt-repository" "the list that would skip the key and floor checks is not printed"
    assert_not_contains "$ERR" "rm -f" "and neither is the placeholder removal"
    assert_empty "$(apt_calls)" "nothing ran"
}

test_without_sudo_the_package_route_still_lists_its_commands() {
    gu_apt_setup 2.43.0 ubuntu "1:2.55.0-1ubuntu1" || return 1
    if [ "$(id -u)" -eq 0 ]; then skip_test "root can elevate"; fi
    rm -f -- "$SANDBOX/pathbin/sudo" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "neither root nor sudo"
    assert_contains "$ERR" "apt-get -o DPkg::Lock::Timeout=120 update" "the list starts with the refresh"
    assert_contains "$ERR" "install -y --no-install-recommends git" "and has the install"
}

test_apt_get_update_comes_before_the_first_install_on_every_route() {
    gu_apt_setup 2.43.0 ubuntu "1:2.55.0-1ubuntu1" || return 1
    gsg install --upgrade-git </dev/null
    assert_eq "$(apt_calls | sed -E 's/ \| .*//')" $'apt-get update\napt-get install -y --no-install-recommends git' "package route: update, install"
    assert_contains "$OUT" " update" "and the plan lists the update"
    check_plan_matches_log "$OUT" "package route"
    gu_apt_setup 2.39.5 debian "1:2.39.5-0+deb12u2" "" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "Debian"
    assert_eq "$(apt_calls | head -n 1 | sed -E 's/ \| .*//')" "apt-get update" "Debian source route: the first apt call is the update"
    assert_contains "$(apt_calls | sed -n 2p)" "install -y --no-install-recommends build-essential" "then the build dependencies"
    check_plan_matches_log "$OUT" "Debian source route"
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_without_sps || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "Ubuntu with software-properties-common missing"
    assert_eq "$(apt_calls | sed -n 1p | sed -E 's/ \| .*//')" "apt-get update" "the software-properties step is preceded by an update"
    assert_contains "$(apt_calls | sed -n 2p)" "software-properties-common" "the install follows it"
}

test_a_failing_gpg_is_a_failure_even_when_the_pin_is_in_its_output() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    printf 'STUBGARBAGE\n' >>"$SANDBOX/apt.fixture/sources/sources.list.d/git-core-ubuntu-ppa-noble.sources" || return 1
    sed -i 's/^ -----END PGP PUBLIC KEY BLOCK-----$/ STUBGARBAGE\n -----END PGP PUBLIC KEY BLOCK-----/' "$SANDBOX/apt.fixture/sources/sources.list.d/git-core-ubuntu-ppa-noble.sources" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows"
    assert_contains "$ERR" "gpg" "the output names gpg as the reason"
    assert_not_contains "$(apt_calls)" "update | ppa-files=1" "the PPA was not accepted"
}

test_may_still_be_enabled_is_said_only_when_a_removal_or_a_file_check_failed() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    : >"$SANDBOX/sudo.fail" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "sudo fails on everything"
    assert_not_contains "$ERR" "may still be enabled" "nothing ran, so nothing may be enabled"
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_fixture sources "$BAD_FPR" || return 1
    printf 'clean' >"$SANDBOX/apt.update.fail" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "the files are gone but the refresh fails"
    assert_not_contains "$ERR" "may still be enabled" "the files were removed, so the PPA is not enabled"
    assert_contains "$ERR" "could not refresh" "the output says what failed"
}

test_a_removal_that_exits_zero_but_leaves_the_file_is_not_a_removal() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_fixture sources "$BAD_FPR" || return 1
    printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/pathbin/rm" && chmod 755 "$SANDBOX/pathbin/rm" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "rm says yes and the file stays"
    assert_contains "$ERR" "may still be enabled" "the PPA is reported as possibly enabled"
    assert_not_contains "$(gu_log)" "make " "no source build"
}

test_a_file_that_cannot_be_removed_stops_the_upgrade() {
    if [ "$(id -u)" -eq 0 ]; then skip_test "root removes files in a read-only directory"; fi
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_fixture sources "$BAD_FPR" || return 1
    : >"$SANDBOX/apt.add.lock" || return 1
    gsg install --upgrade-git </dev/null
    chmod 755 "$GU_ROOT/etc/apt/sources.list.d"
    assert_rc 1 "the directory is read-only after the add"
    assert_contains "$ERR" "may still be enabled" "the PPA may be enabled"
    assert_not_contains "$(gu_log)" "make " "no source build"
}

test_an_apt_query_that_fails_after_the_update_disables_the_ppa() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    : >"$SANDBOX/apt.cache.failafter" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows"
    assert_contains "$ERR" "the apt query for git failed after the update" "the output says why"
    assert_empty "$(ppa_files)" "the PPA is gone"
}

test_an_apt_query_that_fails_at_plan_time_is_named_and_the_route_still_follows_the_rule() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    : >"$SANDBOX/apt.cache.fail" || return 1
    gsg install </dev/null
    assert_contains "$OUT" "the apt query for git failed" "named"
    assert_contains "$OUT" "route: ppa" "and the PPA route is planned"
}

test_linux_mint_style_add_apt_repository_without_n_takes_the_source_route_and_never_runs_it() {
    gu_apt_setup 2.43.0 linuxmint "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_os_release 'ID=linuxmint' 'ID_LIKE="ubuntu debian"' || return 1
    : >"$SANDBOX/apt.add.nonopt" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source build finishes"
    assert_contains "$OUT" "route: source" "the plan takes the source route"
    assert_contains "$OUT" "no -n" "and says why"
    assert_not_contains "$(gu_log)" "add-apt-repository -y" "add-apt-repository was never run to add the PPA"
    assert_empty "$(ppa_files)" "no PPA file exists"
}

test_an_interrupt_prints_a_real_reason_and_removes_only_what_this_run_added() {
    local pid
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    printf 'x' >"$SANDBOX/apt.add.hang" || return 1
    (setsid env --default-signal=INT env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" install --upgrade-git \
        >"$SANDBOX/int.out" 2>&1 </dev/null & echo $! >"$SANDBOX/int.pid")
    pid="$(<"$SANDBOX/int.pid")"
    gu_poll "$GU_STALL_WAIT_TICKS" test -e "$SANDBOX/apt.add.started" || { kill -KILL -- "-$pid" 2>/dev/null; fail "add-apt-repository never started"; return 1; }
    kill -INT -- "-$pid" 2>/dev/null
    gu_poll "$GU_EXIT_WAIT_TICKS" gu_pid_gone "$pid" || { kill -KILL -- "-$pid" 2>/dev/null; fail "install did not end after SIGINT"; return 1; }
    OUT="$(<"$SANDBOX/int.out")"
    assert_contains "$OUT" "route was interrupted by a signal" "the reason is not empty"
    assert_not_contains "$OUT" "the only change made was the git upgrade of this run" "an interrupted upgrade did not upgrade anything"
    assert_contains "$OUT" "left behind by the failed git upgrade" "the summary says what the interrupted attempt left"
    assert_not_contains "$OUT" "failed: "$'\n' "no empty reason"
    assert_empty "$(ppa_files)" "what this run added is removed"
}

test_an_interrupt_with_a_verified_ppa_from_before_removes_nothing() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" "$NOBLE_PPA" || return 1
    gu_apt_preexisting list || return 1
    gu_interrupt_run 'update' 0 INT "$GSG_PROJECT/bin/git-secret-guard" install --upgrade-git || return 1
    assert_eq "$(ppa_files | wc -l | tr -d ' ')" 3 "the user's files are still there"
    assert_not_contains "$OUT" "was added" "and nothing is claimed as added"
    assert_not_contains "$(gu_log)" "sudo -- $SANDBOX/pathbin/rm" "nothing was removed"
}

test_the_plan_of_a_failing_ppa_route_matches_what_sudo_ran() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_fixture sources "$BAD_FPR" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the fallback finishes"
    check_plan_matches_log "$OUT" "the failing PPA route"
}

test_the_plan_says_the_ppa_stays_enabled_and_uninstall_leaves_it() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gsg install </dev/null
    assert_contains "$OUT" "stays enabled" "the plan says the PPA stays enabled"
    assert_contains "$(<"$GSG_PROJECT/docs/platforms.md")" "uninstall" "the docs say what uninstall does"
}

test_a_key_file_alone_a_disabled_entry_and_a_commented_out_entry_are_not_an_enabled_ppa() {
    local case_name src
    for case_name in keyonly disabled off without zeros commented; do
        gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
        case "$case_name" in
            keyonly) printf 'STUBKEY:%s\n' "$PINNED_FPR" >"$GU_ROOT/etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg" || return 1 ;;
            disabled | off | without | zeros)
                gu_apt_preexisting sources || return 1
                src="$GU_ROOT/etc/apt/sources.list.d/git-core-ubuntu-ppa-noble.sources"
                case "$case_name" in disabled) printf 'Enabled: no\n' ;; off) printf 'Enabled: OFF\n' ;; zeros) printf 'Enabled: 00\n' ;; *) printf 'Enabled: without\n' ;; esac >>"$src" || return 1
                ;;
            commented)
                gu_apt_preexisting list || return 1
                src="$GU_ROOT/etc/apt/sources.list.d/git-core-ubuntu-ppa-jammy.list"
                sed -i 's/^deb /# deb /' "$src" || return 1
                ;;
        esac
        gu_apt_fixture sources || return 1
        gsg install </dev/null
        assert_not_contains "$OUT" "is kept" "[$case_name] the plan does not call it a kept PPA"
        assert_contains "$OUT" "moved aside" "[$case_name] the old files go aside"
        gsg install --upgrade-git </dev/null
        assert_rc 0 "[$case_name] a fresh PPA is added"
        assert_contains "$(gu_log)" "add-apt-repository -y -n" "[$case_name] add-apt-repository ran"
        assert_eq "$(path_git)" "git version 2.56.0" "[$case_name] git came from the PPA"
        [ -n "$(aside_dir)" ] || fail "[$case_name] nothing was set aside"
    done
}

test_other_deb822_spellings_of_a_ppa_url_are_found_by_the_content_scan() {
    local spelling
    for spelling in folded joined; do
        gu_apt_setup 2.43.0 ubuntu "1:2.56.0-1ubuntu1" "$NOBLE_PPA" || return 1
        case "$spelling" in
            folded) printf 'Types: deb\nURIs:\n https://ppa.launchpadcontent.net/git-core/ppa/ubuntu/\nSuites: noble\nComponents: main\nSigned-By: /etc/apt/keyrings/other.gpg\n' ;;
            joined) printf 'Types: deb\nURIs:https://ppa.launchpadcontent.net/git-core/ppa/ubuntu/\nSuites: noble\nComponents: main\nSigned-By: /etc/apt/keyrings/other.gpg\n' ;;
        esac >"$GU_ROOT/etc/apt/sources.list.d/my-git.sources"
        gsg install --upgrade-git </dev/null
        assert_rc 1 "[$spelling] an entry whose key cannot be checked stops the route"
        assert_not_contains "$OUT" "route: package" "[$spelling] the candidate does not decide"
        assert_contains "$OUT$ERR" "my-git.sources" "[$spelling] the file is named"
        assert_empty "$(apt_calls)" "[$spelling] no apt call ran"
    done
}

test_the_removal_proof_sees_a_folded_entry_too() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_fixture sources "$BAD_FPR" || return 1
    printf 'Types: deb\nURIs:\n https://ppa.launchpadcontent.net/git-core/ppa/ubuntu/\nSuites: noble\nComponents: main\n' >"$SANDBOX/apt.add.extra" || return 1
    rm_keeps_extra || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "a folded entry under another name stays after the removal"
    assert_contains "$ERR" "git-core-ppa-extra.list" "it is named"
    assert_contains "$ERR" "may still be enabled" "and the PPA may still be enabled"
}

test_a_neighbouring_ppa_name_is_not_the_git_core_ppa() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    printf 'deb https://ppa.launchpadcontent.net/git-core/ppa-next/ubuntu noble main\ndeb https://ppa.launchpadcontent.net/git-core/candidate/ubuntu noble main\n' >"$GU_ROOT/etc/apt/sources.list.d/other.list" || return 1
    gsg install </dev/null
    assert_contains "$OUT" "route: ppa" "other PPAs of the same owner do not stop the route"
}

test_the_rebuild_route_lists_the_aside_commands_it_will_run() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" || return 1
    gu_old_build 2.55.0 || return 1
    gu_apt_preexisting sources "$BAD_FPR" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the rebuild finishes"
    assert_contains "$OUT" "mv -n --" "the plan lists the moves"
    assert_contains "$OUT" "mkdir -p --" "and the directory"
    assert_eq "$(comm -13 <(plan_all_cmds "$OUT") <(sudo_cmds | grep -E '/(mv|mkdir) |apt-get'))" "" "every move, mkdir and apt call sudo ran is in the plan"
    [ -n "$(aside_dir)" ] || fail "the old PPA was set aside"
}

test_the_rebuild_route_refuses_an_entry_it_cannot_check() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" || return 1
    gu_old_build 2.55.0 || return 1
    printf 'deb https://ppa.launchpadcontent.net/git-core/ppa/ubuntu noble main\n' >"$GU_ROOT/etc/apt/sources.list.d/mine.list" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "the flag asked for a rebuild that cannot be done"
    assert_contains "$OUT$ERR" "mine.list" "the entry is named"
    assert_empty "$(gu_log | grep -E '^sudo ')" "no root call ran"
}

test_a_failing_mover_stops_before_any_later_root_apt_call() {
    local what skip
    for what in "mkdir -p|0" "mv -n|0" "mv -n|1"; do
        gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
        gu_apt_preexisting list "$BAD_FPR" || return 1
        printf '%s' "${what%|*}" >"$SANDBOX/sudo.failon" && printf '%s' "${what#*|}" >"$SANDBOX/sudo.skip" || return 1
        skip="$what"
        gsg install --upgrade-git </dev/null
        assert_rc 1 "[$skip] a failing move stops the upgrade"
        assert_contains "$ERR" "aside" "[$skip] the output says what failed"
        assert_empty "$(apt_calls)" "[$skip] no apt call ran after it"
        assert_not_contains "$(gu_log)" "make " "[$skip] no source build"
    done
}

test_a_move_that_exits_zero_and_moves_nothing_stops_the_upgrade() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_preexisting list "$BAD_FPR" || return 1
    printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/pathbin/mv" && chmod 755 "$SANDBOX/pathbin/mv" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "mv says yes and the files stay"
    assert_contains "$ERR" "still in place" "the output says so"
    assert_empty "$(apt_calls)" "no apt call ran"
    assert_not_contains "$(gu_log)" "make " "no source build"
}

test_a_refresh_that_fails_after_the_aside_move_stops_the_upgrade() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_preexisting list "$BAD_FPR" || return 1
    printf 'any' >"$SANDBOX/apt.update.fail" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "the refresh after the move fails"
    assert_contains "$ERR" "could not refresh" "the output says so"
    assert_not_contains "$(apt_calls)" "install" "no apt install ran"
    assert_not_contains "$(gu_log)" "add-apt-repository -y" "no PPA was added"
    assert_not_contains "$(gu_log)" "make " "no source build"
}

test_a_kept_ppa_whose_candidate_lags_goes_through_the_floor_check() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" "1:2.50.1-0ppa1~ubuntu22.04.1" || return 1
    gu_apt_preexisting list || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows"
    assert_contains "$ERR" "below 2.54" "the floor failed"
    assert_not_contains "$(apt_calls)" "no-install-recommends git |" "git was not installed from the lagging PPA"
    assert_eq "$(find "$GU_ROOT/etc/apt/sources.list.d" -name 'git-core-ubuntu-ppa-*' | wc -l | tr -d ' ')" 1 "and the user's PPA is still there"
}

test_the_output_says_how_to_put_the_set_aside_files_back() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_preexisting list "$BAD_FPR" || return 1
    gu_apt_fixture sources || return 1
    gsg install --upgrade-git </dev/null
    assert_contains "$OUT$ERR" "to put them back" "the output says how to restore"
    assert_contains "$OUT$ERR" "mv -n -- $(aside_dir)/sources.list.d/git-core-ubuntu-ppa-jammy.list" "with the real command"
    assert_contains "$(<"$GSG_PROJECT/docs/platforms.md")" "ppa-aside" "the docs name the directory"
    assert_contains "$(<"$GSG_PROJECT/docs/platforms.md")" "uninstall keeps" "and say uninstall keeps it"
}

test_an_interrupt_between_the_two_moves_names_the_aside_directory() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_preexisting list "$BAD_FPR" || return 1
    gu_interrupt_run '/mv -n' 1 INT "$GSG_PROJECT/bin/git-secret-guard" install --upgrade-git || return 1
    assert_contains "$OUT" "ppa-aside-" "the output names the aside directory"
    assert_contains "$OUT" "interrupted" "and says it was interrupted"
}

test_an_unreadable_ppa_file_gets_a_real_reason() {
    if [ "$(id -u)" -eq 0 ]; then skip_test "root reads every file"; fi
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_preexisting sources || return 1
    chmod 000 "$GU_ROOT/etc/apt/sources.list.d/git-core-ubuntu-ppa-noble.sources" || return 1
    gsg install </dev/null
    chmod 644 "$GU_ROOT/etc/apt/sources.list.d/git-core-ubuntu-ppa-noble.sources"
    assert_contains "$OUT$ERR" "cannot read git-core-ubuntu-ppa-noble.sources" "the reason names the file"
    assert_not_contains "$OUT$ERR" "Permission denied" "no raw shell error"
}

test_the_conditional_install_is_marked_so_a_failing_route_matches_its_plan() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_fixture sources "$BAD_FPR" || return 1
    gsg install --upgrade-git </dev/null
    assert_contains "$OUT" "no-install-recommends git  [only when the key and floor checks pass]" "the PPA install is marked"
    check_plan_matches_log "$OUT" "the failing PPA route, both halves"
}

test_an_adopted_ppa_plan_does_not_promise_to_remove_files() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" "$NOBLE_PPA" || return 1
    gu_apt_preexisting list || return 1
    gsg install </dev/null
    assert_contains "$OUT" "is kept" "the plan keeps the PPA"
    assert_not_contains "$OUT" "removed again" "and does not promise to remove files it did not add"
}

test_ubuntu_2004_layout_reaches_the_floor_refusal_and_removes_its_underscore_key() {
    gu_apt_setup 2.25.1 ubuntu "1:2.25.1-1ubuntu3.14" "1:2.50.1-0ppa1~ubuntu20.04.1" || return 1
    gu_apt_fixture focal || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows"
    assert_contains "$ERR" "below 2.54" "the refusal is the floor, as it is on a real focal"
    assert_not_contains "$ERR" "is missing" "the key under the underscore name was found"
    assert_empty "$(ppa_files)" "the .list file and the underscore key are both gone"
    assert_contains "$OUT$ERR" "were removed again (git-core-ubuntu-ppa-focal.list" "the sentence names what was removed"
    assert_contains "$OUT$ERR" "git-core_ubuntu_ppa.gpg" "including the key"
    assert_not_contains "$(apt_calls)" "no-install-recommends git |" "nothing was installed from the PPA"
}

test_a_foreign_key_under_the_underscore_name_is_rejected() {
    gu_apt_setup 2.25.1 ubuntu "1:2.25.1-1ubuntu3.14" "$NOBLE_PPA" || return 1
    gu_apt_fixture focal "$BAD_FPR" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows"
    assert_contains "$ERR" "not the pinned one" "the key was checked"
    assert_not_contains "$(apt_calls)" "update | ppa-files=1" "no update ran while it was trusted"
    assert_empty "$(ppa_files)" "and it is removed"
}

test_the_gpg_backup_beside_the_key_is_removed_with_it() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" "$NOBLE_PPA" || return 1
    gu_apt_fixture list "$BAD_FPR" || return 1
    gsg install --upgrade-git </dev/null
    assert_empty "$(ppa_files)" "the .gpg~ backup is gone too"
    assert_contains "$OUT$ERR" "git-core-ubuntu-ppa.gpg~" "and the sentence names it"
}

test_nothing_is_said_to_be_removed_when_nothing_was_written() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    : >"$SANDBOX/apt.add.nowrite" && printf '1' >"$SANDBOX/apt.add.rc" || return 1
    gsg install --upgrade-git </dev/null
    assert_not_contains "$OUT$ERR" "were removed" "no removal happened, so none is claimed"
}

test_a_kept_ppa_in_the_20_04_layout_is_kept_and_a_wrong_one_is_set_aside_with_its_real_names() {
    gu_apt_setup 2.25.1 ubuntu "1:2.25.1-1ubuntu3.14" "$NOBLE_PPA" || return 1
    gu_apt_preexisting focal || return 1
    gsg install </dev/null
    assert_contains "$OUT" "is kept" "the underscore key counts as the PPA's key"
    gu_apt_setup 2.25.1 ubuntu "1:2.25.1-1ubuntu3.14" "$NOBLE_PPA" || return 1
    gu_apt_preexisting focal "$BAD_FPR" || return 1
    gsg install </dev/null
    assert_contains "$OUT" "git-core_ubuntu_ppa.gpg" "the set-aside plan names the underscore key"
    assert_contains "$OUT" "moved aside" "and moves it"
}

test_the_old_launchpad_host_is_found_by_the_content_scan() {
    gu_apt_setup 2.25.1 ubuntu "1:2.56.0-1ubuntu1" "$NOBLE_PPA" || return 1
    printf 'deb http://ppa.launchpad.net/git-core/ppa/ubuntu focal main\n' >"$GU_ROOT/etc/apt/sources.list.d/other.list" || return 1
    gsg install </dev/null
    assert_contains "$OUT$ERR" "other.list" "the entry on ppa.launchpad.net is found"
    assert_not_contains "$OUT" "route: package" "and the candidate does not decide"
}

test_a_failed_route_and_failed_fallback_do_not_claim_an_upgrade() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    printf 'no-install-recommends git' >"$SANDBOX/apt.fail" || return 1
    : >"$SANDBOX/make.fail" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "both fail"
    assert_not_contains "$ERR" "the only change made was the git upgrade of this run" "nothing was upgraded, so the text must not say so"
    assert_contains "$ERR" "left behind by the failed git upgrade" "it says what the failed attempt left"
}

test_the_rebuild_plan_prints_the_aside_lines_before_the_rebuild_and_a_refusal_prints_no_plan() {
    local plan_at aside_at
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" || return 1
    gu_old_build 2.55.0 || return 1
    gu_apt_preexisting sources "$BAD_FPR" || return 1
    gsg install </dev/null
    aside_at="${OUT%%moved aside*}"
    plan_at="${OUT%%rebuild plan*}"
    [ "${#aside_at}" -lt "${#plan_at}" ] || fail "the aside lines come after the rebuild plan"
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" || return 1
    gu_old_build 2.55.0 || return 1
    printf 'deb https://ppa.launchpadcontent.net/git-core/ppa/ubuntu noble main\n' >"$GU_ROOT/etc/apt/sources.list.d/mine.list" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "refused"
    assert_not_contains "$OUT" "rebuild plan" "a refusal prints no half rebuild plan"
}

test_a_leftover_or_disabled_ppa_does_not_hide_a_new_enough_distribution_candidate() {
    gu_apt_setup 2.43.0 ubuntu "1:2.56.0-1ubuntu1" "$NOBLE_PPA" || return 1
    printf 'STUBKEY:%s\n' "$PINNED_FPR" >"$GU_ROOT/etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the package route finishes"
    assert_contains "$OUT" "route: package" "the distribution's own package is used"
    assert_contains "$OUT" "moved aside" "after the leftover key is set aside"
    assert_not_contains "$(gu_log)" "add-apt-repository -y" "no PPA is added"
    [ -n "$(aside_dir)" ] || fail "the leftover was not set aside"
    assert_eq "$(path_git)" "git version 2.56.0" "git is the distribution's"
}

test_an_unreadable_entry_under_another_name_gets_a_real_reason() {
    if [ "$(id -u)" -eq 0 ]; then skip_test "root reads every file"; fi
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    printf 'deb https://ppa.launchpadcontent.net/git-core/ppa/ubuntu noble main\n' >"$GU_ROOT/etc/apt/sources.list.d/mine.list" || return 1
    chmod 000 "$GU_ROOT/etc/apt/sources.list.d/mine.list" || return 1
    gsg install </dev/null
    chmod 644 "$GU_ROOT/etc/apt/sources.list.d/mine.list"
    assert_contains "$OUT$ERR" "cannot read mine.list" "the reason names the file"
    assert_not_contains "$OUT$ERR" "Permission denied" "and there is no raw shell error"
}

test_the_kept_ppa_plan_says_its_key_was_checked_and_passed() {
    gu_apt_setup 2.34.1 ubuntu "1:2.55.0-1ubuntu1" "$NOBLE_PPA" || return 1
    gu_apt_preexisting list || return 1
    printf 'https://ppa.launchpadcontent.net/git-core/ppa/ubuntu jammy/main' >"$SANDBOX/apt.origin" || return 1
    gsg install </dev/null
    assert_contains "$OUT" "key checked against the pin and passed" "the package route over a kept PPA says so"
}

test_a_file_add_apt_repository_wrote_under_another_name_is_removed_with_the_others() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_fixture sources "$BAD_FPR" || return 1
    : >"$SANDBOX/apt.add.extra" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows, the extra file was this run's own"
    assert_no_file "$GU_ROOT/etc/apt/sources.list.d/git-core-ppa-extra.list" "it is removed"
    assert_contains "$OUT$ERR" "git-core-ppa-extra.list" "and named in the removal sentence"
}

# ^ invariant neighbour_fixture adds a vendor source file and a vendor key to what add-apt-repository writes, as a neighbour process would during the add
neighbour_fixture() {
    printf 'deb https://vendor.example.invalid/apt stable main\n' >"$SANDBOX/apt.fixture/list/sources.list.d/vendor.list" || return 1
    printf 'STUBKEY:%s\n' "$VENDOR_FPR" >"$SANDBOX/apt.fixture/list/trusted.gpg.d/vendor.gpg" || return 1
}

test_a_new_key_under_an_unknown_name_that_holds_the_pin_is_the_ppas_and_goes_with_it() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" "$NOBLE_PPA" || return 1
    gu_apt_fixture list || return 1
    mv -- "$SANDBOX/apt.fixture/list/trusted.gpg.d/git-core-ubuntu-ppa.gpg" "$SANDBOX/apt.fixture/list/trusted.gpg.d/odd-name.gpg" || return 1
    printf 'no-install-recommends git' >"$SANDBOX/apt.fail" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows"
    assert_no_file "$GU_ROOT/etc/apt/trusted.gpg.d/odd-name.gpg" "the key holding the pin is the PPA's, so it is removed"
    assert_contains "$OUT$ERR" "odd-name.gpg" "and named"
}

test_a_neighbours_new_files_are_never_removed_and_do_not_fail_a_good_ppa() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" "$NOBLE_PPA" || return 1
    gu_apt_fixture list || return 1
    neighbour_fixture || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "a good PPA is installed"
    assert_eq "$(path_git)" "git version 2.56.0" "git came from the PPA"
    assert_file "$GU_ROOT/etc/apt/trusted.gpg.d/vendor.gpg" "the vendor key is untouched"
    assert_file "$GU_ROOT/etc/apt/sources.list.d/vendor.list" "and so is the vendor source file"
    assert_contains "$ERR" "vendor.gpg" "the output names what was left alone"
}

test_on_a_failing_route_a_neighbours_files_stay_and_an_unjudged_key_stops_the_upgrade() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" "$NOBLE_PPA" || return 1
    gu_apt_fixture list "$BAD_FPR" || return 1
    neighbour_fixture || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "a new key that cannot be judged stops the upgrade"
    assert_file "$GU_ROOT/etc/apt/trusted.gpg.d/vendor.gpg" "the vendor key is not deleted"
    assert_file "$GU_ROOT/etc/apt/sources.list.d/vendor.list" "nor the vendor source file"
    assert_not_contains "$(gu_log)" "vendor" "no root command names a vendor file"
    assert_contains "$ERR" "vendor.gpg" "the key is named"
    assert_contains "$ERR" "cannot tell" "with the reason"
    assert_empty "$(ppa_files)" "the files that are provably the PPA's were removed"
    assert_not_contains "$(gu_log)" "make " "no source build while a key cannot be judged"
}

test_an_interrupt_leaves_a_neighbours_files_alone_too() {
    local pid
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_fixture list || return 1
    neighbour_fixture || return 1
    printf 'x' >"$SANDBOX/apt.add.hang" || return 1
    (setsid env --default-signal=INT env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" install --upgrade-git \
        >"$SANDBOX/int.out" 2>&1 </dev/null & echo $! >"$SANDBOX/int.pid")
    pid="$(<"$SANDBOX/int.pid")"
    gu_poll "$GU_STALL_WAIT_TICKS" test -e "$SANDBOX/apt.add.started" || { kill -KILL -- "-$pid" 2>/dev/null; fail "add-apt-repository never started"; return 1; }
    kill -INT -- "-$pid" 2>/dev/null
    gu_poll "$GU_EXIT_WAIT_TICKS" gu_pid_gone "$pid" || { kill -KILL -- "-$pid" 2>/dev/null; fail "install did not end after SIGINT"; return 1; }
    OUT="$(<"$SANDBOX/int.out")"
    assert_empty "$(ppa_files)" "what is provably the PPA's is removed"
    assert_file "$GU_ROOT/etc/apt/trusted.gpg.d/vendor.gpg" "the vendor key stays"
    assert_file "$GU_ROOT/etc/apt/sources.list.d/vendor.list" "and so does the vendor source file"
    assert_not_contains "$(gu_log)" "vendor" "no root command names a vendor file"
    assert_contains "$OUT" "vendor.gpg" "the output names the key it left"
    assert_contains "$OUT" "route was interrupted by a signal" "the wording says what happened"
}

test_install_keeps_a_stricter_umask_of_the_caller() {
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then skip_test "NTFS has no unix modes"; fi
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    run_cap bash -c 'umask 077; exec "$@"' _ env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" install
    assert_rc 0 "install under umask 077"
    assert_eq "$(stat -c %a "$LC_DATA/settings")" 600 "the caller's stricter umask is kept for the settings file"
}

test_a_large_new_file_in_trusted_gpg_d_is_not_fed_to_gpg_and_is_left_alone() {
    gu_apt_setup 2.34.1 ubuntu "1:2.34.1-1ubuntu1.11" "$NOBLE_PPA" || return 1
    gu_apt_fixture list || return 1
    head -c 1100000 /dev/zero >"$SANDBOX/apt.fixture/list/trusted.gpg.d/big-vendor.gpg" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "a good PPA is installed"
    assert_file "$GU_ROOT/etc/apt/trusted.gpg.d/big-vendor.gpg" "the large file is left alone"
    assert_contains "$ERR" "big-vendor.gpg" "and named"
    assert_eq "$(gu_log | grep -c '^gpg ')" 1 "gpg read the PPA key only, not the large file"
}

run_file_tests
