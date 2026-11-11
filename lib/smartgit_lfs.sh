# shellcheck shell=bash disable=SC2153
# ^ coupled Git LFS half of the SmartGit support; the plan per route and the apply follow in the chunks below

smartgit_lfs_present() { "$1" lfs version >/dev/null 2>&1; }

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

# ^ invariant on a RHEL-compatible system git-lfs comes from EPEL; without it enabled the plan is refused with the instruction, no repository is enabled here
# ^ security the repository query is bounded and answers no to every prompt;
# ^ security a missing timeout binary and a failed query are their own refusals, never read as "EPEL is off"
smartgit_lfs_plan_dnf() {
    local dnf id repos="" qrc
    smartgit_lfs_require_bin dnf || return 1
    dnf="$REPLY"
    install_os_release_field "${GSG_OS_RELEASE:-/etc/os-release}" ID
    id="$REPLY"
    if [ "$id" != fedora ]; then
        if [ -z "${INSTALL_TIMEOUT_BIN:-}" ]; then
            printf '%s: no timeout binary is known, so the repository query that checks for EPEL cannot run safely; SmartGit was not changed\n' "$GSG_NAME" >&2
            return 1
        fi
        repos="$(LC_ALL=C "$INSTALL_TIMEOUT_BIN" -k "$SG_LFS_KILL_GRACE_SECONDS" "$GITUP_QUERY_TIMEOUT" "$dnf" --assumeno -q repolist --enabled </dev/null 2>&1)"
        qrc=$?
        if [ "$qrc" -ne 0 ]; then
            printf '%s: the repository query failed (exit %s: %s), so EPEL could not be checked; SmartGit was not changed\n' "$GSG_NAME" "$qrc" "${repos//[[:cntrl:]]/ }" >&2
            return 1
        fi
        if [[ ${repos,,} != *epel* ]]; then
            printf '%s: git-lfs is in EPEL on %s and the repository list shows no enabled EPEL; enable it yourself (sudo dnf install epel-release) and run the command again; this tool does not enable a repository; SmartGit was not changed\n' \
                "$GSG_NAME" "${id:-this system}" >&2
            return 1
        fi
        gitup_plan_note "git-lfs comes from EPEL, which is enabled on this system"
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
        printf '%s: git lfs version still fails through %s after the install; SmartGit was not changed\n' "$GSG_NAME" "$GSG_GIT" >&2
        return 1
    fi
}

# ^ invariant the record is written only after the filter was seen to appear; an undo never removes a section this tool did not add
smartgit_lfs_configure() {
    local dir tmp
    if smartgit_lfs_filter_set; then return 0; fi
    printf '%s: running %s lfs install --skip-repo\n' "$GSG_NAME" "$GSG_GIT"
    "$GSG_GIT" -C / lfs install --skip-repo || {
        printf '%s: git lfs install failed; the filter.lfs.* settings were not written\n' "$GSG_NAME" >&2
        return 1
    }
    if ! smartgit_lfs_filter_set; then
        printf '%s: git lfs install finished but no filter.lfs.* setting is visible; nothing is recorded\n' "$GSG_NAME" >&2
        return 1
    fi
    dir="$GSG_STATE_DIR/smartgit"
    (umask 077 && mkdir -p -- "$dir") || {
        printf '%s: could not create %s; the filter.lfs.* settings were written but are not recorded, so an undo will not remove them\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
    tmp="$(umask 077 && mktemp "$dir/lfs.XXXXXX")" || {
        printf '%s: could not create a file in %s; the filter.lfs.* settings were written but are not recorded\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
    printf 'filter_added=yes\n' >"$tmp" || {
        rm -f -- "$tmp" || printf '%s: could not remove the temporary file %s\n' "$GSG_NAME" "$tmp" >&2
        printf '%s: could not write the record in %s; the filter.lfs.* settings are not recorded\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
    mv -f -- "$tmp" "$dir/lfs.record" || {
        rm -f -- "$tmp" || printf '%s: could not remove the temporary file %s\n' "$GSG_NAME" "$tmp" >&2
        printf '%s: could not write %s/lfs.record; the filter.lfs.* settings are not recorded\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
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
