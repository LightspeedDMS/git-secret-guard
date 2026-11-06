#!/usr/bin/env bash
# shellcheck source=tests/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# ^ why GSG_ENV and a bare prelude, not lc_begin; these tests call product functions only, and run on Git for Windows too (the class there is windows)
FU_PRELUDE='set -u; GSG_ROOT="$1"; shift
for lib in brew common state tools hookspath wsl install install_tools gitup gitup_source gitup_takeover exempt timer launchd doctor; do source "$GSG_ROOT/lib/$lib.sh" || exit 9; done
'

fu() {
    local code="$1"
    shift
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c "$FU_PRELUDE$code" _ "$GSG_PROJECT" "$@"
    OUT="$(<"$SANDBOX/.out")"
    ERR="$(<"$SANDBOX/.err")"
}

test_the_refusal_without_a_way_to_elevate_lists_only_commands_that_can_be_typed() {
    fu 'gitup_can_elevate() { return 1; }
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
        fu 'GSG_GITUP_ROOT="$1"; gitup_paths' "$r"
        assert_rc 1 "GSG_GITUP_ROOT=[$r]"
        assert_contains "$ERR" "must name a directory below /" "says why for [$r]"
    done
    fu 'GSG_GITUP_ROOT="$1"; gitup_paths; echo "[$GITUP_PREFIX]"' /srv/sandbox.d/root
    assert_rc 0 "a plain absolute directory still passes"
    assert_contains "$OUT" "[/srv/sandbox.d/root/usr/local]" "and moves the prefix"
}


test_a_dangling_global_config_symlink_leaves_no_empty_file_at_its_target() {
    local link="$SANDBOX/linkcfg" target="$SANDBOX/real-config"
    # ^ why nativestrict, not plain ln -s; plain ln -s on Git for Windows copies or fails and this test needs a real symlink
    MSYS=winsymlinks:nativestrict ln -s -- real-config "$link" 2>/dev/null
    if [ ! -L "$link" ]; then skip_test "this host cannot make a symbolic link"; fi
    set_env GSG_GIT="$GIT" GIT_CONFIG_GLOBAL="$(git_path "$link")"
    fu 'install_check_config_writable'
    assert_rc 0 "the probe through a dangling link works"
    assert_no_file "$target" "the probe left no empty config behind the link"
    [ -L "$link" ] || fail "the link itself is untouched"
}

# ^ invariant fu_root points the product at a sandbox /var, /usr and /etc owned by the current user and acts as root; no real system path is reachable
fu_root() {
    local code="$1"
    shift
    fu 'GSG_GITUP_ROOT="$1"; shift; gitup_paths || exit 9; gitup_is_root() { return 0; }
        gitup_system_bin() { REPLY="$(command -v "$1")"; }
        '"$code" "$SANDBOX/root" "$@"
}

