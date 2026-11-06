# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled the git upgrade module of the windows class (Git for Windows); registered in lib/gitup.sh, contract in CONTRIBUTING.md
# ^ hazard the upgrade replaces the bash.exe install runs in => bash decides, downloads and verifies; bin/gsg-gitup.ps1 runs the installer after bash ended
# ^ external Git for Windows records its setup in the Inno Setup uninstall key Git_is1 (HKLM = all users, HKCU = one user); read here, never written

GITUP_WIN_PLATFORM=windows_amd64
GITUP_WIN_KEY='SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Git_is1'
# ^ invariant one definition of the silent flags; bin/gsg-gitup.ps1 holds the same list, test:test_the_plan_flags_and_the_runner_flags_are_the_same_list checks
GITUP_WIN_FLAGS=(/VERYSILENT /NORESTART /NOCANCEL /SP-)
GITUP_WIN_WINGET_ARGS=(upgrade --id Git.Git --exact --silent --accept-source-agreements --accept-package-agreements)
GITUP_WIN_SCOPE="" GITUP_WIN_APPDIR="" GITUP_WIN_HAVE="" GITUP_WIN_VER="" GITUP_WIN_SHA="" GITUP_WIN_WINGET=""
GITUP_WIN_REG_APP="" GITUP_WIN_REG_VER="" GITUP_WIN_HANDOFF_FILE="" GITUP_WIN_FRONT=0
GITUP_WIN_ELEVATED=0
GITUP_WIN_HANDOFF_NAME=handoff.txt GITUP_WIN_HANDOFF_DIRNAME=git-upgrade

# ^ invariant sets REPLY = the System32 directory in posix form; GSG_GITUP_ROOT (tests) moves it into the sandbox, nothing is looked up through PATH
gitup_windows_sysdir() {
    REPLY=""
    if [ -n "${GITUP_ROOT:-}" ]; then
        REPLY="$GITUP_ROOT/windows/System32"
        return 0
    fi
    if [ -z "${SYSTEMROOT:-}" ]; then
        printf '%s: SYSTEMROOT is not set, cannot locate reg.exe and whoami.exe\n' "$GSG_NAME" >&2
        return 1
    fi
    REPLY="$(cygpath -u "$SYSTEMROOT")/System32" || return 1
}

# ^ invariant sets GITUP_WIN_REG_APP and GITUP_WIN_REG_VER from the Git_is1 key of hive $1 (HKLM or HKCU); rc 0 = App Path found, 1 = none, 2 = no reg.exe
# ^ why the whole key in one call, not one call per value; reg.exe prints every value as "    name    REG_SZ    data" and the call is bounded by the timeout
gitup_windows_reg_read() {
    local hive="$1" sys out line
    local app_prefix='    Inno Setup: App Path    REG_SZ    ' ver_prefix='    DisplayVersion    REG_SZ    '
    GITUP_WIN_REG_APP="" GITUP_WIN_REG_VER=""
    gitup_windows_sysdir || return 2
    sys="$REPLY"
    if [ ! -x "$sys/reg.exe" ]; then
        printf '%s: %s/reg.exe is missing, so the Git for Windows setup record cannot be read\n' "$GSG_NAME" "$sys" >&2
        return 2
    fi
    out="$("$INSTALL_TIMEOUT_BIN" 30 "$sys/reg.exe" query "$hive\\$GITUP_WIN_KEY" </dev/null 2>/dev/null)" || return 1
    while IFS= read -r line; do
        line="${line%$'\r'}"
        case "$line" in
            "$app_prefix"*) GITUP_WIN_REG_APP="${line#"$app_prefix"}" ;;
            "$ver_prefix"*) GITUP_WIN_REG_VER="${line#"$ver_prefix"}" ;;
        esac
    done <<<"$out"
    [ -n "$GITUP_WIN_REG_APP" ]
}

# ^ invariant true when Windows path $1 is $2 or below it; case-insensitive and either slash, as the file system treats them
gitup_windows_below() {
    local p="${1//\//\\}" d="${2//\//\\}"
    d="${d%\\}"
    p="${p,,}"
    d="${d,,}"
    [[ $p == "$d" || $p == "$d\\"* ]]
}

