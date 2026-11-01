#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

CORPUS=""
ODD_NAMES=($'tab\tx.txt' 'q"uote.txt' 'back\slash.txt' $'ctl\001x.txt' 'ünï/ƒ.txt' 'sp ace/a b.txt' $'nl\nname.txt')
MALFORMED_WANT=("unsafe path refused" "absolute path refused" "diff path without the b/ prefix" "unsupported byte escape" "unknown escape"
    "unterminated quoted path" "unparsable hunk header" "unexpected line inside a hunk" "diff ended inside a hunk" "file appears twice"
    "added line outside any file" "empty path" "unsupported byte escape" "bad octal escape")

# ^ external Ubuntu's default awk is mawk and RHEL's is gawk; code under test calls plain awk => a farm directory first on PATH picks the interpreter
# ^ invariant awk_farm NAME prints a directory holding one entry, "awk", a link to the interpreter NAME; rc 1 when NAME is not installed
awk_farm() {
    local bin dir="$SANDBOX/awkbin-$1"
    bin="$(type -P "$1")" || return 1
    mkdir -p -- "$dir" && ln -sfn -- "$bin" "$dir/awk" && printf '%s' "$dir"
}

need_both_awks() {
    if ! type -P mawk >/dev/null || ! type -P gawk >/dev/null; then skip_test "needs both mawk and gawk installed (mawk: $(type -P mawk || echo no), gawk: $(type -P gawk || echo no))"; fi
}

# ^ invariant sets CORPUS = a repository with a base commit and a staged change set covering every branch of lib/extract.awk
build_corpus() {
    local i
    CORPUS="$SANDBOX/corpus"
    if [ -f "$CORPUS/.built" ]; then return 0; fi
    rm -rf -- "$CORPUS"
    mkdir -p -- "$CORPUS" && cd -- "$CORPUS" && gitx init -q . || return 1
    printf '%s\n' one two three four five six >plain.txt
    printf 'old\n' >del.txt
    printf 'keep1\nkeep2\nkeep3\nkeep4\n' >ren-old.txt
    printf 'first\nsecond' >noeol.txt
    seq 1 25000 >big.txt
    printf 'x\0y\n' >bin.dat
    gitx add -A && gitx commit -q --no-verify -m base || return 1
    printf '%s\n' one two three-new four five six seven-new >plain.txt
    printf '++x\n--y\n+++z\n@@ -1 +1 @@\n leading\n' >plusplus.txt
    printf 'first\nsecond\nthird-no-eol' >noeol.txt
    sed 's/^24999$/big-new/' big.txt >big.tmp && mv big.tmp big.txt
    gitx rm -q del.txt && gitx mv ren-old.txt ren-new.txt && printf 'keep1\nkeep2\nchanged3\nkeep4\n' >ren-new.txt
    printf 'x\0z\n' >bin2.dat
    : >empty.txt
    printf '%s\n' $'a\\b\\\\c &amp; \\1 \\n \\\\' $'\\' '%s %d %%' "\"quoted\" and 'single'" >specials.txt
    head -c 200000 /dev/zero | tr '\0' 'L' >long.txt && printf '\n' >>long.txt
    for i in "${!ODD_NAMES[@]}"; do
        mkdir -p -- "$(dirname -- "${ODD_NAMES[$i]}")" && printf 'odd %s\n' "$i" >"${ODD_NAMES[$i]}" || return 1
    done
    gitx add -A && : >"$CORPUS/.built"
}

# ^ invariant extract_with NAME TREE runs the production staged_diff | extract_added_lines pipeline over the corpus with NAME as the awk on PATH
extract_with() {
    local farm
    farm="$(awk_farm "$1")" || return 1
    rm -rf -- "$2"
    # shellcheck disable=SC2016
    run_cap env -i "${GSG_ENV[@]}" PATH="$farm:${GIT%/*}:/usr/bin:/bin" bash -c \
        'set -o pipefail; cd "$1" && source "$2/lib/common.sh" && source "$2/lib/extract.sh" && staged_diff | extract_added_lines "$3"' _ "$CORPUS" "$GSG_PROJECT" "$2"
}

