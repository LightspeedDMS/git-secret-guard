#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/doctor.sh"

test_a_healthy_repo_is_counted_and_not_listed() {
    dr_begin && dr_repo alpha && dr_repo beta || return 1
    doctor
    assert_rc 0 "two covered repos"
    assert_contains "$OUT" "summary: 2 repos, 2 covered" "both counted"
    assert_not_contains "$OUT" "repos with findings" "and no repo section"
    assert_not_contains "$OUT" "$DR_REAL/alpha" "alpha is not named"
}

test_a_repo_that_disables_the_hook_locally_is_listed_with_the_config_file() {
    dr_begin && dr_repo off && dr_repo fine || return 1
    gitx -C "$DR_ROOTS/off" config hook.git-secret-guard.enabled false || return 1
    doctor
    assert_rc 1 "a disabled repo"
    assert_contains "$OUT" "repos with findings:" "the section header"
    assert_contains "$OUT" "  $DR_REAL/off
    PROBLEM  disabled in local config: hook.git-secret-guard.enabled=false ($DR_REAL/off/.git/config); remove that key to cover this repository" "named with its file"
    assert_not_contains "$OUT" "$DR_REAL/fine" "the healthy repo is not listed"
    assert_contains "$OUT" "summary: 2 repos, 1 covered" "the summary counts it as not covered"
}

test_hook_pre_commit_enabled_false_is_reported_with_its_own_key() {
    dr_begin && dr_repo off || return 1
    gitx -C "$DR_ROOTS/off" config hook.pre-commit.enabled false || return 1
    # ^ external Apple Git 2.54.0 (macOS) has no hook.<event>.enabled; the hook stays listed and runs, nothing to report
    case "$(gitx -C "$DR_ROOTS/off" hook list pre-commit 2>/dev/null)" in
        *event-disabled*) ;;
        *) skip_test "this git does not implement hook.<event>.enabled" ;;
    esac
    doctor
    assert_rc 1 "the event is switched off"
    assert_contains "$OUT" "PROBLEM  disabled in local config: hook.pre-commit.enabled=false ($DR_REAL/off/.git/config); remove that key to cover this repository" "the event key is named"
}

test_a_disabling_key_in_an_included_global_file_names_that_file() {
    dr_begin && dr_repo inc || return 1
    printf '[hook "git-secret-guard"]\n\tenabled = false\n' >"$SANDBOX/team.conf" || return 1
    gitx config --global "includeIf.gitdir:$(git_path "$DR_REAL")/.path" "$SANDBOX/team.conf" || return 1
    doctor
    assert_rc 1 "disabled through an include"
    assert_contains "$OUT" "PROBLEM  disabled in global config: hook.git-secret-guard.enabled=false ($SANDBOX/team.conf); remove that key to cover this repository" "the included file, not ~/.gitconfig"
}

test_a_repo_level_command_override_is_listed_without_printing_the_value() {
    local marker
    dr_begin && dr_repo over && dr_repo same || return 1
    marker="$(new_marker)"
    gitx -C "$DR_ROOTS/over" config hook.git-secret-guard.command "/bin/true --token=$marker" || return 1
    gitx -C "$DR_ROOTS/same" config hook.git-secret-guard.command "$LC_DATA/hooks/secret-scan" || return 1
    doctor
    assert_rc 1 "an overridden command"
    assert_contains "$OUT" "PROBLEM  command overridden in local config: hook.git-secret-guard.command ($DR_REAL/over/.git/config); remove that key to run the installed hook" "named by key and file"
    no_leak "$marker"
    assert_not_contains "$OUT" "$DR_REAL/same" "the same command set again locally is harmless"
}

test_a_repo_the_hook_never_reaches_is_listed_when_the_global_hook_config_is_gone() {
    dr_begin && dr_repo lone || return 1
    gitx config --global --remove-section hook.git-secret-guard || return 1
    doctor
    assert_rc 1 "no hook config"
    assert_contains "$OUT" "  $DR_REAL/lone
    PROBLEM  git-secret-guard is not in 'git hook list pre-commit'; no hook.git-secret-guard.event=pre-commit reaches this repository" "the repo is listed"
    assert_contains "$OUT" "summary: 1 repos, 0 covered" "and not covered"
}

