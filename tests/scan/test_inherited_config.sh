#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

# ^ coupled CONFIG_MATRIX with lib/scan/extract.sh:_staged_git_diff; every key able to change the diff text belongs here
# ^ invariant an entry is "set name|key=value ..." and the keys of one set never conflict; a value holds no space
# ^ invariant conflicting values sit in different sets (diff.renames copies and false, core.autocrlf true and input, noprefix and mnemonicPrefix)
CONFIG_MATRIX=(
    "a|core.bigFileThreshold=1 core.attributesFile=ATTRS diff.renames=copies core.autocrlf=true diff.algorithm=minimal diff.noprefix=true diff.suppressBlankEmpty=true diff.interHunkContext=9 color.ui=always core.quotePath=true i18n.logOutputEncoding=UTF-16"
    "b|diff.external=/bin/false diff.renames=false core.autocrlf=input diff.indentHeuristic=false diff.mnemonicPrefix=true diff.context=9 diff.relative=true color.diff=always core.abbrev=4 core.commitEncoding=UTF-16 diff.ignoreSubmodules=all"
    "c|diff.renameLimit=1 core.eol=crlf core.safecrlf=true core.whitespace=cr-at-eol diff.wordRegex=x diff.colorMoved=zebra core.precomposeUnicode=true"
)

# ^ invariant the fixture holds a changed line in a tracked file and a rename with a changed line; an added line keeps its own line number
# ^ invariant args = repo name; leaves the change staged and EXTRA_ENV holding the stub variables, and sets MARKER
fixture() {
    new_repo "$1" || return 1
    MARKER="$(new_marker)"
    EXTRA_ENV=()
    printf '*.txt -diff\n* binary\n' >"$SANDBOX/attrs-hide" || return 1
    stage_file src/app.txt "app one" "app two" "app three" "app four" "" "app six" || return 1
    stage_file old/moved.txt "moved one" "moved two" "moved three" "moved four" "moved five" || return 1
    gitx commit -q --no-verify -m base || return 1
    EXTRA_ENV=(STUB_LOG="$SANDBOX/calls-$1" STUB_MARKER="$MARKER" STUB_RECORD="$SANDBOX/record-$1")
    stage_file src/app.txt "app one" "app two" "app three" "changed four $MARKER" "" "app six" || return 1
    mkdir -p new || return 1
    gitx mv old/moved.txt new/moved.txt || return 1
    stage_file new/moved.txt "moved one" "moved two $MARKER" "moved three" "moved four" "moved five" || return 1
}

# ^ invariant expected_scan prints what the scanner receives whatever the settings are, only the added lines at their own line numbers
# ^ external git pairs same-basename files first and skips rename detection once the remaining pairs pass diff.renameLimit squared (more lines, never fewer)
# ^ why the fixture creates only the renamed file, not a second one; a second created file with another basename can trip diff.renameLimit=1
expected_scan() {
    printf '== new/moved.txt\n\nmoved two %s\n== src/app.txt\n\n\n\nchanged four %s\n' "$MARKER" "$MARKER"
}

apply_config() {
    local form="$1" pair key value n=0 parameters=""
    shift
    case "$form" in
        parameters)
            for pair in "$@"; do
                key="${pair%%=*}"
                value="${pair#*=}"
                parameters+="'$key'='${value//ATTRS/$SANDBOX/attrs-hide}' "
            done
            set_env GIT_CONFIG_PARAMETERS="${parameters% }"
            ;;
        environment)
            set_env GIT_CONFIG_COUNT="$#"
            for pair in "$@"; do
                key="${pair%%=*}"
                value="${pair#*=}"
                set_env "GIT_CONFIG_KEY_$n=$key" "GIT_CONFIG_VALUE_$n=${value//ATTRS/$SANDBOX/attrs-hide}"
                n=$((n + 1))
            done
            ;;
        repo)
            for pair in "$@"; do
                key="${pair%%=*}"
                value="${pair#*=}"
                gitx config "$key" "${value//ATTRS/$SANDBOX/attrs-hide}" || return 1
            done
            ;;
    esac
}

# ^ invariant args = form, repo name, key=value...; rc 0 means the commit passed and the scanner got exactly expected_scan, else REASON says why
try_keys() {
    local form="$1" repo="$2" got
    shift 2
    REASON=""
    fixture "$repo" || { REASON="the fixture could not be built"; return 1; }
    apply_config "$form" "$@" || { REASON="the settings could not be applied"; return 1; }
    commit_cap "$repo"
    [ "$RC" -eq 0 ] || { REASON="the commit exited $RC: ${ERR:0:200}"; return 1; }
    got="$(<"$SANDBOX/record-$repo.betterleaks")" || { REASON="the scanner recorded nothing"; return 1; }
    [ "$got" = "$(expected_scan)" ] || { REASON="the scan text differs: [$got]"; return 1; }
}

# ^ why one commit per set, not per key; a failing set is rerun key by key in fresh repositories to name the keys
run_set() {
    local form="$1" set="$2" pair first_reason n=0
    shift 2
    local -a bad=()
    try_keys "$form" "m-$form-$set" "$@" && return 0
    first_reason="$REASON"
    for pair in "$@"; do
        n=$((n + 1))
        try_keys "$form" "m-$form-$set-$n" "$pair" || bad+=("$pair")
    done
    fail "[$form set $set] the scan text changed with: ${bad[*]:-no single key, only the combination}; set reason: $first_reason"
}

run_matrix() {
    local form="$1" entry set
    local -a keys=()
    for entry in "${CONFIG_MATRIX[@]}"; do
        set="${entry%%|*}"
        read -r -a keys <<<"${entry#*|}"
        run_set "$form" "$set" "${keys[@]}"
    done
}

test_no_config_passed_with_git_dash_c_or_in_the_parameters_variable_changes_what_is_extracted() {
    run_matrix parameters
}

test_no_config_passed_through_the_config_count_variables_changes_what_is_extracted() {
    run_matrix environment
}

test_no_repo_local_config_changes_what_is_extracted() {
    run_matrix repo
}

run_file_tests
