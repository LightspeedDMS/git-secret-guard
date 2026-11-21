#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

setup_commit() { gitx commit -q --no-verify -m setup; }

# shellcheck disable=SC2016
extract_staged() {
    run_cap env -i "${GSG_ENV[@]}" bash -c \
        'set -u; set -o pipefail; source "$1/lib/core/common.sh" && source "$1/lib/scan/extract.sh" && staged_trees_init "$2" && staged_diff | extract_added_lines "$2"' _ "$SHARE" "$1"
}

# shellcheck disable=SC2016
extract_text() {
    run_cap env -i "${GSG_ENV[@]}" bash -c \
        'set -u; set -o pipefail; source "$1/lib/core/common.sh" && source "$1/lib/scan/extract.sh" && extract_added_lines "$2"' _ "$SHARE" "$1" <<<"$2"
}

assert_content() {
    local expected actual
    expected="$(printf '%b' "$2"; printf x)"
    actual="$(cat -- "$1" 2>/dev/null; printf x)"
    [ "$actual" = "$expected" ] || fail "content of $1: expected [$2] got [${actual%x}]"
}

file_list() { (cd -- "$1" && find . -type f | LC_ALL=C sort); }

test_real_path_and_real_line_numbers() {
    new_repo r1 || return 1
    stage_file src/a.txt a b c d && setup_commit
    stage_file src/a.txt a B c d e
    extract_staged "$SANDBOX/scan1"
    assert_rc 0 extract
    assert_content "$SANDBOX/scan1/src/a.txt" '\nB\n\n\ne\n'
    assert_eq "$(file_list "$SANDBOX/scan1")" "./src/a.txt" "only the touched file exists"
}

test_new_file_with_two_hunks() {
    new_repo r2 || return 1
    stage_file f.txt 1 2 3 4 5 6 7 8 9 10 && setup_commit
    stage_file f.txt X 2 3 4 5 6 7 8 9 Y
    extract_staged "$SANDBOX/scan2"
    assert_rc 0 extract
    assert_content "$SANDBOX/scan2/f.txt" 'X\n\n\n\n\n\n\n\n\nY\n'
}

test_brand_new_file_keeps_all_lines() {
    new_repo r3 || return 1
    stage_file new.txt alpha beta gamma
    extract_staged "$SANDBOX/scan3"
    assert_content "$SANDBOX/scan3/new.txt" 'alpha\nbeta\ngamma\n'
}

test_deletion_only_writes_nothing() {
    new_repo r4 || return 1
    stage_file gone.txt one two && setup_commit
    gitx rm -q -- gone.txt
    extract_staged "$SANDBOX/scan4"
    assert_rc 0 extract
    assert_eq "$(file_list "$SANDBOX/scan4")" "" "no file for a pure deletion"
}

test_line_deletion_inside_file_writes_nothing() {
    new_repo r5 || return 1
    stage_file f.txt one two three && setup_commit
    stage_file f.txt one three
    extract_staged "$SANDBOX/scan5"
    assert_eq "$(file_list "$SANDBOX/scan5")" "" "removed lines add nothing"
}

test_empty_diff_writes_nothing() {
    new_repo r6 || return 1
    extract_staged "$SANDBOX/scan6"
    assert_rc 0 extract
    assert_eq "$(file_list "$SANDBOX/scan6")" "" "empty index"
}

test_binary_content_is_not_extracted() {
    new_repo r7 || return 1
    local marker
    marker="$(new_marker)"
    { printf '\000\001\002%s\000\377' "$marker"; } >blob.bin
    gitx add blob.bin
    extract_staged "$SANDBOX/scan7"
    assert_rc 0 extract
    assert_eq "$(file_list "$SANDBOX/scan7")" "" "binary file is skipped"
    assert_not_contains "$(cat -- "$SANDBOX/.out" "$SANDBOX/.err" 2>/dev/null)" "$marker" "marker"
}

