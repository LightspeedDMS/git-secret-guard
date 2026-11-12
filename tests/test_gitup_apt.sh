#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup.sh"

# ^ external the apt module is Linux package-manager code; Windows has its own module and test file
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Linux package manager flows"; fi

PPA_FPR=F911AB184317630C59970973E363C90F8F1B6217
NOBLE_STOCK="1:2.43.0-1ubuntu7.3"
NOBLE_PPA="1:2.56.0-0ppa1~ubuntu24.04.2"
JAMMY_STOCK="1:2.34.1-1ubuntu1.11"
JAMMY_PPA="1:2.56.0-0ppa1~ubuntu22.04.1"

# ^ invariant the apt-get calls of the stand-in log, in order, one per line
apt_calls() { gu_log | grep -E '^(apt-get|add-apt-repository) ' | grep -v -- '--help' | sed -E 's/ -o DPkg::Lock::Timeout=[0-9]+//'; }
ppa_files() { find "$GU_ROOT/etc/apt" -name 'git-core*ppa*' | LC_ALL=C sort; }
path_git_version() { "$SANDBOX/pathbin/git" --version; }

gua_every_plan_line_is_absolute() {
    local line
    while IFS= read -r line; do
        assert_contains "$line" "as root: /" "an absolute tool path: ${line:0:90}"
    done < <(grep -E '^  as root: ' <<<"$1")
}

test_ubuntu_2404_with_stock_git_takes_the_ppa_and_install_continues() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "install --upgrade-git on Ubuntu 24.04"
    assert_contains "$OUT" "route: ppa" "the plan names the PPA route"
    assert_contains "$OUT" "ppa:git-core/ppa" "and the PPA"
    assert_contains "$OUT" "$PPA_FPR" "and its pinned key fingerprint"
    gua_every_plan_line_is_absolute "$OUT"
    assert_contains "$OUT" "-y -n ppa:git-core/ppa" "the plan lists add-apt-repository with -n"
    assert_contains "$OUT" " update" "the plan lists apt-get update"
    assert_contains "$OUT" "install -y --no-install-recommends git" "and apt-get install git"
    assert_eq "$(path_git_version)" "git version 2.56.0" "git on PATH is the package from the PPA"
    assert_not_contains "$(gu_log)" "make " "no source build ran"
    assert_file "$LC_STATE/state" "install ran to the end"
    assert_not_contains "$ERR" "warning: $SANDBOX" "no warning about an old git of the sandbox machine (the test host's own /usr/bin/git may still warn; the container run proves the real case)"
    assert_eq "$(apt_calls | sed -E 's/ \| .*//')" $'add-apt-repository -y -n ppa:git-core/ppa\napt-get update\napt-get install -y --no-install-recommends git' \
        "the order is add, update, install (the key check sits between add and update)"
    assert_contains "$(apt_calls)" "add-apt-repository -y -n ppa:git-core/ppa | ppa-files=0" "nothing existed before the add"
    assert_contains "$(apt_calls)" "apt-get update | ppa-files=1" "the update ran with the verified PPA enabled"
    assert_contains "$(gu_log)" "gpg --batch --show-keys --with-colons | scratch-home" "the key was read with a scratch GNUPGHOME"
    check_plan_matches_log "$OUT" "the PPA route"
}

test_ubuntu_2204_with_the_older_list_form_checks_the_key_in_trusted_gpg_d() {
    gu_apt_setup 2.34.1 ubuntu "$JAMMY_STOCK" "$JAMMY_PPA" || return 1
    gu_apt_fixture list || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "install --upgrade-git on Ubuntu 22.04"
    assert_eq "$(path_git_version)" "git version 2.56.0" "git comes from the package"
    assert_not_contains "$(gu_log)" "make " "with no source build"
    assert_contains "$(apt_calls)" "apt-get update | ppa-files=1 ppa-keys=2" "the .list file and the trusted.gpg.d key were present at the update"
    assert_contains "$(gu_log)" "gpg --batch --show-keys --with-colons" "the key file was read"
    assert_file "$GU_ROOT/etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg" "the key stays (the PPA stays enabled for apt upgrade)"
}

