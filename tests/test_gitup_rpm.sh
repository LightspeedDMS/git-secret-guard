#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup.sh"

# ^ external the RPM module is Linux package-manager code; macOS and Windows have their own modules and test files
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Linux package manager flows"; fi

gu_nothing_changed_on_the_machine() {
    assert_no_file "$LC_STATE" "$1: no state"
    assert_eq "$(find "$GU_ROOT/usr/local" ! -type d | wc -l)" 0 "$1: nothing below the sandbox /usr/local"
    assert_eq "$(find "$SANDBOX/tmp" -maxdepth 1 -name 'gsg-git-build.*' | wc -l)" 0 "$1: no build directory left"
}

test_a_rocky_machine_with_an_old_git_builds_the_pinned_source_when_the_user_accepts() {
    gu_rpm_setup || return 1
    gsg_pty $'y\n' install
    assert_rc 0 "yes at the prompt"
    assert_contains "$OUT" "route: source" "the plan names the source route"
    assert_contains "$OUT" "git 2.56.0" "and the pinned version"
    assert_contains "$OUT" "git-2.56.0.tar.xz" "and the tarball"
    assert_contains "$OUT" "env -i with PATH=" "and the clean build environment"
    assert_contains "$OUT" "as root: $SANDBOX/pathbin/dnf install -y gcc make" "and the dependency command with the full path of the dnf root will run"
    assert_contains "$OUT" "/cp -dR --preserve=timestamps,links" "and the copy"
    assert_contains "$(gu_log)" "make -C" "make ran"
    assert_contains "$(gu_log)" "prefix=$GU_ROOT/usr/local NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 USE_LIBPCRE2=1" "with the proven flags and the prefix"
    assert_contains "$(gu_log)" "DESTDIR=" "into a stage directory"
    assert_eq "$("$GU_ROOT/usr/local/bin/git" --version)" "git version 2.56.0" "git is built into /usr/local"
    assert_file "$LC_STATE/state" "install ran to the end"
    assert_eq "$(find "$SANDBOX/tmp" -maxdepth 1 -name 'gsg-git-build.*' | wc -l)" 0 "the build directory is gone"
    assert_not_contains "$(gu_log)" "query-stdin-is-a-terminal" "no repository query read the terminal"
}

test_the_flag_gives_consent_up_front_for_the_source_route() {
    gu_rpm_setup || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "install --upgrade-git without a terminal"
    assert_not_contains "$OUT$ERR" "[y/N]" "no prompt"
    assert_eq "$("$GU_ROOT/usr/local/bin/git" --version)" "git version 2.56.0" "built"
}

test_a_machine_whose_repositories_offer_a_new_enough_git_is_upgraded_through_dnf_with_no_build() {
    gu_rpm_setup || return 1
    printf '2.55.0\n' >"$SANDBOX/dnf.candidate"
    printf '2.55.0' >"$SANDBOX/dnf.upgrade_to"
    gsg install --upgrade-git </dev/null
    assert_rc 0 "package route"
    assert_contains "$OUT" "route: package" "the plan names the package route"
    assert_contains "$(gu_log)" "dnf install -y git-core" "dnf installed git-core"
    assert_not_contains "$(gu_log)" "make " "no build ran"
    assert_eq "$(pathbin_git_version)" "git version 2.55.0" "git is the repository's"
}

pathbin_git_version() { "$SANDBOX/pathbin/git" --version; }

test_the_repository_query_is_read_only_bounded_and_never_answers_a_prompt() {
    gu_rpm_setup || return 1
    printf '2.55.0\n' >"$SANDBOX/dnf.candidate"
    gsg install </dev/null
    assert_rc 1 "no consent"
    assert_contains "$(gu_log)" "dnf --assumeno -q repoquery --latest-limit=1 --queryformat %{version}\\n git-core" "the exact query"
    assert_not_contains "$(grep repoquery "$SANDBOX/gitup.log")" " -y" "the query never says yes"
}

