# shellcheck shell=bash disable=SC2153,SC2034

# ^ invariant one update cycle of one user (#129); the checkout's owner fetches and fast-forwards to the newest released tag, every user installs from an export
# ^ invariant every doubtful case is a skip with a recorded reason and no change; exit 0 for current, updated and skipped, 1 for failed
# ^ coupled lib/core/state.sh names the record and the lock (GSG_UPDATE_RECORD, GSG_UPDATE_LOCK); the units run "<share>/bin/git-secret-guard update"

# ^ why at most 9 digits a part, not any number; gitup_version_at_least compares with -gt, a 20-digit part overflows bash arithmetic
GSG_UPDATE_VERSION_RE='^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$'
# ^ invariant the most characters autoupdate_first_line reads; a version, a commit id, a ref or an error line the record cuts at 160 all fit
GSG_UPDATE_LINE_MAX=1024

# ^ coupled the parts as GSG_UPDATE_VERSION_RE; a tag outside it is skipped as invalid, else its version check fails the whole tag selection
GSG_UPDATE_TAG_RE='^v[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$'
GSG_UPDATE_MAX_TAGS=1000
GSG_UPDATE_ENV_MAX=100
GSG_UPDATE_FETCH_SECONDS=120
GSG_UPDATE_FETCH_KILL_SECONDS=10
GSG_UPDATE_INSTALL_SECONDS=1800
GSG_UPDATE_INSTALL_KILL_SECONDS=30
# ^ invariant the limit of every short git call (a query of refs, config or one object), and of each long step (status, fast-forward, archive, tar)
GSG_UPDATE_QUERY_SECONDS=60
GSG_UPDATE_STEP_SECONDS=300
# ^ invariant the grace before KILL of every call autoupdate_limited runs, short or long
GSG_UPDATE_STEP_KILL_SECONDS=10
# ^ external GNU timeout exits 124 when the limit ended the command, 137 when it had to send KILL after the grace
GSG_UPDATE_RC_TIMEOUT=124
GSG_UPDATE_RC_KILLED=137
# ^ hazard under a live pid only a lock older than this is broken => a live run holding it longer would lose it; every git call has a limit
# ^ invariant worst case of one owner run, graces included, 13 short calls (910 s) + 4 long steps (1240 s) + fetch (130 s) + install (1830 s) = 4110 s
# ^ coupled tests/autoupdate/test_autoupdate.sh MAX_BOUNDED_CALLS counts these 19 calls; a new call under the lock goes through autoupdate_limited, into the sum
GSG_UPDATE_LOCK_MAX_AGE_MIN=120
# ^ invariant a temp record lives for milliseconds between mktemp and rename; one older than this many minutes was left by a killed run
GSG_UPDATE_TEMP_MAX_AGE_MIN=1
# ^ coupled tests/autoupdate/test_autoupdate.sh:DETAIL_MAX; trunc_text adds one cut mark => the detail of the record has at most 160 characters
GSG_UPDATE_DETAIL_MAX=159
# ^ external a shell ended by a signal exits 128 plus the signal number; the traps of autoupdate_run exit with these
GSG_UPDATE_EXIT_HUP=129
GSG_UPDATE_EXIT_INT=130
GSG_UPDATE_EXIT_TERM=143

AU_LOCK_HELD=0
AU_ROLE="" AU_RESULT="" AU_REASON="" AU_DETAIL="" AU_FROM="" AU_TO="" AU_WORK=""
# ^ invariant AU_TIMED_OUT = "" or the text naming the first call of this run its limit ended; autoupdate_finish records such a run as failed
AU_TIMED_OUT=""
AU_GIT=()
# ^ invariant AU_TAGS = the tag names still in the selection, AU_TAG_HEADS = for each of them "<object> blob <size>" of its VERSION file
AU_TAGS=() AU_TAG_HEADS=()

# ^ invariant rc 0 = pid $1 is the parent or the grandparent of this process
# ^ why the grandparent too, not the parent alone; update starts its child install under timeout, the parent of the child is this timeout
# ^ external ps -o ppid= -p PID prints the parent pid alone (procps and macOS); a failing ps lets nobody in
autoupdate_is_ancestor() {
    local grand
    if [ "$PPID" = "$1" ]; then return 0; fi
    # ^ external the MSYS ps has no -o (probed, #132); /proc/PID/ppid holds the parent there, as lib/core/proc.sh reads it
    if tools_is_windows; then
        { read -r grand <"/proc/$PPID/ppid"; } 2>/dev/null || return 1
    else
        grand="$(ps -o ppid= -p "$PPID" 2>/dev/null)" || return 1
    fi
    [ "${grand//[[:space:]]/}" = "$1" ]
}

