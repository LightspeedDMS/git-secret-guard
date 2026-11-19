#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016
# ^ invariant the Windows parts of the updater (#132) run on real git, a real second owner and real processes; the scheduler has its own file
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/autoupdate/autoupdate.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/autoupdate.sh"

# ^ external only a Windows host has MSYS ownership, icacls and a native git to refuse another account's checkout
if [ "$TEST_IS_WINDOWS" -ne 1 ]; then FILE_SKIP_REASON="needs a Windows host: MSYS file ownership, icacls and native git (Linux has [ -O ] and the container run)"; fi

# ^ invariant SYSTEM by its well-known SID; the account exists on every Windows and needs no name lookup
WIN_OTHER_OWNER='*S-1-5-18'

# ^ invariant win_chown_other DIR gives DIR and everything below it to another account; rc 1 = icacls was refused (needs an elevated prompt)
win_chown_other() {
    MSYS_NO_PATHCONV=1 icacls "$(cygpath -w "$1")" /setowner "$WIN_OTHER_OWNER" /T /C >/dev/null 2>&1
}

WIN_LISTENER_PID=""
# ^ invariant the listener lives as long as its test; every way out of the test subshell ends it
win_stop_listener() {
    if [ -n "$WIN_LISTENER_PID" ]; then kill -KILL "$WIN_LISTENER_PID" 2>/dev/null || :; fi
    WIN_LISTENER_PID=""
}

# ^ invariant win_hang_origin sets WIN_HANG_PORT = a loopback port whose listener accepts connections and never answers; git against it hangs for ever
# ^ why PowerShell, not nc; Windows has no nc, and port 0 lets the system choose a free one, written to a file the test waits for (at most 20 s)
win_hang_origin() {
    local script="$SANDBOX/hang-origin.ps1" portfile="$SANDBOX/hang-origin.port" i
    rm -f -- "$portfile"
    cat >"$script" <<'EOF'
param([string]$PortFile)
$l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$l.Start()
Set-Content -Path $PortFile -Value ([string]$l.LocalEndpoint.Port)
$keep = @()
while ($true) { $keep += $l.AcceptTcpClient() }
EOF
    powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$script")" -PortFile "$(cygpath -w "$portfile")" >/dev/null 2>&1 &
    WIN_LISTENER_PID=$!
    trap win_stop_listener EXIT
    for ((i = 0; i < 40; i++)); do
        if [ -s "$portfile" ]; then
            WIN_HANG_PORT="$(tr -d '\r\n ' <"$portfile")"
            return 0
        fi
        sleep 0.5
    done
    win_stop_listener
    return 1
}

# ^ invariant prints "none", or the git, ssh and git-remote processes whose command line names $1; CIM sees native children the MSYS process table does not
win_survivors() {
    local script="$SANDBOX/survivors.ps1"
    cat >"$script" <<'EOF'
param([string]$Pattern)
$r = Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(git|ssh|git-remote)' -and $_.CommandLine -match $Pattern }
if ($r) { $r | ForEach-Object { '{0} {1}' -f $_.ProcessId, $_.Name } } else { 'none' }
EOF
    powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$script")" -Pattern "$1" | tr -d '\r'
}

# ^ invariant issue 3 of #132; no setsid on Windows, GNU timeout alone ends git and every process below it within the bound
# ^ why the stand-in cuts the fetch to one second, not the real 120; the tree kill under test is the real timeout's
test_a_fetch_against_a_hanging_origin_is_bounded_and_leaves_no_process() {
    local t0 elapsed
    au_setup_with_release || return 1
    win_hang_origin || skip_test "the PowerShell listener of the hanging origin did not start"
    gitx -C "$AU_CO" remote set-url origin "http://127.0.0.1:$WIN_HANG_PORT/x.git" || return 1
    au_timeout_standin fetch cut || return 1
    t0=$SECONDS
    upd
    elapsed=$((SECONDS - t0))
    assert_rc 0 "a fetch that never answers is a skip, not an error"
    assert_record skipped fetch-failed "the record"
    assert_contains "$(<"$SANDBOX/au-timeout.log")" " fetch " "the fetch ran under the timeout"
    [ "$elapsed" -le 40 ] || fail "the run took $elapsed s; the fetch was not bounded"
    sleep 1
    assert_eq "$(win_survivors "$WIN_HANG_PORT")" none "no git, git-remote or ssh process of the hanging fetch is left"
    assert_no_file "$LC_STATE/update.lock" "the lock is released"
}

