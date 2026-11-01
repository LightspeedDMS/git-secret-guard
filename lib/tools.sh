# shellcheck shell=bash disable=SC2034

GSG_LOCK_MAX_LINES=1000
GSG_VERSION_PROBE_SECONDS=20
GSG_TOOL_NAMES=(trufflehog gitleaks)

# ^ security GSG_TOOLS_LOCK swaps WHICH lock is trusted, never whether one is checked => see test:test_the_base_url_override_cannot_skip_verification
tools_lock_path() { printf '%s\n' "${GSG_TOOLS_LOCK:-$GSG_ROOT/tools.lock}"; }

tools_announce_overrides() {
    if [ -n "${GSG_TOOLS_BASE_URL:-}" ] || [ -n "${GSG_TOOLS_LOCK:-}" ]; then
        printf '%s: TEST OVERRIDE active (GSG_TOOLS_BASE_URL=[%s] GSG_TOOLS_LOCK=[%s]); downloads are still verified against the lock\n' \
            "$GSG_NAME" "${GSG_TOOLS_BASE_URL:-}" "${GSG_TOOLS_LOCK:-}" >&2
    fi
}

tools_has_version() {
    local bin="$1" pinned="$2" timeout_bin="$3" out
    if [ ! -f "$bin" ] || [ ! -x "$bin" ]; then return 1; fi
    out="$("$timeout_bin" "$GSG_VERSION_PROBE_SECONDS" "$bin" --version 2>&1)" || return 1
    tools_version_matches "$out" "$pinned"
}

# ^ invariant sets TOOL_FOUND = the reported version ("unknown" when none); rc 0 only when it is the pin, judged like tools_has_version
tools_probe_version() {
    local bin="$1" pinned="$2" timeout_bin="$3" out
    TOOL_FOUND=unknown
    out="$("$timeout_bin" "$GSG_VERSION_PROBE_SECONDS" "$bin" --version 2>&1)" || out=""
    if [[ $out =~ ([0-9]+\.[0-9]+[0-9A-Za-z.+-]*) ]]; then TOOL_FOUND="${BASH_REMATCH[1]}"; fi
    if tools_version_matches "$out" "$pinned"; then
        TOOL_FOUND="$pinned"
        return 0
    fi
    return 1
}

# ^ external the two vendors name the x86_64 build differently (trufflehog linux_amd64, gitleaks linux_x64); doc:tools.lock
tools_platform_key() {
    local tool="$1" os="$2" arch="$3" cpu
    case "$tool" in
        trufflehog | gitleaks) ;;
        *) printf '%s: unknown tool [%s]\n' "$GSG_NAME" "$tool" >&2; return 1 ;;
    esac
    case "$os:$arch" in
        Linux:x86_64) cpu=amd64; [ "$tool" = gitleaks ] && cpu=x64 ;;
        Linux:aarch64 | Linux:arm64) cpu=arm64 ;;
        *) printf '%s: only Linux on x86_64 or arm64 is supported, got %s on %s\n' "$GSG_NAME" "$os" "$arch" >&2; return 1 ;;
    esac
    printf 'linux_%s\n' "$cpu"
}

tools_tarball_name() {
    printf '%s_%s_%s.tar.gz\n' "$1" "$2" "$3"
}

# ^ security GSG_TOOLS_BASE_URL only moves where the tarball is fetched from => the SHA-256 check against a lock still decides
# ^ see test:test_the_base_url_override_cannot_skip_verification
tools_release_url() {
    local tool="$1" version="$2" platform="$3" name repo
    name="$(tools_tarball_name "$tool" "$version" "$platform")" || return 1
    case "$tool" in
        trufflehog) repo=trufflesecurity/trufflehog ;;
        gitleaks) repo=gitleaks/gitleaks ;;
        *) printf '%s: unknown tool [%s]\n' "$GSG_NAME" "$tool" >&2; return 1 ;;
    esac
    if [ -n "${GSG_TOOLS_BASE_URL:-}" ]; then
        printf '%s/%s\n' "${GSG_TOOLS_BASE_URL%/}" "$name"
    else
        printf 'https://github.com/%s/releases/download/v%s/%s\n' "$repo" "$version" "$name"
    fi
}

