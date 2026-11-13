#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2034,SC2119,SC2120
# ^ order sourced after tests/lib.sh; the unit helpers (sw_run) fake uname and cygpath, the end-to-end helpers (sw_setup) need a real Git for Windows
# ^ security HOME, the install dirs, the settings base and every tool are in the sandbox => no test touches a real %APPDATA%\syntevo, ~/.gitconfig or SmartGit

# ^ external Linux and macOS have no cygpath; the stand-in maps C:\x to /c/x and /x to C:\fake\x (and back), enough for the string work of the product
SW_FAKE_CYGPATH='cygpath() {
    local p="$2" rest
    case "$1" in
        -u) case "$p" in
                [Cc]:\\[Ff][Aa][Kk][Ee]\\*) rest="${p:7}"; printf "%s\n" "${rest//\\//}" ;;
                [A-Za-z]:*) rest="${p:2}"; p="${p:0:1}"; printf "/%s%s\n" "${p,,}" "${rest//\\//}" ;;
                *) printf "%s\n" "${p//\\//}" ;;
            esac ;;
        *) case "$p" in
               /[a-z]/*) rest="${p:2}"; p="${p:1:1}"; printf "%s:%s\n" "${p^^}" "${rest//\//\\}" ;;
               *) printf "C:\\\\fake%s\n" "${p//\//\\}" ;;
           esac ;;
    esac
}'

# ^ invariant the libraries the CLI loads, in its order; uname says Git for Windows and SYSTEMROOT is set => every Windows branch runs on any host
SW_PRELUDE='set -u
GSG_ROOT="$1"; GSG_NAME=git-secret-guard; GSG_UNINSTALL_ACTIONS=0
uname() { if [ "${1:-}" = -m ]; then echo x86_64; else echo MINGW64_NT-10.0-26200; fi; }
type -P cygpath >/dev/null || eval "$SW_FAKE_CYGPATH"
export SYSTEMROOT="${SYSTEMROOT:-C:\\Windows}"
for lib in brew common state tools hookspath exempt wsl install install_cmd install_tools gitup gitup_source smartgit smartgit_report smartgit_offer smartgit_lfs smartgit_apply smartgit_flatpak; do
    source "$GSG_ROOT/lib/$lib.sh" || exit 9
done
shift
'

# ^ invariant sw_stub_git FILE VERSION [wrapper] writes a git.exe stand-in; --version answers VERSION.windows.4, other calls run the real git of the suite
# ^ invariant lfs.missing beside it makes lfs fail as without Git LFS; env.log beside it records the PATH of each call
# ^ external git.exe finds git-lfs.exe once its own directory is on PATH (measured); wrapper = cmd\git.exe, adding usr\bin; the real git dir goes first
sw_stub_git() {
    local lead="PATH=\"${GIT%/*}:\$PATH\"; export PATH"
    mkdir -p -- "${1%/*}" || return 1
    if [ "${3:-}" = wrapper ]; then lead="PATH=\"${GIT%/*}:/usr/bin:\$PATH\"; export PATH"; fi
    {
        printf '#!/bin/sh\nd="${0%%/*}"\n'
        printf 'printf "path=[%%s]\\n" "$PATH" >>"$d/env.log"\n'
        printf 'if [ "$1" = --version ]; then echo "git version %s.windows.4"; exit 0; fi\n' "$2"
        printf 'if [ "$1" = lfs ] && [ -f "$d/lfs.missing" ]; then echo "git: lfs is not a git command" >&2; exit 1; fi\n'
        printf '%s\nexec "%s" "$@"\n' "$lead" "$GIT"
    } >"$1" || return 1
    chmod 755 "$1"
}

# ^ invariant sw_gfw DIR [CMDVER [BINVER]] builds a Git for Windows tree with ucrt64/bin/git.exe (BINVER, default 2.56.0) and cmd/git.exe (CMDVER, "-" = none)
sw_gfw() {
    local dir="$1" cmdver="${2:-2.56.0}" binver="${3:-2.56.0}"
    sw_stub_git "$dir/ucrt64/bin/git.exe" "$binver" || return 1
    if [ "$cmdver" = - ]; then return 0; fi
    sw_stub_git "$dir/cmd/git.exe" "$cmdver" wrapper
}

# ^ invariant sw_ps LINES... writes a ps stand-in into the tool directory; it prints a header and the lines like ps -W; ps.fail fails it, ps.log records calls
sw_ps() {
    mkdir -p -- "$SANDBOX/pathbin" || return 1
    printf '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND\n' >"$SANDBOX/ps.out" || return 1
    if [ "$#" -gt 0 ]; then printf '%s\n' "$@" >>"$SANDBOX/ps.out" || return 1; fi
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/ps.log"\nif [ -f "%s/ps.fail" ]; then exit 1; fi\ncat "%s/ps.out"\n' "$SANDBOX" "$SANDBOX" "$SANDBOX" >"$SANDBOX/pathbin/ps" || return 1
    chmod 755 "$SANDBOX/pathbin/ps" || return 1
    rm -f -- "$SANDBOX/ps.fail" "$SANDBOX/ps.log"
}

# ^ invariant sw_w PATH prints the Windows spelling of a path as the cygpath of the product answers it (the stand-in off Windows)
sw_w() { sw_run 'cygpath -w "$1"' "$1" >/dev/null; printf '%s' "$OUT"; }

# ^ invariant sw_prefs FIXTURE DEST APP copies a scrubbed fixture, points the install placeholder at APP (Windows spelling) and marks the setup as finished
# ^ invariant mode 0600 like SmartGit's own; the startup file beside it is what SmartGit writes once its wizard is done
sw_prefs() {
    local text app_w
    app_w="$(cygpath -w "$3")" || return 1
    mkdir -p -- "${2%/*}" || return 1
    text="$(cat -- "$GSG_PROJECT/tests/fixtures/smartgit/$1/preferences.yml" && printf x)" || return 1
    text="${text%x}"
    printf '%s' "${text//'C:\Program Files\SmartGit'/$app_w}" >"$2" || return 1
    chmod 600 "$2" || return 1
    : >"${2%/*}/startup"
}

# ^ invariant sw_setup = a Windows machine (real Git for Windows only) with a Git for Windows tree first on PATH and SmartGit 26.1 with its bundled git 2.53.0
# ^ invariant its settings sit on the bundled git, no SmartGit process is listed, and a copy of the preferences is in $SANDBOX/prefs.orig
SW_GFW="" SW_APP=""
sw_setup() {
    if [ "$TEST_IS_WINDOWS" -ne 1 ]; then skip_test "needs Git for Windows: the end-to-end flow runs real native git.exe, cygpath and ps -W"; fi
    rm -rf -- "$SANDBOX/gfw" "$SANDBOX/apps" "$SANDBOX/appdata" "$SANDBOX/prefs.orig" || return 1
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    SW_GFW="$SANDBOX/gfw" SW_APP="$SANDBOX/apps/SmartGit"
    SG_SETTINGS="$SANDBOX/appdata/syntevo/SmartGit/26.1"
    SG_PREFS="$SG_SETTINGS/preferences.yml"
    SG_BACKUPS="$LC_STATE/smartgit"
    sw_gfw "$SW_GFW" || return 1
    mkdir -p -- "$SW_APP/bin" || return 1
    : >"$SW_APP/bin/smartgit.exe" && sw_stub_git "$SW_APP/git/bin/git.exe" 2.53.0 || return 1
    sw_prefs windows-26.1 "$SG_PREFS" "$SW_APP" && cp -- "$SG_PREFS" "$SANDBOX/prefs.orig" || return 1
    sw_ps || return 1
    set_env GSG_SMARTGIT_INSTALL_DIRS="$SW_APP" GSG_SMARTGIT_SETTINGS_BASE="$SANDBOX/appdata/syntevo/SmartGit"
    set_env PATH="$SW_GFW/ucrt64/bin:$SANDBOX/pathbin:$TEST_BASE_PATH"
}

# ^ invariant sw_set_exec VALUE rewrites the executable line as the GUI of SmartGit does (no executable.absolute line) and keeps every other byte
sw_set_exec() {
    local out
    out="$(SW_VALUE="$1" awk '/^  executable: / { print "  executable: " ENVIRON["SW_VALUE"]; next } /^  executable\.absolute: / { next } { print }' "$SG_PREFS")" || return 1
    printf '%s\n' "$out" >"$SG_PREFS" && cp -- "$SG_PREFS" "$SANDBOX/prefs.orig"
}

# ^ invariant sw_run BODY ARGS... runs BODY in a clean shell, a Git for Windows by its own account; OUT, ERR and RC are set as everywhere
sw_run() {
    local code="$1"
    shift
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" SW_FAKE_CYGPATH="$SW_FAKE_CYGPATH" bash -c "$SW_PRELUDE$code" _ "$GSG_PROJECT" "$@"
    OUT="$(<"$SANDBOX/.out")"
    ERR="$(<"$SANDBOX/.err")"
}
