# shellcheck shell=bash disable=SC2034
# ^ invariant this file must parse and run under bash 3.2 (/bin/bash on macOS); the CLI sources it before it knows a newer bash exists
# ^ invariant no mapfile, no associative arrays, no ${v,,}, no &>> and no += on arrays; test:test_the_brew_library_runs_under_the_bash_macos_ships

GSG_NAME="${GSG_NAME:-git-secret-guard}"
BREW_HOMEBREW_URL=https://brew.sh
BREW_BASH_MIN_MAJOR=4
BREW_BASH_MIN_MINOR=4
BREW_SETTINGS_MAX_LINES=500
BREW_REEXEC_MAX=2

brew_is_macos() { [ "$(uname -s)" = Darwin ]; }

# ^ invariant BREW_INSTALLED = the formulae a brew install put on this machine during this invocation, bootstrap included; "" = brew install never ran
BREW_INSTALLED=""

# ^ invariant prints the claim for a refusal, "nothing was changed" until BREW_INSTALLED is set, afterwards what changed
# ^ invariant GSG_GIT_UPGRADED=1 comes from git-secret-guard.cmd for the run after its hand-off; a rerun cannot know what the earlier run changed
brew_unchanged_text() {
    local gitup="${GITUP_CHANGED:-}"
    if [ "${GSG_GIT_UPGRADED:-}" = 1 ] && [ -z "$gitup" ]; then gitup="Git for Windows was upgraded just before this run"; fi
    if [ -z "$BREW_INSTALLED" ] && [ -z "$gitup" ]; then
        printf 'nothing was changed'
    elif [ -z "$gitup" ]; then
        printf 'the only change made was the Homebrew install of %s in this run' "$BREW_INSTALLED"
    elif [ -z "$BREW_INSTALLED" ]; then
        printf 'the only change made was the git upgrade of this run (%s)' "$gitup"
    else
        printf 'the changes made in this run were the Homebrew install of %s and the git upgrade (%s)' "$BREW_INSTALLED" "$gitup"
    fi
}

# ^ external the only lookup of brew; install-time only, the hook never resolves a tool through PATH
# ^ invariant sets BREW_BIN = the absolute path of brew; a missing or relative one prints the refusal and returns 1
brew_find() {
    BREW_BIN="$(type -P brew)" || BREW_BIN=""
    if [ -z "$BREW_BIN" ] || [ "${BREW_BIN#/}" = "$BREW_BIN" ]; then
        printf '%s: Homebrew (brew) was not found on PATH; install it from %s (and open a new terminal so brew is on PATH), then run install again; %s\n' \
            "$GSG_NAME" "$BREW_HOMEBREW_URL" "$(brew_unchanged_text)" >&2
        return 1
    fi
}

# ^ external gnubin holds the GNU coreutils under their plain names (timeout, realpath, mv, install ...); util-linux is keg-only, setsid lives in its own bin
# ^ invariant sets BREW_PREFIX and the four absolute paths below it; an empty or relative prefix prints the refusal and returns 1
brew_paths() {
    BREW_PREFIX="$("$BREW_BIN" --prefix)" || BREW_PREFIX=""
    if [ -z "$BREW_PREFIX" ] || [ "${BREW_PREFIX#/}" = "$BREW_PREFIX" ]; then
        printf '%s: brew --prefix printed [%s], not an absolute path; %s\n' "$GSG_NAME" "$BREW_PREFIX" "$(brew_unchanged_text)" >&2
        return 1
    fi
    BREW_BASH="$BREW_PREFIX/bin/bash"
    BREW_GNUBIN="$BREW_PREFIX/opt/coreutils/libexec/gnubin"
    BREW_TIMEOUT="$BREW_GNUBIN/timeout"
    BREW_SETSID="$BREW_PREFIX/opt/util-linux/bin/setsid"
}

# ^ invariant true only for an executable reporting bash 4.4 or newer; the version is asked of the binary itself
brew_bash_ok() {
    local v major minor
    if [ ! -x "$1" ]; then return 1; fi
    # shellcheck disable=SC2016
    v="$("$1" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null)" || return 1
    case "$v" in
        [0-9]*.[0-9]*) ;;
        *) return 1 ;;
    esac
    major="${v%%.*}"
    minor="${v#*.}"
    if [ "$major" -gt "$BREW_BASH_MIN_MAJOR" ]; then return 0; fi
    [ "$major" -eq "$BREW_BASH_MIN_MAJOR" ] && [ "$minor" -ge "$BREW_BASH_MIN_MINOR" ]
}