test_a_list_form_whose_trusted_gpg_d_key_is_not_the_pin_is_refused_and_the_key_is_removed() {
    gu_apt_setup 2.34.1 ubuntu "$JAMMY_STOCK" "$JAMMY_PPA" || return 1
    gu_apt_fixture list AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows and finishes"
    assert_contains "$ERR" "not the pinned one" "the output says why"
    assert_empty "$(ppa_files)" "the .list file and the trusted.gpg.d key are gone"
    assert_not_contains "$(apt_calls)" "update | ppa-files=1" "no update ran while the unchecked PPA was enabled"
    assert_not_contains "$(apt_calls)" "no-install-recommends git |" "nothing was installed from the PPA"
    assert_contains "$(apt_calls)" "apt-get update | ppa-files=0 ppa-keys=0" "apt was refreshed without the PPA"
    assert_contains "$(gu_log)" "make " "and the source route followed"
    assert_eq "$("$GU_ROOT/usr/local/bin/git" --version)" "git version 2.56.0" "git is the pinned build in /usr/local"
}

test_a_key_mismatch_in_the_sources_form_never_reaches_an_apt_install() {
    local last_update before_deps
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_fixture sources AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route follows and finishes"
    assert_contains "$ERR" "the PPA signing key fingerprint in git-core-ubuntu-ppa-noble.sources is [AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA], not the pinned one" "the output says why"
    assert_empty "$(ppa_files)" "the sources file is removed"
    assert_not_contains "$(apt_calls)" "update | ppa-files=1" "no update ran while it was enabled"
    assert_not_contains "$(apt_calls)" "no-install-recommends git |" "nothing was installed from it"
    before_deps="$(apt_calls | awk '/build-essential/ { exit } { print }')"
    last_update="$(tail -n 1 <<<"$before_deps")"
    assert_contains "$last_update" "apt-get update | ppa-files=0" "apt was refreshed before any further apt install (the build dependencies)"
    assert_contains "$(gu_log)" "make " "the source route follows"
}

test_a_ppa_that_lags_below_the_floor_is_not_accepted() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "1:2.50.1-0ppa1~ubuntu20.04.1" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route finishes"
    assert_contains "$ERR" "below 2.54" "the output says the PPA lags"
    assert_not_contains "$(apt_calls)" "no-install-recommends git |" "no apt install of git ran from the PPA"
    assert_empty "$(ppa_files)" "the PPA is disabled"
    assert_contains "$(apt_calls)" "apt-get update | ppa-files=0" "and apt refreshed"
    assert_contains "$(gu_log)" "make " "the source route followed"
}

test_a_release_the_ppa_does_not_carry_disables_it_and_the_source_route_follows() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    printf 'ppa' >"$SANDBOX/apt.update.fail" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the source route finishes"
    assert_contains "$ERR" "apt-get update failed with the PPA enabled" "the output says why"
    assert_empty "$(ppa_files)" "the PPA is disabled"
    assert_not_contains "$(apt_calls)" "no-install-recommends git |" "no install from the PPA"
    assert_contains "$(gu_log)" "make " "the source route followed"
}

test_distribution_candidate_new_enough_upgrades_from_the_distribution_and_adds_no_ppa() {
    gu_apt_setup 2.43.0 ubuntu "1:2.55.0-1ubuntu1" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "package route"
    assert_contains "$OUT" "route: package" "the plan names the package route"
    assert_not_contains "$OUT" "ppa:git-core/ppa" "no PPA in the plan"
    assert_not_contains "$(gu_log)" "add-apt-repository" "no PPA was added"
    assert_not_contains "$(gu_log)" "gpg " "and no key was read"
    assert_contains "$(apt_calls)" "apt-get install -y --no-install-recommends git" "git was installed from the distribution"
    assert_eq "$(path_git_version)" "git version 2.55.0" "and it is the distribution's"
    check_plan_matches_log "$OUT" "the package route"
}

