# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled the git upgrade module of the ubuntu and debian classes (apt); registered in lib/gitup.sh, contract in CONTRIBUTING.md
# ^ external apt-cache policy prints a Candidate line such as 1:2.34.1-1ubuntu1.11 (epoch, upstream version, packaging suffix); probed read-only on Ubuntu 22.04

GITUP_APT_PPA=ppa:git-core/ppa
# ^ external the primary key fingerprint of ppa:git-core/ppa; it equals signing_key_fingerprint of the PPA on Launchpad (docs/platforms.md#maintainer-notes)
GITUP_APT_PPA_FPR=F911AB184317630C59970973E363C90F8F1B6217
GITUP_APT_PPA_RE='ppa[.]launchpad(content)?[.]net/git-core/ppa([/ \t]|$)'
GITUP_APT_ENVWORDS=(DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none)
GITUP_APT_BUILD_PKGS=(build-essential libcurl4-openssl-dev libssl-dev libexpat1-dev zlib1g-dev perl libpcre2-dev xz-utils tar)
GITUP_APT_FLAGS=(NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 USE_LIBPCRE2=1)
GITUP_APT_KEY_MAX_BYTES=1048576
GITUP_APT_SIGNED_BY_MAX_LINES=5000
GITUP_APT_LOCK_SECONDS=120
GITUP_APT_APTGET="" GITUP_APT_APTCACHE="" GITUP_APT_ENVBIN="" GITUP_APT_GPG="" GITUP_APT_ADDER=""
GITUP_APT_ETC="" GITUP_APT_SOURCES_DIR="" GITUP_APT_TRUSTED_DIR=""
GITUP_APT_CMD=()
GITUP_APT_PPA_FILES=() GITUP_APT_FOREIGN=() GITUP_APT_UNREADABLE=() GITUP_APT_PRE=() GITUP_APT_KEYRINGS=() GITUP_APT_BEFORE=() GITUP_APT_ADDED=()
GITUP_APT_REMOVED=""
GITUP_APT_NEIGHBOURS=() GITUP_APT_UNJUDGED=()
GITUP_APT_SNAPPED=0
GITUP_APT_INTERRUPTED=0
GITUP_APT_A_MKDIR=() GITUP_APT_A_MVS=() GITUP_APT_A_MVK=()
GITUP_APT_CANDIDATE="" GITUP_APT_CANDIDATE_RAW="" GITUP_APT_CANDIDATE_ORIGIN="" GITUP_APT_WHY="" GITUP_APT_STUCK=""
# ^ invariant none, verified, mismatch or unverifiable; what the git-core PPA looked like before this run touched anything
GITUP_APT_PRE_STATE=none
GITUP_APT_ASIDE=""
# ^ invariant 1 from the moment add-apt-repository may have written files until their key matched the pin; an exit in between removes what this run added
GITUP_APT_PPA_PENDING=0
# ^ invariant 1 once apt lists may hold the PPA or files were removed => a refresh is owed
GITUP_APT_TOUCHED=0
GITUP_APT_ADDED_CLAUSE="the git-core PPA ($GITUP_APT_PPA) was added to apt"

# ^ security root runs apt-get and env found in the fixed system path only, root-owned and not group or other writable; the plan prints their full paths
# ^ invariant sets the tool variables and the apt directories; rc 1 names the problem on stderr
gitup_apt_init() {
    local tool
    GITUP_APT_APTGET="" GITUP_APT_APTCACHE="" GITUP_APT_ENVBIN=""
    if gitup_system_bin apt-get; then GITUP_APT_APTGET="$REPLY"; fi
    if gitup_system_bin apt-cache; then GITUP_APT_APTCACHE="$REPLY"; fi
    if gitup_system_bin env; then GITUP_APT_ENVBIN="$REPLY"; fi
    for tool in "$GITUP_APT_APTGET" "$GITUP_APT_APTCACHE" "$GITUP_APT_ENVBIN"; do
        if [ -n "$tool" ]; then continue; fi
        printf '%s: apt-get, apt-cache or env was not found in the system path (%s) or is not root-owned; install apt, or build git yourself, see docs/platforms.md\n' \
            "$GSG_NAME" "$GITUP_SYSTEM_PATH" >&2
        return 1
    done
    GITUP_APT_ETC="$GITUP_ROOT/etc/apt"
    GITUP_APT_SOURCES_DIR="$GITUP_APT_ETC/sources.list.d"
    GITUP_APT_TRUSTED_DIR="$GITUP_APT_ETC/trusted.gpg.d"
}

# ^ invariant GITUP_APT_CMD = the words of one privileged command, TOOL first; env carries the answers apt asks for, as sudo drops the caller's variables
# ^ invariant the plan prints these words and gitup_elevate runs these words => the two cannot differ
gitup_apt_cmd() {
    GITUP_APT_CMD=("$GITUP_APT_ENVBIN" "${GITUP_APT_ENVWORDS[@]}" "$@")
}

gitup_apt_get_cmd() {
    gitup_apt_cmd "$GITUP_APT_APTGET" -o "DPkg::Lock::Timeout=$GITUP_APT_LOCK_SECONDS" "$@"
}

# ^ invariant runs one privileged apt-get; nothing waits for input => env fixes the frontend and -y answers the rest
gitup_apt_run_get() {
    gitup_apt_get_cmd "$@"
    gitup_elevate "${GITUP_APT_CMD[@]}"
}