# ^ invariant sets BREW_NEED = the formulae still missing, in the order bash coreutils util-linux jq, and BREW_JQ = the jq to record
# ^ external jq is on PATH from macOS 15 on (/usr/bin/jq); only when none is found is the formula needed
brew_missing() {
    BREW_NEED=""
    if ! brew_bash_ok "$BREW_BASH"; then BREW_NEED="$BREW_NEED bash"; fi
    if [ ! -x "$BREW_TIMEOUT" ]; then BREW_NEED="$BREW_NEED coreutils"; fi
    if [ ! -x "$BREW_SETSID" ]; then BREW_NEED="$BREW_NEED util-linux"; fi
    BREW_JQ="$(type -P jq)" || BREW_JQ=""
    if [ -z "$BREW_JQ" ]; then
        BREW_JQ="$BREW_PREFIX/bin/jq"
        if [ ! -x "$BREW_JQ" ]; then BREW_NEED="$BREW_NEED jq"; fi
    fi
    BREW_NEED="${BREW_NEED# }"
}

# ^ invariant $1 = the formulae to install, space separated; announces the command, runs it, and on success adds them to BREW_INSTALLED
# ^ invariant a failing brew install prints brew's own message (it goes straight to the terminal) and one more line; brew may have installed part of the list
brew_run_install() {
    local -a need
    local before="no other change was made"
    printf '%s: installing the missing prerequisites with Homebrew: brew install %s\n' "$GSG_NAME" "$1"
    IFS=' ' read -r -a need <<<"$1"
    "$BREW_BIN" install "${need[@]}" || {
        if [ -n "$BREW_INSTALLED" ]; then before="before that, $(brew_unchanged_text)"; fi
        printf '%s: brew install %s failed (brew'"'"'s message is above); install refused. Homebrew may have installed part of %s before failing (see brew list); %s\n' \
            "$GSG_NAME" "$1" "$1" "$before" >&2
        return 1
    }
    BREW_INSTALLED="${BREW_INSTALLED:+$BREW_INSTALLED }$1"
}

# ^ invariant installs all of BREW_NEED; after a good install every path is checked again => a formula installed elsewhere is refused by name
brew_install_missing() {
    if [ -z "$BREW_NEED" ]; then return 0; fi
    brew_run_install "$BREW_NEED" || return 1
    brew_missing
    if [ -n "$BREW_NEED" ]; then
        printf '%s: brew install finished but these prerequisites are still missing: %s (expected %s, %s, %s); install refused, %s\n' \
            "$GSG_NAME" "$BREW_NEED" "$BREW_BASH" "$BREW_TIMEOUT" "$BREW_SETSID" "$(brew_unchanged_text)" >&2
        return 1
    fi
}

# ^ invariant detection only; sets BREW_BIN, the BREW_* paths and BREW_NEED (may be empty), rc 1 = refused with a message
brew_inspect() {
    brew_find || return 1
    brew_paths || return 1
    brew_missing
}

