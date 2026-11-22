#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

probe_repo() {
    local path="$1"
    mkdir -p -- "$path" || return 1
    gitx -C "$path" init -q || return 1
    gitx -C "$path" config user.name Probe || return 1
    gitx -C "$path" config user.email probe@example.invalid || return 1
}

test_archive_filter_and_export_attributes_observation() {
    local repo="$SANDBOX/archive" marker="$SANDBOX/filter-ran" archive="$SANDBOX/archive.tar" output="$SANDBOX/extract" short
    probe_repo "$repo" || return 1
    printf 'filtered\n' >"$repo/data.txt"
    # shellcheck disable=SC2016
    printf 'visible $Format:%%h$\n' >"$repo/visible.txt"
    printf 'ignored\n' >"$repo/ignored.txt"
    printf 'visible.txt export-subst\nignored.txt export-ignore\n' >"$repo/.gitattributes"
    gitx -C "$repo" config filter.probe.clean "touch $marker; cat" || return 1
    gitx -C "$repo" config filter.probe.smudge "touch $marker; cat" || return 1
    printf 'data.txt filter=probe\n' >"$repo/.git/info/attributes"
    gitx -C "$repo" add -- .gitattributes data.txt visible.txt ignored.txt && gitx -C "$repo" commit -qm archive || return 1
    gitx -C "$repo" tag -a vX -m archive || return 1
    rm -f -- "$marker"
    short="$(gitx -C "$repo" rev-parse --short HEAD)" || return 1
    gitx -C "$repo" archive --format=tar vX >"$archive" || return 1
    assert_file "$marker" "archive ran owner-configured filter"
    mkdir -p -- "$output" && tar -xf "$archive" -C "$output" || return 1
    assert_file "$output/data.txt" "filtered file is archived"
    assert_no_file "$output/ignored.txt" "export-ignore is honored"
    assert_file "$output/visible.txt" "export-subst file is included"
    assert_eq "$(<"$output/visible.txt")" "visible $short" "export-subst expands the commit hash"
}

run_file_tests
