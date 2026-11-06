#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

assert_untouched() {
    assert_no_file "$LC_STATE" "$1: no state dir"
    assert_no_file "$LC_DATA" "$1: no share dir"
    assert_no_file "$LC_BIN" "$1: no bin dir"
    assert_eq "$(cat -- "$SANDBOX/gitconfig")" "$GITCONFIG_BEFORE" "$1: global config unchanged"
}

# ^ external a socket on stdin makes bash -c read ~/.bashrc even under env -i; its PATH edits gave /bin/jq against the /usr/bin/jq install found
lc_which() {
    # shellcheck disable=SC2016
    env -i PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" bash -c 'type -P "$1"' _ "$1" </dev/null
}

GITCONFIG_BEFORE=""
snapshot_config() { GITCONFIG_BEFORE="$(cat -- "$SANDBOX/gitconfig")"; }

test_install_refuses_when_the_git_on_PATH_is_older_than_2_54() {
    lc_begin && lc_fake_git 2.52.0 || return 1
    snapshot_config
    gsg install
    assert_rc 1 "old git"
    assert_contains "$ERR" "git 2.52.0" "names the version found"
    assert_contains "$ERR" "config-based hooks need git >= 2.54" "explains why"
    assert_untouched "old git"
    lc_fake_git 2.53.9
    gsg install
    assert_rc 1 "2.53.9 is still too old"
    lc_fake_git 1.9.0
    gsg install
    assert_rc 1 "1.9.0 is too old"
}

test_install_refuses_when_jq_setsid_or_timeout_is_not_reachable() {
    local tool
    for tool in jq setsid timeout; do
        lc_begin && lc_path_without "$tool" || return 1
        snapshot_config
        gsg install
        assert_rc 1 "$tool missing"
        assert_contains "$ERR" "$tool is required" "names $tool"
        assert_untouched "$tool missing"
    done
}

test_install_refuses_an_unsupported_platform() {
    local os arch
    while read -r os arch; do
        lc_begin || return 1
        # shellcheck disable=SC2016
        printf '#!/bin/sh\nif [ "$1" = "-s" ]; then echo %s; else echo %s; fi\n' "$os" "$arch" >"$SANDBOX/pathbin/uname" || return 1
        chmod 755 "$SANDBOX/pathbin/uname" || return 1
        snapshot_config
        gsg install
        assert_rc 1 "$os $arch"
        assert_contains "$ERR" "only Linux and macOS on x86_64 or arm64, or Git for Windows on x86_64, are supported, got $os on $arch" "says what is supported"
        assert_untouched "$os $arch"
    done <<'EOF'
Darwin i386
Linux riscv64
FreeBSD amd64
EOF
}

test_install_refuses_a_relative_home_or_xdg_dir() {
    local setting
    for setting in HOME= HOME=relative/home XDG_DATA_HOME=relative/data XDG_STATE_HOME=relative/state; do
        lc_begin || return 1
        set_env "$setting"
        snapshot_config
        gsg install
        assert_rc 1 "$setting"
        assert_contains "$ERR" "${setting%%=*} must be an absolute path" "names the variable for $setting"
        assert_untouched "$setting"
    done
}

test_install_refuses_a_global_hooks_path_without_the_flag_and_changes_nothing() {
    local value
    # shellcheck disable=SC2088
    for value in '~/.config/git/hooks' '/abs/hooks dir' ''; do
        lc_begin || return 1
        mkdir -p -- "$LC_HOME/.config/git/hooks" && printf 'echo old\n' >"$LC_HOME/.config/git/hooks/pre-commit" || return 1
        git_literal_config --global core.hooksPath "$value" || return 1
        snapshot_config
        gsg install
        assert_rc 1 "hooksPath [$value]"
        assert_contains "$ERR" "core.hooksPath is set to [$value]" "prints the current value"
        assert_contains "$ERR" "--replace-hooks-path" "names the flag that allows the takeover"
        assert_untouched "hooksPath [$value]"
        assert_file "$LC_HOME/.config/git/hooks/pre-commit" "the old hooks directory is untouched"
    done
}

test_install_refuses_a_hooks_path_with_several_values_even_with_the_flag() {
    lc_begin || return 1
    gitx config --global --add core.hooksPath /one || return 1
    gitx config --global --add core.hooksPath /two || return 1
    snapshot_config
    gsg install --replace-hooks-path
    assert_rc 1 "two values"
    assert_contains "$ERR" "core.hooksPath has 2 values" "says why"
    assert_untouched "several values"
}

test_install_downloads_verifies_and_extracts_both_tools_when_missing() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install with fixtures"
    assert_contains "$ERR" "GSG_TOOLS_BASE_URL" "the test override is announced, never silent"
    assert_eq "$(find "$LC_BIN" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')" "betterleaks git-secret-guard trufflehog " "the CLI link and the two binaries; no LICENSE, README or leftovers"
    [ -x "$LC_BIN/trufflehog$LC_EXE" ] && [ -x "$LC_BIN/betterleaks$LC_EXE" ] || fail "tools are not executable"
    assert_eq "$("$LC_BIN/trufflehog$LC_EXE" --version)" "trufflehog 3.99.2" "trufflehog is the downloaded one"
    assert_eq "$("$LC_BIN/betterleaks$LC_EXE" --version)" "betterleaks version 1.9.0" "betterleaks is the downloaded one"
}

seed_tool() {
    mkdir -p -- "$LC_BIN" || return 1
    printf '#!/bin/sh\necho "%s"\n# mine\n' "$2" >"$LC_BIN/$1$LC_EXE" || return 1
    chmod 755 "$LC_BIN/$1$LC_EXE"
}

recording_curl() {
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "$*" >>"%s/curl.log"\nexit 7\n' "$SANDBOX" >"$SANDBOX/pathbin/curl" || return 1
    chmod 755 "$SANDBOX/pathbin/curl"
}

test_install_keeps_tools_that_already_report_the_pinned_version() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && recording_curl || return 1
    seed_tool trufflehog "trufflehog 3.99.2" && seed_tool betterleaks "betterleaks version 1.9.0" || return 1
    local before
    before="$(sha256sum -- "$LC_BIN/trufflehog$LC_EXE" "$LC_BIN/betterleaks$LC_EXE")"
    gsg install
    assert_rc 0 "install"
    assert_eq "$(sha256sum -- "$LC_BIN/trufflehog$LC_EXE" "$LC_BIN/betterleaks$LC_EXE")" "$before" "both files are byte-identical"
    assert_no_file "$SANDBOX/curl.log" "nothing was downloaded"
}

test_install_replaces_tools_that_report_another_version() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    seed_tool trufflehog "trufflehog 3.0.0" && seed_tool betterleaks "betterleaks version 1.9.0" || return 1
    chmod 644 "$LC_BIN/betterleaks$LC_EXE"
    gsg install
    assert_rc 0 "install"
    assert_eq "$("$LC_BIN/trufflehog$LC_EXE" --version)" "trufflehog 3.99.2" "an older trufflehog is replaced"
    [ -x "$LC_BIN/betterleaks$LC_EXE" ] || fail "a non-executable betterleaks is replaced by an executable one"
    assert_not_contains "$(cat -- "$LC_BIN/trufflehog$LC_EXE")" "# mine" "no trace of the old file"
}

