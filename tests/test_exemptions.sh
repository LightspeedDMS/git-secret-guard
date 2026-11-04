#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

CALLS="" MARKER=""
begin() {
    new_repo "$1" || return 1
    CALLS="$SANDBOX/calls-$1"
    MARKER="$(new_marker)"
    set_env STUB_LOG="$CALLS" STUB_MARKER="$MARKER" STUB_RECORD="$SANDBOX/record-$1"
}
seen_by() {
    grep '^== ' "$SANDBOX/record-${REPO##*/}.$1" 2>/dev/null | sed 's/^== //' | sort -u
}

test_excluded_paths_are_not_scanned_the_rest_is_and_the_count_is_reported() {
    begin sc1 || return 1
    commit_ignore_file 'tests/fixtures/**   # synthetic keys for parser tests'
    stage_file tests/fixtures/k.txt "fixture $MARKER"
    stage_file src/a.txt "real $MARKER"
    commit_cap "mixed"
    assert_rc 0 "stand-ins find nothing"
    assert_eq "$(seen_by trufflehog)" "src/a.txt" "trufflehog never saw the fixture"
    assert_eq "$(seen_by betterleaks)" "src/a.txt" "betterleaks never saw the fixture"
    assert_contains "$ERR" "1 staged file(s) excluded by .secret-scan-ignore" "the count is reported"
    no_leak "$MARKER"
}

test_an_exemption_staged_in_the_same_commit_does_not_apply_but_the_next_commit_is_covered() {
    begin sc2 || return 1
    stage_file other.txt hello && gitx commit -q --no-verify -m base
    stage_file .secret-scan-ignore 'secret/**   # fixtures, exempt from the next commit on'
    stage_file secret/k.txt "value $MARKER"
    set_env STUB_GL_FINDINGS="aws-access-token|secret/k.txt|1"
    commit_cap "self-exempting"
    assert_rc 1 "the finding is reported: only HEAD's file counts"
    assert_contains "$ERR" "secret/k.txt:1" "reported"
    assert_contains "$(seen_by betterleaks)" "secret/k.txt" "the path was scanned"
    assert_not_contains "$ERR" "excluded by .secret-scan-ignore" "nothing was excluded"
    no_leak "$MARKER"

    set_env STUB_GL_FINDINGS=
    gitx rm -q --cached secret/k.txt
    commit_cap "the exemption on its own"
    assert_rc 0 "the ignore file alone is clean"
    rm -f -- "$SANDBOX/record-sc2.betterleaks" "$SANDBOX/record-sc2.trufflehog"
    stage_file secret/k.txt "value $MARKER"
    commit_cap "now covered"
    assert_rc 0 "the exemption is at HEAD now"
    assert_empty "$(seen_by betterleaks)$(seen_by trufflehog)" "the path is not scanned any more"
    assert_contains "$ERR" "1 staged file(s) excluded by .secret-scan-ignore" "and the output says so"
}

stage_two_exempt_fixtures() {
    commit_ignore_file 'tests/fixtures/**   # synthetic keys for parser tests'
    stage_file tests/fixtures/k1.txt "fixture $MARKER"
    stage_file tests/fixtures/k2.txt "fixture $MARKER"
}

test_a_pass_with_exempted_files_states_the_exempted_count() {
    begin sc1b || return 1
    stage_two_exempt_fixtures
    stage_file src/a.txt "real $MARKER"
    commit_cap "two exempted, one scanned"
    assert_rc 0 "stand-ins find nothing"
    assert_contains "$ERR" "2 staged file(s) excluded by .secret-scan-ignore" "the existing line stays"
    assert_contains "${ERR##*$'\n'}" "scanned 1 file, 1 added line (trufflehog 1.2.3, betterleaks 4.5.6): no findings, 2 files exempted, " "the pass line states the count"
    assert_pass_line_only "${ERR##*$'\n'}" "and keeps the pass line shape"
    no_leak "$MARKER"
}

test_a_pass_where_every_file_is_exempted_says_there_was_nothing_to_scan_and_how_many_were_exempted() {
    begin sc1c || return 1
    stage_two_exempt_fixtures
    commit_cap "all exempted"
    assert_rc 0 "nothing left to scan"
    assert_eq "${ERR##*$'\n'}" "git-secret-guard: no added lines to scan (2 files exempted)" "the last line says what happened"
    assert_not_contains "$ERR" "no findings" "no claim of a scan"
    no_leak "$MARKER"
}