test_a_missing_global_hook_command_is_reported_per_repo_as_an_incomplete_hook_config() {
    dr_begin && dr_repo half || return 1
    gitx config --global --unset-all hook.git-secret-guard.command || return 1
    doctor
    assert_rc 1 "the event without its command"
    assert_contains "$OUT" "  $DR_REAL/half
    PROBLEM  hook not reached: the global hook config is incomplete (see machine section)" "git's refusal is explained in doctor's words"
    assert_contains "$OUT" "PROBLEM  hook: hook.git-secret-guard.command is [unset]" "the machine section names the missing key"
    assert_not_contains "$OUT" "exit 128" "no raw git exit code"
    assert_not_contains "$OUT" "must be configured" "and no raw git sentence"
}

dr_disable() { gitx -C "$DR_ROOTS/$1" config hook.git-secret-guard.enabled false; }

test_discovery_finds_nested_repositories_and_skips_node_modules() {
    dr_begin || return 1
    dr_repo a && dr_repo g/b && dr_repo g/s/c || return 1
    dr_repo g/s/d/nested && dr_disable g/s/d/nested || return 1
    dr_repo node_modules/pkg && dr_disable node_modules/pkg || return 1
    dr_repo a/node_modules/dep && dr_disable a/node_modules/dep || return 1
    mkdir -p -- "$DR_ROOTS/plain/dir" || return 1
    doctor
    assert_rc 1 "the repo four levels down is found and disabled"
    assert_contains "$OUT" "summary: 4 repos, 3 covered" "a, g/b, g/s/c and g/s/d/nested"
    assert_contains "$OUT" "  $DR_REAL/g/s/d/nested" "four levels down is searched"
    assert_not_contains "$OUT" "node_modules" "node_modules is pruned at any depth"
}

test_roots_can_be_several_relative_overlapping_or_a_repo_themselves() {
    dr_begin && dr_repo x && dr_repo y && dr_disable y || return 1
    gsg doctor --roots "$DR_ROOTS/x" "$DR_ROOTS/y" "$DR_ROOTS"
    assert_rc 1 "overlapping roots"
    assert_contains "$OUT" "summary: 2 repos, 1 covered" "a repo reached through two roots is counted once"
    gsg doctor --roots "$DR_ROOTS/x"
    assert_rc 0 "a root that is a repository"
    assert_contains "$OUT" "summary: 1 repos, 1 covered" "it is the one repo"
    cd -- "$SANDBOX" || return 1
    gsg doctor --roots roots/y
    assert_rc 1 "a relative root"
    assert_contains "$OUT" "  $DR_REAL/y
" "shown as an absolute path"
}

test_worktrees_are_reported_once_under_their_main_repository() {
    dr_begin && dr_repo m && dr_disable m || return 1
    gitx -C "$DR_ROOTS/m" worktree add -q "$DR_ROOTS/wt1" -b wt1 || return 1
    doctor
    assert_rc 1 "a disabled main repo with a worktree"
    assert_contains "$OUT" "summary: 1 repos, 0 covered" "the worktree is not a second repository"
    assert_contains "$OUT" "  $DR_REAL/m
    worktrees: $DR_REAL/wt1
    PROBLEM  disabled in local config" "listed under the main repo with its worktree"
    mkdir -p -- "$SANDBOX/outside" || return 1
    gitx init -q "$SANDBOX/outside/main" && gitx -C "$SANDBOX/outside/main" commit -q --allow-empty --no-verify -m init \
        && gitx -C "$SANDBOX/outside/main" config hook.git-secret-guard.enabled false \
        && gitx -C "$SANDBOX/outside/main" worktree add -q "$DR_ROOTS/wt2" -b wt2 || return 1
    doctor
    assert_contains "$OUT" "  $(realpath -- "$SANDBOX/outside/main")
    worktrees: $DR_REAL/wt2
    PROBLEM  disabled in local config" "a worktree whose main repo is outside the roots is still reported under the main repo"
}