# ^ invariant rc 0 = taken or let in, 1 = held by a live run or a directory in the way (DR_REC_LOCK_NOT_LINK), 2 = the lock could not be made
# ^ invariant let in without taking = the lock names GSG_UPDATE_LOCK_PID and this pid is an ancestor; only the child install of update is
# ^ order state_make_dir before the lock => a first install can take it, the lock lives in the state dir
autoupdate_lock_take() {
    local holder
    AU_LOCK_HELD=0
    if [ -n "${GSG_UPDATE_LOCK_PID:-}" ]; then
        holder="$(readlink -- "$GSG_UPDATE_LOCK" 2>/dev/null)" || holder=""
        if [ -n "$holder" ] && [ "$holder" = "$GSG_UPDATE_LOCK_PID" ] && autoupdate_is_ancestor "$holder"; then return 0; fi
    fi
    state_make_dir || return 2
    if doctor_rec_lock "$GSG_UPDATE_LOCK" 1 "$GSG_UPDATE_LOCK_MAX_AGE_MIN" "update, install or uninstall"; then
        AU_LOCK_HELD=1
        return 0
    fi
    if [ -n "$DR_REC_LOCK_HOLDER" ] || [ "$DR_REC_LOCK_NOT_LINK" -eq 1 ]; then return 1; fi
    return 2
}

# ^ invariant removes the lock only when this process took it and it still names this process; a process let in leaves its parent's lock alone
autoupdate_lock_release() {
    if [ "$AU_LOCK_HELD" -ne 1 ]; then return 0; fi
    AU_LOCK_HELD=0
    doctor_rec_unlock "$GSG_UPDATE_LOCK"
}

# ^ invariant prints owner when this user owns both the checkout $1 and its .git directory, follower otherwise; a pure function of the two paths
# ^ invariant rc 1 = $1/.git is not a directory (a worktree or a submodule has a file there, a missing checkout nothing) or, on Windows, no repository
autoupdate_role() {
    if [ ! -d "$1/.git" ]; then return 1; fi
    # ^ external [ -O ] cannot tell the owner under MSYS (probed, #132) => on Windows git's own check decides, rc 1 when the directory is no repository
    if tools_is_windows; then
        winupdate_role "$1"
        return
    fi
    if [ -O "$1" ] && [ -O "$1/.git" ]; then printf 'owner\n'; else printf 'follower\n'; fi
}

# ^ invariant sets REPLY = line 1 of file $1, at most GSG_UPDATE_LINE_MAX characters; "" for an empty, missing or unreadable file; rc always 0
# ^ security only a regular file is opened (a link counts when its target is one); a FIFO without a writer or a device would block or never end
# ^ hazard a regular file swapped for a FIFO between the test and the open still blocks; the paths read are the user's own or a checkout's
autoupdate_first_line() {
    local line=""
    REPLY=""
    if [ ! -f "$1" ]; then return 0; fi
    # ^ external read returns 1 at end of file without a newline; the characters read are kept, a failed open leaves line empty
    { IFS= read -r -n "$GSG_UPDATE_LINE_MAX" line <"$1"; } 2>/dev/null || :
    REPLY="$line"
}

# ^ invariant sets REPLY = the VERSION of the installed copy, "" when it has none
autoupdate_installed_version() { autoupdate_first_line "$GSG_SHARE/VERSION"; }

# ^ invariant rc 0 = version $1 is newer than $2, 1 = it is not, 2 = one of them is not x.y.z
# ^ why the strict x.y.z test first, not gitup_version_at_least alone; it reads a missing part as 0 and 1.0 would pass for 1.0.0
autoupdate_newer() {
    local rc=0
    if [[ ! $1 =~ $GSG_UPDATE_VERSION_RE ]] || [[ ! $2 =~ $GSG_UPDATE_VERSION_RE ]]; then return 2; fi
    gitup_version_at_least "$2" "$1" || rc=$?
    case "$rc" in
        0) return 1 ;;
        1) return 0 ;;
        *) return 2 ;;
    esac
}

# ^ invariant rc 0 = version $1 must be installed, 1 = it is installed, 2 = $1, the state's version or the installed VERSION is not x.y.z
# ^ invariant needed = $1 is newer than the state's version OR than the installed VERSION; install records the version before it copies (the gap, #129)
# ^ invariant an installed copy without a VERSION file needs the install; nothing says it is current
autoupdate_needs_install() {
    local state_rc=0 share_rc=0
    autoupdate_newer "$1" "$ST_VERSION" || state_rc=$?
    if [ "$state_rc" -eq 2 ]; then return 2; fi
    autoupdate_installed_version
    if [ -z "$REPLY" ]; then return 0; fi
    autoupdate_newer "$1" "$REPLY" || share_rc=$?
    if [ "$share_rc" -eq 2 ]; then return 2; fi
    [ "$state_rc" -eq 0 ] || [ "$share_rc" -eq 0 ]
}

