#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

# shellcheck disable=SC2016
st() {
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c \
        'set -u; source "$1/lib/core/common.sh" && source "$1/lib/core/state.sh" && paths_init && shift && "$@"' _ "$GSG_PROJECT" "$@"
}

state_dir_env() {
    rm -rf -- "$SANDBOX/st-state" && mkdir -p -- "$SANDBOX/st-home" || return 1
    set_env HOME="$SANDBOX/st-home" XDG_STATE_HOME="$SANDBOX/st-state" XDG_DATA_HOME="$SANDBOX/st-data"
}

show_state() { printf '[%s][%s][%s][%s][%s][%s][%s][%s][%s][%s][%s]' "$ST_EXISTS" "$ST_VERSION" "$ST_PREV_SET" "$ST_PREV" "$ST_TOOLS" "$ST_BACKUP" "$ST_REPLACED" "$ST_PLACED" "$ST_TIMER" "$ST_AUTO_UPDATE" "$ST_SOURCE_CHECKOUT"; }

test_state_round_trips_verbatim_values() {
    local rep sha placed
    sha="$(printf '%064d' 7)" || return 1
    rep="betterleaks.gsg-replaced-20261031T101500Z:$sha"
    placed="betterleaks:$sha trufflehog:$sha"
    state_dir_env || return 1
    st eval "$(declare -f show_state); state_write 0.1.0 yes '~/.config/git/hooks \$x \"q\" = tail' 'trufflehog betterleaks' '/a b/backup.tar.gz' '$rep' '$placed' yes yes '/a b/check=out' && state_read && show_state"
    assert_rc 0 "write then read"
    # shellcheck disable=SC2016
    assert_eq "$OUT" "[1][0.1.0][yes][~/.config/git/hooks \$x \"q\" = tail][trufflehog betterleaks][/a b/backup.tar.gz][$rep][$placed][yes][yes][/a b/check=out]" "values come back exactly, including = and quotes"
    assert_eq "$(stat -c %a "$SANDBOX/st-state/git-secret-guard")" 700 "dir mode"
    assert_eq "$(stat -c %a "$SANDBOX/st-state/git-secret-guard/state")" 600 "file mode"
    st eval "$(declare -f show_state); rm -f \"\$GSG_STATE_FILE\"; state_read && show_state"
    assert_eq "$OUT" '[0][][no][][][][][][no][no][]' "an absent file means not installed, with empty values, no timer and no auto-update"
    st eval "$(declare -f show_state); state_write 0.1.0 no '' '' '' '' '' no no '' && state_read && show_state"
    assert_rc 0 "ten-argument write then read"
    assert_eq "$OUT" '[1][0.1.0][no][][][][][][no][no][]' "auto_update=no and an empty source_checkout round trip"
    assert_contains "$(<"$SANDBOX/st-state/git-secret-guard/state")" $'timer_installed=no\nauto_update=no\nsource_checkout=' "both keys are written, after timer_installed"
}

test_paths_init_names_the_update_record_and_lock() {
    state_dir_env || return 1
    # shellcheck disable=SC2016
    st eval 'printf "[%s][%s]" "$GSG_UPDATE_RECORD" "$GSG_UPDATE_LOCK"'
    assert_rc 0 "paths_init"
    assert_eq "$OUT" "[$SANDBOX/st-state/git-secret-guard/update][$SANDBOX/st-state/git-secret-guard/update.lock]" "the update record and its lock live in the state dir"
}

test_state_read_accepts_a_legacy_five_key_file_with_nothing_replaced() {
    state_dir_env || return 1
    mkdir -p -- "$SANDBOX/st-state/git-secret-guard" || return 1
    printf 'version=0.1.0\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=betterleaks\nbackup_path=\n' \
        >"$SANDBOX/st-state/git-secret-guard/state" || return 1
    st eval "$(declare -f show_state); state_read && show_state"
    assert_rc 0 "a state written before tools_replaced and tools_placed existed"
    assert_eq "$OUT" '[1][0.1.0][no][][betterleaks][][][][no][no][]' "reads with nothing replaced, nothing placed, no timer, no auto-update and no checkout"
}

