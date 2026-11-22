#!/usr/bin/env bash
set -u
set -o pipefail

PROJECT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
trace="$(mktemp)" || exit 2
trap 'rm -f -- "$trace"' EXIT

GSG_TRACE_FILE="$trace" bash "$PROJECT/tests/run.sh" "$@" | grep -E '^(FAIL|SUMMARY)'
run_rc="${PIPESTATUS[0]}"

cd -- "$PROJECT" || exit 2
awk -v trace="$trace" -v root="$PROJECT" -f tests/coverage.awk hooks/secret-scan bin/git-secret-guard lib/core/common.sh lib/platform/brew.sh lib/scan/extract.sh lib/scan/exempt.sh lib/scan/report.sh \
    lib/scan/scanners/trufflehog.sh lib/scan/scanners/betterleaks.sh lib/install/tools.sh lib/core/state.sh lib/install/hookspath.sh lib/install/install.sh lib/install/install_cmd.sh \
    lib/install/install_tools.sh lib/install/uninstall.sh lib/inspect/status.sh lib/autoupdate/timer.sh lib/platform/launchd.sh lib/platform/wsl.sh lib/inspect/doctor.sh \
    lib/inspect/doctor_repos.sh lib/inspect/doctor_findings.sh lib/gitup/gitup*.sh
exit "$run_rc"
