#!/usr/bin/env bash
# ^ invariant the guidance after a findings list (#3) is fixed text plus at most 10 fingerprint lines; every branch is pinned here with rows files and stand-ins
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

WORK="" MARKER="" CALLS=""
ESC=$'\e'
AGENT_LINE="An automated agent asks its user before adding an exemption or using --no-verify."
BYPASS_LINE="To bypass this check for one commit: git commit --no-verify"
VALUES_LINE="  (values are not shown; remove them and rotate any real credential)"
BOTH_MARKERS="trufflehog: trufflehog:ignore    betterleaks: betterleaks:allow    both: trufflehog:ignore betterleaks:allow"

begin() {
    new_repo "$1" || return 1
    WORK="$SANDBOX/work-$1"
    mkdir -p -- "$WORK" || return 1
    : >"$WORK/trufflehog.rows" && : >"$WORK/betterleaks.rows" && : >"$WORK/trufflehog.errors" && : >"$WORK/betterleaks.errors" || return 1
}
# ^ invariant tf_row RULE FILE LINE and gl_row RULE FILE LINE append one row of the scanner with the status match
tf_row() { printf 'trufflehog\t%s\tmatch\t%s\t%s\n' "$1" "$2" "$3" >>"$WORK/trufflehog.rows"; }
gl_row() { printf 'betterleaks\t%s\tmatch\t%s\t%s\n' "$1" "$2" "$3" >>"$WORK/betterleaks.rows"; }
# ^ invariant report [MODE] runs report_results alone on the rows files of the work dir and captures stdout, stderr and the status
report() {
    # shellcheck disable=SC2016
    run_cap env -i "${GSG_ENV[@]}" bash -c 'source "$1/lib/core/common.sh" && source "$1/lib/scan/report.sh" && report_results "$2" "$3"' _ "$SHARE" "$WORK" "${1:-}"
}

# ^ invariant step1_and_2 MARKERS prints the "What to do" heading, step 1 and step 2 with the marker line the rows call for
step1_and_2() {
    cat <<EOF
What to do:
  1. A real credential: remove it from the change and rotate it. Nothing below is for a real credential.
  2. A false positive or a test value, one line: put the marker of every scanner that reports the line on that same line.
       $1
     A marker works in this commit.
EOF
}
step3_head() { printf '  3. A betterleaks finding on a line that cannot hold a marker: add its line to .gitleaksignore at the repository root:\n'; }
# ^ invariant path_step NUMBER [trufflehog] prints the path step, with its second line only when trufflehog has a row
path_step() {
    printf '  %s. A whole path of test data: add "<glob>  # <reason>" to .secret-scan-ignore at the repository root.\n' "$1"
    if [ "${2:-}" = trufflehog ]; then
        printf '     trufflehog has no per-finding file: its finding on a line that cannot hold a marker needs this step.\n'
    fi
}
# ^ invariant closing NAMES prints the HEAD sentence, NAMES is the subject of its first line
closing() {
    printf '  %s read from the last commit, never from the commit being made:\n' "$1"
    printf '  commit the entry by itself first (git add <file> && git commit -m "<message>" <file>), then commit this change.\n'
}

test_both_scanners_on_two_findings_print_the_whole_guidance_after_the_rows() {
    begin both || return 1
    gl_row github-pat c.txt 2
    gl_row pii-credit-card tests/cards.txt 7
    tf_row Github c.txt 2
    report
    assert_rc 1 "blocked"
    assert_empty "$OUT" "stdout stays empty"
    assert_eq "$ERR" "git-secret-guard: 3 potential secret(s) in lines this commit adds:
  betterleaks github-pat (match)  c.txt:2
  betterleaks pii-credit-card (match)  tests/cards.txt:7
  trufflehog  Github (match)  c.txt:2
$VALUES_LINE
$(step1_and_2 "$BOTH_MARKERS")
$(step3_head)
       c.txt:github-pat:2
       tests/cards.txt:pii-credit-card:7
$(path_step 4 trufflehog)
$(closing ".gitleaksignore and .secret-scan-ignore are")
$AGENT_LINE" "the heading, the rows and the values line are as before, the guidance follows"
}

