# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled the git upgrade module of the rpm class (Rocky, RHEL, AlmaLinux, CentOS, Fedora); registered in lib/gitup.sh, contract in CONTRIBUTING.md
# ^ external dnf 4 (Rocky 9) and dnf 5 (Fedora 44) both accept the repoquery call in gitup_rpm_query (probed in containers)

GITUP_RPM_DEPS=(gcc make perl xz tar openssl-devel zlib-devel libcurl-devel expat-devel pcre2-devel perl-ExtUtils-MakeMaker)
GITUP_RPM_FLAGS=(NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 USE_LIBPCRE2=1)
GITUP_RPM_FAILED=()
GITUP_RPM_CANDIDATE=""
GITUP_DNF=""

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
# ^ security a repository cannot hang the plan or enrol a key
gitup_rpm_dnf() {
    "$INSTALL_TIMEOUT_BIN" -k 5 "$GITUP_QUERY_TIMEOUT" "$GITUP_DNF" --assumeno -q "$@" </dev/null
}

gitup_rpm_query() {
    gitup_rpm_dnf "$@" repoquery --latest-limit=1 --queryformat '%{version}\n' git-core
}

# ^ invariant a failed all-repositories query is repeated per enabled repository; failing repositories are named in GITUP_RPM_FAILED
gitup_rpm_find_failed() {
    local listing id rest started="$SECONDS" budget=$((GITUP_QUERY_TIMEOUT * 2))
    GITUP_RPM_FAILED=()
    listing="$(gitup_rpm_dnf repolist --enabled)" || {
        GITUP_RPM_FAILED+=("(the list of enabled repositories could not be read)")
        return 0
    }
    while read -r id rest; do
        if [ -z "$id" ] || [ "$id" = repo ] || [[ ! $id =~ ^[A-Za-z0-9_.:-]+$ ]]; then continue; fi
        if [ $((SECONDS - started)) -ge "$budget" ]; then
            GITUP_RPM_FAILED+=("(the other repositories were not tried: the retry budget of ${budget}s was used up)")
            break
        fi
        gitup_rpm_query "--disablerepo=*" "--enablerepo=$id" >/dev/null || GITUP_RPM_FAILED+=("$id")
    done <<<"$listing"
    if [ "${#GITUP_RPM_FAILED[@]}" -eq 0 ]; then GITUP_RPM_FAILED+=("(the query failed as a whole)"); fi
}

# ^ invariant sets GITUP_RPM_CANDIDATE = the newest git-core the enabled repositories offer ("" = none) and GITUP_RPM_FAILED; rc 1 = a query failed
gitup_rpm_candidate() {
    local out v rc=0
    GITUP_RPM_CANDIDATE="" GITUP_RPM_FAILED=()
    out="$(gitup_rpm_query)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        gitup_rpm_find_failed
        return 1
    fi
    while IFS= read -r v; do
        if [[ ! $v =~ ^[0-9]+(\.[0-9]+)*$ ]]; then continue; fi
        if [ -z "$GITUP_RPM_CANDIDATE" ] || gitup_version_at_least "$v" "$GITUP_RPM_CANDIDATE"; then GITUP_RPM_CANDIDATE="$v"; fi
    done <<<"$out"
}

GITUP_RPM_KEYNOTE="dnf install -y answers yes to every prompt, a repository signing key import included: a key that is pending for a configured repository would be imported by this step; the read-only query above imported none"

# ^ invariant sets GITUP_SRC_DEPS (the dependency install command with the full dnf path) and GITUP_SRC_FLAGS for the shared source build; rc 1 = no usable dnf
gitup_rpm_prepare() {
    gitup_rpm_find_dnf || return 1
    GITUP_SRC_DEPS=("$GITUP_DNF" install -y "${GITUP_RPM_DEPS[@]}")
    GITUP_SRC_FLAGS=("${GITUP_RPM_FLAGS[@]}")
}

gitup_rpm_plan_upgrade() {
    local new="$GITUP_PREFIX/bin/git" reason name
    if [ -x "$new" ] && install_git_is_new_enough "$new" && gitup_source_read_manifests && [ "${#GITUP_PARTIALS[@]}" -eq 0 ]; then
        GITUP_ROUTE=path-fix GITUP_FOUND_GIT="$new"
        printf '  route: path-fix; %s is already git %s, only PATH is wrong\n' "$new" "$(install_git_version "$new")"
        return 0
    fi
    if ! gitup_rpm_prepare; then
        printf '  dnf was not found in the system path (%s) or is not root-owned, and both routes need it; install dnf, or build git yourself, see docs/platforms.md\n' "$GITUP_SYSTEM_PATH"
        return 1
    fi
    if gitup_rpm_candidate && [ -n "$GITUP_RPM_CANDIDATE" ] && gitup_version_at_least "$GITUP_RPM_CANDIDATE" "$GSG_MIN_GIT_MAJOR.$GSG_MIN_GIT_MINOR"; then
        GITUP_ROUTE=package
        printf '  route: package; %s offers git-core %s (the query that found it was read-only: it imported no key and answered no prompt)\n' "$GITUP_DNF" "$GITUP_RPM_CANDIDATE"
        gitup_plan_priv "$GITUP_DNF install -y git-core"
        gitup_plan_note "$GITUP_RPM_KEYNOTE"
        return 0
    fi
    for name in "${GITUP_RPM_FAILED[@]}"; do
        printf '  repository %s could not be queried (it timed out, or it needs a key that is not imported; none is imported here)\n' "$name"
    done
    reason="no enabled repository offers git-core 2.54 or newer"
    if [ -n "$GITUP_RPM_CANDIDATE" ]; then reason="the newest git-core the repositories offer is $GITUP_RPM_CANDIDATE"; fi
    if [ "${#GITUP_RPM_FAILED[@]}" -gt 0 ]; then reason="a repository could not be queried, so the package route is not trusted"; fi
    gitup_source_pins || return 1
    gitup_source_print_plan "$reason"
    gitup_plan_note "$GITUP_RPM_KEYNOTE"
}

# ^ invariant the refresh plan is the shared one; rc 0 = a stale build of ours, rc 2 = a takeover blocks the rebuild, rc 1 = nothing printed
gitup_rpm_plan_refresh() { gitup_source_plan_refresh gitup_rpm_prepare; }

gitup_rpm_plan() {
    GITUP_ROUTE=""
    case "$1" in
        upgrade) gitup_rpm_plan_upgrade ;;
        refresh) gitup_rpm_plan_refresh ;;
        *) return 1 ;;
    esac
}

gitup_rpm_apply_package() {
    gitup_elevate "$GITUP_DNF" install -y git-core || {
        gitup_changed_add "dnf install git-core was started and failed, so the package manager may have changed packages (see rpm -q git-core)"
        return 1
    }
    gitup_changed_add "dnf installed git-core from the repositories"
    GITUP_NEW_GIT="$GITUP_USRBIN/git"
}

gitup_rpm_apply() {
    gitup_rpm_prepare || {
        printf '%s: dnf was not found in the system path (%s) or is not root-owned\n' "$GSG_NAME" "$GITUP_SYSTEM_PATH" >&2
        return 1
    }
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