test_a_repository_whose_key_is_not_imported_is_named_and_the_route_falls_back_to_source() {
    gu_rpm_setup || return 1
    printf 'baseos\nacli\n' >"$SANDBOX/dnf.repos"
    printf 'acli' >"$SANDBOX/dnf.badrepo"
    printf '2.55.0\n' >"$SANDBOX/dnf.candidate"
    gsg install </dev/null
    assert_rc 1 "no consent, only the plan matters"
    assert_contains "$OUT$ERR" "repository acli could not be queried" "the failing repository is named"
    assert_not_contains "$OUT$ERR" "repository baseos could not be queried" "and the good one is not"
    assert_contains "$OUT" "route: source" "the route falls back to source"
    assert_contains "$(gu_log)" "--disablerepo=* --enablerepo=acli" "each repository was queried alone"
    assert_not_contains "$(grep -E 'repoquery|repolist' "$SANDBOX/gitup.log")" " -y" "no key was imported"
}

test_a_repository_that_hangs_ends_within_the_timeout_and_is_named() {
    gu_rpm_setup || return 1
    printf 'baseos\nslow\n' >"$SANDBOX/dnf.repos"
    printf 'slow' >"$SANDBOX/dnf.hang"
    SECONDS=0
    gsg install </dev/null
    assert_rc 1 "no consent"
    assert_contains "$OUT$ERR" "repository slow could not be queried" "the hanging repository is named"
    [ "$SECONDS" -lt 40 ] || fail "the plan took $SECONDS seconds"
}

test_a_new_git_in_usr_local_that_is_not_first_on_path_gets_the_path_fix_and_nothing_is_rebuilt() {
    gu_rpm_setup || return 1
    gu_old_build 2.56.0 || return 1
    set_env PATH="$SANDBOX/pathbin:$GU_ROOT/usr/local/bin:$TEST_BASE_PATH"
    gsg install --upgrade-git </dev/null
    assert_rc 1 "a new git is not first on PATH"
    assert_contains "$ERR" "put $GU_ROOT/usr/local/bin first on PATH, for example: export PATH=\"$GU_ROOT/usr/local/bin:\$PATH\"" "the exact fix"
    assert_not_contains "$(gu_log)" "make " "nothing was rebuilt"
    assert_no_file "$LC_HOME/.bashrc" "no profile edited"
}

test_a_tampered_tarball_stops_before_any_dependency_install_or_build() {
    gu_rpm_setup || return 1
    printf 'tampered\n' >"$LC_FIX/git-2.56.0.tar.xz" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "tarball does not match its digest"
    assert_contains "$ERR" "SHA-256 mismatch for git-2.56.0.tar.xz" "the digest check fired"
    assert_contains "$ERR" "nothing was changed" "and the message says nothing had changed"
    assert_not_contains "$(gu_log)" "dnf install" "no dependency install"
    assert_not_contains "$(gu_log)" "make " "no build"
    gu_nothing_changed_on_the_machine "tampered download"
}

test_a_failed_build_leaves_a_working_git_cleans_up_and_a_rerun_finishes() {
    gu_rpm_setup || return 1
    : >"$SANDBOX/make.fail"
    gsg install --upgrade-git </dev/null
    assert_rc 1 "make fails"
    assert_contains "$ERR" "the git upgrade failed" "says so"
    assert_contains "$ERR" "build dependencies" "and what had changed by then"
    assert_eq "$(pathbin_git_version)" "git version 2.52.0" "the old git still works"
    gu_nothing_changed_on_the_machine "failed build"
    rm -f -- "$SANDBOX/make.fail"
    gsg install --upgrade-git </dev/null
    assert_rc 0 "a rerun finishes"
    assert_eq "$("$GU_ROOT/usr/local/bin/git" --version)" "git version 2.56.0" "git is built"
}

test_an_interrupt_during_the_build_removes_the_build_directory() {
    local pid n=0
    gu_rpm_setup || return 1
    : >"$SANDBOX/make.hang"
    (setsid env --default-signal=INT env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" install --upgrade-git \
        >"$SANDBOX/int.out" 2>&1 </dev/null & echo $! >"$SANDBOX/int.pid")
    pid="$(<"$SANDBOX/int.pid")"
    while [ ! -f "$SANDBOX/make.started" ] && [ "$n" -lt 100 ]; do
        sleep 0.2
        n=$((n + 1))
    done
    assert_file "$SANDBOX/make.started" "the build started"
    kill -INT -- "-$pid" 2>/dev/null
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 100 ]; do
        sleep 0.2
        n=$((n + 1))
    done
    assert_eq "$(kill -0 "$pid" 2>/dev/null && echo alive || echo gone)" gone "install ended"
    assert_eq "$(pathbin_git_version)" "git version 2.52.0" "the old git still works"
    gu_nothing_changed_on_the_machine "interrupted build"
}

