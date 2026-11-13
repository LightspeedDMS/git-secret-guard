#!/usr/bin/env bash
# ^ coupled lib/extract.sh:extract_lfs_objects; Git LFS pointers are followed to their object by content, never by .gitattributes (#98)
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

begin() {
    local rc key_not_set=5
    # ^ why unset here, not per test; the sandbox's global config is shared by every test of the file, git config exits 5 when the key was not set
    git_literal_config --global --unset-all lfs.storage
    rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq "$key_not_set" ] || return 1
    new_repo "$1" || return 1
    MARKER="$(new_marker)"
    set_env STUB_LOG="$SANDBOX/calls-$1" STUB_MARKER="$MARKER" STUB_RECORD="$SANDBOX/record-$1"
}

# ^ invariant args = path, content file; stores the object under <repo>/.git/lfs, stages the pointer of the LFS spec, sets LFS_OID
# ^ external macOS has no sha256sum without the GNU keg, shasum comes with perl there; the tests accept either like the hook
lfs_stage() {
    local path="$1" content="$2" dir line
    if command -v sha256sum >/dev/null 2>&1; then line="$(sha256sum -- "$content")"; else line="$(shasum -a 256 -- "$content")"; fi
    LFS_OID="${line%% *}"
    [[ $LFS_OID =~ ^[0-9a-f]{64}$ ]] || return 1
    dir="$REPO/.git/lfs/objects/${LFS_OID:0:2}/${LFS_OID:2:2}"
    mkdir -p -- "$dir" "$(dirname -- "$path")" || return 1
    cp -- "$content" "$dir/$LFS_OID" || return 1
    printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %s\n' "$LFS_OID" "$(wc -c <"$content" | tr -d ' ')" >"$path" || return 1
    gitx add -- "$path"
}

test_an_lfs_object_is_scanned_instead_of_its_pointer() {
    begin lfs1 || return 1
    printf 'object line one\nobject line two\n' >"$SANDBOX/obj1" || return 1
    lfs_stage data/big.dat "$SANDBOX/obj1" || return 1
    commit_cap "lfs"
    assert_rc 0 commit
    local seen
    seen="$(<"$SANDBOX/record-lfs1.trufflehog")"
    assert_contains "$seen" "== data/big.dat" "the pointer's path is scanned"
    assert_contains "$seen" "object line two" "the object content reaches the scanner"
    assert_not_contains "$seen" "git-lfs.github.com" "the pointer text does not"
    [[ $ERR =~ $PASS_LINE_RE ]] || fail "stderr is not exactly the pass line: [$ERR]"
    assert_eq "${BASH_REMATCH[1]}" 1 "one file"
    assert_eq "${BASH_REMATCH[2]}" 2 "the object's two lines, not the pointer's three"
}

test_a_missing_object_blocks_and_names_the_path_and_the_reason() {
    begin lfs2 || return 1
    printf 'never stored\n' >"$SANDBOX/obj2" || return 1
    lfs_stage data/gone.dat "$SANDBOX/obj2" || return 1
    rm -- "$REPO/.git/lfs/objects/${LFS_OID:0:2}/${LFS_OID:2:2}/$LFS_OID" || return 1
    commit_cap "lfs"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "Git LFS file data/gone.dat: its object is not in the LFS storage" "path and reason"
    assert_contains "$ERR" "$REPO/.git/lfs" "the storage that was searched"
    assert_contains "$ERR" "nothing was committed" "what happened"
    assert_contains "$ERR" "run 'git lfs install', then 'git add' the file again, or commit from the machine that has the content" "the fix"
    assert_not_contains "$ERR" "lfs.extension" "the extension advice does not belong here"
    assert_contains "$ERR" "git commit --no-verify" "bypass hint"
    if gitx rev-parse -q --verify HEAD >/dev/null 2>&1; then fail "a commit was created"; fi
}

test_an_object_whose_sha256_differs_from_the_oid_blocks() {
    begin lfs3 || return 1
    local tampered
    tampered="$(fake_aws_key | LC_ALL=C tr '[:upper:]' '[:lower:]')" || return 1
    printf 'key = "%s"\n' "$(fake_aws_key)" >"$SANDBOX/obj3" || return 1
    lfs_stage data/swap.dat "$SANDBOX/obj3" || return 1
    printf 'key = "%s"\n' "$tampered" >"$REPO/.git/lfs/objects/${LFS_OID:0:2}/${LFS_OID:2:2}/$LFS_OID" || return 1
    commit_cap "lfs"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "Git LFS file data/swap.dat: its object does not match the pointer (SHA-256 differs" "path and reason"
    assert_contains "$ERR" "nothing was committed" "what happened"
    if gitx rev-parse -q --verify HEAD >/dev/null 2>&1; then fail "a commit was created"; fi
    no_leak "$tampered"
    no_leak "$(fake_aws_key)"
}

