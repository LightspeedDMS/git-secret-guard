# shellcheck shell=bash disable=SC2034

GSG_STATE_MAX_LINES=100
# ^ why a cap per line, not only per file; the tools_* values go through read -a <<<, and Git for Windows bash hangs at 64 KiB + 1 to 128 bytes
GSG_STATE_LINE_MAX=8192
GSG_STATE_VALUES=11
GSG_LAUNCHD_LABEL=com.lightspeeddms.git-secret-guard.doctor
# ^ coupled the Windows updater's Task Scheduler task (lib/platform/schtasks.sh); one per user, like the units of Linux
GSG_UPDATE_TASK_NAME=git-secret-guard-update
GSG_LAUNCHD_UPDATE_LABEL=com.lightspeeddms.git-secret-guard.update
GSG_ASIDE_RE='^[a-z][a-z0-9-]*\.gsg-replaced-[0-9]{8}T[0-9]{6}Z$'

# ^ invariant sets ST_* for every key (ST_PREV_SET, ST_TIMER and ST_AUTO_UPDATE are yes|no); the keys after backup_path are optional
# ^ invariant ST_SOURCE_CHECKOUT is an absolute path or "" (no checkout recorded); an older state file reads as auto_update=no and no checkout
# ^ invariant ST_CLI_PATH is "", "macos-block <created 0|1> <no final newline 0|1> <file>" or "windows-user-path <text>"; an older file reads ""
state_read() {
    local line key val missing="" seen=" "
    local -a lines=()
    ST_EXISTS=0 ST_VERSION="" ST_PREV_SET=no ST_PREV="" ST_TOOLS="" ST_BACKUP="" ST_REPLACED="" ST_PLACED="" ST_TIMER=no
    ST_AUTO_UPDATE=no ST_SOURCE_CHECKOUT="" ST_CLI_PATH=""
    if [ ! -e "$GSG_STATE_FILE" ]; then return 0; fi
    mapfile -t -n "$((GSG_STATE_MAX_LINES + 1))" lines <"$GSG_STATE_FILE" || return 1
    if [ "${#lines[@]}" -gt "$GSG_STATE_MAX_LINES" ]; then
        printf '%s: the state file %s is too long to be ours\n' "$GSG_NAME" "$GSG_STATE_FILE" >&2
        return 1
    fi
    for line in "${lines[@]}"; do
        if [ "${#line}" -gt "$GSG_STATE_LINE_MAX" ]; then
            printf '%s: the state file %s has a line longer than %s characters to be ours; fix or remove it\n' "$GSG_NAME" "$GSG_STATE_FILE" "$GSG_STATE_LINE_MAX" >&2
            return 1
        fi
        key="${line%%=*}"
        val="${line#*=}"
        case "$key" in
            version) ST_VERSION="$val" ;;
            previous_hooks_path_set) ST_PREV_SET="$val" ;;
            previous_hooks_path) ST_PREV="$val" ;;
            tools_installed_by_us) ST_TOOLS="$val" ;;
            backup_path) ST_BACKUP="$val" ;;
            tools_replaced) ST_REPLACED="$val" ;;
            tools_placed) ST_PLACED="$val" ;;
            timer_installed) ST_TIMER="$val" ;;
            auto_update) ST_AUTO_UPDATE="$val" ;;
            source_checkout) ST_SOURCE_CHECKOUT="$val" ;;
            cli_path) ST_CLI_PATH="$val" ;;
            *) key="" ;;
        esac
        if [[ $line != *=* ]] || [ -z "$key" ] || [[ $seen == *" $key "* ]]; then
            printf '%s: the state file %s is malformed at [%s]; fix or remove it\n' "$GSG_NAME" "$GSG_STATE_FILE" "${line:0:80}" >&2
            return 1
        fi
        seen+="$key "
    done
    for key in version previous_hooks_path_set previous_hooks_path tools_installed_by_us backup_path; do
        if [[ $seen != *" $key "* ]]; then missing="$key"; fi
    done
    if [ -n "$missing" ] || { [ "$ST_PREV_SET" != yes ] && [ "$ST_PREV_SET" != no ]; } || { [ "$ST_TIMER" != yes ] && [ "$ST_TIMER" != no ]; }; then
        printf '%s: the state file %s is incomplete or has a bad previous_hooks_path_set or timer_installed; fix or remove it\n' "$GSG_NAME" "$GSG_STATE_FILE" >&2
        return 1
    fi
    if { [ "$ST_AUTO_UPDATE" != yes ] && [ "$ST_AUTO_UPDATE" != no ]; } || { [ -n "$ST_SOURCE_CHECKOUT" ] && [ "${ST_SOURCE_CHECKOUT#/}" = "$ST_SOURCE_CHECKOUT" ]; }; then
        printf '%s: the state file %s has a bad auto_update or source_checkout; fix or remove it\n' "$GSG_NAME" "$GSG_STATE_FILE" >&2
        return 1
    fi
    case "$ST_CLI_PATH" in
        "" | "macos-block "[01]" "[01]" /"*)
            ST_EXISTS=1
            return 0
            ;;
        "windows-user-path "?*)
            if common_winrec_split "$ST_CLI_PATH"; then
                ST_EXISTS=1
                return 0
            fi
            ;;
    esac
    printf '%s: the state file %s has a bad cli_path; fix or remove it\n' "$GSG_NAME" "$GSG_STATE_FILE" >&2
    return 1
}

