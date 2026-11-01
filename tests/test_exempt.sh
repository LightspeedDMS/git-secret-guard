#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck disable=SC2016
ex() { run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c 'set -u; source "$1/lib/common.sh" && source "$1/lib/exempt.sh" && shift && "$@"' _ "$SHARE" "$@"; }

ignore_file() {
    local f="$SANDBOX/ignore-$1"
    shift
    printf '%s\n' "$@" >"$f"
    printf '%s' "$f"
}

test_parse_skips_comments_and_blanks_and_trims_each_pattern() {
    local f
    f="$(ignore_file ok '# a comment' '' 'tests/fixtures/**   # synthetic keys for parser tests' $'   docs/*.md\t#\tgenerated docs' '   ' '    # indented comment')"
    ex scan_ignore_parse "$f"
    assert_rc 0 parse
    assert_eq "$OUT" "$(printf '3\ttests/fixtures/**\ttests/fixtures/**\n4\tdocs/*.md\tdocs/*.md')" "line numbers are the file's own, patterns are trimmed, the written form has no anchor to keep"
    assert_empty "$ERR" "a valid file prints nothing to stderr"
}

test_a_pattern_without_a_reason_is_invalid_and_every_bad_line_is_named() {
    local f
    f="$(ignore_file noreason 'a/** # fine' 'no-hash/**' 'empty/**   #' 'blank/**   #    ' 'hashes/** # #' 'glued/**#reason' 'last/** # ok again')"
    ex scan_ignore_parse "$f"
    assert_rc 1 "invalid file"
    local n
    for n in 2 3 4 5 6; do
        assert_contains "$ERR" "git-secret-guard: .secret-scan-ignore line $n:" "line $n named"
    done
    assert_not_contains "$ERR" "line 1:" "valid line 1 is not named"
    assert_not_contains "$ERR" "line 7:" "valid line 7 is not named"
    assert_contains "$ERR" "reason" "says what is missing"
}

test_parse_normalizes_crlf_leading_slash_and_dot_slash() {
    local f
    f="$(ignore_file norm $'src/gen/** # crlf file\r' '/docs/** # anchored' './build/** # dot slash' '//x/** # many slashes' '././y/** # many dots')"
    ex scan_ignore_parse "$f"
    assert_rc 0 parse
    assert_eq "$OUT" "$(printf '1\tsrc/gen/**\tsrc/gen/**\n2\tdocs/**\t/docs/**\n3\tbuild/**\t./build/**\n4\tx/**\t//x/**\n5\ty/**\t././y/**')" "git pathspecs are relative to the root, so anchors are removed; the third column keeps what was written"
}

test_parse_rejects_control_characters_empty_patterns_and_oversized_files() {
    local f
    f="$(ignore_file bad $'tab\tinside # r' $'esc\033[31m/** # r' '/ # only a slash' './ # only dot slash')"
    ex scan_ignore_parse "$f"
    assert_rc 1 "invalid"
    local n
    for n in 1 2 3 4; do assert_contains "$ERR" "git-secret-guard: .secret-scan-ignore line $n:" "line $n named"; done
    assert_not_contains "$ERR" $'\033' "control characters are never echoed"
    local big="$SANDBOX/ignore-big" i
    for ((i = 0; i < 1001; i++)); do printf 'p%s/** # r\n' "$i"; done >"$big"
    ex scan_ignore_parse "$big"
    assert_rc 1 "too many lines"
    assert_contains "$ERR" "git-secret-guard: .secret-scan-ignore has more than 1000 lines" "says why, with the hook's prefix"
    assert_empty "$OUT" "nothing is returned for an oversized file"
}

test_parse_rejects_patterns_that_climb_out_of_the_repository() {
    local f
    f="$(ignore_file dotdot '../x # r' 'a/../b # r' '.. # r' 'a/.. # r' 'a..b/** # fine' '..hidden/** # fine')"
    ex scan_ignore_parse "$f"
    assert_rc 1 "invalid"
    local n
    for n in 1 2 3 4; do assert_contains "$ERR" "git-secret-guard: .secret-scan-ignore line $n:" "line $n named"; done
    assert_not_contains "$ERR" "line 5:" "a..b is a normal name"
    assert_not_contains "$ERR" "line 6:" "..hidden is a normal name"
    assert_eq "$OUT" "$(printf '5\ta..b/**\ta..b/**\n6\t..hidden/**\t..hidden/**')" "valid lines are still returned"
}

