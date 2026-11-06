#!/usr/bin/env bash
set -u
set -o pipefail

GIT_SOURCE=auto
GIT_MIN_MAJOR=2
GIT_MIN_MINOR=54
# ^ coupled the git pin has one copy, the git source row of tools.lock
GIT_BUILD_LOCK="$(dirname -- "${BASH_SOURCE[0]}")/../../tools.lock"
GIT_BUILD_VERSION="$(awk '$1 == "git" && $3 == "source" { print $2 }' "$GIT_BUILD_LOCK")"
GIT_BUILD_SHA256="$(awk '$1 == "git" && $3 == "source" { print $4 }' "$GIT_BUILD_LOCK")"
if [ -z "$GIT_BUILD_VERSION" ] || [ -z "$GIT_BUILD_SHA256" ]; then
    printf 'ubuntu-container.sh: no git source row in %s\n' "$GIT_BUILD_LOCK" >&2
    exit 2
fi
GIT_BUILD_URL="https://www.kernel.org/pub/software/scm/git/git-$GIT_BUILD_VERSION.tar.xz"
GIT_BUILD_FLAGS=(NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1)
SHELLCHECK_VERSION=0.11.0
SHELLCHECK_SHA256_X86_64=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
SHELLCHECK_SHA256_AARCH64=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
APT_TIMEOUT=900
DOWNLOAD_TIMEOUT=300
BUILD_TIMEOUT=2400
E2E_TIMEOUT=900
SUITE_TIMEOUT=3300
TEST_USER=gsguser
USER_HOME=/home/$TEST_USER
CHECKOUT=$USER_HOME/checkout
LOGDIR=/var/log/gsg-platform
PHASES=()
SUITE_FILES=()
FAILURES=0
STEP_SOFT=0
GIT_SOURCE_DESC=""
IMAGE_REF=""
GIT_BIN=""
SUITE_SUMMARY=""
E2E_SUMMARY=""
OS_RELEASE=/etc/os-release
ISOLATION_SKIP_REASON=""
PLATFORM_TITLE="UBUNTU 24.04"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
GSG_ROOT="$(cd -- "$HERE/../.." && pwd -P)" || exit 2
# ^ coupled the PPA route is the product module lib/gitup_apt.sh, loaded in the order the CLI loads its libraries; no second copy of it lives here
for lib in brew common state tools install gitup gitup_source gitup_apt; do
    # shellcheck source=/dev/null
    source "$GSG_ROOT/lib/$lib.sh" || exit 2
done
# shellcheck source=tests/platform/apt-phase.sh
source "$HERE/apt-phase.sh" || exit 2

# ^ security /etc/os-release is read as data by the installer's reader, never sourced; test:test_the_container_script_reads_os_release_as_data
os_field() {
    install_os_release_field "$OS_RELEASE" "$1"
    printf '%s' "$REPLY"
}

usage() {
    printf 'usage: ubuntu-container.sh [--git ppa|source|auto] [--phase prepare|e2e|suite|upgrade]... [--suite-file test_x.sh]... [--host-ns NAME=ID]... [--image REF] [--expect-os ID:VERSION]\n'
    printf 'Runs as root inside ubuntu:24.04, or the image --expect-os names (ubuntu:22.04, debian:13). Default phases: prepare e2e suite; upgrade is the real install --upgrade-git\n'
    printf 'E2E on a stock git and replaces them. Started by tests/platform/ubuntu.sh, which passes --host-ns (the ids of its own\n'
    printf 'cgroup, ipc, net, pid and uts namespaces; the isolation check fails without them) and --image (the pinned reference, shown in the summary).\n'
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --git)
                shift
                case "${1:-}" in ppa | source | auto) GIT_SOURCE="$1" ;; *) usage >&2; exit 2 ;; esac
                ;;
            --phase)
                shift
                case "${1:-}" in prepare | e2e | suite | upgrade | upgrade-root | upgrade-password | upgrade-bump | upgrade-old | upgrade-takeover | upgrade-offline) PHASES+=("$1") ;; *) usage >&2; exit 2 ;; esac
                ;;
            --suite-file)
                shift
                [[ ${1:-} =~ ^test_[a-z0-9_]+\.sh$ ]] || { usage >&2; exit 2; }
                SUITE_FILES+=("tests/$1")
                ;;
            --host-ns)
                shift
                [[ ${1:-} =~ ^(cgroup|ipc|net|pid|uts)=[0-9]+$ ]] || { usage >&2; exit 2; }
                ISOLATION_HOST_NS+=("$1")
                ;;
            --image)
                shift
                [[ ${1:-} =~ ^[A-Za-z0-9._/:@-]+$ ]] || { usage >&2; exit 2; }
                IMAGE_REF="$1"
                ;;
            --expect-os)
                shift
                [[ ${1:-} =~ ^([a-z]+):([0-9][0-9.]*)$ ]] || { usage >&2; exit 2; }
                ISOLATION_OS_ID="${BASH_REMATCH[1]}" ISOLATION_OS_VERSION="${BASH_REMATCH[2]}"
                PLATFORM_TITLE="${ISOLATION_OS_ID^^} $ISOLATION_OS_VERSION"
                ;;
            --skip-isolation)
                shift
                local skip_re='^[A-Za-z0-9._ ,:;/()-]{10,200}$'
                [[ ${1:-} =~ $skip_re ]] || { usage >&2; exit 2; }
                ISOLATION_SKIP_REASON="$1"
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) usage >&2; exit 2 ;;
        esac
        shift
    done
    if [ "${#PHASES[@]}" -eq 0 ]; then PHASES=(prepare e2e suite); fi
}

