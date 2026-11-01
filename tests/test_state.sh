#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck disable=SC2016
st() {
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c \
        'set -u; source "$1/lib/common.sh" && source "$1/lib/state.sh" && paths_init && shift && "$@"' _ "$GSG_PROJECT" "$@"
}

state_dir_env() {
    mkdir -p -- "$SANDBOX/st-home" || return 1
    set_env HOME="$SANDBOX/st-home" XDG_STATE_HOME="$SANDBOX/st-state" XDG_DATA_HOME="$SANDBOX/st-data"
}

show_state() { printf '[%s][%s][%s][%s][%s][%s][%s][%s][%s]' "$ST_EXISTS" "$ST_VERSION" "$ST_PREV_SET" "$ST_PREV" "$ST_TOOLS" "$ST_BACKUP" "$ST_REPLACED" "$ST_PLACED" "$ST_TIMER"; }

test_state_round_trips_verbatim_values() {
    local rep sha placed
    sha="$(printf '%064d' 7)" || return 1
    rep="gitleaks.gsg-replaced-20261031T101500Z:$sha"
    placed="gitleaks:$sha trufflehog:$sha"
    state_dir_env || return 1
    st eval "$(declare -f show_state); state_write 0.1.0 yes '~/.config/git/hooks \$x \"q\" = tail' 'trufflehog gitleaks' '/a b/backup.tar.gz' '$rep' '$placed' yes && state_read && show_state"
    assert_rc 0 "write then read"
    # shellcheck disable=SC2016
    assert_eq "$OUT" "[1][0.1.0][yes][~/.config/git/hooks \$x \"q\" = tail][trufflehog gitleaks][/a b/backup.tar.gz][$rep][$placed][yes]" "values come back exactly, including = and quotes"
    assert_eq "$(stat -c %a "$SANDBOX/st-state/git-secret-guard")" 700 "dir mode"
    assert_eq "$(stat -c %a "$SANDBOX/st-state/git-secret-guard/state")" 600 "file mode"
    st eval "$(declare -f show_state); rm -f \"\$GSG_STATE_FILE\"; state_read && show_state"
    assert_eq "$OUT" '[0][][no][][][][][][no]' "an absent file means not installed, with empty values and no timer"
}

test_state_read_accepts_a_legacy_five_key_file_with_nothing_replaced() {
    state_dir_env || return 1
    mkdir -p -- "$SANDBOX/st-state/git-secret-guard" || return 1
    printf 'version=0.1.0\nprevious_hooks_path_set=no\nprevious_hooks_path=\ntools_installed_by_us=gitleaks\nbackup_path=\n' \
        >"$SANDBOX/st-state/git-secret-guard/state" || return 1
    st eval "$(declare -f show_state); state_read && show_state"
    assert_rc 0 "a state written before tools_replaced and tools_placed existed"
    assert_eq "$OUT" '[1][0.1.0][no][][gitleaks][][][][no]' "reads with nothing replaced, nothing placed and no timer"
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
EOF
    local i
    : >"$f"
    for ((i = 0; i < 101; i++)); do printf 'version=1\n' >>"$f"; done
    st state_read
    assert_rc 1 "101 lines"
    assert_contains "$ERR" "too long to be ours" "says why"
}

test_state_write_refuses_a_newline_and_paths_init_refuses_relative_dirs() {
    state_dir_env || return 1
    st state_write 0.1.0 yes $'a\nb' '' '' '' '' no
    assert_rc 1 "a newline in a value"
    assert_contains "$ERR" "contains a newline" "says why"
    assert_no_file "$SANDBOX/st-state/git-secret-guard/state" "and writes nothing"
    set_env HOME=relative
    st true
    assert_rc 1 "relative HOME"
    assert_contains "$ERR" "HOME must be an absolute path" "says why"
}

run_file_tests
