# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled the git upgrade module of the rpm class (Rocky, RHEL, AlmaLinux, CentOS, Fedora); registered in lib/gitup.sh, contract in CONTRIBUTING.md
# ^ external dnf 4 (Rocky 9) and dnf 5 (Fedora 44) both accept the repoquery call in gitup_rpm_query (probed in containers)

GITUP_RPM_DEPS=(gcc make perl-interpreter xz tar openssl-devel zlib-devel libcurl-devel expat-devel pcre2-devel perl-ExtUtils-MakeMaker)
GITUP_RPM_FLAGS=(NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 USE_LIBPCRE2=1)
GITUP_RPM_FAILED=()
GITUP_RPM_WHY=()
GITUP_RPM_READ=()
GITUP_RPM_READ_VER=()
GITUP_RPM_INCOMPLETE=0
GITUP_RPM_MISSING=()
GITUP_RPM_PKG_CMD=()
GITUP_RPM_PLANNED=0
GITUP_RPM_CANDIDATE=""
GITUP_DNF=""
GITUP_RPM_VERB=install

# ^ coupled the takeover is part of this module; its library loads with it and lib/gitup.sh and the CLI do not list it
# shellcheck source=lib/gitup_takeover.sh
source "$GSG_ROOT/lib/gitup_takeover.sh" || return 1

# ^ security root runs this dnf => found in the fixed system path only, root-owned, not writable by others; the plan prints its full path
gitup_rpm_find_dnf() {
    gitup_system_bin dnf || true
    GITUP_DNF="$REPLY"
    [ -n "$GITUP_DNF" ]
}


# ^ security stdin is /dev/null, the call is bounded, and --assumeno answers every prompt (a GPG key import included) with no
# ^ security a repository cannot hang the plan or enrol a key; stdout and stderr come back together in one variable, no file holds dnf's text
# ^ external LC_ALL=C pins the wording of dnf's table and errors, as the apt route does
gitup_rpm_run() {
    LC_ALL=C "$INSTALL_TIMEOUT_BIN" -k 5 "$GITUP_QUERY_TIMEOUT" "$GITUP_DNF" --assumeno "$@" </dev/null 2>&1
}

gitup_rpm_query() {
    gitup_rpm_run -q "$@" repoquery --latest-limit=1 --queryformat '%{version}\n' git-core
}

# ^ invariant the repository list is stdout only => an error line is never read as a repository id
gitup_rpm_list() {
    LC_ALL=C "$INSTALL_TIMEOUT_BIN" -k 5 "$GITUP_QUERY_TIMEOUT" "$GITUP_DNF" --assumeno -q repolist --enabled </dev/null 2>/dev/null
}

# ^ invariant sets REPLY = the first "Error:" line of the text, control characters replaced and cut, "" when none; the key-import text is never shown
gitup_rpm_error_line() {
    local line="" l
    while IFS= read -r l; do
        if [[ $l == Error:* ]]; then
            line="${l//[^[:print:]]/?}"
            break
        fi
    done <<<"$1"
    trunc_text "$line" 200
}

# ^ invariant sets REPLY = the newest version among the version lines of the text, "" when none
gitup_rpm_newest() {
    local v
    REPLY=""
    while IFS= read -r v; do
        if [[ ! $v =~ ^[0-9]+(\.[0-9]+)*$ ]]; then continue; fi
        if [ -z "$REPLY" ] || gitup_version_at_least "$v" "$REPLY"; then REPLY="$v"; fi
    done <<<"$1"
}

