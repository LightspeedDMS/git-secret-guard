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

# ^ invariant the old git is first on PATH => it is the git in use; the real one stays behind it as the wrapper's target
# shellcheck disable=SC2016
status_with_git_version() {
    printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version %s"; exit 0; fi\nexec %s "$@"\n' "$1" "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git"
}

test_status_names_the_git_in_use_and_its_version() {
    fresh_install
    gsg status
    assert_rc 0 "a git that can run config hooks"
    assert_contains "$OUT" "git in use: " "the line exists on every run"
    assert_contains "$OUT" "(git $("$GIT" --version | sed -e 's/^git version //' -e 's/.windows.*//' -e 's/.vfs.*//'))" "with the version"
}

test_status_exits_1_when_the_git_in_use_is_older_than_2_54() {
    fresh_install
    status_with_git_version 2.52.0 || return 1
    gsg status
    assert_rc 1 "commits are not scanned"
    assert_contains "$OUT" "git 2.52.0" "the version"
    assert_contains "$OUT" "commits are not scanned" "says what it means"
    assert_contains "$OUT" "install --upgrade-git" "and what to run"
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

# ^ external real git 2.56 reads false, no, off, 0 (any case) and an empty value as off; true, yes, 1 and the rest leave it on; the last scope wins
# ^ invariant the system scope uses GIT_CONFIG_SYSTEM with NOSYSTEM=0 (the harness sets 1); status names key, scope and value
status_hook_switch() {
    local scope="$1" key="$2" value="$3"
    if [ "$scope" = global ]; then
        gitx config --global "$key" "$value"
    else
        set_env GIT_CONFIG_NOSYSTEM=0 "GIT_CONFIG_SYSTEM=$SANDBOX/system.cfg"
        gitx config -f "$SANDBOX/system.cfg" "$key" "$value"
    fi
}

test_status_names_a_hook_switched_off_in_each_scope_and_key() {
    local scope key value
    for scope in global system; do
        for key in hook.git-secret-guard.enabled hook.pre-commit.enabled; do
            fresh_install
            status_hook_switch "$scope" "$key" false || return 1
            gsg status
            assert_rc 1 "[$scope $key] switched off"
            assert_contains "$OUT" "MISMATCH $key=false in the $scope config" "[$scope $key] key, value and scope are named"
            assert_contains "$OUT" "remove the line from" "[$scope $key] and the way back"
        done
    done
}

test_status_treats_the_values_git_reads_as_false_as_off() {
    local value
    for value in no off 0 FALSE Off 00 0k 0x0 -0 ""; do
        fresh_install
        status_hook_switch global hook.git-secret-guard.enabled "$value" || return 1
        gsg status
        assert_rc 1 "[$value] is false for git"
        assert_contains "$OUT" "hook.git-secret-guard.enabled=$value in the global config" "[$value] is shown"
    done
}

test_status_stays_clean_when_the_enabled_keys_are_true_or_unset() {
    local scope value
    fresh_install
    gsg status
    assert_rc 0 "unset"
    assert_not_contains "$OUT" "switched off" "nothing said"
    for value in true yes 1; do
        fresh_install
        status_hook_switch global hook.git-secret-guard.enabled "$value" || return 1
        status_hook_switch global hook.pre-commit.enabled "$value" || return 1
        gsg status
        assert_rc 0 "[$value] keeps the hook on"
    done
}

test_status_follows_the_last_value_across_scopes() {
    fresh_install
    status_hook_switch system hook.git-secret-guard.enabled false || return 1
    status_hook_switch global hook.git-secret-guard.enabled true || return 1
    gsg status
    assert_rc 0 "a global true after a system false is on"
    fresh_install
    status_hook_switch system hook.git-secret-guard.enabled true || return 1
    status_hook_switch global hook.git-secret-guard.enabled false || return 1
    gsg status
    assert_rc 1 "a global false after a system true is off"
    assert_contains "$OUT" "in the global config" "and the scope that wins is named"
}

test_status_names_a_valueless_enabled_key_in_any_scope_even_when_a_later_scope_sets_true() {
    local key
    for key in git-secret-guard pre-commit; do
        fresh_install
        printf '[hook "%s"]\n\tenabled\n' "$key" >>"$SANDBOX/gitconfig" || return 1
        gitx config -f "$SANDBOX/system.cfg" "hook.$key.enabled" true || return 1
        set_env GIT_CONFIG_NOSYSTEM=0 "GIT_CONFIG_SYSTEM=$SANDBOX/system.cfg"
        gsg status
        assert_rc 1 "[$key] a key without a value"
        assert_contains "$OUT" "MISMATCH hook.$key.enabled has no value in the global config ($SANDBOX/gitconfig)" "[$key] key, scope and file"
        assert_contains "$OUT" "git commands fail until" "[$key] and what it does"
    done
}

# ^ external a git older than 2.26 has no --show-scope; the line must read cleanly, status still ends with the tools and exits 1
# shellcheck disable=SC2016
test_status_with_a_git_older_than_2_26_reads_cleanly_and_never_says_yes() {
    fresh_install
    printf '#!/bin/sh\nfor a in "$@"; do if [ "$a" = --show-scope ]; then echo "error: unknown option \`show-scope'"'"'" >&2; exit 129; fi; done\nif [ "$1" = --version ]; then echo "git version 2.20.0"; exit 0; fi\nexec %s "$@"\n' "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git"
    gsg status
    assert_rc 1 "an old git"
    assert_not_contains "$OUT$ERR" "unknown option" "no stray git error"
    assert_not_contains "$OUT" "hook enabled: yes" "never a false yes"
    assert_contains "$OUT" "hook enabled: not checked" "said plainly"
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

run_file_tests