test_an_object_whose_size_differs_from_the_pointer_blocks() {
    begin lfs4 || return 1
    printf 'twelve bytes\n' >"$SANDBOX/obj4" || return 1
    lfs_stage data/size.dat "$SANDBOX/obj4" || return 1
    printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize 99\n' "$LFS_OID" >data/size.dat || return 1
    gitx add -- data/size.dat || return 1
    commit_cap "lfs"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "Git LFS file data/size.dat: its object is 13 bytes, the pointer says 99" "path and reason"
    if gitx rev-parse -q --verify HEAD >/dev/null 2>&1; then fail "a commit was created"; fi
}

test_lfs_storage_from_the_global_config_is_used() {
    begin lfs5 || return 1
    printf 'stored elsewhere\n' >"$SANDBOX/obj5" || return 1
    lfs_stage data/moved.dat "$SANDBOX/obj5" || return 1
    mv -- "$REPO/.git/lfs" "$SANDBOX/store5" || return 1
    git_literal_config --global lfs.storage "$(git_path "$SANDBOX/store5")" || return 1
    commit_cap "lfs"
    assert_rc 0 commit
    assert_contains "$(<"$SANDBOX/record-lfs5.trufflehog")" "stored elsewhere" "the object from the configured storage is scanned"
}

test_lfs_storage_from_the_repository_config_is_used_but_lfsconfig_is_not() {
    begin lfs6 || return 1
    printf 'hidden away\n' >"$SANDBOX/obj6" || return 1
    lfs_stage data/away.dat "$SANDBOX/obj6" || return 1
    mv -- "$REPO/.git/lfs" "$SANDBOX/store6" || return 1
    printf '[lfs]\n\tstorage = %s\n' "$(git_path "$SANDBOX/store6")" >.lfsconfig || return 1
    gitx add -- .lfsconfig || return 1
    commit_cap "lfsconfig only"
    assert_rc 1 "a .lfsconfig in the commit does not point the hook elsewhere"
    assert_contains "$ERR" "Git LFS file data/away.dat: its object is not in the LFS storage ($REPO/.git/lfs)" "the default storage was used"
    gitx config --local lfs.storage "$(git_path "$SANDBOX/store6")" || return 1
    commit_cap "repository config"
    assert_rc 0 "the repository's own config is a legitimate shared storage; size and SHA-256 keep it safe"
    assert_contains "$(<"$SANDBOX/record-lfs6.trufflehog")" "hidden away" "the object from that storage was scanned"
}

test_a_relative_global_lfs_storage_is_taken_from_the_common_dir() {
    begin lfs7 || return 1
    printf 'relative store\n' >"$SANDBOX/obj7" || return 1
    lfs_stage data/rel.dat "$SANDBOX/obj7" || return 1
    mv -- "$REPO/.git/lfs" "$REPO/.git/other-lfs" || return 1
    git_literal_config --global lfs.storage other-lfs || return 1
    commit_cap "lfs"
    assert_rc 0 commit
    assert_contains "$(<"$SANDBOX/record-lfs7.trufflehog")" "relative store" "scanned from <common dir>/other-lfs"
}

test_a_binary_object_is_verified_but_adds_no_lines_to_scan() {
    begin lfs9 || return 1
    printf 'bin\0ary text\n' >"$SANDBOX/obj9" || return 1
    lfs_stage data/blob.bin "$SANDBOX/obj9" || return 1
    commit_cap "lfs"
    assert_rc 0 commit
    assert_eq "$ERR" "git-secret-guard: no added lines to scan" "git shows no lines of a binary file, nor does the hook"
}

test_a_symlink_object_blocks() {
    begin lfs10 || return 1
    printf 'behind a link\n' >"$SANDBOX/obj10" || return 1
    lfs_stage data/link.dat "$SANDBOX/obj10" || return 1
    local obj="$REPO/.git/lfs/objects/${LFS_OID:0:2}/${LFS_OID:2:2}/$LFS_OID"
    mv -- "$obj" "$SANDBOX/real10" && ln -s "$SANDBOX/real10" "$obj" || return 1
    commit_cap "lfs"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "Git LFS file data/link.dat: its object is a symbolic link" "path and reason"
}