# ^ invariant sets REPLY = the upstream version of a Debian version string (epoch and packaging suffix dropped); rc 1 = not a plain release version
# ^ why a tilde after the number is refused, not read as a release; 2.54.0~rc1 sorts before 2.54.0 and must not pass the floor
gitup_apt_upstream() {
    local v="$1"
    REPLY=""
    if [[ $v =~ ^[0-9]+:(.*)$ ]]; then v="${BASH_REMATCH[1]}"; fi
    if [[ $v =~ ^([0-9]+(\.[0-9]+)*)([-+].*)?$ ]]; then
        REPLY="${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# ^ security stdin is /dev/null, the call is bounded, the locale is fixed (the label is translated otherwise), and apt-cache takes no lock and writes nothing
gitup_apt_query() {
    LC_ALL=C LANG=C LANGUAGE=C "$INSTALL_TIMEOUT_BIN" -k 5 "$GITUP_QUERY_TIMEOUT" "$GITUP_APT_APTCACHE" policy git </dev/null
}

# ^ invariant sets GITUP_APT_CANDIDATE (upstream version), the raw string and the first source of its table entry; rc 1 = the query failed
# ^ why a here-string loop with break, not a pipe into sed q; under pipefail the writer gets SIGPIPE and a good candidate is lost
gitup_apt_candidate() {
    local out line rc=0 captured=0
    GITUP_APT_CANDIDATE="" GITUP_APT_CANDIDATE_RAW="" GITUP_APT_CANDIDATE_ORIGIN=""
    out="$(gitup_apt_query)" || rc=$?
    if [ "$rc" -ne 0 ]; then return 1; fi
    while IFS= read -r line; do
        if [ -z "$GITUP_APT_CANDIDATE_RAW" ]; then
            if [[ $line =~ ^[[:space:]]+Candidate:[[:space:]]+([A-Za-z0-9.+~:_-]+)[[:space:]]*$ ]]; then GITUP_APT_CANDIDATE_RAW="${BASH_REMATCH[1]}"; fi
            continue
        fi
        if [[ $line =~ ^[[:space:]]+(\*\*\*[[:space:]]+)?([A-Za-z0-9.+~:_-]+)[[:space:]]+[0-9]+$ ]]; then
            if [ "$captured" -eq 1 ]; then break; fi
            if [ "${BASH_REMATCH[2]}" = "$GITUP_APT_CANDIDATE_RAW" ]; then captured=1; fi
        elif [ "$captured" -eq 1 ] && [[ $line =~ ^[[:space:]]+[0-9]+[[:space:]]+([^[:space:]]+) ]]; then
            GITUP_APT_CANDIDATE_ORIGIN="${BASH_REMATCH[1]//[^A-Za-z0-9._:\/@%+~-]/?}"
            break
        fi
    done <<<"$out"
    if [ -n "$GITUP_APT_CANDIDATE_RAW" ] && gitup_apt_upstream "$GITUP_APT_CANDIDATE_RAW"; then GITUP_APT_CANDIDATE="$REPLY"; fi
    return 0
}

gitup_apt_floor_ok() {
    [ -n "$GITUP_APT_CANDIDATE" ] && gitup_version_at_least "$GITUP_APT_CANDIDATE" "$GSG_MIN_GIT_MAJOR.$GSG_MIN_GIT_MINOR"
}

gitup_apt_query_text() {
    local from=""
    if [ -n "$GITUP_APT_CANDIDATE_ORIGIN" ]; then from=" from $GITUP_APT_CANDIDATE_ORIGIN"; fi
    if [ -n "$GITUP_APT_CANDIDATE_RAW" ] && [ -z "$GITUP_APT_CANDIDATE" ]; then
        printf 'apt offers git %s%s, which is not a plain release version' "$GITUP_APT_CANDIDATE_RAW" "$from"
    elif [ -n "$GITUP_APT_CANDIDATE" ]; then
        printf 'apt offers git %s%s' "$GITUP_APT_CANDIDATE_RAW" "$from"
    else
        printf 'apt offers no git candidate'
    fi
}

# ^ invariant sets GITUP_SRC_PRE (the refresh), GITUP_SRC_DEPS and GITUP_SRC_FLAGS for the shared source build; rc 1 = apt is not usable
# ^ order the refresh runs before the first install, as stale or empty lists would fail the dependency install
gitup_apt_prepare() {
    gitup_apt_init || return 1
    gitup_apt_get_cmd update
    GITUP_SRC_PRE=("${GITUP_APT_CMD[@]}")
    gitup_apt_get_cmd install -y --no-install-recommends "${GITUP_APT_BUILD_PKGS[@]}"
    GITUP_SRC_DEPS=("${GITUP_APT_CMD[@]}")
    GITUP_SRC_FLAGS=("${GITUP_APT_FLAGS[@]}")
}

# ^ external real key file names are git-core-ubuntu-ppa.gpg (22.04, with a .gpg~ backup) and git-core_ubuntu_ppa.gpg (20.04, underscores)
# ^ invariant the files of the PPA present now by their names, in both forms (sources and list files, the trusted.gpg.d key with its backup)
gitup_apt_ppa_files() {
    local f
    GITUP_APT_PPA_FILES=()
    for f in "$GITUP_APT_SOURCES_DIR"/git-core-ubuntu-ppa-* "$GITUP_APT_TRUSTED_DIR"/git-core-ubuntu-ppa.gpg* "$GITUP_APT_TRUSTED_DIR"/git-core_ubuntu_ppa.gpg*; do
        if [ -e "$f" ] || [ -L "$f" ]; then GITUP_APT_PPA_FILES+=("$f"); fi
    done
}

# ^ invariant rc 0 = a non-comment line of FILE names the PPA (mode any) or a stanza naming it is enabled (mode active), 1 = none, 2 = unreadable
# ^ why the URL is matched on any non-comment line, not after URIs:; deb822 allows URIs:https://x and a folded value on the next line
# ^ external Enabled is read like apt does, with the false words of StringToBool (no false without off disable 0), libapt-pkg carries without and disable
gitup_apt_scan() {
    awk -v re="$GITUP_APT_PPA_RE" -v mode="$1" '
        function flush() { if (has && !dis) act = 1; has = 0; dis = 0 }
        /^[ \t]*#/ { next }
        /^[ \t]*$/ { flush(); next }
        { l = tolower($0); if (l ~ re) { has = 1; any = 1 } if (l ~ /^[ \t]*enabled:[ \t]*(no|false|without|off|disable|0+)[ \t]*$/) dis = 1 }
        END { flush(); if (mode == "active") exit(act ? 0 : 1); exit(any ? 0 : 1) }' "$2" 2>/dev/null
}

# ^ invariant entries of the PPA found by content in other sources files (sources.list, *.list, *.sources); an unreadable file counts as one and is listed apart
gitup_apt_foreign_entries() {
    local f rc
    GITUP_APT_FOREIGN=() GITUP_APT_UNREADABLE=()
    for f in "$GITUP_APT_ETC/sources.list" "$GITUP_APT_SOURCES_DIR"/*.list "$GITUP_APT_SOURCES_DIR"/*.sources; do
        if [ ! -f "$f" ] || [[ ${f##*/} == git-core-ubuntu-ppa-* ]]; then continue; fi
        rc=0
        gitup_apt_scan any "$f" || rc=$?
        if [ "$rc" -eq 1 ]; then continue; fi
        GITUP_APT_FOREIGN+=("$f")
        if [ "$rc" -ne 0 ]; then GITUP_APT_UNREADABLE+=("$f"); fi
    done
}

# ^ invariant rc 0 = a named PPA file holds an enabled entry, 1 = none (a key alone or a disabled entry is no PPA), 3 = unreadable with WHY set
gitup_apt_ppa_has_active() {
    local f rc
    for f in "$GITUP_APT_SOURCES_DIR"/git-core-ubuntu-ppa-*.list "$GITUP_APT_SOURCES_DIR"/git-core-ubuntu-ppa-*.sources; do
        if [ ! -f "$f" ]; then continue; fi
        rc=0
        gitup_apt_scan active "$f" || rc=$?
        if [ "$rc" -eq 0 ]; then return 0; fi
        if [ "$rc" -eq 2 ]; then
            GITUP_APT_WHY="cannot read ${f##*/}, so it cannot be checked"
            return 3
        fi
    done
    GITUP_APT_WHY="no enabled git-core PPA entry is among them (only a key, a disabled entry or commented-out lines)"
    return 1
}

