#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# ^ order sourced after tests/lib.sh and before run_file_tests => configure_hook is a no-op when sandbox_create runs
# ^ security HOME, XDG_*, GIT_CONFIG_GLOBAL and PATH all point into the sandbox => no lifecycle test touches the real ~/.gitconfig, ~/.local or ~/.config

configure_hook() { :; }

LC_ENV=()
# shellcheck disable=SC2034
LC_HOME="" LC_BIN="" LC_DATA="" LC_STATE="" LC_FIX=""

# ^ security the stand-in records its arguments and touches nothing else => no lifecycle test can reach a real user systemd manager
# ^ coupled with lc_begin and lc_path_without; both put this file first on every PATH a lifecycle test uses
lc_systemctl_standin() {
    cat >"$SANDBOX/pathbin/systemctl" <<'EOF' || return 1
#!/bin/sh
d="${0%/*}/.."
echo "$*" >>"$d/systemctl.log"
if [ -f "$d/systemctl.fail" ]; then
    want="$(cat "$d/systemctl.fail")"
    case " $* " in *"$want"*) echo "Failed: injected systemctl failure" >&2; exit 1 ;; esac
fi
exit 0
EOF
    chmod 755 "$SANDBOX/pathbin/systemctl"
}

# ^ security the stand-in records its arguments and touches only files beside it => no lifecycle test can reach the real launchd
# ^ invariant bootstrap marks the agent loaded, bootout unloads it, print fails with 113 until the agent is loaded; an unmodeled subcommand fails loudly
lc_launchctl_standin() {
    cat >"$SANDBOX/pathbin/launchctl" <<'EOF' || return 1
#!/bin/sh
d="${0%/*}/.."
echo "$*" >>"$d/launchctl.log"
for kind in fail failonce; do
    if [ -f "$d/launchctl.$kind" ]; then
        want="$(cat "$d/launchctl.$kind")"
        case " $* " in *"$want"*)
            if [ "$kind" = failonce ]; then rm -f "$d/launchctl.failonce"; fi
            echo "Failed: injected launchctl failure" >&2
            exit 1 ;;
        esac
    fi
done
case "$1" in
    print) [ -f "$d/launchctl.loaded" ] || { echo "Could not find service" >&2; exit 113; } ;;
    bootstrap) : >"$d/launchctl.loaded" ;;
    bootout) rm -f "$d/launchctl.loaded" ;;
    *) echo "Error: the launchctl stand-in does not know the subcommand [$1]" >&2; exit 1 ;;
esac
exit 0
EOF
    chmod 755 "$SANDBOX/pathbin/launchctl"
}