test_the_pass_line_counts_the_edited_ignore_file_scanned_in_the_second_pass() {
    begin sc1d || return 1
    commit_ignore_file 'tests/fixtures/**   # synthetic keys for parser tests'
    printf '%s\n' 'docs/**   # first added pattern' 'vendor/**   # second added pattern' >>.secret-scan-ignore
    gitx add .secret-scan-ignore
    stage_file tests/fixtures/k1.txt "fixture $MARKER"
    stage_file src/a.txt one two three
    commit_cap "edit the ignore file next to an exempted and an ordinary file"
    assert_rc 0 "stand-ins find nothing"
    assert_contains "${ERR##*$'\n'}" "git-secret-guard: scanned 2 files, 5 added lines (trufflehog 1.2.3, betterleaks 4.5.6): no findings, 1 file exempted, " \
        "src/a.txt (3 lines, first pass) plus the ignore file (2 lines, second pass), one fixture exempted"
    assert_pass_line_only "${ERR##*$'\n'}" "and the line keeps its shape"
    no_leak "$MARKER"
}

test_the_ignore_file_is_always_scanned_even_when_a_pattern_matches_it() {
    begin sc3 || return 1
    commit_ignore_file '.secret-scan-ignore   # a pattern matching the ignore file itself' '.*   # all dot files' '**/*.md   # docs'
    printf '%s\n' 'extra/**   # more' >>.secret-scan-ignore
    gitx add .secret-scan-ignore
    stage_file notes.md "doc $MARKER"
    set_env STUB_GL_FINDINGS="generic-api-key|.secret-scan-ignore|4"
    commit_cap "edit the ignore file"
    assert_rc 1 "finding inside the ignore file is reported"
    assert_contains "$ERR" ".secret-scan-ignore:4" "reported with its real line"
    assert_contains "$(seen_by betterleaks)" ".secret-scan-ignore" "the file is in the scan tree"
    assert_not_contains "$(seen_by betterleaks)" "notes.md" "the other excluded file is not"
    assert_contains "$ERR" "1 staged file(s) excluded by .secret-scan-ignore" "only notes.md counts as excluded, not the ignore file"
}

test_a_pattern_line_without_a_reason_blocks_the_commit_and_names_the_line() {
    begin sc4 || return 1
    commit_ignore_file '# header' 'ok/**   # fine' 'missing/**' 'another/**   #'
    local before
    before="$(gitx rev-parse HEAD)"
    stage_file src/a.txt one
    commit_cap "blocked by the ignore file"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "git-secret-guard: .secret-scan-ignore line 3: a reason is required" "first bad line named, with the hook's prefix"
    assert_contains "$ERR" "git-secret-guard: .secret-scan-ignore line 4: a reason is required" "second bad line named, with the hook's prefix"
    assert_eq "$(grep -c 'line [0-9]*:' <<<"$ERR")" "$(grep -c '^git-secret-guard: .*line [0-9]*:' <<<"$ERR")" "every line-numbered complaint carries the prefix"
    assert_not_contains "$ERR" "line 2:" "valid line not named"
    assert_contains "$ERR" "git commit --no-verify" "bypass hint"
    assert_eq "$(gitx rev-parse HEAD)" "$before" "no commit was created"
    assert_empty "$(seen_by betterleaks)$(seen_by trufflehog)" "no scanner ran"
}

test_catch_all_variants_commit_but_every_commit_prints_a_warning() {
    local n=0 spec p want
    for spec in '**|the whole repository' '**/*|the whole repository' '/**|the whole repository' './**|the whole repository' \
        '**/**|the whole repository' '*|every top-level file' '*/**|every file below the top level'; do
        p="${spec%%|*}"
        want="${spec#*|}"
        n=$((n + 1))
        begin "ca$n" || return 1
        commit_ignore_file "$p   # legacy repository, scanned elsewhere" || return 1
        stage_file top.txt "t $MARKER"
        stage_file sub/dir/nested.txt "n $MARKER"
        commit_cap "first"
        assert_rc 0 "[$p] is allowed"
        assert_contains "$ERR" "WARNING" "[$p] warns"
        assert_contains "$ERR" ".secret-scan-ignore line 1" "[$p] names the line"
        assert_contains "$ERR" "exempts $want" "[$p] says what is exempt"
        stage_file second.txt "s $MARKER"
        commit_cap "second"
        assert_rc 0 "[$p] second commit"
        assert_contains "$ERR" "exempts $want" "[$p] warns on every commit, not only the first"
        gitx rm -q -- second.txt
        commit_cap "deletion only"
        assert_contains "$ERR" "exempts $want" "[$p] warns even when nothing is left to scan"
        no_leak "$MARKER"
    done
}

