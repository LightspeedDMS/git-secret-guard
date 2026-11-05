#!/usr/bin/env bash
set -u
set -o pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
# shellcheck source=tests/platform/ubuntu-container.sh
source "$HERE/ubuntu-container.sh" || exit 2
# shellcheck source=tests/platform/rpm-phase.sh
source "$HERE/rpm-phase.sh" || exit 2

PLATFORM_TITLE="FEDORA 44"
RPM_DISTRO=fedora
ISOLATION_OS_ID=fedora
ISOLATION_OS_VERSION=44

usage() {
    printf 'usage: fedora-container.sh --host-ns NAME=ID... [--phase upgrade] [--image REF]\n'
    printf 'Runs as root inside fedora:44. Started by tests/platform/rpm.sh, which passes --host-ns and --image. Only the upgrade phase exists here: the image has no git,\n'
    printf 'so it is the real package-route E2E (dnf 5, no source build).\n'
}

# ^ invariant the prepare, e2e and suite phases of the Ubuntu script use apt; on Fedora they do not exist
phase_prepare() {
    printf 'the prepare phase does not exist on Fedora; use --phase upgrade\n' >&2
    return 1
}
phase_e2e() { phase_prepare; }
phase_suite() { phase_prepare; }

has_phase=0
for arg in "$@"; do
    if [ "$arg" = --phase ]; then has_phase=1; fi
done
if [ "$has_phase" -eq 0 ]; then set -- "$@" --phase upgrade; fi
main "$@"
