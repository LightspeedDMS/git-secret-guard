#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/doctor.sh"

# ^ invariant prints t (terminal mode) or p (plain mode) for stream $1 as lib/core/common.sh decides it, with only the variables after $1 in the environment
# ^ why stdout and stderr are files here, not terminals; run_cap redirects both and mode t needs CLICOLOR_FORCE
# shellcheck disable=SC2016
ui_probe() {
    local fd="$1"
    shift
    run_cap env -i PATH="$TEST_BASE_PATH" "$@" bash -c 'source "$1/lib/core/common.sh" && if ui_terminal "$2"; then echo t; else echo p; fi' _ "$SHARE" "$fd"
    assert_rc 0 "ui_terminal $fd runs"
}

test_a_stream_that_is_not_a_terminal_gets_plain_mode() {
    ui_probe 1 TERM=xterm LANG=en_US.UTF-8
    assert_eq "$OUT" p "stdout is a file"
    ui_probe 2 TERM=xterm LANG=en_US.UTF-8
    assert_eq "$OUT" p "stderr is a file"
}

test_clicolor_force_makes_terminal_mode_for_both_streams() {
    ui_probe 1 CLICOLOR_FORCE=1 TERM=xterm LANG=en_US.UTF-8
    assert_eq "$OUT" t "stdout"
    ui_probe 2 CLICOLOR_FORCE=1 TERM=xterm LANG=en_US.UTF-8
    assert_eq "$OUT" t "stderr"
    ui_probe 1 CLICOLOR_FORCE= TERM=xterm LANG=en_US.UTF-8
    assert_eq "$OUT" p "an empty CLICOLOR_FORCE forces nothing"
}

test_no_color_wins_over_clicolor_force() {
    ui_probe 1 NO_COLOR=1 CLICOLOR_FORCE=1 TERM=xterm LANG=en_US.UTF-8
    assert_eq "$OUT" p "NO_COLOR set"
    ui_probe 1 NO_COLOR= CLICOLOR_FORCE=1 TERM=xterm LANG=en_US.UTF-8
    assert_eq "$OUT" t "an empty NO_COLOR is as good as unset"
}

test_a_missing_or_dumb_term_gets_plain_mode() {
    ui_probe 1 CLICOLOR_FORCE=1 TERM=dumb LANG=en_US.UTF-8
    assert_eq "$OUT" p "TERM=dumb"
    ui_probe 1 CLICOLOR_FORCE=1 LANG=en_US.UTF-8
    assert_eq "$OUT" p "TERM unset"
    ui_probe 1 CLICOLOR_FORCE=1 TERM= LANG=en_US.UTF-8
    assert_eq "$OUT" p "TERM empty"
}

test_the_locale_charset_must_be_utf8_by_the_first_non_empty_variable() {
    ui_probe 1 CLICOLOR_FORCE=1 TERM=xterm
    assert_eq "$OUT" p "no locale variable"
    ui_probe 1 CLICOLOR_FORCE=1 TERM=xterm LC_ALL=C
    assert_eq "$OUT" p "LC_ALL=C"
    ui_probe 1 CLICOLOR_FORCE=1 TERM=xterm LC_ALL=C LANG=en_US.UTF-8
    assert_eq "$OUT" p "LC_ALL comes before LANG"
    ui_probe 1 CLICOLOR_FORCE=1 TERM=xterm LC_ALL= LC_CTYPE=en_US.utf8 LANG=C
    assert_eq "$OUT" t "an empty LC_ALL is skipped and LC_CTYPE says utf8"
    ui_probe 1 CLICOLOR_FORCE=1 TERM=xterm LANG=C.UTF-8
    assert_eq "$OUT" t "LANG alone, upper case"
    ui_probe 1 CLICOLOR_FORCE=1 TERM=xterm LANG=de_DE.UtF8
    assert_eq "$OUT" t "any case"
    ui_probe 1 CLICOLOR_FORCE=1 TERM=xterm LANG=en_US.ISO-8859-1
    assert_eq "$OUT" p "another charset"
}

# ^ hazard bash warns on stderr for an LC_ALL locale the host lacks, and the terminal-mode tests compare stderr
# shellcheck disable=SC2016
test_the_forced_terminal_locale_exists_on_this_host_and_turns_terminal_mode_on() {
    ui_force_terminal
    run_cap env -i PATH="$TEST_BASE_PATH" "${EXTRA_ENV[@]}" bash -c 'source "$1/lib/core/common.sh" && if ui_terminal 1; then echo t; else echo p; fi' _ "$SHARE"
    assert_eq "$OUT" t "terminal mode with LC_ALL=$TEST_UTF8_LOCALE"
    assert_empty "$ERR" "the host has the locale: bash prints no setlocale warning"
}