gitup_apt_readable() {
    if [ -r "$1" ]; then return 0; fi
    GITUP_APT_WHY="cannot read ${1##*/}, so it cannot be checked"
    return 3
}

# ^ invariant stdin is gpg input, stdout the primary key fingerprints one per line; a scratch GNUPGHOME keeps ~/.gnupg untouched
# ^ why the colon records are read in bash, not by awk after gpg; a failing gpg must not be hidden by the last command of a pipe
gitup_apt_show_keys() {
    local gh out line want=0 rc=0
    local -a f
    gh="$(mktemp -d "${TMPDIR:-/tmp}/gsg-apt-gpg.XXXXXX")" || return 1
    out="$(GNUPGHOME="$gh" "$GITUP_APT_GPG" --batch --show-keys --with-colons 2>/dev/null)" || rc=$?
    rm -rf -- "$gh"
    while IFS= read -r line; do
        case "$line" in
            pub:*) want=1 ;;
            fpr:*)
                if [ "$want" -eq 1 ]; then
                    IFS=: read -r -a f <<<"$line"
                    printf '%s\n' "${f[9]:-}"
                    want=0
                fi
                ;;
        esac
    done <<<"$out"
    return "$rc"
}

# ^ invariant prints the armored key of the Signed-By field of a deb822 file (indented lines, a lone dot is an empty line); nothing for a Signed-By path
gitup_apt_signed_by() {
    local line inblk=0
    local -a lines=()
    { mapfile -t -n "$GITUP_APT_SIGNED_BY_MAX_LINES" lines <"$1"; } 2>/dev/null || return 1
    for line in "${lines[@]}"; do
        if [[ $line == Signed-By:* ]]; then
            inblk=1
            continue
        fi
        if [ "$inblk" -eq 1 ] && [[ $line == " "* ]]; then
            line="${line# }"
            if [ "$line" = . ]; then line=""; fi
            printf '%s\n' "$line"
            continue
        fi
        inblk=0
    done
}

# ^ invariant rc 0 = the keys on stdin are exactly the pin, 1 = other keys, 3 = gpg failed (its output is never trusted after a non-zero exit)
gitup_apt_fpr_is_pinned() {
    local got rc=0
    got="$(gitup_apt_show_keys)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        GITUP_APT_WHY="gpg failed (exit $rc) while reading the key of $1, so it cannot be checked"
        return 3
    fi
    if [ "$got" = "$GITUP_APT_PPA_FPR" ]; then return 0; fi
    got="${got//$'\n'/ }"
    GITUP_APT_WHY="the PPA signing key fingerprint in $1 is [${got//[^0-9A-Za-z ]/?}], not the pinned one"
    return 1
}

gitup_apt_check_keyring() {
    local key="$1" size
    gitup_apt_readable "$key" || return 3
    size="$(wc -c <"$key")" || return 3
    if [ "${size//[[:space:]]/}" -gt "$GITUP_APT_KEY_MAX_BYTES" ]; then
        GITUP_APT_WHY="${key##*/} is larger than $GITUP_APT_KEY_MAX_BYTES bytes"
        return 1
    fi
    gitup_apt_fpr_is_pinned "${key##*/}" <"$key"
}

# ^ invariant the key files to check are the two known names and every file this run added to trusted.gpg.d (backups ending in a tilde are removed, never read)
gitup_apt_keyrings() {
    local f g
    GITUP_APT_KEYRINGS=()
    for f in "$GITUP_APT_TRUSTED_DIR/git-core-ubuntu-ppa.gpg" "$GITUP_APT_TRUSTED_DIR/git-core_ubuntu_ppa.gpg" "${GITUP_APT_ADDED[@]}"; do
        if [ ! -f "$f" ] || [[ $f == *"~" ]] || [[ $f != "$GITUP_APT_TRUSTED_DIR"/* ]]; then continue; fi
        for g in "${GITUP_APT_KEYRINGS[@]}"; do
            if [ "$g" = "$f" ]; then continue 2; fi
        done
        GITUP_APT_KEYRINGS+=("$f")
    done
}

# ^ invariant the entries of sources.list.d and trusted.gpg.d, NUL separated and sorted; the difference around add-apt-repository is what the run added
gitup_apt_list_dirs() {
    local f
    for f in "$GITUP_APT_SOURCES_DIR"/* "$GITUP_APT_TRUSTED_DIR"/*; do
        if [ -e "$f" ] || [ -L "$f" ]; then printf "%s\0" "$f"; fi
    done | LC_ALL=C sort -z
}

gitup_apt_snapshot() {
    mapfile -d "" -t GITUP_APT_BEFORE < <(gitup_apt_list_dirs)
    GITUP_APT_SNAPPED=1
}

# ^ security only what is provably the PPA's is ours to delete, a sources file the content scan matches, a known name, or a key holding exactly the pin
# ^ invariant rc 0 = provably the PPA's; any other new file is a neighbour's or unknown, and is named and left alone, never removed
gitup_apt_owned() {
    local f="$1" n="${1##*/}" rc=0 saved="$GITUP_APT_WHY" size
    case "$f" in
        "$GITUP_APT_SOURCES_DIR"/*)
            if [[ $n == git-core-ubuntu-ppa-* ]]; then return 0; fi
            gitup_apt_scan any "$f" || rc=$?
            return "$rc"
            ;;
        "$GITUP_APT_TRUSTED_DIR"/*)
            case "$n" in git-core-ubuntu-ppa.gpg* | git-core_ubuntu_ppa.gpg*) return 0 ;; esac
            if [[ $n == *"~" ]] || [ ! -f "$f" ] || [ ! -r "$f" ]; then return 1; fi
            size="$(wc -c <"$f")" || return 1
            if [ "${size//[[:space:]]/}" -gt "$GITUP_APT_KEY_MAX_BYTES" ]; then return 1; fi
            if gitup_system_bin gpg; then GITUP_APT_GPG="$REPLY"; else return 1; fi
            gitup_apt_fpr_is_pinned "$n" <"$f" || rc=$?
            GITUP_APT_WHY="$saved"
            return "$rc"
            ;;
    esac
    return 1
}

gitup_apt_added() {
    local f b
    local -a now=()
    GITUP_APT_ADDED=() GITUP_APT_NEIGHBOURS=()
    mapfile -d "" -t now < <(gitup_apt_list_dirs)
    for f in "${now[@]}"; do
        for b in "${GITUP_APT_BEFORE[@]}"; do
            if [ "$b" = "$f" ]; then continue 2; fi
        done
        if gitup_apt_owned "$f"; then GITUP_APT_ADDED+=("$f"); else GITUP_APT_NEIGHBOURS+=("$f"); fi
    done
}

# ^ invariant the new key files not provably the PPA's; apt trusts each for every repository and nothing here tells whose it is
gitup_apt_unjudged_keys() {
    local f
    GITUP_APT_UNJUDGED=()
    for f in "${GITUP_APT_NEIGHBOURS[@]}"; do
        if [[ $f == "$GITUP_APT_TRUSTED_DIR"/* ]] && [[ $f != *"~" ]]; then GITUP_APT_UNJUDGED+=("${f##*/}"); fi
    done
}

