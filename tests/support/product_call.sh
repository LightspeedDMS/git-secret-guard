#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2016
# ^ order sourced after tests/support/lib.sh; it needs no lifecycle sandbox, only GSG_ENV, EXTRA_ENV and SANDBOX of lib.sh
# ^ why GSG_ENV and a bare prelude, not lc_begin; these tests call product functions only, and run on Git for Windows too (the class there is windows)

# ^ invariant the libraries the product functions of the tests below need, loaded in a clean shell; a missing one ends the run with 9
PC_PRELUDE='set -u; GSG_ROOT="$1"; shift
for lib in platform/brew core/common core/state install/tools install/hookspath platform/wsl install/install install/install_tools gitup/gitup gitup/gitup_source gitup/gitup_takeover scan/exempt autoupdate/timer platform/launchd inspect/doctor; do source "$GSG_ROOT/lib/$lib.sh" || exit 9; done
'

# ^ invariant pc_run CODE ARGS... runs CODE after the prelude in a clean shell; OUT and ERR hold what it printed, the rc is the one assert_rc reads
pc_run() {
    local code="$1"
    shift
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c "$PC_PRELUDE$code" _ "$GSG_PROJECT" "$@"
    OUT="$(<"$SANDBOX/.out")"
    ERR="$(<"$SANDBOX/.err")"
}

# ^ invariant pc_run_as_root points the product at a sandbox /var, /usr and /etc owned by the current user and acts as root; no real system path is reachable
pc_run_as_root() {
    local code="$1"
    shift
    pc_run 'GSG_GITUP_ROOT="$1"; shift; gitup_paths || exit 9; gitup_is_root() { return 0; }
        gitup_system_bin() { REPLY="$(command -v "$1")"; }
        '"$code" "$SANDBOX/root" "$@"
}

# ^ invariant pc_root_dirs makes an empty sandbox root with the directories the takeover looks at; refuses a relative SANDBOX
pc_root_dirs() {
    if [ -z "$SANDBOX" ] || [[ $SANDBOX != /* ]]; then fail "SANDBOX is not an absolute path"; return 1; fi
    rm -rf -- "$SANDBOX/root" || return 1
    mkdir -p -- "$SANDBOX/root/usr/bin" "$SANDBOX/root/usr/local/bin" "$SANDBOX/root/etc/dnf" "$SANDBOX/root/var/lib/git-secret-guard"
}

# ^ invariant a stand-in for the git GitHub Desktop bundles, at the path the product looks for below the sandbox root
pc_bundled_git() {
    local d="$SANDBOX/root/usr/lib/github-desktop/resources/app/git/bin"
    pc_root_dirs && mkdir -p -- "$d" || return 1
    printf '#!/bin/sh\necho "git version %s"\n' "$1" >"$d/git" && chmod 755 "$d/git"
}

# ^ invariant a second old git (2.52, like /usr/bin/git on the RHEL host) after the real one on PATH; its own warning must not be mistaken for the bundled git's
PC_OLD_ON_PATH='PATH="$PATH:$1"; '
pc_old_git_dir() {
    mkdir -p -- "$SANDBOX/oldgit" || return 1
    printf '#!/bin/sh\necho "git version 2.52.0"\n' >"$SANDBOX/oldgit/git" && chmod 755 "$SANDBOX/oldgit/git"
}
