#!/usr/bin/env bash
# ^ invariant exit 0 all signed, 1 unsigned commits, 2 usage or git error; sign-off must equal the author, merge commits skipped
set -u
set -o pipefail

# ^ why a bound, not an unbounded walk; a range longer than this is refused, never truncated into a pass
max_commits="${DCO_MAX_COMMITS:-1000}"

die() {
    printf 'check-dco: %s\n' "$*" >&2
    exit 2
}

[ "$#" -eq 2 ] || die "usage: check-dco.sh BASE HEAD"
case "$max_commits" in '' | *[!0-9]*) die "DCO_MAX_COMMITS must be a number, got [$max_commits]" ;; esac

base="$1"
head="$2"
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "unknown base revision [$base]"
git rev-parse --verify --quiet "$head^{commit}" >/dev/null || die "unknown head revision [$head]"

commits="$(git rev-list --no-merges --reverse --max-count=$((max_commits + 1)) "$base..$head")" || die "git rev-list failed for $base..$head"

total=0
bad=0
offenders=""
while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    total=$((total + 1))
    if [ "$total" -gt "$max_commits" ]; then
        die "more than $max_commits commits in $base..$head; raise DCO_MAX_COMMITS to check them all"
    fi
    name="$(git log -1 --format=%an "$sha")" || die "cannot read the author of $sha"
    email="$(git log -1 --format=%ae "$sha")" || die "cannot read the author of $sha"
    subject="$(git log -1 --format=%s "$sha")" || die "cannot read the subject of $sha"
    short="$(git rev-parse --short "$sha")" || die "cannot shorten $sha"
    signoffs="$(git log -1 --format='%(trailers:key=Signed-off-by,valueonly,unfold)' "$sha")" || die "cannot read the trailers of $sha"
    found=0
    while IFS= read -r line; do
        if [ "$line" = "$name <$email>" ]; then
            found=1
            break
        fi
    done <<<"$signoffs"
    if [ "$found" -eq 0 ]; then
        bad=$((bad + 1))
        offenders+="  $short $subject  (author: $name <$email>)"$'\n'
    fi
done <<<"$commits"

if [ "$bad" -gt 0 ]; then
    printf 'check-dco: %d of %d commits lack a Signed-off-by line matching the author:\n%s' "$bad" "$total" "$offenders" >&2
    printf 'Fix the last commit: git commit --amend -s --no-edit\nFix a whole branch:  git rebase --signoff origin/main   (then push with --force-with-lease)\nSee CONTRIBUTING.md and DCO.txt.\n' >&2
    exit 1
fi
printf 'check-dco: %d commits checked, all signed off by their author\n' "$total"