# ^ external extensions.worktreeConfig=true adds a per-worktree config.worktree layer; git hook list there shows "disabled<TAB>git-secret-guard" (git 2.56)
test_a_hook_disabled_in_a_linked_worktrees_own_config_is_reported_under_the_main_repo() {
    dr_begin && dr_repo wtmain || return 1
    gitx -C "$DR_ROOTS/wtmain" worktree add -q "$DR_ROOTS/wt" -b wt || return 1
    gitx -C "$DR_ROOTS/wtmain" config extensions.worktreeConfig true || return 1
    gitx -C "$DR_ROOTS/wt" config --worktree hook.git-secret-guard.enabled false || return 1
    assert_contains "$(gitx -C "$DR_ROOTS/wt" hook list pre-commit 2>&1)" $'disabled\tgit-secret-guard' "git itself says the hook is off in the worktree"
    doctor
    assert_rc 1 "the main checkout is fine, the worktree is not"
    assert_contains "$OUT" "  $DR_REAL/wtmain
    worktrees: $DR_REAL/wt
    PROBLEM  worktree $DR_REAL/wt: disabled in worktree config: hook.git-secret-guard.enabled=false (" "listed under the main repo, naming the worktree and the scope"
    assert_contains "$OUT" "config.worktree); remove that key to cover this repository" "and the file"
    assert_contains "$OUT" "summary: 1 repos, 0 covered" "not covered"
}

test_a_linked_worktree_outside_the_roots_is_not_checked() {
    dr_begin && dr_repo wtmain || return 1
    gitx -C "$DR_ROOTS/wtmain" worktree add -q "$SANDBOX/outside-wt" -b wt || return 1
    gitx -C "$DR_ROOTS/wtmain" config extensions.worktreeConfig true || return 1
    gitx -C "$SANDBOX/outside-wt" config --worktree hook.git-secret-guard.enabled false || return 1
    assert_contains "$(gitx -C "$SANDBOX/outside-wt" hook list pre-commit 2>&1)" $'disabled\tgit-secret-guard' "git itself says the hook is off in that worktree"
    doctor
    assert_rc 0 "only .git entries under the roots are looked at"
    assert_contains "$OUT" "summary: 1 repos, 1 covered" "the main repository is judged on its own checkout"
    assert_not_contains "$OUT" "outside-wt" "and the worktree outside the roots is not named"
}

test_a_shared_config_problem_is_reported_once_not_per_worktree() {
    dr_begin && dr_repo shared && dr_disable shared || return 1
    gitx -C "$DR_ROOTS/shared" worktree add -q "$DR_ROOTS/wta" -b wta || return 1
    gitx -C "$DR_ROOTS/shared" worktree add -q "$DR_ROOTS/wtb" -b wtb || return 1
    doctor
    assert_rc 1 "disabled in the shared repository config"
    assert_eq "$(grep -c 'PROBLEM  ' <<<"$OUT")" 1 "one finding for three checkouts"
    assert_not_contains "$OUT" "PROBLEM  worktree " "and none is attributed to a worktree"
}

test_a_worktree_of_a_bare_repository_is_reported_under_the_bare_repository() {
    dr_begin || return 1
    mkdir -p -- "$SANDBOX/outside" || return 1
    gitx init -q --bare "$SANDBOX/outside/bare.git" && gitx -C "$SANDBOX/outside/bare.git" config hook.git-secret-guard.enabled false \
        && gitx -C "$SANDBOX/outside/bare.git" -c user.name=a -c user.email=a@b.c commit-tree -m x "$(gitx -C "$SANDBOX/outside/bare.git" hash-object -t tree -w /dev/null)" >"$SANDBOX/outside/commit" \
        && gitx -C "$SANDBOX/outside/bare.git" update-ref refs/heads/main "$(<"$SANDBOX/outside/commit")" \
        && gitx -C "$SANDBOX/outside/bare.git" worktree add -q "$DR_ROOTS/wtbare" main || return 1
    doctor
    assert_rc 1 "the bare repository disables the hook"
    assert_contains "$OUT" "  $(realpath -- "$SANDBOX/outside/bare.git")
    worktrees: $DR_REAL/wtbare
    PROBLEM  disabled in local config" "listed under the bare repository, its common dir"
}

test_failing_repo_config_reads_are_problems_not_silence() {
    dr_begin && dr_repo broken || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = config ] && [ "$2" = --show-scope ]; then echo "fatal: injected failure" >&2; exit 128; fi\nexec %s "$@"\n' "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git" || return 1
    doctor
    assert_rc 1 "the per-repository config reads fail with exit 128"
    assert_contains "$OUT" "    PROBLEM  cannot read the hook config (git config exit 128: fatal: injected failure)" "the hook config read"
    assert_contains "$OUT" "    PROBLEM  cannot read core.hooksPath (git config exit 128: fatal: injected failure)" "the hooksPath read"
    assert_contains "$OUT" "summary: 1 repos, 0 covered" "not covered"
}