test_the_catch_all_warning_shows_the_pattern_as_the_user_wrote_it() {
    local n=0 p long
    for p in './**' '/**' './/**' '/./**'; do
        n=$((n + 1))
        begin "cw$n" || return 1
        commit_ignore_file "$p   # legacy repository" || return 1
        stage_file top.txt "t $MARKER"
        commit_cap "first"
        assert_rc 0 "[$p] is allowed"
        assert_contains "$ERR" "line 1 (pattern '$p') exempts the whole repository" "[$p] is quoted as written, not as normalized"
    done
    long="./$(printf '**/%.0s' {1..25})**"
    begin cw9 || return 1
    commit_ignore_file "$long   # long catch-all" || return 1
    stage_file top.txt "t $MARKER"
    commit_cap "long"
    assert_contains "$ERR" "(pattern '${long:0:60}…')" "a long pattern is cut at 60 characters of what was written and marked as cut"
    assert_not_contains "$ERR" "${long:0:61}" "and not one character more"
    no_leak "$MARKER"
}

test_an_ordinary_pattern_prints_no_catch_all_warning() {
    begin ord || return 1
    commit_ignore_file 'tests/fixtures/**   # synthetic' '**/*.pem   # public certificates' '*.md   # docs'
    stage_file src/a.txt "x $MARKER"
    commit_cap "ordinary"
    assert_rc 0 "commit"
    assert_not_contains "$ERR" "WARNING" "no warning for patterns that exempt only part of the tree"
    assert_pass_line_only "$ERR" "only the pass line is printed when nothing was excluded"
}

test_head_gitleaks_files_are_applied_announced_and_the_staged_versions_never_are() {
    begin gl1 || return 1
    stage_file .gitleaks.toml '[extend]' 'useDefault = true' '# head-config-marker'
    stage_file .gitleaksignore 'src/a.txt:aws-access-token:1' '# head-ignore-marker'
    gitx commit -q --no-verify -m "betterleaks files"
    stage_file .gitleaks.toml '[allowlist]' 'paths = [".*"]' '# staged-config-marker'
    stage_file .gitleaksignore '*' '# staged-ignore-marker'
    stage_file src/a.txt "x $MARKER"
    commit_cap "tamper attempt"
    assert_rc 0 "stand-ins find nothing"
    local calls
    calls="$(<"$CALLS")"
    assert_contains "$calls" "betterleaks-config-line: # head-config-marker" "HEAD's config was passed"
    assert_not_contains "$calls" "staged-config-marker" "the staged config was not"
    assert_contains "$calls" "betterleaks-ignore-line: # head-ignore-marker" "HEAD's ignore file was passed"
    assert_not_contains "$calls" "staged-ignore-marker" "the staged ignore file was not"
    assert_contains "$ERR" "using .gitleaks.toml from HEAD" "config notice"
    assert_contains "$ERR" "using .gitleaksignore from HEAD" "ignore file notice"
    assert_not_contains "$ERR" "WARNING" "the config extends the default rules, so no warning"
    no_leak "$MARKER"
}

test_a_head_gitleaks_config_without_use_default_warns_that_the_built_in_rules_are_off() {
    begin gl2 || return 1
    stage_file .gitleaks.toml '[[rules]]' 'id = "corp"' "regex = '''CORP-[0-9]+'''"
    gitx commit -q --no-verify -m "custom rules only"
    stage_file src/a.txt "x $MARKER"
    commit_cap "scan"
    assert_rc 0 "allowed"
    assert_contains "$ERR" "WARNING: with .gitleaks.toml at HEAD, betterleaks does not detect its own built-in rules" "says what is off"
    assert_contains "$ERR" "[extend] useDefault = true is missing" "names the usual cause"
    assert_contains "$ERR" "trufflehog and the AWS access key ID rule of git-secret-guard still run" "and what remains"
    assert_contains "$ERR" "using .gitleaks.toml from HEAD" "and still announces the file"
    no_leak "$(probe_secret)"
}

