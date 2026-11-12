# shellcheck shell=bash disable=SC2153
# ^ coupled Git LFS half of the SmartGit support; the plan per route and the apply follow in the chunks below

# ^ external a SmartGit started from the Dock gave git this PATH (measured on 26.1.056, docs/smartgit.md); the git directory is first, followed by this suffix
# ^ coupled Intel Homebrew lives in /usr/local/bin, absent from the measured PATH; a git-lfs installed there is refused with the instruction, never assumed seen
SMARTGIT_LAUNCHD_PATH_SUFFIX=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
# ^ todo not measured; the Linux launcher passes the desktop session PATH on, and this is the part every session has (docs/smartgit.md)
SMARTGIT_LINUX_PATH_SUFFIX=/usr/local/bin:/usr/bin:/bin

# ^ invariant prints the PATH git-lfs is looked up on for target $1, an absolute path (rc 1 otherwise); GSG_SMARTGIT_LAUNCH_PATH replaces the PATH only
smartgit_lfs_launch_path() {
    case "$1" in
        /?*/*) ;;
        *)
            printf '%s: the git %s is not an absolute path, so the PATH SmartGit gives it cannot be built\n' "$GSG_NAME" "$1" >&2
            return 1
            ;;
    esac
    if [ -n "${GSG_SMARTGIT_LAUNCH_PATH:-}" ]; then
        printf '%s' "$GSG_SMARTGIT_LAUNCH_PATH"
        return 0
    fi
    smartgit_platform
    if [ "$REPLY" = windows ]; then
        smartgit_lfs_windows_path "$1"
        return
    fi
    if [ "$REPLY" = linux ]; then
        printf '%s:%s' "${1%/*}" "$SMARTGIT_LINUX_PATH_SUFFIX"
    else
        printf '%s:%s' "${1%/*}" "$SMARTGIT_LAUNCHD_PATH_SUFFIX"
    fi
}

# ^ external SmartGit gives git its own directory first and the Windows system directories after it; git.exe adds its own directories itself
# ^ external HOME and PATH are enough across env -i; msys adds SYSTEMROOT for a native program (measured with the real cmd\git.exe)
# ^ coupled the system directories come from SYSTEMROOT of the CLI itself, always set in Git Bash; the list is POSIX and converted at exec
smartgit_lfs_windows_path() {
    local sys
    if [ -z "${SYSTEMROOT:-}" ]; then
        printf '%s: SYSTEMROOT is not set, so the PATH SmartGit gives git cannot be built\n' "$GSG_NAME" >&2
        return 1
    fi
    sys="$(gsg_posix_path "$SYSTEMROOT")" || return 1
    printf '%s:%s/System32:%s' "${1%/*}" "$sys" "$sys"
}

# ^ invariant 1 only during the Flatpak check of smartgit_verify_run; git runs through the wrapper inside the SmartGit sandbox
SGF_VIA_SANDBOX=0

# ^ security env -i keeps the installer's variables away; only the global config location, when set, is passed on to read the config install wrote
# ^ invariant runs SMARTGIT_WIN_GIT on Windows (the cmd\git.exe written), GSG_GIT elsewhere
smartgit_launch_git() {
    local p run="${SMARTGIT_WIN_GIT:-$GSG_GIT}"
    local -a keep=()
    if [ "$SGF_VIA_SANDBOX" -eq 1 ]; then
        smartgit_flatpak_git "$@"
        return
    fi
    p="$(smartgit_lfs_launch_path "$run")" || return 1
    if [ -n "${GIT_CONFIG_GLOBAL:-}" ]; then keep+=(GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL"); fi
    if [ -n "${GIT_CONFIG_NOSYSTEM:-}" ]; then keep+=(GIT_CONFIG_NOSYSTEM="$GIT_CONFIG_NOSYSTEM"); fi
    env -i HOME="$HOME" PATH="$p" "${keep[@]}" "$run" "$@"
}

# ^ invariant on macOS the check runs under env -i with HOME and the PATH SmartGit gives git; a git-lfs only your shell can see does not count as present
smartgit_lfs_present() {
    local p
    p="$(smartgit_lfs_launch_path "$1")" || return 1
    env -i HOME="$HOME" PATH="$p" "$1" lfs version >/dev/null 2>&1
}

# ^ invariant true when any scope used outside a repository (system, global) sets a filter.lfs.* key
smartgit_lfs_filter_set() { smartgit_launch_git -C / config --get-regexp '^filter\.lfs\.' >/dev/null 2>&1; }

# ^ invariant none = git lfs works already, brew = the command in SG_LFS_CMD installs it; set by the plan, used by the apply
SG_LFS_ROUTE=none
SG_LFS_CMD=()

# ^ security brew runs as the invoking user, never as root and never through sudo; Homebrew itself refuses root
smartgit_lfs_plan_brew() {
    if gitup_is_root; then
        printf '%s: Homebrew runs as your own user, never as root; run install as a normal user; SmartGit was not changed\n' "$GSG_NAME" >&2
        return 1
    fi
    brew_find || return 1
    brew_paths || return 1
    SG_LFS_ROUTE=brew
    SG_LFS_CMD=("$BREW_BIN" install git-lfs)
    printf '  git lfs version fails through %s, so Git LFS is installed; runs as your user: %s install git-lfs (no sudo; Homebrew may update its own formulae first)\n' "$GSG_GIT" "$BREW_BIN"
}

# ^ security a tool root runs is looked up only in the fixed system path and must be root-owned; sets REPLY, rc 1 prints the one shared refusal
smartgit_lfs_require_bin() {
    if gitup_system_bin "$1"; then return 0; fi
    printf '%s: %s was not found in the system path (%s) or is not root-owned, so git-lfs cannot be installed here; install git-lfs by hand; SmartGit was not changed\n' \
        "$GSG_NAME" "$1" "$GITUP_SYSTEM_PATH" >&2
    return 1
}

SG_LFS_KILL_GRACE_SECONDS=5

# ^ security the query is bounded, reads no terminal and answers no to every prompt => an unimported repository key fails it instead of asking
# ^ invariant a failed query and an empty answer are two refusals; neither names a repository this tool did not see, and none is ever enabled
# ^ why the answer stays in a variable, not a file; dnf output is never written to disk (CLAUDE.md), stderr is dropped and the exit status reported
smartgit_lfs_plan_dnf() {
    local dnf offered qrc=0
    smartgit_lfs_require_bin dnf || return 1
    dnf="$REPLY"
    if [ -z "${INSTALL_TIMEOUT_BIN:-}" ]; then
        printf '%s: no timeout binary is known, so the dnf repoquery for git-lfs cannot run bounded; SmartGit was not changed\n' "$GSG_NAME" >&2
        return 1
    fi
    offered="$(LC_ALL=C "$INSTALL_TIMEOUT_BIN" -k "$SG_LFS_KILL_GRACE_SECONDS" "$GITUP_QUERY_TIMEOUT" \
        "$dnf" --assumeno -q repoquery --available --latest-limit=1 --queryformat '%{version}\n' git-lfs </dev/null 2>/dev/null)" || qrc=$?
    if [ "$qrc" -ne 0 ]; then
        printf '%s: the dnf repoquery for git-lfs failed (exit %s; dnf repoquery git-lfs shows why); SmartGit was not changed\n' "$GSG_NAME" "$qrc" >&2
        return 1
    fi
    if [[ ! ${offered%%$'\n'*} =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        printf '%s: no enabled dnf repository offers git-lfs, and this tool enables none; install git-lfs from a repository you trust and run the command again; SmartGit was not changed\n' "$GSG_NAME" >&2
        return 1
    fi
    SG_LFS_ROUTE=dnf
    SG_LFS_CMD=("$dnf" install -y git-lfs)
    printf '  dnf install -y answers yes to every prompt, a repository signing key import included: a key pending for the repository offering git-lfs would be imported; the read-only query above imported none\n'
    gitup_plan_priv "${SG_LFS_CMD[*]}"
}

# ^ security apt-get and env are the root-owned ones of the system path (gitup_apt_init); env carries the answers apt asks for, as sudo drops variables
# ^ coupled the words come from gitup_apt_get_cmd of lib/gitup_apt.sh => the plan prints exactly what gitup_elevate runs
# ^ invariant a candidate is probed first, as dnf does; a failed query and no candidate are two refusals, and no repository is ever enabled
smartgit_lfs_plan_apt() {
    if ! declare -F gitup_apt_init >/dev/null; then gitup_load_module apt || return 1; fi
    gitup_apt_init || return 1
    if [ -z "${INSTALL_TIMEOUT_BIN:-}" ]; then
        printf '%s: no timeout binary is known, so the apt-cache query for git-lfs cannot run bounded; SmartGit was not changed\n' "$GSG_NAME" >&2
        return 1
    fi
    if ! gitup_apt_candidate git-lfs; then
        printf '%s: the apt-cache policy query for git-lfs failed (apt-cache policy git-lfs shows why); SmartGit was not changed\n' "$GSG_NAME" >&2
        return 1
    fi
    if [ -z "$GITUP_APT_CANDIDATE" ] && [ -n "$GITUP_APT_CANDIDATE_RAW" ]; then
        printf '%s: apt offers git-lfs %s, which is not a release version this tool installs (a pre-release or an unreadable version); install git-lfs by hand if you want it; SmartGit was not changed\n' \
            "$GSG_NAME" "$GITUP_APT_CANDIDATE_RAW" >&2
        return 1
    fi
    if [ -z "$GITUP_APT_CANDIDATE" ]; then
        printf '%s: no apt repository offers git-lfs, and this tool enables none; install git-lfs from a repository you trust and run the command again; SmartGit was not changed\n' "$GSG_NAME" >&2
        return 1
    fi
    gitup_apt_get_cmd install -y git-lfs
    SG_LFS_ROUTE=apt
    SG_LFS_CMD=("${GITUP_APT_CMD[@]}")
    gitup_plan_priv "${SG_LFS_CMD[*]}"
}

# ^ invariant brew on macOS, dnf on the rpm family, apt on ubuntu and debian (a WSL distribution by its own os-release); anything else is refused
smartgit_lfs_plan_route() {
    # ^ why repair advice on Windows, not an install; Git for Windows ships Git LFS and a git without it is a broken install
    if tools_is_windows; then
        printf '%s: git lfs version fails through %s; repair Git for Windows (it ships Git LFS) and run the command again; SmartGit was not changed\n' "$GSG_NAME" "${SMARTGIT_WIN_TARGET:-$GSG_GIT}" >&2
        return 1
    fi
    if brew_is_macos; then
        smartgit_lfs_plan_brew
        return
    fi
    install_os_family
    case "$REPLY" in
        rpm) smartgit_lfs_plan_dnf ;;
        ubuntu | debian) smartgit_lfs_plan_apt ;;
        *)
            printf '%s: git lfs version fails through %s and this system has no known way to install it; install git-lfs with your package manager; SmartGit was not changed\n' "$GSG_NAME" "$GSG_GIT" >&2
            return 1
            ;;
    esac
}

# ^ invariant nothing is installed when git lfs version works through the target; otherwise the route of this system plans the install
# ^ invariant the git lfs install line is conditional on the state after the package install; a package may write the system-wide filter itself
# ^ invariant FLATPAK ($1) = 1 when a Flatpak SmartGit is in the run; its line adds the repeat of the check through the wrapper in the sandbox
smartgit_lfs_plan() {
    local where=""
    SG_LFS_ROUTE=none
    SG_LFS_CMD=()
    if [ "${1:-0}" -eq 1 ]; then where=", the git the wrapper runs; it is checked again through the wrapper inside the SmartGit sandbox"; fi
    gitup_select || return 1
    if smartgit_lfs_present "${SMARTGIT_WIN_GIT:-$GSG_GIT}"; then
        printf '  Git LFS: git lfs version works through %s%s; nothing is installed\n' "${SMARTGIT_WIN_TARGET:-$GSG_GIT}" "$where"
    else
        smartgit_lfs_plan_route || return 1
    fi
    if smartgit_lfs_filter_set; then
        printf '  Git LFS settings: filter.lfs.* is already set; git lfs install is not run\n'
    else
        printf '  [only when no filter.lfs.* is set after that] runs: %s lfs install --skip-repo (writes the filter.lfs.* settings to your ~/.gitconfig)\n' "${SMARTGIT_WIN_TARGET:-$GSG_GIT}"
    fi
}

# ^ invariant runs the command the plan chose; brew is named in BREW_INSTALLED and the root routes in GITUP_CHANGED; a later refusal says what changed
# ^ invariant success means git lfs version works through the target afterwards; anything else is a failure and leaves the package as the manager left it
smartgit_lfs_install_pkg() {
    case "$SG_LFS_ROUTE" in
        none) return 0 ;;
        brew)
            printf '%s: installing Git LFS with Homebrew: brew install git-lfs\n' "$GSG_NAME"
            "${SG_LFS_CMD[@]}" || {
                printf '%s: brew install git-lfs failed (brew'"'"'s message is above); Homebrew may have installed part of it; SmartGit was not changed\n' "$GSG_NAME" >&2
                return 1
            }
            BREW_INSTALLED="${BREW_INSTALLED:+$BREW_INSTALLED }git-lfs"
            ;;
        dnf | apt)
            printf '%s: installing Git LFS with %s as root\n' "$GSG_NAME" "$SG_LFS_ROUTE"
            gitup_elevate "${SG_LFS_CMD[@]}" || {
                gitup_changed_add "the $SG_LFS_ROUTE install of git-lfs was started and failed, so the package manager may have changed packages"
                printf '%s: the %s install of git-lfs failed; SmartGit was not changed\n' "$GSG_NAME" "$SG_LFS_ROUTE" >&2
                return 1
            }
            gitup_changed_add "$SG_LFS_ROUTE installed git-lfs"
            ;;
        *)
            printf '%s: internal error: unknown Git LFS install route [%s]; nothing was run; SmartGit was not changed\n' "$GSG_NAME" "$SG_LFS_ROUTE" >&2
            return 1
            ;;
    esac
    hash -r
    if ! smartgit_lfs_present "${SMARTGIT_WIN_GIT:-$GSG_GIT}"; then
        local lp
        lp="$(smartgit_lfs_launch_path "${SMARTGIT_WIN_GIT:-$GSG_GIT}")" || lp=unknown
        printf '%s: git lfs version still fails through %s in the environment SmartGit gives git (PATH %s); if git-lfs is installed elsewhere, set absolute paths in the filter.lfs.* settings as SmartGit documents, this tool does not write them; SmartGit was not changed\n' \
            "$GSG_NAME" "$GSG_GIT" "$lp" >&2
        return 1
    fi
}

# ^ invariant smartgit_lfs_record_write VALUE; pending is written before git lfs install, yes after it with the filter seen in the config
# ^ invariant the undo removes the filter section only for yes; a pending record may have met a section the user made meanwhile
smartgit_lfs_record_write() {
    local dir="$GSG_STATE_DIR/smartgit" tmp
    case "$1" in
        pending | yes) ;;
        *)
            printf '%s: %s is not a Git LFS record value; nothing was changed\n' "$GSG_NAME" "$1" >&2
            return 1
            ;;
    esac
    (umask 077 && mkdir -p -- "$dir") || {
        printf '%s: could not create %s for the Git LFS record; nothing was changed\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
    tmp="$(umask 077 && mktemp "$dir/lfs-tmp.XXXXXX")" || {
        printf '%s: could not create a file in %s for the Git LFS record; nothing was changed\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
    printf 'filter_added=%s\n' "$1" >"$tmp" || {
        smartgit_discard_tmp "$tmp"
        printf '%s: could not write the Git LFS record in %s; nothing was changed\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
    mv -f -- "$tmp" "$dir/lfs.record" || {
        smartgit_discard_tmp "$tmp"
        printf '%s: could not write %s/lfs.record; nothing was changed\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
}

# ^ invariant true only when lfs.record holds exactly filter_added=pending
smartgit_lfs_is_pending() {
    local rec="$GSG_STATE_DIR/smartgit/lfs.record"
    [ -f "$rec" ] && [ "$(<"$rec")" = filter_added=pending ]
}

# ^ invariant a pending record is dropped (no filter.lfs.* key was visible); any other state goes through the undo
smartgit_lfs_take_back() {
    local rec="$GSG_STATE_DIR/smartgit/lfs.record"
    if smartgit_lfs_is_pending; then
        rm -f -- "$rec" || {
            printf '%s: could not remove %s; run %s restore-smartgit\n' "$GSG_NAME" "$rec" "$GSG_NAME" >&2
            return 1
        }
        return 0
    fi
    smartgit_lfs_undo || {
        printf '%s: the undo did not finish; run %s restore-smartgit\n' "$GSG_NAME" "$GSG_NAME" >&2
        return 1
    }
}

# ^ order pending is written before git lfs install runs, yes after its settings are seen; a stop in between leaves pending, and a rerun only drops it
smartgit_lfs_configure() {
    local irc=0
    if smartgit_lfs_filter_set; then
        if smartgit_lfs_is_pending; then
            smartgit_lfs_take_back || return 1
            printf '%s: the filter.lfs.* settings in your global git config are kept, as this tool cannot prove it added them; if you did not add them yourself, remove them with: git config --global --remove-section filter.lfs\n' "$GSG_NAME"
        fi
        return 0
    fi
    smartgit_lfs_record_write pending || return 1
    printf '%s: running %s lfs install --skip-repo\n' "$GSG_NAME" "${SMARTGIT_WIN_TARGET:-$GSG_GIT}"
    smartgit_launch_git -C / lfs install --skip-repo || irc=$?
    if smartgit_lfs_filter_set; then
        smartgit_lfs_record_write yes || {
            printf '%s: the filter.lfs.* settings stay in your global git config; remove them by hand to undo\n' "$GSG_NAME" >&2
            return 1
        }
    fi
    if [ "$irc" -ne 0 ]; then
        printf '%s: git lfs install failed (exit %s); taking back what it wrote\n' "$GSG_NAME" "$irc" >&2
        smartgit_lfs_take_back
        return 1
    fi
    if ! smartgit_lfs_filter_set; then
        printf '%s: git lfs install exited 0 but no filter.lfs.* setting is visible; taking back its record\n' "$GSG_NAME" >&2
        smartgit_lfs_take_back
        return 1
    fi
}

# ^ invariant sets REPLY = none, pending or yes for the record this tool keeps; rc 1 and a message for a record it did not write
smartgit_lfs_record_state() {
    local rec="$GSG_STATE_DIR/smartgit/lfs.record"
    REPLY=none
    if [ ! -f "$rec" ]; then return 0; fi
    case "$(<"$rec")" in
        filter_added=yes) REPLY=yes ;;
        filter_added=pending) REPLY=pending ;;
        *)
            printf '%s: %s is not a record this tool wrote; it was left alone and the filter.lfs.* settings too\n' "$GSG_NAME" "$rec" >&2
            return 1
            ;;
    esac
}

# ^ invariant rc 0 = the global config sets a filter.lfs.* key, 1 = it sets none, 2 = it cannot be read (said, and the record is kept for another run)
smartgit_lfs_global_filter() {
    local rc=0
    "$GSG_GIT" -C / config --global --get-regexp '^filter\.lfs\.' >/dev/null 2>&1 || rc=$?
    if [ "$rc" -le 1 ]; then return "$rc"; fi
    printf '%s: the global git config could not be read; the record was kept so the restore can run again\n' "$GSG_NAME" >&2
    return 2
}

# ^ invariant changes nothing; rc 0 = the undo can run, rc 1 = its record is refused or, for yes, the global config cannot be read
smartgit_lfs_undo_check() {
    local rc=0
    smartgit_lfs_record_state || return 1
    if [ "$REPLY" != yes ]; then return 0; fi
    smartgit_lfs_global_filter || rc=$?
    if [ "$rc" -eq 2 ]; then return 1; fi
}

# ^ invariant only a recorded filter section is removed, from the global config; the git-lfs package itself is never removed, other tools may use it
# ^ invariant an unreadable config keeps the record; a later run can still remove the section
smartgit_lfs_undo() {
    local rec="$GSG_STATE_DIR/smartgit/lfs.record" rc=0
    smartgit_lfs_undo_check || return 1
    case "$REPLY" in
        none) return 0 ;;
        pending)
            printf '%s: the Git LFS record was never confirmed (a run stopped around git lfs install); the filter.lfs.* settings were left alone; if you did not add them yourself, remove them with: git config --global --remove-section filter.lfs\n' "$GSG_NAME"
            ;;
        yes)
            smartgit_lfs_global_filter || rc=$?
            if [ "$rc" -eq 2 ]; then return 1; fi
            if [ "$rc" -eq 0 ]; then
                "$GSG_GIT" -C / config --global --remove-section filter.lfs || {
                    printf '%s: the filter.lfs section could not be removed from the global git config; run the restore again\n' "$GSG_NAME" >&2
                    return 1
                }
                printf '%s: removed the filter.lfs.* settings that git lfs install added\n' "$GSG_NAME"
            fi
            ;;
    esac
    rm -f -- "$rec"
}