seed_user_betterleaks() {
    mkdir -p -- "$LC_BIN" || return 1
    printf '#!/bin/sh\necho "betterleaks version 8.18.4"\n# user build\n' >"$LC_BIN/betterleaks$LC_EXE" || return 1
    chmod 750 "$LC_BIN/betterleaks$LC_EXE"
}

test_a_different_version_tool_of_the_user_is_moved_aside_recorded_and_never_ours() {
    local sha aside rep
    lc_begin && lc_make_fixtures && lc_use_fixtures && seed_user_betterleaks || return 1
    sha="$(sha256sum <"$LC_BIN/betterleaks$LC_EXE")"
    gsg install
    assert_rc 0 "install over the user's betterleaks 8.18.4"
    aside="$(find "$LC_BIN" -name 'betterleaks.gsg-replaced-*')"
    [[ $aside =~ /betterleaks\.gsg-replaced-[0-9]{8}T[0-9]{6}Z$ ]] || fail "one aside file named <tool>.gsg-replaced-<UTC stamp>, got [$aside]"
    assert_eq "$(sha256sum <"$aside")" "$sha" "the user's file is byte-identical"
    assert_eq "$(stat -c %a "$aside")" 750 "and keeps its mode"
    assert_contains "$OUT" "$aside" "the output says where the original went"
    assert_eq "$("$LC_BIN/betterleaks$LC_EXE" --version)" "betterleaks version 1.9.0" "the pinned betterleaks is in place"
    assert_eq "$(state_value tools_installed_by_us)" "trufflehog" "a replaced file is never recorded as ours to delete"
    rep="$(state_value tools_replaced)"
    assert_eq "$rep" "${aside##*/}:$(sha256sum <"$LC_BIN/betterleaks$LC_EXE" | cut -d' ' -f1)" "state records the aside name and the hash of what install put there"
    gsg install
    assert_rc 0 "second install"
    assert_eq "$(find "$LC_BIN" -name 'betterleaks.gsg-replaced-*' | wc -l)" 1 "no second aside file"
    assert_eq "$(state_value tools_replaced)" "$rep" "and the record is unchanged"
}

test_install_refuses_when_the_aside_name_is_taken_and_changes_nothing() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && seed_user_betterleaks || return 1
    printf '#!/bin/sh\necho 20261031T101500Z\n' >"$SANDBOX/pathbin/date" && chmod 755 "$SANDBOX/pathbin/date" || return 1
    printf 'taken\n' >"$LC_BIN/betterleaks.gsg-replaced-20261031T101500Z" || return 1
    snapshot_config
    gsg install
    assert_rc 1 "the aside name already exists"
    assert_contains "$ERR" "already exists" "says why"
    assert_contains "$(<"$LC_BIN/betterleaks$LC_EXE")" "user build" "the user's betterleaks is untouched"
    assert_eq "$(<"$LC_BIN/betterleaks.gsg-replaced-20261031T101500Z")" taken "and so is the file in the way"
    assert_no_file "$LC_BIN/trufflehog$LC_EXE" "nothing else was installed"
    assert_no_file "$LC_DATA" "no share dir"
    assert_no_file "$LC_STATE" "no state"
    assert_eq "$(cat -- "$SANDBOX/gitconfig")" "$GITCONFIG_BEFORE" "global config unchanged"
}

assert_nothing_installed() {
    assert_rc 1 "$1"
    assert_contains "$ERR" "$2" "$1: says why"
    assert_empty "$(ls -A "$LC_BIN" 2>/dev/null)" "$1: no tool installed"
    assert_empty "$(ls -A "$SANDBOX/tmp")" "$1: the download and staging dir are removed"
    assert_no_file "$LC_DATA" "$1: no share dir"
    assert_no_file "$LC_STATE" "$1: no state dir"
    assert_eq "$(cat -- "$SANDBOX/gitconfig")" "$GITCONFIG_BEFORE" "$1: global config unchanged"
}

test_the_base_url_override_cannot_skip_verification() {
    lc_begin && lc_make_fixtures || return 1
    snapshot_config
    set_env GSG_TOOLS_BASE_URL="$(lc_fixture_url)"
    gsg install
    assert_nothing_installed "fixture tarballs against the real tools.lock" "SHA-256 mismatch"

    lc_use_fixtures
    sed -i 's/ [0-9a-f]\{64\}$/ 0000000000000000000000000000000000000000000000000000000000000000/' "$LC_FIX/fixture.lock" || return 1
    gsg install
    assert_nothing_installed "a lock with the wrong hashes" "SHA-256 mismatch"

    lc_make_fixtures || return 1
    printf 'tampered after the lock was written\n' >>"$LC_FIX/$(lc_asset_name betterleaks 1.9.0 "$(lc_platform betterleaks)")"
    gsg install
    assert_nothing_installed "a tarball changed after the lock was written" "SHA-256 mismatch"
    assert_contains "$ERR" "download removed" "and the download is deleted"

    : >"$LC_FIX/fixture.lock"
    gsg install
    assert_nothing_installed "an empty lock" "no row for trufflehog"

    lc_make_fixtures || return 1
    grep -v '^betterleaks ' "$LC_FIX/fixture.lock" >"$LC_FIX/partial.lock"
    set_env GSG_TOOLS_LOCK="$LC_FIX/partial.lock"
    gsg install
    assert_nothing_installed "a lock without a row for betterleaks" "no row for betterleaks"

    set_env GSG_TOOLS_LOCK="$LC_FIX/missing.lock"
    gsg install
    assert_nothing_installed "a lock file that does not exist" "cannot read the lock file"
}

test_install_refuses_a_binary_that_reports_another_version() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    snapshot_config
    local plat tar
    plat="$(lc_platform betterleaks)"
    tar="$LC_FIX/$(lc_asset_name betterleaks 1.9.0 "$plat")"
    printf '#!/bin/sh\necho "betterleaks version 8.0.0"\n' >"$LC_FIX/src/betterleaks/betterleaks" || return 1
    tar -czf "$tar" -C "$LC_FIX/src/betterleaks" betterleaks LICENSE README.md || return 1
    sed -i "s/^betterleaks 1.9.0 $plat .*/betterleaks 1.9.0 $plat $(sha256sum -- "$tar" | cut -d' ' -f1)/" "$LC_FIX/fixture.lock" || return 1
    gsg install
    assert_nothing_installed "a verified tarball whose binary says 8.0.0" "does not report version 1.9.0"
}

