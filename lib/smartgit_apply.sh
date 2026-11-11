# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled write, verify and restore half of the SmartGit support; the manifest is data (key=value lines), never sourced, and lives in <state dir>/smartgit
# ^ invariant every change of a preferences file is a line edit of the "executable:" and "executable.absolute:" lines
# ^ invariant of its "git:" block; the YAML is never re-serialised

smartgit_discard_tmp() {
    rm -f -- "$1" || printf '%s: could not remove the temporary file %s\n' "$GSG_NAME" "$1" >&2
}

# ^ invariant sets SGA_DIR, SGA_MANIFEST and SGA_BACKUP for settings directory $1; the id is the cksum of its path
smartgit_paths() {
    local id
    id="$(smartgit_dir_id "$1")" || return 1
    SGA_DIR="$GSG_STATE_DIR/smartgit"
    SGA_MANIFEST="$SGA_DIR/$id.manifest"
    SGA_BACKUP="$SGA_DIR/$id.preferences.yml"
}

smartgit_hash_file() {
    local out
    out="$(sha256sum -- "$1")" || {
        printf '%s: cannot hash %s\n' "$GSG_NAME" "$1" >&2
        return 1
    }
    printf '%s' "${out%% *}"
}

SMARTGIT_MANIFEST_VERSION=1
SMARTGIT_MANIFEST_MAX_LINES=20
SMARTGIT_MANIFEST_PREVIEW_CHARS=60
SMARTGIT_SHA256_HEX_LEN=64
SMARTGIT_UMASK=077
SMARTGIT_FILE_MODE=600
SMARTGIT_MANIFEST_KEYS=(version status settings backup orig_hash orig_executable orig_absolute new_executable new_absolute)

# ^ invariant args = status (pending or final), settings file, orig hash/exec/abs, new exec/abs ("-" = no such line); a value never holds a newline
smartgit_manifest_write() {
    local tmp all="$*"
    if [[ $all == *$'\n'* ]]; then
        printf '%s: a value to record contains a newline; refusing to write the manifest\n' "$GSG_NAME" >&2
        return 1
    fi
    tmp="$(umask "$SMARTGIT_UMASK" && mktemp "$SGA_DIR/manifest.XXXXXX")" || {
        printf '%s: cannot create a file in %s\n' "$GSG_NAME" "$SGA_DIR" >&2
        return 1
    }
    {
        printf 'version=%s\nstatus=%s\nsettings=%s\nbackup=%s\n' "$SMARTGIT_MANIFEST_VERSION" "$1" "$2" "$SGA_BACKUP"
        printf 'orig_hash=%s\norig_executable=%s\norig_absolute=%s\n' "$3" "$4" "$5"
        printf 'new_executable=%s\nnew_absolute=%s\n' "$6" "$7"
    } >"$tmp" || {
        printf '%s: cannot write the manifest %s\n' "$GSG_NAME" "$SGA_MANIFEST" >&2
        smartgit_discard_tmp "$tmp"
        return 1
    }
    mv -f -- "$tmp" "$SGA_MANIFEST" || {
        printf '%s: cannot move the manifest into place as %s\n' "$GSG_NAME" "$SGA_MANIFEST" >&2
        smartgit_discard_tmp "$tmp"
        return 1
    }
}

