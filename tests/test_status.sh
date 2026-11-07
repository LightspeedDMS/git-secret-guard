#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

fresh_install() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install"
}

lc_which() {
    # shellcheck disable=SC2016
    env -i HOME="$SANDBOX/home" PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" bash -c 'type -P "$1"' _ "$1" </dev/null
}

test_status_reports_not_installed_with_exit_1() {
    lc_begin || return 1
    gsg status
    assert_rc 1 "status before install"
    assert_contains "$OUT" "not installed" "says so"
    assert_no_file "$LC_STATE" "and creates nothing"
    assert_no_file "$LC_DATA" "not even the share dir"
}

test_status_shows_the_installation() {
    fresh_install
    gsg status
    assert_rc 0 "status after install"
    assert_contains "$OUT" "installed version: $(<"$GSG_PROJECT/VERSION")" "version"
    assert_contains "$OUT" "hook command: $LC_DATA/hooks/secret-scan" "hook command path"
    assert_contains "$OUT" "global config: matches" "config matches"
    assert_contains "$OUT" "previous core.hooksPath: unset" "recorded hooksPath"
    assert_contains "$OUT" "tools installed by us: trufflehog betterleaks" "which tools install downloaded"
    assert_contains "$OUT" "trufflehog: $LC_BIN/trufflehog$LC_EXE 3.99.2 (pinned 3.99.2) ok" "trufflehog path and version"
    assert_contains "$OUT" "betterleaks: $LC_BIN/betterleaks$LC_EXE 1.9.0 (pinned 1.9.0) ok" "betterleaks path and version"
    assert_contains "$OUT" "jq: $(lc_expected_jq)" "jq path"
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then assert_contains "$OUT" "taskkill: " "process tool"; else assert_contains "$OUT" "setsid: $(lc_which setsid)" "setsid path"; fi
    assert_contains "$OUT" "timeout: $(lc_which timeout)" "timeout path"
    assert_eq "$ERR" "git-secret-guard: note: GIT_CONFIG_GLOBAL is set; the global git config used is $SANDBOX/gitconfig" "stderr is only the one-line note"
}

test_status_shows_the_recorded_hooks_path_and_backup() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$LC_HOME/.config/git/hooks" && printf 'x\n' >"$LC_HOME/.config/git/hooks/pre-commit" || return 1
    # shellcheck disable=SC2088
    git_literal_config --global core.hooksPath '~/.config/git/hooks' || return 1
    gsg install --replace-hooks-path
    assert_rc 0 "takeover"
    gsg status
    assert_rc 0 "status"
    assert_contains "$OUT" "previous core.hooksPath: ~/.config/git/hooks" "verbatim, not expanded"
    assert_contains "$OUT" "hooks backup: $(state_value backup_path)" "backup location"
}

test_status_flags_every_kind_of_drift_and_exits_1() {
    fresh_install
    git_literal_config --global --replace-all hook.git-secret-guard.command /elsewhere/secret-scan || return 1
    gsg status
    assert_rc 1 "a changed command"
    assert_contains "$OUT" "global config: MISMATCH" "flagged"
    assert_contains "$OUT" "command=[/elsewhere/secret-scan]" "shows what is configured"
    assert_contains "$OUT" "want [$LC_DATA/hooks/secret-scan]" "and what is expected"

    fresh_install
    gitx config --global --add hook.git-secret-guard.event commit-msg || return 1
    gsg status
    assert_rc 1 "a second event"
    assert_contains "$OUT" "global config: MISMATCH" "flagged"

    fresh_install
    rm -f -- "$LC_DATA/hooks/secret-scan" || return 1
    gsg status
    assert_rc 1 "a missing hook script"
    assert_contains "$OUT" "hook command: $LC_DATA/hooks/secret-scan (MISSING or not executable)" "flagged"

    fresh_install
    printf '#!/bin/sh\necho "trufflehog 3.0.0"\n' >"$LC_BIN/trufflehog$LC_EXE" || return 1
    gsg status
    assert_rc 1 "a tool at another version"
    assert_contains "$OUT" "trufflehog: $LC_BIN/trufflehog$LC_EXE 3.0.0 (pinned 3.99.2) MISMATCH" "flagged with both versions"
    assert_contains "$OUT" "betterleaks: $LC_BIN/betterleaks$LC_EXE 1.9.0 (pinned 1.9.0) ok" "the other tool is still ok"

    fresh_install
    rm -f -- "$LC_BIN/betterleaks$LC_EXE" || return 1
    gsg status
    assert_rc 1 "a missing tool"
    assert_contains "$OUT" "betterleaks: $LC_BIN/betterleaks$LC_EXE (MISSING or not executable)" "flagged"

    fresh_install
    rm -f -- "$LC_DATA/settings" || return 1
    gsg status
    assert_rc 1 "missing settings"
    assert_contains "$OUT" "settings: $LC_DATA/settings (MISSING or unreadable)" "flagged"
}

