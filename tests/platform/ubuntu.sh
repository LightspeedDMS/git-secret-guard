#!/usr/bin/env bash
set -u
set -o pipefail

# ^ external digest = OCI index (manifest list) of ubuntu:24.04 from the registry; lookup and bump steps in doc:CLAUDE.md#Portability and follow-ups
IMAGE=docker.io/library/ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
TOTAL_TIMEOUT_SECONDS=5400
PULL_TIMEOUT_SECONDS=600
CLEANUP_TIMEOUT_SECONDS=60
SENTINEL=host-environment-must-not-arrive
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
PROJECT="${HERE%/tests/platform}"

usage() {
    printf 'usage: tests/platform/ubuntu.sh [--dry-run] [--timeout SECONDS] [container script options]\n'
    printf 'Runs tests/run.sh and an install E2E in a podman %s container.\n' "$IMAGE"
    printf 'Options it does not know go to ubuntu-container.sh (--git ppa|source|auto, --phase prepare|e2e|suite).\n'
}

dry=0
passthru=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) dry=1 ;;
        --timeout)
            shift
            if [[ ${1:-} != [1-9]* ]] || [[ $1 == *[!0-9]* ]]; then
                printf 'ubuntu.sh: --timeout needs a positive number of seconds\n' >&2
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

copy="" podman_home="" name="gsg-ubuntu-$$"
PODMAN_ENV=()
# ^ order trap before mktemp => the private copy, the scratch podman HOME and a half-started container never outlive an interrupted run
# shellcheck disable=SC2329
cleanup() {
    if [ "$dry" -eq 0 ] && [ "${#PODMAN_ENV[@]}" -gt 0 ]; then timeout "$CLEANUP_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" podman rm -f "$name" >/dev/null 2>&1; fi
    if [ -n "$copy" ] && [[ ${copy##*/} == gsg-ubuntu-src.* ]]; then rm -rf -- "$copy"; fi
    if [ -n "$podman_home" ] && [[ ${podman_home##*/} == gsg-ubuntu-podman-home.* ]]; then rm -rf -- "$podman_home"; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$dry" -eq 0 ] && ! type -P podman >/dev/null; then
    printf 'ubuntu.sh: podman is required and was not found on PATH\n' >&2
    exit 2
fi

# ^ security the container mounts a copy made now, not the live tree => the checkout and its .git history stay out of reach
copy="$(mktemp -d -t gsg-ubuntu-src.XXXXXX)" || exit 2
# ^ why the file list of git ls-files -co --exclude-standard, not a copy of the tree minus .git; the tree copy carries ignored .tmp/ and .env files in
git -C "$PROJECT" ls-files -z -co --exclude-standard | tar -C "$PROJECT" --null -T - -cf - | tar -C "$copy" -xf - || {
    printf 'ubuntu.sh: cannot copy the checkout\n' >&2
    exit 2
}

# ^ security podman runs under env -i with this list only => no host variable exists for a containers.conf env entry to forward
# ^ external rootless podman needs XDG_RUNTIME_DIR; XDG_DATA_HOME = the real image store (--pull=never), HOME and XDG_CONFIG_HOME = scratch
# ^ security CONTAINERS_CONF = a scratch file with hooks_dir = an empty directory => no system or user layer and no host OCI hook is read; containers.conf(5)
podman_home="$(mktemp -d -t gsg-ubuntu-podman-home.XXXXXX)" || exit 2
if [[ $podman_home == *[\"\\]* ]]; then
    printf 'ubuntu.sh: the scratch podman home path holds a quote or backslash; set TMPDIR to another directory\n' >&2
    exit 2
fi
# ^ security the scratch .config holds an empty mounts.conf => no RHEL /run/secrets mount; default_mounts_file has no effect for rootless
if ! mkdir -p -- "$podman_home/.config/containers" "$podman_home/hooks.d" \
    || ! : >"$podman_home/.config/containers/mounts.conf" \
    || ! printf '[engine]\nhooks_dir = ["%s"]\n' "$podman_home/hooks.d" >"$podman_home/containers.conf"; then
    printf 'ubuntu.sh: cannot prepare the scratch podman home\n' >&2
    exit 2
fi
PODMAN_ENV=(env -i HOME="$podman_home" PATH="$PATH" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}" XDG_CONFIG_HOME="$podman_home/.config" CONTAINERS_CONF="$podman_home/containers.conf" LANG=C.UTF-8)

# ^ security this process runs in the host's namespaces => its ids go to the container as arguments and it names any it shares (netns, ipcns = host)
host_ns=()
for ns in cgroup ipc net pid uts; do
    link="$(readlink "/proc/self/ns/$ns")" || link=""
    if [[ ! $link =~ ^$ns:\[([0-9]+)\]$ ]]; then
        printf 'ubuntu.sh: cannot read the %s namespace id of this process\n' "$ns" >&2
        exit 2
    fi
    host_ns+=(--host-ns "$ns=${BASH_REMATCH[1]}")
done

# ^ security no --env-host, no -e, no host HOME, ~/.gitconfig or ~/.ssh => the container sees the copy and nothing else of this machine
# ^ external podman forwards the host's http_proxy and friends unless --http-proxy=false
# ^ hazard dropping --init or timeout -k => time limit never fires; test:test_the_run_has_an_init_process_and_a_kill_after_so_the_outer_timeout_fires
cmd=(timeout --foreground -k 60 "$TOTAL_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" GSG_PLATFORM_SENTINEL="$SENTINEL"
    podman run --rm --init --name "$name" --pull=never --http-proxy=false
    -v "$copy:/src:ro,Z" "$IMAGE" bash /src/tests/platform/ubuntu-container.sh "${host_ns[@]}" --image "$IMAGE" "${passthru[@]}")

if [ "$dry" -eq 1 ]; then
    printf 'arg: %s\n' "${cmd[@]}"
    printf 'copy-files: %s\n' "$(find "$copy" -type f | wc -l)"
    find "$copy" -type f -printf 'copy-file: %P\n' | sort
    if [ -e "$copy/.git" ]; then printf 'copy-has-git: yes\n'; else printf 'copy-has-git: no\n'; fi
    printf 'podman-home-mounts-bytes: %s\n' "$(wc -c <"$podman_home/.config/containers/mounts.conf")"
    while IFS= read -r line; do printf 'podman-containers-conf: %s\n' "$line"; done <"$podman_home/containers.conf"
    printf 'podman-containers-conf-lines: %s\n' "$(wc -l <"$podman_home/containers.conf")"
    printf 'podman-hooks-dir-entries: %s\n' "$(find "$podman_home/hooks.d" -mindepth 1 | wc -l)"
    exit 0
fi

if ! "${PODMAN_ENV[@]}" podman image exists "$IMAGE"; then
    timeout "$PULL_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" podman pull "$IMAGE" || {
        printf 'ubuntu.sh: cannot pull %s\n' "$IMAGE" >&2
        exit 2
    }
fi

printf 'containers.conf layers ignored: CONTAINERS_CONF=%s (every system and user layer), OCI hooks_dir=%s (created empty by this script)\n' \
    "$podman_home/containers.conf" "$podman_home/hooks.d"
"${cmd[@]}"
rc=$?
if [ "$rc" -eq 0 ]; then
    printf 'UBUNTU PLATFORM TEST: PASS (image %s)\n' "$IMAGE"
else
    printf 'UBUNTU PLATFORM TEST: FAIL (container run exit %s, image %s)\n' "$rc" "$IMAGE"
fi
exit "$rc"