test_a_malformed_pointer_is_scanned_as_text() {
    begin lfs11 || return 1
    printf 'near miss\n' >"$SANDBOX/obj11" || return 1
    lfs_stage data/odd.dat "$SANDBOX/obj11" || return 1
    printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize 10\nextra line\n' "$LFS_OID" >data/odd.dat || return 1
    gitx add -- data/odd.dat || return 1
    commit_cap "lfs"
    assert_rc 0 commit
    assert_contains "$(<"$SANDBOX/record-lfs11.trufflehog")" "extra line" "the blob itself was scanned"
    assert_not_contains "$(<"$SANDBOX/record-lfs11.trufflehog")" "near miss" "the object was not followed"
}

test_a_linked_worktree_uses_the_common_dir_storage() {
    begin lfs12 || return 1
    printf 'base\n' >base.txt && gitx add -- base.txt && gitx commit -q --no-verify -m base || return 1
    gitx worktree add -q "$SANDBOX/wt12" || return 1
    printf 'from a worktree\n' >"$SANDBOX/obj12" || return 1
    cd -- "$SANDBOX/wt12" || return 1
    lfs_stage data/wt.dat "$SANDBOX/obj12" || return 1
    commit_cap "lfs"
    assert_rc 0 commit
    assert_contains "$(<"$SANDBOX/record-lfs12.trufflehog")" "from a worktree" "object found in the main repository's lfs dir"
}

test_real_a_key_inside_an_lfs_object_blocks_and_is_never_printed() {
    [ -x "$REAL_TRUFFLEHOG" ] && [ -x "$REAL_BETTERLEAKS" ] || skip_test "the real scanners are not installed"
    use_real_tools
    begin lfs13 || return 1
    local key
    key="$(fake_aws_key)" || return 1
    [ -n "$key" ] || return 1
    printf 'aws_key = %s\n' "$key" >"$SANDBOX/obj13" || return 1
    lfs_stage secret.dat "$SANDBOX/obj13" || return 1
    commit_cap "lfs"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "secret.dat:1" "file and line of the object"
    no_leak "$key"
    # ^ why the key without its four-character AKIA prefix too, not only whole; a redacted print would still show the body
    no_leak "${key:4}"
    if gitx rev-parse -q --verify HEAD >/dev/null 2>&1; then fail "a commit was created"; fi
}

test_real_git_lfs_objects_are_followed_on_add_and_on_modify() {
    [ -x "$REAL_TRUFFLEHOG" ] && [ -x "$REAL_BETTERLEAKS" ] || skip_test "the real scanners are not installed"
    begin lfs14 || return 1
    gitx lfs version >/dev/null 2>&1 || skip_test "git-lfs is not installed"
    use_real_tools
    local key
    key="$(fake_aws_key)" || return 1
    [ -n "$key" ] || return 1
    gitx lfs install --local >/dev/null 2>&1 || return 1
    gitx lfs track '*.dat' >/dev/null 2>&1 || return 1
    gitx add .gitattributes || return 1
    gitx commit -q --no-verify -m attrs || return 1
    printf 'one\ntwo\n' >clean.dat && gitx add -- clean.dat || return 1
    commit_cap "lfs v1"
    assert_rc 0 "a clean LFS file"
    [[ $ERR =~ $PASS_LINE_RE ]] || fail "stderr is not exactly the pass line: [$ERR]"
    assert_eq "${BASH_REMATCH[2]}" 2 "the object's two lines, not the pointer's three"
    printf 'one\ntwo\naws_key = %s\n' "$key" >clean.dat && gitx add -- clean.dat || return 1
    commit_cap "lfs v2"
    assert_rc 1 "a key added to the LFS file"
    assert_contains "$ERR" "clean.dat:3" "the line of the object, not of the pointer"
    no_leak "$key"
}

# ^ coupled lib/extract.sh:_lfs_parse_pointer; args = file; prints pointer or text, the hook's verdict on those bytes (NUL mapped to 0x01 like the batch read)
# shellcheck disable=SC2016
lfs_hook_verdict() {
    LC_ALL=C tr '\000' '\001' <"$1" >"$1.n" || return 1
    env -i "${GSG_ENV[@]}" bash -c 'source "$1/lib/common.sh" && source "$1/lib/extract.sh" && IFS= read -r -d "" b <"$2"; if _lfs_parse_pointer "$b"; then echo pointer; else echo text; fi' _ "$SHARE" "$1.n"
}