test_status_lists_the_originals_install_moved_aside() {
    fresh_install
    gsg status
    assert_contains "$OUT" "originals moved aside: none" "a clean install moved nothing"
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$LC_BIN" && printf '#!/bin/sh\necho "betterleaks version 8.18.4"\n' >"$LC_BIN/betterleaks$LC_EXE" && chmod 755 "$LC_BIN/betterleaks$LC_EXE" || return 1
    gsg install
    assert_rc 0 "install over the user's betterleaks"
    gsg status
    assert_rc 0 "status"
    assert_contains "$OUT" "originals moved aside: betterleaks.gsg-replaced-" "the aside file is named"
}

test_status_judges_versions_exactly_like_install_does() {
    fresh_install
    printf '#!/bin/sh\necho "betterleaks version 1.9.0-rc1"\n' >"$LC_BIN/betterleaks$LC_EXE" || return 1
    printf '#!/bin/sh\necho "trufflehog 3.99.2.1"\n' >"$LC_BIN/trufflehog$LC_EXE" || return 1
    gsg status
    assert_rc 1 "a pre-release and a four-part version are not the pin"
    assert_contains "$OUT" "betterleaks: $LC_BIN/betterleaks$LC_EXE 1.9.0-rc1 (pinned 1.9.0) MISMATCH" "betterleaks 1.9.0-rc1"
    assert_contains "$OUT" "trufflehog: $LC_BIN/trufflehog$LC_EXE 3.99.2.1 (pinned 3.99.2) MISMATCH" "trufflehog 3.99.2.1"
    printf '#!/bin/sh\necho "betterleaks version v1.9.0"\n' >"$LC_BIN/betterleaks$LC_EXE" || return 1
    printf '#!/bin/sh\necho "trufflehog 3.99.2"\n' >"$LC_BIN/trufflehog$LC_EXE" || return 1
    gsg status
    assert_rc 0 "install's own accepted spellings (v-prefix) are ok"
    assert_contains "$OUT" "(pinned 1.9.0) ok" "ok"
}

test_status_flags_an_unusable_timeout_in_the_settings() {
    fresh_install
    sed -i 's#^TIMEOUT_BIN=.*#TIMEOUT_BIN=/nonexistent/timeout#' "$LC_DATA/settings" || return 1
    gsg status
    assert_rc 1 "a timeout that cannot run"
    assert_contains "$OUT" "timeout: /nonexistent/timeout (MISSING or not executable)" "flagged"
}