test_a_pre_flight_whose_probe_is_not_detected_warns_whatever_the_config_text_says() {
    begin pw1 || return 1
    commit_toml_at_head
    stage_file src/a.txt "one $MARKER"
    set_env STUB_GL_PREFLIGHT_RC=0
    commit_cap "probe not detected"
    assert_rc 0 "a warning, not a block: the repository's own config is trusted"
    assert_contains "$ERR" "WARNING: with .gitleaks.toml at HEAD, betterleaks does not detect its own built-in rules" "the config text has useDefault = true, the behaviour says otherwise"
    assert_contains "$ERR" "an allowlist or disabledRules" "names the other causes"
    assert_eq "$(seen_by betterleaks)" "src/a.txt" "and the scan still ran"
    no_leak "$MARKER"
    no_leak "$(probe_secret)"
}

test_the_pre_flight_scans_a_private_probe_dir_holding_only_the_fake_github_token() {
    begin pw2 || return 1
    commit_toml_at_head
    stage_file src/a.txt "one $MARKER"
    commit_cap "ok"
    assert_rc 0 "commit"
    local calls
    calls="$(<"$CALLS")"
    assert_eq "$(grep -c '^betterleaks-target-file: ' "$CALLS")" 1 "exactly one probe file"
    assert_eq "$(grep -c '^betterleaks-target-line: ' "$CALLS")" 1 "of one line"
    assert_contains "$calls" "betterleaks-target-line: $(probe_secret)" "holding the built-in-rule secret"
    assert_not_contains "$calls" "betterleaks-target-line: $MARKER" "and nothing of the commit"
    assert_eq "$(grep -c '^betterleaks dir .*/preflight/probe ' "$CALLS")" 1 "the target is the probe directory"
    assert_eq "$(grep -c '^betterleaks-config=.* cwd=.*/preflight/empty$' "$CALLS")" 1 "while the cwd stays the empty one"
    assert_eq "$(grep -c '^betterleaks ' "$CALLS")" 3 "the probe is folded into the pre-flight: pre-flight, main run and the rule-only run of our aws-access-key-id rule"
    no_leak "$(probe_secret)"
}

test_a_pre_flight_exit_code_that_is_neither_clean_nor_a_finding_blocks() {
    begin pw3 || return 1
    commit_toml_at_head
    stage_file src/a.txt "one $MARKER"
    set_env STUB_GL_PREFLIGHT_RC=2
    commit_cap "odd exit"
    assert_rc 1 "fail closed"
    assert_contains "$ERR" "does not load on its own" "says why"
    assert_empty "$(seen_by betterleaks)$(seen_by trufflehog)" "nothing was scanned"
    no_leak "$(probe_secret)"
}

test_nothing_is_announced_and_the_default_config_is_used_without_gitleaks_files_at_head() {
    begin gl3 || return 1
    stage_file other.txt hello && gitx commit -q --no-verify -m base
    stage_file .gitleaks.toml '[allowlist]' 'paths = [".*"]'
    stage_file .gitleaksignore '*'
    commit_cap "only staged"
    assert_rc 0 "allowed"
    assert_pass_line_only "$ERR" "no exemption announced for files that are not at HEAD"
    assert_contains "$(grep '^betterleaks-config=' "$CALLS")" "betterleaks-config=$TEST_WORK_BASE/" "the private default config is used"
    assert_not_contains "$(<"$CALLS")" "betterleaks-ignore-line" "no ignore file given"
}

test_a_gitleaks_config_that_is_not_a_file_at_head_blocks_the_commit() {
    begin gl4 || return 1
    stage_file .gitleaks.toml/inner.txt hello
    gitx commit -q --no-verify -m "a directory with that name"
    stage_file src/a.txt one
    commit_cap "blocked"
    assert_rc 1 "blocked"
    assert_contains "$ERR" ".gitleaks.toml at HEAD must be a regular file" "says why"
    assert_empty "$(seen_by betterleaks)$(seen_by trufflehog)" "nothing was scanned"
}

test_exemptions_work_under_commit_a_with_a_temporary_index() {
    begin sc7 || return 1
    stage_file docs/a.txt one && stage_file src/b.txt two && gitx commit -q --no-verify -m base
    commit_ignore_file 'docs/**   # generated, with a pattern that makes the hook build its probe repository'
    printf 'changed docs\n' >docs/a.txt
    printf 'changed src\n' >src/b.txt
    commit_cap "commit -a" -a
    assert_rc 0 "commit -a"
    assert_eq "$(seen_by betterleaks)" "src/b.txt" "only the non-excluded modification was scanned"
    assert_contains "$ERR" "1 staged file(s) excluded by .secret-scan-ignore" "announced"
    assert_eq "$(gitx show --stat --format= HEAD | grep -c '|')" 2 "git's temporary index was not disturbed: both files are in the commit"
    assert_eq "$(gitx status --porcelain)" "" "and nothing is left over"
}

