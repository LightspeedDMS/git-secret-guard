#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

MAC_SH="$GSG_PROJECT/tests/platform/mac-linux.sh"
ROCKY_SH="$GSG_PROJECT/tests/platform/rocky-container.sh"
UBUNTU_SH="$GSG_PROJECT/tests/platform/ubuntu.sh"
UBUNTU_CONTAINER_SH="$GSG_PROJECT/tests/platform/ubuntu-container.sh"
MAC_ARGS=()
MAC_SCRATCH_SCRIPT=""

# ^ invariant run_isolated CMD... = CMD under env -i with a scratch HOME and the suite's base PATH; RC, OUT and ERR as run_cap leaves them
run_isolated() {
    run_cap env -i HOME="$SANDBOX/home" PATH="$TEST_BASE_PATH" TMPDIR="$SANDBOX/tmp" "$@"
}

# ^ invariant MAC_SCRATCH_SCRIPT = mac-linux.sh inside a throwaway git work tree; the container copy of the project has no .git
mac_scratch() {
    local root="$SANDBOX/macproj"
    if [ -n "$MAC_SCRATCH_SCRIPT" ]; then return 0; fi
    mkdir -p -- "$root/tests/platform" "$SANDBOX/tmp" && cp -- "$MAC_SH" "$root/tests/platform/mac-linux.sh" && gitx -C "$root" init -q . || return 1
    MAC_SCRATCH_SCRIPT="$root/tests/platform/mac-linux.sh"
}

# ^ invariant MAC_ARGS = the podman command line of mac-linux.sh <distro> --dry-run, one element per "arg:" line; stale values are cleared first
mac_dry_run() {
    local line
    RC=""
    OUT=""
    MAC_ARGS=()
    mac_scratch || return 1
    run_isolated bash "$MAC_SCRATCH_SCRIPT" "$@" --dry-run
    while IFS= read -r line; do MAC_ARGS+=("${line#arg: }"); done < <(grep '^arg: ' <<<"$OUT")
}

mac_has_arg() {
    local a
    for a in "${MAC_ARGS[@]}"; do
        if [ "$a" = "$1" ]; then return 0; fi
    done
    return 1
}

test_the_mac_runner_mounts_a_read_only_copy_and_passes_no_environment() {
    local a i vols=0 mount=""
    mac_dry_run ubuntu || return 1
    assert_rc 0 "dry run"
    for ((i = 0; i < ${#MAC_ARGS[@]}; i++)); do
        case "${MAC_ARGS[$i]}" in
            -v)
                vols=$((vols + 1))
                mount="${MAC_ARGS[$((i + 1))]}"
                ;;
            --env-host | --env-host=* | -e | -e* | --env | --env=* | --env-file | --env-file=*) fail "environment is passed to the container: [${MAC_ARGS[$i]}]" ;;
        esac
    done
    for a in "${MAC_ARGS[@]}"; do
        case "$a" in
            *"$SANDBOX/home"* | *.gitconfig* | *.ssh* | "$GSG_PROJECT" | "$GSG_PROJECT":*) fail "a host path that must stay out of the container: [$a]" ;;
        esac
    done
    assert_eq "$vols" 1 "exactly one volume"
    assert_contains "$mount" "/gsg-mac-src." "a fresh copy made by the script"
    assert_eq "${mount##*:/src}" ":ro" "mounted read-only at /src"
    mac_has_arg --rm || fail "the container is not removed after the run"
    mac_has_arg --init || fail "no init process: the time limit would not fire"
    mac_has_arg --pull=never || fail "the run may not pull behind the script's back"
    mac_has_arg --http-proxy=false || fail "podman would forward the host's proxy variables without this"
}

