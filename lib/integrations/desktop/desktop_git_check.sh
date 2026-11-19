# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled install-time only, loaded by bin/git-secret-guard after lib/integrations/desktop/desktop_git.sh; the hook never loads it
# ^ invariant the check runs Desktop's own bundled git as Desktop runs it and says what failed; it writes only to a scratch directory it removes
# ^ security the fake credential below is made up, joined from fragments at run time and never printed; it only proves the wrappers block it

DESKTOP_GIT_REPO_HOOK_MARK=gsg-check-repo-hook-ran

# ^ invariant prints the environment dugite gives Desktop's git (setupEnvironment in renderer.js) plus $1 as core.hooksPath, one NAME=VALUE per line
# ^ invariant $2 = 0 for no network parameters, 2 for Desktop's default (renderer.js sets GIT_CONFIG_COUNT=2 with two credential.helper entries)
# ^ invariant $2 = 1 for the preview branch (only with GITHUB_DESKTOP_PREVIEW_FEATURES=1), appending 'credential.helper=' 'credential.helper=desktop'
desktop_git_check_env() {
    local q="'" params mode="${2:-0}"
    case "$mode" in 0 | 1 | 2) ;; *)
        printf '%s: internal error: unknown Desktop environment mode [%s]\n' "$GSG_NAME" "$mode" >&2
        return 2
        ;;
    esac
    params="'core.hooksPath=${1//$q/$q\\$q$q}'"
    if [ "$mode" -eq 1 ]; then params+=" 'credential.helper=' 'credential.helper=desktop'"; fi
    printf '%s\n' "GIT_EXEC_PATH=$DG_BUNDLE/libexec/git-core" "GIT_CONFIG_SYSTEM=$DG_BUNDLE/etc/gitconfig" \
        "GIT_TEMPLATE_DIR=$DG_BUNDLE/share/git-core/templates" "PREFIX=$DG_BUNDLE" "GIT_CONFIG_PARAMETERS=$params"
    if [ "$mode" -eq 2 ]; then
        printf '%s\n' GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= GIT_CONFIG_KEY_1=credential.helper GIT_CONFIG_VALUE_1=desktop
    fi
}

# ^ invariant desktop_git_check_branch MODE REPO CODE inits REPO in Desktop's environment of MODE; rc 0 = hooksPath and helper coexist, a fake token is blocked
# ^ invariant rc CODE = they did not coexist, CODE+1 = the commit was not blocked, 2 = the setup failed; the fake token is in $DG_CHECK_KEY
desktop_git_check_branch() {
    local mode="$1" repo="$2" code="$3" out helpers
    desktop_git_check_git "$mode" init -q "$repo" || return 2
    out="$(desktop_git_check_git "$mode" -C "$repo" config --get-all core.hooksPath)" || return "$code"
    helpers="$(desktop_git_check_git "$mode" -C "$repo" config --get-all credential.helper)" || return "$code"
    if [ "$out" != "$DG_CHECK_DIR" ] || [[ $helpers != *desktop* ]]; then return "$code"; fi
    printf 'aws_access_key_id = %s\n' "$DG_CHECK_KEY" >"$repo/f.txt" && desktop_git_check_git "$mode" -C "$repo" add f.txt || return 2
    if desktop_git_check_git "$mode" -C "$repo" commit -q -m check-params >/dev/null 2>&1; then return "$((code + 1))"; fi
}

# ^ invariant desktop_git_check_repo_hook REPO HOOK writes a failing hook printing the marker, stages a file and commits; rc 0 = failed with the marker
# ^ invariant rc 1 = the commit passed or the marker was not shown (the repository's own hook did not run), rc 2 = the setup failed
desktop_git_check_repo_hook() {
    local out
    mkdir -p -- "${2%/*}" || return 2
    printf '#!/bin/sh\necho %s >&2\nexit 1\n' "$DESKTOP_GIT_REPO_HOOK_MARK" >"$2" && chmod 755 "$2" || return 2
    printf 'hello\n' >"$1/h.txt" && desktop_git_check_git 0 -C "$1" add h.txt || return 2
    if out="$(desktop_git_check_git 0 -C "$1" commit -q -m check-repo-hook 2>&1)"; then return 1; fi
    [[ $out == *"$DESKTOP_GIT_REPO_HOOK_MARK"* ]]
}

