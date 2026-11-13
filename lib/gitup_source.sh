# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled shared pinned source build of the upgrade modules; a module sets GITUP_SRC_DEPS and GITUP_SRC_FLAGS before gitup_source_apply
# ^ external procedure of the reference host (2026-10-30) plus checks; docs/platforms.md#rhel-rocky-and-fedora-rpm has the facts per step

# ^ invariant an optional privileged command a module runs before the dependency install (apt-get update); empty for modules without one
GITUP_SRC_PRE=()
GITUP_SRC_DEPS=()
GITUP_SRC_FLAGS=()
GITUP_BUILD_DIR=""
GITUP_BUILD_NEED_MB=570
GITUP_BUILD_MIN_KB=819200
GITUP_PREFIX_MIN_KB=307200
GITUP_BUILD_SECONDS=2700
GITUP_MANIFEST_MAX_LINES=20000
GITUP_RM_CHUNK=200
GITUP_MANIFESTS=()
GITUP_REMOVED_COUNT=0
GITUP_TARBALL="" GITUP_MANTARBALL="" GITUP_SRC_DIR="" GITUP_STAGE="" GITUP_MAKE=""

# ^ invariant sets GITUP_PIN_VER, GITUP_PIN_SHA, GITUP_PIN_MAN_SHA from the git and git-manpages source rows; rc 1 = missing row or versions differ
gitup_source_pins() {
    local row mrow
    row="$(tools_lock_lookup "$(tools_lock_path)" git source)" || return 1
    mrow="$(tools_lock_lookup "$(tools_lock_path)" git-manpages source)" || return 1
    GITUP_PIN_VER="${row%% *}"
    GITUP_PIN_SHA="${row##* }"
    GITUP_PIN_MAN_SHA="${mrow##* }"
    if [ "${mrow%% *}" != "$GITUP_PIN_VER" ]; then
        printf '%s: tools.lock pins git %s but git-manpages %s; the two must be the same version\n' "$GSG_NAME" "$GITUP_PIN_VER" "${mrow%% *}" >&2
        return 1
    fi
}

# ^ invariant GITUP_KNOWN holds every path in a MANIFEST of ours below the prefix, GITUP_MANIFESTS the MANIFEST files; rc 1 = unreadable or too long
gitup_source_read_manifests() {
    local f line n kind
    declare -gA GITUP_KNOWN=() GITUP_DONE=()
    GITUP_MANIFESTS=() GITUP_PARTIALS=()
    for f in "$GITUP_PREFIX"/share/doc/git-*-local/MANIFEST "$GITUP_PREFIX"/share/doc/git-*-local/MANIFEST.partial; do
        if [ ! -f "$f" ]; then continue; fi
        GITUP_MANIFESTS+=("$f")
        kind=finished
        if [[ $f == *.partial ]]; then
            GITUP_PARTIALS+=("$f")
            kind=partial
        fi
        n=0
        while IFS= read -r line || [ -n "$line" ]; do
            n=$((n + 1))
            if [ "$n" -gt "$GITUP_MANIFEST_MAX_LINES" ]; then
                printf '%s: %s has more than %s lines\n' "$GSG_NAME" "$f" "$GITUP_MANIFEST_MAX_LINES" >&2
                return 1
            fi
            if [ -z "$line" ]; then continue; fi
            GITUP_KNOWN["$line"]=1
            if [ "$kind" = finished ]; then GITUP_DONE["$line"]=1; fi
        done <"$f" || return 1
    done
}

GITUP_PATH_DEPTH_LIMIT=4096

