#!/usr/bin/env bash
set -u
set -o pipefail

# ^ external both digests are the OCI index (manifest list) of the tag from the registry; lookup and bump steps in docs/platforms.md
ROCKY_IMAGE=docker.io/rockylinux/rockylinux:9.7@sha256:53f4c6dcb34e1403bd93207351f0af9a593610faeb7165cb8a037346765199b0
FEDORA_IMAGE=registry.fedoraproject.org/fedora:44@sha256:4688bc8003a1a6a7815e5f9d1f1b5c6bc9cafa582654af7cec61435d91655e3b
TOTAL_TIMEOUT_SECONDS=5400
PULL_TIMEOUT_SECONDS=600
CLEANUP_TIMEOUT_SECONDS=60
SENTINEL=host-environment-must-not-arrive
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
PROJECT="${HERE%/tests/platform}"

usage() {
    printf 'usage: tests/platform/rpm.sh rocky|fedora [--dry-run] [--timeout SECONDS] [--offline-restore] [container script options]\n'
    printf 'Runs the real git upgrade E2E (install --upgrade-git, takeover, restore) in a podman Rocky 9.7 or Fedora 44 container started from this Linux host.\n'
    printf 'Options it does not know go to rocky-container.sh or fedora-container.sh (--phase prepare|e2e|suite|upgrade on Rocky, --phase upgrade on Fedora;\n'
    printf 'also upgrade-root|password|bump|takeover|offline on Rocky and upgrade-old on Fedora, see docs/platforms.md#ci-on-real-platforms).\n'
    printf -- '--offline-restore (Rocky): stage 1 upgrades and takes over git, the container is committed, stage 2 restores it in a container with --network none.\n'
}

distro="${1:-}"
case "$distro" in
    rocky) image="$ROCKY_IMAGE" ;;
    fedora) image="$FEDORA_IMAGE" ;;
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
offline=0
passthru=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) dry=1 ;;
        --offline-restore) offline=1 ;;
        --timeout)
            shift
            if [[ ${1:-} != [1-9]* ]] || [[ $1 == *[!0-9]* ]]; then
                printf 'rpm.sh: --timeout needs a positive number of seconds\n' >&2
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
has_phase=0
for arg in "${passthru[@]}"; do
    if [ "$arg" = --phase ]; then has_phase=1; fi
done
if [ "$offline" -eq 1 ]; then
    if [ "$distro" != rocky ] || [ "$has_phase" -eq 1 ]; then
        printf 'rpm.sh: --offline-restore is for rocky only and chooses the phases itself (no --phase)\n' >&2
        exit 2
    fi
elif [ "$has_phase" -eq 0 ]; then
    passthru+=(--phase upgrade)
fi

