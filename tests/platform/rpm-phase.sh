# shellcheck shell=bash
# ^ coupled sourced by rocky-container.sh and fedora-container.sh after ubuntu-container.sh; uses its step, record_fail, LOGDIR, TEST_USER, USER_HOME, CHECKOUT
# ^ external neither image ships git; Rocky gets the stock RPM git (2.52) first, Fedora starts with no git at all and takes the package route

RPM_DISTRO=""
RPM_E2E_TIMEOUT=3300
RPM_PREP_PKGS=(jq util-linux sudo ca-certificates diffutils findutils procps-ng rpm-build createrepo_c policycoreutils libcap)
# ^ invariant nopasswd = the test user may run sudo without a password (default), password = it needs one, none = no sudo package at all (a root run)
RPM_SUDO=nopasswd
# ^ external the Fedora 41 release repository still serves this package; the digest is of the file as downloaded over HTTPS on 2026-11-06
RPM_OLD_GIT_URL=https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/41/Everything/x86_64/os/Packages/g/git-core-2.47.0-1.fc41.x86_64.rpm
RPM_OLD_GIT_SHA256=046406e71dd0f87a4fb9013f750113d28bafad52639eda09818fde2df8953978

rpm_prepare_machine() {
    local -a pkgs=("${RPM_PREP_PKGS[@]}")
    if [ "$RPM_SUDO" = none ]; then
        mapfile -t pkgs < <(printf '%s\n' "${RPM_PREP_PKGS[@]}" | grep -vx sudo)
    fi
    step "dnf install prerequisites" 900 dnf install -y --allowerasing --setopt=install_weak_deps=False "${pkgs[@]}" || return 1
    if [ "$RPM_DISTRO" = rocky ]; then
        step "dnf install the stock RPM git" 900 dnf install -y git || return 1
    fi
    rpm_show_caps "before"
    # ^ external rootless podman on the hosted runner drops file capabilities of the image; RHEL's pam_unix helper needs one, and sudo then fails in PAM
    step "restore the file capabilities of the pam package" 120 rpm --setcaps pam || return 1
    rpm_show_caps "after"
    if ! id -u "$TEST_USER" >/dev/null 2>&1; then
        step "create the non-root test user" 60 useradd -m -s /bin/bash "$TEST_USER" || return 1
    fi
    case "$RPM_SUDO" in
        nopasswd) rpm_write_sudoers "$TEST_USER ALL=(ALL) NOPASSWD:ALL" || return 1 ;;
        password) rpm_password_setup || return 1 ;;
        none) if type -P sudo >/dev/null; then record_fail "sudo is installed, a root run proves nothing"; return 1; fi ;;
    esac
}

rpm_show_caps() {
    printf '        | file capabilities of unix_chkpwd %s: %s\n' "$1" "$(getcap /usr/sbin/unix_chkpwd 2>&1 | sed 's/^[^ ]* //')"
}

rpm_write_sudoers() {
    mkdir -p /etc/sudoers.d || return 1
    printf '%s\n' "$1" >"/etc/sudoers.d/$TEST_USER" || return 1
    chmod 440 "/etc/sudoers.d/$TEST_USER" || return 1
}

# ^ security the password is random, lives only in this disposable container and in a file only the test user reads; no step prints it
rpm_password_setup() {
    local pw
    pw="$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')" || return 1
    if [ "${#pw}" -ne 36 ]; then record_fail "no random password could be made"; return 1; fi
    printf '%s:%s\n' "$TEST_USER" "$pw" | chpasswd || return 1
    rpm_write_sudoers "$TEST_USER ALL=(ALL) ALL" || return 1
    (umask 077 && printf '%s' "$pw" >"$USER_HOME/.sudo-pw") || return 1
    chown "$TEST_USER:$TEST_USER" "$USER_HOME/.sudo-pw" || return 1
}

# ^ security the package is accepted only when its SHA-256 equals the digest above; it is the stock git of Fedora 41, older than the 2.54 floor
rpm_old_git() {
    local rpmfile=/tmp/old-git-core.rpm
    step "download an old git-core (Fedora 41, 2.47.0)" 300 curl -fsS --max-time 240 -o "$rpmfile" "$RPM_OLD_GIT_URL" || return 1
    if [ "$(sha256sum <"$rpmfile" | cut -d' ' -f1)" != "$RPM_OLD_GIT_SHA256" ]; then
        record_fail "the old git-core package does not match its digest"
        return 1
    fi
    step "dnf install the old git-core" 900 dnf install -y --allowerasing --setopt=install_weak_deps=False "$rpmfile" || return 1
}

