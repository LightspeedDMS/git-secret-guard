# shellcheck shell=bash disable=SC2153
# ^ coupled Git LFS half of the SmartGit support; the plan per route and the apply follow in the chunks below

# ^ external a SmartGit started from the Dock gave git this PATH (measured on 26.1.056, docs/smartgit.md); the git directory is first, followed by this suffix
# ^ coupled Intel Homebrew lives in /usr/local/bin, absent from the measured PATH; a git-lfs installed there is refused with the instruction, never assumed seen
SMARTGIT_LAUNCHD_PATH_SUFFIX=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin

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
    printf '%s:%s' "${1%/*}" "$SMARTGIT_LAUNCHD_PATH_SUFFIX"
}

# ^ invariant on macOS the check runs under env -i with HOME and the PATH SmartGit gives git; a git-lfs only your shell can see does not count as present
smartgit_lfs_present() {
    local p
    if brew_is_macos; then
        p="$(smartgit_lfs_launch_path "$1")" || return 1
        env -i HOME="$HOME" PATH="$p" "$1" lfs version >/dev/null 2>&1
    else
        "$1" lfs version >/dev/null 2>&1
    fi
}

# ^ invariant true when any scope used outside a repository (system, global) sets a filter.lfs.* key
smartgit_lfs_filter_set() { "$GSG_GIT" -C / config --get-regexp '^filter\.lfs\.' >/dev/null 2>&1; }

# ^ invariant sets REPLY = macos, windows, rpm, apt or other; a WSL distribution counts as the family of the distribution inside
smartgit_lfs_class() {
    gitup_os_class
    case "$REPLY" in
        macos | windows) return 0 ;;
        wsl) install_os_family ;;
    esac
    case "$REPLY" in
        ubuntu | debian) REPLY=apt ;;
        rpm) ;;
        *) REPLY=other ;;
    esac
}

# ^ invariant none = git lfs works already, brew, dnf or apt = the command in SG_LFS_CMD installs it; set by the plan, used by the apply
SG_LFS_ROUTE=none
SG_LFS_CMD=()
SG_LFS_KILL_GRACE_SECONDS=5

# ^ security a tool root runs is looked up only in the fixed system path and must be root-owned; sets REPLY, rc 1 prints the one shared refusal
smartgit_lfs_require_bin() {
    if gitup_system_bin "$1"; then return 0; fi
    printf '%s: %s was not found in the system path (%s) or is not root-owned, so git-lfs cannot be installed here; install git-lfs by hand; SmartGit was not changed\n' \
        "$GSG_NAME" "$1" "$GITUP_SYSTEM_PATH" >&2
    return 1
}

SG_LFS_STDERR_EXCERPT_BYTES=300

# ^ invariant dnf is asked whether an enabled repository offers git-lfs; an answer plans the install, an empty answer refuses naming EPEL as a likely source
# ^ security the query is bounded and answers no to every prompt; a missing timeout binary and a failed query are own refusals, never read as "not offered"
# ^ invariant the answer is read from stdout only; stderr goes to a temp file shown on failure, and a warning never counts as an offer
smartgit_lfs_plan_dnf() {
    local dnf offered qrc errf why
    smartgit_lfs_require_bin dnf || return 1
    dnf="$REPLY"
    if [ -z "${INSTALL_TIMEOUT_BIN:-}" ]; then
        printf '%s: no timeout binary is known, so the dnf repoquery for git-lfs cannot run safely; SmartGit was not changed\n' "$GSG_NAME" >&2
        return 1
    fi
    errf="$(mktemp)" || {
        printf '%s: cannot create a temporary file for the dnf repoquery; SmartGit was not changed\n' "$GSG_NAME" >&2
        return 1
    }
    offered="$(LC_ALL=C "$INSTALL_TIMEOUT_BIN" -k "$SG_LFS_KILL_GRACE_SECONDS" "$GITUP_QUERY_TIMEOUT" "$dnf" --assumeno -q repoquery --latest-limit=1 --queryformat '%{version}\n' git-lfs </dev/null 2>"$errf")"
    qrc=$?
    why="$(head -c "$SG_LFS_STDERR_EXCERPT_BYTES" "$errf")"
    smartgit_discard_tmp "$errf"
    if [ "$qrc" -ne 0 ]; then
        printf '%s: the dnf repoquery for git-lfs failed (exit %s: %s); SmartGit was not changed\n' "$GSG_NAME" "$qrc" "${why//[[:cntrl:]]/ }" >&2
        return 1
    fi
    if [[ ! ${offered%%$'\n'*} =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        printf '%s: no enabled dnf repository offers git-lfs; on RHEL-compatible systems it often comes from EPEL, which you would enable yourself (this tool enables no repository); SmartGit was not changed\n' "$GSG_NAME" >&2
        return 1
    fi
    SG_LFS_ROUTE=dnf
    SG_LFS_CMD=("$dnf" install -y git-lfs)
    gitup_plan_priv "${SG_LFS_CMD[*]}"
}

# ^ security env carries the answers apt asks for, as sudo drops the caller's variables; both tools are the root-owned ones of the system path
smartgit_lfs_plan_apt() {
    local aptget envbin
    smartgit_lfs_require_bin apt-get || return 1
    aptget="$REPLY"
    smartgit_lfs_require_bin env || return 1
    envbin="$REPLY"
    if ! declare -p GITUP_APT_ENVWORDS >/dev/null 2>&1; then gitup_load_module apt || return 1; fi
    SG_LFS_ROUTE=apt
    SG_LFS_CMD=("$envbin" "${GITUP_APT_ENVWORDS[@]}" "$aptget" install -y git-lfs)
    gitup_plan_priv "${SG_LFS_CMD[*]}"
}

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

# ^ invariant nothing is installed when git lfs version works through the target; Windows has nothing to install (Git for Windows includes LFS);
# ^ invariant Windows is refused with the repair hint
# ^ invariant the git lfs install line is conditional on the state after the package install; a package may write the system-wide filter itself
smartgit_lfs_plan() {
    SG_LFS_ROUTE=none
    SG_LFS_CMD=()
    gitup_select || return 1
    if smartgit_lfs_present "$GSG_GIT"; then
        printf '  Git LFS: git lfs version works through %s; nothing is installed\n' "$GSG_GIT"
    else
        smartgit_lfs_class
        case "$REPLY" in
            macos) smartgit_lfs_plan_brew || return 1 ;;
            rpm) smartgit_lfs_plan_dnf || return 1 ;;
            apt) smartgit_lfs_plan_apt || return 1 ;;
            windows)
                printf '%s: git lfs version fails through %s; Git for Windows includes Git LFS, so repair or reinstall Git for Windows (git-secret-guard installs nothing here); SmartGit was not changed\n' "$GSG_NAME" "$GSG_GIT" >&2
                return 1
                ;;
            *)
                printf '%s: git lfs version fails through %s and this system has no known way to install it; install git-lfs with your package manager; SmartGit was not changed\n' "$GSG_NAME" "$GSG_GIT" >&2
                return 1
                ;;
        esac
    fi
    if smartgit_lfs_filter_set; then
        printf '  Git LFS settings: filter.lfs.* is already set; git lfs install is not run\n'
    else
        printf '  [only when no filter.lfs.* is set after that] runs: %s lfs install --skip-repo (writes the filter.lfs.* settings to your ~/.gitconfig)\n' "$GSG_GIT"
    fi
}