test_a_committed_diff_or_binary_attribute_cannot_hide_added_text() {
    local n=0 attrs
    for attrs in '* -diff' '*.dat -diff' '*.dat binary' '*.dat -diff -text'; do
        n=$((n + 1))
        new_repo "r7b$n" || return 1
        printf '%s\n' "$attrs" >.gitattributes
        gitx add .gitattributes
        stage_file notes.dat "plain text that must be scanned"
        extract_staged "$SANDBOX/scan7b$n"
        assert_rc 0 extract
        assert_content "$SANDBOX/scan7b$n/notes.dat" 'plain text that must be scanned\n'
    done
}

test_local_attribute_files_still_hide_text_a_documented_limit() {
    new_repo r7c || return 1
    mkdir -p .git/info && printf '*.dat -diff\n' >.git/info/attributes
    stage_file notes.dat "hidden by the local info/attributes file"
    extract_staged "$SANDBOX/scan7c"
    assert_eq "$(file_list "$SANDBOX/scan7c")" "" "info/attributes is local, uncommitted config and still applies"
}

test_the_users_core_attributes_file_cannot_hide_text() {
    new_repo r7d || return 1
    printf '*.dat -diff\n*.bin binary\n' >"$SANDBOX/user-attributes"
    gitx config --global core.attributesFile "$SANDBOX/user-attributes"
    stage_file notes.dat "hidden by the user's core.attributesFile"
    stage_file notes.bin "binary by the user's core.attributesFile"
    extract_staged "$SANDBOX/scan7d"
    assert_eq "$(file_list "$SANDBOX/scan7d")" "$(printf './notes.bin\n./notes.dat')" "core.attributesFile is pinned to /dev/null for the diff"
    gitx config --global --unset core.attributesFile
}

test_filenames_with_spaces_quotes_and_tabs() {
    new_repo r8 || return 1
    local odd='we ird "q" \back.txt' tabbed=$'tab\tname.txt'
    stage_file "$odd" hello
    stage_file "$tabbed" world
    extract_staged "$SANDBOX/scan8"
    assert_rc 0 extract
    assert_content "$SANDBOX/scan8/$odd" 'hello\n'
    assert_content "$SANDBOX/scan8/$tabbed" 'world\n'
}

test_utf8_filename_is_not_mangled() {
    new_repo r9 || return 1
    local name=$'caf\303\251.txt'
    stage_file "$name" bonjour
    extract_staged "$SANDBOX/scan9"
    assert_content "$SANDBOX/scan9/$name" 'bonjour\n'
}

test_added_lines_that_look_like_diff_headers() {
    new_repo r10 || return 1
    stage_file h.txt '++ x' '+ y' '@@ -1 +1 @@' '--- a/fake' '+++ b/evil.txt'
    extract_staged "$SANDBOX/scan10"
    assert_rc 0 extract
    assert_content "$SANDBOX/scan10/h.txt" '++ x\n+ y\n@@ -1 +1 @@\n--- a/fake\n+++ b/evil.txt\n'
    assert_eq "$(file_list "$SANDBOX/scan10")" "./h.txt" "no file created from a content line"
}

test_no_newline_at_end_of_file_marker() {
    new_repo r11 || return 1
    printf 'tail-without-newline' >nonl.txt
    gitx add nonl.txt
    extract_staged "$SANDBOX/scan11"
    assert_rc 0 extract
    assert_content "$SANDBOX/scan11/nonl.txt" 'tail-without-newline\n'
}

test_rename_with_edit_extracts_only_new_lines() {
    new_repo r12 || return 1
    stage_file old.txt l1 l2 l3 l4 l5 l6 l7 l8 && setup_commit
    gitx mv old.txt new.txt
    stage_file new.txt l1 l2 l3 l4 l5 l6 l7 CHANGED
    extract_staged "$SANDBOX/scan12"
    assert_rc 0 extract
    assert_content "$SANDBOX/scan12/new.txt" '\n\n\n\n\n\n\nCHANGED\n'
}