# ^ invariant autoupdate_outcome RESULT [REASON [DETAIL]] sets what the record will say; DETAIL loses its control characters and is cut
autoupdate_outcome() {
    local detail="${3:-}"
    trunc_text "${detail//[[:cntrl:]]/?}" "$GSG_UPDATE_DETAIL_MAX"
    AU_RESULT="$1" AU_REASON="${2:-}" AU_DETAIL="$REPLY"
}

# ^ invariant the record is replaced by renaming a temp file made beside it => a reader sees the old record or the new one, never half of either
# ^ invariant a run kept out by the lock writes its record too, without the lock; the rename makes two writers safe, the last one wins
# ^ hazard mv onto a directory moves the file into it and exits 0; a record path naming a directory is refused first
autoupdate_record_write() {
    local now tmp
    if [ -d "$GSG_UPDATE_RECORD" ]; then
        printf '%s: cannot write the update record, %s is a directory\n' "$GSG_NAME" "$GSG_UPDATE_RECORD" >&2
        return 1
    fi
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
    tmp="$(umask 077 && mktemp "$GSG_STATE_DIR/update-tmp.XXXXXX")" || {
        printf '%s: cannot create a temp file in %s\n' "$GSG_NAME" "$GSG_STATE_DIR" >&2
        return 1
    }
    {
        printf 'checked_at=%s\n' "$now"
        printf 'role=%s\n' "$AU_ROLE"
        printf 'result=%s\n' "$AU_RESULT"
        printf 'reason=%s\n' "$AU_REASON"
        printf 'detail=%s\n' "$AU_DETAIL"
        printf 'from=%s\n' "${AU_FROM//[[:cntrl:]]/?}"
        printf 'to=%s\n' "${AU_TO//[[:cntrl:]]/?}"
    } >"$tmp" && mv -f -- "$tmp" "$GSG_UPDATE_RECORD" && return 0
    printf '%s: cannot write the update record %s\n' "$GSG_NAME" "$GSG_UPDATE_RECORD" >&2
    rm -f -- "$tmp"
    return 1
}

# ^ invariant only the lock holder makes update-work dirs => under the lock every one found was left by a killed run and is removed
# ^ hazard a run kept out by the lock makes its temp record without the lock => a temp record is removed only past GSG_UPDATE_TEMP_MAX_AGE_MIN
# ^ invariant a failed removal is said on stderr and the run goes on; uninstall's rmdir of the state dir needs them gone, the update does not
autoupdate_work_make() {
    if ! find "$GSG_STATE_DIR" -maxdepth 1 \( -name 'update-work.??????' -o \( -name 'update-tmp.??????' -mmin "+$GSG_UPDATE_TEMP_MAX_AGE_MIN" \) \) \
        -exec rm -rf -- {} +; then
        printf '%s: cannot remove old update files in %s\n' "$GSG_NAME" "$GSG_STATE_DIR" >&2
    fi
    AU_WORK="$(umask 077 && mktemp -d "$GSG_STATE_DIR/update-work.XXXXXX")" || {
        AU_WORK=""
        return 1
    }
}

# ^ invariant rm -rf only on the absolute mktemp directory this run made; it holds the export and the captured output
autoupdate_work_remove() {
    local dir="$AU_WORK"
    AU_WORK=""
    if [ -z "$dir" ] || [ "${dir#/}" = "$dir" ]; then return 0; fi
    if ! rm -rf -- "$dir"; then printf '%s: cannot remove %s\n' "$GSG_NAME" "$dir" >&2; fi
}

