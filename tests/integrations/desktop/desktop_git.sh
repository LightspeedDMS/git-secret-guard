#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC2016
# ^ order sourced after tests/support/lib.sh and tests/support/lifecycle.sh; builds a Desktop fixture below $SANDBOX/root (GSG_GITUP_ROOT), runs product code
# ^ security Desktop's real bundled git is only executed (read-only) through a wrapper in the fixture; nothing under /usr, ~/.local or ~/.config is written

# ^ external GSG_TEST_DESKTOP_BUNDLE moves the place of Desktop's real git; a path with no git emulates a CI runner without Desktop (DG_OLD=0)
DG_REAL_BUNDLE="${GSG_TEST_DESKTOP_BUNDLE:-/usr/lib/github-desktop/resources/app/git}"
DG_REAL_GIT="$DG_REAL_BUNDLE/bin/git"
DG_LAUNCHER_FIXTURE="$GSG_PROJECT/tests/fixtures/desktop-git/github-desktop.desktop"

# ^ invariant the libraries the CLI loads for the Desktop feature, in the CLI's order
# shellcheck disable=SC2016
DG_PRELUDE='set -u; GSG_ROOT="$1"; shift
for lib in platform/brew core/common core/state install/tools install/hookspath platform/wsl install/install install/install_cmd install/install_tools gitup/gitup gitup/gitup_source integrations/desktop/desktop_git integrations/desktop/desktop_git_check integrations/desktop/desktop_git_report; do source "$GSG_ROOT/lib/$lib.sh" || exit 9; done
'

# ^ invariant dg_run BODY ARGS... runs BODY after the libraries load; the lifecycle env and PATH apply, HOME and XDG_* are the sandbox's
dg_run() {
    local body="$1"
    shift
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" bash -c "$DG_PRELUDE$body" _ "$GSG_PROJECT" "$@"
}

# ^ invariant dg_old_env DIR prints the environment Desktop gives its git (dugite's setupEnvironment) plus DIR as core.hooksPath, one NAME=VALUE per line
dg_old_env() {
    printf '%s\n' "GIT_EXEC_PATH=$DG_BUNDLE/libexec/git-core" "GIT_CONFIG_SYSTEM=$DG_BUNDLE/etc/gitconfig" \
        "GIT_TEMPLATE_DIR=$DG_BUNDLE/share/git-core/templates" "PREFIX=$DG_BUNDLE" "GIT_CONFIG_PARAMETERS=${DG_PARAMS_PREFIX:+$DG_PARAMS_PREFIX }'core.hooksPath=$1'"
}

# ^ security the dead proxy is extra isolation only; trufflehog runs --no-verification and a fake credential is a "match" with or without it
DG_DEAD_PROXY_URL=http://127.0.0.1:9

# ^ invariant dgit DIR ARGS... runs Desktop's git with Desktop's environment and DIR as core.hooksPath; stdout, stderr and the status are in OUT, ERR and RC
dgit() {
    local dir="$1" line
    local -a envs=()
    shift
    while IFS= read -r line; do envs+=("$line"); done < <(dg_old_env "$dir")
    run_cap ${DG_TIMEOUT:+timeout "$DG_TIMEOUT"} env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" HTTPS_PROXY="$DG_DEAD_PROXY_URL" HTTP_PROXY="$DG_DEAD_PROXY_URL" "${envs[@]}" "$DG_BUNDLE/bin/git" "$@"
}

# ^ invariant dg_count_begin = Desktop's git and a bash first on PATH log each start; git to $SANDBOX/dg.calls (arguments), bash to $SANDBOX/dg.bash (first arg)
# ^ invariant a hook wrapper started through "#!/usr/bin/env bash" logs its hook name; the loop of dg_checkouts logs -c; both logs start empty
# ^ why a counting shim, not a timer; time cannot tell one bash per hook run from two (wrapped over plain is about 3.7 by construction)
dg_count_begin() {
    local real_bash
    real_bash="$(env -i "${GSG_ENV[@]}" bash -c 'command -v bash')" || return 1
    [ -n "$real_bash" ] && [ -x "$real_bash" ] || return 1
    mkdir -p -- "$SANDBOX/countbin" || return 1
    printf '#!/bin/sh\nprintf "%%s\\n" "${1##*/}" >>"%s/dg.bash"\nexec '\''%s'\'' "$@"\n' "$SANDBOX" "$real_bash" >"$SANDBOX/countbin/bash" || return 1
    chmod 755 "$SANDBOX/countbin/bash" || return 1
    : >"$SANDBOX/dg.count" && : >"$SANDBOX/dg.calls" && : >"$SANDBOX/dg.bash"
}