# ^ invariant data, never sourced; at most 20 lines, only the nine known keys, each once, status pending or final, orig_hash 64 hex; sets SGM_*; rc 1 prints why
smartgit_manifest_read() {
    local f="$1" line key val seen=" " bad="" hex_re="^[0-9a-f]{$SMARTGIT_SHA256_HEX_LEN}$"
    local -a lines=()
    SGM_STATUS="" SGM_SETTINGS="" SGM_BACKUP="" SGM_ORIG_HASH="" SGM_ORIG_EXEC="" SGM_ORIG_ABS="" SGM_NEW_EXEC="" SGM_NEW_ABS=""
    { mapfile -t -n "$((SMARTGIT_MANIFEST_MAX_LINES + 1))" lines <"$f"; } 2>/dev/null || bad="it cannot be read"
    if [ -z "$bad" ] && [ "${#lines[@]}" -gt "$SMARTGIT_MANIFEST_MAX_LINES" ]; then bad="it is too long"; fi
    for line in "${lines[@]}"; do
        key="${line%%=*}"
        val="${line#*=}"
        if [[ $line != *=* ]] || [[ $seen == *" $key "* ]]; then
            bad="malformed at [${line:0:$SMARTGIT_MANIFEST_PREVIEW_CHARS}]"
            break
        fi
        case "$key" in
            version) if [ "$val" != "$SMARTGIT_MANIFEST_VERSION" ]; then bad="unknown version"; fi ;;
            status) SGM_STATUS="$val" ;;
            settings) SGM_SETTINGS="$val" ;;
            backup) SGM_BACKUP="$val" ;;
            orig_hash) SGM_ORIG_HASH="$val" ;;
            orig_executable) SGM_ORIG_EXEC="$val" ;;
            orig_absolute) SGM_ORIG_ABS="$val" ;;
            new_executable) SGM_NEW_EXEC="$val" ;;
            new_absolute) SGM_NEW_ABS="$val" ;;
            *) bad="unknown key [$key]" ;;
        esac
        seen+="$key "
        if [ -n "$bad" ]; then break; fi
    done
    for key in "${SMARTGIT_MANIFEST_KEYS[@]}"; do
        if [ -z "$bad" ] && [[ $seen != *" $key "* ]]; then bad="key [$key] is missing"; fi
    done
    if [ -z "$bad" ] && [ "$SGM_STATUS" != pending ] && [ "$SGM_STATUS" != final ]; then bad="status is neither pending nor final"; fi
    if [ -z "$bad" ] && [[ ! $SGM_ORIG_HASH =~ $hex_re ]]; then bad="orig_hash is not a sha256"; fi
    if [ -n "$bad" ]; then
        printf '%s: the manifest %s is not one this tool wrote (%s)\n' "$GSG_NAME" "$f" "$bad" >&2
        return 1
    fi
}

# ^ invariant the copy is mode 0600 and must hash like the source before the first change is made; any failure discards the partial copy; sets SGA_ORIG_HASH
smartgit_backup_make() {
    local want got
    want="$(smartgit_hash_file "$1")" || return 1
    (umask "$SMARTGIT_UMASK" && cp -- "$1" "$2") || {
        printf '%s: cannot copy %s to %s\n' "$GSG_NAME" "$1" "$2" >&2
        smartgit_discard_tmp "$2"
        return 1
    }
    chmod "$SMARTGIT_FILE_MODE" "$2" || {
        printf '%s: cannot set mode %s on %s\n' "$GSG_NAME" "$SMARTGIT_FILE_MODE" "$2" >&2
        smartgit_discard_tmp "$2"
        return 1
    }
    got="$(smartgit_hash_file "$2")" || {
        smartgit_discard_tmp "$2"
        return 1
    }
    if [ "$got" != "$want" ]; then
        printf '%s: the backup %s does not match %s; nothing was changed\n' "$GSG_NAME" "$2" "$1" >&2
        smartgit_discard_tmp "$2"
        return 1
    fi
    SGA_ORIG_HASH="$want"
}

# ^ invariant the one failure path of the edit; prints the reason, discards the temp file, returns 1
smartgit_edit_fail() {
    printf '%s: %s; the preferences file was not changed\n' "$GSG_NAME" "$2" >&2
    smartgit_discard_tmp "$1"
    return 1
}

# ^ invariant prints the size in bytes of file $1 without the padding some wc versions add; rc 1 prints why
smartgit_size_of() {
    local n
    n="$(wc -c <"$1")" || {
        printf '%s: cannot read the size of %s\n' "$GSG_NAME" "$1" >&2
        return 1
    }
    printf '%s' "${n//[[:space:]]/}"
}

