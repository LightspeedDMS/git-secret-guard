#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

DOCS_ONLY="$GSG_PROJECT/.github/scripts/docs-only.sh"
DOCS_TESTS="$GSG_PROJECT/.github/scripts/docs-tests.sh"
WORKFLOW="$GSG_PROJECT/.github/workflows/tests.yml"

docs_only() { run_cap bash "$DOCS_ONLY" "$1"; }

test_a_change_of_markdown_files_only_is_docs_only() {
    printf 'README.md\ndocs/scan.md\n' >"$SANDBOX/paths"
    docs_only "$SANDBOX/paths"
    assert_rc 0 "two Markdown files"
}

test_a_path_that_is_not_markdown_disqualifies_the_change_and_is_named() {
    printf 'README.md\nlib/core/common.sh\ndocs/x.md\n' >"$SANDBOX/paths"
    docs_only "$SANDBOX/paths"
    assert_rc 1 "a shell file among the paths"
    assert_contains "$OUT" "lib/core/common.sh" "the first disqualifying path is named"
}

test_the_cli_help_text_is_not_docs_because_the_tests_read_it() {
    printf 'README.md\nlib/cli/usage.md\n' >"$SANDBOX/paths"
    docs_only "$SANDBOX/paths"
    assert_rc 1 "usage.md"
    assert_contains "$OUT" "lib/cli/usage.md" "named"
}

test_a_markdown_file_in_another_folder_named_usage_is_docs() {
    printf 'docs/usage.md\nlib/cli/README.md\n' >"$SANDBOX/paths"
    docs_only "$SANDBOX/paths"
    assert_rc 0 "only lib/cli/usage.md is exempt"
}

test_an_extension_that_only_resembles_markdown_is_not_docs() {
    local p
    for p in 'a.markdown' 'a.md.sh' 'md' 'a.MD' 'a.mdx'; do
        printf '%s\n' "$p" >"$SANDBOX/paths"
        docs_only "$SANDBOX/paths"
        assert_rc 1 "$p"
    done
}

test_an_empty_or_blank_path_list_is_not_docs_only() {
    : >"$SANDBOX/paths"
    docs_only "$SANDBOX/paths"
    assert_rc 1 "empty file"
    assert_contains "$OUT" "no changed paths" "the reason is named"
    printf '\n\n' >"$SANDBOX/paths"
    docs_only "$SANDBOX/paths"
    assert_rc 1 "blank lines only"
    assert_contains "$OUT" "no changed paths" "the reason is named"
}

test_blank_lines_are_ignored_and_a_last_line_without_newline_counts() {
    printf 'a.md\n\nb.md\n\nc.sh' >"$SANDBOX/paths"
    docs_only "$SANDBOX/paths"
    assert_rc 1 "the unterminated last line is read"
    assert_contains "$OUT" "c.sh" "and named"
    printf 'a.md\n\nb.md' >"$SANDBOX/paths"
    docs_only "$SANDBOX/paths"
    assert_rc 0 "an unterminated Markdown last line"
}

# ^ invariant git quotes an unusual path => it cannot be proven Markdown => it is not docs
test_a_git_quoted_path_is_not_docs() {
    printf '"docs/caf\\303\\251.md"\n' >"$SANDBOX/paths"
    docs_only "$SANDBOX/paths"
    assert_rc 1 "a quoted path"
}

test_docs_only_refuses_a_missing_or_unreadable_argument() {
    printf 'a.md\n' >"$SANDBOX/a" || { fail "fixture setup failed"; return 1; }
    printf 'b.md\n' >"$SANDBOX/b" || { fail "fixture setup failed"; return 1; }
    run_cap bash "$DOCS_ONLY"
    assert_rc 2 "no argument"
    docs_only "$SANDBOX/nope"
    assert_rc 2 "a file that does not exist"
    run_cap bash "$DOCS_ONLY" "$SANDBOX/a" "$SANDBOX/b"
    assert_rc 2 "two readable arguments"
}

