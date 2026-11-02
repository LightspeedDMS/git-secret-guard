# shellcheck shell=bash disable=SC2153

GSG_MIN_GIT_MAJOR=2
GSG_MIN_GIT_MINOR=54

# ^ external install-time lookups (type -P) are legitimate here; the hook never resolves a tool through PATH
# ^ see test:test_the_hook_never_looks_tools_up_on_PATH
install_git_version() {
    local out
    # ^ external git 2.56 --version dies on a syntactically broken global config; the probe must not read user config
    out="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$1" --version 2>/dev/null)" || return 1
    if [[ $out =~ ^git\ version\ ([0-9]+)\.([0-9]+)(\.[0-9]+)? ]]; then
        printf '%s.%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        return 0
    fi
    return 1
}

install_git_is_new_enough() {
    local ver major minor
    ver="$(install_git_version "$1")" || return 1
    major="${ver%%.*}"
    minor="${ver#*.}"
    minor="${minor%%.*}"
    [ "$major" -gt "$GSG_MIN_GIT_MAJOR" ] || { [ "$major" -eq "$GSG_MIN_GIT_MAJOR" ] && [ "$minor" -ge "$GSG_MIN_GIT_MINOR" ]; }
}

lifecycle_require_git() {
    GSG_GIT="$(type -P git)" || {
        printf '%s: git is not on PATH; config-based hooks need git >= 2.54\n' "$GSG_NAME" >&2
        return 1
    }
}

# ^ security os-release is parsed as data, never sourced => a hostile line cannot run; test:test_os_release_fields_are_read_as_data
# ^ invariant sets REPLY = first KEY= value of FILE minus one pair of quotes, "" for an absent key or unreadable FILE; prints nothing
# ^ why braces around mapfile, not 2>/dev/null after it; a missing FILE fails the redirection first and bash prints its own error
install_os_release_field() {
    local file="$1" key="$2" line
    local -a lines=()
    REPLY=""
    { mapfile -t -n 200 lines <"$file"; } 2>/dev/null || return 0
    for line in "${lines[@]}"; do
        if [[ $line != "$key="* ]]; then continue; fi
        line="${line#"$key="}"
        if [[ $line =~ ^\"(.*)\"$ ]] || [[ $line =~ ^\'(.*)\'$ ]]; then line="${BASH_REMATCH[1]}"; fi
        REPLY="$line"
        return 0
    done
}

# ^ external GSG_OS_RELEASE names another file, for tests only; it can change a hint text and nothing else
# ^ invariant sets REPLY = ubuntu (ID or ID_LIKE names ubuntu), debian (names debian) or other, from the first ID= and ID_LIKE= lines
install_os_family() {
    local file="${GSG_OS_RELEASE:-/etc/os-release}" id like
    install_os_release_field "$file" ID
    id="$REPLY"
    install_os_release_field "$file" ID_LIKE
    like="$REPLY"
    REPLY=other
    case " $id $like " in
        *" ubuntu "*) REPLY=ubuntu ;;
        *" debian "*) REPLY=debian ;;
    esac
}

# ^ invariant prints the end of a "was not found" message for package $1; apt on Ubuntu and Debian, the package manager elsewhere
install_fix_hint() {
    install_os_family
    case "$REPLY" in
        ubuntu | debian) printf 'install it with: sudo apt install %s' "$1" ;;
        *) printf 'install it with your package manager' ;;
    esac
}

# ^ external ppa:git-core/ppa carries git >= 2.54 for Ubuntu only; Ubuntu 24.04 ships 2.43; the build path is in docs/platforms.md
install_git_hint() {
    install_os_family
    case "$REPLY" in
        ubuntu)
            printf '%s: on Ubuntu get a current git with: sudo add-apt-repository ppa:git-core/ppa && sudo apt install git\n' "$GSG_NAME" >&2
            printf '%s: add-apt-repository comes from the software-properties-common package; or build git from source, see docs/platforms.md\n' "$GSG_NAME" >&2
            ;;
        debian)
            printf '%s: Debian has no PPA; install git >= 2.54 from a newer release or backports, or build it from source, see docs/platforms.md\n' "$GSG_NAME" >&2
            ;;
        *)
            printf '%s: get git >= 2.54 from your distribution or build it from source, see docs/platforms.md\n' "$GSG_NAME" >&2
            ;;
    esac
}

install_require_git() {
    local ver
    lifecycle_require_git || {
        install_git_hint
        return 1
    }
    if ! install_git_is_new_enough "$GSG_GIT"; then
        ver="$(install_git_version "$GSG_GIT")" || ver="of unknown version"
        printf '%s: the git on PATH (%s) is git %s; config-based hooks need git >= 2.54, install refused\n' "$GSG_NAME" "$GSG_GIT" "$ver" >&2
        install_git_hint
        return 1
    fi
}

# ^ invariant sets GSG_GIT_CANDIDATES = every executable git on PATH plus /usr/bin/git, one path per real file, as found; GSG_GIT_REAL is parallel
install_collect_gits() {
    local cand real seen=" "
    local -a cands=()
    GSG_GIT_CANDIDATES=() GSG_GIT_REAL=()
    mapfile -t cands < <(type -aP git)
    cands+=(/usr/bin/git)
    for cand in "${cands[@]}"; do
        if [ ! -x "$cand" ]; then continue; fi
        real="$(realpath -- "$cand")" || continue
        if [[ $seen == *" $real "* ]]; then continue; fi
        seen+="$real "
        GSG_GIT_CANDIDATES+=("$cand")
        GSG_GIT_REAL+=("$real")
    done
}

# ^ external a git older than 2.54 ignores hook.<name>.* config without any message (verified on /usr/bin/git 2.52); warning only, the PATH git decides
install_warn_other_gits() {
    local i cand used ver
    used="$(realpath -- "$GSG_GIT")" || {
        printf '%s: cannot resolve the real path of %s; install refused, %s\n' "$GSG_NAME" "$GSG_GIT" "$(brew_unchanged_text)" >&2
        return 1
    }
    install_collect_gits
    for i in "${!GSG_GIT_CANDIDATES[@]}"; do
        cand="${GSG_GIT_CANDIDATES[$i]}"
        if [ "${GSG_GIT_REAL[$i]}" = "$used" ]; then continue; fi
        if install_git_is_new_enough "$cand"; then continue; fi
        ver="$(install_git_version "$cand")" || ver="of unknown version"
        printf '%s: warning: %s is git %s; it ignores config-based hooks without any message, so commits made with it are not scanned\n' \
            "$GSG_NAME" "$cand" "$ver" >&2
    done
}

