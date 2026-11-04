#!/usr/bin/env bash
set -u
set -o pipefail

PROJECT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
trace="$(mktemp)" || exit 2
trap 'rm -f -- "$trace"' EXIT

GSG_TRACE_FILE="$trace" bash "$PROJECT/tests/run.sh" "$@" | grep -E '^(FAIL|SUMMARY)'
run_rc="${PIPESTATUS[0]}"

cd -- "$PROJECT" || exit 2
awk -v trace="$trace" -f tests/coverage.awk hooks/secret-scan bin/git-secret-guard lib/common.sh lib/brew.sh lib/extract.sh lib/exempt.sh lib/report.sh \
    lib/scanners/trufflehog.sh lib/scanners/betterleaks.sh lib/tools.sh lib/state.sh lib/hookspath.sh lib/install.sh lib/install_tools.sh lib/uninstall.sh lib/status.sh \
    lib/timer.sh lib/launchd.sh lib/doctor.sh lib/doctor_repos.sh lib/doctor_findings.sh
exit "$run_rc"
