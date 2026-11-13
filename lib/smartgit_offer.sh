# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled refusal, plan and consent half of the SmartGit support; the write is lib/smartgit_apply.sh, the detection lib/smartgit.sh

# ^ invariant rc 0 = the target runs and is at the floor or newer, and SMARTGIT_TARGET_VER holds its version; the refusal says SmartGit was not changed
smartgit_check_target() {
    SMARTGIT_TARGET_VER=""
    if ! SMARTGIT_TARGET_VER="$(install_git_version "$1")"; then
        printf '%s: the git %s does not run, or does not answer git --version; SmartGit was not changed\n' "$GSG_NAME" "$1" >&2
        return 1
    fi
    if ! install_git_is_new_enough "$1"; then
        printf '%s: the git %s is git %s, older than %s, so its config hooks never fire; SmartGit was not changed\n' "$GSG_NAME" "$1" "$SMARTGIT_TARGET_VER" "$(smartgit_min_git)" >&2
        return 1
    fi
}

smartgit_manual_steps() {
    printf '%s: by hand: in SmartGit open Preferences, Commands, choose "Other Git Executable" and enter %s, then check that git --version through it says %s or newer; every step is in docs/smartgit.md\n' \
        "$GSG_NAME" "${SMARTGIT_WIN_TARGET:-${GSG_GIT:-the git that status reports}}" "$(smartgit_min_git)" >&2
}

smartgit_refuse() {
    printf '%s: SmartGit %s (%s): %s; SmartGit was not changed\n' "$GSG_NAME" "${SG_SET_MAJOR[$1]}" "${SG_SET_DIR[$1]}" "$2" >&2
    if [ "${3:-0}" -eq 1 ]; then smartgit_manual_steps; fi
    return 1
}

# ^ invariant rc 0 = running, 1 = not running, 2 = it cannot be told; macOS and Linux by pgrep, the Flatpak by flatpak ps entries with a live pid
smartgit_is_running() { smartgit_kind_running "${SG_SET_KIND[$1]}"; }

# ^ invariant the four steps of docs/smartgit.md (Fedora, SmartGit 26.1); lib/smartgit_flatpak.sh runs them when allowed, a refusal prints them
smartgit_flatpak_manual_steps() {
    printf '%s: by hand for the Flatpak (verified on Fedora with SmartGit 26.1, details and the wrapper script in docs/smartgit.md):\n' "$GSG_NAME" >&2
    printf '  1. flatpak override --user --talk-name=org.freedesktop.Flatpak %s   (no root; this removes the sandbox for SmartGit)\n' "$SMARTGIT_FLATPAK_ID" >&2
    printf '  2. create the wrapper ~/.local/share/smartgit/host-bin/git (chmod 755) that runs: flatpak-spawn --host %s "$@"\n' "${GSG_GIT:-<the git that status reports>}" >&2
    printf '  3. add -Djava.io.tmpdir=<your home>/.cache/smartgit-tmp to ~/.var/app/%s/config/smartgit/smartgit.vmoptions\n' "$SMARTGIT_FLATPAK_ID" >&2
    printf '  4. in SmartGit choose Other Git Executable and type the wrapper path\n' >&2
}

