# shellcheck shell=bash disable=SC2153

GSG_MIN_GIT_MAJOR=2
GSG_MIN_GIT_MINOR=54

# ^ external install-time lookups (type -P) are legitimate here; the hook never resolves a tool through PATH
# ^ see test:test_the_hook_never_looks_tools_up_on_PATH
install_git_version() {
    local out
    if brew_git_shim_unusable "$1"; then return 1; fi
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

# ^ invariant sets GSG_GIT = the absolute path of the first git on PATH, "" when there is none; prints nothing (the git upgrade decides what to say)
install_find_git() {
    GSG_GIT="$(type -P git)" || GSG_GIT=""
}

# ^ external the only lookup of the upgrade tools (sudo, dnf, rpm, restorecon, make, ldd); install-time only, the hook never resolves a tool through PATH
# ^ invariant install_find_bin NAME [PATH] sets REPLY = the absolute path of NAME on PATH or the given search path, "" when absent; rc 1 when absent
install_find_bin() {
    local found
    if [ -n "${2:-}" ]; then found="$(PATH="$2" type -P "$1")" || found=""; else found="$(type -P "$1")" || found=""; fi
    if [ "${found#/}" = "$found" ]; then found=""; fi
    REPLY="$found"
    [ -n "$found" ]
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

# ^ external GSG_OS_RELEASE names another file, for tests only; it changes the hint text and selects the git upgrade module, and the module announces it
# ^ invariant sets REPLY = ubuntu (ID or ID_LIKE names ubuntu), debian (names debian), rpm (names rhel, fedora, centos, rocky or almalinux) or other
# ^ invariant the first ID= and ID_LIKE= lines decide; a word is matched whole ("fedora-asahi" is not "fedora")
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
        *" rhel "* | *" fedora "* | *" centos "* | *" rocky "* | *" almalinux "*) REPLY=rpm ;;
    esac
}

# ^ invariant prints the end of a "was not found" message for package $1; apt on Ubuntu and Debian, the package manager elsewhere
install_fix_hint() {
    if tools_is_windows; then
        printf 'it comes with Windows or Git for Windows, so check that PATH holds their directories'
        return 0
    fi
    install_os_family
    case "$REPLY" in
        ubuntu | debian) printf 'install it with: sudo apt install %s' "$1" ;;
        rpm) printf 'install it with: sudo dnf install %s' "$1" ;;
        *) printf 'install it with your package manager' ;;
    esac
}

# ^ external ppa:git-core/ppa carries git >= 2.54 for Ubuntu only; Ubuntu 24.04 ships 2.43; the build path is in docs/platforms.md
install_git_hint() {
    if tools_is_windows; then
        printf '%s: update Git for Windows to git >= 2.54 with: winget upgrade Git.Git, then open a new terminal\n' "$GSG_NAME" >&2
        return 0
    fi
    install_os_family
    if brew_is_macos; then
        printf '%s: on macOS run: %s install --upgrade-git; it installs or upgrades git with Homebrew, see docs/platforms.md\n' "$GSG_NAME" "$GSG_NAME" >&2
        return 0
    fi
    case "$REPLY" in
        ubuntu)
            printf '%s: on Ubuntu run: %s install --upgrade-git; it takes git >= 2.54 from your repositories or the git-core PPA, or builds the pinned source, see docs/platforms.md\n' \
                "$GSG_NAME" "$GSG_NAME" >&2
            printf '%s: by hand: sudo add-apt-repository ppa:git-core/ppa && sudo apt install git (add-apt-repository comes from the software-properties-common package)\n' "$GSG_NAME" >&2
            ;;
        debian)
            printf '%s: on Debian run: %s install --upgrade-git; it takes git >= 2.54 from your repositories or builds the pinned source (Debian has no PPA), see docs/platforms.md\n' \
                "$GSG_NAME" "$GSG_NAME" >&2
            ;;
        rpm)
            printf '%s: on RHEL-compatible systems and Fedora, run: %s install --upgrade-git; it takes git >= 2.54 from your repositories or builds the pinned source, see docs/platforms.md\n' \
                "$GSG_NAME" "$GSG_NAME" >&2
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