test_homebrew_first_on_path_cannot_reach_the_build() {
    gu_rpm_setup || return 1
    mkdir -p "$SANDBOX/brewbin" && printf '#!/bin/sh\necho poisoned\nexit 1\n' >"$SANDBOX/brewbin/gcc" && chmod 755 "$SANDBOX/brewbin/gcc" || return 1
    set_env PATH="$SANDBOX/brewbin:$GU_ROOT/usr/local/bin:$SANDBOX/pathbin:$TEST_BASE_PATH"
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the build ran"
    assert_contains "$(<"$SANDBOX/make.env")" "PATH=$SANDBOX/pathbin:/usr/bin:/bin" "the build PATH is the fixed one"
    assert_not_contains "$(<"$SANDBOX/make.env")" "brewbin" "and Homebrew's directory is not in it"
    assert_not_contains "$(<"$SANDBOX/make.env")" "XDG_" "no XDG variable reached make"
    assert_not_contains "$(<"$SANDBOX/make.env")" "GSG_" "no GSG variable reached make"
    assert_not_contains "$(<"$SANDBOX/make.env")" "GIT_" "no GIT variable reached make"
}

test_a_built_binary_that_links_against_homebrew_or_a_missing_library_is_refused_before_the_copy() {
    local line
    for line in '	libz.so.1 => /home/linuxbrew/.linuxbrew/lib/libz.so.1 (0x1)' '	libpcre2-8.so.0 => not found'; do
        gu_rpm_setup || return 1
        printf '%s\n' "$line" >"$SANDBOX/ldd.out"
        gsg install --upgrade-git </dev/null
        assert_rc 1 "ldd says [$line]"
        assert_contains "$ERR" "git-secret-guard: the built git" "the check names the built binary"
        assert_not_contains "$(gu_log)" "cp -dR" "nothing was copied for [$line]"
        assert_eq "$(find "$GU_ROOT/usr/local" -type f | wc -l)" 0 "nothing below /usr/local for [$line]"
    done
}

test_a_foreign_file_where_the_stage_would_write_is_never_overwritten() {
    gu_rpm_setup || return 1
    printf 'mine\n' >"$GU_ROOT/usr/local/bin/git-shell" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "a foreign git-shell"
    assert_contains "$ERR" "$GU_ROOT/usr/local/bin/git-shell" "the path is named"
    assert_contains "$ERR" "not listed in any MANIFEST" "and why"
    assert_not_contains "$(gu_log)" "cp -dR" "nothing was copied"
    assert_eq "$(<"$GU_ROOT/usr/local/bin/git-shell")" mine "the file is untouched"
}

test_the_manifest_lists_every_installed_file_and_git_help_can_find_the_man_pages() {
    local doc
    gu_rpm_setup || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "source route"
    doc="$GU_ROOT/usr/local/share/doc/git-2.56.0-local/MANIFEST"
    assert_file "$doc" "the MANIFEST"
    assert_contains "$(<"$doc")" "$GU_ROOT/usr/local/bin/git" "lists git"
    assert_contains "$(<"$doc")" "$GU_ROOT/usr/local/share/man/man1/git.1" "and the unpacked man page"
    assert_eq "$(find "$GU_ROOT/usr/local" ! -type d ! -path "$doc" | LC_ALL=C sort)" "$(LC_ALL=C sort "$doc")" "every installed file, and only those"
    assert_file "$GU_ROOT/usr/local/share/man/man1/git.1" "the man pages are unpacked"
}

test_too_little_free_space_refuses_before_anything_changes() {
    gu_rpm_setup || return 1
    printf '1000' >"$SANDBOX/df.avail"
    gsg install --upgrade-git </dev/null
    assert_rc 1 "no room to build"
    assert_contains "$ERR" "needs about 570 MB" "says how much"
    assert_contains "$ERR" "nothing was changed" "and that nothing changed"
    assert_not_contains "$(gu_log)" "dnf install" "no dependency install"
}