# ^ security absolute paths found now are written to settings => the hook never resolves jq, setsid or timeout through PATH
install_resolve_bins() {
    local name path bad=0
    local -A package=([jq]=jq [setsid]=util-linux [timeout]=coreutils)
    for name in jq setsid timeout; do
        path="$(type -P "$name")" || {
            printf '%s: %s is required but was not found on PATH; %s\n' "$GSG_NAME" "$name" "$(install_fix_hint "${package[$name]}")" >&2
            bad=$((bad + 1))
            continue
        }
        if [ "${path#/}" = "$path" ]; then
            printf '%s: %s resolved to a relative path [%s]; fix PATH\n' "$GSG_NAME" "$name" "$path" >&2
            bad=$((bad + 1))
            continue
        fi
        case "$name" in
            jq) INSTALL_JQ_BIN="$path" ;;
            setsid) INSTALL_SETSID_BIN="$path" ;;
            timeout) INSTALL_TIMEOUT_BIN="$path" ;;
        esac
    done
    return "$bad"
}

# ^ invariant macOS only, detection only; rc 0 = Homebrew and the paths are known and the missing formulae are listed, rc 1 = refused with a message
# ^ order inspect before any install => the refusable checks after it can still end the run with the machine untouched
install_macos_inspect() {
    install_check_platform || return 1
    brew_inspect || return 1
    if [ -n "$BREW_NEED" ]; then
        printf '%s: Homebrew prerequisites missing: %s; install runs brew install %s only after every other check has passed\n' "$GSG_NAME" "$BREW_NEED" "$BREW_NEED"
    fi
    if [ -x "$BREW_TIMEOUT" ]; then INSTALL_TIMEOUT_BIN="$BREW_TIMEOUT"; fi
}

# ^ why prepend, not rely on the caller's PATH; sha256sum, realpath -m, mv -T and install -T are GNU-only and macOS ships the BSD ones
# ^ invariant needs BREW_GNUBIN to hold coreutils; a second call changes nothing
install_macos_use_gnubin() {
    case ":$PATH:" in
        ":$BREW_GNUBIN:"*) return 0 ;;
    esac
    PATH="$BREW_GNUBIN:$PATH"
    export PATH
}

# ^ order install_run calls this after the last refusable check without a brewed tool
# ^ invariant rc 0 = every INSTALL_*_BIN is set; rc 1 = refused with a message stating what changed
install_macos_finish() {
    brew_install_missing || return 1
    INSTALL_JQ_BIN="$BREW_JQ"
    INSTALL_SETSID_BIN="$BREW_SETSID"
    INSTALL_TIMEOUT_BIN="$BREW_TIMEOUT"
    INSTALL_BASH_BIN="$BREW_BASH"
    INSTALL_GNUBIN_DIR="$BREW_GNUBIN"
    install_macos_use_gnubin
}

install_require_curl() {
    if type -P curl >/dev/null; then return 0; fi
    printf '%s: curl is required to download the scanners but was not found on PATH; %s\n' "$GSG_NAME" "$(install_fix_hint curl)" >&2
    return 1
}

# ^ invariant true = unresolved timeout or a scanner != its pin; an unusable lock or platform = false, later steps refuse those
install_downloads_needed() {
    local tool plat row os arch
    if [ -z "${INSTALL_TIMEOUT_BIN:-}" ]; then return 0; fi
    os="$(uname -s)" && arch="$(uname -m)" || return 1
    for tool in "${GSG_TOOL_NAMES[@]}"; do
        plat="$(tools_platform_key "$tool" "$os" "$arch" 2>/dev/null)" || return 1
        row="$(tools_lock_lookup "$(tools_lock_path)" "$tool" "$plat" 2>/dev/null)" || return 1
        if ! tools_has_version "$GSG_BIN_DIR/$tool" "${row%% *}" "$INSTALL_TIMEOUT_BIN"; then return 0; fi
    done
    return 1
}

# ^ order every prerequisite is checked and reported before any change => one refusal names them all; test:test_every_missing_prerequisite_is_named_at_once
install_check_prerequisites() {
    local timer="$1" bad=0
    INSTALL_TIMEOUT_BIN="" INSTALL_BASH_BIN="" INSTALL_GNUBIN_DIR=""
    if install_require_git; then
        install_warn_other_gits || bad=$((bad + 1))
    else
        bad=$((bad + 1))
    fi
    if brew_is_macos; then
        install_macos_inspect || bad=$((bad + 1))
    else
        install_resolve_bins || bad=$((bad + $?))
    fi
    if install_downloads_needed; then install_require_curl || bad=$((bad + 1)); fi
    # ^ order systemctl check after every other check; bad > 1 => the count line follows and carries the claim of what changed
    if [ "$timer" -eq 1 ]; then
        if [ "$bad" -gt 0 ]; then install_find_systemctl counted >/dev/null || bad=$((bad + 1)); else install_find_systemctl >/dev/null || bad=$((bad + 1)); fi
    fi
    if [ "$bad" -gt 1 ]; then printf '%s: %s prerequisites are missing; install refused, %s\n' "$GSG_NAME" "$bad" "$(brew_unchanged_text)" >&2; fi
    if [ "$bad" -eq 1 ] && [ -n "$BREW_INSTALLED" ]; then printf '%s: install refused; %s\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2; fi
    [ "$bad" -eq 0 ]
}

