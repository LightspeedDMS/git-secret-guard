# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled install-time, status and doctor only; the CLI loads it after lib/gitup_source.sh and the hook never does
# ^ coupled detection half; report text in lib/smartgit_report.sh, refusals and plan in lib/smartgit_offer.sh, write and restore in lib/smartgit_apply.sh
# ^ external sha256sum is the GNU one; brew_use_gnubin puts GNU coreutils first for install, status and doctor on macOS, as every other library relies on

# ^ invariant the one settings directory name this tool has seen (SmartGit 26.1 on macOS); any other major version is refused with the manual steps
SMARTGIT_RECORDED_MAJOR=26.1
SMARTGIT_FLATPAK_ID=com.syntevo.SmartGit
SMARTGIT_MAX_BYTES=1048576
SMARTGIT_MAX_LINES=20000
SMARTGIT_MAX_ENTRIES=64
SMARTGIT_MAX_DESKTOP_FILES=50
SMARTGIT_DIR_ID_LEN=12
SMARTGIT_ANNOUNCED=0
# ^ invariant what a restore refusal tells the user to run again; the restore names itself, uninstall sets its own command before it calls the restore
SMARTGIT_AGAIN="the restore"
SG_FOUND=0
# ^ invariant Windows only, set by smartgit_win_target during an offer; the target written into preferences.yml and the POSIX git path run for the checks
# ^ invariant both stay empty elsewhere, and the expansion "${SMARTGIT_WIN_TARGET:-$GSG_GIT}" names GSG_GIT
SMARTGIT_WIN_TARGET="" SMARTGIT_WIN_GIT=""

# ^ invariant parallel arrays, one entry per install (kind macos, tarball, flatpak, snap, windows) and per settings directory; reset only here
smartgit_reset_results() {
    SG_INST_KIND=() SG_INST_PATH=() SG_INST_VER=()
    SG_SET_DIR=() SG_SET_MAJOR=() SG_SET_KIND=() SG_SET_STATE=() SG_SET_WHY=() SG_SET_CHOICE=() SG_SET_GIT=() SG_SET_VER=()
    SG_SET_LEFT=() SG_SET_NEWER=()
}
smartgit_reset_results

# ^ security the overrides move where SmartGit is looked for and what tools run; they skip no check and are announced like GSG_GITUP_ROOT
# ^ invariant GSG_SMARTGIT_INSTALL_DIRS counts when set, even empty (= no installs); the other four count when non-empty, as their lookups read them
smartgit_announce_overrides() {
    if [ "$SMARTGIT_ANNOUNCED" -eq 1 ]; then return 0; fi
    if [ -z "${GSG_SMARTGIT_INSTALL_DIRS+x}${GSG_SMARTGIT_TOOL_DIR:-}${GSG_SMARTGIT_SETTINGS_BASE:-}${GSG_SMARTGIT_FLATPAK_BASE:-}${GSG_SMARTGIT_LAUNCH_PATH:-}" ]; then return 0; fi
    SMARTGIT_ANNOUNCED=1
    printf '%s: TEST OVERRIDE active (GSG_SMARTGIT_INSTALL_DIRS=[%s] GSG_SMARTGIT_TOOL_DIR=[%s] GSG_SMARTGIT_SETTINGS_BASE=[%s] GSG_SMARTGIT_FLATPAK_BASE=[%s] GSG_SMARTGIT_LAUNCH_PATH=[%s]); SmartGit is looked for there\n' \
        "$GSG_NAME" "${GSG_SMARTGIT_INSTALL_DIRS:-}" "${GSG_SMARTGIT_TOOL_DIR:-}" "${GSG_SMARTGIT_SETTINGS_BASE:-}" "${GSG_SMARTGIT_FLATPAK_BASE:-}" "${GSG_SMARTGIT_LAUNCH_PATH:-}" >&2
}

smartgit_platform() {
    if tools_is_windows; then
        REPLY=windows
    elif brew_is_macos; then
        REPLY=macos
    else
        REPLY=linux
    fi
}

# ^ invariant sets REPLY = the path of tool $1; with GSG_SMARTGIT_TOOL_DIR only this dir is searched, else PATH; rc 1 = not found
smartgit_tool() {
    REPLY=""
    if [ -n "${GSG_SMARTGIT_TOOL_DIR:-}" ]; then
        if [ -x "$GSG_SMARTGIT_TOOL_DIR/$1" ]; then REPLY="$GSG_SMARTGIT_TOOL_DIR/$1"; fi
    else
        REPLY="$(type -P "$1")" || REPLY=""
    fi
    [ -n "$REPLY" ]
}

