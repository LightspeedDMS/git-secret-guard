#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2034
# ^ order sourced after tests/lib.sh, tests/lifecycle.sh, tests/gitup.sh and tests/gitup_macos.sh;
# ^ coupled the SmartGit flows run against a fake bundle and fake settings
# ^ security HOME, the install dirs and every tool are in the sandbox => no test touches a real SmartGit settings dir or runs a real flatpak, brew or pgrep

SG_APPS="" SG_APP="" SG_SETTINGS="" SG_PREFS="" SG_BACKUPS=""
SG_FIXTURE="$GSG_PROJECT/tests/fixtures/smartgit/macos-26.1/preferences.yml"
SG_DEAD_PROXY=http://127.0.0.1:9

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

# ^ invariant pgrep answers 0 (running) only if $SANDBOX/smartgit.running exists; flatpak ps lists the app under the same condition; both log their calls
# ^ invariant flatpak knobs = flatpak.installed (info answers), flatpak.overrides (override --show prints it;
# ^ invariant override --system --talk-name=N appends N=talk; --reset removes it)
sg_standins() {
    gm_stub "$SANDBOX/pathbin/pgrep" 'd="$(cd "${0%/*}/.." && pwd -P)"; printf "%s\n" "pgrep $*" >>"$d/smartgit.log"; [ -f "$d/smartgit.running" ]' || return 1
    gm_stub "$SANDBOX/pathbin/flatpak" 'd="$(cd "${0%/*}/.." && pwd -P)"; printf "%s\n" "flatpak $*" >>"$d/smartgit.log"
case "$1" in
    info) [ -f "$d/flatpak.installed" ] || { echo "error: com.syntevo.SmartGit not installed" >&2; exit 1; }
          printf "SmartGit - Git client\n\n          ID: com.syntevo.SmartGit\n     Version: 26.1.056\n" ;;
    ps) if [ -f "$d/smartgit.running" ]; then echo com.syntevo.SmartGit; fi ;;
    run) if [ "$2" = --command=sh ] && [ "$4" = -c ]; then exec sh -c "$5"; fi; echo "error: the flatpak stand-in does not know the run call [$*]" >&2; exit 1 ;;
    override)
        system=0 talk=""
        for a in "$@"; do
            case "$a" in --system) system=1 ;; --talk-name=*) talk="${a#--talk-name=}" ;; esac
        done
        case " $* " in
            *" --show "*) if [ -f "$d/flatpak.overrides" ]; then cat "$d/flatpak.overrides"; fi ;;
            *" --reset "*) [ "$system" -eq 1 ] || exit 1; rm -f "$d/flatpak.overrides" ;;
            *" --talk-name="*) [ "$system" -eq 1 ] || exit 1; printf "[Session Bus Policy]\n%s=talk\n" "$talk" >>"$d/flatpak.overrides" ;;
            *) echo "error: the flatpak stand-in does not know the override call [$*]" >&2; exit 1 ;;
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
}

# ^ invariant sg_setup [GITVER] = a Mac with git GITVER first on PATH, SmartGit 26.1.056 (bundled git 2.53.0, git-lfs 3.7.1)
# ^ invariant and its settings dir on the bundled git
sg_setup() {
    rm -f -- "$SANDBOX/smartgit.running" "$SANDBOX/smartgit.log" "$SANDBOX/flatpak.installed" "$SANDBOX/flatpak.overrides" || return 1
    gm_setup "${1:-2.54.0}" || return 1
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
# ^ invariant its install writes the filter.lfs.* settings to the global config, like the real one
sg_lfs_standin() {
    gm_stub "$1" "case \"\$1\" in
    version) echo \"git-lfs/$2 (test stand-in)\" ;;
    install)
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
# ^ invariant prints every line of a preferences file except the two the edit may change; a test can compare the rest byte for byte
sg_others() { grep -v -E '^  executable(\.absolute)?: ' "$1"; }