test_a_bad_second_tool_leaves_the_good_first_tool_uninstalled() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    snapshot_config
    printf 'tampered\n' >>"$LC_FIX/$(lc_asset_name betterleaks 1.9.0 "$(lc_platform betterleaks)")"
    gsg install
    assert_nothing_installed "trufflehog fine, betterleaks tampered" "SHA-256 mismatch for betterleaks"
}

test_curl_is_required_only_when_a_download_is_needed() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && lc_path_without curl || return 1
    snapshot_config
    gsg install
    assert_rc 1 "downloads needed, no curl"
    assert_contains "$ERR" "curl is required" "says why"
    assert_untouched "no curl"
    seed_tool trufflehog "trufflehog 3.99.2" && seed_tool betterleaks "betterleaks version 1.9.0" || return 1
    gsg install
    assert_rc 0 "nothing to download, so curl is not needed"
}

test_curl_is_run_with_q_first_so_the_users_curlrc_is_ignored() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    printf 'head\n' >"$LC_HOME/.curlrc" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "$1" >>"%s/curl.first"\nexec %q "$@"\n' "$SANDBOX" "$(type -P curl)" >"$SANDBOX/pathbin/curl" || return 1
    chmod 755 "$SANDBOX/pathbin/curl" || return 1
    gsg install
    assert_rc 0 "a ~/.curlrc that turns every request into HEAD must not matter"
    assert_eq "$(sort -u "$SANDBOX/curl.first")" "-q" "curl's first argument is always -q"
    assert_eq "$("$LC_BIN/betterleaks$LC_EXE" --version)" "betterleaks version 1.9.0" "the real tarball arrived"
}

fresh_install() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
}

gsg_installed() { run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$LC_BIN/git-secret-guard" "$@"; }

test_fresh_install_copies_the_package_into_the_share_dir_and_links_the_cli() {
    fresh_install
    assert_rc 0 "fresh install"
    local f
    for f in hooks/secret-scan lib/common.sh lib/run-scanner.sh lib/exempt.sh lib/extract.sh lib/extract.awk lib/report.sh lib/tools.sh \
        lib/install.sh lib/state.sh lib/usage.md lib/scanners/trufflehog.sh lib/scanners/betterleaks.sh bin/git-secret-guard tools.lock VERSION; do
        assert_file "$LC_DATA/$f" "share dir holds $f"
        assert_eq "$(cmp -s "$GSG_PROJECT/$f" "$LC_DATA/$f" && echo same)" same "$f is a verbatim copy"
    done
    [ -x "$LC_DATA/hooks/secret-scan" ] && [ -x "$LC_DATA/bin/git-secret-guard" ] || fail "hook and CLI keep their exec bit"
    assert_eq "$(readlink -- "$LC_BIN/git-secret-guard")" "$LC_DATA/bin/git-secret-guard" "the link in ~/.local/bin points at the installed CLI"
    assert_no_file "$LC_DATA/tests" "tests are not shipped"
    assert_no_file "$LC_DATA/docs" "docs are not shipped"
    gsg_installed version
    assert_eq "$OUT" "git-secret-guard $(<"$GSG_PROJECT/VERSION")" "the installed CLI runs from the symlink"
}

test_install_writes_the_settings_the_hook_reads_with_absolute_tool_paths() {
    fresh_install
    assert_rc 0 "fresh install"
    assert_file "$LC_DATA/settings" "settings next to hooks/ and lib/"
    # shellcheck disable=SC2016
    run_cap env -i "${GSG_ENV[@]}" bash -c '
        source "$1/lib/common.sh" && load_settings "$1/settings" || exit 10
        for spec in jq:$JQ_BIN trufflehog:$TRUFFLEHOG_BIN betterleaks:$BETTERLEAKS_BIN setsid:$SETSID_BIN timeout:$TIMEOUT_BIN; do
            if tool_unusable "${spec%%:*}" "${spec#*:}"; then echo "unusable ${spec}"; fi
            printf "%s=%s\n" "${spec%%:*}" "${spec#*:}"
        done
        printf "SCAN_TIMEOUT_SECONDS=%s\n" "$SCAN_TIMEOUT_SECONDS"' _ "$LC_DATA"
    assert_rc 0 "settings load through load_settings"
    assert_not_contains "$OUT" "unusable" "every configured tool is absolute and executable"
    assert_contains "$OUT" "trufflehog=$LC_BIN/trufflehog$LC_EXE" "trufflehog from ~/.local/bin"
    assert_contains "$OUT" "betterleaks=$LC_BIN/betterleaks$LC_EXE" "betterleaks from ~/.local/bin"
    assert_contains "$OUT" "jq=$(lc_which jq)" "jq as found on PATH at install time"
    assert_contains "$OUT" "setsid=$(lc_which setsid)" "setsid resolved at install time"
    assert_contains "$OUT" "timeout=$(lc_which timeout)" "timeout resolved at install time"
    assert_contains "$OUT" "SCAN_TIMEOUT_SECONDS=300" "default timeout"
}

test_install_records_the_pinned_scanner_versions_in_the_settings() {
    fresh_install
    assert_rc 0 "fresh install"
    assert_eq "$(grep -c '^TRUFFLEHOG_VERSION=' "$LC_DATA/settings")" 1 "one trufflehog version line"
    # shellcheck disable=SC2016
    run_cap env -i "${GSG_ENV[@]}" TRUFFLEHOG_VERSION=0.0.1 bash -c '
        source "$1/lib/common.sh" && load_settings "$1/settings" || exit 10
        printf "tf=%s gl=%s\n" "$TRUFFLEHOG_VERSION" "$BETTERLEAKS_VERSION"
        grep -v _VERSION= "$1/settings" >"$1/settings.bare"
        load_settings "$1/settings.bare" || exit 11
        printf "bare=[%s]\n" "${TRUFFLEHOG_VERSION:-}"' _ "$LC_DATA"
    assert_rc 0 "settings load"
    assert_contains "$OUT" "tf=3.99.2 gl=1.9.0" "the pinned versions the install verified"
    assert_contains "$OUT" "bare=[]" "an inherited version cannot fill a file without it"
}

cfg_count() { gitx config --global --get-all "$1" 2>/dev/null | wc -l; }

test_fresh_install_sets_exactly_one_event_and_one_absolute_command() {
    fresh_install
    assert_rc 0 "fresh install"
    assert_eq "$(gitx config --global --get-all hook.git-secret-guard.event)" "pre-commit" "one event"
    assert_eq "$(cfg_count hook.git-secret-guard.event)" 1 "event is single-valued"
    assert_eq "$(gitx config --global --get-all hook.git-secret-guard.command)" "$LC_DATA/hooks/secret-scan" "command is the installed hook, absolute"
    assert_eq "$(cfg_count hook.git-secret-guard.command)" 1 "command is single-valued"
    assert_eq "$(gitx config --global --get-regexp '^hook\.' | wc -l)" 2 "nothing else under hook.*"
}

test_install_replaces_duplicate_and_stale_config_values_instead_of_adding() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gitx config --global --add hook.git-secret-guard.event pre-commit || return 1
    gitx config --global --add hook.git-secret-guard.event commit-msg || return 1
    gitx config --global --add hook.git-secret-guard.command /old/one || return 1
    gitx config --global --add hook.git-secret-guard.command /old/two || return 1
    gsg install
    assert_rc 0 "install over stale values"
    assert_eq "$(gitx config --global --get-all hook.git-secret-guard.event)" "pre-commit" "one event, the stale commit-msg is gone"
    assert_eq "$(gitx config --global --get-all hook.git-secret-guard.command)" "$LC_DATA/hooks/secret-scan" "one command, the stale paths are gone"
    gsg install
    assert_rc 0 "second install"
    assert_eq "$(cfg_count hook.git-secret-guard.event)$(cfg_count hook.git-secret-guard.command)" 11 "still single-valued"
}