# ^ invariant sets SG_DIRS = the directories to look in; GSG_SMARTGIT_INSTALL_DIRS (":" separated, ";" on Windows) when set, else the platform defaults
smartgit_install_dirs() {
    local sep=: local_app=""
    SG_DIRS=()
    if tools_is_windows; then sep=';'; fi
    if [ -n "${GSG_SMARTGIT_INSTALL_DIRS+x}" ]; then
        IFS="$sep" read -r -a SG_DIRS <<<"$GSG_SMARTGIT_INSTALL_DIRS"
        return 0
    fi
    smartgit_platform
    case "$REPLY" in
        macos) SG_DIRS=(/Applications "$HOME/Applications") ;;
        windows)
            if [ -n "${LOCALAPPDATA:-}" ]; then local_app="$(gsg_posix_path "$LOCALAPPDATA")/Programs/SmartGit"; fi
            SG_DIRS=("/c/Program Files/SmartGit" ${local_app:+"$local_app"})
            ;;
        *) SG_DIRS=("$HOME/smartgit" /opt/smartgit /usr/share/smartgit) ;;
    esac
}

smartgit_under_cap() { [ "$1" -le "$SMARTGIT_MAX_ENTRIES" ]; }

# ^ invariant prints CFBundleShortVersionString of an Info.plist (XML form, key line, string line next); rc 1 = none or not a plain version
# ^ invariant the awk offsets are the lengths of the tags <string> (8) and <string></string> (17) around the version text
smartgit_plist_version() {
    local v
    v="$(awk -v open_len=8 -v tags_len=17 '/<key>CFBundleShortVersionString<\/key>/ { getline; if (match($0, /<string>[^<]*<\/string>/)) { print substr($0, RSTART + open_len, RLENGTH - tags_len); exit } }' "$1" 2>/dev/null)" || return 1
    if [[ ! $v =~ ^[0-9]+(\.[0-9]+)*$ ]]; then return 1; fi
    printf '%s' "$v"
}

smartgit_add_install() {
    SG_INST_KIND+=("$1")
    SG_INST_PATH+=("$2")
    SG_INST_VER+=("${3:-}")
}

# ^ invariant an unreadable version stays empty and is shown as "version unknown"; status and doctor never assume one
smartgit_find_macos() {
    local dir app ver n=0
    for dir in "${SG_DIRS[@]}"; do
        for app in "$dir"/SmartGit*.app; do
            if [ ! -d "$app" ]; then continue; fi
            n=$((n + 1))
            if ! smartgit_under_cap "$n"; then return 0; fi
            ver="$(smartgit_plist_version "$app/Contents/Info.plist")" || ver=""
            smartgit_add_install macos "$app" "$ver"
        done
    done
}

# ^ invariant a Linux or Windows install root is a directory holding bin/smartgit.sh (bin/smartgit.exe on Windows); its version is not read, none was recorded
smartgit_find_roots() {
    local dir kind="$1" launcher="$2" n=0
    for dir in "${SG_DIRS[@]}"; do
        if [ ! -f "$dir/bin/$launcher" ]; then continue; fi
        n=$((n + 1))
        if ! smartgit_under_cap "$n"; then return 0; fi
        smartgit_add_install "$kind" "$dir" ""
    done
}

# ^ invariant a launcher in the user's applications directory (Exec= naming .../bin/smartgit.sh) is one more tarball install; files and lines read are bounded
smartgit_find_desktop_files() {
    local f line root n=0 lines have i
    for f in "${XDG_DATA_HOME:-$HOME/.local/share}"/applications/*[sS]mart[gG]it*.desktop; do
        if [ ! -f "$f" ]; then continue; fi
        n=$((n + 1))
        if [ "$n" -gt "$SMARTGIT_MAX_DESKTOP_FILES" ]; then return 0; fi
        lines=0
        while IFS= read -r line; do
            lines=$((lines + 1))
            if [ "$lines" -gt "$SMARTGIT_MAX_LINES" ]; then break; fi
            if [[ $line != Exec=*/bin/smartgit.sh* ]]; then continue; fi
            root="${line#Exec=}"
            root="${root%%/bin/smartgit.sh*}"
            root="${root#\"}"
            have=0
            for i in "${!SG_INST_PATH[@]}"; do
                if [ "${SG_INST_PATH[$i]}" = "$root" ]; then have=1; fi
            done
            if [ "$have" -eq 0 ] && [ -f "$root/bin/smartgit.sh" ]; then smartgit_add_install tarball "$root" ""; fi
            break
        done <"$f"
    done
}

