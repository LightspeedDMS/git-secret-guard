#!/usr/bin/env bash
# shellcheck shell=bash
# ^ security sandbox HOME/GIT_CONFIG_GLOBAL/GIT_CONFIG_NOSYSTEM => the real ~/.gitconfig (core.hooksPath) never applies
# ^ external tests drive GSG_TEST_GIT, default /usr/local/bin/git (2.56, config hooks); /usr/bin/git 2.52 on RHEL ignores them silently
set -u

GSG_PROJECT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
STUBS_DIR="$GSG_PROJECT/tests/stubs"
REAL_HOME="$HOME"
HOOK_NAME=git-secret-guard

# ^ external Linux keeps its old defaults byte for byte; macOS needs Homebrew's bash >= 4.4, GNU coreutils and util-linux (all keg paths from brew --prefix)
# ^ external the macOS real-scanner binaries are the pinned ones fetched by tests/fetch-test-tools.sh, never brew's latest release
# ^ external Apple's /usr/bin/git is 2.54.0 on macOS 26 and honours hook.<name>.command (probed); an older Apple git would ignore it; use GSG_TEST_GIT there
TEST_OS="$(uname -s)"
TEST_BREW_PREFIX=""
TEST_BASH="" TEST_GNUBIN=""
TEST_IS_WINDOWS=0 TEST_TASKKILL="" TEST_JQ_EXE="" TEST_SANDBOX_MIXED="" TEST_WORK_BASE=""
# shellcheck disable=SC2034
case "$TEST_OS" in
    MINGW64_NT-*)
        # ^ external Git for Windows has no setsid or /bin/jq; a native jq.exe needs the -b wrapper install writes, built per sandbox in sandbox_create
        TEST_IS_WINDOWS=1
        # ^ why this process only, not GSG_ENV; plain ln -s copies each file here, and the code under test must run without the help
        export MSYS=winsymlinks:sys
        TEST_TOOLS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/git-secret-guard-test-tools"
        GIT="${GSG_TEST_GIT:-$(type -P git)}"
        TEST_SYSTEM32="$(cygpath -u "${SYSTEMROOT:-C:\Windows}")/System32"
        TEST_BASE_PATH="${GIT%/*}:/usr/bin:/bin:$TEST_SYSTEM32"
        REAL_TRUFFLEHOG="${GSG_TEST_TRUFFLEHOG:-$TEST_TOOLS_CACHE/trufflehog.exe}"
        REAL_BETTERLEAKS="${GSG_TEST_BETTERLEAKS:-$TEST_TOOLS_CACHE/betterleaks.exe}"
        TEST_JQ_EXE="${GSG_TEST_JQ:-$TEST_TOOLS_CACHE/jq.exe}"
        if [ ! -x "$TEST_JQ_EXE" ]; then TEST_JQ_EXE="$(type -P jq)"; fi
        if [ ! -x "$TEST_JQ_EXE" ]; then
            printf 'tests need jq on Windows; run tests/fetch-test-tools.sh\n' >&2
            exit 2
        fi
        TEST_JQ=""
        TEST_SETSID=""
        TEST_TASKKILL="$TEST_SYSTEM32/taskkill"
        TEST_TIMEOUT="${GSG_TEST_TIMEOUT:-/usr/bin/timeout}"
        TEST_TRUE="${GSG_TEST_TRUE:-/usr/bin/true}"
        ;;
    Darwin)
        TEST_BREW_PREFIX="${GSG_TEST_BREW_PREFIX:-$(brew --prefix 2>/dev/null)}"
        if [ -z "$TEST_BREW_PREFIX" ]; then
            printf 'tests need Homebrew on macOS (brew not on PATH); install it or set GSG_TEST_BREW_PREFIX\n' >&2
            exit 2
        fi
        TEST_BASH="$TEST_BREW_PREFIX/bin/bash"
        TEST_GNUBIN="$TEST_BREW_PREFIX/opt/coreutils/libexec/gnubin"
        TEST_BASE_PATH="$TEST_BREW_PREFIX/bin:$TEST_GNUBIN:/usr/bin:/bin:/usr/sbin:/sbin:$TEST_BREW_PREFIX/opt/util-linux/bin"
        TEST_TOOLS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/git-secret-guard-test-tools"
        GIT="${GSG_TEST_GIT:-/usr/bin/git}"
        REAL_TRUFFLEHOG="${GSG_TEST_TRUFFLEHOG:-$TEST_TOOLS_CACHE/trufflehog}"
        REAL_BETTERLEAKS="${GSG_TEST_BETTERLEAKS:-$TEST_TOOLS_CACHE/betterleaks}"
        TEST_JQ="${GSG_TEST_JQ:-/usr/bin/jq}"
        if [ ! -x "$TEST_JQ" ]; then TEST_JQ="${GSG_TEST_JQ:-$TEST_BREW_PREFIX/bin/jq}"; fi
        TEST_SETSID="${GSG_TEST_SETSID:-$TEST_BREW_PREFIX/opt/util-linux/bin/setsid}"
        TEST_TIMEOUT="${GSG_TEST_TIMEOUT:-$TEST_GNUBIN/timeout}"
        TEST_TRUE="${GSG_TEST_TRUE:-/usr/bin/true}"
        ;;
    *)
        TEST_BASE_PATH="/usr/local/bin:/usr/bin:/bin"
        GIT="${GSG_TEST_GIT:-/usr/local/bin/git}"
        REAL_TRUFFLEHOG="${GSG_TEST_TRUFFLEHOG:-$REAL_HOME/.local/bin/trufflehog}"
        TEST_TOOLS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/git-secret-guard-test-tools"
        REAL_BETTERLEAKS="${GSG_TEST_BETTERLEAKS:-$REAL_HOME/.local/bin/betterleaks}"
        if [ -z "${GSG_TEST_BETTERLEAKS:-}" ] && [ -x "$TEST_TOOLS_CACHE/betterleaks" ]; then REAL_BETTERLEAKS="$TEST_TOOLS_CACHE/betterleaks"; fi
        TEST_JQ="${GSG_TEST_JQ:-/bin/jq}"
        TEST_SETSID="${GSG_TEST_SETSID:-/bin/setsid}"
        TEST_TIMEOUT="${GSG_TEST_TIMEOUT:-/bin/timeout}"
        TEST_TRUE="${GSG_TEST_TRUE:-/bin/true}"
        ;;