# ^ why the reference text is built from a variable, not written out; this file is itself a test file and must not match the pattern docs-tests.sh looks for
mk_tree() {
    local root="$1" v="\$GSG_PROJECT"
    mkdir -p "$root/tests/project" "$root/tests/scan" "$root/tests/integrations/x" &&
        : >"$root/tests/project/test_quality.sh" &&
        printf 'cat "%s/docs/x.md"\n' "$v" >"$root/tests/scan/test_zeta.sh" &&
        printf 'cat "%s/%s"\n# "%s/docs/only-comment.md"\n' "$v" "\$f" "$v" >"$root/tests/scan/test_alpha.sh" &&
        printf 'cat "%s/lib/a.sh"\n' "$v" >"$root/tests/scan/test_plain.sh" &&
        printf 'cat "%s/docs/x.md" "%s/docs/y.md"\n' "$v" "$v" >"$root/tests/scan/test_twice.sh" &&
        printf 'cat "%s/docs/z.md"\n' "$v" >"$root/tests/integrations/x/test_deep.sh"
}

test_docs_tests_lists_quality_first_then_the_readers_of_markdown_sorted_without_duplicates() {
    mk_tree "$SANDBOX/tree" || { fail "fixture setup failed"; return 1; }
    run_cap bash "$DOCS_TESTS" "$SANDBOX/tree"
    assert_rc 0 "a tree with readers"
    assert_eq "$OUT" "$(printf 'tests/project/test_quality.sh\ntests/integrations/x/test_deep.sh\ntests/scan/test_twice.sh\ntests/scan/test_zeta.sh')" "quality first, then sorted, no duplicate, both depths"
}

test_docs_tests_ignores_a_reference_that_is_only_in_a_comment_or_not_markdown() {
    mk_tree "$SANDBOX/tree" || { fail "fixture setup failed"; return 1; }
    run_cap bash "$DOCS_TESTS" "$SANDBOX/tree"
    assert_rc 0 "a tree with readers"
    assert_contains "$OUT" "tests/scan/test_zeta.sh" "a real reader is listed"
    assert_not_contains "$OUT" "test_alpha.sh" "a comment line does not count"
    assert_not_contains "$OUT" "test_plain.sh" "a .sh reference does not count"
}

# ^ why one file per spelling built from variables, not literal lines; the name shows the missed spelling, this file stays unselected
test_docs_tests_selects_every_spelling_of_the_project_variable() {
    local v="\$GSG_PROJECT" b="\${GSG_PROJECT}" root="$SANDBOX/spell"
    if ! {
        mkdir -p "$root/tests/project" "$root/tests/scan" && : >"$root/tests/project/test_quality.sh" &&
            printf 'cat "%s"/docs/x.md\n' "$v" >"$root/tests/scan/test_quoted_var_then_slash.sh" &&
            printf 'cat %s/x.md\n' "$b" >"$root/tests/scan/test_braced.sh" &&
            printf 'cat "%s"/x.md\n' "$b" >"$root/tests/scan/test_quoted_braced_then_slash.sh" &&
            printf 'cat "%s/x.md"\n' "$b" >"$root/tests/scan/test_braced_inside_quotes.sh" &&
            printf 'cat "%s"/x.sh\n' "$b" >"$root/tests/scan/test_braced_not_markdown.sh"
    }; then
        fail "fixture setup failed"
        return 1
    fi
    run_cap bash "$DOCS_TESTS" "$root"
    assert_rc 0 "a tree with every spelling"
    assert_contains "$OUT" "tests/scan/test_quoted_var_then_slash.sh" "\"\$VAR\"/x.md"
    assert_contains "$OUT" "tests/scan/test_braced.sh" "\${VAR}/x.md"
    assert_contains "$OUT" "tests/scan/test_quoted_braced_then_slash.sh" "\"\${VAR}\"/x.md"
    assert_contains "$OUT" "tests/scan/test_braced_inside_quotes.sh" "\"\${VAR}/x.md\""
    assert_not_contains "$OUT" "test_braced_not_markdown.sh" "a braced .sh reference does not count"
}

