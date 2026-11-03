#!/usr/bin/env bash
set -u
set -o pipefail

# ^ external both images are pinned by manifest-list digest (Ubuntu = the pin of ubuntu.sh); the lookup is in docs/platforms.md
UBUNTU_IMAGE=docker.io/library/ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
ROCKY_IMAGE=docker.io/rockylinux/rockylinux:9.7@sha256:53f4c6dcb34e1403bd93207351f0af9a593610faeb7165cb8a037346765199b0
SKIP_REASON="macOS host: isolation enforced by the podman VM boundary, not verified"
TOTAL_TIMEOUT_SECONDS=7200
KILL_AFTER_SECONDS=60
PROBE_TIMEOUT_SECONDS=60
PULL_TIMEOUT_SECONDS=600
CLEANUP_TIMEOUT_SECONDS=60
# ^ invariant bash 4.4 is the first release where an empty array expands under set -u; the command line below relies on it
MIN_BASH_MAJOR=4
MIN_BASH_MINOR=4
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
PROJECT="${HERE%/tests/platform}"

usage() {
    printf 'usage: tests/platform/mac-linux.sh ubuntu|rocky [--dry-run] [--timeout SECONDS] [container script options]\n'
    printf 'Runs tests/run.sh and an install E2E in a podman-machine Linux container (aarch64) started from a macOS host.\n'
    printf 'Options it does not know go to ubuntu-container.sh or rocky-container.sh (--phase prepare|e2e|suite, --suite-file test_x.sh, --git ...).\n'
}

if [ "${BASH_VERSINFO[0]}" -lt "$MIN_BASH_MAJOR" ] || { [ "${BASH_VERSINFO[0]}" -eq "$MIN_BASH_MAJOR" ] && [ "${BASH_VERSINFO[1]}" -lt "$MIN_BASH_MINOR" ]; }; then
    printf 'mac-linux.sh: needs bash >= %s.%s (found %s); put /opt/homebrew/bin first on PATH\n' "$MIN_BASH_MAJOR" "$MIN_BASH_MINOR" "$BASH_VERSION" >&2
    exit 2
fi

distro="${1:-}"
case "$distro" in
    ubuntu) image="$UBUNTU_IMAGE" ;;
    rocky) image="$ROCKY_IMAGE" ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
shift

dry=0
passthru=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) dry=1 ;;
        --timeout)
            shift
            if [[ ${1:-} != [1-9]* ]] || [[ $1 == *[!0-9]* ]]; then
                printf 'mac-linux.sh: --timeout needs a positive number of seconds\n' >&2
                exit 2
            fi
            TOTAL_TIMEOUT_SECONDS="$1"
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) passthru+=("$1") ;;
    esac
    shift
done

# ^ why gtimeout first, not timeout; macOS has neither, coreutils from Homebrew installs gtimeout (and timeout only through its gnubin directory)
timeout_bin="$(type -P gtimeout || type -P timeout)" || {
    printf 'mac-linux.sh: needs gtimeout or timeout (brew install coreutils)\n' >&2
    exit 2
}
if [ "$dry" -eq 0 ] && ! type -P podman >/dev/null; then
    printf 'mac-linux.sh: podman is required and was not found on PATH\n' >&2
    exit 2
fi

copy="" name="gsg-mac-$distro-$$"
# ^ order trap before mktemp => the private copy and a half-started container never outlive an interrupted run
# shellcheck disable=SC2329
cleanup() {
    if [ "$dry" -eq 0 ]; then "$timeout_bin" "$CLEANUP_TIMEOUT_SECONDS" podman rm -f "$name" >/dev/null 2>&1; fi
    if [ -n "$copy" ] && [[ ${copy##*/} == gsg-mac-src.* ]]; then rm -rf -- "$copy"; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ^ security the container mounts a copy made now, not the live tree => the checkout and its .git history stay out of reach
copy="$(mktemp -d "${TMPDIR:-/tmp}/gsg-mac-src.XXXXXX")" || exit 2
# ^ why the file list of git ls-files -co --exclude-standard, not a copy of the tree minus .git; same rule as ubuntu.sh
git -C "$PROJECT" ls-files -z -co --exclude-standard | tar -C "$PROJECT" --null -T - -cf - | tar -C "$copy" -xf - || {
    printf 'mac-linux.sh: cannot copy the checkout\n' >&2
    exit 2
}

# ^ security no -e, no --env-host, no host HOME, ~/.gitconfig or ~/.ssh in the container; --http-proxy=false stops podman forwarding proxy variables
# ^ hazard dropping --init or the timeout -k => the time limit never fires; same reason as ubuntu.sh
# ^ external podman machine mounts /run/secrets/rhsm from its VM into every container; the suite's check_isolation test wants an empty /run/secrets
cmd=("$timeout_bin" --foreground -k "$KILL_AFTER_SECONDS" "$TOTAL_TIMEOUT_SECONDS" podman run --rm --init --name "$name" --pull=never --http-proxy=false
    --tmpfs /run/secrets -v "$copy:/src:ro" "$image" bash "/src/tests/platform/$distro-container.sh" --image "$image" --skip-isolation "$SKIP_REASON" "${passthru[@]}")

if [ "$dry" -eq 1 ]; then
    printf 'arg: %s\n' "${cmd[@]}"
    printf 'copy-files: %s\n' "$(find "$copy" -type f | wc -l | tr -d ' ')"
    if [ -e "$copy/.git" ]; then printf 'copy-has-git: yes\n'; else printf 'copy-has-git: no\n'; fi
    exit 0
fi

if ! "$timeout_bin" "$PROBE_TIMEOUT_SECONDS" podman image exists "$image"; then
    "$timeout_bin" "$PULL_TIMEOUT_SECONDS" podman pull "$image" || {
        printf 'mac-linux.sh: cannot pull %s\n' "$image" >&2
        exit 2
    }
fi

printf 'isolation check SKIPPED: %s\n' "$SKIP_REASON"
"${cmd[@]}"
rc=$?
if [ "$rc" -eq 0 ]; then
    printf 'MAC-HOST LINUX TEST (%s): PASS (image %s)\n' "$distro" "$image"
else
    printf 'MAC-HOST LINUX TEST (%s): FAIL (container run exit %s, image %s)\n' "$distro" "$rc" "$image"
fi
exit "$rc"
