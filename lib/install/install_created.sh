# shellcheck shell=bash

# ^ coupled issue #74; install records what it brings into being (created_by_install of lib/core/state.sh), uninstall removes an empty one
INSTALL_CREATED_BASE="" INSTALL_CREATED_TIMER="" IC_WORDS=""
INSTALL_CREATED_MAX_STEPS=64
INSTALL_CREATED_MAX_CHARS=2048

# ^ invariant install_created_add KIND PATH appends "KIND:<encoded PATH>" to IC_WORDS once; KIND is file or dir
# ^ invariant IC_WORDS stays within INSTALL_CREATED_MAX_CHARS; a word past it is not recorded => uninstall keeps its item, the state line stays readable
install_created_add() {
    local glue=2
    state_created_encode "$2"
    if [[ " $IC_WORDS " == *" $1:$REPLY "* ]]; then return 0; fi
    # ^ why glue counts the colon and the space for every word, not only after the first; it errs toward recording less
    if [ "$((${#IC_WORDS} + ${#1} + ${#REPLY} + glue))" -gt "$INSTALL_CREATED_MAX_CHARS" ]; then return 0; fi
    IC_WORDS+="${IC_WORDS:+ }$1:$REPLY"
}

# ^ invariant adds DIR and each missing parent, child first; stops at the first existing one (or a link) or after INSTALL_CREATED_MAX_STEPS; trailing / cut
install_created_walk() {
    local d="$1" n=0
    d="${d%"${d##*[!/]}"}"
    while [ "$n" -lt "$INSTALL_CREATED_MAX_STEPS" ] && [ "${d#/}" != "$d" ] && [ ! -e "$d" ] && [ ! -L "$d" ]; do
        install_created_add dir "$d"
        d="${d%/*}"
        n=$((n + 1))
    done
}

# ^ order right after paths_init, before any check or change => what is missing now is what this run may bring into being
# ^ external git config --global writes GIT_CONFIG_GLOBAL, else ~/.gitconfig, except when only the XDG git/config exists; it creates no directory
# ^ why the parents of the state and share dirs only, not the dirs; uninstall removes those two already (rmdir of the state dir, uninstall_share_dir)
install_created_snapshot() {
    local cfg xdg
    IC_WORDS=""
    if [ -n "${GIT_CONFIG_GLOBAL:-}" ]; then
        cfg="$(gsg_posix_path "$GIT_CONFIG_GLOBAL")"
    else
        cfg="$HOME/.gitconfig"
        xdg="${XDG_CONFIG_HOME:-$HOME/.config}/git/config"
        if [ -e "$xdg" ] || [ -L "$xdg" ]; then cfg=""; fi
    fi
    if [ "${cfg#/}" != "$cfg" ] && [ ! -e "$cfg" ] && [ ! -L "$cfg" ]; then install_created_add file "$cfg"; fi
    install_created_walk "${GSG_STATE_DIR%/*}"
    install_created_walk "${GSG_SHARE%/*}"
    install_created_walk "$GSG_BIN_DIR"
    INSTALL_CREATED_BASE="$IC_WORDS"
    IC_WORDS=""
    # ^ why apart, not in INSTALL_CREATED_BASE; the unit dir (or LaunchAgents) is made only with a timer or auto-update, known after the state is read
    if brew_is_macos; then
        install_created_walk "$GSG_AGENT_DIR"
    elif ! tools_is_windows; then
        install_created_walk "$GSG_UNIT_DIR"
    fi
    INSTALL_CREATED_TIMER="$IC_WORDS"
}

# ^ invariant prints the created_by_install value; the earlier record stays first and whole, a word this run saw missing is added once
# ^ why the earlier record wins, not what exists now; a thing the first install created is still ours to remove when empty (#74)
install_created_record() {
    local words="$ST_CREATED $INSTALL_CREATED_BASE" out key=created_by_install=
    if [ "$INSTALL_TIMER" -eq 1 ] || [ "$INSTALL_AUTO_UPDATE" = yes ]; then words+=" $INSTALL_CREATED_TIMER"; fi
    out="$(install_unique_words "$words")" || return 1
    # ^ invariant a line state_read would refuse is never written; the earlier record came from a readable line and stays alone
    if [ "$((${#key} + ${#out}))" -gt "$GSG_STATE_LINE_MAX" ]; then out="$ST_CREATED"; fi
    printf '%s\n' "$out"
}

# ^ invariant removes each recorded file only as a regular file (never a link) of 0 bytes, one line each; anything else stays and nothing is said
# ^ order after uninstall_hook_section, before the state goes => a failed removal keeps the state and a rerun finds the record
uninstall_created_files() {
    local w f
    local -a words=()
    read -r -a words <<<"$ST_CREATED"
    for w in "${words[@]}"; do
        if [[ $w != file:* ]]; then continue; fi
        state_created_decode "${w#file:}"
        f="$REPLY"
        if [ -L "$f" ] || [ ! -f "$f" ] || [ -s "$f" ]; then continue; fi
        rm -f -- "$f" || {
            printf '%s: cannot remove %s\n' "$GSG_NAME" "$f" >&2
            return 1
        }
        uninstall_say "removed $f, which install created and which is empty now"
    done
}

# ^ security rmdir only, on a real directory (never a link) => a directory holding anything stays; silent, as the rmdir of the state dir
# ^ invariant a pass per recorded directory at most, the walk ends at the first pass removing nothing => a child goes before its parent in any order
uninstall_created_dirs() {
    local w pass gone
    local -a words=() dirs=()
    read -r -a words <<<"$ST_CREATED"
    for w in "${words[@]}"; do
        if [[ $w != dir:* ]]; then continue; fi
        state_created_decode "${w#dir:}"
        dirs+=("$REPLY")
    done
    for ((pass = 0; pass < ${#dirs[@]}; pass++)); do
        gone=0
        for w in "${dirs[@]}"; do
            if [ -d "$w" ] && [ ! -L "$w" ] && rmdir -- "$w" 2>/dev/null; then gone=1; fi
        done
        if [ "$gone" -eq 0 ]; then break; fi
    done
}
