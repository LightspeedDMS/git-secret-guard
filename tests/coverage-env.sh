# shellcheck shell=bash
if [ -n "${GSG_TRACE_FILE:-}" ]; then
    if ! exec {GSG_TRACE_FD}>>"$GSG_TRACE_FILE"; then
        echo "coverage-env: cannot open trace file $GSG_TRACE_FILE" >&2
        return 1
    fi
    BASH_XTRACEFD="$GSG_TRACE_FD"
    PS4='TRACE ${BASH_SOURCE[0]:-}:${LINENO:-}:'
    set -x
fi
