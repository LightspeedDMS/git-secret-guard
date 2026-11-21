#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

# ^ invariant runs CODE in a fresh bash with the platform libraries loaded and a uname function over the real ones (FAKE_UNAME, default Linux)
# ^ why a uname function, not a PATH stand-in; a function runs in the shell and in every $(...) of it, and appends to $UNAME_LOG; one log shows each call
# shellcheck disable=SC2016
pf_run() {
    local script='set -u
uname() { printf "%s\n" "$1" >>"$UNAME_LOG"; case "$1" in -s) printf "%s\n" "$FAKE_UNAME" ;; -m) printf "x86_64\n" ;; esac; }
source "$1/lib/core/common.sh" && source "$1/lib/core/proc.sh" && source "$1/lib/platform/brew.sh" && source "$1/lib/install/tools.sh" || exit 9
eval "$2"'
    rm -f -- "${SANDBOX:?}/uname.log"
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" UNAME_LOG="$SANDBOX/uname.log" FAKE_UNAME="${FAKE_UNAME:-Linux}" bash -c "$script" _ "$GSG_PROJECT" "$1"
}

# ^ invariant prints how many times the uname function ran with the argument $1
pf_count() {
    if [ ! -f "$SANDBOX/uname.log" ]; then printf '0\n'; return 0; fi
    awk -v want="$1" '$0 == want { n++ } END { print n + 0 }' "$SANDBOX/uname.log"
}

# shellcheck disable=SC2016
test_a_fill_in_the_main_shell_serves_every_later_check_including_those_in_command_substitutions() {
    FAKE_UNAME=MINGW64_NT-10.0-26200 pf_run 'gsg_os_fill; gsg_arch_fill
a="$(tools_binary_name trufflehog)"; b="$(tools_binary_name betterleaks)"
gsg_is_windows; proc_is_windows; tools_is_windows; brew_is_macos; brew_is_intel_mac
brew_os_fill; brew_arch_fill
printf "%s %s %s %s\n" "$a" "$b" "$GSG_UNAME_S" "$GSG_UNAME_M"'
    assert_rc 0 "the checks run"
    assert_eq "$OUT" "trufflehog.exe betterleaks.exe MINGW64_NT-10.0-26200 x86_64" "every copy reads the one answer"
    assert_eq "$(pf_count -s)" 1 "uname -s ran once for eleven checks, two of them in a subshell"
    assert_eq "$(pf_count -m)" 1 "uname -m ran once"
}

# shellcheck disable=SC2016
test_the_architecture_is_asked_only_by_a_caller_that_needs_it() {
    pf_run 'gsg_is_windows; proc_is_windows; tools_is_windows; brew_is_macos; brew_is_intel_mac; true'
    assert_rc 0 "the checks run"
    assert_eq "$(pf_count -s)" 1 "uname -s ran once"
    assert_eq "$(pf_count -m)" 0 "no check of the operating system runs uname -m"
}

# ^ invariant a failing uname is not cached; the first fill returns 1 and leaves the variable empty, the next one asks again
# shellcheck disable=SC2016
test_a_failing_uname_is_never_cached_by_either_copy_of_the_fill() {
    local fill
    for fill in gsg_os_fill brew_os_fill gsg_arch_fill brew_arch_fill; do
        pf_run 'uname() { if [ ! -e "$UNAME_LOG.failed" ]; then : >"$UNAME_LOG.failed"; printf "partial\n"; return 3; fi; printf "Linux\n"; }
'"$fill"'; printf "first rc=%s [%s%s]\n" "$?" "${GSG_UNAME_S:-}" "${GSG_UNAME_M:-}"
'"$fill"'; printf "second rc=%s [%s%s]\n" "$?" "${GSG_UNAME_S:-}" "${GSG_UNAME_M:-}"'
        assert_eq "$OUT" "first rc=1 []
second rc=0 [Linux]" "$fill: the failure leaves nothing behind and the next call asks again"
        rm -f -- "${SANDBOX:?}/uname.log.failed"
    done
}

# ^ security the answers stay in this shell; an exported copy would reach every child, where the entry points do not read it back
# shellcheck disable=SC2016
test_the_answers_are_never_exported() {
    pf_run 'gsg_os_fill; gsg_arch_fill; brew_os_fill; compgen -e | awk "/^GSG_UNAME/ { n++ } END { print n + 0 }"'
    assert_rc 0 "the fills run"
    assert_eq "$OUT" 0 "neither variable is in the environment"
}

# ^ invariant a test or a caller may still replace a wrapper; the replacement is what the callers of the wrapper reach
# shellcheck disable=SC2016
test_a_replaced_wrapper_still_takes_effect() {
    pf_run 'tools_is_windows() { return 0; }; brew_is_macos() { return 0; }
printf "%s " "$(tools_binary_name x)"; if brew_is_macos; then printf "mac\n"; fi'
    assert_eq "$OUT" "x.exe mac" "the replaced checks answer, not the cached uname"
}

# ^ security a library using the platform checks refuses to load without common.sh; a missing function must never read as not Windows or not WSL
# shellcheck disable=SC2016
test_a_library_that_needs_the_platform_fill_refuses_to_load_without_common_sh() {
    local lib
    for lib in core/proc install/tools platform/wsl; do
        run_cap env -i "${GSG_ENV[@]}" bash -c 'source "$1/lib/$2.sh"' _ "$GSG_PROJECT" "$lib"
        assert_rc 1 "$lib alone"
        assert_contains "$ERR" "lib/core/common.sh must be sourced first" "$lib says what it needs"
        run_cap env -i "${GSG_ENV[@]}" bash -c 'source "$1/lib/core/common.sh" && source "$1/lib/$2.sh"' _ "$GSG_PROJECT" "$lib"
        assert_rc 0 "$lib after common.sh"
    done
}

run_file_tests