esac

# ^ external BSD sed wants a suffix argument after -i where GNU sed takes none; the suites use the GNU spelling and only this wrapper adapts it
if [ "$TEST_OS" = Darwin ]; then
    sed() {
        if [ "${1:-}" = -i ]; then
            shift
            command sed -i '' "$@"
        else
            command sed "$@"
        fi
    }
fi

# ^ why versions unlike any pin, not the pinned ones; the printed line proves the settings are read, not tools.lock
TEST_TF_VERSION=1.2.3
TEST_GL_VERSION=4.5.6

SANDBOX=""
SHARE=""
GSG_ENV=()
EXTRA_ENV=()
RC=0
OUT=""
ERR=""

sandbox_create() {
    mkdir -p -- "$REAL_HOME/.tmp" || exit 2
    SANDBOX="$(mktemp -d -- "$REAL_HOME/.tmp/git-secret-guard-tests.XXXXXX")" || exit 2
    SHARE="$SANDBOX/share"
    # ^ coupled hooks/secret-scan keeps its work dir under HOME on Windows whatever TMPDIR says (NTFS ignores chmod)
    TEST_WORK_BASE="$SANDBOX/tmp"
    # shellcheck disable=SC2034
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then TEST_WORK_BASE="$SANDBOX/home/.tmp"; fi
    mkdir -p -- "$SANDBOX/home" "$SANDBOX/tmp" "$SHARE" "$SANDBOX/repos" || exit 2
    # ^ invariant every test sees a plain Linux kernel through the WSL seams => no result depends on the machine running the suite (a test of WSL sets its own)
    printf '%s\n' "6.8.0-45-generic" >"$SANDBOX/wsl-kernel" || exit 2
    cp -r -- "$GSG_PROJECT/hooks" "$GSG_PROJECT/lib" "$SHARE/" || exit 2
    # ^ invariant jq on the sandbox PATH like a system jq elsewhere => install keeps it; a test wanting the download path removes it with lc_path_without
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then
        mkdir -p -- "$SANDBOX/jqbin" && cp -- "$TEST_JQ_EXE" "$SANDBOX/jqbin/jq.exe" || exit 2
        TEST_BASE_PATH="$SANDBOX/jqbin:$TEST_BASE_PATH"
    fi
    GSG_ENV=(
        HOME="$SANDBOX/home"
        GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
        GIT_CONFIG_NOSYSTEM=1
        TMPDIR="$SANDBOX/tmp"
        PATH="$REAL_HOME/.local/bin:$TEST_BASE_PATH"
        LC_ALL=C
        GIT_TERMINAL_PROMPT=0
        PYTHONUSERBASE="$REAL_HOME/.local"
        GSG_WSL_OSRELEASE="$SANDBOX/wsl-kernel"
        GSG_WSL_INTEROP="$SANDBOX/wsl-no-interop"
        GSG_WSL_SYSTEMD_DIR="$SANDBOX/wsl-no-systemd"
        GSG_SMARTGIT_INSTALL_DIRS="$SANDBOX/smartgit-no-installs"
        GSG_SMARTGIT_TOOL_DIR="$SANDBOX/pathbin"
    )
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then
        TEST_SANDBOX_MIXED="$(cygpath -m "$SANDBOX")" || exit 2
        GSG_ENV+=(SYSTEMROOT="$SYSTEMROOT")
        TEST_JQ="$SANDBOX/jq-binary-mode"
        printf '#!/usr/bin/env bash\nexec %q -b "$@"\n' "$TEST_JQ_EXE" >"$TEST_JQ" || exit 2
        chmod 755 "$TEST_JQ" || exit 2
    fi
    if [ -n "${GSG_TRACE_FILE:-}" ]; then
        GSG_ENV+=(BASH_ENV="$GSG_PROJECT/tests/coverage-env.sh" GSG_TRACE_FILE="$GSG_TRACE_FILE")
    fi
    : >"$SANDBOX/gitconfig"
    configure_hook
    env -i "${GSG_ENV[@]}" "$GIT" config --global user.name "Test User" || exit 2
    env -i "${GSG_ENV[@]}" "$GIT" config --global user.email "test@example.invalid" || exit 2
    env -i "${GSG_ENV[@]}" "$GIT" config --global commit.gpgsign false || exit 2
    env -i "${GSG_ENV[@]}" "$GIT" config --global init.defaultBranch main || exit 2
}

