# shellcheck shell=bash disable=SC2034

# ^ invariant sourced by tests/platform/autoupdate-e2e.sh; the manual end-to-end test of updater visibility in status and doctor, steps 1 to 6
# ^ order runs after step 7 of the auto-update test, before its steps 8 and 9; both installs exist, step 9 uninstalls them at VIS_FINAL, the last version here
# ^ coupled the constants, report, excerpt, check_*, run, fixture, as, bare, path_of, mark and expect_* come from autoupdate-e2e.sh and autoupdate-e2e-lib.sh
PLAIN=gsgplain
VIS_FINAL=""

# ^ invariant check_lacks FILE TEXT LABEL is one claim, PASS when the file holds no line with the fixed string; a grep error is a FAIL
check_lacks() {
    local rc=0
    grep -qF -- "$2" "$1" || rc=$?
    case "$rc" in
        1) report ok "$3" ;;
        0) report bad "$3 (unexpected [$2] in $1: $(excerpt "$1"))" ;;
        *) report bad "$3 ($1 could not be searched)" ;;
    esac
}

# ^ invariant check_line FILE ERE LABEL is one claim, PASS when a whole line of the file matches the extended regex
check_line() {
    if grep -qxE -- "$2" "$1"; then report ok "$3"; else report bad "$3 (no line matching [$2] in $1: $(excerpt "$1"))"; fi
}

# ^ invariant doctor_as ACCOUNT NAME runs the account's installed doctor on an empty root of its own => only the machine section has content
doctor_as() {
    local cli roots="/home/$1/e2e-roots"
    cli="$(path_of "$1" cli)" || return 1
    fixture "roots-$1" as "$1" mkdir -p "$roots" || return 1
    run "doctor-$2" as "$1" "$cli" doctor --roots "$roots"
}

# ^ invariant step 1; a third account of the shared group installs from the same checkout without --auto-update
vis_plain_install() {
    local state
    fixture "useradd-$PLAIN" useradd -m -s /bin/bash -g "$GROUP" "$PLAIN" || return 1
    state="$(path_of "$PLAIN" state)" || return 1
    run "install-$PLAIN" bare "$PLAIN" "$CHECKOUT/bin/git-secret-guard" install
    check_rc 0 "$PLAIN: a plain install from the owner's checkout"
    check_has "$state/state" "auto_update=no" "$PLAIN: the state records auto_update=no"
    check_has "$state/state" "source_checkout=$CHECKOUT" "$PLAIN: and the checkout it ran from"
}

# ^ invariant step 2 for one account; the exit status is part of the PASS or FAIL line
# ^ coupled step 7 of the auto-update test ran just before => the last record of both auto-update accounts says current
vis_status() {
    local a="$1" cli
    cli="$(path_of "$a" cli)" || return 1
    run "status-$a" as "$a" "$cli" status
    check_rc 0 "$a: status exits 0 (exit $RC)"
    if [ "$a" = "$PLAIN" ]; then
        check_line "$OUTF" 'auto-update: off' "$a: status says auto-update: off"
        check_lacks "$OUTF" 'last check:' "$a: and shows no last check line"
        return 0
    fi
    check_has "$OUTF" "auto-update: on (checkout $CHECKOUT, every ${INTERVAL}s)" "$a: status names the checkout and the ${INTERVAL}s interval"
    check_line "$OUTF" 'last check: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z current' "$a: status shows the last check from the record"
}

# ^ invariant vis_wait_idle ACCOUNT returns 0 once systemd says the account's update service is inactive or failed
# ^ invariant rc 1 for a state systemd did not print or one not listed, and after RUN_BOUND seconds or the script deadline
vis_wait_idle() {
    local a="${1:?vis_wait_idle needs an ACCOUNT}" n state
    for ((n = 0; n < RUN_BOUND && SECONDS < E2E_DEADLINE; n++)); do
        # ^ external is-active exits non-zero for every state except active; the printed state is judged, an empty one fails below
        state="$(as "$a" systemctl --user is-active "$SERVICE")" || :
        case "$state" in
            active | activating | deactivating | reloading) sleep 1 ;;
            inactive | failed) return 0 ;;
            *)
                printf 'the state of %s for %s could not be read [%s]\n' "$SERVICE" "$a" "$state" >&2
                return 1
                ;;
        esac
    done
    return 1
}

