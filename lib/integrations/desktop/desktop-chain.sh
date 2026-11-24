#!/usr/bin/env bash
# ^ coupled the text of this file is the shared file of install --link-desktop-git (desktop_git.sh puts the marker on line 2 and replaces the scan=() line)
# ^ invariant every wrapper is a link to this file and the hook event is the name it was started under; it runs inside a hook of the git Desktop runs
# ^ invariant one bash and one git call for a plain event; the scan and the version probe run only for pre-commit and commit-msg
set -u

readonly CONFIG_HOOK_MIN_MAJOR=2 CONFIG_HOOK_MIN_MINOR=54
scan=()
event="${0##*/}"
if [ -z "$event" ] || [ "$event" = gsg-desktop-chain ]; then
    printf 'git-secret-guard: the Desktop hook wrapper was started as %s, not under the name of a hook\n' "${event:-nothing}" >&2
    exit 1
fi
if [ "${#scan[@]}" -eq 0 ]; then
    printf 'git-secret-guard: the Desktop hook wrapper has no scan command (install did not write one); run: git-secret-guard install\n' >&2
    exit 1
fi
# ^ invariant rc 0 = the git running this hook is 2.54 or newer and hook.git-secret-guard.* in the global config already scans; a second scan would repeat it
# ^ why an unreadable version scans, not skips; a git unable to say what it is may not run the config hook
git_scans_by_config() {
    local out
    out="$(git --version 2>/dev/null)" || return 1
    if [[ $out =~ ^git\ version\ ([0-9]+)\.([0-9]+) ]]; then
        [ "${BASH_REMATCH[1]}" -gt "$CONFIG_HOOK_MIN_MAJOR" ] \
            || { [ "${BASH_REMATCH[1]}" -eq "$CONFIG_HOOK_MIN_MAJOR" ] && [ "${BASH_REMATCH[2]}" -ge "$CONFIG_HOOK_MIN_MINOR" ]; }
        return
    fi
    return 1
}

case "$event" in
    pre-commit | commit-msg)
        if ! git_scans_by_config; then
            "${scan[@]}" "$@" || exit "$?"
        fi
        ;;
esac

# ^ hazard a loop guard before the scan would let a reused pid skip it; here it only stops an exec of the chain itself
if [ "${GSG_DESKTOP_CHAIN_PID:-}" = "$$" ]; then exit 0; fi

# ^ why only our own entry leaves GIT_CONFIG_PARAMETERS, not all of it; the user's entries (an include setting core.hooksPath) and Desktop's stay for git
# ^ invariant the entry is matched whole and literally (quoted pattern) as git writes it ('\'' for a quote); absent or twice is unclear and the value is emptied
own="${0%/*}"
quote="'"
entry="'core.hooksPath=${own//$quote/$quote\\$quote$quote}'"
padded=" ${GIT_CONFIG_PARAMETERS-} "
rest="${padded/" $entry "/ }"
if [ "$rest" = "$padded" ] || [[ $rest == *" $entry "* ]]; then
    params=''
else
    params="${rest# }"
    params="${params% }"
fi

# ^ why git is asked for the path, not config read here; with our parameter emptied git applies its own rules (scopes, empty values, ~ and ~user, worktrees)
# ^ external an empty core.hooksPath prints /<event> in git 2.45, a path no hook is at; the answer is relative to the directory the hook runs in, this one
# ^ invariant GIT_CONFIG_PARAMETERS is changed for this one call only; the core.hooksPath of this wrapper is not seen and the repository's own is
if ! hook="$(GIT_CONFIG_PARAMETERS="$params" git rev-parse --git-path "hooks/$event" 2>/dev/null)"; then
    printf 'git-secret-guard: git could not tell where this repository keeps its hooks; its own %s hook was NOT run (the Desktop hook wrapper stops here)\n' "$event" >&2
    exit 1
fi
# ^ invariant a hook missing, or this very wrapper, is no hook => success; the hint for a non-executable one is git's own text, printed only there
if [ -f "$hook" ] && [ -x "$hook" ]; then
    if [ "$hook" -ef "$0" ]; then exit 0; fi
    export GSG_DESKTOP_CHAIN_PID=$$
    exec "$hook" "$@"
fi
if [ -f "$hook" ] && [ "$(git config --type=bool advice.ignoredHook 2>/dev/null)" != false ]; then
    printf "hint: The '%s' hook was ignored because it's not set as executable.\n" "$hook" >&2
    # shellcheck disable=SC2016
    printf 'hint: You can disable this warning with `git config advice.ignoredHook false`.\n' >&2
fi
exit 0
