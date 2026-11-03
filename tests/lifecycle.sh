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

# ^ invariant the fake uname answers these; lc_platform builds the fixture rows for the same platform the CLI will ask about
LC_FAKE_OS="" LC_FAKE_ARCH=""

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
        printf '%s\n' "util-linux|opt/util-linux/bin/setsid|$TEST_SETSID" "jq|bin/jq|$TEST_JQ"
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

lc_begin() {
    LC_HOME="$SANDBOX/home"
    LC_BIN="$LC_HOME/.local/bin"
    LC_FIX="$SANDBOX/fixtures"
    LC_DATA="$SANDBOX/xdg/data/git-secret-guard"
    LC_STATE="$SANDBOX/xdg/state/git-secret-guard"
    LC_FAKE_OS="" LC_FAKE_ARCH=""
    rm -rf -- "$LC_HOME" "$SANDBOX/xdg" "$SANDBOX/pathbin" "$LC_FIX" "$SANDBOX/systemctl.log" "$SANDBOX/systemctl.fail" "$SANDBOX/brew.map" || return 1
    mkdir -p -- "$LC_HOME" "$SANDBOX/xdg/data" "$SANDBOX/xdg/state" "$SANDBOX/pathbin" || return 1
    lc_brew_reset || return 1
    lc_systemctl_standin || return 1
    lc_brew_standin || return 1
    lc_brew_have bash coreutils util-linux jq || return 1
    # ^ why the Linux flow by default on a Mac, not the real Darwin one; tests/test_macos.sh opts into Darwin with lc_real_uname
    if [ "$TEST_OS" = Darwin ]; then lc_fake_uname Linux "$(uname -m)" || return 1; fi
    : >"$SANDBOX/gitconfig" || return 1
    EXTRA_ENV=()
    LC_ENV=("${GSG_ENV[@]}" PATH="$SANDBOX/pathbin:$TEST_BASE_PATH"
        XDG_DATA_HOME="$SANDBOX/xdg/data" XDG_STATE_HOME="$SANDBOX/xdg/state")
    gitx config --global user.name "Test User" || return 1
    gitx config --global user.email "test@example.invalid" || return 1
    gitx config --global commit.gpgsign false || return 1
    gitx config --global init.defaultBranch main || return 1
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

# ^ security the fakes print the version and nothing else => a passing test never needed the real tool
lc_make_fixtures() {
    local tv="${1:-3.99.2}" gv="${2:-1.9.0}" tool ver plat dir tar sha
    mkdir -p -- "$LC_FIX/src" || return 1
    : >"$LC_FIX/fixture.lock" || return 1
    for tool in trufflehog betterleaks; do
        ver="$tv"
        if [ "$tool" = betterleaks ]; then ver="$gv"; fi
        plat="$(lc_platform "$tool")" || return 1
        dir="$LC_FIX/src/$tool"
        mkdir -p -- "$dir" || return 1
        if [ "$tool" = betterleaks ]; then
            printf '#!/bin/sh\necho "betterleaks version %s"\n' "$ver" >"$dir/$tool" || return 1
        else
            printf '#!/bin/sh\necho "trufflehog %s"\n' "$ver" >"$dir/$tool" || return 1
        fi
        chmod 755 "$dir/$tool" || return 1
        printf 'licence text\n' >"$dir/LICENSE" || return 1
        printf 'readme text\n' >"$dir/README.md" || return 1
        tar="$LC_FIX/${tool}_${ver}_${plat}.tar.gz"
        tar -czf "$tar" -C "$dir" "$tool" LICENSE README.md || return 1
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
    for name in systemctl brew uname git; do
        if [ "$1" = "$name" ] || [ ! -e "$SANDBOX/pathbin/$name" ]; then continue; fi
        ln -sfn -- "$SANDBOX/pathbin/$name" "$dir/$name" || return 1
    done
    set_env PATH="$dir"
}

lc_seed_real_tools() {
    mkdir -p -- "$LC_BIN" || return 1
    ln -s "$REAL_TRUFFLEHOG" "$LC_BIN/trufflehog" || return 1
    ln -s "$REAL_BETTERLEAKS" "$LC_BIN/betterleaks" || return 1
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

lc_use_fixtures() { set_env GSG_TOOLS_BASE_URL="file://$LC_FIX" GSG_TOOLS_LOCK="$LC_FIX/fixture.lock"; }