test_a_betterleaks_only_block_names_only_its_marker_and_fingerprint() {
    begin glonly || return 1
    gl_row pii-credit-card tests/cards.txt 7
    report
    assert_rc 1 "blocked"
    assert_eq "$ERR" "git-secret-guard: 1 potential secret(s) in lines this commit adds:
  betterleaks pii-credit-card (match)  tests/cards.txt:7
$VALUES_LINE
$(step1_and_2 'betterleaks: betterleaks:allow')
$(step3_head)
       tests/cards.txt:pii-credit-card:7
$(path_step 4)
$(closing ".gitleaksignore and .secret-scan-ignore are")
$AGENT_LINE" "no trufflehog marker, no trufflehog second line"
    assert_not_contains "$ERR" "trufflehog" "trufflehog is not named at all"
}

test_a_trufflehog_only_block_has_no_fingerprint_step_and_says_why_the_path_step_is_its_way() {
    begin tfonly || return 1
    tf_row Github c.txt 2
    report
    assert_rc 1 "blocked"
    assert_eq "$ERR" "git-secret-guard: 1 potential secret(s) in lines this commit adds:
  trufflehog  Github (match)  c.txt:2
$VALUES_LINE
$(step1_and_2 'trufflehog: trufflehog:ignore')
$(path_step 3 trufflehog)
$(closing ".secret-scan-ignore is")
$AGENT_LINE" "step 3 is the path step, the closing sentence starts with .secret-scan-ignore"
    assert_not_contains "$ERR" ".gitleaksignore" "the file is never named"
    assert_not_contains "$ERR" "betterleaks" "betterleaks is never named"
}

# ^ invariant omission_case NAME FILE LINE pins one omission alone; a second ordinary row still prints its own fingerprint
omission_case() {
    local name="$1" file="$2" line="$3"
    begin "om$name" || return 1
    gl_row github-pat "$file" "$line"
    gl_row github-pat ok.txt 1
    report
    assert_rc 1 "$name: blocked"
    assert_contains "$ERR" $'\n       ok.txt:github-pat:1\n' "$name: the other row has its line"
    assert_not_contains "$ERR" "       ${file}:github-pat" "$name: no fingerprint line for the omitted row"
    assert_not_contains "$ERR" "more (" "$name: the omitted row is not counted"
    assert_contains "$ERR" "  betterleaks github-pat (match)  $file:$line" "$name: the row itself is still listed"
}
test_a_row_with_line_question_mark_gets_no_fingerprint_line() { omission_case line c.txt '?'; }
test_a_row_whose_file_holds_a_question_mark_gets_no_fingerprint_line() { omission_case question 'a?b.txt' 3; }
test_a_row_whose_file_holds_a_backslash_gets_no_fingerprint_line() { omission_case backslash 'a\b.txt' 3; }
test_a_root_gitleaksignore_row_gets_no_fingerprint_line() { omission_case gitleaksignore .gitleaksignore 1; }
test_a_root_betterleaksignore_row_gets_no_fingerprint_line() { omission_case betterleaksignore .betterleaksignore 1; }

test_a_nested_gitleaksignore_is_an_ordinary_path_with_a_fingerprint() {
    begin nested || return 1
    gl_row github-pat sub/.gitleaksignore 1
    report
    assert_contains "$ERR" $'\n       sub/.gitleaksignore:github-pat:1\n' "only the root file is scanned under another name"
}

test_when_every_betterleaks_row_is_left_out_step_3_is_not_printed_and_the_path_step_is_3() {
    begin allomit || return 1
    gl_row github-pat 'a?b.txt' 3
    gl_row github-pat .gitleaksignore 2
    gl_row github-pat c.txt '?'
    report
    assert_rc 1 "blocked"
    assert_eq "$ERR" "git-secret-guard: 3 potential secret(s) in lines this commit adds:
  betterleaks github-pat (match)  .gitleaksignore:2
  betterleaks github-pat (match)  a?b.txt:3
  betterleaks github-pat (match)  c.txt:?
$VALUES_LINE
$(step1_and_2 'betterleaks: betterleaks:allow')
$(path_step 3)
$(closing ".secret-scan-ignore is")
$AGENT_LINE" "no step 3, no .gitleaksignore sentence, no trufflehog line"
}