copy="" podman_home="" name="gsg-$distro-$$" offline_tag="localhost/gsg-rpm-offline:$$"
PODMAN_ENV=()
# ^ order trap before mktemp; the private copy, the scratch podman HOME and a half-started container never outlive an interrupted run
# shellcheck disable=SC2329
cleanup() {
    if [ "$dry" -eq 0 ] && [ "${#PODMAN_ENV[@]}" -gt 0 ]; then
        timeout "$CLEANUP_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" podman rm -f "$name" "$name-offline" >/dev/null 2>&1
        if [ "$offline" -eq 1 ]; then timeout "$CLEANUP_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" podman rmi -f "$offline_tag" >/dev/null 2>&1; fi
    fi
    if [ -n "$copy" ] && [[ ${copy##*/} == gsg-rpm-src.* ]]; then rm -rf -- "$copy"; fi
    if [ -n "$podman_home" ] && [[ ${podman_home##*/} == gsg-rpm-podman-home.* ]]; then rm -rf -- "$podman_home"; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$dry" -eq 0 ] && ! type -P podman >/dev/null; then
    printf 'rpm.sh: podman is required and was not found on PATH\n' >&2
    exit 2
fi

# ^ security the container mounts a copy made now, not the live tree; the checkout and its .git history stay out of reach
copy="$(mktemp -d -t gsg-rpm-src.XXXXXX)" || exit 2
git -C "$PROJECT" ls-files -z -co --exclude-standard | tar -C "$PROJECT" --null -T - -cf - | tar -C "$copy" -xf - || {
    printf 'rpm.sh: cannot copy the checkout\n' >&2
    exit 2
}

# ^ security podman runs under env -i with this list only; no host variable exists for a containers.conf env entry to forward
# ^ security CONTAINERS_CONF is a scratch file with an empty hooks_dir, and the scratch .config holds an empty mounts.conf (no RHEL /run/secrets mount)
podman_home="$(mktemp -d -t gsg-rpm-podman-home.XXXXXX)" || exit 2
if [[ $podman_home == *[\"\\]* ]]; then
    printf 'rpm.sh: the scratch podman home path holds a quote or backslash; set TMPDIR to another directory\n' >&2
    exit 2
fi
if ! mkdir -p -- "$podman_home/.config/containers" "$podman_home/hooks.d" \
    || ! : >"$podman_home/.config/containers/mounts.conf" \
    || ! printf '[engine]\nhooks_dir = ["%s"]\n' "$podman_home/hooks.d" >"$podman_home/containers.conf"; then
    printf 'rpm.sh: cannot prepare the scratch podman home\n' >&2
    exit 2
fi
PODMAN_ENV=(env -i HOME="$podman_home" PATH="$PATH" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}" XDG_CONFIG_HOME="$podman_home/.config" CONTAINERS_CONF="$podman_home/containers.conf" LANG=C.UTF-8)

# ^ security this process runs in the host namespaces; its ids go to the container as arguments and it names any it shares
host_ns=()
for ns in cgroup ipc net pid uts; do
    link="$(readlink "/proc/self/ns/$ns")" || link=""
    if [[ ! $link =~ ^$ns:\[([0-9]+)\]$ ]]; then
        printf 'rpm.sh: cannot read the %s namespace id of this process\n' "$ns" >&2
        exit 2
    fi
    host_ns+=(--host-ns "$ns=${BASH_REMATCH[1]}")
done

# ^ security no --env-host, no -e, no host HOME, ~/.gitconfig or ~/.ssh; --http-proxy=false stops podman forwarding proxy variables
# ^ hazard dropping --init or timeout -k means the time limit never fires, as in ubuntu.sh
# ^ invariant make_cmd NAME IMAGE REMOVE NETWORK PHASE... sets cmd; REMOVE is rm or keep (keep leaves the container for podman commit), NETWORK is empty or none
make_cmd() {
    local cname="$1" cimage="$2" remove="$3" network="$4"
    shift 4
    cmd=(timeout --foreground -k 60 "$TOTAL_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" GSG_PLATFORM_SENTINEL="$SENTINEL" podman run)
    if [ "$remove" = rm ]; then cmd+=(--rm); fi
    cmd+=(--init --name "$cname" --pull=never --http-proxy=false)
    if [ -n "$network" ]; then cmd+=(--network "$network"); fi
    cmd+=(-v "$copy:/src:ro,Z" "$cimage" bash "/src/tests/platform/$distro-container.sh" "${host_ns[@]}" --image "$image" "$@")
}
cmd=() stage2=()
if [ "$offline" -eq 1 ]; then
    make_cmd "$name" "$image" keep "" "${passthru[@]}" --phase upgrade-takeover
    stage1=("${cmd[@]}")
    make_cmd "$name-offline" "$offline_tag" rm none "${passthru[@]}" --phase upgrade-offline
    stage2=("${cmd[@]}")
    cmd=("${stage1[@]}")
else
    make_cmd "$name" "$image" rm "" "${passthru[@]}"
fi

if [ "$dry" -eq 1 ] && [ "$offline" -eq 1 ]; then
    printf 'offline-stage-1-arg: %s\n' "${stage1[@]}"
    printf 'offline-stage-2-arg: %s\n' "${stage2[@]}"
    exit 0
fi
if [ "$dry" -eq 1 ]; then
    printf 'arg: %s\n' "${cmd[@]}"
    printf 'copy-files: %s\n' "$(find "$copy" -type f | wc -l)"
    if [ -e "$copy/.git" ]; then printf 'copy-has-git: yes\n'; else printf 'copy-has-git: no\n'; fi
    printf 'podman-home-mounts-bytes: %s\n' "$(wc -c <"$podman_home/.config/containers/mounts.conf")"
    while IFS= read -r line; do printf 'podman-containers-conf: %s\n' "$line"; done <"$podman_home/containers.conf"
    exit 0
fi

if ! "${PODMAN_ENV[@]}" podman image exists "$image"; then
    timeout "$PULL_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" podman pull "$image" || {
        printf 'rpm.sh: cannot pull %s\n' "$image" >&2
        exit 2
    }
fi

printf 'containers.conf layers ignored: CONTAINERS_CONF=%s (every system and user layer), OCI hooks_dir=%s (created empty by this script)\n' \
    "$podman_home/containers.conf" "$podman_home/hooks.d"
"${cmd[@]}"
rc=$?
# ^ order stage 2 starts only from the container stage 1 left behind; a failed stage 1 or a failed commit ends the run before it
# ^ why podman commit of the stopped container, not a volume; the takeover changes /usr/bin, /etc and /var/lib, where a volume holds nothing
if [ "$offline" -eq 1 ] && [ "$rc" -eq 0 ]; then
    printf 'rpm.sh: stage 1 done; committing the container as %s and starting stage 2 with --network none\n' "$offline_tag"
    if ! timeout "$CLEANUP_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" podman commit --quiet "$name" "$offline_tag" >/dev/null; then
        printf 'rpm.sh: cannot commit the container of stage 1\n' >&2
        exit 2
    fi
    timeout "$CLEANUP_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" podman rm -f "$name" >/dev/null
    "${stage2[@]}"
    rc=$?
fi
if [ "$rc" -eq 0 ]; then
    printf '%s PLATFORM TEST: PASS (image %s)\n' "${distro^^}" "$image"
else
    printf '%s PLATFORM TEST: FAIL (container run exit %s, image %s)\n' "${distro^^}" "$rc" "$image"
fi
exit "$rc"
