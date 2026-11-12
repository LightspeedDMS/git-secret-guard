#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2034
# ^ order sourced after tests/lib.sh, tests/lifecycle.sh, tests/gitup.sh and tests/gitup_macos.sh;
# ^ coupled the SmartGit flows run against a fake bundle and fake settings
# ^ security HOME, the install dirs and every tool are in the sandbox => no test touches a real SmartGit settings dir or runs a real flatpak, brew or pgrep

SG_APPS="" SG_APP="" SG_SETTINGS="" SG_PREFS="" SG_BACKUPS=""
SG_FIXTURE="$GSG_PROJECT/tests/fixtures/smartgit/macos-26.1/preferences.yml"
SG_DEAD_PROXY=http://127.0.0.1:9
# ^ invariant a full install runs before the stalled move; the helper waits 900 ticks of GU_POLL_INTERVAL and the stand-in outlives the wait
SG_STALL_WAIT_TICKS=900
SG_MV_STALL_SECONDS=180

# ^ invariant sg_make_app DIR VERSION GITVER LFSVER builds a bundle with Info.plist and a bundled git and git-lfs answering --version and version
sg_make_app() {
    local app="$1" ver="$2" gitver="$3" lfsver="$4"
    mkdir -p -- "$app/Contents/MacOS" "$app/Contents/Resources/git/bin" || return 1
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="0.9">\n\t<dict>\n\t\t<key>CFBundleShortVersionString</key>\n\t\t<string>%s</string>\n\t\t<key>CFBundleIdentifier</key>\n\t\t<string>com.syntevo.smartgit</string>\n\t</dict>\n</plist>\n' "$ver" >"$app/Contents/Info.plist" || return 1
    gm_stub "$app/Contents/MacOS/SmartGit" 'exit 0' || return 1
    gm_stub "$app/Contents/Resources/git/bin/git" "if [ \"\$1\" = --version ]; then echo \"git version $gitver\"; exit 0; fi
exec $GIT \"\$@\"" || return 1
    gm_stub "$app/Contents/Resources/git/bin/git-lfs" "echo \"git-lfs/$lfsver (GitHub; test)\"" || return 1
}

# ^ invariant sg_make_prefs DEST APP copies the sanitised 26.1 fixture and points its absolute bundled-git line into the sandbox bundle;
# ^ invariant mode 0600 like SmartGit's own
sg_make_prefs() {
    local dest="$1" app="$2" text
    mkdir -p -- "${dest%/*}" || return 1
    text="$(cat -- "$SG_FIXTURE" && printf x)" || return 1
    text="${text%x}"
    printf '%s' "${text//\/Applications\/SmartGit.app/$app}" >"$dest" || return 1
    chmod 600 "$dest" || return 1
}