test_the_mac_runner_bounds_the_run_and_names_the_container_script_per_distro() {
    local i podman_at distro
    for distro in ubuntu rocky; do
        podman_at=-1
        mac_dry_run "$distro" || return 1
        assert_rc 0 "dry run $distro"
        case "${MAC_ARGS[0]:-}" in */gtimeout | */timeout) ;; *) fail "$distro: the run is not under timeout: [${MAC_ARGS[0]:-}]" ;; esac
        for ((i = 0; i < ${#MAC_ARGS[@]}; i++)); do
            if [ "${MAC_ARGS[$i]}" = podman ]; then podman_at="$i"; fi
        done
        if [ "$podman_at" -lt 0 ]; then
            fail "$distro: podman is missing from the command"
            continue
        fi
        if [ "$podman_at" -eq 0 ]; then
            fail "$distro: nothing precedes podman, so no time limit does"
            continue
        fi
        [[ ${MAC_ARGS[$((podman_at - 1))]} =~ ^[1-9][0-9]*$ ]] || fail "$distro: no numeric time limit right before podman: [${MAC_ARGS[$((podman_at - 1))]}]"
        mac_has_arg "/src/tests/platform/$distro-container.sh" || fail "$distro: the container script is not on the command line"
    done
}

test_the_mac_runner_uses_the_pinned_images() {
    local ubuntu_pin rocky_pin
    ubuntu_pin="$(sed -n 's/^IMAGE=//p' "$UBUNTU_SH")" || { fail "cannot read the pin from ubuntu.sh"; return 1; }
    rocky_pin="$(sed -n 's/^ROCKY_IMAGE=//p' "$MAC_SH")" || { fail "cannot read the Rocky pin from mac-linux.sh"; return 1; }
    assert_contains "$ubuntu_pin" "docker.io/library/ubuntu:24.04@sha256:" "ubuntu.sh pins by digest"
    [[ $rocky_pin =~ ^docker\.io/rockylinux/rockylinux:9\.7@sha256:[0-9a-f]{64}$ ]] || fail "the Rocky reference is not 9.7 pinned by a sha256 digest: [$rocky_pin]"
    mac_dry_run ubuntu || return 1
    assert_rc 0 "dry run ubuntu"
    mac_has_arg "$ubuntu_pin" || fail "the Ubuntu image differs from the one pinned in ubuntu.sh"
    mac_dry_run rocky || return 1
    assert_rc 0 "dry run rocky"
    mac_has_arg "$rocky_pin" || fail "the Rocky image on the command line differs from the pin"
}

test_the_mac_runner_always_passes_a_visible_isolation_skip_reason() {
    local i reason=""
    mac_dry_run rocky || return 1
    assert_rc 0 "dry run"
    for ((i = 0; i < ${#MAC_ARGS[@]}; i++)); do
        if [ "${MAC_ARGS[$i]}" = --skip-isolation ]; then reason="${MAC_ARGS[$((i + 1))]}"; fi
    done
    assert_contains "$reason" "not verified" "the reason says the isolation was not verified"
    assert_contains "$reason" "macOS host" "the reason names the macOS host"
}

# ^ security the RHEL launcher is the trust-boundary run and may never skip the isolation check; only mac-linux.sh passes the flag
test_the_rhel_launcher_never_mentions_skip_isolation() {
    local rc=0
    grep -q -- '--skip-isolation' "$UBUNTU_SH" || rc=$?
    case "$rc" in
        0) fail "ubuntu.sh (the RHEL launcher) mentions --skip-isolation" ;;
        1) ;;
        *) fail "could not read ubuntu.sh (grep exit $rc)" ;;
    esac
}

test_the_mac_runner_refuses_an_unknown_distro() {
    mac_scratch || return 1
    run_isolated bash "$MAC_SCRATCH_SCRIPT" centos --dry-run
    assert_rc 2 "unknown distro"
    assert_contains "$ERR" "usage:" "usage is printed"
}

test_the_rocky_container_script_refuses_to_run_without_a_skip_reason() {
    run_isolated bash "$ROCKY_SH" --phase suite
    assert_rc 2 "no --skip-isolation"
    assert_contains "$ERR" "skip-isolation REASON" "usage names the required option"
}

test_the_container_script_rejects_a_skip_reason_with_a_backslash_or_a_short_one() {
    run_isolated bash "$UBUNTU_CONTAINER_SH" --skip-isolation 'a long enough reason \n with a backslash'
    assert_rc 2 "backslash"
    run_isolated bash "$UBUNTU_CONTAINER_SH" --skip-isolation 'short'
    assert_rc 2 "too short"
}

run_file_tests