# ^ invariant dg_checkouts DIR N runs N checkouts (b and main alternately, N even) in the cwd repository with Desktop's git and DIR as core.hooksPath
# ^ invariant one shell loop started through the counting bash of dg_count_begin; a hook's bash and git are found through the same PATH
dg_checkouts() {
    local dir="$1" n="$2" line
    local -a envs=()
    case "$n" in '' | *[!0-9]*) return 1 ;; esac
    [ "$n" -gt 0 ] && [ $((n % 2)) -eq 0 ] || return 1
    while IFS= read -r line; do envs+=("$line"); done < <(dg_old_env "$dir")
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "${envs[@]}" PATH="$SANDBOX/countbin:$REAL_HOME/.local/bin:$TEST_BASE_PATH" "$SANDBOX/countbin/bash" -c 'g="$1"; for _ in $(seq "$(($2 / 2))"); do "$g" checkout -q b && "$g" checkout -q main || exit 1; done' _ "$DG_BUNDLE/bin/git" "$n"
}

# ^ invariant dg_repo NAME makes a scratch repository with Desktop's git (no hooks) and leaves the cwd in it
dg_repo() {
    REPO="$SANDBOX/repos/$1"
    mkdir -p -- "$REPO" && cd -- "$REPO" || return 1
    dgit "$SANDBOX/no-hooks" init -q . || return 1
    dgit "$SANDBOX/no-hooks" config user.name t && dgit "$SANDBOX/no-hooks" config user.email t@example.invalid
}

# ^ invariant dg_stub_share = a share dir whose hook records its arguments in $SANDBOX/scan.log and exits with $SANDBOX/scan.rc; wrappers in $SANDBOX/dh2
dg_stub_share() {
    mkdir -p -- "$SANDBOX/fshare/hooks" "$SANDBOX/stubgit" || return 1
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/scan.log"\nexit "$(cat "%s/scan.rc")"\n' "$SANDBOX" "$SANDBOX" >"$SANDBOX/fshare/hooks/secret-scan" || return 1
    chmod 755 "$SANDBOX/fshare/hooks/secret-scan" && printf '0' >"$SANDBOX/scan.rc" && rm -f -- "$SANDBOX/scan.log" || return 1
    dg_run 'desktop_git_hooks_write "$1" "$2"' "$SANDBOX/fshare" "$SANDBOX/dh2"
}