# ^ external GitHub Desktop for Linux ships its own git here (2.45.3 on the reference host); GITUP_ROOT moves it into a test sandbox
install_bundled_git_path() { printf '%s/usr/lib/github-desktop/resources/app/git/bin/git' "${GITUP_ROOT:-}"; }

# ^ invariant true for the git GitHub Desktop bundles; whether its commits reach the hook is untested => no text claims they are skipped
install_git_is_bundled() { [ "$1" = "$(install_bundled_git_path)" ]; }

# ^ invariant prints why a git older than 2.54 matters; the bundled git gets only the missing test said, any other git the certain claim
install_old_git_effect() {
    if install_git_is_bundled "$1"; then
        printf 'it is the git GitHub Desktop bundles, config-based hooks need git >= 2.54, and whether commits made with it are scanned has not been tested'
    else
        printf 'it ignores config-based hooks without any message, so commits made with it are not scanned'
    fi
}

# ^ invariant sets GSG_GIT_CANDIDATES = every executable git on PATH plus /usr/bin/git and GitHub Desktop's, one path per real file; GSG_GIT_REAL is parallel
install_collect_gits() {
    local cand real seen=" "
    local -a cands=()
    GSG_GIT_CANDIDATES=() GSG_GIT_REAL=()
    mapfile -t cands < <(type -aP git)
    cands+=("${GITUP_USRBIN:-/usr/bin}/git")
    cands+=("$(install_bundled_git_path)")
    for cand in "${cands[@]}"; do
        if [ ! -x "$cand" ]; then continue; fi
        real="$(realpath -- "$cand")" || continue
        if [[ $seen == *" $real "* ]]; then continue; fi
        seen+="$real "
        GSG_GIT_CANDIDATES+=("$cand")
        GSG_GIT_REAL+=("$real")
    done
}

# ^ invariant sets GSG_GIT_USED = the real path of the git on PATH; a path realpath cannot resolve is a refusal naming what changed
install_check_git_real() {
    GSG_GIT_USED="$(realpath -- "$GSG_GIT")" || {
        printf '%s: cannot resolve the real path of %s; install refused, %s\n' "$GSG_NAME" "$GSG_GIT" "$(brew_unchanged_text)" >&2
        return 1
    }
}

# ^ external a git older than 2.54 ignores hook.<name>.* config without any message (verified on /usr/bin/git 2.52); warning only, the PATH git decides
# ^ order runs after the git upgrade offers and install_check_git_real, and a takeover of /usr/bin/git leaves nothing to warn about
install_report_other_gits() {
    local i cand ver
    install_collect_gits
    for i in "${!GSG_GIT_CANDIDATES[@]}"; do
        cand="${GSG_GIT_CANDIDATES[$i]}"
        if [ "${GSG_GIT_REAL[$i]}" = "$GSG_GIT_USED" ]; then continue; fi
        if install_git_is_new_enough "$cand"; then continue; fi
        ver="$(install_git_version "$cand")" || ver="of unknown version"
        printf '%s: warning: %s is git %s; %s (the git in use is %s, git %s)%s\n' \
            "$GSG_NAME" "$cand" "$ver" "$(install_old_git_effect "$cand")" "$GSG_GIT" "$(install_git_version "$GSG_GIT")" "$(gitup_takeover_note "$cand")" >&2
        brew_old_git_note "$cand"
    done
}

# ^ security absolute paths found now are written to settings => the hook never resolves jq, setsid or timeout through PATH
install_resolve_bins() {
    local name path bad=0
    local -A package=([jq]=jq [setsid]=util-linux [taskkill]=taskkill [timeout]=coreutils)
    local -a names=(jq setsid timeout)
    INSTALL_SETSID_BIN="" INSTALL_TASKKILL_BIN="" INSTALL_JQ_WRAPPER="" INSTALL_JQ_BIN=""
    if tools_is_windows; then names=(jq taskkill timeout); fi
    for name in "${names[@]}"; do
        path="$(type -P "$name")" || {
            # ^ why install_manage_jq, not a refusal; winget is absent on Windows Server, the pinned jq is verified like a scanner
            if [ "$name" = jq ] && tools_is_windows; then continue; fi
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
            taskkill) INSTALL_TASKKILL_BIN="$path" ;;
            timeout) INSTALL_TIMEOUT_BIN="$path" ;;
        esac
    done
    if tools_is_windows && [ -n "${INSTALL_JQ_BIN:-}" ]; then INSTALL_JQ_WRAPPER="$GSG_SHARE/jq"; fi
    return "$bad"
}