check_tree() {
    local tree="$1" label="$2" i
    assert_eq "$(<"$tree/plain.txt")" $'\n\nthree-new\n\n\n\nseven-new' "$label: plain.txt has the added lines at their own numbers"
    assert_eq "$(<"$tree/plusplus.txt")" $'++x\n--y\n+++z\n@@ -1 +1 @@\n leading' "$label: ++, --, +++ and @@ lookalikes are content"
    assert_eq "$(<"$tree/noeol.txt")" $'\nsecond\nthird-no-eol' "$label: the no-newline marker is skipped"
    assert_eq "$(wc -l <"$tree/big.txt")" 24999 "$label: line 24999 of a 25000-line file keeps its number"
    assert_eq "$(tail -n 1 "$tree/big.txt")" big-new "$label: and its text"
    assert_eq "$(<"$tree/ren-new.txt")" $'\n\nchanged3' "$label: a renamed file is read at its new name"
    assert_eq "$(<"$tree/specials.txt")" $'a\\b\\\\c &amp; \\1 \\n \\\\\n\\\n%s %d %%\n"quoted" and \'single\'' "$label: backslashes, ampersands and percent signs survive"
    assert_eq "$(wc -c <"$tree/long.txt")" 200001 "$label: a 200000-character line is kept whole"
    for i in "${!ODD_NAMES[@]}"; do
        assert_eq "$(<"$tree/${ODD_NAMES[$i]}")" "odd $i" "$label: odd name $i"
    done
    assert_no_file "$tree/del.txt" "$label: a deleted file adds nothing"
    assert_no_file "$tree/bin.dat" "$label: binary files add nothing"
    assert_no_file "$tree/bin2.dat" "$label: new binary files add nothing"
    assert_no_file "$tree/empty.txt" "$label: an empty file adds nothing"
}

check_extraction_with() {
    type -P "$1" >/dev/null || skip_test "$1 is not installed"
    build_corpus || return 1
    extract_with "$1" "$SANDBOX/tree-$1"
    assert_rc 0 "extraction under $1"
    check_tree "$SANDBOX/tree-$1" "$1"
}

test_extraction_under_gawk() { check_extraction_with gawk; }
test_extraction_under_mawk() { check_extraction_with mawk; }

test_mawk_and_gawk_extract_identical_trees() {
    need_both_awks
    build_corpus || return 1
    extract_with gawk "$SANDBOX/tree-cmp-gawk"
    assert_rc 0 "gawk"
    extract_with mawk "$SANDBOX/tree-cmp-mawk"
    assert_rc 0 "mawk"
    run_cap diff -r "$SANDBOX/tree-cmp-gawk" "$SANDBOX/tree-cmp-mawk"
    assert_rc 0 "the two trees differ: ${OUT:0:300}"
}

# ^ invariant diff_case N prints malformed diff number N (1 to 14); MALFORMED_WANT[N-1] is the start of the message lib/extract.awk dies with
diff_case() {
    case "$1" in
        1) printf '%s\n' '+++ b/../x' '@@ -0,0 +1 @@' '+a' ;;
        2) printf '%s\n' '+++ b//abs' '@@ -0,0 +1 @@' '+a' ;;
        3) printf '%s\n' '+++ x/y' ;;
        4) printf '%s\n' '+++ "b/\777"' ;;
        5) printf '%s\n' '+++ "b/\q"' ;;
        6) printf '%s\n' '+++ "b/open' ;;
        7) printf '%s\n' '@@ nonsense' ;;
        8) printf '%s\n' '+++ b/a' '@@ -0,0 +1,2 @@' '+x' 'weird' ;;
        9) printf '%s\n' '+++ b/a' '@@ -0,0 +1,2 @@' '+x' ;;
        10) printf '%s\n' '+++ b/a' '@@ -0,0 +1 @@' '+x' '+++ b/a' '@@ -0,0 +1 @@' '+y' ;;
        11) printf '%s\n' '@@ -0,0 +1 @@' '+x' ;;
        12) printf '%s\n' '+++ b/' ;;
        13) printf '%s\n' '+++ "b/\000"' ;;
        14) printf '%s\n' '+++ "b/\1"' ;;
    esac
}

