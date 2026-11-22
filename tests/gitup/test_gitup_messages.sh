#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/product_call.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/product_call.sh"

# ^ coupled the refusals, wordings and clauses a product function prints for the git upgrade; no sandbox install, runs on Git for Windows too

test_the_refusal_without_a_way_to_elevate_lists_only_commands_that_can_be_typed() {
    pc_run 'gitup_can_elevate() { return 1; }
        GITUP_PRIV_CMDS=("dnf install -y git-core"
            "cp -a -- /usr/bin/<file> /v/orig.new/<file>"
            "install -m 644 -- <work dir>/record /v/record.new"
            "mv -T -- /v/orig /v/orig.old  [only when an earlier backup exists]"
            "rm -f -- /v/.<file>.gsg-new  [only when a move failed]"
            "mkdir -p -- /v/doc")
        gitup_need_elevation'
    assert_rc 1 "no way to elevate"
    assert_contains "$ERR" "  dnf install -y git-core" "a plain command is listed"
    assert_contains "$ERR" "  mkdir -p -- /v/doc" "another plain command is listed"
    assert_not_contains "$ERR" "<file>" "a per-file placeholder is not typeable"
    assert_not_contains "$ERR" "<work dir>" "the work dir placeholder is not typeable"
    assert_not_contains "$ERR" "[only when" "a conditional line is not listed as a command"
    assert_contains "$ERR" "cannot be typed by hand" "the reason is said"
    assert_contains "$ERR" "run the whole install as root" "with the way out"
}

test_a_root_override_that_resolves_to_the_filesystem_root_is_refused() {
    local r
    for r in / // /. /./ /.. /a/.. /a/../.. //./; do
        pc_run 'GSG_GITUP_ROOT="$1"; gitup_paths' "$r"
        assert_rc 1 "GSG_GITUP_ROOT=[$r]"
        assert_contains "$ERR" "must name a directory below /" "says why for [$r]"
    done
    pc_run 'GSG_GITUP_ROOT="$1"; gitup_paths; echo "[$GITUP_PREFIX]"' /srv/sandbox.d/root
    assert_rc 0 "a plain absolute directory still passes"
    assert_contains "$OUT" "[/srv/sandbox.d/root/usr/local]" "and moves the prefix"
}

# ^ invariant a record naming the six files with no link in place and a dnf.conf without the entry = the takeover is partly undone
undone_record() {
    local n d="$SANDBOX/root/var/lib/git-secret-guard/system-git"
    mkdir -p -- "$d" || return 1
    printf 'git-secret-guard system git takeover 1\npackage git-core-2.52.0\nexcludes git git-core\n' >"$d/record" || return 1
    for n in git git-receive-pack git-shell git-upload-archive git-upload-pack scalar; do
        printf 'file %s %064d\n' "$n" 0 >>"$d/record" || return 1
        printf 'x\n' >"$SANDBOX/root/usr/bin/$n" || return 1
    done
    printf '[main]\ngpgcheck=1\n' >"$SANDBOX/root/etc/dnf/dnf.conf" || return 1
}

test_an_undone_takeover_is_described_in_words_and_not_by_a_bare_label() {
    pc_root_dirs && undone_record || return 1
    pc_run_as_root 'gitup_tk_status; printf "%s\n%s\n" "$GITUP_TK_STATE" "$GITUP_TK_TEXT"'
    assert_rc 0 "status"
    assert_contains "$OUT" "undone" "the state"
    assert_contains "$OUT" "the takeover is partly undone (0 of 6 links are in place" "the text says what happened and the counts"
    assert_not_contains "$OUT" "UNDONE" "no shouted label that reads oddly after MISMATCH"
}

test_an_interrupted_restore_gives_the_next_command_once() {
    pc_root_dirs || return 1
    printf '[main]\n# git-secret-guard: takeover; original: none\nexcludepkgs=git\n' >"$SANDBOX/root/etc/dnf/dnf.conf" || return 1
    pc_run_as_root 'gitup_tk_restore_stopped 130'
    assert_rc 130 "the signal status"
    assert_contains "$ERR" "was interrupted" "says so"
    assert_eq "$(printf '%s' "$ERR" | grep -o 'run: git-secret-guard restore-system-git' | wc -l | tr -d ' ')" 1 "the next command appears once"
}

test_a_signal_during_the_final_rmdir_does_not_ask_for_a_repeat_with_nothing_to_do() {
    pc_root_dirs || return 1
    rmdir -- "$SANDBOX/root/var/lib/git-secret-guard" || return 1
    pc_run_as_root 'gitup_tk_restore_stopped 130'
    assert_rc 130 "the signal status"
    assert_contains "$ERR" "nothing is left to do" "the restore had finished"
    assert_not_contains "$ERR" "restore-system-git (it can be repeated" "and no repeat is suggested"
}

test_restore_removes_the_empty_state_directory_a_by_hand_restore_left() {
    pc_root_dirs || return 1
    pc_run_as_root 'gitup_tk_restore'
    assert_rc 0 "restore with no record"
    assert_no_file "$SANDBOX/root/var/lib/git-secret-guard" "the empty directory is gone"
    assert_contains "$OUT" "nothing to restore" "says there was no takeover"
    assert_contains "$OUT" "removed the empty directory" "and says what it removed"
}

test_the_interrupted_copy_clause_puts_the_next_step_first_and_nests_nothing() {
    pc_run 'GITUP_PIN_VER=2.56.0; GITUP_PREFIX=/usr/local; gitup_source_copy_clause /usr/local/share/doc/git-2.56.0-local'
    assert_rc 0 "the clause"
    assert_contains "$OUT" "partly copied into /usr/local" "files may be in the prefix"
    assert_contains "$OUT" "install --upgrade-git again" "the next step"
    assert_contains "$OUT" "MANIFEST.partial" "the partial manifest"
    assert_not_contains "$OUT" "((" "no parenthesis inside a parenthesis"
    assert_not_contains "$OUT" "; " "no semicolon, gitup_changed_drop splits GITUP_CHANGED on it and must find the clause whole"
    assert_eq "$(printf '%s' "$OUT" | tr -cd '(')" "" "the clause has no parenthesis at all, the caller wraps it"
}

test_a_signal_during_the_last_step_with_a_backup_directory_left_does_not_say_nothing_is_left() {
    pc_root_dirs || return 1
    mkdir -p -- "$SANDBOX/root/var/lib/git-secret-guard/system-git/orig" || return 1
    pc_run_as_root 'gitup_tk_restore_stopped 130'
    assert_rc 130 "the signal status"
    assert_not_contains "$ERR" "nothing is left to do" "something is left"
    assert_contains "$ERR" "system-git is left" "it names the backup directory"
    assert_contains "$ERR" "rm -rf -- $SANDBOX/root/var/lib/git-secret-guard/system-git" "and the command that removes it"
}

run_file_tests