# ^ security the E2E runs as the test user with sudo, the way a real user runs install; env -i and a fixed variable list keep this container's environment out
phase_upgrade() {
    local log="$LOGDIR/upgrade-e2e.log" rc
    rpm_prepare_machine || return 1
    rm -rf -- "$CHECKOUT" || return 1
    cp -a /src "$CHECKOUT" || return 1
    chown -R "$TEST_USER:$TEST_USER" "$CHECKOUT" || return 1
    printf '== upgrade E2E (%s) as %s, real downloads, real dnf, real build\n' "$RPM_DISTRO" "$TEST_USER"
    runuser -u "$TEST_USER" -- env -i HOME="$USER_HOME" PATH="$USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 \
        timeout "$RPM_E2E_TIMEOUT" bash "$CHECKOUT/tests/platform/rpm-upgrade-e2e.sh" "$RPM_DISTRO" 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"
    E2E_SUMMARY="$(grep '^E2E SUMMARY' "$log" | tail -n 1)"
    if [ "$rc" -ne 0 ] || [[ $E2E_SUMMARY != *" 0 failed"* ]]; then record_fail "upgrade E2E (exit $rc): ${E2E_SUMMARY:-no summary}"; fi
}

# ^ invariant rpm_run_mode MODE WHO = rpm-more-e2e.sh MODE for this distribution, as the test user (WHO = user) or as root with HOME=/root (WHO = root)
# ^ security both run under env -i with a fixed variable list; nothing of this container environment reaches the E2E
rpm_run_mode() {
    local mode="$1" who="$2" log="$LOGDIR/upgrade-$1.log" rc home="$USER_HOME" ck
    if [ "$who" = root ]; then home=/root; fi
    ck="$home/checkout"
    rm -rf -- "$ck" || return 1
    cp -a /src "$ck" || return 1
    printf '== E2E mode %s (%s) as %s, real downloads, real dnf\n' "$mode" "$RPM_DISTRO" "$who"
    if [ "$who" = root ]; then
        env -i HOME=/root PATH="/root/.local/bin:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 \
            timeout "$RPM_E2E_TIMEOUT" bash "$ck/tests/platform/rpm-more-e2e.sh" "$RPM_DISTRO" "$mode" 2>&1 | tee "$log"
    else
        chown -R "$TEST_USER:$TEST_USER" "$ck" || return 1
        runuser -u "$TEST_USER" -- env -i HOME="$home" PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 \
            timeout "$RPM_E2E_TIMEOUT" bash "$ck/tests/platform/rpm-more-e2e.sh" "$RPM_DISTRO" "$mode" 2>&1 | tee "$log"
    fi
    rc="${PIPESTATUS[0]}"
    E2E_SUMMARY="$(grep '^E2E SUMMARY' "$log" | tail -n 1)"
    if [ "$rc" -ne 0 ] || [[ $E2E_SUMMARY != *" 0 failed"* ]]; then record_fail "E2E mode $mode (exit $rc): ${E2E_SUMMARY:-no summary}"; fi
}

# ^ invariant the full flow as root, on a machine with no sudo at all
phase_upgrade_root() {
    RPM_SUDO=none
    rpm_prepare_machine || return 1
    rpm_run_mode root root
}

# ^ invariant sudo asks for a password on a pty; the E2E answers it from a file only the test user reads
phase_upgrade_password() {
    RPM_SUDO=password
    rpm_prepare_machine || return 1
    rpm_run_mode password user
}

phase_upgrade_bump() {
    rpm_prepare_machine || return 1
    rpm_run_mode bump user
}

phase_upgrade_old() {
    rpm_prepare_machine || return 1
    rpm_old_git || return 1
    rpm_run_mode old user
}

# ^ invariant stage 1 of the offline restore (rpm.sh --offline-restore) upgrades and takes over and stops; the launcher commits the container
phase_upgrade_takeover() {
    rpm_prepare_machine || return 1
    rpm_run_mode takeover user
}

# ^ invariant stage 2 runs in a container with no network, started from the committed stage 1; nothing is installed here, there is no way to
phase_upgrade_offline() {
    rpm_run_mode offline user
}