test_debian_uses_the_pinned_source_build_and_never_tries_a_ppa() {
    gu_apt_setup 2.39.5 debian "1:2.39.5-0+deb12u2" "" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "Debian source route"
    assert_contains "$OUT" "route: source" "the plan names the source route"
    assert_contains "$OUT" "Debian has no PPA" "and says why there is no PPA"
    assert_contains "$OUT" "can upgrade packages that are already installed, and the plan does not count them" "the dependency install says it can upgrade installed packages"
    assert_not_contains "$OUT$ERR" "ppa:git-core" "no PPA is mentioned as a step"
    assert_not_contains "$(gu_log)" "add-apt-repository" "no PPA was attempted"
    assert_contains "$(apt_calls)" "install -y --no-install-recommends build-essential libcurl4-openssl-dev libssl-dev libexpat1-dev zlib1g-dev perl libpcre2-dev xz-utils tar" "the build dependencies come from apt"
    assert_contains "$(gu_log)" "prefix=$GU_ROOT/usr/local NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 USE_LIBPCRE2=1" "the build goes into /usr/local with the proven flags"
    assert_contains "$(gu_log)" "INSTALL_SYMLINKS=1" "git installs its siblings as symlinks, so no hard link ties bin/git to libexec"
    assert_eq "$(grep '^make ' <<<"$(gu_log)" | grep -cF " sysconfdir=$GU_ROOT/etc INSTALL_SYMLINKS=1 ")" 2 "the compile and the install both read the system config from /etc, so /etc/gitconfig still applies (#90)"
    assert_contains "$OUT" "make prefix=$GU_ROOT/usr/local NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 USE_LIBPCRE2=1 sysconfdir=$GU_ROOT/etc INSTALL_SYMLINKS=1" "and the plan prints the make words it runs"
    assert_eq "$("$GU_ROOT/usr/local/bin/git" --version)" "git version 2.56.0" "git is built"
    check_plan_matches_log "$OUT" "the Debian source route"
}

test_debian_with_a_new_enough_candidate_uses_the_package() {
    gu_apt_setup 2.39.5 debian "1:2.55.1-1" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "Debian package route"
    assert_contains "$OUT" "route: package" "the package route"
    assert_not_contains "$(gu_log)" "make " "no build"
}

test_a_derivative_with_id_like_ubuntu_follows_the_ubuntu_route() {
    gu_apt_setup 2.43.0 linuxmint "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_os_release 'ID=linuxmint' 'ID_LIKE="ubuntu debian"' || return 1
    gsg install </dev/null
    assert_rc 1 "no consent, only the plan matters"
    assert_contains "$OUT" "for this ubuntu system" "the class is ubuntu"
    assert_contains "$OUT" "route: ppa" "the plan follows the Ubuntu route"
    assert_contains "$OUT" "ppa:git-core/ppa" "and names the PPA"
}

test_a_rerun_with_a_new_enough_git_does_nothing_to_git() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "first run"
    rm -f -- "$SANDBOX/gitup.log"
    gsg install </dev/null
    assert_rc 0 "second run"
    assert_not_contains "$OUT$ERR" "[y/N]" "no prompt"
    assert_not_contains "$OUT$ERR" "upgrade plan" "no plan"
    assert_empty "$(gu_log | grep -E '^(apt-get|apt-cache|add-apt-repository|gpg|sudo) ')" "no apt, gpg or sudo call"
}

test_without_a_terminal_and_without_the_flag_install_refuses_names_the_flag_and_changes_nothing() {
    local id
    for id in ubuntu debian; do
        gu_apt_setup 2.43.0 "$id" "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
        gsg install </dev/null
        assert_rc 1 "[$id] old git, no terminal, no flag"
        assert_contains "$ERR" "install --upgrade-git" "[$id] names the flag"
        assert_contains "$ERR" "nothing was changed" "[$id] and that nothing was changed"
        assert_no_file "$LC_STATE" "[$id] no state"
        assert_empty "$(ppa_files)" "[$id] no PPA file"
        assert_empty "$(gu_log | grep -E '^(apt-get|add-apt-repository|gpg|sudo) ' | grep -v -- '--help')" "[$id] no privileged or mutating call, only read-only queries"
        assert_contains "$(gu_log)" "apt-cache policy git | locale=C" "[$id] the read-only query ran"
    done
}