# ^ coupled lc_begin puts $SANDBOX/pathbin first on the CLI PATH => a git written there is the one status measures
# ^ invariant st_git_stub [VERSION [WORD [MESSAGE [stall]]]] answers --version with VERSION (default the real answer)
# ^ invariant a call with the argument WORD prints MESSAGE and exits 3, or sleeps after touching git.stalled; every other call runs the real git
st_git_stub() {
    local ver="${1:-}" word="${2:-}" msg="${3:-}" stall="${4:-}"
    rm -f -- "$SANDBOX/git.version" "$SANDBOX/git.fail.word" "$SANDBOX/git.fail.msg" "$SANDBOX/git.stall" "$SANDBOX/git.stalled"
    if [ -n "$ver" ]; then printf '%s\n' "$ver" >"$SANDBOX/git.version" || return 1; fi
    if [ -n "$word" ]; then printf '%s' "$word" >"$SANDBOX/git.fail.word" && printf '%s\n' "$msg" >"$SANDBOX/git.fail.msg" || return 1; fi
    if [ -n "$stall" ]; then : >"$SANDBOX/git.stall" || return 1; fi
    cat >"$SANDBOX/pathbin/git" <<'EOF' || return 1
#!/bin/sh
d="${0%/*}/.."
if [ "$1" = --version ] && [ -f "$d/git.version" ]; then cat "$d/git.version"; exit 0; fi
if [ -f "$d/git.fail.word" ]; then
    w="$(cat "$d/git.fail.word")"
    for a in "$@"; do
        if [ "$a" = "$w" ]; then
            if [ -f "$d/git.stall" ]; then : >"$d/git.stalled"; exec sleep 30; fi
            cat "$d/git.fail.msg" >&2
            exit 3
        fi
    done
fi
exec "$(cat "$d/real-git")" "$@"
EOF
    chmod 755 "$SANDBOX/pathbin/git"
}

st_git_version_on_path() {
    local g
    g="$(lc_which git)" || return 1
    "$g" --version | sed -E 's/^git version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/'
}

test_status_names_the_git_in_use_and_its_version() {
    fresh_install
    gsg status
    assert_rc 0 "a git that can run config hooks"
    assert_contains "$OUT" "git: $(lc_which git) $(st_git_version_on_path) ok" "path and version on every run"
}

test_status_exits_1_and_says_commits_are_not_scanned_when_the_git_in_use_is_too_old() {
    fresh_install
    st_git_stub "git version 2.52.0" || return 1
    gsg status
    assert_rc 1 "git 2.52.0 ignores config hooks"
    assert_contains "$OUT" "git: $SANDBOX/pathbin/git 2.52.0 MISMATCH" "names the git and its version"
    assert_contains "$OUT" "commits made with it are not scanned" "says what it means"
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then
        assert_contains "$OUT" "update Git for Windows" "and what to do on Windows"
    else
        assert_contains "$OUT" "docs/platforms.md" "and where the way out is described"
    fi
    assert_contains "$OUT" "hook command: $LC_DATA/hooks/secret-scan" "the other lines are still printed"
    assert_contains "$OUT" "global config: matches" "the config itself is fine"
}

test_status_skips_the_hook_listing_when_the_git_is_too_old_or_unreadable() {
    fresh_install
    st_git_stub "git version 2.20.1" hook "git: 'hook' is not a git command" || return 1
    gsg status
    assert_rc 1 "an old git"
    assert_contains "$OUT" "git: $SANDBOX/pathbin/git 2.20.1 MISMATCH" "one clear line"
    assert_not_contains "$OUT" "hook list" "no second line from a command the old git lacks"
    assert_not_contains "$OUT" "hook enabled" "and no third"
    st_git_stub "none of your business" hook "git: 'hook' is not a git command" || return 1
    gsg status
    assert_rc 1 "an unreadable version"
    assert_not_contains "$OUT" "hook list" "the listing is skipped as well"
}

test_status_exits_1_when_the_version_of_the_git_in_use_cannot_be_read() {
    fresh_install
    st_git_stub "none of your business" || return 1
    gsg status
    assert_rc 1 "an unreadable version is a problem"
    assert_contains "$OUT" "git: $SANDBOX/pathbin/git MISMATCH (cannot read its version" "says so"
    assert_contains "$OUT" "not scanned" "and what it may mean"
}

