# shellcheck shell=bash

# ^ invariant sourced by tests/platform/autoupdate-e2e.sh only; the sourcing script sets the constants (accounts, paths, bounds) before a function here runs
# ^ invariant report is the only writer of PASSED and FAILED; a helper returning early without it has claimed nothing
PASSED=0
FAILED=0
RC=0
OUTF=""
ERRF=""

report() {
    if [ "$1" = ok ]; then
        PASSED=$((PASSED + 1))
        printf 'PASS    %s\n' "$2"
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL    %s\n' "$2"
    fi
}

# ^ invariant excerpt FILE prints at most EXCERPT_MAX bytes of it on one line, for a FAIL line
excerpt() { head -c "$EXCERPT_MAX" "$1" | tr '\n\r' '  '; }

# ^ invariant check_ok LABEL CMD... is one claim, PASS when CMD succeeds
check_ok() {
    local label="$1"
    shift
    if "$@"; then report ok "$label"; else report bad "$label"; fi
}

# ^ invariant check_rc WANTED LABEL judges RC, the exit status the last run stored
check_rc() {
    if [ "$RC" -eq "$1" ]; then report ok "$2"; else report bad "$2 (exit $RC, wanted $1; stderr: $(excerpt "$ERRF"))"; fi
}

# ^ invariant check_has FILE TEXT LABEL, TEXT is a fixed string
check_has() {
    if grep -qF -- "$2" "$1"; then report ok "$3"; else report bad "$3 (missing [$2] in $1: $(excerpt "$1"))"; fi
}

# ^ invariant check_eq GOT WANTED LABEL; two empty values never pass, a failed lookup on both sides is not an equality
check_eq() {
    if [ -n "$1$2" ] && [ "$1" = "$2" ]; then report ok "$3"; else report bad "$3 (got [$1], wanted [$2])"; fi
}

# ^ invariant gone PATH... rc 0 = none of them exists; a dangling link exists
gone() {
    local p
    for p in "$@"; do
        if [ -e "$p" ] || [ -L "$p" ]; then return 1; fi
    done
}

# ^ invariant path_of ACCOUNT share|state|units|cli prints where the account's install keeps the thing (default XDG paths, no account sets one)
path_of() {
    case "$2" in
        share) printf '/home/%s/.local/share/git-secret-guard' "$1" ;;
        state) printf '/home/%s/.local/state/git-secret-guard' "$1" ;;
        units) printf '/home/%s/.config/systemd/user' "$1" ;;
        cli) printf '/home/%s/.local/bin/git-secret-guard' "$1" ;;
        *) return 1 ;;
    esac
}

# ^ security env -i and a fixed list => an account starts with nothing of this script's environment
# ^ invariant bare ACCOUNT CMD... runs without XDG_RUNTIME_DIR => no systemd user manager is in reach of CMD
bare() {
    local account="$1"
    shift
    runuser -u "$account" -- env -i HOME="/home/$account" PATH="/home/$account/.local/bin:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 "$@"
}

# ^ invariant as ACCOUNT CMD... is bare plus the account's own XDG_RUNTIME_DIR, where a lingering account's user manager listens
as() {
    local account="$1" uid
    shift
    uid="$(id -u "$account")" || return 1
    bare "$account" XDG_RUNTIME_DIR="/run/user/$uid" "$@"
}

# ^ invariant run NAME CMD... keeps stdout and stderr in LOGS/NAME.out and .err (OUTF, ERRF) and the exit status in RC; stdin is /dev/null
run() {
    local name="$1"
    shift
    OUTF="$LOGS/$name.out" ERRF="$LOGS/$name.err"
    "$@" >"$OUTF" 2>"$ERRF" </dev/null
    RC=$?
}

# ^ invariant fixture NAME CMD... is a preparation, not a claim; it counts only when it fails, and returns CMD's status
fixture() {
    local name="$1"
    shift
    run "fixture-$name" "$@"
    if [ "$RC" -ne 0 ]; then report bad "fixture $name (exit $RC; stderr: $(excerpt "$ERRF"))"; fi
    return "$RC"
}

# ^ hazard a timer run may hold the update lock when a hand run or uninstall starts; the command refuses and changes nothing
# ^ invariant retry_locked NAME out|err TEXT CMD... repeats run NAME CMD... as long as the named output holds TEXT (the lock's refusal); RC is the last run's
# ^ invariant tries used up => one FAIL line and rc 1; the caller's own claims judge the last run
retry_locked() {
    local name="$1" which="$2" text="$3" n
    shift 3
    if [ "$which" != out ] && [ "$which" != err ]; then
        report bad "$name: retry_locked got the stream [$which], wanted out or err"
        return 2
    fi
    for ((n = 0; n < LOCK_TRIES; n++)); do
        run "$name" "$@"
        if ! grep -qF -- "$text" "$LOGS/$name.$which"; then return 0; fi
        sleep "$LOCK_RETRY_SLEEP"
    done
    report bad "$name: still kept out by the update lock after $LOCK_TRIES tries"
    return 1
}

declare -A LAST=() MARK=()

# ^ invariant record_line ACCOUNT prints the account's update record on one line, its key=value lines joined by "|"
# ^ invariant "" with rc 0 only when there is no record file; an unreadable record keeps paste's message and status
record_line() {
    local f
    f="$(path_of "$1" state)/update" || return 1
    if [ ! -e "$f" ]; then return 0; fi
    paste -s -d '|' "$f"
}

