#!/usr/bin/env bash
# shellcheck shell=bash
# ^ external the real-scanner suites pin trufflehog and betterleaks behaviour per version; a package manager only has the latest release
# ^ security every tarball goes through tools_fetch_verified => the SHA-256 in tools.lock decides, same as install
# ^ external usage is tests/fetch-test-tools.sh [DIR]; DIR defaults to $XDG_CACHE_HOME/git-secret-guard-test-tools and never to ~/.local/bin
set -u
set -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
# shellcheck disable=SC2034
GSG_ROOT="$ROOT"
# shellcheck source=/dev/null
source "$ROOT/lib/common.sh" && source "$ROOT/lib/tools.sh" || exit 2

dest="${1:-${XDG_CACHE_HOME:-$HOME/.cache}/git-secret-guard-test-tools}"
os="$(uname -s)" && arch="$(uname -m)" || exit 2
mkdir -p -- "$dest" || exit 2
stage="$(mktemp -d)" || exit 2
trap 'rm -rf -- "$stage"' EXIT
# ^ external Windows has no jq package to rely on => the test tools include the pinned jq.exe; elsewhere jq stays a system prerequisite
tools=("${GSG_TOOL_NAMES[@]}")
if tools_is_windows; then tools+=(jq); fi
for tool in "${tools[@]}"; do
    bin="$(tools_binary_name "$tool")" || exit 2
    plat="$(tools_platform_key "$tool" "$os" "$arch")" || exit 1
    row="$(tools_lock_lookup "$(tools_lock_path)" "$tool" "$plat")" || exit 1
    ver="${row%% *}"
    if tools_has_version "$dest/$bin" "$ver" "${TEST_TIMEOUT_BIN:-timeout}"; then
        printf '%s %s already in %s\n' "$tool" "$ver" "$dest"
        continue
    fi
    tarball="$(tools_fetch_verified "$tool" "$ver" "$plat" "${row##* }" "$stage")" || exit 1
    mkdir -p -- "$stage/out" || exit 1
    tools_extract_binary "$tarball" "$tool" "$stage/out" || exit 1
    mv -f -- "$stage/out/$bin" "$dest/$bin" || exit 1
    printf '%s %s fetched into %s\n' "$tool" "$ver" "$dest"
done
