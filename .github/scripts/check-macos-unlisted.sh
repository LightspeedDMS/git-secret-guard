#!/usr/bin/env bash
# ^ invariant usage check-macos-unlisted.sh LIST MACLOG LINUXLOG; exit 0 = none unlisted, 1 = one found, 2 = usage, unreadable file or empty log
# ^ invariant Mac-only test = PASS in MACLOG, SKIPPED in LINUXLOG with a macOS-only reason; LIST must name it or the Mac gate cannot see it go quiet
# ^ external the reason is the text in parentheses of the SKIPPED line; a new Mac-only wording must match MAC_REASON below; POSIX awk only
set -u
set -o pipefail

MAC_REASON='macOS|BSD|plutil|bwk|bash is [0-9]|GNUBIN|Homebrew|launchd|Darwin'

if [ "$#" -ne 3 ]; then
    printf 'usage: check-macos-unlisted.sh LIST MACLOG LINUXLOG\n' >&2
    exit 2
fi
for f in "$1" "$2" "$3"; do
    if [ ! -r "$f" ]; then
        printf 'check-macos-unlisted: cannot read %s\n' "$f" >&2
        exit 2
    fi
    # ^ why -s in the shell, not left to awk; FNR == 1 never fires for a zero-byte file => the files shift and the error misleads
    if [ ! -s "$f" ]; then
        printf 'check-macos-unlisted: %s is empty, which proves nothing\n' "$f" >&2
        exit 2
    fi
done

awk -v pat="$MAC_REASON" '
    FNR == 1 { fileno++ }
    fileno == 1 { if ($0 != "" && $0 !~ /^#/) listed[$0] = 1; next }
    fileno == 2 { if ($1 == "PASS") { passed[$2] = 1; macpass++ }; next }
    fileno == 3 && ($1 == "PASS" || $1 == "FAIL" || $1 == "SKIPPED") {
        verdicts++
        if ($1 == "SKIPPED" && !($2 in reason)) {
            r = $0
            sub(/^SKIPPED +[^ ]+ */, "", r)
            if (r ~ pat) { reason[$2] = r; order[++n] = $2 }
        }
    }
    END {
        if (macpass == 0 || verdicts == 0) { print "check-macos-unlisted: a log has no PASS/SKIPPED lines, which proves nothing" > "/dev/stderr"; exit 2 }
        for (i = 1; i <= n; i++) {
            id = order[i]
            if ((id in passed) && !(id in listed)) { printf "UNLISTED %s %s\n", id, reason[id]; bad++ }
        }
        printf "check-macos-unlisted: %d unlisted Mac-only tests\n", bad
        exit bad > 0
    }
' "$1" "$2" "$3"
