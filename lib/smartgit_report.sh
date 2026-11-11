# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled report half of the SmartGit support; reads the arrays lib/smartgit.sh fills, prints for status, doctor and the hint of install

# ^ invariant the git floor of every message is the one install uses, built here once
smartgit_min_git() { printf '%s.%s' "$GSG_MIN_GIT_MAJOR" "$GSG_MIN_GIT_MINOR"; }

smartgit_cmd_text() { printf '%s install --configure-smartgit' "$GSG_NAME"; }

# ^ invariant yes = a git at the floor or newer is read, no = an older one is read, unknown = the version could not be read
smartgit_scan_word() {
    local ver="${SG_SET_VER[$1]}"
    if [ -z "$ver" ]; then
        printf unknown
    elif gitup_version_at_least "$ver" "$(smartgit_min_git)"; then
        printf yes
    else
        printf no
    fi
}

smartgit_install_text() {
    local ver="${SG_INST_VER[$1]:-}"
    if [ -n "$ver" ]; then ver="SmartGit $ver"; else ver="version unknown"; fi
    printf '%s (%s)' "${SG_INST_PATH[$1]}" "$ver"
}

# ^ invariant prints what the Git Executable setting of settings directory $1 is ("bundled git" or the path), followed by the git version read from it
smartgit_choice_text() {
    local i="$1" what ver="${SG_SET_VER[$1]}"
    case "${SG_SET_CHOICE[$i]}" in
        bundled) what="bundled git" ;;
        other) what="${SG_SET_GIT[$i]}" ;;
        *) what="an executable setting of an unknown form" ;;
    esac
    if [ -n "$ver" ]; then printf '%s, git %s' "$what" "$ver"; else printf '%s, version unreadable' "$what"; fi
}

# ^ invariant prints "bundled git X" with the prefix $2 in front, or "PATH (git X)" for another executable; the one description hint and doctor share
smartgit_what() {
    local i="$1"
    if [ "${SG_SET_CHOICE[$i]}" = bundled ]; then
        printf '%sbundled git %s' "${2:-}" "${SG_SET_VER[$i]}"
    else
        printf '%s (git %s)' "${SG_SET_GIT[$i]}" "${SG_SET_VER[$i]}"
    fi
}

smartgit_settings_text() {
    local i="$1" head tail
    head="${SG_SET_DIR[$i]} (${SG_SET_MAJOR[$i]})"
    if [ "${SG_SET_STATE[$i]}" = missing ]; then
        printf '%s: no preferences.yml yet' "$head"
        return 0
    fi
    if [ "${SG_SET_STATE[$i]}" != ok ]; then
        printf '%s: preferences.yml cannot be read as SmartGit writes it (%s); not judged' "$head" "${SG_SET_WHY[$i]}"
        return 0
    fi
    case "$(smartgit_scan_word "$i")" in
        yes) tail="commits are scanned" ;;
        no) tail="commits are NOT scanned MISMATCH: run: $(smartgit_cmd_text)" ;;
        *) tail="the git version could not be read; an executable older than $(smartgit_min_git) does not scan commits" ;;
    esac
    printf '%s: %s; %s' "$head" "$(smartgit_choice_text "$i")" "$tail"
}

# ^ invariant a settings directory counts as a problem only when an installation was found; without one it is a leftover and only a warning
smartgit_status_lines() {
    local i
    smartgit_collect
    for i in "${!SG_INST_PATH[@]}"; do status_line "SmartGit install" "$(smartgit_install_text "$i")"; done
    for i in "${!SG_SET_DIR[@]}"; do
        status_line "SmartGit settings" "$(smartgit_settings_text "$i")"
        if [ "${SG_SET_STATE[$i]}" = ok ] && [ "$(smartgit_scan_word "$i")" = no ] && [ "${#SG_INST_PATH[@]}" -gt 0 ]; then status_problem; fi
    done
}

smartgit_doctor_lines() {
    local i head sev
    smartgit_collect
    for i in "${!SG_SET_DIR[@]}"; do
        if [ "${SG_SET_STATE[$i]}" = missing ]; then continue; fi
        head="SmartGit ${SG_SET_MAJOR[$i]} (${SG_SET_DIR[$i]})"
        if [ "${SG_SET_STATE[$i]}" != ok ]; then
            doctor_machine_line WARNING "$head: preferences.yml cannot be read as SmartGit writes it (${SG_SET_WHY[$i]}); not judged"
            continue
        fi
        case "$(smartgit_scan_word "$i")" in
            yes) doctor_machine_line ok "$head: Git Executable is $(smartgit_what "$i" "the ")" ;;
            no)
                sev=PROBLEM
                if [ "${#SG_INST_PATH[@]}" -eq 0 ]; then sev=WARNING; fi
                doctor_machine_line "$sev" "$head: Git Executable is $(smartgit_what "$i" "the "), so its commits are not scanned; run: $(smartgit_cmd_text)"
                ;;
            *) doctor_machine_line WARNING "$head: the git it is set to could not be run to read its version; an executable older than $(smartgit_min_git) does not scan commits" ;;
        esac
    done
}