test_status_ignores_a_second_old_git_that_is_not_first_on_path() {
    fresh_install
    mkdir -p -- "$SANDBOX/oldgit" || return 1
    printf '#!/bin/sh\necho "git version 2.52.0"\n' >"$SANDBOX/oldgit/git" && chmod 755 "$SANDBOX/oldgit/git" || return 1
    set_env PATH="$SANDBOX/pathbin:$TEST_BASE_PATH:$SANDBOX/oldgit"
    gsg status
    assert_rc 0 "an old git behind the good one does not matter"
    assert_contains "$OUT" "git: $(lc_which git) $(st_git_version_on_path) ok" "the first git is the one reported"
    assert_not_contains "$OUT" "2.52.0" "the second one is not mentioned"
}

test_status_exits_1_with_a_message_when_there_is_no_git_on_path() {
    fresh_install
    lc_path_without git || return 1
    gsg status
    assert_rc 1 "no git at all"
    assert_contains "$ERR" "git is not on PATH" "says why"
}

test_status_exits_1_when_jq_or_the_process_tool_cannot_run() {
    local key=SETSID_BIN name=setsid
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then key=TASKKILL_BIN name=taskkill; fi
    fresh_install
    sed -i 's#^JQ_BIN=.*#JQ_BIN=/nonexistent/jq#' "$LC_DATA/settings" || return 1
    gsg status
    assert_rc 1 "a jq that cannot run blocks every commit"
    assert_contains "$OUT" "jq: /nonexistent/jq (MISSING or not executable)" "flagged"

    fresh_install
    sed -i "s#^$key=.*#$key=/nonexistent/$name#" "$LC_DATA/settings" || return 1
    gsg status
    assert_rc 1 "a process tool that cannot run blocks every commit"
    assert_contains "$OUT" "$name: /nonexistent/$name (MISSING or not executable)" "flagged"
}

# ^ invariant gitconfig.installed = the global config right after install; a case appends one raw [hook SECTION] block => repeated and value-less keys work
st_hook_case() {
    local section="$1" want="$2" line
    shift 2
    cp -- "$SANDBOX/gitconfig.installed" "$SANDBOX/gitconfig" || return 1
    { printf '[hook "%s"]\n' "$section"; for line in "$@"; do printf '\t%s\n' "$line"; done; } >>"$SANDBOX/gitconfig" || return 1
    gsg status
    assert_rc "$want" "hook.$section.enabled [$*]"
}

st_install_for_hook_cases() {
    fresh_install
    cp -- "$SANDBOX/gitconfig" "$SANDBOX/gitconfig.installed"
}

st_tmp_listing() { ls -A -- "$SANDBOX/tmp"; }

test_status_exits_1_for_every_enabled_value_git_reads_as_off() {
    local section v
    st_install_for_hook_cases || return 1
    for section in git-secret-guard pre-commit; do
        for v in false no off 0 00 0k 0x0 -0 '' '""'; do
            st_hook_case "$section" 1 "enabled = $v"
            assert_contains "$OUT" "hook enabled: MISMATCH (git hook list pre-commit shows git-secret-guard as" "reported by what git says [$v]"
            assert_contains "$OUT" "hook.$section.enabled" "names the key [$v]"
            assert_contains "$OUT" "commits are not scanned" "says what it means [$v]"
        done
        st_hook_case "$section" 1 "enabled = false" "enabled = garbage"
        assert_contains "$OUT" "hook.$section.enabled" "an unreadable value after false does not switch it back on"
    done
}

test_status_stays_quiet_for_every_enabled_value_git_reads_as_on() {
    local section v
    st_install_for_hook_cases || return 1
    for section in git-secret-guard pre-commit; do
        for v in true yes on 1 garbage; do
            st_hook_case "$section" 0 "enabled = $v"
            assert_not_contains "$OUT" "hook enabled" "no false alarm [$v]"
            assert_not_contains "$OUT" "hook list" "no false alarm [$v]"
        done
        st_hook_case "$section" 0 "enabled = false" "enabled = true"
    done
}

test_status_says_why_a_value_less_enabled_key_blocks_every_commit() {
    local section
    st_install_for_hook_cases || return 1
    for section in git-secret-guard pre-commit; do
        st_hook_case "$section" 1 "enabled"
        assert_contains "$OUT" "hook list: MISMATCH (git init failed with exit" "git cannot even start the check"
        assert_contains "$OUT" "hook.$section.enabled" "git's own message names the key"
    done
}