# ^ invariant malformed_report NAME writes "N rc=R err=TEXT" per case and for an unset GSG_SCAN_DIR, running lib/extract.awk under interpreter NAME
malformed_report() {
    local bin n rc out="$SANDBOX/malformed-$1"
    bin="$(type -P "$1")" || return 1
    : >"$out"
    for n in $(seq 1 14); do
        mkdir -p -- "$SANDBOX/malformed-scan-$1-$n" || return 1
        diff_case "$n" | env -i LC_ALL=C GSG_SCAN_DIR="$SANDBOX/malformed-scan-$1-$n" "$bin" -f "$GSG_PROJECT/lib/extract.awk" >/dev/null 2>"$out.err"
        rc="${PIPESTATUS[1]}"
        printf '%s rc=%s err=%s\n' "$n" "$rc" "$(<"$out.err")" >>"$out"
    done
    env -i LC_ALL=C "$bin" -f "$GSG_PROJECT/lib/extract.awk" </dev/null >/dev/null 2>"$out.err"
    printf 'unset rc=%s err=%s\n' "$?" "$(<"$out.err")" >>"$out"
}

check_malformed_with() {
    local n
    type -P "$1" >/dev/null || skip_test "$1 is not installed"
    malformed_report "$1" || return 1
    for n in $(seq 1 14); do
        assert_contains "$(<"$SANDBOX/malformed-$1")" "$n rc=2 err=extract: ${MALFORMED_WANT[$((n - 1))]}" "$1: malformed diff $n is refused with exit 2"
    done
    assert_contains "$(<"$SANDBOX/malformed-$1")" "unset rc=2 err=extract: GSG_SCAN_DIR is not set" "$1: no scan directory"
}

test_malformed_diffs_fail_the_same_way_under_gawk() { check_malformed_with gawk; }
test_malformed_diffs_fail_the_same_way_under_mawk() { check_malformed_with mawk; }

test_mawk_and_gawk_agree_on_every_malformed_diff() {
    need_both_awks
    malformed_report gawk && malformed_report mawk || return 1
    run_cap diff "$SANDBOX/malformed-gawk" "$SANDBOX/malformed-mawk"
    assert_rc 0 "different failures: ${OUT:0:300}"
}

# ^ invariant inline_run NAME SCRIPT ARGS... runs bash -c SCRIPT with interpreter NAME as the awk first on PATH; git and the system tools follow
inline_run() {
    local farm script="$2"
    farm="$(awk_farm "$1")" || return 1
    shift 2
    env -i "${GSG_ENV[@]}" PATH="$farm:${GIT%/*}:/usr/bin:/bin" bash -c "$script" "$@"
}

# ^ invariant bounds_case NAME LABEL NFILES SIZE MAXFILES MAXBYTES [sparse] prints the verdict of install_check_backup_bounds on a flat directory
# ^ external a directory entry has a size of its own => the cases hold regular files only
bounds_case() {
    local dir="$SANDBOX/bounds-$2" i rc msg
    rm -rf -- "$dir" && mkdir -p -- "$dir" || return 1
    for ((i = 0; i < $3; i++)); do head -c "$4" /dev/zero >"$dir/f$i" || return 1; done
    if [ "${7:-}" = sparse ]; then truncate -s 3G "$dir/sparse" || return 1; fi
    # shellcheck disable=SC2016
    inline_run "$1" 'source "$1/lib/common.sh" && source "$1/lib/install.sh" && GSG_BACKUP_MAX_FILES="$3" GSG_BACKUP_MAX_BYTES="$4" && install_check_backup_bounds "$2"' \
        _ "$GSG_PROJECT" "$dir" "$5" "$6" 2>"$SANDBOX/.bounds.err"
    rc=$?
    msg="$(sed "s#$dir#DIR#" "$SANDBOX/.bounds.err")"
    printf 'bounds %s rc=%s%s\n' "$2" "$rc" "${msg:+ $msg}"
}