test_traversal_paths_are_refused() {
    local p diff n=0
    for p in '../evil' 'a/../../evil' '/abs/evil' 'a//b' './x' 'a/./b' 'dir/'; do
        n=$((n + 1))
        diff="$(printf 'diff --git a/x b/x\n--- a/x\n+++ b/%s\n@@ -0,0 +1 @@\n+payload' "$p")"
        extract_text "$SANDBOX/trav$n" "$diff"
        assert_rc 2 "refuse [$p]"
        assert_no_file "$SANDBOX/evil" "escaped for [$p]"
        assert_eq "$(file_list "$SANDBOX/trav$n" 2>/dev/null)" "" "nothing written for [$p]"
    done
}

test_quoted_traversal_paths_are_refused() {
    local diff
    diff="$(printf 'diff --git a/x b/x\n--- a/x\n+++ "b/..\\057evil"\n@@ -0,0 +1 @@\n+payload')"
    extract_text "$SANDBOX/qtrav1" "$diff"
    assert_rc 2 "refuse quoted ..\\057 path"
    diff="$(printf 'diff --git a/x b/x\n--- a/x\n+++ "b/\\056\\056/evil"\n@@ -0,0 +1 @@\n+payload')"
    extract_text "$SANDBOX/qtrav2" "$diff"
    assert_rc 2 "refuse octal-escaped .. path"
    assert_no_file "$SANDBOX/evil" "escaped"
}

test_symlink_to_file_type_change_is_scanned() {
    new_repo r13 || return 1
    ln -s target.txt link && gitx add link && setup_commit
    rm -f -- link
    printf 'now a file\n' >./link
    gitx add link
    extract_staged "$SANDBOX/scan13"
    assert_rc 0 extract
    assert_content "$SANDBOX/scan13/link" 'now a file\n'
}

test_user_diff_config_cannot_change_the_parse() {
    new_repo r14 || return 1
    gitx config diff.noprefix true
    gitx config diff.mnemonicPrefix true
    gitx config diff.interHunkContext 5
    gitx config diff.context 9
    stage_file f.txt a b c d e f g h && setup_commit
    stage_file f.txt a B c d e f G h
    extract_staged "$SANDBOX/scan14"
    assert_rc 0 extract
    assert_content "$SANDBOX/scan14/f.txt" '\nB\n\n\n\n\nG\n'
}

test_shell_metacharacters_in_paths_are_inert() {
    new_repo r15 || return 1
    local rel="d'ir \$(touch $SANDBOX/PWNED)/\`id\`;x.txt"
    stage_file "$rel" payload
    extract_staged "$SANDBOX/scan15"
    assert_rc 0 extract
    assert_content "$SANDBOX/scan15/$rel" 'payload\n'
    assert_no_file "$SANDBOX/PWNED" "command substitution ran"
}

test_a_truncated_hunk_and_an_unexpected_line_inside_a_hunk_fail() {
    extract_text "$SANDBOX/trunc1" "$(printf '+++ b/f\n@@ -0,0 +1,2 @@\n+only one line')"
    assert_rc 2 "hunk header promised 2 added lines, the diff ended after 1"
    extract_text "$SANDBOX/trunc2" "$(printf '+++ b/f\n@@ -1,2 +1,1 @@\n-gone\n+kept')"
    assert_rc 2 "hunk header promised 2 removed lines, the diff ended after 1"
    extract_text "$SANDBOX/junk1" "$(printf '+++ b/f\n@@ -0,0 +1,2 @@\n+first\n*unexpected\n+second')"
    assert_rc 2 "a line that is not + - space or backslash inside a hunk"
    extract_text "$SANDBOX/ok1" "$(printf '+++ b/f\n@@ -0,0 +1 @@\n+first\n\\ No newline at end of file')"
    assert_rc 0 "the no-newline marker is allowed"
    assert_content "$SANDBOX/ok1/f" 'first\n'
}

# shellcheck disable=SC2016
extract_with_pathspecs() {
    run_cap env -i "${GSG_ENV[@]}" bash -c \
        'set -u; set -o pipefail; source "$1/lib/core/common.sh" && source "$1/lib/scan/extract.sh" && d="$2" && shift 2 && staged_trees_init "$d" && staged_diff -- "$@" | extract_added_lines "$d"' _ "$SHARE" "$@"
}

