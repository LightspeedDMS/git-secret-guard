#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# ^ order sourced by tests/lifecycle.sh before lc_begin runs => lc_apt_standins exists when lc_gitup_standins calls it
# ^ security every apt tool the upgrade reaches is a recording stand-in first on PATH => no test touches the real apt

# ^ invariant the stand-ins log their arguments to $SANDBOX/gitup.log and touch only files below $SANDBOX/root (the sandbox / for GSG_GITUP_ROOT)
# ^ invariant they answer from files beside them (apt.candidate, apt.origin, apt.form, apt.add.*, apt.update.fail, apt.fail, apt.cache.*)
# ^ why printf, not echo; Ubuntu's /bin/sh is dash and its echo turns a backslash into a newline
lc_apt_standins() {
    cat >"$SANDBOX/pathbin/apt-get" <<'EOF' || return 1
#!/bin/sh
d="$(cd "${0%/*}/.." && pwd -P)" || exit 1
root="$d/root"
sub="" skip=0
for a in "$@"; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$a" in -o) skip=1 ;; -*) ;; *) if [ -z "$sub" ]; then sub="$a"; fi ;; esac
done
n="$(ls "$root"/etc/apt/sources.list.d/git-core-ubuntu-ppa-* 2>/dev/null | wc -l | tr -d ' ')"
k="$(ls "$root"/etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg* 2>/dev/null | wc -l | tr -d ' ')"
# ^ invariant a PPA entry counts only when a non-comment line names it and its file does not say Enabled: no, as apt reads it
act=0
for f in "$root"/etc/apt/sources.list.d/*.list "$root"/etc/apt/sources.list.d/*.sources; do
    if [ ! -f "$f" ]; then continue; fi
    if grep -v '^[[:space:]]*#' "$f" | grep -qi 'git-core/ppa' && ! grep -qi '^enabled:[[:space:]]*no' "$f"; then act=$((act + 1)); fi
done
printf 'apt-get %s | ppa-files=%s ppa-keys=%s frontend=%s\n' "$*" "$n" "$k" "${DEBIAN_FRONTEND:-unset}" >>"$d/gitup.log"
case "$sub" in
    update | install)
        if [ "${DEBIAN_FRONTEND:-}" != noninteractive ]; then printf 'E: the stand-in would stop at a debconf prompt\n' >&2; exit 100; fi
        ;;
esac
if [ "$sub" = install ]; then
    case " $* " in *" -y "*) ;; *) printf 'E: the stand-in would stop at Do you want to continue\n' >&2; exit 100 ;; esac
fi
if [ -f "$d/apt.fail" ]; then
    case " $* " in *"$(cat "$d/apt.fail")"*) printf 'E: injected apt-get failure\n' >&2; exit 100 ;; esac
fi
case "$sub" in
    update)
        if [ -f "$d/apt.update.fail" ]; then
            case "$(cat "$d/apt.update.fail")" in
                ppa) if [ "$n" -gt 0 ]; then printf 'E: the repository has no Release file\n' >&2; exit 100; fi ;;
                clean) if [ "$n" -eq 0 ]; then printf 'E: injected clean update failure\n' >&2; exit 100; fi ;;
                *) printf 'E: injected update failure\n' >&2; exit 100 ;;
            esac
        fi
        if [ "$act" -gt 0 ]; then : >"$d/apt.ppa.listed"; else rm -f "$d/apt.ppa.listed"; fi
        exit 0
        ;;
    install)
        case " $* " in
            *" software-properties-common "*)
                for t in "$d"/apt.sps-template/*; do
                    if [ -f "$t" ]; then cp -- "$t" "$d/pathbin/${t##*/}"; fi
                done
                exit 0
                ;;
            *" git "*)
                c="$(cat "$d/apt.candidate" 2>/dev/null || true)"
                if [ -f "$d/apt.ppa.listed" ] && [ -f "$d/apt.ppa.candidate" ]; then c="$(cat "$d/apt.ppa.candidate")"; fi
                c="${c#*:}"
                c="${c%%-*}"
                printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version %s"; exit 0; fi\nexec %s "$@"\n' "$c" "$(cat "$d/real-git")" >"$d/pathbin/git" || exit 1
                chmod 755 "$d/pathbin/git"
                exit 0
                ;;
        esac
        exit 0
        ;;
