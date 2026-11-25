#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

SHELLCHECK="${GSG_TEST_SHELLCHECK:-$REAL_HOME/.local/bin/shellcheck}"
if [ ! -x "$SHELLCHECK" ]; then SHELLCHECK="$(command -v shellcheck || true)"; fi

GSG_SHELLCHECK_PIN=0.11.0

# ^ invariant prints why the gate cannot run with shellcheck BIN (its version is not the pin, or it does not answer), nothing when it can
shellcheck_gate_skip_reason() {
    local out ver
    out="$("$1" --version 2>/dev/null)" || {
        printf 'cannot read the version of %s' "$1"
        return 0
    }
    ver="$(printf '%s\n' "$out" | sed -n 's/^version: //p')"
    if [ "$ver" != "$GSG_SHELLCHECK_PIN" ]; then printf 'shellcheck %s found at %s, the gate is pinned to %s' "${ver:-of unknown version}" "$1" "$GSG_SHELLCHECK_PIN"; fi
}

# ^ why project_scripts omits tests/fixtures/husky/h, not shellcheck it; verbatim third-party sh script
project_scripts() {
    cd -- "$GSG_PROJECT" || return 1
    printf '%s\n' hooks/secret-scan bin/git-secret-guard lib/*/*.sh lib/*/*/*.sh tests/*.sh tests/*/*.sh tests/*/*/*.sh tests/stubs/* .github/scripts/check-dco.sh .github/scripts/check-macos-tests.sh .github/scripts/check-macos-unlisted.sh .github/scripts/docs-only.sh .github/scripts/docs-tests.sh .github/scripts/release-notes.sh
}

test_shellcheck_reports_nothing_on_every_script() {
    [ -x "$SHELLCHECK" ] || skip_test "shellcheck not found at $SHELLCHECK"
    local reason
    reason="$(shellcheck_gate_skip_reason "$SHELLCHECK")"
    if [ -n "$reason" ]; then skip_test "$reason"; fi
    local -a files
    mapfile -t files < <(project_scripts)
    [ "${#files[@]}" -ge 10 ] || fail "only ${#files[@]} scripts found"
    cd -- "$GSG_PROJECT" || return 1
    run_cap "$SHELLCHECK" -x -s bash "${files[@]}"
    assert_rc 0 shellcheck
    assert_empty "$OUT$ERR" "zero warnings, including info"
}

test_the_shellcheck_gate_skips_with_the_version_found_when_it_is_not_pinned() {
    local old="$SANDBOX/shellcheck-old" pinned="$SANDBOX/shellcheck-pinned" reason
    printf '#!/bin/sh\nprintf "ShellCheck - shell script analysis tool\\nversion: 0.9.0\\n"\n' >"$old" || return 1
    printf '#!/bin/sh\nprintf "ShellCheck - shell script analysis tool\\nversion: %s\\n"\n' "$GSG_SHELLCHECK_PIN" >"$pinned" || return 1
    chmod 755 "$old" "$pinned" || return 1
    reason="$(shellcheck_gate_skip_reason "$old")"
    assert_contains "$reason" "0.9.0" "names the version found"
    assert_contains "$reason" "$GSG_SHELLCHECK_PIN" "names the pinned version"
    reason="$(shellcheck_gate_skip_reason "$pinned")"
    assert_eq "$reason" "" "the pinned version runs the gate"
    printf '#!/bin/sh\nexit 3\n' >"$old" || return 1
    reason="$(shellcheck_gate_skip_reason "$old")"
    assert_contains "$reason" "cannot read the version" "a shellcheck that does not answer is skipped with a reason, not passed"
}

test_every_comment_follows_the_coded_comments_rules() {
    cd -- "$GSG_PROJECT" || return 1
    local -a files
    mapfile -t files < <(project_scripts; printf '%s\n' lib/scan/extract.awk tests/*.awk)
    [ "${#files[@]}" -ge 10 ] || { fail "only ${#files[@]} files found"; return 1; }
    run_cap awk -f tests/comment-rules.awk "${files[@]}"
    assert_rc 0 "one awk over every script"
    assert_empty "$OUT" "comment rules in every script"
}

# ^ invariant one awk run over many files prints what a run per file prints, each finding with its own file and line, no state crossing a file
test_one_comment_lint_run_over_several_files_reports_what_a_run_per_file_reports() {
    local d="$SANDBOX/lint-many" f want=""
    local rules="$GSG_PROJECT/tests/comment-rules.awk"
    mkdir -p -- "$d" || return 1
    printf '%s\n' 'x=1' >"$d/a-clean.sh"
    printf '%s\n' 'x=1' 'echo "never closed' >"$d/b-open-quote.sh"
    printf '%s\n' 'x=1' 'cat <<EOT' 'body' >"$d/c-open-heredoc.sh"
    printf '%s\n' '# free comment on line 1' 'y=2' '# ^ unknown tag here' >"$d/d-bad.sh"
    printf '%s\n' "echo 'open single" >"$d/e-open-single.sh"
    printf '%s\n' 'z=3 #glued trailing prose' >"$d/f-bad-after.sh"
    for f in "$d"/*.sh; do
        run_cap awk -f "$rules" "$f"
        assert_rc 0 "awk over $f"
        if [ -n "$OUT" ]; then want="$want${want:+$'\n'}$OUT"; fi
    done
    run_cap awk -f "$rules" "$d"/*.sh
    assert_rc 0 "awk over all files at once"
    assert_eq "$OUT" "$want" "one run reports what a run per file reports"
    assert_contains "$OUT" "$d/d-bad.sh:1: free comment" "the finding on line 1 of the file after open quotes and an open heredoc"
    assert_contains "$OUT" "$d/d-bad.sh:3: unknown tag" "the finding names its own line"
    assert_contains "$OUT" "$d/f-bad-after.sh:1: trailing comment" "the finding after a file that ends inside a single quote"
    assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 3 "three findings and nothing else"
}

GSG_LINT_MAX_CHARS=160

lint_case() {
    local name="$1" expect="$2"
    cat >"$SANDBOX/lint-$name.sh"
    run_cap awk -f "$GSG_PROJECT/tests/comment-rules.awk" "$SANDBOX/lint-$name.sh"
    assert_rc 0 "lint $name"
    if [ -n "$expect" ]; then
        assert_contains "$OUT" "$expect" "lint $name"
    else
        assert_empty "$OUT" "lint $name"
    fi
}

test_the_comment_lint_flags_each_planted_violation() {
    lint_case unknown-tag "unknown tag" <<'EOF'
x=1
# ^ note this tag is not in the vocabulary
EOF
    lint_case why-without-alternative "why needs" <<'EOF'
# ^ why we pick bash here
y=2
EOF
    lint_case trailing-after-quote "trailing comment" <<'EOF'
echo "a" >/dev/null # trailing prose after a quoted string
EOF
    lint_case trailing-glued "trailing comment" <<'EOF'
z=3 #glued trailing prose
EOF
    lint_case free-comment "free comment" <<'EOF'
# explains the obvious
EOF
    lint_case free-glued "free comment" <<'EOF'
#glued prose on its own line
EOF
    lint_case prose-glue "prose glue" <<'EOF'
# ^ hazard editing x => y but z
EOF
    lint_case colon-glue "colon glue" <<'EOF'
# ^ external tool: quirk
EOF
    lint_case order-without-sequence "order tag" <<'EOF'
# ^ order result is left in REPLY
EOF
    lint_case run-over-three "more than 3" <<'EOF'
# ^ hazard a => b
# ^ hazard c => d
# ^ hazard e => f
# ^ hazard g => h
EOF
    { printf '# ^ hazard '; printf 'x%.0s' $(seq 1 "$((GSG_LINT_MAX_CHARS + 10))"); printf ' => y\n'; } | lint_case too-long "longer than $GSG_LINT_MAX_CHARS"
}

test_the_comment_lint_passes_clean_code_with_hash_lookalikes() {
    lint_case clean "" <<'EOF'
#!/usr/bin/env bash
# shellcheck disable=SC2034
# ^ why a quoted hash, not a comment; "x # y" is data => never flagged
echo "a # b" 'c # d' $# ${#x} ${y%%[[:space:]]#*}
cat <<EOT
# not a comment inside a heredoc
x # still data
EOT
msg='multi
# line inside a single quote
'
case "$x" in '#'*) : ;; esac
EOF
}

# ^ invariant ts_line_count_findings FILE... prints "FILE has N lines" per file of 1000 lines or more, from one wc -l; rc 1 when wc cannot read a file
# ^ external wc -l prints a "total" line only when it is given more than one file
ts_line_count_findings() {
    local n name
    wc -l -- "$@" >"$SANDBOX/wc.out" 2>/dev/null || return 1
    while read -r n name; do
        if [ "$name" = total ] && [ "$#" -gt 1 ]; then continue; fi
        if [ "$n" -ge 1000 ]; then printf '%s has %s lines\n' "$name" "$n"; fi
    done <"$SANDBOX/wc.out"
}

test_the_line_count_check_reports_exactly_the_files_of_1000_lines_or_more() {
    local d="$SANDBOX/lines"
    mkdir -p -- "$d" || return 1
    seq 1 999 >"$d/a-short.sh" && seq 1 1000 >"$d/b-limit.sh" && seq 1 1001 >"$d/c-over.sh" && printf 'no newline' >"$d/d-none.sh" || return 1
    assert_eq "$(ts_line_count_findings "$d/a-short.sh" "$d/b-limit.sh" "$d/c-over.sh" "$d/d-none.sh")" \
        "$d/b-limit.sh has 1000 lines"$'\n'"$d/c-over.sh has 1001 lines" "several files: the total line is not a finding"
    assert_eq "$(ts_line_count_findings "$d/b-limit.sh")" "$d/b-limit.sh has 1000 lines" "one file prints no total line"
    assert_empty "$(ts_line_count_findings "$d/a-short.sh")" "999 lines pass"
    if ts_line_count_findings "$d/missing.sh" >/dev/null 2>&1; then fail "a file that cannot be counted must fail the check"; fi
}

test_no_source_file_reaches_1000_lines() {
    local line out
    local -a files
    cd -- "$GSG_PROJECT" || return 1
    mapfile -t files < <(project_scripts; printf '%s\n' lib/scan/extract.awk)
    [ "${#files[@]}" -ge 10 ] || { fail "only ${#files[@]} files found"; return 1; }
    out="$(ts_line_count_findings "${files[@]}")" || { fail "the line count could not run"; return 1; }
    while IFS= read -r line; do
        if [ -n "$line" ]; then fail "$line"; fi
    done <<<"$out"
}

test_the_exit_trap_is_set_before_the_work_dir_is_created() {
    cd -- "$GSG_PROJECT" || return 1
    local trap_line mktemp_line
    trap_line="$(grep -n '^trap cleanup EXIT' hooks/secret-scan | head -n 1 | cut -d: -f1)"
    mktemp_line="$(grep -n 'mktemp -d' hooks/secret-scan | head -n 1 | cut -d: -f1)"
    [ -n "$trap_line" ] && [ -n "$mktemp_line" ] || { fail "trap ($trap_line) or mktemp ($mktemp_line) not found"; return 0; }
    [ "$trap_line" -lt "$mktemp_line" ] || fail "trap at line $trap_line comes after mktemp at line $mktemp_line"
}

# ^ why a name or value the code defines is looked up in the code too, not in the docs alone; a rename or a new limit in the code fails the docs gate
# ^ invariant code_value FILE VAR prints the value of VAR=value at the start of a line of FILE (project-relative); rc 1 when missing or empty
code_value() {
    local v
    v="$(sed -n "s/^$2=\\([^ ]*\\).*/\\1/p" "$GSG_PROJECT/$1" | head -n 1)"
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# ^ invariant docs_tokens_in_code "DIR..." TOKEN... fails once for each TOKEN no file under any DIR holds (project-relative)
docs_tokens_in_code() {
    local dirs="$1" t
    shift
    cd -- "$GSG_PROJECT" || return 1
    for t in "$@"; do
        # shellcheck disable=SC2086
        grep -rqF -- "$t" $dirs || fail "[$t] is in the docs but no file of $dirs has it any more"
    done
}

# ^ why a prose gate, not a code-tied one; the scan tests (test_real.sh, test_inherited_config.sh) pin the UTF-16 behaviour, this pins the docs sentence
test_the_docs_name_utf16_as_unscanned() {
    cd -- "$GSG_PROJECT" || return 1
    grep -q 'UTF-16' docs/scan.md || fail "docs/scan.md does not say that UTF-16 text counts as binary and is not scanned"
}

# ^ why docs/exemptions.md and docs/scan.md, not docs/exemptions.md alone; core.bigFileThreshold and core.attributesFile are in docs/scan.md
test_the_docs_document_every_exemption_mechanism_and_its_verified_syntax() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    for needle in '# Exemptions' '.secret-scan-ignore' 'git ls-tree' 'regular file' 'reason is mandatory' 'WARNING' 'together exempt every tracked file' \
        '[extend] path' 'git commit --amend' 'GIT_LITERAL_PATHSPECS' 'does not load on its own' 'core.bigFileThreshold' \
        'core.attributesFile=/dev/null' 'GIT_NO_REPLACE_OBJECTS' 'git replace' \
        'trufflehog:ignore' 'gitleaks:allow' '.gitleaks.toml' '.gitleaksignore' '--gitleaks-ignore-path' 'useDefault = true' \
        'git config hook.git-secret-guard.enabled false' "GIT_CONFIG_PARAMETERS=\"'hook.git-secret-guard.enabled'='false'\"" '--no-verify'; do
        grep -qiF -- "$needle" docs/exemptions.md docs/scan.md || fail "docs/exemptions.md and docs/scan.md do not mention [$needle]"
    done
    grep -qiF 'absolute path' docs/install.md docs/doctor.md || fail "docs/install.md and docs/doctor.md do not mention [absolute path]"
    docs_tokens_in_code "hooks lib bin" GIT_LITERAL_PATHSPECS GIT_NO_REPLACE_OBJECTS core.bigFileThreshold core.attributesFile=/dev/null --gitleaks-ignore-path \
        trufflehog:ignore hook.git-secret-guard.enabled .secret-scan-ignore .gitleaksignore
}

