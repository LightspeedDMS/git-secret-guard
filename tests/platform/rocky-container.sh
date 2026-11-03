#!/usr/bin/env bash
set -u
set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
# shellcheck source=tests/platform/ubuntu-container.sh
source "$HERE/ubuntu-container.sh" || exit 2

# ^ why the Ubuntu script is sourced and four names are redefined below, not copied; steps, git build, shellcheck, E2E and suite phases are shared
PLATFORM_TITLE="ROCKY LINUX 9"
GIT_SOURCE=source
SHORT_TIMEOUT=60
DNF_TIMEOUT=900
# ^ external the 9.7 image meets repositories serving 9.8 => runtime libraries are listed to be upgraded to match the -devel packages
# ^ external coreutils is left out on purpose; the image has coreutils-single (timeout included) and the full package conflicts with it
DNF_DEPS=(git ca-certificates jq tar gzip xz findutils diffutils gawk procps-ng util-linux systemd dbus-daemon shadow-utils
    perl make gcc libcurl openssl-libs expat zlib libcurl-devel openssl-devel expat-devel zlib-devel python3-pip)

usage() {
    printf 'usage: rocky-container.sh --skip-isolation REASON [--phase prepare|e2e|suite]... [--suite-file test_x.sh]... [--image REF]\n'
    printf 'Runs as root inside rockylinux:9.x. Started by tests/platform/mac-linux.sh, the macOS host runner. check_isolation is the RHEL launcher'"'"'s and\n'
    printf 'knows only ubuntu 24.04, so a skip reason is required and is printed in the output and the summary.\n'
}

# ^ invariant the tarball git in /usr/local/bin comes first on PATH; the stock /usr/bin/git stays installed (older than 2.54), as on the reference host
install_git_source() {
    build_git_from_tarball
}

# ^ external pre-commit has no RHEL 9 base package => installed from pip (unpinned); the suite probes its hook shim only
install_pre_commit() {
    step "pip install pre-commit" "$DOWNLOAD_TIMEOUT" python3 -m pip install --prefix /usr/local pre-commit
}

phase_prepare() {
    # ^ external the image's libcurl-minimal conflicts with libcurl and libcurl-devel => --allowerasing swaps it (the stock fix on RHEL minimal images)
    step "dnf install prerequisites" "$DNF_TIMEOUT" dnf install -y --allowerasing --setopt=install_weak_deps=False "${DNF_DEPS[@]}" || return 1
    step "start the system bus (systemd-analyze connects to it)" "$SHORT_TIMEOUT" bash -c 'mkdir -p /run/dbus && dbus-daemon --system --fork' || return 1
    install_shellcheck || return 1
    install_pre_commit || return 1
    obtain_git || return 1
    if ! id -u "$TEST_USER" >/dev/null 2>&1; then
        step "create the non-root test user" "$SHORT_TIMEOUT" useradd -m -s /bin/bash "$TEST_USER" || return 1
    fi
}

skip_given=0
for arg in "$@"; do
    if [ "$arg" = --skip-isolation ]; then skip_given=1; fi
done
if [ "$skip_given" -eq 0 ]; then
    usage >&2
    exit 2
fi
main "$@"
