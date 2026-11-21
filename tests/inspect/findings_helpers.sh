# shellcheck shell=bash
# ^ invariant these helpers read and write the findings record doctor keeps in the state dir ($LC_STATE, set by the lifecycle harness)

REC_MAGIC="git-secret-guard findings 1"
# shellcheck disable=SC2034
TAB=$'\t'

rec_file() { printf '%s' "$LC_STATE/findings"; }

# ^ invariant writes a valid record whose body is the arguments, one line each
write_record() {
    mkdir -p -- "$LC_STATE" || return 1
    { printf '%s\ntime 2026-01-01T00:00:00Z\n' "$REC_MAGIC"; if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; fi; } >"$(rec_file)"
}