SMARTGIT_KILL_GRACE_SECONDS=5

# ^ invariant runs a command under the doctor time bound (TIMEOUT_BIN, DR_LIMIT set during doctor), plainly otherwise; the child is killed after a grace period
smartgit_bounded() {
    if [ -n "${DR_LIMIT:-}" ] && [ -n "${TIMEOUT_BIN:-}" ]; then
        "$TIMEOUT_BIN" -k "$SMARTGIT_KILL_GRACE_SECONDS" "$DR_LIMIT" "$@"
    else
        "$@"
    fi
}

# ^ invariant prints the version of git $1 as install_git_version does (no config files read), under the doctor time bound; rc 1 = does not run or not git
smartgit_git_version() {
    local out
    if brew_git_shim_unusable "$1"; then return 1; fi
    out="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null smartgit_bounded "$1" --version 2>/dev/null)" || return 1
    smartgit_parse_git_version "$out"
}

# ^ invariant prints X.Y[.Z] of a "git version X.Y.Z..." answer (a suffix such as .dirty is dropped); rc 1 = another answer
smartgit_parse_git_version() {
    if [[ $1 =~ ^git\ version\ ([0-9]+)\.([0-9]+)(\.[0-9]+)? ]]; then
        printf '%s.%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        return 0
    fi
    return 1
}

# ^ invariant prints the version of git $1 as the SmartGit Flatpak runs it, inside its sandbox (/app paths do not exist on the host), under the doctor bound
smartgit_flatpak_git_version() {
    local out
    smartgit_tool flatpak || return 1
    out="$(smartgit_bounded "$REPLY" run --command="$1" "$SMARTGIT_FLATPAK_ID" --version </dev/null 2>/dev/null)" || return 1
    smartgit_parse_git_version "$out"
}

# ^ invariant flatpak info answers for both the user and the system installation; its Version line is the SmartGit version
smartgit_find_flatpak() {
    local out ver=""
    smartgit_tool flatpak || return 0
    out="$(smartgit_bounded "$REPLY" info "$SMARTGIT_FLATPAK_ID" 2>/dev/null)" || return 0
    # ^ why Version accepts digits joined by dot or underscore, not dots only; flatpak prints 26_1_057 for 26.1.057
    if [[ $out =~ (^|$'\n')[[:space:]]*Version:[[:space:]]*([0-9][0-9._]*) ]]; then ver="${BASH_REMATCH[2]//_/.}"; fi
    smartgit_add_install flatpak "flatpak $SMARTGIT_FLATPAK_ID" "$ver"
}

# ^ invariant row 1 of snap list is the header, row 2 the first data row, and its second column is the version
smartgit_find_snap() {
    local out ver
    smartgit_tool snap || return 0
    out="$(smartgit_bounded "$REPLY" list smartgit 2>/dev/null)" || return 0
    ver="$(awk 'NR == 2 { print $2 }' <<<"$out")"
    if [[ ! $ver =~ ^[0-9][0-9.]*$ ]]; then ver=""; fi
    smartgit_add_install snap "snap smartgit" "$ver"
}

# ^ invariant sets SGP_STATE (ok, missing, symlink, owner, big, shape) and SGP_WHY for an unjudgeable file (rc 1); SGP_LINES holds the lines on rc 0
# ^ invariant the file must be a regular file you own, 1 MiB or less, end with a newline and stay within the line bound; anything else is never edited
smartgit_prefs_precheck() {
    local f="$1" size last
    SGP_STATE=ok SGP_WHY="" SGP_LINES=()
    if [ -L "$f" ]; then
        SGP_STATE=symlink SGP_WHY="$f is a symbolic link"
        return 1
    fi
    if [ ! -f "$f" ]; then
        SGP_STATE=missing SGP_WHY="no preferences.yml yet"
        return 1
    fi
    if [ ! -O "$f" ]; then
        SGP_STATE=owner SGP_WHY="$f is not owned by you"
        return 1
    fi
    size="$(wc -c <"$f")" || {
        SGP_STATE=shape SGP_WHY="its size cannot be read"
        return 1
    }
    size="${size//[[:space:]]/}"
    if [ "$size" -gt "$SMARTGIT_MAX_BYTES" ]; then
        SGP_STATE=big SGP_WHY="$f is larger than $SMARTGIT_MAX_BYTES bytes"
        return 1
    fi
    last="$(
        tail -c 1 -- "$f"
        printf x
    )"
    if [ "$last" != $'\nx' ]; then
        SGP_STATE=shape SGP_WHY="it does not end with a newline"
        return 1
    fi
    { mapfile -t -n "$((SMARTGIT_MAX_LINES + 1))" SGP_LINES <"$f"; } 2>/dev/null || {
        SGP_STATE=shape SGP_WHY="it cannot be read"
        return 1
    }
    if [ "${#SGP_LINES[@]}" -gt "$SMARTGIT_MAX_LINES" ]; then
        SGP_STATE=big SGP_WHY="$f has more than $SMARTGIT_MAX_LINES lines"
        return 1
    fi
}

