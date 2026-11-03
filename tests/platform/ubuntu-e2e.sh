#!/usr/bin/env bash
set -u
set -o pipefail

CHECKOUT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)" || exit 2
CLI="$CHECKOUT/bin/git-secret-guard"
INSTALLED="$HOME/.local/bin/git-secret-guard"
WORK="$(mktemp -d)" || exit 2
LOGS="$WORK/logs"
PASSED=0
FAILED=0
RC=0
ERRF=""
DEAD_PROXY=(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9)

# ^ order the trap is set before any file is made => the scratch tree goes on any exit
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p -- "$LOGS" "$WORK/roots" || exit 2

# ^ security the fake token is built from fragments at run time and never printed => this file holds no credential-looking literal
# ^ see tests/lib.sh:fake_github_token; the same value, the project rule for fixtures
fake_token() { printf '%s%s' "ghp""_" "aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF3hJ6"; }

report() {
    if [ "$1" = ok ]; then
        PASSED=$((PASSED + 1))
        printf 'PASS    %s\n' "$2"
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL    %s\n' "$2"
    fi
}

check_rc() {
    if [ "$RC" -eq "$1" ]; then report ok "$2"; else report bad "$2 (exit $RC, wanted $1; stderr: $(head -c 300 "$ERRF" | tr '\n\r' '  '))"; fi
}

check_has() {
    if grep -qF -- "$2" "$1"; then report ok "$3"; else report bad "$3 (missing [$2])"; fi
}

check_eq() {
    if [ "$1" = "$2" ]; then report ok "$3"; else report bad "$3 (got [$1], wanted [$2])"; fi
}

run() {
    local name="$1"
    shift
    ERRF="$LOGS/$name.err"
    "$@" >"$LOGS/$name.out" 2>"$ERRF" </dev/null
    RC=$?
}

pinned() { awk -v t="$1" '$1 == t { print $2; exit }' "$CHECKOUT/tools.lock"; }

commit_in() {
    local repo="$1" name="$2"
    shift 2
    run "$name" env "$@" git -C "$repo" commit -q -m "$name"
}

check_blocked_by_both() {
    check_rc 1 "$2: the commit is blocked"
    check_has "$LOGS/$1.err" "  trufflehog " "$2: trufflehog reported it"
    check_has "$LOGS/$1.err" "  betterleaks " "$2: betterleaks reported it"
}

# shellcheck source=lib/install.sh
source "$CHECKOUT/lib/install.sh" || exit 2
install_os_release_field /etc/os-release PRETTY_NAME
printf '== install E2E on %s (%s)\n' "$REPLY" "$(git --version)"
git config --global user.name "E2E User" && git config --global user.email "e2e@example.invalid" \
    && git config --global init.defaultBranch main && git config --global commit.gpgsign false || exit 2

run install "$CLI" install
check_rc 0 "install with real downloads"
check_has "$LOGS/install.out" "trufflehog $(pinned trufflehog): downloaded, verified against tools.lock and installed to $HOME/.local/bin/trufflehog" "trufflehog was downloaded and verified"
check_has "$LOGS/install.out" "betterleaks $(pinned betterleaks): downloaded, verified against tools.lock and installed to $HOME/.local/bin/betterleaks" "betterleaks was downloaded and verified"
# shellcheck disable=SC2016
run tver bash -c '"$1" --version 2>&1' _ "$HOME/.local/bin/trufflehog"
check_has "$LOGS/tver.out" "$(pinned trufflehog)" "the installed trufflehog reports the pin"
# shellcheck disable=SC2016
run gver bash -c '"$1" version 2>&1' _ "$HOME/.local/bin/betterleaks"
check_has "$LOGS/gver.out" "$(pinned betterleaks)" "the installed betterleaks reports the pin"
check_eq "$(git config --global --get hook.git-secret-guard.event)" pre-commit "the pre-commit event is configured"
check_eq "$(git config --global --get hook.git-secret-guard.command)" "$HOME/.local/share/git-secret-guard/hooks/secret-scan" "with the installed hook"
check_eq "$(grep -cE '^(JQ|SETSID|TIMEOUT)_BIN=/' "$HOME/.local/share/git-secret-guard/settings")" 3 "jq, setsid and timeout are recorded as absolute paths"

run status "$INSTALLED" status
check_rc 0 "status after install"
run doctor "$INSTALLED" doctor --roots "$WORK/roots"
check_rc 0 "doctor on the new machine"
check_has "$LOGS/doctor.out" "summary: 0 repos, 0 covered" "doctor ran its machine checks and found no repository"

git init -q "$WORK/repo" || exit 2
printf 'nothing secret here\n' >"$WORK/repo/clean.txt" || exit 2
git -C "$WORK/repo" add clean.txt || exit 2
commit_in "$WORK/repo" clean
check_rc 0 "a clean commit passes through the installed hook"
check_eq "$(sed -E 's/, [0-9]+s$/, Ns/' "$LOGS/clean.err")" \
    "git-secret-guard: scanned 1 file, 1 added line (trufflehog $(pinned trufflehog), betterleaks $(pinned betterleaks)): no findings, Ns" "and prints exactly the pass line"

printf 'one\ntoken = "%s"\n' "$(fake_token)" >"$WORK/repo/leak.txt" || exit 2
git -C "$WORK/repo" add leak.txt || exit 2
commit_in "$WORK/repo" leak "${DEAD_PROXY[@]}"
check_blocked_by_both leak "a fake token"
check_has "$LOGS/leak.err" "leak.txt:2" "the real file and line are named"

cp -a "$CHECKOUT" "$WORK/newer" && printf '9.9.9\n' >"$WORK/newer/VERSION" || exit 2
run upgrade "$WORK/newer/bin/git-secret-guard" install
check_rc 0 "upgrade from a newer checkout"
check_has "$LOGS/upgrade.out" "installed git-secret-guard 9.9.9" "the new version is installed"
check_has "$LOGS/upgrade.out" "kept $HOME/.local/bin/trufflehog (already at the pinned version)" "trufflehog was not downloaded again"
check_has "$LOGS/upgrade.out" "kept $HOME/.local/bin/betterleaks (already at the pinned version)" "betterleaks was not downloaded again"
run version "$INSTALLED" version
check_eq "$(<"$LOGS/version.out")" "git-secret-guard 9.9.9" "the CLI link reports the new version"
commit_in "$WORK/repo" leak2 "${DEAD_PROXY[@]}"
check_blocked_by_both leak2 "after the upgrade"

run uninstall "$INSTALLED" uninstall
check_rc 0 "uninstall"
check_eq "$(git config --global --get-regexp '^hook\.git-secret-guard\.' | wc -l)" 0 "the hook config is gone"
commit_in "$WORK/repo" leak3 "${DEAD_PROXY[@]}"
check_rc 0 "after uninstall the commit is no longer scanned"
run uninstall2 "$WORK/newer/bin/git-secret-guard" uninstall
check_rc 0 "a second uninstall"
check_has "$LOGS/uninstall2.out" "nothing to do, git-secret-guard is not installed" "says there is nothing to do"

token="$(fake_token)"
if grep -rqF -e "$token" -e "${token:4}" "$LOGS"; then report bad "a fake token value appears in the captured output"; else report ok "no output holds the token or its body"; fi

printf '\nE2E SUMMARY: %s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
