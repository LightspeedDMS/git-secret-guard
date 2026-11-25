#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

NOTES_SCRIPT="$GSG_PROJECT/.github/scripts/release-notes.sh"
RELEASE_WORKFLOW="$GSG_PROJECT/.github/workflows/release.yml"
# ^ why a made-up commit and URL, not a real one; the script only compares strings
FAKE_SHA="0123456789abcdef0123456789abcdef01234567"
OTHER_SHA="ffffffffffffffffffffffffffffffffffffffff"
FAKE_PR_URL="https://example.com/owner/repo/pull/82"
MERGED_AT="2026-01-02T03:04:05Z"

# ^ why every fixture step goes through fixture or put, not a bare command; a failed step is named instead of showing as a wrong assertion
fixture() { "$@" || { fail "fixture setup failed: $1"; return 1; }; }
put() { printf '%s' "$2" >"$1" || { fail "fixture setup failed: write $1"; return 1; }; }

# ^ invariant mk_pulls FILE TITLE MERGED_AT MERGE_SHA BODY writes a one-element answer of the commit pulls API; MERGED_AT "null" = not merged
mk_pulls() {
    # shellcheck disable=SC2016 # $title and the like are jq variables bound by --arg
    "$TEST_JQ" -n --arg title "$2" --arg merged "$3" --arg sha "$4" --arg body "$5" --arg url "$FAKE_PR_URL" \
        '[{number: 82, title: $title, body: $body, html_url: $url, merge_commit_sha: $sha, merged_at: (if $merged == "null" then null else $merged end)}]' >"$1"
}

set_pulls() { fixture mk_pulls "$SANDBOX/pulls.json" "$@"; }

# ^ why a good case in $SANDBOX by default, not a fixture per test; each test breaks the one input it is about
require_good_inputs() {
    put "$SANDBOX/VERSION" $'1.4.1\n' && put "$SANDBOX/released.txt" $'v1.4.0\nv1.3.0\n' &&
        set_pulls "Release 1.4.1" "$MERGED_AT" "$FAKE_SHA" $'Lists #80 and #81.\n\nBump: patch.'
}

# ^ invariant replace_pulls CMD... makes the stdout of CMD the new pulls.json via a temp file, a failed CMD leaves the old one
replace_pulls() {
    fixture "$@" >"$SANDBOX/replace.json" && fixture mv -- "$SANDBOX/replace.json" "$SANDBOX/pulls.json"
}

edit_pulls() { replace_pulls "$TEST_JQ" "$@" "$SANDBOX/pulls.json"; }

# ^ why the release pull request is the second of two arrays, not one; gh api --paginate prints one array per page
combine_pages() {
    fixture cp -- "$SANDBOX/pulls.json" "$SANDBOX/page2.json" && set_pulls "Something else" "$MERGED_AT" "$OTHER_SHA" "x" &&
        replace_pulls cat -- "$SANDBOX/pulls.json" "$SANDBOX/page2.json"
}

# ^ why the script gets the harness PATH first, not a test hook in it; on Windows the plain jq.exe sits in the sandbox jqbin of TEST_BASE_PATH
run_script() { run_cap env "PATH=$TEST_BASE_PATH:$PATH" bash "$NOTES_SCRIPT" "$@"; }

# ^ why carriage returns are dropped only on Windows, not everywhere; a plain jq.exe writes CRLF and the text is otherwise compared byte for byte
notes_text() {
    local t
    t="$(<"$SANDBOX/notes.md")" || { fail "cannot read notes.md"; return 1; }
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then t="${t//$'\r'/}"; fi
    printf '%s' "$t"
}

run_notes() {
    rm -f -- "$SANDBOX/notes.md" || { fail "cannot clear notes.md"; return 1; }
    run_script notes "$1" "$FAKE_SHA" "$SANDBOX/VERSION" "$SANDBOX/pulls.json" "$SANDBOX/released.txt" "$SANDBOX/notes.md"
}

test_a_good_release_writes_the_pull_request_description_and_a_link_to_it() {
    require_good_inputs || return 1
    run_notes v1.4.1
    assert_rc 0 "a release tag of a merged release pull request"
    assert_eq "$(notes_text)" "$(printf 'Lists #80 and #81.\n\nBump: patch.\n\nRelease pull request: %s' "$FAKE_PR_URL")" "the description, then the link"
}

test_a_pull_request_without_a_description_still_gives_a_page_with_the_link() {
    require_good_inputs && edit_pulls '.[0].body = null' || return 1
    run_notes v1.4.1
    assert_rc 0 "a null description"
    assert_eq "$(notes_text)" "Release pull request: $FAKE_PR_URL" "only the link"
}

