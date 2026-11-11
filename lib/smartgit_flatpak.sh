# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled Flatpak half of the SmartGit support; the four steps were run by hand on Fedora with SmartGit 26.1 and host git 2.55.0
# ^ see docs/smartgit.md, "Linux, Flatpak (verified)"
# ^ security step 1 removes the SmartGit sandbox (it can run any command on the host as you); it has its own consent, never implied by --configure-smartgit

SMARTGIT_FLATPAK_TALK=org.freedesktop.Flatpak
SMARTGIT_WRAPPER_MARKER='# git-secret-guard: written by install --configure-smartgit; undone by restore-smartgit'
SMARTGIT_FLATPAK_KEYS=(override override_clean wrapper_hash vmoption vmoption_file tmpdir tmpdir_path)

# ^ invariant sets SGF_WRAPPER, SGF_VMOPTS, SGF_TMPDIR and SGF_RECORD for the Flatpak settings directory $1;
# ^ invariant the vmoptions file sits one level above the major directory
smartgit_flatpak_paths() {
    if [ -z "${1:-}" ]; then
        printf '%s: no Flatpak settings directory was given to smartgit_flatpak_paths\n' "$GSG_NAME" >&2
        return 1
    fi
    SGF_WRAPPER="$HOME/.local/share/smartgit/host-bin/git"
    SGF_VMOPTS="${1%/*}/smartgit.vmoptions"
    SGF_TMPDIR="$HOME/.cache/smartgit-tmp"
    SGF_RECORD="$GSG_STATE_DIR/smartgit/flatpak.record"
}

# ^ invariant the wrapper of the verified setup; it runs the HOST git through flatpak-spawn and rewrites SmartGit's sandbox-only credential helper argument;
# ^ invariant the marker is line 2
smartgit_flatpak_wrapper_text() {
    printf '#!/bin/sh\n%s\n' "$SMARTGIT_WRAPPER_MARKER"
    cat <<'EOF'
# SmartGit passes credential.helper=/app/bin/smartgit.sh ..., a path that only exists inside the sandbox,
# so it is rewritten to launch that helper through the host's flatpak.
n=$#
while [ "$n" -gt 0 ]; do
    a=$1; shift
    case "$a" in
        "credential.helper=/app/bin/smartgit.sh "*)
            a="credential.helper=!flatpak run --command=/app/bin/smartgit.sh com.syntevo.SmartGit ${a#credential.helper=/app/bin/smartgit.sh }"
            ;;
    esac
    set -- "$@" "$a"
    n=$((n - 1))
done
exec flatpak-spawn --host git "$@"
EOF
}

# ^ invariant data, never sourced; only the seven known keys, each at most once, at most 20 lines; sets SGR_* (empty = not recorded); rc 1 prints why
smartgit_flatpak_record_read() {
    local f="$1" line key bad="" seen=" "
    local -a lines=()
    SGR_override="" SGR_override_clean="" SGR_wrapper_hash="" SGR_vmoption="" SGR_vmoption_file="" SGR_tmpdir="" SGR_tmpdir_path=""
    { mapfile -t -n "$((SMARTGIT_MANIFEST_MAX_LINES + 1))" lines <"$f"; } 2>/dev/null || bad="it cannot be read"
    if [ -z "$bad" ] && [ "${#lines[@]}" -gt "$SMARTGIT_MANIFEST_MAX_LINES" ]; then bad="it is too long"; fi
    for line in "${lines[@]}"; do
        key="${line%%=*}"
        if [[ $line != *=* ]] || [[ $seen == *" $key "* ]] || [[ " ${SMARTGIT_FLATPAK_KEYS[*]} " != *" $key "* ]]; then
            bad="malformed or unknown at [${line:0:$SMARTGIT_MANIFEST_PREVIEW_CHARS}]"
            break
        fi
        printf -v "SGR_$key" '%s' "${line#*=}"
        seen+="$key "
    done
    if [ -n "$bad" ]; then
        printf '%s: the record %s is not one this tool wrote (%s)\n' "$GSG_NAME" "$f" "$bad" >&2
        return 1
    fi
}

SMARTGIT_WRAPPER_MODE=755

# ^ invariant args = directory, template name, umask or "" for the caller's; creates the directory and one temp file in it, prints the path, says why on failure
smartgit_mktmp() {
    local dir="$1" tpl="$2" um="${3:-}" tmp
    if ! tmp="$(umask "${um:-$(umask)}" && mkdir -p -- "$dir" && mktemp "$dir/$tpl.XXXXXX")"; then
        printf '%s: cannot create a temporary file in %s\n' "$GSG_NAME" "$dir" >&2
        return 1
    fi
    printf '%s' "$tmp"
}