test_a_betterleaks_row_that_gets_no_fingerprint_still_counts_for_the_both_marker_line() {
    begin bothom || return 1
    tf_row Github c.txt 2
    gl_row github-pat c.txt '?'
    report
    assert_rc 1 "blocked"
    assert_contains "$ERR" "       $BOTH_MARKERS" "both scanners have a row, so the both form is printed"
    assert_contains "$ERR" $'  3. A whole path of test data' "no step 3 of fingerprints"
    assert_not_contains "$ERR" "A betterleaks finding on a line" "the fingerprint step is left out"
}

test_an_aws_access_key_id_row_gets_its_own_rule_in_the_fingerprint() {
    begin aws || return 1
    gl_row aws-access-key-id k.txt 4
    report
    assert_contains "$ERR" $'\n       k.txt:aws-access-key-id:4\n' "the rule the row names"
    assert_not_contains "$ERR" "aws-access-token" "never the twin"
}

test_25_betterleaks_rows_list_10_fingerprints_and_count_the_other_15() {
    begin cap || return 1
    local i
    for i in $(seq 1 25); do gl_row github-pat c.txt "$i"; done
    report
    assert_rc 1 "blocked"
    assert_eq "$(grep -c '^       c\.txt:github-pat:' <<<"$ERR")" 10 "exactly 10 fingerprint lines"
    assert_contains "$ERR" "$(step3_head)
       c.txt:github-pat:1
       c.txt:github-pat:10
       c.txt:github-pat:11
       c.txt:github-pat:12
       c.txt:github-pat:13
       c.txt:github-pat:14
       c.txt:github-pat:15
       c.txt:github-pat:16
       c.txt:github-pat:17
       c.txt:github-pat:18
       ... and 15 more (<path>:<rule>:<line> of each betterleaks row above)
$(path_step 4)" "the first ten rows in the order of the sorted rows, then the more line, then the path step"
}

test_omitted_rows_do_not_use_up_the_cap_and_are_not_in_the_more_count() {
    begin capom || return 1
    local i
    for i in $(seq 1 12); do gl_row github-pat c.txt "$i"; done
    for i in $(seq 1 5); do gl_row github-pat "q?$i.txt" 1; done
    report
    assert_eq "$(grep -c '^       c\.txt:github-pat:' <<<"$ERR")" 10 "ten listed"
    assert_contains "$ERR" "       ... and 2 more (" "12 listable rows less 10, the 5 omitted rows are not counted"
}

test_exactly_10_betterleaks_rows_print_no_more_line() {
    begin ten || return 1
    local i
    for i in $(seq 1 10); do gl_row github-pat c.txt "$i"; done
    report
    assert_not_contains "$ERR" "more (" "nothing is left over"
}

test_the_percent_characters_of_a_path_print_unharmed_in_a_fingerprint() {
    begin pct || return 1
    gl_row github-pat '100%.txt' 3
    gl_row github-pat 'p%d.txt' 1
    report
    assert_contains "$ERR" $'\n       100%.txt:github-pat:3\n' "a percent sign"
    assert_contains "$ERR" $'\n       p%d.txt:github-pat:1\n' "a printf conversion"
}

test_the_commit_message_run_prints_its_four_fixed_lines_and_names_no_exemption_file() {
    begin msg || return 1
    gl_row github-pat COMMIT_EDITMSG 3
    tf_row Github COMMIT_EDITMSG 3
    report message
    assert_rc 1 "blocked"
    assert_eq "$ERR" "git-secret-guard: 2 potential secret(s) in the commit message:
  betterleaks github-pat (match)  commit message:3
  trufflehog  Github (match)  commit message:3
$VALUES_LINE
What to do:
  1. Write the message again without the value, and rotate a real credential.
  2. A false positive that must stay in the message: put the marker of every scanner that reports the line on that same line
     (trufflehog: trufflehog:ignore, betterleaks: betterleaks:allow). The marker stays in the commit message.
$AGENT_LINE" "the text of scope 3"
    assert_not_contains "$ERR" ".secret-scan-ignore" "a path exemption does not apply to a message"
    assert_not_contains "$ERR" ".gitleaksignore" "nor does a fingerprint belong in the guidance"
    assert_not_contains "$ERR" "COMMIT_EDITMSG" "the file name is never shown"
}

