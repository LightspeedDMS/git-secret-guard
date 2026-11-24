#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh disable=SC2016 # test code is single-quoted on purpose, a child shell expands it
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="the macOS startup file flow; the Windows PATH entry has its own adapter tests"; fi

# ^ coupled lib/platform/macpath.sh holds the block install adds to the startup file of the account's login shell, and every case where it adds nothing
MARK='# begin git-secret-guard PATH'

test_the_account_login_shell_picks_the_startup_file_and_other_answers_leave_files_alone() {
    local row shell file why f
    for row in "/bin/zsh|.zprofile|" "/opt/homebrew/bin/bash|.bash_profile|" "/usr/local/bin/fish||neither zsh nor bash" "/bin/sh||neither zsh nor bash" "||cannot be determined"; do
        IFS='|' read -r shell file why <<<"$row"
        lc_mac_begin "${shell:-/bin/zsh}" || return 1
        if [ -z "$shell" ]; then rm -f -- "$SANDBOX/dscl.shell"; fi
        set_env SHELL=/bin/fish
        gsg install
        assert_rc 0 "install with the login shell [$shell]"
        for f in .zprofile .bash_profile; do
            if [ "$f" = "$file" ]; then assert_contains "$(<"$LC_HOME/$f")" "$MARK" "[$shell] the block is in $f"; else assert_no_file "$LC_HOME/$f" "[$shell] $f is not written"; fi
        done
        if [ -z "$file" ]; then
            assert_contains "$OUT" "$why" "[$shell] says why nothing was written"
            assert_contains "$OUT" 'add this line to your shell startup file: export PATH="$HOME/.local/bin:$PATH"' "[$shell] prints the line to add"
        fi
        assert_contains "$(<"$SANDBOX/dscl.log")" ". -read /Users/$(id -un) UserShell" "[$shell] the account is asked, not the environment variable SHELL"
    done
}

test_a_startup_file_install_must_not_edit_is_left_alone_and_the_line_is_printed() {
    local name why before="" watched limit=1048576 p
    for name in symlink directory marker-without-record marker-crlf marker-trailing-space nul-byte over-the-limit; do
        lc_mac_begin || return 1
        p="$LC_HOME/.zprofile"
        watched="$p"
        case "$name" in
            symlink)
                why="is a symbolic link"
                watched="$SANDBOX/target-profile"
                printf 'export T=1\n' >"$watched" && ln -s "$watched" "$p" || return 1
                ;;
            directory)
                why="is not a regular file"
                watched=""
                mkdir -p -- "$p" || return 1
                ;;
            marker-without-record | marker-crlf | marker-trailing-space)
                why="has a PATH marker of ours that no record of ours names"
                printf 'export A=1\n%s\nexport X=1\n' "$MARK" >"$p" || return 1
                if [ "$name" = marker-crlf ]; then printf '%s\r\n%s\r\n%s\r\n' "$MARK" 'export PATH="$HOME/.local/bin:$PATH"' '# end git-secret-guard PATH' >"$p" || return 1; fi
                if [ "$name" = marker-trailing-space ]; then printf '%s \nexport A=1\n' "$MARK" >"$p" || return 1; fi
                ;;
            nul-byte)
                why="holds a NUL byte"
                printf 'a\0b\n' >"$p" || return 1
                ;;
            *)
                why="is larger than $limit bytes"
                head -c "$((limit + 1))" /dev/zero | tr '\0' a >"$p" || return 1
                ;;
        esac
        if [ -n "$watched" ]; then before="$(cksum <"$watched")" || return 1; fi
        gsg install
        assert_rc 0 "install over a startup file of the kind [$name]"
        assert_contains "$OUT" "$why" "[$name] says why"
        assert_contains "$OUT" 'add this line to your shell startup file: export PATH="$HOME/.local/bin:$PATH"' "[$name] prints the line to add"
        assert_eq "$(state_value cli_path)" "" "[$name] records nothing"
        if [ "$name" = symlink ] && [ ! -L "$p" ]; then fail "[$name] the link was replaced"; fi
        if [ "$name" = directory ] && [ ! -d "$p" ]; then fail "[$name] the directory was replaced"; fi
        if [ -n "$watched" ]; then assert_eq "$(cksum <"$watched")" "$before" "[$name] the bytes are untouched"; fi
    done
}

# ^ invariant install and uninstall in turn give the file back byte for byte, mode kept; a file install created (missing-file) is removed again
test_existing_content_stays_byte_for_byte_and_the_record_says_what_to_restore() {
    local LC_ALL=C row name content created nonl p n
    for row in "with-newline|0|0" "no-final-newline|0|1" "empty-file|0|0" "missing-file|1|0" "utf8|0|0" "crlf|0|0" "trailing-blank-lines|0|0" "user-added-the-same-line|0|0"; do
        IFS='|' read -r name created nonl <<<"$row"
        case "$name" in
            with-newline) content=$'export A=1\n' ;;
            no-final-newline) content=$'export A=1' ;;
            utf8) content=$'# caf\xc3\xa9 \xe2\x82\xac\nexport B=2\n' ;;
            crlf) content=$'export A=1\r\nexport B=2\r\n' ;;
            trailing-blank-lines) content=$'export A=1\n\n\n' ;;
            user-added-the-same-line) content='export PATH="$HOME/.local/bin:$PATH"'$'\n' ;;
            *) content="" ;;
        esac
        lc_mac_begin || return 1
        p="$LC_HOME/.zprofile"
        if [ "$created" -eq 0 ]; then printf '%s' "$content" >"$p" && chmod 600 "$p" || return 1; fi
        n="${#content}"
        gsg install
        assert_rc 0 "install over [$name]"
        assert_eq "$(state_value cli_path)" "macos-block $created $nonl $p" "[$name] the record says what to restore"
        # ^ external cmp -n 0 exits non-zero on the macOS runner; a zero-length prefix is unchanged by definition, cmp runs for n > 0 only
        if [ "$n" -gt 0 ]; then cmp -s -n "$n" -- "$p" <(printf '%s' "$content") || fail "[$name] the first $n bytes changed"; fi
        assert_contains "$(<"$p")" "$MARK" "[$name] the block is there"
        gsg uninstall
        assert_rc 0 "uninstall over [$name]"
        assert_contains "$OUT" "removed the marked PATH block from $p" "[$name] says what it removed"
        if [ "$created" -eq 1 ]; then
            assert_no_file "$p" "[$name] a file install created is removed again"
            continue
        fi
        cmp -s -- "$p" <(printf '%s' "$content") || fail "[$name] the file is not byte for byte what it was"
        assert_eq "$(stat -c %a "$p")" 600 "[$name] the mode is kept"
    done
}

run_file_tests