test_head_blob_is_read_from_the_commit_only() {
    new_repo headblob || return 1
    local dest="$SANDBOX/head-copy"
    ex exempt_head_blob .secret-scan-ignore "$dest"
    assert_rc 1 "no HEAD yet (first commit) means absent"
    stage_file .secret-scan-ignore 'staged/** # not committed'
    ex exempt_head_blob .secret-scan-ignore "$dest"
    assert_rc 1 "a staged file is not at HEAD"
    gitx rm -q --cached .secret-scan-ignore
    stage_file other.txt hello
    gitx commit -q --no-verify -m "base without the file"
    ex exempt_head_blob .secret-scan-ignore "$dest"
    assert_rc 1 "the commit does not hold the file, the index does"
    gitx add .secret-scan-ignore && gitx commit -q --no-verify -m "ignore file"
    ex exempt_head_blob .secret-scan-ignore "$dest"
    assert_rc 0 "committed"
    assert_eq "$(<"$dest")" 'staged/** # not committed' "HEAD content"
    printf 'worktree/** # edited\n' >.secret-scan-ignore
    stage_file .secret-scan-ignore 'index/** # edited and staged'
    printf 'worktree/** # edited again\n' >.secret-scan-ignore
    ex exempt_head_blob .secret-scan-ignore "$dest"
    assert_rc 0 "still committed"
    assert_eq "$(<"$dest")" 'staged/** # not committed' "neither the index nor the work tree counts"
}

test_head_blob_refuses_a_symlink_accepts_an_executable_and_reports_an_unreadable_tree_as_an_error() {
    new_repo headmode || return 1
    local dest="$SANDBOX/head-copy3"
    ln -s '**   # reads as a catch-all, reviews as a one-line symlink' .secret-scan-ignore
    printf 'tool/** # executable file\n' >.gitleaksignore && chmod +x .gitleaksignore
    gitx add .secret-scan-ignore .gitleaksignore && gitx commit -q --no-verify -m "link and executable"
    ex exempt_head_blob .secret-scan-ignore "$dest"
    assert_rc 3 "a symlink is not a regular file"
    ex exempt_head_blob .gitleaksignore "$dest"
    assert_rc 0 "mode 100755 is a regular file"
    local tree
    tree="$(gitx rev-parse 'HEAD^{tree}')"
    rm -f -- ".git/objects/${tree:0:2}/${tree:2}"
    ex exempt_head_blob .gitleaksignore "$dest"
    assert_rc 2 "an unreadable root tree is an error, not an absent file"
}

test_head_blob_reports_a_non_file_as_an_error() {
    new_repo headtree || return 1
    stage_file .secret-scan-ignore/inner.txt hello
    gitx commit -q --no-verify -m "a directory with that name"
    ex exempt_head_blob .secret-scan-ignore "$SANDBOX/head-copy2"
    assert_rc 3 "a directory at HEAD is an error, not an absent file"
}

test_the_probe_secret_is_an_aws_key_id_shape_built_from_fragments() {
    ex gitleaks_probe_secret
    assert_rc 0 "prints"
    [[ $OUT =~ ^AKIA[A-Z2-7]{16}$ ]] || fail "not an AWS access key id shape: ${#OUT} chars"
    assert_eq "$(grep -rlF -- "$OUT" "$GSG_PROJECT/lib" "$GSG_PROJECT/hooks" | wc -l)" 0 "the full value is not a literal in the shipped code"
}

