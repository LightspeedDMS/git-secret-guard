#!/usr/bin/env bash
# shellcheck source=tests/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup_windows.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup_windows.sh"

# ^ coupled the .cmd front ends and a Git for Windows left half installed by a stopped installer; tests/test_gitup_windows.sh holds the rest of #30
# ^ external a killed installer left bin/bash.exe (the launcher) without usr/bin/bash.exe, and the launcher failed with its own text (run 42267563578)
test_a_half_installed_git_for_windows_is_named_and_not_run_as_if_it_were_missing_or_fine() {
    local g="$SANDBOX/halfgit" w32
    if [ "$TEST_IS_WINDOWS" -ne 1 ]; then skip_test "gsg-bash.cmd is a Windows batch file"; fi
    mkdir -p -- "$g/cmd" "$g/bin" "$SANDBOX/pf" "$SANDBOX/lad" || return 1
    : >"$g/cmd/git.exe" && : >"$g/bin/bash.exe" && : >"$g/unins000.exe" || return 1
    w32="$(cygpath -w "$TEST_SYSTEM32")"
    run_cap env -i SystemRoot="$(cygpath -w "$(dirname "$TEST_SYSTEM32")")" PATH="$(cygpath -w "$g/cmd");$w32" ProgramFiles="$(cygpath -w "$SANDBOX/pf")" \
        LocalAppData="$(cygpath -w "$SANDBOX/lad")" "$TEST_SYSTEM32/cmd.exe" //c "$(cygpath -w "$GSG_PROJECT/bin/gsg-bash.cmd")" -c "echo ran"
    assert_rc 127 "bash cannot be started"
    assert_not_contains "$OUT$ERR" "ran" "nothing ran"
    assert_contains "$OUT$ERR" "half installed" "the message says Git for Windows looks half installed"
    assert_contains "$OUT$ERR" "git-scm.com" "and where to get it again"
    assert_contains "$OUT$ERR" "git-upgrade" "and the folder that keeps the installer of a stopped upgrade"
    assert_contains "$OUT$ERR" "Git for Windows at \"$(cygpath -w "$g")\" looks" "with the folder written plainly, no bin\.. in it"
}


# ^ external a Cygwin or MSYS tree has bin\bash.exe and no usr\bin\bash.exe either; it is not Git for Windows, whose Inno setup leaves unins000.exe
test_a_bash_tree_that_is_not_git_for_windows_is_reported_as_not_found_and_not_as_half_installed() {
    local g="$SANDBOX/cygtree" w32
    if [ "$TEST_IS_WINDOWS" -ne 1 ]; then skip_test "gsg-bash.cmd is a Windows batch file"; fi
    mkdir -p -- "$g/bin" "$SANDBOX/pf" "$SANDBOX/lad" || return 1
    : >"$g/bin/git.exe" && : >"$g/bin/bash.exe" || return 1
    w32="$(cygpath -w "$TEST_SYSTEM32")"
    run_cap env -i SystemRoot="$(cygpath -w "$(dirname "$TEST_SYSTEM32")")" PATH="$(cygpath -w "$g/bin");$w32" ProgramFiles="$(cygpath -w "$SANDBOX/pf")" \
        LocalAppData="$(cygpath -w "$SANDBOX/lad")" "$TEST_SYSTEM32/cmd.exe" //c "$(cygpath -w "$GSG_PROJECT/bin/gsg-bash.cmd")" -c "echo ran"
    assert_rc 127 "no Git for Windows"
    assert_not_contains "$OUT$ERR" "half installed" "a tree that is not Git for Windows is not called half installed"
    assert_contains "$OUT$ERR" "was not found" "it is reported as not found"
}

test_the_installed_cmd_names_a_half_installed_git_for_windows_before_it_starts_bash() {
    local fake="$SANDBOX/fakeroot"
    wu_need_windows_runner
    wu_begin machine 2.43.0 || return 1
    mkdir -p -- "$fake/bin" "$SANDBOX/instbin" "$SANDBOX/lad" || return 1
    : >"$fake/bin/bash.exe" || return 1
    wu 'FR="$3"; cygpath() { if [ "$1" = -w ] && [ "$2" = / ]; then printf "%s" "$FR"; else command cygpath "$@"; fi; }; GSG_SHARE="$1"; install_cli_cmd_text >"$2"' \
        "$GSG_PROJECT" "$SANDBOX/instbin/git-secret-guard.cmd" "$(cygpath -w "$fake")"
    run_cap env -i SystemRoot="$(cygpath -w "$(dirname "$TEST_SYSTEM32")")" LocalAppData="$(cygpath -w "$SANDBOX/lad")" \
        "$TEST_SYSTEM32/cmd.exe" //c "$(cygpath -w "$SANDBOX/instbin/git-secret-guard.cmd")" status </dev/null
    assert_rc 127 "the installed .cmd stops"
    assert_contains "$OUT$ERR" "half installed" "and names the state"
    assert_contains "$OUT$ERR" "git-upgrade" "and the folder that keeps the installer of a stopped upgrade"
    assert_contains "$OUT$ERR" "Git for Windows at \"$(cygpath -w "$fake")\" looks" "and the Git it means"
    assert_eq "$(grep -o 'run the installer kept in.*' "$SANDBOX/instbin/git-secret-guard.cmd" | tr -d '\r')" "$(grep -o 'run the installer kept in.*' "$GSG_PROJECT/bin/gsg-bash.cmd" | tr -d '\r')" "the installed .cmd and bin/gsg-bash.cmd give the same advice"
}

