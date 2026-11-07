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

# ^ invariant the old git is first on PATH => it is the git in use; the real one stays behind it as the wrapper's target
test_status_names_the_git_in_use_and_its_version() {
    fresh_install
    gsg status
    assert_rc 0 "a git that can run config hooks"
    assert_contains "$OUT" "git in use: " "the line exists on every run"
    assert_contains "$OUT" "(git $("$GIT" --version | sed -e 's/^git version //' -e 's/.windows.*//' -e 's/.vfs.*//'))" "with the version"
}

test_status_exits_1_when_the_git_in_use_is_older_than_2_54() {
    fresh_install
    st_git_stub "git version 2.52.0" || return 1
    gsg status
    assert_rc 1 "commits are not scanned"
    assert_contains "$OUT" "git 2.52.0" "the version"
    assert_contains "$OUT" "commits are not scanned" "says what it means"
    assert_contains "$OUT" "install --upgrade-git" "and what to run"
}

test_status_skips_the_hook_check_when_the_git_is_too_old_or_unreadable() {
    fresh_install
    st_git_stub "git version 2.20.1" hook "git: 'hook' is not a git command" || return 1
    gsg status
    assert_rc 1 "an old git"
    assert_contains "$OUT" "git in use: $SANDBOX/pathbin/git (git 2.20.1) MISMATCH" "one clear line"
    assert_not_contains "$OUT" "hook list" "no second line from a command the old git lacks"
    assert_not_contains "$OUT" "hook enabled" "and no third"
    st_git_stub "none of your business" hook "git: 'hook' is not a git command" || return 1
    gsg status
    assert_rc 1 "an unreadable version"
    assert_contains "$OUT" "version unreadable" "says so"
    assert_not_contains "$OUT" "hook list" "the check is skipped as well"
}

test_status_ignores_an_old_git_that_is_not_first_on_path() {
    fresh_install
    mkdir -p -- "$SANDBOX/lastbin" || return 1
    printf '#!/bin/sh\necho "git version 2.52.0"\n' >"$SANDBOX/lastbin/git" && chmod 755 "$SANDBOX/lastbin/git" || return 1
    set_env PATH="$SANDBOX/pathbin:$TEST_BASE_PATH:$SANDBOX/lastbin"
    gsg status
    assert_rc 0 "an old git behind the first one is the doctor's business"
    assert_not_contains "$OUT" "2.52.0" "and not named"
}

test_status_exits_1_with_a_message_when_there_is_no_git_on_path() {
    fresh_install
    lc_path_without git || return 1
    gsg status
    assert_rc 1 "no git at all"
    assert_contains "$ERR" "git is not on PATH" "says why"
}

test_status_counts_a_missing_jq_setsid_taskkill_or_timeout_as_a_problem() {
    local key name
    for key in JQ_BIN SETSID_BIN TASKKILL_BIN TIMEOUT_BIN; do
        fresh_install
        if ! grep -q "^$key=" "$LC_DATA/settings"; then continue; fi
        sed -i "s#^$key=.*#$key=/nonexistent/tool#" "$LC_DATA/settings" || return 1
        gsg status
        name="${key%_BIN}"
        name="${name,,}"
        assert_rc 1 "[$key] a missing tool stops every commit"
        assert_contains "$OUT" "$name: /nonexistent/tool (MISSING or not executable)" "[$key] flagged"
    done
}

# ^ external a git older than 2.26 has no --show-scope => the lines needing it say so; status still ends with the tools and exits 1
# shellcheck disable=SC2016
test_status_with_a_git_older_than_2_26_reads_cleanly_and_never_says_yes() {
    fresh_install
    printf '#!/bin/sh\nfor a in "$@"; do if [ "$a" = --show-scope ]; then echo "error: unknown option \\`show-scope'"'"'" >&2; exit 129; fi; done\nif [ "$1" = --version ]; then echo "git version 2.20.0"; exit 0; fi\nexec %s "$@"\n' "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git"
    gsg status
    assert_rc 1 "an old git"
    assert_not_contains "$OUT$ERR" "unknown option" "no stray git error"
    assert_not_contains "$OUT" "hook enabled" "no verdict from a git that cannot give one"
    assert_contains "$OUT" "core.hooksPath (effective): not read" "said plainly"
    assert_contains "$OUT" "trufflehog" "the tool lines still follow"
}