test_trailing_whitespace_of_a_description_does_not_stretch_the_gap_before_the_link() {
    require_good_inputs && set_pulls "Release 1.4.1" "$MERGED_AT" "$FAKE_SHA" $'Body line.\n\n \t\n' || return 1
    run_notes v1.4.1
    assert_rc 0 "a description ending in blank lines"
    assert_eq "$(notes_text)" "Body line."$'\n\n'"Release pull request: $FAKE_PR_URL" "one blank line, then the link"
}

test_the_pages_of_the_api_answer_may_arrive_as_several_arrays() {
    require_good_inputs && combine_pages || return 1
    run_notes v1.4.1
    assert_rc 0 "the release pull request on the second of two pages"
}

# ^ invariant the body is data => backticks, command substitution, quotes, backslashes and dollar signs come out as written and nothing runs
test_a_description_with_shell_syntax_is_written_verbatim_and_never_run() {
    local body
    # shellcheck disable=SC2016 # the text is meant to stay unexpanded
    body='`touch "$SANDBOX/pwn1"` $(touch "$SANDBOX/pwn2") "quoted" '"'single'"' \n \\ $HOME ${HOME} %s %d'
    require_good_inputs && set_pulls "Release 1.4.1" "$MERGED_AT" "$FAKE_SHA" "$body" || return 1
    run_notes v1.4.1
    assert_rc 0 "a description full of shell syntax"
    assert_eq "$(notes_text)" "$body"$'\n\n'"Release pull request: $FAKE_PR_URL" "verbatim"
    assert_no_file "$SANDBOX/pwn1" "backticks not run"
    assert_no_file "$SANDBOX/pwn2" "command substitution not run"
}

test_only_x_y_z_with_a_v_is_a_release_tag_name() {
    local t
    for t in v1.4.1-rc1 1.4.1 v1.4 v1.4.1.2 V1.4.1 v1.4.x ' v1.4.1' 'v1.4.1 ' "$(printf 'v1.4.1\nx')" 'v1..1' 'v-1.4.1' '' v1234567890.0.0 v1.1234567890.0 v1.0.1234567890; do
        run_script name "$t"
        assert_rc 1 "[$t] is refused"
        assert_contains "$ERR" "not a release tag" "the reason is named for [$t]"
    done
    for t in v0.0.0 v1.4.1 v10.200.3000 v999999999.999999999.999999999; do
        run_script name "$t"
        assert_rc 0 "[$t] is a release tag"
    done
}

# ^ why the value is read from the source line, not sourced; sourcing either file would run its code
regex_of() {
    local line
    line="$(grep -m1 -E "^(readonly )?$2=" "$1")" || { fail "no $2= line in $1"; return 1; }
    line="${line#*=}"
    line="${line#\'}"
    printf '%s' "${line%\'}"
}

# ^ invariant the release page and auto-update accept the same tag names => a tag one deploys is a tag the other documents
test_the_tag_rule_is_the_one_auto_update_uses() {
    local mine theirs
    mine="$(regex_of "$NOTES_SCRIPT" TAG_RE)" || return 1
    theirs="$(regex_of "$GSG_PROJECT/lib/autoupdate/autoupdate.sh" GSG_UPDATE_TAG_RE)" || return 1
    assert_eq "$mine" "$theirs" "release-notes.sh TAG_RE equals GSG_UPDATE_TAG_RE"
    assert_contains "$mine" "{1,9}" "the bounded form"
}

# ^ invariant a log line starting with two colons is a workflow command => no stderr line of a refusal starts with them, whatever the tag text
test_a_refused_tag_name_never_starts_a_log_line_with_a_workflow_command() {
    local t line
    for t in "$(printf '::error::x\nv1')" '::error::x' "$(printf 'v1\n::set-output::x')"; do
        run_script name "$t"
        assert_rc 1 "a hostile tag"
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in '::'*) fail "a stderr line starts with ::" ;; esac
        done <<<"$ERR"
    done
}

test_a_bad_tag_name_stops_the_notes_run_too() {
    require_good_inputs || return 1
    run_notes v1.4.1-rc1
    assert_rc 1 "a pre-release name"
    assert_contains "$ERR" "not a release tag" "the reason"
    assert_no_file "$SANDBOX/notes.md" "nothing written"
}

test_a_version_file_that_differs_from_the_tag_is_refused() {
    local v
    require_good_inputs || return 1
    for v in $'1.4.0\n' $'1.4.1-rc1\n' ''; do
        put "$SANDBOX/VERSION" "$v" || return 1
        run_notes v1.4.1
        assert_rc 1 "VERSION [$v]"
        assert_contains "$ERR" "VERSION" "the reason names VERSION"
    done
    assert_no_file "$SANDBOX/notes.md" "nothing written"
}

