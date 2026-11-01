#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/doctor.sh"

# ^ invariant one line per file, directory or link under the sandbox (mode, size, mtime, SHA-256 of regular files); tmp/ and the harness dot files are left out
# ^ why mtimes are included, not only hashes; a created, touched or rewritten file or directory changes at least one of them
snapshot() {
    (
        cd -- "$SANDBOX" || exit 1
        find . \( -path ./tmp -o -path './.*' \) -prune -o -print0 | LC_ALL=C sort -z \
            | while IFS= read -r -d '' p; do
                if [ -f "$p" ] && [ ! -L "$p" ]; then
                    printf '%s %s %s\n' "$(stat -c '%n %a %s %Y' -- "$p")" "$(sha256sum -- "$p" | cut -d' ' -f1)" f
                else
                    stat -c '%n %F %a %Y' -- "$p"
                fi
            done
    )
}

# ^ external the real gitleaks is used when present, covering every kind of check
mess() {
    local i
    dr_begin || return 1
    for i in ok off over ign wide linked husky fw wtmain; do dr_repo "$i" || return 1; done
    gitx -C "$DR_ROOTS/off" config hook.git-secret-guard.enabled false || return 1
    gitx -C "$DR_ROOTS/over" config hook.git-secret-guard.command "/bin/true --token=$1" || return 1
    gitx -C "$DR_ROOTS/husky" config core.hooksPath .husky/_ || return 1
    gitx -C "$DR_ROOTS/wtmain" worktree add -q "$DR_ROOTS/wt" -b wt || return 1
    printf 'repos: [] # %s\n' "$1" >"$DR_ROOTS/fw/.pre-commit-config.yaml" || return 1
    mkdir -p -- "$DR_ROOTS/stray/.git" || return 1
    (
        cd -- "$DR_ROOTS/ign" || exit 1
        commit_ignore_file "no-reason-here"
    ) || return 1
    (
        cd -- "$DR_ROOTS/wide" || exit 1
        commit_ignore_file "**   # $1 everything" "src/*   # $1 top level"
    ) || return 1
    (
        cd -- "$DR_ROOTS/linked" || exit 1
        ln -s /etc/hostname .secret-scan-ignore && gitx add .secret-scan-ignore && gitx commit -q --no-verify -m link
    ) || return 1
    if [ -x "$REAL_GITLEAKS" ]; then
        sed -i "s#^GITLEAKS_BIN=.*#GITLEAKS_BIN=$REAL_GITLEAKS#" "$LC_DATA/settings" || return 1
        (
            cd -- "$DR_ROOTS/ok" || exit 1
            stage_file .gitleaks.toml "# $1" '[extend]' 'path = "base.toml"' && gitx commit -q --no-verify -m cfg
        ) || return 1
    fi
    gitx config --global core.hooksPath /old/hooks || return 1
    printf 'x\n' >"$SANDBOX/xdg/state/git-secret-guard/hooks-path-backup-20260101T000000Z.leftover.tar.gz" || return 1
}

test_doctor_changes_nothing_on_a_sandbox_full_of_problems() {
    local before after
    mess "$(new_marker)" || return 1
    before="$(snapshot)" || return 1
    [ "$(wc -l <<<"$before")" -gt 100 ] || fail "the snapshot is suspiciously small: $(wc -l <<<"$before") entries"
    assert_empty "$(find "$SANDBOX/tmp" -mindepth 1)" "the temp dir is empty before"
    doctor
    assert_rc 1 "a run with many findings"
    assert_contains "$OUT" "repos with findings:" "doctor really worked through the repos"
    assert_contains "$OUT" "summary: 10 repos, " "all of them, the worktree and the stray .git included once"
    assert_contains "$OUT" "WARNING  .secret-scan-ignore line 1 (pattern '**')" "the catch-all path ran"
    after="$(snapshot)" || return 1
    assert_eq "$after" "$before" "no file, directory, config, state or share entry was created, changed or touched"
    assert_empty "$(find "$SANDBOX/tmp" -mindepth 1)" "and doctor removed its own temp dir"
    doctor
    assert_eq "$(snapshot)" "$before" "also after a second run"
}

test_doctor_never_prints_file_contents_secrets_or_the_environment() {
    local marker env_marker key
    marker="$(new_marker)"
    env_marker="ENVMARKER$$$RANDOM"
    mess "$marker" || return 1
    key="$(fake_aws_key)"
    printf 'secret = %s\n' "$key" >"$DR_ROOTS/ok/leak.txt" || return 1
    set_env GSG_TEST_ENV_MARKER="$env_marker" GSG_TEST_API_TOKEN="$env_marker-token"
    doctor
    assert_rc 1 "a run with many findings"
    no_leak "$marker"
    no_leak "$env_marker"
    no_leak "$key"
    no_leak "$(probe_secret)"
    assert_not_contains "$OUT$ERR" "GSG_TEST_ENV_MARKER" "not even the variable names"
}

# ^ invariant a marker file proves git ran a script => doctor executed repository-configured code
marker_script() {
    printf '#!/bin/sh\n: >"%s/markers/%s"\nexit 1\n' "$SANDBOX" "$2" >"$1" && chmod 755 "$1"
}

reset_markers() {
    rm -rf -- "$SANDBOX/markers" "$SANDBOX/outside" || return 1
    mkdir -p -- "$SANDBOX/markers" "$SANDBOX/outside"
}