esac
printf 'E: the apt-get stand-in does not know the call [%s]\n' "$*" >&2
exit 1
EOF
    cat >"$SANDBOX/pathbin/apt-cache" <<'EOF' || return 1
#!/bin/sh
d="$(cd "${0%/*}/.." && pwd -P)" || exit 1
printf 'apt-cache %s | locale=%s\n' "$*" "${LC_ALL:-unset}" >>"$d/gitup.log"
if [ -t 0 ]; then printf 'query-stdin-is-a-terminal\n' >>"$d/gitup.log"; fi
if [ -f "$d/apt.hang" ]; then exec sleep 60; fi
if [ -f "$d/apt.cache.fail" ]; then printf 'E: injected apt-cache failure\n' >&2; exit 100; fi
if [ -f "$d/apt.cache.failafter" ] && [ -f "$d/apt.ppa.listed" ]; then printf 'E: injected apt-cache failure after the update\n' >&2; exit 100; fi
if [ "$*" != "policy git" ]; then printf 'E: the apt-cache stand-in does not know the call [%s]\n' "$*" >&2; exit 1; fi
c="(none)"
if [ -f "$d/apt.candidate" ]; then c="$(cat "$d/apt.candidate")"; fi
if [ -f "$d/apt.ppa.listed" ] && [ -f "$d/apt.ppa.candidate" ]; then c="$(cat "$d/apt.ppa.candidate")"; fi
origin="http://archive.ubuntu.com/ubuntu jammy-updates/main"
if [ -f "$d/apt.ppa.listed" ]; then origin="https://ppa.launchpadcontent.net/git-core/ppa/ubuntu noble/main"; fi
if [ -f "$d/apt.origin" ]; then origin="$(cat "$d/apt.origin")"; fi
label="Candidate:"
if [ "${LC_ALL:-}" != C ]; then label="Kandidat:"; fi
printf 'git:\n  Installed: 1:2.34.1-1ubuntu1.5\n  %s %s\n  Version table:\n     %s 500\n        500 %s amd64 Packages\n' "$label" "$c" "$c" "$origin"
exit 0
EOF
    cat >"$SANDBOX/pathbin/add-apt-repository" <<'EOF' || return 1
#!/bin/sh
d="$(cd "${0%/*}/.." && pwd -P)" || exit 1
root="$d/root"
n="$(ls "$root"/etc/apt/sources.list.d/git-core-ubuntu-ppa-* 2>/dev/null | wc -l | tr -d ' ')"
printf 'add-apt-repository %s | ppa-files=%s\n' "$*" "$n" >>"$d/gitup.log"
if [ "$*" = "--help" ]; then
    if [ -f "$d/apt.add.nonopt" ]; then printf 'usage: add-apt-repository [-h] [-y] [-r] ppa\n'; else printf 'usage: add-apt-repository [-h] [-d] [-y] [-n] [--no-update] ppa\n  -n, --no-update  do not update the package cache after adding\n'; fi
    exit 0
fi
if [ -f "$d/apt.add.nonopt" ]; then printf 'add-apt-repository: error: unrecognized arguments: -n\n' >&2; exit 2; fi
if [ "$*" != "-y -n ppa:git-core/ppa" ]; then printf 'E: the add-apt-repository stand-in expects -y -n ppa:git-core/ppa, got [%s]\n' "$*" >&2; exit 1; fi
# ^ invariant like software-properties 0.99.22 an entry that exists is kept, and the key is imported into the existing keyring (a merge, never an overwrite)
if [ ! -f "$d/apt.add.nowrite" ]; then
    form="sources"
    if [ -f "$d/apt.form" ]; then form="$(cat "$d/apt.form")"; fi
    mkdir -p "$root/etc/apt/sources.list.d" "$root/etc/apt/trusted.gpg.d" || exit 1
    for f in "$d/apt.fixture/$form/sources.list.d"/*; do
        if [ -f "$f" ] && [ ! -e "$root/etc/apt/sources.list.d/${f##*/}" ]; then cp -- "$f" "$root/etc/apt/sources.list.d/"; fi
    done
    for f in "$d/apt.fixture/$form/trusted.gpg.d"/*; do
        if [ ! -f "$f" ]; then continue; fi
        dest="$root/etc/apt/trusted.gpg.d/${f##*/}"
        if [ ! -e "$dest" ]; then cp -- "$f" "$dest"; continue; fi
        while IFS= read -r line; do
            if ! grep -qxF -- "$line" "$dest"; then printf '%s\n' "$line" >>"$dest"; fi
        done <"$f"
    done
    if [ -f "$d/apt.add.extra" ]; then
        if [ -s "$d/apt.add.extra" ]; then cp -- "$d/apt.add.extra" "$root/etc/apt/sources.list.d/git-core-ppa-extra.list"; else printf 'deb https://ppa.launchpadcontent.net/git-core/ppa/ubuntu jammy main\n' >"$root/etc/apt/sources.list.d/git-core-ppa-extra.list"; fi
    fi