test_the_docs_document_install_upgrade_and_uninstall() {
    cd -- "$GSG_PROJECT" || return 1
    local needle backup_bytes backup_files mib=1048576
    backup_bytes="$(code_value lib/install/install.sh GSG_BACKUP_MAX_BYTES)" || { fail "GSG_BACKUP_MAX_BYTES is not defined in lib/install/install.sh"; return 0; }
    backup_files="$(code_value lib/install/install.sh GSG_BACKUP_MAX_FILES)" || { fail "GSG_BACKUP_MAX_FILES is not defined in lib/install/install.sh"; return 0; }
    [ "$((backup_bytes % mib))" -eq 0 ] || { fail "GSG_BACKUP_MAX_BYTES ($backup_bytes) is not a whole number of MiB; the docs name it in MB"; return 0; }
    docs_tokens_in_code "hooks lib bin" --replace-hooks-path --remove-tools hooks-path-backup- GSG_TOOLS_BASE_URL GSG_TOOLS_LOCK SETSID_BIN TIMEOUT_BIN gsg-replaced-
    # shellcheck disable=SC2088,SC2016
    for needle in '# Install, upgrade and uninstall' 'bin/git-secret-guard install' 'git-secret-guard uninstall' 'git-secret-guard status' \
        '--replace-hooks-path' '--remove-tools' 'hooks-path-backup-' 'previous `core.hooksPath`' 'verbatim' \
        'tools.lock' 'SHA-256' 'GSG_TOOLS_BASE_URL' 'GSG_TOOLS_LOCK' 'still verified' \
        'XDG_DATA_HOME' 'XDG_STATE_HOME' '~/.local/bin' 'SETSID_BIN' 'TIMEOUT_BIN' \
        '/usr/bin/git' '2.52' 'ignores config hooks' 'Linux' 'macOS' 'nothing to do' \
        'gsg-replaced-' 'includeIf' 'XDG config' 'recorded value differs' "$((backup_bytes / mib)) MB" "$backup_bytes bytes" "more than $backup_files files" 'curlrc' \
        '%(prefix)/' '~user/' 'real directory' 'replaced in place' 'GIT_CONFIG_GLOBAL'; do
        grep -qF -- "$needle" docs/install.md || fail "docs/install.md does not mention [$needle]"
    done
    if grep -q 'Wire it manually' README.md docs/*.md; then fail "the manual wiring section is still in the docs"; fi
}

test_the_docs_document_doctor_and_the_timer() {
    cd -- "$GSG_PROJECT" || return 1
    local needle find_depth
    find_depth="$(code_value lib/inspect/doctor_repos.sh GSG_DOCTOR_FIND_DEPTH)" || { fail "GSG_DOCTOR_FIND_DEPTH is not defined in lib/inspect/doctor_repos.sh"; return 0; }
    docs_tokens_in_code "hooks lib bin" --roots --with-timer git-secret-guard-doctor.timer git-secret-guard-doctor.service OnCalendar=weekly SYSTEMCTL_BIN
    # shellcheck disable=SC2016
    for needle in '# Coverage report: `doctor`' 'git-secret-guard doctor' '--roots' 'node_modules' "$((find_depth - 1)) levels" '--git-common-dir' 'worktree' \
        'git hook list pre-commit' 'disabled in local config' 'command overridden' 'pre-commit install not run' 'read-only' \
        'machine:' 'repos with findings:' 'summary:' 'exit status 0' 'exit status 1' 'exit status 2' 'PROBLEM' 'WARNING' 'info' \
        '/usr/bin/git' '.secret-scan-ignore' 'catch-all' '.gitleaks.toml' 'tools_placed' 'core.hooksPath' 'GIT_NO_REPLACE_OBJECTS' \
        '--with-timer' 'git-secret-guard-doctor.timer' 'git-secret-guard-doctor.service' 'OnCalendar=weekly' 'systemctl --user enable --now' \
        'journalctl --user -u git-secret-guard-doctor.service' 'SYSTEMCTL_BIN' 'timer_installed' 'systemd-analyze --user verify' \
        'XDG_CONFIG_HOME' 'daemon-reload' 'systemctl --user disable --now'; do
        grep -qF -- "$needle" docs/doctor.md || fail "docs/doctor.md does not mention [$needle]"
    done
    if grep -q 'comes with a later story' README.md docs/*.md; then fail "the docs still say doctor is a later story"; fi
    if grep -q 'The doctor, in a later story' README.md docs/*.md; then fail "the docs still say the doctor is a later story in the exemptions section"; fi
}

test_the_docs_describe_the_launchd_agent_and_drop_the_macos_refusal() {
    cd -- "$GSG_PROJECT" || return 1
    local needle label
    label="$(code_value lib/core/state.sh GSG_LAUNCHD_LABEL)" || { fail "GSG_LAUNCHD_LABEL is not defined in lib/core/state.sh"; return 0; }
    docs_tokens_in_code "hooks lib bin" LAUNCHCTL_BIN doctor.log
    for needle in "$label.plist" 'LAUNCHCTL_BIN' 'launchctl bootstrap gui/' 'launchctl bootout' \
        'StartCalendarInterval' 'plutil -lint' 'doctor.log'; do
        grep -qF -- "$needle" docs/doctor.md || fail "docs/doctor.md does not mention [$needle]"
    done
    if grep -q -E 'launchd is not supported yet|--with-timer. is refused' README.md docs/*.md lib/cli/usage.md; then
        fail "a doc still says --with-timer is refused on macOS"
    fi
}

# ^ why a prose gate, not a code-tied one; tests/inspect/test_doctor_repos.sh pins the worktree behaviour, this pins the docs sentence
test_the_docs_say_a_linked_worktree_outside_the_roots_is_not_checked() {
    cd -- "$GSG_PROJECT" || return 1
    # shellcheck disable=SC2016
    grep -qF 'A linked worktree outside `--roots` is not checked' docs/doctor.md || fail "docs/doctor.md does not say that a linked worktree outside --roots is not checked"
}

test_the_docs_have_a_supported_platforms_chapter() {
    cd -- "$GSG_PROJECT" || return 1
    local needle git_ver git_sha
    read -r _ git_ver _ git_sha < <(awk '$1 == "git" && $3 == "source" { print; exit }' tools.lock)
    [ -n "$git_ver" ] && [ -n "$git_sha" ] || { fail "tools.lock has no line 'git VERSION source SHA256'"; return 0; }
    # shellcheck disable=SC2016
    for needle in '# Supported platforms' 'RHEL 9' 'Ubuntu 24.04' 'tests/platform/ubuntu.sh' 'ppa:git-core/ppa' \
        'sudo add-apt-repository ppa:git-core/ppa && sudo apt install git' 'sudo apt install jq' "git-$git_ver.tar.xz" \
        "$git_sha" 'NO_RUST=1' 'mawk' 'gawk' 'macOS arm64'; do
        grep -qF -- "$needle" docs/platforms.md || fail "docs/platforms.md does not mention [$needle] in its supported platforms"
    done
}

# ^ why two variables looked up in the code, not every needle; the rest is prose on the tested machine and the tools brew supplies, defined by no file
test_the_docs_state_exactly_what_macos_support_means() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    docs_tokens_in_code "hooks lib bin" BASH_BIN GNUBIN_DIR
    for needle in '# macOS (Homebrew)' 'macOS 26.7.1' 'x86_64' 'not tested' 'brew install' 'coreutils' 'util-linux' 'bash 4.4' 'launchd' \
        'BASH_BIN' 'GNUBIN_DIR' 'never installed with brew'; do
        grep -qF -- "$needle" docs/platforms.md || fail "docs/platforms.md does not state [$needle] for macOS"
    done
    for needle in README.md docs/install.md; do
        grep -qF -- 'Homebrew' "$needle" || fail "$needle does not mention Homebrew"
        if grep -qiF 'install` refuses it' "$needle"; then fail "$needle still says install refuses macOS"; fi
    done
    grep -qF -- 'macOS arm64' README.md || fail "README.md does not list macOS arm64"
}

test_the_docs_state_the_platform_test_trust_decisions() {
    cd -- "$GSG_PROJECT" || return 1
    local needle image ppa_fpr
    image="$(code_value tests/platform/ubuntu.sh IMAGE)" || { fail "IMAGE is not defined in tests/platform/ubuntu.sh"; return 0; }
    ppa_fpr="$(code_value lib/gitup/gitup_apt.sh GITUP_APT_PPA_FPR)" || { fail "GITUP_APT_PPA_FPR is not defined in lib/gitup/gitup_apt.sh"; return 0; }
    grep -qF -- 'RHEL 9-compatible (tested on Rocky Linux 9.7)' docs/platforms.md || fail "docs/platforms.md does not state the tested RPM distribution"
    for needle in "sha256:${image#*@sha256:}" \
        "$ppa_fpr" 'env -i' '/run/secrets' '--init' 'not version-pinned' 'Launchpad'; do
        grep -qF -- "$needle" docs/platform-testing.md || fail "docs/platform-testing.md does not state [$needle]"
    done
    if grep -qF "tested on the maintainer's machine" README.md docs/*.md; then fail "the docs still say the maintainer's machine instead of the distribution"; fi
}

# shellcheck disable=SC2016
test_the_docs_state_the_container_config_copy_and_ppa_rules() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    docs_tokens_in_code "tests/platform lib" 'add-apt-repository -y -n' /proc/self/mountinfo copy-file: hooks_dir 'podman rm -f'
    for needle in 'exact list of mount points' '/proc/self/mountinfo' 'volumes' 'devices' 'hooks_dir' 'containers.conf.d' '`copy-file:`' \
        'untracked files that are not ignored are copied' '.tmp/' '.analysis/' 'reports/' '.env*' 'add-apt-repository -y -n' '`podman rm -f` runs under `timeout`'; do
        grep -qF -- "$needle" docs/platform-testing.md || fail "docs/platform-testing.md does not state [$needle]"
    done
    if grep -qF 'no ignored local folder (`.tmp/`, `reports/`, `.env`) reaches the container' README.md docs/*.md; then
        fail "the docs still promise that nothing ignored reaches the container without saying the project .gitignore does it"
    fi
}

# shellcheck disable=SC2016
test_the_docs_separate_what_the_platform_run_enforces_from_what_it_trusts() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    docs_tokens_in_code "tests/platform lib" CONTAINERS_CONF default_mounts_file --host-ns fstype namespaces 'mounted more than once'
    for needle in '### What the platform run enforces' '### What the platform run trusts' 'CONTAINERS_CONF' 'ping_group_range' 'mounted more than once' \
        'fstype' 'namespaces' '--host-ns' 'reports/troubleshooting/' 'reports/bugs/' 'image digest' 'default_mounts_file' 'not compared'; do
        grep -qF -- "$needle" docs/platform-testing.md || fail "docs/platform-testing.md does not state [$needle]"
    done
    for needle in 'catch what they add' 'Probed with a real container: a `volumes` layer aborted' 'The system layers'; do
        if grep -qF -- "$needle" README.md docs/*.md; then fail "the docs still say [$needle], which overstates what is enforced"; fi
    done
}

test_the_docs_do_not_claim_the_hook_has_no_PATH_lookup() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    docs_tokens_in_code "hooks lib bin" realpath mktemp shebang
    # shellcheck disable=SC2016
    if grep -qF 'There is no `PATH` lookup' README.md docs/*.md; then fail "the docs still claim there is no PATH lookup"; fi
    for needle in 'shebang' 'exec-path' 'realpath' 'mktemp'; do
        grep -qF -- "$needle" docs/scan.md || fail "docs/scan.md does not mention [$needle] among what the hook finds through PATH"
    done
}

# ^ why 165, not the 160 of the code comments; the notes are prose with links and an index line may carry a path or two more
GSG_CLAUDE_MD_MAX_LINE_LENGTH=165
test_claude_md_has_no_line_over_the_length_limit() {
    local long
    long="$(awk -v max="$GSG_CLAUDE_MD_MAX_LINE_LENGTH" 'length($0) > max { printf "%d: %d  ", FNR, length($0) }' "$GSG_PROJECT/CLAUDE.md")" || return 1
    [ -z "$long" ] || fail "CLAUDE.md has lines over $GSG_CLAUDE_MD_MAX_LINE_LENGTH characters (line: length): $long"
}

GSG_README_MAX_LINES=135

test_the_readme_stays_a_short_overview() {
    cd -- "$GSG_PROJECT" || return 1
    local n
    n="$(wc -l <README.md)"
    [ "$n" -le "$GSG_README_MAX_LINES" ] || fail "README.md has $n lines, more than $GSG_README_MAX_LINES: move detail into docs/"
}

# ^ why exit 3 on an indented or ~~~ fence, not guess; a half-handled fence hides links and headings from the check
md_body() {
    awk '/^[ \t]+```/ || /^[ \t]*~~~/ { printf "%s:%d: unsupported fence (only backtick fences at column 0 are handled)\n", FILENAME, NR > "/dev/stderr"; exit 3 }
        /^```/ { fence = !fence; next } !fence' "$1"
}

# ^ external GitHub heading slug = lowercase, punctuation except _ - dropped, spaces to hyphens; test:test_the_markdown_link_check_flags_planted_breakage
md_slugs() {
    local body
    body="$(md_body "$1")" || return $?
    printf '%s\n' "$body" | awk '/^#+ / { t = $0; sub(/^#+ +/, "", t); t = tolower(t); gsub(/[^a-z0-9 _-]/, "", t); gsub(/ /, "-", t)
        n = seen[t]++; print (n ? t "-" n : t) }'
}

md_link_targets() {
    local body
    body="$(md_body "$1")" || return $?
    printf '%s\n' "$body" | { grep -o ']([^)]*)' || [ $? -eq 1 ]; } | sed 's/^](//; s/)$//'
}

# ^ why skip fenced code, web and mailto links, not check them; examples, external URLs != repository files
md_link_problems() {
    local md="$1" targets slugs target path anchor dest
    targets="$(md_link_targets "$md" 2>&1)" || { printf '%s\n' "$targets"; return 0; }
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        case "$target" in http://* | https://* | mailto:*) continue ;; esac
        path="${target%%#*}"
        anchor=""
        case "$target" in *'#'*) anchor="${target#*#}" ;; esac
        if [ -z "$path" ]; then dest="$md"; else dest="$(dirname -- "$md")/$path"; fi
        if [ ! -f "$dest" ]; then
            printf '%s: [%s] points at %s, which is not a file\n' "$md" "$target" "$dest"
        elif [ -n "$anchor" ]; then
            slugs="$(md_slugs "$dest" 2>&1)" || { printf '%s\n' "$slugs"; continue; }
            printf '%s\n' "$slugs" | grep -qxF -- "$anchor" || printf '%s: [%s] has no heading #%s in %s\n' "$md" "$target" "$anchor" "$dest"
        fi
    done <<<"$targets"
}

test_every_relative_markdown_link_in_the_docs_resolves() {
    cd -- "$GSG_PROJECT" || return 1
    local md links=0
    for md in README.md CLAUDE.md CONTRIBUTING.md docs/*.md; do
        [ -f "$md" ] || { fail "$md does not exist"; continue; }
        run_cap md_link_problems "$md"
        assert_empty "$OUT" "broken links in $md"
        links=$((links + $(md_link_targets "$md" | wc -l)))
    done
    [ "$links" -ge 10 ] || fail "only $links links outside code fences found in README.md, CLAUDE.md, CONTRIBUTING.md and docs/*.md"
    [ -f docs/install.md ] && [ -f docs/platforms.md ] && [ -f docs/scan.md ] && [ -f docs/exemptions.md ] && [ -f docs/doctor.md ] \
        || fail "one of the five docs files is missing"
}

# shellcheck disable=SC2016
test_the_markdown_link_check_flags_planted_breakage() {
    mkdir -p -- "$SANDBOX/md"
    printf '# A\n\n## Same\n\n## Same\n\n[ok](b.md#target-one) [self](#same-1) [web](https://example.com/x#y)\n[gone](nope.md) [bad](b.md#missing) [selfbad](#nowhere)\n```\n[fenced](also-missing.md)\n```\n' >"$SANDBOX/md/a.md"
    printf '# B\n\n## Target `One`\n' >"$SANDBOX/md/b.md"
    run_cap md_link_problems "$SANDBOX/md/a.md"
    assert_contains "$OUT" "[nope.md] points at" "missing file"
    assert_contains "$OUT" "[b.md#missing] has no heading #missing" "missing anchor in another file"
    assert_contains "$OUT" "[#nowhere] has no heading #nowhere" "missing anchor in the same file"
    assert_eq "$(printf '%s\n' "$OUT" | grep -c .)" 3 "only the three planted breaks; ok, repeated heading, web and fenced links pass"
    assert_eq "$(md_link_targets "$SANDBOX/md/a.md" | wc -l | tr -d ' ')" 6 "six links outside fences are counted, the fenced one is not"
    printf '# C\n\n  ```\n  [x](y.md)\n  ```\n' >"$SANDBOX/md/indented.md"
    printf '# D\n\n~~~\n[x](y.md)\n~~~\n' >"$SANDBOX/md/tilde.md"
    for f in indented tilde; do
        run_cap md_link_problems "$SANDBOX/md/$f.md"
        assert_contains "$OUT" "unsupported fence" "link check on a $f fence says so instead of half-handling it"
        run_cap md_slugs "$SANDBOX/md/$f.md"
        assert_rc 3 "heading slugs of a $f fence"
        assert_contains "$ERR" "unsupported fence" "slugs of a $f fence say so"
    done
}

hook_load_path() {
    printf '%s\n' hooks/secret-scan lib/core/common.sh lib/scan/extract.sh lib/scan/exempt.sh lib/scan/report.sh lib/scan/run-scanner.sh lib/scan/scanners/*.sh
}

# ^ invariant grep exits 0 (match) or 1 (no match) when it worked and 2 when it failed; $1 = the exit status, $2 = the name of the grep
grep_status_ok() { [ "$1" -le 1 ] || fail "$2 failed (exit $1)"; }

test_the_hook_never_looks_tools_up_on_PATH() {
    cd -- "$GSG_PROJECT" || return 1
    local -a files=(bin/git-secret-guard lib/scan/scanners/*.sh)
    local f matches others allowed
    # ^ invariant the one allowed lookup outside install.sh and brew.sh is this line of smartgit_tool in lib/integrations/smartgit/smartgit.sh, exactly once
    # shellcheck disable=SC2016
    local allowed_re='^lib/integrations/smartgit/smartgit\.sh:[0-9]+:[[:space:]]*REPLY="\$\(type -P "\$1"\)" \|\| REPLY=""$'
    for f in hooks/secret-scan lib/*/*.sh lib/integrations/*/*.sh; do
        if [ "$f" != lib/install/install.sh ] && [ "$f" != lib/platform/brew.sh ]; then files+=("$f"); fi
    done
    matches="$(grep -nE '(^|[;&|(`]|\$\()[[:space:]]*(command -v|which |type -P)' "${files[@]}")"
    grep_status_ok "$?" "the lookup scan"
    others="$(grep -vE "$allowed_re" <<<"$matches")"
    grep_status_ok "$?" "the filter grep"
    allowed="$(grep -cE "$allowed_re" <<<"$matches")"
    grep_status_ok "$?" "the counting grep"
    assert_empty "$others" "no PATH lookup of a tool outside lib/install/install.sh, lib/platform/brew.sh and the one line of smartgit_tool"
    assert_eq "$allowed" 1 "the smartgit_tool lookup is there exactly once"
}

# ^ invariant the pattern of the hook guard; the guard and the test of its coverage share this one definition
GSG_LIFECYCLE_RE='(install[a-z_]*|uninstall|autoupdate[a-z_]*|winupdate|schtasks|status|state|tools|hookspath|brew|wsl|gitup[a-z_]*|smartgit[a-z_]*|desktop_git[a-z_]*)\.sh|usage\.md'

test_the_hook_guard_pattern_names_every_install_time_library() {
    cd -- "$GSG_PROJECT" || return 1
    local f
    for f in lib/install/install*.sh lib/install/uninstall.sh lib/autoupdate/autoupdate*.sh lib/autoupdate/install_timer.sh lib/platform/winupdate.sh lib/platform/schtasks.sh \
        lib/gitup/gitup*.sh lib/integrations/smartgit/smartgit*.sh lib/integrations/desktop/desktop_git*.sh; do
        grep -qE "$GSG_LIFECYCLE_RE" <<<"source \"\$GSG_ROOT/$f\"" || fail "the hook guard does not name $f"
    done
}

test_the_hook_never_loads_the_install_time_libraries() {
    cd -- "$GSG_PROJECT" || return 1
    local -a files
    local rc
    mapfile -t files < <(hook_load_path)
    [ "${#files[@]}" -ge 8 ] || fail "only ${#files[@]} hook files found"
    grep -nE "$GSG_LIFECYCLE_RE" "${files[@]}"
    rc=$?
    assert_eq "$rc" 1 "the hook's load path never reaches a lifecycle library (grep exit 1 = no match)"
}

test_the_hook_never_loads_the_doctor_and_timer_libraries() {
    cd -- "$GSG_PROJECT" || return 1
    local -a files
    local rc
    mapfile -t files < <(hook_load_path)
    grep -nE '^[^#]*(doctor|doctor_repos|doctor_findings|timer|launchd)\.sh' "${files[@]}"
    rc=$?
    assert_eq "$rc" 1 "no code line of the hook's load path names a doctor or timer library (comments may anchor to them)"
}

# ^ why floors, not exact counts; a check over an empty list passes by itself, each dependency test asserts it saw this much of the real tree
DEP_MIN_HOOK_ENTRIES=8

# ^ security the hook runs no find (#25); a no-op one made the scan tree look empty and a token committed => bash globs decide
# ^ invariant command position only (line start, after ; & | ( { $( or a keyword or a wrapper) => the word find in a message is fine
GSG_FIND_WORDS='then|do|else|exec|command( -p)?|env|xargs|if|elif|while|until|time|timeout [0-9]+|nice'
# shellcheck disable=SC2016
GSG_FIND_CALL_RE='(^|[;&|(){`!\\]|\$\(|(^|[;&|(){`[:space:]])('"$GSG_FIND_WORDS"'))[[:space:]]*\\?find([[:space:]]|$)'

# shellcheck disable=SC2016
test_the_hook_runs_no_find_command() {
    cd -- "$GSG_PROJECT" || return 1
    local entries entry f
    local -a files=(hooks/secret-scan lib/core/common.sh)
    printf '%s\n' '    find "$work" -mindepth 1 -delete || {' 'first="$(find "$d" -type f -print -quit)" || return 1' 'x | xargs find .' 'if [ -n "$(command find .)" ]; then' \
        'if find . -type f; then' 'elif find . -type f; then' 'while find .; do' 'until find .; do' 'if ! find .; then' 'x=`find .`' 'timeout 5 find .' 'nice find .' \
        'time find .' '\find .' 'command -p find .' 'y) find . ;;' \
        | grep -cE "$GSG_FIND_CALL_RE" | grep -qx 16 || fail "the pattern does not catch the sixteen call forms it exists for"
    printf '%s\n' 'printf "%s: cannot find the Git LFS storage"' 'a message that says find a file' | grep -qE "$GSG_FIND_CALL_RE" \
        && fail "the pattern flags the word find inside a message"
    entries="$(dep_hook_entries)" || { fail "cannot read the hook lists out of lib/core/common.sh"; return 1; }
    while IFS= read -r entry; do files+=("lib/$entry"); done <<<"$entries"
    [ "${#files[@]}" -gt "$DEP_MIN_HOOK_ENTRIES" ] || fail "only ${#files[@]} hook files found"
    for f in "${files[@]}"; do
        case "$f" in *.toml) continue ;; esac
        grep -vE '^[[:space:]]*#' -- "$f" | grep -nE "$GSG_FIND_CALL_RE" && fail "$f runs find"
    done
    return 0
}

# ^ invariant the hook lists come out of lib/core/common.sh, the file the hook reads them from => this test holds no copy of them
# shellcheck disable=SC2016
dep_hook_entries() {
    bash -c 'source "$1/lib/core/common.sh" && printf "%s\n" "${GSG_HOOK_LIBS[@]}" "${GSG_HOOK_FILES[@]}"' _ "$GSG_PROJECT" </dev/null
}

test_the_hook_lists_name_only_files_under_lib_core_and_lib_scan() {
    cd -- "$GSG_PROJECT" || return 1
    local entries entry n=0
    entries="$(dep_hook_entries)" || { fail "cannot read the hook lists out of lib/core/common.sh"; return 1; }
    while IFS= read -r entry; do
        n=$((n + 1))
        case "$entry" in
            core/* | scan/*) ;;
            *) fail "the hook lists [$entry], outside lib/core/ and lib/scan/" ;;
        esac
        [ -f "lib/$entry" ] || fail "the hook lists [$entry] and lib/$entry is not a file"
    done <<<"$entries"
    [ "$n" -ge "$DEP_MIN_HOOK_ENTRIES" ] || fail "only $n hook list entries found"
}

DEP_MIN_CORE_FILES=4

# ^ invariant prints one "FILE TARGET" line per source of a library whose path the script spells out, TARGET relative to the project root
# ^ why a bare "$var" target is skipped, not resolved; it is a settings file or a loop variable, the hook lists and the bin list cover the loops
# shellcheck disable=SC2016
dep_source_pairs() {
    local f spelled target name
    for f in "$@"; do
        [ -r "$f" ] || { printf '%s is not readable\n' "$f" >&2; return 1; }
        while IFS= read -r spelled; do
            spelled="${spelled#*\"}"
            spelled="${spelled%\"}"
            case "$spelled" in
                *'$lib'*) continue ;;
                '$GSG_ROOT/lib/'*) target="lib/${spelled#'$GSG_ROOT/lib/'}" ;;
                '$SHARE/lib/'*) target="lib/${spelled#'$SHARE/lib/'}" ;;
                '$LIBROOT/'*) target="lib/${spelled#'$LIBROOT/'}" ;;
                '$LIBDIR/'*) target="${f%/*}/${spelled#'$LIBDIR/'}" ;;
                *)
                    if [[ $spelled =~ ^\$[A-Za-z_][A-Za-z_0-9]*$ ]]; then continue; fi
                    printf '%s sources a path this test cannot resolve: [%s]\n' "$f" "$spelled" >&2
                    return 1
                    ;;
            esac
            if [[ $target == *'$name'* ]]; then
                for name in trufflehog betterleaks; do printf '%s %s\n' "$f" "${target//'$name'/$name}"; done
            else
                printf '%s %s\n' "$f" "$target"
            fi
        done < <(grep -hoE '(^|[;&|{(])[[:space:]]*(source|\.)[[:space:]]+"[^"]+"' "$f")
    done
}

test_lib_core_sources_nothing_outside_lib_core() {
    cd -- "$GSG_PROJECT" || return 1
    local -a files=(lib/core/*.sh)
    local f target pairs
    { [ -f "${files[0]}" ] && [ "${#files[@]}" -ge "$DEP_MIN_CORE_FILES" ]; } || { fail "only ${#files[@]} files found under lib/core/"; return 1; }
    pairs="$(dep_source_pairs "${files[@]}")" || { fail "cannot read the library sources of lib/core/"; return 1; }
    while read -r f target; do
        [ -z "$f" ] && continue
        case "$target" in
            lib/core/*) ;;
            *) fail "$f sources $target, outside lib/core/" ;;
        esac
    done <<<"$pairs"
}

DEP_MIN_SOURCE_TARGETS=8
DEP_MIN_BIN_LIBS=20

test_every_library_source_target_exists() {
    cd -- "$GSG_PROJECT" || return 1
    local f target pairs n=0 name names
    local -a all
    mapfile -t all < <(printf '%s\n' bin/git-secret-guard hooks/secret-scan lib/*/*.sh lib/*/*/*.sh)
    pairs="$(dep_source_pairs "${all[@]}")" || { fail "cannot read the library sources of the shipped scripts"; return 1; }
    while read -r f target; do
        [ -z "$f" ] && continue
        n=$((n + 1))
        [ -f "$target" ] || fail "$f sources $target and it does not exist"
    done <<<"$pairs"
    [ "$n" -ge "$DEP_MIN_SOURCE_TARGETS" ] || fail "only $n source targets found"
    names="$(sed -n 's/^for lib in \(.*\); do$/\1/p' bin/git-secret-guard)"
    n=0
    for name in $names; do
        n=$((n + 1))
        [ -f "lib/$name.sh" ] || fail "bin/git-secret-guard loads lib/$name.sh and it does not exist"
    done
    [ "$n" -ge "$DEP_MIN_BIN_LIBS" ] || fail "only $n names found in the library list of bin/git-secret-guard"
}