# ^ external macOS ships BSD tools; realpath -m, mv -T and install -T need the GNU ones, kept by Homebrew in one directory outside PATH
# ^ invariant macOS only; the settings file of an installed copy and brew are exclusive branches, a broken settings file is never papered over by brew
brew_use_gnubin() {
    local dir="" cmd="${1:-}" reason="" reason_max=200
    if ! brew_is_macos; then return 0; fi
    if [ -f "$GSG_ROOT/settings" ]; then
        # ^ security the reason echoes a settings value => control characters become ?, cut at reason_max
        reason="$(load_settings "$GSG_ROOT/settings" 2>&1 >/dev/null)" || {
            reason="${reason//[[:cntrl:]]/?}"
            trunc_text "$reason" "$reason_max"
            printf '%s: cannot read %s%s\n' "$GSG_NAME" "$GSG_ROOT/settings" "${REPLY:+: $REPLY}" >&2
            return 1
        }
        dir="$(load_settings "$GSG_ROOT/settings" >/dev/null 2>&1 && printf '%s' "${GNUBIN_DIR:-}")"
    elif brew_find 2>/dev/null && brew_paths 2>/dev/null; then
        dir="$BREW_GNUBIN"
    fi
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        PATH="$dir:$PATH"
        export PATH
        return 0
    fi
    # ^ invariant install, version and help are exempt from the refusal; install installs coreutils, the other two run no GNU tool
    case "$cmd" in
        "" | install | version | help | -h | --help) return 0 ;;
    esac
    if [ -n "$dir" ]; then
        printf '%s: the GNU coreutils directory %s is missing, and %s needs GNU tools (macOS ships BSD ones); run: brew install coreutils\n' \
            "$GSG_NAME" "$dir" "$cmd" >&2
        return 1
    fi
    reason="brew was not found on PATH"
    if [ -f "$GSG_ROOT/settings" ]; then reason="no GNUBIN_DIR in $GSG_ROOT/settings"; fi
    printf '%s: cannot find the GNU coreutils directory (%s), and %s needs GNU tools (macOS ships BSD ones); run: brew install coreutils\n' \
        "$GSG_NAME" "$reason" "$cmd" >&2
    return 1
}

# ^ external bug #10, an installed copy started by /bin/bash 3.2 with no brew on PATH still has the bash install recorded in its own settings file
# ^ security the settings file is read as data, never sourced; only a plain absolute path of safe characters is believed, anything else is ignored
# ^ invariant rc 0 sets BREW_RECORDED to a usable bash; rc 1 sets BREW_RECORDED_NOTE to the reason, empty when nothing was recorded; the last BASH_BIN line wins
brew_recorded_bash() {
    local file="${GSG_ROOT:-}/settings" line value="" shown="" reason="" seen=0 n=0
    BREW_RECORDED="" BREW_RECORDED_NOTE=""
    if [ -z "${GSG_ROOT:-}" ] || [ ! -f "$file" ]; then return 1; fi
    if [ ! -r "$file" ]; then
        BREW_RECORDED_NOTE="the settings file $file cannot be read"
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        if [ "$n" -gt "$BREW_SETTINGS_MAX_LINES" ]; then
            BREW_RECORDED_NOTE="the settings file $file has more than $BREW_SETTINGS_MAX_LINES lines and was not read"
            return 1
        fi
        case "$line" in
            BASH_BIN=*)
                value="${line#BASH_BIN=}"
                seen=1
                ;;
        esac
    done <"$file"
    if [ "$seen" -eq 0 ]; then return 1; fi
    shown="$value"
    if [ -z "$value" ]; then
        reason="is empty"
    elif [ -n "${value//[A-Za-z0-9._\/+@%-]/}" ]; then
        shown=""
        reason="is not a plain path (shell quoting and expansion are not read under bash $BASH_VERSION)"
    elif [ "${value#/}" = "$value" ]; then
        reason="is not an absolute path"
    elif [ ! -f "$value" ] || [ ! -x "$value" ]; then
        reason="is not an executable file"
    elif ! brew_bash_ok "$value"; then
        reason="does not report bash $BREW_BASH_MIN_MAJOR.$BREW_BASH_MIN_MINOR or newer"
    fi
    if [ -z "$reason" ]; then
        BREW_RECORDED="$value"
        return 0
    fi
    BREW_RECORDED_NOTE="the BASH_BIN recorded in $file ${shown:+($shown) }$reason"
    return 1
}

# ^ invariant quiet lookup for commands other than install; true only when brew is on PATH and its bash is usable, sets BREW_BIN and BREW_BASH
brew_have_brew_bash() {
    BREW_BIN="$(type -P brew)" || return 1
    if [ -z "$BREW_BIN" ] || [ "${BREW_BIN#/}" = "$BREW_BIN" ]; then return 1; fi
    brew_paths 2>/dev/null || return 1
    brew_bash_ok "$BREW_BASH"
}

