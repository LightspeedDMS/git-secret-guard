# shellcheck shell=bash
# ^ invariant these helpers drive the commit-msg scan by hand on a message file, as git does, and read what both scanners were handed

CALLS="" MARKER=""
begin() {
    new_repo "$1" || return 1
    CALLS="$SANDBOX/calls-$1"
    MARKER="$(new_marker)"
    enable_message_hook
    set_env STUB_LOG="$CALLS" STUB_MARKER="$MARKER"
}

# ^ invariant runs the hook by hand on a message file, as git does for commit-msg (path as the one argument), and records what both scanners saw
run_message_hook() {
    set_env STUB_RECORD="$SANDBOX/record-$1"
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$SHARE/hooks/secret-scan" "$2"
}

# ^ invariant builds a message file as commit -v writes it with comment char ; (subject, comments, cut block, the text from stdin last)
verbose_message() {
    local sc=' ------------------------ >8 ------------------------'
    {
        printf 'subject\n\n; Please enter the commit message.\n;\n; On branch main\n'
        printf ';%s\n; Do not modify or remove the line above.\n; Everything below it will be ignored.\n;\n; Changes to be committed:\n' "$sc"
        cat
    } >"$1"
}

# ^ invariant a repository with the removed line "gone MARKER" staged; the diff of git holds the marker in a removed line
verbose_repo() {
    printf 'keep\ngone %s\n' "$MARKER" >src.txt && gitx add src.txt && gitx commit -q --no-verify -m base || return 1
    printf 'keep\nnew line\n' >src.txt && gitx add src.txt
}
