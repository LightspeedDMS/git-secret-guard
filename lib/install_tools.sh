# shellcheck shell=bash disable=SC2153
# ^ coupled install_run in lib/install.sh calls these in order; install_tools_ready calls the macOS helpers defined there

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
    local path got h
    local -a want=()
    path="$GSG_BIN_DIR/$(tools_binary_name "$1")"
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

# ^ invariant Windows only; a jq on PATH install did not place stays in use, one recorded in tools_placed stays managed on every rerun
# ^ invariant the file at the install path with the pinned SHA-256 is install's own after an uninstall kept it => adopted, recorded in both state keys now
# ^ order after state_read and before install_plan_lock => jq joins the parallel arrays and gets the same lock, staging, ownership and aside handling
install_manage_jq() {
    if ! tools_is_windows; then return 0; fi
    if [[ " $ST_PLACED " != *" jq:"* ]]; then
        if [ -z "$INSTALL_JQ_BIN" ]; then
            install_adopt_jq || true
        elif [ "$INSTALL_JQ_BIN" -ef "$GSG_BIN_DIR/$(tools_binary_name jq)" ]; then
            install_adopt_jq || return 0
        else
            return 0
        fi
    fi
    GSG_TOOL_NAMES+=(jq)
    INSTALL_JQ_BIN="$GSG_BIN_DIR/$(tools_binary_name jq)"
    # shellcheck disable=SC2034
    INSTALL_JQ_WRAPPER="$GSG_SHARE/jq"
}

# ^ why the lock row decides, not a record; uninstall without --remove-tools deletes the state and keeps the file => its hash is the only proof left
# ^ security a link, another directory or another hash is the user's file => never recorded, never replaced, never removed
# ^ invariant rc 1 = nothing adopted, no error; tools_installed_by_us gets the tool too = uninstall_tools walks only the list of tools_installed_by_us
install_adopt_if_hash() {
    local tool="$1" expect="$2" path sha
    path="$GSG_BIN_DIR/$(tools_binary_name "$tool")"
    if [ -z "$expect" ] || [ ! -f "$path" ] || [ -L "$path" ]; then return 1; fi
    sha="$(sha256sum -- "$path" | cut -d' ' -f1)" || return 1
    if [ -z "$sha" ] || [ "$sha" != "$expect" ]; then return 1; fi
    ST_PLACED+="${ST_PLACED:+ }$tool:$sha"
    if [[ " $ST_TOOLS " != *" $tool "* ]]; then ST_TOOLS+="${ST_TOOLS:+ }$tool"; fi
}

# ^ invariant the jq asset is the bare binary => the lock row's archive hash is its binary hash
install_adopt_jq() {
    local plat row
    plat="$(tools_platform_key jq "$GSG_OS" "$GSG_ARCH")" || return 1
    row="$(tools_lock_lookup "$(tools_lock_path)" jq "$plat")" || return 1
    install_adopt_if_hash jq "${row##* }"
}

# ^ invariant scanners always sit at $GSG_BIN_DIR => no PATH condition as for jq; a tool with a hash in tools_placed is left alone
# ^ invariant a row without the fifth column adopts nothing; a file kept from an older pin does not match the new row and stays the user's
# ^ order after state_read, before install_plan_lock and install_manage_jq => the adopted words are in ST_PLACED when the plan and install_write_state read them
install_adopt_scanners() {
    local tool plat want
    for tool in "${GSG_TOOL_NAMES[@]}"; do
        if [[ " $ST_PLACED " == *" $tool:"* ]]; then continue; fi
        plat="$(tools_platform_key "$tool" "$GSG_OS" "$GSG_ARCH")" || continue
        want="$(tools_lock_binary_sha "$(tools_lock_path)" "$tool" "$plat" 2>/dev/null)" || continue
        install_adopt_if_hash "$tool" "$want" || true
    done
}

# ^ order pure bash, no timeout needed => install_run calls it before the brew install, a missing or invalid lock row refuses with the machine untouched
# ^ invariant parallel arrays indexed like GSG_TOOL_NAMES, holding platform key, version, archive SHA-256 and binary SHA-256 ("" without the fifth column)
install_plan_lock() {
    local tool plat row lock
    GSG_TOOL_VER=() GSG_TOOL_SHA=() GSG_TOOL_PLAT=() GSG_TOOL_BSHA=()
    lock="$(tools_lock_path)"
    for tool in "${GSG_TOOL_NAMES[@]}"; do
        plat="$(tools_platform_key "$tool" "$GSG_OS" "$GSG_ARCH")" || return 1
        row="$(tools_lock_lookup "$lock" "$tool" "$plat")" || return 1
        GSG_TOOL_PLAT+=("$plat")
        GSG_TOOL_VER+=("${row%% *}")
        GSG_TOOL_SHA+=("${row##* }")
        GSG_TOOL_BSHA+=("$(tools_lock_binary_sha "$lock" "$tool" "$plat")") || return 1
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
        if tools_has_version "$GSG_BIN_DIR/$(tools_binary_name "$tool")" "${GSG_TOOL_VER[$i]}" "$INSTALL_TIMEOUT_BIN"; then
            GSG_TOOL_NEED+=(0)
        else
            GSG_TOOL_NEED+=(1)
            if { [ -e "$GSG_BIN_DIR/$(tools_binary_name "$tool")" ] || [ -L "$GSG_BIN_DIR/$(tools_binary_name "$tool")" ]; } && ! install_owns_file "$tool"; then aside="$tool.gsg-replaced-$stamp"; fi
        fi
        if [ -n "$aside" ] && { [ -e "$GSG_BIN_DIR/$aside" ] || [ -L "$GSG_BIN_DIR/$aside" ]; }; then
            printf '%s: %s already exists, so %s cannot be moved there; %s\n' "$GSG_NAME" "$GSG_BIN_DIR/$aside" "$GSG_BIN_DIR/$(tools_binary_name "$tool")" "$(brew_unchanged_text)" >&2
            return 1
        fi
        GSG_TOOL_ASIDE+=("$aside")
    done
}

