#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

DOCS_ONLY="$GSG_PROJECT/.github/scripts/docs-only.sh"
DOCS_TESTS="$GSG_PROJECT/.github/scripts/docs-tests.sh"
WORKFLOW="$GSG_PROJECT/.github/workflows/tests.yml"
# ^ why a depth of 8 bounds the search for nested actions, not an unbounded find
PIN_ACTION_MAX_DEPTH=8
# ^ why a depth of 1 for workflows, not a recursive search; GitHub ignores a workflow in a subfolder
PIN_WORKFLOW_DEPTH=1
PIN_TREE_SHA="3d3c42e5aac5ba805825da76410c181273ba90b1"
PIN_TREE_UPLOAD_SHA="cf430e030ddbb5b0abf93d22962f4752f3646cd9"

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
    assert_contains "$OUT" "tests/gitup/test_gitup_apt.sh" "gitup apt"
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

# ^ why rc 1 for a missing block or key and rc 2 for a failed awk, not an empty value compared as equal
concurrency_value() {
    local key="$1" block line rc=0
    block="$(awk '/^concurrency:/ { inb = 1; next } inb && /^[^[:space:]]/ { exit } inb && /^[[:space:]]*#/ { next } inb && NF { print }' "$WORKFLOW")" || rc=$?
    [ "$rc" -eq 0 ] || { printf 'cannot read %s (awk rc=%s)\n' "$WORKFLOW" "$rc" >&2; return 2; }
    while IFS= read -r line; do
        case "$line" in
            "  $key: "*) printf '%s' "${line#"  $key: "}"; return 0 ;;
        esac
    done <<<"$block"
    return 1
}

# ^ invariant main runs per commit and is never cancelled, other refs cancel superseded runs => two quick merges to main each get a full run
test_the_workflow_runs_every_main_commit_and_cancels_only_superseded_runs_elsewhere() {
    local want_group="tests-\${{ github.workflow }}-\${{ github.ref == 'refs/heads/main' && github.sha || github.ref }}"
    local want_cancel="\${{ github.ref != 'refs/heads/main' }}" got rc
    got="$(concurrency_value group)" && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || { fail "tests.yml concurrency block has no group: key (rc=$rc)"; return 1; }
    assert_eq "$got" "$want_group" "concurrency group"
    got="$(concurrency_value cancel-in-progress)" && rc=0 || rc=$?
    [ "$rc" -eq 0 ] || { fail "tests.yml concurrency block has no cancel-in-progress: key (rc=$rc)"; return 1; }
    assert_eq "$got" "$want_cancel" "concurrency cancel-in-progress"
}

# ^ hazard the scan misses an action deeper than PIN_ACTION_MAX_DEPTH, a local action outside .github/actions, a symlink, a quoted or flow-mapping uses key
pin_find() {
    local dir="$1" depth="$2" found rc=0
    shift 2
    [ -d "$dir" ] || return 0
    found="$(find "$dir" -maxdepth "$depth" -type f \( "$@" \))" || rc=$?
    [ "$rc" -eq 0 ] || { printf 'find failed in %s (rc=%s)\n' "$dir" "$rc" >&2; return 2; }
    printf '%s\n' "$found"
}

many_values() { printf '%s' "$1" | sort -u | cut -d' ' -f1 | sort | uniq -d; }