# ^ invariant rc 0 = settings directory $1 may be edited; every refusal prints why, says SmartGit was not changed and, where it helps, the manual steps
smartgit_check_dir() {
    local i="$1" kind="${SG_SET_KIND[$1]}" major="${SG_SET_MAJOR[$1]}" rc
    if [ "$major" != "$SMARTGIT_RECORDED_MAJOR" ]; then
        smartgit_refuse "$i" "SmartGit $major was not recorded: this tool has only seen SmartGit $SMARTGIT_RECORDED_MAJOR, and edits nothing it has not seen" 1
        return 1
    fi
    if [ "$kind" != macos ] && [ "$kind" != linux ] && [ "$kind" != flatpak ] && [ "$kind" != windows ]; then
        smartgit_refuse "$i" "a $kind settings directory is not one this tool edits (macOS, Linux, the Flatpak and Windows were recorded)" 1
        return 1
    fi
    case "${SG_SET_STATE[$i]}" in
        ok) ;;
        symlink | owner | big)
            smartgit_refuse "$i" "${SG_SET_WHY[$i]}" 1
            return 1
            ;;
        *)
            smartgit_refuse "$i" "preferences.yml does not have the recorded shape (${SG_SET_WHY[$i]})" 1
            return 1
            ;;
    esac
    # ^ external on Linux the setup wizard writes "startup" only when it reaches Finish, and shows again on every start before it (measured, 26.1)
    if [ "$kind" != macos ] && [ ! -f "${SG_SET_DIR[$i]}/startup" ]; then
        smartgit_refuse "$i" "SmartGit is not set up yet here (no startup file); start SmartGit once, finish its setup wizard, exit it and run the command again"
        return 1
    fi
    if [ "$kind" = flatpak ]; then
        smartgit_flatpak_check "$i" || return 1
    fi
    smartgit_is_running "$i"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        smartgit_running_who "$kind"
        smartgit_refuse "$i" "$REPLY is running and rewrites its settings while it runs; exit it with Repository, Exit and run the command again"
        return 1
    fi
    if [ "$rc" -ne 1 ]; then
        if [ "$kind" = windows ]; then
            smartgit_refuse "$i" "it cannot be told whether SmartGit is running (ps -W is missing or failed); exit SmartGit with Repository, Exit and run the command again"
        else
            smartgit_refuse "$i" "it cannot be told whether SmartGit is running (pgrep or flatpak ps is missing or failed); exit SmartGit and install pgrep"
        fi
        return 1
    fi
}

# ^ invariant true for a settings directory this run offers to change; its preferences are judgeable and the git it is set to is read and older than the floor
smartgit_needs_change() {
    if [ "${SG_SET_STATE[$1]}" != ok ]; then return 1; fi
    [ "$(smartgit_scan_word "$1")" = no ]
}

# ^ invariant true only when at least one settings directory exists and each existing one is judged and at the floor or newer
smartgit_all_good() {
    local i seen=0
    for i in "${!SG_SET_DIR[@]}"; do
        if [ "${SG_SET_STATE[$i]}" = missing ]; then continue; fi
        if [ "${SG_SET_STATE[$i]}" != ok ] || [ "$(smartgit_scan_word "$i")" != yes ]; then return 1; fi
        seen=1
    done
    [ "$seen" -eq 1 ]
}

smartgit_hint() {
    local i="$1" where
    where="${SG_SET_DIR[$i]}"
    if smartgit_install_for "${SG_SET_MAJOR[$i]}"; then where="${SG_INST_PATH[$REPLY]} (SmartGit ${SG_INST_VER[$REPLY]})"; fi
    printf '%s: SmartGit: found %s; it commits with its %s, so its commits are not scanned; run: %s\n' "$GSG_NAME" "$where" "$(smartgit_what "$i")" "$(smartgit_cmd_text)"
}

# ^ invariant the target must be an absolute path made of [A-Za-z0-9._/+@%-] only; this makes it a plain YAML scalar the edit can write without quoting
smartgit_target_is_plain() { [[ $1 =~ ^/[A-Za-z0-9._/+@%-]+$ ]]; }

# ^ invariant a Windows target is a drive letter and backslash components of [A-Za-z0-9._()+@%-] with inner spaces, a plain YAML scalar as SmartGit writes it
# ^ invariant no component starts or ends with a space and none holds ..; a quote, a hash, a colon after the drive and the slash form are refused
smartgit_win_target_is_plain() {
    local comp='[A-Za-z0-9._()+@%-]([A-Za-z0-9._()+@% -]*[A-Za-z0-9._()+@%-])?' re bs=$'\\'
    re="^[A-Za-z]:(${bs}${bs}${comp})+\$"
    if [[ $1 == *..* ]]; then return 1; fi
    [[ $1 =~ $re ]]
}