# ^ security these stand-ins log their arguments to $SANDBOX/gitup.log and touch only sandbox files => no lifecycle test runs a real sudo, dnf or restorecon
# ^ invariant sudo runs the given command as the test user; dnf answers from files beside it (dnf.candidate, dnf.repos) and fails loudly on an unmodeled call
lc_gitup_standins() {
    local tool src dir
    cat >"$SANDBOX/pathbin/sudo" <<'EOF' || return 1
#!/bin/sh
d="$(cd "${0%/*}/.." && pwd -P)" || exit 1
printf 'sudo %s\n' "$*" >>"$d/gitup.log"
if [ -f "$d/sudo.stall" ]; then
    case " $* " in
        *"$(cat "$d/sudo.stall")"*)
            stallskip=0
            if [ -f "$d/sudo.stallskip" ]; then stallskip="$(cat "$d/sudo.stallskip")"; fi
            if [ "$stallskip" -gt 0 ]; then
                echo $((stallskip - 1)) >"$d/sudo.stallskip"
            else
                rm -f "$d/sudo.stall" "$d/sudo.stallskip"
                : >"$d/sudo.stalled"
                exec sleep 30
            fi
            ;;
    esac
fi
if [ -f "$d/sudo.fail" ]; then
    echo "sudo: injected failure" >&2
    exit 1
fi
if [ -f "$d/sudo.failon" ]; then
    case " $* " in
        *"$(cat "$d/sudo.failon")"*)
            skip=0
            if [ -f "$d/sudo.skip" ]; then skip="$(cat "$d/sudo.skip")"; fi
            if [ "$skip" -gt 0 ]; then
                echo $((skip - 1)) >"$d/sudo.skip"
            else
                rm -f "$d/sudo.failon" "$d/sudo.skip"
                echo "sudo: injected one-shot failure" >&2
                exit 1
            fi
            ;;
    esac
fi
if [ "$1" = "--" ]; then shift; fi
exec "$@"
EOF
    cat >"$SANDBOX/pathbin/rpm" <<'EOF' || return 1
#!/bin/sh
d="$(cd "${0%/*}/.." && pwd -P)" || exit 1
printf 'rpm %s\n' "$*" >>"$d/gitup.log"
answer() { if [ -f "$d/$1" ]; then cat "$d/$1"; exit 0; fi; echo "error: the rpm stand-in has no $1" >&2; exit 1; }
case "$*" in
    "-qf --qf %{NAME}\n -- "*) if [ -f "$d/rpm.owner" ]; then cat "$d/rpm.owner"; exit 0; fi; echo "file $5 is not owned by any package" >&2; exit 1 ;;
    "-q --qf %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n git-core") answer rpm.nevra ;;
    "-ql git-core") answer rpm.files ;;
    "-q --qf %{SOURCERPM}\n git-core") answer rpm.srpm ;;
    "-qa --qf %{NAME} %{SOURCERPM}\n") answer rpm.all ;;
    "-V git-core") if [ -f "$d/rpm.verify" ]; then cat "$d/rpm.verify"; fi; exit 0 ;;
esac
echo "Error: the rpm stand-in does not know the call [$*]" >&2
exit 1
EOF
    cat >"$SANDBOX/pathbin/dnf" <<'EOF' || return 1
#!/bin/sh
d="$(cd "${0%/*}/.." && pwd -P)" || exit 1
printf 'dnf %s\n' "$*" >>"$d/gitup.log"
case " $* " in *" repoquery "* | *" repolist "*) if [ -t 0 ]; then echo "query-stdin-is-a-terminal" >>"$d/gitup.log"; fi ;; esac
if [ -f "$d/dnf.fail" ]; then
    case " $* " in *"$(cat "$d/dnf.fail")"*) echo "Error: injected dnf failure" >&2; exit 1 ;; esac
fi
repo=""
for a in "$@"; do
    case "$a" in --enablerepo=*) repo="${a#--enablerepo=}" ;; esac
done
case " $* " in
    *" repoquery "*)
        if [ -f "$d/dnf.hang" ] && { [ -z "$repo" ] || [ "$repo" = "$(cat "$d/dnf.hang")" ] || [ "$(cat "$d/dnf.hang")" = "*" ]; }; then exec sleep 60; fi
        if [ -f "$d/dnf.badrepo" ] && { [ -z "$repo" ] || [ "$repo" = "$(cat "$d/dnf.badrepo")" ]; }; then
            echo "Importing GPG key 0xDEADBEEF: Is this ok [y/N]: Operation aborted." >&2
            exit 1
        fi
        if [ -f "$d/dnf.candidate" ]; then cat "$d/dnf.candidate"; fi
        exit 0
        ;;
    *" repolist "*)
        echo "repo id    repo name"
        if [ -f "$d/dnf.repos" ]; then cat "$d/dnf.repos"; fi
        exit 0
        ;;
    *" install "* | *" upgrade "*)
        # ^ invariant dnf.upgrade_to names the version a package upgrade brings; the git on the sandbox PATH then reports it and runs the real git
        if [ -f "$d/dnf.upgrade_to" ]; then
            printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version %s"; exit 0; fi\nexec %s "$@"\n' "$(cat "$d/dnf.upgrade_to")" "$(cat "$d/real-git")" >"$d/pathbin/git" || exit 1
            chmod 755 "$d/pathbin/git"
        fi
        exit 0
        ;;
esac
echo "Error: the dnf stand-in does not know the call [$*]" >&2
exit 1
EOF
    cat >"$SANDBOX/pathbin/restorecon" <<'EOF' || return 1
#!/bin/sh
d="$(cd "${0%/*}/.." && pwd -P)" || exit 1
printf 'restorecon %s\n' "$*" >>"$d/gitup.log"
exit 0
EOF
    cat >"$SANDBOX/pathbin/make" <<'EOF' || return 1
#!/bin/sh
d="$(cd "${0%/*}/.." && pwd -P)" || exit 1
printf 'make %s\n' "$*" >>"$d/gitup.log"
{ echo "PATH=$PATH"; env | cut -d= -f1 | LC_ALL=C sort | tr '\n' ' '; echo; echo "cwd=$(pwd)"; } >>"$d/make.env"
if [ -f "$d/make.hang" ]; then : >"$d/make.started"; exec sleep 60; fi
if [ -f "$d/make.fail" ]; then echo "make: *** injected failure" >&2; exit 2; fi
destdir="" prefix=""
for a in "$@"; do
    case "$a" in DESTDIR=*) destdir="${a#DESTDIR=}" ;; prefix=*) prefix="${a#prefix=}" ;; esac
done
case " $* " in
    *" install "*)
        ver="$(cat "$d/make.version" 2>/dev/null || echo 2.56.0)"
        b="$destdir$prefix/bin"
        mkdir -p "$b" "$destdir$prefix/libexec/git-core" "$destdir$prefix/share/man/man1" || exit 1
        real="$(cat "$d/real-git")"
        printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version %s"; exit 0; fi\ncase " $* " in *" commit "*) if [ -f "%s/newgit.broken" ]; then exit 0; fi ;; esac\nexec %s "$@"\n' \
            "$ver" "$d" "$real" >"$b/git" || exit 1
        chmod 755 "$b/git" || exit 1
        for s in receive-pack upload-pack upload-archive; do
            printf '#!/bin/sh\nexec %s %s "$@"\n' "$real" "$s" >"$b/git-$s" || exit 1
            chmod 755 "$b/git-$s" || exit 1
        done
        for s in git-shell scalar; do
            printf '#!/bin/sh\nexit 0\n' >"$b/$s" || exit 1
            chmod 755 "$b/$s" || exit 1
        done
        ln -f "$b/git" "$destdir$prefix/libexec/git-core/git" || exit 1
        echo "built by the make stand-in" >"$destdir$prefix/libexec/git-core/git-stand-in-helper"
        echo "man page of the make stand-in" >"$destdir$prefix/share/man/man1/git.1"
        ;;
esac
exit 0
EOF
    cat >"$SANDBOX/pathbin/df" <<'EOF' || return 1
#!/bin/sh
d="$(cd "${0%/*}/.." && pwd -P)" || exit 1
if [ -f "$d/df.avail" ]; then
    echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
    echo "fake 1000000 1 $(cat "$d/df.avail") 1% /"
    exit 0
fi
for real in /usr/bin/df /bin/df; do
    if [ -x "$real" ]; then exec "$real" "$@"; fi
done
exit 1
EOF
    cat >"$SANDBOX/pathbin/ldd" <<'EOF' || return 1
#!/bin/sh
d="$(cd "${0%/*}/.." && pwd -P)" || exit 1
printf 'ldd %s\n' "$*" >>"$d/gitup.log"
if [ -f "$d/ldd.out" ]; then
    if [ ! -f "$d/ldd.only" ]; then cat "$d/ldd.out"; exit 0; fi
    case "$1" in *"$(cat "$d/ldd.only")"*) cat "$d/ldd.out"; exit 0 ;; esac
fi
echo "	not a dynamic executable" >&2
exit 1
EOF
    chmod 755 "$SANDBOX/pathbin/sudo" "$SANDBOX/pathbin/dnf" "$SANDBOX/pathbin/restorecon" "$SANDBOX/pathbin/make" "$SANDBOX/pathbin/df" "$SANDBOX/pathbin/ldd" "$SANDBOX/pathbin/rpm" || return 1
    # ^ why exec wrappers, not symlinks or copies; gitup_system_bin wants a regular file owned by the test user, and macOS kills a copied system binary
    # ^ why TEST_BASE_PATH, not /usr/bin; on macOS the GNU directory comes first, and the install needs GNU mv -T
    local -a base_dirs
    IFS=: read -r -a base_dirs <<<"$TEST_BASE_PATH"
    for tool in cp rm mv mkdir install ln rmdir touch; do
        src=""
        for dir in "${base_dirs[@]}"; do
            if [ -x "$dir/$tool" ]; then
                src="$dir/$tool"
                break
            fi
        done
        if [ -z "$src" ]; then
            printf 'lc_gitup_standins: no %s on TEST_BASE_PATH (%s)\n' "$tool" "$TEST_BASE_PATH" >&2
            return 1
        fi
        printf '#!/bin/sh\nexec %s "$@"\n' "$src" >"$SANDBOX/pathbin/$tool" || return 1
        chmod 755 "$SANDBOX/pathbin/$tool" || return 1
    done
    printf '%s' "$GIT" >"$SANDBOX/real-git"
}

# ^ invariant the fake uname answers these; lc_platform builds the fixture rows for the same platform the CLI will ask about
LC_FAKE_OS="" LC_FAKE_ARCH=""
# ^ invariant the suffix of a tool file under test; lc_begin sets it per platform, a faked uname clears it
LC_EXE=""

# ^ security the stand-in only links files inside $SANDBOX/brewprefix => no lifecycle test can run a real brew install
# ^ invariant brew.map lines are formula|path under the prefix|source; install links what it is given, brew.fail fails it, brew.nopopulate makes it do nothing
# ^ invariant an unmapped formula or an unknown subcommand fails loudly => a test never passes on a call the stand-in cannot answer
lc_brew_standin() {
    cat >"$SANDBOX/pathbin/brew" <<'EOF' || return 1
#!/bin/sh
d="$(cd "${0%/*}/.." && pwd -P)" || exit 1
echo "$*" >>"$d/brew.log"
case "$1" in
    --prefix)
        echo "$d/brewprefix"
        exit 0
        ;;
    install)
        fail_install=0
        if [ -f "$d/brew.fail" ]; then fail_install=1; fi
        if [ -f "$d/brew.failon" ]; then
            case " $* " in *"$(cat "$d/brew.failon")"*) fail_install=1 ;; esac
        fi
        if [ "$fail_install" -eq 1 ]; then
            echo "Error: injected brew failure" >&2
            exit 1
        fi
        shift
        if [ -f "$d/brew.nopopulate" ]; then exit 0; fi
        for f in "$@"; do
            found=0
            while IFS='|' read -r formula dest src; do
                [ "$formula" = "$f" ] || continue
                found=1
                if [ -d "$src" ]; then
                    mkdir -p "$d/brewprefix/$dest" || exit 1
                    for entry in "$src"/*; do
                        case "${entry##*/}" in uname) continue ;; esac
                        ln -sfn "$entry" "$d/brewprefix/$dest/" || exit 1
                    done
                    continue
                fi
                mkdir -p "$d/brewprefix/$(dirname "$dest")" && ln -sfn "$src" "$d/brewprefix/$dest" || exit 1
            done <"$d/brew.map"
            if [ "$found" -eq 0 ]; then
                echo "Error: no brew.map entry for $f" >&2
                exit 1
            fi
        done
        exit 0
        ;;
esac
echo "Error: the brew stand-in does not know the subcommand [$1]" >&2
exit 1
EOF
    chmod 755 "$SANDBOX/pathbin/brew" || return 1
    lc_brew_map
}