test_a_long_git_error_in_a_finding_is_cut_with_the_marker() {
    local msg
    dr_begin && dr_repo chatty || return 1
    msg="fatal: $(printf 'e%.0s' $(seq 1 250))"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = config ] && [ "$2" = --show-scope ]; then echo "%s" >&2; exit 128; fi\nexec %s "$@"\n' "$msg" "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git" || return 1
    doctor
    assert_rc 1 "the per-repository config reads fail"
    assert_contains "$OUT" "(git config exit 128: ${msg:0:200}…)" "git's words are cut at 200 characters and marked"
    assert_not_contains "$OUT" "${msg:0:201}" "and nothing past the cut"
}

test_more_repositories_than_the_bound_is_a_discovery_error() {
    dr_begin && dr_repo one && dr_repo two && dr_repo three || return 1
    # shellcheck disable=SC2016
    run_cap env -i "${LC_ENV[@]}" bash -c '
        source "$1/lib/common.sh" && source "$1/lib/doctor_repos.sh" && source "$1/lib/doctor.sh"
        GSG_GIT=/usr/local/bin/git; DR_WORK="$(mktemp -d)"; DR_ROOT_LIST=("$2"); GSG_DOCTOR_MAX_ENTRIES=2
        doctor_discover; rc=$?; rm -rf -- "$DR_WORK"; exit "$rc"' _ "$GSG_PROJECT" "$DR_ROOTS"
    assert_rc 1 "three repositories against a bound of two"
    assert_contains "$ERR" "more than 2 repositories or worktrees under the roots; narrow --roots" "says what to do"
}

# ^ invariant an unreadable directory is a finding, never a doctor error => one directory such as a database data dir cannot silence the whole report
test_an_unreadable_directory_is_a_listed_problem_and_the_rest_is_still_checked() {
    local limit="group" folders=30 i
    dr_begin && dr_repo fine && dr_repo off && dr_disable off || return 1
    # ^ invariant group + 30 folders + limit = find depth 32, the search depth; find never opens it, its entries would be depth 33
    for ((i = 0; i < folders; i++)); do limit+="/d"; done
    limit+="/limit"
    mkdir -p -- "$DR_ROOTS/locked" "$DR_ROOTS/group/nox" "$DR_ROOTS/$limit" && chmod 000 "$DR_ROOTS/locked" && chmod 600 "$DR_ROOTS/group/nox" || return 1
    chmod 000 "$DR_ROOTS/$limit" || return 1
    doctor
    assert_rc 1 "an unreadable directory under the roots is a PROBLEM"
    assert_not_contains "$ERR" "could not read everything" "and not a doctor error"
    assert_contains "$OUT" "PROBLEM  cannot read $DR_REAL/locked; repositories below it are not checked" "named, with what it means"
    assert_contains "$OUT" "PROBLEM  cannot read $DR_REAL/group/nox; repositories below it are not checked" "also a directory that can be listed but not searched"
    assert_not_contains "$OUT" "limit" "a directory at the search depth limit is never opened, so it is no finding"
    assert_contains "$OUT" "PROBLEM  disabled in local config" "the other repositories were still judged"
    assert_contains "$OUT" "summary: 2 repos, 1 covered" "and the summary counts them"
}

test_a_dot_git_that_git_cannot_open_is_listed_never_skipped() {
    dr_begin && dr_repo fine || return 1
    mkdir -p -- "$DR_ROOTS/stray/.git" || return 1
    doctor
    assert_rc 1 "a broken repository"
    assert_contains "$OUT" "  $DR_REAL/stray
    PROBLEM  cannot be inspected: fatal: not a git repository" "listed with git's own words"
    assert_contains "$OUT" "summary: 2 repos, 1 covered" "counted, not covered"
}