# ^ invariant step 3; vis_older_cycle PREV NEXT pushes tag vNEXT, both auto-update installs and the plain one are at PREV
# ^ why the follower's timer is stopped, not raced; the gap exists only between the owner's fast-forward and the follower's next run
vis_older_cycle() {
    local prev="$1" v="$2" older
    older="auto-update: the installed version $prev is older than $CHECKOUT/VERSION ($v)"
    fixture "stop-timer-$FOLLOWER" as "$FOLLOWER" systemctl --user stop "$TIMER" || return 1
    if ! vis_wait_idle "$FOLLOWER"; then
        report bad "$FOLLOWER: the update service still runs after its timer was stopped"
        return 1
    fi
    mark || return 1
    fixture "release-$v" release "$v" good || return 1
    # ^ order set after the push, before the claims; the owner's checkout moves to the tag whatever the claims find
    VIS_FINAL="$v"
    expect_update "$OWNER" owner "$prev" "$v"
    doctor_as "$FOLLOWER" "$FOLLOWER-older" || return 1
    check_rc 1 "$FOLLOWER: doctor exits 1 while the install is behind the checkout"
    check_has "$OUTF" "PROBLEM  $older" "$FOLLOWER: doctor reports the install older than the checkout's VERSION"
    doctor_as "$PLAIN" "$PLAIN-older" || return 1
    check_rc 1 "$PLAIN: doctor exits 1 for the same gap with auto-update off"
    check_has "$OUTF" "PROBLEM  $older" "$PLAIN: doctor reports the install older"
    check_has "$OUTF" "info     auto-update: off" "$PLAIN: and says auto-update is off"
    fixture "start-timer-$FOLLOWER" as "$FOLLOWER" systemctl --user start "$TIMER" || return 1
    expect_update "$FOLLOWER" follower "$prev" "$v"
    doctor_as "$FOLLOWER" "$FOLLOWER-current" || return 1
    check_lacks "$OUTF" "is older than" "$FOLLOWER: after the cycle the problem is gone (doctor exit $RC)"
    check_has "$OUTF" "ok       auto-update: on, following $CHECKOUT every ${INTERVAL}s; last check " "$FOLLOWER: doctor's ok line for the updater"
    doctor_as "$PLAIN" "$PLAIN-still" || return 1
    check_rc 1 "$PLAIN: doctor still exits 1, nothing updates a plain install"
    check_has "$OUTF" "PROBLEM  $older" "$PLAIN: doctor keeps reporting the install older"
}

# ^ invariant step 4; the wants link is what systemctl enable writes, enable writes it back
vis_wants_link() {
    local wants
    wants="$(path_of "$FOLLOWER" units)/timers.target.wants/$TIMER" || return 1
    fixture unlink-wants as "$FOLLOWER" rm -- "$wants" || return 1
    doctor_as "$FOLLOWER" wants-missing || return 1
    check_rc 1 "$FOLLOWER: doctor exits 1 without the wants link"
    check_has "$OUTF" "PROBLEM  auto-update: timer inactive: $wants is missing" "$FOLLOWER: doctor reports the timer inactive and names the link"
    fixture relink-wants as "$FOLLOWER" systemctl --user enable "$TIMER" || return 1
    check_ok "$FOLLOWER: systemctl --user enable wrote the wants link back" test -e "$wants"
}

# ^ invariant step 5; the checkout is moved back before this returns, whatever the doctor runs gave
vis_checkout_moved() {
    local away="$CHECKOUT.e2e-away" missing="auto-update: the recorded checkout $CHECKOUT is missing"
    fixture checkout-away mv -- "$CHECKOUT" "$away" || return 1
    if doctor_as "$FOLLOWER" checkout-missing; then
        check_rc 1 "$FOLLOWER: doctor exits 1 while the recorded checkout is gone"
        check_has "$OUTF" "PROBLEM  $missing" "$FOLLOWER: doctor reports the recorded checkout missing"
    fi
    if doctor_as "$PLAIN" checkout-missing-plain; then
        check_lacks "$OUTF" "$missing" "$PLAIN: no checkout-missing problem while auto-update is off"
        check_lacks "$OUTF" "timer inactive" "$PLAIN: and no timer problem"
    fi
    fixture checkout-back mv -- "$away" "$CHECKOUT"
}

# ^ invariant rc 0 once the follower's user manager answers and its update timer is active again; at most MANAGER_WAIT seconds
# ^ coupled step 9 of the auto-update test uninstalls through this manager, the timer must be back before it
vis_manager_back() {
    local n state
    for ((n = 0; n < MANAGER_WAIT && SECONDS < E2E_DEADLINE; n++)); do
        if as "$FOLLOWER" systemctl --user is-system-running >/dev/null 2>&1; then
            state="$(as "$FOLLOWER" systemctl --user is-active "$TIMER")" || :
            if [ "$state" = active ]; then return 0; fi
        fi
        sleep 1
    done
    return 1
}

# ^ invariant step 6; disable-linger stops the follower's user manager, enable-linger and the wants link bring it and the timer back
vis_linger() {
    local file="/var/lib/systemd/linger/$FOLLOWER"
    fixture disable-linger loginctl disable-linger "$FOLLOWER" || return 1
    check_ok "$FOLLOWER: loginctl disable-linger removed $file" gone "$file"
    if doctor_as "$FOLLOWER" no-linger; then
        check_has "$OUTF" "WARNING  auto-update: linger is off for $FOLLOWER ($file is missing)" "$FOLLOWER: doctor warns about the missing linger file (doctor exit $RC)"
    fi
    fixture enable-linger loginctl enable-linger "$FOLLOWER" || return 1
    check_ok "$FOLLOWER: linger is back, the user manager answers and the update timer is active" vis_manager_back
}

# ^ invariant step_visibility PREV NEXT; the group's steps 1 to 6 in order, tag vNEXT is pushed in step 3
step_visibility() {
    local a
    printf '== step S2: updater visibility in status and doctor\n'
    vis_plain_install || return 1
    for a in "$OWNER" "$FOLLOWER" "$PLAIN"; do vis_status "$a"; done
    vis_older_cycle "$1" "$2"
    vis_wants_link
    vis_checkout_moved
    vis_linger
}
