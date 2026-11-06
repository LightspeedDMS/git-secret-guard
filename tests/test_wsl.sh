#!/usr/bin/env bash
# shellcheck source=tests/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# ^ why a uname function over the real libs, not a container; the WSL branches run on Linux, macOS and Git for Windows alike (FAKE_UNAME defaults to Linux)
# ^ why no lc_begin, not the lifecycle stand-ins; they need setsid and this file also has to run on the Windows host
WSL_PRELUDE='set -u
GSG_ROOT="$1"
GSG_NAME=git-secret-guard
GSG_UNINSTALL_ACTIONS=0
FAKE_UNAME="${FAKE_UNAME:-Linux}"
uname() { if [ "${1:-}" = -m ]; then echo x86_64; else echo "$FAKE_UNAME"; fi; }
for lib in brew common state tools hookspath timer launchd install install_tools wsl gitup gitup_source; do
    source "$1/lib/$lib.sh" || exit 9
done
shift
'

wsl() {
    local code="$1"
    shift
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c "$WSL_PRELUDE$code" _ "${WSL_ROOT:-$GSG_PROJECT}" "$@"
    OUT="$(<"$SANDBOX/.out")"
    ERR="$(grep -v "TEST OVERRIDE active (GSG_WSL" "$SANDBOX/.err" || true)"
}

# ^ invariant wsl_kernel TEXT writes the kernel release text WSL reads; the interop file and the systemd directory are absent until a test makes them
wsl_kernel() {
    printf '%s\n' "$1" >"$SANDBOX/osrelease" || return 1
    set_env GSG_WSL_OSRELEASE="$SANDBOX/osrelease" GSG_WSL_INTEROP="$SANDBOX/no-interop" GSG_WSL_SYSTEMD_DIR="$SANDBOX/no-systemd"
}

WSL1_KERNEL='4.4.0-17763-Microsoft'
WSL2_KERNEL='5.15.153.1-microsoft-standard-WSL2'

test_the_wsl1_kernel_text_with_a_capital_M_is_wsl_version_1() {
    wsl_kernel "$WSL1_KERNEL" || return 1
    wsl 'wsl_is; echo "is=$?"; wsl_version; echo "version=$REPLY"'
    assert_contains "$OUT" "is=0" "a case-sensitive match on microsoft would miss WSL 1"
    assert_contains "$OUT" "version=1" "no WSL2 in the text"
}

test_the_wsl2_kernel_text_is_wsl_version_2() {
    wsl_kernel "$WSL2_KERNEL" || return 1
    wsl 'wsl_is; echo "is=$?"; wsl_version; echo "version=$REPLY"'
    assert_contains "$OUT" "is=0" "microsoft in lower case"
    assert_contains "$OUT" "version=2" "the WSL2 suffix"
}

test_a_plain_linux_kernel_is_not_wsl() {
    wsl_kernel "6.8.0-45-generic" || return 1
    wsl 'wsl_is; echo "is=$?"'
    assert_contains "$OUT" "is=1" "no microsoft, no interop file"
}

test_the_interop_file_alone_is_wsl() {
    wsl_kernel "6.8.0-45-generic" || return 1
    : >"$SANDBOX/interop" || return 1
    set_env GSG_WSL_INTEROP="$SANDBOX/interop"
    wsl 'wsl_is; echo "is=$?"'
    assert_contains "$OUT" "is=0" "the second signal"
}

test_a_missing_kernel_file_is_not_wsl_and_prints_nothing() {
    set_env GSG_WSL_OSRELEASE="$SANDBOX/absent" GSG_WSL_INTEROP="$SANDBOX/no-interop"
    wsl 'wsl_is; echo "is=$?"'
    assert_contains "$OUT" "is=1" "an unreadable file is no signal"
    assert_empty "$ERR" "and no error text"
}

test_the_wsl_signal_is_ignored_on_macos_and_git_for_windows() {
    wsl_kernel "$WSL1_KERNEL" || return 1
    set_env FAKE_UNAME=Darwin
    wsl 'wsl_is; echo "is=$?"'
    assert_contains "$OUT" "is=1" "uname is not Linux"
    set_env FAKE_UNAME=MINGW64_NT-10.0-26200
    wsl 'wsl_is; echo "is=$?"'
    assert_contains "$OUT" "is=1" "Git for Windows"
}

test_the_wsl_overrides_are_announced_once_on_stderr() {
    wsl_kernel "$WSL1_KERNEL" || return 1
    wsl 'wsl_is; wsl_is; wsl_announce_overrides'
    assert_contains "$(<"$SANDBOX/.err")" "TEST OVERRIDE" "named like the other test seams"
    assert_contains "$(<"$SANDBOX/.err")" "GSG_WSL_OSRELEASE=[$SANDBOX/osrelease]" "with its value"
    assert_eq "$(grep -c "TEST OVERRIDE" "$SANDBOX/.err")" 1 "once, not once per call"
}

# ^ invariant a class is wsl only when the distribution inside has a git upgrade module; any other WSL distribution keeps today's refusal as class other
test_the_class_of_a_wsl_ubuntu_debian_or_rpm_distribution_is_wsl() {
    local id
    wsl_kernel "$WSL2_KERNEL" || return 1
    for id in "ubuntu|" "debian|" "rocky|rhel fedora" "linuxmint|ubuntu debian"; do
        printf 'ID=%s\nID_LIKE="%s"\n' "${id%%|*}" "${id#*|}" >"$SANDBOX/os-release"
        set_env GSG_OS_RELEASE="$SANDBOX/os-release"
        wsl 'gitup_os_class; echo "class=$REPLY"'
        assert_contains "$OUT" "class=wsl" "${id%%|*} in WSL"
    done
}

test_the_class_of_a_wsl_distribution_without_a_module_is_other() {
    wsl_kernel "$WSL2_KERNEL" || return 1
    printf 'ID=alpine\n' >"$SANDBOX/os-release" || return 1
    set_env GSG_OS_RELEASE="$SANDBOX/os-release"
    wsl 'gitup_os_class; echo "class=$REPLY"'
    assert_contains "$OUT" "class=other" "no WSL notes for a route that does not exist"
}

test_the_class_outside_wsl_is_unchanged() {
    wsl_kernel "6.8.0-45-generic" || return 1
    printf 'ID=ubuntu\n' >"$SANDBOX/os-release" || return 1
    set_env GSG_OS_RELEASE="$SANDBOX/os-release"
    wsl 'gitup_os_class; echo "class=$REPLY"'
    assert_contains "$OUT" "class=ubuntu" "plain Linux"
    wsl_kernel "$WSL1_KERNEL" || return 1
    EXTRA_ENV+=(FAKE_UNAME=MINGW64_NT-10.0-26200)
    wsl 'gitup_os_class; echo "class=$REPLY"'
    assert_contains "$OUT" "class=windows" "Git for Windows wins over any kernel file"
}

test_wsl_is_a_registered_class_with_its_own_module() {
    wsl 'gitup_registry wsl; echo "module=$REPLY rc=$?"; gitup_check_registered_modules'
    assert_contains "$OUT" "module=wsl" "one registry line"
    assert_contains "$OUT" "checked the git upgrade module wsl (class wsl)" "it loads and implements the contract"
}

# ^ invariant the timer needs systemd running (a directory /run/systemd/system, what sd_booted tests); systemctl on PATH proves nothing on WSL 1
test_with_timer_is_refused_on_wsl1_without_a_wsl_conf_fix() {
    wsl_kernel "$WSL1_KERNEL" || return 1
    wsl 'wsl_check_timer 1; echo "rc=$?"'
    assert_contains "$OUT" "rc=1" "refused"
    assert_contains "$ERR" "WSL 1" "names the platform"
    assert_contains "$ERR" "not available" "says the timer is not available"
    assert_not_contains "$ERR" "wsl.conf" "no fix that cannot work on WSL 1"
    assert_not_contains "$ERR" "wsl --shutdown" "no restart advice either"
    assert_contains "$ERR" "nothing was changed" "before any change"
}

test_with_timer_is_refused_on_wsl2_without_systemd_with_the_wsl_conf_fix() {
    wsl_kernel "$WSL2_KERNEL" || return 1
    wsl 'wsl_check_timer 1; echo "rc=$?"'
    assert_contains "$OUT" "rc=1" "refused"
    assert_contains "$ERR" "/etc/wsl.conf" "the file"
    assert_contains "$ERR" "[boot]" "the section"
    assert_contains "$ERR" "systemd=true" "the key"
    assert_contains "$ERR" "wsl --shutdown" "the restart"
    assert_not_contains "$ERR" "WSL 1" "not the WSL 1 text"
}

test_with_timer_goes_on_when_systemd_runs_or_the_timer_was_not_asked_for() {
    wsl_kernel "$WSL2_KERNEL" || return 1
    mkdir -p "$SANDBOX/systemd" || return 1
    set_env GSG_WSL_SYSTEMD_DIR="$SANDBOX/systemd"
    wsl 'wsl_check_timer 1; echo "rc=$?"'
    assert_contains "$OUT" "rc=0" "systemd is running"
    assert_empty "$ERR" "silently"
    wsl_kernel "$WSL2_KERNEL" || return 1
    wsl 'wsl_check_timer 0; echo "rc=$?"'
    assert_contains "$OUT" "rc=0" "no --with-timer"
}

test_with_timer_is_unchanged_outside_wsl() {
    wsl_kernel "6.8.0-45-generic" || return 1
    wsl 'wsl_check_timer 1; echo "rc=$?"'
    assert_contains "$OUT" "rc=0" "plain Linux has its own checks"
    assert_empty "$ERR" "no WSL text"
}

# ^ order the WSL check sits in install_precheck_timer => the refusal comes before the git offers and before any change
test_install_precheck_timer_runs_the_wsl_check_first() {
    wsl_kernel "$WSL1_KERNEL" || return 1
    wsl 'GSG_GIT=""; install_precheck_timer 1; echo "rc=$?"'
    assert_contains "$OUT" "rc=1" "refused by the precheck"
    assert_contains "$ERR" "WSL 1" "with the WSL text"
}

test_a_reachable_windows_git_is_explained_as_a_separate_setup() {
    wsl_kernel "$WSL1_KERNEL" || return 1
    mkdir -p "$SANDBOX/winbin" || return 1
    printf '#!/bin/sh\n' >"$SANDBOX/winbin/git.exe" && chmod 755 "$SANDBOX/winbin/git.exe" || return 1
    wsl 'PATH="$1:$PATH"; install_wsl_notice; echo "rc=$?"' "$SANDBOX/winbin"
    assert_contains "$OUT" "rc=0" "never fails an install"
    assert_contains "$ERR" "$SANDBOX/winbin/git.exe" "names the Windows git it saw"
    assert_contains "$ERR" "not covered" "says what is not covered"
    assert_contains "$ERR" "Git for Windows" "and where to install it"
}

test_the_windows_git_notice_is_silent_without_a_windows_git_or_outside_wsl() {
    wsl_kernel "$WSL1_KERNEL" || return 1
    mkdir -p "$SANDBOX/empty" || return 1
    wsl 'PATH="$1"; install_wsl_notice; echo "rc=$?"' "$SANDBOX/empty"
    assert_contains "$OUT" "rc=0" "nothing reachable"
    assert_empty "$ERR" "no notice"
    wsl_kernel "6.8.0-45-generic" || return 1
    mkdir -p "$SANDBOX/winbin" || return 1
    printf '#!/bin/sh\n' >"$SANDBOX/winbin/git.exe" && chmod 755 "$SANDBOX/winbin/git.exe" || return 1
    wsl 'PATH="$1:$PATH"; install_wsl_notice; echo "rc=$?"' "$SANDBOX/winbin"
    assert_empty "$ERR" "not WSL"
}

test_a_windows_git_is_never_taken_for_a_git_of_the_distribution() {
    wsl_kernel "$WSL1_KERNEL" || return 1
    mkdir -p "$SANDBOX/winbin" || return 1
    printf '#!/bin/sh\n' >"$SANDBOX/winbin/git.exe" && chmod 755 "$SANDBOX/winbin/git.exe" || return 1
    wsl 'PATH="$1:$PATH"; GITUP_USRBIN="$2"; install_collect_gits; printf "[%s]\n" "${GSG_GIT_CANDIDATES[@]}"' "$SANDBOX/winbin" "$SANDBOX/none"
    assert_not_contains "$OUT" "git.exe" "install_collect_gits looks for git, not git.exe"
}

# ^ external renaming the directory of a running script fails on WSL 1 (4.4.0-20348-Microsoft, rc 1) and works on WSL 2 (6.18.54.1-microsoft-standard-WSL2)
test_the_running_script_pin_covers_windows_and_wsl1_only() {
    wsl_kernel "$WSL1_KERNEL" || return 1
    wsl 'install_pins_running_script; echo "wsl1=$?"'
    assert_contains "$OUT" "wsl1=0" "WSL 1"
    wsl_kernel "$WSL2_KERNEL" || return 1
    wsl 'install_pins_running_script; echo "wsl2=$?"'
    assert_contains "$OUT" "wsl2=1" "WSL 2"
    wsl_kernel "6.8.0-45-generic" || return 1
    wsl 'install_pins_running_script; echo "linux=$?"'
    assert_contains "$OUT" "linux=1" "plain Linux"
    EXTRA_ENV+=(FAKE_UNAME=MINGW64_NT-10.0-26200)
    wsl 'install_pins_running_script; echo "windows=$?"'
    assert_contains "$OUT" "windows=0" "Git for Windows"
}

test_an_install_from_the_installed_copy_on_wsl1_never_renames_the_directory_it_runs_from() {
    local share="$SANDBOX/share-copy" item
    wsl_kernel "$WSL1_KERNEL" || return 1
    mkdir -p "$share" || return 1
    for item in hooks lib bin tools.lock VERSION; do cp -a -- "$GSG_PROJECT/$item" "$share/" || return 1; done
    printf 'old\n' >"$share/settings" && printf 'kept\n' >"$share/sentinel" || return 1
    wsl 'GSG_ROOT="$1" GSG_SHARE="$1" GSG_BIN_DIR=/b GSG_TOOL_VER=(1 2) INSTALL_JQ_BIN=/b/jq INSTALL_JQ_WRAPPER=""
INSTALL_TIMEOUT_BIN=/t INSTALL_BASH_BIN="" INSTALL_GNUBIN_DIR="" INSTALL_TIMER_BIN=""; install_copy_share; echo "rc=$?"' "$share"
    assert_contains "$OUT" "rc=0" "no rename is attempted"
    assert_contains "$(<"$share/settings")" "JQ_BIN=" "the settings are rewritten in place"
    assert_eq "$(<"$share/sentinel")" kept "the rest of the tree is not replaced (the sentinel is not one of the copied items, so a replaced tree would lose it)"
    assert_eq "$(find "$SANDBOX" -maxdepth 1 -name 'share-copy.*' | wc -l | tr -d ' ')" 0 "nothing is left beside it"
}

# ^ invariant the same install on a plain kernel replaces the whole tree and the sentinel of the test above is gone => the test above can fail
test_the_same_install_on_a_plain_kernel_replaces_the_tree_and_loses_the_sentinel() {
    local share="$SANDBOX/share-plain" item
    wsl_kernel "6.8.0-45-generic" || return 1
    mkdir -p "$share" || return 1
    for item in hooks lib bin tools.lock VERSION; do cp -a -- "$GSG_PROJECT/$item" "$share/" || return 1; done
    printf 'old\n' >"$share/settings" && printf 'kept\n' >"$share/sentinel" || return 1
    wsl 'GSG_ROOT="$1" GSG_SHARE="$1" GSG_BIN_DIR=/b GSG_TOOL_VER=(1 2) INSTALL_JQ_BIN=/b/jq INSTALL_JQ_WRAPPER=""
INSTALL_TIMEOUT_BIN=/t INSTALL_BASH_BIN="" INSTALL_GNUBIN_DIR="" INSTALL_TIMER_BIN=""; install_copy_share; echo "rc=$?"' "$share"
    assert_contains "$OUT" "rc=0" "the copy ran"
    assert_no_file "$share/sentinel" "the tree was replaced, not updated in place"
    assert_contains "$(<"$share/settings")" "JQ_BIN=" "and the new tree has its settings"
}


# ^ invariant wsl_tree copies the product to $WSL_ROOT and registers a synthetic module for ubuntu (and rpm); the real apt and rpm modules are not reached
# ^ why a synthetic inner module, not apt; the apt stand-ins need setsid (lc_begin), and this file also has to run on Git for Windows
WSL_INNER='
gitup_inner_plan() {
    if [ "$1" = refresh ]; then return "${INNER_REFRESH_RC:-1}"; fi
    gitup_inner_class
    printf "  inner plan (%s) class=%s\n" "$1" "$REPLY"
    GITUP_ROUTE=innerroute
    return "${INNER_PLAN_RC:-0}"
}
gitup_inner_apply() { gitup_inner_class; printf "inner apply class=%s\n" "$REPLY"; return "${INNER_APPLY_RC:-0}"; }
gitup_inner_abort() { printf "inner abort\n"; }
'
WSL_INNER_TAKEOVER='
gitup_inner_takeover_supported() { printf "inner supported %s\n" "$1"; }
gitup_inner_takeover_plan() { printf "inner takeover plan %s\n" "$1"; }
gitup_inner_takeover_apply() { printf "inner takeover apply %s\n" "$1"; }
gitup_inner_takeover_restore() { printf "inner restore\n"; }
gitup_inner_takeover_status() { GITUP_TK_STATE=active; printf "inner status\n"; }
'

wsl_tree() {
    WSL_ROOT="$SANDBOX/proj"
    rm -rf -- "$WSL_ROOT" && mkdir -p -- "$WSL_ROOT" || return 1
    cp -a -- "$GSG_PROJECT/bin" "$GSG_PROJECT/lib" "$GSG_PROJECT/hooks" "$GSG_PROJECT/tools.lock" "$GSG_PROJECT/VERSION" "$WSL_ROOT/" || return 1
    printf '%s\n%s\n' "$WSL_INNER" "${1:-}" >"$WSL_ROOT/lib/gitup_inner.sh" || return 1
    sed -i 's/^\( *\)ubuntu) REPLY=apt ;;$/\1ubuntu) REPLY=inner ;;/' "$WSL_ROOT/lib/gitup.sh" || return 1
    grep -q '^ *ubuntu) REPLY=inner ;;$' "$WSL_ROOT/lib/gitup.sh" || return 1
    wsl_kernel "$WSL2_KERNEL" || return 1
    printf 'ID=ubuntu\n' >"$SANDBOX/os-release" || return 1
    set_env GSG_OS_RELEASE="$SANDBOX/os-release"
}

test_the_wsl_plan_is_the_inner_plan_plus_two_notes() {
    wsl_tree || return 1
    wsl 'gitup_select; echo "class=$GITUP_CLASS module=$GITUP_MODULE"; gitup_call plan upgrade; echo "rc=$? route=$GITUP_ROUTE"'
    assert_contains "$OUT" "class=wsl module=wsl" "the run is a WSL run"
    assert_contains "$OUT" "inner plan (upgrade) class=ubuntu" "the inner module sees its own class"
    assert_contains "$OUT" "rc=0 route=innerroute" "the inner route is the route"
    assert_contains "$OUT" "note: this upgrades git inside this WSL distribution only" "first note"
    assert_contains "$OUT" "Windows-side git is a separate setup" "second note"
}

test_a_wsl_plan_with_no_route_adds_no_notes_and_keeps_the_inner_return_code() {
    wsl_tree || return 1
    set_env INNER_PLAN_RC=1
    wsl 'gitup_select; gitup_call plan upgrade; echo "rc=$?"'
    assert_contains "$OUT" "rc=1" "the inner code"
    assert_not_contains "$OUT" "note:" "no notes for a plan that does not exist"
}

test_a_wsl_refresh_with_nothing_stale_prints_nothing_at_all() {
    wsl_tree || return 1
    wsl 'gitup_select; gitup_call plan refresh >"$1"; echo "rc=$?"; wc -c <"$1"' "$SANDBOX/refresh.out"
    assert_contains "$OUT" "rc=1" "nothing stale"
    assert_eq "$(tr -d ' \r\n' <<<"${OUT#*rc=1}")" 0 "the wrapper adds no byte of its own"
}

test_wsl_apply_and_abort_are_forwarded_to_the_inner_module() {
    wsl_tree || return 1
    wsl 'gitup_select; gitup_call plan upgrade >/dev/null; gitup_call apply; echo "rc=$?"; gitup_call abort; echo "abort=$?"'
    assert_contains "$OUT" "inner apply class=ubuntu" "apply"
    assert_contains "$OUT" "inner abort" "a wrapper forwards abort (CONTRIBUTING.md)"
    set_env INNER_APPLY_RC=1
    wsl 'gitup_select; gitup_call plan upgrade >/dev/null; gitup_call apply; echo "rc=$?"'
    assert_contains "$OUT" "rc=1" "a failed apply stays failed"
}

test_a_wsl_abort_with_an_inner_module_that_has_none_does_nothing() {
    wsl_tree || return 1
    sed -i '/gitup_inner_abort/d' "$WSL_ROOT/lib/gitup_inner.sh" || return 1
    wsl 'gitup_select; gitup_call abort; echo "rc=$?"'
    assert_contains "$OUT" "rc=0" "nothing to undo"
}

test_the_takeover_functions_are_forwarded_when_the_inner_module_has_them() {
    wsl_tree "$WSL_INNER_TAKEOVER" || return 1
    wsl 'gitup_select; gitup_call takeover_supported /x; gitup_call takeover_plan /x; gitup_call takeover_apply /x; gitup_call takeover_restore; gitup_call takeover_status; echo "state=$GITUP_TK_STATE"'
    assert_contains "$OUT" "inner supported /x" "supported"
    assert_contains "$OUT" "inner takeover plan /x" "plan"
    assert_contains "$OUT" "inner takeover apply /x" "apply"
    assert_contains "$OUT" "inner restore" "restore"
    assert_contains "$OUT" "state=active" "status"
}


test_the_wsl_module_for_an_rpm_distribution_wraps_the_rpm_module() {
    wsl_kernel "$WSL2_KERNEL" || return 1
    printf 'ID=rocky\nID_LIKE="rhel fedora"\n' >"$SANDBOX/os-release" || return 1
    set_env GSG_OS_RELEASE="$SANDBOX/os-release"
    wsl 'gitup_select; echo "class=$GITUP_CLASS"; gitup_wsl_enter; echo "inner=$GITUP_INNER_CLASS module=$GITUP_WSL_MODULE"; declare -F gitup_rpm_plan >/dev/null; echo "rpm=$?"'
    assert_contains "$OUT" "class=wsl" "WSL"
    assert_contains "$OUT" "inner=rpm module=rpm" "the rpm module"
    assert_contains "$OUT" "rpm=0" "and its plan function is loaded"
}


# ^ invariant the takeover forwards exist only when the inner module has them => --take-over-system-git behaves as on the same distribution outside WSL
test_without_an_inner_takeover_the_wsl_module_has_no_takeover_functions() {
    wsl_tree || return 1
    wsl 'gitup_select; gitup_has takeover_supported; echo "supported=$?"; gitup_has takeover_status; echo "status=$?"; gitup_has takeover_unavailable; echo "unavail=$?"'
    assert_contains "$OUT" "supported=1" "no takeover capability"
    assert_contains "$OUT" "status=1" "and no status"
}

test_take_over_system_git_on_a_wsl_distribution_without_a_takeover_is_refused_like_outside_wsl() {
    wsl_tree || return 1
    wsl 'gitup_offers 0 1; echo "rc=$?"'
    assert_contains "$OUT" "rc=1" "refused, as plain Ubuntu refuses it"
    assert_contains "$ERR" "--take-over-system-git is not available" "the core's refusal text"
}

test_with_an_inner_takeover_the_wsl_module_forwards_all_five_functions() {
    wsl_tree "$WSL_INNER_TAKEOVER" || return 1
    wsl 'gitup_select; for k in takeover_supported takeover_plan takeover_apply takeover_restore takeover_status; do gitup_has $k; printf "%s=%s " "$k" "$?"; done'
    assert_eq "$OUT" "takeover_supported=0 takeover_plan=0 takeover_apply=0 takeover_restore=0 takeover_status=0 " "all five, so the contract check passes"
}

# ^ external real WSL 2 kernels can lack the WSL2 suffix (4.19.128-microsoft-standard); WSL 1 is the one with a capital M (Microsoft)
test_a_wsl2_kernel_without_the_wsl2_suffix_is_version_2() {
    wsl_kernel "4.19.128-microsoft-standard" || return 1
    wsl 'wsl_is; echo "is=$?"; wsl_version; echo "version=$REPLY"'
    assert_contains "$OUT" "is=0" "microsoft"
    assert_contains "$OUT" "version=2" "no capital M, so not WSL 1"
}

test_a_kernel_text_with_a_capital_M_is_version_1_whatever_follows() {
    wsl_kernel "4.4.0-19041-Microsoft" || return 1
    wsl 'wsl_version; echo "version=$REPLY"'
    assert_contains "$OUT" "version=1" "Microsoft"
}

# ^ invariant a plain fixture says nothing on stderr; an override is announced only when it makes the run a WSL run
test_a_plain_kernel_fixture_is_silent_and_a_wsl_one_is_announced() {
    wsl_kernel "6.8.0-45-generic" || return 1
    wsl 'wsl_is; echo "is=$?"'
    assert_empty "$(<"$SANDBOX/.err")" "no announcement for a plain kernel"
    wsl_kernel "$WSL1_KERNEL" || return 1
    wsl 'wsl_is'
    assert_contains "$(<"$SANDBOX/.err")" "TEST OVERRIDE" "announced when it makes the run WSL"
}

# ^ invariant results never depend on the kernel of the test machine; the harness points every seam at a plain Linux fixture
test_the_harness_pins_the_wsl_seams_to_a_plain_kernel() {
    local kernel
    wsl 'echo "[$GSG_WSL_OSRELEASE] [$GSG_WSL_INTEROP] [$GSG_WSL_SYSTEMD_DIR]"; wsl_is; echo "is=$?"'
    assert_not_contains "$OUT" "[] [] []" "the seams are set"
    assert_contains "$OUT" "is=1" "and say plain Linux"
    kernel="$(<"$SANDBOX/wsl-kernel")"
    assert_not_contains "$kernel" -icrosoft "the fixture is a plain kernel text"
    assert_empty "$(<"$SANDBOX/.err")" "silently"
}

test_the_wsl_helpers_live_in_lib_wsl_sh_and_install_sh_stays_under_the_size_limit() {
    grep -q '^install_pins_running_script()' "$GSG_PROJECT/lib/wsl.sh" || fail "install_pins_running_script is not in lib/wsl.sh"
    grep -q '^install_wsl_notice()' "$GSG_PROJECT/lib/wsl.sh" || fail "install_wsl_notice is not in lib/wsl.sh"
    assert_eq "$(( $(wc -l <"$GSG_PROJECT/lib/install.sh") < 1000 ))" 1 "lib/install.sh is under 1000 lines"
}

test_the_windows_test_prelude_loads_the_wsl_library() {
    grep -qE '^for lib in .* wsl ' "$GSG_PROJECT/tests/test_windows.sh" || fail "tests/test_windows.sh does not load wsl"
}


# ^ security the CI script installs software and renames directories; it refuses unless it runs in GitHub Actions, and writes nothing before it decides
test_the_ci_script_refuses_to_run_outside_github_actions() {
    run_cap env -i "${GSG_ENV[@]}" bash "$GSG_PROJECT/tests/platform/wsl-ci.sh" facts
    assert_rc 2 "refused"
    assert_contains "$(<"$SANDBOX/.err")" "GITHUB_ACTIONS" "says why"
    assert_no_file "$SANDBOX/home/wsl-logs" "and created nothing"
    run_cap env -i "${GSG_ENV[@]}" GITHUB_ACTIONS=false bash "$GSG_PROJECT/tests/platform/wsl-ci.sh" facts
    assert_rc 2 "only the value true counts"
}


# ^ external measured on WSL 1 (build 20348); without systemd, systemd-analyze --user verify complains of a device monitor and a system bus, and exits 0
test_the_systemd_analyze_probe_names_a_machine_that_cannot_verify_and_never_a_unit_problem() {
    local stub="$SANDBOX/analyze-stub"
    printf '#!/bin/sh\necho "Failed to start device monitor: Invalid argument"\necho "Failed to connect to system bus: No such file or directory"\nexit 0\n' >"$stub" && chmod 755 "$stub" || return 1
    assert_contains "$(analyze_blocked_reason "$stub")" "Failed to start device monitor" "no systemd: a reason, so the test skips"
    printf '#!/bin/sh\necho "x.service: Unknown key name Foo in section Service"\nexit 1\n' >"$stub" || return 1
    assert_empty "$(analyze_blocked_reason "$stub")" "a real unit problem is no reason to skip"
    printf '#!/bin/sh\nexit 0\n' >"$stub" || return 1
    assert_empty "$(analyze_blocked_reason "$stub")" "a working systemd-analyze is no reason either"
}

run_file_tests