# ^ invariant prints the free kilobytes of the filesystem holding DIR or its nearest existing parent; rc 1 = DIR is relative or df said nothing usable
gitup_free_kb() {
    local dir="$1" kb n=0
    if [[ $dir != /* ]]; then return 1; fi
    while [ -n "$dir" ] && [ ! -d "$dir" ] && [ "$n" -lt "$GITUP_PATH_DEPTH_LIMIT" ]; do
        dir="${dir%/*}"
        n=$((n + 1))
    done
    if [ -z "$dir" ]; then dir=/; fi
    kb="$(df -Pk -- "$dir" | awk 'NR == 2 { print $4 }')" || return 1
    if [[ ! $kb =~ ^[0-9]+$ ]]; then return 1; fi
    printf '%s\n' "$kb"
}

# ^ invariant prints the first library in ldd output $1 outside the system directories and the prefix (rc 0); rc 1 = all inside
gitup_source_lib_outside() {
    local line path
    while IFS= read -r line; do
        if [[ $line =~ =\>[[:space:]]+(/[^[:space:]]+) ]]; then
            path="${BASH_REMATCH[1]}"
            case "$path" in
                /lib/* | /lib64/* | /usr/lib/* | /usr/lib64/* | /usr/local/lib/* | /usr/local/lib64/* | "$GITUP_PREFIX"/lib/* | "$GITUP_PREFIX"/lib64/*) ;;
                *)
                    printf '%s\n' "$path"
                    return 0
                    ;;
            esac
        fi
    done <<<"$1"
    return 1
}

# ^ invariant rc 0 when DIR ($1) has $2 kilobytes free; else a refusal naming the need ($3 megabytes), the room and what changed
gitup_source_room() {
    local kb
    kb="$(gitup_free_kb "$1")" || {
        printf '%s: cannot measure the free disk space in %s; install refused, %s\n' "$GSG_NAME" "$1" "$(brew_unchanged_text)" >&2
        return 1
    }
    if [ "$kb" -ge "$2" ]; then return 0; fi
    printf '%s: the build needs about %s MB of free disk space in %s and %s MB is free; free some space (TMPDIR moves the build directory); install refused, %s\n' \
        "$GSG_NAME" "$3" "$1" "$((kb / 1024))" "$(brew_unchanged_text)" >&2
    return 1
}

# ^ invariant only a directory this library made (gsg-git-build.*) is removed, on every exit path; install_cleanup calls it on an interrupt
gitup_source_cleanup() {
    if [ -n "$GITUP_BUILD_DIR" ] && [[ ${GITUP_BUILD_DIR##*/} == gsg-git-build.* ]]; then rm -rf -- "$GITUP_BUILD_DIR"; fi
    GITUP_BUILD_DIR=""
}

# ^ security make runs as the invoking user under env -i with a fixed PATH and a scratch HOME and TMPDIR; Homebrew and user variables never reach it
# ^ hazard dropping --foreground puts make in its own process group, a terminal Ctrl-C never reaches it, and the build outlives the interrupt
gitup_source_make() {
    local dir="$1"
    shift
    "$INSTALL_TIMEOUT_BIN" --foreground "$GITUP_BUILD_SECONDS" env -i PATH="$GITUP_BUILD_PATH" HOME="$GITUP_BUILD_DIR/home" LC_ALL=C TMPDIR="$GITUP_BUILD_DIR/tmp" \
        "$GITUP_MAKE" -C "$dir" "$@" >>"$GITUP_BUILD_DIR/make.log" 2>&1
}

# ^ why sysconfdir=/etc, not git's default $(prefix)/etc; the new git reads the /etc/gitconfig of the distribution's git (#90)
# ^ why INSTALL_SYMLINKS=1, not git's hard links; one inode under bin and libexec gets one SELinux label from two policy rules, and restorecon flips it
# ^ invariant rc 0 sets GITUP_MAKE_WORDS for both make runs and the plan; rc 1 with a message when GITUP_PREFIX or GITUP_SYSCONFDIR is empty
gitup_source_make_words() {
    local name
    for name in GITUP_PREFIX GITUP_SYSCONFDIR; do
        if [ -z "${!name:-}" ]; then
            printf '%s: %s is empty, so the make words cannot be built; this is a bug, nothing was built\n' "$GSG_NAME" "$name" >&2
            return 1
        fi
    done
    GITUP_MAKE_WORDS=("prefix=$GITUP_PREFIX" "${GITUP_SRC_FLAGS[@]}" "sysconfdir=$GITUP_SYSCONFDIR" INSTALL_SYMLINKS=1)
}

gitup_source_build() {
    local jobs kept
    jobs="$(nproc 2>/dev/null)" || jobs=2
    if [[ ! $jobs =~ ^[0-9]+$ ]] || [ "$jobs" -lt 1 ]; then jobs=2; fi
    if [ "$jobs" -gt 8 ]; then jobs=8; fi
    printf '%s: building git %s (about %s MB of disk, several minutes; the make output is kept only if the build fails)\n' "$GSG_NAME" "$GITUP_PIN_VER" "$GITUP_BUILD_NEED_MB"
    gitup_source_make_words || return 1
    if gitup_source_make "$GITUP_SRC_DIR" "-j$jobs" "${GITUP_MAKE_WORDS[@]}" all &&
        gitup_source_make "$GITUP_SRC_DIR" "${GITUP_MAKE_WORDS[@]}" "DESTDIR=$GITUP_STAGE" install; then
        return 0
    fi
    tail -n 25 "$GITUP_BUILD_DIR/make.log" | sed 's/^/        | /' >&2
    if kept="$(mktemp --suffix=.log "${TMPDIR:-/tmp}/gsg-git-build-failed.XXXXXX")" && cp -- "$GITUP_BUILD_DIR/make.log" "$kept"; then
        printf '%s: the full make output is kept in %s\n' "$GSG_NAME" "$kept" >&2
    else
        printf '%s: the make output could not be saved; the last lines are above\n' "$GSG_NAME" >&2
    fi
    printf '%s: the git build failed; the old git is untouched\n' "$GSG_NAME" >&2
    return 1
}