record_fail() {
    FAILURES=$((FAILURES + 1))
    printf 'FAIL    %s\n' "$1"
}

# ^ invariant step runs one external command under timeout and logs to $LOGDIR; a failure is counted (unless STEP_SOFT=1) and its last lines are shown
step() {
    local name="$1" secs="$2" log rc
    shift 2
    log="$LOGDIR/${name//[^A-Za-z0-9]/_}.log"
    printf '== %s\n' "$name"
    timeout "$secs" "$@" >"$log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'ok      %s\n' "$name"
        return 0
    fi
    tail -n 25 "$log" | sed 's/^/        | /'
    if [ "$STEP_SOFT" -eq 1 ]; then
        printf 'failed  %s (exit %s, not counted: the next source is tried)\n' "$name" "$rc"
    else
        record_fail "$name (exit $rc)"
    fi
    return 1
}

ISOLATION_ALLOWED_VARS=" PATH HOME HOSTNAME container PWD SHLVL _ OLDPWD "

# ^ security prints variable NAMES only, sanitized; the value part of an entry is dropped unread and never reaches any output
# ^ invariant rc 1 when any name is not in ISOLATION_ALLOWED_VARS, 0 otherwise, 2 (nothing printed on stdout) when the list cannot be read
# ^ security an entry without = or with an empty name prints a fixed placeholder => its text, possibly a value, never reaches the output
isolation_stray_names() {
    local kv name stray=0
    if [ ! -r "$1" ] || [ -d "$1" ]; then
        printf 'isolation_stray_names: cannot read %s\n' "${1//[^A-Za-z0-9_\/.-]/?}" >&2
        return 2
    fi
    while IFS= read -r -d '' kv || [ -n "$kv" ]; do
        if [[ $kv != *=* ]]; then
            printf '<entry without =>\n'
            stray=1
            continue
        fi
        name="${kv%%=*}"
        if [ -z "$name" ]; then
            printf '<empty name>\n'
            stray=1
            continue
        fi
        if [[ $name != *[!A-Za-z0-9_]* && $ISOLATION_ALLOWED_VARS == *" $name "* ]]; then continue; fi
        printf '%s\n' "${name//[^A-Za-z0-9_]/?}"
        stray=1
    done <"$1"
    [ "$stray" -eq 0 ]
}