test_the_pre_flight_runs_gitleaks_under_the_configured_timeout_binary_never_PATH() {
    mkdir -p -- "$SANDBOX/poison" "$SANDBOX/wrap"
    printf '#!/bin/bash\necho PATH-USED >>"%s/poison.log"\nexit 99\n' "$SANDBOX" >"$SANDBOX/poison/timeout"
    # shellcheck disable=SC2016
    printf '#!/bin/bash\necho "$0" >>"%s/wrap.log"\nexec /bin/timeout "$@"\n' "$SANDBOX" >"$SANDBOX/wrap/timeout"
    chmod +x "$SANDBOX/poison/timeout" "$SANDBOX/wrap/timeout"
    printf '[extend]\nuseDefault = true\n' >"$SANDBOX/pf.toml"
    set_env PATH="$SANDBOX/poison:/usr/local/bin:/usr/bin:/bin" GITLEAKS_BIN="$STUBS_DIR/gitleaks" TIMEOUT_BIN="$SANDBOX/wrap/timeout" \
        STUB_LOG="$SANDBOX/pf-calls"
    ex gitleaks_config_preflight "$SANDBOX/pf.toml" "$SANDBOX/pf-work" 20
    assert_rc 0 "the probe is reported by the stand-in"
    assert_no_file "$SANDBOX/poison.log" "PATH timeout was not used"
    assert_contains "$(<"$SANDBOX/wrap.log")" "$SANDBOX/wrap/timeout" "configured timeout was used"
    set_env TIMEOUT_BIN="$SANDBOX/missing"
    ex gitleaks_config_preflight "$SANDBOX/pf.toml" "$SANDBOX/pf-work2" 20
    assert_rc 1 "an unusable timeout binary blocks"
    assert_contains "$ERR" "timeout" "names it"
    assert_contains "$ERR" "nothing was scanned" "says nothing was scanned"
}

test_the_pre_flight_needs_an_explicit_positive_timeout() {
    local bad
    printf '[extend]\nuseDefault = true\n' >"$SANDBOX/pf.toml"
    set_env GITLEAKS_BIN=/nonexistent/gitleaks
    ex gitleaks_config_preflight "$SANDBOX/pf.toml" "$SANDBOX/pf-work"
    assert_rc 1 "no timeout argument"
    assert_contains "$ERR" "needs a timeout in seconds" "says what is missing"
    for bad in 0 abc -5 ''; do
        ex gitleaks_config_preflight "$SANDBOX/pf.toml" "$SANDBOX/pf-work" "$bad"
        assert_rc 1 "timeout [$bad]"
        assert_contains "$ERR" "needs a timeout in seconds" "timeout [$bad] is refused before anything runs"
    done
    assert_no_file "$SANDBOX/pf-work" "and nothing was created"
}

probe_dir() {
    local d="$SANDBOX/probe"
    if [ ! -d "$d" ]; then
        ex scan_ignore_probe_init "$d"
        assert_rc 0 "probe init"
    fi
    printf '%s' "$d"
}

scope_of() {
    ex scan_ignore_scope "$(probe_dir)" "$1"
}

test_scope_classifies_trivial_catch_all_variants_via_git_pathspec_matching() {
    local p
    for p in '**' '**/*' '**/**'; do
        scope_of "$p"
        assert_rc 0 "scope of [$p]"
        assert_eq "$OUT" whole "[$p] exempts every probe path at every depth"
    done
    scope_of '*'
    assert_eq "$OUT" top "[*] matches every top-level name but does not cross a slash in git's glob pathspecs"
    for p in '*/**' '**/*/**'; do
        scope_of "$p"
        assert_eq "$OUT" nested "[$p] matches everything below the top level"
    done
}

test_scope_leaves_ordinary_patterns_alone() {
    local p
    for p in 'tests/fixtures/**' '*.txt' '**/*.pem' 'src/**' 'a' 'docs/' '**/*.txt' '*.*' '*/*' '.github/**' '**/.*' '**/' '[' 'a b/**' '.'; do
        scope_of "$p"
        assert_rc 0 "scope of [$p]"
        assert_eq "$OUT" none "[$p] is an ordinary pattern"
    done
}

test_scope_fails_closed_when_the_probe_repo_is_unusable() {
    ex scan_ignore_scope "$SANDBOX/no-such-probe" '**'
    assert_rc 2 "no probe repo"
    assert_empty "$OUT" "no scope is claimed"
}

run_file_tests