DEP_MIN_CONTEXT_DIRS=8

test_no_file_sits_directly_in_lib() {
    cd -- "$GSG_PROJECT" || return 1
    local p dirs=0
    for p in lib/*; do
        if [ -d "$p" ]; then dirs=$((dirs + 1)); else fail "$p sits directly in lib/, every file belongs in a context folder"; fi
    done
    [ "$dirs" -ge "$DEP_MIN_CONTEXT_DIRS" ] || fail "only $dirs context folders under lib/"
}

TS_TOP_ALLOWED=" run.sh run.cmd fetch-test-tools.sh comment-rules.awk coverage.sh coverage.awk coverage-env.sh windows-skips.list macos-only.list herestring-bounded.list herestring-tokens.awk test-costs.list "
TS_MIN_TOP_FILES=8
TS_MIN_TOP_DIRS=10
TS_MIN_TEST_FILES=80
TS_MIN_TEST_FOLDERS=10
TS_MIN_SUPPORT_HELPERS=9
TS_MIN_SOURCE_LINES=100
TS_SOURCE_RE='^[[:space:]]*source[[:space:]]+"\$\(dirname -- "\$\{BASH_SOURCE\[0\]\}"\)/([^"]+)"[[:space:]]*$'

# ^ invariant ts_test_files prints every test_*.sh under tests/ at any depth, C-sorted; stubs/ and fixtures/ hold none
ts_test_files() { find tests -name 'test_*.sh' | LC_ALL=C sort; }

test_no_test_file_or_helper_sits_directly_in_tests() {
    cd -- "$GSG_PROJECT" || return 1
    local p dirs=0 tops=0
    for p in tests/*; do
        if [ -d "$p" ]; then
            dirs=$((dirs + 1))
        elif [[ $TS_TOP_ALLOWED == *" ${p#tests/} "* ]]; then
            tops=$((tops + 1))
        else
            fail "$p sits directly in tests/, a test belongs in its context folder and a helper in tests/support/ or its own folder"
        fi
    done
    [ "$tops" -ge "$TS_MIN_TOP_FILES" ] || fail "only $tops entry points found directly in tests/"
    [ "$dirs" -ge "$TS_MIN_TOP_DIRS" ] || fail "only $dirs folders found in tests/"
}

TS_PATH_SOURCE_RE='(^|[^[:alnum:]_])(source|\.)[[:space:]]+"[^"]*tests/([a-z0-9_/]+)/([A-Za-z0-9_.-]+)"'

# ^ invariant ts_check_path_sources FILE flags each source of a quoted path naming tests/FOLDER/NAME unless FOLDER is support or FILE's own folder
# ^ why stubs/ and fixtures/ get no exception, not a data allowance; nothing sources them, they are reached through the project root
# ^ why only double-quoted paths, not all quote forms; every source of a tests/ path in this tree is written so
ts_check_path_sources() {
    local f="$1" line dir own out
    [[ $f == tests/* ]] || { fail "ts_check_path_sources needs a path below tests/, got [$f]"; return 1; }
    own="${f#tests/}"
    if [[ $own == */* ]]; then own="${own%/*}"; else own=""; fi
    out="$(grep -E '(source|\.)[[:space:]]+"[^"]*tests/' -- "$f" || { [ "$?" -eq 1 ]; })" || { fail "cannot read $f"; return 1; }
    while IFS= read -r line; do
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line =~ $TS_PATH_SOURCE_RE ]] || continue
        dir="${BASH_REMATCH[3]}"
        if [ "$dir" != support ] && [ "$dir" != "$own" ]; then fail "$f sources tests/$dir/${BASH_REMATCH[4]}, outside tests/support/ and its own folder"; continue; fi
        [ -f "tests/$dir/${BASH_REMATCH[4]}" ] || fail "$f sources tests/$dir/${BASH_REMATCH[4]} and it does not exist"
    done <<<"$out"
}