# ^ invariant refuses a built binary linking against Homebrew or missing a library; each inode is checked once, scripts (ldd rc 1) have no libraries
gitup_source_check_links() {
    local ldd listing entry inode path out off seen=" "
    install_find_bin ldd || {
        printf '%s: ldd was not found, so the built git cannot be checked for Homebrew or missing libraries\n' "$GSG_NAME" >&2
        return 1
    }
    ldd="$REPLY"
    listing="$(find "$GITUP_STAGE$GITUP_PREFIX/bin" "$GITUP_STAGE$GITUP_PREFIX/libexec" -type f -perm /111 -printf '%i %p\n')" || {
        printf '%s: cannot list the built files below %s\n' "$GSG_NAME" "$GITUP_STAGE" >&2
        return 1
    }
    while IFS= read -r entry; do
        inode="${entry%% *}"
        path="${entry#* }"
        if [[ $seen == *" $inode "* ]]; then continue; fi
        seen+="$inode "
        out="$("$ldd" "$path" 2>&1)" || true
        if [[ $out == *"not found"* ]]; then
            printf '%s: the built git is not usable: %s has a missing library\n' "$GSG_NAME" "${path##*/}" >&2
            return 1
        fi
        if [[ $out == *[Hh]omebrew* ]] || [[ $out == *linuxbrew* ]]; then
            printf '%s: the built git is not usable: %s links against Homebrew, which a system caller or root must not load\n' "$GSG_NAME" "${path##*/}" >&2
            return 1
        fi
        if off="$(gitup_source_lib_outside "$out")"; then
            printf '%s: the built git is not usable: %s loads %s, which is outside the system library directories\n' "$GSG_NAME" "${path##*/}" "${off//[^[:print:]]/?}" >&2
            return 1
        fi
    done <<<"$listing"
}

# ^ invariant rc 0 and no output when no staged file exists in the prefix outside the MANIFESTs of ours; otherwise names up to five and returns 1
gitup_source_check_foreign() {
    local line shown="" n=0
    while IFS= read -r line; do
        if { [ -e "$line" ] || [ -L "$line" ]; } && [ -z "${GITUP_KNOWN[$line]:-}" ]; then
            n=$((n + 1))
            if [ "$n" -le 5 ]; then shown+="${shown:+, }$line"; fi
        fi
    done <"$1"
    if [ "$n" -eq 0 ]; then return 0; fi
    printf '%s: %s file(s) the new git would write already exist in %s and are not listed in any MANIFEST of ours (%s); nothing was copied and they were left alone\n' \
        "$GSG_NAME" "$n" "$GITUP_PREFIX" "$shown" >&2
    return 1
}

