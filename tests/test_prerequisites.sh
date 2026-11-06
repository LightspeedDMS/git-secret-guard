#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

# ^ external these pin the apt, PPA and os-release hints of Linux; on Windows the hints and the jq download differ, test_windows.sh covers them
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Linux package manager hints"; fi

UBUNTU_FIX="sudo add-apt-repository ppa:git-core/ppa && sudo apt install git"

# ^ external install reads the distribution from GSG_OS_RELEASE, default /etc/os-release; the tests point it at fixtures
# ^ why the system paths move into the sandbox too, not only os-release; a git in the real /usr/local/bin would change the refusal under test
os_release() {
    mkdir -p -- "$SANDBOX/root/usr/bin" "$SANDBOX/root/usr/local/bin" && printf '%s\n' "$@" >"$SANDBOX/os-release" && set_env GSG_OS_RELEASE="$SANDBOX/os-release" GSG_GITUP_ROOT="$SANDBOX/root"
}

# ^ why a sandbox root, not the real /usr/local; WSL Rocky with its own build in place got the path-fix refusal (run 42278541531)
apt_root() { set_env GSG_GITUP_ROOT="$SANDBOX/gitup-root"; }

ubuntu_release() { os_release 'NAME="Ubuntu"' 'ID=ubuntu' 'ID_LIKE=debian' 'VERSION_ID="24.04"' && apt_root; }

nothing_changed() {
    assert_no_file "$LC_STATE" "$1: no state"
    assert_no_file "$LC_DATA" "$1: no share dir"
    assert_no_file "$LC_BIN" "$1: no tools"
    assert_eq "$(gitx config --global --get-regexp '^hook\.git-secret-guard\.' | wc -l)" 0 "$1: no hook config"
}

test_an_old_git_on_ubuntu_names_the_ppa_command_and_changes_nothing() {
    lc_begin && lc_fake_git 2.43.0 && ubuntu_release || return 1
    gsg install
    assert_rc 1 "git 2.43.0 is too old"
    assert_contains "$ERR" "git 2.43.0; config-based hooks need git >= 2.54, install refused" "the existing refusal"
    assert_contains "$ERR" "$UBUNTU_FIX" "the exact command"
    assert_contains "$ERR" "software-properties-common" "and the package add-apt-repository comes from"
    assert_contains "$ERR" "install --upgrade-git" "and the offer that does it for you"
    assert_contains "$ERR" "see docs/platforms.md" "and where the build path is described"
    nothing_changed "old git on ubuntu"
}

test_a_missing_git_on_ubuntu_names_the_same_command() {
    lc_begin && lc_path_without git && ubuntu_release || return 1
    gsg install
    assert_rc 1 "no git on PATH"
    assert_contains "$ERR" "git is not on PATH" "the existing refusal"
    assert_contains "$ERR" "$UBUNTU_FIX" "the exact command"
    nothing_changed "no git on ubuntu"
}

test_ubuntu_derivatives_are_recognised_through_ID_LIKE() {
    lc_begin && lc_fake_git 2.43.0 && os_release 'NAME="Linux Mint"' 'ID=linuxmint' 'ID_LIKE="ubuntu debian"' && apt_root || return 1
    gsg install
    assert_rc 1 "old git on a derivative"
    assert_contains "$ERR" "$UBUNTU_FIX" "the PPA works on Ubuntu derivatives"
}

test_debian_gets_a_source_build_pointer_and_no_ppa_command() {
    lc_begin && lc_fake_git 2.39.5 && os_release 'NAME="Debian GNU/Linux"' 'ID=debian' 'VERSION_ID="12"' && apt_root || return 1
    gsg install
    assert_rc 1 "old git on Debian"
    assert_contains "$ERR" "Debian" "names the distribution"
    assert_contains "$ERR" "see docs/platforms.md" "points at the build instructions"
    assert_not_contains "$ERR" "add-apt-repository" "a PPA exists for Ubuntu only"
    assert_contains "$ERR" "install --upgrade-git" "the hint names the offer"
    nothing_changed "old git on debian"
}

test_other_distributions_and_a_missing_os_release_get_a_generic_text() {
    local release
    for release in 'ID=alpine' 'ID="arch"|ID_LIKE="archlinux"' ''; do
        lc_begin && lc_fake_git 2.43.0 || return 1
        if [ -n "$release" ]; then
            IFS='|' read -r -a lines <<<"$release"
            os_release "${lines[@]}" || return 1
        else
            set_env GSG_OS_RELEASE="$SANDBOX/no-such-os-release"
        fi
        gsg install
        assert_rc 1 "old git, os-release [$release]"
        assert_contains "$ERR" "git >= 2.54 from your distribution" "a generic hint"
        assert_contains "$ERR" "see docs/platforms.md" "and the build pointer"
        assert_not_contains "$ERR" "apt" "no apt command for [$release]"
    done
}