# ^ invariant inline_report NAME writes $SANDBOX/inline-NAME, one section per awk program other than lib/extract.awk
inline_report() {
    local out="$SANDBOX/inline-$1" work="$SANDBOX/report-work" cov="$SANDBOX/cov" f
    build_corpus || return 1
    mkdir -p -- "$work" "$cov" || return 1
    printf 'trufflehog\tgithub\tunknown\tsrc/a b.txt\t12\ntrufflehog\tdetect%%sor\tunknown\tp%%d.txt\t1\n' >"$work/trufflehog.rows"
    printf 'gitleaks\taws-access-token\tfinding\t100%%.txt\t3\n' >"$work/gitleaks.rows"
    : >"$work/trufflehog.errors" && : >"$work/gitleaks.errors" || return 1
    printf '%s\n' 'x=1' '# ^ note this tag is not in the vocabulary' '# ^ why we pick bash here' '# explains the obvious' 'y=2 # trailing' >"$SANDBOX/planted.sh"
    # shellcheck disable=SC2016
    printf '%s\n' '# shellcheck shell=bash' 'a=1' 'if [ "$a" = 1 ]; then' '    b=2' 'fi' "c='multi" "line'" 'd=4' >"$cov/sample.sh"
    printf 'TRACE sample.sh:2:\nTRACE sample.sh:4:\nTTRACE sample.sh:8:\n' >"$cov/trace"
    {
        # shellcheck disable=SC2016
        printf 'numstat=%s\n' "$(inline_run "$1" 'cd "$1" && source "$2/lib/common.sh" && source "$2/lib/extract.sh" && staged_added_file_count' _ "$CORPUS" "$GSG_PROJECT")"
        bounds_case "$1" files-at-limit 3 1 3 100
        bounds_case "$1" files-over-limit 4 1 3 100
        bounds_case "$1" files-ten-over-nine 10 0 9 100
        bounds_case "$1" bytes-at-limit 1 10 10 10
        bounds_case "$1" bytes-over-limit 1 11 10 10
        bounds_case "$1" bytes-hundred-over-ninety-nine 1 100 10 99
        bounds_case "$1" bytes-3g-over-2g 0 0 10 2147483648 sparse
        bounds_case "$1" empty-dir 0 0 3 100
        # shellcheck disable=SC2016
        inline_run "$1" 'source "$1/lib/common.sh" && source "$1/lib/report.sh" && report_results "$2"' _ "$GSG_PROJECT" "$work" >/dev/null 2>"$SANDBOX/.report.err"
        sed 's/^/report: /' "$SANDBOX/.report.err"
        # shellcheck disable=SC2016
        inline_run "$1" 'awk -f "$1/tests/comment-rules.awk" "$2"' _ "$GSG_PROJECT" "$SANDBOX/planted.sh" | sed "s#$SANDBOX#SB#; s/^/lint: /"
        # shellcheck disable=SC2016
        printf 'projectlint=%s\n' "$(cd -- "$GSG_PROJECT" && for f in hooks/secret-scan bin/git-secret-guard lib/*.sh lib/scanners/*.sh tests/*.sh tests/platform/*.sh tests/stubs/* lib/extract.awk tests/*.awk; do
            inline_run "$1" 'awk -f "$1/tests/comment-rules.awk" "$2"' _ "$GSG_PROJECT" "$f"
        done | wc -l)"
        # shellcheck disable=SC2016
        (cd -- "$cov" && inline_run "$1" 'awk -v trace="$2" -f "$1/tests/coverage.awk" sample.sh' _ "$GSG_PROJECT" "$cov/trace") | sed 's/^/coverage: /'
    } >"$out"
}

