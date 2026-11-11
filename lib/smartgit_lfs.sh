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
    p="$(smartgit_lfs_launch_path "$1")" || return 1
    env -i HOME="$HOME" PATH="$p" "$1" lfs version >/dev/null 2>&1
}

# ^ invariant true when any scope used outside a repository (system, global) sets a filter.lfs.* key
smartgit_lfs_filter_set() { "$GSG_GIT" -C / config --get-regexp '^filter\.lfs\.' >/dev/null 2>&1; }

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

# ^ invariant nothing is installed when git lfs version works through the target; otherwise brew is the one route, as only macOS reaches the plan
# ^ invariant the git lfs install line is conditional on the state after the package install; a package may write the system-wide filter itself
smartgit_lfs_plan() {
    SG_LFS_ROUTE=none
    SG_LFS_CMD=()
    gitup_select || return 1
    if smartgit_lfs_present "$GSG_GIT"; then
        printf '  Git LFS: git lfs version works through %s; nothing is installed\n' "$GSG_GIT"
    else
        smartgit_lfs_plan_brew || return 1
    fi
    if smartgit_lfs_filter_set; then
        printf '  Git LFS settings: filter.lfs.* is already set; git lfs install is not run\n'
    else
        printf '  [only when no filter.lfs.* is set after that] runs: %s lfs install --skip-repo (writes the filter.lfs.* settings to your ~/.gitconfig)\n' "$GSG_GIT"
    fi
}

# ^ invariant runs the command the plan chose; brew is named in BREW_INSTALLED; a later refusal says what changed
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

# ^ order pending is written before git lfs install runs, yes after its settings are seen; a stop in between leaves pending, and a rerun makes it yes
smartgit_lfs_configure() {
    local irc=0
    if smartgit_lfs_filter_set; then
        if smartgit_lfs_is_pending; then smartgit_lfs_record_write yes || return 1; fi
        return 0
    fi
    smartgit_lfs_record_write pending || return 1
    printf '%s: running %s lfs install --skip-repo\n' "$GSG_NAME" "$GSG_GIT"
    "$GSG_GIT" -C / lfs install --skip-repo || irc=$?
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