# ^ security https only by default; file is allowed solely when GSG_TOOLS_BASE_URL (tests) points the download elsewhere
# ^ invariant prints the tarball path only when its SHA-256 equals the expected one
tools_fetch_verified() {
    local tool="$1" version="$2" platform="$3" want="$4" dest_dir="$5" url name file proto got rc
    if [[ ! $want =~ ^[0-9a-f]{64}$ ]]; then
        printf '%s: the expected checksum for %s is not a SHA-256 (64 lowercase hex digits)\n' "$GSG_NAME" "$tool" >&2
        return 1
    fi
    url="$(tools_release_url "$tool" "$version" "$platform")" || return 1
    name="$(tools_tarball_name "$tool" "$version" "$platform")" || return 1
    file="$dest_dir/$name"
    proto='=https'
    if [ -n "${GSG_TOOLS_BASE_URL:-}" ]; then proto='=https,file'; fi
    # ^ hazard dropping curl -q => ~/.curlrc alters the verified download; test:test_curl_is_run_with_q_first_so_the_users_curlrc_is_ignored
    curl -q --fail --silent --show-error --location --proto "$proto" --proto-redir '=https' \
        --max-time 600 --max-filesize 500000000 --output "$file" -- "$url"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f -- "$file" || return 1
        printf '%s: downloading %s failed (curl exit %s)\n' "$GSG_NAME" "$url" "$rc" >&2
        return 1
    fi
    got="$(sha256sum -- "$file" | cut -d' ' -f1)" || { rm -f -- "$file"; return 1; }
    if [ "$got" != "$want" ]; then
        rm -f -- "$file" || return 1
        printf '%s: SHA-256 mismatch for %s: expected %s got %s; download removed, nothing installed\n' "$GSG_NAME" "$name" "$want" "$got" >&2
        return 1
    fi
    printf '%s\n' "$file"
}

# ^ security only the member named exactly like the tool is extracted, as a regular file => no path in the tarball can write elsewhere
tools_extract_binary() {
    local tarball="$1" tool="$2" dest="$3" listing member nl=$'\n'
    listing="$(tar -tzf "$tarball" 2>/dev/null)" || {
        printf '%s: cannot list the tarball %s\n' "$GSG_NAME" "$tarball" >&2
        return 1
    }
    case "$nl$listing$nl" in
        *"$nl$tool$nl"*) member="$tool" ;;
        *"$nl./$tool$nl"*) member="./$tool" ;;
        *) printf '%s: the tarball %s does not contain a file named %s\n' "$GSG_NAME" "$tarball" "$tool" >&2; return 1 ;;
    esac
    tar -xzf "$tarball" -C "$dest" --no-same-owner -- "$member" || {
        printf '%s: cannot extract %s from %s\n' "$GSG_NAME" "$tool" "$tarball" >&2
        return 1
    }
    if [ ! -f "$dest/$tool" ] || [ -L "$dest/$tool" ]; then
        rm -f -- "$dest/$tool" || return 1
        printf '%s: %s in the tarball is not a regular file\n' "$GSG_NAME" "$tool" >&2
        return 1
    fi
    chmod 755 -- "$dest/$tool"
}

# ^ external trufflehog prints "trufflehog 3.99.2", gitleaks prints "8.30.1" (version) or "gitleaks version 8.30.1" (--version); probed
tools_version_matches() {
    local output="$1" pinned="$2" word
    local -a words=()
    read -r -d '' -a words <<<"$output" || true
    for word in "${words[@]}"; do
        if [ "$word" = "$pinned" ] || [ "$word" = "v$pinned" ]; then return 0; fi
    done
    return 1
}

# ^ security every row validated, asked for or not => a lock unreadable in full is never trusted for one row
# ^ invariant rc 0 prints "<version> <sha256>"; rc 1 = no row for tool+platform; rc 2 = lock unreadable, malformed or ambiguous
tools_lock_lookup() {
    local lock="$1" tool="$2" platform="$3" line t v p s extra n=0 matches=0 found=""
    local -a lines=()
    if [ ! -r "$lock" ] || [ -d "$lock" ]; then
        printf '%s: cannot read the lock file %s\n' "$GSG_NAME" "$lock" >&2
        return 2
    fi
    mapfile -t -n "$((GSG_LOCK_MAX_LINES + 1))" lines <"$lock" || return 2
    if [ "${#lines[@]}" -gt "$GSG_LOCK_MAX_LINES" ]; then
        printf '%s: the lock file %s has more than %s lines\n' "$GSG_NAME" "$lock" "$GSG_LOCK_MAX_LINES" >&2
        return 2
    fi
    for line in "${lines[@]}"; do
        n=$((n + 1))
        if [[ $line =~ ^[[:space:]]*(#|$) ]]; then continue; fi
        read -r t v p s extra <<<"$line"
        if [ -n "$extra" ] || [[ ! $t =~ ^[a-z][a-z0-9-]*$ ]] || [[ ! $v =~ ^[0-9][0-9A-Za-z.+-]*$ ]] \
            || [[ ! $p =~ ^[a-z0-9_]+$ ]] || [[ ! $s =~ ^[0-9a-f]{64}$ ]]; then
            printf '%s: line %s is malformed in the lock file %s (want: tool version platform sha256, lowercase hex)\n' "$GSG_NAME" "$n" "$lock" >&2
            return 2
        fi
        if [ "$t" = "$tool" ] && [ "$p" = "$platform" ]; then
            matches=$((matches + 1))
            found="$v $s"
        fi
    done
    if [ "$matches" -gt 1 ]; then
        printf '%s: more than one row for %s on %s in the lock file %s\n' "$GSG_NAME" "$tool" "$platform" "$lock" >&2
        return 2
    fi
    if [ "$matches" -eq 0 ]; then
        printf '%s: no row for %s on %s in the lock file %s\n' "$GSG_NAME" "$tool" "$platform" "$lock" >&2
        return 1
    fi
    printf '%s\n' "$found"
}