# ^ invariant Git Credential Manager waits for an unseen window (probed, the fetch ran to its limit); update exports GCM_INTERACTIVE=never
test_update_tells_credential_manager_never_to_prompt() {
    au_setup || return 1
    au_broken_installer 'printf "%s\n" "${GCM_INTERACTIVE:-unset}" >"'"$SANDBOX"'/au-child.gcm"; exit 1' && au_release 1.1.0 && au_publish || return 1
    upd
    assert_record failed install-failed "the stand-in installer ran"
    assert_eq "$(<"$SANDBOX/au-child.gcm")" never "the child install sees GCM_INTERACTIVE=never"
}

# ^ invariant AC3 of #132; [ -O ] says mine for another account under MSYS (probed), the role comes from the ownership check of git
test_the_role_is_owner_for_my_checkout_and_follower_for_another_accounts_checkout() {
    local other="$SANDBOX/au-extra-other"
    au_setup_with_release || return 1
    upd
    assert_rc 0 "update on my own checkout"
    assert_eq "$(rec role)" owner "my checkout, owned by the running user: role=owner"
    assert_record updated "" "the owner updated"
    au_release 1.2.0 && au_publish && au_clone other || return 1
    win_chown_other "$other" || skip_test "icacls /setowner was refused: setting another owner needs an elevated prompt"
    if [ -O "$other" ] && [ -O "$other/.git" ]; then
        printf 'observation: [ -O ] is true for the checkout of another account (not reliable under MSYS)\n' >&2
    fi
    au_state source_checkout "$(realpath -- "$other")" || return 1
    upd
    assert_rc 0 "update on the checkout of another account"
    assert_eq "$(rec role)" follower "the checkout owned by another account: role=follower"
    assert_record updated "" "the follower installed from the checkout without writing to it"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.2.0 "the follower's copy is the tag's"
}

# ^ invariant issue 1 of #132; a script or a working directory in the share blocks the rename install does; update leaves both first
# ^ coupled the update starts from the installed copy, re-executes itself from a private copy in the state dir and removes it when it ends
test_an_update_started_from_the_share_replaces_it_and_leaves_no_copy() {
    au_setup_with_release || return 1
    upd
    assert_rc 0 "update started from the installed share"
    assert_record updated "" "the share was replaced while update was running from it"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.1.0 "the installed copy is the tag's"
    assert_eq "$(find "$LC_STATE" -maxdepth 1 -name 'update-copy.*' | wc -l | tr -d ' ')" 0 "the private copy is gone"
    assert_eq "$(au_leftovers)" 0 "no work dir is left"
}

# ^ invariant a working directory inside the share pins it as well; the re-exec leaves it first
test_an_update_started_inside_the_share_dir_replaces_it() {
    au_setup_with_release || return 1
    # ^ why exec in a bash -c, not a subshell with cd; the subshell of the test would keep its working directory in the share
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" bash -c 'cd -- "$1" && exec ./git-secret-guard update' _ "$LC_DATA/bin" </dev/null
    assert_rc 0 "update started with the share's bin dir as the working directory"
    assert_record updated "" "the share was replaced"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.1.0 "the installed copy is the tag's"
}

# ^ invariant a copy left by a killed run is removed by the next run once it is a day old; a young one may belong to a live run and stays
test_a_copy_left_by_a_killed_run_is_swept_when_old_and_kept_when_young() {
    au_setup || return 1
    mkdir -p -- "$LC_STATE/update-copy.OLD111" "$LC_STATE/update-copy.NEW222" && touch -d '3 days ago' "$LC_STATE/update-copy.OLD111" || return 1
    upd
    assert_rc 0 "update with nothing to install"
    assert_no_file "$LC_STATE/update-copy.OLD111" "the old copy is swept"
    assert_file "$LC_STATE/update-copy.NEW222" "the young copy stays"
}

# ^ invariant with auto_update off update prints its line and copies nothing
test_update_with_auto_update_off_makes_no_copy() {
    au_setup || return 1
    au_state auto_update no || return 1
    upd
    assert_rc 0 "update while off"
    assert_contains "$OUT" "auto-update is off" "says so"
    assert_eq "$(find "$LC_STATE" -maxdepth 1 -name 'update-copy.*' | wc -l | tr -d ' ')" 0 "no copy was made"
}