# ^ security the PPA key is fetched from Launchpad over TLS on first use; its fingerprint must equal the pin before apt trusts a package from it
# ^ security every key in a trusted.gpg.d file is trusted by apt for all repositories => each PPA key file must hold the pin and nothing else
# ^ invariant rc 0 = every PPA file present is the pin, 1 = mismatch, 2 = no PPA file, 3 = cannot check; the key file is read whenever it exists
gitup_apt_ppa_key_matches() {
    local f key armor seen=0 rc
    GITUP_APT_WHY=""
    if gitup_system_bin gpg; then GITUP_APT_GPG="$REPLY"; else
        GITUP_APT_WHY="gpg was not found in the system path ($GITUP_SYSTEM_PATH), so the PPA key cannot be checked"
        return 3
    fi
    for f in "$GITUP_APT_SOURCES_DIR"/git-core-ubuntu-ppa-*.sources; do
        if [ ! -f "$f" ]; then continue; fi
        seen=1
        gitup_apt_readable "$f" || return 3
        armor="$(gitup_apt_signed_by "$f")" || return 3
        rc=0
        gitup_apt_fpr_is_pinned "${f##*/}" <<<"$armor" || rc=$?
        if [ "$rc" -ne 0 ]; then return "$rc"; fi
    done
    gitup_apt_keyrings
    for f in "$GITUP_APT_SOURCES_DIR"/git-core-ubuntu-ppa-*.list; do
        if [ ! -f "$f" ]; then continue; fi
        seen=1
        gitup_apt_readable "$f" || return 3
        if [ "${#GITUP_APT_KEYRINGS[@]}" -eq 0 ]; then
            GITUP_APT_WHY="${f##*/} names the PPA but no key file (git-core-ubuntu-ppa.gpg or git-core_ubuntu_ppa.gpg) is in $GITUP_APT_TRUSTED_DIR"
            return 1
        fi
    done
    for key in "${GITUP_APT_KEYRINGS[@]}"; do
        seen=1
        rc=0
        gitup_apt_check_keyring "$key" || rc=$?
        if [ "$rc" -ne 0 ]; then return "$rc"; fi
    done
    if [ "$seen" -eq 0 ]; then
        GITUP_APT_WHY="no git-core PPA .sources or .list file found in $GITUP_APT_SOURCES_DIR"
        return 2
    fi
}

# ^ invariant sets GITUP_APT_PRE (PPA files present before this run) and GITUP_APT_PRE_STATE; an entry under another name cannot be checked and stops the route
gitup_apt_preflight() {
    local rc name more=""
    GITUP_APT_PRE=() GITUP_APT_PRE_STATE=none GITUP_APT_WHY=""
    gitup_apt_foreign_entries
    if [ "${#GITUP_APT_UNREADABLE[@]}" -gt 0 ]; then
        GITUP_APT_PRE_STATE=unverifiable
        GITUP_APT_WHY="cannot read ${GITUP_APT_UNREADABLE[0]##*/}, so it cannot be checked for a git-core PPA entry; make it readable and run install again"
        return 0
    fi
    if [ "${#GITUP_APT_FOREIGN[@]}" -gt 0 ]; then
        name="${GITUP_APT_FOREIGN[0]##*/}"
        if [ "${#GITUP_APT_FOREIGN[@]}" -gt 1 ]; then more=" and $((${#GITUP_APT_FOREIGN[@]} - 1)) more"; fi
        GITUP_APT_PRE_STATE=unverifiable
        GITUP_APT_WHY="a git-core PPA entry exists in ${name//[^[:print:]]/?}$more, which this tool did not write, so its key cannot be checked; remove or fix it by hand and run install again"
        return 0
    fi
    gitup_apt_ppa_files
    if [ "${#GITUP_APT_PPA_FILES[@]}" -eq 0 ]; then return 0; fi
    GITUP_APT_PRE=("${GITUP_APT_PPA_FILES[@]}")
    rc=0
    gitup_apt_ppa_key_matches || rc=$?
    if [ "$rc" -eq 0 ]; then
        gitup_apt_ppa_has_active || rc=$?
    fi
    case "$rc" in
        0) GITUP_APT_PRE_STATE=verified ;;
        3) GITUP_APT_PRE_STATE=unverifiable ;;
        *) GITUP_APT_PRE_STATE=mismatch ;;
    esac
}