# ^ invariant the record is rewritten after every step changing something, from the SGT_* variables; a step changing nothing does not rewrite it
smartgit_flatpak_record_write() {
    local tmp
    tmp="$(smartgit_mktmp "${SGF_RECORD%/*}" flatpak "$SMARTGIT_UMASK")" || return 1
    {
        printf 'override=%s\noverride_clean=%s\nwrapper_hash=%s\n' "${SGT_override:-no}" "${SGT_clean:-no}" "${SGT_whash:-}"
        printf 'vmoption=%s\nvmoption_file=%s\ntmpdir=%s\ntmpdir_path=%s\n' "${SGT_vm:-no}" "$SGF_VMOPTS" "${SGT_tmpd:-no}" "$SGF_TMPDIR"
    } >"$tmp" || {
        printf '%s: cannot write the Flatpak record %s\n' "$GSG_NAME" "$SGF_RECORD" >&2
        smartgit_discard_tmp "$tmp"
        return 1
    }
    mv -f -- "$tmp" "$SGF_RECORD" || {
        printf '%s: cannot move the Flatpak record into place as %s\n' "$GSG_NAME" "$SGF_RECORD" >&2
        smartgit_discard_tmp "$tmp"
        return 1
    }
}

# ^ invariant step 1 adds the talk permission only when it is absent; override_clean=yes records the absence of any override;
# ^ invariant the undo may reset the whole override in this case
# ^ invariant a failing override --show is refused, never read as "no override"; an existing override is never recorded as ours to reset
smartgit_flatpak_step_override() {
    local out
    SGT_override=no SGT_clean=no
    out="$("$SGT_FLATPAK" override --show --system "$SMARTGIT_FLATPAK_ID" 2>&1)" || {
        printf '%s: flatpak override --show failed (%s); the sandbox was not changed\n' "$GSG_NAME" "${out//[[:cntrl:]]/ }" >&2
        return 1
    }
    if [[ $out == *"$SMARTGIT_FLATPAK_TALK=talk"* ]]; then return 0; fi
    if [ -z "${out//[[:space:]]/}" ]; then SGT_clean=yes; fi
    if ! gitup_system_bin flatpak; then
        printf '%s: flatpak was not found in the system path (%s) or is not root-owned, so it cannot be run as root; the sandbox was not changed\n' "$GSG_NAME" "$GITUP_SYSTEM_PATH" >&2
        return 1
    fi
    gitup_elevate "$REPLY" override --system --talk-name="$SMARTGIT_FLATPAK_TALK" "$SMARTGIT_FLATPAK_ID" || {
        printf '%s: flatpak override --system failed; the sandbox was not changed\n' "$GSG_NAME" >&2
        return 1
    }
    SGT_override=yes
    smartgit_flatpak_record_write
}

# ^ invariant an existing file at the wrapper path is replaced only when it is not a link and still carries our marker line; anything else is refused
# ^ invariant the wrapper is hashed and recorded before it is moved into place; a failure never leaves a wrapper the record does not name
# ^ why a normal umask here, not SMARTGIT_UMASK; the wrapper must be executable and readable by the sandbox, and it holds no secret
smartgit_flatpak_step_wrapper() {
    local tmp
    if [ -e "$SGF_WRAPPER" ] || [ -L "$SGF_WRAPPER" ]; then
        if [ -L "$SGF_WRAPPER" ] || ! grep -qxF -- "$SMARTGIT_WRAPPER_MARKER" "$SGF_WRAPPER"; then
            printf '%s: %s exists and is not a wrapper this tool wrote; it was left alone\n' "$GSG_NAME" "$SGF_WRAPPER" >&2
            return 1
        fi
    fi
    tmp="$(smartgit_mktmp "${SGF_WRAPPER%/*}" .git.gsg "")" || return 1
    if ! smartgit_flatpak_wrapper_text >"$tmp" || ! chmod "$SMARTGIT_WRAPPER_MODE" "$tmp"; then
        printf '%s: cannot write the wrapper %s\n' "$GSG_NAME" "$SGF_WRAPPER" >&2
        smartgit_discard_tmp "$tmp"
        return 1
    fi
    SGT_whash="$(smartgit_hash_file "$tmp")" || {
        printf '%s: cannot hash the wrapper %s\n' "$GSG_NAME" "$SGF_WRAPPER" >&2
        smartgit_discard_tmp "$tmp"
        return 1
    }
    smartgit_flatpak_record_write || {
        smartgit_discard_tmp "$tmp"
        return 1
    }
    mv -f -- "$tmp" "$SGF_WRAPPER" || {
        printf '%s: cannot move the wrapper into place as %s\n' "$GSG_NAME" "$SGF_WRAPPER" >&2
        smartgit_discard_tmp "$tmp"
        return 1
    }
}

# ^ invariant one java.io.tmpdir line is added only when absent and every other line of the file stays; a file without a final newline gets one first
# ^ why the tmp dir, not the sandbox /tmp; SmartGit writes the commit message there and the host git cannot see the sandbox's /tmp
smartgit_flatpak_step_vmoptions() {
    local line="-Djava.io.tmpdir=$SGF_TMPDIR" last
    SGT_vm=no SGT_tmpd=no
    if [ ! -d "$SGF_TMPDIR" ]; then
        mkdir -p -- "$SGF_TMPDIR" || {
            printf '%s: cannot create %s\n' "$GSG_NAME" "$SGF_TMPDIR" >&2
            return 1
        }
        SGT_tmpd=yes
    fi
    if [ -f "$SGF_VMOPTS" ] && grep -qxF -- "$line" "$SGF_VMOPTS"; then
        smartgit_flatpak_record_write
        return
    fi
    mkdir -p -- "${SGF_VMOPTS%/*}" || {
        printf '%s: cannot create %s\n' "$GSG_NAME" "${SGF_VMOPTS%/*}" >&2
        return 1
    }
    if [ -s "$SGF_VMOPTS" ]; then
        last="$(
            tail -c 1 -- "$SGF_VMOPTS"
            printf x
        )"
        if [ "$last" != $'\nx' ] && ! printf '\n' >>"$SGF_VMOPTS"; then
            printf '%s: cannot write %s\n' "$GSG_NAME" "$SGF_VMOPTS" >&2
            return 1
        fi
    fi
    printf '%s\n' "$line" >>"$SGF_VMOPTS" || {
        printf '%s: cannot write %s\n' "$GSG_NAME" "$SGF_VMOPTS" >&2
        return 1
    }
    SGT_vm=yes
    smartgit_flatpak_record_write
}

# ^ invariant the wrapper is run the way SmartGit runs it, inside the sandbox; git --version must be at the floor or newer and git lfs version must work
smartgit_flatpak_sandbox_check() {
    local out
    out="$("$SGT_FLATPAK" run --command=sh "$SMARTGIT_FLATPAK_ID" -c "\"$SGF_WRAPPER\" --version" 2>&1)" || {
        printf '%s: the wrapper %s does not run inside the SmartGit sandbox (%s)\n' "$GSG_NAME" "$SGF_WRAPPER" "${out//[[:cntrl:]]/ }" >&2
        return 1
    }
    if [[ $out != *"git version "* ]] || ! gitup_version_at_least "$(sed -E 's/^.*git version ([0-9]+\.[0-9]+).*$/\1/' <<<"$out")" "$(smartgit_min_git)"; then
        printf '%s: the wrapper reports [%s] inside the sandbox, not a git of %s or newer\n' "$GSG_NAME" "${out//[[:cntrl:]]/ }" "$(smartgit_min_git)" >&2
        return 1
    fi
    "$SGT_FLATPAK" run --command=sh "$SMARTGIT_FLATPAK_ID" -c "\"$SGF_WRAPPER\" lfs version" >/dev/null 2>&1 || {
        printf '%s: git lfs version fails through the wrapper inside the sandbox\n' "$GSG_NAME" >&2
        return 1
    }
}

# ^ security the override step runs only with SMARTGIT_SANDBOX_FLAG=1 (--allow-smartgit-sandbox-removal or a yes at the question);
# ^ security --configure-smartgit alone never removes the sandbox
# ^ order step 1 override, 2 wrapper, 3 vmoptions line, 4 Git Executable; each step records itself before acting; any stop is undone by restore-smartgit
smartgit_flatpak_apply_one() {
    local i="$1" rc
    SGT_override="" SGT_clean="" SGT_whash="" SGT_vm="" SGT_tmpd=""
    if [ "${SMARTGIT_SANDBOX_FLAG:-0}" -ne 1 ]; then
        printf '%s: the Flatpak setup removes the sandbox of SmartGit and needs its own consent: run with --allow-smartgit-sandbox-removal, or answer yes at the question\n' "$GSG_NAME" >&2
        return 1
    fi
    smartgit_tool flatpak || {
        printf '%s: flatpak was not found; the Flatpak setup needs it\n' "$GSG_NAME" >&2
        return 1
    }
    SGT_FLATPAK="$REPLY"
    smartgit_tool flatpak-spawn || {
        printf '%s: flatpak-spawn was not found; the wrapper needs it\n' "$GSG_NAME" >&2
        return 1
    }
    smartgit_flatpak_paths "${SG_SET_DIR[$i]}" || return 1
    smartgit_flatpak_step_override || return 1
    smartgit_flatpak_step_wrapper || return 1
    smartgit_flatpak_step_vmoptions || return 1
    SGA_TARGET="$SGF_WRAPPER"
    smartgit_apply_one "$i"
    rc=$?
    SGA_TARGET=""
    if [ "$rc" -ne 0 ]; then return 1; fi
    smartgit_flatpak_sandbox_check
}

# ^ invariant the plan names all four steps; the override is a root command (gitup_plan_priv resolves flatpak in the system path), the rest runs as you
smartgit_flatpak_plan_dir() {
    local i="$1"
    smartgit_flatpak_paths "${SG_SET_DIR[$i]}" || return 1
    printf '  Flatpak SmartGit %s, in four steps (verified by hand on Fedora with SmartGit 26.1; see docs/smartgit.md):\n' "${SG_SET_MAJOR[$i]}"
    printf '    1. the sandbox of SmartGit is removed: it may then run any command on the host as you (needs its own consent)\n'
    gitup_plan_priv "flatpak override --system --talk-name=$SMARTGIT_FLATPAK_TALK $SMARTGIT_FLATPAK_ID"
    printf '    2. writes the wrapper %s (runs the host git; marked as ours)\n' "$SGF_WRAPPER"
    printf '    3. adds the line -Djava.io.tmpdir=%s to %s and creates that directory\n' "$SGF_TMPDIR" "$SGF_VMOPTS"
    printf '    4. sets the Git Executable of %s to the wrapper\n' "${SG_SET_DIR[$i]}/preferences.yml"
}

# ^ invariant the wrapper and record paths do not depend on the directory given to smartgit_flatpak_paths; undo passes this placeholder only to set them
SMARTGIT_UNDO_PLACEHOLDER_DIR=undo-placeholder

# ^ invariant undo removes exactly what the record names; a whole override only if there was none, the wrapper only with our marker, the recorded vmoptions line
# ^ invariant smartgit_flatpak_paths and smartgit_flatpak_record_read report own errors; an unresettable override prints a by-hand step, keeps the record, rc 1
# ^ invariant the directories of the wrapper are left, they may predate this tool; the tmp dir goes only when this tool created it and it is empty
smartgit_flatpak_undo() {
    local rec="$GSG_STATE_DIR/smartgit/flatpak.record" rc=0 line tmp
    if [ ! -f "$rec" ]; then return 0; fi
    smartgit_flatpak_paths "$HOME/.var/app/$SMARTGIT_FLATPAK_ID/config/smartgit/$SMARTGIT_UNDO_PLACEHOLDER_DIR" || return 1
    smartgit_flatpak_record_read "$rec" || return 1
    if [ "$SGR_override" = yes ]; then
        if [ "$SGR_override_clean" = yes ] && gitup_select && gitup_system_bin flatpak && gitup_elevate "$REPLY" override --system --reset "$SMARTGIT_FLATPAK_ID"; then
            printf '%s: removed the system override of %s\n' "$GSG_NAME" "$SMARTGIT_FLATPAK_ID"
        else
            printf '%s: the system override of %s was not reset here (other overrides may exist, or flatpak or a way to run it as root was not found); by hand: sudo flatpak override --system --no-talk-name=%s %s\n' \
                "$GSG_NAME" "$SMARTGIT_FLATPAK_ID" "$SMARTGIT_FLATPAK_TALK" "$SMARTGIT_FLATPAK_ID" >&2
            rc=1
        fi
    fi
    if [ -f "$SGF_WRAPPER" ] && [ ! -L "$SGF_WRAPPER" ] && grep -qxF -- "$SMARTGIT_WRAPPER_MARKER" "$SGF_WRAPPER"; then
        rm -f -- "$SGF_WRAPPER" || rc=1
    fi
    line="-Djava.io.tmpdir=$SGR_tmpdir_path"
    if [ "$SGR_vmoption" = yes ] && [ "${SGR_vmoption_file##*/}" = smartgit.vmoptions ] && [ -f "$SGR_vmoption_file" ]; then
        tmp="$(smartgit_mktmp "${SGR_vmoption_file%/*}" .vmoptions.gsg "")" || rc=1
        if [ -n "$tmp" ]; then
            if { grep -vxF -- "$line" "$SGR_vmoption_file" >"$tmp" || [ "$?" -eq 1 ]; } && mv -f -- "$tmp" "$SGR_vmoption_file"; then
                printf '%s: removed the java.io.tmpdir line from %s\n' "$GSG_NAME" "$SGR_vmoption_file"
            else
                smartgit_discard_tmp "$tmp"
                rc=1
            fi
        fi
    fi
    if [ "$SGR_tmpdir" = yes ] && [ -d "$SGR_tmpdir_path" ] && ! rmdir -- "$SGR_tmpdir_path" 2>/dev/null; then
        printf '%s: %s is not empty, so it was kept\n' "$GSG_NAME" "$SGR_tmpdir_path"
    fi
    if [ "$rc" -eq 0 ]; then rm -f -- "$rec" || rc=1; fi
    return "$rc"
}
