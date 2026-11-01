#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# ^ coupled CONFIG_MATRIX with lib/extract.sh:_staged_git_diff; every key able to change the diff text belongs here
CONFIG_MATRIX=(
    core.bigFileThreshold=1
    core.attributesFile=ATTRS
    diff.external=/bin/false
    diff.renames=copies
    diff.renameLimit=1
    core.autocrlf=true
    core.autocrlf=input
    core.eol=crlf
    core.safecrlf=true
    core.whitespace=cr-at-eol
    diff.algorithm=minimal
    diff.indentHeuristic=false
    diff.noprefix=true
    diff.mnemonicPrefix=true
    diff.relative=true
    diff.suppressBlankEmpty=true
    diff.interHunkContext=9
    diff.context=9
    diff.wordRegex=x
    diff.ignoreSubmodules=all
    color.ui=always
    color.diff=always
    diff.colorMoved=zebra
    core.quotePath=true
    core.abbrev=4
    core.precomposeUnicode=true
    i18n.logOutputEncoding=UTF-16
    core.commitEncoding=UTF-16
)

BASE_ENV=()

begin() {
    new_repo "$1" || return 1
    MARKER="$(new_marker)"
    BASE_ENV=(STUB_LOG="$SANDBOX/calls-$1" STUB_MARKER="$MARKER" STUB_RECORD="$SANDBOX/record-$1")
    printf '*.txt -diff\n* binary\n' >"$SANDBOX/attrs-hide"
}

apply_config() {
    case "$1" in
        parameters) set_env GIT_CONFIG_PARAMETERS="'$2'='$3'" ;;
        environment) set_env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="$2" GIT_CONFIG_VALUE_0="$3" ;;
        repo) gitx config "$2" "$3" ;;
    esac
}

run_matrix() {
    local form="$1" entry key value i=0 file
    begin "matrix-$form" || return 1
    for entry in "${CONFIG_MATRIX[@]}"; do
        i=$((i + 1))
        key="${entry%%=*}"
        value="${entry#*=}"
        value="${value//ATTRS/$SANDBOX/attrs-hide}"
        file="f$i.txt"
        EXTRA_ENV=("${BASE_ENV[@]}")
        stage_file "$file" "payload $MARKER $i"
        apply_config "$form" "$key" "$value"
        commit_cap "$key=$value"
        assert_rc 0 "[$form $key=$value] commit"
        grep -qF -- "payload $MARKER $i" "$SANDBOX/record-matrix-$form.gitleaks" || fail "[$form $key=$value] the added line never reached the scanner"
        if [ "$form" = repo ]; then gitx config --unset-all "$key"; fi
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