# ^ why GSG_PROJECT as it is, not resolved again; tests/support/lib.sh set it with pwd -P, the same form as the folders resolved below
test_every_test_helper_source_resolves_to_tests_support_or_the_files_own_folder() {
    cd -- "$GSG_PROJECT" || return 1
    local f line lines rel own target n=0 support="$GSG_PROJECT/tests/support"
    local -a files helpers
    mapfile -t files < <(find tests -name '*.sh' -not -path 'tests/stubs/*' -not -path 'tests/fixtures/*' | LC_ALL=C sort)
    helpers=(tests/support/*.sh)
    [ "${#files[@]}" -ge "$TS_MIN_TEST_FILES" ] || { fail "only ${#files[@]} scripts found under tests/"; return 1; }
    [ -f "${helpers[0]}" ] && [ "${#helpers[@]}" -ge "$TS_MIN_SUPPORT_HELPERS" ] || fail "only ${#helpers[@]} helpers found in tests/support/"
    for f in "${files[@]}"; do
        ts_check_path_sources "$f"
        lines="$(grep -E '^[[:space:]]*(source|\.)[[:space:]].*BASH_SOURCE' -- "$f" || { [ "$?" -eq 1 ]; })" || { fail "cannot read $f"; continue; }
        [ -n "$lines" ] || continue
        own="$(cd -- "${f%/*}" && pwd -P)" || { fail "cannot resolve the folder of $f"; continue; }
        while IFS= read -r line; do
            n=$((n + 1))
            if ! [[ $line =~ $TS_SOURCE_RE ]]; then fail "$f has a source line this test cannot resolve: [$line]"; continue; fi
            rel="${BASH_REMATCH[1]}"
            target="$own"
            if [[ $rel == */* ]]; then target="$(cd -- "$own/${rel%/*}" 2>/dev/null && pwd -P)" || { fail "$f sources $rel and its folder does not exist"; continue; }; fi
            if [ "$target" != "$support" ] && [ "$target" != "$own" ]; then fail "$f sources $rel, outside tests/support/ and its own folder"; continue; fi
            [ -f "$target/${rel##*/}" ] || fail "$f sources $rel and it does not exist"
        done <<<"$lines"
    done
    [ "$n" -ge "$TS_MIN_SOURCE_LINES" ] || fail "only $n helper source lines found"
}

