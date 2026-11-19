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

probe_commit() {
    local path="$1" file="$2" value="$3"
    printf '%s\n' "$value" >"$path/$file" || return 1
    gitx -C "$path" add -- "$file" && gitx -C "$path" commit -qm "$value"
}

test_safe_directory_command_line_override_with_simulated_owner() {
    local repo="$SANDBOX/owner-repo" head
    probe_repo "$repo" || return 1
    probe_commit "$repo" file one || return 1
    head="$(gitx -C "$repo" rev-parse HEAD)" || return 1
    run_cap env -i "${GSG_ENV[@]}" GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "$GIT" -C "$repo" rev-parse HEAD
    assert_rc 128 "different owner is rejected without exception"
    assert_contains "$ERR" "dubious ownership" "git reports ownership refusal"
    run_cap env -i "${GSG_ENV[@]}" GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "$GIT" -c "safe.directory=$repo" -C "$repo" rev-parse HEAD
    assert_rc 0 "exact command-line safe.directory permits read-only git"
    assert_eq "$OUT" "$head" "HEAD is read"
}

test_moved_tag_fetch_is_rejected_without_force() {
    local src="$SANDBOX/src" work="$SANDBOX/clone" bare="$SANDBOX/origin.git" a fetched
    probe_repo "$src" || return 1
    probe_commit "$src" file first || return 1
    gitx -C "$src" tag -a vT -m first || return 1
    a="$(gitx -C "$src" rev-parse HEAD)" || return 1
    gitx clone --bare -q "$src" "$bare" || return 1
    gitx clone -q "$bare" "$work" || return 1
    gitx -C "$src" remote add origin "$bare" || return 1
    gitx -C "$work" config user.name Probe && gitx -C "$work" config user.email probe@example.invalid || return 1
    fetched="$(gitx -C "$work" rev-parse 'refs/tags/vT^{commit}')" || return 1
    assert_eq "$fetched" "$a" "clone starts with vT at commit A"
    probe_commit "$src" file second || return 1
    gitx -C "$src" tag -fa vT -m moved >/dev/null || return 1
    gitx -C "$src" push -q origin main || return 1
    gitx -C "$src" push -q --force origin refs/tags/vT || return 1
    run_cap env -i "${GSG_ENV[@]}" "$GIT" -C "$work" fetch --no-recurse-submodules origin '+refs/heads/main:refs/remotes/origin/main' 'refs/tags/v*:refs/tags/v*'
    assert_rc 1 "moved tag fetch is rejected"
    assert_contains "$ERR" rejected "fetch reports the tag update as rejected"
    assert_contains "$ERR" "would clobber existing tag" "fetch explains the rejection"
    fetched="$(gitx -C "$work" rev-parse 'refs/tags/vT^{commit}')" || return 1
    assert_eq "$fetched" "$a" "local tag remains at commit A"
}

test_ff_only_peeled_annotated_tag_and_tag_object_observation() {
    local commit="$SANDBOX/merge-commit" tagged="$SANDBOX/merge-tagged" target head
    probe_repo "$commit" && probe_commit "$commit" file one || return 1
    probe_commit "$commit" file two || return 1
    gitx -C "$commit" tag -a vX -m annotated || return 1
    target="$(gitx -C "$commit" rev-parse 'refs/tags/vX^{commit}')" || return 1
    gitx -C "$commit" reset --hard HEAD^ >/dev/null || return 1
    gitx -C "$commit" merge --ff-only 'refs/tags/vX^{commit}' || return 1
    head="$(gitx -C "$commit" rev-parse HEAD)" || return 1
    assert_eq "$head" "$target" "peeled annotated tag fast-forwards to commit"
    assert_rc 0 "peeled tag merge completed"

    probe_repo "$tagged" && probe_commit "$tagged" file one || return 1
    probe_commit "$tagged" file two || return 1
    gitx -C "$tagged" tag -a vX -m annotated || return 1
    gitx -C "$tagged" reset --hard HEAD^ >/dev/null || return 1
    run_cap env -i "${GSG_ENV[@]}" "$GIT" -C "$tagged" merge --ff-only refs/tags/vX
    assert_rc 0 "annotated tag object merge result recorded"
    head="$(gitx -C "$tagged" rev-parse HEAD)" || return 1
    target="$(gitx -C "$tagged" rev-parse 'refs/tags/vX^{commit}')" || return 1
    assert_eq "$head" "$target" "tag object merge also fast-forwards on this git"
    assert_eq "$(gitx -C "$tagged" rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" 2 "no merge commit was made"
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
