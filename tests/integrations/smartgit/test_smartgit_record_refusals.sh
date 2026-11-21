#!/usr/bin/env bash
# shellcheck disable=SC2016
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/lifecycle.sh"
# shellcheck source=tests/support/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/gitup.sh"
# shellcheck source=tests/support/gitup_macos.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/gitup_macos.sh"
# shellcheck source=tests/support/smartgit.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/smartgit.sh"
# shellcheck source=tests/integrations/smartgit/smartgit_linux.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/smartgit_linux.sh"

# ^ external the Flatpak setup uses Linux paths and the flatpak stand-in; Windows has its own detection and no Flatpak
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="the SmartGit Flatpak record"; fi

# ^ why hand-written state, not a real configure; the refusals sit before any scanner runs, a real run would add a verify commit per case
RR_MANIFEST="" RR_BACKUP="" RR_HASH="" RR_BASE=""

# ^ invariant rr_setup = the Flatpak SmartGit on its fixture and a valid backup with its hash; RR_BASE is the valid manifest, one key per line
rr_setup() {
    local exec_value
    sl_flatpak_setup || return 1
    mkdir -p -- "$SG_BACKUPS" || return 1
    RR_MANIFEST="$SG_BACKUPS/handmade.manifest"
    RR_BACKUP="$SG_BACKUPS/handmade.preferences.yml"
    cp -p -- "$SG_PREFS" "$RR_BACKUP" || return 1
    RR_HASH="$(sg_hash "$RR_BACKUP")" || return 1
    exec_value="$(sg_git_value executable "$SG_PREFS")" || return 1
    RR_BASE="$(printf 'version=1\nstatus=final\nsettings=%s\nbackup=%s\norig_hash=%s\norig_executable=%s\norig_absolute=-\nnew_executable=%s\nnew_absolute=-\nkind=flatpak' \
        "$SG_PREFS" "$RR_BACKUP" "$RR_HASH" "$exec_value" "$exec_value")"
}

# ^ invariant rr_manifest_case WHY TEXT = restore-smartgit refuses the manifest TEXT (empty = no line at all) with rc 1 and WHY in the message, changing nothing
rr_manifest_case() {
    if [ -z "$2" ]; then : >"$RR_MANIFEST" || return 1; else printf '%s\n' "$2" >"$RR_MANIFEST" || return 1; fi
    gsg restore-smartgit </dev/null
    assert_rc 1 "$1: restore-smartgit refuses the manifest"
    assert_contains "$ERR" "the manifest $RR_MANIFEST is not one this tool wrote ($1)" "$1: says why the manifest is refused"
    assert_contains "$ERR" "restore by hand" "$1: prints the by-hand step"
    assert_file "$RR_MANIFEST" "$1: the manifest is kept"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "$1: the preferences are byte-identical"
    assert_eq "$(sg_hash "$RR_BACKUP")" "$RR_HASH" "$1: the backup is untouched"
}

test_a_manifest_this_tool_did_not_write_is_refused_for_each_reason_and_leaves_the_preferences_alone() {
    local sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa i long
    rr_setup || return 1
    long="$RR_BASE"
    rr_manifest_case "malformed at [no equals sign here]" "$RR_BASE"$'\n'"no equals sign here" || return 1
    rr_manifest_case "malformed at [status=pending]" "$RR_BASE"$'\n'"status=pending" || return 1
    rr_manifest_case "unknown key [extra]" "$RR_BASE"$'\n'"extra=1" || return 1
    rr_manifest_case "unknown key [kind ]" "${RR_BASE/kind=flatpak/kind =flatpak}" || return 1
    rr_manifest_case "unknown kind [plan9]" "${RR_BASE/kind=flatpak/kind=plan9}" || return 1
    rr_manifest_case "unknown version" "${RR_BASE/version=1/version=2}" || return 1
    rr_manifest_case "key [new_absolute] is missing" "${RR_BASE/new_absolute=-$'\n'/}" || return 1
    rr_manifest_case "key [version] is missing" "" || return 1
    rr_manifest_case "status is neither pending nor final" "${RR_BASE/status=final/status=done}" || return 1
    rr_manifest_case "orig_hash is not a sha256" "${RR_BASE/orig_hash=$RR_HASH/orig_hash=${sha:1}}" || return 1
    rr_manifest_case "orig_hash is not a sha256" "${RR_BASE/orig_hash=$RR_HASH/orig_hash=${sha}0}" || return 1
    rr_manifest_case "orig_hash is not a sha256" "${RR_BASE/orig_hash=$RR_HASH/orig_hash=${sha//a/A}}" || return 1
    for i in 1 2 3 4 5 6 7 8 9 10 11; do long+=$'\n'"x$i=y"; done
    rr_manifest_case "it is too long" "$long" || return 1
}

