# shellcheck shell=bash

# ^ invariant the scan file of the commit message; nothing else in a scan tree carries this name
GSG_MESSAGE_SCAN_NAME=COMMIT_EDITMSG
# ^ external git writes the cut line as <comment char(s)> + this text (wt-status.c cut_line) and the text is not translated; the explanation below it is
GSG_MESSAGE_SCISSORS=" ------------------------ >8 ------------------------"
GSG_MESSAGE_KILL_AFTER_SECONDS=5

# ^ why the prefix of the cut line itself, not core.commentChar; "auto" picks a character the config does not hold
# ^ invariant reads the message on stdin; writes the text after the cut and its comment lines to S1 (up to the next comment line) and S2 (after it)
# ^ invariant prints "none" (no cut line), "bad" (a third part), or the line ranges "A1 B1 A2 B2" of S1 and S2, 0 0 when a part is empty
_message_split_cut() {
    # ^ external gawk on Git for Windows reads and writes text mode and drops a carriage return unless BINMODE=3; other awks treat it as a plain variable
    LC_ALL=C awk -v BINMODE=3 -v cut="$GSG_MESSAGE_SCISSORS" -v s1="$1" -v s2="$2" '
        BEGIN { n = length(cut); state = 0; a1 = 0; b1 = 0; a2 = 0; b2 = 0; bad = 0; printf "" > s1; printf "" > s2 }
        function is_cut(l) { return length(l) > n && substr(l, length(l) - n + 1) == cut }
        state == 0 { if (is_cut($0)) { prefix = substr($0, 1, length($0) - n); state = 1 } next }
        state == 1 && index($0, prefix) == 1 { next }
        state == 1 { state = 2; a1 = NR }
        state == 2 && index($0, prefix) == 1 { state = 3; next }
        state == 2 { print > s1; b1 = NR; next }
        state == 3 && index($0, prefix) == 1 { next }
        state == 3 { state = 4; a2 = NR }
        state == 4 && index($0, prefix) == 1 { bad = 1 }
        state == 4 { print > s2; b2 = NR }
        END { if (state == 0) print "none"; else if (bad) print "bad"; else print a1, b1, a2, b2 }'
}

# ^ invariant every git call of this file runs here, under the hook's timeout like the scanner adapters (--foreground); a timeout or no timeout binary is rc 1
# ^ security MSG_ENV, when set, points git at a scratch object directory; GIT_OPTIONAL_LOCKS=0 keeps git from writing the index
_message_git() {
    if [ -z "${TIMEOUT_BIN:-}" ] || [ ! -x "$TIMEOUT_BIN" ] || [ -z "${SCAN_TIMEOUT_SECONDS:-}" ]; then return 1; fi
    "$TIMEOUT_BIN" --foreground -k "$GSG_MESSAGE_KILL_AFTER_SECONDS" "$SCAN_TIMEOUT_SECONDS" env GIT_OPTIONAL_LOCKS=0 "${MSG_ENV[@]}" git "$@"
}

# ^ invariant arg = a scratch path; sets MSG_BASES ("" = git's pick, HEAD^ for an amend, the empty tree for a root amend) and MSG_ENV
# ^ why a scratch object directory, not git hash-object -w; git diff needs the empty tree to exist and the repository is not written
# ^ invariant every base is HEAD, HEAD^ or the empty tree => hidden text is only a real diff between a commit in history and the staged tree
_message_bases() {
    local objs empty
    MSG_BASES=("")
    MSG_ENV=()
    if ! _message_git rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1; then return 0; fi
    if _message_git rev-parse -q --verify 'HEAD^^{commit}' >/dev/null 2>&1; then
        MSG_BASES+=("HEAD^")
        return 0
    fi
    objs="$(_message_git rev-parse --path-format=absolute --git-path objects 2>/dev/null)" || return 0
    if [ -z "$objs" ] || ! mkdir -p -- "$1.obj"; then return 0; fi
    MSG_ENV=(GIT_OBJECT_DIRECTORY="$1.obj" GIT_ALTERNATE_OBJECT_DIRECTORIES="$objs")
    empty="$(_message_git hash-object -w -t tree /dev/null 2>/dev/null)" && MSG_BASES+=("$empty")
}

# ^ invariant arg = the staged part file; rc 0 = it equals what git diff --cached prints against HEAD, HEAD^ or the empty tree, byte for byte
# ^ invariant a hidden removed line is in a commit of the history, a hidden added line is in the tree pre-commit scans; HEAD^ on an ordinary commit is safe too
# ^ security the work tree part of -v -v is never matched; git diff converts work tree files (filter.<x>.clean runs) and its text is in no tree
_message_matches_git() {
    local part="$1" out="$1.git" mn base
    local -a args
    # ^ external commit -v runs textconv, not an external diff (git 2.56) => --no-ext-diff --no-textconv run no repository command
    # ^ hazard a file with a textconv driver differs from the template and is scanned; at worst a removed secret in it blocks the commit
    # ^ external -v diffs the index against HEAD, against HEAD^ for --amend and against the empty tree for a root amend; -v -v forces diff.mnemonicPrefix
    _message_bases "$part"
    for mn in off on; do
        for base in "${MSG_BASES[@]}"; do
            args=(-c core.fsmonitor=false)
            # ^ why the user's own diff.mnemonicPrefix first, not forced on; commit -v honours it and commit -v -v forces it
            if [ "$mn" = on ]; then args+=(-c diff.mnemonicPrefix=true); fi
            args+=(diff --cached --no-color --no-ext-diff --no-textconv)
            if [ -n "$base" ]; then args+=("$base"); fi
            if _message_git "${args[@]}" >"$out" 2>/dev/null && cmp -s -- "$part" "$out"; then return 0; fi
        done
    done
    return 1
}

# ^ invariant args = message file (the path git passed), scan dir; leaves <scan dir>/COMMIT_EDITMSG; rc 1 = the file is unreadable or the copy failed
# ^ security text below a cut line is dropped only when it is git's own diff; matched lines become blank and line N stays line N
# ^ invariant the scratch files sit beside the scan dir (<scan dir>.cut, in the hook's work dir) and are removed with it by the hook's cleanup
message_scan_prepare() {
    local src="$1" dir="$2" dest="$2/$GSG_MESSAGE_SCAN_NAME" meta a1 b1 rest
    if [ ! -f "$src" ] || [ ! -r "$src" ]; then return 1; fi
    mkdir -p -- "$dir.cut" "$dir" || return 1
    meta="$(_message_split_cut "$dir.cut/s1" "$dir.cut/s2" <"$src")" || return 1
    cat -- "$src" >"$dest" || return 1
    read -r a1 b1 _ _ rest <<<"$meta"
    # ^ hazard a diff of git for a commit this hook cannot rebuild is no match and is scanned; at worst a removed secret blocks the commit
    if [ -n "$rest" ] || [[ ! $a1 =~ ^[0-9]+$ ]] || [ "$b1" -eq 0 ]; then return 0; fi
    if ! _message_matches_git "$dir.cut/s1"; then return 0; fi
    LC_ALL=C awk -v BINMODE=3 -v a1="$a1" -v b1="$b1" 'NR >= a1 && NR <= b1 { print ""; next } { print }' <"$src" >"$dir.cut/blanked" || return 1
    mv -f -- "$dir.cut/blanked" "$dest"
}
