#!/usr/bin/env bash
set -u
set -o pipefail

# ^ external digest is the pinned Ubuntu 24.04 manifest list used by ubuntu.sh
IMAGE=docker.io/library/ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
# ^ external Ubuntu 24.04 ships git 2.43; the real install needs git >= 2.54 (ppa:git-core/ppa), curl and jq, the update lock needs ps (procps)
IMAGE_RECIPE='apt-get update && apt-get install -y --no-install-recommends systemd dbus-user-session bash ca-certificates util-linux curl jq procps xz-utils gnupg software-properties-common && add-apt-repository -y ppa:git-core/ppa && apt-get update && apt-get install -y --no-install-recommends git && apt-get clean && rm -rf /var/lib/apt/lists/*'
# ^ coupled tests/platform/autoupdate-e2e.sh:E2E_DEADLINE stays below this; the steps wait 5 minutes (OnBootSec) for the timer's first run
TOTAL_TIMEOUT_SECONDS=2400
PULL_TIMEOUT_SECONDS=600
CLEANUP_TIMEOUT_SECONDS=60
SENTINEL=host-environment-must-not-arrive
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
PROJECT="${HERE%/tests/platform}"
copy="" podman_home="" name="gsg-autoupdate-$$"
PODMAN_ENV=()

# ^ hazard trap precedes temporary resources => interrupted runs remove the container and scratch trees
# shellcheck disable=SC2329
cleanup() {
    if [ "${#PODMAN_ENV[@]}" -gt 0 ]; then timeout "$CLEANUP_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" podman rm -f "$name" >/dev/null 2>&1; fi
    if [ -n "$copy" ] && [[ ${copy##*/} == gsg-autoupdate-src.* ]]; then rm -rf -- "$copy"; fi
    if [ -n "$podman_home" ] && [[ ${podman_home##*/} == gsg-autoupdate-home.* ]]; then rm -rf -- "$podman_home"; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! type -P podman >/dev/null; then printf 'autoupdate.sh: podman is required\n' >&2; exit 2; fi
copy="$(mktemp -d -t gsg-autoupdate-src.XXXXXX)" || exit 2
git -C "$PROJECT" ls-files -z -co --exclude-standard | tar -C "$PROJECT" --null -T - -cf - | tar -C "$copy" -xf - || {
    printf 'autoupdate.sh: cannot copy checkout\n' >&2; exit 2;
}
podman_home="$(mktemp -d -t gsg-autoupdate-home.XXXXXX)" || exit 2
case "$podman_home" in *'"'*) printf 'autoupdate.sh: unsafe scratch path; set TMPDIR elsewhere\n' >&2; exit 2 ;; esac
if ! mkdir -p "$podman_home/.config/containers" "$podman_home/hooks.d" "$podman_home/build" \
    || ! : >"$podman_home/.config/containers/mounts.conf" \
    || ! printf '[engine]\nhooks_dir = ["%s"]\n' "$podman_home/hooks.d" >"$podman_home/containers.conf" \
    || ! printf 'FROM %s\nENV DEBIAN_FRONTEND=noninteractive\nRUN %s\n' "$IMAGE" "$IMAGE_RECIPE" >"$podman_home/build/Containerfile"; then
    printf 'autoupdate.sh: cannot prepare isolated podman configuration/image recipe\n' >&2; exit 2
fi
PODMAN_RUNTIME_DIR="/run/user/$(id -u)"
PODMAN_ENV=(env -i HOME="$podman_home" PATH="$PATH" XDG_RUNTIME_DIR="$PODMAN_RUNTIME_DIR" \
    XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}" XDG_CONFIG_HOME="$podman_home/.config" CONTAINERS_CONF="$podman_home/containers.conf" LANG=C.UTF-8)
if ! "${PODMAN_ENV[@]}" podman image exists "$IMAGE"; then
    timeout "$PULL_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" podman pull "$IMAGE" || { printf 'autoupdate.sh: image pull failed\n' >&2; exit 2; }
fi
build_start=$SECONDS
if ! timeout "$PULL_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" podman build --pull=never -t gsg-autoupdate-systemd:local -f "$podman_home/build/Containerfile" "$podman_home/build"; then
    printf 'autoupdate.sh: systemd image build failed\n' >&2; exit 2
fi
printf 'IMAGE BUILD: %ss\n' "$((SECONDS - build_start))"
run_start=$SECONDS
timeout "$PULL_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" GSG_PLATFORM_SENTINEL="$SENTINEL" \
    podman run -d --systemd=always --name "$name" --pull=never --http-proxy=false -v "$copy:/src:ro,Z" \
    gsg-autoupdate-systemd:local /sbin/init >/dev/null
rc=$?
if [ "$rc" -eq 0 ]; then
    ready=0
    for ((attempt = 0; attempt < 60; attempt++)); do
        if "${PODMAN_ENV[@]}" podman exec "$name" systemctl is-system-running >/dev/null 2>&1; then ready=1; break; fi
        sleep 1
    done
    if [ "$ready" -eq 1 ]; then
        # ^ hazard bash runs a trap only after its foreground child returns => the steps run as a job under wait, a TERM removes the container at once
        timeout --foreground -k 30 "$TOTAL_TIMEOUT_SECONDS" "${PODMAN_ENV[@]}" podman exec -e GSG_PLATFORM_SENTINEL="$SENTINEL" "$name" bash /src/tests/platform/autoupdate-e2e.sh &
        wait "$!"
        rc=$?
    else
        printf 'autoupdate.sh: systemd did not reach running state within 60 seconds\n' >&2
        rc=124
    fi
fi
printf 'CONTAINER RUN: %ss\n' "$((SECONDS - run_start))"
if [ "$rc" -eq 0 ]; then printf 'AUTOUPDATE PLATFORM TEST: PASS (base image %s)\n' "$IMAGE"; else printf 'AUTOUPDATE PLATFORM TEST: FAIL (exit %s)\n' "$rc"; fi
exit "$rc"