# ^ invariant dg_stub_git TEXT = a git first on PATH; it answers --version with TEXT and rev-parse --git-path hooks/EVENT with $SANDBOX/nogit/EVENT
# ^ invariant the log is $SANDBOX/git.calls, one line per call; any other call fails
dg_stub_git() {
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/git.calls"\nprintf "%%s\\n" "${GIT_CONFIG_PARAMETERS-unset}" >>"%s/git.params"\ncase "$1" in\n  --version) printf "%%s\\n" "%s"; exit 0 ;;\n  rev-parse) printf "%%s/nogit/%%s\\n" "%s" "${3#hooks/}"; exit 0 ;;\nesac\nexit 1\n' \
        "$SANDBOX" "$SANDBOX" "$1" "$SANDBOX" >"$SANDBOX/stubgit/git" && chmod 755 "$SANDBOX/stubgit/git" && rm -f -- "$SANDBOX/git.calls" "$SANDBOX/git.params"
}

# ^ invariant dg_hook EVENT ARGS... runs the wrapper of $SANDBOX/dh2 under a clean environment whose PATH has the stub git first
dg_hook() {
    local hook="$1"
    local -a params=()
    shift
    if [ -n "${DG_PARAMS:-}" ]; then params=(GIT_CONFIG_PARAMETERS="$DG_PARAMS"); fi
    run_cap env -i PATH="$SANDBOX/stubgit:$TEST_BASE_PATH" HOME="$SANDBOX/home" "${params[@]}" "$SANDBOX/dh2/$hook" "$@"
}

# ^ invariant dg_repo_hook DIR EVENT writes DIR/EVENT, logging "EVENT args" (and stdin for pre-push) to $SANDBOX/chain.log and exiting with $SANDBOX/chain.rc
dg_repo_hook() {
    mkdir -p -- "$1" || return 1
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >>"%s/chain.log"\nif [ "%s" = pre-push ]; then cat >>"%s/chain.log"; fi\nexit "$(cat "%s/chain.rc" 2>/dev/null || echo 0)"\n' \
        "$2" "$SANDBOX" "$2" "$SANDBOX" "$SANDBOX" >"$1/$2" || return 1
    chmod 755 "$1/$2"
}

# ^ invariant dg_launch FILE OUT = GLib launches the .desktop file FILE for real (DesktopAppInfo.launch); a stub env first on PATH writes its arguments to OUT
# ^ why the stub is env itself, not a wrapper; the entry starts Desktop through env and env receives exactly the arguments GLib built
# ^ invariant the stub writes a temp file and renames it => the poller only ever sees a complete OUT
dg_launch() {
    mkdir -p -- "$SANDBOX/launchbin" || return 1
    printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\0" "$a"; done >"%s.tmp"\nmv -f -- "%s.tmp" "%s"\n' "$2" "$2" "$2" >"$SANDBOX/launchbin/env" || return 1
    chmod 755 "$SANDBOX/launchbin/env" && rm -f -- "$2" || return 1
    PATH="$SANDBOX/launchbin:$PATH" python3 -I -c '
import sys, time, os, gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio
try:
    gi.require_version("GioUnix", "2.0")
    from gi.repository import GioUnix
    DesktopAppInfo = GioUnix.DesktopAppInfo
except (ValueError, ImportError):
    DesktopAppInfo = Gio.DesktopAppInfo
POLL_TRIES, POLL_INTERVAL_S = 100, 0.05
app = DesktopAppInfo.new_from_filename(sys.argv[1])
if app is None:
    sys.exit("not a valid desktop entry: " + sys.argv[1])
if not app.launch([], None):
    sys.exit("GLib could not launch " + sys.argv[1])
for _ in range(POLL_TRIES):
    if os.path.exists(sys.argv[2]):
        sys.exit(0)
    time.sleep(POLL_INTERVAL_S)
sys.exit("the launched program never wrote " + sys.argv[2])
' "$1" "$2"
}

# ^ invariant dg_install_begin = a lifecycle sandbox with the real scanners seeded (install adopts them at the pin), a dead proxy and the Desktop fixture
# ^ invariant the test skips without Desktop's real old git unless it sets DG_NO_DESKTOP_GIT_OK=1 (a refusal or file test); a value other than 1 skips
# ^ why a skip, not a stand-in git; on macOS CI the check's fake token passed in 6 of 16 link tests with git 2.56 as Desktop's git, cause not found
dg_install_begin() {
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    [ -x "$REAL_BETTERLEAKS" ] || skip_test "betterleaks not found at $REAL_BETTERLEAKS"
    lc_begin && lc_seed_real_tools && dg_fixture || return 1
    if [ "${DG_NO_DESKTOP_GIT_OK:-}" != 1 ]; then dg_need_old_git; fi
    set_env HTTPS_PROXY="$DG_DEAD_PROXY_URL" HTTP_PROXY="$DG_DEAD_PROXY_URL" https_proxy="$DG_DEAD_PROXY_URL" http_proxy="$DG_DEAD_PROXY_URL"
    DG_HOOKS="$LC_DATA/desktop-hooks"
}

# ^ invariant dg_snapshot prints path, size and modification time (nanoseconds) of every file of the Desktop link, sorted; equal output = nothing was rewritten
dg_snapshot() {
    { find "$DG_HOOKS" -type f -printf '%p %s %T@\n' 2>/dev/null; find "$DG_LAUNCHER_USER" -type f -printf '%p %s %T@\n' 2>/dev/null; } | LC_ALL=C sort
}

# ^ invariant dg_nothing_changed = a refused install left no share dir, state file, hook config or hooks directory (the sandbox starts without any)
dg_nothing_changed() {
    assert_no_file "$LC_DATA" "no share dir"
    assert_no_file "$LC_STATE/state" "no state file"
    assert_eq "$(gitx config --global --get-all hook.git-secret-guard.event | wc -l)" 0 "no hook config"
    assert_no_file "$DG_HOOKS" "no hooks directory"
}

# ^ invariant dg_foreign_launcher_kept CMD... = a launcher of the user's own is in place; CMD (a git-secret-guard command) succeeds, names it and keeps it
dg_foreign_launcher_kept() {
    printf 'mine\n' >"$DG_LAUNCHER_USER" || return 1
    gsg "$@"
    assert_rc 0 "$* with a launcher that became the user's"
    assert_contains "$ERR" "$DG_LAUNCHER_USER was not written by git-secret-guard; left in place" "names it"
    assert_eq "$(<"$DG_LAUNCHER_USER")" mine "and keeps it"
}

# ^ invariant dg_expect_mismatch REASON COMMAND = status exits 1 and prints the Desktop line with MISMATCH, REASON and the command to run
dg_expect_mismatch() {
    gsg status
    assert_rc 1 "status with a stale Desktop link ($1)"
    assert_contains "$OUT" "GitHub Desktop: MISMATCH $1; run: git-secret-guard $2" "the mismatch is named, with the fix"
}

# ^ invariant dg_repair = a plain install exits 0 and status shows a current link afterwards
dg_repair() {
    gsg install </dev/null
    assert_rc 0 "a plain install repairs it ($ERR)"
    gsg status
    assert_rc 0 "status after the repair"
    assert_contains "$OUT" "GitHub Desktop: linked" "the link is current again"
}

# ^ invariant dg_need_old_git = skips the test unless the fixture runs Desktop's real old git (DG_OLD=1); call it after dg_fixture
# ^ why a skip, not a pass; the git under test honours config hooks and the wrapper skips its scan for it; a "git 2.45" test would prove nothing
dg_need_old_git() {
    [ "$DG_OLD" -eq 1 ] || skip_test "needs GitHub Desktop's own old git; a git of 2.54 or newer is no stand-in for it"
}

# ^ invariant dg_fixture builds Desktop's directory layout (names of the real one, tiny stand-ins) and the system launcher entry under GSG_GITUP_ROOT
# ^ invariant bin/git and libexec/git-core/git run Desktop's real git 2.45.3 when it is here (DG_OLD=1), else the git under test (DG_OLD=0, config hooks work)
dg_fixture() {
    local g real="$GIT"
    DG_ROOT="$SANDBOX/root"
    DG_BUNDLE="$DG_ROOT/usr/lib/github-desktop/resources/app/git"
    DG_LAUNCHER_USER="$SANDBOX/xdg/data/applications/github-desktop.desktop"
    DG_LAUNCHER_SYS="$DG_ROOT/usr/share/applications/github-desktop.desktop"
    rm -rf -- "$DG_ROOT" || return 1
    mkdir -p -- "$DG_BUNDLE/bin" "$DG_BUNDLE/etc" "$DG_BUNDLE/libexec/git-core" "$DG_BUNDLE/share/git-core/templates/hooks" "$DG_ROOT/usr/share/applications" || return 1
    DG_OLD=0
    if [ -x "$DG_REAL_GIT" ]; then
        real="$DG_REAL_GIT"
        DG_OLD=1
    fi
    DG_VER="$("$real" --version | sed -n 's/^git version \([0-9][0-9.]*\).*/\1/p')"
    [ -n "$DG_VER" ] || return 1
    for g in "$DG_BUNDLE/bin/git" "$DG_BUNDLE/libexec/git-core/git"; do
        # ^ invariant with $SANDBOX/dg.stall present a commit marks dg.stalled and sleeps, for a test to signal the run in the middle of the check
        # ^ invariant with $SANDBOX/dg.count present each call logs its arguments as a line in $SANDBOX/dg.calls; a hook's git is the libexec one
        printf '#!/bin/sh\nif [ -f "%s/dg.count" ]; then printf "%%s\\n" "$*" >>"%s/dg.calls"; fi\ncase " $* " in *" commit "*) if [ -f "%s/dg.stall" ]; then : >"%s/dg.stalled"; exec sleep 120; fi ;; esac\nexec '\''%s'\'' "$@"\n' "$SANDBOX" "$SANDBOX" "$SANDBOX" "$SANDBOX" "$real" >"$g" || return 1
        chmod 755 "$g" || return 1
    done
    printf '#!/bin/sh\nexit 0\n' >"$DG_BUNDLE/bin/scalar" && chmod 755 "$DG_BUNDLE/bin/scalar" || return 1
    printf '[include]\n  path=/etc/gitconfig\n' >"$DG_BUNDLE/etc/gitconfig" || return 1
    cp -- "$DG_LAUNCHER_FIXTURE" "$DG_LAUNCHER_SYS" || return 1
    set_env GSG_GITUP_ROOT="$DG_ROOT"
}