# ^ invariant runs the command the plan chose; brew is named in BREW_INSTALLED and privileged routes in GITUP_CHANGED; a later refusal says what changed
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
        *)
            printf '%s: installing Git LFS with %s\n' "$GSG_NAME" "$SG_LFS_ROUTE"
            gitup_elevate "${SG_LFS_CMD[@]}" || {
                gitup_changed_add "$SG_LFS_ROUTE install of git-lfs was started and failed, so the package manager may have changed packages"
                printf '%s: the %s install of git-lfs failed; SmartGit was not changed\n' "$GSG_NAME" "$SG_LFS_ROUTE" >&2
                return 1
            }
            gitup_changed_add "$SG_LFS_ROUTE installed git-lfs"
            ;;
    esac
    hash -r
    if ! smartgit_lfs_present "$GSG_GIT"; then
        local lp
        lp="$(smartgit_lfs_launch_path "$GSG_GIT")" || lp=unknown
        printf '%s: git lfs version still fails through %s in the environment SmartGit gives git (PATH %s); if git-lfs is installed elsewhere, set absolute paths in the filter.lfs.* settings as SmartGit documents, this tool does not write them; SmartGit was not changed\n' \
            "$GSG_NAME" "$GSG_GIT" "$lp" >&2
        return 1
    fi
}

# ^ invariant the record is written before any change; the undo removes the filter section only when this record says the tool added it
smartgit_lfs_record_write() {
    local dir="$GSG_STATE_DIR/smartgit" tmp
    (umask 077 && mkdir -p -- "$dir") || {
        printf '%s: could not create %s for the Git LFS record; nothing was changed\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
    tmp="$(umask 077 && mktemp "$dir/lfs-tmp.XXXXXX")" || {
        printf '%s: could not create a file in %s for the Git LFS record; nothing was changed\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
    printf 'filter_added=yes\n' >"$tmp" || {
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

# ^ order the record is written before git lfs install runs; a stop in between leaves a record the undo understands (no section = it only drops the record)
smartgit_lfs_configure() {
    if smartgit_lfs_filter_set; then return 0; fi
    smartgit_lfs_record_write || return 1
    printf '%s: running %s lfs install --skip-repo\n' "$GSG_NAME" "$GSG_GIT"
    "$GSG_GIT" -C / lfs install --skip-repo || {
        printf '%s: git lfs install failed; taking back what it may have written\n' "$GSG_NAME" >&2
        smartgit_lfs_undo
        return 1
    }
    if ! smartgit_lfs_filter_set; then
        printf '%s: git lfs install finished but no filter.lfs.* setting is visible; the record was dropped\n' "$GSG_NAME" >&2
        smartgit_lfs_undo
        return 1
    fi
}

# ^ invariant only a recorded filter section is removed, from the global config; the git-lfs package itself is never removed, other tools may use it
# ^ invariant an unreadable config keeps the record; a later run can still remove the section
smartgit_lfs_undo() {
    local rec="$GSG_STATE_DIR/smartgit/lfs.record" rc=0
    if [ ! -f "$rec" ]; then return 0; fi
    if [ "$(<"$rec")" != filter_added=yes ]; then
        printf '%s: %s is not a record this tool wrote; it was left alone and the filter.lfs.* settings too\n' "$GSG_NAME" "$rec" >&2
        return 1
    fi
    "$GSG_GIT" -C / config --global --get-regexp '^filter\.lfs\.' >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        "$GSG_GIT" -C / config --global --remove-section filter.lfs || {
            printf '%s: the filter.lfs section could not be removed from the global git config; run the restore again\n' "$GSG_NAME" >&2
            return 1
        }
        printf '%s: removed the filter.lfs.* settings that git lfs install added\n' "$GSG_NAME"
    elif [ "$rc" -ne 1 ]; then
        printf '%s: the global git config could not be read; the record was kept so the restore can run again\n' "$GSG_NAME" >&2
        return 1
    fi
    rm -f -- "$rec"
}