# ^ invariant runs in a subshell of desktop_git_check_run, $1 = a scratch directory; rc 0 = every check held, else a number for desktop_git_check_why
desktop_git_check_steps() {
    local key out a="$1/a" c="$1/c" d="$1/d" e="$1/e" rc
    key="$(printf '%s%s%s' 'AKI' 'A' 'Q7XK2MWB4HZ5NR3T')"
    desktop_git_check_git 0 init -q "$a" || return 2
    printf 'aws_access_key_id = %s\n' "$key" >"$a/f.txt" || return 2
    desktop_git_check_git 0 -C "$a" add f.txt || return 2
    if out="$(desktop_git_check_git 0 -C "$a" commit -q -m check-file 2>&1)"; then return 3; fi
    if desktop_git_check_git 0 -C "$a" rev-parse -q --verify HEAD >/dev/null 2>&1; then return 3; fi
    if [[ $out != *"potential secret(s) in lines this commit adds"* ]]; then return 4; fi
    desktop_git_check_git 0 -C "$a" rm -q -f --cached f.txt || return 2
    printf 'hello\n' >"$a/g.txt" || return 2
    desktop_git_check_git 0 -C "$a" add g.txt || return 2
    if out="$(desktop_git_check_git 0 -C "$a" commit -q -m "note $key" 2>&1)"; then return 5; fi
    if [[ $out != *"potential secret(s) in the commit message"* ]]; then return 6; fi
    out="$(desktop_git_check_git 0 -C "$a" commit -q -m clean 2>&1)" || return 7
    if [[ $out != *"$GSG_NAME: scanned"* ]]; then return 8; fi
    desktop_git_check_git 0 init -q "$c" && desktop_git_check_git 0 -C "$c" config core.hooksPath .husky || return 2
    desktop_git_check_repo_hook "$c" "$c/.husky/pre-commit"
    rc=$?
    if [ "$rc" -eq 1 ]; then return 9; elif [ "$rc" -ne 0 ]; then return 2; fi
    desktop_git_check_git 0 init -q "$d" || return 2
    desktop_git_check_repo_hook "$d" "$d/.git/hooks/pre-commit"
    rc=$?
    if [ "$rc" -eq 1 ]; then return 10; elif [ "$rc" -ne 0 ]; then return 2; fi
    DG_CHECK_KEY="$key"
    desktop_git_check_branch 1 "$e" 11 || return "$?"
    desktop_git_check_branch 2 "$1/f" 13 || return "$?"
}

# ^ invariant prints what check number $1 of desktop_git_check_steps means
desktop_git_check_why() {
    case "$1" in
        3) printf 'a commit of a fake token in a file was NOT blocked' ;;
        4) printf 'a commit of a fake token in a file failed, but not with the findings text of the hook' ;;
        5) printf 'a commit of a fake token only in the message was NOT blocked' ;;
        6) printf 'a commit with a fake token in its message failed, but not with the message findings text' ;;
        7) printf 'a clean commit failed' ;;
        8) printf 'a clean commit printed no %s summary line' "$GSG_NAME" ;;
        9) printf 'a repository hook named by its own core.hooksPath (husky style) did not run' ;;
        10) printf 'a repository hook in .git/hooks did not run' ;;
        11) printf 'the credential parameters of Desktop'\''s preview branch (appended to GIT_CONFIG_PARAMETERS) did not coexist with core.hooksPath' ;;
        12) printf 'a commit of a fake token was NOT blocked in Desktop'\''s preview branch (credential parameters appended to ours)' ;;
        13) printf 'the credential entries of Desktop'\''s default (count) branch (GIT_CONFIG_COUNT=2) did not coexist with core.hooksPath' ;;
        14) printf 'a commit of a fake token was NOT blocked in Desktop'\''s default (count) branch (GIT_CONFIG_COUNT=2 beside our parameter)' ;;
        *) printf 'the scratch repository could not be set up (check status %s)' "$1" ;;
    esac
}

# ^ invariant desktop_git_check_run HOOKS_DIR runs the checks with Desktop's own git and always removes its scratch directory; rc 1 = a check failed, named
# ^ security the repository-local GIT_* names are dropped from every call => a run inside a hook never touches its own repository; an empty list is refused
desktop_git_check_run() {
    local work rc names
    DG_CHECK_DIR="$1"
    names="$("$GSG_GIT" rev-parse --local-env-vars)" || {
        printf '%s: cannot list the repository-local git variables for the GitHub Desktop check\n' "$GSG_NAME" >&2
        return 1
    }
    mapfile -t DG_CHECK_UNSET <<<"$names"
    if [ "${#DG_CHECK_UNSET[@]}" -eq 0 ] || [ -z "${DG_CHECK_UNSET[0]}" ]; then
        printf '%s: git listed no repository-local variables for the GitHub Desktop check\n' "$GSG_NAME" >&2
        return 1
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/gsg-desktop-check.XXXXXX")" || {
        printf '%s: cannot create a scratch directory for the GitHub Desktop check\n' "$GSG_NAME" >&2
        return 1
    }
    (desktop_git_check_steps "$work")
    rc=$?
    rm -rf -- "$work" || printf '%s: could not remove the scratch directory %s\n' "$GSG_NAME" "$work" >&2
    if [ "$rc" -ne 0 ]; then
        printf '%s: checked through GitHub Desktop'\''s git: %s\n' "$GSG_NAME" "$(desktop_git_check_why "$rc")" >&2
        return 1
    fi
    printf '%s: checked through GitHub Desktop'\''s own git with the launcher'\''s environment: a fake token in a file and in a message were blocked, a clean commit was scanned, the repository'\''s own hooks (core.hooksPath and .git/hooks) still ran, Desktop'\''s credential parameters coexist in its default (count) branch and in its preview (append) branch\n' "$GSG_NAME"
}

# ^ invariant desktop_git_check_git APPEND ARGS... runs Desktop's git in this environment; DG_CHECK_DIR = hooks directory, DG_CHECK_UNSET = names to drop
# ^ why identity and signing as -c options, not a config file; the user's global config applies as in Desktop and gpgsign=true must not stop the commit
desktop_git_check_git() {
    local append="$1" line
    local -a envs=() unset_args=()
    shift
    while IFS= read -r line; do envs+=("$line"); done < <(desktop_git_check_env "$DG_CHECK_DIR" "$append")
    for line in "${DG_CHECK_UNSET[@]}"; do unset_args+=(-u "$line"); done
    env "${unset_args[@]}" "${envs[@]}" "$DG_GIT" -c commit.gpgsign=false -c user.name=gsg-check -c user.email=gsg-check@example.invalid "$@"
}
