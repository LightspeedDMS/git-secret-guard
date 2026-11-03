#!/usr/bin/env bash
# ^ invariant started by hooks/secret-scan through lib/proc.sh => on Linux runner pid = its process group id, which the hook's cleanup signals
set -u
set -o pipefail

LIBDIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
name="${1:-}"
case "$name" in
    trufflehog | gitleaks) ;;
    *) printf 'run-scanner: unknown scanner [%s]\n' "$name" >&2; exit 2 ;;
esac
[ "$#" -eq 3 ] || { printf 'run-scanner: expected 3 arguments, got %s\n' "$#" >&2; exit 2; }

# shellcheck source=/dev/null
source "$LIBDIR/common.sh" || exit 1
# shellcheck source=/dev/null
source "$LIBDIR/scanners/$name.sh" || exit 1
# ^ order settings after the adapter lib => a settings-defined scan_<name> overrides it (used by tests/test_hook.sh)
load_settings "${LIBDIR%/*}/settings" || exit 1

"scan_$name" "$2" "$3"
