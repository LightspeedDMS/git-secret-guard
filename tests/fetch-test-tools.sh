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

check=0
if [ "${1:-}" = --check ]; then
    check=1
    shift
fi
dest="${1:-${XDG_CACHE_HOME:-$HOME/.cache}/git-secret-guard-test-tools}"
os="$(uname -s)" && arch="$(uname -m)" || exit 2
mkdir -p -- "$dest" || exit 2
stage="$(mktemp -d)" || exit 2
trap 'rm -rf -- "$stage"' EXIT
# ^ external Windows has no jq package to rely on => the test tools include the pinned jq.exe; elsewhere jq stays a system prerequisite
tools=("${GSG_TOOL_NAMES[@]}")
if tools_is_windows; then tools+=(jq); fi

# ^ invariant --check prints what the cache lacks and exits 3, else exits 0; the installer is named from the lock row, not a glob; an older one cannot pass
if [ "$check" -eq 1 ]; then
    missing=()
    for tool in "${tools[@]}"; do
        bin="$(tools_binary_name "$tool")" || exit 2
        [ -x "$dest/$bin" ] || missing+=("$bin")
    done
    if tools_is_windows; then
        row="$(tools_lock_lookup "$(tools_lock_path)" git-for-windows windows_amd64)" || exit 1
        [ -f "$dest/Git-${row%% *}-64-bit.exe" ] || missing+=("Git-${row%% *}-64-bit.exe")
    fi
    if [ "${#missing[@]}" -gt 0 ]; then
        printf 'the tools cache %s lacks: %s\n' "$dest" "${missing[*]}"
        exit 3
    fi
    exit 0
fi
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
# ^ external the Windows upgrade runner is tested against the real pinned Git for Windows installer; it is only read and checked, never started
if tools_is_windows; then
    row="$(tools_lock_lookup "$(tools_lock_path)" git-for-windows windows_amd64)" || exit 1
    ver="${row%% *}"
    inst="Git-$ver-64-bit.exe"
    if [ -f "$dest/$inst" ] && [ "$(sha256sum -- "$dest/$inst" | cut -d' ' -f1)" = "${row##* }" ]; then
        printf 'git-for-windows %s already in %s\n' "$ver" "$dest"
    else
        file="$(tools_fetch_verified git-for-windows "$ver" windows_amd64 "${row##* }" "$stage")" || exit 1
        mv -f -- "$file" "$dest/$inst" || exit 1
        printf 'git-for-windows %s fetched into %s\n' "$ver" "$dest"
    fi
fi