test_patterns_with_spaces_and_glob_characters_exclude_the_right_files() {
    begin sc8 || return 1
    commit_ignore_file 'my dir/**   # a name with a space' '**/*.pem   # public certificates' 'file[1].txt   # literal brackets are a class in globs' '# **/*.md   # a commented-out pattern excludes nothing'
    stage_file "my dir/k.txt" a
    stage_file a/b/c.pem b
    stage_file src/x.txt c
    stage_file notes.md d
    stage_file file1.txt e
    commit_cap "globs"
    assert_rc 0 "commit"
    assert_eq "$(seen_by betterleaks | LC_ALL=C sort | tr '\n' ' ')" "notes.md src/x.txt " "space, **/*.pem and the bracket class excluded; the commented-out pattern did not exclude notes.md"
    assert_contains "$ERR" "3 staged file(s) excluded by .secret-scan-ignore" "count"
}

test_a_comment_only_or_empty_ignore_file_excludes_nothing_and_prints_nothing() {
    begin sc9 || return 1
    commit_ignore_file '# only comments' '' '   '
    stage_file src/a.txt one
    commit_cap "comments only"
    assert_rc 0 "commit"
    assert_pass_line_only "$ERR" "only the pass line"
    assert_eq "$(seen_by betterleaks)" "src/a.txt" "scanned"
    : >.secret-scan-ignore
    gitx add .secret-scan-ignore && gitx commit -q --no-verify -m "empty ignore file"
    stage_file src/b.txt two
    commit_cap "empty"
    assert_rc 0 "commit with an empty ignore file"
    assert_pass_line_only "$ERR" "only the pass line"
}

test_a_plain_directory_name_excludes_everything_below_it_but_not_a_same_named_file_elsewhere() {
    begin sc13 || return 1
    commit_ignore_file 'vendor   # third-party code' '*.lock   # lock files at the top level only'
    stage_file vendor/a/b/c.txt one
    stage_file src/vendor/x.txt two
    stage_file yarn.lock three
    stage_file sub/yarn.lock four
    commit_cap "dir name"
    assert_rc 0 "commit"
    assert_eq "$(seen_by betterleaks | LC_ALL=C sort | tr '\n' ' ')" "src/vendor/x.txt sub/yarn.lock " "vendor/ and the top-level lock file are excluded; a nested vendor/ and a nested lock file are not"
    assert_contains "$ERR" "2 staged file(s) excluded" "count"
}

# ^ external git puts its own exec-path first on PATH for hooks => a fake git on PATH is never reached
# ^ why includeIf gitdir scoped to $TMPDIR, not a global bad value; the repo being committed (outside it) must keep working, only the hook's probe repo breaks
break_probe_repository() {
    cp -- "$SANDBOX/gitconfig" "$SANDBOX/gitconfig-broken"
    printf '[includeIf "gitdir:%s/"]\n\tpath = %s\n' "$(git_path "$TEST_WORK_BASE")" "$(git_path "$SANDBOX/probe-breaker.cfg")" >>"$SANDBOX/gitconfig-broken"
    printf '[%s]\n\t%s = %s\n' "$1" "$2" "$3" >"$SANDBOX/probe-breaker.cfg"
    set_env GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig-broken"
}

test_the_commit_is_blocked_when_the_probe_repository_cannot_be_built() {
    begin sc10 || return 1
    commit_ignore_file 'docs/**   # generated'
    stage_file src/a.txt one
    break_probe_repository core autocrlf bogus
    commit_cap "no probe"
    assert_rc 1 "fails closed"
    assert_contains "$ERR" "cannot build the pattern probe repository" "says why"
    assert_empty "$(seen_by betterleaks)$(seen_by trufflehog)" "nothing was scanned"
}

test_the_commit_is_blocked_when_git_cannot_evaluate_a_pattern() {
    begin sc11 || return 1
    commit_ignore_file 'ok/**   # fine' 'docs/**   # generated'
    stage_file src/a.txt one
    break_probe_repository diff renames bogus
    commit_cap "no evaluation"
    assert_rc 1 "fails closed"
    assert_contains "$ERR" "cannot evaluate .secret-scan-ignore line 1 with git" "names the line"
    assert_empty "$(seen_by betterleaks)$(seen_by trufflehog)" "nothing was scanned"
}