# ^ security the repository-local GIT_* variables are unset => GIT_DIR of a calling hook cannot point the cycle at another repository
# ^ invariant GIT_TERMINAL_PROMPT=0 for every git call and for the child install; nothing here may wait for a person
# ^ order after autoupdate_work_make; the query runs under the short limit and its answer is read from the work dir
autoupdate_git_env() {
    local v
    local -a names=()
    autoupdate_capture /dev/null autoupdate_limited "$GSG_UPDATE_QUERY_SECONDS" "git rev-parse" "$GSG_GIT" rev-parse --local-env-vars || return 1
    mapfile -t -n "$GSG_UPDATE_ENV_MAX" names <"$AU_WORK/git.out" || return 1
    for v in "${names[@]}"; do
        if [[ $v =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then unset "$v"; fi
    done
    export GIT_TERMINAL_PROMPT=0
}

# ^ invariant every git call on checkout $1 carries these options; a follower ($2) adds safe.directory for the exact recorded path
# ^ security safe.directory is given on the command line only, never "*" and never written to a config file
autoupdate_git_init() {
    AU_GIT=("$GSG_GIT" -c core.fsmonitor=false --no-optional-locks)
    if [ "$2" = follower ]; then AU_GIT+=(-c "safe.directory=$1"); fi
    AU_GIT+=(-C "$1")
}

# ^ invariant autoupdate_capture STDIN CMD... runs CMD in the foreground, stdin from file STDIN, stdout into git.out and stderr into git.err of the work dir
# ^ invariant rc = CMD's, or 1 when STDIN cannot be opened
autoupdate_capture() {
    local stdin="$1"
    shift
    "$@" >"$AU_WORK/git.out" 2>"$AU_WORK/git.err" <"$stdin"
}

# ^ invariant autoupdate_git ARGS... runs git on the checkout under the short limit, no stdin, output captured; rc = git's, or timeout's
# ^ invariant every git call of a run goes through autoupdate_limited, the fetch has its own limit (tests/autoupdate/test_autoupdate.sh reads this file for it)
autoupdate_git() { autoupdate_capture /dev/null autoupdate_limited "$GSG_UPDATE_QUERY_SECONDS" "git $1" "${AU_GIT[@]}" "$@"; }

# ^ invariant autoupdate_limited LIMIT WHAT CMD... runs CMD for at most LIMIT seconds; rc = the command's, or 124 or 137 when the limit ended it
# ^ invariant the first call of a run the limit ended is remembered by name in AU_TIMED_OUT; no caller has to tell a timeout from a failure
# ^ external timeout without --foreground signals its whole group => a hook the fast-forward started ends with the git it hangs in
autoupdate_limited() {
    local limit="$1" what="$2" rc=0
    shift 2
    "$TIMEOUT_BIN" -k "$GSG_UPDATE_STEP_KILL_SECONDS" "$limit" "$@" || rc=$?
    if autoupdate_rc_timed_out "$rc" && [ -z "$AU_TIMED_OUT" ]; then AU_TIMED_OUT="$what timed out after $limit s"; fi
    return "$rc"
}

# ^ invariant autoupdate_git_bounded ARGS... is autoupdate_git under the step limit, for the git calls a large tree, a slow disk or a hook can hold up
autoupdate_git_bounded() { autoupdate_capture /dev/null autoupdate_limited "$GSG_UPDATE_STEP_SECONDS" "git $1" "${AU_GIT[@]}" "$@"; }

# ^ invariant autoupdate_git_line out|err sets REPLY = line 1 of what the last autoupdate_git wrote to stdout or to stderr
autoupdate_git_line() { autoupdate_first_line "$AU_WORK/git.$1"; }

# ^ invariant autoupdate_git_failed WHAT sets result failed with WHAT and git's first stderr line, shows git's stderr, returns 1
autoupdate_git_failed() {
    autoupdate_git_line err
    autoupdate_outcome failed "" "$1 failed${REPLY:+, $REPLY}"
    cat -- "$AU_WORK/git.err" >&2 || true
    return 1
}

# ^ invariant rc 0 = HEAD is the commit revision $1 names; 1 = it is not, or one of the two cannot be resolved to a commit
# ^ invariant both sides are peeled here => an annotated tag is compared by its commit, never by its tag object
autoupdate_at_commit() {
    local head
    autoupdate_git rev-parse --verify -q 'HEAD^{commit}' || return 1
    autoupdate_git_line out
    head="$REPLY"
    autoupdate_git rev-parse --verify -q "$1^{commit}" || return 1
    autoupdate_git_line out
    [ -n "$head" ] && [ "$head" = "$REPLY" ]
}

# ^ order shallow, no origin, not on main, dirty (#129 AC7); the first check to hold names the skip, later ones do not run after it
# ^ invariant rc 0 = the checkout may be fetched into and fast-forwarded, 1 = the outcome is set
autoupdate_owner_checks() {
    autoupdate_git rev-parse --is-shallow-repository || { autoupdate_git_failed "git rev-parse"; return 1; }
    autoupdate_git_line out
    if [ "$REPLY" = true ]; then
        autoupdate_outcome skipped shallow
        return 1
    fi
    if ! autoupdate_git remote get-url origin; then
        autoupdate_git_line err
        autoupdate_outcome skipped no-origin "$REPLY"
        return 1
    fi
    if ! autoupdate_git symbolic-ref -q HEAD; then
        autoupdate_outcome skipped not-on-main "HEAD is not on a branch"
        return 1
    fi
    autoupdate_git_line out
    if [ "$REPLY" != refs/heads/main ]; then
        autoupdate_outcome skipped not-on-main "HEAD is on $REPLY"
        return 1
    fi
    autoupdate_git_bounded status --porcelain --untracked-files=no || { autoupdate_git_failed "git status"; return 1; }
    if [ -s "$AU_WORK/git.out" ]; then
        autoupdate_git_line out
        autoupdate_outcome skipped dirty "$REPLY"
        return 1
    fi
}

# ^ external timeout without --foreground signals its whole group; under setsid git has no controlling terminal => ssh cannot prompt (#129, Bounded fetch)
# ^ invariant no --force for tags; a tag moved on origin is rejected, the fetch exits non-zero, the local tag stays (tests/autoupdate/test_autoupdate_probes.sh)
# ^ external Windows has no setsid (probed, #132); GNU timeout alone ends git and every process below it (probed), winupdate.sh sets GCM_INTERACTIVE=never
autoupdate_fetch() {
    local -a launcher=()
    if ! tools_is_windows; then launcher=("$SETSID_BIN"); fi
    "$TIMEOUT_BIN" -k "$GSG_UPDATE_FETCH_KILL_SECONDS" "$GSG_UPDATE_FETCH_SECONDS" "${launcher[@]}" "${AU_GIT[@]}" fetch --no-recurse-submodules origin \
        '+refs/heads/main:refs/remotes/origin/main' 'refs/tags/v*:refs/tags/v*' >"$AU_WORK/git.out" 2>"$AU_WORK/git.err" </dev/null
}

# ^ invariant autoupdate_git_fed FILE ARGS... is autoupdate_git with file FILE on stdin, for git commands reading a list of objects
autoupdate_git_fed() { autoupdate_capture "$1" autoupdate_limited "$GSG_UPDATE_QUERY_SECONDS" "git $2" "${AU_GIT[@]}" "${@:2}"; }

# ^ invariant sets AU_TAGS = the tags named vX.Y.Z, merged into origin/main, whose version needs the install, in the order of git's list (read with a bound)
# ^ invariant one git call; rc 2 = the installed version is not x.y.z, 3 = git failed
autoupdate_tag_candidates() {
    local name rc
    local -a names=()
    AU_TAGS=()
    autoupdate_git tag --list 'v*' --sort=-v:refname --merged refs/remotes/origin/main || return 3
    mapfile -t -n "$GSG_UPDATE_MAX_TAGS" names <"$AU_WORK/git.out" || return 3
    for name in "${names[@]}"; do
        if [[ ! $name =~ $GSG_UPDATE_TAG_RE ]]; then continue; fi
        rc=0
        autoupdate_needs_install "${name#v}" || rc=$?
        if [ "$rc" -eq 2 ]; then return 2; fi
        if [ "$rc" -eq 0 ]; then AU_TAGS+=("$name"); fi
    done
}

# ^ invariant keeps in AU_TAGS the tags whose VERSION file is a blob of exactly the bytes of "X.Y.Z" plus a newline; AU_TAG_HEADS = git's line for each
# ^ invariant one git call for all tags; git answers one line per name asked, "<name> missing" where there is no such file; rc 3 = git failed or miscounted
autoupdate_tags_sized() {
    local i x
    local -a answers=() kept=()
    AU_TAG_HEADS=()
    if [ "${#AU_TAGS[@]}" -eq 0 ]; then return 0; fi
    printf 'refs/tags/%s:VERSION\n' "${AU_TAGS[@]}" >"$AU_WORK/git.in" || return 3
    autoupdate_git_fed "$AU_WORK/git.in" cat-file '--batch-check=%(objectname) %(objecttype) %(objectsize)' || return 3
    mapfile -t -n "$((${#AU_TAGS[@]} + 1))" answers <"$AU_WORK/git.out" || return 3
    if [ "${#answers[@]}" -ne "${#AU_TAGS[@]}" ]; then return 3; fi
    for i in "${!AU_TAGS[@]}"; do
        x="${AU_TAGS[$i]#v}"
        if [[ ! ${answers[$i]} =~ ^[0-9a-f]+\ blob\ $((${#x} + 1))$ ]]; then continue; fi
        kept+=("${AU_TAGS[$i]}")
        AU_TAG_HEADS+=("${answers[$i]}")
    done
    AU_TAGS=("${kept[@]}")
}

# ^ invariant keeps in AU_TAGS the tags whose VERSION file says exactly X.Y.Z; one git call prints all the files autoupdate_tags_sized kept
# ^ security each answer must start with the line recorded for its object and is read by its known byte count => no file content can pass for another answer
# ^ invariant rc 3 = git failed or its answer is not the objects asked for; LC_ALL=C makes read -N count bytes
autoupdate_tags_valid() {
    local i x head body rest LC_ALL=C
    local -a kept=()
    if [ "${#AU_TAGS[@]}" -eq 0 ]; then return 0; fi
    printf '%s\n' "${AU_TAG_HEADS[@]%% *}" >"$AU_WORK/git.in" || return 3
    autoupdate_git_fed "$AU_WORK/git.in" cat-file --batch || return 3
    for i in "${!AU_TAGS[@]}"; do
        x="${AU_TAGS[$i]#v}"
        if ! IFS= read -r -u 3 head || [ "$head" != "${AU_TAG_HEADS[$i]}" ]; then return 3; fi
        if ! IFS= read -r -u 3 -N "$((${#x} + 1))" body || ! IFS= read -r -u 3 rest || [ -n "$rest" ]; then return 3; fi
        if [ "$body" = "$x"$'\n' ]; then kept+=("${AU_TAGS[$i]}"); fi
    done 3<"$AU_WORK/git.out"
    AU_TAGS=("${kept[@]}")
}

# ^ invariant sets REPLY = the highest valid tag whose version needs the install; rc 1 = none, 2 = a version is not x.y.z, 3 = git failed
# ^ invariant valid = named vX.Y.Z, merged into origin/main, and its VERSION file says X.Y.Z; three git calls, whatever the number of tags
# ^ invariant the order of git's list is never trusted; a tag replaces the best one only when autoupdate_newer says so
autoupdate_pick_tag() {
    local name best=""
    autoupdate_tag_candidates || return "$?"
    autoupdate_tags_sized || return 3
    autoupdate_tags_valid || return 3
    for name in "${AU_TAGS[@]}"; do
        if [ -z "$best" ] || autoupdate_newer "${name#v}" "$best"; then best="${name#v}"; fi
    done
    REPLY="${best:+v$best}"
    [ -n "$best" ]
}

# ^ invariant rc 0 = HEAD is where the install step may read it, 1 = the outcome is set
# ^ invariant the merge target is the peeled commit of the tag, fast-forward only => no merge commit, HEAD ends exactly at the tag and never past it
# ^ invariant the owner's own git hooks run during the fast-forward; nothing here turns them off
autoupdate_owner_advance() {
    local tag="" rc=0
    autoupdate_owner_checks || return 1
    if ! autoupdate_fetch; then
        autoupdate_git_line err
        autoupdate_outcome skipped fetch-failed "$REPLY"
        cat -- "$AU_WORK/git.err" >&2 || true
        return 1
    fi
    autoupdate_pick_tag || rc=$?
    case "$rc" in
        0) tag="$REPLY" ;;
        1) autoupdate_outcome current ;;
        2) autoupdate_outcome skipped bad-version "the installed version is not x.y.z" ;;
        *) autoupdate_git_failed "git tag" ;;
    esac
    if [ -z "$tag" ]; then return 1; fi
    AU_TO="${tag#v}"
    rc=0
    autoupdate_git merge-base --is-ancestor HEAD "refs/tags/$tag^{commit}" || rc=$?
    if [ "$rc" -eq 1 ]; then
        autoupdate_outcome skipped ahead-of-tag "HEAD is not an ancestor of $tag"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then autoupdate_git_failed "git merge-base"; return 1; fi
    autoupdate_git_bounded merge --ff-only "refs/tags/$tag^{commit}" || { autoupdate_git_failed "git merge --ff-only $tag"; return 1; }
    if ! autoupdate_at_commit "refs/tags/$tag"; then
        autoupdate_outcome failed "" "HEAD is not at $tag after the fast-forward"
        return 1
    fi
}

# ^ invariant rc 0 = tag $1 is exported into the work dir's tree; rc 1 = REPLY says why not; archive and tar run in the foreground, each rc is taken
# ^ external git archive runs the filters the checkout's own config names and expands export-subst (probed) => the checkout's owner is trusted
# ^ invariant archive and tar each run under the step limit through autoupdate_limited; it remembers one the limit ended, the run is recorded as failed
autoupdate_export() {
    local tree="$AU_WORK/tree"
    if ! mkdir -- "$tree"; then
        REPLY="cannot create $tree"
        return 1
    fi
    if ! autoupdate_limited "$GSG_UPDATE_STEP_SECONDS" "git archive" "${AU_GIT[@]}" archive --format=tar "refs/tags/$1" >"$AU_WORK/export.tar" 2>"$AU_WORK/git.err" </dev/null; then
        autoupdate_git_line err
        REPLY="git archive $1 failed${REPLY:+, $REPLY}"
        return 1
    fi
    if ! autoupdate_limited "$GSG_UPDATE_STEP_SECONDS" "tar" tar -xf "$AU_WORK/export.tar" -C "$tree" 2>"$AU_WORK/git.err" </dev/null; then
        autoupdate_git_line err
        REPLY="the export of $1 cannot be unpacked${REPLY:+, $REPLY}"
        return 1
    fi
    if [ ! -f "$tree/bin/$GSG_NAME" ] || [ ! -x "$tree/bin/$GSG_NAME" ]; then
        REPLY="the export of $1 holds no executable bin/$GSG_NAME"
        return 1
    fi
}

# ^ security the child install gets no flags and /dev/null on stdin => it never upgrades git, takes over the system git or replaces a hooksPath
# ^ order nothing is sourced after the child returns; the installer replaced the share tree this shell's libraries came from
# ^ invariant rc 0 = exit status $1 is one GNU timeout gives when its limit ended the command
autoupdate_rc_timed_out() { [ "$1" -eq "$GSG_UPDATE_RC_TIMEOUT" ] || [ "$1" -eq "$GSG_UPDATE_RC_KILLED" ]; }

# ^ invariant updated only when the child exits 0 AND the installed VERSION is $1; anything else is failed, install-failed
# ^ invariant an install its limit ended is recorded as timed out, whatever it printed before
autoupdate_child_install() {
    local x="$1" rc=0
    # ^ coupled autoupdate_first_line copies a line of install.err into the record status shows => CLICOLOR_FORCE would put escape codes in it
    GSG_UPDATE_LOCK_PID="$$" env -u CLICOLOR_FORCE "$TIMEOUT_BIN" -k "$GSG_UPDATE_INSTALL_KILL_SECONDS" "$GSG_UPDATE_INSTALL_SECONDS" "$AU_WORK/tree/bin/$GSG_NAME" install \
        >"$AU_WORK/install.out" 2>"$AU_WORK/install.err" </dev/null || rc=$?
    cat -- "$AU_WORK/install.out" || true
    cat -- "$AU_WORK/install.err" >&2 || true
    if [ "$rc" -ne 0 ]; then
        autoupdate_first_line "$AU_WORK/install.err"
        if autoupdate_rc_timed_out "$rc"; then REPLY="install timed out after $GSG_UPDATE_INSTALL_SECONDS s"; fi
        autoupdate_outcome failed install-failed "${REPLY:-install exit $rc}"
        return 1
    fi
    autoupdate_installed_version
    if [ "$REPLY" != "$x" ]; then
        autoupdate_outcome failed install-failed "install exit 0, the installed VERSION is [$REPLY], expected $x"
        return 1
    fi
    autoupdate_outcome updated
}

# ^ invariant X is read from git objects (HEAD:VERSION), never from the work tree; HEAD must be the commit of tag vX or nothing is installed
# ^ invariant owner and follower share this step; a follower runs only rev-parse, show and archive on the checkout
autoupdate_install_step() {
    local x rc=0
    if ! autoupdate_git show HEAD:VERSION; then
        autoupdate_git_line err
        autoupdate_outcome skipped bad-version "$REPLY"
        return 1
    fi
    x="$(<"$AU_WORK/git.out")"
    if [[ ! $x =~ $GSG_UPDATE_VERSION_RE ]]; then
        autoupdate_outcome skipped bad-version "VERSION at HEAD is not x.y.z"
        return 1
    fi
    AU_TO="$x"
    if ! autoupdate_at_commit "refs/tags/v$x"; then
        autoupdate_outcome skipped not-at-tag "HEAD is not the commit of tag v$x"
        return 1
    fi
    autoupdate_needs_install "$x" || rc=$?
    if [ "$rc" -eq 2 ]; then
        autoupdate_outcome skipped bad-version "the installed version is not x.y.z"
        return 1
    fi
    if [ "$rc" -eq 1 ]; then
        autoupdate_outcome current
        return 0
    fi
    if ! autoupdate_export "v$x"; then
        autoupdate_outcome failed install-failed "$REPLY"
        return 1
    fi
    autoupdate_child_install "$x"
}

# ^ invariant rc 0 = the installed version is readable, the settings are loaded, the tools are usable, the work dir and the git options are set
# ^ order the installed version is judged before any fetch => a bad one skips with the checkout's refs untouched
autoupdate_prepare() {
    local why rc=0
    autoupdate_needs_install 0.0.0 || rc=$?
    if [ "$rc" -eq 2 ]; then
        autoupdate_outcome skipped bad-version "the installed version is not x.y.z"
        return 1
    fi
    if ! load_settings "$GSG_SHARE/settings"; then
        autoupdate_outcome failed "" "the settings file of the installed copy cannot be loaded"
        return 1
    fi
    # ^ external Windows has no setsid; its fetch runs under timeout alone (autoupdate_fetch)
    if why="$(tool_unusable timeout "${TIMEOUT_BIN:-}")" || { [ "$AU_ROLE" = owner ] && ! tools_is_windows && why="$(tool_unusable setsid "${SETSID_BIN:-}")"; }; then
        autoupdate_outcome failed "" "$why"
        return 1
    fi
    # ^ order the work dir before the git environment; its query runs under a limit and captures into the work dir
    if ! autoupdate_work_make || ! autoupdate_git_env; then
        autoupdate_outcome failed "" "cannot prepare git or a work dir in $GSG_STATE_DIR"
        return 1
    fi
    autoupdate_git_init "$1" "$AU_ROLE"
}

# ^ invariant runs under the lock and sets the outcome (AU_*); its rc only says whether a step stopped early, autoupdate_finish reads AU_RESULT
# ^ order the state is read again after the lock is taken => an install finished a moment ago is seen, its version is never taken for an old one
autoupdate_cycle() {
    local co
    if ! state_read; then
        autoupdate_outcome failed "" "the state file cannot be read"
        return 1
    fi
    co="$ST_SOURCE_CHECKOUT"
    if [ -z "$co" ] || [ ! -d "$co" ] || { [ ! -e "$co/.git" ] && [ ! -L "$co/.git" ]; }; then
        autoupdate_outcome skipped checkout-missing "$co"
        return 1
    fi
    AU_ROLE="$(autoupdate_role "$co")" || {
        AU_ROLE=""
        autoupdate_outcome skipped not-a-plain-checkout "$co/.git is not a directory or no repository"
        return 1
    }
    autoupdate_prepare "$co" || return 1
    if [ "$AU_ROLE" = owner ]; then autoupdate_owner_advance || return 1; fi
    autoupdate_install_step
}

# shellcheck disable=SC2329
autoupdate_cleanup() {
    autoupdate_work_remove
    autoupdate_lock_release
}

# ^ order the work dir is removed and the record written before the one line is printed (stderr for failed), the lock is released after it
# ^ invariant a cycle ending without an outcome is failed; one with a call its limit ended is failed naming the call, whatever its step concluded
# ^ invariant rc 0 for current, updated and skipped, 1 for failed and for a record or a lock problem
autoupdate_finish() {
    local rc=0 text
    if [ -n "$AU_TIMED_OUT" ]; then autoupdate_outcome failed "" "$AU_TIMED_OUT"; fi
    if [ -z "$AU_RESULT" ]; then autoupdate_outcome failed "" "the cycle ended without an outcome"; fi
    autoupdate_work_remove
    autoupdate_record_write || rc=1
    case "$AU_RESULT" in
        updated) text="updated ${AU_FROM:-nothing} -> $AU_TO" ;;
        current) text="current${AU_FROM:+, $AU_FROM is installed}" ;;
        *) text="$AU_RESULT${AU_REASON:+ ($AU_REASON)}${AU_DETAIL:+: $AU_DETAIL}" ;;
    esac
    if [ "$AU_RESULT" = failed ]; then
        ui_prefix 2 PROBLEM
        printf '%s%s: update: %s\n' "$REPLY" "$GSG_NAME" "$text" >&2
        rc=1
    else
        if [ "$AU_RESULT" = skipped ]; then ui_prefix 1 info; else ui_prefix 1 ok; fi
        printf '%s%s: update: %s\n' "$REPLY" "$GSG_NAME" "$text"
    fi
    autoupdate_lock_release || rc=1
    return "$rc"
}