test_an_old_git_on_an_rpm_system_names_upgrade_git_and_the_platform_doc() {
    local release
    for release in 'ID="rocky"|ID_LIKE="rhel centos fedora"' 'ID=fedora' 'ID="rhel"|ID_LIKE="fedora"'; do
        lc_begin && lc_fake_git 2.52.0 || return 1
        IFS='|' read -r -a lines <<<"$release"
        os_release "${lines[@]}" || return 1
        set_env GSG_GITUP_ROOT="$SANDBOX/root"
        gsg install
        assert_rc 1 "old git, os-release [$release]"
        assert_contains "$ERR" "git 2.52.0; config-based hooks need git >= 2.54, install refused" "the existing refusal"
        assert_contains "$ERR" "install --upgrade-git" "names the flag that offers the upgrade"
        assert_contains "$ERR" "docs/platforms.md" "and the RPM section"
        assert_not_contains "$ERR" "apt" "no apt command for [$release]"
        nothing_changed "old git on [$release]"
    done
}

test_a_missing_tool_on_an_rpm_system_names_the_dnf_package() {
    local pair tool pkg
    for pair in jq:jq setsid:util-linux timeout:coreutils; do
        tool="${pair%%:*}" pkg="${pair#*:}"
        lc_begin && lc_path_without "$tool" && os_release 'ID="rocky"' 'ID_LIKE="rhel centos fedora"' || return 1
        gsg install
        assert_rc 1 "$tool missing"
        assert_contains "$ERR" "$tool is required but was not found on PATH; install it with: sudo dnf install $pkg" "the exact line for $tool"
        nothing_changed "$tool missing"
    done
}

test_a_missing_jq_setsid_timeout_or_curl_on_ubuntu_names_the_apt_package() {
    local pair tool pkg
    for pair in jq:jq setsid:util-linux timeout:coreutils; do
        tool="${pair%%:*}" pkg="${pair#*:}"
        lc_begin && lc_path_without "$tool" && ubuntu_release || return 1
        gsg install
        assert_rc 1 "$tool missing"
        assert_contains "$ERR" "$tool is required but was not found on PATH; install it with: sudo apt install $pkg" "the exact line for $tool"
        nothing_changed "$tool missing"
    done
    lc_begin && lc_make_fixtures && lc_use_fixtures && lc_path_without curl && ubuntu_release || return 1
    gsg install
    assert_rc 1 "downloads needed, no curl"
    assert_contains "$ERR" "curl is required to download the scanners but was not found on PATH; install it with: sudo apt install curl" "curl"
}

test_a_missing_systemctl_for_the_timer_names_the_apt_package() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && lc_path_without systemctl && ubuntu_release || return 1
    gsg install --with-timer
    assert_rc 1 "no systemctl"
    assert_contains "$ERR" "systemctl is required for --with-timer but was not found on PATH; nothing was changed (install it with: sudo apt install systemd)" "the old text, then the fix"
    nothing_changed "no systemctl"
}

test_a_missing_tool_elsewhere_says_to_use_the_package_manager() {
    lc_begin && lc_path_without jq && os_release 'ID=alpine' || return 1
    gsg install
    assert_rc 1 "jq missing"
    assert_contains "$ERR" "jq is required but was not found on PATH; install it with your package manager" "generic"
    assert_not_contains "$ERR" "apt" "no apt command"
}

# ^ security /etc/os-release is parsed as data, never sourced => a hostile file cannot run a command
test_the_os_release_file_is_parsed_and_never_executed() {
    lc_begin && lc_fake_git 2.43.0 && os_release "ID=\$(touch $SANDBOX/executed)" "touch $SANDBOX/executed2" 'ID_LIKE=ubuntu' || return 1
    gsg install
    assert_rc 1 "old git"
    assert_no_file "$SANDBOX/executed" "no command substitution ran"
    assert_no_file "$SANDBOX/executed2" "no line ran"
}

test_a_missing_or_unreadable_os_release_prints_no_raw_shell_error() {
    local target
    for target in "$SANDBOX/no-such-os-release" "$SANDBOX"; do
        lc_begin && lc_fake_git 2.43.0 && set_env GSG_OS_RELEASE="$target" || return 1
        gsg install
        assert_rc 1 "old git, os-release [$target]"
        assert_contains "$ERR" "git >= 2.54 from your distribution" "the generic hint"
        assert_not_contains "$ERR" "No such file" "no raw bash message for [$target]"
        assert_not_contains "$ERR" "Is a directory" "no raw bash message for [$target]"
        assert_not_contains "$ERR" "install.sh" "no script location for [$target]"
    done
}

os_field() {
    # shellcheck disable=SC2016
    run_cap env -i PATH="$TEST_BASE_PATH" bash -c 'source "$1/lib/install.sh" && install_os_release_field "$2" "$3" && printf "%s" "$REPLY"' _ "$GSG_PROJECT" "$1" "$2" </dev/null
}

