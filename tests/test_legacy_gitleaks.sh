#!/usr/bin/env bash
# ^ why a suite of its own, not test_upgrade; machines the gitleaks build installed hold gitleaks records to retire on install and honour on uninstall
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

STAMP=20261031T101500Z
USER_MODE=750
OURS_MODE=755
BETTERLEAKS_PIN_VERSION=1.9.0
OURS_SHA="" USER_SHA=""

# ^ invariant file_sha PATH prints the hex SHA-256 of the file; a missing file or tool is a failure
file_sha() {
    local out
    out="$(sha256sum <"$1")" || return 1
    printf '%s\n' "${out%% *}"
}

# ^ invariant write_legacy_state TOOLS REPLACED PLACED writes the state file as the gitleaks build did (eight keys)
write_legacy_state() {
    printf 'version=%s\nprevious_hooks_path_set=%s\nprevious_hooks_path=%s\ntools_installed_by_us=%s\nbackup_path=\ntools_replaced=%s\ntools_placed=%s\ntimer_installed=no\n' \
        "$(state_value version)" "$(state_value previous_hooks_path_set)" "$(state_value previous_hooks_path)" "$1" "$2" "$3" >"$LC_STATE/state"
}

# ^ invariant legacy_machine MODE builds an install by this build, rewritten into what the gitleaks build left behind
# ^ invariant mode ours = a gitleaks placed by us on an empty path; mode user = ours placed over the user's own, moved aside
legacy_machine() {
    local mode="$1" tf_sha aside
    case "$mode" in ours | user) ;; *) printf 'legacy_machine: unknown mode [%s]\n' "$mode" >&2; return 1 ;; esac
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    aside="$LC_BIN/gitleaks.gsg-replaced-$STAMP"
    gsg install
    assert_rc 0 "the install that is rewritten below"
    rm -f -- "$LC_BIN/betterleaks" || return 1
    printf '#!/bin/sh\necho "gitleaks version 8.30.1"\n# placed by install\n' >"$LC_BIN/gitleaks" || return 1
    chmod "$OURS_MODE" "$LC_BIN/gitleaks" || return 1
    OURS_SHA="$(file_sha "$LC_BIN/gitleaks")" || return 1
    tf_sha="$(file_sha "$LC_BIN/trufflehog")" || return 1
    if [ "$mode" = user ]; then
        printf '#!/bin/sh\necho "gitleaks version 8.18.4"\n# user build\n' >"$aside" || return 1
        chmod "$USER_MODE" "$aside" || return 1
        USER_SHA="$(file_sha "$aside")" || return 1
        write_legacy_state trufflehog "gitleaks.gsg-replaced-$STAMP:$OURS_SHA" "trufflehog:$tf_sha gitleaks:$OURS_SHA"
    else
        write_legacy_state "trufflehog gitleaks" "" "trufflehog:$tf_sha gitleaks:$OURS_SHA"
    fi
}

assert_betterleaks_at_pin() {
    assert_eq "$("$LC_BIN/betterleaks" --version)" "betterleaks version $BETTERLEAKS_PIN_VERSION" "$1"
}

test_an_upgrade_removes_a_gitleaks_install_placed_and_places_betterleaks() {
    legacy_machine ours || return 1
    gsg install
    assert_rc 0 "upgrade"
    assert_no_file "$LC_BIN/gitleaks" "the gitleaks we placed is removed"
    assert_betterleaks_at_pin "betterleaks is placed at the pin"
    assert_contains "$OUT$ERR" "gitleaks" "the removal is announced"
    assert_eq "$(state_value tools_installed_by_us)" "trufflehog betterleaks" "the state names the current tools only"
    assert_not_contains "$(state_value tools_placed)" "gitleaks" "no gitleaks hash is kept"
    assert_contains "$(state_value tools_placed)" "betterleaks:" "betterleaks is recorded as placed"
    assert_eq "$(state_value tools_replaced)" "" "nothing is recorded as replaced"
    assert_contains "$(<"$LC_DATA/settings")" "BETTERLEAKS_BIN=" "settings name betterleaks"
    assert_contains "$(<"$LC_DATA/settings")" "BETTERLEAKS_VERSION=$BETTERLEAKS_PIN_VERSION" "and its version"
    assert_not_contains "$(<"$LC_DATA/settings")" "GITLEAKS" "and no GITLEAKS key"
}