# ^ external a native jq.exe writes CRLF unless given -b => rows end in a carriage return; on Windows JQ_BIN is this wrapper adding -b
# ^ security the wrapper holds the absolute jq path found at install time, quoted with printf %q => it never looks jq up on PATH
install_write_jq_wrapper() {
    local file="$1" real="$2"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'exec %q -b "$@"\n' "$real"
    } >"$file" || return 1
    chmod 755 -- "$file"
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
    if tools_is_windows && [ -z "$INSTALL_JQ_BIN" ]; then return 0; fi
    os="$(uname -s)" && arch="$(uname -m)" || return 1
    for tool in "${GSG_TOOL_NAMES[@]}"; do
        plat="$(tools_platform_key "$tool" "$os" "$arch" 2>/dev/null)" || return 1
        row="$(tools_lock_lookup "$(tools_lock_path)" "$tool" "$plat" 2>/dev/null)" || return 1
        if ! tools_has_version "$GSG_BIN_DIR/$(tools_binary_name "$tool")" "${row%% *}" "$INSTALL_TIMEOUT_BIN"; then return 0; fi
    done
    return 1
}

# ^ order every prerequisite is checked and reported before any change => one refusal names them all; test:test_every_missing_prerequisite_is_named_at_once
install_check_prerequisites() {
    local timer="$1" bad=0 claim
    INSTALL_TIMEOUT_BIN="" INSTALL_BASH_BIN="" INSTALL_GNUBIN_DIR=""
    GITUP_PENDING=0
    # ^ order an old or missing git is recorded, not refused, before the checks below, and every other check still runs and is reported with it
    gitup_defers_git
    case $? in
        0) GITUP_PENDING=1 ;;
        2) bad=$((bad + 1)) ;;
        *)
            if install_require_git; then
                install_check_git_real || bad=$((bad + 1))
            else
                bad=$((bad + 1))
            fi
            ;;
    esac
    if brew_is_macos; then
        install_macos_inspect || bad=$((bad + 1))
    else
        install_resolve_bins || bad=$((bad + $?))
    fi
    if install_downloads_needed; then install_require_curl || bad=$((bad + 1)); fi
    # ^ order the timer manager check (systemctl, launchctl on macOS) runs after every other check; bad > 1 => the count line carries the claim
    if [ "$timer" -eq 1 ] && tools_is_windows; then
        claim="; $(brew_unchanged_text)"
        if [ "$bad" -gt 0 ]; then claim=""; fi
        printf '%s: --with-timer needs systemd, which Windows does not have%s\n' "$GSG_NAME" "$claim" >&2
        bad=$((bad + 1))
    elif [ "$timer" -eq 1 ]; then
        if [ "$bad" -gt 0 ]; then install_find_timer_bin counted >/dev/null || bad=$((bad + 1)); else install_find_timer_bin >/dev/null || bad=$((bad + 1)); fi
    fi
    if [ "$bad" -gt 1 ]; then printf '%s: %s prerequisites are missing; install refused, %s\n' "$GSG_NAME" "$bad" "$(brew_unchanged_text)" >&2; fi
    if [ "$bad" -eq 1 ] && [ -n "$BREW_INSTALLED" ]; then printf '%s: install refused; %s\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2; fi
    if [ "$bad" -gt 0 ] && [ "$GITUP_PENDING" -eq 1 ]; then
        printf '%s: %s; once the problems above are fixed install offers to upgrade it (%s install --upgrade-git)\n' "$GSG_NAME" "$(gitup_describe_git)" "$GSG_NAME" >&2
    fi
    [ "$bad" -eq 0 ]
}

