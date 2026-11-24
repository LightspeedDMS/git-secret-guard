#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2153 # stand-in texts are single-quoted, WP_* globals are read by the test files, WU_DIR is set by gitup_windows.sh
# ^ order sourced after tests/support/lib.sh and tests/support/gitup_windows.sh => the helpers here build on wu, wu_begin, set_env and the sandbox
# ^ coupled lib/platform/winpath.sh runs bin/gsg-path.ps1 under the Windows PowerShell of System32; here powershell.exe is a recording stand-in
# ^ security the stand-in lives in the sandbox System32 named by GSG_GITUP_ROOT => no helper here reaches the real registry or the real PowerShell

# ^ external Linux has no cygpath; this stand-in maps /c/x to C:\x and any other absolute path below C:\fake, a relative one stays as it is
# ^ why a second fake, not WU_FAKE_CYGPATH; it reads the path as $2 (these calls end in -l -- PATH) and puts a relative path under C:\fake
WP_FAKE_CYGPATH='cygpath() {
    local p="${*: -1}" rest
    case "$p" in
        /[a-z]/*) rest="${p:2}"; p="${p:1:1}"; p="${p^}:${rest//\//\\}" ;;
        /*) p="C:\\fake${p//\//\\}" ;;
    esac
    printf "%s\n" "$p"
}'
# ^ invariant the status of a shell whose libraries did not load; the prelude exits with it
WP_LOAD_FAILED_RC=9
# ^ coupled WP_FAKE_CYGPATH_TEXT is supplied by wp (the text of WP_FAKE_CYGPATH); the prelude runs only through wp
WP_PRELUDE='for l in install/install_path platform/winpath; do source "$GSG_ROOT/lib/$l.sh" || exit '"$WP_LOAD_FAILED_RC"'; done
if ! type -P cygpath >/dev/null; then eval "$WP_FAKE_CYGPATH_TEXT"; fi
GSG_BIN_DIR=/c/Users/me/.local/bin
'
WP_DIR='C:\Users\me\.local\bin'
# ^ coupled the adapter cuts a reason at 200 characters (GSG_WINPATH_REASON_MAX); the test reason is longer, the probe a longer run of digits
WP_LONG_REASON_LENGTH=300 WP_PAST_THE_CUT=250

# ^ invariant wp CODE ARGS... runs CODE in the clean shell of wu with winpath.sh loaded and the CLI folder /c/Users/me/.local/bin; the answer is OUT, ERR, RC
wp() {
    local code="${1:?wp needs the code to run}"
    shift
    wu "WP_FAKE_CYGPATH_TEXT=${WP_FAKE_CYGPATH@Q}"$'\n'"$WP_PRELUDE$code" "$@"
}

# ^ invariant wp_begin leaves a sandbox System32 whose powershell.exe logs its arguments to ps.log and answers per command word from files
wp_begin() {
    local f
    wu_begin user 2.50.0.1 || return 1
    f="$WU_DIR/root/windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    mkdir -p -- "${f%/*}" || return 1
    {
        printf '#!/bin/sh\nWU_DIR=%q\n' "$WU_DIR"
        cat <<'STUB'
printf '%s\n' "$*" >>"$WU_DIR/ps.log"
cmd="$6"
if [ -f "$WU_DIR/ps.err.$cmd" ]; then cat "$WU_DIR/ps.err.$cmd" >&2; fi
if [ -f "$WU_DIR/ps.out.$cmd" ]; then cat "$WU_DIR/ps.out.$cmd"; fi
if [ -f "$WU_DIR/ps.rc.$cmd" ]; then exit "$(cat "$WU_DIR/ps.rc.$cmd")"; fi
exit 0
STUB
    } >"$f" && chmod 755 "$f"
}

# ^ invariant wp_say CMD OUT RC ERR sets what the stand-in prints on stdout, its exit status and its stderr line when asked for CMD (plan, apply, remove)
wp_say() {
    local cmd="${1:?wp_say needs the command word}" out="${2?wp_say needs the text to print}"
    printf '%s\n' "$out" >"$WU_DIR/ps.out.$cmd" && printf '%s\n' "${3:-0}" >"$WU_DIR/ps.rc.$cmd" || return 1
    if [ -n "${4:-}" ]; then printf '%s\n' "$4" >"$WU_DIR/ps.err.$cmd"; else rm -f -- "$WU_DIR/ps.err.$cmd"; fi
}

wp_log() { if [ -f "$WU_DIR/ps.log" ]; then cat "$WU_DIR/ps.log"; fi; }