test_test_file_base_names_are_unique() {
    cd -- "$GSG_PROJECT" || return 1
    local -a files
    local base
    mapfile -t files < <(ts_test_files)
    [ "${#files[@]}" -ge "$TS_MIN_TEST_FILES" ] || { fail "only ${#files[@]} test files found"; return 1; }
    while read -r base; do
        [ -n "$base" ] || continue
        fail "the base name $base belongs to more than one test file: $(printf '%s\n' "${files[@]}" | grep -F -- "/$base" | tr '\n' ' ')"
    done < <(printf '%s\n' "${files[@]##*/}" | LC_ALL=C sort | uniq -d)
}

test_every_folder_holding_test_files_has_a_readme() {
    cd -- "$GSG_PROJECT" || return 1
    local -a files
    local f dir seen=" " n=0
    mapfile -t files < <(ts_test_files)
    for f in "${files[@]}"; do
        dir="${f%/*}"
        [[ $seen == *" $dir "* ]] && continue
        seen="$seen$dir "
        n=$((n + 1))
        [ -f "$dir/README.md" ] || fail "$dir holds test files ($f) and has no README.md"
    done
    [ "$n" -ge "$TS_MIN_TEST_FOLDERS" ] || fail "only $n folders holding test files found"
}

# ^ why a mirror of the real paths run by the real run.sh, not a copy of its glob; a file the runner cannot reach shows as absent from what ran
# ^ invariant each mirrored file prints its own path as a PASS line => $OUT lists exactly the files the runner reached
test_the_runners_no_argument_list_is_every_test_file_at_any_depth() {
    cd -- "$GSG_PROJECT" || return 1
    local root="$SANDBOX/mirror" f line
    local -a files
    local ran=" "
    mapfile -t files < <(ts_test_files)
    [ "${#files[@]}" -ge "$TS_MIN_TEST_FILES" ] || { fail "only ${#files[@]} test files found"; return 1; }
    mkdir -p -- "$root/tests" || return 1
    cp -- tests/run.sh "$root/tests/run.sh" || return 1
    printf '#!/usr/bin/env bash\nexit 0\n' >"$root/tests/fetch-test-tools.sh" || return 1
    chmod 755 "$root/tests/run.sh" "$root/tests/fetch-test-tools.sh" || return 1
    for f in "${files[@]}"; do
        mkdir -p -- "$root/${f%/*}" || return 1
        printf '#!/usr/bin/env bash\nprintf "PASS    %%s::t\\n" "%s"\n' "$f" >"$root/$f" || return 1
    done
    run_cap env -i "${GSG_ENV[@]}" bash "$root/tests/run.sh"
    assert_rc 0 "the mirror run"
    while IFS= read -r line; do
        case "$line" in "PASS    "*) line="${line#PASS    }"; ran="$ran${line%%::*} " ;; esac
    done <<<"$OUT"
    for f in "${files[@]}"; do
        [[ $ran == *" $f "* ]] || fail "$f is not in the no-argument list of tests/run.sh (it reaches test_*.sh one and two levels below tests/)"
    done
}