union_case() {
    local name="$1" f
    local -a tracked
    read -ra tracked <<<"$2"
    shift 2
    begin "$name" || return 1
    for f in "${tracked[@]}"; do stage_file "$f" base; done
    gitx commit -q --no-verify -m base
    commit_ignore_file "$@"
    for f in "${tracked[@]}"; do stage_file "$f" "changed $MARKER"; done
    commit_cap "union"
    assert_rc 0 "[$name] allowed"
    assert_contains "$ERR" "WARNING: the patterns in .secret-scan-ignore together exempt every tracked file" "[$name] warns about the union"
    assert_contains "$ERR" "WARNING: every staged file with added lines is excluded" "[$name] and about this commit"
    assert_empty "$(seen_by betterleaks)" "[$name] nothing was scanned"
}

test_two_patterns_that_only_together_cover_every_name_are_warned_about() {
    union_case un-pair "src/k.py lib/m.py top.txt" '**/*[!t]   # not ending in t' '**/*t   # ending in t'
}

test_one_negated_class_pattern_that_covers_the_tree_is_warned_about() {
    union_case un-class "src/k.py lib/m.py .env" '**/[!a]*   # everything not starting with a'
}

test_a_list_of_directories_that_covers_the_tree_is_warned_about() {
    union_case un-dirs "src/k.py lib/m.py" 'src/**   # code' 'lib/**   # libraries'
}

test_no_union_warning_while_part_of_the_tree_is_still_scanned() {
    begin un-part || return 1
    stage_file src/a.py base && stage_file lib/b.py base && gitx commit -q --no-verify -m base
    commit_ignore_file 'src/**   # code'
    stage_file src/a.py "changed $MARKER"
    commit_cap "one directory"
    assert_rc 0 "allowed"
    assert_not_contains "$ERR" "together exempt" "lib/ is still tracked and scanned"
    assert_contains "$ERR" "WARNING: every staged file with added lines is excluded" "but this commit scanned nothing"
    stage_file lib/b.py "changed $MARKER"
    stage_file src/a.py "again $MARKER"
    commit_cap "mixed"
    assert_not_contains "$ERR" "WARNING" "a commit that still scans something is quiet about it"
    assert_contains "$ERR" "1 staged file(s) excluded" "count"
}

test_amend_can_fold_an_exemption_and_the_exempted_file_into_one_commit_a_documented_limit() {
    begin am || return 1
    stage_file base.txt hello && gitx commit -q --no-verify -m base
    commit_ignore_file 'secret/**   # fixtures'
    stage_file secret/k.txt "value $MARKER"
    commit_cap "amend" --amend
    assert_rc 0 "documented limit: HEAD is the commit that holds the ignore file, so --amend reads it as already committed"
    assert_empty "$(seen_by betterleaks)" "the amended-in file was not scanned"
    assert_eq "$(gitx show --stat --format= HEAD | grep -c '|')" 2 "and the resulting commit holds both the exemption and the exempted file"
}

test_patterns_without_glob_characters_never_need_the_probe_repository() {
    begin sc14 || return 1
    commit_ignore_file 'docs   # plain name' 'vendor/   # plain directory' 'tests/fixtures/k.txt   # plain file'
    stage_file docs/a.txt one && stage_file vendor/b.txt two && stage_file src/c.txt three
    break_probe_repository core autocrlf bogus
    commit_cap "plain patterns"
    assert_rc 0 "no probe is built for patterns that cannot be catch-alls"
    assert_eq "$(seen_by betterleaks)" "src/c.txt" "and the exclusions still apply"
    assert_contains "$ERR" "2 staged file(s) excluded" "count"
}

test_an_unreadable_head_tree_blocks_the_commit_instead_of_reading_as_no_exemption() {
    begin sc15 || return 1
    stage_file other.txt hello && gitx commit -q --no-verify -m base
    local tree
    tree="$(gitx rev-parse 'HEAD^{tree}')"
    rm -f -- ".git/objects/${tree:0:2}/${tree:2}"
    stage_file src/a.txt "x $MARKER"
    commit_cap "tree gone"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "cannot read .secret-scan-ignore at HEAD" "git could not read it"
    assert_not_contains "$ERR" "regular file" "and the message does not blame the file type"
    assert_empty "$(seen_by betterleaks)$(seen_by trufflehog)" "nothing was scanned"
}