# ^ external a kill before the setup wrote unins000.exe leaves cmd/git.exe; a Cygwin or MSYS tree never has a cmd directory
test_a_stopped_installer_before_unins000_exists_still_gets_the_kept_installer_hint() {
    local g="$SANDBOX/earlykill" w32
    if [ "$TEST_IS_WINDOWS" -ne 1 ]; then skip_test "gsg-bash.cmd is a Windows batch file"; fi
    mkdir -p -- "$g/cmd" "$g/bin" "$SANDBOX/pf" "$SANDBOX/lad" || return 1
    : >"$g/cmd/git.exe" && : >"$g/bin/bash.exe" || return 1
    w32="$(cygpath -w "$TEST_SYSTEM32")"
    run_cap env -i SystemRoot="$(cygpath -w "$(dirname "$TEST_SYSTEM32")")" PATH="$(cygpath -w "$g/cmd");$w32" ProgramFiles="$(cygpath -w "$SANDBOX/pf")" \
        LocalAppData="$(cygpath -w "$SANDBOX/lad")" "$TEST_SYSTEM32/cmd.exe" //c "$(cygpath -w "$GSG_PROJECT/bin/gsg-bash.cmd")" -c "echo ran"
    assert_rc 127 "bash cannot be started"
    assert_contains "$OUT$ERR" "half installed" "git.exe under cmd is enough to know it is Git for Windows"
    assert_contains "$OUT$ERR" "git-upgrade" "and the hint names the folder of the kept installer"
}

# ^ hazard an ampersand in the path ends the echo and runs the rest of the line as a command ('D' is not recognized)
test_an_ampersand_in_the_git_path_is_printed_and_never_run() {
    local g="$SANDBOX/R&D Git" w32
    if [ "$TEST_IS_WINDOWS" -ne 1 ]; then skip_test "gsg-bash.cmd is a Windows batch file"; fi
    mkdir -p -- "$g/cmd" "$g/bin" "$SANDBOX/pf" "$SANDBOX/R&D lad" || return 1
    : >"$g/cmd/git.exe" && : >"$g/bin/bash.exe" || return 1
    w32="$(cygpath -w "$TEST_SYSTEM32")"
    run_cap env -i SystemRoot="$(cygpath -w "$(dirname "$TEST_SYSTEM32")")" PATH="$(cygpath -w "$g/cmd");$w32" ProgramFiles="$(cygpath -w "$SANDBOX/pf")" \
        LocalAppData="$(cygpath -w "$SANDBOX/R&D lad")" "$TEST_SYSTEM32/cmd.exe" //c "$(cygpath -w "$GSG_PROJECT/bin/gsg-bash.cmd")" -c "echo ran"
    assert_rc 127 "bash cannot be started"
    assert_contains "$OUT$ERR" "R&D Git" "the whole path is printed"
    assert_contains "$OUT$ERR" "R&D lad" "and so is the profile path of the installer folder, which also holds an ampersand"
    assert_not_contains "$OUT$ERR" "is not recognized" "and nothing after the ampersand ran"
}

test_the_installed_cmd_prints_a_path_with_an_ampersand_and_tells_a_removed_git_from_a_half_installed_one() {
    local half="$SANDBOX/R&D half" gone="$SANDBOX/R&D gone" w
    wu_need_windows_runner
    wu_begin machine 2.43.0 || return 1
    mkdir -p -- "$half/bin" "$gone" "$SANDBOX/instbin" "$SANDBOX/R&D lad" || return 1
    : >"$half/bin/bash.exe" || return 1
    for w in half gone; do
        wu 'FR="$3"; cygpath() { if [ "$1" = -w ] && [ "$2" = / ]; then printf "%s" "$FR"; else command cygpath "$@"; fi; }; GSG_SHARE="$1"; install_cli_cmd_text >"$2"' \
            "$GSG_PROJECT" "$SANDBOX/instbin/$w.cmd" "$(cygpath -w "$SANDBOX/R&D $w")"
        run_cap env -i SystemRoot="$(cygpath -w "$(dirname "$TEST_SYSTEM32")")" LocalAppData="$(cygpath -w "$SANDBOX/R&D lad")" \
            "$TEST_SYSTEM32/cmd.exe" //c "$(cygpath -w "$SANDBOX/instbin/$w.cmd")" status </dev/null
        assert_rc 127 "the installed .cmd stops [$w]"
        assert_contains "$OUT$ERR" "R&D $w" "the path is printed whole [$w]"
        if [ "$w" = half ]; then assert_contains "$OUT$ERR" "R&D lad" "and the profile path with its ampersand"; else assert_contains "$OUT$ERR" "or an installer stopped" "a missing Git also fits a stopped installer"; fi
        assert_not_contains "$OUT$ERR" "is not recognized" "and nothing after the ampersand ran [$w]"
    done
    assert_contains "$OUT$ERR" "was not found" "a removed Git for Windows is reported as not found"
    assert_not_contains "$OUT$ERR" "half installed" "and not as half installed"
}

run_file_tests