# ^ invariant sets SMARTGIT_WIN_TARGET (written into preferences.yml) and SMARTGIT_WIN_GIT (the POSIX path run for the checks); rc 1 prints why
# ^ why cmd\git.exe of the same Git for Windows when its version equals, not the git in use; the GUI offers it and it survives the ucrt64 layout change
smartgit_win_target() {
    local w root cand_w cand ver_use ver_cmd
    SMARTGIT_WIN_TARGET="" SMARTGIT_WIN_GIT="$GSG_GIT"
    w="$(cygpath -w "$GSG_GIT")" || {
        printf '%s: cannot turn %s into a Windows path (cygpath failed); SmartGit was not changed\n' "$GSG_NAME" "$GSG_GIT" >&2
        return 1
    }
    if [[ ${w,,} != *.exe ]] && [ -f "$GSG_GIT.exe" ]; then w+=.exe; fi
    root="${w%\\*}"
    case "${root,,}" in
        *\\cmd | *\\bin)
            root="${root%\\*}"
            case "${root,,}" in *\\mingw64 | *\\ucrt64 | *\\clang64 | *\\clangarm64 | *\\mingw32) root="${root%\\*}" ;; esac
            cand_w="$root\\cmd\\git.exe"
            cand="$(cygpath -u "$cand_w")" || cand=""
            if [ -n "$cand" ] && [ -f "$cand" ] && ver_use="$(smartgit_git_version "$GSG_GIT")" && ver_cmd="$(smartgit_git_version "$cand")" && [ "$ver_use" = "$ver_cmd" ]; then
                w="$cand_w"
                SMARTGIT_WIN_GIT="$cand"
            fi
            ;;
    esac
    if ! smartgit_win_target_is_plain "$w"; then
        printf '%s: the git %s is not a Windows path made of a drive letter, backslashes and [A-Za-z0-9._()+@%%-] (spaces inside a name), which this tool does not write into a YAML file; SmartGit was not changed\n' "$GSG_NAME" "$w" >&2
        return 1
    fi
    SMARTGIT_WIN_TARGET="$w"
}

# ^ invariant the id of a settings directory is the POSIX cksum of its path (crc and size); no GNU tool is needed to name the backup files
smartgit_dir_id() {
    local out crc size
    out="$(printf '%s' "$1" | cksum)" || return 1
    read -r crc size <<<"$out"
    printf '%s-%s' "$crc" "$size"
}

smartgit_plan_dir() {
    local i="$1" id
    id="$(smartgit_dir_id "${SG_SET_DIR[$i]}")" || {
        printf '%s: SmartGit: cannot compute the backup id of %s (cksum failed); SmartGit was not changed\n' "$GSG_NAME" "${SG_SET_DIR[$i]}" >&2
        return 1
    }
    local target="${SMARTGIT_WIN_TARGET:-$GSG_GIT}"
    if [ "${SG_SET_KIND[$i]}" = flatpak ]; then target="$SGF_WRAPPER"; fi
    printf '  SmartGit %s, settings %s\n' "${SG_SET_MAJOR[$i]}" "${SG_SET_DIR[$i]}"
    printf '    Git Executable: %s -> %s (git %s)\n' "$(smartgit_choice_text "$i")" "$target" "$SMARTGIT_TARGET_VER"
    printf '    writes: %s/preferences.yml (only the executable: and executable.absolute: lines of its git: block; every other byte stays)\n' "${SG_SET_DIR[$i]}"
    printf '    backup and manifest: %s/smartgit/%s.*\n' "$GSG_STATE_DIR" "$id"
    if [ "${SG_SET_KIND[$i]}" = flatpak ]; then smartgit_flatpak_plan; fi
}

# ^ invariant prints why nothing was done for an explicit flag and nothing at all without it; rc 1 only for the flag
smartgit_nothing_to_change() {
    local flag="$1" i
    if [ "$flag" -ne 1 ]; then return 0; fi
    if smartgit_all_good; then
        printf '%s: SmartGit: nothing to change, every SmartGit settings directory already commits with a git of %s or newer\n' "$GSG_NAME" "$(smartgit_min_git)"
        return 0
    fi
    if [ "${#SG_SET_DIR[@]}" -eq 0 ]; then
        printf '%s: SmartGit: no SmartGit settings directory exists yet (start SmartGit once so it creates one); SmartGit was not changed\n' "$GSG_NAME" >&2
        return 1
    fi
    for i in "${!SG_SET_DIR[@]}"; do printf '%s: SmartGit settings: %s\n' "$GSG_NAME" "$(smartgit_settings_text "$i")" >&2; done
    printf '%s: SmartGit was not changed: nothing above is a setting this tool can judge and change\n' "$GSG_NAME" >&2
    return 1
}