# ^ invariant ok = exactly one "git:" line at column 0 and, in its indented block, exactly one "  executable:" and at most one "  executable.absolute:"
# ^ invariant sets SGP_EXEC, SGP_ABS and line indexes SGP_EXEC_IDX and SGP_ABS_IDX (-1 = none); a tab or carriage return in the block is not the recorded shape
smartgit_prefs_scan() {
    local i line in_git=0 git_blocks=0 execs=0 abss=0
    SGP_EXEC="" SGP_ABS="" SGP_EXEC_IDX=-1 SGP_ABS_IDX=-1
    for i in "${!SGP_LINES[@]}"; do
        line="${SGP_LINES[$i]}"
        if [ "$line" = "git:" ]; then
            git_blocks=$((git_blocks + 1))
            in_git=1
            continue
        fi
        if [ "$in_git" -eq 1 ] && [ -n "$line" ] && [[ $line != " "* ]]; then in_git=0; fi
        if [ "$in_git" -ne 1 ]; then continue; fi
        if [[ $line == *$'\r'* || $line == *$'\t'* ]]; then
            SGP_STATE=shape SGP_WHY="the git: block has a tab or a carriage return"
            return 1
        fi
        case "$line" in
            "  executable: "*)
                execs=$((execs + 1))
                SGP_EXEC="${line#  executable: }" SGP_EXEC_IDX="$i"
                ;;
            "  executable.absolute: "*)
                abss=$((abss + 1))
                SGP_ABS="${line#  executable.absolute: }" SGP_ABS_IDX="$i"
                ;;
        esac
    done
    if [ "$git_blocks" -ne 1 ] || [ "$execs" -ne 1 ] || [ "$abss" -gt 1 ]; then
        SGP_STATE=shape SGP_WHY="$git_blocks git: block(s), $execs executable: line(s) and $abss executable.absolute: line(s) where 1, 1 and at most 1 are expected"
        return 1
    fi
}

smartgit_prefs_analyze() {
    smartgit_prefs_precheck "$1" || return 1
    smartgit_prefs_scan
}

smartgit_unquote() {
    local v="$1"
    if [[ $v == \'*\' ]] && [ "${#v}" -ge 2 ] && [[ ${v:1:${#v}-2} != *\'* ]]; then v="${v:1:${#v}-2}"; fi
    printf '%s' "$v"
}

# ^ invariant the install of version MAJOR.MINOR or MAJOR.MINOR.x is the one a settings directory MAJOR.MINOR belongs to; sets REPLY = its index, rc 1 = none
# ^ invariant 26.10 does not match 26.1; only the whole version or a dot after the prefix does
# ^ invariant an optional second argument limits the match to installs of one kind (a macOS app never owns a Flatpak directory)
smartgit_install_for() {
    local major="$1" kind="${2:-}" i
    REPLY=""
    for i in "${!SG_INST_PATH[@]}"; do
        if [ -n "$kind" ] && [ "${SG_INST_KIND[$i]}" != "$kind" ]; then continue; fi
        if [[ ${SG_INST_VER[$i]} == "$major" || ${SG_INST_VER[$i]} == "$major".* ]]; then
            REPLY="$i"
            return 0
        fi
    done
    return 1
}

# ^ invariant kind windows reads ${smartgit.install}\... (backslash only) as bundled, its git from executable.absolute, else below the only install found
# ^ invariant a drive path (C:\... or C:/...) is another git; executable wins over a stale executable.absolute (measured, SmartGit 26.1 on Windows)
# ^ invariant SGP_GITPATH is the POSIX spelling, as the version probe needs it; a path cannot be converted = the git stays unknown
smartgit_classify_windows() {
    local v rest bs=$'\\'
    # shellcheck disable=SC2016
    local pfx='${smartgit.install}'
    v="$(smartgit_unquote "$SGP_EXEC")"
    case "$v" in
        "$pfx$bs"?*)
            SGP_CHOICE=bundled
            rest="${v#"$pfx$bs"}"
            if [ -n "$SGP_ABS" ]; then
                SGP_GITPATH="$(gsg_posix_path "$(smartgit_unquote "$SGP_ABS")")" || SGP_GITPATH=""
            elif [ "${#SG_INST_PATH[@]}" -eq 1 ]; then
                SGP_GITPATH="${SG_INST_PATH[0]}/${rest//\\//}"
            fi
            ;;
        [A-Za-z]:[\\/]?*)
            SGP_CHOICE=other
            SGP_GITPATH="$(gsg_posix_path "$v")" || SGP_GITPATH=""
            ;;
    esac
}