# ^ external macOS keeps GNU coreutils in one gnubin directory, Linux has them on PATH already; the fake prefix links only what the tests need
lc_brew_map() {
    {
        if [ "$TEST_OS" = Darwin ]; then
            printf '%s\n' "bash|bin/bash|$TEST_BASH" "coreutils|opt/coreutils/libexec/gnubin|$TEST_GNUBIN"
        else
            printf '%s\n' "bash|bin/bash|$BASH" "coreutils|opt/coreutils/libexec/gnubin/timeout|$TEST_TIMEOUT"
        fi
        printf '%s\n' "util-linux|opt/util-linux/bin/setsid|${TEST_SETSID:-$TEST_TRUE}" "jq|bin/jq|$TEST_JQ"
    } >"$SANDBOX/brew.map"
}

lc_brew_reset() { rm -rf -- "$SANDBOX/brewprefix" "$SANDBOX/brew.log" "$SANDBOX/brew.fail" "$SANDBOX/brew.failon" "$SANDBOX/brew.nopopulate" && mkdir -p -- "$SANDBOX/brewprefix"; }

# ^ invariant populates the fake prefix with the given formulae and leaves brew.log absent; a test sees only the calls install makes
lc_brew_have() {
    "$SANDBOX/pathbin/brew" install "$@" || return 1
    rm -f -- "$SANDBOX/brew.log"
}