# ^ external an unmodified rootless podman 5 container under CONTAINERS_CONF has exactly these MOUNTPOINT=FSTYPE entries
# ^ see doc:docs/platforms.md#what-the-platform-run-enforces
ISOLATION_MOUNT_RULES=" /=* /dev=tmpfs /dev/full=devtmpfs /dev/mqueue=mqueue /dev/null=devtmpfs /dev/pts=devpts /dev/random=devtmpfs /dev/shm=tmpfs /dev/tty=devtmpfs"
ISOLATION_MOUNT_RULES+=" /dev/urandom=devtmpfs /dev/zero=devtmpfs /etc/hostname=tmpfs /etc/hosts=tmpfs /etc/resolv.conf=tmpfs /proc=proc /proc/acpi=tmpfs"
ISOLATION_MOUNT_RULES+=" /proc/asound=proc /proc/bus=proc /proc/fs=proc /proc/interrupts=devtmpfs /proc/irq=proc /proc/kcore=devtmpfs /proc/keys=devtmpfs"
ISOLATION_MOUNT_RULES+=" /proc/scsi=tmpfs /proc/sys=proc /proc/sysrq-trigger=proc /proc/timer_list=devtmpfs /run/.containerenv=tmpfs /run/podman-init=*"
# ^ external podman 5.6.0 masks these three files on kernels having them (names in its binary); fstype by analogy with /proc/kcore, not probed
ISOLATION_MOUNT_RULES+=" /proc/latency_stats=devtmpfs /proc/sched_debug=devtmpfs /proc/timer_stats=devtmpfs"
# ^ external podman 5.6.0 masks the directory /sys/devices/virtual/powercap with a tmpfs where intel_rapl exists (name in its binary)
ISOLATION_MOUNT_RULES+=" /sys/devices/virtual/powercap=tmpfs"
# ^ external podman 4.9.3 (ubuntu-24.04 hosted runner) masks the directory /sys/dev/block with a tmpfs; in its config.json maskedPaths
ISOLATION_MOUNT_RULES+=" /sys/dev/block=tmpfs"
ISOLATION_MOUNT_RULES+=" /src=* /sys=sysfs /sys/firmware=tmpfs /sys/fs/cgroup=cgroup2 /sys/fs/selinux=tmpfs "

ISOLATION_MAX_MOUNT_LINES=500

# ^ security containers.conf volumes can bind a host directory anywhere => any mount point outside the table fails the run, no /proc /dev /sys wildcards
# ^ security only the mount point (field 5) is read; root (field 4) and source (field 10) are host paths and are never printed
# ^ invariant rc 1 when a mount point is stray, 0 when none is, 2 when the table cannot be read or has no root mount
isolation_stray_mounts() {
    local mp rest fs want stray=0 root=0 seen=" " mount_lines=0
    if [ ! -r "$1" ] || [ -d "$1" ]; then
        printf 'isolation_stray_mounts: cannot read the mount table\n' >&2
        return 2
    fi
    while read -r _ _ _ _ mp _ rest; do
        mount_lines=$((mount_lines + 1))
        if [ "$mount_lines" -gt "$ISOLATION_MAX_MOUNT_LINES" ]; then
            printf '<more than %s mount lines>\n' "$ISOLATION_MAX_MOUNT_LINES"
            stray=1
            break
        fi
        if [ "$mp" = / ]; then root=1; fi
        fs="<none>"
        rest=" $rest"
        if [[ $rest == *" - "* ]]; then
            rest="${rest#* - }"
            fs="${rest%% *}"
        fi
        if [[ $mp != *[!A-Za-z0-9_/.-]* && $ISOLATION_MOUNT_RULES == *" $mp="* ]]; then
            if [[ $seen == *" $mp "* ]]; then
                printf '%s (mounted more than once)\n' "$mp"
                stray=1
                continue
            fi
            seen+="$mp "
            want="${ISOLATION_MOUNT_RULES#*" $mp="}"
            want="${want%% *}"
            if [ "$want" = "*" ] || [ "$want" = "$fs" ]; then continue; fi
            printf '%s (fstype %s)\n' "$mp" "${fs//[^A-Za-z0-9_.-]/?}"
            stray=1
            continue
        fi
        printf '%s\n' "${mp//[^A-Za-z0-9_\/.-]/?}"
        stray=1
    done <"$1"
    if [ "$root" -eq 0 ]; then
        printf 'isolation_stray_mounts: the mount table has no root mount\n' >&2
        return 2
    fi
    [ "$stray" -eq 0 ]
}

# ^ external the 17 entries of /dev to depth 4 in an unmodified rootless podman 5 container under CONTAINERS_CONF
# ^ see doc:docs/platforms.md#what-the-platform-run-enforces
ISOLATION_ALLOWED_DEV=" core fd full mqueue null ptmx pts pts/ptmx random shm stderr stdin stdout tty urandom zero "
ISOLATION_MAX_DEV_ENTRIES=500
ISOLATION_DEV_DEPTH=4