# ^ invariant rc 0 when the whoami.exe /groups listing carries the High (S-1-16-12288) or System mandatory label; a failing whoami counts as not elevated
# ^ external the mandatory label is in the token of an elevated administrator and absent from a filtered one; group membership alone is the same for both
gitup_windows_is_elevated() {
    local sys out
    gitup_windows_sysdir || return 1
    sys="$REPLY"
    if [ ! -x "$sys/whoami.exe" ]; then return 1; fi
    out="$(MSYS2_ARG_CONV_EXCL='*' "$INSTALL_TIMEOUT_BIN" 30 "$sys/whoami.exe" /groups </dev/null 2>/dev/null)" || return 1
    [[ $out == *S-1-16-12288* || $out == *S-1-16-16384* ]]
}

# ^ invariant sets GITUP_WIN_SCOPE (machine or user), GITUP_WIN_APPDIR and GITUP_WIN_HAVE for the install the git on PATH belongs to; rc 1 prints the reason
# ^ why the setup record of the git on PATH, not any record; another install would be upgraded and the git running commits would stay old
gitup_windows_detect() {
    local gitw hive rc scope
    GITUP_WIN_SCOPE="" GITUP_WIN_APPDIR="" GITUP_WIN_HAVE=""
    if [ -z "$GSG_GIT" ]; then
        printf '  no git was found on PATH, so there is no Git for Windows install to upgrade; install one from https://git-scm.com/download/win\n'
        return 1
    fi
    gitw="$(cygpath -w "$GSG_GIT")" || return 1
    for hive in HKLM HKCU; do
        gitup_windows_reg_read "$hive"
        rc=$?
        if [ "$rc" -eq 2 ]; then return 1; fi
        if [ "$rc" -ne 0 ]; then continue; fi
        if ! gitup_windows_below "$gitw" "$GITUP_WIN_REG_APP"; then
            printf '  %s is not inside the Git for Windows install the %s setup record names (%s)\n' "$gitw" "$hive" "$GITUP_WIN_REG_APP"
            continue
        fi
        scope=machine
        if [ "$hive" = HKCU ]; then scope=user; fi
        GITUP_WIN_SCOPE="$scope" GITUP_WIN_APPDIR="$GITUP_WIN_REG_APP" GITUP_WIN_HAVE="${GITUP_WIN_REG_VER:-unknown}"
        return 0
    done
    printf '  no Git for Windows setup record (HKLM or HKCU, %s) describes the git on PATH (%s); a portable, scoop or MinGit install is not upgraded by this tool\n' "$GITUP_WIN_KEY" "$gitw"
    return 1
}

# ^ invariant the runner needs the signer line of the lock for this version; a lock without it is refused here, before the download of the installer
gitup_windows_signer_line() {
    local line found=0 re="^#[[:space:]]gsg-signer[[:space:]]git-for-windows[[:space:]]$1[[:space:]]+.+"
    local -a lines=()
    mapfile -t -n "$((GSG_LOCK_MAX_LINES + 1))" lines <"$(tools_lock_path)" || return 1
    for line in "${lines[@]}"; do
        if [[ $line =~ $re ]]; then found=1; fi
    done
    if [ "$found" -eq 0 ]; then
        printf '%s: tools.lock has no "# gsg-signer git-for-windows %s SUBJECT" line, which the upgrade runner needs; nothing was downloaded\n' "$GSG_NAME" "$1" >&2
        return 1
    fi
}