# shellcheck disable=SC2016
added_file_count() {
    run_cap env -i "${GSG_ENV[@]}" bash -c \
        'set -u; set -o pipefail; source "$1/lib/core/common.sh" && source "$1/lib/scan/extract.sh" && shift && staged_trees_init "$PWD" && staged_added_file_count -- "$@"' _ "$SHARE" "$@"
}

test_pathspec_excludes_remove_files_from_the_extraction_and_the_rest_stays() {
    new_repo ps1 || return 1
    stage_file tests/fixtures/k.txt fixture-line
    stage_file src/a.txt real-line
    stage_file docs/readme.txt doc-line
    extract_with_pathspecs "$SANDBOX/scan-ps1" ':(exclude,top,glob)tests/fixtures/**' ':(exclude,top,glob)docs/**'
    assert_rc 0 extract
    assert_eq "$(file_list "$SANDBOX/scan-ps1")" "./src/a.txt" "only the non-excluded file is extracted"
    assert_content "$SANDBOX/scan-ps1/src/a.txt" 'real-line\n'
}

test_added_file_count_counts_files_that_add_lines_and_honours_pathspecs() {
    new_repo ps2 || return 1
    stage_file gone.txt one two && stage_file keep.txt a b c && setup_commit
    gitx rm -q -- gone.txt
    stage_file keep.txt a b c d
    stage_file tests/fixtures/k.txt fixture-line
    stage_file src/a.txt real-line
    printf '\000\001binary' >bin.dat && gitx add bin.dat
    added_file_count
    assert_rc 0 count
    assert_eq "$OUT" 3 "keep.txt, tests/fixtures/k.txt and src/a.txt add lines; a deletion and a binary file do not"
    added_file_count ':(exclude,top,glob)tests/fixtures/**'
    assert_eq "$OUT" 2 "the excluded file is not counted"
    added_file_count ':(exclude,top,glob)**'
    assert_eq "$OUT" 0 "everything excluded"
}

# shellcheck disable=SC2016
clean_stderr_of() {
    run_cap env -i "${GSG_ENV[@]}" bash -c 'source "$1/lib/core/common.sh" && source "$1/lib/scan/extract.sh" && _extract_clean_stderr' _ "$SHARE" <<<"$1"
}

test_the_awk_error_sanitizer_ends_the_text_with_a_newline_not_a_question_mark() {
    clean_stderr_of 'awk: close failed on file "a'$'\e''b"'
    assert_rc 0 "sanitizer"
    assert_eq "$ERR" 'awk: close failed on file "a?b"' "one clean line, the line end is not turned into ?"
    assert_eq "$(od -An -c <"$SANDBOX/.err" | tr -d ' \n')" 'awk:closefailedonfile"a?b"\n' "the text ends in exactly one newline"
    clean_stderr_of $'two\nlines\n\n'
    assert_eq "$ERR" $'two?lines' "an inner newline is marked, the trailing ones are dropped"
    clean_stderr_of ""
    assert_empty "$(<"$SANDBOX/.err")" "empty input prints nothing"
}

# ^ hazard a no-op find first on PATH (#25) => the helpers under test run with one there and still answer from the tree itself
# shellcheck disable=SC2016
tree_fn() {
    local fn="$1"
    shift
    mkdir -p -- "$SANDBOX/nofind" && printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/nofind/find" && chmod 755 -- "$SANDBOX/nofind/find" || return 1
    run_cap env -i "${GSG_ENV[@]}" PATH="$SANDBOX/nofind:$PATH" GSG_EXTRACT_FILES="${TREE_FILES:-0}" GSG_EXTRACT_LINES="${TREE_LINES:-0}" bash -c \
        'set -u; set -o pipefail; source "$1/lib/core/common.sh" && source "$1/lib/scan/extract.sh" && fn="$2" && shift 2 && "$fn" "$@"' _ "$SHARE" "$fn" "$@"
}