test_status_names_the_key_and_prints_no_configured_command_value() {
    local line section
    st_install_for_hook_cases || return 1
    for section in git-secret-guard pre-commit; do
        st_hook_case "$section" 1 "enabled = false"
        line="$(printf '%s\n' "$OUT" | grep '^hook enabled: ')"
        assert_contains "$line" "hook.$section.enabled" "the key [$section]"
        assert_not_contains "$line" "$LC_DATA" "not the hook command that is configured [$section]"
    done
}

test_status_exits_1_when_the_hook_is_missing_from_the_listing() {
    fresh_install
    gitx config --global --unset hook.git-secret-guard.event || return 1
    gsg status
    assert_rc 1 "no event reaches the hook"
    assert_contains "$OUT" "hook list: MISMATCH (git-secret-guard is not in git hook list pre-commit" "says which"

    fresh_install
    gitx config --global --unset hook.git-secret-guard.command || return 1
    gsg status
    assert_rc 1 "an event without its command"
    assert_contains "$OUT" "hook list: MISMATCH (git init failed with exit 128" "git itself refuses the half-configured hook"
    assert_contains "$OUT" "'hook.git-secret-guard.command' must be configured" "and its words name the key"
}

# ^ external native git reads GIT_CONFIG_SYSTEM and GIT_DIR itself; on Windows they must be C:/ paths
st_native_sandbox() { if [ "$TEST_IS_WINDOWS" -eq 1 ]; then printf '%s' "$TEST_SANDBOX_MIXED"; else printf '%s' "$SANDBOX"; fi; }

test_status_reads_a_disable_in_the_system_config() {
    local section sys
    st_install_for_hook_cases || return 1
    sys="$(st_native_sandbox)/sysconfig"
    set_env GIT_CONFIG_NOSYSTEM=0 "GIT_CONFIG_SYSTEM=$sys"
    for section in git-secret-guard pre-commit; do
        printf '[hook "%s"]\n\tenabled = false\n' "$section" >"$SANDBOX/sysconfig" || return 1
        gsg status
        assert_rc 1 "a system-wide disable of hook.$section.enabled"
        assert_contains "$OUT" "hook.$section.enabled" "names the key"
    done
    printf '[hook "git-secret-guard"]\n\tenabled = false\n' >"$SANDBOX/sysconfig" || return 1
    printf '[hook "git-secret-guard"]\n\tenabled = garbage\n' >>"$SANDBOX/gitconfig" || return 1
    gsg status
    assert_rc 1 "system false stays off under a global value git cannot read"
    : >"$SANDBOX/sysconfig"
    cp -- "$SANDBOX/gitconfig.installed" "$SANDBOX/gitconfig" || return 1
    gsg status
    assert_rc 0 "an empty system config changes nothing"
}

test_status_sees_a_disable_given_through_the_environment() {
    fresh_install
    set_env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=hook.git-secret-guard.enabled GIT_CONFIG_VALUE_0=false
    gsg status
    assert_rc 1 "a command-scope disable"
    assert_contains "$OUT" "hook.git-secret-guard.enabled" "names the key"

    fresh_install
    set_env "GIT_CONFIG_PARAMETERS='hook.pre-commit.enabled'='false'"
    gsg status
    assert_rc 1 "a disable passed down by git -c"
    assert_contains "$OUT" "hook.pre-commit.enabled" "names the key"
}

test_status_ignores_the_repository_a_caller_points_git_at() {
    local repo
    fresh_install
    repo="$(st_native_sandbox)/localrepo"
    gitx init -q --bare "$repo" || return 1
    printf '[hook "git-secret-guard"]\n\tenabled = true\n' >>"$SANDBOX/localrepo/config" || return 1
    gitx config --global hook.git-secret-guard.enabled false || return 1
    set_env "GIT_DIR=$repo" "GIT_COMMON_DIR=$repo"
    gsg status
    assert_rc 1 "status run from a hook still sees the global disable"
    assert_contains "$OUT" "hook.git-secret-guard.enabled" "names the key"
}