# ^ invariant the entry point of "git-secret-guard update"; with auto_update not yes it prints one line, takes no lock and writes nothing
# ^ invariant a lock held by another run is a skip (locked) with the record written; the traps release the lock and the work dir on every exit
# ^ hazard bash runs a trap only after its foreground child returns => a signal during the child install is acted on when the install ends or times out
autoupdate_run() {
    local rc=0
    paths_init || return 1
    lifecycle_require_git || return 1
    state_read || return 1
    if [ "$ST_EXISTS" -ne 1 ] || [ "$ST_AUTO_UPDATE" != yes ]; then
        ui_prefix 1 ok
        printf '%s%s: auto-update is off\n' "$REPLY" "$GSG_NAME"
        return 0
    fi
    AU_ROLE="" AU_RESULT="" AU_REASON="" AU_DETAIL="" AU_TO="" AU_WORK="" AU_TIMED_OUT=""
    autoupdate_installed_version
    AU_FROM="$REPLY"
    trap autoupdate_cleanup EXIT
    trap 'exit "$GSG_UPDATE_EXIT_HUP"' HUP
    trap 'exit "$GSG_UPDATE_EXIT_INT"' INT
    trap 'exit "$GSG_UPDATE_EXIT_TERM"' TERM
    autoupdate_lock_take || rc=$?
    case "$rc" in
        0) autoupdate_cycle || true ;;
        1)
            AU_ROLE="$(autoupdate_role "$ST_SOURCE_CHECKOUT")" || AU_ROLE=""
            if [ "$DR_REC_LOCK_NOT_LINK" -eq 1 ]; then
                autoupdate_outcome skipped locked "a directory, not a lock, is at $GSG_UPDATE_LOCK"
            else
                autoupdate_outcome skipped locked "process $DR_REC_LOCK_HOLDER holds $GSG_UPDATE_LOCK"
            fi
            ;;
        *) autoupdate_outcome failed "" "the lock $GSG_UPDATE_LOCK cannot be taken" ;;
    esac
    autoupdate_finish
}