# ^ invariant a failed whole query is repeated per repository => unreadable ones in GITUP_RPM_FAILED (reason in GITUP_RPM_WHY), readable ones keep their answer
# ^ invariant a parenthesised GITUP_RPM_FAILED entry or no readable repository = GITUP_RPM_INCOMPLETE=1
gitup_rpm_find_failed() {
    local listing id rest rc out whole="$1" started="$SECONDS" budget=$((GITUP_QUERY_TIMEOUT * 2))
    GITUP_RPM_FAILED=() GITUP_RPM_WHY=() GITUP_RPM_READ=() GITUP_RPM_READ_VER=() GITUP_RPM_INCOMPLETE=0
    listing="$(gitup_rpm_list)" || {
        GITUP_RPM_FAILED+=("(the list of enabled repositories could not be read)")
        GITUP_RPM_WHY+=("")
        GITUP_RPM_INCOMPLETE=1
        return 0
    }
    while read -r id rest; do
        if [ -z "$id" ] || [ "$id" = repo ] || [[ ! $id =~ ^[A-Za-z0-9_.:-]+$ ]]; then continue; fi
        if [ $((SECONDS - started)) -ge "$budget" ]; then
            GITUP_RPM_FAILED+=("(the other repositories were not tried: the retry budget of ${budget}s was used up)")
            GITUP_RPM_WHY+=("")
            GITUP_RPM_INCOMPLETE=1
            break
        fi
        rc=0
        out="$(gitup_rpm_query "--disablerepo=*" "--enablerepo=$id")" || rc=$?
        if [ "$rc" -eq 0 ]; then
            gitup_rpm_newest "$out"
            GITUP_RPM_READ+=("$id")
            GITUP_RPM_READ_VER+=("$REPLY")
            continue
        fi
        gitup_rpm_error_line "$out"
        if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then REPLY="timed out"; fi
        GITUP_RPM_FAILED+=("$id")
        GITUP_RPM_WHY+=("$REPLY")
    done <<<"$listing"
    if [ "${#GITUP_RPM_FAILED[@]}" -eq 0 ]; then
        GITUP_RPM_FAILED+=("(the query failed as a whole, no repository was named by the retry)")
        GITUP_RPM_WHY+=("$whole")
        GITUP_RPM_INCOMPLETE=1
    elif [ "${#GITUP_RPM_READ[@]}" -eq 0 ]; then
        GITUP_RPM_INCOMPLETE=1
    fi
}

# ^ invariant sets GITUP_RPM_CANDIDATE = newest git-core of the repositories read ("" = none) and the find_failed lists; rc 1 = the whole query failed
gitup_rpm_candidate() {
    local out rc=0 i
    GITUP_RPM_CANDIDATE="" GITUP_RPM_FAILED=() GITUP_RPM_WHY=() GITUP_RPM_READ=() GITUP_RPM_READ_VER=() GITUP_RPM_INCOMPLETE=0
    out="$(gitup_rpm_query)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        gitup_rpm_error_line "$out"
        gitup_rpm_find_failed "$REPLY"
        for i in "${!GITUP_RPM_READ_VER[@]}"; do
            if [ -z "${GITUP_RPM_READ_VER[$i]}" ]; then continue; fi
            if [ -z "$GITUP_RPM_CANDIDATE" ] || gitup_version_at_least "${GITUP_RPM_READ_VER[$i]}" "$GITUP_RPM_CANDIDATE"; then GITUP_RPM_CANDIDATE="${GITUP_RPM_READ_VER[$i]}"; fi
        done
        return 1
    fi
    gitup_rpm_newest "$out"
    GITUP_RPM_CANDIDATE="$REPLY"
    gitup_rpm_read_listing
}

# ^ external dnf 4.14 skips a repo file the user cannot read (0600), warns and returns 0 => it is not in this list, and the root command enables only these ids
# ^ invariant GITUP_RPM_READ = ids of the enabled repositories after a successful whole query; no list = an incomplete check
gitup_rpm_read_listing() {
    local listing id rest
    listing="$(gitup_rpm_list)" || listing=""
    while read -r id rest; do
        if [ -z "$id" ] || [ "$id" = repo ] || [[ ! $id =~ ^[A-Za-z0-9_.:-]+$ ]]; then continue; fi
        GITUP_RPM_READ+=("$id")
    done <<<"$listing"
    if [ "${#GITUP_RPM_READ[@]}" -eq 0 ]; then
        GITUP_RPM_FAILED+=("(the list of enabled repositories could not be read or holds no repository)")
        GITUP_RPM_WHY+=("")
        GITUP_RPM_INCOMPLETE=1
    fi
}