fu_dirs() {
    if [ -z "$SANDBOX" ] || [[ $SANDBOX != /* ]]; then fail "SANDBOX is not an absolute path"; return 1; fi
    rm -rf -- "$SANDBOX/root" || return 1
    mkdir -p -- "$SANDBOX/root/usr/bin" "$SANDBOX/root/usr/local/bin" "$SANDBOX/root/etc/dnf" "$SANDBOX/root/var/lib/git-secret-guard"
}

# ^ invariant a record naming the six files with no link in place and a dnf.conf without the entry = the takeover is partly undone
fu_undone_record() {
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
    fu_dirs && fu_undone_record || return 1
    fu_root 'gitup_tk_status; printf "%s\n%s\n" "$GITUP_TK_STATE" "$GITUP_TK_TEXT"'
    assert_rc 0 "status"
    assert_contains "$OUT" "undone" "the state"
    assert_contains "$OUT" "the takeover is partly undone (0 of 6 links are in place" "the text says what happened and the counts"
    assert_not_contains "$OUT" "UNDONE" "no shouted label that reads oddly after MISMATCH"
}

test_an_interrupted_restore_gives_the_next_command_once() {
    fu_dirs || return 1
    printf '[main]\n# git-secret-guard: takeover; original: none\nexcludepkgs=git\n' >"$SANDBOX/root/etc/dnf/dnf.conf" || return 1
    fu_root 'gitup_tk_restore_stopped 130'
    assert_rc 130 "the signal status"
    assert_contains "$ERR" "was interrupted" "says so"
    assert_eq "$(printf '%s' "$ERR" | grep -o 'run: git-secret-guard restore-system-git' | wc -l | tr -d ' ')" 1 "the next command appears once"
}

test_a_signal_during_the_final_rmdir_does_not_ask_for_a_repeat_with_nothing_to_do() {
    fu_dirs || return 1
    rmdir -- "$SANDBOX/root/var/lib/git-secret-guard" || return 1
    fu_root 'gitup_tk_restore_stopped 130'
    assert_rc 130 "the signal status"
    assert_contains "$ERR" "nothing is left to do" "the restore had finished"
    assert_not_contains "$ERR" "restore-system-git (it can be repeated" "and no repeat is suggested"
}

test_restore_removes_the_empty_state_directory_a_by_hand_restore_left() {
    fu_dirs || return 1
    fu_root 'gitup_tk_restore'
    assert_rc 0 "restore with no record"
    assert_no_file "$SANDBOX/root/var/lib/git-secret-guard" "the empty directory is gone"
    assert_contains "$OUT" "nothing to restore" "says there was no takeover"
    assert_contains "$OUT" "removed the empty directory" "and says what it removed"
}

test_ctrl_c_while_the_cli_starts_says_that_nothing_was_changed() {
    local tree="$SANDBOX/startup-tree"
    if [ -z "$SANDBOX" ] || [[ $SANDBOX != /* ]]; then fail "SANDBOX is not an absolute path"; return 1; fi
    rm -rf -- "$tree" && mkdir -p -- "$tree" || return 1
    cp -R -- "$GSG_PROJECT/bin" "$GSG_PROJECT/lib" "$GSG_PROJECT/VERSION" "$tree/" || return 1
    # ^ why a signal sent by the library itself, not a timed kill; it is the same SIGINT a terminal sends, at a fixed point of the startup
    printf '\nkill -INT $$\n' >>"$tree/lib/state.sh" || return 1
    run_cap env --default-signal=INT env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$tree/bin/git-secret-guard" status
    assert_rc 130 "ended by the signal"
    assert_contains "$ERR" "interrupted" "says so"
    assert_contains "$ERR" "nothing was changed" "and that nothing was changed"
}

test_the_interrupted_copy_clause_puts_the_next_step_first_and_nests_nothing() {
    fu 'GITUP_PIN_VER=2.56.0; GITUP_PREFIX=/usr/local; gitup_source_copy_clause /usr/local/share/doc/git-2.56.0-local'
    assert_rc 0 "the clause"
    assert_contains "$OUT" "partly copied into /usr/local" "files may be in the prefix"
    assert_contains "$OUT" "install --upgrade-git again" "the next step"
    assert_contains "$OUT" "MANIFEST.partial" "the partial manifest"
    assert_not_contains "$OUT" "((" "no parenthesis inside a parenthesis"
    assert_not_contains "$OUT" "; " "no semicolon, gitup_changed_drop splits GITUP_CHANGED on it and must find the clause whole"
    assert_eq "$(printf '%s' "$OUT" | tr -cd '(')" "" "the clause has no parenthesis at all, the caller wraps it"
}

# ^ invariant a stand-in for the git GitHub Desktop bundles, at the path the product looks for below the sandbox root
fu_bundled_git() {
    local d="$SANDBOX/root/usr/lib/github-desktop/resources/app/git/bin"
    fu_dirs && mkdir -p -- "$d" || return 1
    printf '#!/bin/sh\necho "git version %s"\n' "$1" >"$d/git" && chmod 755 "$d/git"
}

# ^ invariant a second old git (2.52, like /usr/bin/git on the RHEL host) after the real one on PATH; its own warning must not be mistaken for the bundled git's
FU_OLD_ON_PATH='PATH="$PATH:$1"; '
fu_old_git_dir() {
    mkdir -p -- "$SANDBOX/oldgit" || return 1
    printf '#!/bin/sh\necho "git version 2.52.0"\n' >"$SANDBOX/oldgit/git" && chmod 755 "$SANDBOX/oldgit/git"
}

test_the_git_bundled_with_github_desktop_is_named_and_said_to_skip_the_scan_as_measured() {
    fu_bundled_git 2.45.3 || return 1
    fu_old_git_dir || return 1
    fu_root "$FU_OLD_ON_PATH"'GSG_GIT="$(type -P git)"; GSG_GIT_USED="$(realpath -- "$GSG_GIT")"; install_report_other_gits' "$SANDBOX/oldgit"
    assert_rc 0 "a warning does not fail install"
    assert_contains "$ERR" "/usr/lib/github-desktop/resources/app/git/bin/git is git 2.45.3" "the bundled git and its version"
    assert_contains "$ERR" "GitHub Desktop" "says whose it is"
    assert_contains "$ERR" "commits made with it are not scanned (measured with 2.45.3)" "and that, as measured, its commits are not scanned"
    assert_not_contains "$ERR" "has not been tested" "the warning no longer says the question is open"
    assert_contains "$ERR" "oldgit/git is git 2.52.0; it ignores config-based hooks" "the second old git still gets the plain warning"
}

test_a_bundled_git_that_is_new_enough_is_not_warned_about() {
    fu_bundled_git 2.56.0 || return 1
    fu_old_git_dir || return 1
    fu_root "$FU_OLD_ON_PATH"'GSG_GIT="$(type -P git)"; GSG_GIT_USED="$(realpath -- "$GSG_GIT")"; install_report_other_gits' "$SANDBOX/oldgit"
    assert_rc 0 "no warning"
    assert_not_contains "$ERR" "github-desktop" "a git >= 2.54 reads config hooks"
}

test_doctor_lists_the_bundled_git_as_a_warning_with_the_same_wording() {
    fu_bundled_git 2.45.3 || return 1
    fu_old_git_dir || return 1
    fu_root "$FU_OLD_ON_PATH"'doctor_machine_line() { printf "%s|%s\n" "$1" "$2"; }; doctor_check_git' "$SANDBOX/oldgit"
    assert_contains "$OUT" "WARNING|git: $SANDBOX/root/usr/lib/github-desktop/resources/app/git/bin/git is git 2.45.3" "doctor names it"
    assert_contains "$OUT" "commits made with it are not scanned (measured with 2.45.3)" "and says, as measured, its commits are not scanned"
    assert_not_contains "$OUT" "has not been tested" "the warning no longer says the question is open"
    assert_contains "$OUT" "oldgit/git is git 2.52.0; it ignores config-based hooks" "the second old git still gets the plain warning"
}

test_ctrl_c_while_the_cli_starts_names_a_homebrew_install_this_run_already_made() {
    local tree="$SANDBOX/startup-tree-brew"
    if [ -z "$SANDBOX" ] || [[ $SANDBOX != /* ]]; then fail "SANDBOX is not an absolute path"; return 1; fi
    rm -rf -- "$tree" && mkdir -p -- "$tree" || return 1
    cp -R -- "$GSG_PROJECT/bin" "$GSG_PROJECT/lib" "$GSG_PROJECT/VERSION" "$tree/" || return 1
    # ^ why BREW_INSTALLED set by the library, not a real brew; it is the value the bootstrap leaves after brew install bash
    printf '\nBREW_INSTALLED=bash\nkill -INT $$\n' >>"$tree/lib/state.sh" || return 1
    run_cap env --default-signal=INT env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$tree/bin/git-secret-guard" status
    assert_rc 130 "ended by the signal"
    assert_contains "$ERR" "the only change made was the Homebrew install of bash" "the claim is not nothing was changed"
    assert_not_contains "$ERR" "nothing was changed" "and no false claim"
}

test_a_signal_during_the_last_step_with_a_backup_directory_left_does_not_say_nothing_is_left() {
    fu_dirs || return 1
    mkdir -p -- "$SANDBOX/root/var/lib/git-secret-guard/system-git/orig" || return 1
    fu_root 'gitup_tk_restore_stopped 130'
    assert_rc 130 "the signal status"
    assert_not_contains "$ERR" "nothing is left to do" "something is left"
    assert_contains "$ERR" "system-git is left" "it names the backup directory"
    assert_contains "$ERR" "rm -rf -- $SANDBOX/root/var/lib/git-secret-guard/system-git" "and the command that removes it"
}

run_file_tests