# ^ external git-lfs 3.7.1 decoder, probed with git lfs pointer --check => blob trimmed, CR dropped, empty lines skipped, ext lines before size
test_real_the_hook_recognises_exactly_the_pointers_git_lfs_accepts() {
    begin lfs15 || return 1
    gitx lfs version >/dev/null 2>&1 || skip_test "git-lfs is not installed"
    local o p v name fmt want got rc bad="" nl=$'\n' n=0
    o="$(printf 'a%.0s' {1..64})" p="$(printf 'b%.0s' {1..64})"
    v='version https://git-lfs.github.com/spec/v1'
    local -a table=(
        "base|$v\noid sha256:$o\nsize 5\n"
        "crlf|$v\r\noid sha256:$o\r\nsize 5\r\n"
        "no final LF|$v\noid sha256:$o\nsize 5"
        "hawser|version https://hawser.github.com/spec/v1\noid sha256:$o\nsize 5\n"
        "git-media|version http://git-media.io/v/2\noid sha256:$o\nsize 5\n"
        "other version|version https://example.com/v1\noid sha256:$o\nsize 5\n"
        "http lfs url|version http://git-lfs.github.com/spec/v1\noid sha256:$o\nsize 5\n"
        "ext upper|$v\next-0-Foo sha256:$p\noid sha256:$o\nsize 5\n"
        "ext before version|ext-0-foo sha256:$p\n$v\noid sha256:$o\nsize 5\n"
        "ext between oid and size|$v\noid sha256:$o\next-0-foo sha256:$p\nsize 5\n"
        "ext after size|$v\noid sha256:$o\nsize 5\next-0-foo sha256:$p\n"
        "ext two digits|$v\next-10-foo sha256:$p\noid sha256:$o\nsize 5\n"
        "ext odd name|$v\next-0-a/b:c sha256:$p\noid sha256:$o\nsize 5\n"
        "ext name starts with dot|$v\next-0-.a sha256:$p\noid sha256:$o\nsize 5\n"
        "ext bad digest|$v\next-0-foo sha256:abc\noid sha256:$o\nsize 5\n"
        "ext without value|$v\next-0-foo\noid sha256:$o\nsize 5\n"
        "ext repeated|$v\next-0-foo sha256:$p\next-0-foo sha256:$p\noid sha256:$o\nsize 5\n"
        "unknown key|$v\noid sha256:$o\nfoo bar\nsize 5\n"
        "duplicate size|$v\noid sha256:$o\nsize 5\nsize 5\n"
        "size leading zero|$v\noid sha256:$o\nsize 05\n"
        "size plus|$v\noid sha256:$o\nsize +5\n"
        "size minus|$v\noid sha256:$o\nsize -5\n"
        "size minus zero|$v\noid sha256:$o\nsize -0\n"
        "size int64 max|$v\noid sha256:$o\nsize 9223372036854775807\n"
        "size over int64|$v\noid sha256:$o\nsize 9223372036854775808\n"
        "size long zeros|$v\noid sha256:$o\nsize 000000000000000000000000000005\n"
        "size hex|$v\noid sha256:$o\nsize 0x5\n"
        "size two words|$v\noid sha256:$o\nsize 5 6\n"
        "blank lines|$v\n\noid sha256:$o\n\nsize 5\n"
        "crlf blank lines|$v\r\n\r\noid sha256:$o\r\nsize 5\r\n"
        "leading blank lines|\n\n$v\noid sha256:$o\nsize 5\n"
        "space-only line|$v\n   \noid sha256:$o\nsize 5\n"
        "leading tab on oid|$v\n\toid sha256:$o\nsize 5\n"
        "leading space on version|  $v\noid sha256:$o\nsize 5\n"
        "trailing space on size|$v\noid sha256:$o\nsize 5 \n"
        "trailing space on oid|$v\noid sha256:$o \nsize 5\n"
        "unicode space around|\xe3\x80\x80$v\noid sha256:$o\nsize 5\n\xc2\xa0"
        "zero width space after|$v\noid sha256:$o\nsize 5\n\xe2\x80\x8b"
        "double CR|$v\r\r\noid sha256:$o\nsize 5\n"
        "oid upper case|$v\noid sha256:${o^^}\nsize 5\n"
        "oid md5|$v\noid md5:$o\nsize 5\n"
        "oid first|oid sha256:$o\n$v\nsize 5\n"
        "size before oid|$v\nsize 5\noid sha256:$o\n"
        "duplicate version|$v\n$v\noid sha256:$o\nsize 5\n"
        "BOM|\xef\xbb\xbf$v\noid sha256:$o\nsize 5\n"
        "extra junk line|$v\noid sha256:$o\nsize 5\njunk\n"
    )
    for fmt in "${table[@]}"; do
        n=$((n + 1))
        name="${fmt%%|*}"
        printf '%b' "${fmt#*|}" >"$SANDBOX/fx" || return 1
        gitx lfs pointer --check --file "$SANDBOX/fx" >/dev/null 2>&1
        rc=$?
        want=text
        if [ "$rc" -eq 0 ]; then want=pointer; fi
        got="$(lfs_hook_verdict "$SANDBOX/fx")" || return 1
        if [ "$got" != "$want" ]; then bad+="$nl$name: git-lfs says $want, the hook says $got"; fi
    done
    [ -z "$bad" ] || fail "the hook and git-lfs disagree on $bad"
    [ "$n" -ge 40 ] || fail "too few fixtures ran ($n)"
}