# ^ security containers.conf devices and volumes add host nodes below /dev (shm, mqueue, pts); the whole tree to depth 4 is compared with a baseline
# ^ invariant rc 1 when an entry is stray, 0 when none is, 2 when the tree cannot be listed; find follows no symlink, /dev/fd is one entry
isolation_stray_devices() {
    local -a entries=()
    local -A withheld=()
    local entry stray=0 rc
    if [ ! -d "$1" ] || [ ! -r "$1" ]; then
        printf 'isolation_stray_devices: cannot list %s\n' "${1//[^A-Za-z0-9_\/.-]/?}" >&2
        return 2
    fi
    mapfile -d '' -t -n $((ISOLATION_MAX_DEV_ENTRIES + 1)) entries < <(find "$1" -mindepth 1 -maxdepth "$ISOLATION_DEV_DEPTH" -printf '%P\0' 2>/dev/null)
    wait "$!"
    rc=$?
    if [ "${#entries[@]}" -gt "$ISOLATION_MAX_DEV_ENTRIES" ]; then
        printf '<more than %s /dev entries>\n' "$ISOLATION_MAX_DEV_ENTRIES"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        printf 'isolation_stray_devices: cannot list all of %s\n' "${1//[^A-Za-z0-9_\/.-]/?}" >&2
        return 2
    fi
    for entry in "${entries[@]}"; do
        if [[ $entry != *[!A-Za-z0-9_/.-]* ]] && { [[ $ISOLATION_ALLOWED_DEV == *" $entry "* ]] || [[ $entry =~ ^pts/[0-9]+$ ]]; }; then continue; fi
        stray=1
        # ^ security below shm, mqueue and pts the names can be those of host files (a host /dev/shm over this one) => counted per directory, never printed
        case "$entry" in
            mqueue/* | pts/* | shm/*)
                withheld["${entry%%/*}"]=$((${withheld["${entry%%/*}"]:-0} + 1))
                continue
                ;;
        esac
        printf '%s\n' "${entry//[^A-Za-z0-9_\/.-]/?}"
    done
    for entry in mqueue pts shm; do
        if [ -n "${withheld[$entry]:-}" ]; then printf '%s/* (count %s)\n' "$entry" "${withheld[$entry]}"; fi
    done
    [ "$stray" -eq 0 ]
}

# ^ external time is shared with the host; user is not compared (rootful shares it); probed with each *ns = host
# ^ see doc:docs/platforms.md#what-the-platform-run-enforces
ISOLATION_NS_LIST=(cgroup ipc net pid uts)

# ^ security a container in the launcher's network or IPC namespace sees host interfaces or shared memory => ubuntu.sh passes its /proc/self/ns ids as arguments
# ^ invariant prints namespace NAMES only; rc 1 when one equals the launcher's, 2 when an id or a link cannot be compared, 0 when all differ
isolation_shared_namespaces() {
    local nsdir="$1" ns kv host link own shared=0 bad=0
    shift
    for ns in "${ISOLATION_NS_LIST[@]}"; do
        host=""
        for kv in "$@"; do
            if [ "${kv%%=*}" = "$ns" ]; then host="${kv#*=}"; fi
        done
        if [[ ! $host =~ ^[0-9]+$ ]]; then
            printf 'isolation_shared_namespaces: no usable launcher id for the %s namespace\n' "$ns" >&2
            bad=1
            continue
        fi
        link="$(readlink "$nsdir/$ns" 2>/dev/null)"
        if [[ ! $link =~ ^$ns:\[([0-9]+)\]$ ]]; then
            printf 'isolation_shared_namespaces: cannot read the %s namespace link\n' "$ns" >&2
            bad=1
            continue
        fi
        own="${BASH_REMATCH[1]}"
        if [ "$own" = "$host" ]; then
            printf '%s\n' "$ns"
            shared=1
        fi
    done
    if [ "$bad" -ne 0 ]; then return 2; fi
    [ "$shared" -eq 0 ]
}

# ^ security prints a count only; entry names under /run/secrets could be entitlement certificates and keys
isolation_dir_entries() {
    (
        shopt -s nullglob dotglob
        local -a entries=("$1"/*)
        printf '%s\n' "${#entries[@]}"
    )
}

ISOLATION_ENVIRON=/proc/1/environ
ISOLATION_MOUNTINFO=/proc/self/mountinfo
ISOLATION_DEVDIR=/dev
ISOLATION_NSDIR=/proc/1/ns
ISOLATION_HOST_NS=()
ISOLATION_OS_ID=ubuntu
ISOLATION_OS_VERSION=24.04

# ^ invariant isolation_report KIND WHAT CMD... = one failure line on stray entries (rc 1) or an unreadable source (rc 2), else ok
isolation_report() {
    local kind="$1" what="$2" out rc
    shift 2
    out="$("$@" 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 2 ]; then
        record_fail "cannot $what: the run cannot be shown to be isolated"
        return 1
    fi
    if [ "$rc" -ne 0 ] || [ -n "$out" ]; then
        record_fail "$kind: ${out//$'\n'/ }"
        return 1
    fi
}

# ^ security only variable NAMES are tested against an allow-list, never a value; the container is started without any host environment
# ^ security mount points and /dev entries are tested too => a containers.conf volumes or devices entry cannot put a host path in unnoticed
check_isolation() {
    local var leaked=0 id version
    printf '== the container has no host state\n'
    isolation_report "variable names outside the allow-list" "read the variable names" isolation_stray_names "$ISOLATION_ENVIRON" || leaked=1
    isolation_report "variable names outside the allow-list" "read the variable names" isolation_stray_names \
        <(compgen -e | while IFS= read -r var; do printf '%s=\0' "$var"; done) || leaked=1
    isolation_report "mount points outside the allow-list" "read the mount table" isolation_stray_mounts "$ISOLATION_MOUNTINFO" || leaked=1
    isolation_report "/dev entries outside the allow-list" "list the device directory" isolation_stray_devices "$ISOLATION_DEVDIR" || leaked=1
    isolation_report "namespaces shared with the launcher" "compare the namespaces" isolation_shared_namespaces "$ISOLATION_NSDIR" "${ISOLATION_HOST_NS[@]}" || leaked=1
    if touch /src/.gsg-write-probe 2>/dev/null; then
        rm -f /src/.gsg-write-probe
        record_fail "/src is writable"
        leaked=1
    fi
    if [ "$(isolation_dir_entries /run/secrets)" != 0 ]; then
        record_fail "/run/secrets is not empty ($(isolation_dir_entries /run/secrets) entries): host subscription secrets are mounted"
        leaked=1
    fi
    for var in /root/.ssh /root/.gitconfig /src/.git; do
        if [ -e "$var" ]; then
            record_fail "$var exists"
            leaked=1
        fi
    done
    id="$(os_field ID)"
    version="$(os_field VERSION_ID)"
    if [ "$id" != "$ISOLATION_OS_ID" ] || [[ $version != "$ISOLATION_OS_VERSION"* ]]; then
        record_fail "this is $id $version, not $ISOLATION_OS_ID $ISOLATION_OS_VERSION"
        leaked=1
    fi
    if [ "$leaked" -ne 0 ]; then return 1; fi
    printf 'ok      %s %s: checked variable names, mount points and fstypes, /dev entries, namespaces and /run/secrets; /src read-only, no ssh or git config;\n' "$ISOLATION_OS_ID" "$version"
    printf '        containers.conf layers ignored by the launcher via CONTAINERS_CONF\n'
}

git_is_new_enough() {
    local out
    out="$("$1" --version 2>/dev/null)" || return 1
    [[ $out =~ ^git\ version\ ([0-9]+)\.([0-9]+) ]] || return 1
    [ "${BASH_REMATCH[1]}" -gt "$GIT_MIN_MAJOR" ] || { [ "${BASH_REMATCH[1]}" -eq "$GIT_MIN_MAJOR" ] && [ "${BASH_REMATCH[2]}" -ge "$GIT_MIN_MINOR" ]; }
}

# ^ invariant the PPA route is gitup_apt_ppa_apply of the product; this wrapper adds the log file and the record of where git came from
# ^ invariant rc 0 = git from the PPA, rc 1 = failed and the PPA is disabled again, rc 2 = the PPA may still be enabled (product semantics)
# shellcheck disable=SC2016,SC2034
install_git_ppa() {
    local log="$LOGDIR/git_core_ppa.log" rc
    printf '== git-core PPA (gitup_apt_ppa_apply of the product)\n'
    GITUP_CLASS=ubuntu
    INSTALL_TIMEOUT_BIN="$(type -P timeout)"
    gitup_paths || return 1
    gitup_apt_ppa_apply >"$log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        tail -n 25 "$log" | sed 's/^/        | /'
        printf 'failed  git-core PPA (exit %s, not counted here: the caller decides)\n' "$rc"
        return "$rc"
    fi
    printf 'ok      git-core PPA\n'
    GIT_SOURCE_DESC="PPA ppa:git-core/ppa, package $(dpkg-query -W -f='${Version}' git), $(apt-cache policy git | sed -n '/\*\*\*/{n;s/^ *[0-9]* //;p}')"
}

# ^ security the tarball is accepted only when sha256sum -c matches the pinned digest => a changed or truncated download never reaches make
# ^ external git 2.56 builds without Rust, Tcl/Tk and gettext; the digest is the one of git-2.56.0.tar.xz on kernel.org
# shellcheck disable=SC2016
install_git_source() {
    step "apt-get install git build dependencies" "$APT_TIMEOUT" apt-get install -y --no-install-recommends \
        build-essential libcurl4-openssl-dev libssl-dev libexpat1-dev zlib1g-dev perl || return 1
    build_git_from_tarball
}

# shellcheck disable=SC2016
build_git_from_tarball() {
    local dir=/opt/gsg-git-build
    mkdir -p "$dir" || return 1
    step "download git $GIT_BUILD_VERSION" "$DOWNLOAD_TIMEOUT" curl -fsSL -o "$dir/git.tar.xz" "$GIT_BUILD_URL" || return 1
    step "verify the SHA-256 of the tarball" 60 bash -c 'cd "$1" && printf "%s  git.tar.xz\n" "$2" | sha256sum -c -' _ "$dir" "$GIT_BUILD_SHA256" || return 1
    step "unpack the tarball" 300 tar -C "$dir" -xf "$dir/git.tar.xz" || return 1
    step "make git" "$BUILD_TIMEOUT" make -C "$dir/git-$GIT_BUILD_VERSION" -j "$(nproc)" prefix=/usr/local "${GIT_BUILD_FLAGS[@]}" all || return 1
    step "make install git" "$BUILD_TIMEOUT" make -C "$dir/git-$GIT_BUILD_VERSION" prefix=/usr/local "${GIT_BUILD_FLAGS[@]}" install || return 1
    GIT_SOURCE_DESC="source tarball git-$GIT_BUILD_VERSION.tar.xz from $GIT_BUILD_URL, SHA-256 $GIT_BUILD_SHA256 verified, built with ${GIT_BUILD_FLAGS[*]} into /usr/local"
}

# ^ invariant the PPA comes first; a PPA git below 2.54 or a PPA failure cleaned up falls through to the source build in auto mode, not counted
# ^ security install_git_ppa rc 2 = the PPA may still be enabled => one counted failure and no source build (its root apt install would trust the PPA)
obtain_git() {
    local ok=0 ppa_rc
    # ^ why source for Debian in auto mode, not a PPA try; Launchpad serves Ubuntu releases, and the product's Debian class takes the source route
    if [ "$GIT_SOURCE" = auto ] && [ "$(os_field ID)" = debian ]; then GIT_SOURCE=source; fi
    if [ "$GIT_SOURCE" != source ]; then
        if [ "$GIT_SOURCE" = auto ]; then STEP_SOFT=1; fi
        install_git_ppa
        ppa_rc=$?
        STEP_SOFT=0
        if [ "$ppa_rc" -eq 2 ]; then
            record_fail "the git-core PPA could not be disabled: no source build and no root apt install while it may still be enabled"
            return 1
        fi
        if [ "$ppa_rc" -eq 0 ] && git_is_new_enough git; then ok=1; fi
        if [ "$ok" -eq 0 ] && [ "$GIT_SOURCE" = ppa ]; then
            record_fail "the PPA did not give git >= $GIT_MIN_MAJOR.$GIT_MIN_MINOR"
            return 1
        fi
        if [ "$ok" -eq 0 ]; then printf 'the PPA did not give git >= %s.%s: falling back to the source build\n' "$GIT_MIN_MAJOR" "$GIT_MIN_MINOR"; fi
    fi
    if [ "$ok" -eq 0 ]; then
        install_git_source || return 1
        git_is_new_enough /usr/local/bin/git || { record_fail "the source build is not git >= $GIT_MIN_MAJOR.$GIT_MIN_MINOR"; return 1; }
    fi
    GIT_BIN="$(type -P git)"
    printf 'git: %s (%s)\ngit source: %s\n' "$GIT_BIN" "$("$GIT_BIN" --version)" "$GIT_SOURCE_DESC"
}

# ^ why release 0.11.0, not apt shellcheck 0.9.0; the suite's gate is clean on 0.11 and 0.9 reports other infos (SC2317, SC2119, SC2015)
# ^ external koalaman publishes no digests for the release tarballs; these SHA-256 values were computed once from the v0.11.0 downloads and pin them
# shellcheck disable=SC2016
install_shellcheck() {
    local arch sha dir=/opt/gsg-shellcheck v=$SHELLCHECK_VERSION
    arch="$(uname -m)"
    case "$arch" in
        x86_64) sha="$SHELLCHECK_SHA256_X86_64" ;;
        aarch64) sha="$SHELLCHECK_SHA256_AARCH64" ;;
        *)
            record_fail "no pinned shellcheck for $arch"
            return 1
            ;;
    esac
    mkdir -p "$dir" || return 1
    step "download shellcheck $v" "$DOWNLOAD_TIMEOUT" curl -fsSL -o "$dir/sc.tar.xz" \
        "https://github.com/koalaman/shellcheck/releases/download/v$v/shellcheck-v$v.linux.$arch.tar.xz" || return 1
    step "verify the SHA-256 of shellcheck" 60 bash -c 'cd "$1" && printf "%s  sc.tar.xz\n" "$2" | sha256sum -c -' _ "$dir" "$sha" || return 1
    step "unpack shellcheck" 120 tar -C "$dir" -xf "$dir/sc.tar.xz" || return 1
    step "install shellcheck" 60 install -m 755 "$dir/shellcheck-v$v/shellcheck" /usr/local/bin/shellcheck || return 1
}