# ^ invariant edits only the "executable:" line and, when the file has one and ABS is not "-", the "executable.absolute:" line; args = file, exec, abs
# ^ invariant the temp file is in the same dir, keeps the mode and size, differs from the old lines at the two indexes only, is re-analysed before the rename
# ^ external LC_ALL=C makes ${#line} count bytes; the size check holds for non-ASCII paths; stat -c is GNU, put first on a Mac by brew_use_gnubin
smartgit_edit_prefs() {
    local f="$1" exec="$2" abs="$3" dir tmp mode i exec_idx abs_idx old_size want_size got_size exec_line="  executable: $2" abs_line=""
    local LC_ALL=C
    local -a old=() new=()
    smartgit_prefs_analyze "$f" || {
        printf '%s: %s does not have the recorded shape any more (%s); it was not changed\n' "$GSG_NAME" "$f" "$SGP_WHY" >&2
        return 1
    }
    old=("${SGP_LINES[@]}")
    new=("${SGP_LINES[@]}")
    exec_idx="$SGP_EXEC_IDX" abs_idx="$SGP_ABS_IDX"
    old_size="$(smartgit_size_of "$f")" || return 1
    want_size=$((old_size - ${#old[$exec_idx]} + ${#exec_line}))
    new[exec_idx]="$exec_line"
    if [ "$abs_idx" -ge 0 ] && [ "$abs" != - ]; then
        abs_line="  executable.absolute: $abs"
        want_size=$((want_size - ${#old[$abs_idx]} + ${#abs_line}))
        new[abs_idx]="$abs_line"
    fi
    mode="$(stat -c %a -- "$f")" || {
        printf '%s: cannot read the mode of %s; it was not changed\n' "$GSG_NAME" "$f" >&2
        return 1
    }
    dir="$(dirname -- "$f")"
    tmp="$(mktemp "$dir/.preferences.yml.gsg.XXXXXX")" || {
        printf '%s: cannot create a temporary file beside %s\n' "$GSG_NAME" "$f" >&2
        return 1
    }
    if ! printf '%s\n' "${new[@]}" >"$tmp" || ! chmod "$mode" "$tmp"; then smartgit_edit_fail "$tmp" "cannot write the new preferences beside $f"; return; fi
    got_size="$(smartgit_size_of "$tmp")" || {
        smartgit_discard_tmp "$tmp"
        return 1
    }
    if [ "$got_size" -ne "$want_size" ] || ! smartgit_prefs_analyze "$tmp" || [ "$SGP_EXEC" != "$exec" ] || [ "${#SGP_LINES[@]}" -ne "${#old[@]}" ]; then
        smartgit_edit_fail "$tmp" "the edited copy of $f failed its checks (size $got_size, expected $want_size)"
        return
    fi
    for i in "${!old[@]}"; do
        if [ "$i" -ne "$exec_idx" ] && [ "$i" -ne "$abs_idx" ] && [ "${SGP_LINES[$i]}" != "${old[$i]}" ]; then
            smartgit_edit_fail "$tmp" "line $((i + 1)) of the edited copy of $f differs from the original"
            return
        fi
    done
    mv -f -- "$tmp" "$f" || smartgit_edit_fail "$tmp" "cannot move the edited copy over $f"
}

# ^ security the fake credential below is made up, joined from fragments at run time and never printed; it only proves the hook blocks it (AC8)
# ^ invariant runs in a subshell of smartgit_verify_run; rc 0 = the fake-token commit was blocked with findings text, a clean commit printed the summary line
# ^ invariant 2 = scratch setup failed, 3 = fake-token commit not blocked, 4 = clean commit failed, 5 = no summary line, 6 = fake-token commit failed otherwise
smartgit_verify_commits() {
    local work="$1" key out env_names
    local -a gc=(-c user.name=gsg-verify -c user.email=gsg-verify@example.invalid -c commit.gpgsign=false)
    env_names="$("$GSG_GIT" rev-parse --local-env-vars)" || return 2
    # shellcheck disable=SC2086
    unset $env_names
    key="$(printf '%s%s%s' 'AKI' 'A' 'Q7XK2MWB4HZ5NR3T')"
    "$GSG_GIT" init -q --template= "$work" || return 2
    printf 'aws_access_key_id = %s\n' "$key" >"$work/leak.txt" || return 2
    "$GSG_GIT" -C "$work" add leak.txt || return 2
    if out="$("$GSG_GIT" "${gc[@]}" -C "$work" commit -q -m verify-secret 2>&1)"; then return 3; fi
    if "$GSG_GIT" -C "$work" rev-parse -q --verify HEAD >/dev/null 2>&1; then return 3; fi
    if [[ $out != *"potential secret(s)"* ]]; then return 6; fi
    "$GSG_GIT" -C "$work" rm -q -f --cached leak.txt || return 2
    printf 'hello\n' >"$work/ok.txt" || return 2
    "$GSG_GIT" -C "$work" add ok.txt || return 2
    out="$("$GSG_GIT" "${gc[@]}" -C "$work" commit -q -m verify-clean 2>&1)" || return 4
    if [[ $out != *"$GSG_NAME: scanned"* ]]; then return 5; fi
}

# ^ invariant the scratch repository is removed on every path; any failing check says what failed and returns 1
smartgit_verify_run() {
    local work rc
    if ! smartgit_check_target "$GSG_GIT"; then return 1; fi
    if ! smartgit_lfs_present "$GSG_GIT"; then
        printf '%s: git lfs version fails through %s\n' "$GSG_NAME" "$GSG_GIT" >&2
        return 1
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/gsg-smartgit-verify.XXXXXX")" || {
        printf '%s: cannot create a scratch directory for the check\n' "$GSG_NAME" >&2
        return 1
    }
    (smartgit_verify_commits "$work")
    rc=$?
    if [ -n "$work" ] && [ -d "$work" ]; then rm -rf -- "$work" || printf '%s: could not remove the scratch directory %s\n' "$GSG_NAME" "$work" >&2; fi
    case "$rc" in
        0) printf '%s: checked through %s: git lfs works, a fake-token commit was blocked and a clean commit printed the summary line\n' "$GSG_NAME" "$GSG_GIT" ;;
        3) printf '%s: a commit of a fake token through %s was NOT blocked, so it does not run the hook\n' "$GSG_NAME" "$GSG_GIT" >&2 ;;
        4) printf '%s: a clean commit through %s failed\n' "$GSG_NAME" "$GSG_GIT" >&2 ;;
        5) printf '%s: a clean commit through %s printed no %s summary line\n' "$GSG_NAME" "$GSG_GIT" "$GSG_NAME" >&2 ;;
        6) printf '%s: the commit of a fake token through %s failed, but not with the findings text of the hook\n' "$GSG_NAME" "$GSG_GIT" >&2 ;;
        *) printf '%s: the scratch repository check could not be set up (status %s)\n' "$GSG_NAME" "$rc" >&2 ;;
    esac
    [ "$rc" -eq 0 ]
}