# ^ security umask 077 and a 700 dir => the recorded hooksPath and backup tarballs are readable by this user only
# ^ order state_make_dir before any file moves => the refusal changed nothing of ours; brew_unchanged_text adds the brew install; reason = last mkdir field
state_make_dir() {
    local err
    err="$( (umask 077 && mkdir -p -- "$GSG_STATE_DIR") 2>&1)" || {
        printf '%s: cannot create the state dir %s (%s); %s\n' "$GSG_NAME" "$GSG_STATE_DIR" "${err##*: }" "$(brew_unchanged_text)" >&2
        return 1
    }
    chmod 700 -- "$GSG_STATE_DIR" || return 1
}

# ^ invariant every caller passes all GSG_STATE_VALUES values; one written before auto_update, source_checkout and cli_path existed is refused, never defaulted
# ^ why refuse a short call, not default the new values; a default would silently turn a recorded auto_update=yes into no, or drop a recorded PATH entry
state_write() {
    local version prev_set prev tools backup replaced placed timer auto checkout clipath tmp all
    if [ "$#" -ne "$GSG_STATE_VALUES" ]; then
        printf '%s: state_write needs %s values, got %s; refusing to write the state file\n' "$GSG_NAME" "$GSG_STATE_VALUES" "$#" >&2
        return 1
    fi
    version="$1" prev_set="$2" prev="$3" tools="$4" backup="$5" replaced="$6" placed="$7" timer="$8" auto="$9" checkout="${10}" clipath="${11}"
    all="$version$prev_set$prev$tools$backup$replaced$placed$timer$auto$checkout$clipath"
    if [[ $all == *$'\n'* ]]; then
        printf '%s: a value to record contains a newline; refusing to write the state file\n' "$GSG_NAME" >&2
        return 1
    fi
    state_make_dir || return 1
    tmp="$(umask 077 && mktemp "$GSG_STATE_DIR/state.XXXXXX")" || return 1
    {
        printf 'version=%s\n' "$version"
        printf 'previous_hooks_path_set=%s\n' "$prev_set"
        printf 'previous_hooks_path=%s\n' "$prev"
        printf 'tools_installed_by_us=%s\n' "$tools"
        printf 'backup_path=%s\n' "$backup"
        printf 'tools_replaced=%s\n' "$replaced"
        printf 'tools_placed=%s\n' "$placed"
        printf 'timer_installed=%s\n' "$timer"
        printf 'auto_update=%s\n' "$auto"
        printf 'source_checkout=%s\n' "$checkout"
        printf 'cli_path=%s\n' "$clipath"
    } >"$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$GSG_STATE_FILE"
}

# ^ external XDG says a relative XDG_*_HOME is to be ignored; refusing is safer than guessing where the share dir and state go
paths_init() {
    local name val
    for name in HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CONFIG_HOME; do
        val="${!name:-}"
        if [ -z "$val" ] && [ "$name" != HOME ]; then continue; fi
        val="$(gsg_posix_path "$val")"
        printf -v "$name" '%s' "$val"
        if [ "${val#/}" = "$val" ]; then
            printf '%s: %s must be an absolute path, got [%s]\n' "$GSG_NAME" "$name" "$val" >&2
            return 1
        fi
    done
    GSG_BIN_DIR="$HOME/.local/bin"
    GSG_SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/git-secret-guard"
    GSG_STATE_DIR="$(state_dir_path)" || return 1
    GSG_STATE_FILE="$GSG_STATE_DIR/state"
    GSG_FINDINGS_FILE="$GSG_STATE_DIR/findings"
    GSG_FINDINGS_LOCK="$GSG_STATE_DIR/findings.lock"
    # ^ coupled lib/autoupdate/autoupdate.sh writes the record on every update run and holds the lock for a whole run; install and uninstall take the same lock
    GSG_UPDATE_RECORD="$GSG_STATE_DIR/update"
    GSG_UPDATE_LOCK="$GSG_STATE_DIR/update.lock"
    GSG_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    GSG_AGENT_DIR="$HOME/Library/LaunchAgents"
    GSG_AGENT_PLIST="$GSG_AGENT_DIR/$GSG_LAUNCHD_LABEL.plist"
    GSG_AGENT_LOG="$GSG_STATE_DIR/doctor.log"
    # ^ coupled the task's action is the wrapper, in the state dir and not the share (a running wrapper would pin the share); its output goes to the log
    GSG_UPDATE_TASK_CMD="$GSG_STATE_DIR/update-task.cmd"
    GSG_UPDATE_LOG="$GSG_STATE_DIR/update.log"
    GSG_UPDATE_AGENT_PLIST="$GSG_AGENT_DIR/$GSG_LAUNCHD_UPDATE_LABEL.plist"
    GSG_UPDATE_AGENT_LOG="$GSG_STATE_DIR/update.log"
}