# ^ external software-properties-common (add-apt-repository) exists on Ubuntu only; Debian 13 has no such package
apt_prerequisites() {
    local -a pkgs=(ca-certificates curl gnupg jq tar xz-utils gzip util-linux coreutils procps pre-commit systemd dbus gawk mawk perl)
    if [ "$(os_field ID)" = ubuntu ]; then pkgs+=(software-properties-common); fi
    # ^ why the stock git on Debian too, not only the build; as on Rocky, a doctor test calls /usr/bin/git and the source build leaves it alone
    if [ "$(os_field ID)" = debian ]; then pkgs+=(git); fi
    printf '%s\n' "${pkgs[@]}"
}

phase_prepare() {
    local -a pkgs
    export DEBIAN_FRONTEND=noninteractive
    mapfile -t pkgs < <(apt_prerequisites)
    step "apt-get update" "$APT_TIMEOUT" apt-get update || return 1
    step "apt-get install prerequisites" "$APT_TIMEOUT" apt-get install -y --no-install-recommends "${pkgs[@]}" || return 1
    step "start the system bus (systemd-analyze connects to it)" 60 bash -c 'mkdir -p /run/dbus && dbus-daemon --system --fork' || return 1
    install_shellcheck || return 1
    step "make mawk the default awk" 60 update-alternatives --set awk /usr/bin/mawk || return 1
    obtain_git || return 1
    if ! id -u "$TEST_USER" >/dev/null 2>&1; then
        step "create the non-root test user" 60 useradd -m -s /bin/bash "$TEST_USER" || return 1
    fi
}