# ^ invariant rc 0 = running, 1 = not running, 2 = it cannot be told; only the macOS app is edited, hence only it is looked for, by its launcher path
smartgit_kind_running() {
    local rc
    if [ "$1" != macos ]; then return 2; fi
    smartgit_tool pgrep || return 2
    "$REPLY" -f 'Contents/MacOS/SmartGit' >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then return "$rc"; fi
    return 2
}

# ^ invariant removes the manifest and its backup together; a failed removal is said, never silent
smartgit_drop_manifest() {
    rm -f -- "$1" "$2" || {
        printf '%s: could not remove %s and %s\n' "$GSG_NAME" "$1" "$2" >&2
        return 1
    }
}

# ^ invariant informational outcomes (restored, already original, file gone, changed since) print to stdout and return 0; errors print to stderr and return 1
# ^ invariant restores only when the executable lines are still those this tool wrote; a value changed since is left alone, manifest dropped, backup kept
# ^ invariant an invalid manifest, or a missing backup or one not hashing like the manifest says, stops the restore and prints the by-hand step
smartgit_restore_one() {
    local mf="$1" kind=macos want got
    smartgit_manifest_read "$mf" || {
        printf '%s: restore by hand: in SmartGit open Preferences, Commands and choose the Git Executable you used before\n' "$GSG_NAME" >&2
        return 1
    }
    if [ ! -f "$SGM_BACKUP" ] || ! got="$(smartgit_hash_file "$SGM_BACKUP")" || [ "$got" != "$SGM_ORIG_HASH" ]; then
        printf '%s: the backup %s is missing or does not match the manifest %s; nothing was restored; by hand: in SmartGit open Preferences, Commands and set the Git Executable back to %s\n' \
            "$GSG_NAME" "$SGM_BACKUP" "$mf" "$SGM_ORIG_EXEC" >&2
        return 1
    fi
    if [ ! -f "$SGM_SETTINGS" ]; then
        printf '%s: %s is gone; nothing to restore there\n' "$GSG_NAME" "$SGM_SETTINGS"
        smartgit_drop_manifest "$mf" "$SGM_BACKUP"
        return
    fi
    smartgit_kind_running "$kind"
    case $? in
        0)
            printf '%s: SmartGit is running; exit it with Repository, Exit and run the restore again; nothing was changed\n' "$GSG_NAME" >&2
            return 1
            ;;
        1) ;;
        *)
            printf '%s: it cannot be told whether SmartGit is running; exit it and run the restore again; nothing was changed\n' "$GSG_NAME" >&2
            return 1
            ;;
    esac
    smartgit_prefs_analyze "$SGM_SETTINGS" || {
        printf '%s: %s cannot be edited (%s); restore by hand: set the Git Executable back to %s; the backup is %s\n' "$GSG_NAME" "$SGM_SETTINGS" "$SGP_WHY" "$SGM_ORIG_EXEC" "$SGM_BACKUP" >&2
        return 1
    }
    want="$SGM_NEW_ABS"
    if [ "$SGP_EXEC" = "$SGM_NEW_EXEC" ] && { { [ "$want" = - ] && [ "$SGP_ABS_IDX" -lt 0 ]; } || [ "$SGP_ABS" = "$want" ]; }; then
        smartgit_edit_prefs "$SGM_SETTINGS" "$SGM_ORIG_EXEC" "$SGM_ORIG_ABS" || return 1
        printf '%s: restored the Git Executable of %s from the backup\n' "$GSG_NAME" "$SGM_SETTINGS"
        smartgit_drop_manifest "$mf" "$SGM_BACKUP"
    elif [ "$SGP_EXEC" = "$SGM_ORIG_EXEC" ]; then
        printf '%s: the Git Executable of %s is already the original; nothing to restore\n' "$GSG_NAME" "$SGM_SETTINGS"
        smartgit_drop_manifest "$mf" "$SGM_BACKUP"
    else
        printf '%s: the Git Executable of %s was changed after this tool set it (now %s); it was left alone; the original preferences are kept at %s\n' "$GSG_NAME" "$SGM_SETTINGS" "$SGP_EXEC" "$SGM_BACKUP"
        rm -f -- "$mf" || {
            printf '%s: could not remove %s\n' "$GSG_NAME" "$mf" >&2
            return 1
        }
    fi
}