test_a_valid_manifest_is_restored_so_each_refusal_above_is_down_to_its_one_edit() {
    rr_setup || return 1
    printf '%s\n' "$RR_BASE" >"$RR_MANIFEST" || return 1
    gsg restore-smartgit </dev/null
    assert_rc 0 "restore-smartgit with the valid hand-written manifest"
    assert_contains "$OUT" "the Git Executable of $SG_PREFS is already the original; nothing to restore" "it is read, accepted and dealt with"
    assert_no_file "$RR_MANIFEST" "the manifest is dropped"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are the original"
}

test_a_manifest_that_cannot_be_read_is_refused() {
    if [ "$(id -u)" -eq 0 ]; then skip_test "root reads a file of mode 000"; fi
    rr_setup || return 1
    printf '%s\n' "$RR_BASE" >"$RR_MANIFEST" || return 1
    chmod 000 -- "$RR_MANIFEST" || return 1
    gsg restore-smartgit </dev/null
    chmod 600 -- "$RR_MANIFEST" || return 1
    assert_rc 1 "restore-smartgit with an unreadable manifest"
    assert_contains "$ERR" "is not one this tool wrote (it cannot be read)" "says it cannot be read"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are byte-identical"
}

# ^ invariant rr_record_base = a valid Flatpak record with every step "no"
rr_record_base() { printf 'version=1\noverride=no\noverride_clean=no\nwrapper=no\nwrapper_top=\nvmoption=no\nvmoption_file=\ntmpdir=no'; }

# ^ invariant rr_record_case WHY TEXT = restore-smartgit refuses the record TEXT with rc 1 and WHY in the message; the record, wrapper and preferences stay
rr_record_case() {
    printf '%s\n' "$2" >"$SL_FLATPAK_RECORD" || return 1
    gsg restore-smartgit </dev/null
    assert_rc 1 "$1: restore-smartgit refuses the record"
    assert_contains "$ERR" "the record $SL_FLATPAK_RECORD is not one this tool wrote ($1)" "$1: says why the record is refused"
    assert_file "$SL_FLATPAK_RECORD" "$1: the record is kept"
    assert_file "$SL_WRAPPER" "$1: the wrapper is kept"
    assert_file "$SL_HOME/sentinel" "$1: a file of HOME is kept"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "$1: the preferences are byte-identical"
}

# ^ invariant rr_record_setup = the Flatpak SmartGit, a wrapper with our marker in place and a file in HOME no undo may touch
rr_record_setup() {
    sl_flatpak_setup || return 1
    mkdir -p -- "$SG_BACKUPS" "${SL_WRAPPER%/*}" || return 1
    printf '#!/bin/sh\n%s\nexec true\n' "$SL_WRAPPER_MARKER" >"$SL_WRAPPER" && chmod 755 "$SL_WRAPPER" || return 1
    : >"$SL_HOME/sentinel"
}