# ^ invariant fixes the aside location once per run and builds the commands moving the existing PPA files there; an unused kind leaves its array empty
gitup_apt_aside_words() {
    local f
    local -a src=() key=()
    if [ -z "$GITUP_APT_ASIDE" ]; then GITUP_APT_ASIDE="$GITUP_VARLIB/ppa-aside-$(date -u +%Y%m%dT%H%M%SZ)"; fi
    for f in "${GITUP_APT_PRE[@]}"; do
        case "$f" in
            "$GITUP_APT_SOURCES_DIR"/*) src+=("$f") ;;
            *) key+=("$f") ;;
        esac
    done
    GITUP_APT_A_MKDIR=(mkdir -p --) GITUP_APT_A_MVS=() GITUP_APT_A_MVK=()
    if [ "${#src[@]}" -gt 0 ]; then
        GITUP_APT_A_MKDIR+=("$GITUP_APT_ASIDE/sources.list.d")
        GITUP_APT_A_MVS=(mv -n -- "${src[@]}" "$GITUP_APT_ASIDE/sources.list.d/")
    fi
    if [ "${#key[@]}" -gt 0 ]; then
        GITUP_APT_A_MKDIR+=("$GITUP_APT_ASIDE/trusted.gpg.d")
        GITUP_APT_A_MVK=(mv -n -- "${key[@]}" "$GITUP_APT_ASIDE/trusted.gpg.d/")
    fi
}

# ^ invariant prints the commands putting the set aside files back, one per file; the directory is kept by install and uninstall
gitup_apt_restore_lines() {
    local f sub
    for f in "${GITUP_APT_PRE[@]}"; do
        sub=trusted.gpg.d
        case "$f" in "$GITUP_APT_SOURCES_DIR"/*) sub=sources.list.d ;; esac
        printf '    as root: mv -n -- %s/%s/%s %s/\n' "$GITUP_APT_ASIDE" "$sub" "${f##*/}" "${f%/*}"
    done
}

# ^ invariant prints the plan of moving a PPA aside when it cannot be used, never deleting it; a refresh follows to drop what it offered
gitup_apt_plan_aside() {
    gitup_apt_aside_words
    printf '  the git-core PPA files already here cannot be used (%s); they are moved aside to %s, kept and never deleted, and apt is refreshed\n' \
        "$GITUP_APT_WHY" "$GITUP_APT_ASIDE"
    printf '  to put them back later, once the key is one you trust\n'
    gitup_apt_restore_lines
    gitup_plan_priv "${GITUP_APT_A_MKDIR[*]}"
    if [ "${#GITUP_APT_A_MVS[@]}" -gt 0 ]; then gitup_plan_priv "${GITUP_APT_A_MVS[*]}"; fi
    if [ "${#GITUP_APT_A_MVK[@]}" -gt 0 ]; then gitup_plan_priv "${GITUP_APT_A_MVK[*]}"; fi
    gitup_apt_get_cmd update
    gitup_plan_priv "${GITUP_APT_CMD[*]}"
}

# ^ security the old files move to a root-owned directory under the state area; rc 1 sets GITUP_APT_STUCK, the PPA may still be enabled when a move failed
gitup_apt_ppa_set_aside() {
    local partial
    gitup_apt_aside_words
    GITUP_APT_STUCK=""
    partial="files of the existing git-core PPA may be partly moved to $GITUP_APT_ASIDE (the files there are kept; mv -n them back to undo)"
    gitup_changed_add "$partial"
    gitup_elevate "${GITUP_APT_A_MKDIR[@]}" || {
        GITUP_APT_STUCK="cannot move the existing git-core PPA aside to $GITUP_APT_ASIDE (mkdir failed); it may still be enabled"
        return 1
    }
    if [ "${#GITUP_APT_A_MVS[@]}" -gt 0 ]; then
        gitup_elevate "${GITUP_APT_A_MVS[@]}" || {
            GITUP_APT_STUCK="cannot move the existing git-core PPA aside to $GITUP_APT_ASIDE (mv failed); it may still be enabled"
            return 1
        }
    fi
    if [ "${#GITUP_APT_A_MVK[@]}" -gt 0 ]; then
        gitup_elevate "${GITUP_APT_A_MVK[@]}" || {
            GITUP_APT_STUCK="cannot move the key of the existing git-core PPA aside to $GITUP_APT_ASIDE (mv failed); it may still be enabled"
            return 1
        }
    fi
    gitup_apt_ppa_files
    if [ "${#GITUP_APT_PPA_FILES[@]}" -gt 0 ]; then
        GITUP_APT_STUCK="the existing git-core PPA file ${GITUP_APT_PPA_FILES[0]##*/} is still in place after the move; it may still be enabled"
        return 1
    fi
    gitup_changed_drop "$partial"
    gitup_changed_add "the existing git-core PPA files, which could not be used, were moved to $GITUP_APT_ASIDE (kept; uninstall leaves them)"
    printf '%s: to put them back later\n' "$GSG_NAME"
    gitup_apt_restore_lines
    GITUP_APT_PRE=()
    gitup_apt_run_get update || {
        GITUP_APT_STUCK="moved the old git-core PPA files aside to $GITUP_APT_ASIDE but apt could not refresh its lists; run apt-get update by hand"
        return 1
    }
}

GITUP_APT_UPGRADE_NOTE="apt-get install -y of the build dependencies can upgrade packages that are already installed, and the plan does not count them"