test_docs_tests_fails_when_quality_is_missing_or_the_root_is_bad() {
    mk_tree "$SANDBOX/tree" || { fail "fixture setup failed"; return 1; }
    rm "$SANDBOX/tree/tests/project/test_quality.sh" || { fail "fixture setup failed: cannot remove test_quality.sh"; return 1; }
    run_cap bash "$DOCS_TESTS" "$SANDBOX/tree"
    assert_rc 1 "no test_quality.sh"
    assert_contains "$ERR" "test_quality.sh" "named"
    assert_empty "$OUT" "nothing is printed"
    run_cap bash "$DOCS_TESTS" "$SANDBOX/no-such-root"
    assert_rc 1 "a root that does not exist"
}

test_docs_tests_on_the_real_repo_lists_every_known_reader_of_markdown() {
    run_cap bash "$DOCS_TESTS" "$GSG_PROJECT"
    assert_rc 0 "the real repo"
    assert_eq "${OUT%%$'\n'*}" "tests/project/test_quality.sh" "quality is first"
    assert_contains "$OUT" "tests/project/test_dco.sh" "dco"
    assert_contains "$OUT" "tests/scan/test_reminder.sh" "reminder"
    assert_contains "$OUT" "tests/gitup/test_gitup_apt_state.sh" "gitup apt state"
    assert_contains "$OUT" "tests/gitup/test_gitup_apt_ppa.sh" "gitup apt ppa"
    assert_not_contains "$OUT" "tests/project/test_ci_plan.sh" "this file reads no project Markdown"
}

# ^ invariant a test file with a non-comment line naming the project root and .md is listed => a new kind of reader fails here, not skipped on docs-only
# ^ why no exemption list, not a loose guard; on the real repo each such file reads Markdown, none only names a fixture
test_docs_tests_lists_every_test_file_that_mentions_the_project_root_and_markdown() {
    local flagged f missing=""
    run_cap bash "$DOCS_TESTS" "$GSG_PROJECT"
    assert_rc 0 "the real repo"
    flagged="$(cd -- "$GSG_PROJECT" && LC_ALL=C grep -l -E -e '^[^#]*GSG_PROJECT[^#]*\.md' -e '^[^#]*\.md[^#]*GSG_PROJECT' tests/*/test_*.sh tests/*/*/test_*.sh)"
    case "$?" in
        0) ;;
        *) fail "the guard scan of the test files failed"; return 1 ;;
    esac
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$f" = "tests/project/test_ci_plan.sh" ] && continue
        case "$OUT" in
            *"$f"*) ;;
            *) missing="$missing $f" ;;
        esac
    done <<<"$flagged"
    assert_eq "$missing" "" "docs-tests.sh lists every file that mentions the project root and .md"
}

# ^ invariant branch protection names these checks => a rename in the workflow leaves a required check never reporting
test_the_workflow_still_declares_every_required_check_it_owns() {
    local pat
    for pat in '^    name: suite \(head\)$' '^  windows-suite:$' '^  macos-suite:$' '^  windows:$' '^  macos-list-complete:$' '^    name: suite \(base\)$'; do
        grep -q -E "$pat" "$WORKFLOW" || fail "tests.yml has no line matching $pat"
    done
}

test_the_workflow_has_no_matrix_job_left_that_would_hide_suite_head() {
    local rc=0
    grep -q -E '^[[:space:]]+matrix:' "$WORKFLOW" || rc=$?
    case "$rc" in
        0) fail "a matrix job would not report suite (head)" ;;
        1) ;;
        *) fail "cannot read $WORKFLOW (grep rc=$rc)" ;;
    esac
}

run_file_tests
