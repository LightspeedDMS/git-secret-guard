# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled system git takeover of the rpm module (story 28); the step order is a safety rule (dnf entry, backup, atomic swaps, verification, rollback)
# ^ external /usr/bin holds six git-core RPM files (git, git-receive-pack, git-shell, git-upload-archive, git-upload-pack, scalar); Rocky 9.7, Fedora 44
# ^ external excludepkgs must name every installed package of the git-core source RPM (git git-core git-core-doc perl-Git), git-core alone breaks dnf update

GITUP_TK_MARKER='# git-secret-guard: takeover; original: '
GITUP_TK_NAMES=()
GITUP_TK_REC_NAMES=()
GITUP_TK_REC_SHAS=()
GITUP_TK_HASHES=()
GITUP_TK_EXCLUDES="" GITUP_TK_NEVRA="" GITUP_TK_WORK="" GITUP_TK_REC_EXCLUDES=""
GITUP_TK_ACTIVE=0 GITUP_RPM_BIN=""
GITUP_TK_TARGET=""
GITUP_TK_LIMIT=50
GITUP_TK_RECORD_MAGIC="git-secret-guard system git takeover 1"

# shellcheck disable=SC2016
GITUP_TK_AWK_ADD='
BEGIN { sect = ""; done = 0; cont = 0; bad = 0 }
cont == 1 { cont = 0; if ($0 ~ /^[ \t]+[^ \t]/) { bad = 4; exit } }
/^[ \t]*\[/ {
    if (sect == "main" && !done) { print marker "none"; print "excludepkgs=" names; done = 1 }
    sect = ($0 ~ /^[ \t]*\[main\][ \t]*$/) ? "main" : "other"
    print
    next
}
sect == "main" && !done && $0 ~ /^[ \t]*[Ee][Xx][Cc][Ll][Uu][Dd][Ee][Pp][Kk][Gg][Ss][ \t]*=/ {
    orig = $0
    print marker orig
    sub(/[ \t]+$/, "", orig)
    print orig " " names
    done = 1
    cont = 1
    next
}
{ print }
END {
    if (bad) exit bad
    if (sect == "main" && !done) { print marker "none"; print "excludepkgs=" names; done = 1 }
    if (!done) exit 3
}'

# shellcheck disable=SC2016
GITUP_TK_AWK_DEL='
BEGIN { nn = split(names, nm, " "); for (i = 1; i <= nn; i++) isname[nm[i]] = 1 }
index($0, marker) == 1 {
    orig = substr($0, length(marker) + 1)
    if ((getline nxt) <= 0) next
    while (index(nxt, marker) == 1) { if ((getline nxt) <= 0) next }
    if (nxt !~ /^[ \t]*[Ee][Xx][Cc][Ll][Uu][Dd][Ee][Pp][Kk][Gg][Ss][ \t]*=/ || nn == 0) { print nxt; next }
    o = orig
    sub(/[ \t]+$/, "", o)
    if (o != "none" && nxt == o " " names) { print orig; next }
    eq = index(nxt, "=")
    no = 0
    if (o != "none") { ov = o; sub(/^[^=]*=[ \t]*/, "", ov); no = split(ov, ot, /[ \t,]+/); for (i = 1; i <= no; i++) inorig[ot[i]] = 1 }
    nc = split(substr(nxt, eq + 1), cur, /[ \t,]+/)
    kept = ""; cnt = 0
    for (i = 1; i <= nc; i++) {
        if ((cur[i] in isname) && !(cur[i] in inorig)) continue
        kept = kept (cnt++ ? " " : "") cur[i]
    }
    if (cnt == 0 && o == "none") next
    print substr(nxt, 1, eq) kept
    next
}
{ print }'

# shellcheck disable=SC2016
GITUP_TK_AWK_HAS='
index($0, marker) == 1 { want = 1; next }
want == 1 {
    want = 0
    if ($0 ~ /^[ \t]*[Ee][Xx][Cc][Ll][Uu][Dd][Ee][Pp][Kk][Gg][Ss][ \t]*=/) {
        n = split(substr($0, index($0, "=") + 1), t, /[ \t,]+/)
        for (i = 1; i <= n; i++) if (t[i] == "git-core") found = 1
    }
}
END { exit found ? 0 : 1 }'

# ^ invariant rc 0 only when a marker line is followed by an excludepkgs line listing git-core; a lone marker is no protection against dnf overwriting git
gitup_tk_entry_present() {
    [ -f "$GITUP_DNFCONF" ] && awk -v marker="$GITUP_TK_MARKER" "$GITUP_TK_AWK_HAS" "$GITUP_DNFCONF"
}

gitup_tk_dirs() {
    GITUP_TK_DIR="$GITUP_VARLIB/system-git"
    GITUP_TK_RECORD="$GITUP_TK_DIR/record"
    GITUP_TK_ORIG="$GITUP_TK_DIR/orig"
}

gitup_tk_fail() {
    GITUP_REASON="$1"
    return 1
}

# ^ invariant sets GITUP_TK_NAMES = the files of git-core directly in /usr/bin, from rpm -ql, each a plain file name; rc 1 sets GITUP_REASON
gitup_tk_names() {
    local listing line name
    GITUP_TK_NAMES=()
    install_find_bin rpm || gitup_tk_fail "rpm was not found on PATH, so the package that owns /usr/bin/git cannot be identified" || return 1
    GITUP_RPM_BIN="$REPLY"
    listing="$("$GITUP_RPM_BIN" -ql git-core)" || gitup_tk_fail "rpm -ql git-core failed, git-core is not an installed package" || return 1
    while IFS= read -r line; do
        if [[ $line != /usr/bin/* ]]; then continue; fi
        name="${line#/usr/bin/}"
        if [[ ! $name =~ ^[A-Za-z0-9._+-]+$ ]]; then gitup_tk_fail "git-core lists the unusable file name [${name//[^[:print:]]/?}] in /usr/bin" || return 1; fi
        GITUP_TK_NAMES+=("$name")
    done <<<"$listing"
    if [ "${#GITUP_TK_NAMES[@]}" -eq 0 ] || [ "${#GITUP_TK_NAMES[@]}" -gt "$GITUP_TK_LIMIT" ]; then
        gitup_tk_fail "git-core lists ${#GITUP_TK_NAMES[@]} files in /usr/bin, which is not a plausible set" || return 1
    fi
}

# ^ invariant sets GITUP_TK_EXCLUDES = every installed package built from the source RPM of git-core, sorted, space separated; git-core must be among them
gitup_tk_excludes() {
    local srpm all name sr
    local -a names=()
    srpm="$("$GITUP_RPM_BIN" -q --qf '%{SOURCERPM}\n' git-core)" || gitup_tk_fail "rpm could not name the source package of git-core" || return 1
    all="$("$GITUP_RPM_BIN" -qa --qf '%{NAME} %{SOURCERPM}\n')" || gitup_tk_fail "rpm -qa failed" || return 1
    while read -r name sr; do
        if [ "$sr" = "$srpm" ] && [[ $name =~ ^[A-Za-z0-9._+-]+$ ]]; then names+=("$name"); fi
    done <<<"$all"
    GITUP_TK_EXCLUDES="$(printf '%s\n' "${names[@]}" | LC_ALL=C sort -u | tr '\n' ' ')" || return 1
    GITUP_TK_EXCLUDES="${GITUP_TK_EXCLUDES% }"
    if [[ " $GITUP_TK_EXCLUDES " != *" git-core "* ]]; then gitup_tk_fail "git-core is not among the installed packages of its own source RPM" || return 1; fi
    GITUP_TK_NEVRA="$("$GITUP_RPM_BIN" -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' git-core)" || gitup_tk_fail "rpm could not name the installed git-core" || return 1
}

# ^ invariant reads the record of an earlier takeover into GITUP_TK_REC_NAMES and GITUP_TK_REC_SHAS; rc 1 = absent, foreign, malformed or too long
gitup_tk_read_record() {
    local line kind a b n=0
    GITUP_TK_REC_NAMES=() GITUP_TK_REC_SHAS=() GITUP_TK_REC_EXCLUDES=""
    if [ ! -f "$GITUP_TK_RECORD" ]; then return 1; fi
    while IFS= read -r line; do
        n=$((n + 1))
        if [ "$n" -gt $((GITUP_TK_LIMIT * 2)) ]; then return 1; fi
        if [ "$n" -eq 1 ] && [ "$line" != "$GITUP_TK_RECORD_MAGIC" ]; then return 1; fi
        if [[ $line == "excludes "* ]]; then GITUP_TK_REC_EXCLUDES="${line#excludes }"; fi
        read -r kind a b <<<"$line"
        if [ "$kind" != file ]; then continue; fi
        if [[ ! $a =~ ^[A-Za-z0-9._+-]+$ ]] || [[ ! $b =~ ^[0-9a-f]{64}$ ]]; then return 1; fi
        GITUP_TK_REC_NAMES+=("$a")
        GITUP_TK_REC_SHAS+=("$b")
    done <"$GITUP_TK_RECORD"
    [ "${#GITUP_TK_REC_NAMES[@]}" -gt 0 ]
}

# ^ invariant a link of ours is a symlink into the prefix; the RPM's own relative links (git-upload-pack -> git) are not, and neither is any regular file
gitup_tk_is_ours() { [ -L "$1" ] && [[ $(readlink -- "$1") == "$GITUP_PREFIX"/* ]]; }

# ^ invariant prints the identity of a path, never following a link; SHA-256 of a regular file, SHA-256 of 'link:<target>' for a symlink; rc 1 = neither
gitup_tk_id() {
    local t sum
    if [ -L "$1" ]; then
        t="$(readlink -- "$1")" || return 1
        sum="$(printf 'link:%s' "$t" | sha256sum)" || return 1
    elif [ -f "$1" ]; then
        sum="$(sha256sum -- "$1")" || return 1
    else
        return 1
    fi
    printf '%s\n' "${sum%% *}"
}

# ^ invariant sets GITUP_TK_HOWTO = the commands undoing the takeover without this CLI, from the record read just before
gitup_tk_howto() {
    local n
    GITUP_TK_HOWTO=""
    for n in "${GITUP_TK_REC_NAMES[@]}"; do
        GITUP_TK_HOWTO+="  sudo cp -a --remove-destination -- $GITUP_TK_ORIG/$n $GITUP_USRBIN/$n"$'\n'
    done
    GITUP_TK_HOWTO+="  then edit $GITUP_DNFCONF: find the comment line starting with [$GITUP_TK_MARKER]; if it ends in 'original: none' delete it and the excludepkgs line below it, otherwise delete it and put the original line it names back in place of the excludepkgs line below it"$'\n'
    GITUP_TK_HOWTO+="  last, remove the backup so status stops warning about the takeover:"$'\n'"  sudo rm -rf -- $GITUP_TK_DIR"
}

# ^ invariant gitup_tk_howto from the files in orig/ when the record is missing or unreadable; the originals prove the content, the record only names them
gitup_tk_howto_orig() {
    local f n
    GITUP_TK_REC_NAMES=()
    if [ -d "$GITUP_TK_ORIG" ]; then
        for f in "$GITUP_TK_ORIG"/*; do
            if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
            n="${f##*/}"
            if [[ ! $n =~ ^[A-Za-z0-9._+-]+$ ]] || [ "${#GITUP_TK_REC_NAMES[@]}" -ge "$GITUP_TK_LIMIT" ]; then continue; fi
            GITUP_TK_REC_NAMES+=("$n")
        done
    fi
    gitup_tk_howto
    if [ "${#GITUP_TK_REC_NAMES[@]}" -eq 0 ]; then
        GITUP_TK_HOWTO="  the saved originals are gone from $GITUP_TK_ORIG; put the RPM files back with: sudo dnf reinstall --disableexcludes=main git-core"$'\n'"$GITUP_TK_HOWTO"
    fi
}

# ^ invariant sets GITUP_TK_STATE = none (no record), active (links and dnf entry in place), undone (RPM files or config came back), broken (unreadable)
# ^ invariant GITUP_TK_TEXT = one line for status and doctor
gitup_tk_status() {
    local i links=0 marker=0 git_ours=0 total
    gitup_tk_dirs
    GITUP_TK_STATE=none GITUP_TK_TEXT="none (the RPM files are in $GITUP_USRBIN)" GITUP_TK_TARGET="$GITUP_USRBIN/git" GITUP_TK_HOWTO=""
    gitup_tk_howto_orig
    if grep -qF -- "$GITUP_TK_MARKER" "$GITUP_DNFCONF" 2>/dev/null; then marker=1; fi
    if gitup_tk_is_ours "$GITUP_USRBIN/git"; then git_ours=1; fi
    if [ ! -e "$GITUP_TK_RECORD" ]; then
        if [ "$git_ours" -eq 1 ]; then
            GITUP_TK_STATE=broken GITUP_TK_TEXT="$GITUP_USRBIN/git is a link of ours but there is no record $GITUP_TK_RECORD; the originals, if any, are in $GITUP_TK_ORIG"
        elif [ "$marker" -eq 1 ]; then
            GITUP_TK_STATE=undone GITUP_TK_TEXT="the takeover is partly undone (the excludepkgs entry of a takeover is in $GITUP_DNFCONF but there is no record in $GITUP_TK_DIR, so nothing is taken over and dnf skips git updates); run: $GSG_NAME restore-system-git to remove the dnf entry"
        fi
        return 0
    fi
    if ! gitup_tk_read_record; then
        GITUP_TK_STATE=broken GITUP_TK_TEXT="the record $GITUP_TK_RECORD cannot be read; the originals, if any, are in $GITUP_TK_ORIG"
        return 0
    fi
    gitup_tk_howto
    total="${#GITUP_TK_REC_NAMES[@]}"
    for i in "${!GITUP_TK_REC_NAMES[@]}"; do
        if gitup_tk_is_ours "$GITUP_USRBIN/${GITUP_TK_REC_NAMES[$i]}"; then links=$((links + 1)); fi
    done
    # ^ invariant from here marker = 1 only when the excludepkgs line below the marker lists git-core; a lone marker comment protects nothing
    marker=0
    if gitup_tk_entry_present; then marker=1; fi
    if [ "$links" -eq "$total" ] && [ "$marker" -eq 1 ]; then
        GITUP_TK_STATE=active
        GITUP_TK_TEXT="active ($GITUP_USRBIN/git and its $((total - 1)) siblings point at $GITUP_PREFIX/bin; originals in $GITUP_TK_ORIG)"
        return 0
    fi
    GITUP_TK_STATE=undone
    if [ "$git_ours" -eq 1 ]; then
        GITUP_TK_TEXT="the takeover is half done ($links of $total links are in place, the dnf entry is $([ "$marker" -eq 1 ] && echo present || echo gone)); $GITUP_USRBIN/git still reaches the new git; run: $GSG_NAME install --take-over-system-git to finish it, or $GSG_NAME restore-system-git to undo it"
    else
        GITUP_TK_TEXT="the takeover is partly undone ($links of $total links are in place, the dnf entry is $([ "$marker" -eq 1 ] && echo present || echo gone)); commits made through $GITUP_USRBIN/git are no longer scanned; run: $GSG_NAME restore-system-git to finish undoing it, or $GSG_NAME install --take-over-system-git to take over again"
    fi
}

# ^ invariant rc 0 = the file, or the target of a symlink below the prefix, has the trusted owner and no group or other write bit; rc 1 sets GITUP_REASON
# ^ why the target of a link is judged, not the link; a symlink shows mode 777, and git installs its siblings as symlinks (INSTALL_SYMLINKS=1)
gitup_tk_check_owner() {
    local path="$1" uid mode stat_out real prefix_real
    if [ -L "$path" ]; then
        real="$(realpath -- "$path")" || gitup_tk_fail "cannot resolve the link $path" || return 1
        prefix_real="$(realpath -- "$GITUP_PREFIX")" || gitup_tk_fail "cannot resolve $GITUP_PREFIX" || return 1
        if [[ $real != "$prefix_real"/* ]]; then gitup_tk_fail "$path is a link out of $GITUP_PREFIX" || return 1; fi
        path="$real"
    fi
    stat_out="$(stat -c '%u %a' -- "$path")" || gitup_tk_fail "cannot read the owner of $path" || return 1
    read -r uid mode <<<"$stat_out"
    if [ "$uid" != "$(gitup_trusted_uid)" ]; then gitup_tk_fail "$path is owned by user $uid, not by the trusted user" || return 1; fi
    if [ $((8#$mode & 8#022)) -ne 0 ]; then gitup_tk_fail "$path is writable by group or others (mode $mode)" || return 1; fi
}

GITUP_TK_FILES_LIMIT=5000

# ^ invariant rc 0 when every non-directory below libexec/git-core has the trusted owner and no group or other write bit, and no symlink leaves the prefix
gitup_tk_check_libexec() {
    local dir="$GITUP_PREFIX/libexec/git-core" listing entry n=0
    if [ ! -d "$dir" ]; then return 0; fi
    gitup_tk_check_owner "$dir" || return 1
    listing="$(find "$dir" ! -type d -printf '%p\n')" || gitup_tk_fail "cannot list the files below $dir" || return 1
    while IFS= read -r entry; do
        if [ -z "$entry" ]; then continue; fi
        n=$((n + 1))
        if [ "$n" -gt "$GITUP_TK_FILES_LIMIT" ]; then gitup_tk_fail "$dir holds more than $GITUP_TK_FILES_LIMIT files" || return 1; fi
        gitup_tk_check_owner "$entry" || return 1
    done <<<"$listing"
}

# ^ invariant rc 0 when ldd of each program in the finished MANIFEST below bin and libexec (each inode once) shows no Homebrew, missing or outside library
# ^ why only MANIFEST paths, not every file below the prefix bin; /usr/local/bin holds other programs and a library missing for one must not block the takeover
gitup_tk_check_libs() {
    local ldd inode path out off seen=" "
    install_find_bin ldd || gitup_tk_fail "ldd was not found, so the libraries of $GITUP_PREFIX/bin/git cannot be checked" || return 1
    ldd="$REPLY"
    for path in "${!GITUP_DONE[@]}"; do
        case "$path" in "$GITUP_PREFIX/bin/"* | "$GITUP_PREFIX/libexec/"*) ;; *) continue ;; esac
        if [ -L "$path" ] || [ ! -f "$path" ] || [ ! -x "$path" ]; then continue; fi
        inode="$(stat -c '%i' -- "$path")" || gitup_tk_fail "cannot read ${path//[^[:print:]]/?}" || return 1
        if [[ $seen == *" $inode "* ]]; then continue; fi
        seen+="$inode "
        out="$("$ldd" "$path" 2>&1)" || true
        if [[ $out == *"not found"* ]]; then gitup_tk_fail "${path##*/} has a missing library" || return 1; fi
        if [[ $out == *[Hh]omebrew* ]] || [[ $out == *linuxbrew* ]]; then gitup_tk_fail "${path##*/} loads Homebrew code" || return 1; fi
        if off="$(gitup_source_lib_outside "$out")"; then gitup_tk_fail "${path##*/} loads ${off//[^[:print:]]/?}, which is outside the system library directories" || return 1; fi
    done
}

# ^ security the target is a build of ours, owned by root, with no Homebrew or user-owned code behind it; a system caller never runs files a user can rewrite
gitup_tk_check_target() {
    local new="$GITUP_PREFIX/bin/git" n
    if [ ! -f "$new" ] || [ -L "$new" ]; then gitup_tk_fail "$new is not a regular file" || return 1; fi
    install_git_is_new_enough "$new" || gitup_tk_fail "$new is older than git 2.54" || return 1
    gitup_source_read_manifests || gitup_tk_fail "the MANIFESTs below $GITUP_PREFIX/share/doc cannot be read" || return 1
    if [ "${#GITUP_PARTIALS[@]}" -gt 0 ]; then gitup_tk_fail "an earlier copy of git into $GITUP_PREFIX was interrupted (${GITUP_PARTIALS[0]}), so the tree is unfinished; run install --upgrade-git first" || return 1; fi
    if [ -z "${GITUP_DONE[$new]:-}" ]; then gitup_tk_fail "$new is not listed in any MANIFEST of ours (only a finished one counts), so git-secret-guard did not finish building it" || return 1; fi
    for n in "${GITUP_TK_NAMES[@]}"; do
        if [ ! -e "$GITUP_PREFIX/bin/$n" ]; then gitup_tk_fail "the sibling $n is missing from $GITUP_PREFIX/bin" || return 1; fi
        gitup_tk_check_owner "$GITUP_PREFIX/bin/$n" || return 1
    done
    gitup_tk_check_libexec || return 1
    gitup_tk_check_libs
}

# ^ invariant rc 0 when the dnf config has a [main] section and its excludepkgs, if any, fits on one line; rc 1 sets GITUP_REASON
gitup_tk_check_conf() {
    local rc=0
    if [ ! -f "$GITUP_DNFCONF" ]; then gitup_tk_fail "$GITUP_DNFCONF does not exist" || return 1; fi
    awk -v marker="$GITUP_TK_MARKER" -v names="$GITUP_TK_EXCLUDES" "$GITUP_TK_AWK_ADD" "$GITUP_DNFCONF" >/dev/null || rc=$?
    case "$rc" in
        0) ;;
        3) gitup_tk_fail "$GITUP_DNFCONF has no [main] section to put the excludepkgs entry in" || return 1 ;;
        4) gitup_tk_fail "the excludepkgs line in $GITUP_DNFCONF continues on a second line, which this tool will not merge; add the names yourself" || return 1 ;;
        *) gitup_tk_fail "cannot read $GITUP_DNFCONF" || return 1 ;;
    esac
}