# ^ invariant prints the plan of the shared source build with every privileged line marked as the fallback of the PPA route
# ^ why a temporary file, not a command substitution; the lists gitup_plan_priv fills must stay in this shell
gitup_apt_plan_fallback() {
    local tmp line mark="  [only when the PPA route fails or its git is below 2.54]" first i
    first="${#GITUP_PRIV_CMDS[@]}"
    tmp="$(mktemp "${TMPDIR:-/tmp}/gsg-apt-plan.XXXXXX")" || return 1
    if ! gitup_source_print_plan "$1" >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    while IFS= read -r line; do
        case "$line" in
            "  route: source "*) printf '  fallback, only when the PPA route fails or its git is below 2.54:%s\n' "${line#  route:}" ;;
            "  as root: "*) printf '%s%s\n' "$line" "$mark" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done <"$tmp"
    rm -f -- "$tmp"
    for ((i = first; i < ${#GITUP_PRIV_CMDS[@]}; i++)); do GITUP_PRIV_CMDS[i]+="$mark"; done
    gitup_plan_note "$GITUP_APT_UPGRADE_NOTE"
}

gitup_apt_plan_package() {
    GITUP_ROUTE=package
    printf "  route: package; %s (the query was read-only and stdin was /dev/null)\n" "$(gitup_apt_query_text)"
    if [ "$GITUP_APT_PRE_STATE" = verified ]; then printf "  your git-core PPA is kept; its key checked against the pin and passed\n"; fi
    gitup_apt_get_cmd update
    gitup_plan_priv "${GITUP_APT_CMD[*]}"
    gitup_apt_get_cmd install -y --no-install-recommends git
    gitup_plan_priv "${GITUP_APT_CMD[*]}"
}

# ^ invariant rc 0 when add-apt-repository is missing (the Ubuntu package brings one) or names --no-update; Linux Mint's has no -n
gitup_apt_adder_ok() {
    local out
    if ! gitup_system_bin add-apt-repository; then return 0; fi
    GITUP_APT_ADDER="$REPLY"
    out="$("$INSTALL_TIMEOUT_BIN" -k 5 "$GITUP_QUERY_TIMEOUT" "$GITUP_APT_ADDER" --help </dev/null 2>&1)" || true
    [[ $out == *--no-update* ]]
}

# ^ invariant the PPA plan names the PPA and the pinned fingerprint, lists every privileged command able to run and marks the conditional ones
# ^ invariant $2 = 1 keeps a PPA from before whose key passed the check (no add-apt-repository, nothing to remove when the route fails)
gitup_apt_plan_ppa() {
    local adder="${GITUP_SYSTEM_PATH%%:*}/add-apt-repository" need=0 mark
    GITUP_PRIV_BYHAND=0
    if [ "$2" -eq 1 ]; then
        printf '  route: ppa (%s, below 2.54); your git-core PPA, whose key passed the check against the pin, is kept; the pinned source build is the stated fallback\n' "$1"
    else
        printf '  route: ppa (%s, below 2.54); the pinned source build is the stated fallback\n' "$1"
        printf '  the PPA is %s; its signing key must have the fingerprint %s, checked before the first apt-get update that could trust it\n' "$GITUP_APT_PPA" "$GITUP_APT_PPA_FPR"
        if gitup_system_bin add-apt-repository; then adder="$REPLY"; else need=1; fi
        if ! gitup_system_bin gpg; then need=1; fi
        if [ "$need" -eq 1 ]; then
            gitup_apt_get_cmd update
            gitup_plan_priv "${GITUP_APT_CMD[*]}"
            gitup_apt_get_cmd install -y --no-install-recommends software-properties-common gnupg
            gitup_plan_priv "${GITUP_APT_CMD[*]}"
        fi
        gitup_apt_cmd "$adder" -y -n "$GITUP_APT_PPA"
        gitup_plan_priv "${GITUP_APT_CMD[*]}"
    fi
    printf '  the PPA counts only if its git is 2.54 or newer after the update\n'
    gitup_apt_get_cmd update
    gitup_plan_priv "${GITUP_APT_CMD[*]}"
    gitup_apt_get_cmd install -y --no-install-recommends git
    gitup_plan_priv "${GITUP_APT_CMD[*]}  [only when the key and floor checks pass]"
    if [ "$2" -eq 0 ]; then
        printf '  otherwise the PPA files this run added are removed again (sources or list file and trusted.gpg.d key)\n'
        mark="  [only when the PPA route fails]"
        gitup_plan_priv "rm -f -- <the git-core PPA files in $GITUP_APT_SOURCES_DIR and $GITUP_APT_TRUSTED_DIR that this run added>$mark"
        gitup_apt_get_cmd update
        gitup_plan_priv "${GITUP_APT_CMD[*]}$mark"
    fi
    gitup_plan_note "after a successful install the PPA stays enabled, so apt upgrade keeps git current; uninstall leaves the PPA and git as they are"
    gitup_source_pins || return 1
    gitup_apt_prepare || return 1
    gitup_apt_plan_fallback "the PPA route did not give git 2.54 or newer" || return 1
    GITUP_ROUTE=ppa
}

gitup_apt_plan_upgrade() {
    local new="$GITUP_PREFIX/bin/git" reason adopt=0 from_ppa=0 class
    if [ -x "$new" ] && install_git_is_new_enough "$new" && gitup_source_read_manifests && [ "${#GITUP_PARTIALS[@]}" -eq 0 ]; then
        GITUP_ROUTE=path-fix GITUP_FOUND_GIT="$new"
        printf "  route: path-fix; %s is already git %s, only PATH is wrong\n" "$new" "$(install_git_version "$new")"
        return 0
    fi
    gitup_apt_init || return 1
    gitup_apt_preflight
    case "$GITUP_APT_PRE_STATE" in
        unverifiable)
            printf "  %s\n" "$GITUP_APT_WHY"
            return 1
            ;;
        mismatch) GITUP_PRIV_BYHAND=0 ;;
        verified) adopt=1 ;;
    esac
    if ! gitup_apt_candidate; then printf "  the apt query for git failed or timed out; no package route is trusted\n"; fi
    # ^ why the origin is read, not the state alone; a candidate offered by a PPA going aside is not the distribution package
    if [[ $GITUP_APT_CANDIDATE_ORIGIN == *ppa.launchpad* ]]; then from_ppa=1; fi
    if gitup_apt_floor_ok && { [ "$GITUP_APT_PRE_STATE" != mismatch ] || [ "$from_ppa" -eq 0 ]; }; then
        if [ "$GITUP_APT_PRE_STATE" = mismatch ]; then gitup_apt_plan_aside; fi
        gitup_apt_plan_package
        return 0
    fi
    reason="$(gitup_apt_query_text)"
    if [ "$GITUP_APT_PRE_STATE" = mismatch ]; then
        reason="the candidate shown with the old PPA is not trusted"
        gitup_apt_plan_aside
    fi
    gitup_inner_class
    class="$REPLY"
    if [ "$class" = ubuntu ] && ! gitup_apt_adder_ok; then
        reason="$reason; the add-apt-repository here has no -n (--no-update) option, and without it apt would trust the key before it is checked"
    elif [ "$class" = ubuntu ]; then
        gitup_apt_plan_ppa "$reason" "$adopt"
        return
    fi
    gitup_source_pins || return 1
    gitup_apt_prepare || return 1
    if [ "$class" = debian ]; then reason="$reason; Debian has no PPA"; fi
    gitup_source_print_plan "$reason"
    gitup_plan_note "$GITUP_APT_UPGRADE_NOTE"
}

# ^ invariant the rebuild runs the PPA preflight of the upgrade; an unusable PPA gets its aside commands listed, an unreadable one refuses
gitup_apt_plan_refresh() {
    local rc first tmp
    local -a src=()
    first="${#GITUP_PRIV_CMDS[@]}"
    tmp="$(mktemp "${TMPDIR:-/tmp}/gsg-apt-plan.XXXXXX")" || return 1
    gitup_source_plan_refresh gitup_apt_prepare >"$tmp"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f -- "$tmp"
        return "$rc"
    fi
    gitup_apt_preflight
    case "$GITUP_APT_PRE_STATE" in
        unverifiable)
            printf "%s: %s\n" "$GSG_NAME" "$GITUP_APT_WHY" >&2
            GITUP_PRIV_CMDS=("${GITUP_PRIV_CMDS[@]:0:first}")
            rm -f -- "$tmp"
            return 2
            ;;
        mismatch)
            src=("${GITUP_PRIV_CMDS[@]:first}")
            GITUP_PRIV_CMDS=("${GITUP_PRIV_CMDS[@]:0:first}")
            GITUP_PRIV_BYHAND=0
            gitup_apt_plan_aside
            GITUP_PRIV_CMDS+=("${src[@]}")
            ;;
    esac
    cat -- "$tmp"
    rm -f -- "$tmp"
}

gitup_apt_plan() {
    GITUP_ROUTE=""
    case "$1" in
        upgrade) gitup_apt_plan_upgrade ;;
        refresh) gitup_apt_plan_refresh ;;
        *) return 1 ;;
    esac
}

