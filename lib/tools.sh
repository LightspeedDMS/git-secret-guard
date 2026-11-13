# shellcheck shell=bash disable=SC2034

GSG_LOCK_MAX_LINES=1000
GSG_VERSION_PROBE_SECONDS=20
GSG_TOOL_NAMES=(trufflehog betterleaks)
# ^ external the previous build installed gitleaks and recorded it in the state file => state validation accepts it, install retires it
GSG_LEGACY_TOOL_NAMES=(gitleaks)
# ^ invariant jq joins GSG_TOOL_NAMES only inside an install run, by install_manage_jq; status and doctor see the two scanners
GSG_STATE_TOOL_NAMES=(trufflehog betterleaks gitleaks jq)

# ^ security GSG_TOOLS_LOCK swaps WHICH lock is trusted, never whether one is checked => see test:test_the_base_url_override_cannot_skip_verification
tools_lock_path() { printf '%s\n' "${GSG_TOOLS_LOCK:-$GSG_ROOT/tools.lock}"; }

tools_announce_overrides() {
    if [ -n "${GSG_TOOLS_BASE_URL:-}" ] || [ -n "${GSG_TOOLS_LOCK:-}" ]; then
        printf '%s: TEST OVERRIDE active (GSG_TOOLS_BASE_URL=[%s] GSG_TOOLS_LOCK=[%s]); downloads are still verified against the lock\n' \
            "$GSG_NAME" "${GSG_TOOLS_BASE_URL:-}" "${GSG_TOOLS_LOCK:-}" >&2
    fi
}

# ^ external Windows means Git for Windows bash (uname -s MINGW64_NT-*) running the native .exe scanners; WSL is Linux and takes the Linux rows
tools_is_windows() {
    case "$(uname -s)" in
        MINGW64_NT-*) return 0 ;;
    esac
    return 1
}

# ^ invariant the file name of a scanner on this platform; callers build "$dir/$(tools_binary_name "$tool")", never "$dir/$tool"
# ^ external trufflehog restarts itself by its own path and Go cannot start a Windows file without .exe (probed) => the scanners keep the .exe name
tools_binary_name() {
    if tools_is_windows; then
        printf '%s.exe\n' "$1"
    else
        printf '%s\n' "$1"
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

# ^ external the two vendors name the x86_64 build differently (trufflehog linux_amd64, betterleaks linux_x64); the same holds for windows_*; doc:tools.lock
tools_platform_key() {
    local tool="$1" os="$2" arch="$3" cpu prefix=linux
    case "$tool" in
        trufflehog | betterleaks | jq) ;;
        *) printf '%s: unknown tool [%s]\n' "$GSG_NAME" "$tool" >&2; return 1 ;;
    esac
    case "$os:$arch" in
        Linux:x86_64) cpu=amd64; [ "$tool" = betterleaks ] && cpu=x64 ;;
        Darwin:x86_64) prefix=darwin; cpu=amd64; [ "$tool" = betterleaks ] && cpu=x64 ;;
        Linux:aarch64 | Linux:arm64) cpu=arm64 ;;
        Darwin:arm64) prefix=darwin; cpu=arm64 ;;
        MINGW64_NT-*:x86_64) prefix=windows; cpu=amd64; [ "$tool" = betterleaks ] && cpu=x64 ;;
        *) printf '%s: only Linux and macOS on x86_64 or arm64, or Git for Windows on x86_64, are supported, got %s on %s\n' "$GSG_NAME" "$os" "$arch" >&2; return 1 ;;
    esac
    printf '%s_%s\n' "$prefix" "$cpu"
}

