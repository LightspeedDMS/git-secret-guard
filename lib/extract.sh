# shellcheck shell=bash

GSG_EXTRACT_AWK="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/extract.awk" || return 2

# ^ security --attr-source=<empty tree> => committed .gitattributes cannot hide text; test:test_a_committed_diff_or_binary_attribute_cannot_hide_added_text
# ^ external info/attributes and the system attributes file still apply under --attr-source; test:test_local_attribute_files_still_hide_text_a_documented_limit
# ^ security -c core.attributesFile=/dev/null => the user's attributes file and the XDG default cannot mark files -diff or binary
_staged_git_diff() {
    local empty_tree
    # ^ hazard core.bigFileThreshold below the file size => git treats the file as binary, shows no + lines, the commit passes unscanned
    # ^ why empty tree computed by hash-object, not hard-coded; the id differs for sha256 repositories
    empty_tree="$(git hash-object -t tree /dev/null)" || return 1
    # ^ why explicit prefixes/context/no-ext-diff/no-textconv, not the user's diff config; noprefix, interHunkContext and external diff would change the parse
    # ^ why ACMRT, not ACMR; a symlink->file type change adds content
    # ^ hazard adding --text => binary content reaches the scanners; test:test_binary_content_is_not_extracted
    git --attr-source="$empty_tree" -c core.quotePath=false -c core.bigFileThreshold=100g -c core.attributesFile=/dev/null diff --cached --no-color --no-ext-diff --no-textconv \
        --inter-hunk-context=0 --src-prefix=a/ --dst-prefix=b/ --diff-filter=ACMRT "$@"
}

# ^ order callers pass "-- <pathspec>..." as arguments; nothing else may be added after the pathspecs
staged_diff() {
    _staged_git_diff -U0 "$@"
}

# ^ why numstat's first column, not the file list; binary shows "-" and a deletion-only change shows 0, neither adds scannable lines
staged_added_file_count() {
    _staged_git_diff --numstat "$@" | awk -F'\t' '$1 ~ /^[0-9]+$/ && $1 > 0 { n++ } END { print n + 0 }'
}

# ^ security awk error text names raw paths => one line, non-printable bytes = ?; test:test_an_awk_write_error_on_an_odd_path_is_sanitized_under_mawk
_extract_clean_stderr() {
    local text
    text="$(LC_ALL=C tr -c ' -~\n' '?')"
    text="${text//$'\n'/?}"
    if [ -n "$text" ]; then printf '%s\n' "$text" >&2; fi
}

# ^ why env, not awk -v; -v would interpret backslash escapes in the path
# ^ invariant lib/extract.awk prints only to files and /dev/stderr => 2>&1 into the sanitizer loses nothing; the status returned is awk's own
extract_added_lines() {
    local dir="$1" counts="${2:-}" rc
    mkdir -p -- "$dir" || return 2
    GSG_SCAN_DIR="$dir" GSG_EXTRACT_COUNTS="$counts" LC_ALL=C awk -f "$GSG_EXTRACT_AWK" 2>&1 | _extract_clean_stderr
    rc="${PIPESTATUS[0]}"
    return "$rc"
}