# ^ invariant user_gitleaks_is_back LABEL = the user's gitleaks is the only file in the bin dir, byte for byte, with its mode, nothing aside
user_gitleaks_is_back() {
    assert_eq "$(file_sha "$LC_BIN/gitleaks")" "$USER_SHA" "$1: the user's gitleaks is byte-identical"
    assert_eq "$(stat -c %a "$LC_BIN/gitleaks")" "$USER_MODE" "$1: and has its mode"
    assert_empty "$(find "$LC_BIN" -name '*.gsg-replaced-*')" "$1: no aside file is left"
    assert_eq "$(find "$LC_BIN" -mindepth 1 | wc -l | tr -d ' ')" 1 "$1: only the user's gitleaks is left, as before the first install"
}

test_an_upgrade_restores_the_users_moved_aside_gitleaks_and_uninstall_then_leaves_the_machine_as_before() {
    legacy_machine user || return 1
    gsg install
    assert_rc 0 "upgrade"
    assert_eq "$(find "$LC_BIN" -name 'gitleaks*' | wc -l | tr -d ' ')" 1 "after the upgrade the user's gitleaks is the only gitleaks file"
    assert_eq "$(file_sha "$LC_BIN/gitleaks")" "$USER_SHA" "and it is byte-identical"
    assert_betterleaks_at_pin "betterleaks is placed"
    assert_eq "$(state_value tools_replaced)" "" "the record of the move is gone"
    assert_not_contains "$(state_value tools_placed)" "gitleaks" "and so is the placed hash"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall after the upgrade"
    user_gitleaks_is_back "after uninstall"
}

test_uninstall_without_upgrading_still_restores_the_users_gitleaks_and_removes_ours() {
    legacy_machine user || return 1
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall of a state the gitleaks build wrote"
    user_gitleaks_is_back "after uninstall"
}

test_uninstall_without_upgrading_removes_a_gitleaks_we_placed_on_an_empty_path() {
    legacy_machine ours || return 1
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall of a state the gitleaks build wrote"
    assert_empty "$(find "$LC_BIN" -mindepth 1)" "nothing of ours is left behind"
}

test_an_upgrade_leaves_a_gitleaks_that_is_no_longer_the_one_we_placed() {
    legacy_machine ours || return 1
    printf '#!/bin/sh\necho "gitleaks version 9.0.0"\n# changed by the user\n' >"$LC_BIN/gitleaks" || return 1
    gsg install
    assert_rc 0 "upgrade"
    assert_contains "$(<"$LC_BIN/gitleaks")" "changed by the user" "a file we did not place is never deleted"
    assert_contains "$OUT$ERR" "left in place" "and the output says so"
    assert_betterleaks_at_pin "betterleaks is placed anyway"
}

# ^ security the wrapper only adds one TERM to the real mv => nothing else about the move changes
# ^ invariant interrupt_after_restore puts an mv first on PATH; it does the move and terminates its parent (install) when an aside file is involved
interrupt_after_restore() {
    local real_mv
    real_mv="$(command -v mv)" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\n%s "$@" || exit 1\ncase "$*" in *.gsg-replaced-*) kill -TERM "$PPID" ;; esac\n' "$real_mv" >"$SANDBOX/pathbin/mv" || return 1
    chmod 755 "$SANDBOX/pathbin/mv"
}

test_an_interruption_after_the_restore_never_lets_the_rerun_delete_the_users_gitleaks() {
    legacy_machine user || return 1
    cp -- "$LC_BIN/gitleaks" "$LC_BIN/gitleaks.gsg-replaced-$STAMP" || return 1
    chmod "$USER_MODE" "$LC_BIN/gitleaks.gsg-replaced-$STAMP" || return 1
    USER_SHA="$(file_sha "$LC_BIN/gitleaks.gsg-replaced-$STAMP")" || return 1
    interrupt_after_restore || return 1
    gsg install
    assert_rc 143 "the first upgrade is interrupted right after the user's gitleaks was moved back"
    rm -f -- "$SANDBOX/pathbin/mv" || return 1
    gsg install
    assert_rc 0 "the rerun"
    assert_eq "$(file_sha "$LC_BIN/gitleaks")" "$USER_SHA" "the user's gitleaks (identical to the one we placed) was not deleted by the rerun"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall"
    user_gitleaks_is_back "after the interrupted upgrade"
}

run_file_tests
