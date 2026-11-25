#!/usr/bin/env bash
# ^ invariant usage `name TAG` | `notes TAG SHA VERSION_FILE PULLS_JSON RELEASED_TAGS NOTES_OUT`; exit 0 ok, 1 refused (reason on stderr), 2 usage error
# ^ invariant NOTES_OUT is written only when every check passed; a refusal leaves no file behind
# ^ security no value read from an input is expanded by a shell; the pull request body goes from jq to the file as data
set -u
set -o pipefail

readonly SHA_LENGTH=40
readonly TAG_SHOWN_MAX=60
readonly VERSION_SHOWN_MAX=40
# ^ coupled lib/autoupdate/autoupdate.sh GSG_UPDATE_TAG_RE, the same pattern; a test compares the two lines
readonly TAG_RE='^v[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$'

usage() {
    printf 'usage: release-notes.sh name TAG\n       release-notes.sh notes TAG SHA VERSION_FILE PULLS_JSON RELEASED_TAGS NOTES_OUT\n' >&2
    exit 2
}

# ^ why every message starts with the script name, not with the reason; no log line can start with two colons (a workflow command) whatever a value says
refuse() {
    printf 'release-notes: %s\n' "$*" >&2
    exit 1
}

# ^ security a tag is quoted with %q and cut, never printed raw; a dispatcher types it
check_name() {
    if ! [[ $1 =~ $TAG_RE ]]; then
        refuse "$(printf '%q' "${1:0:TAG_SHOWN_MAX}") is not a release tag name (v<digits>.<digits>.<digits>)"
    fi
}

readable() { [ -r "$1" ] && [ ! -d "$1" ]; }

check_version() {
    local want="$1" file="$2" have=""
    IFS= read -r have <"$file" || [ -n "$have" ] || true
    [ "$have" = "$want" ] || refuse "VERSION at the tagged commit is [${have:0:VERSION_SHOWN_MAX}], the tag says [$want]"
}

# ^ why pick runs in the calling shell and sets globals, not a command substitution; a refusal there would end only the subshell
# ^ invariant pick JSON FILTER [JQ_ARG...] leaves the filtered array in PICKED and its length in PICKED_N
PICKED=""
PICKED_N=0
pick() {
    local json="$1" filter="$2"
    shift 2
    PICKED="$(printf '%s' "$json" | jq -c "$@" "$filter")" || refuse "cannot read the pull requests"
    PICKED_N="$(printf '%s' "$PICKED" | jq 'length')" || refuse "cannot count the pull requests"
}

# ^ invariant exactly one pull request has the commit as merge commit, is merged and carries the title; each stage names its own reason
select_release_pr() {
    local all="$1" sha="$2" title="$3"
    # shellcheck disable=SC2016 # $sha is a jq variable bound by --arg, not a shell expansion
    pick "$all" '[.[] | select(.merge_commit_sha == $sha)]' --arg sha "$sha"
    [ "$PICKED_N" -gt 0 ] || refuse "no pull request has the tagged commit as its merge commit"
    pick "$PICKED" '[.[] | select(.merged_at != null)]'
    [ "$PICKED_N" -gt 0 ] || refuse "the pull request of the tagged commit is not merged"
    # shellcheck disable=SC2016 # $title is a jq variable bound by --arg, not a shell expansion
    pick "$PICKED" '[.[] | select(.title == $title)]' --arg title "$title"
    [ "$PICKED_N" -gt 0 ] || refuse "no merged pull request of the tagged commit is titled [$title]"
    [ "$PICKED_N" -eq 1 ] || refuse "more than one merged pull request of the tagged commit is titled [$title]"
}

# ^ why the link line is the only text added, not a heading or a generated list; the pull request description is the notes
write_notes() {
    local out="$1"
    if ! printf '%s' "$PICKED" | jq -r '.[0] | ((.body // "") | sub("[ \t\r\n]+$"; "")) as $b | (if $b == "" then "" else $b + "\n\n" end) + "Release pull request: " + (.html_url // error("no html_url"))' >"$out"; then
        rm -f -- "$out"
        refuse "cannot write the release notes"
    fi
}

cmd_notes() {
    local tag="$1" sha="$2" version_file="$3" pulls="$4" released="$5" out="$6" version title all rc=0 sha_re="^[0-9a-f]{${SHA_LENGTH}}\$"
    [[ $sha =~ $sha_re ]] || usage
    if ! { readable "$version_file" && readable "$pulls" && readable "$released"; }; then usage; fi
    check_name "$tag"
    version="${tag#v}"
    title="Release $version"
    check_version "$version" "$version_file"
    all="$(jq -s -c 'map(if type == "array" then .[] else . end)' "$pulls")" || refuse "the pull request answer is not JSON"
    select_release_pr "$all" "$sha" "$title"
    grep -Fxq -- "$tag" "$released" || rc=$?
    case "$rc" in
        0) refuse "a release for $tag already exists" ;;
        1) ;;
        *) refuse "cannot read the list of releases" ;;
    esac
    write_notes "$out"
}

[ "$#" -ge 1 ] || usage
case "$1" in
    name)
        [ "$#" -eq 2 ] || usage
        check_name "$2"
        ;;
    notes)
        [ "$#" -eq 7 ] || usage
        shift
        cmd_notes "$@"
        ;;
    *) usage ;;
esac