configure_hook() {
    local cmd="$SHARE/hooks/secret-scan"
    if [ -n "$TEST_BASH" ]; then cmd="'$TEST_BASH' '$cmd'"; fi
    env -i "${GSG_ENV[@]}" "$GIT" config --global "hook.$HOOK_NAME.event" pre-commit || exit 2
    env -i "${GSG_ENV[@]}" "$GIT" config --global "hook.$HOOK_NAME.command" "$cmd" || exit 2
}

sandbox_destroy() {
    if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
        chmod -R u+rwX -- "$SANDBOX" 2>/dev/null
        rm -rf -- "$SANDBOX"
    fi
}

# ^ coupled lib/install.sh:install_write_settings writes the same keys; the extra line (arg 4) may override SETSID_BIN/TIMEOUT_BIN
write_settings() {
    {
        printf 'TRUFFLEHOG_BIN=%q\n' "$1"
        printf 'BETTERLEAKS_BIN=%q\n' "$2"
        printf 'JQ_BIN=%q\n' "$3"
        if [ -n "$TEST_SETSID" ]; then printf 'SETSID_BIN=%q\n' "$TEST_SETSID"; fi
        if [ -n "$TEST_TASKKILL" ]; then printf 'TASKKILL_BIN=%q\n' "$TEST_TASKKILL"; fi
        printf 'TIMEOUT_BIN=%q\n' "$TEST_TIMEOUT"
        printf 'TRUFFLEHOG_VERSION=%q\n' "$TEST_TF_VERSION"
        printf 'BETTERLEAKS_VERSION=%q\n' "$TEST_GL_VERSION"
        if [ -n "$TEST_BASH" ]; then
            printf 'BASH_BIN=%q\n' "$TEST_BASH"
            printf 'GNUBIN_DIR=%q\n' "$TEST_GNUBIN"
        fi
        if [ -n "${4:-}" ]; then printf '%s\n' "$4"; fi
    } >"$SHARE/settings"
}