# ^ security only paths below the prefix, without .., and not directories are removed; a damaged or hostile MANIFEST cannot delete anything else
# ^ invariant sets GITUP_REMOVED_COUNT = how many files of earlier MANIFESTs the new MANIFEST ($1) no longer lists and were removed
gitup_source_remove_obsolete() {
    local p
    local -a list=() chunk=()
    local -A keep=()
    GITUP_REMOVED_COUNT=0
    while IFS= read -r p; do keep["$p"]=1; done <"$1"
    for p in "${!GITUP_KNOWN[@]}"; do
        if [ -n "${keep[$p]:-}" ]; then continue; fi
        if [[ $p != "$GITUP_PREFIX"/* ]] || [[ $p == *"/../"* ]]; then continue; fi
        if [ -d "$p" ] && [ ! -L "$p" ]; then continue; fi
        if [ -e "$p" ] || [ -L "$p" ]; then list+=("$p"); fi
    done
    while [ "${#list[@]}" -gt 0 ]; do
        chunk=("${list[@]:0:$GITUP_RM_CHUNK}")
        list=("${list[@]:$GITUP_RM_CHUNK}")
        gitup_elevate rm -f -- "${chunk[@]}" || return 1
        GITUP_REMOVED_COUNT=$((GITUP_REMOVED_COUNT + ${#chunk[@]}))
    done
}

# ^ order the verified downloads come before the first privileged command, and a tampered tarball stops with the machine untouched
gitup_source_prepare() {
    if [ -n "${TMPDIR:-}" ] && [[ $TMPDIR != /* ]]; then
        printf '%s: TMPDIR must be an absolute path (it is [%s]); install refused, %s\n' "$GSG_NAME" "${TMPDIR//[[:cntrl:]]/?}" "$(brew_unchanged_text)" >&2
        return 1
    fi
    if gitup_source_takeover_blocks; then
        printf '%s: %s; install refused, %s\n' "$GSG_NAME" "$REPLY" "$(brew_unchanged_text)" >&2
        return 1
    fi
    gitup_source_pins || return 1
    install_require_curl || return 1
    gitup_source_room "${TMPDIR:-/tmp}" "$GITUP_BUILD_MIN_KB" "$GITUP_BUILD_NEED_MB" || return 1
    gitup_source_room "$GITUP_PREFIX" "$GITUP_PREFIX_MIN_KB" "$((GITUP_PREFIX_MIN_KB / 1024))" || return 1
    GITUP_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gsg-git-build.XXXXXX")" || return 1
    GITUP_STAGE="$GITUP_BUILD_DIR/stage"
    GITUP_SRC_DIR="$GITUP_BUILD_DIR/src/git-$GITUP_PIN_VER"
    mkdir -p -- "$GITUP_BUILD_DIR/home" "$GITUP_BUILD_DIR/tmp" "$GITUP_BUILD_DIR/src" "$GITUP_STAGE" || return 1
    GITUP_TARBALL="$(tools_fetch_verified git "$GITUP_PIN_VER" source "$GITUP_PIN_SHA" "$GITUP_BUILD_DIR")" || return 1
    GITUP_MANTARBALL="$(tools_fetch_verified git-manpages "$GITUP_PIN_VER" source "$GITUP_PIN_MAN_SHA" "$GITUP_BUILD_DIR")" || return 1
}

# ^ invariant installs the build dependencies as root (the first change), builds and stages as the invoking user, writes the MANIFEST of the staged files
gitup_source_compile() {
    if [ "${#GITUP_SRC_PRE[@]}" -gt 0 ]; then
        gitup_elevate "${GITUP_SRC_PRE[@]}" || {
            gitup_changed_add "the step before the build dependencies (${GITUP_SRC_PRE[*]##*/}) was started and failed"
            printf '%s: the step before the build dependencies failed\n' "$GSG_NAME" >&2
            return 1
        }
        gitup_changed_add "the package lists were refreshed before the build dependencies"
    fi
    if [ "${#GITUP_SRC_DEPS[@]}" -gt 0 ]; then
        gitup_elevate "${GITUP_SRC_DEPS[@]}" || {
            gitup_changed_add "the install of the build dependencies (${GITUP_SRC_DEPS[*]}) was started and failed, so the package manager may have installed part of them"
            printf '%s: the build dependencies could not be installed\n' "$GSG_NAME" >&2
            return 1
        }
        gitup_changed_add "the build dependencies were installed (${GITUP_SRC_DEPS[*]})"
    fi
    install_find_bin make "$GITUP_BUILD_PATH" || {
        printf '%s: make was not found in PATH=%s after installing the build dependencies\n' "$GSG_NAME" "$GITUP_BUILD_PATH" >&2
        return 1
    }
    GITUP_MAKE="$REPLY"
    tar -xf "$GITUP_TARBALL" -C "$GITUP_BUILD_DIR/src" --no-same-owner || return 1
    if [ ! -f "$GITUP_SRC_DIR/Makefile" ]; then
        printf '%s: the tarball has no git-%s/Makefile\n' "$GSG_NAME" "$GITUP_PIN_VER" >&2
        return 1
    fi
    gitup_source_build || return 1
    mkdir -p -- "$GITUP_STAGE$GITUP_PREFIX/share/man" || return 1
    tar -xf "$GITUP_MANTARBALL" -C "$GITUP_STAGE$GITUP_PREFIX/share/man" --no-same-owner || return 1
    gitup_source_check_links || return 1
    (cd -- "$GITUP_STAGE" && find . ! -type d -printf '/%P\n' | LC_ALL=C sort) >"$GITUP_BUILD_DIR/MANIFEST"
}