TS_MIN_WINDOWS_SKIPS=50
TS_MIN_MACOS_ONLY=20

# ^ invariant ts_list_entries LIST prints the file::test id of each entry (before the first space or bar), none for blank lines and comments
ts_list_entries() {
    local line id
    while IFS= read -r line; do
        case "$line" in '' | '#'*) continue ;; esac
        id="${line%% *}"
        printf '%s\n' "${id%%|*}"
    done <"$1"
}

test_every_skip_list_entry_names_an_existing_test() {
    cd -- "$GSG_PROJECT" || return 1
    local list id file fn path n
    local -a paths
    for list in "tests/windows-skips.list $TS_MIN_WINDOWS_SKIPS" "tests/macos-only.list $TS_MIN_MACOS_ONLY"; do
        n=0
        while read -r id; do
            n=$((n + 1))
            file="${id%%::*}"
            fn="${id#*::}"
            mapfile -t paths < <(find tests -name "$file.sh")
            if [ "${#paths[@]}" -ne 1 ]; then fail "${list%% *}: $id names ${#paths[@]} test files called $file.sh, expected one"; continue; fi
            path="${paths[0]}"
            grep -q -- "^${fn}() {" "$path" || fail "${list%% *}: $id names no function $fn in $path"
        done < <(ts_list_entries "${list%% *}")
        [ "$n" -ge "${list##* }" ] || fail "only $n entries found in ${list%% *}"
    done
}

