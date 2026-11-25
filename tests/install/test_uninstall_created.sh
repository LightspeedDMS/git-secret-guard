#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

# ^ coupled issue #74; install records what it brings into being (created_by_install), uninstall removes a recorded item only when it is empty

# ^ invariant a profile with no ~/.gitconfig, ~/.local or ~/.config, git's own global lookup (no GIT_CONFIG_GLOBAL) and no XDG_* variable
# ^ security HOME stays the sandbox home => git's global lookup and every path of install land in scratch files
uc_bare_profile() {
    local e
    local -a keep=()
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    for e in "${LC_ENV[@]}"; do
        case "$e" in GIT_CONFIG_GLOBAL=* | XDG_DATA_HOME=* | XDG_STATE_HOME=* | XDG_CONFIG_HOME=*) ;; *) keep+=("$e") ;; esac
    done
    LC_ENV=("${keep[@]}")
    UC_STATE="$LC_HOME/.local/state/git-secret-guard/state"
    [ -z "$(uc_home_listing)" ] || fail "the bare profile is not empty: $(uc_home_listing)"
}

uc_record() { awk -F= '$1 == "created_by_install" { sub(/^[^=]*=/, ""); print; exit }' "${1:-$UC_STATE}"; }

# ^ invariant uc_run ARGS... runs the CLI and asserts exit 0, naming the arguments; OUT and ERR stay for the caller
uc_run() {
    gsg "$@"
    assert_rc 0 "$*"
}

uc_home_listing() { (cd -- "$LC_HOME" && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' '); }

uc_assert_home_empty() { assert_eq "$(uc_home_listing)" "" "$1"; }

test_uninstall_with_remove_tools_leaves_a_bare_profile_as_it_was() {
    uc_bare_profile || return 1
    uc_run install
    assert_file "$LC_HOME/.gitconfig" "install brought ~/.gitconfig into being"
    assert_file "$UC_STATE" "and the state in ~/.local/state"
    assert_eq "$(uc_record)" "file:$LC_HOME/.gitconfig dir:$LC_HOME/.local/state dir:$LC_HOME/.local dir:$LC_HOME/.local/share dir:$LC_HOME/.local/bin" \
        "the state names the file and each directory install created, the config file first"
    uc_run uninstall --remove-tools
    uc_assert_home_empty "nothing install created is left in the home"
    assert_contains "$OUT" "git-secret-guard: removed $LC_HOME/.gitconfig, which install created and which is empty now" "the file has its line"
    assert_not_contains "$OUT$ERR" "$LC_HOME/.local/share " "an empty directory goes without a line, as the state dir does"
}

test_uninstall_keeps_the_bin_dir_with_the_tools_and_removes_the_rest() {
    uc_bare_profile || return 1
    uc_run install
    uc_run uninstall
    assert_no_file "$LC_HOME/.gitconfig" "the empty ~/.gitconfig install created is gone"
    assert_eq "$(ls -A -- "$LC_HOME/.local")" "bin" "the share and state dirs of ~/.local are gone, ~/.local/bin stays with the tools"
    assert_eq "$("$LC_BIN/trufflehog$LC_EXE" --version)" "trufflehog 3.99.2" "the scanners stay"
}

test_a_config_file_and_directories_that_existed_before_install_stay_even_when_empty() {
    uc_bare_profile || return 1
    : >"$LC_HOME/.gitconfig" && mkdir -p -- "$LC_HOME/.local/share" "$LC_HOME/.local/state" || return 1
    uc_run install
    assert_eq "$(uc_record)" "dir:$LC_BIN" "only what was missing is recorded"
    uc_run uninstall --remove-tools
    assert_eq "$(wc -c <"$LC_HOME/.gitconfig")" 0 "the ~/.gitconfig that was there before stays, empty as before"
    assert_eq "$(uc_home_listing)" "./.gitconfig ./.local ./.local/share ./.local/state " "the directories that were there stay; ~/.local/bin, which install created, goes"
    assert_not_contains "$ERR" "$LC_HOME/.local/s" "nothing is said about what stays"
}