test_answering_yes_at_the_prompt_takes_the_ppa() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gsg_pty $'y\n' install
    assert_rc 0 "yes at the prompt"
    assert_contains "$OUT" "Upgrade git now with the plan above?" "the question"
    assert_eq "$(path_git_version)" "git version 2.56.0" "git came from the PPA"
}

test_every_privileged_apt_command_is_noninteractive_under_sudo() {
    local line
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the PPA route"
    while IFS= read -r line; do
        assert_contains "$line" "$SANDBOX/pathbin/env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none " "sudo runs env with the frontend: ${line:0:100}"
    done < <(gu_log | grep -E '^sudo -- .*(apt-get|add-apt-repository)')
    assert_not_contains "$(gu_log | grep '^apt-get ')" "frontend=unset" "every apt-get saw DEBIAN_FRONTEND"
    assert_not_contains "$(gu_log | grep '^apt-get ')" "frontend=dialog" "none ran with a dialog frontend"
    assert_contains "$(gu_log | grep '^apt-get ')" "frontend=noninteractive" "the value arrived under sudo"
}

test_the_stand_in_apt_get_stops_where_a_real_one_would_prompt() {
    gu_apt_setup || return 1
    run_cap env -i PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" "$SANDBOX/pathbin/apt-get" install git
    assert_rc 100 "control: without DEBIAN_FRONTEND and -y the stand-in refuses, so the tests above prove the module sets both"
}

test_a_machine_without_add_apt_repository_installs_software_properties_common_first() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gu_apt_without_sps || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the PPA route"
    assert_contains "$OUT" "install -y --no-install-recommends software-properties-common gnupg" "the plan adds software-properties-common"
    assert_contains "$(apt_calls | sed -n 2p)" "software-properties-common gnupg" "and the install follows the update"
    assert_eq "$(path_git_version)" "git version 2.56.0" "git came from the PPA"
    check_plan_matches_log "$OUT" "the PPA route with software-properties-common"
}

test_a_machine_with_add_apt_repository_does_not_install_software_properties_common() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gsg install --upgrade-git </dev/null
    assert_not_contains "$OUT" "software-properties-common" "not in the plan"
    assert_not_contains "$(gu_log)" "software-properties-common" "and not installed"
}

test_the_candidate_is_read_with_a_fixed_locale_stdin_from_dev_null_and_a_timeout() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" || return 1
    gsg install </dev/null
    assert_contains "$OUT" "apt offers git $NOBLE_STOCK" "the candidate is read under LC_ALL=C (the stand-in translates the label otherwise)"
    assert_not_contains "$(gu_log)" "query-stdin-is-a-terminal" "stdin of the query is not a terminal"
    printf 'x' >"$SANDBOX/apt.hang"
    SECONDS=0
    gsg install </dev/null
    assert_rc 1 "no consent"
    assert_contains "$OUT" "the apt query for git failed or timed out" "a hanging query is named"
    assert_contains "$OUT" "route: ppa" "and the route still follows the rule"
    [ "$SECONDS" -lt 40 ] || fail "the plan took $SECONDS seconds"
}

test_a_candidate_that_is_a_release_candidate_does_not_pass_the_floor() {
    gu_apt_setup 2.43.0 ubuntu "1:2.54.0~rc1-1" || return 1
    gsg install </dev/null
    assert_contains "$OUT" "not a plain release version" "2.54.0~rc1 is named as no release"
    assert_contains "$OUT" "route: ppa" "and does not select the package route"
}

test_apt_versions_are_reduced_to_the_upstream_release() {
    local v want
    gu_apt_setup || return 1
    for v in "1:2.34.1-1ubuntu1.11|2.34.1" "1:2.56.0-0ppa1~ubuntu22.04.1|2.56.0" "2.39.5-0+deb12u2|2.39.5" "1:2.43.0-1ubuntu7.3|2.43.0" "2.54.0|2.54.0" "2.54.0+ds-1|2.54.0" \
        "2.54.0~rc1-1|" "garbage|" "|" "1:|"; do
        want="${v#*|}"
        gua_reply gitup_apt_upstream "${v%%|*}"
        assert_eq "$OUT" "$want" "upstream of [${v%%|*}]"
    done
}

