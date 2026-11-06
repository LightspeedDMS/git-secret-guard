# shellcheck shell=bash disable=SC2034
# ^ coupled the git upgrade module of class wsl wraps the module of the distribution inside WSL; the contract is CONTRIBUTING.md "Adding an OS module"
# ^ coupled behaviour is in docs/platforms.md#wsl-windows-subsystem-for-linux; tests are tests/test_wsl.sh

# ^ invariant sets GITUP_INNER_CLASS (rpm, ubuntu or debian, from os-release) and GITUP_WSL_MODULE (the module registered for it); rc 1 = no inner module
# ^ invariant the inner module reads gitup_inner_class, never GITUP_CLASS => it behaves as on the same distribution outside WSL
GITUP_WSL_MODULE=""
gitup_wsl_enter() {
    install_os_family
    case "$REPLY" in
        rpm | ubuntu | debian) GITUP_INNER_CLASS="$REPLY" ;;
        *)
            printf '%s: WSL runs a distribution with no git upgrade module (class %s)\n' "$GSG_NAME" "$REPLY" >&2
            return 1
            ;;
    esac
    gitup_registry "$GITUP_INNER_CLASS" || return 1
    GITUP_WSL_MODULE="$REPLY"
    if [ -z "$GITUP_WSL_MODULE" ]; then return 1; fi
    if ! declare -F "gitup_${GITUP_WSL_MODULE}_plan" >/dev/null; then gitup_load_module "$GITUP_WSL_MODULE" || return 1; fi
}

# ^ invariant true when the inner module defines function KIND; the wrapper defines every optional function => each forward asks first
gitup_wsl_inner_has() { declare -F "gitup_${GITUP_WSL_MODULE}_$1" >/dev/null; }

# ^ invariant the inner plan runs unchanged; the two notes follow a plan only (rc 0), never a refusal or a nothing-to-do answer
gitup_wsl_plan() {
    local rc
    gitup_wsl_enter || return 1
    gitup_delegate "$GITUP_INNER_CLASS" plan "$@"
    rc=$?
    if [ "$rc" -ne 0 ]; then return "$rc"; fi
    gitup_plan_note "this upgrades git inside this WSL distribution only"
    gitup_plan_note "Windows-side git is a separate setup with its own global config; it keeps its own version and needs its own install"
}

gitup_wsl_apply() {
    gitup_wsl_enter || return 1
    gitup_delegate "$GITUP_INNER_CLASS" apply "$@"
}

# ^ invariant a wrapper forwards abort (CONTRIBUTING.md); an inner module without one has nothing half-made to undo
gitup_wsl_abort() {
    gitup_wsl_enter || return 0
    if ! gitup_wsl_inner_has abort; then return 0; fi
    gitup_delegate "$GITUP_INNER_CLASS" abort "$@"
}

# ^ invariant the takeover set is all five or none, defined only when the inner module has it => gitup_has answers as outside WSL and the core refuses the flag
# ^ why decided when the file loads, not per call; the core asks gitup_has first and os-release already names the inner module
# ^ invariant REPLY belongs to the caller (gitup_check_registered_modules reads it after the load) => the function puts it back
gitup_wsl_forward_takeover() {
    local keep="${REPLY:-}"
    if gitup_wsl_enter 2>/dev/null && gitup_wsl_inner_has takeover_supported; then
        gitup_wsl_takeover_supported() { gitup_delegate "$GITUP_INNER_CLASS" takeover_supported "$@"; }
        gitup_wsl_takeover_plan() { gitup_delegate "$GITUP_INNER_CLASS" takeover_plan "$@"; }
        gitup_wsl_takeover_apply() { gitup_delegate "$GITUP_INNER_CLASS" takeover_apply "$@"; }
        gitup_wsl_takeover_restore() { gitup_delegate "$GITUP_INNER_CLASS" takeover_restore "$@"; }
        gitup_wsl_takeover_status() { gitup_delegate "$GITUP_INNER_CLASS" takeover_status "$@"; }
    fi
    REPLY="$keep"
}
gitup_wsl_forward_takeover