test_state_read_refuses_files_that_are_not_ours() {
    state_dir_env || return 1
    mkdir -p -- "$SANDBOX/st-state/git-secret-guard" || return 1
    local f="$SANDBOX/st-state/git-secret-guard/state" body
    while IFS='|' read -r body; do
        printf '%b' "$body" >"$f" || return 1
        st state_read
        assert_rc 1 "[$body]"
        assert_contains "$ERR" "git-secret-guard: the state file" "[$body] is refused with a message"
    done <<'EOF'
version=1\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=\n
version=1\nprevious_hooks_path_set=maybe\nprevious_hooks_path=\ntools_installed_by_us=\nbackup_path=\n
version=1\nversion=2\nprevious_hooks_path=\ntools_installed_by_us=\nbackup_path=\n
version=1\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=\nbackup_path=\nextra=1\n
version=1\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=\nnot a key value line\n
version=1\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=\ntools_replaced=\n
version=1\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=\nbackup_path=\ntools_replaced=\ntools_replaced=\n
version=1\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=\nbackup_path=\ntimer_installed=maybe\n
version=1\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=\nbackup_path=\ntimer_installed=yes\ntimer_installed=yes\n
version=1\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=\nbackup_path=\nauto_update=maybe\n
version=1\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=\nbackup_path=\nauto_update=\n
version=1\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=\nbackup_path=\nauto_update=yes\nauto_update=yes\n
version=1\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=\nbackup_path=\nsource_checkout=relative/checkout\n
version=1\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=\nbackup_path=\nsource_checkout=/a\nsource_checkout=/a\n
EOF
    local i
    : >"$f"
    for ((i = 0; i < 101; i++)); do printf 'version=1\n' >>"$f"; done
    st state_read
    assert_rc 1 "101 lines"
    assert_contains "$ERR" "too long to be ours" "says why"
}

# ^ why a cap per line, not only per file; the tools_* values go through here-strings, and Git for Windows bash hangs at 64 KiB + 1 to 128 bytes
test_state_read_refuses_a_line_longer_than_8192_characters() {
    local f="$SANDBOX/st-state/git-secret-guard/state" head words
    state_dir_env || return 1
    mkdir -p -- "${f%/*}" || return 1
    head='version=1\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=\nbackup_path=\n'
    printf -v words '%8179s' ''
    printf '%btools_placed=%s\n' "$head" "${words// /w}" >"$f" || return 1
    st state_read
    assert_rc 0 "a line of exactly 8192 characters loads"
    printf '%btools_placed=%s\n' "$head" "${words// /w}w" >"$f" || return 1
    st state_read
    assert_rc 1 "8193 characters"
    assert_contains "$ERR" "has a line longer than 8192 characters to be ours" "says why"
}

test_state_write_refuses_a_newline_and_paths_init_refuses_relative_dirs() {
    state_dir_env || return 1
    st state_write 0.1.0 yes $'a\nb' '' '' '' '' no no ''
    assert_rc 1 "a newline in a value"
    assert_contains "$ERR" "contains a newline" "says why"
    assert_no_file "$SANDBOX/st-state/git-secret-guard/state" "and writes nothing"
    st state_write 0.1.0 yes '' '' '' '' '' no yes $'/a\n/b'
    assert_rc 1 "a newline in source_checkout"
    assert_contains "$ERR" "contains a newline" "says why"
    st state_write 0.1.0 yes '' '' '' '' '' no
    assert_rc 1 "a caller that does not pass auto_update and source_checkout"
    assert_contains "$ERR" "state_write needs 10 values, got 8" "says why"
    assert_no_file "$SANDBOX/st-state/git-secret-guard/state" "and writes nothing either"
    set_env HOME=relative
    st true
    assert_rc 1 "relative HOME"
    assert_contains "$ERR" "HOME must be an absolute path" "says why"
}

run_file_tests