test_status_reports_each_failing_git_step_and_prints_no_control_character() {
    local word esc=$'\033'
    fresh_install
    for word in rev-parse init hook; do
        st_git_stub "" "$word" "${esc}[31mboom ${esc}[0m" || return 1
        gsg status
        assert_rc 1 "git $word fails"
        assert_contains "$OUT" "hook list: MISMATCH (git " "a line says which step [$word]"
        assert_contains "$OUT" "failed with exit 3" "and the exit status [$word]"
        assert_not_contains "$OUT" "$esc" "no escape sequence reaches the terminal [$word]"
        assert_eq "$(st_tmp_listing)" "" "no temp directory left behind [$word]"
    done
}

test_status_exits_1_when_only_its_own_mktemp_fails() {
    local real
    fresh_install
    real="$(lc_which mktemp)" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = -d ]; then echo "mktemp: injected failure" >&2; exit 1; fi\nexec "%s" "$@"\n' "$real" >"$SANDBOX/pathbin/mktemp" || return 1
    chmod 755 "$SANDBOX/pathbin/mktemp" || return 1
    gsg status
    assert_rc 1 "no place for the throwaway repository"
    assert_contains "$OUT" "hook list: MISMATCH (cannot create a temp directory" "says so"
    assert_contains "$OUT" "core.hooksPath (effective)" "the rest of status still ran, so the exit comes from this check alone"
}

test_status_leaves_no_temp_directory_after_a_normal_run() {
    fresh_install
    gsg status
    assert_rc 0 "a healthy install"
    assert_eq "$(st_tmp_listing)" "" "the throwaway repository is gone"
}

# ^ security only the group this function started is signalled; setsid makes the sh its own group leader and kill -SIG -- -PID stays inside it
# ^ invariant st_signal_status SIGNAL stalls git hook list, signals the group, waits; sets ST_RC = the exit status of status and OUT = its output
st_signal_status() {
    local sig="$1" pid n
    rm -f -- "$SANDBOX/int.rc" "$SANDBOX/int.pid"
    st_git_stub "" hook "" stall || return 1
    # shellcheck disable=SC2016
    (setsid sh -c 'echo $$ >"$1"; shift; exec "$@"' sh "$SANDBOX/int.pid" env --default-signal=INT env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" status >"$SANDBOX/int.out" 2>&1 </dev/null
        echo $? >"$SANDBOX/int.rc") &
    for ((n = 0; n < 100; n++)); do
        if [ -e "$SANDBOX/git.stalled" ]; then break; fi
        sleep 0.1
    done
    pid="$(<"$SANDBOX/int.pid")"
    if [ ! -e "$SANDBOX/git.stalled" ]; then
        kill -KILL -- "-$pid" 2>/dev/null
        fail "status never reached the hook listing"
        return 1
    fi
    [ -n "$(st_tmp_listing)" ] || fail "the throwaway repository should exist while git is busy"
    kill "-$sig" -- "-$pid" 2>/dev/null
    for ((n = 0; n < 100; n++)); do
        if [ -e "$SANDBOX/int.rc" ]; then break; fi
        sleep 0.1
    done
    if [ ! -e "$SANDBOX/int.rc" ]; then
        kill -KILL -- "-$pid" 2>/dev/null
        fail "status did not end after SIG$sig"
        return 1
    fi
    ST_RC="$(<"$SANDBOX/int.rc")"
    OUT="$(<"$SANDBOX/int.out")"
    for ((n = 0; n < 100; n++)); do
        if [ -z "$(st_tmp_listing)" ]; then break; fi
        sleep 0.1
    done
}

test_an_interrupted_status_leaves_no_temp_directory() {
    fresh_install
    st_signal_status TERM || return 1
    assert_eq "$ST_RC" 143 "killed by SIGTERM"
    assert_eq "$(st_tmp_listing)" "" "SIGTERM removed the throwaway repository"
}