test_scan_tree_has_file_answers_from_the_tree_not_from_find() {
    local d="$SANDBOX/tree"
    mkdir -p -- "$d/empty" "$d/only/dirs/here" "$d/a[b]*/.hid/deep" || return 1
    tree_fn scan_tree_has_file "$d/empty"
    assert_rc 1 "an empty directory holds no file"
    tree_fn scan_tree_has_file "$d/only"
    assert_rc 1 "directories only hold no file"
    printf 'x\n' >"$d/a[b]*/.hid/deep/.dot" || return 1
    tree_fn scan_tree_has_file "$d/a[b]*"
    assert_rc 0 "a hidden file in a hidden directory, below a path with glob characters, is a file"
    printf 'x\n' >"$d/only/top.txt" || return 1
    tree_fn scan_tree_has_file "$d/only"
    assert_rc 0 "a file at the top is a file"
    tree_fn scan_tree_has_file "$d/missing"
    assert_rc 2 "a directory that is not there cannot be inspected"
}

# ^ invariant counts and tree agree => a counted file with no file on disk is a broken extraction, never an empty commit (#25)
test_scan_tree_verdict_blocks_when_the_counts_say_lines_were_added_and_the_tree_is_empty() {
    local d="$SANDBOX/vtree"
    mkdir -p -- "$d" || return 1
    TREE_FILES=0 TREE_LINES=0 tree_fn scan_tree_verdict "$d"
    assert_rc 1 "no count and no file: nothing to scan"
    TREE_FILES=2 TREE_LINES=7 tree_fn scan_tree_verdict "$d"
    assert_rc 2 "counts above zero and no file: the invariant is broken"
    assert_eq "$OUT" "the extraction counted 7 added lines in 2 files but the scan tree holds no file; nothing was scanned." "the reason names both counts"
    TREE_FILES=1 TREE_LINES=0 tree_fn scan_tree_verdict "$d"
    assert_rc 2 "one file counted is enough"
    assert_contains "$OUT" "0 added lines in 1 files" "the counts are printed as they are"
    printf 'x\n' >"$d/f.txt" || return 1
    TREE_FILES=1 TREE_LINES=1 tree_fn scan_tree_verdict "$d"
    assert_rc 0 "a file on disk is scanned"
    TREE_FILES=0 TREE_LINES=0 tree_fn scan_tree_verdict "$d"
    assert_rc 0 "a file on disk is scanned whatever the counts say"
    tree_fn scan_tree_verdict "$d/missing"
    assert_rc 3 "a missing tree cannot be inspected"
}

test_dir_contents_clear_removes_every_entry_including_hidden_ones_without_find() {
    local d="$SANDBOX/clr"
    mkdir -p -- "$d/sub/.deep" "$d/-dash" || return 1
    printf 'x\n' >"$d/a.txt" && printf 'x\n' >"$d/.hid" && printf 'x\n' >"$d/sub/.deep/f" && printf 'x\n' >"$d/-rf" || return 1
    tree_fn scan_dir_clear "$d"
    assert_rc 0 "clear"
    assert_eq "$(cd -- "$d" && shopt -s dotglob nullglob && left=(*) && printf '%s' "${#left[@]}")" 0 "nothing is left, hidden entries and a name starting with a dash included"
    assert_file "$d" "the directory itself stays"
    tree_fn scan_dir_clear "$d"
    assert_rc 0 "an empty directory is cleared too"
    tree_fn scan_dir_clear "$d/missing"
    assert_rc 1 "a directory that is not there is a failure"
}

test_dir_contents_clear_fails_when_the_rm_on_path_does_nothing() {
    local d="$SANDBOX/clr2"
    mkdir -p -- "$d" "$SANDBOX/norm" || return 1
    printf 'x\n' >"$d/left.txt" && printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/norm/rm" && chmod 755 -- "$SANDBOX/norm/rm" || return 1
    # shellcheck disable=SC2016
    run_cap env -i "${GSG_ENV[@]}" PATH="$SANDBOX/norm:$PATH" bash -c \
        'set -u; source "$1/lib/core/common.sh" && source "$1/lib/scan/extract.sh" && scan_dir_clear "$2"' _ "$SHARE" "$d"
    assert_rc 1 "a no-op rm leaves the entries, the clear says so"
    assert_file "$d/left.txt" "sanity: the no-op rm removed nothing"
}

run_file_tests