# ^ invariant args = repo name, file count; stages small plain files, commits with GIT_TRACE on, prints the ls-files and cat-file run counts
lfs_trace_count() {
    local i trace="$SANDBOX/trace-$1"
    begin "$1" || return 1
    mkdir -p -- plain || return 1
    for ((i = 1; i <= $2; i++)); do printf 'plain file %s\n' "$i" >"plain/f$i.txt" || return 1; done
    gitx add -A || return 1
    rm -f -- "$trace"
    set_env GIT_TRACE="$trace"
    commit_cap "plain"
    [ "$RC" -eq 0 ] || return 1
    printf '%s %s' "$(grep -c 'git ls-files' "$trace")" "$(grep -c 'git cat-file' "$trace")"
}

test_small_plain_files_cost_no_git_process_per_file() {
    local few many
    few="$(lfs_trace_count lfs16 3)" || return 1
    many="$(lfs_trace_count lfs17 300)" || return 1
    assert_eq "$many" "$few" "the number of ls-files and cat-file runs does not grow with the number of files"
    assert_eq "${many%% *}" 0 "no per-file git ls-files"
    [ "${many##* }" -le 2 ] || fail "more than two cat-file runs for 300 plain files: [$many]"
}

test_a_failing_sha256sum_blocks_with_a_clear_line_and_shasum_is_not_a_fallback() {
    begin lfs18 || return 1
    local tool
    printf 'cannot hash\n' >"$SANDBOX/obj18" || return 1
    lfs_stage data/nohash.dat "$SANDBOX/obj18" || return 1
    mkdir -p -- "$SANDBOX/nosha" || return 1
    printf '#!/bin/sh\nexit 1\n' >"$SANDBOX/nosha/sha256sum" || return 1
    chmod 755 "$SANDBOX/nosha/sha256sum" || return 1
    set_env PATH="$SANDBOX/nosha:$REAL_HOME/.local/bin:$TEST_BASE_PATH"
    # ^ external the hook puts GNUBIN_DIR from the settings first on PATH (macOS) => the stand-in must be in a gnubin copy, with every other GNU tool linked
    if [ -n "$TEST_GNUBIN" ]; then
        mkdir -p -- "$SANDBOX/gnubin-fail" || return 1
        for tool in "$TEST_GNUBIN"/*; do ln -sf -- "$tool" "$SANDBOX/gnubin-fail/" || return 1; done
        ln -sf -- "$SANDBOX/nosha/sha256sum" "$SANDBOX/gnubin-fail/sha256sum" || return 1
        use_stubs "GNUBIN_DIR=$SANDBOX/gnubin-fail"
    fi
    commit_cap "lfs"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "Git LFS file data/nohash.dat: the SHA-256 of its object cannot be computed (sha256sum is missing or failed)" "path and reason"
    if gitx rev-parse -q --verify HEAD >/dev/null 2>&1; then fail "a commit was created"; fi
}

test_real_every_pointer_form_git_lfs_accepts_is_blocked_end_to_end() {
    [ -x "$REAL_TRUFFLEHOG" ] && [ -x "$REAL_BETTERLEAKS" ] || skip_test "the real scanners are not installed"
    use_real_tools
    begin lfs19 || return 1
    local key name form text n=0 size ver='version https://git-lfs.github.com/spec/v1'
    key="$(fake_aws_key)" || return 1
    [ -n "$key" ] || return 1
    printf 'aws_key = %s\n' "$key" >"$SANDBOX/obj19" || return 1
    lfs_stage seed.dat "$SANDBOX/obj19" || return 1
    gitx reset -q || return 1
    size="$(wc -c <"$SANDBOX/obj19" | tr -d ' ')" || return 1
    [ -n "$size" ] || return 1
    local -a forms=(
        "crlf|$ver\r\noid sha256:@O@\r\nsize @S@\r\n"
        "size with leading zeros|$ver\noid sha256:@O@\nsize 000@S@\n"
        "size with plus|$ver\noid sha256:@O@\nsize +@S@\n"
        "no final line feed|$ver\noid sha256:@O@\nsize @S@"
        "hawser|version https://hawser.github.com/spec/v1\noid sha256:@O@\nsize @S@\n"
        "git-media|version http://git-media.io/v/2\noid sha256:@O@\nsize @S@\n"
        "blank lines and trailing spaces|\n$ver\n\noid sha256:@O@\nsize @S@  \n\n"
    )
    for form in "${forms[@]}"; do
        n=$((n + 1))
        name="${form%%|*}"
        text="${form#*|}"
        text="${text//@O@/$LFS_OID}"
        text="${text//@S@/$size}"
        printf '%b' "$text" >"form$n.dat" || return 1
        gitx add -f -- "form$n.dat" || return 1
        commit_cap "form $name"
        assert_rc 1 "$name: blocked"
        assert_contains "$ERR" "form$n.dat:1" "$name: the finding is in the object"
        no_leak "$key"
        gitx reset -q || return 1
    done
}

# ^ invariant prints the storage path of the object lfs_stage stored last (LFS_OID), in the default storage of the repository
lfs_object_path() { printf '%s' "$REPO/.git/lfs/objects/${LFS_OID:0:2}/${LFS_OID:2:2}/$LFS_OID"; }

test_an_unreadable_object_blocks() {
    [ "$(id -u)" -ne 0 ] || skip_test "root reads a file whatever its mode"
    begin lfs20 || return 1
    printf 'locked\n' >"$SANDBOX/obj20" || return 1
    lfs_stage data/locked.dat "$SANDBOX/obj20" || return 1
    chmod 000 "$(lfs_object_path)" || return 1
    commit_cap "lfs"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "Git LFS file data/locked.dat: its object cannot be read" "path and reason"
}

test_a_directory_object_blocks() {
    begin lfs21 || return 1
    printf 'a directory\n' >"$SANDBOX/obj21" || return 1
    lfs_stage data/dir.dat "$SANDBOX/obj21" || return 1
    rm -- "$(lfs_object_path)" && mkdir -- "$(lfs_object_path)" || return 1
    commit_cap "lfs"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "Git LFS file data/dir.dat: its object is not a regular file" "path and reason"
}

# ^ why 20 seconds, not the scanner timeout; a commit waiting on a pipe never ends, the whole hook takes about two seconds
HANG_LIMIT_SECONDS=20

test_a_fifo_object_blocks_without_hanging() {
    begin lfs23 || return 1
    printf 'a pipe\n' >"$SANDBOX/obj23" || return 1
    lfs_stage data/pipe.dat "$SANDBOX/obj23" || return 1
    rm -- "$(lfs_object_path)" && mkfifo -- "$(lfs_object_path)" || return 1
    run_cap timeout "$HANG_LIMIT_SECONDS" env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$GIT" commit -q -m "lfs"
    assert_rc 1 "blocked, not hung"
    assert_contains "$ERR" "Git LFS file data/pipe.dat: its object is not a regular file" "path and reason"
}

test_lfs_storage_given_with_dash_c_is_used() {
    begin lfs24 || return 1
    printf 'from -c\n' >"$SANDBOX/obj24" || return 1
    lfs_stage data/dashc.dat "$SANDBOX/obj24" || return 1
    mv -- "$REPO/.git/lfs" "$SANDBOX/store24" || return 1
    run_cap gitx -c "lfs.storage=$(git_path "$SANDBOX/store24")" commit -q -m "lfs"
    assert_rc 0 commit
    assert_contains "$(<"$SANDBOX/record-lfs24.trufflehog")" "from -c" "the object from the -c storage was scanned"
}

test_a_partial_commit_follows_only_the_pointer_it_commits() {
    begin lfs25 || return 1
    printf 'in the partial commit\n' >"$SANDBOX/obj25a" && printf 'left in the index\n' >"$SANDBOX/obj25b" || return 1
    lfs_stage data/a.dat "$SANDBOX/obj25a" && lfs_stage data/b.dat "$SANDBOX/obj25b" || return 1
    commit_cap "partial" -- data/a.dat
    assert_rc 0 "git commit -- path"
    assert_contains "$(<"$SANDBOX/record-lfs25.trufflehog")" "in the partial commit" "the named pointer was followed"
    assert_not_contains "$(<"$SANDBOX/record-lfs25.trufflehog")" "left in the index" "the other staged pointer is not part of this commit"
}

test_commit_a_follows_a_pointer_changed_in_the_work_tree() {
    begin lfs26 || return 1
    printf 'first version\n' >"$SANDBOX/obj26a" || return 1
    lfs_stage data/c.dat "$SANDBOX/obj26a" && gitx commit -q --no-verify -m base || return 1
    printf 'second version\n' >"$SANDBOX/obj26b" || return 1
    lfs_stage data/c.dat "$SANDBOX/obj26b" && gitx reset -q -- data/c.dat || return 1
    commit_cap "all" -a
    assert_rc 0 "git commit -a"
    assert_contains "$(<"$SANDBOX/record-lfs26.trufflehog")" "second version" "commit -a followed the pointer it staged"
}

test_lfs_files_under_secret_scan_ignore_are_skipped_and_the_rest_followed() {
    begin lfs22 || return 1
    commit_ignore_file 'skipped/**  # generated data' || return 1
    printf 'excluded content\n' >"$SANDBOX/obj27a" && printf 'checked content\n' >"$SANDBOX/obj27b" || return 1
    lfs_stage skipped/x.dat "$SANDBOX/obj27a" || return 1
    rm -- "$(lfs_object_path)" || return 1
    lfs_stage kept/y.dat "$SANDBOX/obj27b" || return 1
    commit_cap "lfs"
    assert_rc 0 "an excluded pointer needs no object"
    assert_not_contains "$(<"$SANDBOX/record-lfs22.trufflehog")" "excluded content" "the excluded file is not scanned"
    assert_contains "$(<"$SANDBOX/record-lfs22.trufflehog")" "checked content" "the other pointer is followed"
}

test_real_git_lfs_rename_with_change_is_followed_and_a_pure_rename_adds_nothing() {
    [ -x "$REAL_TRUFFLEHOG" ] && [ -x "$REAL_BETTERLEAKS" ] || skip_test "the real scanners are not installed"
    begin lfs8 || return 1
    gitx lfs version >/dev/null 2>&1 || skip_test "git-lfs is not installed"
    use_real_tools
    local key
    key="$(fake_aws_key)" || return 1
    [ -n "$key" ] || return 1
    gitx lfs install --local >/dev/null 2>&1 && gitx lfs track '*.dat' >/dev/null 2>&1 || return 1
    # ^ why an old mtime, not a fresh file; an old file is stat-clean and never racy, git reads it every time (#103), the outcome is fixed
    gitx add .gitattributes && printf 'one\ntwo\nthree\n' >old.dat && touch -d '2 hours ago' old.dat && gitx add -- old.dat && gitx commit -q --no-verify -m base || return 1
    gitx mv old.dat same.dat || return 1
    commit_cap "pure rename"
    assert_rc 0 "a pure rename"
    # ^ why exactly this line, not a pass line; the diff is between two trees (#103), the rename leaves the pointer unchanged and adds nothing
    assert_eq "$ERR" "git-secret-guard: no added lines to scan" "a pure rename of an LFS file adds nothing"
    gitx mv same.dat moved.dat && printf 'one\ntwo\nthree\naws_key = %s\n' "$key" >moved.dat && gitx add -- moved.dat || return 1
    commit_cap "rename with change"
    assert_rc 1 "a rename that adds a key to the object"
    assert_contains "$ERR" "moved.dat:4" "the line of the object, not of the pointer"
    no_leak "$key"
}

test_a_pointer_with_an_extension_line_blocks_even_when_its_object_verifies() {
    begin lfs27 || return 1
    local size
    printf 'transformed on the way in\n' >"$SANDBOX/obj27" || return 1
    size="$(wc -c <"$SANDBOX/obj27" | tr -d ' ')" || return 1
    lfs_stage data/ext.dat "$SANDBOX/obj27" || return 1
    printf 'version https://git-lfs.github.com/spec/v1\next-0-gz sha256:%s\noid sha256:%s\nsize %s\n' "$LFS_OID" "$LFS_OID" "$size" >data/ext.dat || return 1
    gitx add -- data/ext.dat || return 1
    commit_cap "lfs"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "Git LFS file data/ext.dat: it uses the Git LFS extension gz, so its stored object is transformed and cannot be scanned" "path and reason"
    assert_contains "$ERR" "a file stored through a Git LFS extension cannot be scanned: commit it without the extension (remove its lfs.extension setting for this path and 'git add' it again)" "advice for an extension"
    assert_not_contains "$ERR" "git lfs install" "the object advice cannot help here"
    if gitx rev-parse -q --verify HEAD >/dev/null 2>&1; then fail "a commit was created"; fi
}

test_real_a_git_lfs_gzip_extension_commit_is_blocked() {
    [ -x "$REAL_TRUFFLEHOG" ] && [ -x "$REAL_BETTERLEAKS" ] || skip_test "the real scanners are not installed"
    begin lfs28 || return 1
    gitx lfs version >/dev/null 2>&1 || skip_test "git-lfs is not installed"
    use_real_tools
    local key
    key="$(fake_aws_key)" || return 1
    [ -n "$key" ] || return 1
    gitx lfs install --local >/dev/null 2>&1 && gitx lfs track '*.dat' >/dev/null 2>&1 || return 1
    gitx config --local lfs.extension.gz.clean 'gzip -nc' && gitx config --local lfs.extension.gz.smudge 'gzip -dc' && gitx config --local lfs.extension.gz.priority 0 || return 1
    printf 'aws_key = %s\n' "$key" >zipped.dat || return 1
    gitx add .gitattributes zipped.dat || return 1
    commit_cap "gzip extension"
    assert_rc 1 "an object a clean filter transformed cannot be scanned, so the commit is blocked"
    assert_contains "$ERR" "Git LFS file zipped.dat: it uses the Git LFS extension gz" "path and reason"
    no_leak "$key"
    if gitx rev-parse -q --verify HEAD >/dev/null 2>&1; then fail "a commit was created"; fi
}

test_only_blobs_under_1024_bytes_are_pointers() {
    begin lfs29 || return 1
    local limit=1024 name have
    printf 'padded pointer\n' >"$SANDBOX/obj29" || return 1
    lfs_stage data/seed.dat "$SANDBOX/obj29" || return 1
    for name in "$((limit - 1))" "$limit"; do
        cp -- data/seed.dat "data/p$name.dat" || return 1
        have="$(wc -c <"data/p$name.dat" | tr -d ' ')" || return 1
        head -c "$((name - have))" /dev/zero | tr '\0' ' ' >>"data/p$name.dat" || return 1
        gitx add -- "data/p$name.dat" || return 1
        assert_eq "$(gitx cat-file -s ":data/p$name.dat")" "$name" "fixture size"
    done
    gitx rm -q --cached -- data/seed.dat || return 1
    commit_cap "lfs"
    assert_rc 0 commit
    assert_contains "$(<"$SANDBOX/record-lfs29.trufflehog")" "padded pointer" "the object of the $((limit - 1))-byte pointer was scanned"
    assert_eq "$(grep -c 'git-lfs.github.com' "$SANDBOX/record-lfs29.trufflehog")" 1 "only the $limit-byte blob was scanned as text, with its pointer lines"
}

test_both_kinds_of_problem_print_both_pieces_of_advice() {
    begin lfs30 || return 1
    local size
    printf 'object that went missing\n' >"$SANDBOX/obj30a" && printf 'object behind an extension\n' >"$SANDBOX/obj30b" || return 1
    lfs_stage data/gone.dat "$SANDBOX/obj30a" || return 1
    rm -- "$(lfs_object_path)" || return 1
    size="$(wc -c <"$SANDBOX/obj30b" | tr -d ' ')" || return 1
    lfs_stage data/ext.dat "$SANDBOX/obj30b" || return 1
    printf 'version https://git-lfs.github.com/spec/v1\next-0-gz sha256:%s\noid sha256:%s\nsize %s\n' "$LFS_OID" "$LFS_OID" "$size" >data/ext.dat || return 1
    gitx add -- data/ext.dat || return 1
    commit_cap "lfs"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "Git LFS file data/gone.dat: its object is not in the LFS storage" "the missing object"
    assert_contains "$ERR" "Git LFS file data/ext.dat: it uses the Git LFS extension gz" "the extension"
    assert_contains "$ERR" "a file stored through a Git LFS extension cannot be scanned: commit it without the extension (remove its lfs.extension setting for this path and 'git add' it again)" "advice for the extension"
    assert_contains "$ERR" "for the other files, run 'git lfs install', then 'git add' the file again, or commit from the machine that has the content" "advice for the object"
}

run_file_tests