# ^ invariant sets GITUP_WIN_VER and GITUP_WIN_SHA from the git-for-windows row of tools.lock; rc 1 = no row, a version older than 2.54 or a malformed lock
gitup_windows_pins() {
    local row
    row="$(tools_lock_lookup "$(tools_lock_path)" git-for-windows "$GITUP_WIN_PLATFORM")" || {
        printf '%s: tools.lock has no git-for-windows %s row\n' "$GSG_NAME" "$GITUP_WIN_PLATFORM" >&2
        return 1
    }
    GITUP_WIN_VER="${row%% *}"
    GITUP_WIN_SHA="${row##* }"
    if ! gitup_version_at_least "$GITUP_WIN_VER" "$GSG_MIN_GIT_MAJOR.$GSG_MIN_GIT_MINOR"; then
        printf '%s: tools.lock pins Git for Windows %s, older than git %s.%s\n' "$GSG_NAME" "$GITUP_WIN_VER" "$GSG_MIN_GIT_MAJOR" "$GSG_MIN_GIT_MINOR" >&2
        return 1
    fi
    gitup_windows_signer_line "$GITUP_WIN_VER" || return 1
}

gitup_windows_print_scope() {
    if [ "$GITUP_WIN_SCOPE" = machine ]; then
        printf '  scope: machine-wide; Git for Windows %s is installed for all users in %s (HKLM setup record), the installer is started with administrator rights\n' \
            "$GITUP_WIN_HAVE" "$GITUP_WIN_APPDIR"
        if [ "$GITUP_WIN_ELEVATED" -eq 1 ]; then
            printf '  elevation: this prompt is already elevated, no prompt will appear\n'
        else
            printf '  elevation: this prompt is not elevated, so a Windows UAC prompt should appear when the installer starts; declining it stops the upgrade before the installer starts and you can run the command again\n'
        fi
    else
        printf '  scope: per-user; Git for Windows %s is installed for this user only in %s (HKCU setup record), the installer is started without administrator rights\n' \
            "$GITUP_WIN_HAVE" "$GITUP_WIN_APPDIR"
        printf '  elevation: this prompt is not elevated and must stay so, because an elevated installer might install machine-wide instead (the setup was not tested for this)\n'
    fi
    printf '  kept: no directory or option is passed on the command line; the setup is expected to reuse what it recorded in the registry (install directory, components, editor, PATH option and the rest)\n'
}

gitup_windows_print_route() {
    local name="Git-$GITUP_WIN_VER-64-bit.exe"
    if [ "$GITUP_ROUTE" = winget ]; then
        printf '  route: winget (%s); winget does the upgrade; its own hash check, its elevation and whether it keeps the scope are not tested here\n' "$GITUP_WIN_WINGET"
        printf '  step 1, after this process has ended (the upgrade replaces the bash install runs in): winget %s --scope %s\n' "${GITUP_WIN_WINGET_ARGS[*]}" "$GITUP_WIN_SCOPE"
    else
        printf '  route: installer; winget was not found on PATH, so the pinned Git for Windows %s is used\n' "$GITUP_WIN_VER"
        printf '  step 1, in this process: download %s from %s and check its SHA-256 against tools.lock; a file that differs is removed and nothing runs\n' \
            "$name" "$(tools_release_url git-for-windows "$GITUP_WIN_VER" "$GITUP_WIN_PLATFORM")"
        printf '  step 2, after this process has ended (the installer replaces the bash install runs in): %s %s; right before it starts the runner checks it against the SHA-256 pin of tools.lock and the Authenticode signature of the pinned signer\n' "$name" "${GITUP_WIN_FLAGS[*]}"
    fi
    printf '  step 3: install runs again with the new git (git-secret-guard.cmd does it by itself; from Git Bash you are told the exact commands)\n'
}