# ^ external git walks up from an empty .git directory and finds the parent repository; --show-toplevel names the parent, not the asked directory
test_an_invalid_nested_git_directory_is_listed_on_its_own_and_not_credited_to_its_parent() {
    dr_begin && dr_repo parent && dr_disable parent || return 1
    mkdir -p -- "$DR_ROOTS/parent/fixtures/sub/.git" || return 1
    printf 'repos: []\n' >"$DR_ROOTS/parent/.pre-commit-config.yaml" || return 1
    doctor
    assert_rc 1 "a parent with a disabled hook and a bogus .git below it"
    assert_contains "$OUT" "  $DR_REAL/parent
    PROBLEM  disabled in local config: hook.git-secret-guard.enabled=false ($DR_REAL/parent/.git/config); remove that key to cover this repository" "the parent is shown as itself, with a real config path"
    assert_contains "$OUT" ".pre-commit-config.yaml is present but $DR_REAL/parent/.git/hooks/pre-commit is not" "and its files were checked in its own directory"
    assert_contains "$OUT" "  $DR_REAL/parent/fixtures/sub
    PROBLEM  cannot be inspected: " "the bogus .git is its own entry"
    assert_contains "$OUT" "git resolves it to $DR_REAL/parent" "and says where git really went"
    assert_not_contains "$OUT" "$DR_REAL/parent/fixtures/sub/.git/config" "no config path that does not exist"
    assert_contains "$OUT" "summary: 2 repos, 0 covered" "two entries, neither covered"
}

# ^ external git opens an include.path FIFO for reading and blocks until a writer appears; nothing in git bounds that
# ^ external DOCTOR_TIMEOUT_SECONDS in the settings file bounds each git call of the repository phase (default 30), like SCAN_TIMEOUT_SECONDS does for the hook
test_a_repository_whose_config_hangs_git_becomes_a_timed_out_finding_instead_of_a_hang() {
    local start
    dr_begin && dr_repo fine && dr_repo hang || return 1
    mkfifo "$SANDBOX/cfg.fifo" || return 1
    printf '[include]\n\tpath = %s\n' "$SANDBOX/cfg.fifo" >>"$DR_ROOTS/hang/.git/config" || return 1
    printf 'DOCTOR_TIMEOUT_SECONDS=1\n' >>"$LC_DATA/settings" || return 1
    start="$(date +%s)"
    run_cap timeout 120 env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" doctor --roots "$DR_ROOTS"
    assert_rc 1 "the hung repository is a finding, doctor still finishes"
    [ "$(($(date +%s) - start))" -lt 60 ] || fail "doctor took $(($(date +%s) - start)) s"
    assert_contains "$OUT" "  $DR_REAL/hang
    PROBLEM  cannot be inspected: timed out after 1s" "listed with the reason"
    assert_contains "$OUT" "summary: 2 repos, 1 covered" "the other repository was judged"
}

# ^ why exec sleep, not a plain sleep; the shim's timeout kills its direct child only, a forked sleep would hold git's pipe open for 30 s
test_a_hung_hook_list_is_a_timed_out_finding() {
    dr_begin && dr_repo slow || return 1
    printf 'DOCTOR_TIMEOUT_SECONDS=1\n' >>"$LC_DATA/settings" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = hook ]; then exec sleep 30; fi\nexec %s "$@"\n' "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git" || return 1
    doctor
    assert_rc 1 "git hook list does not answer"
    assert_contains "$OUT" "PROBLEM  cannot read the hooks git runs (git hook list pre-commit exit 124: timed out after 1s)" "reported as a timeout, not a hang"
}

# ^ external macOS has no /proc; ps -axo works on both and the pattern travels in the environment; awk never matches itself
procs_running() {
    local listing
    listing="$(ps -axo pid=,command=)" || return 1
    printf '%s\n' "$listing" | PROCS_PATTERN="$1" awk 'index($0, ENVIRON["PROCS_PATTERN"]) { print $1 }'
}

# ^ hazard timeout --foreground in the doctor shim => only git is signalled, a process it started outlives the timeout
# ^ why the sleeper redirects its output, not inherits the pipe; an inherited pipe would hold doctor until the sleeper ends and hide the stray
test_a_timed_out_doctor_run_leaves_no_process_behind() {
    local sleeper="$SANDBOX/pathbin/gsg-stray-sleeper" stray
    dr_begin && dr_repo slow || return 1
    printf 'DOCTOR_TIMEOUT_SECONDS=1\n' >>"$LC_DATA/settings" || return 1
    ln -s /bin/sleep "$sleeper" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = hook ]; then %s 30 >/dev/null 2>&1 & wait; fi\nexec %s "$@"\n' "$sleeper" "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git" || return 1
    doctor
    assert_rc 1 "git hook list does not finish"
    assert_contains "$OUT" "PROBLEM  cannot read the hooks git runs (git hook list pre-commit exit 124: timed out after 1s)" "git was stopped by the limit"
    stray="$(procs_running "$sleeper")" || return 1
    # shellcheck disable=SC2086
    if [ -n "$stray" ]; then kill $stray 2>/dev/null; fi
    assert_empty "$stray" "no process git started is left running after the timeout"
}