# ^ invariant rc 0 = SmartGit is not running; running, or not tellable, is refused with SmartGit untouched; arg = the settings directory index
smartgit_assert_not_running() {
    local rc
    smartgit_kind_running "${SG_SET_KIND[$1]}"
    rc=$?
    if [ "$rc" -eq 1 ]; then return 0; fi
    printf '%s: SmartGit %s: SmartGit is running or started meanwhile (or it cannot be told); exit it with Repository, Exit and run the command again; its preferences were not changed\n' \
        "$GSG_NAME" "${SG_SET_MAJOR[$1]}" >&2
    return 1
}

# ^ invariant an existing backup of a different file is renamed to a dated .kept name, never overwritten; one of the same file stays; arg = the preferences file
smartgit_backup_aside() {
    local cur old aside
    if [ ! -e "$SGA_BACKUP" ]; then return 0; fi
    cur="$(smartgit_hash_file "$1")" || return 1
    old="$(smartgit_hash_file "$SGA_BACKUP")" || return 1
    if [ "$cur" = "$old" ]; then return 0; fi
    aside="$SGA_BACKUP.kept-$(date -u +%Y%m%dT%H%M%SZ)"
    mv -n -- "$SGA_BACKUP" "$aside" || return 1
    if [ -e "$SGA_BACKUP" ] || [ ! -e "$aside" ]; then
        printf '%s: could not move the earlier backup %s aside; nothing was changed\n' "$GSG_NAME" "$SGA_BACKUP" >&2
        return 1
    fi
    printf '%s: the earlier backup was kept as %s\n' "$GSG_NAME" "$aside"
}