# ^ invariant mode refresh has nothing to do (Windows has no build of ours); mode upgrade sets GITUP_ROUTE to winget or installer, rc 1 prints why not
gitup_windows_plan() {
    GITUP_ROUTE=""
    case "$1" in
        refresh) return 1 ;;
        upgrade) ;;
        *) return 1 ;;
    esac
    gitup_windows_detect || return 1
    GITUP_WIN_ELEVATED=0
    if gitup_windows_is_elevated; then GITUP_WIN_ELEVATED=1; fi
    if [ "$GITUP_WIN_SCOPE" = user ] && [ "$GITUP_WIN_ELEVATED" -eq 1 ]; then
        printf '  this prompt is elevated and Git for Windows is installed for this user only; an elevated installer could install machine-wide, so open a normal (not elevated) prompt and run install --upgrade-git again; nothing was changed\n'
        return 1
    fi
    gitup_windows_pins || return 1
    GITUP_WIN_WINGET=""
    if install_find_bin winget; then
        GITUP_WIN_WINGET="$REPLY"
        GITUP_ROUTE=winget
    else
        GITUP_ROUTE=installer
    fi
    gitup_windows_print_route
    gitup_windows_print_scope
    gitup_plan_note "IDEs and GUI clients that bundle their own git (or use another Git for Windows) are not changed by this; check the git they use"
    gitup_plan_note "close other programs that use Git for Windows (Git Bash windows, editors with a git terminal) first; the silent installer cannot ask to close them"
}

