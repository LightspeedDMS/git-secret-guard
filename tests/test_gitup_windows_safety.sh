#!/usr/bin/env bash
# shellcheck source=tests/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup_windows.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup_windows.sh"

# ^ coupled the safety nets of the #30 tests live here (path guards, never-start guards, certificate hygiene); tests/test_gitup_windows.sh holds the behaviour
# ^ invariant the entries at the root of the file system when this file was loaded (on Git Bash the Git for Windows install); the last test compares them
WU_ROOT_NAMES="$(wu_names /)"

wu_store_counts() {
    "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -Command '
        $s = "CN=GSG Test Signer"
        $n = 0
        foreach ($st in "My", "CA", "Root", "TrustedPublisher") { $n += @(Get-ChildItem "Cert:\CurrentUser\$st" | Where-Object { $_.Subject -eq $s }).Count }
        "certs=$n keys=" + @(Get-ChildItem "$env:APPDATA\Microsoft\Crypto\Keys" -Force).Count' | tr -d '\r'
}

test_building_the_signed_stand_in_leaves_no_certificate_and_no_key_behind() {
    wu_need_windows_runner
    wu_with_cert_lock stand_in_build_check
}

# ^ invariant runs under wu_with_cert_lock; no other test file writes the certificate store or the key directory during the counts and the cache move
stand_in_build_check() {
    local cache before after key
    cache="$(wu_standin_cache)" || return 1
    wu_build_standin_unlocked || return 1
    before="$(wu_store_counts)"
    mv -- "$cache" "$cache.aside" || return 1
    rm -f -- "$SANDBOX/standin/key.name" || return 1
    wu_build_standin_unlocked
    after="$(wu_store_counts)"
    rm -f -- "$cache.aside"/standin.exe "$cache.aside"/standin-unsigned.exe
    rmdir -- "$cache.aside"
    assert_file "$cache/standin.exe" "the stand-in was built again"
    key="$(<"$SANDBOX/standin/key.name")" || return 1
    [ -n "$key" ] || fail "the build recorded no file name for its own key" || return 1
    assert_eq "$(wu_key_files_named "$key")" 0 "the key file of the stand-in is gone; the Keys directory is shared with other processes, so it is not counted as a whole"
    assert_eq "${after%% keys=*}" "${before%% keys=*}" "the user's stores hold the same certificates as before"
    assert_contains "$before" "certs=0" "and none of ours"
}

test_the_certificate_lock_admits_one_holder_and_clears_a_dead_holders_lock() {
    local dead
    WU_CERT_LOCK="$SANDBOX/cert-lock"
    wu_with_cert_lock test -d "$WU_CERT_LOCK" || fail "the lock directory exists while the command runs" || return 1
    assert_no_file "$WU_CERT_LOCK" "the lock is released when the command ends"
    if wu_with_cert_lock false; then fail "the status of the command is passed on"; return 1; fi
    assert_no_file "$WU_CERT_LOCK" "and released when the command fails"
    mkdir -- "$WU_CERT_LOCK" && printf '%s\n' "$$" >"$WU_CERT_LOCK/pid" || return 1
    if WU_CERT_LOCK_WAIT=1 wu_with_cert_lock true; then fail "a live holder's lock was taken over"; return 1; fi
    assert_file "$WU_CERT_LOCK/pid" "a refused run leaves the live holder's lock alone"
    true &
    dead=$!
    wait "$dead"
    printf '%s\n' "$dead" >"$WU_CERT_LOCK/pid" || return 1
    wu_with_cert_lock true || fail "a dead holder's lock was not taken over" || return 1
    assert_no_file "$WU_CERT_LOCK" "taken over and released"
}

test_the_certificate_sweep_removes_what_an_aborted_build_leaves() {
    if [ "$TEST_IS_WINDOWS" -ne 1 ]; then skip_test "uses the Windows certificate stores"; fi
    wu_with_cert_lock sweep_check
}