# ^ order MANIFEST.partial is saved before the copy and renamed to MANIFEST after it
# ^ invariant a copy stopped half way, also between a removed file and its copy, leaves the partial file; the next run counts it as ours and unfinished
# ^ why --remove-destination, not a plain cp; cp onto an existing symlink writes through it. No mode in --preserve, it rewrote share/man
GITUP_SRC_CP=(cp -dR --remove-destination "--preserve=timestamps,links" --)
gitup_source_docdir() { printf '%s/share/doc/git-%s-local' "$GITUP_PREFIX" "$GITUP_PIN_VER"; }

# ^ invariant prints the clause GITUP_CHANGED holds during the copy; the next step comes first and the clause has no bracket, since brew_unchanged_text wraps it
gitup_source_copy_clause() {
    printf 'files of git %s may be partly copied into %s, so run %s install --upgrade-git again to finish the copy, MANIFEST.partial in %s lists them' \
        "$GITUP_PIN_VER" "$GITUP_PREFIX" "$GSG_NAME" "$1"
}

gitup_source_install() {
    local docdir f dir seen=" " copying
    docdir="$(gitup_source_docdir)"
    gitup_source_read_manifests || return 1
    gitup_source_check_foreign "$GITUP_BUILD_DIR/MANIFEST" || return 1
    gitup_elevate mkdir -p -- "$docdir" && gitup_elevate install -m 644 -- "$GITUP_BUILD_DIR/MANIFEST" "$docdir/MANIFEST.partial" || return 1
    # ^ invariant the clause is recorded before the copy starts => an interrupt still reports files in the prefix and the next step
    copying="$(gitup_source_copy_clause "$docdir")" || return 1
    gitup_changed_add "$copying"
    gitup_elevate "${GITUP_SRC_CP[@]}" "$GITUP_STAGE$GITUP_PREFIX/." "$GITUP_PREFIX/" || return 1
    gitup_changed_drop "$copying"
    gitup_elevate mv -T -- "$docdir/MANIFEST.partial" "$docdir/MANIFEST" || {
        gitup_changed_add "git $GITUP_PIN_VER was copied into $GITUP_PREFIX but its MANIFEST.partial in $docdir could not be renamed, so running install --upgrade-git again finishes it"
        return 1
    }
    gitup_changed_add "git $GITUP_PIN_VER was installed into $GITUP_PREFIX with its MANIFEST in $docdir"
    gitup_source_remove_obsolete "$GITUP_BUILD_DIR/MANIFEST" || {
        gitup_changed_add "removing the files of the previous build failed after $GITUP_REMOVED_COUNT files"
        return 1
    }
    gitup_changed_add "$GITUP_REMOVED_COUNT files of the previous build were removed"
    for f in "${GITUP_MANIFESTS[@]}"; do
        dir="${f%/*}"
        if [ "$dir" = "$docdir" ] || [[ $seen == *" $dir "* ]]; then continue; fi
        seen+="$dir "
        gitup_elevate rm -f -- "$dir/MANIFEST" "$dir/MANIFEST.partial" && gitup_elevate rmdir -- "$dir" || printf '%s: left %s in place\n' "$GSG_NAME" "$dir" >&2
    done
}

# ^ invariant rc 0 = git $GITUP_PIN_VER is in the prefix; any failure removes the build directory and returns 1 with GITUP_CHANGED saying what was done
gitup_source_apply() {
    local step old_umask rc=0
    old_umask="$(umask)"
    umask 022
    for step in gitup_source_prepare gitup_source_compile gitup_source_install; do
        "$step" || {
            rc=1
            break
        }
    done
    gitup_source_cleanup
    umask "$old_umask"
    return "$rc"
}

# ^ invariant rc 0 with REPLY = one sentence when a MANIFEST.partial of ours is in the prefix (an interrupted copy); rc 1 when there is none
gitup_source_unfinished_copy() {
    if [ -z "${GITUP_PREFIX:-}" ]; then gitup_paths || return 1; fi
    gitup_source_read_manifests || return 1
    if [ "${#GITUP_PARTIALS[@]}" -eq 0 ]; then return 1; fi
    REPLY="UNFINISHED: an interrupted copy of git into $GITUP_PREFIX left ${GITUP_PARTIALS[0]}; run: $GSG_NAME install --upgrade-git to finish it"
}

