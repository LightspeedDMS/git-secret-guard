#!/usr/bin/env bash
# ^ invariant the installed hook loads the libraries listed in lib/core/common.sh and blocks the commit when one is missing
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

# ^ invariant a list shorter than these means a broken reader => the test fails instead of looping over nothing
HL_MIN_LIBS=4
HL_MIN_FILES=5
HL_MIN_UNLISTED=10

# ^ invariant the lists come out of lib/core/common.sh, the file the hook reads them from => this test holds no copy to drift
hl_share_list() {
    # shellcheck disable=SC2016
    bash -c 'source "$1/lib/core/common.sh" && if [ "$2" = libs ]; then printf "%s\n" "${GSG_HOOK_LIBS[@]}"; else printf "%s\n" "${GSG_HOOK_FILES[@]}"; fi' _ "$GSG_PROJECT" "$1"
}

hl_commit_probe() {
    new_repo "probe$RANDOM" && stage_file src/ok.txt hello "nothing secret" || return 1
    commit_cap probe
}

# ^ invariant hl_probe_without REL moves lib/REL of the share aside, runs one commit and puts the file back; the commit's result stays in RC, OUT and ERR
hl_probe_without() {
    mv -- "$LC_DATA/lib/$1" "$LC_DATA/lib/$1.aside" || return 1
    hl_commit_probe
    mv -- "$LC_DATA/lib/$1.aside" "$LC_DATA/lib/$1" || return 1
}

# ^ invariant hl_require_entries NAME MIN ENTRY... fails the test when fewer than MIN entries came back or the first is empty
hl_require_entries() {
    local name="$1" min="$2"
    shift 2
    if [ "$#" -lt "$min" ] || [ -z "${1:-}" ]; then
        fail "the $name holds too few entries ($#)"
        return 1
    fi
}

test_the_hook_loads_exactly_the_libraries_in_the_shared_list() {
    local lib f name listed
    local -a libs=() files=() moved=()
    fresh_install
    mapfile -t libs < <(hl_share_list libs)
    mapfile -t files < <(hl_share_list files)
    hl_require_entries "shared library list" "$HL_MIN_LIBS" "${libs[@]}" || return 1
    assert_not_contains "$(<"$GSG_PROJECT/hooks/secret-scan")" "extract.sh exempt.sh" "the hook holds no list of its own"
    assert_contains "$(<"$GSG_PROJECT/hooks/secret-scan")" 'GSG_HOOK_LIBS' "the hook loops over the shared list"
    for lib in core/common.sh "${libs[@]}"; do
        hl_probe_without "$lib" || return 1
        assert_rc 1 "$lib missing"
        assert_contains "$ERR" "cannot load $LC_DATA/lib/$lib; nothing was scanned" "the hook names $lib"
    done
    while IFS= read -r f; do
        name="${f#"$LC_DATA"/lib/}"
        listed=0
        for lib in core/common.sh "${libs[@]}" "${files[@]}"; do if [ "$lib" = "$name" ]; then listed=1; fi; done
        if [ "$listed" -eq 1 ]; then continue; fi
        mv -- "$f" "$f.aside" || return 1
        moved+=("$f")
    done < <(find "$LC_DATA/lib" -type f | sort)
    [ "${#moved[@]}" -ge "$HL_MIN_UNLISTED" ] || fail "only ${#moved[@]} unlisted files were moved aside"
    hl_commit_probe
    for f in "${moved[@]}"; do mv -- "$f.aside" "$f" || return 1; done
    assert_not_contains "$ERR" "cannot load" "no library outside the lists is loaded"
    assert_not_contains "$ERR" "wrapper failed" "no file outside the lists is run by a scanner wrapper"
    assert_not_contains "$ERR" "extracting" "no file outside the lists is read by the extraction"
    assert_not_contains "$ERR" "unreadable" "no file outside the lists is read by an adapter"
    assert_contains "$ERR" "scanner did not complete" "the hook reached the scanners without them"
}

test_the_hook_blocks_on_its_own_when_the_library_list_is_empty_or_unset() {
    local variant file
    for variant in '()' '("")' unset; do
        fresh_install
        file="$LC_DATA/lib/core/common.sh"
        if [ "$variant" = unset ]; then
            sed 's/^GSG_HOOK_LIBS=.*/unset GSG_HOOK_LIBS/' "$file" >"$SANDBOX/common.edit" || return 1
        else
            sed "s/^GSG_HOOK_LIBS=.*/GSG_HOOK_LIBS=$variant/" "$file" >"$SANDBOX/common.edit" || return 1
        fi
        cat -- "$SANDBOX/common.edit" >"$file" || return 1
        hl_commit_probe
        assert_rc 1 "list $variant"
        assert_contains "$ERR" "cannot load the hook library list (GSG_HOOK_LIBS in $LC_DATA/lib/core/common.sh); nothing was scanned." "list $variant: the hook's own block"
        assert_not_contains "$ERR" "command not found" "list $variant: not by accident later on"
    done
}

test_the_hook_blocks_when_a_file_it_reads_is_missing() {
    local rel
    local -a files=()
    fresh_install
    mapfile -t files < <(hl_share_list files)
    hl_require_entries "shared file list" "$HL_MIN_FILES" "${files[@]}" || return 1
    for rel in "${files[@]}"; do
        hl_probe_without "$rel" || return 1
        assert_rc 1 "$rel missing"
        assert_contains "$ERR" "${rel##*/}" "the hook names $rel"
        assert_contains "$ERR" "To bypass this check for one commit" "and blocks the commit"
    done
}

run_file_tests