test_what_install_created_stays_when_it_holds_anything_else_at_uninstall() {
    uc_bare_profile || return 1
    uc_run install
    printf '[user]\n\tname = Someone Else\n' >>"$LC_HOME/.gitconfig" || return 1
    : >"$LC_HOME/.local/share/other" && : >"$LC_HOME/.local/state/other" || return 1
    uc_run uninstall --remove-tools
    assert_contains "$(<"$LC_HOME/.gitconfig")" "Someone Else" "the config file stays with the user's key"
    assert_not_contains "$(<"$LC_HOME/.gitconfig")" "git-secret-guard" "and without our section"
    assert_eq "$(uc_home_listing)" "./.gitconfig ./.local ./.local/share ./.local/share/other ./.local/state ./.local/state/other " \
        "the directories holding a file stay, and so does ~/.local above them"
    assert_not_contains "$OUT$ERR" "which install created" "nothing is said about what stays"
    assert_not_contains "$ERR" "$LC_HOME/.local" "no warning either"
}

test_an_install_over_an_install_keeps_the_record() {
    local first
    uc_bare_profile || return 1
    uc_run install
    first="$(uc_record)"
    assert_contains "$first" "file:$LC_HOME/.gitconfig" "the first install recorded the file"
    uc_run install
    assert_eq "$(uc_record)" "$first" "the second install, where everything exists, keeps the record of the first whole"
    uc_run uninstall --remove-tools
    uc_assert_home_empty "what the first install created goes"
}

test_an_install_over_an_older_install_records_nothing_it_found_in_place() {
    uc_bare_profile || return 1
    uc_run install
    grep -v '^created_by_install=' "$UC_STATE" >"$UC_STATE.old" && mv -f -- "$UC_STATE.old" "$UC_STATE" || return 1
    uc_run install
    assert_eq "$(uc_record)" "" "over the state of an older install, which recorded nothing, what exists now is not install's to remove"
    uc_run uninstall --remove-tools
    assert_eq "$(uc_home_listing)" "./.gitconfig ./.local ./.local/bin ./.local/share ./.local/state " "the empty ~/.gitconfig and the directories stay"
}

test_a_named_config_file_and_xdg_directories_install_created_go_whatever_their_names() {
    local cfg="$SANDBOX/new cfg%20" top="$SANDBOX/xdg new%" c t b h
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    rm -rf -- "${top:?}" "${cfg:?}" || return 1
    c="${cfg//%/%25}" t="${top//%/%25}" b="$LC_BIN" h="$LC_HOME"
    set_env GIT_CONFIG_GLOBAL="$cfg" XDG_DATA_HOME="$top/da ta/deep" XDG_STATE_HOME="$top/state"
    uc_run install
    assert_eq "$(uc_record "$top/state/git-secret-guard/state")" \
        "file:${c// /%20} dir:${t// /%20}/state dir:${t// /%20} dir:${t// /%20}/da%20ta/deep dir:${t// /%20}/da%20ta dir:${b// /%20} dir:${h// /%20}/.local" \
        "spaces and percent signs are written encoded"
    uc_run uninstall
    assert_no_file "$cfg" "the config file named by GIT_CONFIG_GLOBAL goes"
    assert_no_file "$top" "and every XDG directory install created"
    assert_file "$LC_BIN/trufflehog$LC_EXE" "the bin dir stays with the tools"
    assert_contains "$OUT" "removed $cfg, which install created and which is empty now" "named as it is"
}

test_the_unit_dir_install_created_for_the_timer_goes_with_it() {
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then skip_test "the systemd timer is refused on Windows"; fi
    uc_bare_profile || return 1
    uc_run install --with-timer
    assert_contains "$(uc_record)" "dir:$LC_HOME/.config/systemd/user dir:$LC_HOME/.config/systemd dir:$LC_HOME/.config" "the unit dir is recorded"
    uc_run uninstall --remove-tools
    uc_assert_home_empty "the config dir goes with the units, ~/.config included"
}

test_a_record_too_long_for_the_state_line_is_cut_and_the_state_stays_readable() {
    # ^ external macOS refuses a path over 1024 bytes; 30 levels of 20 stay under it, and unbounded their record would be over 10K characters
    local max_line=8192 depth=30 seg_len=20 deep="$SANDBOX/deep" i seg line state
    printf -v seg '%0*d' "$seg_len" 0
    for ((i = 0; i < depth; i++)); do deep+="/$seg"; done
    state="$deep/git-secret-guard/state"
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    set_env XDG_STATE_HOME="$deep"
    uc_run install
    assert_file "$state" "install wrote the state"
    line="$(grep '^created_by_install=' "$state")" || fail "the state has no created_by_install line"
    [ "${#line}" -le "$max_line" ] || fail "the record line has ${#line} characters, over the $max_line state_read accepts"
    uc_run uninstall
    assert_no_file "$state" "the state could be read and was removed"
}

run_file_tests