# ^ external a local file:// remote with uploadpack.allowFilter serves a filtered clone; moving it away leaves an unreachable promisor
blocked_with_git_reason() {
    local filter="$1" name="$2" origin="$SANDBOX/origin-$2" line
    gitx init -q "$origin" && gitx -C "$origin" config uploadpack.allowFilter true || return 1
    (cd -- "$origin" && commit_ignore_file "docs/x.txt   # a reason") || return 1
    gitx clone -q --no-checkout --filter="$filter" "file://$origin" "$SANDBOX/repos/$name" || return 1
    mv -- "$origin" "$origin.gone" || return 1
    REPO="$SANDBOX/repos/$name"
    cd -- "$REPO" || return 1
    stage_file src/a.txt "x $(new_marker)"
    commit_cap "no promisor"
    assert_rc 1 "the exemption file cannot be read"
    assert_contains "$ERR" "cannot read .secret-scan-ignore at HEAD (git said: fatal: " "git's reason is part of the message"
    while IFS= read -r line; do
        case "$line" in "git-secret-guard: "* | "To bypass this check"*) ;; *) fail "raw git line on stderr: [$line]" ;; esac
    done <<<"$ERR"
}

test_a_head_blob_git_cannot_fetch_is_blocked_with_git_s_reason_folded_into_the_message() {
    blocked_with_git_reason blob:none pc1
}

test_a_head_tree_git_cannot_fetch_is_blocked_with_git_s_reason_folded_into_the_message() {
    blocked_with_git_reason tree:0 pc2
}

test_an_ignore_file_that_is_not_a_file_at_head_blocks_the_commit() {
    begin sc12 || return 1
    stage_file .secret-scan-ignore/inner.txt hello
    gitx commit -q --no-verify -m "a directory with that name"
    stage_file src/a.txt one
    commit_cap "blocked"
    assert_rc 1 "blocked"
    assert_contains "$ERR" ".secret-scan-ignore at HEAD must be a regular file" "says why"
    assert_empty "$(seen_by betterleaks)$(seen_by trufflehog)" "nothing was scanned"
}

test_a_symlink_as_the_ignore_file_or_gitleaks_config_at_head_blocks_the_commit() {
    local name n=0
    for name in .secret-scan-ignore .gitleaks.toml .gitleaksignore; do
        n=$((n + 1))
        begin "sym$n" || return 1
        stage_symlink '**   # a catch-all behind a symlink' "$name" && gitx commit -q --no-verify -m "symlink"
        stage_file src/a.txt "x $MARKER"
        commit_cap "blocked"
        assert_rc 1 "[$name] blocked"
        assert_contains "$ERR" "$name at HEAD must be a regular file" "[$name] says which file and what is expected"
        assert_empty "$(seen_by betterleaks)$(seen_by trufflehog)" "[$name] nothing was scanned"
    done
}

commit_toml_at_head() {
    stage_file .gitleaks.toml '[extend]' 'useDefault = true'
    gitx commit -q --no-verify -m "config"
}

test_a_head_gitleaks_config_that_does_not_load_alone_blocks_and_prints_message_words_only() {
    begin pf1 || return 1
    commit_toml_at_head
    stage_file src/a.txt "one $MARKER"
    set_env STUB_GL_PREFLIGHT_RC=1 STUB_GL_PREFLIGHT_ERROR="failed to load config error=\"open base.toml: no such file $MARKER\""
    commit_cap "blocked"
    assert_rc 1 "blocked"
    assert_contains "$ERR" ".gitleaks.toml at HEAD does not load on its own" "says why"
    assert_contains "$ERR" "failed to load config" "and what betterleaks said, message words only"
    assert_contains "$ERR" "[extend] path" "and the usual cause"
    assert_not_contains "$ERR" "scan failed" "not the opaque scanner failure"
    no_leak "$MARKER"
    assert_empty "$(seen_by betterleaks)$(seen_by trufflehog)" "nothing was scanned"
}

