# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled Flatpak half of the SmartGit support; the four steps of docs/smartgit.md as one unit, each recorded before it acts, undone from the record
# ^ security step 1 removes the SmartGit sandbox; it has its own consent (a second question or --allow-smartgit-sandbox-removal), never implied by the first
# ^ invariant the record is data (key=value lines), never sourced; it lives beside the manifests in <state dir>/smartgit

SMARTGIT_FLATPAK_TALK=org.freedesktop.Flatpak
SMARTGIT_WRAPPER_MARKER='# git-secret-guard: written by install --configure-smartgit; undone by restore-smartgit'
SMARTGIT_FLATPAK_RECORD_VERSION=1
SMARTGIT_PROBE_SECONDS=60
SMARTGIT_PROBE_GRACE_SECONDS=5
SMARTGIT_WRAPPER_MODE=755
SMARTGIT_TMPDIR_MODE=700
SMARTGIT_VMOPTS_NEW_MODE=644
# ^ invariant 1 only when the CLI saw --allow-smartgit-sandbox-removal; bin/git-secret-guard sets it after the libraries load
SMARTGIT_SANDBOX_FLAG=0
SGF_FLATPAK=""

# ^ invariant sets SGF_WRAPPER, SGF_TMPDIR, SGF_RECORD, SGF_VMOPTS (one level above every major directory) and SGF_WRAPPER_TOPS, the directories
# ^ invariant mkdir -p may create for the wrapper, outermost first; the record may name only one of them
smartgit_flatpak_paths() {
    SGF_WRAPPER="$HOME/.local/share/smartgit/host-bin/git"
    SGF_TMPDIR="$HOME/.cache/smartgit-tmp"
    SGF_RECORD="$GSG_STATE_DIR/smartgit/flatpak.record"
    SGF_VMOPTS="${GSG_SMARTGIT_FLATPAK_BASE:-$HOME/.var/app/$SMARTGIT_FLATPAK_ID/config/smartgit}/smartgit.vmoptions"
    SGF_WRAPPER_TOPS=("$HOME/.local" "$HOME/.local/share" "$HOME/.local/share/smartgit" "$HOME/.local/share/smartgit/host-bin")
}

# ^ invariant the one failure path of smartgit_flatpak_record_read; prints why and returns 1
smartgit_flatpak_record_bad() {
    printf '%s: the record %s is not one this tool wrote (%s)\n' "$GSG_NAME" "$SGF_RECORD" "$1" >&2
    return 1
}

# ^ invariant sets SGR_* from the record (no and empty without one); yes/no values, vmoption also created; the two paths only as this tool writes them
smartgit_flatpak_record_read() {
    local line key val seen=" " bad="" top_ok=0 d
    local -a lines=()
    SGR_override=no SGR_clean=no SGR_wrapper=no SGR_wrapper_top="" SGR_vm=no SGR_vmfile="" SGR_tmpdir=no
    if [ ! -e "$SGF_RECORD" ]; then return 0; fi
    { mapfile -t -n "$((SMARTGIT_MANIFEST_MAX_LINES + 1))" lines <"$SGF_RECORD"; } 2>/dev/null || bad="it cannot be read"
    if [ -z "$bad" ] && [ "${#lines[@]}" -gt "$SMARTGIT_MANIFEST_MAX_LINES" ]; then bad="it is too long"; fi
    for line in "${lines[@]}"; do
        if [ -n "$bad" ]; then break; fi
        key="${line%%=*}" val="${line#*=}"
        if [[ $line != *=* ]] || [[ $seen == *" $key "* ]]; then
            bad="malformed at [${line:0:$SMARTGIT_MANIFEST_PREVIEW_CHARS}]"
            break
        fi
        seen+="$key "
        case "$key" in
            version) if [ "$val" != "$SMARTGIT_FLATPAK_RECORD_VERSION" ]; then bad="unknown version"; fi ;;
            override) SGR_override="$val" ;;
            override_clean) SGR_clean="$val" ;;
            wrapper) SGR_wrapper="$val" ;;
            wrapper_top) SGR_wrapper_top="$val" ;;
            vmoption) SGR_vm="$val" ;;
            vmoption_file) SGR_vmfile="$val" ;;
            tmpdir) SGR_tmpdir="$val" ;;
            *) bad="unknown key [$key]" ;;
        esac
    done
    if [ -n "$bad" ]; then smartgit_flatpak_record_bad "$bad"; return; fi
    if [[ ! "$SGR_override $SGR_clean $SGR_wrapper $SGR_tmpdir" =~ ^(yes|no)\ (yes|no)\ (yes|no)\ (yes|no)$ ]] || [[ ! $SGR_vm =~ ^(yes|no|created)$ ]]; then
        smartgit_flatpak_record_bad "a value is not yes, no or created"
        return
    fi
    if [ -n "$SGR_vmfile" ] && [ "$SGR_vmfile" != "$SGF_VMOPTS" ]; then smartgit_flatpak_record_bad "vmoption_file is not $SGF_VMOPTS"; return; fi
    for d in "" "${SGF_WRAPPER_TOPS[@]}"; do
        if [ "$SGR_wrapper_top" = "$d" ]; then top_ok=1; fi
    done
    if [ "$top_ok" -ne 1 ]; then smartgit_flatpak_record_bad "wrapper_top is not a directory above the wrapper"; fi
}

