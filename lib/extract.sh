# shellcheck shell=bash

GSG_EXTRACT_AWK="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/extract.awk" || return 2

# ^ security --attr-source=<empty tree> => committed .gitattributes cannot hide text; test:test_a_committed_diff_or_binary_attribute_cannot_hide_added_text
# ^ external info/attributes and the system attributes file still apply under --attr-source; test:test_local_attribute_files_still_hide_text_a_documented_limit
# ^ security -c core.attributesFile=/dev/null => the user's attributes file and the XDG default cannot mark files -diff or binary
_staged_git_diff() {
    local empty_tree threshold=100g
    # ^ external Git for Windows keeps core.bigFileThreshold in 32 bits => 100g is out of range (probed), 4095m is the largest value it takes
    if gsg_is_windows; then threshold=4095m; fi
    # ^ hazard core.bigFileThreshold below the file size => git treats the file as binary, shows no + lines, the commit passes unscanned
    # ^ why empty tree computed by hash-object, not hard-coded; the id differs for sha256 repositories
    empty_tree="$(git hash-object -t tree /dev/null)" || return 1
    # ^ why explicit prefixes/context/no-ext-diff/no-textconv, not the user's diff config; noprefix, interHunkContext and external diff would change the parse
    # ^ why ACMRT, not ACMR; a symlink->file type change adds content
    # ^ hazard adding --text => binary content reaches the scanners; test:test_binary_content_is_not_extracted
    git --attr-source="$empty_tree" -c core.quotePath=false -c core.bigFileThreshold="$threshold" -c core.attributesFile=/dev/null diff --cached --no-color --no-ext-diff --no-textconv \
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

# ^ external git-lfs lists and pushes only blobs under 1024 bytes as pointers (measured 1023 yes, 1024 and 1025 no) => 1023 is the largest
GSG_LFS_POINTER_MAX=1023
# ^ external git-lfs reads the size with Go ParseInt, bitSize 64 => int64 max is the largest size it accepts
GSG_LFS_SIZE_MAX=9223372036854775807
# ^ external git-lfs trims Go unicode.IsSpace from both ends of a blob (probed on 3.7.1) => NBSP, NEL, U+2000..200A, U+2028/9, U+202F, U+205F, U+3000
GSG_LFS_SPACE=(" " $'\t' $'\n' $'\v' $'\f' $'\r' $'\xc2\x85' $'\xc2\xa0' $'\xe1\x9a\x80' $'\xe2\x80\x80' $'\xe2\x80\x81' $'\xe2\x80\x82' $'\xe2\x80\x83'
    $'\xe2\x80\x84' $'\xe2\x80\x85' $'\xe2\x80\x86' $'\xe2\x80\x87' $'\xe2\x80\x88' $'\xe2\x80\x89' $'\xe2\x80\x8a' $'\xe2\x80\xa8' $'\xe2\x80\xa9'
    $'\xe2\x80\xaf' $'\xe2\x81\x9f' $'\xe3\x80\x80')

# ^ invariant args = text; sets REPLY = the text without leading and trailing Go whitespace; each pass removes a byte or ends the loop, the cap bounds it
_lfs_trim_space() {
    local LC_ALL=C s="$1" t i moved
    for ((i = 0; i <= GSG_LFS_POINTER_MAX; i++)); do
        moved=0
        for t in "${GSG_LFS_SPACE[@]}"; do
            if [[ $s == "$t"* ]]; then s="${s#"$t"}" moved=1; fi
            if [[ $s == *"$t" ]]; then s="${s%"$t"}" moved=1; fi
        done
        if [ "$moved" -eq 0 ]; then break; fi
    done
    REPLY="$s"
}

# ^ external git-lfs refuses a negative size => a + and leading zeros pass, -0 passes, more than int64 does not (probed on 3.7.1)
# ^ invariant args = text; sets REPLY = decimal without sign or leading zeros (a numeric compare with the object size); rc 1 = not a size
_lfs_parse_size() {
    local LC_ALL=C digits
    if [[ $1 =~ ^[+]?([0-9]+)$ ]]; then
        digits="${BASH_REMATCH[1]}"
    elif [[ $1 =~ ^-0+$ ]]; then
        digits=0
    else
        return 1
    fi
    digits="${digits#"${digits%%[!0]*}"}"
    digits="${digits:-0}"
    if [ "${#digits}" -gt "${#GSG_LFS_SIZE_MAX}" ]; then return 1; fi
    # shellcheck disable=SC2071
    if [ "${#digits}" -eq "${#GSG_LFS_SIZE_MAX}" ] && [[ $digits > $GSG_LFS_SIZE_MAX ]]; then return 1; fi
    REPLY="$digits"
}

# ^ external git-lfs 3.7.1 decoder (probed) = trim the blob, split at LF, drop one CR, skip empty lines, version-oid-size in order, 3 version URLs
# ^ security a blob is a pointer by content only, as wide as git-lfs reads it => a form git-lfs pushes cannot pass as text
# ^ invariant args = blob text (NUL mapped to 0x01); rc 0 sets LFS_OID and LFS_SIZE, rc 1 = scan the blob as text
_lfs_parse_pointer() {
    local LC_ALL=C line key value step=0 i oid="" size="" ext=""
    local -a lines=()
    LFS_OID="" LFS_SIZE="" LFS_EXT=""
    if [ "${#1}" -gt "$GSG_LFS_POINTER_MAX" ]; then return 1; fi
    _lfs_trim_space "$1"
    mapfile -t lines <<<"$REPLY"
    for ((i = 0; i < ${#lines[@]}; i++)); do
        line="${lines[i]%$'\r'}"
        if [ -z "$line" ]; then continue; fi
        if [ "$step" -eq 3 ]; then return 1; fi
        key="${line%% *}" value="${line#* }"
        if [ "$key" = "$line" ]; then return 1; fi
        if [[ $key =~ ^ext-[0-9]-[A-Za-z0-9_] ]]; then
            [[ $value =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
            ext="${ext:-${key#ext-?-}}"
            continue
        fi
        case "$step:$key" in
            0:version) case "$value" in https://git-lfs.github.com/spec/v1 | https://hawser.github.com/spec/v1 | http://git-media.io/v/2) ;; *) return 1 ;; esac ;;
            1:oid) [[ $value =~ ^sha256:([0-9a-f]{64})$ ]] && oid="${BASH_REMATCH[1]}" || return 1 ;;
            2:size) _lfs_parse_size "$value" && size="$REPLY" || return 1 ;;
            *) return 1 ;;
        esac
        step=$((step + 1))
    done
    if [ "$step" -ne 3 ]; then return 1; fi
    LFS_OID="$oid" LFS_SIZE="$size" LFS_EXT="$ext"
}

# ^ why every git config scope, not only the user's; size and SHA-256 are checked on the copy, the place an object comes from decides no safety
# ^ security a committed .lfsconfig is never read, git config does not see it => a file in the commit cannot move the storage
# ^ invariant sets LFS_STORAGE = absolute dir with objects/ (default <common dir>/lfs, a relative value starts at the common dir); rc 1 = git failed
_lfs_storage_dir() {
    local common configured rc
    common="$(git rev-parse --path-format=absolute --git-common-dir)" || return 1
    configured="$(git config --type=path --get lfs.storage 2>/dev/null)"
    rc=$?
    if [ "$rc" -gt 1 ]; then return 1; fi
    configured="$(gsg_posix_path "$configured")" || return 1
    case "$configured" in
        "") LFS_STORAGE="$common/lfs" ;;
        /*) LFS_STORAGE="$configured" ;;
        *) LFS_STORAGE="$common/$configured" ;;
    esac
}

# ^ why the same diff flags as the extraction, not a pathspec-limited diff; a paired rename must count the lines the awk counted
# ^ invariant fills LFS_ADDED[path] = added lines of every file in the staged diff; rc 1 = git failed
_lfs_added_lines() {
    local rec path tab=$'\t' file="$1"
    declare -gA LFS_ADDED=()
    _staged_git_diff --numstat -z >"$file" || return 1
    while IFS= read -r -d '' rec; do
        [[ $rec =~ ^([0-9]+|-)$tab([0-9]+|-)$tab(.*)$ ]] || return 1
        path="${BASH_REMATCH[3]}"
        if [ -z "$path" ]; then
            IFS= read -r -d '' _ || return 1
            IFS= read -r -d '' path || return 1
        fi
        LFS_ADDED["$path"]="${BASH_REMATCH[1]}"
    done <"$file"
}

# ^ why 200, not another length; first_message and the other printed texts cut at 200 too
GSG_LFS_PATH_SHOW_MAX=200

# ^ security the path comes from the commit and the storage from git config => control characters are mapped to ? in both, the path is cut
_lfs_problem() {
    local reason="${2//[^[:print:]]/?}" shown="${1//[^[:print:]]/?}"
    trunc_text "$shown" "$GSG_LFS_PATH_SHOW_MAX"
    printf '%s: Git LFS file %s: %s\n' "$GSG_NAME" "$REPLY" "$reason" >&2
}

# ^ external sha256sum is coreutils, on PATH through GNUBIN_DIR on macOS and shipped with Git for Windows; no second tool is tried
# ^ invariant prints the hex digest of a file; rc 1 = sha256sum is missing, failed or printed no digest
_lfs_sha256() {
    local out
    out="$(sha256sum -- "$1" 2>/dev/null)" || return 1
    out="${out%% *}"
    [[ $out =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "$out"
}

# ^ invariant args = path, oid, destination; copies the object of LFS_STORAGE to the destination; rc 2 = problem printed
# ^ security the object must be a regular file and no symlink => a link cannot make the hook read another file
# ^ security the digest is taken from the scanned copy, not the storage file => nothing changes between the check and the scan
_lfs_fetch_object() {
    local path="$1" oid="$2" dest="$3" want="$4" obj digest have
    obj="$LFS_STORAGE/objects/${oid:0:2}/${oid:2:2}/$oid"
    if [ -L "$obj" ]; then
        _lfs_problem "$path" "its object is a symbolic link, not a regular file ($obj)"
    elif [ ! -e "$obj" ]; then
        _lfs_problem "$path" "its object is not in the LFS storage ($LFS_STORAGE)"
    elif [ ! -f "$obj" ]; then
        _lfs_problem "$path" "its object is not a regular file ($obj)"
    elif ! cp -- "$obj" "$dest" 2>/dev/null; then
        _lfs_problem "$path" "its object cannot be read ($obj)"
    elif ! have="$(wc -c <"$dest" | tr -d ' ')" || [ "$have" != "$want" ]; then
        _lfs_problem "$path" "its object is ${have:-of unknown size} bytes, the pointer says $want ($obj)"
    elif ! digest="$(_lfs_sha256 "$dest")"; then
        _lfs_problem "$path" "the SHA-256 of its object cannot be computed (sha256sum is missing or failed)"
    elif [ "$digest" != "$oid" ]; then
        _lfs_problem "$path" "its object does not match the pointer (SHA-256 differs from the oid; $obj)"
    else
        return 0
    fi
    return 2
}

# ^ why the staged blob, not the scan file; a changed pointer shows only its changed lines in the scan tree, the blob is whole
# ^ why one diff --raw -z, not a git call per path; test:test_small_plain_files_cost_no_git_process_per_file
# ^ invariant args = scan dir; fills LFS_B_PATHS and LFS_B_SHAS with the regular staged files holding a scan file => exclusions are honoured
_lfs_staged_blobs() {
    local dir="$1" raw="$1.lfs-raw" meta path mode sha status
    LFS_B_PATHS=() LFS_B_SHAS=()
    _staged_git_diff --raw -z --no-abbrev >"$raw" || return 1
    while IFS= read -r -d '' meta; do
        IFS=' ' read -r _ mode _ sha status <<<"${meta#:}"
        IFS= read -r -d '' path || return 1
        case "$status" in R* | C*) IFS= read -r -d '' path || return 1 ;; esac
        case "$mode" in 100644 | 100755) ;; *) continue ;; esac
        if [ -f "$dir/$path" ]; then
            LFS_B_PATHS+=("$path")
            LFS_B_SHAS+=("$sha")
        fi
    done <"$raw"
}

# ^ invariant fills LFS_P_PATHS, LFS_P_OIDS and LFS_P_SIZES with the staged LFS pointers; two git runs (sizes, small blobs) for any number of files
# ^ security NUL is mapped to 0x01 before bash reads a blob => no byte vanishes, and 0x01 is no whitespace and no word character, as in git-lfs
_lfs_find_pointers() {
    local LC_ALL=C dir="$1" in="$1.lfs-in" sizes="$1.lfs-sizes" batch="$1.lfs-batch" i=0 n=0 sha type bytes header body
    local -a small=() status=()
    LFS_P_PATHS=() LFS_P_OIDS=() LFS_P_SIZES=() LFS_P_EXTS=()
    if [ "${#LFS_B_SHAS[@]}" -eq 0 ]; then return 0; fi
    printf '%s\n' "${LFS_B_SHAS[@]}" >"$in" || return 1
    git cat-file --batch-check <"$in" >"$sizes" || return 1
    while read -r sha type bytes; do
        if [ "$type" = blob ] && [[ $bytes =~ ^[0-9]+$ ]] && [ "$bytes" -le "$GSG_LFS_POINTER_MAX" ]; then small+=("$i"); fi
        i=$((i + 1))
    done <"$sizes"
    if [ "$i" -ne "${#LFS_B_SHAS[@]}" ]; then return 1; fi
    if [ "${#small[@]}" -eq 0 ]; then return 0; fi
    for i in "${small[@]}"; do printf '%s\n' "${LFS_B_SHAS[i]}"; done >"$in" || return 1
    git cat-file --batch <"$in" | tr '\000' '\001' >"$batch"
    status=("${PIPESTATUS[@]}")
    if [ "${status[0]}" -ne 0 ] || [ "${status[1]}" -ne 0 ]; then return 1; fi
    while IFS= read -r header; do
        bytes="${header##* }"
        [[ $bytes =~ ^[0-9]+$ ]] || return 1
        body=""
        if [ "$bytes" -gt 0 ]; then IFS= read -r -N "$bytes" body || return 1; fi
        IFS= read -r -N 1 _ || return 1
        if [[ $body == *"oid sha256:"* ]] && _lfs_parse_pointer "$body"; then
            LFS_P_PATHS+=("${LFS_B_PATHS[small[n]]}")
            LFS_P_OIDS+=("$LFS_OID")
            LFS_P_SIZES+=("$LFS_SIZE")
            LFS_P_EXTS+=("$LFS_EXT")
        fi
        n=$((n + 1))
    done <"$batch"
    [ "$n" -eq "${#small[@]}" ]
}

# ^ external git calls a file binary when a NUL is in its first 8000 bytes (xdiff FIRST_FEW_BYTES), the same rule as the diff the extraction reads
GSG_BINARY_PROBE_BYTES=8000

# ^ invariant rc 0 = binary, 1 = text, 2 = the file could not be read
_lfs_is_binary() {
    local total kept
    [ -r "$1" ] || return 2
    total="$(wc -c <"$1" | tr -d ' ')" || return 2
    if [ "$total" -gt "$GSG_BINARY_PROBE_BYTES" ]; then total="$GSG_BINARY_PROBE_BYTES"; fi
    kept="$(head -c "$GSG_BINARY_PROBE_BYTES" -- "$1" | LC_ALL=C tr -d '\000' | wc -c | tr -d ' ')" || return 2
    [ "$kept" != "$total" ]
}

# ^ invariant prints the closing sentence of the block line after extract_lfs_objects failed; the advice matches the kinds of problem it saw
# ^ why separate advice, not one sentence; "git lfs install" and "git add" again cannot help a file stored through an extension
lfs_block_text() {
    local base ext obj
    base="the content of a staged Git LFS file could not be scanned (the lines above name the files and why), so nothing was committed"
    ext="a file stored through a Git LFS extension cannot be scanned: commit it without the extension (remove its lfs.extension setting for this path and 'git add' it again)"
    obj="run 'git lfs install', then 'git add' the file again, or commit from the machine that has the content"
    if [ "${GSG_LFS_FAIL_EXT:-0}" -eq 1 ] && [ "${GSG_LFS_FAIL_OBJECT:-0}" -eq 1 ]; then
        printf '%s; %s; for the other files, %s.' "$base" "$ext" "$obj"
    elif [ "${GSG_LFS_FAIL_EXT:-0}" -eq 1 ]; then
        printf '%s; %s.' "$base" "$ext"
    else
        printf '%s; %s.' "$base" "$obj"
    fi
}

# ^ invariant args = scan dir; swaps each staged pointer's scan file for its object and fixes the counts; rc 1 = a pointer was not followed
# ^ coupled lib/exempt.sh:exempt_extract_tree sets GSG_EXTRACT_FILES and GSG_EXTRACT_LINES first; the hook calls this right after it
extract_lfs_objects() {
    local dir="$1" obj="$1.lfs-object" i path rc obj_lines bad=0 first
    GSG_LFS_FAIL_EXT=0 GSG_LFS_FAIL_OBJECT=0
    first="$(find "$dir" -type f -print -quit)" || return 1
    if [ -z "$first" ]; then return 0; fi
    if ! _lfs_staged_blobs "$dir" || ! _lfs_find_pointers "$dir"; then
        printf '%s: cannot read the staged blobs to look for Git LFS pointers\n' "$GSG_NAME" >&2
        return 1
    fi
    if [ "${#LFS_P_PATHS[@]}" -eq 0 ]; then return 0; fi
    if ! _lfs_storage_dir || ! _lfs_added_lines "$dir.lfs-numstat"; then
        printf '%s: cannot find the Git LFS storage or count the staged lines\n' "$GSG_NAME" >&2
        return 1
    fi
    for ((i = 0; i < ${#LFS_P_PATHS[@]}; i++)); do
        path="${LFS_P_PATHS[i]}"
        # ^ security an extension stores the output of a clean command (gzip, rot13) => the object is not the file; the command is never run here
        if [ -n "${LFS_P_EXTS[i]}" ]; then
            trunc_text "${LFS_P_EXTS[i]}" "$GSG_LFS_PATH_SHOW_MAX"
            _lfs_problem "$path" "it uses the Git LFS extension $REPLY, so its stored object is transformed and cannot be scanned"
            bad=1 GSG_LFS_FAIL_EXT=1
            continue
        fi
        if ! _lfs_fetch_object "$path" "${LFS_P_OIDS[i]}" "$obj" "${LFS_P_SIZES[i]}"; then bad=1 GSG_LFS_FAIL_OBJECT=1; continue; fi
        mv -f -- "$obj" "$dir/$path" || return 1
        _lfs_is_binary "$dir/$path"
        rc=$?
        if [ "$rc" -eq 2 ]; then return 1; fi
        if [ "$rc" -eq 0 ]; then
            rm -f -- "$dir/$path" || return 1
            GSG_EXTRACT_FILES=$((GSG_EXTRACT_FILES - 1))
            GSG_EXTRACT_LINES=$((GSG_EXTRACT_LINES - ${LFS_ADDED["$path"]:-0}))
            continue
        fi
        obj_lines="$(LC_ALL=C awk 'END { print NR }' "$dir/$path")" || return 1
        GSG_EXTRACT_LINES=$((GSG_EXTRACT_LINES - ${LFS_ADDED["$path"]:-0} + obj_lines))
    done
    return "$bad"
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