test_a_commit_that_is_the_merge_of_no_pull_request_is_refused() {
    require_good_inputs && put "$SANDBOX/pulls.json" $'[]\n' || return 1
    run_notes v1.4.1
    assert_rc 1 "no pull request at all"
    assert_contains "$ERR" "no pull request" "the reason"
    set_pulls "Release 1.4.1" "$MERGED_AT" "$OTHER_SHA" "x" || return 1
    run_notes v1.4.1
    assert_rc 1 "a pull request whose merge commit is another commit"
    assert_contains "$ERR" "no pull request" "the reason"
    assert_no_file "$SANDBOX/notes.md" "nothing written"
}

test_a_release_pull_request_that_is_not_merged_is_refused() {
    require_good_inputs && set_pulls "Release 1.4.1" "null" "$FAKE_SHA" "x" || return 1
    run_notes v1.4.1
    assert_rc 1 "merged_at is null"
    assert_contains "$ERR" "not merged" "the reason"
    assert_no_file "$SANDBOX/notes.md" "nothing written"
}

test_a_pull_request_with_another_title_is_refused() {
    local t
    require_good_inputs || return 1
    for t in "Release 1.4.0" "release 1.4.1" "Release 1.4.1 " "Release v1.4.1" "Fix things"; do
        set_pulls "$t" "$MERGED_AT" "$FAKE_SHA" "x" || return 1
        run_notes v1.4.1
        assert_rc 1 "title [$t]"
        assert_contains "$ERR" "Release 1.4.1" "the expected title is named for [$t]"
    done
    assert_no_file "$SANDBOX/notes.md" "nothing written"
}

test_two_pull_requests_with_the_same_merge_commit_and_title_are_refused() {
    require_good_inputs && edit_pulls '. + .' || return 1
    run_notes v1.4.1
    assert_rc 1 "two matches"
    assert_contains "$ERR" "more than one" "the reason"
    assert_no_file "$SANDBOX/notes.md" "nothing written"
}

test_a_tag_that_already_has_a_release_is_refused() {
    require_good_inputs && put "$SANDBOX/released.txt" $'v1.4.0\nv1.4.1\n' || return 1
    run_notes v1.4.1
    assert_rc 1 "v1.4.1 is released"
    assert_contains "$ERR" "already" "the reason"
    assert_no_file "$SANDBOX/notes.md" "nothing written"
    put "$SANDBOX/released.txt" $'v1.4.10\nxv1.4.1\n' || return 1
    run_notes v1.4.1
    assert_rc 0 "other tags that only contain the name do not count"
}

test_an_answer_that_is_not_json_is_refused_not_passed() {
    require_good_inputs && put "$SANDBOX/pulls.json" 'not json' || return 1
    run_notes v1.4.1
    assert_rc 1 "unreadable API answer"
    assert_no_file "$SANDBOX/notes.md" "nothing written"
}

test_the_script_refuses_a_wrong_usage_and_an_unreadable_input() {
    run_script
    assert_rc 2 "no argument"
    run_script frob v1.4.1
    assert_rc 2 "an unknown command"
    run_script notes v1.4.1 "$FAKE_SHA"
    assert_rc 2 "too few arguments"
    require_good_inputs || return 1
    run_script notes v1.4.1 "$FAKE_SHA" "$SANDBOX/none" "$SANDBOX/pulls.json" "$SANDBOX/released.txt" "$SANDBOX/notes.md"
    assert_rc 2 "a missing VERSION file"
    run_script notes v1.4.1 "not a sha" "$SANDBOX/VERSION" "$SANDBOX/pulls.json" "$SANDBOX/released.txt" "$SANDBOX/notes.md"
    assert_rc 2 "a commit that is not 40 hex digits"
}