# shellcheck disable=SC2016
test_the_mode_is_decided_once_per_process_and_stream() {
    run_cap env -i PATH="$TEST_BASE_PATH" CLICOLOR_FORCE=1 TERM=xterm LANG=en_US.UTF-8 bash -c '
        source "$1/lib/core/common.sh" || exit 2
        ui_terminal 1 && printf t || printf p
        unset CLICOLOR_FORCE
        ui_terminal 1 && printf t || printf p
        ui_terminal 2 && printf t || printf p' _ "$SHARE"
    assert_eq "$OUT" "ttp" "stdout is kept, stderr is decided on its own call and now sees a file"
}

# shellcheck disable=SC2016
ui_mark_probe() {
    run_cap env -i PATH="$TEST_BASE_PATH" "$@" bash -c '
        source "$1/lib/core/common.sh" || exit 2
        for tag in PROBLEM WARNING ok info; do ui_mark 1 "$tag"; printf "[%s]\n" "$REPLY"; done
        for tag in PROBLEM WARNING ok info; do ui_prefix 1 "$tag"; printf "<%s>\n" "$REPLY"; done' _ "$SHARE"
    assert_rc 0 "ui_mark runs"
}

test_plain_mode_marks_are_doctors_words_padded_to_8_and_prefixes_are_empty() {
    ui_mark_probe TERM=xterm LANG=en_US.UTF-8
    assert_eq "$OUT" "[PROBLEM ]
[WARNING ]
[ok      ]
[info    ]
<>
<>
<>
<>" "padded words, no escape sequence"
}

