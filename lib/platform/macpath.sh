# shellcheck shell=bash disable=SC2034
# ^ why a file-wide SC2034 off, not one per line; MACPATH_RESULT and the other MACPATH_* globals are read by install_path.sh

GSG_MACPATH_BEGIN='# begin git-secret-guard PATH'
GSG_MACPATH_END='# end git-secret-guard PATH'
# ^ invariant a startup file over this many bytes is never read whole or edited; a login file is a few lines
GSG_MACPATH_FILE_MAX=1048576
MACPATH_CONTENT="" MACPATH_WHY=""

# ^ invariant prints the block install adds, three lines each ending in a newline; the first and the last line carry the marker, the middle one is GSG_PATH_LINE
macpath_block_text() { printf '%s\n%s\n%s\n' "$GSG_MACPATH_BEGIN" "$GSG_PATH_LINE" "$GSG_MACPATH_END"; }

# ^ external dscl . -read /Users/NAME UserShell answers one line with the shell path; $SHELL names the shell this process started under, never the account's
# ^ invariant sets REPLY = zsh, bash or other; rc 1 (REPLY empty) when dscl or id is missing, or dscl fails or names no shell
macpath_login_shell() {
    local dscl name out
    REPLY=""
    install_find_bin dscl || return 1
    dscl="$REPLY"
    install_find_bin id || return 1
    name="$("$REPLY" -un)" || return 1
    out="$("$dscl" . -read "/Users/$name" UserShell 2>/dev/null)" || return 1
    out="${out##*[[:space:]]}"
    case "${out##*/}" in
        "") return 1 ;;
        zsh) REPLY=zsh ;;
        bash) REPLY=bash ;;
        *) REPLY=other ;;
    esac
}

# ^ invariant sets MACPATH_CONTENT = bytes of file $1, only on success; rc 1 with MACPATH_WHY when over GSG_MACPATH_FILE_MAX, unreadable or holding a NUL
# ^ why a trailing x through the substitution, not the substitution alone; $(...) cuts every final newline and the file must come back byte for byte
macpath_read() {
    local LC_ALL=C size text
    MACPATH_CONTENT="" MACPATH_WHY=""
    size="$(wc -c <"$1")" || { MACPATH_WHY="cannot read $1"; return 1; }
    size="${size//[[:space:]]/}"
    if [ "$size" -gt "$GSG_MACPATH_FILE_MAX" ]; then
        MACPATH_WHY="$1 is larger than $GSG_MACPATH_FILE_MAX bytes"
        return 1
    fi
    text="$(cat -- "$1" && printf x)" || { MACPATH_WHY="cannot read $1"; return 1; }
    text="${text%x}"
    if [ "${#text}" -ne "$size" ]; then
        MACPATH_WHY="$1 holds a NUL byte"
        return 1
    fi
    MACPATH_CONTENT="$text"
}

# ^ invariant rc 0 = MACPATH_CONTENT has a whole line equal to the begin marker; a newline on each side lets a first or last line count
macpath_has_marker() {
    local c=$'\n'"$MACPATH_CONTENT"$'\n'
    [[ $c == *$'\n'"$GSG_MACPATH_BEGIN"$'\n'* ]]
}

# ^ invariant rc 0 = $1 is "macos-block <created 0|1> <no final newline 0|1> <absolute file>"; sets MACPATH_RCREATED, MACPATH_RNONL and MACPATH_RFILE
macpath_record_file() {
    local rest
    MACPATH_RCREATED="" MACPATH_RNONL="" MACPATH_RFILE=""
    if [[ $1 != "macos-block "[01]" "[01]" /"* ]]; then return 1; fi
    rest="${1#macos-block }"
    MACPATH_RCREATED="${rest:0:1}" MACPATH_RNONL="${rest:2:1}" MACPATH_RFILE="${rest:4}"
}

# ^ invariant rc 0 = file $1 may get the block; rc 1 with MACPATH_WHY otherwise, nothing is written either way
# ^ invariant sets MACPATH_CREATED (1 = the file does not exist) and MACPATH_NONL (1 = it has content and no final newline), for the record
macpath_check_file() {
    MACPATH_CREATED=1 MACPATH_NONL=0 MACPATH_WHY=""
    if [ -L "$1" ]; then MACPATH_WHY="$1 is a symbolic link"; return 1; fi
    if [ ! -e "$1" ]; then return 0; fi
    if [ ! -f "$1" ]; then MACPATH_WHY="$1 is not a regular file"; return 1; fi
    if [ ! -O "$1" ]; then MACPATH_WHY="$1 is not owned by you"; return 1; fi
    macpath_read "$1" || return 1
    if macpath_has_marker; then MACPATH_WHY="$1 has a PATH marker of ours that no record of ours names"; return 1; fi
    MACPATH_CREATED=0
    if [ -n "$MACPATH_CONTENT" ] && [ "${MACPATH_CONTENT%$'\n'}" = "$MACPATH_CONTENT" ]; then MACPATH_NONL=1; fi
}