# ^ invariant sets SGP_CHOICE (bundled, other, unknown) and SGP_GITPATH; a macOS bundled git is read via executable.absolute, else the matching install's bundle
smartgit_classify() {
    local kind="$1" major="$2" v rest
    SGP_CHOICE=unknown SGP_GITPATH=""
    if [ "$kind" = windows ]; then
        smartgit_classify_windows
        return 0
    fi
    v="$(smartgit_unquote "$SGP_EXEC")"
    # shellcheck disable=SC2016
    case "$v" in
        '${smartgit.install}/'*)
            SGP_CHOICE=bundled
            rest="${v#'${smartgit.install}/'}"
            if [ -n "$SGP_ABS" ]; then
                SGP_GITPATH="$(smartgit_unquote "$SGP_ABS")"
            elif [ "$kind" = macos ] && smartgit_install_for "$major"; then
                SGP_GITPATH="${SG_INST_PATH[$REPLY]}/Contents/Resources/$rest"
            fi
            ;;
        /*)
            SGP_CHOICE=other
            SGP_GITPATH="$v"
            ;;
        # ^ external SmartGit stores a typed home path as ~/... with the expanded path in executable.absolute (measured on the Linux Flatpak 26.1)
        [~]/*)
            SGP_CHOICE=other
            SGP_GITPATH="$HOME/${v#'~/'}"
            if [[ $(smartgit_unquote "$SGP_ABS") == /* ]]; then SGP_GITPATH="$(smartgit_unquote "$SGP_ABS")"; fi
            ;;
    esac
}

# ^ invariant an unreadable git version stays empty and smartgit_scan_word calls it unknown; it is never assumed to be old or new
smartgit_add_settings() {
    local dir="$1" kind="$2" major="$3" ver=""
    SGP_CHOICE="" SGP_GITPATH=""
    if [ -L "$dir" ]; then
        SGP_STATE=symlink SGP_WHY="$dir is a symbolic link"
    elif [ ! -O "$dir" ]; then
        SGP_STATE=owner SGP_WHY="$dir is not owned by you"
    elif smartgit_prefs_analyze "$dir/preferences.yml"; then
        smartgit_classify "$kind" "$major"
    fi
    if [ -n "$SGP_GITPATH" ] && [ "$kind" = flatpak ]; then
        ver="$(smartgit_flatpak_git_version "$SGP_GITPATH")" || ver=""
    elif [ -n "$SGP_GITPATH" ] && [ -x "$SGP_GITPATH" ]; then
        ver="$(smartgit_git_version "$SGP_GITPATH")" || ver=""
    fi
    SG_SET_DIR+=("$dir")
    SG_SET_MAJOR+=("$major")
    SG_SET_KIND+=("$kind")
    SG_SET_STATE+=("$SGP_STATE")
    SG_SET_WHY+=("$SGP_WHY")
    SG_SET_CHOICE+=("$SGP_CHOICE")
    SG_SET_GIT+=("$SGP_GITPATH")
    SG_SET_VER+=("$ver")
}

smartgit_scan_base() {
    local base="$1" kind="$2" d name n=0
    for d in "$base"/*; do
        if [ ! -d "$d" ]; then continue; fi
        name="${d##*/}"
        # ^ why at most 9 digits a part, not any length; smartgit_major_newer compares them as shell integers
        if [[ ! $name =~ ^[0-9]{1,9}\.[0-9]{1,9}$ ]]; then continue; fi
        n=$((n + 1))
        if ! smartgit_under_cap "$n"; then return 0; fi
        smartgit_add_settings "$d" "$kind" "$name"
    done
}