# ^ invariant prints the line of every expression inside a run value => a block ends at the first line not indented deeper than its run key
# ^ why awk over the file text, not a YAML parser; the project has none and the workflow uses plain block scalars
run_blocks_with_expressions() {
    awk '
        function indent(s) { match(s, /^ */); return RLENGTH }
        /^[[:space:]]*(- )?run:/ {
            if ($0 ~ /\$\{\{/) print FNR ": " $0
            if ($0 ~ /run:[[:space:]]*[|>]/) { in_run = 1; match($0, /run:/); base = RSTART - 1 } else { in_run = 0 }
            next
        }
        in_run && /^[[:space:]]*$/ { next }
        in_run && indent($0) > base { if ($0 ~ /\$\{\{/) print FNR ": " $0; next }
        { in_run = 0 }
    ' "$1"
}

# ^ why WF is read once with the failure named, not an empty string; every assert_contains would fail for the wrong reason
read_workflow() {
    [ -r "$RELEASE_WORKFLOW" ] || { fail "cannot read $RELEASE_WORKFLOW"; return 1; }
    WF="$(<"$RELEASE_WORKFLOW")"
}

test_the_expression_check_flags_an_event_value_inside_a_run_block_and_only_there() {
    # shellcheck disable=SC2016 # the YAML text holds literal dollar-brace expressions, nothing for the shell to expand
    put "$SANDBOX/bad.yml" "$(printf '%s\n' 'jobs:' '  j:' '    steps:' '      - run: echo ${{ github.ref }}' '      - run: |' '          echo ok' '' '          echo ${{ inputs.tag }}' \
        '      - env:' '          T: ${{ inputs.tag }}' '        run: echo "$T"' '      - run: |' '          echo ok' '        env:' '          T: ${{ inputs.tag }}' \
        '        if: ${{ success() }}')" || return 1
    run_cap run_blocks_with_expressions "$SANDBOX/bad.yml"
    assert_rc 0 "awk ran"
    assert_eq "${OUT%%$'\n'*}" "4:       - run: echo \${{ github.ref }}" "the one-line run"
    assert_contains "$OUT" "8:" "the line after a blank line in a block"
    assert_not_contains "$OUT" "10:" "an env value before run is allowed"
    assert_not_contains "$OUT" "15:" "an env value after a block is allowed"
    assert_not_contains "$OUT" "16:" "an if expression after a block is allowed"
}

test_the_release_workflow_passes_no_expression_to_a_shell() {
    read_workflow || return 1
    run_cap run_blocks_with_expressions "$RELEASE_WORKFLOW"
    assert_rc 0 "awk ran on release.yml"
    assert_empty "$OUT" "every expression reaches the shell through env"
}

test_the_release_workflow_is_read_only_except_for_the_job_that_creates_the_page() {
    local top writes rc=0
    read_workflow || return 1
    top="$(awk '/^permissions:/ { getline; print; exit }' "$RELEASE_WORKFLOW")" || { fail "awk failed"; return 1; }
    assert_eq "$top" "  contents: read" "top-level permissions"
    writes="$(grep -c -E '^[[:space:]]+contents: write$' "$RELEASE_WORKFLOW")" || rc=$?
    [ "$rc" -le 1 ] || { fail "grep failed on release.yml (rc=$rc)"; return 1; }
    assert_eq "$writes" "1" "one write grant, in the job"
}

test_the_release_workflow_has_a_time_limit_and_one_run_per_tag() {
    read_workflow || return 1
    assert_contains "$WF" "timeout-minutes:" "a time limit"
    assert_contains "$WF" "concurrency:" "a concurrency group"
    assert_contains "$WF" "cancel-in-progress: false" "a run for a tag is never cancelled half way"
}

test_the_release_workflow_never_creates_or_moves_a_tag() {
    read_workflow || return 1
    assert_contains "$WF" "--verify-tag" "gh release create checks the tag exists"
    assert_not_contains "$WF" "git tag" "no git tag"
    assert_not_contains "$WF" "git push" "no git push"
    assert_not_contains "$WF" "--target" "no target that could create a tag"
}

# ^ invariant prints every cat of notes.md outside a stop-commands line and its resume line => a body line of two colons is never a command
unguarded_note_prints() {
    awk '
        /::stop-commands::/ { guard = 1; next }
        /printf .::%s::/ { guard = 0; next }
        /cat .*notes\.md/ && !guard { print FNR ": " $0 }
    ' "$1"
}

test_the_dry_run_never_prints_the_notes_outside_a_stop_commands_pair() {
    put "$SANDBOX/raw.yml" $'  cat "$work/notes.md"\n' || return 1
    run_cap unguarded_note_prints "$SANDBOX/raw.yml"
    assert_contains "$OUT" "1:" "the checker flags a raw cat"
    put "$SANDBOX/ok.yml" $'  printf \'::stop-commands::%s\\n\' "$t"\n  cat "$work/notes.md"\n  printf \'::%s::\\n\' "$t"\n' || return 1
    run_cap unguarded_note_prints "$SANDBOX/ok.yml"
    assert_empty "$OUT" "a guarded cat is not flagged"
    read_workflow || return 1
    # shellcheck disable=SC2016 # the text searched for is workflow shell source, nothing to expand here
    assert_contains "$WF" 'cat "$work/notes.md"' "the dry run prints the notes"
    run_cap unguarded_note_prints "$RELEASE_WORKFLOW"
    assert_empty "$OUT" "release.yml guards its cat"
    assert_contains "$WF" "::stop-commands::" "the guard exists"
    assert_contains "$WF" "openssl rand" "the token is random per run"
}

run_file_tests
