#!/usr/bin/env bash
set -u
set -o pipefail

IMAGE=docker.io/library/ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
name="gsg-autoupdate-probe-$$"
podman_home="$(mktemp -d -t gsg-autoupdate-podman-home.XXXXXX)" || exit 2
cleanup() {
    timeout 60 env -i HOME="$podman_home" PATH="$PATH" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
        XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}" XDG_CONFIG_HOME="$podman_home/.config" \
        CONTAINERS_CONF="$podman_home/containers.conf" podman rm -f "$name" >/dev/null 2>&1 || :
    rm -rf -- "$podman_home"
}
trap cleanup EXIT
mkdir -p -- "$podman_home/.config/containers" "$podman_home/hooks.d" || exit 2
: >"$podman_home/.config/containers/mounts.conf" || exit 2
printf '[engine]\nhooks_dir = ["%s"]\n' "$podman_home/hooks.d" >"$podman_home/containers.conf" || exit 2
PODMAN_ENV=(env -i HOME="$podman_home" PATH="$PATH" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}" XDG_CONFIG_HOME="$podman_home/.config" CONTAINERS_CONF="$podman_home/containers.conf" LANG=C.UTF-8)
if ! type -P podman >/dev/null; then printf 'FAIL podman is required\n' >&2; exit 2; fi
if ! "${PODMAN_ENV[@]}" podman image exists "$IMAGE"; then timeout 600 "${PODMAN_ENV[@]}" podman pull "$IMAGE" || exit 2; fi
# shellcheck disable=SC2016
"${PODMAN_ENV[@]}" podman run --rm --init --name "$name" --pull=never --http-proxy=false "$IMAGE" bash -euc '
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq software-properties-common
    add-apt-repository -y ppa:git-core/ppa
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git
    git --version | grep -E "git version 2\.(5[4-9]|[6-9][0-9])" >/dev/null
    useradd -m owner
    useradd -m follower
    mkdir -p /srv/owned
    git -C /srv/owned init -q
    git -C /srv/owned -c user.name=Owner -c user.email=owner@example.invalid commit --allow-empty -qm initial
    chown -R owner:owner /srv/owned
    set +e
    plain=$(runuser -u follower -- env -i PATH=/usr/bin:/bin HOME=/home/follower /usr/bin/git -C /srv/owned rev-parse HEAD 2>&1)
    plain_rc=$?
    set -e
    printf "without safe.directory rc=%s\n%s\n" "$plain_rc" "$plain"
    test "$plain_rc" -ne 0
    printf "%s" "$plain" | grep -F "dubious ownership" >/dev/null
    safe=$(runuser -u follower -- env -i PATH=/usr/bin:/bin HOME=/home/follower /usr/bin/git -c safe.directory=/srv/owned -C /srv/owned rev-parse HEAD)
    printf "with exact safe.directory: %s\n" "$safe"
    test "${#safe}" -eq 40
' || exit $?