# ^ external the only type -P of systemctl; its absolute path is written to the settings, uninstall and doctor never look it up on PATH
# ^ invariant sets REPLY = the absolute path of systemctl; a missing or relative one prints the refusal with its hint and returns 1
install_find_systemctl() {
    local found claim="; nothing was changed"
    if [ "${1:-}" = counted ]; then claim=""; fi
    found="$(type -P systemctl)" || found=""
    if [ -z "$found" ]; then
        printf '%s: systemctl is required for --with-timer but was not found on PATH%s (%s)\n' "$GSG_NAME" "$claim" "$(install_fix_hint systemd)" >&2
        return 1
    fi
    if [ "${found#/}" = "$found" ]; then
        printf '%s: systemctl resolved to a relative path [%s]; fix PATH\n' "$GSG_NAME" "$found" >&2
        return 1
    fi
    REPLY="$found"
}

# ^ invariant sets INSTALL_TIMER (1 = state records a timer), INSTALL_TIMER_ENABLE (1 = write and enable, --with-timer only), INSTALL_SYSTEMCTL_BIN
# ^ invariant a plain install over a recorded timer neither enables nor needs systemctl; it keeps the recorded systemctl path for uninstall
install_prepare_timer() {
    local want="$1" found
    INSTALL_TIMER=0 INSTALL_TIMER_ENABLE=0 INSTALL_SYSTEMCTL_BIN=""
    if [ "$want" -ne 1 ] && [ "$ST_TIMER" != yes ]; then return 0; fi
    if [ "$want" -ne 1 ]; then
        if install_find_systemctl 2>/dev/null; then found="$REPLY"; else found=""; fi
        INSTALL_SYSTEMCTL_BIN="${found:-$(install_recorded_systemctl)}"
        INSTALL_TIMER=1
        return 0
    fi
    install_find_systemctl || return 1
    INSTALL_SYSTEMCTL_BIN="$REPLY"
    timer_check_target "${GSG_GIT%/*}" || return 1
    INSTALL_TIMER=1 INSTALL_TIMER_ENABLE=1
}

# ^ invariant prints SYSTEMCTL_BIN from the settings file of the installed copy, "" when there is none
install_recorded_systemctl() {
    (
        load_settings "$GSG_SHARE/settings" >/dev/null 2>&1 || exit 0
        printf '%s' "${SYSTEMCTL_BIN:-}"
    )
}