# ^ invariant the note about prompts, worded by what the plan really runs as root; no dependency install means no prompt to answer
gitup_rpm_keynote() {
    local where="this step"
    if [ "$1" = package ]; then where="this install (only the repositories the plan read are enabled)"; fi
    if [ "$1" = source ] && [ "${#GITUP_SRC_DEPS[@]}" -eq 0 ]; then
        printf 'no dnf install runs in this plan, so no repository signing key can be imported by it'
        return 0
    fi
    printf 'dnf install -y answers yes to every prompt, a repository signing key import included: a key pending for a configured repository would be imported by %s; the read-only query above imported none' "$where"
}

# ^ invariant sets GITUP_SRC_DEPS (only names rpm -q lacks, empty when none), GITUP_SRC_FLAGS and GITUP_RPM_VERB once, at plan time; rc 1 = no dnf
# ^ why only the missing names, not all; dnf install -y also upgrades an installed name when a newer build exists
# ^ order apply reuses these values after the plan; it never recomputes them
gitup_rpm_prepare() {
    local dep rpm_bin="" missing=()
    gitup_rpm_find_dnf || return 1
    if gitup_system_bin rpm; then rpm_bin="$REPLY"; fi
    for dep in "${GITUP_RPM_DEPS[@]}"; do
        if [ -n "$rpm_bin" ] && "$rpm_bin" -q --qf '%{NAME}\n' "$dep" >/dev/null 2>&1; then continue; fi
        missing+=("$dep")
    done
    GITUP_RPM_MISSING=("${missing[@]}")
    GITUP_SRC_DEPS=()
    if [ "${#missing[@]}" -gt 0 ]; then GITUP_SRC_DEPS=("$GITUP_DNF" install -y "${missing[@]}"); fi
    GITUP_SRC_FLAGS=("${GITUP_RPM_FLAGS[@]}")
    # ^ external dnf 5 answers "already installed, nothing to do" to install of an older git-core (Fedora 44); upgrade ran there, on dnf 4 it is untested
    GITUP_RPM_VERB=install
    if [ -n "$rpm_bin" ] && "$rpm_bin" -q --qf '%{NAME}\n' git-core >/dev/null 2>&1; then GITUP_RPM_VERB=upgrade; fi
    GITUP_RPM_PLANNED=1
}

# ^ invariant prints the dependency install effect as a note; counts come from dnf --assumeno without -q (dnf 4 hides the table under -q), else the cause
# ^ external as a user dnf 4 refuses install ("superuser privileges"); as root the same call prints the table and changes nothing
gitup_rpm_deps_note() {
    local out line counts="" rc=0 cause
    if [ "${#GITUP_RPM_MISSING[@]}" -eq 0 ]; then
        gitup_plan_note "every build dependency is installed, so no dependency install runs"
        return 0
    fi
    out="$(gitup_rpm_run install "${GITUP_RPM_MISSING[@]}")" || rc=$?
    while IFS= read -r line; do
        if [[ $line =~ ^[[:space:]]*((Install|Installing|Upgrade|Upgrading|Remove|Removing|Downgrade|Downgrading)[:\ ]+[0-9]+\ [Pp]ackages?)$ ]]; then
            line="${line#"${line%%[![:space:]]*}"}"
            counts+="${counts:+; }$line"
        fi
    done <<<"$out"
    if [ -n "$counts" ]; then
        gitup_plan_note "dnf may upgrade packages that are already installed when a missing dependency needs a newer version of one; dry run (--assumeno): $counts"
        return 0
    fi
    cause="dnf printed no table (exit $rc)"
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then cause="the dry run timed out after ${GITUP_QUERY_TIMEOUT}s"; fi
    if [[ $out == *"superuser privileges"* ]]; then cause="dnf refuses a dry run of install to a user who is not root"; fi
    gitup_plan_note "dnf may upgrade packages that are already installed when a missing dependency needs a newer version of one; the size was not counted: $cause"
}