test_a_flatpak_record_that_names_a_path_the_undo_may_not_touch_or_is_not_data_this_tool_wrote_is_refused_for_each_reason() {
    local base why_top="wrapper_top is not a directory above the wrapper" why_val="a value is not yes, no or created" i long
    rr_record_setup || return 1
    base="$(rr_record_base)"
    base="${base/wrapper=no/wrapper=yes}"
    rr_record_case "$why_top" "${base/wrapper_top=/wrapper_top=$SL_HOME}" || return 1
    rr_record_case "$why_top" "${base/wrapper_top=/wrapper_top=$SL_WRAPPER}" || return 1
    rr_record_case "$why_top" "${base/wrapper_top=/wrapper_top=$SL_HOME/.local/}" || return 1
    rr_record_case "$why_top" "${base/wrapper_top=/wrapper_top=/tmp}" || return 1
    rr_record_case "vmoption_file is not $SL_VMOPTS" "${base/vmoption_file=/vmoption_file=$SL_HOME/other.vmoptions}" || return 1
    rr_record_case "$why_val" "${base/override=no/override=maybe}" || return 1
    rr_record_case "$why_val" "${base/override_clean=no/override_clean=created}" || return 1
    rr_record_case "$why_val" "${base/wrapper=yes/wrapper=}" || return 1
    rr_record_case "$why_val" "${base/tmpdir=no/tmpdir=created}" || return 1
    rr_record_case "$why_val" "${base/vmoption=no/vmoption=maybe}" || return 1
    rr_record_case "unknown version" "${base/version=1/version=2}" || return 1
    rr_record_case "unknown key [extra]" "$base"$'\n'"extra=no" || return 1
    rr_record_case "malformed at [no equals sign here]" "$base"$'\n'"no equals sign here" || return 1
    rr_record_case "malformed at [tmpdir=no]" "$base"$'\n'"tmpdir=no" || return 1
    long="$base"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do long+=$'\n'"x$i=y"; done
    rr_record_case "it is too long" "$long" || return 1
}

test_a_flatpak_record_with_the_paths_this_tool_writes_is_accepted_and_undone() {
    local base
    rr_record_setup || return 1
    base="$(rr_record_base)"
    printf '%s\n' "$base" >"$SL_FLATPAK_RECORD" || return 1
    gsg restore-smartgit </dev/null
    assert_rc 0 "restore-smartgit with a record of a run that changed nothing (empty wrapper_top)"
    assert_no_file "$SL_FLATPAK_RECORD" "that record is gone"
    assert_file "$SL_WRAPPER" "a wrapper the record does not claim is kept"
    base="${base/wrapper=no/wrapper=yes}"
    base="${base/wrapper_top=/wrapper_top=$SL_HOME/.local/share/smartgit}"
    base="${base/vmoption=no/vmoption=created}"
    base="${base/vmoption_file=/vmoption_file=$SL_VMOPTS}"
    mkdir -p -- "$SG_BACKUPS" "${SL_VMOPTS%/*}" || return 1
    printf '%s\n' "$base" >"$SL_FLATPAK_RECORD" || return 1
    : >"$SL_VMOPTS"
    gsg restore-smartgit </dev/null
    assert_rc 0 "restore-smartgit with a record of the paths this tool writes"
    assert_no_file "$SL_WRAPPER" "the wrapper it names is removed"
    assert_no_file "$SL_FLATPAK_RECORD" "the record is gone"
    assert_file "$SL_HOME/sentinel" "a file of HOME is kept"
}

test_a_flatpak_record_that_cannot_be_read_is_refused() {
    if [ "$(id -u)" -eq 0 ]; then skip_test "root reads a file of mode 000"; fi
    rr_record_setup || return 1
    rr_record_base >"$SL_FLATPAK_RECORD" || return 1
    chmod 000 -- "$SL_FLATPAK_RECORD" || return 1
    gsg restore-smartgit </dev/null
    chmod 600 -- "$SL_FLATPAK_RECORD" || return 1
    assert_rc 1 "restore-smartgit with an unreadable record"
    assert_contains "$ERR" "is not one this tool wrote (it cannot be read)" "says it cannot be read"
    assert_file "$SL_WRAPPER" "the wrapper is kept"
}

run_file_tests