# ^ invariant rewrites a unit only when it is ours and its text changed; a foreign or missing unit is left alone, nothing is enabled and systemctl is not run
# ^ why only a hint for daemon-reload, not the call; a plain install must work where systemctl is gone or no user manager is reachable
install_refresh_timer_units() {
    local unit path text changed=0
    if ! timer_check_values "${GSG_GIT%/*}" 2>/dev/null; then
        printf '%s: the timer units were not refreshed: a path or variable cannot be written into a systemd unit; run install --with-timer to see which\n' "$GSG_NAME" >&2
        return 0
    fi
    for unit in "$GSG_SERVICE_UNIT" "$GSG_TIMER_UNIT"; do
        path="$GSG_UNIT_DIR/$unit"
        if ! timer_unit_is_ours "$path"; then continue; fi
        if [ "$unit" = "$GSG_SERVICE_UNIT" ]; then text="$(timer_service_text "${GSG_GIT%/*}")"; else text="$(timer_timer_text)"; fi
        if [ "$(<"$path")" = "$text" ]; then continue; fi
        timer_write_unit "$path" "$text" || {
            printf '%s: could not rewrite %s; the hook is installed and scanning\n' "$GSG_NAME" "$path" >&2
            return 1
        }
        changed=1
    done
    if [ "$changed" -eq 1 ]; then
        printf '%s: updated the weekly doctor timer units in %s; the timer is left as it was, run systemctl --user daemon-reload to make systemd read them\n' "$GSG_NAME" "$GSG_UNIT_DIR"
    fi
}

# ^ order enable the timer after the hook config => a failing systemctl leaves the hook installed; state says timer_installed=yes before the units exist
install_enable_timer() {
    local rc
    if [ "$INSTALL_TIMER" -ne 1 ]; then return 0; fi
    if [ "$INSTALL_TIMER_ENABLE" -ne 1 ]; then
        install_refresh_timer_units
        return
    fi
    timer_write_units "${GSG_GIT%/*}" || {
        printf '%s: could not write the timer units into %s; the hook is installed and scanning\n' "$GSG_NAME" "$GSG_UNIT_DIR" >&2
        return 1
    }
    "$INSTALL_SYSTEMCTL_BIN" --user enable --now "$GSG_TIMER_UNIT"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s: could not enable %s (systemctl exit %s); the hook is installed and scanning; fix the cause and run install --with-timer again\n' \
            "$GSG_NAME" "$GSG_TIMER_UNIT" "$rc" >&2
        return 1
    fi
    printf '%s: weekly doctor timer enabled (%s); read its output with: journalctl --user -u %s\n' "$GSG_NAME" "$GSG_UNIT_DIR/$GSG_TIMER_UNIT" "$GSG_SERVICE_UNIT"
}

install_check_platform() {
    local tool
    GSG_OS="$(uname -s)" || return 1
    GSG_ARCH="$(uname -m)" || return 1
    for tool in trufflehog gitleaks; do
        tools_platform_key "$tool" "$GSG_OS" "$GSG_ARCH" >/dev/null || return 1
    done
}

# ^ invariant sets GSG_PREV_SET=yes|no and GSG_PREV = the value as written (a leading ~ stays ~); install only, others use lifecycle_read_hooks_path
# ^ security a value in a file install does not write (XDG, include) is refused even with --replace-hooks-path => it could be neither recorded nor unset
install_check_hooks_path() {
    local i
    GSG_PREV_SET=no
    GSG_PREV=""
    lifecycle_read_hooks_path || return 1
    for i in "${!GSG_HP_FOREIGN_FILE[@]}"; do
        printf '%s: core.hooksPath is set to [%s] in %s, a file install does not write to; remove it there and run install again; %s.\n' \
            "$GSG_NAME" "${GSG_HP_FOREIGN_VALUE[$i]}" "${GSG_HP_FOREIGN_FILE[$i]}" "$(brew_unchanged_text)" >&2
    done
    if [ "${#GSG_HP_FOREIGN_FILE[@]}" -gt 0 ]; then return 1; fi
    if [ "${#GSG_HP_OWN[@]}" -eq 0 ]; then return 0; fi
    if [ "${#GSG_HP_OWN[@]}" -ne 1 ]; then
        printf '%s: the global core.hooksPath has %s values; reduce it to one and run install again\n' "$GSG_NAME" "${#GSG_HP_OWN[@]}" >&2
        return 1
    fi
    if [[ ${GSG_HP_OWN[0]} == *$'\n'* ]]; then
        printf '%s: the global core.hooksPath contains a newline, which the state file cannot record\n' "$GSG_NAME" >&2
        return 1
    fi
    GSG_PREV_SET=yes
    GSG_PREV="${GSG_HP_OWN[0]}"
}

# ^ invariant ST_PLACED words = "<tool>:<sha256>"; two words for one tool = old and new hash of an unconfirmed placement
# ^ invariant an older state without tools_placed falls back to the newest tools_replaced hash of the tool
install_placed_hashes() {
    local w tool="$1" found=""
    local -a words=()
    read -r -a words <<<"$ST_PLACED"
    for w in "${words[@]}"; do
        if [ "${w%%:*}" = "$tool" ]; then found+="${found:+ }${w#*:}"; fi
    done
    if [ -z "$found" ]; then
        read -r -a words <<<"$ST_REPLACED"
        for w in "${words[@]}"; do
            if [[ $w == "$tool.gsg-replaced-"*:* ]]; then found="${w##*:}"; fi
        done
    fi
    printf '%s\n' "$found"
}

# ^ invariant true only for a regular file whose SHA-256 is ANY hash install recorded for the tool => install's own file, never a user's
install_owns_file() {
    local path="$GSG_BIN_DIR/$1" got h
    local -a want=()
    read -r -a want <<<"$(install_placed_hashes "$1")"
    if [ "${#want[@]}" -eq 0 ] || [ -L "$path" ] || [ ! -f "$path" ]; then return 1; fi
    got="$(sha256sum -- "$path" | cut -d' ' -f1)"
    if [ -z "$got" ]; then return 1; fi
    for h in "${want[@]}"; do
        if [ "$h" = "$got" ]; then return 0; fi
    done
    return 1
}

# ^ invariant a record whose aside file is gone is dropped here => a failed earlier run cannot hide the user's real original behind a stale record
install_prune_replaced() {
    local entry aside kept=""
    local -a words=()
    read -r -a words <<<"$ST_REPLACED"
    for entry in "${words[@]}"; do
        aside="${entry%:*}"
        if [[ $aside =~ $GSG_ASIDE_RE ]] && [ ! -e "$GSG_BIN_DIR/$aside" ] && [ ! -L "$GSG_BIN_DIR/$aside" ]; then
            printf '%s: %s is gone; its record is dropped\n' "$GSG_NAME" "$GSG_BIN_DIR/$aside" >&2
            continue
        fi
        kept+="${kept:+ }$entry"
    done
    ST_REPLACED="$kept"
}

# ^ order pure bash, no timeout needed => install_run calls it before the brew install, a missing or invalid lock row refuses with the machine untouched
# ^ invariant parallel arrays indexed like GSG_TOOL_NAMES, holding platform key, pinned version and SHA-256 from the lock
install_plan_lock() {
    local tool plat row lock
    GSG_TOOL_VER=() GSG_TOOL_SHA=() GSG_TOOL_PLAT=()
    lock="$(tools_lock_path)"
    for tool in "${GSG_TOOL_NAMES[@]}"; do
        plat="$(tools_platform_key "$tool" "$GSG_OS" "$GSG_ARCH")" || return 1
        row="$(tools_lock_lookup "$lock" "$tool" "$plat")" || return 1
        GSG_TOOL_PLAT+=("$plat")
        GSG_TOOL_VER+=("${row%% *}")
        GSG_TOOL_SHA+=("${row##* }")
    done
}

# ^ invariant parallel arrays indexed like GSG_TOOL_NAMES; NEED=1 means the pinned version is not in ~/.local/bin yet; needs install_plan_lock first
# ^ invariant ASIDE = name the user's file moves to (<tool>.gsg-replaced-<UTC stamp>); "" when the path is empty or holds install's own file, replaced in place
install_plan_tools() {
    local i tool stamp aside
    GSG_TOOL_NEED=() GSG_TOOL_ASIDE=()
    stamp="$(date -u +%Y%m%dT%H%M%SZ)" || return 1
    install_prune_replaced
    for i in "${!GSG_TOOL_NAMES[@]}"; do
        tool="${GSG_TOOL_NAMES[$i]}"
        aside=""
        if tools_has_version "$GSG_BIN_DIR/$tool" "${GSG_TOOL_VER[$i]}" "$INSTALL_TIMEOUT_BIN"; then
            GSG_TOOL_NEED+=(0)
        else
            GSG_TOOL_NEED+=(1)
            if { [ -e "$GSG_BIN_DIR/$tool" ] || [ -L "$GSG_BIN_DIR/$tool" ]; } && ! install_owns_file "$tool"; then aside="$tool.gsg-replaced-$stamp"; fi
        fi
        if [ -n "$aside" ] && { [ -e "$GSG_BIN_DIR/$aside" ] || [ -L "$GSG_BIN_DIR/$aside" ]; }; then
            printf '%s: %s already exists, so %s cannot be moved there; %s\n' "$GSG_NAME" "$GSG_BIN_DIR/$aside" "$GSG_BIN_DIR/$tool" "$(brew_unchanged_text)" >&2
            return 1
        fi
        GSG_TOOL_ASIDE+=("$aside")
    done
}

# shellcheck disable=SC2329
install_cleanup() {
    if [ -n "${GSG_STAGE:-}" ]; then rm -rf -- "$GSG_STAGE"; fi
    # ^ invariant GSG_SHARE_NEW is "" once the tree is renamed to the share dir => this never deletes the live share
    if [ -n "${GSG_SHARE_NEW:-}" ]; then rm -rf -- "$GSG_SHARE_NEW"; fi
}

# ^ invariant always returns 1; the closing line of a staging refusal, true before and after a brew install
install_stage_refused() {
    printf '%s: install refused; %s\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2
    return 1
}

# ^ order every needed tool is downloaded, verified and version-checked before any file leaves the staging dir => a bad second tool installs nothing
install_stage_tools() {
    local i tool tarball out
    GSG_STAGE=""
    if [[ " ${GSG_TOOL_NEED[*]} " != *" 1 "* ]]; then return 0; fi
    install_require_curl || install_stage_refused || return 1
    GSG_STAGE="$(mktemp -d)" || return 1
    mkdir -p -- "$GSG_STAGE/out" || return 1
    for i in "${!GSG_TOOL_NAMES[@]}"; do
        if [ "${GSG_TOOL_NEED[$i]}" -ne 1 ]; then continue; fi
        tool="${GSG_TOOL_NAMES[$i]}"
        tarball="$(tools_fetch_verified "$tool" "${GSG_TOOL_VER[$i]}" "${GSG_TOOL_PLAT[$i]}" "${GSG_TOOL_SHA[$i]}" "$GSG_STAGE")" || install_stage_refused || return 1
        tools_extract_binary "$tarball" "$tool" "$GSG_STAGE/out" || install_stage_refused || return 1
        if ! tools_has_version "$GSG_STAGE/out/$tool" "${GSG_TOOL_VER[$i]}" "$INSTALL_TIMEOUT_BIN"; then
            out="$("$INSTALL_TIMEOUT_BIN" "$GSG_VERSION_PROBE_SECONDS" "$GSG_STAGE/out/$tool" --version 2>&1 | head -c 200)"
            printf '%s: the extracted %s does not report version %s (it said: %s)\n' "$GSG_NAME" "$tool" "${GSG_TOOL_VER[$i]}" "${out//[^[:print:]]/?}" >&2
            install_stage_refused || return 1
        fi
    done
}

install_plan_and_stage() {
    install_plan_tools || return 1
    install_stage_tools || return 1
}

install_tools_ready() {
    if ! brew_is_macos; then
        install_plan_and_stage
        return
    fi
    # ^ order an existing GNU timeout lets the plan and the staging run before brew; without one the version probes wait for the brewed timeout
    if [ -n "$INSTALL_TIMEOUT_BIN" ]; then
        install_macos_use_gnubin || return 1
        install_plan_and_stage || return 1
        install_macos_finish
    else
        install_macos_finish || return 1
        install_plan_and_stage
    fi
}

install_hash_staged() {
    local i tool sha
    GSG_TOOL_NEWSHA=()
    for i in "${!GSG_TOOL_NAMES[@]}"; do
        GSG_TOOL_NEWSHA+=("")
        if [ "${GSG_TOOL_NEED[$i]}" -ne 1 ]; then continue; fi
        tool="${GSG_TOOL_NAMES[$i]}"
        sha="$(sha256sum -- "$GSG_STAGE/out/$tool" | cut -d' ' -f1)"
        if [ -z "$sha" ]; then
            printf '%s: cannot hash the staged %s\n' "$GSG_NAME" "$tool" >&2
            install_stage_refused || return 1
        fi
        GSG_TOOL_NEWSHA[i]="$sha"
    done
}

# ^ order install_write_state before install_commit_tools => every aside name and placed hash is recorded before a user's file moves
# ^ external coreutils 8.32 (el9) mv -n exits 0 when it skips => the move is verified by looking at both paths
install_commit_tools() {
    local i tool target aside new err
    mkdir -p -- "$GSG_BIN_DIR" || return 1
    for i in "${!GSG_TOOL_NAMES[@]}"; do
        if [ "${GSG_TOOL_NEED[$i]}" -ne 1 ]; then continue; fi
        tool="${GSG_TOOL_NAMES[$i]}"
        target="$GSG_BIN_DIR/$tool"
        aside="${GSG_TOOL_ASIDE[$i]}"
        new="$GSG_BIN_DIR/.$tool.gsg-new"
        # ^ why install -T, not a plain destination; a directory at $new would take the file inside it and the cleanup rm -f would add "Is a directory"
        # ^ why capture install's stderr, not let it through; coreutils prints its own line before ours, and the reason belongs inside the one message
        err="$(install -m 755 -T -- "$GSG_STAGE/out/$tool" "$new" 2>&1)" || {
            err="${err%%$'\n'*}"
            err="${err#install: }"
            err="${err//[[:cntrl:]]/?}"
            printf '%s: could not place %s (cannot write %s%s)\n' "$GSG_NAME" "$target" "$new" "${err:+: ${err:0:200}}" >&2
            return 1
        }
        if [ -n "$aside" ]; then
            mv -T -n -- "$target" "$GSG_BIN_DIR/$aside"
            if [ -e "$target" ] || [ -L "$target" ] || { [ ! -e "$GSG_BIN_DIR/$aside" ] && [ ! -L "$GSG_BIN_DIR/$aside" ]; }; then
                rm -f -- "$new"
                printf '%s: could not move %s aside to %s; your original was left where it was%s\n' "$GSG_NAME" "$target" "$GSG_BIN_DIR/$aside" \
                    "${BREW_INSTALLED:+; the Homebrew install of $BREW_INSTALLED in this run was kept}" >&2
                return 1
            fi
        fi
        mv -T -f -- "$new" "$target" || {
            rm -f -- "$new"
            printf '%s: could not place %s\n' "$GSG_NAME" "$target" >&2
            if [ -n "$aside" ] && ! mv -T -n -- "$GSG_BIN_DIR/$aside" "$target"; then
                printf '%s: your original is at %s\n' "$GSG_NAME" "$GSG_BIN_DIR/$aside" >&2
            fi
            return 1
        }
        if [ -n "$aside" ]; then
            printf '%s: %s does not report version %s; it was moved to %s (uninstall puts it back)\n' \
                "$GSG_NAME" "$target" "${GSG_TOOL_VER[$i]}" "$GSG_BIN_DIR/$aside"
        fi
    done
}

GSG_SHARE_ITEMS=(hooks lib bin tools.lock VERSION)
GSG_DEFAULT_SCAN_TIMEOUT=300

# ^ coupled tests/lib.sh:write_settings writes the same keys for the hook suites; lib/common.sh:load_settings reads and validates them
# ^ security values are printf %q quoted => the hook sources this file, a path with spaces or quotes cannot inject code
install_write_settings() {
    local i
    {
        printf '# generated by git-secret-guard install; every install rewrites this file\n'
        printf 'TRUFFLEHOG_BIN=%q\n' "$GSG_BIN_DIR/trufflehog"
        printf 'GITLEAKS_BIN=%q\n' "$GSG_BIN_DIR/gitleaks"
        printf 'JQ_BIN=%q\n' "$INSTALL_JQ_BIN"
        printf 'SETSID_BIN=%q\n' "$INSTALL_SETSID_BIN"
        printf 'TIMEOUT_BIN=%q\n' "$INSTALL_TIMEOUT_BIN"
        # ^ invariant every tool reported its pinned version (tools_has_version) before this file is written; the hook prints these and never runs --version
        for i in "${!GSG_TOOL_NAMES[@]}"; do
            printf '%s_VERSION=%q\n' "${GSG_TOOL_NAMES[$i]^^}" "${GSG_TOOL_VER[$i]}"
        done
        if [ -n "$INSTALL_BASH_BIN" ]; then printf 'BASH_BIN=%q\n' "$INSTALL_BASH_BIN"; fi
        if [ -n "$INSTALL_GNUBIN_DIR" ]; then printf 'GNUBIN_DIR=%q\n' "$INSTALL_GNUBIN_DIR"; fi
        if [ -n "$INSTALL_SYSTEMCTL_BIN" ]; then printf 'SYSTEMCTL_BIN=%q\n' "$INSTALL_SYSTEMCTL_BIN"; fi
        printf 'SCAN_TIMEOUT_SECONDS=%s\n' "$GSG_DEFAULT_SCAN_TIMEOUT"
    } >"$1"
}

# ^ order the new tree is complete before it replaces the share dir => a commit during an upgrade sees the old or the new hook, never half of either
install_copy_share() {
    local old item
    GSG_SHARE_NEW=""
    mkdir -p -- "${GSG_SHARE%/*}" || return 1
    GSG_SHARE_NEW="$(mktemp -d "$GSG_SHARE.new.XXXXXX")" || return 1
    chmod 755 -- "$GSG_SHARE_NEW" || return 1
    for item in "${GSG_SHARE_ITEMS[@]}"; do
        cp -a -- "$GSG_ROOT/$item" "$GSG_SHARE_NEW/" || return 1
    done
    install_write_settings "$GSG_SHARE_NEW/settings" || return 1
    if [ -e "$GSG_SHARE" ]; then
        old="$(mktemp -d "$GSG_SHARE.old.XXXXXX")" || return 1
        mv -- "$GSG_SHARE" "$old/previous" || {
            rmdir -- "$old"
            return 1
        }
        mv -- "$GSG_SHARE_NEW" "$GSG_SHARE" || {
            if mv -- "$old/previous" "$GSG_SHARE" && rmdir -- "$old"; then
                printf '%s: could not move the new share tree into place; restored the previous share dir\n' "$GSG_NAME" >&2
            else
                printf '%s: could not move the new share tree into place; the previous tree is at %s/previous\n' "$GSG_NAME" "$old" >&2
            fi
            return 1
        }
        GSG_SHARE_NEW=""
        rm -rf -- "$old" || printf '%s: could not remove the previous share tree %s; the upgrade is complete, delete that directory by hand\n' "$GSG_NAME" "$old" >&2
    else
        mv -- "$GSG_SHARE_NEW" "$GSG_SHARE" || return 1
        GSG_SHARE_NEW=""
    fi
}

install_check_cli_link() {
    local link="$GSG_BIN_DIR/git-secret-guard"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        printf '%s: %s exists and is not a symlink; remove it and run install again\n' "$GSG_NAME" "$link" >&2
        return 1
    fi
}

# ^ why a write probe, not git config --list; --list exits 128 for a missing file too = a normal fresh machine
# ^ order before the first download or copy => an unwritable global config leaves nothing half installed
install_check_config_writable() {
    if "$GSG_GIT" config --global gsg-install-probe.ok 1 2>/dev/null; then
        "$GSG_GIT" config --global --remove-section gsg-install-probe 2>/dev/null && return 0
    fi
    printf '%s: cannot write the global git config; %s\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2
    return 1
}

install_link_cli() {
    mkdir -p -- "$GSG_BIN_DIR" || return 1
    ln -sfn -- "$GSG_SHARE/bin/git-secret-guard" "$GSG_BIN_DIR/git-secret-guard"
}

GSG_BACKUP_MAX_BYTES=52428800
GSG_BACKUP_MAX_FILES=10000

# ^ external GNU find has -printf, BSD find does not; stat's format letter differs too (GNU -c %s, BSD -f %z) and a Mac's PATH may hold either stat
# ^ why sizes from stat or -printf, not find -ls; -ls prints owner and group as words, and a name with a space moves the size column
# ^ why find -print0 into xargs, not find -exec stat; find must write to the pipe itself => a closed pipe stops the walk through SIGPIPE
install_entry_sizes() {
    # ^ invariant prints one lstat size in bytes per entry below $1, nothing else; errors of find and stat are discarded, as the find -ls call did
    if find "$1" -maxdepth 0 -printf '' 2>/dev/null; then
        find "$1" -mindepth 1 -printf '%s\n' 2>/dev/null
    elif stat -c %s -- "$1" >/dev/null 2>&1; then
        find "$1" -mindepth 1 -print0 2>/dev/null | xargs -r -0 stat -c %s -- 2>/dev/null
    else
        find "$1" -mindepth 1 -print0 2>/dev/null | xargs -r -0 stat -f %z 2>/dev/null
    fi
}

# ^ why a bound on the backup, not an unbounded tar; a hooksPath of ~ or / would archive the whole home or disk into the state dir
# ^ invariant the walk stops at the first bound crossed => a huge tree is never read to the end; SIGPIPE kills the producer => pipefail is off in the subshell
install_check_backup_bounds() {
    local dir="$1" home verdict
    home="$(realpath -- "$HOME")" || return 1
    if [ "$dir" = / ]; then
        printf '%s: refusing to back up / (core.hooksPath points at the root directory); use a dedicated hooks directory\n' "$GSG_NAME" >&2
        return 1
    fi
    if [ "$dir" = "$home" ]; then
        printf '%s: refusing to back up %s: it is your home directory; use a dedicated hooks directory\n' "$GSG_NAME" "$dir" >&2
        return 1
    fi
    verdict="$(
        set +o pipefail
        install_entry_sizes "$dir" | awk -v max_files="$GSG_BACKUP_MAX_FILES" -v max_bytes="$GSG_BACKUP_MAX_BYTES" '
            { files++; bytes += $1 }
            files > max_files { print "files"; found = 1; exit }
            bytes > max_bytes { print "bytes"; found = 1; exit }
            END { if (!found) print "ok" }'
    )"
    case "$verdict" in
        ok) ;;
        files)
            printf '%s: refusing to back up %s: it holds more than %s files\n' "$GSG_NAME" "$dir" "$GSG_BACKUP_MAX_FILES" >&2
            return 1
            ;;
        bytes)
            printf '%s: refusing to back up %s: it is larger than %s bytes\n' "$GSG_NAME" "$dir" "$GSG_BACKUP_MAX_BYTES" >&2
            return 1
            ;;
        *)
            printf '%s: cannot measure %s for the backup\n' "$GSG_NAME" "$dir" >&2
            return 1
            ;;
    esac
}

# ^ invariant sets GSG_PREV_DIR = the real directory core.hooksPath resolves to, "" when none; a relative result is refused before any change
install_resolve_hooks_dir() {
    local expanded
    GSG_PREV_DIR=""
    if [ "$GSG_PREV_SET" != yes ] || [ -z "$GSG_PREV" ]; then return 0; fi
    expanded="$("$GSG_GIT" config --global --type=path --get core.hooksPath)" || {
        printf '%s: cannot expand the global core.hooksPath [%s]\n' "$GSG_NAME" "$GSG_PREV" >&2
        return 1
    }
    if [ "${expanded#/}" = "$expanded" ]; then
        printf '%s: core.hooksPath [%s] is relative (git resolves it per repository), so there is no one directory to back up; make it absolute and run install again\n' \
            "$GSG_NAME" "$GSG_PREV" >&2
        return 1
    fi
    if [ -d "$expanded" ]; then
        GSG_PREV_DIR="$(realpath -- "$expanded")" || return 1
        install_check_backup_bounds "$GSG_PREV_DIR" || {
            GSG_PREV_DIR=""
            return 1
        }
    else
        printf '%s: the directory core.hooksPath [%s] points to does not exist; nothing to back up\n' "$GSG_NAME" "$GSG_PREV"
    fi
}

# ^ security backup is written with umask 077 in the 700 state dir => hook scripts of the old setup stay private
install_backup_hooks_dir() {
    local stamp
    GSG_BACKUP_NEW=""
    if [ -z "$GSG_PREV_DIR" ]; then return 0; fi
    state_make_dir || return 1
    stamp="$(date -u +%Y%m%dT%H%M%SZ)" || return 1
    GSG_BACKUP_NEW="$(umask 077 && mktemp --suffix=.tar.gz "$GSG_STATE_DIR/hooks-path-backup-$stamp.XXXXXX")" || return 1
    tar -czf "$GSG_BACKUP_NEW" -C "${GSG_PREV_DIR%/*}" -- "${GSG_PREV_DIR##*/}" || {
        rm -f -- "$GSG_BACKUP_NEW"
        printf '%s: cannot back up %s; %s\n' "$GSG_NAME" "$GSG_PREV_DIR" "$(brew_unchanged_text)" >&2
        return 1
    }
    tar -tzf "$GSG_BACKUP_NEW" >/dev/null || return 1
    printf '%s: backed up %s to %s (it is left in place; uninstall keeps the backup)\n' "$GSG_NAME" "$GSG_PREV_DIR" "$GSG_BACKUP_NEW"
}

