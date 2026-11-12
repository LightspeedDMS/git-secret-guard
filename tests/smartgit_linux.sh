#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# ^ order sourced after tests/lib.sh, tests/lifecycle.sh, tests/gitup.sh and tests/smartgit.sh; the Linux flows run against the stand-ins of sg_standins
# ^ security HOME, install dirs and tools are in the sandbox => no test touches a real SmartGit settings dir, flatpak override or package manager

SL_FIX="$GSG_PROJECT/tests/fixtures/smartgit"
SL_APP_ID=com.syntevo.SmartGit
SL_SYSTEM_PATH=/usr/bin:/bin
SL_WRAPPER="" SL_VMOPTS="" SL_TMPDIR="" SL_INSTALL="" SL_FLATPAK_RECORD="" SL_HOME=""
SL_WRAPPER_MARKER='# git-secret-guard: written by install --configure-smartgit; undone by restore-smartgit'

# ^ invariant sl_prefs FIXTURE DEST INSTALL copies a scrubbed fixture, points its install and home placeholders into the sandbox and marks the setup as finished
# ^ invariant the file gets mode 0600 like SmartGit's own; the "startup" file next to it is what SmartGit writes once its wizard is done
sl_prefs() {
    local text
    mkdir -p -- "${2%/*}" || return 1
    text="$(cat -- "$SL_FIX/$1/preferences.yml" && printf x)" || return 1
    text="${text%x}"
    text="${text//\/opt\/smartgit/$3}"
    text="${text//\/home\/user/$SL_HOME}"
    printf '%s' "$text" >"$2" || return 1
    chmod 600 "$2" || return 1
    : >"${2%/*}/startup"
}

# ^ invariant sl_common = a Linux machine (host git 2.56.0 first on PATH, os-release fedora) with the stand-ins; launch path = sandbox and system dirs
sl_common() {
    rm -f -- "$SANDBOX/smartgit.running" "$SANDBOX/smartgit.log" "$SANDBOX/pgrep.count" "$SANDBOX/smartgit.running.after" "$SANDBOX/mv.stall" \
        "$SANDBOX/mv.stallskip" "$SANDBOX/mv.stalled" "$SANDBOX/flatpak.installed" "$SANDBOX/flatpak.ps" "$SANDBOX/flatpak.override.user" \
        "$SANDBOX/flatpak.override.system" "$SANDBOX/flatpak.version" "$SANDBOX/flatpak.nospawn" "$SANDBOX/flatpak.nostale" "$SANDBOX/flatpak.run.fail" \
        "$SANDBOX/flatpak.override.fail" "$SANDBOX/vmopts.orig" "$SANDBOX/apt.lfs.candidate" || return 1
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gu_old_git 2.56.0 || return 1
    gu_os_release 'ID=fedora' || return 1
    sg_standins || return 1
    SL_HOME="$LC_HOME"
    SG_BACKUPS="$LC_STATE/smartgit"
    SL_WRAPPER="$LC_HOME/.local/share/smartgit/host-bin/git"
    SL_VMOPTS="$LC_HOME/.var/app/$SL_APP_ID/config/smartgit/smartgit.vmoptions"
    SL_TMPDIR="$LC_HOME/.cache/smartgit-tmp"
    SL_FLATPAK_RECORD="$SG_BACKUPS/flatpak.record"
    mkdir -p -- "$SANDBOX/root" || return 1
    set_env GSG_GITUP_ROOT="$SANDBOX/root"
    set_env GSG_SMARTGIT_LAUNCH_PATH="$SANDBOX/pathbin:$SANDBOX/lfsmissing:$SL_SYSTEM_PATH"
    set_env PATH="$SANDBOX/pathbin:$SANDBOX/lfsmissing:$TEST_BASE_PATH"
}

# ^ invariant sl_settings DIR FIXTURE INSTALL = settings directory DIR of SmartGit SL_MAJOR from a fixture, a copy of the file in $SANDBOX/prefs.orig
SL_MAJOR=26.1
sl_settings() {
    SG_SETTINGS="$1"
    SG_PREFS="$SG_SETTINGS/preferences.yml"
    sl_prefs "$2" "$SG_PREFS" "$3" || return 1
    cp -- "$SG_PREFS" "$SANDBOX/prefs.orig"
}

# ^ invariant sl_flatpak_setup [FIXTURE] = the Flatpak SmartGit installed (system), its settings dir from the fixture (bundled git by default)
sl_flatpak_setup() {
    sl_common || return 1
    : >"$SANDBOX/flatpak.installed" || return 1
    sl_settings "$LC_HOME/.var/app/$SL_APP_ID/config/smartgit/$SL_MAJOR" "${1:-linux-flatpak-26.1}" /app
}

# ^ invariant sl_tarball_setup = a tarball install in $SANDBOX/apps/smartgit (bundled git 2.53.0), settings under ~/.config/smartgit
sl_tarball_setup() {
    sl_common || return 1
    SL_INSTALL="$SANDBOX/apps/smartgit"
    mkdir -p -- "$SL_INSTALL/bin" "$SL_INSTALL/git/bin" || return 1
    gm_stub "$SL_INSTALL/bin/smartgit.sh" 'exit 0' || return 1
    gm_stub "$SL_INSTALL/git/bin/git" "if [ \"\$1\" = --version ]; then echo 'git version 2.53.0'; exit 0; fi
exec '$GIT' \"\$@\"" || return 1
    set_env GSG_SMARTGIT_INSTALL_DIRS="$SL_INSTALL"
    sl_settings "$LC_HOME/.config/smartgit/$SL_MAJOR" linux-tarball-26.1 "$SL_INSTALL"
}

# ^ invariant sl_hand_wrapper writes the wrapper a user makes by hand after the docs, without our marker, running the host git
sl_hand_wrapper() {
    mkdir -p -- "${SL_WRAPPER%/*}" || return 1
    printf '#!/bin/sh\nexec flatpak-spawn --host git "$@"\n' >"$SL_WRAPPER" || return 1
    chmod 755 "$SL_WRAPPER"
}

# ^ invariant sl_flatpak_running lists an instance with a live pid (this shell); sl_flatpak_stale_only one whose pid is gone, as a finished flatpak run leaves
sl_flatpak_running() { printf '%s\t%s\n' "$$" "$SL_APP_ID" >"$SANDBOX/flatpak.ps"; }
sl_flatpak_stale_only() { printf '%s\t%s\n' "$(sh -c 'echo $$')" "$SL_APP_ID" >"$SANDBOX/flatpak.ps"; }