# ^ coupled lc_platform reads LC_FAKE_OS and LC_FAKE_ARCH; the CLI reads the same answers through the fake uname on PATH
# ^ invariant the fake answers -s and -m only and fails loudly on anything else; its two values are plain words, they are written into a script
lc_fake_uname() {
    LC_EXE=""
    if [[ ! $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || [[ ! $2 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        printf 'lc_fake_uname: [%s] [%s] are not plain words\n' "$1" "$2" >&2
        return 1
    fi
    LC_FAKE_OS="$1" LC_FAKE_ARCH="$2"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\ncase "$1" in\n    -s) echo %s ;;\n    -m) echo %s ;;\n    *) echo "Error: the uname stand-in does not know [$*]" >&2; exit 1 ;;\nesac\n' \
        "$1" "$2" >"$SANDBOX/pathbin/uname" || return 1
    chmod 755 "$SANDBOX/pathbin/uname"
}

lc_real_uname() {
    LC_FAKE_OS="" LC_FAKE_ARCH=""
    rm -f -- "$SANDBOX/pathbin/uname"
}

# ^ external on a Mac these run against the real uname (lc_begin installed a fake Linux one, lc_real_uname removes it); elsewhere a fake uname says Darwin
as_macos() {
    if [ "$TEST_OS" = Darwin ]; then lc_real_uname; else lc_fake_uname Darwin arm64; fi
}

lc_begin() {
    LC_HOME="$SANDBOX/home"
    LC_BIN="$LC_HOME/.local/bin"
    LC_FIX="$SANDBOX/fixtures"
    LC_DATA="$SANDBOX/xdg/data/git-secret-guard"
    LC_STATE="$SANDBOX/xdg/state/git-secret-guard"
    LC_FAKE_OS="" LC_FAKE_ARCH="" LC_EXE=""
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then LC_EXE=.exe; fi
    rm -rf -- "$LC_HOME" "$SANDBOX/xdg" "$SANDBOX/pathbin" "$LC_FIX" "$SANDBOX/systemctl.log" "$SANDBOX/systemctl.fail" \
        "$SANDBOX/launchctl.log" "$SANDBOX/launchctl.fail" "$SANDBOX/launchctl.failonce" "$SANDBOX/launchctl.loaded" "$SANDBOX/brew.map" \
        "$SANDBOX"/gitup.log "$SANDBOX"/sudo.fail "$SANDBOX"/dnf.* "$SANDBOX"/make.* "$SANDBOX"/rpm.* "$SANDBOX"/sudo.failon "$SANDBOX"/sudo.skip "$SANDBOX"/newgit.broken "$SANDBOX"/df.avail "$SANDBOX"/ldd.out "$SANDBOX/root" "$SANDBOX/os-release" || return 1
    mkdir -p -- "$LC_HOME" "$SANDBOX/xdg/data" "$SANDBOX/xdg/state" "$SANDBOX/pathbin" || return 1
    lc_brew_reset || return 1
    lc_systemctl_standin || return 1
    lc_launchctl_standin || return 1
    lc_brew_standin || return 1
    lc_gitup_standins || return 1
    # ^ why a neutral distribution by default, not the host's; on Rocky the real os-release would route every old-git test into the RPM upgrade offer
    printf 'ID=gsgtestos\n' >"$SANDBOX/os-release" || return 1
    lc_brew_have bash coreutils util-linux jq || return 1
    # ^ why the Linux flow by default on a Mac, not the real Darwin one; tests/test_macos.sh opts into Darwin with lc_real_uname
    if [ "$TEST_OS" = Darwin ]; then lc_fake_uname Linux "$(uname -m)" || return 1; fi
    : >"$SANDBOX/gitconfig" || return 1
    EXTRA_ENV=()
    LC_ENV=("${GSG_ENV[@]}" PATH="$SANDBOX/pathbin:$TEST_BASE_PATH"
        XDG_DATA_HOME="$SANDBOX/xdg/data" XDG_STATE_HOME="$SANDBOX/xdg/state" GSG_OS_RELEASE="$SANDBOX/os-release"
        GSG_GITUP_BUILD_PATH="$SANDBOX/pathbin")
    gitx config --global user.name "Test User" || return 1
    gitx config --global user.email "test@example.invalid" || return 1
    gitx config --global commit.gpgsign false || return 1
    gitx config --global init.defaultBranch main || return 1
}

# ^ external on Windows JQ_BIN is the wrapper in the share dir adding -b; elsewhere the jq on PATH
lc_expected_jq() {
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then printf '%s' "$LC_DATA/jq"; else env -i HOME="$SANDBOX/home" PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" bash -c 'type -P jq' </dev/null; fi
}

gsg() { run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" "$@"; }

# ^ external the first git on the lifecycle PATH is the one install records in the timer unit; RHEL keeps it in /usr/local/bin, an Ubuntu PPA git is in /usr/bin
lc_first_git_dir() {
    local g
    g="$(env -i HOME="$SANDBOX/home" PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" bash -c 'type -P git' </dev/null)" || return 1
    printf '%s' "${g%/*}"
}

state_value() {
    [ -f "$LC_STATE/state" ] || return 1
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$LC_STATE/state"
}

lc_platform() {
    (
        source "$GSG_PROJECT/lib/common.sh" && source "$GSG_PROJECT/lib/tools.sh" \
            && tools_platform_key "$1" "${LC_FAKE_OS:-$(uname -s)}" "${LC_FAKE_ARCH:-$(uname -m)}"
    )
}

lc_asset_name() { (source "$GSG_PROJECT/lib/common.sh" && source "$GSG_PROJECT/lib/tools.sh" && tools_tarball_name "$@"); }

# ^ security the fakes print the version and nothing else => a passing test never needed the real tool
lc_make_fixtures() {
    local tv="${1:-3.99.2}" gv="${2:-1.9.0}" tool ver plat dir tar sha bin
    mkdir -p -- "$LC_FIX/src" || return 1
    : >"$LC_FIX/fixture.lock" || return 1
    for tool in trufflehog betterleaks; do
        ver="$tv"
        if [ "$tool" = betterleaks ]; then ver="$gv"; fi
        plat="$(lc_platform "$tool")" || return 1
        dir="$LC_FIX/src/$tool"
        bin="$tool"
        if [ "$TEST_IS_WINDOWS" -eq 1 ] && [ -z "$LC_FAKE_OS" ]; then bin="$tool.exe"; fi
        mkdir -p -- "$dir" || return 1
        if [ "$tool" = betterleaks ]; then
            printf '#!/bin/sh\necho "betterleaks version %s"\n' "$ver" >"$dir/$bin" || return 1
        else
            printf '#!/bin/sh\necho "trufflehog %s"\n' "$ver" >"$dir/$bin" || return 1
        fi
        chmod 755 "$dir/$bin" || return 1
        printf 'licence text\n' >"$dir/LICENSE" || return 1
        printf 'readme text\n' >"$dir/README.md" || return 1
        tar="$LC_FIX/$(lc_asset_name "$tool" "$ver" "$plat")"
        # ^ external the betterleaks Windows asset is a .zip; only the System32 bsdtar writes one, GNU tar cannot
        if [[ $tar == *.zip ]]; then
            "$TEST_SYSTEM32/tar.exe" -a -cf "$(cygpath -m "$tar")" -C "$(cygpath -m "$dir")" "$bin" LICENSE README.md || return 1
        else
            tar -czf "$tar" -C "$dir" "$bin" LICENSE README.md || return 1
        fi
        sha="$(sha256sum -- "$tar" | cut -d' ' -f1)" || return 1
        printf '%s %s %s %s\n' "$tool" "$ver" "$plat" "$sha" >>"$LC_FIX/fixture.lock" || return 1
    done
}

lc_path_without() {
    local dir="$SANDBOX/pathfarm-$1" d i name
    local -a dirs=()
    rm -rf -- "$dir" || return 1
    mkdir -p -- "$dir" || return 1
    IFS=: read -r -a dirs <<<"$TEST_BASE_PATH"
    for ((i = ${#dirs[@]} - 1; i >= 0; i--)); do
        d="${dirs[$i]}"
        if compgen -G "$d/*" >/dev/null; then ln -sfn "$d"/* "$dir/" || return 1; fi
    done
    rm -f -- "$dir/$1" || return 1
    for name in systemctl launchctl brew uname git sudo dnf restorecon make df ldd rpm; do
        if [ "$1" = "$name" ] || [ ! -e "$SANDBOX/pathbin/$name" ]; then continue; fi
        ln -sfn -- "$SANDBOX/pathbin/$name" "$dir/$name" || return 1
    done
    set_env PATH="$dir"
}

lc_seed_real_tools() {
    mkdir -p -- "$LC_BIN" || return 1
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then
        cp -- "$REAL_TRUFFLEHOG" "$REAL_BETTERLEAKS" "$LC_BIN/" || return 1
        return 0
    fi
    ln -s "$REAL_TRUFFLEHOG" "$LC_BIN/trufflehog$LC_EXE" || return 1
    ln -s "$REAL_BETTERLEAKS" "$LC_BIN/betterleaks$LC_EXE" || return 1
}

lc_fake_git() {
    printf '#!/bin/sh\necho "git version %s"\n' "$1" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git"
}

# ^ security HOME and XDG_CONFIG_HOME stay inside the sandbox => git's real global lookup runs against scratch files, never ~/.gitconfig
lc_real_lookup() {
    local e
    local -a keep=()
    for e in "${LC_ENV[@]}"; do
        case "$e" in GIT_CONFIG_GLOBAL=*) ;; *) keep+=("$e") ;; esac
    done
    LC_ENV=("${keep[@]}" XDG_CONFIG_HOME="$LC_HOME/.config")
    mkdir -p -- "$LC_HOME/.config/git"
}

gitreal() { env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GIT" "$@"; }

# ^ security the wrapper execs the absolute $GIT after the injected failure => nothing else about git changes
lc_git_wrapper() {
    printf '#!/bin/sh\nif %s; then echo "fatal: injected failure" >&2; exit 1; fi\nexec %s "$@"\n' "$1" "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git"
}

lc_fixture_url() { if [ "$TEST_IS_WINDOWS" -eq 1 ]; then printf 'file:///%s' "$(cygpath -m "$LC_FIX")"; else printf 'file://%s' "$LC_FIX"; fi; }
lc_use_fixtures() { set_env GSG_TOOLS_BASE_URL="$(lc_fixture_url)" GSG_TOOLS_LOCK="$LC_FIX/fixture.lock"; }