# ^ order stage_checkout after prepare => the copy of /src is owned by the test user and writable, /src itself stays read-only
stage_checkout() {
    rm -rf -- "$CHECKOUT" || return 1
    cp -a /src "$CHECKOUT" || return 1
    chown -R "$TEST_USER:$TEST_USER" "$CHECKOUT" || return 1
    # ^ why an empty repository in the copy, not the host history; tests list the project's files with git ls-files (test_quality.sh), and /src has no .git
    runuser -u "$TEST_USER" -- env -i HOME="$USER_HOME" PATH="/usr/local/bin:/usr/bin:/bin" "$GIT_BIN" -C "$CHECKOUT" init -q || return 1
}

# ^ security env -i and a fixed variable list => the test user's shell starts with nothing from this container's process environment
as_user() {
    runuser -u "$TEST_USER" -- env -i HOME="$USER_HOME" PATH="$USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 \
        GSG_TEST_GIT="$GIT_BIN" GSG_TEST_SHELLCHECK="$(type -P shellcheck)" GSG_TEST_JQ="$(type -P jq)" \
        GSG_TEST_TRUFFLEHOG="$USER_HOME/.local/bin/trufflehog" GSG_TEST_BETTERLEAKS="$USER_HOME/.local/bin/betterleaks" "$@"
}