# ^ invariant a rerun starts from the earlier record; a yes stays yes (OR); a step done by an earlier run is still undone by the restore
smartgit_flatpak_carry() {
    SGT_override="$SGR_override" SGT_clean="$SGR_clean" SGT_wrapper="$SGR_wrapper" SGT_wrapper_top="$SGR_wrapper_top"
    SGT_vm="$SGR_vm" SGT_vmfile="$SGR_vmfile" SGT_tmpdir="$SGR_tmpdir"
}

# ^ invariant written from SGT_* through a temp file renamed over flatpak.record; each step calls it before the change it records
smartgit_flatpak_record_write() {
    local dir="${SGF_RECORD%/*}" tmp
    (umask "$SMARTGIT_UMASK" && mkdir -p -- "$dir") || {
        printf '%s: cannot create %s for the Flatpak record\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
    tmp="$(umask "$SMARTGIT_UMASK" && mktemp "$dir/flatpak-tmp.XXXXXX")" || {
        printf '%s: cannot create a file in %s for the Flatpak record\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
    {
        printf 'version=%s\noverride=%s\noverride_clean=%s\nwrapper=%s\nwrapper_top=%s\n' \
            "$SMARTGIT_FLATPAK_RECORD_VERSION" "$SGT_override" "$SGT_clean" "$SGT_wrapper" "$SGT_wrapper_top"
        printf 'vmoption=%s\nvmoption_file=%s\ntmpdir=%s\n' "$SGT_vm" "$SGT_vmfile" "$SGT_tmpdir"
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

# ^ invariant rc 0 = a SmartGit Flatpak instance with a live pid, 1 = none, 2 = it cannot be told (no flatpak, ps failed, too many lines)
# ^ external flatpak ps keeps listing an instance for some seconds after its flatpak run ended, with a pid already gone (fact 6 of the Linux spike)
smartgit_flatpak_running() {
    local out pid app rest n=0
    smartgit_tool flatpak || return 2
    out="$(smartgit_bounded "$REPLY" ps --columns=pid,application </dev/null 2>/dev/null)" || return 2
    while read -r pid app rest; do
        n=$((n + 1))
        if [ "$n" -gt "$SMARTGIT_MAX_LINES" ]; then return 2; fi
        if [ "$app" != "$SMARTGIT_FLATPAK_ID" ] || [[ ! $pid =~ ^[0-9]+$ ]]; then continue; fi
        if kill -0 "$pid" 2>/dev/null; then return 0; fi
    done <<<"$out"
    return 1
}

# ^ invariant runs the host flatpak (SGF_FLATPAK) with stdin from /dev/null, killed after SECONDS ($1) under install's timeout, the doctor bound otherwise
# ^ why --foreground, not plain timeout; plain timeout moves flatpak into a group of its own, where a Ctrl-C or TERM of install never reaches it
smartgit_flatpak_call() {
    local secs="$1"
    shift
    if [ -n "${INSTALL_TIMEOUT_BIN:-}" ]; then
        "$INSTALL_TIMEOUT_BIN" --foreground -k "$SMARTGIT_PROBE_GRACE_SECONDS" "$secs" "$SGF_FLATPAK" "$@" </dev/null
    else
        smartgit_bounded "$SGF_FLATPAK" "$@" </dev/null
    fi
}

# ^ invariant sets SGF_SHOW = the override of scope $1 (user or system) and SGF_TALK = 1 when it lets SmartGit talk to flatpak; a failing show is said, rc 1
smartgit_flatpak_show() {
    local line
    SGF_TALK=0
    SGF_SHOW="$(smartgit_flatpak_call "$SMARTGIT_PROBE_SECONDS" override --"$1" --show "$SMARTGIT_FLATPAK_ID" 2>/dev/null)" || {
        printf '%s: flatpak override --%s --show %s failed, so it cannot be told whether SmartGit may already talk to flatpak\n' "$GSG_NAME" "$1" "$SMARTGIT_FLATPAK_ID" >&2
        return 1
    }
    while IFS= read -r line; do
        if [ "$line" = "$SMARTGIT_FLATPAK_TALK=talk" ] || [ "$line" = "$SMARTGIT_FLATPAK_TALK=own" ]; then SGF_TALK=1; fi
    done <<<"$SGF_SHOW"
}

# ^ security step 1 (--user, no root); a permission found in either scope is the user's and is never recorded as ours; a restore never takes it away
# ^ order the record says override=yes before the command runs; an interrupt after it leaves a record the restore can undo
smartgit_flatpak_override_step() {
    local before
    smartgit_flatpak_show user || return 1
    before="$SGF_SHOW"
    if [ "$SGF_TALK" -eq 1 ]; then return 0; fi
    smartgit_flatpak_show system || return 1
    if [ "$SGF_TALK" -eq 1 ]; then
        printf '%s: SmartGit may already talk to flatpak (system override); that override is not ours and is left alone\n' "$GSG_NAME"
        return 0
    fi
    if [ "$SGT_override" != yes ]; then
        SGT_clean=no
        if [ -z "${before//[[:space:]]/}" ]; then SGT_clean=yes; fi
    fi
    SGT_override=yes
    smartgit_flatpak_record_write || return 1
    smartgit_flatpak_call "$SMARTGIT_PROBE_SECONDS" override --user --talk-name="$SMARTGIT_FLATPAK_TALK" "$SMARTGIT_FLATPAK_ID" || {
        printf '%s: flatpak override --user --talk-name=%s %s failed; the record already says override=yes, so the rollback (or restore-smartgit) undoes what it left\n' \
            "$GSG_NAME" "$SMARTGIT_FLATPAK_TALK" "$SMARTGIT_FLATPAK_ID" >&2
        return 1
    }
}

# ^ invariant $1 = the host git, absolute and plain (smartgit_target_is_plain); it needs no quoting; the marker is line 2, where the undo looks for it
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
EOF
    printf 'exec flatpak-spawn --host %s "$@"\n' "$1"
}

# ^ invariant rc 0 = the wrapper must not be written, SGF_WHY says why; a wrapper without our marker on line 2 was made by hand and is never replaced
smartgit_flatpak_wrapper_unsafe() {
    local d l1="" l2=""
    for d in "${SGF_WRAPPER_TOPS[@]}"; do
        if [ -L "$d" ] || { [ -e "$d" ] && { [ ! -d "$d" ] || [ ! -O "$d" ]; }; }; then
            SGF_WHY="$d is a symlink, not a directory or not yours"
            return 0
        fi
    done
    if [ ! -e "$SGF_WRAPPER" ] && [ ! -L "$SGF_WRAPPER" ]; then return 1; fi
    if [ -L "$SGF_WRAPPER" ] || [ ! -f "$SGF_WRAPPER" ]; then
        SGF_WHY="the wrapper $SGF_WRAPPER is a symlink or not a regular file"
        return 0
    fi
    { IFS= read -r l1 && IFS= read -r l2; } <"$SGF_WRAPPER" 2>/dev/null
    if [ "$l2" != "$SMARTGIT_WRAPPER_MARKER" ]; then
        SGF_WHY="the wrapper $SGF_WRAPPER exists and was not written by this tool (made by hand?); it is left as it is"
        return 0
    fi
    return 1
}

# ^ order wrapper=yes and the outermost new directory are recorded before mkdir; the file is a temp file renamed with mv -T, never written through a link
smartgit_flatpak_wrapper_step() {
    local d dir="${SGF_WRAPPER%/*}" tmp
    if smartgit_flatpak_wrapper_unsafe; then
        printf '%s: %s; SmartGit was not changed further\n' "$GSG_NAME" "$SGF_WHY" >&2
        return 1
    fi
    if [ -z "$SGT_wrapper_top" ]; then
        for d in "${SGF_WRAPPER_TOPS[@]}"; do
            if [ ! -e "$d" ]; then SGT_wrapper_top="$d" && break; fi
        done
    fi
    SGT_wrapper=yes
    smartgit_flatpak_record_write || return 1
    (umask 022 && mkdir -p -- "$dir") || {
        printf '%s: cannot create %s for the wrapper\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
    tmp="$(mktemp "$dir/.git.gsg.XXXXXX")" || {
        printf '%s: cannot create a file in %s for the wrapper\n' "$GSG_NAME" "$dir" >&2
        return 1
    }
    if ! smartgit_flatpak_wrapper_text "$1" >"$tmp" || ! chmod "$SMARTGIT_WRAPPER_MODE" "$tmp" || ! mv -fT -- "$tmp" "$SGF_WRAPPER"; then
        printf '%s: cannot write the wrapper %s\n' "$GSG_NAME" "$SGF_WRAPPER" >&2
        if [ -e "$tmp" ]; then smartgit_discard_tmp "$tmp"; fi
        return 1
    fi
}

# ^ invariant rc 0 = smartgit.vmoptions must not be edited, SGF_WHY says why; a file without a final newline is refused, the added line would join its last one
smartgit_flatpak_vm_unsafe() {
    local f="$SGF_VMOPTS"
    if [ -L "${f%/*}" ]; then
        SGF_WHY="${f%/*} is a symlink"
        return 0
    fi
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then return 1; fi
    if [ -L "$f" ] || [ ! -f "$f" ] || [ ! -O "$f" ]; then
        SGF_WHY="$f is a symlink, not a regular file or not yours"
        return 0
    fi
    if [ -n "$(tail -c 1 -- "$f")" ]; then
        SGF_WHY="$f does not end with a newline"
        return 0
    fi
    return 1
}

# ^ order vmoption (yes, or created for a new file) is recorded before the temp file is renamed over the original; every byte before the line stays
smartgit_flatpak_vm_step() {
    local f="$SGF_VMOPTS" line="-Djava.io.tmpdir=$SGF_TMPDIR" mode="$SMARTGIT_VMOPTS_NEW_MODE" tmp
    if smartgit_flatpak_vm_unsafe; then
        printf '%s: %s; SmartGit was not changed further\n' "$GSG_NAME" "$SGF_WHY" >&2
        return 1
    fi
    if [ -f "$f" ] && grep -qxF -e "$line" -- "$f"; then return 0; fi
    if [ "$SGT_vm" = no ]; then
        SGT_vm=created
        if [ -e "$f" ]; then SGT_vm=yes; fi
    fi
    SGT_vmfile="$f"
    smartgit_flatpak_record_write || return 1
    if [ -e "$f" ]; then mode="$(stat -c %a -- "$f")" || return 1; fi
    tmp="$(mktemp "${f%/*}/.smartgit.vmoptions.gsg.XXXXXX")" || {
        printf '%s: cannot create a file next to %s\n' "$GSG_NAME" "$f" >&2
        return 1
    }
    if ! { if [ -e "$f" ]; then cat -- "$f"; fi && printf '%s\n' "$line"; } >"$tmp" || ! chmod "$mode" "$tmp" || ! mv -fT -- "$tmp" "$f"; then
        printf '%s: cannot add the temp directory line to %s\n' "$GSG_NAME" "$f" >&2
        if [ -e "$tmp" ]; then smartgit_discard_tmp "$tmp"; fi
        return 1
    fi
}

# ^ invariant rc 0 = the temp directory exists and is a symlink, not a directory or not yours (SGF_WHY says so); rc 1 = it is missing or usable
smartgit_flatpak_tmpdir_unsafe() {
    if [ -L "$SGF_TMPDIR" ] || { [ -e "$SGF_TMPDIR" ] && { [ ! -d "$SGF_TMPDIR" ] || [ ! -O "$SGF_TMPDIR" ]; }; }; then
        SGF_WHY="$SGF_TMPDIR is a symlink, not a directory or not yours; SmartGit's temp directory must be a real directory of yours"
        return 0
    fi
    return 1
}

# ^ invariant the temp directory SmartGit gets (mode 0700); an existing one is used as it is when it is a real directory of yours, never recorded as ours
smartgit_flatpak_tmpdir_step() {
    if smartgit_flatpak_tmpdir_unsafe; then
        printf '%s: %s; SmartGit was not changed further\n' "$GSG_NAME" "$SGF_WHY" >&2
        return 1
    fi
    if [ -d "$SGF_TMPDIR" ]; then return 0; fi
    SGT_tmpdir=yes
    smartgit_flatpak_record_write || return 1
    if ! mkdir -p -- "${SGF_TMPDIR%/*}" || ! mkdir -m "$SMARTGIT_TMPDIR_MODE" -- "$SGF_TMPDIR"; then
        printf '%s: cannot create %s\n' "$GSG_NAME" "$SGF_TMPDIR" >&2
        return 1
    fi
}

# ^ invariant rc 0 = the Flatpak directory $1 may be set up; each refusal comes before any change, says why and prints the manual steps
# ^ external the probe leaves a flatpak ps entry with a dead pid; the running check after it counts live pids only
smartgit_flatpak_check() {
    local i="$1" why=""
    smartgit_flatpak_paths
    if ! smartgit_tool flatpak; then
        why="no flatpak command was found on this machine"
    elif [ "$SMARTGIT_SANDBOX_FLAG" -ne 1 ] && { [ ! -t 0 ] || [ ! -t 2 ]; }; then
        why="step 1 removes the SmartGit sandbox and needs its own yes: run install at a terminal, or add --allow-smartgit-sandbox-removal"
    elif ! smartgit_target_is_plain "$SGF_WRAPPER"; then
        why="the wrapper path $SGF_WRAPPER is not made of [A-Za-z0-9._/+@%-]"
    elif smartgit_flatpak_wrapper_unsafe || smartgit_flatpak_vm_unsafe || smartgit_flatpak_tmpdir_unsafe; then
        why="$SGF_WHY"
    elif ! smartgit_flatpak_record_read; then
        why="the Flatpak record cannot be used (see above); run $GSG_NAME restore-smartgit or remove it"
    fi
    SGF_FLATPAK="$REPLY"
    if [ -z "$why" ] && ! smartgit_flatpak_call "$SMARTGIT_PROBE_SECONDS" run --command=sh "$SMARTGIT_FLATPAK_ID" -c 'command -v flatpak-spawn' >/dev/null 2>&1; then
        why="flatpak-spawn was not found inside the SmartGit sandbox (or flatpak run failed)"
    fi
    if [ -z "$why" ]; then return 0; fi
    smartgit_refuse "$i" "$why" 0
    smartgit_flatpak_manual_steps
    return 1
}

smartgit_flatpak_plan() {
    local dir="creates that directory (mode 0700)"
    if [ -d "$SGF_TMPDIR" ] && [ ! -L "$SGF_TMPDIR" ]; then
        dir="uses the existing directory $SGF_TMPDIR as it is (this tool did not make it, so restore-smartgit keeps it)"
    fi
    printf '    1. flatpak override --user --talk-name=%s %s (no root; this removes the SmartGit sandbox; an override already there is left alone)\n' "$SMARTGIT_FLATPAK_TALK" "$SMARTGIT_FLATPAK_ID"
    printf '    2. writes the wrapper %s (mode 0755, marked as ours) running flatpak-spawn --host %s\n' "$SGF_WRAPPER" "$GSG_GIT"
    printf '    3. adds -Djava.io.tmpdir=%s to %s (every other byte stays) and %s\n' "$SGF_TMPDIR" "$SGF_VMOPTS" "$dir"
    printf '    4. Git Executable -> %s; record %s; restore-smartgit undoes exactly what it says\n' "$SGF_WRAPPER" "$SGF_RECORD"
}

# ^ security the second, separate yes for step 1; default No at a terminal; --allow-smartgit-sandbox-removal gives this yes without one
smartgit_flatpak_consent() {
    if gitup_consent "$SMARTGIT_SANDBOX_FLAG" "Step 1 removes the SmartGit sandbox: SmartGit can then run any program on this machine as you. Allow it?"; then return 0; fi
    printf '%s: the SmartGit Flatpak was not changed (the sandbox removal was declined)\n' "$GSG_NAME"
    return 1
}

# ^ invariant sets SGF_KEEP = the indexes to apply; the sandbox question is asked once and only when a Flatpak directory is among them; a No drops those only
smartgit_flatpak_keep() {
    local i ask=0 yes=0
    SGF_KEEP=()
    for i in "$@"; do
        if [ "${SG_SET_KIND[$i]}" = flatpak ]; then ask=1; fi
    done
    if [ "$ask" -eq 1 ] && smartgit_flatpak_consent; then yes=1; fi
    for i in "$@"; do
        if [ "${SG_SET_KIND[$i]}" != flatpak ] || [ "$yes" -eq 1 ]; then SGF_KEEP+=("$i"); fi
    done
}

# ^ invariant --reset only when the user override held nothing before (override_clean) and holds only our line now; anything else gets the by-hand step
smartgit_flatpak_override_undo() {
    local line other=0
    if [ "$SGR_override" != yes ]; then return 0; fi
    smartgit_flatpak_show user || return 1
    if [ "$SGF_TALK" -ne 1 ]; then return 0; fi
    while IFS= read -r line; do
        case "$line" in
            '' | '[Session Bus Policy]' | "$SMARTGIT_FLATPAK_TALK=talk") ;;
            *) other=1 ;;
        esac
    done <<<"$SGF_SHOW"
    if [ "$SGR_clean" = yes ] && [ "$other" -eq 0 ]; then
        smartgit_flatpak_call "$SMARTGIT_PROBE_SECONDS" override --user --reset "$SMARTGIT_FLATPAK_ID" || {
            printf '%s: flatpak override --user --reset %s failed; the SmartGit sandbox is still removed\n' "$GSG_NAME" "$SMARTGIT_FLATPAK_ID" >&2
            return 1
        }
        smartgit_flatpak_undone "the --user override"
        printf '%s: removed the --user override this tool added; SmartGit is sandboxed again\n' "$GSG_NAME"
        return 0
    fi
    printf '%s: your --user override of %s held other settings before this tool added its line, or holds more now, so it is not reset; by hand: remove the line %s=talk from ~/.local/share/flatpak/overrides/%s\n' \
        "$GSG_NAME" "$SMARTGIT_FLATPAK_ID" "$SMARTGIT_FLATPAK_TALK" "$SMARTGIT_FLATPAK_ID"
}

# ^ invariant removes the wrapper only when it carries our marker, and after it the empty directories mkdir made for it, up to the recorded wrapper_top
smartgit_flatpak_wrapper_undo() {
    local d past=0
    if [ "$SGR_wrapper" != yes ]; then return 0; fi
    if [ -e "$SGF_WRAPPER" ] || [ -L "$SGF_WRAPPER" ]; then
        if smartgit_flatpak_wrapper_unsafe; then
            printf '%s: %s\n' "$GSG_NAME" "$SGF_WHY"
            return 0
        fi
        rm -f -- "$SGF_WRAPPER" || {
            printf '%s: could not remove the wrapper %s\n' "$GSG_NAME" "$SGF_WRAPPER" >&2
            return 1
        }
        smartgit_flatpak_undone "the wrapper"
    fi
    if [ -z "$SGR_wrapper_top" ]; then return 0; fi
    for ((d = ${#SGF_WRAPPER_TOPS[@]} - 1; d >= 0 && past == 0; d--)); do
        if [ "${SGF_WRAPPER_TOPS[$d]}" = "$SGR_wrapper_top" ]; then past=1; fi
        rmdir -- "${SGF_WRAPPER_TOPS[$d]}" 2>/dev/null || break
    done
}

# ^ invariant removes the last line equal to the one this tool added, every other byte and the mode kept; a file this tool created and holding only it goes
smartgit_flatpak_vm_undo() {
    local f="$SGF_VMOPTS" line="-Djava.io.tmpdir=$SGF_TMPDIR" k at=-1 mode="" tmp=""
    local -a lines=()
    if { [ "$SGR_vm" != yes ] && [ "$SGR_vm" != created ]; } || [ ! -e "$f" ]; then return 0; fi
    SGF_WHY="unreadable or too long"
    if smartgit_flatpak_vm_unsafe || ! mapfile -t -n "$((SMARTGIT_MAX_LINES + 1))" lines <"$f" || [ "${#lines[@]}" -gt "$SMARTGIT_MAX_LINES" ]; then
        printf '%s: %s cannot be edited back (%s); by hand: remove the line %s from it\n' "$GSG_NAME" "$f" "$SGF_WHY" "$line" >&2
        return 1
    fi
    for k in "${!lines[@]}"; do
        if [ "${lines[$k]}" = "$line" ]; then at="$k"; fi
    done
    if [ "$at" -lt 0 ]; then return 0; fi
    if [ "$SGR_vm" = created ] && [ "${#lines[@]}" -eq 1 ]; then
        rm -f -- "$f" || { printf '%s: could not remove %s\n' "$GSG_NAME" "$f" >&2; return 1; }
        smartgit_flatpak_undone "the smartgit.vmoptions line"
        return 0
    fi
    unset 'lines[at]'
    if ! mode="$(stat -c %a -- "$f")" || ! tmp="$(mktemp "${f%/*}/.smartgit.vmoptions.gsg.XXXXXX")" ||
        ! { if [ "${#lines[@]}" -gt 0 ]; then printf '%s\n' "${lines[@]}"; fi; } >"$tmp" || ! chmod "$mode" "$tmp" || ! mv -fT -- "$tmp" "$f"; then
        printf '%s: cannot remove the temp directory line from %s; by hand: remove the line %s\n' "$GSG_NAME" "$f" "$line" >&2
        if [ -n "$tmp" ] && [ -e "$tmp" ]; then smartgit_discard_tmp "$tmp"; fi
        return 1
    fi
    smartgit_flatpak_undone "the smartgit.vmoptions line"
}

# ^ invariant removes the temp files an interrupted wrapper or vmoptions write left (only these names, only regular files, never a link)
smartgit_flatpak_drop_temps() {
    local f rc=0
    for f in "${SGF_WRAPPER%/*}"/.git.gsg.?????? "${SGF_VMOPTS%/*}"/.smartgit.vmoptions.gsg.??????; do
        if [ -f "$f" ] && [ ! -L "$f" ]; then smartgit_discard_tmp "$f" || rc=1; fi
    done
    return "$rc"
}

# ^ order override before wrapper before temp directory before vmoptions line before preferences; each step records itself first, for the undo
smartgit_flatpak_apply() {
    smartgit_flatpak_paths
    smartgit_flatpak_drop_temps || return 1
    smartgit_flatpak_record_read || return 1
    smartgit_flatpak_carry
    smartgit_flatpak_override_step || return 1
    smartgit_flatpak_wrapper_step "$GSG_GIT" || return 1
    smartgit_flatpak_tmpdir_step || return 1
    smartgit_flatpak_vm_step || return 1
    smartgit_apply_one "$1" "$SGF_WRAPPER"
}

# ^ invariant changes nothing; rc 1 = the recorded Flatpak steps cannot all be undone (says why), decided before restore-smartgit restores anything
smartgit_flatpak_undo_check() {
    smartgit_flatpak_paths
    if [ ! -e "$SGF_RECORD" ]; then return 0; fi
    smartgit_flatpak_record_read || return 1
    if [ "$SGR_override" = yes ]; then
        if ! smartgit_tool flatpak; then
            printf '%s: no flatpak command was found, so the --user override cannot be undone; nothing was restored\n' "$GSG_NAME" >&2
            return 1
        fi
        SGF_FLATPAK="$REPLY"
        if ! smartgit_flatpak_call "$SMARTGIT_PROBE_SECONDS" override --user --show "$SMARTGIT_FLATPAK_ID" >/dev/null; then
            printf '%s: the --user override of %s cannot be read; nothing was restored\n' "$GSG_NAME" "$SMARTGIT_FLATPAK_ID" >&2
            return 1
        fi
    fi
    case "$SGR_vm" in
        yes | created)
            if smartgit_flatpak_vm_unsafe; then
                printf '%s: %s; nothing was restored\n' "$GSG_NAME" "$SGF_WHY" >&2
                return 1
            fi
            ;;
    esac
    return 0
}

# ^ invariant appends NAME ($1) to SGF_UNDONE (", " between entries); called only right after an undo really removed something; always rc 0
smartgit_flatpak_undone() {
    SGF_UNDONE="${SGF_UNDONE:+$SGF_UNDONE, }$1"
    return 0
}

# ^ invariant undoes what the record says, each part tried even after a failure; the record goes only when every part worked
# ^ invariant SGF_UNDONE names only what an undo really removed, never what the record merely marks as done
smartgit_flatpak_undo() {
    local rc=0 can_override=1 vm_failed=0
    SGF_UNDONE=""
    smartgit_flatpak_paths
    if [ ! -e "$SGF_RECORD" ]; then return 0; fi
    smartgit_flatpak_record_read || return 1
    smartgit_flatpak_drop_temps || rc=1
    if [ "$SGR_override" = yes ]; then
        if smartgit_tool flatpak; then
            SGF_FLATPAK="$REPLY"
        else
            printf '%s: no flatpak command was found, so the --user override cannot be undone; by hand: flatpak override --user --reset %s\n' "$GSG_NAME" "$SMARTGIT_FLATPAK_ID" >&2
            rc=1 can_override=0
        fi
    fi
    if [ "$can_override" -eq 1 ]; then smartgit_flatpak_override_undo || rc=1; fi
    smartgit_flatpak_wrapper_undo || rc=1
    smartgit_flatpak_vm_undo || { rc=1; vm_failed=1; }
    # ^ order the directory goes only after its smartgit.vmoptions line; a kept line would name a missing java.io.tmpdir
    if [ "$SGR_tmpdir" = yes ] && [ -d "$SGF_TMPDIR" ] && [ "$vm_failed" -eq 1 ]; then
        printf '%s: %s was kept: the smartgit.vmoptions line still points at it\n' "$GSG_NAME" "$SGF_TMPDIR" >&2
    elif [ "$SGR_tmpdir" = yes ] && [ -d "$SGF_TMPDIR" ]; then
        if [ -n "$(ls -A -- "$SGF_TMPDIR")" ]; then
            printf '%s: %s is not empty and was kept\n' "$GSG_NAME" "$SGF_TMPDIR"
        elif rmdir -- "$SGF_TMPDIR"; then
            smartgit_flatpak_undone "the temp directory"
        else
            printf '%s: could not remove %s\n' "$GSG_NAME" "$SGF_TMPDIR" >&2
            rc=1
        fi
    fi
    if [ "$rc" -eq 0 ]; then
        rm -f -- "$SGF_RECORD" || {
            printf '%s: could not remove %s\n' "$GSG_NAME" "$SGF_RECORD" >&2
            return 1
        }
    fi
    return "$rc"
}

SMARTGIT_VERIFY_SECONDS=300

# ^ external flatpak run needs the session of the installer (its DBUS and XDG variables); it runs in the installer's environment, not under env -i (fact 7)
# ^ why --cwd of the temp directory, not the caller's cwd; it is under HOME and has the same path inside the sandbox and on the host
smartgit_flatpak_git() {
    smartgit_flatpak_call "$SMARTGIT_VERIFY_SECONDS" run --cwd="$SGF_TMPDIR" --command="$SGF_WRAPPER" "$SMARTGIT_FLATPAK_ID" "$@"
}

# ^ invariant the version and Git LFS checks of the verify, run through the wrapper inside the sandbox; each failure says what failed
smartgit_flatpak_verify_pre() {
    local out ver
    if ! out="$(smartgit_flatpak_git --version 2>/dev/null)" || ! ver="$(smartgit_parse_git_version "$out")"; then
        printf '%s: git --version through the wrapper %s inside the SmartGit sandbox failed\n' "$GSG_NAME" "$SGF_WRAPPER" >&2
        return 1
    fi
    if ! gitup_version_at_least "$ver" "$(smartgit_min_git)"; then
        printf '%s: the wrapper %s runs git %s inside the SmartGit sandbox, older than %s\n' "$GSG_NAME" "$SGF_WRAPPER" "$ver" "$(smartgit_min_git)" >&2
        return 1
    fi
    if ! smartgit_flatpak_git lfs version >/dev/null 2>&1; then
        printf '%s: git lfs version fails through the wrapper %s inside the SmartGit sandbox\n' "$GSG_NAME" "$SGF_WRAPPER" >&2
        return 1
    fi
}