# ^ external the only type -P of systemctl and of launchctl; the absolute path goes to the settings, uninstall and doctor never look it up on PATH
# ^ invariant sets REPLY = the absolute path of launchctl on macOS, of systemctl elsewhere; a missing or relative one prints its hint and returns 1
install_find_timer_bin() {
    local found tool hint claim
    claim="; $(brew_unchanged_text)"
    if [ "${1:-}" = counted ]; then claim=""; fi
    if brew_is_macos; then
        tool=launchctl
        found="$(type -P launchctl)" || found=""
        hint="launchctl ships with macOS in /bin"
    else
        tool=systemctl
        found="$(type -P systemctl)" || found=""
        hint="$(install_fix_hint systemd)"
    fi
    if [ -z "$found" ]; then
        printf '%s: %s is required for --with-timer but was not found on PATH%s (%s)\n' "$GSG_NAME" "$tool" "$claim" "$hint" >&2
        return 1
    fi
    if [ "${found#/}" = "$found" ]; then
        printf '%s: %s resolved to a relative path [%s]; fix PATH\n' "$GSG_NAME" "$tool" "$found" >&2
        return 1
    fi
    REPLY="$found"
}

# ^ invariant sets INSTALL_TIMER (1 = state records a timer), INSTALL_TIMER_ENABLE (1 = write and enable, --with-timer only), INSTALL_TIMER_BIN
# ^ invariant INSTALL_TIMER_BIN = systemctl, launchctl on macOS; a plain install over a recorded timer neither enables nor needs it, keeps the recorded path
install_prepare_timer() {
    local want="$1" found
    INSTALL_TIMER=0 INSTALL_TIMER_ENABLE=0 INSTALL_TIMER_BIN=""
    if [ "$want" -ne 1 ] && [ "$ST_TIMER" != yes ]; then return 0; fi
    if [ "$want" -ne 1 ]; then
        if install_find_timer_bin 2>/dev/null; then found="$REPLY"; else found=""; fi
        INSTALL_TIMER_BIN="${found:-$(install_recorded_timer_bin)}"
        INSTALL_TIMER=1
        return 0
    fi
    install_find_timer_bin || return 1
    INSTALL_TIMER_BIN="$REPLY"
    if brew_is_macos; then
        launchd_check_target "${GSG_GIT%/*}" || return 1
    else
        timer_check_target "${GSG_GIT%/*}" || return 1
    fi
    INSTALL_TIMER=1 INSTALL_TIMER_ENABLE=1
}