# ^ invariant an earlier manifest of the same directory is finished or undone first (restore); an interrupted run never leaves two backups in play
# ^ order backup, pending manifest, edit, final manifest; the original file is not touched before the backup hashes right and the pending manifest is written
smartgit_apply_one() {
    local i="$1" dir f orig_exec orig_abs new_abs=- stale target="$GSG_GIT"
    dir="${SG_SET_DIR[$i]}"
    f="$dir/preferences.yml"
    smartgit_paths "$dir" || return 1
    (umask "$SMARTGIT_UMASK" && mkdir -p -- "$SGA_DIR") || {
        printf '%s: cannot create %s\n' "$GSG_NAME" "$SGA_DIR" >&2
        return 1
    }
    smartgit_clean_tmp || return 1
    for stale in "$dir"/.preferences.yml.gsg.??????; do
        if [ -f "$stale" ]; then smartgit_discard_tmp "$stale"; fi
    done
    smartgit_assert_not_running "$i" || return 1
    if [ -e "$SGA_MANIFEST" ]; then
        smartgit_restore_one "$SGA_MANIFEST" || {
            printf '%s: an earlier change of %s could not be undone first; run %s restore-smartgit\n' "$GSG_NAME" "$dir" "$GSG_NAME" >&2
            return 1
        }
    fi
    smartgit_prefs_analyze "$f" || {
        printf '%s: %s cannot be edited (%s)\n' "$GSG_NAME" "$f" "$SGP_WHY" >&2
        return 1
    }
    orig_exec="$SGP_EXEC"
    orig_abs=-
    if [ "$SGP_ABS_IDX" -ge 0 ]; then
        orig_abs="$SGP_ABS"
        new_abs="$target"
    fi
    smartgit_backup_aside "$f" || return 1
    smartgit_backup_make "$f" "$SGA_BACKUP" || return 1
    smartgit_manifest_write pending "$f" "$SGA_ORIG_HASH" "$orig_exec" "$orig_abs" "$target" "$new_abs" || return 1
    if ! smartgit_assert_not_running "$i"; then
        smartgit_drop_manifest "$SGA_MANIFEST" "$SGA_BACKUP" || printf '%s: could not drop the pending change of %s\n' "$GSG_NAME" "$f" >&2
        return 1
    fi
    smartgit_edit_prefs "$f" "$target" "$new_abs" || return 1
    smartgit_manifest_write final "$f" "$SGA_ORIG_HASH" "$orig_exec" "$orig_abs" "$target" "$new_abs"
}

# ^ invariant args = indexes of the settings directories touched; each restored from its manifest; "restored" is claimed only if a restore ran and none failed
smartgit_rollback() {
    local i failed=0 restored=0
    for i in "$@"; do
        smartgit_paths "${SG_SET_DIR[$i]}" || {
            printf '%s: %s could not be checked for a restore\n' "$GSG_NAME" "${SG_SET_DIR[$i]}" >&2
            failed=1
            continue
        }
        if [ ! -e "$SGA_MANIFEST" ]; then continue; fi
        if smartgit_restore_one "$SGA_MANIFEST"; then
            restored=$((restored + 1))
        else
            printf '%s: the preferences of %s could not be restored; see the by-hand step above\n' "$GSG_NAME" "${SG_SET_DIR[$i]}" >&2
            failed=1
        fi
    done
    if [ "$failed" -ne 0 ]; then
        printf '%s: SmartGit was NOT fully restored (see above); %s\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2
    elif [ "$restored" -gt 0 ]; then
        printf '%s: SmartGit was restored from its backup; %s\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2
    else
        printf '%s: no SmartGit file had been changed, so nothing was restored; %s\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2
    fi
}

