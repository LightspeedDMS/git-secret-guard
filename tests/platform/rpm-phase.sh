# shellcheck shell=bash
# ^ coupled sourced by rocky-container.sh and fedora-container.sh after ubuntu-container.sh; uses its step, record_fail, LOGDIR, TEST_USER, USER_HOME, CHECKOUT
# ^ external neither image ships git; Rocky gets the stock RPM git (2.52) first, Fedora starts with no git at all and takes the package route

RPM_DISTRO=""
RPM_E2E_TIMEOUT=3300
RPM_PREP_PKGS=(jq util-linux sudo ca-certificates diffutils findutils procps-ng rpm-build createrepo_c policycoreutils)

rpm_prepare_machine() {
    step "dnf install prerequisites" 900 dnf install -y --allowerasing --setopt=install_weak_deps=False "${RPM_PREP_PKGS[@]}" || return 1
    if [ "$RPM_DISTRO" = rocky ]; then
        step "dnf install the stock RPM git" 900 dnf install -y git || return 1
    fi
    if ! id -u "$TEST_USER" >/dev/null 2>&1; then
        step "create the non-root test user" 60 useradd -m -s /bin/bash "$TEST_USER" || return 1
    fi
    mkdir -p /etc/sudoers.d || return 1
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TEST_USER" >"/etc/sudoers.d/$TEST_USER" || return 1
    chmod 440 "/etc/sudoers.d/$TEST_USER" || return 1
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