# ^ invariant every record seen is appended once to WORK/runs.ACCOUNT => a record a later run replaced is still found by wait_run
# ^ invariant rc 1 = a record could not be read or the history not written; a lost record would let a later wait match the wrong run
hist_poll() {
    local a line
    for a in "$OWNER" "$FOLLOWER"; do
        if ! line="$(record_line "$a")"; then
            printf 'cannot read the update record of %s\n' "$a" >&2
            return 1
        fi
        if [ -z "$line" ] || [ "$line" = "${LAST[$a]:-}" ]; then continue; fi
        if ! printf '%s\n' "$line" >>"$WORK/runs.$a"; then
            printf 'cannot append to %s\n' "$WORK/runs.$a" >&2
            return 1
        fi
        LAST[$a]="$line"
    done
}

# ^ invariant mark remembers how many records each account has by now; wait_run looks only at later ones
# ^ invariant a failure is one FAIL line and rc 1 => a step stopping on it never leaves a green summary
mark() {
    local a count
    if ! hist_poll; then
        report bad "record history: the records could not be read or kept"
        return 1
    fi
    for a in "$OWNER" "$FOLLOWER"; do
        if ! count="$(wc -l <"$WORK/runs.$a")"; then
            report bad "record history: cannot count $WORK/runs.$a"
            return 1
        fi
        MARK[$a]="$count"
    done
}

# ^ invariant wait_run ACCOUNT SKIP REGEX sets REPLY = the first record after the mark, past SKIP earlier ones, matching REGEX; rc 1 after the bound
# ^ why SKIP, not the first match; a run started before the change may still write "current", only a later record proves the claim
# ^ invariant bounded twice, RUN_BOUND seconds per awaited run and E2E_DEADLINE seconds of the whole script
wait_run() {
    local a="$1" skip="$2" from n
    from=$((${MARK[$a]:-0} + skip + 1))
    REPLY=""
    for ((n = 0; n < RUN_BOUND * (skip + 1) && SECONDS < E2E_DEADLINE; n++)); do
        hist_poll || return 1
        if REPLY="$(tail -n "+$from" "$WORK/runs.$a" | grep -E -m 1 -- "$3")"; then return 0; fi
        sleep 1
    done
    printf 'no record of %s matched [%s] after %s seconds (script second %s); its last records:\n' "$a" "$3" "$n" "$SECONDS" >&2
    tail -n "$DIAG_RECORDS" "$WORK/runs.$a" >&2
    return 1
}

# ^ invariant expect_run ACCOUNT SKIP REGEX LABEL is one claim; its PASS line shows the record, without checked_at
expect_run() {
    if wait_run "$1" "$2" "$3"; then report ok "$4 [${REPLY#*|}]"; else report bad "$4"; fi
}

# ^ invariant prints a value equal to nothing else, in place of an unreadable one => two failed snapshots never compare equal
unreadable() { printf 'unreadable-%s-%s-%s' "$BASHPID" "$SECONDS" "$RANDOM"; }

# ^ invariant tree_hash DIR prints one hash over the name and content of every regular file under DIR
# ^ invariant a missing DIR or a failing stage (pipefail) prints unreadable's value and returns 1
tree_hash() {
    local sum=""
    if [ -d "$1" ]; then
        sum="$(set -o pipefail && cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum | sha256sum)" || sum=""
    fi
    if [ -z "$sum" ]; then
        unreadable
        return 1
    fi
    printf '%s' "${sum%% *}"
}

SNAP_OWNER=""
SNAP_FOLLOWER=""

# ^ invariant snap ACCOUNT = what "installed" means for one account, every file of the installed copy, the state file, the installed VERSION
# ^ invariant an unreadable part becomes unreadable's value, and the status is 1
snap() {
    local share state tree state_sum version rc=0
    if ! share="$(path_of "$1" share)" || ! state="$(path_of "$1" state)"; then
        unreadable
        return 1
    fi
    tree="$(tree_hash "$share")" || rc=1
    if ! state_sum="$(sha256sum <"$state/state")"; then state_sum="$(unreadable)" rc=1; fi
    if ! version="$(head -n 1 "$share/VERSION")"; then version="$(unreadable)" rc=1; fi
    printf '%s %s %s' "$tree" "${state_sum%% *}" "$version"
    return "$rc"
}

# ^ invariant a failed snapshot is one FAIL line; the later comparison with it fails as well
snap_take() {
    if ! SNAP_OWNER="$(snap "$OWNER")"; then report bad "snapshot: the install of $OWNER cannot be read"; fi
    if ! SNAP_FOLLOWER="$(snap "$FOLLOWER")"; then report bad "snapshot: the install of $FOLLOWER cannot be read"; fi
}

# ^ invariant expect_unchanged LABEL is two claims, each account's install is what snap_take saw
expect_unchanged() {
    check_eq "$(snap "$OWNER")" "$SNAP_OWNER" "$1: the owner's installed copy and state file are unchanged"
    check_eq "$(snap "$FOLLOWER")" "$SNAP_FOLLOWER" "$1: the follower's installed copy and state file are unchanged"
}
