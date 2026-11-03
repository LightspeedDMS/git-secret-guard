# shellcheck shell=bash
# ^ external BASH_ENV also reaches a bash 3.2 child on macOS, and exec {fd}>> needs bash 4.1; such a child is simply not traced
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then return 0; fi
if [ -n "${GSG_TRACE_FILE:-}" ]; then
    if ! exec {GSG_TRACE_FD}>>"$GSG_TRACE_FILE"; then
        echo "coverage-env: cannot open trace file $GSG_TRACE_FILE" >&2
        return 1
    fi
    BASH_XTRACEFD="$GSG_TRACE_FD"
    PS4='TRACE ${BASH_SOURCE[0]:-}:${LINENO:-}:'
    set -x
fi
