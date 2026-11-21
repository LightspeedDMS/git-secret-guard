#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2034
# ^ order sourced after tests/support/lib.sh and tests/support/lifecycle.sh by the update tests; real git, a local bare origin, real tags

DEAD_PROXY=(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9)
HOLDER_SECONDS=300
# ^ coupled lib/autoupdate/autoupdate.sh cuts the detail of the record at this many characters, the cut mark included
DETAIL_MAX=160
# ^ coupled lib/autoupdate/autoupdate.sh:GSG_UPDATE_LOCK_MAX_AGE_MIN is 120 minutes; a lock this old is past it, whatever its holder
STALE_LOCK_AGE='3 hours ago'
# ^ invariant the bound on the child shell of the let-in test; it only takes and releases a lock
CHILD_TIMEOUT_SECONDS=20
# ^ invariant the stderr line of the refusing stand-in installer; the record's detail must carry it
REFUSAL='install refused by the test'
AU_SRC="" AU_ORIGIN="" AU_CO=""

# ^ invariant the libraries one update cycle needs, loaded in a clean shell from the tree given as $1 (the project, or the installed copy)
AU_PRELUDE='set -u; GSG_ROOT="$1"; shift
for lib in platform/brew core/common core/state install/tools install/hookspath install/install gitup/gitup inspect/doctor_findings autoupdate/autoupdate platform/winupdate; do source "$GSG_ROOT/lib/$lib.sh" || exit 9; done
'
AU_TAKE='paths_init || exit 9; autoupdate_lock_take; echo "take=$? link=$(readlink -- "$GSG_UPDATE_LOCK" 2>/dev/null) pid=$$"'

# ^ invariant au_lib ROOT BODY ARGS... runs BODY after the libraries of ROOT load, with the lifecycle env and no terminal on stdin
au_lib() {
    local root="$1" body="$2"
    shift 2
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" bash -c "$AU_PRELUDE$body" _ "$root" "$@" </dev/null
}