# ^ invariant the temporary file the new dnf.conf is written to before the rename; the plan and gitup_tk_conf_write name the same path
gitup_tk_conf_tmp() { printf '%s/.%s.gsg-new' "${GITUP_DNFCONF%/*}" "${GITUP_DNFCONF##*/}"; }

# ^ invariant every gitup_plan_priv line below is a command the apply steps run, with the same names and paths; <file> stands for each of the files listed above
gitup_tk_print_plan() {
    local list="" n mode
    for n in "${GITUP_TK_NAMES[@]}"; do list+="${list:+, }$n"; done
    mode="$(stat -c %a -- "$GITUP_DNFCONF" 2>/dev/null)" || mode=644
    printf '  system git takeover plan:\n'
    printf '  %s (%s) and its %s siblings will point at %s: %s\n' "$1" "$GITUP_TK_NEVRA" "$((${#GITUP_TK_NAMES[@]} - 1))" "$GITUP_PREFIX/bin" "$list"
    printf '  <work dir> is a private temporary directory of your user; the new dnf.conf in it adds excludepkgs=%s behind a marker comment\n' "$GITUP_TK_EXCLUDES"
    gitup_plan_priv "install -m $mode -- <work dir>/dnf.conf.new $(gitup_tk_conf_tmp)"
    gitup_plan_priv "mv -T -- $(gitup_tk_conf_tmp) $GITUP_DNFCONF"
    gitup_plan_priv "restorecon -- $GITUP_DNFCONF"
    gitup_plan_priv "rm -rf -- $GITUP_TK_ORIG.new $GITUP_TK_RECORD.new $GITUP_TK_ORIG.old"
    gitup_plan_priv "mkdir -p -- $GITUP_TK_ORIG.new"
    gitup_plan_priv "cp -a -- $GITUP_USRBIN/<file> $GITUP_TK_ORIG.new/<file>"
    gitup_plan_priv "install -m 644 -- <work dir>/record $GITUP_TK_RECORD.new"
    gitup_plan_priv "mv -T -- $GITUP_TK_ORIG $GITUP_TK_ORIG.old  [only when an earlier backup exists]"
    gitup_plan_priv "mv -T -- $GITUP_TK_ORIG.new $GITUP_TK_ORIG"
    gitup_plan_priv "mv -T -- $GITUP_TK_RECORD.new $GITUP_TK_RECORD"
    gitup_plan_priv "rm -rf -- $GITUP_TK_ORIG.old"
    gitup_plan_priv "ln -sfT -- $GITUP_PREFIX/bin/<file> $GITUP_USRBIN/.<file>.gsg-new"
    gitup_plan_priv "mv -T -- $GITUP_USRBIN/.<file>.gsg-new $GITUP_USRBIN/<file>"
    gitup_plan_priv "restorecon -- $GITUP_USRBIN/<file>"
    gitup_plan_priv "install -m $mode -- <work dir>/dnf.conf.old $(gitup_tk_conf_tmp)  [only when an old marker is removed, or a failed or interrupted takeover is rolled back]"
    gitup_plan_priv "rm -f -- $GITUP_USRBIN/.<file>.gsg-new $GITUP_USRBIN/.<file>.gsg-restore $(gitup_tk_conf_tmp)  [only when a move failed or a rollback finds leftover temporary files]"
    gitup_plan_priv "cp -a --remove-destination -- $GITUP_TK_ORIG/<file> $GITUP_USRBIN/.<file>.gsg-restore  [only when a failed or interrupted takeover is rolled back]"
    gitup_plan_priv "mv -T -- $GITUP_USRBIN/.<file>.gsg-restore $GITUP_USRBIN/<file>  [only when a failed or interrupted takeover is rolled back]"
    gitup_plan_priv "rm -rf -- $GITUP_TK_DIR  [only when a failed or interrupted takeover is rolled back]"
    gitup_plan_priv "rmdir -- $GITUP_VARLIB  [only when a failed or interrupted takeover is rolled back and the directory is empty]"
    printf '  then %s --version must be >= 2.54, a commit through it must reach a hook in a scratch repo and git-upload-pack must run; any failure puts every original back\n' "$1"
    printf '  what you give up:\n'
    printf '   - dnf stops updating git, git-core, and the other packages of its source RPM; git updates then need a pin bump in tools.lock and install --upgrade-git\n'
    printf '   - rpm -V will report these %s files as changed, and the RPM stays installed (other packages depend on it)\n' "${#GITUP_TK_NAMES[@]}"
    printf '   - a broken build in %s breaks everything that uses git, gh and glab included\n' "$GITUP_PREFIX"
    printf '   - to undo it run %s restore-system-git (it needs no network)\n' "$GSG_NAME"
}