# ^ security any failure removes only the PPA files this run added (both forms and the trusted.gpg.d key) and refreshes before any further root apt call
# ^ invariant success is proved by content too; an entry left in any sources file, a failed removal or a failed refresh is rc 1 with GITUP_APT_STUCK set
gitup_apt_ppa_disable() {
    local f g name
    local -a rm_list=()
    GITUP_APT_STUCK="" GITUP_APT_REMOVED=""
    gitup_apt_ppa_files
    for f in "${GITUP_APT_PPA_FILES[@]}" "${GITUP_APT_ADDED[@]}"; do
        if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
        for g in "${rm_list[@]}"; do
            if [ "$g" = "$f" ]; then continue 2; fi
        done
        rm_list+=("$f")
    done
    if [ "${#rm_list[@]}" -gt 0 ]; then
        gitup_elevate rm -f -- "${rm_list[@]}" || {
            GITUP_APT_STUCK="cannot remove the git-core PPA (rm failed on ${#rm_list[@]} file(s)); it may still be enabled, remove git-core-ubuntu-ppa-* from $GITUP_APT_SOURCES_DIR and the git-core PPA key files from $GITUP_APT_TRUSTED_DIR by hand"
            return 1
        }
        GITUP_APT_TOUCHED=1
    fi
    gitup_apt_ppa_files
    gitup_apt_foreign_entries
    for f in "${GITUP_APT_PPA_FILES[@]}" "${GITUP_APT_FOREIGN[@]}" "${GITUP_APT_ADDED[@]}"; do
        if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
        name="${f##*/}"
        GITUP_APT_STUCK="cannot remove the git-core PPA (${name//[^[:print:]]/?} still carries it after the removal); it may still be enabled, remove it by hand"
        return 1
    done
    for f in "${rm_list[@]}"; do GITUP_APT_REMOVED+="${GITUP_APT_REMOVED:+, }${f##*/}"; done
    if [ "$GITUP_APT_TOUCHED" -eq 1 ]; then
        gitup_apt_run_get update || {
            GITUP_APT_STUCK="removed ${GITUP_APT_REMOVED:-nothing} but apt could not refresh its lists; run apt-get update by hand"
            return 1
        }
    fi
    gitup_apt_unjudged_keys
    if [ "${#GITUP_APT_UNJUDGED[@]}" -gt 0 ]; then
        local done_text=""
        if [ -n "$GITUP_APT_REMOVED" ]; then done_text="removed ${GITUP_APT_REMOVED}"; fi
        if [ "$GITUP_APT_TOUCHED" -eq 1 ]; then done_text+="${done_text:+ and }refreshed apt"; fi
        GITUP_APT_STUCK="${done_text:+$done_text; }cannot tell whether ${GITUP_APT_UNJUDGED[*]} (new key file(s) that appeared while add-apt-repository ran) belong to the PPA; apt trusts them for every repository, they were left in place, remove them by hand if they do"
        return 1
    fi
}

gitup_apt_ppa_step_tools() {
    local need=0
    if ! gitup_system_bin add-apt-repository; then need=1; fi
    if ! gitup_system_bin gpg; then need=1; fi
    if [ "$need" -eq 1 ]; then
        gitup_apt_run_get update || {
            GITUP_APT_WHY="apt-get update failed before installing software-properties-common"
            return 1
        }
        gitup_apt_run_get install -y --no-install-recommends software-properties-common gnupg || {
            GITUP_APT_WHY="installing software-properties-common and gnupg failed"
            gitup_changed_add "the install of software-properties-common and gnupg was started and failed, so the package manager may have changed packages"
            return 1
        }
        gitup_changed_add "software-properties-common and gnupg were installed with apt"
    fi
    gitup_system_bin add-apt-repository || {
        GITUP_APT_WHY="add-apt-repository was not found in the system path ($GITUP_SYSTEM_PATH)"
        return 1
    }
    GITUP_APT_ADDER="$REPLY"
    gitup_apt_adder_ok || {
        GITUP_APT_WHY="the add-apt-repository here has no -n option, and without it apt would trust the key before it is checked"
        return 1
    }
}

# ^ order the clause and the pending flag are set before add-apt-repository runs => an interrupt inside it still reports and removes what it wrote
gitup_apt_ppa_step_add() {
    local rc=0
    GITUP_APT_PPA_PENDING=1
    gitup_changed_add "$GITUP_APT_ADDED_CLAUSE"
    gitup_apt_snapshot
    gitup_apt_cmd "$GITUP_APT_ADDER" -y -n "$GITUP_APT_PPA"
    gitup_elevate "${GITUP_APT_CMD[@]}" || rc=$?
    gitup_apt_added
    if [ "$rc" -ne 0 ]; then
        GITUP_APT_WHY="add-apt-repository failed"
        return 1
    fi
}

# ^ order the key check comes after add-apt-repository -n and before the first apt-get update able to trust the key
gitup_apt_ppa_step_key() {
    local rc=0
    gitup_apt_ppa_key_matches || rc=$?
    if [ "$rc" -ne 0 ]; then return 1; fi
    GITUP_APT_PPA_PENDING=0
    if [ "${#GITUP_APT_NEIGHBOURS[@]}" -gt 0 ]; then
        printf "%s: left alone, new files that appeared while add-apt-repository ran and are not the PPA's: %s\n" "$GSG_NAME" "${GITUP_APT_NEIGHBOURS[*]##*/}" >&2
    fi
}

gitup_apt_ppa_step_update() {
    GITUP_APT_TOUCHED=1
    gitup_apt_run_get update || {
        GITUP_APT_WHY="apt-get update failed with the PPA enabled (the release may not be carried by the PPA)"
        return 1
    }
}

# ^ invariant a PPA can exist and still lag; its candidate below 2.54 is a failure before any apt-get install
gitup_apt_ppa_step_floor() {
    gitup_apt_candidate || {
        GITUP_APT_WHY="the apt query for git failed after the update"
        return 1
    }
    if gitup_apt_floor_ok; then return 0; fi
    GITUP_APT_WHY="after the update $(gitup_apt_query_text), below 2.54 (a PPA can exist and still lag)"
    return 1
}

gitup_apt_ppa_step_install() {
    gitup_apt_run_get install -y --no-install-recommends git || {
        GITUP_APT_WHY="apt-get install git failed"
        gitup_changed_add "apt-get install git was started and failed, so the package manager may have changed packages (see dpkg -l git)"
        return 1
    }
}