test_no_apt_means_no_route_and_the_usual_refusal() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" || return 1
    rm -f -- "$SANDBOX/pathbin/apt-get" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "no apt-get"
    assert_contains "$ERR" "apt-get, apt-cache or env was not found in the system path" "named"
    assert_contains "$ERR" "config-based hooks need git >= 2.54, install refused" "the usual refusal follows"
}

test_an_empty_ppa_file_is_unverifiable_and_stops_the_route_with_a_reason() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    : >"$GU_ROOT/etc/apt/sources.list.d/git-core-ubuntu-ppa-noble.sources" || return 1
    gsg install </dev/null
    assert_contains "$OUT$ERR" "gpg failed" "real gpg exits 2 on empty input, so the file cannot be checked and the plan says so"
    assert_not_contains "$OUT" "route: " "no route is planned"
    assert_empty "$(apt_calls)" "no apt call ran"
}

test_a_pin_bump_on_an_apt_machine_rebuilds_through_the_same_source_route() {
    gu_apt_setup 2.34.1 ubuntu "$JAMMY_STOCK" || return 1
    gu_old_build 2.55.0 || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "install --upgrade-git over an older build of ours"
    assert_contains "$OUT" "older than the git this version pins" "the rebuild is offered"
    assert_contains "$OUT" "can upgrade packages that are already installed, and the plan does not count them" "the rebuild plan carries the dependency upgrade note too"
    assert_eq "$("$GU_ROOT/usr/local/bin/git" --version)" "git version 2.56.0" "the new build replaced it"
    assert_not_contains "$(gu_log)" "add-apt-repository" "no PPA is involved in a rebuild"
    assert_contains "$(apt_calls)" "install -y --no-install-recommends build-essential" "the dependencies come from apt"
    assert_no_file "$GU_ROOT/usr/local/share/man/man1/obsolete.1" "an obsolete file of the old build is removed"
}

test_a_new_git_in_usr_local_that_is_not_first_on_path_gets_the_path_fix_on_apt_machines() {
    gu_apt_setup 2.34.1 ubuntu "$JAMMY_STOCK" || return 1
    gu_old_build 2.56.0 || return 1
    set_env PATH="$SANDBOX/pathbin:$GU_ROOT/usr/local/bin:$TEST_BASE_PATH"
    gsg install --upgrade-git </dev/null
    assert_rc 1 "a new git is not first on PATH"
    assert_contains "$ERR" "put $GU_ROOT/usr/local/bin first on PATH" "the exact fix"
    assert_not_contains "$(gu_log)" "apt-get" "no apt call"
}

test_a_failed_package_install_reports_what_may_have_changed() {
    gu_apt_setup 2.43.0 ubuntu "1:2.55.0-1ubuntu1" || return 1
    printf 'no-install-recommends git' >"$SANDBOX/apt.fail" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "the package install fails"
    assert_contains "$ERR" "the git upgrade failed" "says so"
    assert_contains "$ERR" "apt-get install git was started and failed" "and what may have changed"
    assert_not_contains "$ERR" "nothing was changed" "no claim that nothing changed"
}

test_the_unattended_flag_path_never_reads_the_terminal_for_a_query() {
    gu_apt_setup 2.43.0 ubuntu "$NOBLE_STOCK" "$NOBLE_PPA" || return 1
    gsg install --upgrade-git </dev/null
    assert_not_contains "$(gu_log)" "query-stdin-is-a-terminal" "the apt-cache query had a closed stdin"
}

test_the_module_never_pipes_apt_output_into_an_early_exiting_reader() {
    local f="$GSG_PROJECT/lib/gitup_apt.sh"
    assert_eq "$(grep -cE '\| *(sed|head|grep -m|awk)[^|]*(q|-n *[0-9]|exit)' "$f")" 0 "no pipe into sed q, head or awk exit (the pipefail race)"
    assert_eq "$(grep -cE 'git-core-ubuntu-ppa' "$GSG_PROJECT/tests/platform/ubuntu-container.sh")" 0 "the container script holds no copy of the PPA file logic"
}

run_file_tests