# shellcheck disable=SC2016
test_status_names_usr_bin_git_when_bin_is_a_link_and_comes_first() {
    local r="$SANDBOX/rootfs"
    fresh_install
    mkdir -p -- "$r/usr/bin" || return 1
    printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.52.0"; exit 0; fi\nexec %s "$@"\n' "$GIT" >"$r/usr/bin/git" || return 1
    chmod 755 "$r/usr/bin/git"
    ln -s usr/bin "$r/bin" || return 1
    set_env GSG_GITUP_ROOT="$r" PATH="$r/bin:$SANDBOX/pathbin:$TEST_BASE_PATH"
    gsg status
    assert_rc 1 "an old git first"
    assert_contains "$OUT" "git in use: $r/usr/bin/git (git 2.52.0)" "the real spelling, not the link"
    assert_not_contains "$OUT" "$r/bin/git" "the link spelling appears nowhere"
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

# ^ external native git reads GIT_CONFIG_SYSTEM and GIT_DIR itself; on Windows they must be C:/ paths
st_native_sandbox() { if [ "$TEST_IS_WINDOWS" -eq 1 ]; then printf '%s' "$TEST_SANDBOX_MIXED"; else printf '%s' "$SANDBOX"; fi; }

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
        assert_contains "$OUT" "hook.$section.enabled=false in the global config" "an unreadable value after false does not switch it back on, and the deciding value is named"
    done
}

test_status_stays_quiet_for_every_enabled_value_git_reads_as_on() {
    local section v
    st_install_for_hook_cases || return 1
    for section in git-secret-guard pre-commit; do
        for v in true yes on 1 garbage; do
            st_hook_case "$section" 0 "enabled = $v"
            assert_not_contains "$OUT" "MISMATCH (git hook list" "no false alarm [$v]"
            assert_not_contains "$OUT" "hook list: MISMATCH" "no false alarm [$v]"
        done
        st_hook_case "$section" 0 "enabled = false" "enabled = true"
    done
}

test_status_says_why_a_value_less_enabled_key_blocks_every_commit() {
    local section
    st_install_for_hook_cases || return 1
    for section in git-secret-guard pre-commit; do
        st_hook_case "$section" 1 "enabled"
        assert_contains "$OUT" "hook list: MISMATCH (git hook list pre-commit failed with exit" "git itself refuses the listing"
        assert_contains "$OUT" "hook.$section.enabled" "git's own message names the key"
        assert_contains "$OUT" "hook enabled: hook.$section.enabled has no value in the global config" "and the scan names scope and file"
    done
}

test_status_names_the_key_scope_file_and_advice_and_prints_no_configured_command_value() {
    local line section
    st_install_for_hook_cases || return 1
    for section in git-secret-guard pre-commit; do
        st_hook_case "$section" 1 "enabled = false"
        line="$(printf '%s\n' "$OUT" | grep '^hook enabled: ')"
        assert_contains "$line" "hook.$section.enabled=false in the global config" "key, value and scope [$section]"
        assert_contains "$line" "remove the line from" "and the way back [$section]"
        assert_not_contains "$line" "$LC_DATA/hooks" "not the hook command that is configured [$section]"
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
    assert_contains "$OUT" "hook list: MISMATCH (git hook list pre-commit failed with exit 128" "git itself refuses the half-configured hook"
    assert_contains "$OUT" "'hook.git-secret-guard.command' must be configured" "and its words name the key"
}

