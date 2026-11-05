# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled the git upgrade module of the macos class; registered in lib/gitup.sh, contract in CONTRIBUTING.md; loads after the bash 3.2 bootstrap
# ^ external Homebrew only has the latest git, nothing is pinned and no rebuild applies; /usr/bin/git is on the sealed system volume

# ^ security brew runs as the invoking user, never as root and never through sudo; Homebrew itself refuses root
# ^ invariant sets BREW_BIN, BREW_PREFIX and the paths below it; rc 1 = refused with a message (root, no brew, no usable prefix)
gitup_macos_prepare() {
    if gitup_is_root; then
        printf '%s: Homebrew runs as your own user, never as root; run install as a normal user\n' "$GSG_NAME" >&2
        return 1
    fi
    brew_find || return 1
    brew_paths
}

# ^ invariant one route per state of the Homebrew git; path-fix (new, not first on PATH), brew-upgrade (old), brew-install (absent)
# ^ why the file under the prefix decides, not brew list; the prefix bin is the path a user puts on PATH and the version is asked of the binary
gitup_macos_plan_upgrade() {
    local new ver
    gitup_macos_prepare || return 1
    new="$BREW_PREFIX/bin/git"
    if [ -x "$new" ] && install_git_is_new_enough "$new"; then
        GITUP_ROUTE=path-fix GITUP_FOUND_GIT="$new"
        printf '  route: path-fix; %s is already git %s, only PATH is wrong\n' "$new" "$(install_git_version "$new")"
        return 0
    fi
    if [ -x "$new" ]; then
        ver="$(install_git_version "$new")" || ver="of unknown version"
        GITUP_ROUTE=brew-upgrade
        printf '  route: brew upgrade git; the Homebrew git (%s) is git %s\n' "$new" "$ver"
        printf '  runs as your user: %s upgrade git (no sudo; Homebrew may update its own formulae first)\n' "$BREW_BIN"
        return 0
    fi
    GITUP_ROUTE=brew-install
    printf '  route: brew install git; Homebrew has no git on this machine (%s is missing)\n' "$new"
    printf '  runs as your user: %s install git (no sudo; Homebrew may update its own formulae first)\n' "$BREW_BIN"
}

# ^ invariant Homebrew has only its latest git, no build of ours can be older than a pin; the refresh plan prints nothing and returns 1
gitup_macos_plan() {
    GITUP_ROUTE=""
    case "$1" in
        upgrade) gitup_macos_plan_upgrade ;;
        refresh) return 1 ;;
        *) return 1 ;;
    esac
}

# ^ why a runner of its own, not brew_run_install; a failure there prints its own refusal line and the contract leaves the one refusal to the core
# ^ invariant VERB is install or upgrade; GITUP_CHANGED carries the change, a later refusal names it once (BREW_INSTALLED is left to the formulae install)
# ^ invariant a failure prints brew's own message (it goes straight to the terminal) and the facts, never a refusal
gitup_macos_brew_run() {
    local verb="$1" past=installed
    if [ "$verb" = upgrade ]; then past=upgraded; fi
    printf '%s: %sing git with Homebrew: brew %s git\n' "$GSG_NAME" "${verb%e}" "$verb"
    "$BREW_BIN" "$verb" git || {
        gitup_changed_add "brew $verb git was started and failed, Homebrew may have changed the git package (see brew list git)"
        printf '%s: brew %s git failed (brew'"'"'s message is above); Homebrew may have installed part of git before failing (see brew list git)\n' \
            "$GSG_NAME" "$verb" >&2
        return 1
    }
    gitup_changed_add "Homebrew $past git at $BREW_PREFIX/bin/git"
}

gitup_macos_apply() {
    gitup_macos_prepare || return 1
    case "$GITUP_ROUTE" in
        brew-install) gitup_macos_brew_run install || return 1 ;;
        brew-upgrade) gitup_macos_brew_run upgrade || return 1 ;;
        *)
            printf '%s: the macos module has no route [%s] to apply\n' "$GSG_NAME" "$GITUP_ROUTE" >&2
            return 1
            ;;
    esac
    GITUP_NEW_GIT="$BREW_PREFIX/bin/git"
}

# ^ invariant no takeover capability on macOS; the core prints this text for --take-over-system-git, changes nothing and install goes on
gitup_macos_takeover_unavailable() {
    printf '/usr/bin/git is on the sealed, SIP-protected system volume and cannot be replaced on macOS; no file there is touched, install goes on and uses the Homebrew git'
}