# ^ invariant read-only; sets INSTALL_PATH_ACTION (present | hint | add), INSTALL_PATH_WHY and for add the record; a refusal keeps the carried record
# ^ why the recorded file is checked before the login shell, not after; a user who changed shell still has the earlier block, and one record holds one file
# ^ external the login shell is the account's (dscl); ~/.zprofile for zsh, ~/.bash_profile for bash
macpath_plan() {
    local file=""
    if macpath_record_file "${ST_CLI_PATH:-}" && [ -f "$MACPATH_RFILE" ] && macpath_read "$MACPATH_RFILE" && macpath_has_marker; then
        INSTALL_PATH_ACTION=present INSTALL_PATH_WHY="$MACPATH_RFILE already has the marked block an earlier install added"
        return 0
    fi
    if ! macpath_login_shell; then
        INSTALL_PATH_ACTION=hint INSTALL_PATH_WHY="the login shell of this account cannot be determined (dscl)"
        return 0
    fi
    case "$REPLY" in
        zsh) file="$HOME/.zprofile" ;;
        bash) file="$HOME/.bash_profile" ;;
        *)
            INSTALL_PATH_ACTION=hint INSTALL_PATH_WHY="the login shell of this account is neither zsh nor bash"
            return 0
            ;;
    esac
    if ! macpath_check_file "$file"; then
        INSTALL_PATH_ACTION=hint INSTALL_PATH_WHY="$MACPATH_WHY; install left it alone"
        return 0
    fi
    INSTALL_PATH_ACTION=add INSTALL_PATH_WHY="" INSTALL_PATH_RECORD="macos-block $MACPATH_CREATED $MACPATH_NONL $file"
}

# ^ invariant appends the block to the recorded file, after the newline it lacked when the record says so; rc 1 with MACPATH_WHY when it cannot write
# ^ why 2>/dev/null before the append redirection, not after; the shell prints its own error for a failed open and the reason is reported once, by the caller
macpath_apply() {
    macpath_record_file "$INSTALL_PATH_RECORD" || { MACPATH_WHY="the record of this install names no startup file"; return 1; }
    {
        if [ "$MACPATH_RNONL" = 1 ]; then printf '\n'; fi
        macpath_block_text
    } 2>/dev/null >>"$MACPATH_RFILE" || { MACPATH_WHY="cannot write $MACPATH_RFILE"; return 1; }
}

# ^ invariant $1 = the record; sets MACPATH_RESULT to removed, none (gone) or left (MACPATH_WHY says why); rc 1 when a write fails or the record is not ours
# ^ invariant only the first exact block starting at a line start is cut; the final newline install added is taken back only when nothing follows the block
# ^ why a cp -p copy renamed over the file, not a write in place; a failure half way never leaves a cut login file, and mode and owner stay
macpath_remove() {
    local LC_ALL=C file block before after tmp
    MACPATH_RESULT=none MACPATH_WHY=""
    macpath_record_file "$1" || { MACPATH_WHY="the record names no startup file"; return 1; }
    file="$MACPATH_RFILE"
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then return 0; fi
    if [ -L "$file" ]; then MACPATH_RESULT=left MACPATH_WHY="$file is a symbolic link now"; return 0; fi
    if [ ! -f "$file" ] || [ ! -O "$file" ]; then MACPATH_RESULT=left MACPATH_WHY="$file is no longer a regular file of yours"; return 0; fi
    if ! macpath_read "$file"; then MACPATH_RESULT=left; return 0; fi
    if ! macpath_has_marker; then return 0; fi
    block="$(macpath_block_text; printf x)"
    block="${block%x}"
    before="${MACPATH_CONTENT%%"$block"*}"
    if [[ $MACPATH_CONTENT != *"$block"* ]] || { [ -n "$before" ] && [ "${before%$'\n'}" = "$before" ]; }; then
        MACPATH_RESULT=left MACPATH_WHY="$file has the PATH marker but not the block install wrote"
        return 0
    fi
    after="${MACPATH_CONTENT#*"$block"}"
    if [ "$MACPATH_RNONL" = 1 ] && [ -z "$after" ] && [ -n "$before" ]; then before="${before%$'\n'}"; fi
    MACPATH_CONTENT="$before$after"
    if [ -z "$MACPATH_CONTENT" ] && [ "$MACPATH_RCREATED" = 1 ]; then
        rm -f -- "$file" || { MACPATH_WHY="cannot remove $file"; return 1; }
    else
        tmp="$file.gsg-new.$$"
        { cp -p -- "$file" "$tmp" && printf '%s' "$MACPATH_CONTENT" >"$tmp" && mv -f -- "$tmp" "$file"; } 2>/dev/null || {
            MACPATH_WHY="cannot write $file"
            rm -f -- "$tmp" || MACPATH_WHY+=" and cannot remove the copy $tmp"
            return 1
        }
    fi
    MACPATH_RESULT=removed
}