test_status_reads_a_disable_in_the_system_config() {
    local section sys
    st_install_for_hook_cases || return 1
    sys="$(st_native_sandbox)/sysconfig"
    set_env GIT_CONFIG_NOSYSTEM=0 "GIT_CONFIG_SYSTEM=$sys"
    for section in git-secret-guard pre-commit; do
        printf '[hook "%s"]\n\tenabled = false\n' "$section" >"$SANDBOX/sysconfig" || return 1
        gsg status
        assert_rc 1 "a system-wide disable of hook.$section.enabled"
        assert_contains "$OUT" "hook.$section.enabled=false in the system config" "names key and scope"
    done
    printf '[hook "git-secret-guard"]\n\tenabled = false\n' >"$SANDBOX/sysconfig" || return 1
    printf '[hook "git-secret-guard"]\n\tenabled = garbage\n' >>"$SANDBOX/gitconfig" || return 1
    gsg status
    assert_rc 1 "system false stays off under a global value git cannot read"
    assert_contains "$OUT" "hook.git-secret-guard.enabled=false in the system config" "and the system value is the one named"
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
    assert_contains "$OUT" "hook.git-secret-guard.enabled=false in the command config" "names key and scope"
    assert_contains "$OUT" "unset the setting in the environment" "and says where to remove it"

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

# ^ invariant git reports the hook off and the scan finds no setting => the line reports it plainly; git keeps the verdict
test_status_says_plainly_when_git_reports_the_hook_disabled_but_the_setting_cannot_be_located() {
    st_install_for_hook_cases || return 1
    cp -- "$SANDBOX/gitconfig.installed" "$SANDBOX/gitconfig" || return 1
    printf '[hook "git-secret-guard"]\n\tenabled = false\n' >>"$SANDBOX/gitconfig" || return 1
    st_git_stub "" --show-scope "fatal: simulated" || return 1
    gsg status
    assert_rc 1 "git still decides"
    assert_contains "$OUT" "hook enabled: MISMATCH (git hook list pre-commit shows git-secret-guard as disabled" "the verdict line"
    assert_contains "$OUT" "git reports the hook disabled; the setting could not be located" "and the plain admission"
    st_git_stub "" gsg.probe=false "fatal: simulated" || return 1
    gsg status
    assert_rc 1 "a failing boolean probe leaves the verdict alone"
    assert_contains "$OUT" "the setting could not be located" "and is only a location failure"
    cp -- "$SANDBOX/gitconfig.installed" "$SANDBOX/gitconfig" || return 1
    gsg status
    assert_rc 0 "git says on, the broken scan is never asked"
    assert_not_contains "$OUT" "could not be located" "and nothing is said"
}

test_status_cleans_non_printing_characters_out_of_the_origin_file_name() {
    local inc
    case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) skip_test "Windows cannot create a file name with a control character" ;; esac
    fresh_install
    inc="$SANDBOX/inc"$'\001'"x.cfg"
    gitx config -f "$inc" hook.git-secret-guard.enabled false || return 1
    gitx config --global include.path "$inc" || return 1
    gsg status
    assert_rc 1 "an included file switches the hook off"
    assert_contains "$OUT" "hook.git-secret-guard.enabled=false in the global config" "named"
    assert_not_contains "$OUT" $'\001' "and the control character is gone from the file name"
}