assert_no_markers() {
    assert_empty "$(find "$SANDBOX/markers" -type f 2>/dev/null)" "${1:-no repository-configured command ran}"
}

objects_listing() { (cd -- "$1/.git/objects" && find . -type f -printf '%p %s\n' | LC_ALL=C sort); }

test_doctor_runs_no_command_a_repository_configures() {
    local hook before after
    dr_begin && reset_markers && dr_repo fsm || return 1
    (cd -- "$DR_ROOTS/fsm" && commit_ignore_file "docs/x.txt   # a reason") || return 1
    marker_script "$SANDBOX/fsm.sh" fsmonitor || return 1
    mkdir -p -- "$SANDBOX/hp" || return 1
    for hook in reference-transaction post-index-change post-checkout pre-commit post-commit; do
        marker_script "$SANDBOX/hp/$hook" "hook-$hook" || return 1
    done
    gitx -C "$DR_ROOTS/fsm" config core.fsmonitor "$SANDBOX/fsm.sh" || return 1
    gitx -C "$DR_ROOTS/fsm" config core.hooksPath "$SANDBOX/hp" || return 1
    gitx -C "$DR_ROOTS/fsm" config gc.auto 1 || return 1
    gitx -C "$DR_ROOTS/fsm" config gc.autoDetach false || return 1
    gitx -C "$DR_ROOTS/fsm" config maintenance.auto true || return 1
    before="$(objects_listing "$DR_ROOTS/fsm")" || return 1
    doctor
    after="$(objects_listing "$DR_ROOTS/fsm")" || return 1
    assert_no_markers "core.fsmonitor, reference-transaction and the other hooks stay silent"
    assert_eq "$after" "$before" "the object store is as it was (no auto gc, no maintenance)"
    assert_contains "$OUT" "summary: 1 repos, " "doctor still judged the repository"
}

# ^ external a local file:// remote with uploadpack.allowFilter serves a --filter=blob:none clone; no network is involved
test_doctor_never_lazy_fetches_from_a_promisor_remote() {
    local before after
    dr_begin && reset_markers || return 1
    gitx init -q "$SANDBOX/outside/src" && gitx -C "$SANDBOX/outside/src" commit -q --allow-empty --no-verify -m init \
        && gitx -C "$SANDBOX/outside/src" config uploadpack.allowFilter true \
        && (cd -- "$SANDBOX/outside/src" && commit_ignore_file "docs/x.txt   # a reason") || return 1
    gitx clone -q --no-checkout --filter=blob:none "file://$SANDBOX/outside/src" "$DR_ROOTS/pc" || return 1
    printf '#!/bin/sh\n: >"%s/markers/uploadpack"\nexec %s upload-pack "$@"\n' "$SANDBOX" "$GIT" >"$SANDBOX/up.sh" && chmod 755 "$SANDBOX/up.sh" || return 1
    gitx -C "$DR_ROOTS/pc" config remote.origin.uploadpack "$SANDBOX/up.sh" || return 1
    before="$(objects_listing "$DR_ROOTS/pc")" || return 1
    doctor
    after="$(objects_listing "$DR_ROOTS/pc")" || return 1
    assert_rc 1 "the missing blob is a finding"
    assert_no_markers "the promisor remote's upload-pack was never started"
    assert_eq "$after" "$before" "no object arrived"
    assert_contains "$OUT" "PROBLEM  cannot read .secret-scan-ignore at HEAD" "the unreadable file is reported, not fetched"
    assert_contains "$OUT" "(doctor never fetches a missing object; git said: fatal: git cat-file HEAD:.secret-scan-ignore: bad file)" "with git's own reason"
    assert_not_contains "$ERR" "git cat-file" "and git's raw stderr line does not reach doctor's stderr"
}

test_doctor_folds_git_s_reason_for_a_missing_tree_into_the_finding() {
    dr_begin && reset_markers || return 1
    gitx init -q "$SANDBOX/outside/src" && gitx -C "$SANDBOX/outside/src" config uploadpack.allowFilter true \
        && (cd -- "$SANDBOX/outside/src" && commit_ignore_file "docs/x.txt   # a reason") || return 1
    gitx clone -q --no-checkout --filter=tree:0 "file://$SANDBOX/outside/src" "$DR_ROOTS/tc" || return 1
    doctor
    assert_rc 1 "the missing tree is a finding"
    assert_contains "$OUT" "git said: fatal: not a tree object)" "git's reason is in the finding"
    assert_contains "$OUT" "cannot read .gitleaks.toml at HEAD (git said: fatal: not a tree object); every commit" "also for the gitleaks file"
    assert_not_contains "$ERR" "not a tree object" "and not on doctor's stderr"
}

# ^ external GIT_TEST_ASSUME_DIFFERENT_OWNER=1 makes git treat every repository as foreign (setup.c), the safe.directory refusal without a second user
test_a_repository_git_refuses_for_its_owner_is_reported_not_a_crash() {
    dr_begin && dr_repo theirs || return 1
    set_env GIT_TEST_ASSUME_DIFFERENT_OWNER=1
    doctor
    assert_rc 1 "a finding, not a doctor error"
    assert_contains "$OUT" "PROBLEM  cannot be inspected: fatal: detected dubious ownership" "listed with git's own words"
    assert_contains "$OUT" "summary: 1 repos, 0 covered" "counted, not covered"
}

run_file_tests
