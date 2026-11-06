# shellcheck shell=bash
# ^ coupled sourced by ubuntu-container.sh; uses its step, record_fail, os_field, LOGDIR, TEST_USER, USER_HOME, CHECKOUT and E2E_SUMMARY
# ^ external the images ship no sudo and no git; the machine is made like a user's with the stock git, sudo and no PPA tools (no gnupg)

APT_E2E_TIMEOUT=3300
APT_PREP_PKGS=(git jq util-linux sudo ca-certificates curl xz-utils tar gzip procps)

apt_prepare_machine() {
    export DEBIAN_FRONTEND=noninteractive
    step "apt-get update" 900 apt-get update || return 1
    step "apt-get install the stock git and the prerequisites" 900 apt-get install -y --no-install-recommends "${APT_PREP_PKGS[@]}" || return 1
    # ^ why the lists are emptied again, not left as the install made them; the product must refresh them itself before its first install
    step "empty the apt package lists again" 120 find /var/lib/apt/lists -mindepth 1 -type f ! -name lock -delete || return 1
    if ! id -u "$TEST_USER" >/dev/null 2>&1; then
        step "create the non-root test user" 60 useradd -m -s /bin/bash "$TEST_USER" || return 1
    fi
    mkdir -p /etc/sudoers.d || return 1
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TEST_USER" >"/etc/sudoers.d/$TEST_USER" || return 1
    chmod 440 "/etc/sudoers.d/$TEST_USER" || return 1
}

# ^ security the E2E runs as the test user with sudo, the way a real user runs install; env -i and a fixed variable list keep this container's environment out
phase_upgrade() {
    local log="$LOGDIR/upgrade-e2e.log" rc distro
    distro="$(os_field ID)"
    apt_prepare_machine || return 1
    rm -rf -- "$CHECKOUT" || return 1
    cp -a /src "$CHECKOUT" || return 1
    chown -R "$TEST_USER:$TEST_USER" "$CHECKOUT" || return 1
    printf '== upgrade E2E (%s %s) as %s, real downloads, real apt, real PPA\n' "$distro" "$(os_field VERSION_ID)" "$TEST_USER"
    runuser -u "$TEST_USER" -- env -i HOME="$USER_HOME" PATH="$USER_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 \
        timeout "$APT_E2E_TIMEOUT" bash "$CHECKOUT/tests/platform/apt-upgrade-e2e.sh" "$distro" "$(os_field VERSION_ID)" 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"
    E2E_SUMMARY="$(grep '^E2E SUMMARY' "$log" | tail -n 1)"
    if [ "$rc" -ne 0 ] || [[ $E2E_SUMMARY != *" 0 failed"* ]]; then record_fail "upgrade E2E (exit $rc): ${E2E_SUMMARY:-no summary}"; fi
}