# shellcheck disable=SC2329
install_cleanup() {
    local rc=$?
    gitup_abort_cleanup "$rc"
    if [ -n "${GSG_STAGE:-}" ]; then rm -rf -- "$GSG_STAGE"; fi
    if [ -n "${GITUP_BUILD_DIR:-}" ]; then gitup_source_cleanup; fi
    # ^ invariant GSG_SHARE_NEW is "" once the tree is renamed to the share dir => this never deletes the live share
    if [ -n "${GSG_SHARE_NEW:-}" ]; then rm -rf -- "$GSG_SHARE_NEW"; fi
}

# ^ invariant always returns 1; the closing line of a staging refusal, true before and after a brew install
install_stage_refused() {
    printf '%s: install refused; %s\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2
    return 1
}

# ^ invariant rc 0 when $3 is empty (the lock row has no binary hash) or equals the SHA-256 of $2; rc 1 with a message otherwise
# ^ why before the version probe, not after; the probe would run a file the lock does not vouch for
install_check_binary_sha() {
    local tool="$1" bin="$2" want="$3" got
    if [ -z "$want" ]; then return 0; fi
    got="$(sha256sum -- "$bin" | cut -d' ' -f1)" || return 1
    if [ "$got" = "$want" ]; then return 0; fi
    printf '%s: the extracted %s does not match the SHA-256 in the lock for the binary (want %s, got %s)\n' "$GSG_NAME" "$tool" "$want" "${got:-none}" >&2
    return 1
}

# ^ order every needed tool is downloaded, verified and version-checked before any file leaves the staging dir => a bad second tool installs nothing
install_stage_tools() {
    local i tool tarball out bin
    GSG_STAGE=""
    if [[ " ${GSG_TOOL_NEED[*]} " != *" 1 "* ]]; then return 0; fi
    install_require_curl || install_stage_refused || return 1
    GSG_STAGE="$(mktemp -d)" || return 1
    mkdir -p -- "$GSG_STAGE/out" || return 1
    for i in "${!GSG_TOOL_NAMES[@]}"; do
        if [ "${GSG_TOOL_NEED[$i]}" -ne 1 ]; then continue; fi
        tool="${GSG_TOOL_NAMES[$i]}"
        printf '%s: downloading %s %s\n' "$GSG_NAME" "$tool" "${GSG_TOOL_VER[$i]}" >&2
        tarball="$(tools_fetch_verified "$tool" "${GSG_TOOL_VER[$i]}" "${GSG_TOOL_PLAT[$i]}" "${GSG_TOOL_SHA[$i]}" "$GSG_STAGE")" || install_stage_refused || return 1
        tools_extract_binary "$tarball" "$tool" "$GSG_STAGE/out" || install_stage_refused || return 1
        bin="$GSG_STAGE/out/$(tools_binary_name "$tool")"
        install_check_binary_sha "$tool" "$bin" "${GSG_TOOL_BSHA[$i]:-}" || install_stage_refused || return 1
        if ! tools_has_version "$bin" "${GSG_TOOL_VER[$i]}" "$INSTALL_TIMEOUT_BIN"; then
            out="$("$INSTALL_TIMEOUT_BIN" "$GSG_VERSION_PROBE_SECONDS" "$bin" --version 2>&1 | head -c 200)"
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
        sha="$(sha256sum -- "$GSG_STAGE/out/$(tools_binary_name "$tool")" | cut -d' ' -f1)"
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
        target="$GSG_BIN_DIR/$(tools_binary_name "$tool")"
        aside="${GSG_TOOL_ASIDE[$i]}"
        new="$GSG_BIN_DIR/.$tool.gsg-new"
        # ^ why install -T, not a plain destination; a directory at $new would take the file inside it and the cleanup rm -f would add "Is a directory"
        # ^ why capture install's stderr, not let it through; coreutils prints its own line before ours, and the reason belongs inside the one message
        err="$(install -m 755 -T -- "$GSG_STAGE/out/$(tools_binary_name "$tool")" "$new" 2>&1)" || {
            err="${err%%$'\n'*}"
            # ^ why strip through the name, not only its start; an absolute-path exec wrapper, as the lifecycle stand-ins are, makes install print its full path
            err="${err#*install: }"
            err="${err//[[:cntrl:]]/?}"
            # ^ why our own text for a directory, not install's; one wording on every platform and no reliance on coreutils phrasing
            if [ -d "$new" ]; then err="a directory is in the way"; fi
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