# ^ invariant the one entry of install; rc 0 = nothing to do, the hint, a decline without the flag, or success; rc 1 = a refused or failed explicit flag
# ^ invariant a failed apply returns 1 with or without the flag, as the user said yes to it; the backup was restored and the failure says so
# ^ order every refusal and the whole plan come before the one question, and nothing is written before its yes
smartgit_install_step() {
    local flag="$1" i
    local -a todo=()
    smartgit_collect
    if [ "$flag" -eq 1 ]; then smartgit_announce_overrides; fi
    if [ "$SG_FOUND" -eq 0 ]; then
        if [ "$flag" -eq 1 ]; then
            printf '%s: --configure-smartgit: no SmartGit installation or settings directory was found; SmartGit was not changed\n' "$GSG_NAME" >&2
            return 1
        fi
        return 0
    fi
    for i in "${!SG_SET_DIR[@]}"; do
        if smartgit_needs_change "$i" || { [ "${SG_SET_STATE[$i]}" != ok ] && [ "${SG_SET_STATE[$i]}" != missing ]; }; then
            todo+=("$i")
        elif [ "$flag" -eq 1 ] && [ "${SG_SET_STATE[$i]}" = ok ] && [ "${SG_SET_KIND[$i]}" != macos ] && [ "$(smartgit_scan_word "$i")" != yes ]; then
            todo+=("$i")
        fi
    done
    if [ "${#todo[@]}" -eq 0 ]; then
        smartgit_nothing_to_change "$flag"
        return
    fi
    if [ "$flag" -eq 0 ] && { [ ! -t 0 ] || [ ! -t 2 ]; }; then
        for i in "${todo[@]}"; do
            if smartgit_needs_change "$i"; then smartgit_hint "$i"; fi
        done
        return 0
    fi
    smartgit_offer "$flag" "${todo[@]}"
}

# ^ invariant the answer is no only without the flag (the flag is the yes); a decline returns 0; every refusal before the plan returns the flag value
# ^ security a Flatpak directory also needs the sandbox yes (smartgit_flatpak_keep) after the general one; a No there leaves the Flatpak untouched
smartgit_offer() {
    local flag="$1" i rc=0
    local -a elig=()
    shift
    SMARTGIT_WIN_TARGET="" SMARTGIT_WIN_GIT=""
    smartgit_platform
    if [ "$REPLY" = windows ]; then
        smartgit_win_target || return "$flag"
    elif ! smartgit_target_is_plain "$GSG_GIT"; then
        printf '%s: the git %s is not an absolute path made of [A-Za-z0-9._/+@%%-], which this tool does not write into a YAML file; SmartGit was not changed\n' "$GSG_NAME" "$GSG_GIT" >&2
        return "$flag"
    fi
    smartgit_check_target "${SMARTGIT_WIN_GIT:-$GSG_GIT}" || return "$flag"
    for i in "$@"; do
        if smartgit_check_dir "$i"; then elig+=("$i"); else rc=1; fi
    done
    if [ "${#elig[@]}" -eq 0 ]; then return "$flag"; fi
    GITUP_PRIV_CMDS=()
    printf '%s: SmartGit plan (nothing has been changed yet):\n' "$GSG_NAME"
    for i in "${elig[@]}"; do smartgit_plan_dir "$i" || return "$flag"; done
    local host_run=0 fp_run=0
    for i in "${elig[@]}"; do
        if [ "${SG_SET_KIND[$i]}" = flatpak ]; then fp_run=1; else host_run=1; fi
    done
    smartgit_lfs_plan "$fp_run" || return "$flag"
    if [ "$host_run" -eq 1 ]; then
        printf '  then: git --version and git lfs version through %s, a fake-token commit in a scratch repository must be blocked and a clean commit must print the summary line; any failure restores the backup\n' "${SMARTGIT_WIN_TARGET:-$GSG_GIT}"
    fi
    if [ "$fp_run" -eq 1 ]; then
        printf '  then (Flatpak): the same checks run through the wrapper %s inside the SmartGit sandbox (flatpak run, in your own session; the scratch repository under %s); any failure also undoes the Flatpak steps\n' "$SGF_WRAPPER" "$SGF_TMPDIR"
    fi
    gitup_need_elevation || return "$flag"
    if ! gitup_consent "$flag" "Point SmartGit at ${SMARTGIT_WIN_TARGET:-$GSG_GIT}?"; then
        printf '%s: SmartGit was not changed\n' "$GSG_NAME"
        return 0
    fi
    smartgit_flatpak_keep "${elig[@]}"
    if [ "${#SGF_KEEP[@]}" -eq 0 ]; then return 0; fi
    smartgit_apply "${SGF_KEEP[@]}" || return 1
    return "$((flag * rc))"
}