test_fresh_install_records_the_state() {
    fresh_install
    assert_rc 0 "fresh install"
    assert_file "$LC_STATE/state" "state file"
    assert_eq "$(state_value version)" "$(<"$GSG_PROJECT/VERSION")" "installed version"
    assert_eq "$(state_value previous_hooks_path_set)" no "no previous core.hooksPath"
    assert_eq "$(state_value previous_hooks_path)" "" "and no value"
    assert_eq "$(state_value tools_installed_by_us)" "trufflehog betterleaks" "both tools were downloaded by us"
    assert_eq "$(state_value backup_path)" "" "no backup"
    assert_eq "$(stat -c %a "$LC_STATE")" 700 "state dir is private"
    assert_eq "$(stat -c %a "$LC_STATE/state")" 600 "state file is private"
    assert_eq "$(state_value tools_replaced)" "" "nothing of the user's was moved aside"
    assert_eq "$(state_value tools_placed)" \
        "trufflehog:$(sha256sum <"$LC_BIN/trufflehog$LC_EXE" | cut -d' ' -f1) betterleaks:$(sha256sum <"$LC_BIN/betterleaks$LC_EXE" | cut -d' ' -f1)" \
        "the hash of every file install placed is recorded, also on an empty path"
    assert_eq "$(state_value timer_installed)" no "a plain install installs no timer"
    assert_eq "$(wc -l <"$LC_STATE/state")" 8 "exactly the eight keys"
}

# ^ invariant what install writes is independent of the caller umask; WSL 1 starts every shell at 0000, the normal case there
test_install_under_umask_000_leaves_nothing_writable_by_group_or_others() {
    local bad
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then skip_test "NTFS has no unix modes"; fi
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    run_cap bash -c 'umask 000; exec "$@"' _ env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" install
    assert_rc 0 "install under umask 000"
    assert_file "$LC_DATA/settings" "the settings file exists"
    bad="$(find "$LC_DATA" "$LC_STATE" "$LC_HOME/.local/bin" ! -type l -perm /022 2>/dev/null | LC_ALL=C sort)"
    assert_empty "$bad" "no file or directory install wrote is writable by group or others"
    assert_eq "$(stat -c %a "$LC_DATA/settings")" 644 "settings is 644, as under the usual umask 022"
}

seed_old_hooks() {
    mkdir -p -- "$1/sub" && printf '#!/bin/sh\necho old pre-commit\n' >"$1/pre-commit" && chmod 755 "$1/pre-commit" \
        && printf 'nested\n' >"$1/sub/data.txt"
}