install_unset_hooks_path() {
    if [ "$GSG_PREV_SET" != yes ]; then return 0; fi
    "$GSG_GIT" config --global --unset-all core.hooksPath || {
        printf '%s: git could not unset the global core.hooksPath [%s]; the hook config is already installed and the old value is recorded; run install --replace-hooks-path again\n' \
            "$GSG_NAME" "$GSG_PREV" >&2
        return 1
    }
    printf '%s: core.hooksPath [%s] recorded verbatim and unset\n' "$GSG_NAME" "$GSG_PREV"
}

# ^ invariant prints the "<tool>:<sha256>" words of one tool; several words and one matching the file on disk => the match stays alone
install_tool_placed_words() {
    local tool="$1" w got path="$GSG_BIN_DIR/$1"
    local -a words=() mine=()
    read -r -a words <<<"$ST_PLACED"
    for w in "${words[@]}"; do
        if [ "${w%%:*}" = "$tool" ]; then mine+=("$w"); fi
    done
    if [ "${#mine[@]}" -gt 1 ] && [ -f "$path" ] && [ ! -L "$path" ]; then
        got="$(sha256sum -- "$path" | cut -d' ' -f1)"
        for w in "${mine[@]}"; do
            if [ -n "$got" ] && [ "${w#*:}" = "$got" ]; then
                mine=("$w")
                break
            fi
        done
    fi
    printf '%s\n' "${mine[*]}"
}