need_git() {
    if [ -z "$GIT_BIN" ]; then GIT_BIN="$(type -P git)"; fi
    if [ -z "$GIT_BIN" ] || ! git_is_new_enough "$GIT_BIN"; then
        record_fail "no git >= $GIT_MIN_MAJOR.$GIT_MIN_MINOR is installed; run the prepare phase first"
        return 1
    fi
}

phase_e2e() {
    local log="$LOGDIR/e2e.log" rc
    need_git || return 1
    printf '== install E2E as %s (real downloads)\n' "$TEST_USER"
    stage_checkout || { record_fail "cannot stage the checkout"; return 1; }
    as_user timeout "$E2E_TIMEOUT" bash "$CHECKOUT/tests/platform/ubuntu-e2e.sh" 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"
    E2E_SUMMARY="$(grep '^E2E SUMMARY' "$log" | tail -n 1)"
    if [ "$rc" -ne 0 ] || [[ $E2E_SUMMARY != *" 0 failed"* ]]; then record_fail "install E2E (exit $rc): ${E2E_SUMMARY:-no summary}"; fi
}

# shellcheck disable=SC2016
phase_suite() {
    local log="$LOGDIR/suite.log" rc
    need_git || return 1
    printf '== tests/run.sh as %s (awk is %s)\n' "$TEST_USER" "$(awk -W version 2>&1 | head -n 1)"
    stage_checkout || { record_fail "cannot stage the checkout"; return 1; }
    as_user timeout "$SUITE_TIMEOUT" bash -c 'cd "$1" && shift && exec bash tests/run.sh "$@"' _ "$CHECKOUT" "${SUITE_FILES[@]}" 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"
    SUITE_SUMMARY="$(grep '^SUMMARY:' "$log" | tail -n 1)"
    if [ "$rc" -ne 0 ] || [[ $SUITE_SUMMARY != *" 0 failed"* ]]; then record_fail "tests/run.sh (exit $rc): ${SUITE_SUMMARY:-no summary}"; fi
}