test_an_interrupt_during_the_hook_check_stops_status_with_130() {
    fresh_install
    st_signal_status INT || return 1
    assert_eq "$ST_RC" 130 "Ctrl-C ends status"
    assert_not_contains "$OUT" "previous core.hooksPath" "none of the later lines is printed"
    assert_not_contains "$OUT" "originals moved aside" "status does not carry on"
    assert_eq "$(st_tmp_listing)" "" "SIGINT removed the throwaway repository"
}

test_status_accepts_a_git_found_through_a_relative_path_entry() {
    local here="$PWD"
    fresh_install
    mkdir -p -- "$SANDBOX/rb" || return 1
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$(<"$SANDBOX/real-git")" >"$SANDBOX/rb/git" || return 1
    chmod 755 "$SANDBOX/rb/git" || return 1
    set_env "PATH=rb:$SANDBOX/pathbin:$TEST_BASE_PATH"
    cd -- "$SANDBOX" || return 1
    gsg status
    cd -- "$here" || return 1
    assert_rc 0 "a healthy install with git found as rb/git"
    assert_contains "$OUT" "git: rb/git " "the relative path is what status reports"
    assert_not_contains "$OUT" "hook list" "and the throwaway repository check uses it from any directory"
}

# ^ external status reads a relative GIT_CONFIG_GLOBAL from its own directory, git in a repository from the repo top => only an absolute value is reliable
test_status_reads_a_relative_global_config_from_the_directory_it_runs_in() {
    local here="$PWD"
    st_install_for_hook_cases || return 1
    set_env GIT_CONFIG_GLOBAL=gitconfig
    cd -- "$SANDBOX" || return 1
    gsg status
    assert_rc 0 "a healthy install with a relative GIT_CONFIG_GLOBAL"
    assert_not_contains "$OUT" "hook list" "no false alarm"
    printf '[hook "git-secret-guard"]\n\tenabled = false\n' >>"$SANDBOX/gitconfig" || return 1
    gsg status
    cd -- "$here" || return 1
    assert_rc 1 "a disable in that file is still seen"
    assert_contains "$OUT" "hook.git-secret-guard.enabled" "names the key"
}

test_status_ignores_defaults_that_only_break_a_new_repository() {
    local v
    fresh_install
    for v in GIT_DEFAULT_HASH GIT_DEFAULT_REF_FORMAT; do
        EXTRA_ENV=("$v=bad")
        gsg status
        assert_rc 0 "$v=bad does not stop a commit in an existing repository"
        assert_not_contains "$OUT" "hook list" "no false alarm [$v]"
    done
}

test_status_ignores_a_template_config_that_only_a_new_repository_would_copy() {
    local section tmpl
    for section in git-secret-guard pre-commit; do
        fresh_install
        mkdir -p -- "$SANDBOX/tmpl" || return 1
        printf '[hook "%s"]\n\tenabled = false\n' "$section" >"$SANDBOX/tmpl/config" || return 1
        tmpl="$(st_native_sandbox)/tmpl"
        gitx config --global init.templateDir "$tmpl" || return 1
        gsg status
        assert_rc 0 "a template that disables hook.$section.enabled copies into new repositories only"
        assert_not_contains "$OUT" "hook enabled" "no false alarm [$section]"
        assert_not_contains "$OUT" "hook list" "no init failure either [$section]"
    done
}

test_status_ignores_bad_values_of_the_variables_git_names_as_local() {
    local v
    fresh_install
    for v in GIT_IMPLICIT_WORK_TREE GIT_NO_REPLACE_OBJECTS GIT_REPLACE_REF_BASE GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_SHALLOW_FILE GIT_GRAFT_FILE; do
        EXTRA_ENV=("$v=/nonexistent/bad")
        gsg status
        assert_rc 0 "$v with a bad value"
        assert_not_contains "$OUT" "hook list" "no false alarm [$v]"
    done
}

run_file_tests