# ^ invariant rc 0 with the plan printed = the takeover can run; rc 2 = nothing to take over; rc 1 = refused; GITUP_REASON says why on 1 and 2
gitup_tk_plan() {
    local target="$GITUP_USRBIN/git" owner
    gitup_tk_dirs
    GITUP_REASON=""
    gitup_tk_status
    if [ "$GITUP_TK_STATE" = active ]; then
        GITUP_REASON="the takeover is already $GITUP_TK_TEXT"
        return 2
    fi
    if [ "$GITUP_TK_STATE" = broken ] && gitup_tk_is_ours "$target"; then gitup_tk_fail "$GITUP_TK_TEXT"$'\n'"undo it by hand:"$'\n'"$GITUP_TK_HOWTO" || return 1; fi
    install_find_bin rpm || gitup_tk_fail "rpm was not found on PATH" || return 1
    owner="$("$REPLY" -qf --qf '%{NAME}\n' -- "$target")" || gitup_tk_fail "$target is not owned by any package, so it is not the RPM file to take over" || return 1
    if [ "$owner" != git-core ]; then gitup_tk_fail "$target belongs to the package $owner, not git-core" || return 1; fi
    gitup_tk_names || return 1
    gitup_tk_check_target || return 1
    gitup_tk_excludes || return 1
    gitup_tk_check_conf || return 1
    if [ "$GITUP_TK_STATE" = undone ]; then printf '  an earlier takeover is unfinished (%s); this run finishes it and keeps the originals saved then\n' "$GITUP_TK_TEXT"; fi
    gitup_tk_print_plan "$target"
}