test_terminal_mode_marks_are_one_coloured_icon_each() {
    local esc=$'\e'
    ui_mark_probe CLICOLOR_FORCE=1 TERM=xterm LANG=en_US.UTF-8
    assert_eq "$OUT" "[${esc}[31m✗${esc}[0m]
[${esc}[33m▲${esc}[0m]
[${esc}[32m✓${esc}[0m]
[${esc}[2m•${esc}[0m]
<${esc}[31m✗${esc}[0m >
<${esc}[33m▲${esc}[0m >
<${esc}[32m✓${esc}[0m >
<${esc}[2m•${esc}[0m >" "icon only is coloured, the prefix adds one space"
}

# shellcheck disable=SC2016
test_an_unknown_tag_stays_plain_text_in_terminal_mode() {
    run_cap env -i PATH="$TEST_BASE_PATH" CLICOLOR_FORCE=1 TERM=xterm LANG=en_US.UTF-8 bash -c '
        source "$1/lib/core/common.sh" || exit 2
        ui_mark 1 odd; printf "[%s]" "$REPLY"
        ui_prefix 1 odd; printf "<%s>" "$REPLY"' _ "$SHARE"
    assert_eq "$OUT" "[odd     ]<>" "no icon, no escape sequence"
}

# shellcheck disable=SC2016
test_a_stream_number_other_than_1_or_2_is_refused() {
    run_cap env -i PATH="$TEST_BASE_PATH" bash -c 'source "$1/lib/core/common.sh" || exit 2; ui_terminal 3; echo "rc=$?"' _ "$SHARE"
    assert_eq "$OUT" "rc=2" "fail closed"
}

# shellcheck disable=SC2016
test_the_worst_level_picks_the_summary_icon_level() {
    run_cap env -i PATH="$TEST_BASE_PATH" bash -c '
        source "$1/lib/core/common.sh" || exit 2
        ui_worst 2 3; printf "%s " "$REPLY"
        ui_worst 0 3; printf "%s " "$REPLY"
        ui_worst 0 0; printf "%s" "$REPLY"' _ "$SHARE"
    assert_eq "$OUT" "PROBLEM WARNING ok" "problems first, then warnings, else ok"
}

# ^ invariant args = the text after the summary label, an optional icon in front of it; the summary is the last line of the status output
assert_summary() {
    local want="summary: $1"
    if [ -n "${2:-}" ]; then want="$2 $want"; fi
    case "$OUT" in
        *$'\n'"$want" | "$want") ;;
        *) fail "the last line is [$want], got [${OUT##*$'\n'}]" ;;
    esac
}

test_status_plain_output_has_sections_levels_and_a_summary() {
    fresh_install
    gsg status
    assert_rc 0 "status after install"
    assert_contains "$OUT" $'install:\n  info     installed version: ' "install section first, info level"
    assert_contains "$OUT" $'\ngit:\n  ok       git in use: ' "git section, git in use is ok"
    assert_contains "$OUT" $'\ntools:\n' "tools section"
    assert_contains "$OUT" $'\nauto-update:\n  info     auto-update: off' "auto-update section"
    assert_contains "$OUT" "  ok       hook command: $LC_DATA/hooks/secret-scan" "hook command is ok"
    assert_contains "$OUT" "  ok       hook libraries: " "hook libraries are ok"
    assert_contains "$OUT" "  ok       global config: matches" "global config is ok"
    assert_contains "$OUT" "  ok       bash: $(lc_recorded_bash)"$'\n' "the bash the install recorded (with .exe on Windows)"
    assert_contains "$OUT" "  info     share dir: $LC_DATA" "share dir is info"
    assert_contains "$OUT" "  ok       trufflehog: $LC_BIN/trufflehog$LC_EXE 3.99.2 (pinned 3.99.2)" "a tool is ok"
    assert_not_contains "$OUT" "(pinned 3.99.2) ok" "no trailing ok, the level says it"
    assert_summary "0 problems, 0 warnings"
    assert_not_contains "$OUT" $'\e' "no escape sequence in plain mode"
}

test_status_summary_counts_problems_and_uses_the_singular() {
    fresh_install
    rm -f -- "$LC_DATA/hooks/secret-scan" || return 1
    gsg status
    assert_rc 1 "a missing hook script"
    assert_contains "$OUT" "  PROBLEM  hook command: $LC_DATA/hooks/secret-scan (MISSING or not executable)" "problem level, wording kept"
    assert_summary "1 problem, 0 warnings"
    printf '#!/bin/sh\necho "trufflehog 3.0.0"\n' >"$LC_BIN/trufflehog$LC_EXE" || return 1
    gsg status
    assert_rc 1 "and a drifted scanner"
    assert_contains "$OUT" "  PROBLEM  trufflehog: " "tool problem"
    assert_contains "$OUT" "MISMATCH" "the word stays in the text"
    assert_summary "2 problems, 0 warnings"
}

test_status_not_installed_still_exits_1_with_a_problem_line_and_a_summary() {
    lc_begin || return 1
    gsg status
    assert_rc 1 "status before install"
    assert_contains "$OUT" "not installed" "says so"
    assert_contains "$OUT" "  PROBLEM  installed: not installed" "as a problem line"
    assert_summary "1 problem, 0 warnings"
}

test_status_in_terminal_mode_draws_icons_and_colours_only_the_icon() {
    local esc=$'\e'
    fresh_install
    ui_force_terminal
    gsg status
    assert_rc 0 "status"
    assert_contains "$OUT" "  ${esc}[32m✓${esc}[0m hook command: $LC_DATA/hooks/secret-scan" "ok icon, text plain"
    assert_contains "$OUT" "  ${esc}[2m•${esc}[0m share dir: $LC_DATA" "info icon"
    assert_not_contains "$OUT" "PROBLEM" "no tag word"
    assert_summary "0 problems, 0 warnings" "${esc}[32m✓${esc}[0m"
    rm -f -- "$LC_DATA/hooks/secret-scan" || return 1
    gsg status
    assert_rc 1 "a problem"
    assert_contains "$OUT" "  ${esc}[31m✗${esc}[0m hook command: " "problem icon"
    assert_summary "1 problem, 0 warnings" "${esc}[31m✗${esc}[0m"
}

test_status_stays_plain_with_no_color_even_when_a_terminal_is_forced() {
    fresh_install
    ui_force_terminal
    set_env NO_COLOR=1
    gsg status
    assert_not_contains "$OUT" $'\e' "no escape sequence"
    assert_not_contains "$OUT" "✓" "no icon"
    assert_contains "$OUT" "  ok       hook command: " "plain tags"
}

test_doctor_in_terminal_mode_draws_the_tag_as_an_icon_and_prefixes_the_summary() {
    local esc=$'\e' want icon
    dr_begin || return 1
    want="$(<"$GSG_PROJECT/VERSION")" || return 1
    icon="${esc}[32m✓${esc}[0m"
    doctor
    assert_not_contains "$OUT" $'\e' "plain mode has no escape sequence"
    ui_force_terminal
    doctor
    assert_rc 0 "healthy machine"
    assert_contains "$OUT" "  ${esc}[32m✓${esc}[0m installed: version $want" "ok line, icon instead of the tag"
    assert_not_contains "$OUT" "  ok       " "no tag word"
    # ^ why the icon follows the output, not a fixed green; a second older git on PATH (a CI runner's Apple git) adds a machine WARNING
    if [[ $OUT == *"${esc}[33m▲${esc}[0m"* ]]; then icon="${esc}[33m▲${esc}[0m"; fi
    assert_contains "$OUT" $'\n'"$icon summary: 0 repos, 0 covered" "summary with the worst level's icon"
}

test_doctor_in_terminal_mode_draws_repository_findings_with_the_problem_icon() {
    local esc=$'\e'
    dr_begin || return 1
    dr_repo off || return 1
    gitx -C "$DR_ROOTS/off" config hook.git-secret-guard.enabled false || return 1
    ui_force_terminal
    doctor
    assert_rc 1 "a repository without coverage"
    assert_contains "$OUT" "    ${esc}[31m✗${esc}[0m disabled in local config: hook.git-secret-guard.enabled=false" "finding icon, four-space indent"
    assert_not_contains "$OUT" "PROBLEM" "no tag word"
    assert_contains "$OUT" $'\n'"${esc}[31m✗${esc}[0m summary: 1 repos, 0 covered" "summary with the problem icon"
}

run_file_tests