test_the_message_text_is_the_same_for_one_scanner() {
    begin msg1 || return 1
    tf_row Github COMMIT_EDITMSG 1
    report message
    assert_contains "$ERR" "(trufflehog: trufflehog:ignore, betterleaks: betterleaks:allow). The marker stays in the commit message." "fixed text"
}

test_the_guidance_names_neither_amend_nor_the_enabled_switch_and_every_exemption_names_its_condition() {
    begin neg || return 1
    gl_row github-pat c.txt 2
    tf_row Github c.txt 2
    report
    assert_not_contains "$ERR" "--amend" "no amend"
    assert_not_contains "$ERR" "hook.git-secret-guard.enabled" "no switch"
    # ^ why step 3 has no condition assertion, not a weaker one; its text names neither word and step 1 covers it ("Nothing below is for a real credential")
    local before_step2="${ERR%%$'\n'"  2. A false positive"*}"
    assert_contains "$before_step2" "Nothing below is for a real credential." "step 1 says so before step 2"
    assert_contains "$ERR" "  2. A false positive or a test value" "step 2 names false positive and test"
    assert_contains "$ERR" "  4. A whole path of test data" "step 4 names test data"
    assert_contains "$ERR" "  1. A real credential: remove it from the change and rotate it." "removal comes first"
}

test_a_scanner_error_alone_prints_the_error_block_and_no_guidance() {
    begin erralone || return 1
    printf 'trufflehog: timed out after 300s; the scan did not complete\n' >"$WORK/trufflehog.errors"
    report
    assert_rc 1 "blocked"
    assert_eq "$ERR" "git-secret-guard: a scanner did not complete, so the commit is blocked:
  trufflehog: timed out after 300s; the scan did not complete" "only the error block"
}

test_a_scanner_error_and_a_finding_print_the_error_block_first_then_the_findings_and_the_guidance() {
    begin errfind || return 1
    printf 'trufflehog: timed out after 300s; the scan did not complete\n' >"$WORK/trufflehog.errors"
    gl_row github-pat c.txt 2
    report
    assert_rc 1 "blocked"
    assert_eq "${ERR%%$'\n'*}" "git-secret-guard: a scanner did not complete, so the commit is blocked:" "the error block comes first"
    assert_contains "$ERR" "$VALUES_LINE"$'\nWhat to do:\n' "the guidance follows the values line"
    assert_eq "${ERR##*$'\n'}" "$AGENT_LINE" "and ends the report"
}

test_a_failing_awk_after_the_rows_blocks_with_the_rows_intact_and_no_guidance() {
    begin awkfail || return 1
    gl_row github-pat c.txt 2
    # shellcheck disable=SC2016
    run_cap env -i "${GSG_ENV[@]}" bash -c '
        source "$1/lib/core/common.sh" && source "$1/lib/scan/report.sh" || exit 9
        real_awk="$(command -v awk)"
        awk() { case "$*" in *"What to do"*) printf "awk: stand-in failure\n" >&2; return 2 ;; esac; "$real_awk" "$@"; }
        report_results "$2"' _ "$SHARE" "$WORK"
    assert_rc 1 "report_results returns 1"
    assert_contains "$ERR" $'  betterleaks github-pat (match)  c.txt:2\n'"$VALUES_LINE" "the rows were printed"
    assert_not_contains "$ERR" "What to do" "no half guidance"
}

# ^ invariant guidance_fn_run AWK_RC runs _report_guidance on the rows of the work dir; a non-empty AWK_RC makes the guidance awk return AWK_RC
guidance_fn_run() {
    # shellcheck disable=SC2016
    run_cap env -i "${GSG_ENV[@]}" bash -c '
        source "$1/lib/core/common.sh" && source "$1/lib/scan/report.sh" || exit 9
        real_awk="$(command -v awk)"
        if [ -n "$3" ]; then awk() { case "$*" in *"What to do"*) return "$3" ;; esac; "$real_awk" "$@"; }; fi
        _report_guidance "$2/all.rows" ""' _ "$SHARE" "$WORK" "$1"
}