# ^ invariant rc 0 with REPLY = the refusal sentence when a system git takeover is not none; a rebuild would replace its link targets in place
gitup_source_takeover_blocks() {
    if ! gitup_system_git_state || [ "$GITUP_TK_STATE" = none ]; then return 1; fi
    REPLY="a system git takeover is in place ($GITUP_TK_TEXT); a rebuild replaces in place the files its links point at, and an interruption there would break the system git; run $GSG_NAME restore-system-git, then install --upgrade-git, then install --take-over-system-git again"
}

# ^ invariant prints the source route plan and sets GITUP_ROUTE=source; the module sets GITUP_SRC_DEPS (its dependency install command, full path first) before
gitup_source_print_plan() {
    printf '  route: source (%s)\n' "$1"
    printf '  download git %s and its man pages from %s, each checked against the SHA-256 in tools.lock\n' "$GITUP_PIN_VER" "$(tools_release_url git "$GITUP_PIN_VER" source)"
    printf '  build as %s in a temporary directory under env -i with PATH=%s (about %s MB of disk, several minutes)\n' "$(id -un)" "$GITUP_BUILD_PATH" "$GITUP_BUILD_NEED_MB"
    gitup_source_make_words || return 1
    printf '  the build runs: make %s all, then the same with DESTDIR=<build dir>/stage install\n' "${GITUP_MAKE_WORDS[*]}"
    local docdir
    docdir="$(gitup_source_docdir)"
    if [ "${#GITUP_SRC_PRE[@]}" -gt 0 ]; then gitup_plan_priv "${GITUP_SRC_PRE[*]}"; fi
    if [ "${#GITUP_SRC_DEPS[@]}" -gt 0 ]; then gitup_plan_priv "${GITUP_SRC_DEPS[*]}"; fi
    gitup_plan_priv "mkdir -p -- $docdir"
    gitup_plan_priv "install -m 644 -- <build dir>/MANIFEST $docdir/MANIFEST.partial"
    gitup_plan_priv "${GITUP_SRC_CP[*]} <build dir>/stage$GITUP_PREFIX/. $GITUP_PREFIX/"
    gitup_plan_priv "mv -T -- $docdir/MANIFEST.partial $docdir/MANIFEST"
    if gitup_source_read_manifests && [ "${#GITUP_MANIFESTS[@]}" -gt 0 ]; then
        gitup_plan_priv "rm -f -- <files of the previous build that <build dir>/MANIFEST does not list>  [only when the previous build has files the new one lacks]"
        gitup_plan_priv "rmdir -- <doc directories of the previous builds, <build dir>/MANIFEST replaces them>  [only when a previous build left a doc directory of another version]"
    fi
    gitup_plan_note "the copy leaves the mode of existing directories as it is"
    GITUP_ROUTE=source
}

# ^ invariant rc 0 = a build of ours is older than the pin or has an unfinished copy, and the plan is printed; rc 1 = nothing stale, nothing printed
# ^ invariant rc 2 = stale, not doable now, reason printed
gitup_source_plan_refresh() {
    local prepare="$1" mine="$GITUP_PREFIX/bin/git" ver real_used real_mine why
    if [ -z "$GSG_GIT" ] || [ ! -x "$mine" ]; then return 1; fi
    real_used="$(realpath -- "$GSG_GIT")" || return 1
    real_mine="$(realpath -- "$mine")" || return 1
    if [ "$real_used" != "$real_mine" ]; then return 1; fi
    gitup_source_read_manifests || return 1
    gitup_source_pins || return 1
    if [ "${#GITUP_PARTIALS[@]}" -gt 0 ]; then
        why="an earlier copy of git into $GITUP_PREFIX was interrupted (${GITUP_PARTIALS[0]})"
    else
        if [ -z "${GITUP_DONE[$mine]:-}" ]; then return 1; fi
        ver="$(install_git_version "$mine")" || return 1
        gitup_version_at_least "$ver" "$GITUP_PIN_VER"
        if [ $? -ne 1 ]; then return 1; fi
        why="$mine was built by git-secret-guard as git $ver and is older than the git this version pins ($GITUP_PIN_VER)"
    fi
    "$prepare" || return 1
    if gitup_source_takeover_blocks; then
        printf '%s: %s; %s\n' "$GSG_NAME" "$why" "$REPLY" >&2
        return 2
    fi
    printf '%s: %s; the rebuild plan:\n' "$GSG_NAME" "$why"
    gitup_source_print_plan "$why" || return 2
}