test_replace_hooks_path_records_verbatim_backs_up_and_unsets() {
    local value dir
    # shellcheck disable=SC2088
    for value in '~/.config/git/hooks' "$SANDBOX/home/my hooks"; do
        lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
        dir="$LC_HOME/.config/git/hooks"
        case "$value" in /*) dir="$value" ;; esac
        seed_old_hooks "$dir" || return 1
        git_literal_config --global core.hooksPath "$value" || return 1
        gsg install --replace-hooks-path
        assert_rc 0 "takeover of [$value]"
        gitx config --global --get core.hooksPath >/dev/null
        assert_eq "$?" 1 "core.hooksPath is unset after the takeover of [$value]"
        assert_eq "$(state_value previous_hooks_path_set)" yes "recorded as set"
        assert_eq "$(state_value previous_hooks_path)" "$value" "recorded verbatim, [$value] not expanded"
        local backup
        backup="$(state_value backup_path)"
        case "$backup" in "$LC_STATE"/hooks-path-backup-*.tar.gz) ;; *) fail "backup path [$backup] is not a tarball in the state dir" ;; esac
        assert_file "$backup" "the tarball exists"
        assert_eq "$(stat -c %a "$backup")" 600 "and is private"
        mkdir -p -- "$SANDBOX/restore" && rm -rf -- "${SANDBOX:?}/restore/"* && tar -xzf "$backup" -C "$SANDBOX/restore" || return 1
        assert_eq "$(find "$SANDBOX/restore" -type f | sed "s#^$SANDBOX/restore/##" | LC_ALL=C sort | tr '\n' ' ')" \
            "$(basename -- "$dir")/pre-commit $(basename -- "$dir")/sub/data.txt " "the tarball holds the whole directory"
        assert_file "$dir/pre-commit" "the old directory is left in place"
        assert_contains "$OUT$ERR" "$backup" "the backup location is printed"
    done
}

test_replace_hooks_path_handles_a_missing_directory_and_an_empty_value() {
    local value
    for value in "$SANDBOX/home/does-not-exist" ""; do
        lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
        git_literal_config --global core.hooksPath "$value" || return 1
        gsg install --replace-hooks-path
        assert_rc 0 "takeover of [$value]"
        assert_eq "$(state_value previous_hooks_path_set)" yes "[$value] is recorded as set"
        assert_eq "$(state_value previous_hooks_path)" "$value" "and verbatim"
        assert_eq "$(state_value backup_path)" "" "there is nothing to back up"
        gitx config --global --get core.hooksPath >/dev/null
        assert_eq "$?" 1 "and core.hooksPath is unset"
    done
}

test_replace_hooks_path_refuses_a_relative_value_and_an_unbackupable_directory() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    git_literal_config --global core.hooksPath relative/hooks || return 1
    snapshot_config
    gsg install --replace-hooks-path
    assert_rc 1 "relative value"
    assert_contains "$ERR" "is relative" "says why"
    assert_untouched "relative hooksPath"

    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    seed_old_hooks "$LC_HOME/hooks" || return 1
    chmod 000 "$LC_HOME/hooks/pre-commit" || return 1
    git_literal_config --global core.hooksPath "$LC_HOME/hooks" || return 1
    snapshot_config
    gsg install --replace-hooks-path
    chmod 755 "$LC_HOME/hooks/pre-commit"
    assert_rc 1 "a directory tar cannot read"
    assert_contains "$ERR" "cannot back up" "says why"
    assert_no_file "$LC_BIN" "no tools installed"
    assert_no_file "$LC_DATA" "no share dir"
    assert_no_file "$LC_STATE/state" "no state"
    assert_empty "$(find "$LC_STATE" -type f 2>/dev/null)" "and no partial tarball is left"
    assert_eq "$(cat -- "$SANDBOX/gitconfig")" "$GITCONFIG_BEFORE" "global config unchanged: core.hooksPath is still set"
}

test_replace_hooks_path_refuses_the_home_dir_and_directories_over_the_backup_bounds() {
    local dir="$SANDBOX/home/big hooks"
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    printf 'x\n' >"$LC_HOME/some-file-in-home" || return 1
    git_literal_config --global core.hooksPath "$LC_HOME" || return 1
    snapshot_config
    gsg install --replace-hooks-path
    assert_rc 1 "hooksPath = the home directory"
    assert_contains "$ERR" "home directory" "says why"
    assert_untouched "home as hooksPath"

    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    seed_old_hooks "$dir" && truncate -s 51M "$dir/huge" || return 1
    git_literal_config --global core.hooksPath "$dir" || return 1
    snapshot_config
    gsg install --replace-hooks-path
    assert_rc 1 "a directory over 50 MB"
    assert_contains "$ERR" "larger than 52428800 bytes" "names the bound"
    assert_untouched "oversized hooksPath"

    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    seed_old_hooks "$dir" || return 1
    (cd -- "$dir" && seq 1 9997 | xargs touch) || return 1
    assert_eq "$(find "$dir" -mindepth 1 | wc -l)" 10000 "the fixture holds exactly 10000 entries"
    git_literal_config --global core.hooksPath "$dir" || return 1
    gsg install --replace-hooks-path
    assert_rc 0 "10000 entries in all are still backed up"

    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    seed_old_hooks "$dir" || return 1
    (cd -- "$dir" && seq 1 9998 | xargs touch) || return 1
    assert_eq "$(find "$dir" -mindepth 1 | wc -l)" 10001 "the fixture holds exactly 10001 entries"
    git_literal_config --global core.hooksPath "$dir" || return 1
    snapshot_config
    gsg install --replace-hooks-path
    assert_rc 1 "10001 files"
    assert_contains "$ERR" "more than 10000 files" "names the bound"
    assert_untouched "too many files"
}

# ^ external find -ls prints owner and group as separate words; a name with a space (AD, SSSD, directory-bound Macs) moves the size column
# shellcheck disable=SC2016
test_the_backup_bounds_do_not_depend_on_the_owner_columns_of_find_ls() {
    local fake="$SANDBOX/fakefind" dir="$SANDBOX/bounded" real_find
    lc_begin || return 1
    real_find="$(type -P find)" || return 1
    mkdir -p -- "$fake" "$dir" && head -c 11 /dev/zero >"$dir/f" || return 1
    printf '#!/bin/sh\nfor a in "$@"; do\n    if [ "$a" = -ls ]; then echo "1 1 -rw-r--r-- 1 Domain Users staff 11 Nov 1 12:00 x"; exit 0; fi\ndone\nexec %s "$@"\n' "$real_find" >"$fake/find" || return 1
    chmod 755 "$fake/find" || return 1
    run_cap env -i "${LC_ENV[@]}" PATH="$fake:$SANDBOX/pathbin:$TEST_BASE_PATH" bash -c '
        for l in common state tools hookspath install; do source "$1/lib/$l.sh" || exit 10; done
        GSG_BACKUP_MAX_BYTES=10 GSG_BACKUP_MAX_FILES=100
        install_check_backup_bounds "$2"' _ "$GSG_PROJECT" "$dir"
    assert_rc 1 "an 11 byte file against a 10 byte bound"
    assert_contains "$ERR" "larger than 10 bytes" "the bound is read from real sizes, not from the owner columns"
}

test_the_resolver_refuses_root_before_anything_could_back_it_up() {
    local value
    lc_begin || return 1
    for value in / // /./ /usr/..; do
        git_literal_config --global core.hooksPath "$value" || return 1
        # shellcheck disable=SC2016
        run_cap env -i "${LC_ENV[@]}" bash -c '
            for l in common state tools hookspath install; do source "$1/lib/$l.sh" || exit 10; done
            GSG_GIT="$(type -P git)"; GSG_PREV_SET=yes; GSG_PREV="$2"
            install_resolve_hooks_dir; rc=$?
            printf "dir=[%s]\n" "$GSG_PREV_DIR"; exit "$rc"' _ "$GSG_PROJECT" "$value"
        assert_rc 1 "hooksPath [$value] resolves to /"
        assert_contains "$ERR" "refusing to back up /" "says why"
        assert_not_contains "$OUT" "dir=[/]" "and never offers / as the directory to archive"
    done
}

tree_digest() { (cd -- "$1" && find . -type f -o -type l | LC_ALL=C sort | xargs -d '\n' sha256sum 2>&1 | sha256sum); }

test_a_second_install_changes_nothing_and_downloads_nothing() {
    fresh_install
    assert_rc 0 "first install"
    local cfg state share tools
    cfg="$(cat -- "$SANDBOX/gitconfig")"
    state="$(cat -- "$LC_STATE/state")"
    share="$(tree_digest "$LC_DATA")"
    tools="$(tree_digest "$LC_BIN")"
    recording_curl || return 1
    gsg install
    assert_rc 0 "second install"
    assert_eq "$(cat -- "$SANDBOX/gitconfig")" "$cfg" "global config is identical"
    assert_eq "$(cat -- "$LC_STATE/state")" "$state" "state is identical, both tools are still ours"
    assert_eq "$(tree_digest "$LC_DATA")" "$share" "share dir is identical"
    assert_eq "$(tree_digest "$LC_BIN")" "$tools" "tools and link are identical"
    assert_no_file "$SANDBOX/curl.log" "nothing was downloaded"
    assert_empty "$(find "$LC_DATA/.." -maxdepth 1 -name 'git-secret-guard.*')" "no staging leftovers beside the share dir"
}

test_a_tool_the_user_installed_is_never_recorded_as_ours() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    seed_tool trufflehog "trufflehog 3.99.2" || return 1
    gsg install
    assert_rc 0 "install"
    assert_eq "$(state_value tools_installed_by_us)" "betterleaks" "only the downloaded tool is ours"
    gsg install
    assert_eq "$(state_value tools_installed_by_us)" "betterleaks" "and a re-install keeps it that way"
}

make_newer_checkout() {
    local dest="$SANDBOX/checkout2"
    rm -rf -- "$dest" && mkdir -p -- "$dest" || return 1
    cp -a -- "$GSG_PROJECT/hooks" "$GSG_PROJECT/lib" "$GSG_PROJECT/bin" "$GSG_PROJECT/tools.lock" "$dest/" || return 1
    printf '0.2.0\n' >"$dest/VERSION" || return 1
    printf '# newer hook marker\n' >>"$dest/hooks/secret-scan" || return 1
    printf '# new lib\n' >"$dest/lib/added-in-0.2.0.sh" || return 1
}

test_an_install_from_a_newer_checkout_replaces_the_files_and_keeps_the_record() {
    fresh_install
    assert_rc 0 "first install"
    printf 'stale\n' >"$LC_DATA/lib/stale-from-0.1.0.sh" || return 1
    printf '# local edit\n' >>"$LC_DATA/lib/common.sh" || return 1
    make_newer_checkout || return 1
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$SANDBOX/checkout2/bin/git-secret-guard" install
    assert_rc 0 "upgrade"
    assert_eq "$(state_value version)" "0.2.0" "state shows the new version"
    assert_contains "$(<"$LC_DATA/hooks/secret-scan")" "newer hook marker" "the hook is the newer one"
    assert_file "$LC_DATA/lib/added-in-0.2.0.sh" "new files arrive"
    assert_no_file "$LC_DATA/lib/stale-from-0.1.0.sh" "files the new version no longer ships are gone"
    assert_eq "$(cmp -s "$GSG_PROJECT/lib/common.sh" "$LC_DATA/lib/common.sh" && echo same)" same "a local edit is overwritten"
    assert_eq "$(cfg_count hook.git-secret-guard.event)$(cfg_count hook.git-secret-guard.command)" 11 "config keys stay single-valued"
    assert_eq "$(state_value tools_installed_by_us)" "trufflehog betterleaks" "tools downloaded by the first install stay recorded"
    gsg_installed version
    assert_eq "$OUT" "git-secret-guard 0.2.0" "the installed CLI is the new one"
}

test_a_failed_copy_leaves_no_staging_dir_beside_the_share_dir() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    make_newer_checkout || return 1
    chmod 000 "$SANDBOX/checkout2/lib/extract.awk" || return 1
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$SANDBOX/checkout2/bin/git-secret-guard" install
    chmod 644 "$SANDBOX/checkout2/lib/extract.awk"
    assert_rc 1 "a source file that cannot be copied"
    assert_contains "$ERR" "extract.awk" "cp names the file it could not read, so the failure is the copy"
    assert_empty "$(find "$SANDBOX/xdg/data" -mindepth 1)" "nothing is left beside the share dir: no git-secret-guard.new.*"
    assert_no_file "$LC_DATA" "and no half-built share dir"
}

test_a_failed_swap_of_the_share_dir_rolls_back_to_the_old_tree() {
    local before
    fresh_install
    assert_rc 0 "first install"
    before="$(tree_digest "$LC_DATA")"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nfor a; do last=$a; case "$a" in *.new.*) isnew=1 ;; esac; done\nif [ "$last" = "%s" ] && [ -n "$isnew" ]; then echo "mv: injected failure" >&2; exit 1; fi\nexec %s "$@"\n' \
        "$LC_DATA" "$(type -P mv)" >"$SANDBOX/pathbin/mv" || return 1
    chmod 755 "$SANDBOX/pathbin/mv" || return 1
    gsg install
    assert_rc 1 "the new tree cannot be renamed onto the share dir"
    assert_contains "$ERR" "restored the previous share dir" "says the old tree is back"
    assert_eq "$(tree_digest "$LC_DATA")" "$before" "the share dir is back, byte-identical"
    assert_eq "$(find "$SANDBOX/xdg/data" -mindepth 1 -maxdepth 1 | wc -l)" 1 "nothing is left beside it: no .new. and no .old. directory"
}

test_a_leftover_old_tree_that_cannot_be_removed_is_reported() {
    fresh_install
    assert_rc 0 "first install"
    chmod 555 "$LC_DATA/lib/scanners" || return 1
    gsg install
    chmod -R u+rwX "$LC_DATA/.." 2>/dev/null
    assert_rc 0 "the upgrade itself succeeded"
    assert_contains "$ERR" "could not remove the previous share tree" "the failed cleanup is reported, not ignored"
    assert_contains "$ERR" "git-secret-guard.old." "with its location"
}

test_an_install_run_from_the_installed_copy_upgrades_in_place() {
    # ^ external measured on real WSL 1 (build 20348); renaming the directory of a running script fails there, and the plain-kernel path below cannot pass
    if grep -q 'Microsoft' /proc/sys/kernel/osrelease 2>/dev/null; then
        skip_test "real WSL 1 (4.4.0-20348-Microsoft): mv of the directory of a running script fails with Permission denied; the next test runs the WSL 1 path through the fixture seams"
    fi
    fresh_install
    assert_rc 0 "first install"
    local before
    before="$(tree_digest "$LC_DATA")"
    gsg_installed install
    assert_rc 0 "install run through the symlink, replacing the tree it runs from"
    assert_eq "$(tree_digest "$LC_DATA")" "$before" "the source is the installed copy itself, so the tree is identical"
    gsg_installed version
    assert_rc 0 "the CLI still runs afterwards"
    assert_empty "$(find "$LC_DATA/.." -maxdepth 1 -name 'git-secret-guard.*')" "no staging or old-tree leftovers"
}

# ^ external WSL 1 refuses to rename the directory of a running script (measured, build 20348); an install from the installed copy rewrites only the settings
# ^ invariant the WSL 1 kernel text comes through the fixture seams => the pinned path runs on any host, real WSL 1 included
test_an_install_run_from_the_installed_copy_on_wsl1_rewrites_only_the_settings_and_never_renames_the_tree() {
    printf '%s\n' "4.4.0-20348-Microsoft" >"$SANDBOX/wsl1-kernel" || return 1
    fresh_install
    assert_rc 0 "first install"
    set_env GSG_WSL_OSRELEASE="$SANDBOX/wsl1-kernel"
    printf 'kept\n' >"$LC_DATA/sentinel" || return 1
    printf 'stale\n' >"$LC_DATA/settings" || return 1
    gsg_installed install
    assert_rc 0 "install run through the symlink on WSL 1"
    assert_eq "$(<"$LC_DATA/sentinel")" kept "the tree it runs from was not replaced"
    assert_not_contains "$(<"$LC_DATA/settings")" stale "the settings were written again"
    assert_contains "$(<"$LC_DATA/settings")" "JQ_BIN=" "with their keys"
    gsg_installed version
    assert_rc 0 "the CLI still runs afterwards"
    assert_empty "$(find "$LC_DATA/.." -maxdepth 1 -name 'git-secret-guard.*')" "no staging or old-tree leftovers"
}

test_the_recorded_hooks_path_is_never_overwritten_by_a_later_install() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    local first second
    seed_old_hooks "$LC_HOME/.config/git/hooks" || return 1
    # shellcheck disable=SC2088
    git_literal_config --global core.hooksPath '~/.config/git/hooks' || return 1
    gsg install --replace-hooks-path
    assert_rc 0 "takeover"
    first="$(state_value backup_path)"
    gsg install
    assert_rc 0 "plain re-install"
    # shellcheck disable=SC2088
    assert_eq "$(state_value previous_hooks_path)" '~/.config/git/hooks' "still the first recorded value"
    assert_eq "$(state_value backup_path)" "$first" "and the same backup"

    seed_old_hooks "$LC_HOME/other hooks" || return 1
    git_literal_config --global core.hooksPath "$LC_HOME/other hooks" || return 1
    gsg install
    assert_rc 1 "a new global hooksPath needs the flag again"
    # shellcheck disable=SC2088
    assert_eq "$(state_value previous_hooks_path)" '~/.config/git/hooks' "refusal leaves the record alone"
    # shellcheck disable=SC2088
    git_literal_config --global core.hooksPath '~/.config/git/hooks' || return 1
    gsg install --replace-hooks-path
    assert_rc 0 "second takeover of the value that is already recorded"
    # shellcheck disable=SC2088
    assert_eq "$(state_value previous_hooks_path)" '~/.config/git/hooks' "the recorded value is still the first one"
    second="$(state_value backup_path)"
    [ "$second" != "$first" ] || fail "the second takeover reused the first backup file"
    assert_file "$first" "the first backup is kept"
    assert_file "$second" "the second backup exists"
    gitx config --global --get core.hooksPath >/dev/null
    assert_eq "$?" 1 "core.hooksPath is unset again"
}

test_a_second_takeover_with_a_different_value_is_refused_and_changes_nothing() {
    local state backups
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    seed_old_hooks "$LC_HOME/h1" && seed_old_hooks "$LC_HOME/h2" || return 1
    git_literal_config --global core.hooksPath "$LC_HOME/h1" || return 1
    gsg install --replace-hooks-path
    assert_rc 0 "first takeover"
    git_literal_config --global core.hooksPath "$LC_HOME/h2" || return 1
    snapshot_config
    state="$(cat -- "$LC_STATE/state")"
    backups="$(find "$LC_STATE" -name 'hooks-path-backup-*' | wc -l)"
    gsg install --replace-hooks-path
    assert_rc 1 "a different value than the recorded one"
    assert_contains "$ERR" "$LC_HOME/h1" "names the recorded value"
    assert_contains "$ERR" "$LC_HOME/h2" "and the current one"
    assert_contains "$ERR" "nothing was changed" "says nothing happened"
    assert_not_contains "$OUT$ERR" "recorded verbatim and unset" "never claims the value was recorded"
    assert_eq "$(cat -- "$LC_STATE/state")" "$state" "the state still holds the first value and its backup"
    assert_eq "$(cat -- "$SANDBOX/gitconfig")" "$GITCONFIG_BEFORE" "the global config is unchanged"
    assert_eq "$(find "$LC_STATE" -name 'hooks-path-backup-*' | wc -l)" "$backups" "no second tarball"
    gsg uninstall
    assert_rc 0 "uninstall keeps the newer value"
    assert_eq "$(gitx config --global --get core.hooksPath)" "$LC_HOME/h2" "h2 stays"
    gsg install --replace-hooks-path
    assert_rc 0 "a fresh takeover after uninstall"
    assert_eq "$(state_value previous_hooks_path)" "$LC_HOME/h2" "h2 is recorded now"
}

test_a_hooks_path_taken_over_after_a_plain_install_is_recorded() {
    fresh_install
    assert_rc 0 "plain install, nothing to record"
    assert_eq "$(state_value previous_hooks_path_set)" no "recorded as unset"
    seed_old_hooks "$LC_HOME/late hooks" || return 1
    git_literal_config --global core.hooksPath "$LC_HOME/late hooks" || return 1
    gsg install --replace-hooks-path
    assert_rc 0 "takeover after the fact"
    assert_eq "$(state_value previous_hooks_path_set)" yes "an 'unset' record is not a recorded value, so the real one is kept for uninstall"
    assert_eq "$(state_value previous_hooks_path)" "$LC_HOME/late hooks" "verbatim"
}

test_install_warns_but_proceeds_for_other_reachable_old_gits() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$SANDBOX/oldbin" "$SANDBOX/oldbin2" || return 1
    printf '#!/bin/sh\necho "git version 2.52.0"\n' >"$SANDBOX/oldbin/git" || return 1
    printf '#!/bin/sh\necho "git version 2.30.2"\n' >"$SANDBOX/oldbin2/git" || return 1
    chmod 755 "$SANDBOX/oldbin/git" "$SANDBOX/oldbin2/git" || return 1
    set_env PATH="$SANDBOX/pathbin:$TEST_BASE_PATH:$SANDBOX/oldbin:$SANDBOX/oldbin2:$SANDBOX/oldbin"
    gsg install
    assert_rc 0 "install proceeds"
    assert_contains "$ERR" "warning: $SANDBOX/oldbin/git is git 2.52.0" "warns about the first old git"
    assert_contains "$ERR" "warning: $SANDBOX/oldbin2/git is git 2.30.2" "and about the second"
    assert_contains "$ERR" "commits made with it are not scanned" "says what it means"
    assert_eq "$(grep -c "warning: $SANDBOX/oldbin/git" <<<"$ERR")" 1 "one warning per binary, though it is on PATH twice"
    assert_not_contains "$ERR" "warning: $GIT " "the git being used is not warned about"
    assert_file "$LC_STATE/state" "the install completed"
    if [ "$(/usr/bin/git --version 2>/dev/null | cut -d' ' -f3 | cut -d. -f2)" -lt 54 ] 2>/dev/null; then
        assert_contains "$ERR" "warning: /usr/bin/git is git" "the machine's own /usr/bin/git is reported"
        assert_eq "$(grep -c 'warning: /usr/bin/git ' <<<"$ERR")" 1 "once, though /bin/git is the same file"
    fi
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    lc_path_without git_none || return 1
    gsg install
    assert_rc 0 "with a clean PATH"
    if [ -x /usr/bin/git ] && [ "$(/usr/bin/git --version | cut -d' ' -f3 | cut -d. -f2)" -lt 54 ]; then
        assert_contains "$ERR" "warning: /usr/bin/git is git" "/usr/bin/git is checked even when it is not the first git on PATH"
    fi
}

test_install_refuses_before_changing_anything_when_it_cannot_record_or_link() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$LC_BIN" && printf 'mine\n' >"$LC_BIN/git-secret-guard" || return 1
    snapshot_config
    gsg install
    assert_rc 1 "a regular file where the CLI link goes"
    assert_contains "$ERR" "is not a symlink" "says why"
    assert_eq "$(cat -- "$LC_BIN/git-secret-guard")" mine "and the file is untouched"
    assert_eq "$(find "$LC_BIN" -mindepth 1 | wc -l)" 1 "no tool was installed"
    assert_no_file "$LC_DATA" "no share dir"
    assert_no_file "$LC_STATE" "no state"
    assert_eq "$(cat -- "$SANDBOX/gitconfig")" "$GITCONFIG_BEFORE" "global config unchanged"

    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$LC_STATE" && printf 'version=0.1.0\nnonsense\n' >"$LC_STATE/state" || return 1
    snapshot_config
    gsg install
    assert_rc 1 "a malformed state file"
    assert_contains "$ERR" "is malformed" "says why"
    assert_no_file "$LC_BIN" "no tools"
    assert_no_file "$LC_DATA" "no share dir"
    assert_eq "$(cat -- "$SANDBOX/gitconfig")" "$GITCONFIG_BEFORE" "global config unchanged"

    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    git_literal_config --global core.hooksPath $'/with\nnewline' || return 1
    snapshot_config
    gsg install --replace-hooks-path
    assert_rc 1 "a hooksPath that contains a newline cannot be recorded"
    assert_contains "$ERR" "contains a newline" "says why"
    assert_untouched "newline hooksPath"
}

test_install_prints_a_summary_of_what_it_did() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    seed_tool trufflehog "trufflehog 3.99.2" || return 1
    gsg install
    assert_rc 0 "install"
    assert_contains "$OUT" "installed git-secret-guard $(<"$GSG_PROJECT/VERSION")" "version"
    assert_contains "$OUT" "hook command: $LC_DATA/hooks/secret-scan" "hook command"
    assert_contains "$OUT" "trufflehog 3.99.2: kept $LC_BIN/trufflehog$LC_EXE (already at the pinned version)" "a tool that was already right"
    assert_contains "$OUT" "betterleaks 1.9.0: downloaded, verified against tools.lock and installed to $LC_BIN/betterleaks$LC_EXE" "a tool that was downloaded"
    gsg install
    assert_contains "$OUT" "betterleaks 1.9.0: kept $LC_BIN/betterleaks$LC_EXE (already at the pinned version)" "the second run keeps it"
}

test_install_refuses_when_git_is_missing_or_unreadable_or_a_tool_path_is_relative() {
    lc_begin && lc_path_without git || return 1
    snapshot_config
    gsg install
    assert_rc 1 "no git on PATH"
    assert_contains "$ERR" "git is not on PATH" "says why"
    assert_untouched "no git"

    lc_begin && lc_fake_git "none of your business" || return 1
    snapshot_config
    gsg install
    assert_rc 1 "a git that prints no version"
    assert_contains "$ERR" "is git of unknown version" "says the version is unknown"
    assert_untouched "unparsable git"

    lc_begin || return 1
    mkdir -p -- "$SANDBOX/rel" && printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/rel/jq" && chmod 755 "$SANDBOX/rel/jq" || return 1
    set_env PATH="rel:$SANDBOX/pathbin:$TEST_BASE_PATH"
    snapshot_config
    gsg install
    assert_rc 1 "jq found through a relative PATH entry"
    assert_contains "$ERR" "jq resolved to a relative path [rel/jq]" "says why"
    assert_untouched "relative jq"

    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    set_env GIT_CONFIG_GLOBAL="$SANDBOX"
    gsg install
    assert_rc 1 "a global git config that is a directory"
    assert_contains "$ERR" "cannot read the global git config" "says why"
    assert_no_file "$LC_DATA" "no share dir"
    assert_no_file "$LC_STATE" "no state"
    assert_no_file "$LC_BIN" "no tools"
}

test_install_refuses_a_read_only_global_config_before_changing_anything() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$SANDBOX/ro" && : >"$SANDBOX/ro/gitconfig" && chmod 555 "$SANDBOX/ro" || return 1
    set_env GIT_CONFIG_GLOBAL="$SANDBOX/ro/gitconfig"
    snapshot_config
    gsg install
    chmod 755 "$SANDBOX/ro"
    assert_rc 1 "a global config whose directory git cannot write a lock file in"
    assert_contains "$ERR" "cannot write the global git config" "says why"
    assert_untouched "read-only config"
}

test_install_creates_the_global_config_on_a_machine_that_has_none() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    rm -f -- "$SANDBOX/gitconfig" || return 1
    gsg install
    assert_rc 0 "no global git config file at all"
    assert_eq "$(gitx config --global --get hook.git-secret-guard.event)" pre-commit "the file was created with the hook config"
    assert_not_contains "$(cat -- "$SANDBOX/gitconfig")" "gsg-install-probe" "and the write probe left no trace"
}

test_a_syntactically_broken_global_config_stops_install_and_uninstall() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    printf '[broken\n' >"$SANDBOX/gitconfig" || return 1
    gsg install
    assert_rc 1 "install over a broken config"
    assert_contains "$ERR" "cannot read the global git config" "says why"
    assert_no_file "$LC_DATA" "no share dir"
    assert_no_file "$LC_BIN" "no tools"
    gsg uninstall
    assert_rc 1 "uninstall over a broken config"
    assert_contains "$ERR" "cannot read the global git config" "says why"
}

test_install_refuses_a_hooks_path_it_cannot_expand() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    git_literal_config --global core.hooksPath '~no_such_user_gsg/hooks' || return 1
    snapshot_config
    gsg install --replace-hooks-path
    assert_rc 1 "a ~user that does not exist"
    assert_contains "$ERR" "cannot expand the global core.hooksPath" "says why"
    assert_untouched "unexpandable hooksPath"
}

test_install_keeps_scanning_when_the_final_hooks_path_unset_fails() {
    local old
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    old="$LC_HOME/old hooks"
    seed_old_hooks "$old" || return 1
    git_literal_config --global core.hooksPath "$old" || return 1
    # shellcheck disable=SC2016
    lc_git_wrapper '[ "$1" = config ] && [ "$3" = --unset-all ] && [ "$4" = core.hooksPath ]' || return 1
    gsg install --replace-hooks-path
    assert_rc 1 "git refuses to unset core.hooksPath"
    assert_contains "$ERR" "could not unset the global core.hooksPath" "says what failed"
    assert_eq "$(gitx config --global --get hook.git-secret-guard.event)" pre-commit "the hook config was set before the unset: commits are scanned"
    assert_eq "$(gitx config --global --get core.hooksPath)" "$old" "the old hooksPath still applies"
    assert_file "$LC_STATE/state" "the record exists, so uninstall can undo it"
    rm -f -- "$SANDBOX/pathbin/git"
    gsg install --replace-hooks-path
    assert_rc 0 "the same command succeeds once git cooperates"
    gitx config --global --get core.hooksPath >/dev/null
    assert_eq "$?" 1 "core.hooksPath is unset now"
    assert_eq "$(state_value previous_hooks_path)" "$old" "and the record still holds the old value"
}

test_without_xdg_variables_the_defaults_under_home_are_used() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    LC_ENV=("${GSG_ENV[@]}" PATH="$SANDBOX/pathbin:$TEST_BASE_PATH")
    gsg install
    assert_rc 0 "install with HOME only"
    assert_file "$LC_HOME/.local/share/git-secret-guard/hooks/secret-scan" "share dir under ~/.local/share"
    assert_file "$LC_HOME/.local/state/git-secret-guard/state" "state under ~/.local/state"
    assert_eq "$(gitx config --global --get hook.git-secret-guard.command)" "$LC_HOME/.local/share/git-secret-guard/hooks/secret-scan" "command points there"
    assert_no_file "$SANDBOX/xdg/data/git-secret-guard" "the XDG dirs were not used"
}

run_file_tests
