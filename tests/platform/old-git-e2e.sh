#!/usr/bin/env bash
set -u
# ^ external measures whether a commit made by a git older than 2.54 is scanned (#40, GitHub Desktop's bundled git); the argument is the old git
# ^ security the fake credential is built at runtime from fragments and never printed; the output is checked for its absence before any of it is shown

OLD_GIT="${1:-}"
LABEL="${2:-old git}"
PROJECT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)" || exit 2
pass=0
fail=0
RC=0
OUT=""

ok() {
    printf 'ok      %s\n' "$1"
    pass=$((pass + 1))
}
bad() {
    printf 'FAIL    %s\n' "$1"
    fail=$((fail + 1))
}
check() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
show() { printf '        | %s\n' "$@"; }
# shellcheck disable=SC2329
has() { [[ $OUT == *"$1"* ]]; }
fake_key() { printf '%s%s' "AKI""A" "Q7XK2MWB4HZ5NR3T"; }
version_of() { "$1" --version | sed 's/^git version //'; }
git_below_254() {
    local v
    v="$(version_of "$1")" || return 1
    [[ $v =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    [ "${BASH_REMATCH[1]}" -lt 2 ] || { [ "${BASH_REMATCH[1]}" -eq 2 ] && [ "${BASH_REMATCH[2]}" -lt 54 ]; }
}

# ^ invariant commit_with GIT DIR sets RC and OUT of a commit in a fresh repository DIR holding the fake key; rc 1 only when the repository cannot be prepared
commit_with() {
    local g="$1" d="$2"
    "$g" init -q "$d" && "$g" -C "$d" config user.name gsg && "$g" -C "$d" config user.email gsg@example.invalid || return 1
    printf 'aws_access_key_id = %s\n' "$(fake_key)" >"$d/a.txt" || return 1
    "$g" -C "$d" add a.txt || return 1
    OUT="$("$g" -C "$d" commit -q -m probe 2>&1)"
    RC=$?
}

finish() {
    printf 'E2E SUMMARY: %s passed, %s failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]
    exit
}

main() {
    local scratch home newgit d
    if [ ! -x "$OLD_GIT" ]; then
        printf 'usage: old-git-e2e.sh OLD_GIT [LABEL]\n' >&2
        exit 2
    fi
    scratch="$(mktemp -d)" || exit 2
    if [ -z "$scratch" ] || [[ $scratch != /* ]]; then
        bad "no absolute scratch directory"
        exit 2
    fi
    trap 'rm -rf -- "$scratch"' EXIT
    home="$scratch/home"
    mkdir -p "$home" || exit 2
    newgit="$(type -P git)"
    printf '== a commit made by %s: %s, with the hook installed for a git of %s\n' "$LABEL" "$("$OLD_GIT" --version)" "$("$newgit" --version)"
    check "the git under test is older than 2.54" git_below_254 "$OLD_GIT"
    check "the git that installs the hook is 2.54 or newer" test "$(git_below_254 "$newgit" && echo old || echo new)" = new
    OUT="$(HOME="$home" "$PROJECT/bin/git-secret-guard" install 2>&1)"
    RC=$?
    show "$(printf '%s' "$OUT" | tail -n 2)"
    check "install ends with exit 0" test "$RC" -eq 0
    check "the hook is configured in the global config the old git reads too" test -n "$(HOME="$home" "$OLD_GIT" config --global --get-regexp '^hook\.git-secret-guard\.' || true)"

    d="$scratch/new"
    commit_with "$newgit" "$d" || { bad "the repository for the new git cannot be prepared"; finish; }
    show "new git: exit $RC; $(printf '%s' "$OUT" | head -n 1 | cut -c1-120)"
    check "the new git blocks the commit with the fake key" test "$RC" -ne 0
    check "and the scan said so" has "potential secret"
    check "and the key is not in the output" test "${OUT//$(fake_key)/}" = "$OUT"

    d="$scratch/old"
    commit_with "$OLD_GIT" "$d" || { bad "the repository for the old git cannot be prepared"; finish; }
    show "old git: exit $RC; output: [$(printf '%s' "$OUT" | head -n 3 | cut -c1-120)]"
    check "the old git completes the commit with the fake key" test "$RC" -eq 0
    check "and prints no scan line and no finding" test -z "$OUT"
    check "the key is in the history of the old git's repository" test -n "$("$newgit" -C "$d" log --all -p 2>/dev/null | grep -F "$(fake_key)")"
    finish
}

main