smartgit_find_settings() {
    local appdata=""
    smartgit_platform
    case "$REPLY" in
        macos) smartgit_scan_base "${GSG_SMARTGIT_SETTINGS_BASE:-$HOME/Library/Preferences/SmartGit}" macos ;;
        windows)
            if [ -n "${APPDATA:-}" ]; then appdata="$(gsg_posix_path "$APPDATA")/syntevo/SmartGit"; fi
            # ^ why return on an empty base, not scan it; an empty base would make the glob "/*" and look for settings directories at the file system root
            if [ -z "${GSG_SMARTGIT_SETTINGS_BASE:-$appdata}" ]; then return 0; fi
            smartgit_scan_base "${GSG_SMARTGIT_SETTINGS_BASE:-$appdata}" windows
            ;;
        *)
            smartgit_scan_base "${GSG_SMARTGIT_SETTINGS_BASE:-${XDG_CONFIG_HOME:-$HOME/.config}/smartgit}" linux
            smartgit_scan_base "${GSG_SMARTGIT_FLATPAK_BASE:-$HOME/.var/app/$SMARTGIT_FLATPAK_ID/config/smartgit}" flatpak
            ;;
    esac
}

# ^ invariant true when major $1 (MAJOR.MINOR, digits only as smartgit_scan_base admits) is newer than major $2
smartgit_major_newer() {
    local hi_a="${1%%.*}" lo_a="${1#*.}" hi_b="${2%%.*}" lo_b="${2#*.}"
    if [ "$hi_a" -ne "$hi_b" ]; then [ "$hi_a" -gt "$hi_b" ]; else [ "$lo_a" -gt "$lo_b" ]; fi
}

# ^ invariant a directory SmartGit has set up is judged (not missing, a link or foreign) and, off macOS, holds the startup file its wizard writes at Finish
# ^ invariant only such a directory can be the newest of its root; one SmartGit never set up demotes nothing and is never left over itself
smartgit_set_ready() {
    case "${SG_SET_STATE[$1]}" in missing | symlink | owner) return 1 ;; esac
    [ "${SG_SET_KIND[$1]}" = macos ] || [ -f "${SG_SET_DIR[$1]}/startup" ]
}

# ^ invariant within one settings root (the directory holding the MAJOR.MINOR subdirectories) the newest major set up is live
# ^ invariant an older major is live only when an install of its kind has exactly its major (read on macOS and for the Flatpak only), else it is left over
# ^ invariant sets SG_SET_LEFT (1 = left over) and SG_SET_NEWER (newest major of its root) per directory; a left-over one is reported, never edited
smartgit_mark_left_over() {
    local i j newest
    SG_SET_LEFT=() SG_SET_NEWER=()
    for i in "${!SG_SET_DIR[@]}"; do
        newest="${SG_SET_MAJOR[$i]}"
        if smartgit_set_ready "$i"; then
            for j in "${!SG_SET_DIR[@]}"; do
                if [ "${SG_SET_DIR[$j]%/*}" = "${SG_SET_DIR[$i]%/*}" ] && smartgit_set_ready "$j" && smartgit_major_newer "${SG_SET_MAJOR[$j]}" "$newest"; then newest="${SG_SET_MAJOR[$j]}"; fi
            done
        fi
        SG_SET_NEWER+=("$newest")
        if [ "$newest" != "${SG_SET_MAJOR[$i]}" ] && ! smartgit_install_for "${SG_SET_MAJOR[$i]}" "${SG_SET_KIND[$i]}"; then
            SG_SET_LEFT+=(1)
        else
            SG_SET_LEFT+=(0)
        fi
    done
}

# ^ invariant fills the SG_INST_* and SG_SET_* arrays and SG_FOUND (installs plus settings directories); nothing found prints nothing
# ^ why the override is announced only when something was found or the flag was given, not on every run; a suite-wide seam would add a line to every stderr
smartgit_collect() {
    smartgit_reset_results
    smartgit_install_dirs
    smartgit_platform
    case "$REPLY" in
        macos) smartgit_find_macos ;;
        windows) smartgit_find_roots windows smartgit.exe ;;
        *)
            smartgit_find_roots tarball smartgit.sh
            smartgit_find_desktop_files
            smartgit_find_flatpak
            smartgit_find_snap
            ;;
    esac
    smartgit_find_settings
    smartgit_mark_left_over
    SG_FOUND=$((${#SG_INST_PATH[@]} + ${#SG_SET_DIR[@]}))
    if [ "$SG_FOUND" -gt 0 ]; then smartgit_announce_overrides; fi
}