# ^ invariant upd runs one cycle as the timer's service does, the CLI of the installed copy with the lifecycle env and no terminal on stdin
upd() { run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$LC_DATA/bin/git-secret-guard" update </dev/null; }

# ^ why a role override plus git's own ownership knob, not a second user; run.sh has one user, real ownership is driven in the container (tests/platform)
# ^ why the libraries of the installed copy, not its CLI; the override of autoupdate_role needs a shell, the CLI offers no way to set the role
# ^ invariant with GIT_TEST_ASSUME_DIFFERENT_OWNER=1 every git call on the checkout fails unless it carries the follower's safe.directory
upd_follower() {
    set_env GIT_TEST_ASSUME_DIFFERENT_OWNER=1
    au_lib "$LC_DATA" 'autoupdate_role() { if [ -d "$1/.git" ]; then printf "follower\n"; else return 1; fi; }; autoupdate_run; exit'
    unset 'EXTRA_ENV[-1]'
}

au_state() {
    local out
    out="$(awk -F= -v k="$1" -v v="$2" '$1 == k { print k "=" v; done = 1; next } { print } END { if (!done) print k "=" v }' "$LC_STATE/state")" || return 1
    printf '%s\n' "$out" >"$LC_STATE/state"
}

rec() {
    [ -f "$LC_STATE/update" ] || return 1
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$LC_STATE/update"
}

assert_record() { assert_eq "$(rec result)/$(rec reason)" "$1/$2" "$3"; }

au_release() {
    printf '%s\n' "$1" >"$AU_SRC/VERSION" || return 1
    gitx -C "$AU_SRC" add -A || return 1
    gitx -C "$AU_SRC" commit -q --no-verify -m "release $1" || return 1
    gitx -C "$AU_SRC" tag -a "v$1" -m "v$1"
}

au_publish() { gitx -C "$AU_SRC" push -q origin main --tags; }

au_commit() { gitx -C "$1" add -A && gitx -C "$1" commit -q --no-verify -m "$2"; }

au_clone() {
    rm -rf -- "$SANDBOX/au-extra-$1" || return 1
    gitx clone -q "${@:2}" "$(lc_file_url "$AU_ORIGIN")" "$SANDBOX/au-extra-$1"
}

# ^ invariant AU_TEMPLATE=1 in a file makes the first au_setup build and every later one restore a fresh copy of what it built
# ^ why a copy on disk, not shell state; each test runs in its own subshell and only files outlast it
# ^ why the same paths, not another place; state, settings and git configs record absolute paths and SANDBOX is fixed for the file
AU_TEMPLATE=0
AU_TEMPLATE_ITEMS=(home xdg gitconfig fixtures au-src au-origin.git au-checkout)

au_template_save() {
    local tpl="$SANDBOX/au-template" item
    rm -rf -- "${tpl:?}" "${tpl:?}.part" && mkdir -p -- "$tpl.part" || return 1
    for item in "${AU_TEMPLATE_ITEMS[@]}"; do cp -a -- "$SANDBOX/$item" "$tpl.part/" || return 1; done
    mv -- "$tpl.part" "$tpl"
}

# ^ invariant sets what the build sets; AU_SRC, AU_ORIGIN, AU_CO, the lifecycle variables and the fixture environment, no leftover of an earlier test
au_template_restore() {
    local tpl="$SANDBOX/au-template" item
    lc_begin || return 1
    rm -rf -- "$SANDBOX"/au-extra-* "$SANDBOX"/au-child.* || return 1
    for item in "${AU_TEMPLATE_ITEMS[@]}"; do
        rm -rf -- "${SANDBOX:?}/$item" && cp -a -- "$tpl/$item" "$SANDBOX/" || return 1
    done
    lc_use_fixtures
}

# ^ invariant au_setup [real] leaves version 1.0.0 installed from the checkout, auto_update=yes and the checkout recorded; origin holds v1.0.0 only
# ^ why the state keys are set here, not by install --auto-update; these tests are about update, the flag and the units have their own file
# ^ invariant real never takes part in the copy; its tools and its proxy are its own
au_setup() {
    local mode="${1:-fixtures}" item
    AU_SRC="$SANDBOX/au-src" AU_ORIGIN="$SANDBOX/au-origin.git" AU_CO="$SANDBOX/au-checkout"
    if [ "$mode" != real ] && [ "$AU_TEMPLATE" = 1 ] && [ -d "$SANDBOX/au-template" ]; then
        au_template_restore
        return
    fi
    lc_begin || return 1
    if [ "$mode" = real ]; then
        lc_seed_real_tools || return 1
        set_env "${DEAD_PROXY[@]}"
    else
        lc_make_fixtures && lc_use_fixtures || return 1
    fi
    rm -rf -- "$AU_SRC" "$AU_ORIGIN" "$AU_CO" "$SANDBOX"/au-extra-* "$SANDBOX"/au-child.* || return 1
    gitx init -q "$AU_SRC" || return 1
    for item in bin lib hooks tools.lock VERSION; do cp -a -- "$GSG_PROJECT/$item" "$AU_SRC/" || return 1; done
    au_release 1.0.0 || return 1
    gitx clone -q --bare "$AU_SRC" "$AU_ORIGIN" || return 1
    gitx -C "$AU_SRC" remote add origin "$AU_ORIGIN" || return 1
    gitx clone -q "$(lc_file_url "$AU_ORIGIN")" "$AU_CO" || return 1
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$AU_CO/bin/git-secret-guard" install </dev/null
    assert_rc 0 "setup: install 1.0.0 from the checkout" || return 1
    au_state auto_update yes && au_state source_checkout "$AU_CO" || return 1
    if [ "$mode" != real ] && [ "$AU_TEMPLATE" = 1 ]; then au_template_save; fi
}

# ^ invariant the setup of the skip tests; release 1.1.0 waits on origin => only the obstacle of each case keeps update from installing it
au_setup_with_release() { au_setup && au_release 1.1.0 && au_publish; }

# ^ invariant the follower's starting point; the owner already moved the checkout to v1.1.0, the follower's own copy is still 1.0.0
au_setup_follower_at_release() {
    au_setup_with_release || return 1
    gitx -C "$AU_CO" fetch -q origin && gitx -C "$AU_CO" merge -q --ff-only 'refs/tags/v1.1.0^{commit}'
}

# ^ invariant prints every installed file with its hash and the state file after them; equal output = the installed copy and the state are unchanged
au_share_state() {
    (cd -- "$LC_DATA" && find . -type f -exec sha256sum {} + | LC_ALL=C sort) || return 1
    cat -- "$LC_STATE/state"
}

# ^ invariant one hash over au_share_state and the refs, HEAD and status of checkout $1; equal hashes = nothing of these changed
au_snapshot() {
    {
        au_share_state
        gitx -C "$1" rev-parse HEAD 2>&1
        gitx -C "$1" status --porcelain 2>&1
        gitx -C "$1" for-each-ref 2>&1
    } | sha256sum
}

# ^ invariant au_run_unchanged LABEL CHECKOUT RC removes the record, runs update once and expects exit RC with share, state and CHECKOUT unchanged
au_run_unchanged() {
    local label="$1" snap="$2" want="$3" before
    before="$(au_snapshot "$snap")"
    rm -f -- "$LC_STATE/update" || return 1
    upd
    assert_rc "$want" "$label: exit $want"
    assert_eq "$(au_snapshot "$snap")" "$before" "$label: the share, the state file and the checkout are unchanged"
}

# ^ invariant au_skip_case REASON CHECKOUT [SNAPSHOT_DIR] runs update against CHECKOUT and expects exit 0, the record with REASON and nothing changed
au_skip_case() {
    local reason="$1" co="$2" snap="${3:-$2}"
    au_state source_checkout "$co" || return 1
    au_run_unchanged "$reason" "$snap" 0
    assert_record skipped "$reason" "$reason: the record"
    assert_no_file "$LC_STATE/update.lock" "$reason: the lock is released"
}

# ^ invariant the control of a skip test; with the obstacles removed the same update installs 1.1.0 => the skips before it were not vacuous
au_control() {
    au_state source_checkout "$AU_CO" || return 1
    upd
    assert_rc 0 "control: with every obstacle removed the same update goes through"
    assert_record updated "" "control: updated"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.1.0 "control: installed"
}

au_leftovers() { find "$LC_STATE" -maxdepth 1 \( -name 'update-work.*' -o -name 'update-tmp.*' \) | wc -l | tr -d ' '; }

stop_holder() {
    kill "$1" 2>/dev/null
    wait "$1" 2>/dev/null
    return 0
}

# ^ invariant the stand-in installer of a broken release records its arguments, the bytes on its stdin and the inherited lock pid; it ends by running $1
au_broken_installer() {
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >"%s"\nwc -c >"%s"\nprintf "%%s\\n" "$GSG_UPDATE_LOCK_PID" >"%s"\n%s\n' \
        "$SANDBOX/au-child.args" "$SANDBOX/au-child.stdin" "$SANDBOX/au-child.lockpid" "$1" >"$AU_SRC/bin/git-secret-guard"
}

# ^ external GNU timeout exits with this status when the limit ended the command
TIMEOUT_EXPIRED_RC=124

# ^ invariant au_timeout_standin WORD ACTION makes the installed settings name a timeout logging every call and passing it on to the real timeout
# ^ invariant for a call with the argument WORD cut leaves a limit of one second, expire ends it at once as a limit run out; log treats no call apart
# ^ why through the settings, not PATH; update takes TIMEOUT_BIN from the settings file of the installed copy only, a later line of the file wins
au_timeout_standin() {
    local act
    case "$2" in
        cut) act="shift 3; exec $TEST_TIMEOUT -k 1 1 \"\$@\"" ;;
        expire) act="exit $TIMEOUT_EXPIRED_RC" ;;
        log) act=: ;;
        *)
            printf 'au_timeout_standin: unknown action [%s]\n' "$2" >&2
            return 1
            ;;
    esac
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\ncase " $* " in *" %s "*) %s ;; esac\nexec %s "$@"\n' \
        "$SANDBOX/au-timeout.log" "$1" "$act" "$TEST_TIMEOUT" >"$SANDBOX/au-timeout" || return 1
    chmod 755 "$SANDBOX/au-timeout" || return 1
    : >"$SANDBOX/au-timeout.log" || return 1
    printf 'TIMEOUT_BIN=%q\n' "$SANDBOX/au-timeout" >>"$LC_DATA/settings"
}