test_an_unusable_timeout_stops_the_repository_phase_from_running_git() {
    dr_begin && dr_repo blind || return 1
    sed -i 's#^TIMEOUT_BIN=.*#TIMEOUT_BIN=/nonexistent/timeout#' "$LC_DATA/settings" || return 1
    doctor
    assert_rc 1 "the machine section already has the problem"
    assert_contains "$OUT" "  $DR_REAL/blind
    PROBLEM  cannot be inspected: git was not run: timeout or DOCTOR_TIMEOUT_SECONDS is unusable (see machine section)" "no repository is judged without a bound"
    assert_contains "$OUT" "summary: 1 repos, 0 covered" "and none is counted as covered"
}

test_an_invalid_doctor_time_limit_is_a_machine_problem() {
    local bad
    dr_begin && dr_repo calm || return 1
    for bad in 0 abc 1.5 -3 ''; do
        sed -i '/^DOCTOR_TIMEOUT_SECONDS=/d' "$LC_DATA/settings" && printf 'DOCTOR_TIMEOUT_SECONDS=%s\n' "$bad" >>"$LC_DATA/settings" || return 1
        doctor
        assert_rc 1 "[$bad] is not a positive integer"
        assert_contains "$OUT" "PROBLEM  settings: DOCTOR_TIMEOUT_SECONDS must be a positive integer, got [$bad]; fix or remove it in $LC_DATA/settings" "[$bad] named"
        assert_contains "$OUT" "summary: 1 repos, 0 covered" "[$bad]: the repository is not judged unbounded"
    done
    printf 'DOCTOR_TIMEOUT_SECONDS=%s\n' "$(printf '9%.0s' $(seq 1 60))" >>"$LC_DATA/settings" || return 1
    doctor
    assert_contains "$OUT" "got [$(printf '9%.0s' $(seq 1 40))…]" "a long value is cut and marked"
}

# ^ invariant doctor_unreadable rc 1 = not explained by permissions (caller exits 2), rc 0 only for Permission denied lines naming a directory
test_a_find_failure_that_is_not_a_permission_problem_is_not_explained_away() {
    dr_begin && dr_repo fine || return 1
    # shellcheck disable=SC2016
    run_cap env -i "${LC_ENV[@]}" bash -c '
        source "$1/lib/common.sh" && source "$1/lib/doctor_repos.sh" && source "$1/lib/doctor.sh"
        DR_WORK="$(mktemp -d)"; DR_UNREADABLE=(); declare -A DR_BAD_SEEN=()
        printf "find: x: No such file or directory\n" >"$DR_WORK/find.err"
        doctor_unreadable "$2"; a=$?
        printf "find: x: Permission denied\n" >"$DR_WORK/find.err"
        doctor_unreadable "$2"; b=$?
        : >"$DR_WORK/find.err"
        doctor_unreadable "$2"; c=$?
        rm -rf -- "$DR_WORK"; printf "%s %s %s" "$a" "$b" "$c"' _ "$GSG_PROJECT" "$DR_ROOTS"
    assert_eq "$OUT" "1 1 1" "another error, a permission error with no unreadable directory to name, and an empty log are all left unexplained"
}

test_a_repo_with_a_broken_local_config_is_listed_as_not_inspectable() {
    dr_begin && dr_repo fine && dr_repo garbled || return 1
    printf '[core\n\tbroken = (\n' >>"$DR_ROOTS/garbled/.git/config" || return 1
    doctor
    assert_rc 1 "git cannot read that repository's config"
    assert_contains "$OUT" "  $DR_REAL/garbled
    PROBLEM  cannot be inspected: " "listed, not skipped"
    assert_contains "$OUT" "summary: 2 repos, 1 covered" "and not counted as covered"
}