HS_LIST_NAME=tests/herestring-bounded.list
HS_MIN_FOUND=40

# ^ invariant prints "path token" per occurrence of a here-string or here-doc in the bash scripts under root $1 (the hook, the CLI, lib/), C-sorted
hs_found() {
    (
        cd -- "$1" || exit 1
        shopt -s nullglob
        awk -f "$GSG_PROJECT/tests/herestring-tokens.awk" hooks/secret-scan bin/git-secret-guard lib/*/*.sh lib/*/*/*.sh
    ) >"$SANDBOX/hs.raw" || return 1
    LC_ALL=C sort "$SANDBOX/hs.raw"
}

# ^ invariant prints "path token" per token listed in file $1 (comment lines skipped), C-sorted; a token listed twice allows two occurrences
hs_allowed() {
    awk '!/^#/ && NF > 1 { for (i = 2; i <= NF; i++) print $1, $i }' "$1" >"$SANDBOX/hs.list.raw" || return 1
    LC_ALL=C sort "$SANDBOX/hs.list.raw"
}

# ^ invariant prints one line per pair found under root $1 and missing from list $2, after them one per listed pair no longer found; nothing = they agree
hs_problems() {
    local d="$SANDBOX"
    hs_found "$1" >"$d/hs.found" || return 1
    hs_allowed "$2" >"$d/hs.allowed" || return 1
    LC_ALL=C comm -23 "$d/hs.found" "$d/hs.allowed" >"$d/hs.new" || return 1
    LC_ALL=C comm -13 "$d/hs.found" "$d/hs.allowed" >"$d/hs.stale" || return 1
    awk -v list="$HS_LIST_NAME" '{ f = $1; sub(/^[^ ]* /, ""); printf "%s: %s is not in %s; Git for Windows bash 5.3 never returns on a here-string or here-doc of 65,537 to 65,664 bytes: pipe the value, use a file or split_lines, or list it with why it is bounded\n", f, $0, list }' "$d/hs.new" || return 1
    awk -v list="$HS_LIST_NAME" '{ f = $1; sub(/^[^ ]* /, ""); printf "%s: %s is listed in %s but no longer in the file; drop it\n", f, $0, list }' "$d/hs.stale"
}

test_here_strings_and_here_docs_in_the_product_are_only_the_listed_bounded_ones() {
    local out
    out="$(hs_problems "$GSG_PROJECT" "$GSG_PROJECT/$HS_LIST_NAME")" || fail "the here-string lint could not run"
    assert_empty "$out" "every here-string and here-doc in hooks/, bin/ and lib/ is a listed bounded one"
    [ "$(wc -l <"$SANDBOX/hs.found")" -ge "$HS_MIN_FOUND" ] || fail "fewer than $HS_MIN_FOUND here-strings found, the scan missed files"
}

# shellcheck disable=SC2016
test_the_here_string_lint_flags_a_new_one_and_a_stale_entry() {
    local root="$SANDBOX/hs-root" out
    mkdir -p -- "$root/hooks" "$root/bin" "$root/lib/core" || return 1
    : >"$root/hooks/secret-scan" && : >"$root/bin/git-secret-guard" || return 1
    printf '%s\n' 'read -r a <<<"$listed"' 'mapfile -t b <<<"$new"' '    # ^ hazard never <<<"$in_a_comment"' 'cat <<EOF' 'EOF' 'read -r c <<<"$listed"' >"$root/lib/core/x.sh" || return 1
    printf '%s\n' '# a comment' 'lib/core/x.sh <<<"$listed" <<<"$gone"' >"$SANDBOX/hs-planted.list" || return 1
    out="$(hs_problems "$root" "$SANDBOX/hs-planted.list")" || fail "the here-string lint could not run"
    assert_contains "$out" 'lib/core/x.sh: <<<"$new" is not in tests/herestring-bounded.list; Git for Windows bash 5.3 never returns' "a new here-string, with the rule"
    assert_contains "$out" 'lib/core/x.sh: <<EOF is not in' "a new here-doc"
    assert_contains "$out" 'lib/core/x.sh: <<<"$gone" is listed in tests/herestring-bounded.list but no longer in the file' "a stale entry"
    assert_contains "$out" 'lib/core/x.sh: <<<"$listed" is not in' "a second use of a token listed once"
    assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 4 "nothing else: the listed use and the comment pass"
}

test_systemctl_is_looked_up_only_in_lib_install_sh() {
    cd -- "$GSG_PROJECT" || return 1
    local found
    found="$(grep -rnE '(^|[;&|(`]|\$\()[[:space:]]*(command -v|which |type -a?P)[[:space:]]+systemctl' bin hooks lib | cut -d: -f1)"
    assert_eq "$found" "lib/install/install.sh" "exactly one lookup of systemctl in the shipped code, at install time"
}

test_launchctl_is_looked_up_only_in_lib_install_sh() {
    cd -- "$GSG_PROJECT" || return 1
    local found
    found="$(grep -rnE '(^|[;&|(`]|\$\()[[:space:]]*(command -v|which |type -a?P)[[:space:]]+launchctl' bin hooks lib | cut -d: -f1)"
    assert_eq "$found" "lib/install/install.sh" "exactly one lookup of launchctl in the shipped code, at install time"
}

# ^ why the version column of tools.lock, not a copy of it; a pin bump without updating THIRD_PARTY_LICENSES fails here
test_third_party_licenses_list_every_component_at_its_tools_lock_version() {
    cd -- "$GSG_PROJECT" || return 1
    local tool version rest needle
    assert_file THIRD_PARTY_LICENSES "THIRD_PARTY_LICENSES"
    while read -r tool version rest; do
        case "$tool" in '' | '#'*) continue ;; esac
        grep -F -- "$tool" THIRD_PARTY_LICENSES | grep -qF -- "$version" || fail "THIRD_PARTY_LICENSES has no row with $tool and $version from tools.lock"
    done <tools.lock
    for needle in 'AGPL-3.0' 'MIT' 'GPL-2.0' 'not redistributed' 'husky' 'typicode' 'Zachary Rice' 'Stephen Dolan' \
        'Heimdal' 'Kungliga Tekniska' 'NetBSD' 'Lucent' 'decNumber' \
        'https://github.com/trufflesecurity/trufflehog' 'https://github.com/betterleaks/betterleaks' 'https://github.com/jqlang/jq'; do
        grep -qF -- "$needle" THIRD_PARTY_LICENSES || fail "THIRD_PARTY_LICENSES does not mention [$needle]"
    done
}

# ^ why the maintainer link built from fragments, not a literal; test_no_tracked_file_names_an_internal_host_service_or_account searches this file
# shellcheck disable=SC2016
test_the_security_policy_and_the_maintainer_are_published() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    assert_file SECURITY.md "SECURITY.md"
    for needle in 'Report a vulnerability' 'security/advisories/new' 'do not open a public issue' '5 business days' 'current `main` branch' 'merged to `main`'; do
        grep -qiF -- "$needle" SECURITY.md || fail "SECURITY.md does not mention [$needle]"
    done
    if grep -qi 'latest release' SECURITY.md; then fail "SECURITY.md speaks of releases, and the repository has none"; fi
    grep -qF 'GSG_TEST_SERVICE_UNIT' CONTRIBUTING.md || fail "CONTRIBUTING.md does not document GSG_TEST_SERVICE_UNIT"
    grep -qF -- "[js""battig](https://github.com/js""battig)" README.md || fail "README.md does not name the maintainer as a link"
    for needle in 'DCO.txt' 'SECURITY.md' 'THIRD_PARTY_LICENSES'; do
        grep -qF -- "($needle)" README.md || fail "the README documentation table does not link $needle"
    done
}

# ^ why names built from fragments, not literals; this file is one of the tracked files being searched
test_no_tracked_file_names_an_internal_host_service_or_account() {
    cd -- "$GSG_PROJECT" || return 1
    local account="js""battig" service="cidx""-server" domain="lightspeedd""ms\\.com" hits
    hits="$(gitx ls-files -z -co --exclude-standard | xargs -0 grep -nIiE -- "$service|$domain" 2>/dev/null || true)"
    assert_empty "$hits" "no internal service unit or company domain"
    hits="$(gitx ls-files -z -co --exclude-standard | xargs -0 grep -nIi -- "$account" 2>/dev/null | grep -v '^README.md:' || true)"
    assert_empty "$hits" "the maintainer account appears only in README.md"
    hits="$(grep -ci -- "$account" README.md || true)"
    assert_eq "$hits" 1 "one mention of the account in README.md, the maintainer link"
}

test_the_project_tree_holds_no_credential_looking_literals() {
    [ -x "$REAL_BETTERLEAKS" ] || skip_test "betterleaks not found at $REAL_BETTERLEAKS"
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    local copy="$SANDBOX/tree-copy" report="$SANDBOX/tree-report.json" listing="$SANDBOX/tree-files.z"
    mkdir -p -- "$copy"
    # ^ why the files git lists, not the whole directory; gitignored tool data such as .code-indexer/ belongs to no commit
    (cd -- "$GSG_PROJECT" && gitx ls-files -z -co --exclude-standard) >"$listing" || return 1
    (cd -- "$GSG_PROJECT" && tar -cf - --null -T "$listing") | tar -xf - -C "$copy" || return 1
    [ -n "$(ls -A -- "$copy")" ] || { fail "the project tree copy is empty"; return 1; }
    run_cap "$REAL_BETTERLEAKS" dir "$copy" --redact --report-format json --report-path "$report" --no-banner --no-color
    assert_rc 0 "betterleaks over the project tree"
    run_cap env HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 \
        "$REAL_TRUFFLEHOG" filesystem "$copy" --results=verified,unverified,unknown --fail --no-verification --no-update --no-color
    assert_rc 0 "trufflehog over the project tree"
}

run_file_tests