# ^ invariant pgrep answers 0 (running) if smartgit.running exists or its call count passes smartgit.running.after; flatpak ps follows the file only
# ^ invariant flatpak knobs = flatpak.installed, flatpak.version (info), flatpak.ps (listed instances), flatpak.override.user and .system (override),
# ^ invariant flatpak.override.fail, flatpak.run.fail, flatpak.nospawn (no flatpak-spawn inside the sandbox), flatpak.nostale (a run leaves no stale instance)
sg_standins() {
    gm_stub "$SANDBOX/pathbin/pgrep" 'd="$(cd "${0%/*}/.." && pwd -P)"; printf "%s\n" "pgrep $*" >>"$d/smartgit.log"
n=0; if [ -f "$d/pgrep.count" ]; then n="$(cat "$d/pgrep.count")"; fi; n=$((n + 1)); echo "$n" >"$d/pgrep.count"
if [ -f "$d/smartgit.running.after" ] && [ "$n" -gt "$(cat "$d/smartgit.running.after")" ]; then exit 0; fi
[ -f "$d/smartgit.running" ]' || return 1
    gm_stub "$SANDBOX/pathbin/flatpak" 'd="$(cd "${0%/*}/.." && pwd -P)"; printf "%s\n" "flatpak $*" >>"$d/smartgit.log"
# a run leaves a listed instance whose pid is already gone, as the real flatpak does for about ten seconds
stale() { if [ ! -f "$d/flatpak.nostale" ]; then printf "%s\t%s\n" "$(sh -c "echo \$\$")" com.syntevo.SmartGit >>"$d/flatpak.ps"; fi; }
# the stall knob of the mv stand-in also stops an override call whose arguments hold its text
stall() {
    if [ -f "$d/mv.stall" ]; then
        case " $* " in
            *"$(cat "$d/mv.stall")"*) : >"$d/mv.stalled"; exec sleep 180 ;;
        esac
    fi
}
case "$1" in
    info) [ -f "$d/flatpak.installed" ] || { echo "error: com.syntevo.SmartGit not installed" >&2; exit 1; }
          v=26_1_057; if [ -f "$d/flatpak.version" ]; then v="$(cat "$d/flatpak.version")"; fi
          printf "SmartGit - Use Git the Smart Way\n\n            ID: com.syntevo.SmartGit\n       Version: %s\n   Installation: system\n" "$v" ;;
    ps) if [ -f "$d/flatpak.ps" ]; then cat "$d/flatpak.ps"; fi; exit 0 ;;
    run)
        [ ! -f "$d/flatpak.run.fail" ] || { echo "error: flatpak run fails on request" >&2; exit 1; }
        cwd=""
        case "$2" in --cwd=*) cwd="${2#--cwd=}"; shift ;; esac
        cmd="${2#--command=}"; shift 3; stale
        if [ -n "$cwd" ]; then cd "$cwd" || { echo "error: --cwd $cwd does not exist" >&2; exit 1; }; fi
        if [ "$cmd" = sh ] && [ "$1" = -c ]; then
            case "$2" in *flatpak-spawn*) [ ! -f "$d/flatpak.nospawn" ] || exit 1 ;; esac
            exec sh -c "$2"
        fi
        if [ "$cmd" = /app/git/bin/git ] && [ "$1" = --version ]; then echo "git version 2.53.0.dirty"; exit 0; fi
        exec "$cmd" "$@" ;;
    override)
        scope="" talk="" mode=set
        for a in "$@"; do
            case "$a" in --user) scope=user ;; --system) scope=system ;; --talk-name=*) talk="${a#--talk-name=}" ;; --show) mode=show ;; --reset) mode=reset ;; esac
        done
        f="$d/flatpak.override.$scope"
        [ -n "$scope" ] || { echo "error: the flatpak stand-in wants an explicit scope [$*]" >&2; exit 1; }
        case "$mode" in
            show) if [ -f "$f" ]; then cat "$f"; fi ;;
            reset) stall "$@"; [ "$scope" = user ] || exit 1; rm -f "$f" ;;
            set) stall "$@"; [ "$scope" = user ] || exit 1; [ ! -f "$d/flatpak.override.fail" ] || exit 1
                 if [ ! -s "$f" ]; then echo "[Session Bus Policy]" >"$f"; fi
                 printf "%s=talk\n" "$talk" >>"$f" ;;
        esac ;;
    *) echo "error: the flatpak stand-in does not know the call [$*]" >&2; exit 1 ;;
esac' || return 1
    gm_stub "$SANDBOX/pathbin/flatpak-spawn" 'if [ "$1" = --host ]; then shift; exec "$@"; fi; echo "flatpak-spawn stand-in: unknown call [$*]" >&2; exit 1' || return 1
    # ^ invariant a failing git-lfs stands for "no git-lfs" ahead of any real one in the base path;
    # ^ invariant a Homebrew prefix bin comes first and wins after brew install git-lfs
    mkdir -p -- "$SANDBOX/lfsmissing" || return 1
    gm_stub "$SANDBOX/lfsmissing/git-lfs" 'd="$(cd "${0%/*}/.." && pwd -P)"
if grep -q "install -y git-lfs" "$d/gitup.log" 2>/dev/null; then
    case "$1" in
        version) echo "git-lfs/3.7.0 (package stand-in)"; exit 0 ;;
        install) git config --global filter.lfs.clean "git-lfs clean -- %f" && git config --global filter.lfs.required true && exit 0; exit 1 ;;
        *) echo "git-lfs stand-in: unknown call [$1]" >&2; exit 1 ;;
    esac
fi
echo "git-lfs is not installed" >&2; exit 1' || return 1
    # ^ invariant the mv stand-in stalls once on a move whose arguments hold the text in mv.stall, after mv.stallskip such moves pass; else the real mv
    local mv_stall_seconds="$SG_MV_STALL_SECONDS"
    # ^ invariant the sandbox path holds no quote, dollar or backtick (mktemp under ~/.tmp); it is embedded in the stand-in as written
    local mv_body real_mv gnubin_mv="$GM_PREFIX/opt/coreutils/libexec/gnubin/mv"
    real_mv="$(command -v mv)" || return 1
    mv_body="d=\"$SANDBOX\"