inline_expected() {
    cat <<'EOF'
numstat=14
bounds files-at-limit rc=0
bounds files-over-limit rc=1 git-secret-guard: refusing to back up DIR: it holds more than 3 files
bounds files-ten-over-nine rc=1 git-secret-guard: refusing to back up DIR: it holds more than 9 files
bounds bytes-at-limit rc=0
bounds bytes-over-limit rc=1 git-secret-guard: refusing to back up DIR: it is larger than 10 bytes
bounds bytes-hundred-over-ninety-nine rc=1 git-secret-guard: refusing to back up DIR: it is larger than 99 bytes
bounds bytes-3g-over-2g rc=1 git-secret-guard: refusing to back up DIR: it is larger than 2147483648 bytes
bounds empty-dir rc=0
report: git-secret-guard: 3 potential secret(s) in lines this commit adds:
report:   gitleaks   aws-access-token (finding)  100%.txt:3
report:   trufflehog detect%sor (unknown)  p%d.txt:1
report:   trufflehog github (unknown)  src/a b.txt:12
report:   (values are not shown; remove them and rotate any real credential)
lint: SB/planted.sh:2: unknown tag [note]: # ^ note this tag is not in the vocabulary
lint: SB/planted.sh:3: why needs ', not <alternative>': # ^ why we pick bash here
lint: SB/planted.sh:4: free comment: # explains the obvious
lint: SB/planted.sh:5: trailing comment: y=2 # trailing
projectlint=0
coverage: sample.sh                            3/5    60.0%
coverage:     3: if [ "$a" = 1 ]; then
coverage:     6: c='multi
coverage: TOTAL 3/5 60.0%
EOF
}

check_inline_with() {
    type -P "$1" >/dev/null || skip_test "$1 is not installed"
    inline_report "$1" || return 1
    inline_expected >"$SANDBOX/inline-want"
    run_cap diff "$SANDBOX/inline-want" "$SANDBOX/inline-$1"
    assert_rc 0 "$1: the report differs from the expectation: ${OUT:0:3000}"
}

test_the_inline_awk_programs_give_the_expected_results_under_gawk() { check_inline_with gawk; }
test_the_inline_awk_programs_give_the_expected_results_under_mawk() { check_inline_with mawk; }

test_mawk_and_gawk_agree_on_the_inline_awk_programs() {
    need_both_awks
    inline_report gawk && inline_report mawk || return 1
    run_cap diff "$SANDBOX/inline-gawk" "$SANDBOX/inline-mawk"
    assert_rc 0 "the two reports differ: ${OUT:0:600}"
}

# ^ external mawk 1.3.4 words a failed open or close itself and exits 2 before extract.awk sees close()
# ^ invariant check_awk_error_with NAME = the added path is a directory with ESC and TAB in its name => the interpreter fails on it
# shellcheck disable=SC2016
check_awk_error_with() {
    local farm odd=$'a\e[31m\tb.txt' dir="$SANDBOX/l4-$1"
    type -P "$1" >/dev/null || skip_test "$1 is not installed"
    farm="$(awk_farm "$1")" || return 1
    rm -rf -- "$dir" && mkdir -p -- "$dir/scan/$odd" || return 1
    printf '%s\n' "+++ b/$odd" '@@ -0,0 +1 @@' '+x' >"$dir/diff" || return 1
    run_cap env -i "${GSG_ENV[@]}" PATH="$farm:${GIT%/*}:/usr/bin:/bin" bash -c \
        'source "$1/lib/common.sh" && source "$1/lib/extract.sh" && extract_added_lines "$2" <"$3"' _ "$GSG_PROJECT" "$dir/scan" "$dir/diff"
    assert_rc 2 "$1: the write error ends the extraction"
    if [ -z "$ERR" ]; then fail "$1: no error was reported"; fi
    if LC_ALL=C grep -q '[^ -~]' <<<"$ERR"; then fail "$1: raw control or non-ASCII bytes reached stderr"; fi
    if [[ $ERR == *"?" ]]; then fail "$1: the error text ends in a stray ? (the line end was marked): [${ERR: -40}]"; fi
}

test_an_awk_write_error_on_an_odd_path_is_sanitized_under_gawk() { check_awk_error_with gawk; }
test_an_awk_write_error_on_an_odd_path_is_sanitized_under_mawk() { check_awk_error_with mawk; }

run_file_tests