# ^ invariant git exits 128 for dubious ownership and for no repository alike, and walks up from the checkout; neither may turn a broken checkout into a role
test_a_checkout_that_is_no_repository_has_no_role_and_is_skipped() {
    local base="$SANDBOX/role-broken"
    au_setup || return 1
    rm -rf -- "$base" && mkdir -p -- "$base/lone/.git" "$base/outer/sub/.git" && gitx init -q "$base/outer" || return 1
    au_lib "$GSG_PROJECT" 'lifecycle_require_git; autoupdate_role "$1"' "$base/lone"
    assert_rc 1 "an empty .git directory on its own"
    assert_empty "$OUT" "no role is printed"
    au_lib "$GSG_PROJECT" 'lifecycle_require_git; autoupdate_role "$1"' "$base/outer/sub"
    assert_rc 1 "an empty .git directory inside a repository of this user (git must not walk up to it)"
    assert_empty "$OUT" "no role is printed either"
    au_state source_checkout "$base/lone" || return 1
    upd
    assert_rc 0 "a skip is not an error"
    assert_record skipped not-a-plain-checkout "update on a checkout that is no repository"
    assert_contains "$(rec detail)" "$base/lone/.git is not a directory or no repository" "the detail names both causes"
}

# ^ invariant Git Credential Manager waits for an unseen window (probed); a run by hand from the checkout makes no copy and needs the variable too
test_a_run_by_hand_that_does_not_re_exec_still_tells_credential_manager_never_to_prompt() {
    au_setup || return 1
    au_broken_installer 'printf "%s\n" "${GCM_INTERACTIVE:-unset}" >"'"$SANDBOX"'/au-child.gcm"; exit 1' && au_release 1.1.0 && au_publish || return 1
    mkdir -p -- "$SANDBOX/handcli" && cp -R -- "$GSG_PROJECT/bin" "$GSG_PROJECT/lib" "$GSG_PROJECT/VERSION" "$SANDBOX/handcli/" || return 1
    # ^ why a CLI copy of its own, not the checkout; the owner fast-forwards the checkout and would replace the script this shell is still reading
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$SANDBOX/handcli/bin/git-secret-guard" update </dev/null
    assert_record failed install-failed "the stand-in installer ran"
    assert_eq "$(<"$SANDBOX/au-child.gcm")" never "GCM_INTERACTIVE=never reached the child install of a run that made no copy"
    assert_eq "$(find "$LC_STATE" -maxdepth 1 -name 'update-copy.*' | wc -l | tr -d ' ')" 0 "and it made no copy"
}

# ^ invariant an inherited GSG_UPDATE_COPY is not trusted; only a process running from its directory is the copy, and only it removes it
test_an_inherited_copy_variable_neither_skips_the_re_exec_nor_deletes_anything() {
    local decoy
    au_setup_with_release || return 1
    decoy="$LC_STATE/update-copy.BOGUS1"
    mkdir -p -- "$decoy" && printf 'keep\n' >"$decoy/file" && touch "$decoy" || return 1
    set_env GSG_UPDATE_COPY="$decoy"
    upd
    assert_rc 0 "update with a bogus GSG_UPDATE_COPY in the environment"
    assert_record updated "" "it still re-executed from a copy, so the share could be replaced"
    assert_file "$decoy/file" "the directory the variable names is untouched"
}

# ^ invariant a failed copy is a recorded outcome, not a log line the next run overwrites; failed with no reason is the record word for it
test_a_failed_copy_for_the_re_exec_is_recorded_as_a_failed_run() {
    local realcp
    au_setup_with_release || return 1
    realcp="$(type -P cp)" || return 1
    printf '#!/bin/sh\ncase "$*" in *update-copy*) echo "cp: injected failure" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$realcp" >"$SANDBOX/pathbin/cp" && chmod 755 "$SANDBOX/pathbin/cp" || return 1
    upd
    assert_rc 1 "a run that cannot make its copy is failed"
    assert_record failed "" "the record"
    assert_contains "$(rec detail)" "cannot copy" "names the cause"
    assert_eq "$(rec from)" 1.0.0 "and the installed version"
    assert_contains "$ERR" "update: failed" "update says so on stderr"
    assert_eq "$(find "$LC_STATE" -maxdepth 1 -name 'update-copy.*' | wc -l | tr -d ' ')" 0 "no half copy is left"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.0.0 "nothing was installed"
}

# ^ invariant an inherited MSYS_NO_PATHCONV=1 stops the path conversion native git relies on; update clears it, and the role stays owner
test_an_inherited_no_path_conversion_does_not_break_the_role_or_the_run() {
    au_setup_with_release || return 1
    set_env MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    upd
    assert_rc 0 "update with path conversion switched off in its environment"
    assert_eq "$(rec role)" owner "the role is owner, not a checkout git cannot find"
    assert_record updated "" "and the update goes through"
}

run_file_tests