# ^ invariant prints the words of $1 once each, first occurrence first => a failed placement repeated any number of times cannot grow tools_placed
install_unique_words() {
    local w out=" "
    local -a words=()
    read -r -a words <<<"$1"
    for w in "${words[@]}"; do
        if [[ $out != *" $w "* ]]; then out+="$w "; fi
    done
    out="${out# }"
    printf '%s\n' "${out% }"
}

# ^ invariant a recorded hooksPath is never overwritten by a later install; "no" is replaced only by a real value taken over now
# ^ invariant tools_installed_by_us only grows on install (kept from state plus the ones downloaded now)
# ^ order write pending before install_commit_tools = old and new hash; write final after it = new hash only => a failed move never orphans install's own file
install_write_state() {
    local phase="$1" i tool kept prev_set=no prev="" tools="" backup="${GSG_BACKUP_NEW:-$ST_BACKUP}" replaced="$ST_REPLACED" placed="" timer=no
    if [ "$ST_PREV_SET" = yes ]; then
        prev_set=yes
        prev="$ST_PREV"
    elif [ "$GSG_PREV_SET" = yes ]; then
        prev_set=yes
        prev="$GSG_PREV"
    fi
    for i in "${!GSG_TOOL_NAMES[@]}"; do
        tool="${GSG_TOOL_NAMES[$i]}"
        kept="$(install_tool_placed_words "$tool")"
        if [ "${GSG_TOOL_NEED[$i]}" -eq 1 ]; then
            if [ "$phase" = pending ] && [ -n "$kept" ]; then placed+="${placed:+ }$kept"; fi
            placed+="${placed:+ }$tool:${GSG_TOOL_NEWSHA[$i]}"
            if [ -n "${GSG_TOOL_ASIDE[$i]}" ]; then replaced+="${replaced:+ }${GSG_TOOL_ASIDE[$i]}:${GSG_TOOL_NEWSHA[$i]}"; fi
            continue
        fi
        if [ -n "$kept" ]; then placed+="${placed:+ }$kept"; fi
    done
    for i in "${!GSG_TOOL_NAMES[@]}"; do
        tool="${GSG_TOOL_NAMES[$i]}"
        if [[ " $replaced " == *" $tool.gsg-replaced-"* ]]; then continue; fi
        if [[ " $ST_TOOLS " == *" $tool "* ]] || { [ "${GSG_TOOL_NEED[$i]}" -eq 1 ] && [ -z "${GSG_TOOL_ASIDE[$i]}" ]; }; then tools+="${tools:+ }$tool"; fi
    done
    if [ "$INSTALL_TIMER" -eq 1 ]; then timer=yes; fi
    placed="$(install_unique_words "$placed")"
    state_write "$(<"$GSG_ROOT/VERSION")" "$prev_set" "$prev" "$tools" "$backup" "$replaced" "$placed" "$timer"
}

