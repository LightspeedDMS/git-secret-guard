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

lc_begin() {
    LC_HOME="$SANDBOX/home"
    LC_BIN="$LC_HOME/.local/bin"
    LC_FIX="$SANDBOX/fixtures"
    LC_DATA="$SANDBOX/xdg/data/git-secret-guard"
    LC_STATE="$SANDBOX/xdg/state/git-secret-guard"
    rm -rf -- "$LC_HOME" "$SANDBOX/xdg" "$SANDBOX/pathbin" "$LC_FIX" "$SANDBOX/systemctl.log" "$SANDBOX/systemctl.fail" || return 1
    mkdir -p -- "$LC_HOME" "$SANDBOX/xdg/data" "$SANDBOX/xdg/state" "$SANDBOX/pathbin" || return 1
    lc_systemctl_standin || return 1
    : >"$SANDBOX/gitconfig" || return 1
    EXTRA_ENV=()
    LC_ENV=("${GSG_ENV[@]}" PATH="$SANDBOX/pathbin:/usr/local/bin:/usr/bin:/bin"
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
    g="$(env -i HOME="$SANDBOX/home" PATH="$SANDBOX/pathbin:/usr/local/bin:/usr/bin:/bin" bash -c 'type -P git' </dev/null)" || return 1
    printf '%s' "${g%/*}"
}

state_value() {
    [ -f "$LC_STATE/state" ] || return 1
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$LC_STATE/state"
}

lc_platform() {
    (
        source "$GSG_PROJECT/lib/common.sh" && source "$GSG_PROJECT/lib/tools.sh" \
            && tools_platform_key "$1" "$(uname -s)" "$(uname -m)"
    )
}

# ^ security the fakes print the version and nothing else => a passing test never needed the real tool
lc_make_fixtures() {
    local tv="${1:-3.99.2}" gv="${2:-8.30.1}" tool ver plat dir tar sha
    mkdir -p -- "$LC_FIX/src" || return 1
    : >"$LC_FIX/fixture.lock" || return 1
    for tool in trufflehog gitleaks; do
        ver="$tv"
        if [ "$tool" = gitleaks ]; then ver="$gv"; fi
        plat="$(lc_platform "$tool")" || return 1
        dir="$LC_FIX/src/$tool"
        mkdir -p -- "$dir" || return 1
        if [ "$tool" = gitleaks ]; then
            printf '#!/bin/sh\necho "gitleaks version %s"\n' "$ver" >"$dir/$tool" || return 1
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
    local dir="$SANDBOX/pathfarm-$1"
    rm -rf -- "$dir" || return 1
    mkdir -p -- "$dir" || return 1
    ln -s /usr/bin/* "$dir/" || return 1
    ln -sf /usr/local/bin/* "$dir/" || return 1
    rm -f -- "$dir/$1" || return 1
    if [ "$1" != systemctl ]; then ln -sfn -- "$SANDBOX/pathbin/systemctl" "$dir/systemctl" || return 1; fi
    set_env PATH="$dir"
}

lc_seed_real_tools() {
    mkdir -p -- "$LC_BIN" || return 1
    ln -s "$REAL_TRUFFLEHOG" "$LC_BIN/trufflehog" || return 1
    ln -s "$REAL_GITLEAKS" "$LC_BIN/gitleaks" || return 1
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