test_a_machine_without_dnf_or_curl_has_no_route_and_says_why() {
    gu_rpm_setup || return 1
    rm -f -- "$SANDBOX/pathbin/dnf" || return 1
    set_env GSG_GITUP_BUILD_PATH="$SANDBOX/pathbin"
    gsg install --upgrade-git </dev/null
    assert_rc 1 "no dnf"
    assert_contains "$OUT$ERR" "dnf was not found" "says why"
    assert_contains "$ERR" "config-based hooks need git >= 2.54, install refused" "today's refusal follows"
    gu_rpm_setup || return 1
    lc_path_without curl || return 1
    set_env PATH="$GU_ROOT/usr/local/bin:$SANDBOX/pathfarm-curl"
    gsg install --upgrade-git </dev/null
    assert_rc 1 "no curl"
    assert_contains "$ERR" "curl is required to download" "names curl"
    assert_not_contains "$(gu_log)" "dnf install" "before any dependency install"
}

test_a_rerun_after_the_upgrade_downloads_nothing_and_runs_no_privileged_command() {
    gu_rpm_setup || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "first run"
    rm -f -- "$SANDBOX/gitup.log" "$LC_FIX"/git-*.tar.xz
    gsg install --upgrade-git </dev/null
    assert_rc 0 "second run, with the flag"
    assert_no_file "$SANDBOX/gitup.log" "no sudo, dnf or make call"
    gsg_pty $'\n' install
    assert_rc 0 "second run in a terminal"
    assert_not_contains "$OUT" "[y/N]" "no prompt"
}

test_a_pin_bump_is_offered_and_replaces_the_old_build_and_its_obsolete_files() {
    gu_rpm_setup || return 1
    gu_old_build 2.55.0 || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "install --upgrade-git over an older build of ours"
    assert_eq "$("$GU_ROOT/usr/local/bin/git" --version)" "git version 2.56.0" "the new build replaced it"
    assert_file "$GU_ROOT/usr/local/share/doc/git-2.56.0-local/MANIFEST" "a new MANIFEST was saved"
    assert_no_file "$GU_ROOT/usr/local/share/man/man1/obsolete.1" "a file the new version no longer ships is removed"
    assert_no_file "$GU_ROOT/usr/local/share/doc/git-2.55.0-local" "and so is the old MANIFEST directory"
}

test_declining_a_pin_bump_changes_nothing_and_install_continues() {
    gu_rpm_setup || return 1
    gu_old_build 2.55.0 || return 1
    gsg_pty $'\n' install
    assert_rc 0 "Enter at the prompt"
    assert_contains "$OUT" "older than the git this version pins" "the offer was made"
    assert_eq "$("$GU_ROOT/usr/local/bin/git" --version)" "git version 2.55.0" "git is unchanged"
    assert_file "$GU_ROOT/usr/local/share/man/man1/obsolete.1" "nothing was removed"
    assert_file "$LC_STATE/state" "install continued"
    gsg install </dev/null
    assert_rc 0 "no terminal and no flag"
    assert_contains "$OUT$ERR" "--upgrade-git" "names the flag"
    assert_eq "$("$GU_ROOT/usr/local/bin/git" --version)" "git version 2.55.0" "git is still unchanged"
}

test_a_git_newer_than_the_pin_is_left_alone() {
    gu_rpm_setup || return 1
    gu_old_build 2.57.0 || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "newer than the pin"
    assert_not_contains "$OUT$ERR" "pins" "no offer"
    assert_no_file "$SANDBOX/gitup.log" "no privileged command"
}

test_a_build_that_is_not_ours_is_never_offered_a_rebuild() {
    gu_rpm_setup || return 1
    gu_old_build 2.55.0 || return 1
    rm -rf -- "$GU_ROOT/usr/local/share/doc" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "an older git in /usr/local without a MANIFEST of ours"
    assert_not_contains "$OUT$ERR" "pins" "no offer"
    assert_eq "$("$GU_ROOT/usr/local/bin/git" --version)" "git version 2.55.0" "git is untouched"
}

run_file_tests