# ^ why no test of the "|| return 1" in report_results, not a weak one; rows force status 1 anyway and the check cannot be seen from outside
# ^ coupled report_results relies on the status passed on here => a function swallowing it would print half a guidance and still look fine
test_the_guidance_function_alone_passes_on_the_status_of_a_failing_awk_and_returns_0_when_it_works() {
    begin guidefn || return 1
    gl_row github-pat c.txt 2
    cat -- "$WORK/betterleaks.rows" >"$WORK/all.rows" || return 1
    guidance_fn_run 2
    assert_rc 2 "the status of the failing awk is the status of the function"
    guidance_fn_run ""
    assert_rc 0 "a working awk gives 0"
    assert_contains "$ERR" "What to do:" "and the text"
}

test_an_unknown_mode_still_refuses_before_any_output() {
    begin badmode || return 1
    gl_row github-pat c.txt 2
    report bogus
    assert_rc 1 "refused"
    assert_not_contains "$ERR" "What to do" "no guidance"
}

# ^ invariant the hook-level tests use the stand-in scanners through git commit; the guidance is judged where the user sees it
hook_begin() {
    new_repo "$1" || return 1
    MARKER="$(new_marker)"
    CALLS="$SANDBOX/calls-$1"
    set_env STUB_LOG="$CALLS" STUB_MARKER="$MARKER"
}
hook_leak() {
    hook_begin "$1" || return 1
    stage_file c.txt one two
    set_env STUB_TF_FINDINGS="Github|true|c.txt|2" STUB_GL_FINDINGS="github-pat|c.txt|2"
}

test_the_hook_prints_the_guidance_before_the_bypass_line_and_the_bypass_line_stays_last() {
    hook_leak hkorder || return 1
    commit_cap "leak"
    assert_rc 1 "blocked"
    assert_contains "$ERR" $'What to do:\n' "the guidance is there"
    assert_contains "$ERR" "$AGENT_LINE"$'\n'"$BYPASS_LINE" "the agent line comes right before the bypass line"
    assert_eq "${ERR##*$'\n'}" "$BYPASS_LINE" "the bypass line is the last"
    no_leak "$MARKER"
}

test_a_nothing_was_scanned_block_prints_no_guidance_and_no_agent_line() {
    hook_begin hknone || return 1
    stage_file c.txt one two
    use_stubs "SCAN_TIMEOUT_SECONDS=soon"
    commit_cap "x"
    assert_rc 1 "blocked"
    assert_not_contains "$ERR" "What to do" "no guidance"
    assert_not_contains "$ERR" "An automated agent" "no agent line"
    assert_contains "$ERR" "nothing was scanned" "the block says nothing was scanned"
    assert_eq "${ERR##*$'\n'}" "$BYPASS_LINE" "the sentence of today is the last line"
}

test_terminal_mode_puts_an_escape_sequence_on_the_heading_only() {
    hook_leak hkterm || return 1
    ui_force_terminal
    commit_cap "leak"
    assert_rc 1 "blocked"
    assert_contains "$ERR" $'What to do:\n' "the guidance is printed in terminal mode too"
    assert_eq "$(grep -c "$ESC" <<<"$ERR")" 1 "one line carries an escape sequence"
}

test_the_commit_msg_run_of_the_hook_prints_the_message_guidance_before_the_bypass_line() {
    hook_begin hkmsg || return 1
    stage_file c.txt one
    set_env STUB_TF_FINDINGS="Github|false|COMMIT_EDITMSG|2"
    printf 'subject\n%s\n' "line two $MARKER" >"$SANDBOX/msg-hk"
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$SHARE/hooks/secret-scan" "$SANDBOX/msg-hk"
    assert_rc 1 "blocked"
    assert_contains "$ERR" $'  1. Write the message again without the value, and rotate a real credential.\n' "the message guidance"
    assert_contains "$ERR" "$AGENT_LINE"$'\n'"$BYPASS_LINE" "agent line then the bypass line"
    assert_eq "${ERR##*$'\n'}" "$BYPASS_LINE" "the bypass line is the last"
    no_leak "$MARKER"
}

run_file_tests