# ^ invariant rc 1 = what this run added is gone and apt is refreshed (a fallback may follow), rc 2 = the PPA may still be enabled, nothing else runs as root
gitup_apt_ppa_fail() {
    local done_text=""
    if [ "$GITUP_APT_INTERRUPTED" -eq 1 ]; then
        printf "%s: the git-core PPA route was interrupted by a signal while the PPA was being added and checked\n" "$GSG_NAME" >&2
    else
        printf "%s: the git-core PPA route failed: %s\n" "$GSG_NAME" "$GITUP_APT_WHY" >&2
    fi
    if gitup_apt_ppa_disable; then
        GITUP_APT_PPA_PENDING=0
        gitup_changed_drop "$GITUP_APT_ADDED_CLAUSE"
        if [ -n "$GITUP_APT_REMOVED" ]; then done_text="the git-core PPA files this run added were removed again ($GITUP_APT_REMOVED)"; fi
        if [ "$GITUP_APT_TOUCHED" -eq 1 ]; then done_text+="${done_text:+, and }apt package lists were refreshed"; fi
        if [ -n "$done_text" ]; then
            gitup_changed_add "$done_text"
            printf "%s: %s\n" "$GSG_NAME" "$done_text" >&2
        fi
        return 1
    fi
    gitup_changed_drop "$GITUP_APT_ADDED_CLAUSE"
    gitup_changed_add "$GITUP_APT_STUCK"
    printf "%s: %s; no source build and no root apt install follow\n" "$GSG_NAME" "$GITUP_APT_STUCK" >&2
    return 2
}

# ^ invariant rc 0 = git came from the PPA; rc 1 = failed, only what this run added is removed; rc 2 = stop, nothing else may run as root
# ^ order tools, add-apt-repository -n, key check, apt-get update, floor check, apt-get install; a PPA kept from before skips the first three
gitup_apt_ppa_apply() {
    local step adopt=0
    local -a steps
    gitup_apt_init || return 1
    GITUP_APT_TOUCHED=0 GITUP_APT_PPA_PENDING=0 GITUP_APT_ADDED=() GITUP_APT_BEFORE=() GITUP_APT_NEIGHBOURS=() GITUP_APT_SNAPPED=0 GITUP_APT_INTERRUPTED=0
    gitup_apt_preflight
    case "$GITUP_APT_PRE_STATE" in
        unverifiable)
            printf '%s: %s\n' "$GSG_NAME" "$GITUP_APT_WHY" >&2
            return 2
            ;;
        mismatch)
            printf '%s: %s\n' "$GSG_NAME" "$GITUP_APT_WHY" >&2
            gitup_apt_ppa_set_aside || {
                printf '%s: %s; no source build and no root apt install follow\n' "$GSG_NAME" "$GITUP_APT_STUCK" >&2
                gitup_changed_add "$GITUP_APT_STUCK"
                return 2
            }
            printf '%s: the old git-core PPA files were moved aside to %s (kept)\n' "$GSG_NAME" "$GITUP_APT_ASIDE"
            ;;
        verified)
            adopt=1
            printf '%s: the git-core PPA already here carries the pinned key and is kept\n' "$GSG_NAME"
            ;;
    esac
    steps=(gitup_apt_ppa_step_tools gitup_apt_ppa_step_add gitup_apt_ppa_step_key gitup_apt_ppa_step_update gitup_apt_ppa_step_floor gitup_apt_ppa_step_install)
    if [ "$adopt" -eq 1 ]; then steps=(gitup_apt_ppa_step_update gitup_apt_ppa_step_floor gitup_apt_ppa_step_install); fi
    for step in "${steps[@]}"; do
        "$step" || {
            if [ "$adopt" -eq 1 ]; then
                printf '%s: the git-core PPA route failed: %s; the PPA that was already here is kept\n' "$GSG_NAME" "$GITUP_APT_WHY" >&2
                return 1
            fi
            gitup_apt_ppa_fail
            return $?
        }
    done
    gitup_changed_drop "$GITUP_APT_ADDED_CLAUSE"
    gitup_changed_add "git was installed from the git-core PPA ($GITUP_APT_PPA, key $GITUP_APT_PPA_FPR); the PPA stays enabled, so apt upgrade keeps git current"
}

gitup_apt_apply_package() {
    gitup_apt_run_get update || {
        gitup_changed_add "apt-get update was started and failed"
        return 1
    }
    gitup_apt_run_get install -y --no-install-recommends git || {
        gitup_changed_add "apt-get install git was started and failed, so the package manager may have changed packages (see dpkg -l git)"
        return 1
    }
    gitup_changed_add "apt installed git ${GITUP_APT_CANDIDATE_RAW:-}${GITUP_APT_CANDIDATE_ORIGIN:+ from $GITUP_APT_CANDIDATE_ORIGIN}"
    GITUP_NEW_GIT="$GITUP_USRBIN/git"
}

gitup_apt_apply_source() {
    gitup_apt_prepare || return 1
    gitup_source_apply || return 1
    GITUP_NEW_GIT="$GITUP_PREFIX/bin/git"
}

gitup_apt_apply_ppa() {
    local rc
    gitup_apt_ppa_apply
    rc=$?
    case "$rc" in
        0) GITUP_NEW_GIT="$GITUP_USRBIN/git" ;;
        1)
            printf '%s: falling back to the pinned source build\n' "$GSG_NAME"
            GITUP_ROUTE=source
            gitup_apt_apply_source
            ;;
        *) return 1 ;;
    esac
}

# ^ invariant package and source routes read the PPA state again; an unverifiable one stops them, one with another key is moved aside
gitup_apt_apply_checked() {
    gitup_apt_init || return 1
    gitup_apt_preflight
    case "$GITUP_APT_PRE_STATE" in
        unverifiable)
            printf "%s: %s\n" "$GSG_NAME" "$GITUP_APT_WHY" >&2
            return 1
            ;;
        mismatch)
            gitup_apt_ppa_set_aside || {
                printf "%s: %s\n" "$GSG_NAME" "$GITUP_APT_STUCK" >&2
                gitup_changed_add "$GITUP_APT_STUCK"
                return 1
            }
            printf "%s: the old git-core PPA files were moved aside to %s (kept)\n" "$GSG_NAME" "$GITUP_APT_ASIDE"
            ;;
    esac
}

gitup_apt_apply() {
    case "$GITUP_ROUTE" in
        package)
            gitup_apt_apply_checked || return 1
            gitup_apt_apply_package
            ;;
        ppa) gitup_apt_apply_ppa ;;
        source)
            gitup_apt_apply_checked || return 1
            gitup_apt_apply_source
            ;;
        *)
            printf '%s: the apt module has no route [%s] to apply\n' "$GSG_NAME" "$GITUP_ROUTE" >&2
            return 1
            ;;
    esac
}

# ^ invariant the core calls it once when the process ends inside apply; a PPA whose key was not yet checked loses the files this run added
# ^ security signals are ignored during the clean-up as in the takeover code => a second Ctrl-C cannot leave an unchecked PPA behind
gitup_apt_abort() {
    if [ "$GITUP_APT_PPA_PENDING" -ne 1 ]; then return 0; fi
    trap "" INT TERM HUP
    if [ "$GITUP_APT_SNAPPED" -eq 1 ]; then gitup_apt_added; fi
    GITUP_APT_INTERRUPTED=1
    gitup_apt_ppa_fail
    GITUP_APT_PPA_PENDING=0
    return 0
}