use_stubs() { write_settings "$STUBS_DIR/trufflehog" "$STUBS_DIR/betterleaks" "$TEST_JQ" "${1:-}"; }
use_real_tools() { write_settings "$REAL_TRUFFLEHOG" "$REAL_BETTERLEAKS" "$TEST_JQ" "${1:-}"; }

set_env() { EXTRA_ENV+=("$@"); }

gitx() { env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$GIT" "$@"; }

# ^ why normalise here, not in each assertion; native git answers C:/ paths and the tools keep .exe, the suites expect the POSIX spelling on every platform
# ^ invariant only the sandbox prefix and the three tool names change => a wrong path elsewhere still fails its assertion
windows_plain_text() {
    local text="$1" tool
    text="${text//$TEST_SANDBOX_MIXED/$SANDBOX}"
    for tool in trufflehog betterleaks jq; do text="${text//$tool.exe/$tool}"; done
    printf '%s' "$text"
}

# ^ external a path written into a git config file reaches native git unconverted, and it only understands C:/ there
git_path() { if [ "$TEST_IS_WINDOWS" -eq 1 ]; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

windows_or_plain() { if [ "$TEST_IS_WINDOWS" -eq 1 ]; then windows_plain_text "$1"; else printf '%s' "$1"; fi; }

run_cap() {
    "$@" >"$SANDBOX/.out" 2>"$SANDBOX/.err"
    RC=$?
    OUT="$(<"$SANDBOX/.out")"
    ERR="$(<"$SANDBOX/.err")"
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then
        OUT="$(windows_plain_text "$OUT")"
        ERR="$(windows_plain_text "$ERR")"
    fi
}

# shellcheck disable=SC2016
run_adapter() {
    mkdir -p -- "$3" || return 1
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c \
        'set -u; source "$1/lib/common.sh" && load_settings "$1/settings" && source "$1/lib/scanners/$2.sh" && "scan_$2" "$3" "$4"' \
        _ "$SHARE" "$1" "$2" "$3"
}

make_scan_tree() {
    mkdir -p -- "$1/src" && printf 'one\ntwo\nthree\n' >"$1/src/a.txt"
}

# ^ external GSG_TEST_SERVICE_UNIT names a systemd unit with a User= and a PATH= (a service environment, no TMPDIR); read only via systemctl show
service_prepare() {
    local unit="${GSG_TEST_SERVICE_UNIT:-}"
    [ -n "$unit" ] || skip_test "GSG_TEST_SERVICE_UNIT is not set (a systemd unit whose environment the service tests emulate)"
    command -v systemctl >/dev/null 2>&1 || skip_test "systemctl is not available"
    local show svc_user
    show="$(systemctl show "$unit" -p User -p Environment 2>/dev/null)" || skip_test "unit $unit cannot be read"
    svc_user="$(sed -n 's/^User=//p' <<<"$show")"
    SVC_PATH="$(sed -n 's/^Environment=\(.* \)\{0,1\}PATH=\([^ ]*\).*/\2/p' <<<"$show")"
    [ -n "$svc_user" ] && [ -n "$SVC_PATH" ] || skip_test "unit $unit has no User/PATH"
    [ "$svc_user" = "$(id -un)" ] || skip_test "unit $unit runs as $svc_user, not the current user"
    SVC_HOME="$(getent passwd "$svc_user" | cut -d: -f6)"
    [ -d "$SVC_HOME" ] || skip_test "no home directory for $svc_user"
    mkdir -p -- "$SANDBOX/passthrough-empty"
}

service_env() {
    # shellcheck disable=SC2034
    SVC_ENV=(HOME="$SVC_HOME" PATH="$SVC_PATH" GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig" GIT_CONFIG_NOSYSTEM=1
        GIT_CONFIG_PARAMETERS="'core.hooksPath'='$SANDBOX/passthrough-empty'" "${EXTRA_ENV[@]}")
    if [ -n "${GSG_TRACE_FILE:-}" ]; then
        SVC_ENV+=(BASH_ENV="$GSG_PROJECT/tests/coverage-env.sh" GSG_TRACE_FILE="$GSG_TRACE_FILE")
    fi
}

new_repo() {
    REPO="$SANDBOX/repos/$1"
    mkdir -p -- "$REPO" || return 1
    gitx init -q "$REPO" || return 1
    cd -- "$REPO" || return 1
}

# ^ why through the index, not ln -s; on Windows ln -s writes no symlink native git can see, and the refusal of a symlink at HEAD must be tested there too
stage_symlink() {
    local sha
    sha="$(printf '%s' "$1" | gitx hash-object -w --stdin)" || return 1
    gitx update-index --add --cacheinfo "120000,$sha,$2"
}

# ^ external Git Bash rewrites an argument like /old/hooks into a path under its install dir before native git sees it
git_literal_config() {
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then
        env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" MSYS_NO_PATHCONV=1 GIT_CONFIG_GLOBAL="$(git_path "$SANDBOX/gitconfig")" "$GIT" config "$@"
    else
        gitx config "$@"
    fi
}

stage_file() {
    local path="$1"
    shift
    mkdir -p -- "$(dirname -- "$path")" || return 1
    printf '%s\n' "$@" >"$path" || return 1
    gitx add -- "$path"
}

commit_cap() { run_cap gitx commit -q -m "${1:-test}" "${@:2}"; }

replace_head_with_permissive_commit() {
    local file="$1" branch real perm
    shift
    branch="$(gitx rev-parse --abbrev-ref HEAD)" || return 1
    real="$(gitx rev-parse HEAD)" || return 1
    gitx checkout -q -b permissive || return 1
    stage_file "$file" "$@" || return 1
    gitx commit -q --no-verify -m "permissive" || return 1
    perm="$(gitx rev-parse HEAD)" || return 1
    gitx checkout -q "$branch" || return 1
    gitx replace "$real" "$perm"
}

commit_ignore_file() {
    stage_file .secret-scan-ignore "$@" || return 1
    gitx commit -q --no-verify -m "add the ignore file"
}

# ^ security fake credentials are built from fragments => no committed file holds a credential-looking literal
# ^ see test:test_the_project_tree_holds_no_credential_looking_literals
fake_aws_key() { printf '%s%s' "AKI""A" "Q7XK2MWB4HZ5NR3T"; }
# ^ security generated per call, never a literal => nothing in the tree looks like a credential; 40 random alphanumerics clear the entropy filter
# ^ why || true, not a bare pipe; head closes it, tr gets SIGPIPE, pipefail would fail the call
fake_aws_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 40 || true; }
fake_github_token() { printf '%s%s' "ghp""_" "aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hJ6"; }
new_marker() { printf 'LEAKMARKER%s%s' "$$" "$RANDOM$RANDOM"; }
# ^ coupled lib/exempt.sh:betterleaks_probe_secret is the pre-flight probe value; the hook must never print it
probe_secret() { (source "$GSG_PROJECT/lib/common.sh" && source "$GSG_PROJECT/lib/exempt.sh" && betterleaks_probe_secret); }

fail() { printf '%s\n' "$*" >>"$SANDBOX/.fails"; return 1; }
assert_eq() { [ "$1" = "$2" ] || fail "${3:-assert_eq}: expected [$2] got [$1]"; }
assert_rc() { [ "$RC" -eq "$1" ] || fail "${2:-rc}: expected exit $1 got $RC (stderr: ${ERR:0:${GSG_TEST_DETAIL:-300}})"; }
assert_contains() { case "$1" in *"$2"*) return 0 ;; esac; fail "${3:-assert_contains}: missing [$2] in [${1:0:${GSG_TEST_DETAIL:-400}}]"; }
assert_not_contains() { case "$1" in *"$2"*) fail "${3:-assert_not_contains}: unexpected [$2]"; return 1 ;; esac; }
# ^ why here too, not only in run_cap; many assertions read git or the state directly
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then
    eval "$(declare -f assert_eq | sed '1s/assert_eq/posix_assert_eq/')"
    eval "$(declare -f assert_contains | sed '1s/assert_contains/posix_assert_contains/')"
    eval "$(declare -f assert_not_contains | sed '1s/assert_not_contains/posix_assert_not_contains/')"
    assert_eq() { posix_assert_eq "$(windows_plain_text "$1")" "$(windows_plain_text "$2")" "${3:-assert_eq}"; }
    assert_contains() { posix_assert_contains "$(windows_plain_text "$1")" "$(windows_plain_text "$2")" "${3:-assert_contains}"; }
    assert_not_contains() { posix_assert_not_contains "$(windows_plain_text "$1")" "$(windows_plain_text "$2")" "${3:-assert_not_contains}"; }
