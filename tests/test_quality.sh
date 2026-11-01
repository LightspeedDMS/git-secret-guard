#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

SHELLCHECK="${GSG_TEST_SHELLCHECK:-$REAL_HOME/.local/bin/shellcheck}"

# ^ why project_scripts omits tests/fixtures/husky/h, not shellcheck it; verbatim third-party sh script
project_scripts() {
    cd -- "$GSG_PROJECT" || return 1
    printf '%s\n' hooks/secret-scan bin/git-secret-guard lib/*.sh lib/scanners/*.sh tests/*.sh tests/platform/*.sh tests/stubs/*
}

test_shellcheck_reports_nothing_on_every_script() {
    [ -x "$SHELLCHECK" ] || skip_test "shellcheck not found at $SHELLCHECK"
    local -a files
    mapfile -t files < <(project_scripts)
    [ "${#files[@]}" -ge 10 ] || fail "only ${#files[@]} scripts found"
    cd -- "$GSG_PROJECT" || return 1
    run_cap "$SHELLCHECK" -x -s bash "${files[@]}"
    assert_rc 0 shellcheck
    assert_empty "$OUT$ERR" "zero warnings, including info"
}

test_every_comment_follows_the_coded_comments_rules() {
    cd -- "$GSG_PROJECT" || return 1
    local f
    local -a files
    mapfile -t files < <(project_scripts; printf '%s\n' lib/extract.awk tests/*.awk)
    for f in "${files[@]}"; do
        run_cap awk -f tests/comment-rules.awk "$f"
        assert_rc 0 "awk over $f"
        assert_empty "$OUT" "comment rules in $f"
    done
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

test_no_source_file_reaches_1000_lines() {
    local f n
    cd -- "$GSG_PROJECT" || return 1
    while IFS= read -r f; do
        n="$(wc -l <"$f")"
        [ "$n" -lt 1000 ] || fail "$f has $n lines"
    done < <(project_scripts; printf '%s\n' lib/extract.awk)
}

test_the_exit_trap_is_set_before_the_work_dir_is_created() {
    cd -- "$GSG_PROJECT" || return 1
    local trap_line mktemp_line
    trap_line="$(grep -n '^trap cleanup EXIT' hooks/secret-scan | head -n 1 | cut -d: -f1)"
    mktemp_line="$(grep -n 'mktemp -d' hooks/secret-scan | head -n 1 | cut -d: -f1)"
    [ -n "$trap_line" ] && [ -n "$mktemp_line" ] || { fail "trap ($trap_line) or mktemp ($mktemp_line) not found"; return 0; }
    [ "$trap_line" -lt "$mktemp_line" ] || fail "trap at line $trap_line comes after mktemp at line $mktemp_line"
}

test_the_readme_names_utf16_as_unscanned() {
    cd -- "$GSG_PROJECT" || return 1
    grep -q 'UTF-16' README.md || fail "README.md does not say that UTF-16 text counts as binary and is not scanned"
}

test_the_readme_documents_every_exemption_mechanism_and_its_verified_syntax() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    for needle in '## Exemptions' '.secret-scan-ignore' 'git ls-tree' 'regular file' 'reason is mandatory' 'WARNING' 'together exempt every tracked file' \
        '[extend] path' 'git commit --amend' 'GIT_LITERAL_PATHSPECS' 'does not load on its own' 'absolute path' 'core.bigFileThreshold' \
        'core.attributesFile=/dev/null' 'GIT_NO_REPLACE_OBJECTS' 'git replace' \
        'trufflehog:ignore' 'gitleaks:allow' '.gitleaks.toml' '.gitleaksignore' '--gitleaks-ignore-path' 'useDefault = true' \
        'git config hook.git-secret-guard.enabled false' "GIT_CONFIG_PARAMETERS=\"'hook.git-secret-guard.enabled'='false'\"" '--no-verify'; do
        grep -qiF -- "$needle" README.md || fail "README.md does not mention [$needle]"
    done
}

test_the_readme_documents_install_upgrade_and_uninstall() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    # shellcheck disable=SC2088,SC2016
    for needle in '## Install, upgrade and uninstall' 'bin/git-secret-guard install' 'git-secret-guard uninstall' 'git-secret-guard status' \
        '--replace-hooks-path' '--remove-tools' 'hooks-path-backup-' 'previous `core.hooksPath`' 'verbatim' \
        'tools.lock' 'SHA-256' 'GSG_TOOLS_BASE_URL' 'GSG_TOOLS_LOCK' 'still verified' \
        'XDG_DATA_HOME' 'XDG_STATE_HOME' '~/.local/bin' 'SETSID_BIN' 'TIMEOUT_BIN' \
        '/usr/bin/git' '2.52' 'ignores config hooks' 'Linux' 'macOS' 'nothing to do' \
        'gsg-replaced-' 'includeIf' 'XDG config' 'recorded value differs' '50 MB' '10000 files' 'curlrc' \
        '%(prefix)/' '~user/' 'real directory' 'replaced in place' 'GIT_CONFIG_GLOBAL'; do
        grep -qF -- "$needle" README.md || fail "README.md does not mention [$needle]"
    done
    if grep -q 'Wire it manually' README.md; then fail "the manual wiring section is still in README.md"; fi
}

test_the_readme_documents_doctor_and_the_timer() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    # shellcheck disable=SC2016
    for needle in '## Coverage report: `doctor`' 'git-secret-guard doctor' '--roots' 'node_modules' 'three levels' '--git-common-dir' 'worktree' \
        'git hook list pre-commit' 'disabled in local config' 'command overridden' 'pre-commit install not run' 'read-only' \
        'machine:' 'repos with findings:' 'summary:' 'exit status 0' 'exit status 1' 'exit status 2' 'PROBLEM' 'WARNING' 'info' \
        '/usr/bin/git' '.secret-scan-ignore' 'catch-all' '.gitleaks.toml' 'tools_placed' 'core.hooksPath' 'GIT_NO_REPLACE_OBJECTS' \
        '--with-timer' 'git-secret-guard-doctor.timer' 'git-secret-guard-doctor.service' 'OnCalendar=weekly' 'systemctl --user enable --now' \
        'journalctl --user -u git-secret-guard-doctor.service' 'SYSTEMCTL_BIN' 'timer_installed' 'systemd-analyze --user verify' \
        'XDG_CONFIG_HOME' 'daemon-reload' 'systemctl --user disable --now'; do
        grep -qF -- "$needle" README.md || fail "README.md does not mention [$needle]"
    done
    if grep -q 'comes with a later story' README.md; then fail "README.md still says doctor is a later story"; fi
    if grep -q 'The doctor, in a later story' README.md; then fail "README.md still says the doctor is a later story in the exemptions section"; fi
}

test_the_readme_says_a_linked_worktree_outside_the_roots_is_not_checked() {
    cd -- "$GSG_PROJECT" || return 1
    # shellcheck disable=SC2016
    grep -qF 'A linked worktree outside `--roots` is not checked' README.md || fail "README.md does not say that a linked worktree outside --roots is not checked"
}

test_the_readme_has_a_supported_platforms_section() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    # shellcheck disable=SC2016
    for needle in '## Supported platforms' 'RHEL 9' 'Ubuntu 24.04' 'tests/platform/ubuntu.sh' 'ppa:git-core/ppa' \
        'sudo add-apt-repository ppa:git-core/ppa && sudo apt install git' 'sudo apt install jq' 'git-2.56.0.tar.xz' \
        '26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3' 'NO_RUST=1' 'mawk' 'gawk' 'macOS is not supported yet'; do
        grep -qF -- "$needle" README.md || fail "README.md does not mention [$needle] in its supported platforms"
    done
}

test_the_readme_states_the_platform_test_trust_decisions() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    for needle in 'RHEL 9-compatible (tested on Rocky Linux 9.7)' 'sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852' \
        'F911AB184317630C59970973E363C90F8F1B6217' 'env -i' '/run/secrets' '--init' 'not version-pinned' 'Launchpad'; do
        grep -qF -- "$needle" README.md || fail "README.md does not state [$needle]"
    done
    if grep -qF "tested on the maintainer's machine" README.md; then fail "README.md still says the maintainer's machine instead of the distribution"; fi
}

# shellcheck disable=SC2016
test_the_readme_states_the_container_config_copy_and_ppa_rules() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    for needle in 'exact list of mount points' '/proc/self/mountinfo' 'volumes' 'devices' 'hooks_dir' 'containers.conf.d' '`copy-file:`' \
        'untracked files that are not ignored are copied' '.tmp/' '.analysis/' 'reports/' '.env*' 'add-apt-repository -y -n' '`podman rm -f` runs under `timeout`'; do
        grep -qF -- "$needle" README.md || fail "README.md does not state [$needle]"
    done
    if grep -qF 'no ignored local folder (`.tmp/`, `reports/`, `.env`) reaches the container' README.md; then
        fail "README.md still promises that nothing ignored reaches the container without saying the project .gitignore does it"
    fi
}

# shellcheck disable=SC2016
test_the_readme_separates_what_the_platform_run_enforces_from_what_it_trusts() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    for needle in '#### What the platform run enforces' '#### What the platform run trusts' 'CONTAINERS_CONF' 'ping_group_range' 'mounted more than once' \
        'fstype' 'namespaces' '--host-ns' 'reports/troubleshooting/' 'reports/bugs/' 'image digest' 'default_mounts_file' 'not compared'; do
        grep -qF -- "$needle" README.md || fail "README.md does not state [$needle]"
    done
    for needle in 'catch what they add' 'Probed with a real container: a `volumes` layer aborted' 'The system layers'; do
        if grep -qF -- "$needle" README.md; then fail "README.md still says [$needle], which overstates what is enforced"; fi
    done
}

test_the_readme_does_not_claim_the_hook_has_no_PATH_lookup() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    # shellcheck disable=SC2016
    if grep -qF 'There is no `PATH` lookup' README.md; then fail "README.md still claims there is no PATH lookup"; fi
    for needle in 'shebang' 'exec-path' 'realpath' 'mktemp'; do
        grep -qF -- "$needle" README.md || fail "README.md does not mention [$needle] among what the hook finds through PATH"
    done
}

hook_load_path() {
    printf '%s\n' hooks/secret-scan lib/common.sh lib/extract.sh lib/exempt.sh lib/report.sh lib/run-scanner.sh lib/scanners/*.sh
}

test_the_hook_never_looks_tools_up_on_PATH() {
    cd -- "$GSG_PROJECT" || return 1
    local -a files=(bin/git-secret-guard lib/scanners/*.sh)
    local f rc
    for f in hooks/secret-scan lib/*.sh; do
        if [ "$f" != lib/install.sh ]; then files+=("$f"); fi
    done
    grep -nE '(^|[;&|(`]|\$\()[[:space:]]*(command -v|which |type -P)' "${files[@]}"
    rc=$?
    assert_eq "$rc" 1 "no PATH lookup of a tool outside lib/install.sh (grep exit 1 = no match; 0 = found one, 2 = grep failed)"
}

test_the_hook_never_loads_the_install_time_libraries() {
    cd -- "$GSG_PROJECT" || return 1
    local -a files
    local rc
    mapfile -t files < <(hook_load_path)
    [ "${#files[@]}" -ge 8 ] || fail "only ${#files[@]} hook files found"
    grep -nE '(install|uninstall|status|state|tools|hookspath)\.sh|usage\.md' "${files[@]}"
    rc=$?
    assert_eq "$rc" 1 "the hook's load path never reaches a lifecycle library (grep exit 1 = no match)"
}

test_the_hook_never_loads_the_doctor_and_timer_libraries() {
    cd -- "$GSG_PROJECT" || return 1
    local -a files
    local rc
    mapfile -t files < <(hook_load_path)
    grep -nE '^[^#]*(doctor|doctor_repos|timer)\.sh' "${files[@]}"
    rc=$?
    assert_eq "$rc" 1 "no code line of the hook's load path names a doctor or timer library (comments may anchor to them)"
}

test_systemctl_is_looked_up_only_in_lib_install_sh() {
    cd -- "$GSG_PROJECT" || return 1
    local found
    found="$(grep -rnE '(^|[;&|(`]|\$\()[[:space:]]*(command -v|which |type -a?P)[[:space:]]+systemctl' bin hooks lib | cut -d: -f1)"
    assert_eq "$found" "lib/install.sh" "exactly one lookup of systemctl in the shipped code, at install time"
}

test_the_project_tree_holds_no_credential_looking_literals() {
    [ -x "$REAL_GITLEAKS" ] || skip_test "gitleaks not found at $REAL_GITLEAKS"
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    local copy="$SANDBOX/tree-copy" report="$SANDBOX/tree-report.json"
    mkdir -p -- "$copy"
    (cd -- "$GSG_PROJECT" && tar --exclude=./.git -cf - .) | tar -xf - -C "$copy" || return 1
    run_cap "$REAL_GITLEAKS" dir "$copy" --redact --report-format json --report-path "$report" --no-banner --no-color
    assert_rc 0 "gitleaks over the project tree"
    run_cap env HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 \
        "$REAL_TRUFFLEHOG" filesystem "$copy" --results=verified,unknown --fail --no-update --no-color
    assert_rc 0 "trufflehog over the project tree"
}

run_file_tests