# ^ invariant fills GITUP_TK_HASHES = the identity of each current /usr/bin file, in GITUP_TK_NAMES order; a symlink is identified by its target, never followed
gitup_tk_hash_originals() {
    local n id
    GITUP_TK_HASHES=()
    for n in "${GITUP_TK_NAMES[@]}"; do
        id="$(gitup_tk_id "$GITUP_USRBIN/$n")" || gitup_tk_fail "cannot read $GITUP_USRBIN/$n" || return 1
        GITUP_TK_HASHES+=("$id")
    done
}

GITUP_TK_NO_RESTORECON=0
gitup_tk_relabel() {
    if ! gitup_system_bin restorecon; then
        if [ "$GITUP_TK_NO_RESTORECON" -eq 0 ]; then
            printf '%s: restorecon was not found in %s; if SELinux is enforcing run restorecon -v on the files this takeover changed, for example %s\n' "$GSG_NAME" "$GITUP_SYSTEM_PATH" "$1" >&2
            GITUP_TK_NO_RESTORECON=1
        fi
        return 0
    fi
    gitup_elevate "$REPLY" -- "$1" || printf '%s: restorecon failed for %s; if SELinux is enforcing run: restorecon -v %s\n' "$GSG_NAME" "$1" "$1" >&2
}

