#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

DCO_SCRIPT="$GSG_PROJECT/.github/scripts/check-dco.sh"

# ^ why the real script in a scratch repo, not a stand-in; CI runs this very script; the test drives git for real
dco_check() {
    run_cap env -i "${GSG_ENV[@]}" "${TEST_BASH:-bash}" "$DCO_SCRIPT" "$@"
}

# ^ why --no-verify, not the sandbox hook; only the sign-off matters here
dco_commit_file() {
    local file="$1" msg="$2"
    shift 2
    printf 'x%s\n' "$RANDOM" >>"$REPO/$file" || return 1
    gitx add "$file" || return 1
    gitx commit -q --no-verify "$@" -m "$msg"
}

dco_commit() {
    local msg="$1"
    shift
    dco_commit_file f.txt "$msg" "$@"
}

# ^ invariant repo with an unsigned commit on main (the base) and a topic branch on top of it
dco_repo() {
    new_repo "$1" || return 1
    dco_commit "history on main, never signed" || return 1
    DCO_BASE="$(gitx rev-parse HEAD)" || return 1
    gitx checkout -q -b topic || return 1
}

test_a_branch_where_every_commit_is_signed_passes() {
    dco_repo signed_all || return 1
    dco_commit "first" -s || return 1
    dco_commit "second" -s || return 1
    dco_check "$DCO_BASE" HEAD
    assert_rc 0 "all signed"
    assert_contains "$OUT" "2 commits" "says how many commits it checked"
}

test_an_unsigned_commit_fails_and_is_named() {
    dco_repo one_unsigned || return 1
    dco_commit "signed one" -s || return 1
    dco_commit "forgot the sign-off" || return 1
    local bad
    bad="$(gitx rev-parse --short HEAD)" || return 1
    dco_check "$DCO_BASE" HEAD
    assert_rc 1 "one unsigned commit"
    assert_contains "$ERR" "$bad" "names the offending commit"
    assert_contains "$ERR" "forgot the sign-off" "shows its subject"
    assert_contains "$ERR" "git rebase --signoff" "says how to fix it"
}

test_a_sign_off_by_another_identity_than_the_author_fails() {
    dco_repo other_identity || return 1
    dco_commit $'someone else signed\n\nSigned-off-by: Mallory Other <mallory@example.invalid>' || return 1
    dco_check "$DCO_BASE" HEAD
    assert_rc 1 "sign-off of a different identity"
    assert_contains "$ERR" "someone else signed" "names the commit"
}

test_a_sign_off_with_the_authors_name_but_another_email_fails() {
    dco_repo other_email || return 1
    dco_commit $'right name wrong mail\n\nSigned-off-by: Test User <other@example.invalid>' || return 1
    dco_check "$DCO_BASE" HEAD
    assert_rc 1 "same name, different email"
}

test_a_commit_authored_by_someone_the_committer_signed_for_fails() {
    dco_repo authored_elsewhere || return 1
    dco_commit "applied for a contributor" -s --author "Alice Author <alice@example.invalid>" || return 1
    dco_check "$DCO_BASE" HEAD
    assert_rc 1 "the committer signed, the author did not"
}

test_a_matching_sign_off_among_several_trailers_passes() {
    dco_repo several_trailers || return 1
    dco_commit $'many trailers\n\nSigned-off-by: Reviewer One <r1@example.invalid>\nSigned-off-by: Test User <test@example.invalid>\nCo-authored-by: Pair <p@example.invalid>' || return 1
    dco_check "$DCO_BASE" HEAD
    assert_rc 0 "the author's line is one of several"
}

test_a_sign_off_line_outside_the_trailer_block_does_not_count() {
    dco_repo not_a_trailer || return 1
    dco_commit $'prose after the line\n\nSigned-off-by: Test User <test@example.invalid>\n\nand then more prose that ends the trailer block' || return 1
    dco_check "$DCO_BASE" HEAD
    assert_rc 1 "a Signed-off-by line in the middle of the body is not a trailer"
}

test_merge_commits_are_ignored() {
    dco_repo with_merge || return 1
    dco_commit "topic work" -s || return 1
    gitx checkout -q main || return 1
    dco_commit_file main.txt "main work, signed" -s || return 1
    gitx checkout -q topic || return 1
    gitx merge -q --no-ff --no-verify -m "Merge main into topic, unsigned" main || return 1
    dco_check "$DCO_BASE" HEAD
    assert_rc 0 "an unsigned merge commit is skipped, the signed commits on both sides pass"
    assert_contains "$OUT" "2 commits" "the merge is not counted"
}

test_history_already_on_the_base_is_not_checked() {
    dco_repo old_history || return 1
    dco_commit "topic work" -s || return 1
    dco_check "$DCO_BASE" HEAD
    assert_rc 0 "the unsigned commit on main is outside base..head"
}

test_an_empty_range_passes_and_says_so() {
    dco_repo empty_range || return 1
    dco_check "$DCO_BASE" "$DCO_BASE"
    assert_rc 0 "nothing between base and head"
    assert_contains "$OUT" "0 commits" "reports zero"
}

test_every_unsigned_commit_is_listed_not_only_the_first() {
    dco_repo two_unsigned || return 1
    dco_commit "unsigned alpha" || return 1
    dco_commit "unsigned beta" || return 1
    dco_check "$DCO_BASE" HEAD
    assert_rc 1 "two unsigned"
    assert_contains "$ERR" "unsigned alpha" "first listed"
    assert_contains "$ERR" "unsigned beta" "second listed"
}

