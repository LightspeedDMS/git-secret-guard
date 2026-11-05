#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

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
    printf '%s\n' hooks/secret-scan bin/git-secret-guard lib/*.sh lib/scanners/*.sh tests/*.sh tests/platform/*.sh tests/stubs/* .github/scripts/check-dco.sh
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
}

test_the_docs_document_install_upgrade_and_uninstall() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    # shellcheck disable=SC2088,SC2016
    for needle in '# Install, upgrade and uninstall' 'bin/git-secret-guard install' 'git-secret-guard uninstall' 'git-secret-guard status' \
        '--replace-hooks-path' '--remove-tools' 'hooks-path-backup-' 'previous `core.hooksPath`' 'verbatim' \
        'tools.lock' 'SHA-256' 'GSG_TOOLS_BASE_URL' 'GSG_TOOLS_LOCK' 'still verified' \
        'XDG_DATA_HOME' 'XDG_STATE_HOME' '~/.local/bin' 'SETSID_BIN' 'TIMEOUT_BIN' \
        '/usr/bin/git' '2.52' 'ignores config hooks' 'Linux' 'macOS' 'nothing to do' \
        'gsg-replaced-' 'includeIf' 'XDG config' 'recorded value differs' '50 MB' '10000 files' 'curlrc' \
        '%(prefix)/' '~user/' 'real directory' 'replaced in place' 'GIT_CONFIG_GLOBAL'; do
        grep -qF -- "$needle" docs/install.md || fail "docs/install.md does not mention [$needle]"
    done
    if grep -q 'Wire it manually' README.md docs/*.md; then fail "the manual wiring section is still in the docs"; fi
}

test_the_docs_document_doctor_and_the_timer() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    # shellcheck disable=SC2016
    for needle in '# Coverage report: `doctor`' 'git-secret-guard doctor' '--roots' 'node_modules' '31 levels' '--git-common-dir' 'worktree' \
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
    local needle
    for needle in 'com.lightspeeddms.git-secret-guard.doctor.plist' 'LAUNCHCTL_BIN' 'launchctl bootstrap gui/' 'launchctl bootout' \
        'StartCalendarInterval' 'plutil -lint' 'doctor.log'; do
        grep -qF -- "$needle" docs/doctor.md || fail "docs/doctor.md does not mention [$needle]"
    done
    if grep -q -E 'launchd is not supported yet|--with-timer. is refused' README.md docs/*.md lib/usage.md; then
        fail "a doc still says --with-timer is refused on macOS"
    fi
}

test_the_docs_say_a_linked_worktree_outside_the_roots_is_not_checked() {
    cd -- "$GSG_PROJECT" || return 1
    # shellcheck disable=SC2016
    grep -qF 'A linked worktree outside `--roots` is not checked' docs/doctor.md || fail "docs/doctor.md does not say that a linked worktree outside --roots is not checked"
}

test_the_docs_have_a_supported_platforms_chapter() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    # shellcheck disable=SC2016
    for needle in '# Supported platforms' 'RHEL 9' 'Ubuntu 24.04' 'tests/platform/ubuntu.sh' 'ppa:git-core/ppa' \
        'sudo add-apt-repository ppa:git-core/ppa && sudo apt install git' 'sudo apt install jq' 'git-2.56.0.tar.xz' \
        '26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3' 'NO_RUST=1' 'mawk' 'gawk' 'macOS arm64'; do
        grep -qF -- "$needle" docs/platforms.md || fail "docs/platforms.md does not mention [$needle] in its supported platforms"
    done
}

test_the_docs_state_exactly_what_macos_support_means() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
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
    local needle
    for needle in 'RHEL 9-compatible (tested on Rocky Linux 9.7)' 'sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852' \
        'F911AB184317630C59970973E363C90F8F1B6217' 'env -i' '/run/secrets' '--init' 'not version-pinned' 'Launchpad'; do
        grep -qF -- "$needle" docs/platforms.md || fail "docs/platforms.md does not state [$needle]"
    done
    if grep -qF "tested on the maintainer's machine" README.md docs/*.md; then fail "the docs still say the maintainer's machine instead of the distribution"; fi
}

# shellcheck disable=SC2016
test_the_docs_state_the_container_config_copy_and_ppa_rules() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    for needle in 'exact list of mount points' '/proc/self/mountinfo' 'volumes' 'devices' 'hooks_dir' 'containers.conf.d' '`copy-file:`' \
        'untracked files that are not ignored are copied' '.tmp/' '.analysis/' 'reports/' '.env*' 'add-apt-repository -y -n' '`podman rm -f` runs under `timeout`'; do
        grep -qF -- "$needle" docs/platforms.md || fail "docs/platforms.md does not state [$needle]"
    done
    if grep -qF 'no ignored local folder (`.tmp/`, `reports/`, `.env`) reaches the container' README.md docs/*.md; then
        fail "the docs still promise that nothing ignored reaches the container without saying the project .gitignore does it"
    fi
}

# shellcheck disable=SC2016
test_the_docs_separate_what_the_platform_run_enforces_from_what_it_trusts() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    for needle in '### What the platform run enforces' '### What the platform run trusts' 'CONTAINERS_CONF' 'ping_group_range' 'mounted more than once' \
        'fstype' 'namespaces' '--host-ns' 'reports/troubleshooting/' 'reports/bugs/' 'image digest' 'default_mounts_file' 'not compared'; do
        grep -qF -- "$needle" docs/platforms.md || fail "docs/platforms.md does not state [$needle]"
    done
    for needle in 'catch what they add' 'Probed with a real container: a `volumes` layer aborted' 'The system layers'; do
        if grep -qF -- "$needle" README.md docs/*.md; then fail "the docs still say [$needle], which overstates what is enforced"; fi
    done
}

test_the_docs_do_not_claim_the_hook_has_no_PATH_lookup() {
    cd -- "$GSG_PROJECT" || return 1
    local needle
    # shellcheck disable=SC2016
    if grep -qF 'There is no `PATH` lookup' README.md docs/*.md; then fail "the docs still claim there is no PATH lookup"; fi
    for needle in 'shebang' 'exec-path' 'realpath' 'mktemp'; do
        grep -qF -- "$needle" docs/scan.md || fail "docs/scan.md does not mention [$needle] among what the hook finds through PATH"
    done
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
    for md in README.md docs/*.md; do
        [ -f "$md" ] || { fail "$md does not exist"; continue; }
        run_cap md_link_problems "$md"
        assert_empty "$OUT" "broken links in $md"
        links=$((links + $(md_link_targets "$md" | wc -l)))
    done
    [ "$links" -ge 10 ] || fail "only $links links outside code fences found in README.md and docs/*.md"
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
    printf '%s\n' hooks/secret-scan lib/common.sh lib/extract.sh lib/exempt.sh lib/report.sh lib/run-scanner.sh lib/scanners/*.sh
}

test_the_hook_never_looks_tools_up_on_PATH() {
    cd -- "$GSG_PROJECT" || return 1
    local -a files=(bin/git-secret-guard lib/scanners/*.sh)
    local f rc
    for f in hooks/secret-scan lib/*.sh; do
        if [ "$f" != lib/install.sh ] && [ "$f" != lib/brew.sh ]; then files+=("$f"); fi
    done
    grep -nE '(^|[;&|(`]|\$\()[[:space:]]*(command -v|which |type -P)' "${files[@]}"
    rc=$?
    assert_eq "$rc" 1 "no PATH lookup of a tool outside lib/install.sh and lib/brew.sh (grep exit 1 = no match; 0 = found one, 2 = grep failed)"
}

test_the_hook_never_loads_the_install_time_libraries() {
    cd -- "$GSG_PROJECT" || return 1
    local -a files
    local rc
    mapfile -t files < <(hook_load_path)
    [ "${#files[@]}" -ge 8 ] || fail "only ${#files[@]} hook files found"
    grep -nE '(install|uninstall|status|state|tools|hookspath|brew|gitup[a-z_]*)\.sh|usage\.md' "${files[@]}"
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

test_systemctl_is_looked_up_only_in_lib_install_sh() {
    cd -- "$GSG_PROJECT" || return 1
    local found
    found="$(grep -rnE '(^|[;&|(`]|\$\()[[:space:]]*(command -v|which |type -a?P)[[:space:]]+systemctl' bin hooks lib | cut -d: -f1)"
    assert_eq "$found" "lib/install.sh" "exactly one lookup of systemctl in the shipped code, at install time"
}

test_launchctl_is_looked_up_only_in_lib_install_sh() {
    cd -- "$GSG_PROJECT" || return 1
    local found
    found="$(grep -rnE '(^|[;&|(`]|\$\()[[:space:]]*(command -v|which |type -a?P)[[:space:]]+launchctl' bin hooks lib | cut -d: -f1)"
    assert_eq "$found" "lib/install.sh" "exactly one lookup of launchctl in the shipped code, at install time"
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
        "$REAL_TRUFFLEHOG" filesystem "$copy" --results=verified,unknown --fail --no-update --no-color
    assert_rc 0 "trufflehog over the project tree"
}

run_file_tests