print_summary() {
    local v
    printf '\n=== %s PLATFORM TEST SUMMARY ===\n' "$PLATFORM_TITLE"
    printf 'os:        %s\n' "$(os_field PRETTY_NAME)"
    if [ -n "$ISOLATION_SKIP_REASON" ]; then printf 'isolation: SKIPPED (%s)\n' "$ISOLATION_SKIP_REASON"; fi
    printf 'image:     %s\n' "${IMAGE_REF:-not passed (start the run through tests/platform/ubuntu.sh)}"
    printf 'bash:      %s\n' "${BASH_VERSION}"
    printf 'awk:       %s -> %s\n' "$(readlink -f /usr/bin/awk)" "$(awk -W version 2>&1 | head -n 1)"
    if type -P gawk >/dev/null; then printf 'gawk:      %s\n' "$(gawk --version | head -n 1)"; fi
    if type -P mawk >/dev/null; then printf 'mawk:      %s\n' "$(mawk -W version 2>&1 | head -n 1)"; fi
    printf 'jq:        %s\n' "$(jq --version 2>&1)"
    printf 'coreutils: %s\n' "$(timeout --version | head -n 1)"
    if [ -n "$GIT_BIN" ]; then printf 'git:       %s (%s)\ngit from:  %s\n' "$GIT_BIN" "$("$GIT_BIN" --version)" "$GIT_SOURCE_DESC"; fi
    for v in "$E2E_SUMMARY" "$SUITE_SUMMARY"; do
        if [ -n "$v" ]; then printf '%s\n' "$v"; fi
    done
    if [ -f "$LOGDIR/suite.log" ]; then
        printf 'skipped tests and their reasons:\n'
        grep '^SKIPPED' "$LOGDIR/suite.log" | sed 's/^/  /' || printf '  none\n'
    fi
    if [ "$FAILURES" -eq 0 ]; then
        printf 'RESULT: PASS\n'
    else
        printf 'RESULT: FAIL (%s failed step(s))\n' "$FAILURES"
    fi
}

main() {
    local phase
    parse_args "$@"
    mkdir -p -- "$LOGDIR" || exit 2
    # ^ order check_isolation before every phase => a leaked host variable or secret ends the run before any apt or network step
    # ^ security --skip-isolation is for the macOS host runner only (podman VM boundary); the reason is printed here and in the summary
    if [ -n "$ISOLATION_SKIP_REASON" ]; then
        printf 'SKIPPED isolation check: %s\n' "$ISOLATION_SKIP_REASON"
    else
        check_isolation || {
            printf 'ABORT: the isolation check failed; nothing was installed or downloaded\nRESULT: FAIL (%s failed step(s))\n' "$FAILURES"
            return 1
        }
    fi
    for phase in "${PHASES[@]}"; do
        "phase_${phase//-/_}" || record_fail "phase $phase did not finish"
    done
    print_summary
    [ "$FAILURES" -eq 0 ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