# ^ order the new text is written beside dnf.conf and renamed over it after the write; dnf never reads a half-written file and the mode is kept
gitup_tk_conf_write() {
    local tmp mode
    tmp="$(gitup_tk_conf_tmp)"
    mode="$(stat -c %a -- "$GITUP_DNFCONF")" || return 1
    gitup_elevate install -m "$mode" -- "$1" "$tmp" || return 1
    gitup_elevate mv -T -- "$tmp" "$GITUP_DNFCONF" || {
        gitup_elevate rm -f -- "$tmp" || printf '%s: left the temporary file %s\n' "$GSG_NAME" "$tmp" >&2
        return 1
    }
    gitup_tk_relabel "$GITUP_DNFCONF"
}

# ^ invariant a marker already in dnf.conf means the entry is there; nothing is written and a rerun after an interruption never doubles it
gitup_tk_conf_add() {
    if gitup_tk_entry_present; then return 0; fi
    if grep -qF -- "$GITUP_TK_MARKER" "$GITUP_DNFCONF"; then
        awk -v marker="$GITUP_TK_MARKER" -v names="" "$GITUP_TK_AWK_DEL" "$GITUP_DNFCONF" >"$GITUP_TK_WORK/dnf.conf.old" || gitup_tk_fail "cannot prepare $GITUP_DNFCONF without the dangling marker" || return 1
        gitup_tk_conf_write "$GITUP_TK_WORK/dnf.conf.old" || gitup_tk_fail "cannot write $GITUP_DNFCONF" || return 1
    fi
    awk -v marker="$GITUP_TK_MARKER" -v names="$GITUP_TK_EXCLUDES" "$GITUP_TK_AWK_ADD" "$GITUP_DNFCONF" >"$GITUP_TK_WORK/dnf.conf.new" || gitup_tk_fail "cannot prepare the new $GITUP_DNFCONF" || return 1
    gitup_tk_conf_write "$GITUP_TK_WORK/dnf.conf.new" || gitup_tk_fail "cannot write $GITUP_DNFCONF" || return 1
}

# ^ invariant works from the marker alone; $1 = the package names of the entry ("" = unknown, only the marker goes and the line below stays)
gitup_tk_conf_remove() {
    if ! grep -qF -- "$GITUP_TK_MARKER" "$GITUP_DNFCONF" 2>/dev/null; then return 0; fi
    if [ -z "$1" ]; then printf '%s: the package names of the dnf entry are unknown (no record, rpm gave none); the excludepkgs line below the marker in %s stays, remove it by hand\n' "$GSG_NAME" "$GITUP_DNFCONF" >&2; fi
    awk -v marker="$GITUP_TK_MARKER" -v names="$1" "$GITUP_TK_AWK_DEL" "$GITUP_DNFCONF" >"$GITUP_TK_WORK/dnf.conf.old" || return 1
    gitup_tk_conf_write "$GITUP_TK_WORK/dnf.conf.old"
}

# ^ invariant sets GITUP_TK_OURS (files already links of ours) and GITUP_TK_REUSE (1 = record, saved originals and other files all match, originals stay)
# ^ invariant rc 1 with GITUP_REASON when links of ours exist and the saved originals cannot be trusted; nothing is changed
# ^ invariant the saved originals are never replaced as long as a link of ours exists
gitup_tk_classify() {
    local i n same=1 saved_ok=1 have=0
    GITUP_TK_OURS=0 GITUP_TK_REUSE=0
    for n in "${GITUP_TK_NAMES[@]}"; do
        if gitup_tk_is_ours "$GITUP_USRBIN/$n"; then GITUP_TK_OURS=$((GITUP_TK_OURS + 1)); fi
    done
    if gitup_tk_read_record && [ "${GITUP_TK_REC_NAMES[*]}" = "${GITUP_TK_NAMES[*]}" ]; then have=1; fi
    if [ "$have" -eq 1 ]; then
        for i in "${!GITUP_TK_NAMES[@]}"; do
            n="${GITUP_TK_NAMES[$i]}"
            if [ "$(gitup_tk_id "$GITUP_TK_ORIG/$n" 2>/dev/null)" != "${GITUP_TK_REC_SHAS[$i]}" ]; then saved_ok=0; fi
            if ! gitup_tk_is_ours "$GITUP_USRBIN/$n" && [ "${GITUP_TK_HASHES[$i]}" != "${GITUP_TK_REC_SHAS[$i]}" ]; then same=0; fi
        done
    fi
    if [ "$have" -eq 1 ] && [ "$saved_ok" -eq 1 ] && [ "$same" -eq 1 ]; then
        GITUP_TK_REUSE=1
        return 0
    fi
    if [ "$GITUP_TK_OURS" -gt 0 ]; then
        gitup_tk_fail "$GITUP_TK_OURS of ${#GITUP_TK_NAMES[@]} files in $GITUP_USRBIN are already links of ours but the saved originals in $GITUP_TK_ORIG cannot be trusted (record usable: $have, saved originals intact: $saved_ok, other files unchanged: $same); nothing was changed; run $GSG_NAME restore-system-git" || return 1
    fi
    if [ -f "$GITUP_TK_RECORD" ]; then
        printf '%s: the saved originals in %s are not the files the RPM has installed now; the saved originals are replaced by the current RPM files once the new copy is verified\n' "$GSG_NAME" "$GITUP_TK_DIR"
    fi
}