# ^ external the betterleaks Windows release is a .zip, every other asset is a .tar.gz
# ^ external jq ships a bare executable, jq-windows-amd64.exe, with no version in its name
tools_tarball_name() {
    local tool="$1" version="$2" platform="$3" ext=tar.gz
    # ^ external kernel.org ships git and its man pages as .tar.xz named <tool>-<version>, one tarball for every platform
    if [ "$tool" = git ] || [ "$tool" = git-manpages ]; then
        printf '%s-%s.tar.xz\n' "$tool" "$version"
        return 0
    fi
    if [ "$tool" = jq ]; then
        printf 'jq-%s.exe\n' "${platform//_/-}"
        return 0
    fi
    # ^ external the Git for Windows installer is Git-<a.b.c.n>-64-bit.exe; only the 64-bit one is pinned (platform windows_amd64)
    if [ "$tool" = git-for-windows ]; then
        printf 'Git-%s-64-bit.exe\n' "$version"
        return 0
    fi
    case "$platform" in
        windows_*) if [ "$tool" = betterleaks ]; then ext=zip; fi ;;
    esac
    printf '%s_%s_%s.%s\n' "$tool" "$version" "$platform" "$ext"
}

# ^ security GSG_TOOLS_BASE_URL only moves where the tarball is fetched from => the SHA-256 check against a lock still decides
# ^ see test:test_the_base_url_override_cannot_skip_verification
tools_release_url() {
    local tool="$1" version="$2" platform="$3" name repo tag="v$2"
    name="$(tools_tarball_name "$tool" "$version" "$platform")" || return 1
    case "$tool" in
        trufflehog) repo=trufflesecurity/trufflehog ;;
        betterleaks) repo=betterleaks/betterleaks ;;
        jq) repo=jqlang/jq tag="jq-$version" ;;
        git | git-manpages) repo="" ;;
        # ^ external version a.b.c.n is the release v<a.b.c>.windows.<n> of git-for-windows/git (2.56.0.4 = v2.56.0.windows.4)
        git-for-windows)
            repo=git-for-windows/git
            if [[ ! $version =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)$ ]]; then
                printf '%s: a Git for Windows version is a.b.c.n (2.56.0.4), got [%s]\n' "$GSG_NAME" "$version" >&2
                return 1
            fi
            tag="v${BASH_REMATCH[1]}.windows.${BASH_REMATCH[2]}"
            ;;
        *) printf '%s: unknown tool [%s]\n' "$GSG_NAME" "$tool" >&2; return 1 ;;
    esac
    if [ -n "${GSG_TOOLS_BASE_URL:-}" ]; then
        printf '%s/%s\n' "${GSG_TOOLS_BASE_URL%/}" "$name"
    elif [ -z "$repo" ]; then
        printf 'https://www.kernel.org/pub/software/scm/git/%s\n' "$name"
    else
        printf 'https://github.com/%s/releases/download/%s/%s\n' "$repo" "$tag" "$name"
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
        printf '%s: SHA-256 mismatch for %s: expected %s got %s; download removed\n' "$GSG_NAME" "$name" "$want" "$got" >&2
        return 1
    fi
    printf '%s\n' "$file"
}

