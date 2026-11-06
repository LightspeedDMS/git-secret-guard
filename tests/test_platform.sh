#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# ^ external the Ubuntu podman launcher and its container scripts read /proc and run apt; they are Linux only and macOS and Windows have neither
if [ "$TEST_OS" = Darwin ] || [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="the Ubuntu podman launcher and container scripts read /proc and run apt, Linux only"; fi

UBUNTU_SH="$GSG_PROJECT/tests/platform/ubuntu.sh"
ARGS=()
DRY_ENV=()
DRY_SCRIPT=""

# ^ invariant DRY_SCRIPT = ubuntu.sh in a git work tree; the container copy has no .git => a throwaway repository with a copy of the script stands in
dry_script() {
    local root="$SANDBOX/dryproj"
    if gitx -C "$GSG_PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        DRY_SCRIPT="$UBUNTU_SH"
        return 0
    fi
    mkdir -p -- "$root/tests/platform" && cp -- "$UBUNTU_SH" "$root/tests/platform/ubuntu.sh" && gitx -C "$root" init -q . || return 1
    DRY_SCRIPT="$root/tests/platform/ubuntu.sh"
}

# ^ invariant ARGS = the podman command line of tests/platform/ubuntu.sh --dry-run, one element per "arg:" line; the script runs nothing in this mode
dry_run() {
    dry_script || return 1
    run_cap env -i HOME="$SANDBOX/home" PATH="/usr/local/bin:/usr/bin:/bin" TMPDIR="$SANDBOX/tmp" "${DRY_ENV[@]}" bash "$DRY_SCRIPT" --dry-run "$@"
    mapfile -t ARGS < <(sed -n 's/^arg: //p' <<<"$OUT")
}

has_arg() {
    local a
    for a in "${ARGS[@]}"; do
        if [ "$a" = "$1" ]; then return 0; fi
    done
    return 1
}

test_the_container_command_receives_no_host_environment_and_mounts_only_a_read_only_copy() {
    local a i vols=0 mount="" copy podman_at=0
    dry_run
    assert_rc 0 "dry run"
    if [ "${#ARGS[@]}" -le 8 ]; then
        fail "only ${#ARGS[@]} arguments were printed"
        return 1
    fi
    for ((i = 0; i < ${#ARGS[@]}; i++)); do
        if [ "${ARGS[$i]}" = podman ]; then
            podman_at="$i"
            break
        fi
    done
    for a in "${ARGS[@]:podman_at}"; do
        case "$a" in
            --env-host | --env-host=* | -e | -e* | --env | --env=* | --env-file | --env-file=* | --env-merge | --env-merge=*)
                fail "environment is passed to the container: [$a]"
                ;;
            *"$SANDBOX/home"* | *.gitconfig* | *.ssh* | "$GSG_PROJECT" | "$GSG_PROJECT":*)
                fail "a host path that must stay out of the container: [$a]"
                ;;
        esac
    done
    for ((i = 0; i < ${#ARGS[@]}; i++)); do
        case "${ARGS[$i]}" in
            -v | --volume | --mount)
                vols=$((vols + 1))
                mount="${ARGS[$((i + 1))]}"
                ;;
            -v* | --volume=* | --mount=*) fail "write the volume as a separate argument so it can be checked: [${ARGS[$i]}]" ;;
        esac
    done
    assert_eq "$vols" 1 "exactly one volume"
    copy="${mount%%:*}"
    assert_eq "${mount#"$copy":}" "/src:ro,Z" "mounted read-only at /src (Z relabels only the private copy for SELinux)"
    if [ "$copy" = "$GSG_PROJECT" ] || [ "${copy#"$GSG_PROJECT"/}" != "$copy" ]; then fail "the live tree is mounted: [$copy]"; fi
    assert_contains "$copy" "gsg-ubuntu-src." "a fresh copy made by the script"
    has_arg --rm || fail "the container is not removed after the run"
    has_arg --pull=never || fail "the run may not pull behind the script's back"
    has_arg --http-proxy=false || fail "podman would forward the host's proxy variables without this"
}

test_the_run_is_bounded_and_uses_the_named_image_and_the_container_script() {
    local i image_at=-1 env_at=-1
    dry_run
    assert_rc 0 "dry run"
    assert_eq "${ARGS[0]:-}" timeout "the whole run sits under timeout"
    for ((i = 0; i < ${#ARGS[@]}; i++)); do
        if [ "${ARGS[$i]}" = env ]; then
            env_at="$i"
            break
        fi
    done
    if [ "$env_at" -lt 2 ]; then
        fail "env is missing from the command"
        return 1
    fi
    [[ ${ARGS[$((env_at - 1))]} =~ ^[1-9][0-9]*$ ]] || fail "no numeric time limit right before env: [${ARGS[$((env_at - 1))]}]"
    for ((i = 0; i < ${#ARGS[@]}; i++)); do
        if [[ ${ARGS[$i]} == docker.io/library/ubuntu:24.04* ]] && [ "$image_at" -lt 0 ]; then image_at="$i"; fi
    done
    if [ "$image_at" -le 0 ]; then
        fail "the pinned image name is missing"
        return 1
    fi
    assert_eq "${ARGS[$((image_at + 1))]}" bash "the container runs bash"
    assert_eq "${ARGS[$((image_at + 2))]}" /src/tests/platform/ubuntu-container.sh "on the container script from the copy"
}

# ^ security the launcher runs in the host's namespaces => its ids go to the container as arguments (no environment) and it names any it shares
test_the_launcher_passes_its_own_namespace_ids_and_the_image_to_the_container_script() {
    local i script_at=-1 ns link id want="" got="" image=""
    dry_run --git source
    assert_rc 0 "dry run"
    for ((i = 0; i < ${#ARGS[@]}; i++)); do
        if [ "${ARGS[$i]}" = /src/tests/platform/ubuntu-container.sh ]; then script_at="$i"; fi
    done
    if [ "$script_at" -lt 0 ]; then
        fail "the container script is not on the command line"
        return 1
    fi
    for ns in cgroup ipc net pid uts; do
        link="$(readlink "/proc/self/ns/$ns")" || return 1
        id="${link##*[}"
        want+="$ns=${id%]} "
    done
    for ((i = script_at + 1; i < ${#ARGS[@]}; i++)); do
        case "${ARGS[$i]}" in
            --host-ns) got+="${ARGS[$((i + 1))]} " ;;
            --image) image="${ARGS[$((i + 1))]}" ;;
        esac
    done
    assert_eq "$got" "$want" "the launcher's own cgroup, ipc, net, pid and uts ids, in the order of the check"
    assert_contains "$image" "docker.io/library/ubuntu:24.04@sha256:" "the pinned image reference"
    assert_eq "${ARGS[$((${#ARGS[@]} - 2))]}" --git "the caller's options come last"
    assert_not_contains "$got" "time" "time, mnt and user are not compared"
}

test_the_launcher_stops_when_it_cannot_read_its_own_namespace_ids() {
    local bin="$SANDBOX/readlink-bin"
    dry_script || return 1
    mkdir -p -- "$bin" "$SANDBOX/tmp" || return 1
    printf '%s\n' '#!/bin/sh' 'exit 1' >"$bin/readlink" && chmod 755 "$bin/readlink" || return 1
    run_cap env -i HOME="$SANDBOX/home" PATH="$bin:/usr/local/bin:/usr/bin:/bin" TMPDIR="$SANDBOX/tmp" bash "$DRY_SCRIPT" --dry-run
    assert_rc 2 "no readable /proc/self/ns, no run"
    assert_contains "$ERR" "namespace" "says why"
    assert_empty "$(find "$SANDBOX/tmp" -maxdepth 1 -name 'gsg-ubuntu-*' 2>/dev/null)" "and leaves nothing behind"
}

test_the_image_is_pinned_by_manifest_list_digest() {
    local a images=0 prev="" podman_image="" passed_image=""
    dry_run
    assert_rc 0 "dry run"
    for a in "${ARGS[@]}"; do
        case "$a" in
            docker.io/library/ubuntu:24.04*)
                [[ $a =~ ^docker\.io/library/ubuntu:24\.04@sha256:[0-9a-f]{64}$ ]] || fail "the image is not pinned by digest: [$a]"
                if [ "$prev" = --image ]; then
                    passed_image="$a"
                else
                    images=$((images + 1))
                    podman_image="$a"
                fi
                ;;
        esac
        prev="$a"
    done
    assert_eq "$images" 1 "exactly one image argument for podman"
    assert_eq "$passed_image" "$podman_image" "and the reference shown in the summary is the one podman runs"
    run_cap bash "$UBUNTU_SH" --help
    assert_contains "$OUT" "ubuntu:24.04@sha256:" "the usage text names the pinned reference"
}

test_arguments_after_the_options_of_the_script_reach_the_container_script() {
    dry_run --git source
    assert_rc 0 "dry run"
    assert_eq "${ARGS[$((${#ARGS[@]} - 2))]:-}" --git "the last two arguments"
    assert_eq "${ARGS[$((${#ARGS[@]} - 1))]:-}" source "are passed on"
}

test_the_copy_holds_the_checkout_without_its_git_directory() {
    local want
    dry_run
    assert_rc 0 "dry run"
    want="$(gitx -C "${DRY_SCRIPT%/tests/platform/ubuntu.sh}" ls-files -co --exclude-standard | wc -l)"
    assert_contains "$OUT" "copy-files: $want" "every file of the checkout is in the copy"
    assert_contains "$OUT" "copy-has-git: no" "and the history is not"
}

test_the_copy_holds_only_tracked_and_untracked_files_that_are_not_ignored() {
    local proj="$SANDBOX/proj"
    mkdir -p -- "$proj/tests/platform" "$proj/ignored" "$proj/sub" "$proj/.tmp" || return 1
    cp -- "$UBUNTU_SH" "$proj/tests/platform/ubuntu.sh" || return 1
    printf 'ignored/\n.env\n.tmp/\n' >"$proj/.gitignore"
    printf 'k\n' >"$proj/keep.txt" && printf 'k\n' >"$proj/sub/ok.txt" && printf 'k\n' >"$proj/untracked.txt" || return 1
    printf 'k\n' >"$proj/ignored/planted.txt" && printf 'k\n' >"$proj/.env" && printf 'k\n' >"$proj/.tmp/scratch.txt" || return 1
    gitx -C "$proj" init -q . && gitx -C "$proj" add keep.txt || return 1
    run_cap env -i HOME="$SANDBOX/home" PATH="/usr/local/bin:/usr/bin:/bin" TMPDIR="$SANDBOX/tmp" bash "$proj/tests/platform/ubuntu.sh" --dry-run
    assert_rc 0 "dry run on the throwaway project"
    assert_contains "$OUT" "copy-file: keep.txt" "a tracked file"
    assert_contains "$OUT" "copy-file: sub/ok.txt" "a nested untracked file"
    assert_contains "$OUT" "copy-file: untracked.txt" "an untracked file that is not ignored"
    assert_contains "$OUT" "copy-file: .gitignore" "the ignore file itself"
    assert_not_contains "$OUT" "planted.txt" "a file in an ignored directory"
    assert_not_contains "$OUT" "copy-file: .env" "an ignored file at the top"
    assert_not_contains "$OUT" "scratch.txt" "an ignored .tmp directory"
    assert_not_contains "$OUT" "copy-file: .git/" "the history"
}

# ^ coupled /.gitignore with tests/platform/ubuntu.sh; an unlisted scratch or secret path => copied into the container
test_the_project_gitignore_keeps_scratch_and_secret_paths_out_of_the_container_copy() {
    local root="$GSG_PROJECT" p
    if ! gitx -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        root="$SANDBOX/ignoreproj"
        mkdir -p -- "$root" && cp -- "$GSG_PROJECT/.gitignore" "$root/.gitignore" && gitx -C "$root" init -q . || return 1
    fi
    assert_file "$GSG_PROJECT/.gitignore" "the project has an ignore file"
    for p in .tmp/scratch.txt .analysis/notes.md reports/troubleshooting/log.txt .env .env.local sub/.env.production; do
        run_cap gitx -C "$root" check-ignore -q -- "$p"
        assert_rc 0 "[$p] is ignored (taxonomy standard: .tmp/ .analysis/ reports/troubleshooting/, plus .env*), so the container copy does not hold it"
    done
    for p in .gitignore README.md lib/common.sh tests/platform/ubuntu.sh docs/scan.md tests/fixtures/husky/h \
        reports/bugs/x.md reports/reviews/x.md plans/designs/x.md; do
        run_cap gitx -C "$root" check-ignore -q -- "$p"
        assert_rc 1 "[$p] is a project file and stays in the copy (reports/bugs/ is the no-remote bug tracker and must stay committable)"
    done
}

# shellcheck disable=SC2016
test_the_cleanup_removal_of_the_container_runs_under_timeout() {
    local bin="$SANDBOX/podman-bin"
    dry_script || return 1
    mkdir -p -- "$bin" "$SANDBOX/tmp" || return 1
    printf '%s\n' '#!/bin/sh' 'read -r parent </proc/$PPID/comm' 'printf "%s parent=%s\n" "$1" "$parent" >>"${0%/*}/podman.log"' 'exit 0' >"$bin/podman" || return 1
    chmod 755 "$bin/podman"
    run_cap env -i HOME="$SANDBOX/home" PATH="$bin:/usr/local/bin:/usr/bin:/bin" TMPDIR="$SANDBOX/tmp" bash "$DRY_SCRIPT"
    assert_rc 0 "the stub container run"
    assert_contains "$(<"$bin/podman.log")" "rm parent=timeout" "a hung podman rm cannot keep the script from exiting"
}

# shellcheck disable=SC2016
test_the_container_summary_names_the_image_it_was_started_from() {
    local img=docker.io/library/ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
    run_cap env -i PATH="/usr/local/bin:/usr/bin:/bin" bash -c 'source "$1"; LOGDIR="$2"; IMAGE_REF="$3"; print_summary' _ "$GSG_PROJECT/tests/platform/ubuntu-container.sh" "$SANDBOX" "$img"
    assert_contains "$OUT" "image:     $img" "the summary names the image reference with its digest"
    run_cap env -i PATH="/usr/local/bin:/usr/bin:/bin" bash -c 'source "$1"; LOGDIR="$2"; print_summary' _ "$GSG_PROJECT/tests/platform/ubuntu-container.sh" "$SANDBOX"
    assert_contains "$OUT" "image:     not passed" "without --image it says so instead of guessing"
}

# ^ invariant stub_podman DIR RUN_RC = a podman stand-in in DIR; every subcommand exits 0 except run (exit RUN_RC)
stub_podman() {
    mkdir -p -- "$1" || return 1
    printf '%s\n' '#!/bin/sh' "if [ \"\$1\" = run ]; then exit $2; fi" 'exit 0' >"$1/podman" && chmod 755 "$1/podman"
}

test_the_launcher_final_line_names_the_image_and_the_config_isolation() {
    local img=docker.io/library/ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
    dry_script || return 1
    mkdir -p -- "$SANDBOX/tmp" || return 1
    stub_podman "$SANDBOX/podman-pass" 0 || return 1
    run_cap env -i HOME="$SANDBOX/home" PATH="$SANDBOX/podman-pass:/usr/local/bin:/usr/bin:/bin" TMPDIR="$SANDBOX/tmp" bash "$DRY_SCRIPT"
    assert_rc 0 "a passing run"
    assert_contains "$OUT" "containers.conf layers ignored" "the launcher says it made podman ignore the system and user containers.conf"
    assert_contains "$OUT" "UBUNTU PLATFORM TEST: PASS (image $img)" "the final line names the image digest"
    stub_podman "$SANDBOX/podman-fail" 7 || return 1
    run_cap env -i HOME="$SANDBOX/home" PATH="$SANDBOX/podman-fail:/usr/local/bin:/usr/bin:/bin" TMPDIR="$SANDBOX/tmp" bash "$DRY_SCRIPT"
    assert_rc 7 "a failing run keeps the exit status"
    assert_contains "$OUT" "UBUNTU PLATFORM TEST: FAIL (container run exit 7, image $img)" "and names the image too"
}

test_the_dry_run_leaves_no_copy_behind() {
    mkdir -p -- "$SANDBOX/tmp"
    dry_run
    assert_rc 0 "dry run"
    assert_empty "$(find "$SANDBOX/tmp" -maxdepth 1 -name 'gsg-ubuntu-src.*' 2>/dev/null)" "the temporary copy is removed"
}

# ^ security podman forwards host variables named in containers.conf env, also via CONTAINERS_CONF(_OVERRIDE) => podman must start with nothing to forward
test_podman_starts_under_env_i_with_a_fixed_allow_list() {
    local i a name env_at=-1 podman_at=-1 names=" " home_value=""
    local want=" HOME PATH XDG_RUNTIME_DIR XDG_DATA_HOME XDG_CONFIG_HOME CONTAINERS_CONF LANG GSG_PLATFORM_SENTINEL "
    DRY_ENV=(CONTAINERS_CONF_OVERRIDE="$SANDBOX/override.conf" CONTAINERS_CONF="$SANDBOX/c.conf" GSG_PROBE_MARKER=marker-value-must-not-travel
        XDG_RUNTIME_DIR="$SANDBOX/run" XDG_CONFIG_HOME="$SANDBOX/real-config-must-not-be-read" XDG_DATA_HOME="$SANDBOX/real-data")
    dry_run
    assert_rc 0 "dry run"
    assert_eq "${ARGS[0]:-}" timeout "the command starts with timeout"
    for ((i = 0; i < ${#ARGS[@]}; i++)); do
        if [ "${ARGS[$i]}" = env ] && [ "$env_at" -lt 0 ]; then env_at="$i"; fi
        if [ "${ARGS[$i]}" = podman ] && [ "$podman_at" -lt 0 ]; then podman_at="$i"; fi
    done
    if [ "$env_at" -lt 0 ] || [ "$podman_at" -le "$env_at" ]; then
        fail "podman does not run under env: env at $env_at, podman at $podman_at"
        return 1
    fi
    assert_eq "${ARGS[$((env_at + 1))]}" -i "env clears the whole environment"
    for ((i = env_at + 2; i < podman_at; i++)); do
        a="${ARGS[$i]}"
        name="${a%%=*}"
        if [ "$name" = "$a" ]; then fail "env -i argument without NAME=value: [$a]"; continue; fi
        if [[ $want != *" $name "* ]]; then fail "variable not on the allow-list: [$name]"; fi
        names+="$name "
        case "$name" in
            HOME)
                home_value="${a#*=}"
                assert_not_contains "$a" "$SANDBOX/home" "podman gets a scratch HOME, not the caller's"
                assert_contains "$a" "gsg-ubuntu-podman-home." "a fresh directory"
                ;;
            XDG_RUNTIME_DIR) assert_eq "${a#*=}" "$SANDBOX/run" "rootless podman needs the runtime dir" ;;
            XDG_CONFIG_HOME)
                assert_not_contains "$a" "real-config-must-not-be-read" "the caller's ~/.config/containers (containers.conf volumes, devices) is not read"
                assert_contains "$a" "gsg-ubuntu-podman-home." "a fresh directory"
                assert_eq "${a#*=}" "$home_value/.config" "the .config of the scratch HOME, which holds only the empty mounts.conf"
                ;;
            XDG_DATA_HOME) assert_eq "${a#*=}" "$SANDBOX/real-data" "the image store stays the real one (--pull=never uses the existing image)" ;;
            CONTAINERS_CONF)
                assert_eq "${a#*=}" "$home_value/containers.conf" "a file in the scratch HOME: podman then ignores every system and user containers.conf layer"
                assert_not_contains "$a" "$SANDBOX/c.conf" "the caller's CONTAINERS_CONF is not passed on"
                ;;
        esac
    done
    for name in $want; do
        if [[ $names != *" $name "* ]]; then fail "allow-listed variable missing: [$name]"; fi
    done
    for a in "${ARGS[@]}"; do
        case "$a" in
            *CONTAINERS_CONF_OVERRIDE* | *GSG_PROBE_MARKER* | *marker-value-must-not-travel*) fail "a caller variable reached the command: [$a]" ;;
        esac
    done
    assert_contains "$OUT" "podman-home-mounts-bytes: 0" "an empty user mounts.conf replaces the RHEL secrets default mount"
    assert_contains "$OUT" "podman-containers-conf: [engine]" "the containers.conf of the scratch HOME has an engine table"
    assert_contains "$OUT" "podman-containers-conf: hooks_dir = [\"$home_value/hooks.d\"]" "and names an OCI hooks directory of the scratch HOME only"
    assert_contains "$OUT" "podman-containers-conf-lines: 2" "and nothing else (no volumes, devices, env, namespaces)"
    assert_contains "$OUT" "podman-hooks-dir-entries: 0" "the hooks directory is empty: no OCI hook runs on the host for this container"
    DRY_ENV=()
}

# ^ security a quote or backslash in the scratch path breaks the hooks_dir TOML string => the launcher refuses and writes no file
test_a_scratch_home_path_that_would_break_the_containers_conf_toml_is_refused() {
    local odd="$SANDBOX/tmp-with\"quote"
    dry_script || return 1
    mkdir -p -- "$odd" || return 1
    run_cap env -i HOME="$SANDBOX/home" PATH="/usr/local/bin:/usr/bin:/bin" TMPDIR="$odd" bash "$DRY_SCRIPT" --dry-run
    assert_rc 2 "a TMPDIR with a double quote"
    assert_contains "$ERR" "quote or backslash" "says why"
    assert_empty "$(find "$odd" -mindepth 1 -maxdepth 1 2>/dev/null)" "and leaves no scratch directory behind"
}

# ^ invariant container_fn FN ARGS... sources tests/platform/ubuntu-container.sh in a clean bash (its main code is skipped when sourced) and calls FN
container_fn() {
    # shellcheck disable=SC2016
    run_cap env -i PATH="/usr/local/bin:/usr/bin:/bin" bash -c 'source "$1" && shift && "$@"' _ "$GSG_PROJECT/tests/platform/ubuntu-container.sh" "$@"
}

test_the_isolation_check_lists_stray_variable_names_and_never_a_value() {
    printf 'PATH=/usr/bin\0HOME=/root\0container=podman\0HOSTNAME=abc\0GSG_STRAY_NAME=value-that-must-not-print\0GSG_MULTI=first\nsecond-line-secret\0' \
        >"$SANDBOX/environ"
    container_fn isolation_stray_names "$SANDBOX/environ"
    assert_rc 1 "a name outside the allow-list fails the check"
    assert_eq "$OUT" $'GSG_STRAY_NAME\nGSG_MULTI' "the stray NAMES, one per line"
    no_leak "value-that-must-not-print"
    no_leak "second-line-secret"
}

test_the_isolation_check_fails_closed_when_the_environ_file_cannot_be_read() {
    local f
    : >"$SANDBOX/unreadable-environ" && chmod 000 "$SANDBOX/unreadable-environ" || return 1
    mkdir -p -- "$SANDBOX/environ-is-a-dir" || return 1
    for f in "$SANDBOX/unreadable-environ" "$SANDBOX/no-such-environ" "$SANDBOX/environ-is-a-dir"; do
        container_fn isolation_stray_names "$f"
        assert_rc 2 "[${f##*/}] is not an empty list of names"
        assert_contains "$ERR" "cannot read" "[${f##*/}] says why"
    done
    chmod 600 "$SANDBOX/unreadable-environ"
}

test_an_environ_entry_without_an_equals_sign_is_named_by_a_fixed_placeholder() {
    printf 'PATH=/x\0NOEQUALS-text-that-must-not-print\0HOME=/root\0' >"$SANDBOX/environ"
    container_fn isolation_stray_names "$SANDBOX/environ"
    assert_rc 1 "an entry without = is outside the allow-list"
    assert_eq "$OUT" '<entry without =>' "the fixed placeholder"
    no_leak "NOEQUALS-text-that-must-not-print"
    printf '=value-that-must-not-print\0' >"$SANDBOX/environ"
    container_fn isolation_stray_names "$SANDBOX/environ"
    assert_rc 1 "an empty name is outside the allow-list"
    assert_eq "$OUT" '<empty name>' "a blank line would vanish in a command substitution"
    no_leak "value-that-must-not-print"
}

# ^ invariant mountinfo_fixture FILE MP[=FSTYPE]... = one line per mount point (fstype ext4 by default); fake host paths in fields 4 and 10 => never printed
mountinfo_fixture() {
    local file="$1" entry mp fs n=100
    shift
    : >"$file" || return 1
    for entry in "$@"; do
        n=$((n + 1))
        mp="${entry%%=*}"
        fs=ext4
        if [[ $entry == *=* ]]; then fs="${entry#*=}"; fi
        printf '%s 1 0:%s /home/host-user/secret-root %s rw,relatime shared:%s - %s /home/host-user/secret-source-dir rw\n' "$n" "$n" "$mp" "$n" "$fs" >>"$file"
    done
}

# ^ external the 33 mount points and fstypes of an unmodified rootless podman 5 container under CONTAINERS_CONF
# ^ see doc:docs/platforms.md#what-the-platform-run-enforces
BASELINE_MOUNTS=(/=overlay /dev=tmpfs /dev/full=devtmpfs /dev/mqueue=mqueue /dev/null=devtmpfs /dev/pts=devpts /dev/random=devtmpfs /dev/shm=tmpfs /dev/tty=devtmpfs
    /dev/urandom=devtmpfs /dev/zero=devtmpfs /etc/hostname=tmpfs /etc/hosts=tmpfs /etc/resolv.conf=tmpfs /proc=proc /proc/acpi=tmpfs /proc/asound=proc /proc/bus=proc
    /proc/fs=proc /proc/interrupts=devtmpfs /proc/irq=proc /proc/kcore=devtmpfs /proc/keys=devtmpfs /proc/scsi=tmpfs /proc/sys=proc /proc/sysrq-trigger=proc
    /proc/timer_list=devtmpfs /run/.containerenv=tmpfs /run/podman-init=xfs /src=xfs /sys=sysfs /sys/firmware=tmpfs /sys/fs/cgroup=cgroup2 /sys/fs/selinux=tmpfs)

test_the_mount_check_lists_only_stray_mount_points_and_fails_closed_on_unreadable_input() {
    local f
    mountinfo_fixture "$SANDBOX/mi" "${BASELINE_MOUNTS[@]}" || return 1
    container_fn isolation_stray_mounts "$SANDBOX/mi"
    assert_rc 0 "the unmodified container baseline is accepted"
    assert_empty "$OUT" "nothing is named"
    mountinfo_fixture "$SANDBOX/mi" "${BASELINE_MOUNTS[@]}" /root/injected '/root/with\040space' /src/sub /srcx /etc /run/secrets /devices/x /home/someuser /dev/dri/card0 /procx || return 1
    container_fn isolation_stray_mounts "$SANDBOX/mi"
    assert_rc 1 "stray mount points fail the check"
    assert_eq "$OUT" $'/root/injected\n/root/with?040space\n/src/sub\n/srcx\n/etc\n/run/secrets\n/devices/x\n/home/someuser\n/dev/dri/card0\n/procx' \
        "only the stray mount points, sanitized, /dev/dri/card0 included"
    no_leak "secret-source-dir"
    no_leak "secret-root"
    no_leak "host-user"
    : >"$SANDBOX/unreadable-mi" && chmod 000 "$SANDBOX/unreadable-mi" || return 1
    mkdir -p -- "$SANDBOX/mi-is-a-dir" || return 1
    : >"$SANDBOX/empty-mi"
    mountinfo_fixture "$SANDBOX/no-root-mi" /proc /src || return 1
    for f in "$SANDBOX/unreadable-mi" "$SANDBOX/no-such-mi" "$SANDBOX/mi-is-a-dir" "$SANDBOX/empty-mi" "$SANDBOX/no-root-mi"; do
        container_fn isolation_stray_mounts "$f"
        assert_rc 2 "[${f##*/}] cannot be trusted as an empty list"
        assert_contains "$ERR" "mount" "[${f##*/}] says why"
    done
    chmod 600 "$SANDBOX/unreadable-mi"
}

# ^ invariant baseline_with MP=FSTYPE... = the baseline mount table where the given mount points carry another fstype; lines land in $SANDBOX/mi
baseline_with() {
    local -a table=()
    local entry over
    for entry in "${BASELINE_MOUNTS[@]}"; do
        for over in "$@"; do
            if [ "${over%%=*}" = "${entry%%=*}" ]; then entry="$over"; fi
        done
        table+=("$entry")
    done
    mountinfo_fixture "$SANDBOX/mi" "${table[@]}"
}

test_the_mount_check_names_a_replaced_mount_point_with_the_fstype_it_shows() {
    baseline_with /etc/hosts=xfs /etc/hostname=ext4 /etc/resolv.conf=btrfs /run/.containerenv=xfs /dev/shm=xfs /dev/mqueue=tmpfs /dev/pts=tmpfs || return 1
    container_fn isolation_stray_mounts "$SANDBOX/mi"
    assert_rc 1 "a podman mount replaced by a host path shows another fstype"
    assert_eq "$OUT" $'/dev/mqueue (fstype tmpfs)\n/dev/pts (fstype tmpfs)\n/dev/shm (fstype xfs)\n/etc/hostname (fstype ext4)\n/etc/hosts (fstype xfs)\n/etc/resolv.conf (fstype btrfs)\n/run/.containerenv (fstype xfs)' \
        "each named with the fstype it shows, in mount table order"
    baseline_with '/=fuse.fuse-overlayfs' /src=ext4 /run/podman-init=btrfs || return 1
    container_fn isolation_stray_mounts "$SANDBOX/mi"
    assert_rc 0 "the root, /src and /run/podman-init live on the host's filesystems: any fstype is fine there"
    # shellcheck disable=SC2016
    baseline_with '/dev/shm=xf$s;x' || return 1
    container_fn isolation_stray_mounts "$SANDBOX/mi"
    assert_eq "$OUT" '/dev/shm (fstype xf?s?x)' "an fstype is sanitized like a mount point"
    no_leak "secret-source-dir"
    no_leak "secret-root"
}

# ^ external podman 5.6.0 masks these files and the powercap directory on hosts having them (names in its binary); the files devtmpfs by analogy, not probed
# ^ external podman 4.9.3 on the ubuntu-24.04 hosted runner also masks /sys/dev/block (its config.json maskedPaths); fstype proven by CI
test_the_mount_check_accepts_the_optional_masked_paths_other_kernels_add() {
    local entry p fs
    for entry in /proc/latency_stats=devtmpfs /proc/sched_debug=devtmpfs /proc/timer_stats=devtmpfs /sys/devices/virtual/powercap=tmpfs /sys/dev/block=tmpfs; do
        p="${entry%%=*}"
        fs="${entry#*=}"
        mountinfo_fixture "$SANDBOX/mi" "${BASELINE_MOUNTS[@]}" "$p=$fs" || return 1
        container_fn isolation_stray_mounts "$SANDBOX/mi"
        assert_rc 0 "[$p] as $fs, the way podman masks it"
        mountinfo_fixture "$SANDBOX/mi" "${BASELINE_MOUNTS[@]}" "$p=xfs" || return 1
        container_fn isolation_stray_mounts "$SANDBOX/mi"
        assert_eq "$OUT" "$p (fstype xfs)" "[$p] with any other fstype is named"
    done
}

# ^ invariant ns_fixture DIR NAME=INODE... = a stand-in for /proc/1/ns with one symlink per namespace (net -> net:[4026532008])
ns_fixture() {
    local dir="$1" entry
    shift
    rm -rf -- "$dir" && mkdir -p -- "$dir" || return 1
    for entry in "$@"; do ln -s "${entry%%=*}:[${entry#*=}]" "$dir/${entry%%=*}" || return 1; done
}

test_the_namespace_check_names_each_namespace_shared_with_the_launcher_and_fails_closed() {
    local d="$SANDBOX/ns"
    local -a ids=(cgroup=4026531835 ipc=4026531839 net=4026532008 pid=4026531836 uts=4026531838)
    ns_fixture "$d" cgroup=4026532101 ipc=4026532102 net=4026532103 pid=4026532104 uts=4026532105 time=4026531834 mnt=4026532106 user=4026532107 || return 1
    container_fn isolation_shared_namespaces "$d" "${ids[@]}" time=4026531834 mnt=4026532106 user=4026532107
    assert_rc 0 "private namespaces; the launcher's time, mnt and user ids are never compared"
    assert_empty "$OUT" "nothing is named"
    ns_fixture "$d" cgroup=4026531835 ipc=4026532102 net=4026532008 pid=4026532104 uts=4026532105 || return 1
    container_fn isolation_shared_namespaces "$d" "${ids[@]}"
    assert_rc 1 "a container in the launcher's cgroup and net namespaces"
    assert_eq "$OUT" $'cgroup\nnet' "only the names, in the order of the check, never an inode number"
    no_leak "4026531835"
    no_leak "4026532008"
    ns_fixture "$d" cgroup=4026532101 ipc=4026531839 net=4026532103 pid=4026531836 uts=4026531838 || return 1
    container_fn isolation_shared_namespaces "$d" "${ids[@]}"
    assert_eq "$OUT" $'ipc\npid\nuts' "ipc, pid and uts"
    ns_fixture "$d" cgroup=4026532101 ipc=4026532102 net=4026532103 pid=4026532104 uts=4026532105 || return 1
    container_fn isolation_shared_namespaces "$d" cgroup=4026531835 ipc=4026531839 net=4026532008 pid=4026531836
    assert_rc 2 "no launcher id for uts"
    assert_contains "$ERR" "uts" "names the namespace it could not compare"
    container_fn isolation_shared_namespaces "$d" cgroup=4026531835 ipc=4026531839 net=abc pid=4026531836 uts=4026531838
    assert_rc 2 "a launcher id that is not a number"
    container_fn isolation_shared_namespaces "$d"
    assert_rc 2 "no launcher ids at all: the run was not started by ubuntu.sh"
    ns_fixture "$d" cgroup=4026532101 ipc=4026532102 net=4026532103 pid=4026532104 || return 1
    container_fn isolation_shared_namespaces "$d" "${ids[@]}"
    assert_rc 2 "the container's own uts link is missing"
    assert_contains "$ERR" "uts" "and says which"
    container_fn isolation_shared_namespaces "$SANDBOX/no-such-ns-dir" "${ids[@]}"
    assert_rc 2 "no namespace directory at all"
}

# ^ invariant parse_with ARGS... = parse_args of the container script in a clean bash; stdout is the parsed state "host ids|image|phases|count"
# shellcheck disable=SC2016
parse_with() {
    run_cap env -i PATH="/usr/local/bin:/usr/bin:/bin" bash -c \
        'source "$1"; shift; parse_args "$@"; printf "%s|%s|%s|%s" "${ISOLATION_HOST_NS[*]}" "${IMAGE_REF:-}" "${PHASES[*]}" "${#ISOLATION_HOST_NS[@]}"' \
        _ "$GSG_PROJECT/tests/platform/ubuntu-container.sh" "$@"
}

test_the_container_script_takes_the_launcher_namespace_ids_and_the_image_as_arguments() {
    local img=docker.io/library/ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852 bad
    parse_with --host-ns net=4026532008 --host-ns ipc=4026531839 --image "$img" --phase suite
    assert_rc 0 "valid arguments"
    assert_eq "$OUT" "net=4026532008 ipc=4026531839|$img|suite|2" "both ids, the image and the phase"
    # shellcheck disable=SC2016
    for bad in "--host-ns" "--host-ns net" "--host-ns net=" "--host-ns net=abc" "--host-ns time=5" "--host-ns mnt=5" "--host-ns user=5" "--host-ns =5" "--host-ns net=5=6" \
        "--image" "--image a;b" '--image $x' "--image a=b"; do
        # shellcheck disable=SC2086
        parse_with $bad
        assert_rc 2 "[$bad] is refused"
        assert_contains "$ERR" "usage" "[$bad] prints the usage"
    done
    parse_with --image "has space"
    assert_rc 2 "an image with a space"
}

test_the_mount_check_stops_reading_a_mount_table_that_is_far_too_long() {
    local -a many=()
    local i lines
    for ((i = 0; i < 570; i++)); do many+=("/root/m$i"); done
    mountinfo_fixture "$SANDBOX/mi" "${BASELINE_MOUNTS[@]}" "${many[@]}" || return 1
    container_fn isolation_stray_mounts "$SANDBOX/mi"
    assert_rc 1 "a table with 603 mounts"
    assert_contains "$OUT" "<more than 500 mount lines>" "says why it stopped"
    lines="$(wc -l <<<"$OUT")"
    if [ "$lines" -gt 501 ]; then fail "the check printed $lines lines for a table it should have stopped reading at 500"; fi
    no_leak "secret-source-dir"
    no_leak "secret-root"
}

test_the_mount_check_names_a_mount_point_that_is_mounted_twice() {
    mountinfo_fixture "$SANDBOX/mi" "${BASELINE_MOUNTS[@]}" /src=xfs /dev/shm=tmpfs /dev/null=devtmpfs || return 1
    container_fn isolation_stray_mounts "$SANDBOX/mi"
    assert_rc 1 "a second mount on top of /src, /dev/shm or /dev/null"
    assert_eq "$OUT" $'/src (mounted more than once)\n/dev/shm (mounted more than once)\n/dev/null (mounted more than once)' \
        "named once per extra mount, although the fstype is the expected one (V5: a host directory over the read-only copy)"
    no_leak "secret-source-dir"
    no_leak "secret-root"
}

# ^ external the 17 entries of /dev (depth <= 4) in an unmodified rootless podman 5 container; probed under CONTAINERS_CONF
# ^ see doc:docs/platforms.md#what-the-platform-run-enforces
dev_baseline() {
    local name
    local -a dirs=(mqueue pts shm)
    local -a files=(core fd full null ptmx random stderr stdin stdout tty urandom zero pts/ptmx)
    rm -rf -- "$1" && mkdir -p -- "$1" || return 1
    for name in "${dirs[@]}"; do mkdir -- "$1/$name" || return 1; done
    for name in "${files[@]}"; do : >"$1/$name" || return 1; done
}

test_the_device_check_lists_entries_of_dev_outside_the_baseline_and_fails_closed() {
    local d="$SANDBOX/dev"
    dev_baseline "$d" || return 1
    container_fn isolation_stray_devices "$d"
    assert_rc 0 "the 17 entries of an unmodified container /dev are accepted"
    assert_empty "$OUT" "nothing is named"
    : >"$d/pts/3" || return 1
    container_fn isolation_stray_devices "$d"
    assert_rc 0 "a pty the user allocated (pts/<digits>) is normal"
    : >"$d/fuse" && : >"$d/.hidden" && : >"$d/null zero" && mkdir -p -- "$d/dri" && : >"$d/dri/card0" && : >"$d/shm/host-ipc-object-name" && : >"$d/shm/second" \
        && : >"$d/mqueue/q" && : >"$d/pts/gsgfuse" && mkdir -p -- "$d/deep/a/b/c/d/e" || return 1
    container_fn isolation_stray_devices "$d"
    assert_rc 1 "devices added by containers.conf fail the check, below the top level too"
    assert_eq "$(LC_ALL=C sort <<<"$OUT")" $'.hidden\ndeep\ndeep/a\ndeep/a/b\ndeep/a/b/c\ndri\ndri/card0\nfuse\nmqueue/* (count 1)\nnull?zero\npts/* (count 1)\nshm/* (count 2)' \
        "paths a config named, sanitized (space is shown as ?), listing stops at depth 4; under shm, mqueue and pts only a count"
    assert_not_contains "$OUT" "host-ipc-object-name" "the names below a baseline directory can be host file names (a host /dev/shm) and are withheld"
    assert_not_contains "$OUT" "second" "all of them"
    container_fn isolation_stray_devices "$SANDBOX/no-such-dev"
    assert_rc 2 "a /dev that cannot be listed is not an empty list"
    assert_contains "$ERR" "cannot list" "and says so"
}

test_the_device_check_fails_closed_on_an_unreadable_subdirectory_and_stops_at_500_entries() {
    local d="$SANDBOX/dev3" i
    dev_baseline "$d" || return 1
    mkdir -p -- "$d/shm/locked" && chmod 000 "$d/shm/locked" || return 1
    container_fn isolation_stray_devices "$d"
    assert_rc 2 "a directory find cannot enter is not an empty list"
    assert_contains "$ERR" "cannot list" "and says so"
    chmod 755 "$d/shm/locked"
    for ((i = 0; i < 600; i++)); do : >"$d/shm/f$i" || return 1; done
    container_fn isolation_stray_devices "$d"
    assert_rc 1 "600 stray entries"
    assert_contains "$OUT" "<more than 500 /dev entries>" "stops reading and says so"
    if [ "$(wc -l <<<"$OUT")" -gt 1 ]; then fail "the stop notice is the only line, got $(wc -l <<<"$OUT")"; fi
}

# ^ invariant isolation_with ENVIRON MOUNTINFO DEVDIR LOGDIR [NSDIR [NAME=ID...]] = check_isolation on fixtures; the default namespaces are private
# shellcheck disable=SC2016
isolation_with() {
    local env="$1" mi="$2" dev="$3" logdir="$4" nsdir
    local -a ids=()
    if [ "$#" -ge 5 ]; then
        nsdir="$5"
        shift 5
        ids=("$@")
    else
        nsdir="$SANDBOX/ns-ok"
        ids=(cgroup=1 ipc=2 net=3 pid=4 uts=5)
        ns_fixture "$nsdir" cgroup=11 ipc=12 net=13 pid=14 uts=15 || return 1
    fi
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' >"$SANDBOX/osr-ubuntu" || return 1
    run_cap env -i PATH="/usr/local/bin:/usr/bin:/bin" bash -c \
        'source "$1"; OS_RELEASE="$7"; LOGDIR="$5"; ISOLATION_ENVIRON="$2"; ISOLATION_MOUNTINFO="$3"; ISOLATION_DEVDIR="$4"; ISOLATION_NSDIR="$6"; shift 7; ISOLATION_HOST_NS=("$@"); check_isolation' \
        _ "$GSG_PROJECT/tests/platform/ubuntu-container.sh" "$env" "$mi" "$dev" "$logdir" "$nsdir" "$SANDBOX/osr-ubuntu" "${ids[@]}"
}

test_check_isolation_reports_stray_mounts_and_devices_and_fails_closed_on_unreadable_sources() {
    local d="$SANDBOX/dev2"
    dev_baseline "$d" || return 1
    printf 'PATH=/usr/bin\0HOME=/root\0' >"$SANDBOX/env-ok"
    mountinfo_fixture "$SANDBOX/mi-ok" "${BASELINE_MOUNTS[@]}" || return 1
    isolation_with "$SANDBOX/env-ok" "$SANDBOX/mi-ok" "$d" "$SANDBOX"
    assert_rc 0 "control: a baseline container passes"
    assert_not_contains "$OUT" "FAIL" "control: and names no stray mount, device, namespace or variable"
    assert_contains "$OUT" "variable names" "the ok line names the variables"
    assert_contains "$OUT" "mount points and fstypes" "the mount points and their fstypes"
    assert_contains "$OUT" "/dev entries" "the device entries"
    assert_contains "$OUT" "namespaces" "the namespaces"
    assert_contains "$OUT" "containers.conf layers ignored" "and says the containers.conf layers are ignored"
    ns_fixture "$SANDBOX/ns-shared" cgroup=11 ipc=12 net=13 pid=14 uts=15 || return 1
    isolation_with "$SANDBOX/env-ok" "$SANDBOX/mi-ok" "$d" "$SANDBOX" "$SANDBOX/ns-shared" cgroup=1 ipc=2 net=13 pid=4 uts=5
    assert_rc 1 "a container in the launcher's network namespace"
    assert_contains "$OUT" "namespaces shared with the launcher" "is reported"
    assert_contains "$OUT" "net" "naming the namespace"
    assert_not_contains "$OUT" "13" "and no inode number"
    isolation_with "$SANDBOX/env-ok" "$SANDBOX/mi-ok" "$d" "$SANDBOX" "$SANDBOX/ns-shared"
    assert_rc 1 "launcher ids that never arrived"
    assert_contains "$OUT" "cannot compare the namespaces" "fail the check instead of skipping it"
    mountinfo_fixture "$SANDBOX/mi-bad" "${BASELINE_MOUNTS[@]}" /root/injected || return 1
    : >"$d/fuse" || return 1
    isolation_with "$SANDBOX/env-ok" "$SANDBOX/mi-bad" "$d" "$SANDBOX"
    assert_rc 1 "stray mounts and devices fail the check"
    assert_contains "$OUT" "/root/injected" "the stray mount point is named"
    assert_contains "$OUT" "fuse" "the stray device is named"
    assert_not_contains "$OUT" "secret-source-dir" "the host source path of the mount is not"
    isolation_with "$SANDBOX/no-such-env" "$SANDBOX/mi-ok" "$d" "$SANDBOX"
    assert_rc 1 "an unreadable variable list fails the check"
    assert_contains "$OUT" "cannot read the variable names" "and says so"
    isolation_with "$SANDBOX/env-ok" "$SANDBOX/no-such-mi" "$d" "$SANDBOX"
    assert_contains "$OUT" "cannot read the mount table" "an unreadable mount table fails the check"
    isolation_with "$SANDBOX/env-ok" "$SANDBOX/mi-ok" "$SANDBOX/no-such-dev" "$SANDBOX"
    assert_contains "$OUT" "cannot list the device directory" "an unlistable /dev fails the check"
}

test_a_variable_name_that_spells_two_allowed_names_is_still_stray() {
    printf 'PATH=/usr/bin\0PATH HOME=value-that-must-not-print\0HOME HOSTNAME=value-that-must-not-print\0' >"$SANDBOX/environ"
    container_fn isolation_stray_names "$SANDBOX/environ"
    assert_rc 1 "a name with a space is not on the allow-list"
    assert_eq "$OUT" $'PATH?HOME\nHOME?HOSTNAME' "both are named, the space shown as ?"
    no_leak "value-that-must-not-print"
}

test_the_isolation_check_accepts_exactly_the_container_defaults() {
    printf 'PATH=/usr/bin\0HOME=/root\0container=podman\0HOSTNAME=abc\0PWD=/\0SHLVL=1\0_=/usr/bin/env\0' >"$SANDBOX/environ"
    container_fn isolation_stray_names "$SANDBOX/environ"
    assert_rc 0 "only the defaults podman and bash set"
    assert_empty "$OUT" "nothing is named"
    printf 'PATH=/usr/bin\0http_proxy=x\0' >"$SANDBOX/environ"
    container_fn isolation_stray_names "$SANDBOX/environ"
    assert_rc 1 "a proxy variable is not on the list"
    assert_eq "$OUT" http_proxy "and is named"
}

# shellcheck disable=SC2016
test_obtain_git_does_not_build_from_source_when_the_ppa_could_not_be_disabled() {
    local script='source "$1"; LOGDIR="$2"; MARK="$2/source-build-ran"; GIT_SOURCE="$3"; PPA_RC="$4"
        install_git_source() { : >"$MARK"; return 0; }; git_is_new_enough() { return 0; }; install_git_ppa() { return "$PPA_RC"; }
        obtain_git; rc=$?; printf "rc=%s failures=%s\n" "$rc" "$FAILURES"'
    local mode
    for mode in auto ppa; do
        rm -f -- "$SANDBOX/source-build-ran"
        run_cap env -i PATH="/usr/local/bin:/usr/bin:/bin" bash -c "$script" _ "$GSG_PROJECT/tests/platform/ubuntu-container.sh" "$SANDBOX" "$mode" 2
        assert_contains "$OUT" "rc=1 failures=1" "[$mode] a PPA that may still be enabled stops the run with one counted failure"
        assert_contains "$OUT" "could not be disabled" "[$mode] and says why"
        assert_no_file "$SANDBOX/source-build-ran" "[$mode] no root apt install of build dependencies, no source build"
    done
    rm -f -- "$SANDBOX/source-build-ran"
    run_cap env -i PATH="/usr/local/bin:/usr/bin:/bin" bash -c "$script" _ "$GSG_PROJECT/tests/platform/ubuntu-container.sh" "$SANDBOX" auto 1
    assert_file "$SANDBOX/source-build-ran" "control: a PPA that failed and was removed cleanly falls back to the source build in auto mode"
}

test_the_container_script_reads_os_release_as_data() {
    # shellcheck disable=SC2016
    printf '%s\n' 'ID=$(touch '"$SANDBOX/executed"')' 'PRETTY_NAME="Ubuntu 24.04.2 LTS"' >"$SANDBOX/osr"
    # shellcheck disable=SC2016
    run_cap env -i PATH="/usr/local/bin:/usr/bin:/bin" bash -c 'source "$1"; OS_RELEASE="$2"; os_field ID; printf "|"; os_field PRETTY_NAME' _ \
        "$GSG_PROJECT/tests/platform/ubuntu-container.sh" "$SANDBOX/osr"
    assert_rc 0 "os_field"
    assert_eq "$OUT" "\$(touch $SANDBOX/executed)|Ubuntu 24.04.2 LTS" "literal text and an unquoted value"
    assert_no_file "$SANDBOX/executed" "the hostile line ran nothing"
    assert_eq "$(cat "$GSG_PROJECT"/tests/platform/*.sh | grep -c -E '^[^#]*(\.|source)[[:space:]]+/etc/os-release')" 0 "no platform script sources /etc/os-release"
}

test_the_isolation_check_counts_the_entries_of_run_secrets_and_never_names_them() {
    mkdir -p -- "$SANDBOX/secrets-dir" "$SANDBOX/empty-dir" || return 1
    : >"$SANDBOX/secrets-dir/entitlement-key-name.pem" && : >"$SANDBOX/secrets-dir/.hidden-cert-name" || return 1
    container_fn isolation_dir_entries "$SANDBOX/secrets-dir"
    assert_rc 0 "count"
    assert_eq "$OUT" 2 "two entries, hidden ones included"
    no_leak "entitlement-key-name"
    no_leak "hidden-cert-name"
    container_fn isolation_dir_entries "$SANDBOX/empty-dir"
    assert_eq "$OUT" 0 "an empty directory"
    container_fn isolation_dir_entries "$SANDBOX/no-such-dir"
    assert_eq "$OUT" 0 "a missing directory"
}

# shellcheck disable=SC2016
test_a_failed_isolation_check_aborts_before_any_phase_runs() {
    local script='source "$1"; LOGDIR="$2/log"; MARK="$2/phase-ran"; phase_prepare() { : >"$MARK"; }; print_summary() { :; }
        if [ "$3" = fail ]; then check_isolation() { record_fail "planted leak"; return 1; }; else check_isolation() { return 0; }; fi
        main --phase prepare'
    run_cap env -i PATH="/usr/local/bin:/usr/bin:/bin" bash -c "$script" _ "$GSG_PROJECT/tests/platform/ubuntu-container.sh" "$SANDBOX" fail
    assert_rc 1 "a failed isolation check ends the run"
    assert_no_file "$SANDBOX/phase-ran" "no phase (no apt, no network) ran after it"
    assert_contains "$OUT" "ABORT" "and the run says so"
    rm -f -- "$SANDBOX/phase-ran"
    run_cap env -i PATH="/usr/local/bin:/usr/bin:/bin" bash -c "$script" _ "$GSG_PROJECT/tests/platform/ubuntu-container.sh" "$SANDBOX" pass
    assert_rc 0 "control: a passing check runs the phases"
    assert_file "$SANDBOX/phase-ran" "the phase ran"
}

# ^ hazard PID 1 bash without a TERM trap drops the forwarded TERM => the outer timeout never ends the run; --init and timeout -k fix it
test_the_run_has_an_init_process_and_a_kill_after_so_the_outer_timeout_fires() {
    local i k_at=-1 env_at=-1 podman_at=-1 init_at=-1
    dry_run
    assert_rc 0 "dry run"
    for ((i = 0; i < ${#ARGS[@]}; i++)); do
        if [ "${ARGS[$i]}" = -k ] && [ "$k_at" -lt 0 ]; then k_at="$i"; fi
        if [ "${ARGS[$i]}" = env ] && [ "$env_at" -lt 0 ]; then env_at="$i"; fi
        if [ "${ARGS[$i]}" = podman ] && [ "$podman_at" -lt 0 ]; then podman_at="$i"; fi
        if [ "${ARGS[$i]}" = --init ] && [ "$init_at" -lt 0 ]; then init_at="$i"; fi
    done
    if [ "$env_at" -lt 0 ] || [ "$podman_at" -lt 0 ]; then
        fail "env or podman missing from the command (env at $env_at, podman at $podman_at)"
        return 1
    fi
    if [ "$k_at" -lt 1 ] || [ "$k_at" -ge "$env_at" ]; then
        fail "no timeout -k before env (k at $k_at, env at $env_at)"
    else
        [[ ${ARGS[$((k_at + 1))]} =~ ^[1-9][0-9]*$ ]] || fail "timeout -k needs a number of seconds: [${ARGS[$((k_at + 1))]}]"
    fi
    assert_eq "${ARGS[$((podman_at + 1))]}" run "podman is called with run"
    if [ "$init_at" -le "$podman_at" ]; then fail "podman run without --init: bash is PID 1 and ignores the forwarded TERM"; fi
}

# ^ invariant each --os names one image pinned by manifest-list digest and names the os-release to expect; podman gets exactly one image
test_the_launcher_selects_a_pinned_image_per_os_and_tells_the_container_what_to_expect() {
    local row os prefix expect a images expected_arg
    for row in "ubuntu-24.04|docker.io/library/ubuntu:24.04|ubuntu:24.04" "ubuntu-22.04|docker.io/library/ubuntu:22.04|ubuntu:22.04" "debian-13|docker.io/library/debian:13|debian:13"; do
        IFS='|' read -r os prefix expect <<<"$row"
        dry_run --os "$os"
        assert_rc 0 "[$os] dry run"
        images=0 expected_arg=""
        for ((a = 0; a < ${#ARGS[@]}; a++)); do
            case "${ARGS[$a]}" in
                "$prefix"@sha256:*)
                    [[ ${ARGS[$a]} =~ ^${prefix//./\.}@sha256:[0-9a-f]{64}$ ]] || fail "[$os] the image is not pinned by digest: [${ARGS[$a]}]"
                    if [ "${ARGS[$((a - 1))]}" != --image ]; then images=$((images + 1)); fi
                    ;;
                --expect-os) expected_arg="${ARGS[$((a + 1))]}" ;;
            esac
        done
        assert_eq "$images" 1 "[$os] exactly one image argument for podman"
        assert_eq "$expected_arg" "$expect" "[$os] the container is told which os-release to expect"
    done
    dry_run --os fedora-44
    assert_rc 2 "an image the launcher does not pin is refused"
}

# shellcheck disable=SC2016
test_the_container_script_takes_the_expected_os_and_names_it_in_its_title() {
    local bad
    run_cap env -i PATH="/usr/local/bin:/usr/bin:/bin" bash -c \
        'source "$1"; shift; parse_args "$@"; printf "%s|%s|%s" "$ISOLATION_OS_ID" "$ISOLATION_OS_VERSION" "$PLATFORM_TITLE"' _ "$GSG_PROJECT/tests/platform/ubuntu-container.sh" --expect-os debian:13
    assert_eq "$OUT" "debian|13|DEBIAN 13" "the isolation check will compare against Debian 13"
    for bad in "--expect-os" "--expect-os debian" "--expect-os debian:" "--expect-os :13" "--expect-os a;b:1"; do
        # shellcheck disable=SC2086
        parse_with $bad
        assert_rc 2 "[$bad] is refused"
    done
}

# shellcheck disable=SC2016
test_the_container_script_has_an_upgrade_phase_for_stock_git_machines() {
    run_cap env -i PATH="/usr/local/bin:/usr/bin:/bin" bash -c 'source "$1"; declare -F phase_upgrade apt_prepare_machine' _ "$GSG_PROJECT/tests/platform/ubuntu-container.sh"
    assert_rc 0 "the apt flavour of phase_upgrade exists next to the prepare, e2e and suite phases"
    assert_contains "$(<"$GSG_PROJECT/tests/platform/apt-upgrade-e2e.sh")" "install --upgrade-git" "and the E2E runs the real command"
}

test_the_container_script_calls_the_product_for_the_ppa_and_holds_no_copy_of_it() {
    local f="$GSG_PROJECT/tests/platform/ubuntu-container.sh"
    assert_contains "$(<"$f")" "gitup_apt_ppa_apply" "the PPA route is the product function"
    assert_eq "$(grep -cE 'ppa_key_matches|ppa_disable|PPA_PINNED_FPR|add-apt-repository -y -n|git-core-ubuntu-ppa' "$f")" 0 "no key check, no disable and no pinned fingerprint of its own"
}

test_the_entry_script_runs_by_the_path_the_readme_documents() {
    run_cap env -i HOME="$SANDBOX/home" PATH="/usr/local/bin:/usr/bin:/bin" "$UBUNTU_SH" --help
    assert_rc 0 "executing tests/platform/ubuntu.sh directly (a mode without x gives 126)"
    assert_contains "$OUT" "usage: tests/platform/ubuntu.sh" "and it prints its usage"
}

run_file_tests