test_os_release_fields_are_read_as_data() {
    local target
    # shellcheck disable=SC2016
    printf '%s\n' 'NAME="Ubuntu"' 'PRETTY_NAME="Ubuntu 24.04.2 LTS"' "VERSION_ID='24.04'" 'ID=ubuntu' 'ID=second' 'ID_LIKE=debian' \
        'HOSTILE=$(touch '"$SANDBOX/executed"')' >"$SANDBOX/osr"
    os_field "$SANDBOX/osr" PRETTY_NAME
    assert_eq "$OUT" "Ubuntu 24.04.2 LTS" "double quotes are removed"
    os_field "$SANDBOX/osr" VERSION_ID
    assert_eq "$OUT" "24.04" "single quotes are removed"
    os_field "$SANDBOX/osr" ID
    assert_eq "$OUT" ubuntu "the first occurrence wins"
    os_field "$SANDBOX/osr" HOSTILE
    assert_eq "$OUT" "\$(touch $SANDBOX/executed)" "a hostile value is literal text"
    assert_no_file "$SANDBOX/executed" "and ran nothing"
    os_field "$SANDBOX/osr" NO_SUCH_KEY
    assert_rc 0 "an absent key"
    assert_empty "$OUT" "is empty"
    for target in "$SANDBOX/no-such-file" "$SANDBOX"; do
        os_field "$target" ID
        assert_rc 0 "unreadable [$target]"
        assert_empty "$OUT" "gives an empty value"
        assert_empty "$ERR" "and no stderr text for [$target]"
    done
}

# ^ invariant farm_strip NAME TOOL... builds the PATH farm without NAME (lc_path_without) and removes the other TOOLs from it
farm_strip() {
    local name="$1" t
    shift
    lc_path_without "$name" || return 1
    for t in "$@"; do rm -f -- "$SANDBOX/pathfarm-$name/$t" || return 1; done
}

# ^ invariant farm_old_git NAME VERSION swaps git in the farm NAME for a stand-in reporting only VERSION
farm_old_git() {
    local dir="$SANDBOX/pathfarm-$1"
    rm -f -- "$dir/git" && printf '#!/bin/sh\necho "git version %s"\n' "$2" >"$dir/git" && chmod 755 "$dir/git"
}

test_an_old_git_and_a_missing_jq_are_both_named_in_one_refusal() {
    lc_begin && farm_strip jq && farm_old_git jq 2.43.0 && ubuntu_release || return 1
    gsg install
    assert_rc 1 "old git and no jq"
    assert_contains "$ERR" "jq is required but was not found on PATH; install it with: sudo apt install jq" "the jq line"
    assert_contains "$ERR" "git 2.43.0; once the problems above are fixed install offers to upgrade it" "the old git is deferred to the offer, the apt module has a route for it"
    assert_contains "$ERR" "install --upgrade-git" "and names the flag"
    nothing_changed "old git and no jq"
}

# shellcheck disable=SC2016
test_a_failing_realpath_of_the_git_on_path_refuses_with_a_message_and_changes_nothing() {
    lc_begin && lc_git_wrapper false && ubuntu_release || return 1
    printf '%s\n' '#!/bin/sh' 'for a in "$@"; do case "$a" in */pathbin/git) exit 1 ;; esac; done' "exec $(type -P realpath) \"\$@\"" >"$SANDBOX/pathbin/realpath" || return 1
    chmod 755 "$SANDBOX/pathbin/realpath"
    gsg install
    assert_rc 1 "the git on PATH cannot be resolved"
    assert_contains "$ERR" "cannot resolve the real path of $SANDBOX/pathbin/git" "the refusal names the git and says what failed"
    assert_contains "$ERR" "nothing was changed" "and that nothing happened"
    nothing_changed "realpath failure"
}

test_every_missing_prerequisite_is_named_at_once() {
    local tool pkg
    lc_begin && lc_make_fixtures && lc_use_fixtures && farm_strip jq setsid timeout curl && ubuntu_release || return 1
    gsg install
    assert_rc 1 "four tools missing"
    for tool in jq:jq setsid:util-linux timeout:coreutils; do
        pkg="${tool#*:}"
        assert_contains "$ERR" "${tool%%:*} is required but was not found on PATH; install it with: sudo apt install $pkg" "${tool%%:*}"
    done
    assert_contains "$ERR" "curl is required to download the scanners but was not found on PATH; install it with: sudo apt install curl" "curl"
    assert_contains "$ERR" "4 prerequisites are missing; install refused, nothing was changed" "one summary"
    nothing_changed "four tools missing"
}

test_a_missing_systemctl_is_named_with_the_other_missing_tools_when_the_timer_is_wanted() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && farm_strip systemctl jq && ubuntu_release || return 1
    gsg install --with-timer
    assert_rc 1 "no systemctl and no jq"
    assert_contains "$ERR" "jq is required but was not found on PATH" "jq"
    assert_contains "$ERR" "systemctl is required for --with-timer but was not found on PATH (install it with: sudo apt install systemd)" "systemctl, without its own claim"
    assert_contains "$ERR" "2 prerequisites are missing; install refused, nothing was changed" "one summary"
    assert_eq "$(grep -c 'nothing was changed' <<<"$ERR")" 1 "nothing was changed is said once, on the count line"
    nothing_changed "no systemctl, no jq"
}

run_file_tests