# ^ security only the member named exactly like the binary is extracted, as a regular file => no path in the archive can write elsewhere
# ^ external on Windows bsdtar from System32 reads .tar.gz and .zip (GNU tar cannot read zip); found through SYSTEMROOT, never PATH
tools_extract_binary() {
    local tarball="$1" tool="$2" dest="$3" listing member nl=$'\n' bin tar_bin=tar list_flags=-tzf extract_flags=-xzf
    bin="$(tools_binary_name "$tool")" || return 1
    # ^ external the jq asset is the executable itself => nothing to list or unpack, the checksum already covered these bytes
    if [ "$tool" = jq ]; then
        cp -- "$tarball" "$dest/$bin" || return 1
        chmod 755 -- "$dest/$bin"
        return
    fi
    if tools_is_windows; then
        if [ -z "${SYSTEMROOT:-}" ]; then
            printf '%s: SYSTEMROOT is not set, cannot locate tar.exe\n' "$GSG_NAME" >&2
            return 1
        fi
        tar_bin="$(cygpath -u "$SYSTEMROOT")/System32/tar.exe" || return 1
        if [ ! -x "$tar_bin" ]; then
            printf '%s: %s not found; it ships with Windows 10 and 11\n' "$GSG_NAME" "$tar_bin" >&2
            return 1
        fi
        list_flags=-tf
        extract_flags=-xf
    fi
    listing="$("$tar_bin" "$list_flags" "$tarball" 2>/dev/null)" || {
        printf '%s: cannot list the tarball %s\n' "$GSG_NAME" "$tarball" >&2
        return 1
    }
    listing="${listing//$'\r'/}"
    case "$nl$listing$nl" in
        *"$nl$bin$nl"*) member="$bin" ;;
        *"$nl./$bin$nl"*) member="./$bin" ;;
        *) printf '%s: the tarball %s does not contain a file named %s\n' "$GSG_NAME" "$tarball" "$bin" >&2; return 1 ;;
    esac
    "$tar_bin" "$extract_flags" "$tarball" -C "$dest" --no-same-owner -- "$member" || {
        printf '%s: cannot extract %s from %s\n' "$GSG_NAME" "$bin" "$tarball" >&2
        return 1
    }
    if [ ! -f "$dest/$bin" ] || [ -L "$dest/$bin" ]; then
        rm -f -- "$dest/$bin" || return 1
        printf '%s: %s in the tarball is not a regular file\n' "$GSG_NAME" "$bin" >&2
        return 1
    fi
    chmod 755 -- "$dest/$bin"
}

# ^ external trufflehog prints "trufflehog 3.99.2", betterleaks prints "1.9.0" (version) or "betterleaks version 1.9.0" (--version); probed
# ^ external jq prints "jq-1.8.2", with CRLF from the native jq.exe (probed) => the carriage return would stick to the word
tools_version_matches() {
    local output="$1" pinned="$2" word
    local -a words=()
    read -r -d '' -a words <<<"${output//$'\r'/}" || true
    for word in "${words[@]}"; do
        if [ "$word" = "$pinned" ] || [ "$word" = "v$pinned" ] || [ "$word" = "jq-$pinned" ]; then return 0; fi
    done
    return 1
}

# ^ security every row validated, asked for or not => a lock unreadable in full is never trusted for one row
# ^ invariant rc 0 prints "<version> <sha256>" of the archive; with $4 = binary only the optional fifth column ("" when the row has none)
# ^ invariant rc 1 = no row for tool+platform; rc 2 = lock unreadable, malformed or ambiguous; one parse serves both outputs
tools_lock_lookup() {
    local lock="$1" tool="$2" platform="$3" mode="${4:-row}" line t v p s b extra n=0 matches=0 found="" foundbin=""
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
        read -r t v p s b extra <<<"$line"
        if [ -n "$extra" ] || [[ ! $t =~ ^[a-z][a-z0-9-]*$ ]] || [[ ! $v =~ ^[0-9][0-9A-Za-z.+-]*$ ]] \
            || [[ ! $p =~ ^[a-z0-9_]+$ ]] || [[ ! $s =~ ^[0-9a-f]{64}$ ]] || { [ -n "$b" ] && [[ ! $b =~ ^[0-9a-f]{64}$ ]]; }; then
            printf '%s: line %s is malformed in the lock file %s (want: tool version platform sha256 [binary sha256], lowercase hex)\n' "$GSG_NAME" "$n" "$lock" >&2
            return 2
        fi
        if [ "$t" = "$tool" ] && [ "$p" = "$platform" ]; then
            matches=$((matches + 1))
            found="$v $s"
            foundbin="$b"
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
    if [ "$mode" = binary ]; then
        printf '%s\n' "$foundbin"
    else
        printf '%s\n' "$found"
    fi
}

# ^ invariant prints the SHA-256 of the binary inside the release archive, or an empty line when the row has none; same return codes as tools_lock_lookup
tools_lock_binary_sha() { tools_lock_lookup "$1" "$2" "$3" binary; }