test_status_reports_each_failing_git_step_and_prints_no_control_character() {
    local word esc=$'\033'
    fresh_install
    for word in rev-parse hook; do
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

# ^ security the probe runs no hook of the user's; git init fires reference-transaction => the repository is built by hand, nothing is initialised
# ^ invariant a reference-transaction script in core.hooksPath and a config hook for the event both write a marker; neither may exist after status or doctor
st_rt_traps() {
    mkdir -p -- "$SANDBOX/rthooks" || return 1
    printf '#!/bin/sh\necho ran >>"%s/rt.marker"\ncat >/dev/null\nexit 0\n' "$SANDBOX" >"$SANDBOX/rthooks/reference-transaction" || return 1
    chmod 755 "$SANDBOX/rthooks/reference-transaction" || return 1
    printf '#!/bin/sh\necho ran >>"%s/rt.config.marker"\ncat >/dev/null\nexit 0\n' "$SANDBOX" >"$SANDBOX/rtconfig.sh" || return 1
    chmod 755 "$SANDBOX/rtconfig.sh" || return 1
    gitx config --global core.hooksPath "$(st_native_sandbox)/rthooks" || return 1
    gitx config --global hook.rt.event reference-transaction || return 1
    gitx config --global hook.rt.command "$(st_native_sandbox)/rtconfig.sh" || return 1
}

test_status_runs_no_hook_of_the_users_while_it_asks_git() {
    fresh_install
    st_rt_traps || return 1
    gsg status
    assert_rc 0 "a healthy install"
    assert_no_file "$SANDBOX/rt.marker" "no core.hooksPath hook ran during the probe"
    assert_no_file "$SANDBOX/rt.config.marker" "and no config hook for reference-transaction ran"
}

# ^ invariant the settings' timeout binary bounds git hook list; a wrapper records the call and can fail it with 124
test_status_bounds_the_hook_listing_with_the_settings_timeout() {
    local real
    fresh_install
    real="$(sed -n 's#^TIMEOUT_BIN=##p' "$LC_DATA/settings" | head -n 1)"
    real="$(eval "printf '%s' $real")"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nprintf "%%s\n" "$*" >>"%s/timeout.log"\ncase " $* " in *" hook list "*) if [ -f "%s/timeout.fail" ]; then exit 124; fi ;; esac\nexec "%s" "$@"\n' "$SANDBOX" "$SANDBOX" "$real" >"$SANDBOX/mytimeout" || return 1
    chmod 755 "$SANDBOX/mytimeout" || return 1
    sed -i "s#^TIMEOUT_BIN=.*#TIMEOUT_BIN=$SANDBOX/mytimeout#" "$LC_DATA/settings" || return 1
    gsg status
    assert_rc 0 "a bounded listing still works"
    assert_contains "$(cat "$SANDBOX/timeout.log")" "hook list pre-commit" "git hook list ran under the timeout binary"
    : >"$SANDBOX/timeout.fail"
    gsg status
    assert_rc 1 "a listing that times out"
    assert_contains "$OUT" "hook list: MISMATCH (git hook list pre-commit failed with exit 124" "is a MISMATCH naming the exit status"
}

# ^ external a conditional include (gitdir, onbranch, hasconfig) never matches the throwaway repository => doctor sees what it switches off, status cannot
test_status_says_once_that_conditional_includes_are_only_seen_by_doctor() {
    local inc
    fresh_install
    gsg status
    assert_not_contains "$OUT" "conditional include" "nothing to say without one"
    inc="$SANDBOX/cond.cfg"
    printf '[hook "git-secret-guard"]\n\tenabled = false\n' >"$inc" || return 1
    gitx config --global "includeIf.gitdir:$(st_native_sandbox)/work/.path" "$(st_native_sandbox)/cond.cfg" || return 1
    gsg status
    assert_rc 0 "informational, not a problem"
    assert_contains "$OUT" "conditional includes: " "one plain line"
    assert_contains "$OUT" "doctor" "that points at doctor"
    assert_contains "$OUT" "gitconfig" "and names the file that holds the include"
    assert_not_contains "$OUT" "cond.cfg" "never the include path"
    assert_not_contains "$OUT" "/work/" "nor its condition"
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
    assert_contains "$OUT" "git in use: rb/git " "the relative path is what status reports"
    assert_not_contains "$OUT" "hook list: MISMATCH" "and the throwaway repository check uses it from any directory"
}

# ^ external status reads a relative GIT_CONFIG_GLOBAL from its own directory, git in a repository from the repo top => only an absolute value is reliable
test_status_reads_a_relative_global_config_from_the_directory_it_runs_in() {
    local here="$PWD"
    st_install_for_hook_cases || return 1
    set_env GIT_CONFIG_GLOBAL=gitconfig
    cd -- "$SANDBOX" || return 1
    gsg status
    assert_rc 0 "a healthy install with a relative GIT_CONFIG_GLOBAL"
    assert_not_contains "$OUT" "hook list: MISMATCH" "no false alarm"
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
        assert_not_contains "$OUT" "hook list: MISMATCH" "no false alarm [$v]"
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
        assert_not_contains "$OUT" "hook list: MISMATCH" "no init failure either [$section]"
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
        assert_not_contains "$OUT" "hook list: MISMATCH" "no false alarm [$v]"
    done
}

run_file_tests