# ^ invariant $1 = where the record goes; the record names the package, the dnf excludes and the identity of each file as it is in usr/bin now
gitup_tk_write_record() {
    local i
    printf '%s\npackage %s\nexcludes %s\n' "$GITUP_TK_RECORD_MAGIC" "$GITUP_TK_NEVRA" "$GITUP_TK_EXCLUDES" >"$GITUP_TK_WORK/record" || return 1
    for i in "${!GITUP_TK_NAMES[@]}"; do
        printf 'file %s %s\n' "${GITUP_TK_NAMES[$i]}" "${GITUP_TK_HASHES[$i]}" >>"$GITUP_TK_WORK/record" || return 1
    done
    gitup_elevate install -m 644 -- "$GITUP_TK_WORK/record" "$1"
}

# ^ order orig.new and record.new are built and checked before they are renamed into place; the old backup is removed after the new one is complete
gitup_tk_backup() {
    local i n new="$GITUP_TK_ORIG.new" id
    if [ "$GITUP_TK_REUSE" -eq 1 ]; then return 0; fi
    gitup_elevate rm -rf -- "$new" "$GITUP_TK_RECORD.new" "$GITUP_TK_ORIG.old" || gitup_tk_fail "cannot clear $new" || return 1
    gitup_elevate mkdir -p -- "$new" || gitup_tk_fail "cannot create $new" || return 1
    for i in "${!GITUP_TK_NAMES[@]}"; do
        n="${GITUP_TK_NAMES[$i]}"
        gitup_elevate cp -a -- "$GITUP_USRBIN/$n" "$new/$n" || gitup_tk_fail "cannot copy $n to $new" || return 1
        id="$(gitup_tk_id "$new/$n")" || gitup_tk_fail "cannot read the saved copy of $n" || return 1
        if [ "$id" != "${GITUP_TK_HASHES[$i]}" ]; then gitup_tk_fail "the saved copy of $n differs from the original" || return 1; fi
    done
    gitup_tk_write_record "$GITUP_TK_RECORD.new" || gitup_tk_fail "cannot write the record $GITUP_TK_RECORD" || return 1
    if [ -d "$GITUP_TK_ORIG" ]; then gitup_elevate mv -T -- "$GITUP_TK_ORIG" "$GITUP_TK_ORIG.old" || gitup_tk_fail "cannot move the old saved originals aside" || return 1; fi
    gitup_elevate mv -T -- "$new" "$GITUP_TK_ORIG" || gitup_tk_fail "cannot move the new saved originals into place" || return 1
    gitup_elevate mv -T -- "$GITUP_TK_RECORD.new" "$GITUP_TK_RECORD" || gitup_tk_fail "cannot move the new record into place" || return 1
    gitup_elevate rm -rf -- "$GITUP_TK_ORIG.old" || printf '%s: left the old saved originals in %s\n' "$GSG_NAME" "$GITUP_TK_ORIG.old" >&2
}

# ^ order ln -sfT beside the path before mv -T over it; the rename is atomic and a file already our link is skipped
gitup_tk_swap() {
    local n tmp
    for n in "${GITUP_TK_NAMES[@]}"; do
        if gitup_tk_is_ours "$GITUP_USRBIN/$n"; then continue; fi
        tmp="$GITUP_USRBIN/.$n.gsg-new"
        gitup_elevate ln -sfT -- "$GITUP_PREFIX/bin/$n" "$tmp" || gitup_tk_fail "cannot create the link for $n" || return 1
        gitup_elevate mv -T -- "$tmp" "$GITUP_USRBIN/$n" || {
            gitup_elevate rm -f -- "$tmp" || printf '%s: left the temporary link %s\n' "$GSG_NAME" "$tmp" >&2
            gitup_tk_fail "cannot move the link over $GITUP_USRBIN/$n" || return 1
        }
        gitup_tk_relabel "$GITUP_USRBIN/$n"
    done
}

# ^ invariant after the swap /usr/bin/git is >= 2.54, a commit through it reaches a hook in a scratch repo and git-upload-pack runs; the scratch dir always goes
gitup_tk_verify() {
    local scratch rc=0
    install_git_is_new_enough "$GITUP_USRBIN/git" || gitup_tk_fail "$GITUP_USRBIN/git is not git 2.54 or newer after the swap" || return 1
    scratch="$(mktemp -d)" || return 1
    gitup_tk_verify_in "$scratch" || rc=$?
    rm -rf -- "$scratch"
    return "$rc"
}

