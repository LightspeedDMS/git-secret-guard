#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# ^ external the Rocky and Fedora podman launcher reads /proc and starts podman; it is Linux only
if [ "$TEST_OS" = Darwin ] || [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="the RPM podman launcher reads /proc and starts podman, Linux only"; fi

RPM_SH="$GSG_PROJECT/tests/platform/rpm.sh"
RPM_ARGS=()

# ^ invariant RPM_ARGS = the podman command line of rpm.sh DISTRO --dry-run, one element per "arg:" line; the script runs nothing in this mode
# ^ invariant the container copy has no .git; a throwaway repository holding a copy of the script stands in for the work tree
rpm_dry() {
    local script="$RPM_SH" root="$SANDBOX/rpmproj"
    if ! gitx -C "$GSG_PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        mkdir -p -- "$root/tests/platform" && cp -- "$RPM_SH" "$root/tests/platform/rpm.sh" && gitx -C "$root" init -q . || return 1
        script="$root/tests/platform/rpm.sh"
    fi
    mkdir -p -- "$SANDBOX/tmp" "$SANDBOX/home" || return 1
    run_cap env -i HOME="$SANDBOX/home" PATH="/usr/local/bin:/usr/bin:/bin" TMPDIR="$SANDBOX/tmp" bash "$script" "$@" --dry-run
    mapfile -t RPM_ARGS < <(sed -n 's/^arg: //p' <<<"$OUT")
}

rpm_has_arg() {
    local a
    for a in "${RPM_ARGS[@]}"; do
        if [ "$a" = "$1" ]; then return 0; fi
    done
    return 1
}

# ^ invariant prints every element of RPM_ARGS directly after FLAG, one per line
rpm_args_after() {
    local i
    for ((i = 1; i < ${#RPM_ARGS[@]}; i++)); do
        if [ "${RPM_ARGS[$((i - 1))]}" = "$1" ]; then printf '%s\n' "${RPM_ARGS[$i]}"; fi
    done
}

test_the_rpm_launcher_gives_the_container_no_host_environment_and_a_pinned_image_for_both_distributions() {
    local distro a mount image
    local -a vols=() images=()
    for distro in rocky fedora; do
        rpm_dry "$distro" || return 1
        assert_rc 0 "dry run [$distro]"
        for a in timeout --foreground -k env -i --init --pull=never --http-proxy=false GSG_PLATFORM_SENTINEL=host-environment-must-not-arrive "/src/tests/platform/$distro-container.sh"; do
            rpm_has_arg "$a" || fail "[$distro] the command line lacks [$a]"
        done
        for a in "${RPM_ARGS[@]}"; do
            case "$a" in
                # ^ external XDG_DATA_HOME stays the real one on purpose; it holds the image store read by --pull=never
                XDG_DATA_HOME=*) ;;
                --env-host | --env-host=* | -e | -e* | --env | --env=* | --env-file | --env-file=* | --env-merge | --env-merge=*) fail "[$distro] environment is passed to the container: [$a]" ;;
                *"$SANDBOX/home"* | *.gitconfig* | *.ssh* | "$GSG_PROJECT" | "$GSG_PROJECT":*) fail "[$distro] a host path that must stay out of the container: [$a]" ;;
            esac
        done
        mapfile -t vols < <(rpm_args_after -v)
        assert_eq "${#vols[@]}" 1 "[$distro] exactly one volume"
        mount="${vols[0]}"
        assert_eq "${mount#*:}" "/src:ro,Z" "[$distro] the copy is mounted read-only at /src (Z relabels only the private copy)"
        if [ "${mount%%:*}" = "$GSG_PROJECT" ]; then fail "[$distro] the live tree is mounted"; fi
        mapfile -t images < <(rpm_args_after --image)
        image="${images[0]:-}"
        assert_eq "${#images[@]}" 1 "[$distro] one --image"
        if [[ ! $image =~ @sha256:[0-9a-f]{64}$ ]]; then fail "[$distro] the image is not pinned by digest [$image]"; fi
        rpm_has_arg "$image" || fail "[$distro] the --image value is not the image that runs"
    done
}

test_the_rpm_launcher_passes_the_host_namespace_ids_and_the_default_phase_to_the_container_script() {
    local distro ns
    local -a ids=()
    for distro in rocky fedora; do
        rpm_dry "$distro" || return 1
        mapfile -t ids < <(rpm_args_after --host-ns)
        for ns in cgroup ipc net pid uts; do
            assert_contains " ${ids[*]} " " ${ns}=" "[$distro] --host-ns $ns=<id> is an argument"
        done
        assert_eq "${#ids[@]}" 5 "[$distro] five namespaces, no more"
        assert_eq "$(rpm_args_after --phase)" upgrade "[$distro] the default phase is upgrade"
    done
    rpm_dry rocky --phase e2e || return 1
    assert_eq "$(rpm_args_after --phase)" e2e "an explicit phase is passed on and no second one is added"
}

test_the_rpm_launcher_uses_a_scratch_podman_home_and_copies_no_git_directory() {
    local home_arg conf_arg
    rpm_dry rocky || return 1
    assert_contains "$OUT" "copy-has-git: no" "the copy has no .git"
    assert_contains "$OUT" "podman-home-mounts-bytes: 0" "the scratch mounts.conf is empty"
    home_arg="$(printf '%s\n' "${RPM_ARGS[@]}" | sed -n 's/^HOME=//p')"
    conf_arg="$(printf '%s\n' "${RPM_ARGS[@]}" | sed -n 's/^CONTAINERS_CONF=//p')"
    if [ -z "$home_arg" ] || [ "$home_arg" = "$SANDBOX/home" ]; then fail "podman does not run with a scratch HOME [$home_arg]"; fi
    assert_eq "$conf_arg" "$home_arg/containers.conf" "CONTAINERS_CONF is the scratch file"
    assert_eq "$(grep -c '^podman-containers-conf: ' <<<"$OUT")" 2 "containers.conf holds the [engine] header and one setting"
    assert_contains "$OUT" "podman-containers-conf: [engine]" "the engine section"
    assert_contains "$OUT" "podman-containers-conf: hooks_dir = [\"$home_arg/hooks.d\"]" "and the only setting is the empty hooks directory inside the scratch home"
}

test_the_rpm_launcher_rejects_an_unknown_distribution_and_a_bad_timeout() {
    run_cap env -i HOME="$SANDBOX/home" PATH="/usr/local/bin:/usr/bin:/bin" bash "$RPM_SH" ubuntu --dry-run
    assert_rc 2 "an unknown distribution"
    assert_contains "$ERR" "usage: tests/platform/rpm.sh rocky|fedora" "prints the usage"
    run_cap env -i HOME="$SANDBOX/home" PATH="/usr/local/bin:/usr/bin:/bin" bash "$RPM_SH" rocky --timeout abc --dry-run
    assert_rc 2 "a timeout that is not a number"
    assert_contains "$ERR" "--timeout needs a positive number of seconds" "says why"
}

test_a_dry_run_starts_no_podman_and_the_script_runs_by_its_path() {
    if ! gitx -C "$GSG_PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then skip_test "the checkout is not a git work tree"; fi
    mkdir -p -- "$SANDBOX/bin" "$SANDBOX/tmp" "$SANDBOX/home" || return 1
    printf '#!/bin/sh\necho called >>"%s/podman.log"\nexit 0\n' "$SANDBOX" >"$SANDBOX/bin/podman" && chmod 755 "$SANDBOX/bin/podman" || return 1
    run_cap env -i HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/local/bin:/usr/bin:/bin" TMPDIR="$SANDBOX/tmp" bash "$RPM_SH" rocky --dry-run
    assert_rc 0 "dry run with a recording podman first on PATH"
    assert_no_file "$SANDBOX/podman.log" "podman was never called"
    run_cap env -i HOME="$SANDBOX/home" PATH="/usr/local/bin:/usr/bin:/bin" "$RPM_SH" --help
    assert_rc 0 "executing tests/platform/rpm.sh directly (a mode without x gives 126)"
    assert_contains "$OUT" "usage: tests/platform/rpm.sh" "and it prints its usage"
}

run_file_tests