fi
assert_empty() { [ -z "$1" ] || fail "${2:-assert_empty}: got [${1:0:${GSG_TEST_DETAIL:-300}}]"; }
PASS_LINE_RE='^git-secret-guard: scanned ([0-9]+) files?, ([0-9]+) added lines? \(([^)]*)\): no findings(, [0-9]+ files? exempted)?, [0-9]+s$'
assert_pass_line_only() { [[ $1 =~ $PASS_LINE_RE ]] || fail "${2:-assert_pass_line_only}: expected exactly the pass line, got [${1:0:${GSG_TEST_DETAIL:-300}}]"; }
assert_file() { [ -e "$1" ] || fail "${2:-assert_file}: missing $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "${2:-assert_no_file}: unexpected $1"; }

skip_test() { printf '%s\n' "$1" >"$SANDBOX/.skip"; exit 0; }

# ^ external Apple Git 2.54.0 has no hook.<event>.enabled; its hook list never says event-disabled and the hook still runs
# ^ why probe the behaviour, not the version; git reports event-disabled only where it reads the key (docs/install.md#maintainer-notes)
# ^ invariant git_enabled_sections prints the hook.<section>.enabled sections the git under test honours, one per line; git-secret-guard always
git_enabled_sections() {
    local cfg="$SANDBOX/event-probe.config" repo="$SANDBOX/event-probe.git" listing
    printf '[hook "probe"]\n\tevent = pre-commit\n\tcommand = true\n[hook "pre-commit"]\n\tenabled = false\n' >"$cfg" || return 1
    # ^ external outside a repository git hook list does not report a disabled event; the probe runs in a bare repository (docs/install.md#maintainer-notes)
    listing="$(gitx init -q --bare "$(git_path "$repo")" 2>&1)" || {
        fail "the hook list probe could not make its repository: $listing"
        return 1
    }
    listing="$(set_env "GIT_CONFIG_GLOBAL=$(git_path "$cfg")" && gitx -C "$(git_path "$repo")" hook list pre-commit 2>&1)" || {
        fail "the hook list probe failed: $listing"
        return 1
    }
    printf 'git-secret-guard\n'
    case "$listing" in
        *event-disabled*) printf 'pre-commit\n' ;;
        *probe*)
            # ^ invariant only Linux must honour the key; git is built from source there, and a silent drop of the event halves would go unseen
            if [ "$TEST_OS" = Linux ]; then
                fail "the git under test lists the probe hook without event-disabled: $listing"
                return 1
            fi
            ;;
        *)
            fail "the hook list probe did not list the probe hook: $listing"
            return 1
            ;;
    esac
}