gitup_tk_verify_in() {
    local s="$1" g="$GITUP_USRBIN/git"
    local -a run=(env -i HOME="$s" PATH="$PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1)
    printf '#!/bin/sh\n: >%q\nexit 1\n' "$s/hook-ran" >"$s/hook.sh" || return 1
    chmod 755 "$s/hook.sh" || return 1
    "${run[@]}" "$g" init -q "$s/repo" || gitup_tk_fail "$g cannot create a repository" || return 1
    "${run[@]}" "$g" -C "$s/repo" config hook.gsgverify.event pre-commit || return 1
    "${run[@]}" "$g" -C "$s/repo" config hook.gsgverify.command "$s/hook.sh" || return 1
    "${run[@]}" "$g" -C "$s/repo" -c user.name=gsg -c user.email=gsg@example.invalid commit --allow-empty -q -m probe >/dev/null 2>&1 || true
    if [ ! -e "$s/hook-ran" ]; then gitup_tk_fail "a commit through $g did not reach the hook, so commits would not be scanned" || return 1; fi
    "${run[@]}" "$GITUP_USRBIN/git-upload-pack" --stateless-rpc --advertise-refs "$s/repo" >/dev/null 2>&1 || gitup_tk_fail "git-upload-pack does not run through $GITUP_USRBIN" || return 1
}

# ^ invariant puts the saved original of NAME ($1) back with the same temporary-path move; the copy is checked against the recorded hash ($2) first
gitup_tk_put_back() {
    local n="$1" want="$2" tmp="$GITUP_USRBIN/.$1.gsg-restore" id
    gitup_elevate cp -a --remove-destination -- "$GITUP_TK_ORIG/$n" "$tmp" || return 1
    id="$(gitup_tk_id "$tmp")" || return 1
    if [ "$id" != "$want" ]; then
        gitup_elevate rm -f -- "$tmp" || printf '%s: left the temporary file %s\n' "$GSG_NAME" "$tmp" >&2
        printf '%s: the saved original of %s does not match its recorded SHA-256; it was not put back\n' "$GSG_NAME" "$n" >&2
        return 1
    fi
    gitup_elevate mv -T -- "$tmp" "$GITUP_USRBIN/$n" || return 1
    gitup_tk_relabel "$GITUP_USRBIN/$n"
}

# ^ invariant rc 0 only when rpm names git-core as owner of /usr/bin/NAME and rpm -V git-core ran without listing it; any doubt returns 1 and keeps the backup
gitup_tk_accept_foreign() {
    local n="$1" out line rc=0 owner err="$GITUP_TK_WORK/rpmv.err"
    install_find_bin rpm || {
        printf '%s: %s/%s is neither our link nor the saved original and rpm was not found to check it; the backup is kept\n' "$GSG_NAME" "$GITUP_USRBIN" "$n" >&2
        return 1
    }
    owner="$("$REPLY" -qf --qf '%{NAME}\n' -- "/usr/bin/$n" 2>"$err")" || owner=""
    if [ "$owner" != git-core ]; then
        printf '%s: %s/%s is neither our link nor the saved original and rpm does not name git-core as its owner; the backup is kept\n' "$GSG_NAME" "$GITUP_USRBIN" "$n" >&2
        return 1
    fi
    # ^ why rc 1 is tolerated, not a hard failure; rpm -V exits 1 when it lists differences, an answer here
    out="$("$REPLY" -V git-core 2>"$err")" || rc=$?
    if [ "$rc" -gt 1 ] || [[ $out == *"not installed"* ]]; then
        printf '%s: rpm -V git-core could not verify %s/%s (exit %s); the backup is kept\n' "$GSG_NAME" "$GITUP_USRBIN" "$n" "$rc" >&2
        return 1
    fi
    while IFS= read -r line; do
        if [ "${line##* }" = "/usr/bin/$n" ]; then
            printf '%s: %s/%s is neither our link nor the saved original and rpm -V reports it; it was left alone and the backup is kept\n' "$GSG_NAME" "$GITUP_USRBIN" "$n" >&2
            return 1
        fi
    done <<<"$out"
    printf '%s: %s/%s is neither our link nor the saved original, and rpm -V accepts it (the RPM wrote it); left alone\n' "$GSG_NAME" "$GITUP_USRBIN" "$n"
}

# ^ invariant removes the temporary files a stopped swap, restore or dnf.conf write can leave; a path is listed only when it exists
gitup_tk_clean_leftovers() {
    local n p
    local -a list=()
    for n in "${GITUP_TK_REC_NAMES[@]}" "${GITUP_TK_NAMES[@]}"; do
        for p in "$GITUP_USRBIN/.$n.gsg-new" "$GITUP_USRBIN/.$n.gsg-restore"; do
            if [ -e "$p" ] || [ -L "$p" ]; then list+=("$p"); fi
        done
    done
    p="${GITUP_DNFCONF%/*}/.${GITUP_DNFCONF##*/}.gsg-new"
    if [ -e "$p" ] || [ -L "$p" ]; then list+=("$p"); fi
    if [ "${#list[@]}" -eq 0 ]; then return 0; fi
    gitup_elevate rm -f -- "${list[@]}"
}

# ^ invariant true when the parent of the backup is a real empty directory; a link or a directory holding another file of ours is not
gitup_tk_varlib_empty() {
    [ -d "$GITUP_VARLIB" ] && [ ! -L "$GITUP_VARLIB" ] && [ -z "$(ls -A -- "$GITUP_VARLIB" 2>/dev/null)" ]
}

# ^ invariant the parent of the backup goes only when empty; rc 0 = removed, 1 = nothing to remove or it stayed
gitup_tk_drop_varlib() {
    if ! gitup_tk_varlib_empty; then return 1; fi
    if gitup_elevate rmdir -- "$GITUP_VARLIB"; then return 0; fi
    printf '%s: left the empty directory %s\n' "$GSG_NAME" "$GITUP_VARLIB" >&2
    return 1
}

# ^ invariant acts on what is on disk (record, dnf marker, links); rc 0 = every recorded file is the RPM file again, the dnf entry and the backup are gone
# ^ order the backup directory goes last, after every file and the dnf entry are fine; a stopped run can be repeated
gitup_tk_restore_core() {
    local i n path cur pkgs="" bad=0
    if gitup_tk_read_record; then
        pkgs="$GITUP_TK_REC_EXCLUDES"
        for i in "${!GITUP_TK_REC_NAMES[@]}"; do
            n="${GITUP_TK_REC_NAMES[$i]}"
            path="$GITUP_USRBIN/$n"
            if gitup_tk_is_ours "$path" || { [ ! -e "$path" ] && [ ! -L "$path" ]; }; then
                gitup_tk_put_back "$n" "${GITUP_TK_REC_SHAS[$i]}" || bad=1
                continue
            fi
            cur="$(gitup_tk_id "$path")" || {
                printf '%s: cannot read %s\n' "$GSG_NAME" "$path" >&2
                bad=1
                continue
            }
            if [ "$cur" != "${GITUP_TK_REC_SHAS[$i]}" ]; then gitup_tk_accept_foreign "$n" || bad=1; fi
        done
    elif [ -e "$GITUP_TK_RECORD" ]; then
        printf '%s: the record %s cannot be read\n' "$GSG_NAME" "$GITUP_TK_RECORD" >&2
        bad=1
    elif install_find_bin rpm; then
        GITUP_RPM_BIN="$REPLY"
        if gitup_tk_excludes >/dev/null 2>&1; then pkgs="$GITUP_TK_EXCLUDES"; fi
    fi
    gitup_tk_clean_leftovers || printf '%s: could not remove a temporary file below %s (a directory in the way is left alone)\n' "$GSG_NAME" "$GITUP_USRBIN" >&2
    if [ "$bad" -eq 0 ]; then gitup_tk_conf_remove "$pkgs" || bad=1; fi
    if [ "$bad" -eq 0 ] && { [ -e "$GITUP_TK_DIR" ] || [ -L "$GITUP_TK_DIR" ]; }; then gitup_elevate rm -rf -- "$GITUP_TK_DIR" || bad=1; fi
    if [ "$bad" -eq 0 ]; then gitup_tk_drop_varlib || true; fi
    return "$bad"
}

gitup_tk_rollback() {
    local bad=0
    printf '%s: the takeover failed (%s); putting everything back\n' "$GSG_NAME" "${GITUP_REASON:-see above}" >&2
    gitup_tk_restore_core || bad=1
    GITUP_TK_ACTIVE=0
    if [ "$bad" -eq 1 ]; then
        gitup_changed_add "the takeover could not be fully undone; the originals are in $GITUP_TK_ORIG and the dnf entry is marked in $GITUP_DNFCONF; run $GSG_NAME restore-system-git"
        return 1
    fi
    printf '%s: every original is back (hashes checked) and the dnf entry is gone\n' "$GSG_NAME" >&2
}

# ^ invariant the core calls it when the process exits during a takeover; INT TERM HUP stay ignored for the whole undo
gitup_tk_abort() {
    if [ "$GITUP_TK_ACTIVE" -ne 1 ]; then return 0; fi
    trap '' INT TERM HUP
    GITUP_REASON="interrupted"
    if [ -z "$GITUP_TK_WORK" ] || [ ! -d "$GITUP_TK_WORK" ]; then GITUP_TK_WORK="$(mktemp -d)" || return 1; fi
    gitup_tk_rollback || printf '%s: the rollback after the interruption did not finish\n' "$GSG_NAME" >&2
    rm -rf -- "$GITUP_TK_WORK"
}

gitup_tk_apply_steps() {
    GITUP_TK_ACTIVE=0
    gitup_tk_names && gitup_tk_excludes && gitup_tk_hash_originals && gitup_tk_classify || return 1
    GITUP_TK_ACTIVE=1
    if gitup_tk_conf_add && gitup_tk_backup && gitup_tk_swap && gitup_tk_verify; then
        GITUP_TK_ACTIVE=0
        printf '%s: %s and its %s siblings now point at %s (originals saved in %s; undo with: %s restore-system-git)\n' \
            "$GSG_NAME" "$GITUP_USRBIN/git" "$((${#GITUP_TK_NAMES[@]} - 1))" "$GITUP_PREFIX/bin" "$GITUP_TK_ORIG" "$GSG_NAME"
        gitup_changed_add "the system git $GITUP_USRBIN/git was taken over (dnf entry in $GITUP_DNFCONF, originals in $GITUP_TK_ORIG)"
        return 0
    fi
    gitup_tk_rollback
    return 1
}

gitup_tk_apply() {
    local rc
    gitup_tk_dirs
    GITUP_TK_WORK="$(mktemp -d)" || return 1
    gitup_tk_apply_steps "$1"
    rc=$?
    rm -rf -- "$GITUP_TK_WORK"
    return "$rc"
}

# ^ invariant a signal during restore-system-git ends it with the machine state and the next command; every step can be repeated, the backup goes last
# ^ why a trap, not the default; with none a script ignores SIGINT if the child it waits for survives it, and some Ctrl-C did nothing
gitup_tk_restore_stopped() {
    trap '' INT TERM HUP
    gitup_tk_status
    # ^ why its own message for state none, not the generic one; the last file was back before the signal, only the backup or an empty directory can be left
    if [ "$GITUP_TK_STATE" = none ]; then
        if [ -e "$GITUP_TK_DIR" ] || [ -L "$GITUP_TK_DIR" ]; then
            printf '\n%s: restore-system-git was interrupted at its last step; the RPM files are back and the backup directory %s is left; remove it by hand: sudo rm -rf -- %s\n' "$GSG_NAME" "$GITUP_TK_DIR" "$GITUP_TK_DIR" >&2
        elif gitup_tk_varlib_empty; then
            printf '\n%s: restore-system-git was interrupted at its last step; the RPM files are back and the empty directory %s is left; run %s restore-system-git to remove it\n' "$GSG_NAME" "$GITUP_VARLIB" "$GSG_NAME" >&2
        else
            printf '\n%s: restore-system-git was interrupted at its last step; the restore had finished and nothing is left to do\n' "$GSG_NAME" >&2
        fi
        exit "$1"
    fi
    printf '\n%s: restore-system-git was interrupted. %s\n' "$GSG_NAME" "${GITUP_TK_TEXT%%; run: *}" >&2
    printf '%s: run: %s restore-system-git (it can be repeated; the saved originals stay until the restore finishes)\n' "$GSG_NAME" "$GSG_NAME" >&2
    exit "$1"
}

# ^ invariant restores each file still our link from its saved original (hash checked), drops the dnf entry and the backup directory; no network, no dnf
gitup_tk_restore() {
    local bad=0
    gitup_tk_dirs
    gitup_tk_status
    if [ "$GITUP_TK_STATE" = none ]; then
        printf '%s: nothing to restore: there is no takeover record in %s\n' "$GSG_NAME" "$GITUP_TK_DIR"
        if gitup_tk_drop_varlib; then printf '%s: removed the empty directory %s\n' "$GSG_NAME" "$GITUP_VARLIB"; fi
        return 0
    fi
    if [ "$GITUP_TK_STATE" = broken ]; then
        printf '%s: %s\n' "$GSG_NAME" "$GITUP_TK_TEXT" >&2
        printf '%s: restore will not guess from a record it cannot read; undo it by hand:\n%s\n' "$GSG_NAME" "$GITUP_TK_HOWTO" >&2
        return 1
    fi
    GITUP_TK_WORK=""
    trap 'gitup_tk_restore_stopped 130' INT
    trap 'gitup_tk_restore_stopped 143' TERM
    trap 'gitup_tk_restore_stopped 129' HUP
    trap 'if [ -n "$GITUP_TK_WORK" ]; then rm -rf -- "$GITUP_TK_WORK"; fi' EXIT
    GITUP_TK_WORK="$(mktemp -d)" || return 1
    gitup_tk_restore_core || bad=1
    rm -rf -- "$GITUP_TK_WORK"
    GITUP_TK_WORK=""
    trap - INT TERM HUP EXIT
    if [ "$bad" -ne 0 ]; then
        printf '%s: the restore did not finish; the saved originals stay in %s, fix the cause and run it again\n' "$GSG_NAME" "$GITUP_TK_ORIG" >&2
        return 1
    fi
    printf '%s: restored the RPM files in %s, removed the excludepkgs entry from %s and the backup directory %s\n' "$GSG_NAME" "$GITUP_USRBIN" "$GITUP_DNFCONF" "$GITUP_TK_DIR"
}