test_a_pre_flight_that_hangs_is_bounded_and_blocks() {
    begin pf2 || return 1
    commit_toml_at_head
    stage_file src/a.txt one
    use_stubs "SCAN_TIMEOUT_SECONDS=1"
    set_env STUB_GL_PREFLIGHT_SLEEP=20
    local t0 t1
    t0="$(date +%s)"
    commit_cap "hang"
    t1="$(date +%s)"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "did not finish" "says why"
    [ $((t1 - t0)) -lt 12 ] || fail "the pre-flight was not bounded: $((t1 - t0)) s"
}

test_a_config_that_loads_alone_passes_the_pre_flight_with_only_the_exemption_notice() {
    begin pf3 || return 1
    commit_toml_at_head
    stage_file src/a.txt one
    commit_cap "ok"
    assert_rc 0 "a config that loads alone passes"
    assert_eq "${ERR%%$'\n'*}" "git-secret-guard: using .gitleaks.toml from HEAD (this repository's betterleaks rules and allowlists apply)" "the exemption notice comes first"
    assert_pass_line_only "${ERR#*$'\n'}" "and the pass line is the only other line"
}

test_the_pre_flight_runs_from_an_empty_directory() {
    begin pf4 || return 1
    commit_toml_at_head
    stage_file src/a.txt one
    commit_cap "ok"
    assert_eq "$(grep -c '^betterleaks-config=.* cwd=.*/preflight/empty$' "$CALLS")" 1 "one run in an empty pre-flight directory"
    assert_contains "$(grep '^betterleaks-config=.*/preflight/empty$' "$CALLS")" "/repo-gitleaks.toml " "on the copy taken from HEAD"
}

test_a_replace_ref_on_head_cannot_substitute_a_permissive_ignore_file() {
    begin rr || return 1
    stage_file base.txt hello && gitx commit -q --no-verify -m base
    replace_head_with_permissive_commit .secret-scan-ignore 'src/**   # not in the branch history' || return 1
    assert_contains "$(gitx ls-tree --name-only HEAD)" ".secret-scan-ignore" "setup: plain git now reads the substitute"
    stage_file src/a.txt "x $MARKER"
    commit_cap "replaced HEAD"
    assert_eq "$(seen_by betterleaks)" "src/a.txt" "the real HEAD has no ignore file, so src/ is scanned"
    assert_not_contains "$ERR" "excluded by .secret-scan-ignore" "and nothing was excluded"
}

test_inherited_pathspec_variables_cannot_disable_the_excludes() {
    local v n=0
    for v in GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS; do
        n=$((n + 1))
        EXTRA_ENV=()
        begin "pv$n" || return 1
        commit_ignore_file 'docs/**   # generated'
        stage_file docs/a.txt "one $MARKER"
        stage_file src/b.txt "two $MARKER"
        set_env "$v=1"
        commit_cap "env"
        assert_rc 0 "[$v] commit"
        assert_eq "$(seen_by betterleaks)" "src/b.txt" "[$v] src is scanned and docs is the only exclusion"
    done
}

test_the_literal_pathspecs_flag_cannot_disable_the_excludes() {
    begin pf || return 1
    commit_ignore_file 'docs/**   # generated'
    stage_file docs/a.txt "one $MARKER"
    stage_file src/b.txt "two $MARKER"
    run_cap gitx --literal-pathspecs commit -q -m flag
    assert_rc 0 "commit"
    assert_eq "$(seen_by betterleaks)" "src/b.txt" "git --literal-pathspecs exports GIT_LITERAL_PATHSPECS to the hook"
    assert_not_contains "$ERR" "exempts the whole repository" "and no false catch-all warning"
}

test_other_inherited_git_settings_cannot_change_what_is_extracted() {
    begin gs || return 1
    stage_file src/app.txt a b c d && gitx commit -q --no-verify -m base
    stage_file src/app.txt a X c d
    set_env GIT_DIFF_OPTS=-u9 GIT_EXTERNAL_DIFF=/bin/false GIT_CONFIG_PARAMETERS="'diff.context'='7' 'diff.mnemonicPrefix'='true' 'diff.noprefix'='true' 'diff.renames'='copies' 'diff.algorithm'='patience' 'diff.suppressBlankEmpty'='true' 'diff.relative'='true' 'diff.interHunkContext'='9' 'color.ui'='always' 'diff.colorMoved'='zebra' 'core.whitespace'='cr-at-eol'"
    commit_cap "settings"
    assert_rc 0 "commit"
    assert_eq "$(<"$SANDBOX/record-gs.betterleaks")" "== src/app.txt

X" "only the added line, at its real line number, whatever the diff settings say"
}

run_file_tests