fi
if [ -f "$d/apt.add.lock" ]; then chmod 555 "$root/etc/apt/sources.list.d"; fi
if [ -f "$d/apt.add.hang" ]; then : >"$d/apt.add.started"; exec sleep 60; fi
if [ -f "$d/apt.add.rc" ]; then exit "$(cat "$d/apt.add.rc")"; fi
exit 0
EOF
    # ^ invariant gpg reads one STUBKEY:FINGERPRINT line per key from stdin and prints the colon records the real gpg prints for it
    # ^ external the real colon format is proved by test_real_gpg_reads_the_fingerprint_of_both_ppa_file_forms
    cat >"$SANDBOX/pathbin/gpg" <<'EOF' || return 1
#!/bin/sh
d="$(cd "${0%/*}/.." && pwd -P)" || exit 1
if [ -d "${GNUPGHOME:-/nonexistent}" ]; then g=scratch-home; else g=no-home; fi
printf 'gpg %s | %s\n' "$*" "$g" >>"$d/gitup.log"
if [ "$*" != "--batch --show-keys --with-colons" ]; then printf 'gpg: the stand-in does not know the call [%s]\n' "$*" >&2; exit 2; fi
while IFS= read -r line; do
    case "$line" in
        STUBGARBAGE*) garbage=1 ;;
        STUBKEY:*) keys=1; printf 'pub:-:255:22:0000000000000000:1:::-:::scESC::::::23::0:\nfpr:::::::::%s:\nsub:-:255:18:1111111111111111:1:::::e::::::23:\nfpr:::::::::%s:\n' "${line#STUBKEY:}" "SUBKEYFPR${line#STUBKEY:}" ;;
    esac
done
if [ -n "${garbage:-}" ] || [ -z "${keys:-}" ]; then printf 'gpg: no valid OpenPGP data found\n' >&2; exit 2; fi
exit 0
EOF
    chmod 755 "$SANDBOX/pathbin/apt-get" "$SANDBOX/pathbin/apt-cache" "$SANDBOX/pathbin/add-apt-repository" "$SANDBOX/pathbin/gpg"
}

# ^ invariant gu_apt_fixture FORM [FINGERPRINT] writes the files add-apt-repository leaves in the sandbox for the release family FORM
# ^ invariant real layouts, seen on 24.04 (sources), 22.04 (list, with the .gpg~ backup gpg leaves) and 20.04 (focal, underscore key name and http host)
gu_apt_fixture() {
    local form="$1" fpr="${2:-F911AB184317630C59970973E363C90F8F1B6217}" dir="$SANDBOX/apt.fixture/$1"
    [[ -n $SANDBOX && $SANDBOX == /* && $form =~ ^[a-z]+$ ]] || return 1
    rm -rf -- "$SANDBOX/apt.fixture/$form" && mkdir -p -- "$dir/sources.list.d" "$dir/trusted.gpg.d" || return 1
    case "$form" in
        sources)
            printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/git-core/ppa/ubuntu/\nSuites: noble\nComponents: main\nSigned-By:\n -----BEGIN PGP PUBLIC KEY BLOCK-----\n .\n STUBKEY:%s\n .\n -----END PGP PUBLIC KEY BLOCK-----\n' \
                "$fpr" >"$dir/sources.list.d/git-core-ubuntu-ppa-noble.sources" || return 1
            ;;
        list)
            printf 'deb https://ppa.launchpadcontent.net/git-core/ppa/ubuntu jammy main\n# deb-src https://ppa.launchpadcontent.net/git-core/ppa/ubuntu jammy main\n' \
                >"$dir/sources.list.d/git-core-ubuntu-ppa-jammy.list" || return 1
            printf 'STUBKEY:%s\n' "$fpr" >"$dir/trusted.gpg.d/git-core-ubuntu-ppa.gpg" || return 1
            : >"$dir/trusted.gpg.d/git-core-ubuntu-ppa.gpg~" || return 1
            ;;
        focal)
            printf 'deb http://ppa.launchpad.net/git-core/ppa/ubuntu focal main\n# deb-src http://ppa.launchpad.net/git-core/ppa/ubuntu focal main\n' \
                >"$dir/sources.list.d/git-core-ubuntu-ppa-focal.list" || return 1
            printf 'STUBKEY:%s\n' "$fpr" >"$dir/trusted.gpg.d/git-core_ubuntu_ppa.gpg" || return 1
            ;;
        *) return 1 ;;
    esac
    printf '%s' "$form" >"$SANDBOX/apt.form"
}

# ^ invariant gu_apt_without_sps moves add-apt-repository and gpg off the sandbox PATH; apt-get puts them back with software-properties-common
gu_apt_without_sps() {
    mkdir -p -- "$SANDBOX/apt.sps-template" && mv -- "$SANDBOX/pathbin/add-apt-repository" "$SANDBOX/pathbin/gpg" "$SANDBOX/apt.sps-template/"
}

# ^ invariant gu_apt_setup [OLD [ID [CANDIDATE [PPA_CANDIDATE]]]] leaves an apt machine with git OLD, the distribution offering CANDIDATE and the PPA 2.56.0
# ^ invariant the PPA files appear only when add-apt-repository runs, and the PPA candidate shows only after an apt-get update with them present
gu_apt_setup() {
    gu_rpm_setup "${1:-2.34.1}" || return 1
    gu_os_release "ID=${2:-ubuntu}" 'ID_LIKE=debian' || return 1
    mkdir -p -- "$GU_ROOT/etc/apt/sources.list.d" "$GU_ROOT/etc/apt/trusted.gpg.d" || return 1
    printf '%s\n' "${3:-1:2.34.1-1ubuntu1.11}" >"$SANDBOX/apt.candidate" || return 1
    printf '%s\n' "${4:-1:2.56.0-0ppa1~ubuntu22.04.1}" >"$SANDBOX/apt.ppa.candidate" || return 1
    gu_apt_fixture sources
}

# ^ invariant gu_apt_preexisting FORM [FINGERPRINT] puts the files of FORM into the sandbox /etc/apt as if the user had set the PPA up before this run
gu_apt_preexisting() {
    gu_apt_fixture "$@" || return 1
    cp -- "$SANDBOX/apt.fixture/$1/sources.list.d"/* "$GU_ROOT/etc/apt/sources.list.d/" || return 1
    cp -- "$SANDBOX/apt.fixture/$1/trusted.gpg.d"/* "$GU_ROOT/etc/apt/trusted.gpg.d/" 2>/dev/null || true
}