# ^ why one problem per line with rc 1 and rc 2 for a failed scan, not a bare pass or fail, with a scratch tree proving each kind
pin_problems() {
    local root="$1" files f uses line text pin='^[[:space:]-]*uses:[[:space:]]+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@([0-9a-f]{40}) # (v[0-9]+\.[0-9]+\.[0-9]+)$' localuse='^[[:space:]-]*uses:[[:space:]]+\./' pairs="" tags="" dup out="" rc
    files="$(pin_find "$root/.github/workflows" "$PIN_WORKFLOW_DEPTH" -name '*.yml' -o -name '*.yaml')" || return 2
    files="$files"$'\n'"$(pin_find "$root/.github/actions" "$PIN_ACTION_MAX_DEPTH" -name action.yml -o -name action.yaml)" || return 2
    [ -n "${files//$'\n'/}" ] || { printf 'no workflow or action file under %s\n' "$root" >&2; return 2; }
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rc=0
        uses="$(LC_ALL=C grep -n -E -e '^[[:space:]-]*uses:[[:space:]]' -- "$f")" || rc=$?
        case "$rc" in
            0 | 1) ;;
            *) printf 'cannot scan %s for uses: lines (grep rc=%s)\n' "$f" "$rc" >&2; return 2 ;;
        esac
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            text="${line#*:}"
            [[ "$text" =~ $localuse ]] && continue
            if [[ "$text" =~ $pin ]]; then
                pairs="$pairs${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"$'\n'
                tags="$tags${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"$'\n'
            else
                out="${out}not pinned as owner/repo@<40 hex> # vX.Y.Z: ${f#"$root"/}:${line%%:*}:$text"$'\n'
            fi
        done <<<"$uses"
    done <<<"$files"
    dup="$(many_values "$pairs")" || { printf 'cannot compare the pins per repo\n' >&2; return 2; }
    [ -z "$dup" ] || out="${out}more than one SHA for: $dup"$'\n'
    dup="$(many_values "$tags")" || { printf 'cannot compare the tags per SHA\n' >&2; return 2; }
    [ -z "$dup" ] || out="${out}more than one tag for SHA: $dup"$'\n'
    printf '%s' "$out"
    [ -z "$out" ]
}

# ^ invariant an external action is pinned by full commit SHA with a release-tag comment (shape only), one SHA per repo => a moved tag cannot change CI
test_every_external_action_is_pinned_by_full_sha_with_a_release_tag_comment_and_one_sha_per_repo() {
    run_cap pin_problems "$GSG_PROJECT"
    assert_rc 0 "the real workflows and actions"
    assert_empty "$OUT" "no unpinned or inconsistent action"
}

# ^ why one builder with a single broken file per test, not a hand-made tree in every test
mk_pin_tree() {
    local root="$1" in_yaml="$2" in_action_yaml="$3"
    mkdir -p "$root/.github/workflows" "$root/.github/actions/a/b" &&
        printf 'steps:\n  - uses: actions/checkout@%s # v7.0.1\n  - uses: ./.github/actions/a/b\n' "$PIN_TREE_SHA" >"$root/.github/workflows/ok.yml" &&
        printf 'runs:\n  steps:\n    - uses: actions/upload-artifact@%s # v7.0.2\n' "$PIN_TREE_UPLOAD_SHA" >"$root/.github/actions/a/b/action.yml" &&
        printf '%s' "$in_yaml" >"$root/.github/workflows/extra.yaml" &&
        printf '%s' "$in_action_yaml" >"$root/.github/actions/a/b/action.yaml"
}

test_the_pin_scan_accepts_a_clean_tree() {
    mk_pin_tree "$SANDBOX/t" '' '' || { fail "fixture setup failed"; return 1; }
    run_cap pin_problems "$SANDBOX/t"
    assert_rc 0 "a clean tree"
    assert_empty "$OUT" "nothing flagged"
}

test_the_pin_scan_flags_a_yaml_workflow_and_a_nested_action_pinned_by_tag() {
    mk_pin_tree "$SANDBOX/t" '  - uses: actions/checkout@v4
' '    - uses: actions/checkout@v4
' || { fail "fixture setup failed"; return 1; }
    run_cap pin_problems "$SANDBOX/t"
    assert_rc 1 "tags instead of SHAs"
    assert_contains "$OUT" ".github/workflows/extra.yaml:1:" "the .yaml workflow is named with its line"
    assert_contains "$OUT" ".github/actions/a/b/action.yaml:1:" "the nested action.yaml is named with its line"
}

# ^ invariant one commit SHA carries one tag comment in every file => a stale comment cannot name a release the SHA is not
test_the_pin_scan_flags_one_sha_carrying_two_tags() {
    mk_pin_tree "$SANDBOX/t" "  - uses: actions/checkout@$PIN_TREE_SHA # v7.0.0
" '' || { fail "fixture setup failed"; return 1; }
    run_cap pin_problems "$SANDBOX/t"
    assert_rc 1 "the same SHA under v7.0.1 in ok.yml and v7.0.0 in extra.yaml"
    assert_contains "$OUT" "more than one tag for SHA: $PIN_TREE_SHA" "the tag-conflict problem names the SHA"
}

run_file_tests