if [ -f \"\$d/mv.stall\" ]; then
    case \" \$* \" in
        *\"\$(cat \"\$d/mv.stall\")\"*)
            skip=0
            if [ -f \"\$d/mv.stallskip\" ]; then skip=\"\$(cat \"\$d/mv.stallskip\")\"; fi
            if [ \"\$skip\" -gt 0 ]; then
                echo \$((skip - 1)) >\"\$d/mv.stallskip\"
            else
                rm -f \"\$d/mv.stall\" \"\$d/mv.stallskip\"
                : >\"\$d/mv.stalled\"
                exec sleep $mv_stall_seconds
            fi
            ;;
    esac
fi
exec $real_mv \"\$@\""
    gm_stub "$SANDBOX/pathbin/mv" "$mv_body" || return 1
    if [ "$TEST_OS" != Darwin ] || [ -z "$GM_PREFIX" ]; then return 0; fi
    if [ ! -L "$gnubin_mv" ]; then
        printf 'the mv stand-in: %s is missing from the fake prefix\n' "$gnubin_mv" >&2
        return 1
    fi
    rm -f -- "$gnubin_mv" || return 1
    gm_stub "$gnubin_mv" "$mv_body"
}

# ^ invariant sg_launch_path = the PATH the tests give SmartGit's git; sandbox directories and the system ones, nothing of the real Homebrew
# ^ invariant lfsmissing comes before the system dirs => a real /usr/bin/git-lfs of the host never answers the Git LFS check
SG_SYSTEM_PATH=/usr/bin:/bin:/usr/sbin:/sbin
sg_launch_path() { printf '%s' "$GM_PREFIX/bin:$SANDBOX/pathbin:$SANDBOX/lfsmissing:$SG_SYSTEM_PATH"; }

# ^ invariant sg_setup [GITVER] = a Mac with git GITVER first on PATH, SmartGit 26.1.056 (bundled git 2.53.0, git-lfs 3.7.1)
# ^ invariant and its settings dir on the bundled git
sg_setup() {
    rm -f -- "$SANDBOX/smartgit.running" "$SANDBOX/smartgit.log" "$SANDBOX/flatpak.installed" "$SANDBOX/flatpak.override.user" "$SANDBOX/flatpak.override.system" "$SANDBOX/flatpak.ps" "$SANDBOX/flatpak.version" \
        "$SANDBOX/pgrep.count" "$SANDBOX/smartgit.running.after" "$SANDBOX/mv.stall" "$SANDBOX/mv.stallskip" "$SANDBOX/mv.stalled" \
        "$SANDBOX/lfs.install.fail" "$SANDBOX/lfs.record.during" "$SANDBOX/lfs.install.env" || return 1
    gm_setup "${1:-2.54.0}" || return 1
    set_env GSG_SMARTGIT_LAUNCH_PATH="$(sg_launch_path)"
    SG_APPS="$SANDBOX/apps"
    SG_APP="$SG_APPS/SmartGit.app"
    SG_SETTINGS="$LC_HOME/Library/Preferences/SmartGit/26.1"
    SG_PREFS="$SG_SETTINGS/preferences.yml"
    SG_BACKUPS="$LC_STATE/smartgit"
    sg_make_app "$SG_APP" 26.1.056 2.53.0 3.7.1 || return 1
    sg_make_prefs "$SG_PREFS" "$SG_APP" || return 1
    sg_standins || return 1
    set_env GSG_SMARTGIT_INSTALL_DIRS="$SG_APPS"
    set_env PATH="$GM_PREFIX/bin:$SANDBOX/pathbin:$SANDBOX/lfsmissing:$TEST_BASE_PATH"
    # ^ invariant brew install git-lfs puts a git-lfs into the fake prefix; the git-lfs formula is mapped to a stand-in answering version and install
    sg_lfs_standin "$SANDBOX/brewsrc/git-lfs" 3.9.9 || return 1
    printf 'git-lfs|bin/git-lfs|%s\n' "$SANDBOX/brewsrc/git-lfs" >>"$SANDBOX/brew.map" || return 1
}

# ^ invariant sg_lfs_standin FILE VERSION writes a git-lfs answering version;
# ^ invariant its install writes the filter.lfs.* settings to the global config, like the real one; lfs.install.fail makes it exit 1 first
# ^ invariant its install copies lfs.record to lfs.record.during (the record during the command) and logs PATH and VERIFY_LEAK to lfs.install.env
sg_lfs_standin() {
    gm_stub "$1" "case \"\$1\" in
    version) echo \"git-lfs/$2 (test stand-in)\" ;;
    install)
        printf 'PATH=%s leak=%s\n' \"\$PATH\" \"\${VERIFY_LEAK:-none}\" >>\"$SANDBOX/lfs.install.env\" || exit 1
        if [ -f \"$SANDBOX/lfs.install.fail\" ]; then echo 'git-lfs stand-in: install fails on request' >&2; exit 1; fi
        if [ -f \"$LC_STATE/smartgit/lfs.record\" ]; then cp -- \"$LC_STATE/smartgit/lfs.record\" \"$SANDBOX/lfs.record.during\" || exit 1; fi
        git config --global filter.lfs.clean 'git-lfs clean -- %f' || exit 1
        git config --global filter.lfs.smudge 'git-lfs smudge -- %f' || exit 1
        git config --global filter.lfs.required true || exit 1
        echo 'Git LFS initialized.' ;;
    *) exit 0 ;;
esac"
}

# ^ invariant sg_lfs_present puts a working git-lfs first on the sandbox PATH, as an installed Git LFS would be
sg_lfs_present() { sg_lfs_standin "$SANDBOX/pathbin/git-lfs" 3.8.0; }

# ^ invariant sg_real_tools seeds the real scanners and a dead proxy, as the lifecycle end-to-end test does; the verify step really scans
sg_real_tools() {
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    [ -x "$REAL_BETTERLEAKS" ] || skip_test "betterleaks not found at $REAL_BETTERLEAKS"
    lc_seed_real_tools || return 1
    set_env HTTPS_PROXY="$SG_DEAD_PROXY" HTTP_PROXY="$SG_DEAD_PROXY" https_proxy="$SG_DEAD_PROXY" http_proxy="$SG_DEAD_PROXY"
}

sg_running() { : >"$SANDBOX/smartgit.running" || return 1; }
# ^ external sha256sum is GNU; tests/run.sh puts the GNU coreutils directory first on a Mac, as every other test here relies on
sg_hash() {
    local out
    out="$(sha256sum -- "$1")" || return 1
    printf '%s\n' "${out%% *}"
}
sg_log() { if [ -f "$SANDBOX/smartgit.log" ]; then cat -- "$SANDBOX/smartgit.log"; fi; }
# ^ invariant sg_git_value KEY FILE prints the value of the "  KEY:" line inside the "git:" block; a missing key exits 1 (the key is matched literally)
sg_git_value() {
    awk -v key="$1" '
        /^git:$/ { g = 1; next }
        g && /^[^ ]/ { g = 0 }
        g && index($0, "  " key ": ") == 1 { print substr($0, length(key) + 5); found = 1; exit }
        END { exit !found }' "$2"
}
# ^ invariant sg_interrupt_run PATTERN SKIP SIGNAL CMD... stops CMD at the move with PATTERN in its arguments (after SKIP such moves) with SIGNAL
sg_interrupt_run() {
    local pattern="$1" skip="$2" sig="$3" pid
    shift 3
    if ! printf '%s' "$pattern" >"$SANDBOX/mv.stall" || ! printf '%s' "$skip" >"$SANDBOX/mv.stallskip"; then
        fail "could not arm the mv stall knob"
        return 1
    fi
    rm -f -- "$SANDBOX/mv.stalled"
    (${TEST_SETSID:-setsid} env --default-signal=INT env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$@" >"$SANDBOX/int.out" 2>&1 </dev/null & echo $! >"$SANDBOX/int.pid")
    pid="$(<"$SANDBOX/int.pid")"
    if [ -z "$pid" ]; then
        fail "no pid for the started command"
        return 1
    fi
    gu_poll "$SG_STALL_WAIT_TICKS" test -e "$SANDBOX/mv.stalled" || {
        kill -KILL -- "-$pid" 2>/dev/null
        local said=""
        if [ -f "$SANDBOX/int.out" ]; then said="$(<"$SANDBOX/int.out")"; fi
        fail "the command never reached the stalled move [$pattern]; it said: ${said:0:${GSG_TEST_DETAIL:-300}}"
        return 1
    }
    kill "-$sig" -- "-$pid" 2>/dev/null
    if ! gu_poll "$GU_EXIT_WAIT_TICKS" gu_pid_gone "$pid"; then
        kill -KILL -- "-$pid" 2>/dev/null
        fail "the command did not end after SIG$sig"
        return 1
    fi
    OUT="$(<"$SANDBOX/int.out")"
}

# ^ invariant prints every line of a preferences file except the two the edit may change; a test can compare the rest byte for byte
sg_others() { grep -v -E '^  executable(\.absolute)?: ' "$1"; }