# ^ why --replace-all, not a plain set; a plain set exits 5 when the key already has several values, and --add would duplicate the event
install_set_config() {
    local cmd
    cmd="$(hook_command_text "$GSG_SHARE" "$INSTALL_BASH_BIN")" || return 1
    "$GSG_GIT" config --global --replace-all hook.git-secret-guard.event pre-commit || return 1
    "$GSG_GIT" config --global --replace-all hook.git-secret-guard.command "$cmd" || return 1
}

install_summary() {
    local i tool hook_cmd
    printf '%s: installed %s %s\n' "$GSG_NAME" "$GSG_NAME" "$(<"$GSG_ROOT/VERSION")"
    hook_cmd="$(hook_command_text "$GSG_SHARE" "$INSTALL_BASH_BIN")" || return 1
    printf '%s: hook command: %s\n' "$GSG_NAME" "$hook_cmd"
    for i in "${!GSG_TOOL_NAMES[@]}"; do
        tool="${GSG_TOOL_NAMES[$i]}"
        if [ "${GSG_TOOL_NEED[$i]}" -eq 1 ]; then
            printf '%s: %s %s: downloaded, verified against tools.lock and installed to %s\n' "$GSG_NAME" "$tool" "${GSG_TOOL_VER[$i]}" "$GSG_BIN_DIR/$tool"
        else
            printf '%s: %s %s: kept %s (already at the pinned version)\n' "$GSG_NAME" "$tool" "${GSG_TOOL_VER[$i]}" "$GSG_BIN_DIR/$tool"
        fi
    done
}