# ^ external git lists unknown extension names lowercased on tab-indented lines after its fatal line; the noun is plural for several
test_an_unknown_repository_extension_is_named_in_the_cannot_be_inspected_line() {
    dr_begin && dr_repo fine && dr_repo ext || return 1
    gitx -C "$DR_ROOTS/ext" config core.repositoryformatversion 1 && gitx -C "$DR_ROOTS/ext" config extensions.fooBar true || return 1
    doctor
    assert_rc 1 "git refuses that repository"
    assert_contains "$OUT" "  $DR_REAL/ext
    PROBLEM  cannot be inspected: fatal: unknown repository extension found: foobar
" "git's second line, the name, is part of the finding"
    assert_contains "$OUT" "summary: 2 repos, 1 covered" "and the other repository was judged"
}

test_several_unknown_extensions_are_all_named() {
    dr_begin && dr_repo ext || return 1
    gitx -C "$DR_ROOTS/ext" config core.repositoryformatversion 1 || return 1
    printf '[extensions]\n\tfooBar = true\n\tbazQux = true\n' >>"$DR_ROOTS/ext/.git/config" || return 1
    doctor
    assert_contains "$OUT" "cannot be inspected: fatal: unknown repository extensions found: foobar bazqux" "both names, on one line"
}

test_a_very_long_extension_name_is_cut_and_marked() {
    local long want
    dr_begin && dr_repo ext || return 1
    long="$(printf 'x%.0s' $(seq 1 300))"
    gitx -C "$DR_ROOTS/ext" config core.repositoryformatversion 1 && printf '[extensions]\n\t%s = true\n' "$long" >>"$DR_ROOTS/ext/.git/config" || return 1
    doctor
    want="fatal: unknown repository extension found: $long"
    assert_contains "$OUT" "cannot be inspected: ${want:0:200}…
" "cut at 200 characters with the marker, like every other git text"
    assert_not_contains "$OUT" "${want:0:201}" "and not one character more"
}

test_control_characters_in_repository_names_never_reach_the_output() {
    local name
    dr_begin || return 1
    name=$'evil\n\e[31mname'
    dr_repo "$name" && dr_disable "$name" || return 1
    doctor
    assert_rc 1 "a disabled repo with a hostile name"
    assert_contains "$OUT" "evil??[31mname" "newline and escape become question marks"
    assert_not_contains "$OUT" $'\e' "no escape byte is printed"
    assert_not_contains "$OUT" "evil
" "and no line break inside the name"
}

test_a_valueless_hooks_path_makes_git_refuse_and_is_reported_with_an_empty_value() {
    dr_begin && dr_repo bare || return 1
    printf '[core]\n\thooksPath\n' >>"$DR_ROOTS/bare/.git/config" || return 1
    doctor
    assert_rc 1 "git hook list fails on the repository"
    assert_contains "$OUT" "    PROBLEM  cannot read the hooks git runs (git hook list pre-commit exit 128: error: missing value for 'core.hookspath')" "the failure is a PROBLEM with git's words"
    assert_contains "$OUT" "    info     core.hooksPath= in local config ($DR_REAL/bare/.git/config)" "the valueless key shows an empty value, never its own name"
}

test_a_switch_off_exported_in_the_callers_environment_is_not_what_doctor_reports() {
    dr_begin && dr_repo calm || return 1
    set_env GIT_CONFIG_PARAMETERS="'hook.git-secret-guard.enabled'='false'"
    doctor
    assert_rc 0 "doctor reports the config files, not the caller's environment"
    assert_contains "$OUT" "summary: 1 repos, 1 covered" "the repo is covered by its files"
}

test_an_inherited_git_dir_cannot_point_every_check_at_one_repository() {
    dr_begin && dr_repo good && dr_repo bad && dr_disable bad || return 1
    set_env GIT_DIR="$DR_ROOTS/good/.git" GIT_WORK_TREE="$DR_ROOTS/good" GIT_INDEX_FILE="$DR_ROOTS/good/.git/index"
    doctor
    assert_rc 1 "GIT_DIR names the healthy repo"
    assert_contains "$OUT" "  $DR_REAL/bad
    PROBLEM  disabled in local config" "the disabled repo is still found"
    assert_contains "$OUT" "summary: 2 repos, 1 covered" "and judged on its own"
}

run_file_tests