# ^ external measured on WSL 1 (build 20348); without systemd, systemd-analyze --user verify complains of a device monitor and a system bus, and exits 0
# ^ invariant analyze_blocked_reason [BIN] prints why BIN cannot verify anything here, nothing when it can; it verifies a good unit => a bad unit is no reason
analyze_blocked_reason() {
    local bin="${1:-systemd-analyze}" out
    case "${SANDBOX:-}" in /?*) ;; *) return 1 ;; esac
    mkdir -p -- "$SANDBOX/run-probe" && chmod 700 "$SANDBOX/run-probe" || return 1
    printf '[Service]\nExecStart=/usr/bin/true\n' >"$SANDBOX/run-probe/probe.service" || return 1
    out="$(env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$SANDBOX/run-probe" "$bin" --user verify "$SANDBOX/run-probe/probe.service" 2>&1)" || true
    case "$out" in
        *"Failed to start device monitor"* | *"Failed to connect to system bus"*) printf 'systemd-analyze cannot run here, no systemd (%s)' "${out%%$'\n'*}" ;;
    esac
}

no_leak() { assert_not_contains "$OUT" "$1" "stdout leak"; assert_not_contains "$ERR" "$1" "stderr leak"; }

# ^ invariant prints the reason tests/windows-skips.list gives for test $1 of file $2; rc 1 when it has none, or off Windows
windows_skip_reason() {
    local id reason
    if [ "$TEST_IS_WINDOWS" -ne 1 ]; then return 1; fi
    while IFS='|' read -r id reason; do
        id="${id%% *}"
        if [ "$id" = "$2::$1" ]; then
            printf '%s\n' "${reason# }"
            return 0
        fi
    done <"$GSG_PROJECT/tests/windows-skips.list"
    return 1
}