# ^ invariant prints the repositories the user could not read with the route's tail, dnf's error line after the sentence saying it proves nothing
gitup_rpm_print_unread() {
    local i name
    for i in "${!GITUP_RPM_FAILED[@]}"; do
        name="${GITUP_RPM_FAILED[$i]}"
        if [[ $name == "("* ]]; then
            printf '  %s\n' "$name"
        else
            printf '  repository %s could not be read by this unprivileged query; a repository that works for root can fail here, so this does not mean it is broken%s\n' "$name" "$1"
        fi
        if [ -n "${GITUP_RPM_WHY[$i]}" ]; then printf '    dnf said: %s\n' "${GITUP_RPM_WHY[$i]}"; fi
    done
}

# ^ invariant package route = git >= 2.54 and a complete check; root enables only the repositories read (--disablerepo=* --enablerepo=ID), failing closed
gitup_rpm_plan_package() {
    local id enabled=() shown=""
    for id in "${GITUP_RPM_READ[@]}"; do
        enabled+=("--enablerepo=$id")
        shown+="${shown:+, }$id"
    done
    GITUP_RPM_PKG_CMD=("$GITUP_DNF" "$GITUP_RPM_VERB" -y "--disablerepo=*" "${enabled[@]}" git-core)
    GITUP_ROUTE=package
    gitup_rpm_print_unread " (not enabled for root: only the repositories that were read are used)"
    printf '  route: package; %s offers git-core %s (the query that found it was read-only: it imported no key and answered no prompt)\n' "$GITUP_DNF" "$GITUP_RPM_CANDIDATE"
    printf '  only the repositories read are enabled for root (%s); a repository file this user cannot read is not among them, and a dependency of git-core found only elsewhere makes dnf fail instead\n' "$shown"
    gitup_plan_priv "${GITUP_RPM_PKG_CMD[*]}"
    gitup_plan_note "$(gitup_rpm_keynote package)"
}

gitup_rpm_plan_upgrade() {
    local new="$GITUP_PREFIX/bin/git" reason qrc=0 offers=0
    if [ -x "$new" ] && install_git_is_new_enough "$new" && gitup_source_read_manifests && [ "${#GITUP_PARTIALS[@]}" -eq 0 ]; then
        GITUP_ROUTE=path-fix GITUP_FOUND_GIT="$new"
        printf '  route: path-fix; %s is already git %s, only PATH is wrong\n' "$new" "$(install_git_version "$new")"
        return 0
    fi
    if ! gitup_rpm_prepare; then
        printf '  dnf was not found in the system path (%s) or is not root-owned, and both routes need it; install dnf, or build git yourself, see docs/platforms.md\n' "$GITUP_SYSTEM_PATH"
        return 1
    fi
    gitup_rpm_candidate || qrc=$?
    if [ -n "$GITUP_RPM_CANDIDATE" ] && gitup_version_at_least "$GITUP_RPM_CANDIDATE" "$GSG_MIN_GIT_MAJOR.$GSG_MIN_GIT_MINOR"; then offers=1; fi
    if [ "$offers" -eq 1 ] && [ "$GITUP_RPM_INCOMPLETE" -eq 0 ]; then
        gitup_rpm_plan_package
        return 0
    fi
    gitup_rpm_print_unread " (not considered for the route)"
    reason="no enabled repository offers git-core 2.54 or newer"
    if [ -n "$GITUP_RPM_CANDIDATE" ]; then reason="the newest git-core the repositories offer is $GITUP_RPM_CANDIDATE"; fi
    if [ "$GITUP_RPM_INCOMPLETE" -eq 1 ]; then reason="the check of the repositories was incomplete, so the package route is not trusted"; fi
    if [ "$qrc" -ne 0 ] && [ "$GITUP_RPM_INCOMPLETE" -eq 0 ]; then reason="the repositories that could be read offer ${GITUP_RPM_CANDIDATE:-no git-core}, not 2.54 or newer"; fi
    gitup_source_pins || return 1
    gitup_source_print_plan "$reason" || return 1
    gitup_rpm_deps_note
    gitup_plan_note "$(gitup_rpm_keynote source)"
}