test_wrong_arguments_and_unknown_revisions_are_errors_not_passes() {
    dco_repo bad_args || return 1
    dco_check
    assert_rc 2 "no arguments"
    assert_contains "$ERR" "usage" "prints the usage"
    dco_check "$DCO_BASE"
    assert_rc 2 "one argument"
    dco_check "$DCO_BASE" no-such-revision
    assert_rc 2 "an unknown head is an error, never a pass"
    dco_check no-such-revision HEAD
    assert_rc 2 "an unknown base is an error, never a pass"
}

test_a_range_longer_than_the_bound_is_refused_not_truncated() {
    dco_repo too_many || return 1
    dco_commit "one" -s || return 1
    dco_commit "two" -s || return 1
    dco_commit "three" -s || return 1
    run_cap env -i "${GSG_ENV[@]}" DCO_MAX_COMMITS=2 "${TEST_BASH:-bash}" "$DCO_SCRIPT" "$DCO_BASE" HEAD
    assert_rc 2 "more commits than the bound"
    assert_contains "$ERR" "DCO_MAX_COMMITS" "names the knob"
}

test_a_sign_off_email_that_differs_only_in_case_passes_but_the_name_is_exact() {
    dco_repo email_case || return 1
    dco_commit $'mixed case mail\n\nSigned-off-by: Case Author <case@x.com>' --author "Case Author <Case@X.com>" || return 1
    dco_check "$DCO_BASE" HEAD
    assert_rc 0 "email addresses are compared without regard to case"
    dco_commit $'mixed case name\n\nSigned-off-by: case author <case@x.com>' --author "Case Author <case@x.com>" || return 1
    dco_check "$DCO_BASE" HEAD
    assert_rc 1 "the name must match exactly"
}

test_a_zero_or_leading_zero_commit_bound_is_a_usage_error() {
    dco_repo bad_bound || return 1
    dco_commit "one" -s || return 1
    local bad
    for bad in 0 00 08 007; do
        run_cap env -i "${GSG_ENV[@]}" DCO_MAX_COMMITS="$bad" "${TEST_BASH:-bash}" "$DCO_SCRIPT" "$DCO_BASE" HEAD
        assert_rc 2 "DCO_MAX_COMMITS=$bad"
        assert_contains "$ERR" "DCO_MAX_COMMITS must be a whole number from 1" "[$bad] gets a clear message"
    done
    run_cap env -i "${GSG_ENV[@]}" DCO_MAX_COMMITS=10 "${TEST_BASH:-bash}" "$DCO_SCRIPT" "$DCO_BASE" HEAD
    assert_rc 0 "a plain number is accepted"
}

test_the_pass_line_uses_the_singular_for_one_commit() {
    dco_repo singular || return 1
    dco_commit "only" -s || return 1
    dco_check "$DCO_BASE" HEAD
    assert_rc 0 "one signed commit"
    assert_contains "$OUT" "1 commit checked" "singular"
    assert_not_contains "$OUT" "1 commits" "no '1 commits'"
}

# shellcheck disable=SC2016
test_the_ci_workflow_runs_the_check_on_pull_requests_only() {
    local wf="$GSG_PROJECT/.github/workflows/tests.yml"
    grep -qF '.github/scripts/check-dco.sh' "$wf" || fail "the workflow does not run check-dco.sh"
    grep -qF "github.event_name == 'pull_request'" "$wf" || fail "the dco job is not limited to pull requests"
    grep -qF 'fetch-depth: 0' "$wf" || fail "the dco job does not fetch the history it compares"
    grep -qF 'git show "$PR_BASE:.github/scripts/check-dco.sh"' "$wf" || fail "the dco job does not run the base commit's copy of the script"
    grep -qF 'cat-file -e "$PR_BASE:.github/scripts/check-dco.sh"' "$wf" || fail "the dco job does not test whether the base has the script before falling back"
}

test_the_repository_ships_the_verbatim_certificate_and_documents_the_sign_off() {
    local dco="$GSG_PROJECT/DCO.txt" needle
    assert_file "$dco" "DCO.txt"
    for needle in 'Developer Certificate of Origin' 'Version 1.1' 'Copyright (C) 2004, 2006 The Linux Foundation and its contributors.' \
        'Everyone is permitted to copy and distribute verbatim copies of this' "Developer's Certificate of Origin 1.1" \
        'By making a contribution to this project, I certify that:' '(a) The contribution was created in whole or in part by me and I' \
        '(b) The contribution is based upon previous work that, to the best' '(c) The contribution was provided directly to me by some other' \
        "(d) I understand and agree that this project and the contribution" 'maintained indefinitely and may be redistributed consistent with'; do
        grep -qF -- "$needle" "$dco" || fail "DCO.txt does not contain [$needle]"
    done
    for needle in 'Signed-off-by:' 'git commit -s' 'git commit --amend -s --no-edit' 'git rebase --signoff origin/main' '(DCO.txt)'; do
        grep -qF -- "$needle" "$GSG_PROJECT/CONTRIBUTING.md" || fail "CONTRIBUTING.md does not mention [$needle]"
    done
}

run_file_tests