# ^ order Git LFS first (package, and after it its filter), the settings last; a failure before the first edit leaves every preferences file untouched
# ^ invariant any failure after the first edit rolls every directory of this run back; the Git LFS package and filter stay, and the message says so
smartgit_apply() {
    local i
    local -a applied=()
    smartgit_lfs_install_pkg || return 1
    smartgit_lfs_configure || return 1
    for i in "$@"; do
        smartgit_apply_one "$i" || {
            smartgit_rollback "$i" "${applied[@]}"
            return 1
        }
        applied+=("$i")
    done
    if ! smartgit_verify_run; then
        smartgit_rollback "${applied[@]}"
        return 1
    fi
    for i in "${applied[@]}"; do
        printf '%s: SmartGit %s now commits with %s; start SmartGit again to use it (backup and manifest in %s/smartgit)\n' "$GSG_NAME" "${SG_SET_MAJOR[$i]}" "$GSG_GIT" "$GSG_STATE_DIR"
    done
}

# ^ invariant true when this tool left a manifest, a record or a temp file of an interrupted run under <state dir>/smartgit
smartgit_has_records() {
    local f
    for f in "$GSG_STATE_DIR"/smartgit/*.manifest "$GSG_STATE_DIR"/smartgit/lfs.record "$GSG_STATE_DIR"/smartgit/manifest.?????? "$GSG_STATE_DIR"/smartgit/lfs-tmp.??????; do
        if [ -e "$f" ]; then return 0; fi
    done
    return 1
}

# ^ invariant removes only the temp files this tool names (manifest.XXXXXX, lfs-tmp.XXXXXX) left in the smartgit state directory by an interrupted run
smartgit_clean_tmp() {
    local f rc=0
    for f in "$GSG_STATE_DIR"/smartgit/manifest.?????? "$GSG_STATE_DIR"/smartgit/lfs-tmp.??????; do
        if [ -f "$f" ]; then smartgit_discard_tmp "$f" || rc=1; fi
    done
    return "$rc"
}

# ^ invariant the manifest loop is bounded; every manifest is tried even after a failure, and the directory goes only when everything worked
smartgit_restore_all() {
    local mf n=0 rc=0
    smartgit_clean_tmp || rc=1
    for mf in "$GSG_STATE_DIR"/smartgit/*.manifest; do
        if [ ! -e "$mf" ]; then continue; fi
        n=$((n + 1))
        if ! smartgit_under_cap "$n"; then
            printf '%s: more than %s manifests in %s/smartgit; the rest were not restored\n' "$GSG_NAME" "$SMARTGIT_MAX_ENTRIES" "$GSG_STATE_DIR" >&2
            rc=1
            break
        fi
        smartgit_restore_one "$mf" || rc=1
    done
    smartgit_lfs_undo || rc=1
    if [ "$rc" -eq 0 ]; then rmdir -- "$GSG_STATE_DIR/smartgit" 2>/dev/null || true; fi
    return "$rc"
}

# ^ invariant the restore-smartgit command; "nothing to restore" and rc 0 when this tool never changed SmartGit
smartgit_restore_run() {
    paths_init || return 1
    lifecycle_note_global_config
    lifecycle_require_git || return 1
    smartgit_announce_overrides
    if ! smartgit_has_records; then
        printf '%s: nothing to restore: git-secret-guard has not changed SmartGit\n' "$GSG_NAME"
        return 0
    fi
    smartgit_restore_all
}
