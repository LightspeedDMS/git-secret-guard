#!/usr/bin/env bash
# ^ invariant each test pins a Hook gap of docs/bypass-detection-scenarios.md (N11, N12), a tool the hook still takes from the user's PATH (#31)
# ^ why pinned, not fixed; a lying awk or head has no second reading to check against, and a trusted PATH for every tool is out of scope
# ^ why not reachable by accident, not by a plain no-op; each stand-in must know the hook's own arguments (extract.awk, the count file)
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

begin() {
    local rc key_not_set=5
    git_literal_config --global --unset-all lfs.storage
    rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq "$key_not_set" ] || return 1
    new_repo "$1" || return 1
    MARKER="$(new_marker)"
    set_env STUB_LOG="$SANDBOX/calls-$1" STUB_MARKER="$MARKER" STUB_RECORD="$SANDBOX/record-$1"
}

# ^ invariant args = tool name, script body; the script goes first on PATH for the commit after it, the real tools stay behind
shadow() {
    mkdir -p -- "$SANDBOX/shadow-$1" || return 1
    printf '#!/bin/sh\n%s\n' "$2" >"$SANDBOX/shadow-$1/$1" && chmod 755 -- "$SANDBOX/shadow-$1/$1" || return 1
    set_env PATH="$SANDBOX/shadow-$1:$PATH"
}

# ^ coupled tests/scan/test_lfs.sh:lfs_stage, the same pointer and storage layout
lfs_stage_object() {
    local path="$1" content="$2" dir oid
    oid="$(sha256sum -- "$content")" || return 1
    oid="${oid%% *}"
    dir="$REPO/.git/lfs/objects/${oid:0:2}/${oid:2:2}"
    mkdir -p -- "$dir" "$(dirname -- "$path")" || return 1
    cp -- "$content" "$dir/$oid" || return 1
    printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %s\n' "$oid" "$(wc -c <"$content" | tr -d ' ')" >"$path" || return 1
    gitx add -- "$path"
}

# ^ invariant prints what the stub scanner recorded for the test, "" when it never ran
recorded() { if [ -f "$SANDBOX/record-$1.trufflehog" ]; then cat -- "$SANDBOX/record-$1.trufflehog"; fi; }

# ^ hazard N11 an awk answering the extraction with counts 0 0 and no files agrees with an empty scan tree => the hook says nothing is to scan
test_a_counts_lying_awk_first_on_path_still_lets_a_commit_pass_unscanned() {
    begin awk || return 1
    # shellcheck disable=SC2016
    shadow awk 'case "$1" in -f) cat >/dev/null; printf "0 0\n" >"$GSG_EXTRACT_COUNTS"; exit 0 ;; esac; exec /usr/bin/awk "$@"' || return 1
    stage_file src/app.txt "secret = $MARKER" || return 1
    commit_cap "awk lies"
    assert_rc 0 "N11 is a Hook gap: the commit passes"
    assert_contains "$ERR" "no added lines to scan" "with the one line that says nothing was scanned"
    assert_not_contains "$(recorded awk)" "$MARKER" "the scanner never saw the line"
}

# ^ hazard N12 a head printing nothing makes the stored object look like a binary file; it is dropped from the scan and from the counts
test_a_no_op_head_first_on_path_drops_an_lfs_object_from_the_scan() {
    begin head || return 1
    printf 'object line %s\n' "$MARKER" >"$SANDBOX/obj-head" || return 1
    lfs_stage_object data/big.dat "$SANDBOX/obj-head" || return 1
    shadow head 'exit 0' || return 1
    commit_cap "head lies"
    assert_rc 0 "N12 is a Hook gap: the commit passes"
    assert_not_contains "$(recorded head)" "$MARKER" "the object content never reached the scanner"
}

# ^ hazard N12 a no-op mv never swaps the object in; only the pointer text is scanned
test_a_no_op_mv_first_on_path_scans_the_pointer_instead_of_the_lfs_object() {
    begin mv || return 1
    printf 'object line %s\n' "$MARKER" >"$SANDBOX/obj-mv" || return 1
    lfs_stage_object data/big.dat "$SANDBOX/obj-mv" || return 1
    shadow mv 'exit 0' || return 1
    commit_cap "mv lies"
    assert_not_contains "$(recorded mv)" "$MARKER" "the object content never reached the scanner"
}

# ^ invariant args = tool name, script body; stages an LFS object with the marker, shadows the tool, commits; the outcome is left to the caller
lfs_commit_with_shadow() {
    begin "$1" || return 1
    printf 'object line %s\n' "$MARKER" >"$SANDBOX/obj-$1" || return 1
    lfs_stage_object data/big.dat "$SANDBOX/obj-$1" || return 1
    shadow "$1" "$2" || return 1
    commit_cap "$1 lies"
}

# ^ invariant N12 tr and wc are not gaps, they block with a misleading reason => the rows are pinned here
test_a_no_op_tr_first_on_path_blocks_with_the_lfs_pointer_message() {
    lfs_commit_with_shadow tr 'exit 0' || return 1
    assert_rc 1 "blocked"
    assert_contains "$ERR" "cannot read the staged blobs to look for Git LFS pointers" "the message names a pointer walk, not the tr"
    assert_not_contains "$(recorded tr)" "$MARKER" "the object content never reached the scanner"
}

test_a_zero_printing_wc_first_on_path_blocks_with_a_size_mismatch() {
    lfs_commit_with_shadow wc 'echo 0' || return 1
    assert_rc 1 "blocked"
    assert_contains "$ERR" "its object is 0 bytes, the pointer says" "the size check sees 0 and refuses"
    assert_not_contains "$(recorded wc)" "$MARKER" "the object content never reached the scanner"
}

run_file_tests