# ^ invariant prints LAUNCHCTL_BIN (macOS) or SYSTEMCTL_BIN from the settings file of the installed copy, "" when there is none
install_recorded_timer_bin() {
    (
        load_settings "$GSG_SHARE/settings" >/dev/null 2>&1 || exit 0
        if brew_is_macos; then printf '%s' "${LAUNCHCTL_BIN:-}"; else printf '%s' "${SYSTEMCTL_BIN:-}"; fi
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
    if brew_is_macos; then
        launchd_enable
        return
    fi
    if [ "$INSTALL_TIMER_ENABLE" -ne 1 ]; then
        install_refresh_timer_units
        return
    fi
    timer_write_units "${GSG_GIT%/*}" || {
        printf '%s: could not write the timer units into %s; the hook is installed and scanning\n' "$GSG_NAME" "$GSG_UNIT_DIR" >&2
        return 1
    }
    "$INSTALL_TIMER_BIN" --user enable --now "$GSG_TIMER_UNIT"
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
    for tool in trufflehog betterleaks; do
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

GSG_SHARE_ITEMS=(hooks lib bin tools.lock VERSION)
GSG_DEFAULT_SCAN_TIMEOUT=300

# ^ coupled tests/lib.sh:write_settings writes the same keys for the hook suites; lib/common.sh:load_settings reads and validates them
# ^ security values are printf %q quoted => the hook sources this file, a path with spaces or quotes cannot inject code
install_write_settings() {
    local i
    {
        printf '# generated by git-secret-guard install; every install rewrites this file\n'
        printf 'TRUFFLEHOG_BIN=%q\n' "$GSG_BIN_DIR/$(tools_binary_name trufflehog)"
        printf 'BETTERLEAKS_BIN=%q\n' "$GSG_BIN_DIR/$(tools_binary_name betterleaks)"
        printf 'JQ_BIN=%q\n' "${INSTALL_JQ_WRAPPER:-$INSTALL_JQ_BIN}"
        if [ -n "${INSTALL_SETSID_BIN:-}" ]; then printf 'SETSID_BIN=%q\n' "$INSTALL_SETSID_BIN"; fi
        if [ -n "${INSTALL_TASKKILL_BIN:-}" ]; then printf 'TASKKILL_BIN=%q\n' "$INSTALL_TASKKILL_BIN"; fi
        printf 'TIMEOUT_BIN=%q\n' "$INSTALL_TIMEOUT_BIN"
        # ^ invariant every tool reported its pinned version (tools_has_version) before this file is written; the hook prints these and never runs --version
        for i in "${!GSG_TOOL_NAMES[@]}"; do
            if [ "${GSG_TOOL_NAMES[$i]}" = jq ]; then continue; fi
            printf '%s_VERSION=%q\n' "${GSG_TOOL_NAMES[$i]^^}" "${GSG_TOOL_VER[$i]}"
        done
        if [ -n "$INSTALL_BASH_BIN" ]; then printf 'BASH_BIN=%q\n' "$INSTALL_BASH_BIN"; fi
        if [ -n "$INSTALL_GNUBIN_DIR" ]; then printf 'GNUBIN_DIR=%q\n' "$INSTALL_GNUBIN_DIR"; fi
        if [ -n "$INSTALL_TIMER_BIN" ] && brew_is_macos; then printf 'LAUNCHCTL_BIN=%q\n' "$INSTALL_TIMER_BIN"; fi
        if [ -n "$INSTALL_TIMER_BIN" ] && ! brew_is_macos; then printf 'SYSTEMCTL_BIN=%q\n' "$INSTALL_TIMER_BIN"; fi
        printf 'SCAN_TIMEOUT_SECONDS=%s\n' "$GSG_DEFAULT_SCAN_TIMEOUT"
    } >"$1"
}

# ^ order the new tree is complete before it replaces the share dir => a commit during an upgrade sees the old or the new hook, never half of either
install_copy_share() {
    local old item
    GSG_SHARE_NEW=""
    # ^ external Windows refuses to rename a directory with a running script in it (probed) => from the installed copy only generated files change
    if install_pins_running_script && [ "$GSG_ROOT" -ef "$GSG_SHARE" ]; then
        install_write_settings "$GSG_SHARE/settings.new" && mv -T -f -- "$GSG_SHARE/settings.new" "$GSG_SHARE/settings" || return 1
        if [ -n "${INSTALL_JQ_WRAPPER:-}" ]; then install_write_jq_wrapper "$GSG_SHARE/jq" "$INSTALL_JQ_BIN" || return 1; fi
        return 0
    fi
    mkdir -p -- "${GSG_SHARE%/*}" || return 1
    GSG_SHARE_NEW="$(mktemp -d "$GSG_SHARE.new.XXXXXX")" || return 1
    chmod 755 -- "$GSG_SHARE_NEW" || return 1
    for item in "${GSG_SHARE_ITEMS[@]}"; do
        cp -a -- "$GSG_ROOT/$item" "$GSG_SHARE_NEW/" || return 1
    done
    # ^ security cp -a keeps the modes of the checkout (777 on a WSL drive) => nothing the hook sources or runs may stay writable by group or others
    chmod -R go-w -- "$GSG_SHARE_NEW" || return 1
    install_write_settings "$GSG_SHARE_NEW/settings" || return 1
    if [ -n "${INSTALL_JQ_WRAPPER:-}" ]; then install_write_jq_wrapper "$GSG_SHARE_NEW/jq" "$INSTALL_JQ_BIN" || return 1; fi
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

# ^ external Git Bash ln -s copies the file instead of linking (probed) => on Windows the CLI entry is a wrapper script running the share copy with exec
install_cli_wrapper_text() {
    printf '#!/usr/bin/env bash\n'
    printf 'exec %q "$@"\n' "$GSG_SHARE/bin/git-secret-guard"
}

GSG_CLI_CMD_MARKER='rem git-secret-guard: written by install, every install rewrites this file'

# ^ external cmd and PowerShell cannot start the bash wrapper => a .cmd beside it; Git's bin\bash.exe sets up PATH, usr\bin\bash.exe does not
# ^ hazard uninstall removes the share under this running file => it deletes itself with the (goto) idiom; a plain rm ends in "batch file cannot be found"
# ^ invariant prints CRLF lines; % is doubled => cmd reads a literal percent sign in a path
install_cli_cmd_text() {
    local root share_win share_mixed bash_win
    root="$(cygpath -w /)" || return 1
    share_win="$(cygpath -w "$GSG_SHARE")" || return 1
    share_mixed="$(cygpath -m "$GSG_SHARE")" || return 1
    bash_win="${root%\\}\\bin\\bash.exe"
    printf '%s\r\n' '@echo off' "$GSG_CLI_CMD_MARKER" setlocal 'set "GSG_CMD_ENTRY=%~f0"' \
        "\"${bash_win//%/%%}\" \"${share_mixed//%/%%}/bin/git-secret-guard\" %*" 'set "GSG_RC=%errorlevel%"' \
        "if not exist \"${share_win//%/%%}\\bin\\git-secret-guard\" (goto) 2>nul & del \"%~f0\"" 'exit /b %GSG_RC%'
}

# ^ invariant true only for a file install_cli_cmd_text wrote; the second line is the marker, whatever paths it names
install_cli_cmd_is_ours() {
    local line
    { read -r line && read -r line; } <"$1" || return 1
    [ "${line%$'\r'}" = "$GSG_CLI_CMD_MARKER" ]
}

# ^ invariant on Windows only a file written by install_cli_wrapper_text counts as ours, whatever share path it names => any other file is refused
install_check_cli_link() {
    local link="$GSG_BIN_DIR/git-secret-guard"
    if tools_is_windows; then
        if [ -e "$link" ] && [[ "$(<"$link")" != "#!/usr/bin/env bash"$'\n'"exec "*"/bin/git-secret-guard "'"$@"' ]]; then
            printf '%s: %s exists and is not the wrapper install writes; remove it and run install again\n' "$GSG_NAME" "$link" >&2
            return 1
        fi
        if [ -e "$link.cmd" ] && ! install_cli_cmd_is_ours "$link.cmd"; then
            printf '%s: %s exists and is not the wrapper install writes; remove it and run install again\n' "$GSG_NAME" "$link.cmd" >&2
            return 1
        fi
        return 0
    fi
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        printf '%s: %s exists and is not a symlink; remove it and run install again\n' "$GSG_NAME" "$link" >&2
        return 1
    fi
}

install_link_cli() {
    local link="$GSG_BIN_DIR/git-secret-guard" tmp
    mkdir -p -- "$GSG_BIN_DIR" || return 1
    if tools_is_windows; then
        tmp="$link.gsg-new"
        install_cli_wrapper_text >"$tmp" || return 1
        chmod 755 -- "$tmp" || {
            rm -f -- "$tmp"
            return 1
        }
        mv -T -f -- "$tmp" "$link" || return 1
        install_cli_cmd_text >"$tmp" || {
            rm -f -- "$tmp"
            return 1
        }
        mv -T -f -- "$tmp" "$link.cmd"
        return
    fi
    ln -sfn -- "$GSG_SHARE/bin/git-secret-guard" "$link"
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
    # ^ external native Windows git expands to C:/dir => the absolute check and the backup below need the POSIX form
    if [[ $expanded == [A-Za-z]:/* ]] && tools_is_windows; then expanded="$(cygpath -u "$expanded")" || return 1; fi
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
    local tool="$1" w got path
    local -a words=() mine=()
    path="$GSG_BIN_DIR/$(tools_binary_name "$tool")"
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
    for tool in "${GSG_LEGACY_TOOL_NAMES[@]}"; do
        if [[ " $ST_TOOLS " == *" $tool "* ]] && [[ " $GSG_LEGACY_PLACED " == *" $tool:"* ]]; then tools+="${tools:+ }$tool"; fi
    done
    if [ -n "$GSG_LEGACY_PLACED" ]; then placed+="${placed:+ }$GSG_LEGACY_PLACED"; fi
    if [ "$INSTALL_TIMER" -eq 1 ]; then timer=yes; fi
    placed="$(install_unique_words "$placed")"
    state_write "$(<"$GSG_ROOT/VERSION")" "$prev_set" "$prev" "$tools" "$backup" "$replaced" "$placed" "$timer"
}

# ^ invariant GSG_LEGACY_PLACED = tools_placed words of tools an earlier build installed (gitleaks); kept until install_retire_legacy_tools settles them
GSG_LEGACY_PLACED=""
GSG_LEGACY_CHANGED=0

install_path_present() { [ -e "$1" ] || [ -L "$1" ]; }

install_note_legacy() {
    local w tool
    local -a words=()
    GSG_LEGACY_PLACED=""
    read -r -a words <<<"$ST_PLACED"
    for w in "${words[@]}"; do
        tool="${w%%:*}"
        if [[ " ${GSG_LEGACY_TOOL_NAMES[*]} " == *" $tool "* ]]; then GSG_LEGACY_PLACED+="${GSG_LEGACY_PLACED:+ }$w"; fi
    done
}

# ^ invariant a legacy tool is removed only when install_owns_file proves its hash was recorded; any other file at the path is the user's and stays
# ^ invariant the user's moved-aside original comes back only onto an empty path; every record not restored stays, a record whose aside file is gone goes
# ^ external coreutils 8.32 (el9) mv -n exits 0 when it skips => the restore is verified by looking at both paths
install_retire_legacy_tool() {
    local tool="$1" path w aside asidepath kept="" restored=0 foreign=0
    path="$GSG_BIN_DIR/$(tools_binary_name "$tool")"
    local -a words=()
    if install_path_present "$path"; then
        if install_owns_file "$tool"; then
            rm -f -- "$path" || return 1
            GSG_LEGACY_CHANGED=1
            printf '%s: removed %s (placed by an earlier install; git-secret-guard scans with betterleaks now)\n' "$GSG_NAME" "$path"
            # ^ order the state loses the placed hash before the user's file comes back => a rerun after an interruption cannot match and delete it
            read -r -a words <<<"$GSG_LEGACY_PLACED"
            GSG_LEGACY_PLACED=""
            for w in "${words[@]}"; do
                if [[ $w != "$tool:"* ]]; then GSG_LEGACY_PLACED+="${GSG_LEGACY_PLACED:+ }$w"; fi
            done
            install_write_state final || return 1
        else
            foreign=1
            printf '%s: %s is not the file an earlier install placed; left in place (git-secret-guard no longer uses it)\n' "$GSG_NAME" "$path"
        fi
    fi
    read -r -a words <<<"$ST_REPLACED"
    for w in "${words[@]}"; do
        aside="${w%:*}"
        asidepath="$GSG_BIN_DIR/$aside"
        if [[ $aside != "$tool.gsg-replaced-"* ]]; then
            kept+="${kept:+ }$w"
        elif ! install_path_present "$asidepath"; then
            GSG_LEGACY_CHANGED=1
        elif [ "$foreign" -eq 1 ] || [ "$restored" -eq 1 ]; then
            kept+="${kept:+ }$w"
            if [ "$foreign" -eq 1 ]; then printf '%s: your original %s stays at %s\n' "$GSG_NAME" "$tool" "$asidepath"; fi
        else
            mv -n -- "$asidepath" "$path"
            if ! install_path_present "$path" || install_path_present "$asidepath"; then
                printf '%s: could not move your original %s back to %s\n' "$GSG_NAME" "$asidepath" "$path" >&2
                return 1
            fi
            restored=1
            GSG_LEGACY_CHANGED=1
            printf '%s: restored %s from %s (the file you had before the first install)\n' "$GSG_NAME" "$path" "$asidepath"
        fi
    done
    ST_REPLACED="$kept"
}

# ^ order runs after the new hook is live => no commit in the upgrade window finds the scanner its settings name gone
# ^ invariant a failed retirement returns before the clear => the placed hashes stay in the state and the next install retries
install_retire_legacy_tools() {
    local tool
    GSG_LEGACY_CHANGED=0
    for tool in "${GSG_LEGACY_TOOL_NAMES[@]}"; do
        if [[ " $GSG_LEGACY_PLACED " != *" $tool:"* ]] && [[ " $ST_REPLACED " != *" $tool.gsg-replaced-"* ]]; then continue; fi
        install_retire_legacy_tool "$tool" || return 1
    done
    if [ -n "$GSG_LEGACY_PLACED" ]; then GSG_LEGACY_CHANGED=1; fi
    GSG_LEGACY_PLACED=""
    if [ "$GSG_LEGACY_CHANGED" -eq 1 ]; then install_write_state final || return 1; fi
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
            printf '%s: %s %s: downloaded, verified against tools.lock and installed to %s\n' "$GSG_NAME" "$tool" "${GSG_TOOL_VER[$i]}" "$GSG_BIN_DIR/$(tools_binary_name "$tool")"
        else
            printf '%s: %s %s: kept %s (already at the pinned version)\n' "$GSG_NAME" "$tool" "${GSG_TOOL_VER[$i]}" "$GSG_BIN_DIR/$(tools_binary_name "$tool")"
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

# ^ invariant refuses a recorded global core.hooksPath without --replace-hooks-path; the claim also covers a Homebrew install or a git upgrade of this run
install_refuse_hooks_path() {
    local claim
    claim="install changes nothing and refuses"
    if [ "$GSG_PREV_SET" != yes ] || [ "$1" -eq 1 ]; then return 0; fi
    if [ -n "$BREW_INSTALLED${GITUP_CHANGED:-}" ]; then claim="install refuses ($(brew_unchanged_text))"; fi
    printf '%s: the global core.hooksPath is set to [%s]; %s.\n' "$GSG_NAME" "$GSG_PREV" "$claim" >&2
    printf '%s: run install --replace-hooks-path to record it, back up the directory it points to, and unset it.\n' "$GSG_NAME" >&2
    return 1
}

# ^ invariant the refusable checks needing a git (global config, state) run before the git offers if the git can read them, otherwise after
# ^ coupled a refusal here after an upgrade of this run names the upgrade through gitup_report_changes, for the checks whose own text does not
install_run_state_checks() {
    install_resolve_hooks_dir || {
        gitup_report_changes
        return 1
    }
    install_check_config_writable || return 1
    state_read || {
        gitup_report_changes
        return 1
    }
    install_note_legacy
    install_manage_jq
    install_check_recorded_hooks_path || return 1
    install_plan_lock || {
        gitup_report_changes
        return 1
    }
}

# ^ external git 2.26 added config --show-scope, used by lifecycle_read_hooks_path; an older git has its hooks-path checks after the upgrade
INSTALL_HP_MIN_GIT=2.26

# ^ order the timer or agent checks run before the git offers; the git directory is the only value an upgrade changes (it installs under /usr/local/bin)
# ^ invariant $1 = 1 when --with-timer was given; the later install_prepare_timer repeats the check with the final git directory
install_precheck_timer() {
    local dir="/usr/local/bin"
    if [ "$1" -ne 1 ]; then return 0; fi
    wsl_check_timer "$1" || return 1
    if [ -n "$GSG_GIT" ]; then dir="${GSG_GIT%/*}"; fi
    if brew_is_macos; then launchd_check_target "$dir"; else timer_check_target "$dir"; fi
}

# ^ order the git offers run after every refusable check a git can run; a missing git, or one too old for --show-scope, runs them after the offers
# ^ invariant install_run returns 3 when a git upgrade module hands off to finish outside this process
install_run() {
    local replace="$1" timer="$2" upgrade="${3:-0}" takeover="${4:-0}" early=0 ver
    # ^ security umask only tightens (022 or stricter) => settings, share tree, CLI link and state are never group or other writable; WSL 1 starts at 0000
    umask "$(printf '%03o' "$((8#$(umask) | 8#022))")"
    paths_init || return 1
    lifecycle_note_global_config
    trap install_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    install_check_prerequisites "$timer" || return 1
    install_check_platform || return 1
    if [ -n "$GSG_GIT" ] && ver="$(install_git_version "$GSG_GIT")" && gitup_version_at_least "$ver" "$INSTALL_HP_MIN_GIT"; then early=1; fi
    if [ "$early" -eq 1 ]; then install_check_hooks_path || return 1; fi
    install_check_cli_link || return 1
    install_precheck_timer "$timer" || return 1
    if [ "$early" -eq 1 ]; then
        install_refuse_hooks_path "$replace" || return 1
        install_run_state_checks || return 1
    fi
    gitup_offers "$upgrade" "$takeover" || return $?
    if [ "$early" -eq 0 ]; then
        install_check_hooks_path || return 1
        install_refuse_hooks_path "$replace" || return 1
    fi
    install_check_git_real || return 1
    install_report_other_gits || return 1
    if [ "$early" -eq 0 ]; then install_run_state_checks || return 1; fi
    install_prepare_timer "$timer" || return 1
    tools_announce_overrides
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
    install_retire_legacy_tools || return 1
    install_summary
    install_wsl_notice
    install_enable_timer
}