# ^ invariant true when $1 is $2 or below it, without regard to case (NTFS ignores it and cygpath -u keeps the case it was given)
gitup_windows_under() {
    local p="${1,,}" root="${2,,}"
    root="${root%/}"
    [[ -n $root && $p == "$root"/* ]]
}

# ^ security git-upgrade and its parent must not be symbolic links or junctions (MSYS shows both as links); install creates exactly these two directories
# ^ invariant the runner checks the same two directories and the installer file; a link above them (a moved profile) is the user's and both accept it
gitup_windows_no_links() {
    local d="$1" n
    for n in 1 2; do
        if [ -L "$d" ]; then
            printf '%s: %s is a symbolic link or junction; nothing was changed\n' "$GSG_NAME" "$d" >&2
            return 1
        fi
        d="${d%/*}"
    done
}

# ^ invariant sets GITUP_WIN_HANDOFF_FILE; GSG_HANDOFF (from git-secret-guard.cmd) must lie below LOCALAPPDATA, else the state directory is used
# ^ security both routes must end in git-secret-guard/git-upgrade/handoff.txt, with no .. component and no link in those two directories => no aiming elsewhere
gitup_windows_handoff_place() {
    local raw="${GSG_HANDOFF:-}" p base dir pdir root="" what where
    GITUP_WIN_FRONT=0
    if [ -z "$raw" ]; then
        root="$(state_dir_path)" || return 1
        p="$root/$GITUP_WIN_HANDOFF_DIRNAME/$GITUP_WIN_HANDOFF_NAME"
        what="the state directory (XDG_STATE_HOME)"
        where="an absolute state directory"
    else
        p="$(gsg_posix_path "$raw")" || return 1
        if [ -n "${LOCALAPPDATA:-}" ]; then root="$(gsg_posix_path "$LOCALAPPDATA")" || return 1; fi
        what="GSG_HANDOFF"
        where="LOCALAPPDATA"
    fi
    dir="${p%/*}"
    base="${p##*/}"
    pdir="${dir%/*}"
    if [[ $p != /* || $p == *[[:cntrl:]]* || /$p/ == */../* || $base != "$GITUP_WIN_HANDOFF_NAME" || ${dir##*/} != "$GITUP_WIN_HANDOFF_DIRNAME" || ${pdir##*/} != git-secret-guard ]] \
        || { [ -n "$raw" ] && ! gitup_windows_under "$p" "$root"; }; then
        printf '%s: %s must be an absolute path to git-secret-guard/%s/%s below %s, got [%s]; nothing was changed\n' \
            "$GSG_NAME" "$what" "$GITUP_WIN_HANDOFF_DIRNAME" "$GITUP_WIN_HANDOFF_NAME" "$where" "${p//[[:cntrl:]]/?}" >&2
        return 1
    fi
    GITUP_WIN_HANDOFF_FILE="$p"
    if [ -n "$raw" ]; then GITUP_WIN_FRONT=1; fi
    gitup_windows_no_links "$dir"
}

# ^ invariant the hand-off directory is made empty of earlier hand-offs and installers; only files named like ours are removed, never a tree
gitup_windows_prepare_dir() {
    local dir="${GITUP_WIN_HANDOFF_FILE%/*}" f
    mkdir -p -- "$dir" || return 1
    chmod 700 -- "$dir" || return 1
    for f in "$dir"/Git-*-64-bit.exe "$dir/$GITUP_WIN_HANDOFF_NAME" "$dir/$GITUP_WIN_HANDOFF_NAME".*; do
        if [ -e "$f" ] || [ -L "$f" ]; then rm -f -- "$f" || return 1; fi
    done
}

# ^ invariant the hand-off is data the runner parses line by line; it is written complete or not at all (temp file and rename), and the digest is not in it
gitup_windows_write_handoff() {
    local installer="$1" tmp="$GITUP_WIN_HANDOFF_FILE.$$" installer_w=""
    if [ -n "$installer" ]; then installer_w="$(cygpath -w "$installer")" || return 1; fi
    {
        printf 'gsg-git-upgrade-handoff 1\n'
        printf 'route=%s\nscope=%s\nversion=%s\n' "$GITUP_ROUTE" "$GITUP_WIN_SCOPE" "$GITUP_WIN_VER"
        if [ -n "$installer_w" ]; then printf 'installer=%s\n' "$installer_w"; fi
    } >"$tmp" || return 1
    mv -f -- "$tmp" "$GITUP_WIN_HANDOFF_FILE"
}

# ^ invariant the exact text of the next step; with a cmd front end it runs by itself, from Git Bash the user runs it in a new window with the flags of this run
# ^ invariant GSG_INSTALL_FLAGS holds the flags of this install besides --upgrade-git (install_run sets it); the new git makes --upgrade-git unnecessary
gitup_windows_next_text() {
    local runner file cmd what="the verified installer" uac="no UAC prompt is expected"
    if [ "$GITUP_ROUTE" = winget ]; then what="winget"; uac="winget decides about elevation"; fi
    if [ "$GITUP_ROUTE" = installer ] && [ "$GITUP_WIN_SCOPE" = machine ] && [ "$GITUP_WIN_ELEVATED" -eq 0 ]; then uac="a UAC prompt should appear"; fi
    if [ "$GITUP_WIN_FRONT" -eq 1 ]; then
        GITUP_NEXT="git-secret-guard.cmd runs $what next ($uac) and then runs install again by itself"
        return 0
    fi
    runner="$(cygpath -w "$GSG_ROOT/bin/gsg-gitup.ps1")" || return 1
    file="$(cygpath -w "$GITUP_WIN_HANDOFF_FILE")" || return 1
    cmd="$(cygpath -w "$GSG_ROOT/bin/git-secret-guard.cmd")" || return 1
    GITUP_NEXT="close every Git Bash window (the upgrade replaces bash), open PowerShell or cmd and run: powershell -NoProfile -ExecutionPolicy Bypass -File \"$runner\" \"$file\" ; when it reports success open a new terminal and run: \"$cmd\" install${GSG_INSTALL_FLAGS:-}"
}

# ^ invariant apply never runs the installer; it verifies, writes the hand-off and returns 2 (the core stops with exit 3 and prints GITUP_NEXT)
# ^ invariant a failed download or digest changes nothing on the machine; GITUP_CHANGED stays empty and the core says nothing was changed
gitup_windows_apply() {
    local dir file=""
    if [ -z "$GITUP_ROUTE" ] || [ -z "$GITUP_WIN_SCOPE" ] || [ -z "$GITUP_WIN_VER" ]; then
        printf '%s: the windows module was asked to apply without a plan\n' "$GSG_NAME" >&2
        return 1
    fi
    gitup_windows_handoff_place || return 1
    gitup_windows_prepare_dir || return 1
    dir="${GITUP_WIN_HANDOFF_FILE%/*}"
    if [ "$GITUP_ROUTE" = installer ]; then
        tools_announce_overrides
        file="$(tools_fetch_verified git-for-windows "$GITUP_WIN_VER" "$GITUP_WIN_PLATFORM" "$GITUP_WIN_SHA" "$dir")" || return 1
    fi
    gitup_windows_write_handoff "$file" || return 1
    gitup_windows_next_text || return 1
    return 2
}