# ^ invariant the refresh plan is the shared one; rc 0 = a stale build of ours, rc 2 = a takeover blocks the rebuild, rc 1 = nothing printed
gitup_rpm_plan_refresh() {
    local rc=0
    gitup_source_plan_refresh gitup_rpm_prepare || rc=$?
    if [ "$rc" -eq 0 ]; then gitup_rpm_deps_note; fi
    return "$rc"
}

gitup_rpm_plan() {
    GITUP_ROUTE=""
    case "$1" in
        upgrade) gitup_rpm_plan_upgrade ;;
        refresh) gitup_rpm_plan_refresh ;;
        *) return 1 ;;
    esac
}

gitup_rpm_apply_package() {
    gitup_elevate "${GITUP_RPM_PKG_CMD[@]}" || {
        gitup_changed_add "dnf $GITUP_RPM_VERB git-core was started and failed, so the package manager may have changed packages (see rpm -q git-core)"
        return 1
    }
    gitup_changed_add "dnf ran $GITUP_RPM_VERB -y from the repositories (${GITUP_RPM_PKG_CMD[*]:2})"
    GITUP_NEW_GIT="$GITUP_USRBIN/git"
}

# ^ invariant apply runs what the plan printed => only the dnf lookup is repeated, never the rpm questions or the repository query
gitup_rpm_apply() {
    local planned_dnf="$GITUP_DNF"
    gitup_rpm_find_dnf || {
        printf '%s: dnf was not found in the system path (%s) or is not root-owned\n' "$GSG_NAME" "$GITUP_SYSTEM_PATH" >&2
        return 1
    }
    if [ "$GITUP_RPM_PLANNED" -ne 1 ] || [ "$planned_dnf" != "$GITUP_DNF" ]; then
        printf '%s: the rpm module has no plan for this dnf (%s) to apply\n' "$GSG_NAME" "$GITUP_DNF" >&2
        return 1
    fi
    case "$GITUP_ROUTE" in
        package) gitup_rpm_apply_package ;;
        source)
            gitup_source_apply || return 1
            GITUP_NEW_GIT="$GITUP_PREFIX/bin/git"
            ;;
        *)
            printf '%s: the rpm module has no route [%s] to apply\n' "$GSG_NAME" "$GITUP_ROUTE" >&2
            return 1
            ;;
    esac
}

# ^ invariant the optional takeover capability is all five functions or none, and the contract check enforces it; the work is in lib/gitup_takeover.sh
gitup_rpm_takeover_supported() {
    local given own
    given="$(realpath -- "$1")" || return 1
    own="$(realpath -- "$GITUP_USRBIN/git")" || return 1
    [ "$given" = "$own" ]
}
gitup_rpm_takeover_plan() { gitup_tk_plan "$@"; }
gitup_rpm_takeover_apply() { gitup_tk_apply "$@"; }
gitup_rpm_takeover_restore() { gitup_tk_restore "$@"; }
gitup_rpm_takeover_status() { gitup_tk_status "$@"; }

# ^ invariant the core calls it once when the process ends inside apply or takeover_apply; only an unfinished takeover has anything to undo
gitup_rpm_abort() { gitup_tk_abort; }
