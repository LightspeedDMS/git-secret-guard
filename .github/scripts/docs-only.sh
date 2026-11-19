#!/usr/bin/env bash
# ^ invariant usage PATHS_FILE (git diff --name-only --no-renames output); exit 0 docs only, 1 not (path or reason printed), 2 usage error
# ^ invariant docs only = one path or more, each ending in .md, none lib/cli/usage.md (CLI help the tests read); git-quoted path = not docs
set -u
set -o pipefail

if [ "$#" -ne 1 ]; then
    printf 'usage: docs-only.sh PATHS_FILE\n' >&2
    exit 2
fi
paths="$1"
if [ ! -r "$paths" ] || [ -d "$paths" ]; then
    printf 'docs-only: cannot read %s\n' "$paths" >&2
    exit 2
fi

count=0
while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    count=$((count + 1))
    case "$p" in
        lib/cli/usage.md)
            printf '%s\n' "$p"
            exit 1
            ;;
        *.md) ;;
        *)
            printf '%s\n' "$p"
            exit 1
            ;;
    esac
done <"$paths"

if [ "$count" -eq 0 ]; then
    printf 'no changed paths\n'
    exit 1
fi
exit 0