run_file_tests() {
    local file name fn status detail line reason
    local -a fns=()
    local passed=0 failed=0 skipped=0
    file="$(basename -- "${BASH_SOURCE[1]}")"
    sandbox_create
    trap sandbox_destroy EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mapfile -t fns < <(compgen -A function test_ | sort)
    for fn in "${fns[@]}"; do
        name="${file%.sh}::$fn"
        : >"$SANDBOX/.fails"
        rm -f -- "$SANDBOX/.skip"
        EXTRA_ENV=()
        configure_hook
        use_stubs
        if [ -n "${FILE_SKIP_REASON:-}" ]; then
            printf '%s\n' "$FILE_SKIP_REASON" >"$SANDBOX/.skip"
            status=0
        elif reason="$(windows_skip_reason "$fn" "${file%.sh}")"; then
            printf '%s\n' "$reason" >"$SANDBOX/.skip"
            status=0
        else
            (cd -- "$SANDBOX" && "$fn") >"$SANDBOX/.testout" 2>&1
            status=$?
        fi
        if [ -s "$SANDBOX/.skip" ]; then
            printf 'SKIPPED %s (%s)\n' "$name" "$(<"$SANDBOX/.skip")"
            skipped=$((skipped + 1))
        elif [ "$status" -eq 0 ] && [ ! -s "$SANDBOX/.fails" ]; then
            printf 'PASS    %s\n' "$name"
            passed=$((passed + 1))
        else
            printf 'FAIL    %s (test status %s)\n' "$name" "$status"
            while IFS= read -r line; do printf '          %s\n' "$line"; done <"$SANDBOX/.fails"
            while IFS= read -r detail; do printf '          | %s\n' "$detail"; done < <(tail -n 15 "$SANDBOX/.testout")
            failed=$((failed + 1))
        fi
    done
    [ "$failed" -eq 0 ]
}