# ^ invariant arg 1 is the command; says what is missing and how to fix it, never install wording and never a claim about changes
brew_refuse_old_bash() {
    local cmd="this command"
    if [ -n "${1:-}" ]; then cmd="the $1 command"; fi
    printf '%s: %s needs bash %s.%s or newer and this is bash %s; %sput the Homebrew bash first on PATH, or get it with: brew install bash\n' \
        "$GSG_NAME" "$cmd" "$BREW_BASH_MIN_MAJOR" "$BREW_BASH_MIN_MINOR" "${BASH_VERSION:-unknown}" "${BREW_RECORDED_NOTE:+$BREW_RECORDED_NOTE; }" >&2
}

# ^ invariant true when the running bash is the minimum or newer; plain bash 3.2 syntax
brew_running_bash_ok() {
    [ "${BASH_VERSINFO[0]:-0}" -gt "$BREW_BASH_MIN_MAJOR" ] \
        || { [ "${BASH_VERSINFO[0]:-0}" -eq "$BREW_BASH_MIN_MAJOR" ] && [ "${BASH_VERSINFO[1]:-0}" -ge "$BREW_BASH_MIN_MINOR" ]; }
}

# ^ invariant SCRIPT is the CLI path and the rest its arguments; rc 0 = the running bash is fine, rc 1 = refused with a message, a good re-exec never returns
# ^ invariant GSG_BREW_BOOTSTRAPPED=<pid>:<formulae> carries the install across the re-exec; exec keeps the pid, a stale shell value is ignored
brew_cli_bootstrap() {
    local self="$1" reexeced=0 depth="${GSG_BREW_REEXEC_DEPTH-0}" minimum="$BREW_BASH_MIN_MAJOR.$BREW_BASH_MIN_MINOR"
    shift
    case "${GSG_BREW_BOOTSTRAPPED:-}" in
        "$$:"*)
            BREW_INSTALLED="${GSG_BREW_BOOTSTRAPPED#*:}"
            reexeced=1
            ;;
    esac
    unset GSG_BREW_BOOTSTRAPPED GSG_BREW_REEXEC_DEPTH
    # ^ invariant an empty or non-digit depth counts as already at the bound => an inherited odd value refuses, never loops
    case "$depth" in
        "" | *[!0-9]*) depth="$BREW_REEXEC_MAX" ;;
    esac
    if brew_running_bash_ok; then return 0; fi
    if ! brew_is_macos; then
        printf '%s: bash %s or newer is required, this is bash %s\n' "$GSG_NAME" "$minimum" "${BASH_VERSION:-unknown}" >&2
        return 1
    fi
    # ^ invariant two bounds stop a loop, the pid-bound marker and an environment depth counter; a wrapper running bash as a child gets a new pid
    # ^ invariant either one means the bash we started is still old; refuse, never exec again
    if [ "$reexeced" -eq 1 ] || [ "$depth" -ge "$BREW_REEXEC_MAX" ]; then
        printf '%s: the CLI was started again under a bash that still reports bash %s; it needs bash %s or newer; put the Homebrew bash first on PATH, or get it with: brew install bash\n' \
            "$GSG_NAME" "${BASH_VERSION:-unknown}" "$minimum" >&2
        return 1
    fi
    if brew_recorded_bash; then
        GSG_BREW_BOOTSTRAPPED="$$:$BREW_INSTALLED" GSG_BREW_REEXEC_DEPTH=$((depth + 1)) exec "$BREW_RECORDED" "$self" "$@"
    fi
    if [ "${1:-}" != install ]; then
        if ! brew_have_brew_bash; then
            brew_refuse_old_bash "${1:-}"
            return 1
        fi
    else
        brew_find || return 1
        brew_paths || return 1
        if ! brew_bash_ok "$BREW_BASH"; then
            brew_run_install bash || return 1
            if ! brew_bash_ok "$BREW_BASH"; then
                printf '%s: brew install bash finished but %s is not a bash %s or newer; install refused, %s\n' \
                    "$GSG_NAME" "$BREW_BASH" "$minimum" "$(brew_unchanged_text)" >&2
                return 1
            fi
        fi
    fi
    if [ ! -x "$BREW_BASH" ]; then
        printf '%s: cannot start %s\n' "$GSG_NAME" "$BREW_BASH" >&2
        return 1
    fi
    GSG_BREW_BOOTSTRAPPED="$$:$BREW_INSTALLED" GSG_BREW_REEXEC_DEPTH=$((depth + 1)) exec "$BREW_BASH" "$self" "$@"
}