# ^ invariant runs under wu_with_cert_lock; a build in another test file would show as a certificate or key in the first count
sweep_check() {
    local before planted after
    before="$(wu_store_counts)"
    wu_plant_signer_cert
    planted="$(wu_store_counts)"
    wu_sweep_signer_certs
    after="$(wu_store_counts)"
    "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -Command '
        foreach ($st in "My", "CA") { foreach ($x in @(Get-ChildItem "Cert:\CurrentUser\$st" | Where-Object { $_.Subject -eq "CN=GSG Test Signer" })) { Remove-Item -LiteralPath ("Cert:\CurrentUser\$st\" + $x.Thumbprint) -DeleteKey -Force } }'
    assert_not_contains "$planted" "certs=0" "the planted certificate is in the stores"
    assert_eq "$after" "$before" "the sweep removed the planted certificates and the key file"
}

test_the_tools_cache_check_wants_the_installer_named_by_the_lock_not_any_installer() {
    local d="$SANDBOX/cache-check" t
    if [ "$TEST_IS_WINDOWS" -ne 1 ]; then skip_test "the check lists the Windows tool set"; fi
    mkdir -p -- "$d" || return 1
    for t in jq trufflehog betterleaks; do printf '#!/bin/sh\n' >"$d/$t.exe" && chmod 755 "$d/$t.exe" || return 1; done
    : >"$d/Git-2.55.0.1-64-bit.exe"
    run_cap bash "$GSG_PROJECT/tests/fetch-test-tools.sh" --check "$d"
    assert_rc 3 "an older installer in the cache does not satisfy the pin"
    assert_contains "$OUT$ERR" "Git-2.56.0.4-64-bit.exe" "the missing pinned file is named"
    : >"$d/Git-2.56.0.4-64-bit.exe"
    run_cap bash "$GSG_PROJECT/tests/fetch-test-tools.sh" --check "$d"
    assert_rc 0 "the pinned name satisfies it"
}

test_the_start_path_denylist_accepts_the_runner_and_refuses_known_extra_ways_to_start_a_program() {
    local f="$SANDBOX/guard.ps1" line
    wu_runner_starts_only_through_the_shadowed_calls "$GSG_PROJECT/bin/gsg-gitup.ps1" || fail "the product runner passes its own guard"
    for line in 'Microsoft.PowerShell.Management\Start-Process @params' '[System.Diagnostics.Process]::Start($path)' '& $path /VERYSILENT' 'Invoke-Item $path' 'Start-Process -FilePath x'; do
        cp -- "$GSG_PROJECT/bin/gsg-gitup.ps1" "$f" || return 1
        printf '%s\n' "$line" >>"$f"
        if wu_runner_starts_only_through_the_shadowed_calls "$f"; then fail "the guard accepted an extra start path: $line"; fi
    done
}

test_the_shadow_wrapper_fails_closed_for_an_unknown_mode_and_for_a_never_start_test() {
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    wu_runner_shadow bogus "$WU_STATE_HANDOFF"
    assert_rc 15 "an unknown mode ends in a start failure, not in a real start"
    assert_contains "$ERR" "unknown shadow mode bogus" "and names the mode"
    assert_eq "$(wu_installer_log)" "" "nothing ran"
    wu_prepare_handoff machine || return 1
    wu_shadow_script
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" GSG_TEST_NEVER_START=1 GSG_TEST_VERBLOG="$(cygpath -w "$WU_DIR/verbs.log")" GSG_TEST_RUNNER="$(cygpath -w "$WU_RT/bin/gsg-gitup.ps1")" \
        GSG_TEST_HANDOFF="$(cygpath -w "$WU_STATE_HANDOFF")" "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$WU_DIR/shadow.ps1")" ok
    assert_rc 15 "mode ok under the never-start switch is refused inside the wrapper too"
    assert_eq "$(wu_installer_log)" "" "nothing ran"
}

test_a_broken_shadow_cannot_start_the_stand_in_when_execute_is_denied() {
    local inst pin standin_sha standin_size
    wu_need_windows_runner
    wu_prepare_handoff machine || return 1
    inst="$WU_HANDOFF_DIR/Git-2.56.0.4-64-bit.exe"
    standin_sha="$(sha256sum -- "$SANDBOX/standin/standin.exe" | cut -d' ' -f1)"
    standin_size="$(stat -c %s -- "$SANDBOX/standin/standin.exe")"
    pin="$(awk '$1 == "git-for-windows" && $3 == "windows_amd64" { print $4 }' "$GSG_PROJECT/tools.lock")"
    assert_eq "$(sha256sum -- "$inst" | cut -d' ' -f1)" "$standin_sha" "the file under test is the stand-in" || return 1
    assert_eq "$(stat -c %s -- "$inst")" "$standin_size" "with the size of the stand-in" || return 1
    [ "$standin_sha" != "$pin" ] || { fail "the stand-in must never be the real asset"; return 1; }
    [ "$standin_size" -lt 1000000 ] || { fail "the stand-in is far smaller than the real asset"; return 1; }
    wu_runner_broken "$WU_STATE_HANDOFF"
    assert_eq "$(wu_installer_log)" "/VERYSILENT /NORESTART /NOCANCEL /SP-" "without the deny a broken shadow lets the stand-in start, which is the danger"
    rm -f -- "$WU_DIR/standin/installer.log"
    wu_prepare_handoff machine || return 1
    wu_deny_execute "$inst" || return 1
    wu_runner_broken "$WU_STATE_HANDOFF"
    assert_rc 15 "with execute denied the start fails"
    assert_eq "$(wu_installer_log)" "" "and nothing started"
    wu_allow_execute "$inst"
}

test_the_path_helpers_refuse_an_empty_or_outside_path_and_create_nothing() {
    local before after
    before="$(wu_names /)"
    WU_DIR=""
    if wu_sandbox_path "$WU_DIR/top" 2>/dev/null; then fail "an empty WU_DIR gave an accepted path"; fi
    if wu_sandbox_path "/tmp/outside" 2>/dev/null; then fail "a path outside the sandbox was accepted"; fi
    if wu_sandbox_path "$SANDBOX/a/../../outside" 2>/dev/null; then fail "a .. path was accepted"; fi
    wu_sandbox_path "$SANDBOX/inside/x" || fail "a path in the sandbox was refused"
    if wu_mklink "$WU_DIR/greal" "$WU_DIR/top" 2>/dev/null; then fail "wu_mklink accepted empty paths"; fi
    after="$(wu_names /)"
    assert_eq "$after" "$before" "nothing was created at the root"
}

test_the_stray_file_check_sees_a_new_entry_in_a_directory() {
    local d="$SANDBOX/names" before
    wu_sandbox_path "$d" || return 1
    mkdir -p -- "$d" && : >"$d/a" || return 1
    before="$(wu_names "$d")"
    : >"$d/stray" || return 1
    [ "$(wu_names "$d")" != "$before" ] || fail "a new entry went unseen"
}

test_zz_nothing_was_created_at_the_root_of_the_file_system() {
    assert_eq "$(wu_names /)" "$WU_ROOT_NAMES" "no test of this file created an entry at the root (on Git Bash the Git for Windows install)"
}

run_file_tests