# ^ invariant a recorded hooksPath stays the only record => a takeover of a different value is refused, never recorded or backed up half way
install_check_recorded_hooks_path() {
    if [ "$GSG_PREV_SET" != yes ] || [ "$ST_PREV_SET" != yes ] || [ "$GSG_PREV" = "$ST_PREV" ]; then return 0; fi
    printf '%s: the state already records the previous core.hooksPath [%s] but the global value is now [%s]; %s.\n' \
        "$GSG_NAME" "$ST_PREV" "$GSG_PREV" "$(brew_unchanged_text)" >&2
    printf '%s: run uninstall (it keeps the current value and the backup tarballs) and then install --replace-hooks-path to record the new value.\n' "$GSG_NAME" >&2
    return 1
}

install_run() {
    local replace="$1" timer="$2" claim
    brew_refuse_timer "$timer" || return 1
    paths_init || return 1
    lifecycle_note_global_config
    install_check_prerequisites "$timer" || return 1
    install_check_platform || return 1
    install_check_hooks_path || return 1
    install_check_cli_link || return 1
    if [ "$GSG_PREV_SET" = yes ] && [ "$replace" -ne 1 ]; then
        claim="install changes nothing and refuses"
        if [ -n "$BREW_INSTALLED" ]; then claim="install refuses ($(brew_unchanged_text))"; fi
        printf '%s: the global core.hooksPath is set to [%s]; %s.\n' "$GSG_NAME" "$GSG_PREV" "$claim" >&2
        printf '%s: run install --replace-hooks-path to record it, back up the directory it points to, and unset it.\n' "$GSG_NAME" >&2
        return 1
    fi
    trap install_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    install_resolve_hooks_dir || return 1
    install_check_config_writable || return 1
    state_read || return 1
    install_check_recorded_hooks_path || return 1
    install_prepare_timer "$timer" || return 1
    tools_announce_overrides
    install_plan_lock || return 1
    install_tools_ready || return 1
    install_hash_staged || return 1
    install_backup_hooks_dir || return 1
    install_write_state pending || return 1
    install_commit_tools || return 1
    install_write_state final || return 1
    install_copy_share || return 1
    install_link_cli || return 1
    install_set_config || return 1
    install_unset_hooks_path || return 1
    install_summary
    install_enable_timer
}
