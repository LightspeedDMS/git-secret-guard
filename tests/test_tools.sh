#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

# shellcheck disable=SC2016
tl() { run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c 'set -u; source "$1/lib/common.sh" && source "$1/lib/tools.sh" && shift && "$@"' _ "$GSG_PROJECT" "$@"; }

test_the_lock_holds_exactly_the_eight_pinned_rows() {
    local rows
    rows="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$GSG_PROJECT/tools.lock" | LC_ALL=C sort)" || return 1
    assert_eq "$rows" "$(LC_ALL=C sort <<'EOF'
trufflehog 3.99.2 linux_amd64 3c7b0d1dc4278294269bfdd7594bca8bb28c78da0a4a06ad202ded37b48deca4
trufflehog 3.99.2 linux_arm64 929b81efffca752eafd58bf6f17bf725d354f338636a7bbbee65c086d2f9ddf3
trufflehog 3.99.2 darwin_amd64 c23a1b10522b8b84cfd04dc88a3a8819d3dc23b20f15e23540ba442b4b2fbeed
trufflehog 3.99.2 darwin_arm64 b612143d840b4c75d41fe40436c5932efead001951283f18c87013c4145e1675
betterleaks 1.9.0 linux_x64 f8b185a39ffcece2a1ca82bf3a4e7435cd81963ffd16b7a9128daf75f35f6de7
betterleaks 1.9.0 linux_arm64 1d39116e0a58dc94574715e2aa12a2dbd5062f193eee3fec011fef6ba06bd13b
betterleaks 1.9.0 darwin_x64 68dfd83458d9e7f90663daa7a81c7f944083b170dae82e4f5f8d0581ed519ef1
betterleaks 1.9.0 darwin_arm64 83dd7eaab13d44a1e8e347a17064cdef153a1478db473276d41b38d55613d3f2
EOF
)" "the lock rows match the story's table"
}

test_lock_lookup_returns_the_version_and_sha_for_a_tool_and_platform() {
    tl tools_lock_lookup "$GSG_PROJECT/tools.lock" betterleaks linux_x64
    assert_rc 0 lookup
    assert_eq "$OUT" "1.9.0 f8b185a39ffcece2a1ca82bf3a4e7435cd81963ffd16b7a9128daf75f35f6de7" "betterleaks linux_x64"
    tl tools_lock_lookup "$GSG_PROJECT/tools.lock" trufflehog linux_arm64
    assert_eq "$OUT" "3.99.2 929b81efffca752eafd58bf6f17bf725d354f338636a7bbbee65c086d2f9ddf3" "trufflehog linux_arm64"
}

lock_file() {
    local f="$SANDBOX/lock-$1"
    shift
    printf '%s\n' "$@" >"$f"
    printf '%s' "$f"
}

test_lock_lookup_refuses_a_missing_empty_malformed_or_ambiguous_lock() {
    local sha=3c7b0d1dc4278294269bfdd7594bca8bb28c78da0a4a06ad202ded37b48deca4 f
    tl tools_lock_lookup "$SANDBOX/no-such-lock" betterleaks linux_x64
    assert_rc 2 "missing lock"
    assert_contains "$ERR" "cannot read the lock file" "says why"
    tl tools_lock_lookup /dev/null betterleaks linux_x64
    assert_rc 1 "an empty lock has no row, it does not mean 'skip verification'"
    assert_contains "$ERR" "no row for betterleaks on linux_x64" "says what is missing"
    f="$(lock_file other '# only a comment' "trufflehog 3.99.2 linux_amd64 $sha")"
    tl tools_lock_lookup "$f" betterleaks linux_x64
    assert_rc 1 "a lock without the tool"
    local bad
    for bad in "betterleaks 1.9.0 linux_x64" "betterleaks 1.9.0 linux_x64 $sha extra" "betterleaks 1.9.0 linux_x64 ${sha:0:63}" \
        "betterleaks 1.9.0 linux_x64 ${sha^^}" "betterleaks 1.9.0 linux_x64 ${sha}0" "betterleaks ../x linux_x64 $sha" "betterleaks 1.9.0 linux/x64 $sha"; do
        f="$(lock_file bad "trufflehog 3.99.2 linux_amd64 $sha" "$bad")"
        tl tools_lock_lookup "$f" trufflehog linux_amd64
        assert_rc 2 "malformed row [$bad] taints the whole lock, even for another tool"
        assert_contains "$ERR" "line 2 is malformed" "names the line"
    done
    f="$(lock_file dup "betterleaks 1.9.0 linux_x64 $sha" "betterleaks 1.9.0 linux_x64 ${sha//3/4}")"
    tl tools_lock_lookup "$f" betterleaks linux_x64
    assert_rc 2 "two rows for one tool and platform are ambiguous"
    assert_contains "$ERR" "more than one row" "says why"
}

test_platform_keys_use_each_vendors_own_names_and_only_linux_and_macos_are_supported() {
    local tool os arch want
    while read -r tool os arch want; do
        tl tools_platform_key "$tool" "$os" "$arch"
        assert_rc 0 "$tool $os $arch"
        assert_eq "$OUT" "$want" "$tool on $os $arch"
    done <<'EOF'
trufflehog Linux x86_64 linux_amd64
trufflehog Linux aarch64 linux_arm64
trufflehog Linux arm64 linux_arm64
betterleaks Linux x86_64 linux_x64
betterleaks Linux aarch64 linux_arm64
betterleaks Linux arm64 linux_arm64
trufflehog Darwin arm64 darwin_arm64
trufflehog Darwin x86_64 darwin_amd64
betterleaks Darwin arm64 darwin_arm64
betterleaks Darwin x86_64 darwin_x64
EOF
    while read -r os arch; do
        tl tools_platform_key betterleaks "$os" "$arch"
        assert_rc 1 "[$os $arch] is not supported"
        assert_contains "$ERR" "only Linux and macOS on x86_64 or arm64 are supported" "says what is supported"
    done <<'EOF'
Darwin i386
FreeBSD amd64
Linux i686
Linux riscv64
Linux
EOF
    tl tools_platform_key semgrep Linux x86_64
    assert_rc 1 "an unknown tool"
    assert_contains "$ERR" "unknown tool" "says why"
}

test_release_urls_follow_the_vendor_patterns_and_the_base_url_override_replaces_only_the_prefix() {
    tl tools_release_url trufflehog 3.99.2 linux_amd64
    assert_eq "$OUT" "https://github.com/trufflesecurity/trufflehog/releases/download/v3.99.2/trufflehog_3.99.2_linux_amd64.tar.gz" "trufflehog URL"
    tl tools_release_url betterleaks 1.9.0 linux_x64
    assert_eq "$OUT" "https://github.com/betterleaks/betterleaks/releases/download/v1.9.0/betterleaks_1.9.0_linux_x64.tar.gz" "betterleaks URL"
    tl tools_tarball_name betterleaks 1.9.0 linux_arm64
    assert_eq "$OUT" "betterleaks_1.9.0_linux_arm64.tar.gz" "tarball name"
    set_env GSG_TOOLS_BASE_URL="file:///some/dir/"
    tl tools_release_url betterleaks 1.9.0 linux_x64
    assert_eq "$OUT" "file:///some/dir/betterleaks_1.9.0_linux_x64.tar.gz" "override keeps the tarball name, drops one trailing slash"
    tl tools_release_url bogus 1.0.0 linux_x64
    assert_rc 1 "unknown tool"
}

test_a_version_matches_only_as_a_whole_word_of_the_tool_output() {
    local out
    tl tools_version_matches "trufflehog 3.99.2" 3.99.2
    assert_rc 0 "plain"
    tl tools_version_matches "betterleaks version 1.9.0" 1.9.0
    assert_rc 0 "after a word"
    tl tools_version_matches "v1.9.0" 1.9.0
    assert_rc 0 "v prefix"
    tl tools_version_matches $'warning: x\nbetterleaks 1.9.0\n' 1.9.0
    assert_rc 0 "on a later line"
    for out in "trufflehog 3.99.20" "trufflehog 13.99.2" "trufflehog 3.99.2-rc1" "trufflehog 3.99" "trufflehog 3.99.2.1" "" "3.99.2x" "no version"; do
        tl tools_version_matches "$out" 3.99.2
        assert_rc 1 "[$out] is not 3.99.2"
    done
}

fixture_row() { awk -v t="$1" '$1 == t { print $2, $3, $4 }' "$LC_FIX/fixture.lock"; }

test_fetch_verified_downloads_and_accepts_a_matching_sha() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    local ver plat sha dest="$SANDBOX/dl"
    read -r ver plat sha <<<"$(fixture_row betterleaks)"
    mkdir -p -- "$dest"
    tl tools_fetch_verified betterleaks "$ver" "$plat" "$sha" "$dest"
    assert_rc 0 "fetch"
    assert_eq "$OUT" "$dest/betterleaks_${ver}_${plat}.tar.gz" "prints the tarball path"
    assert_file "$OUT" "the tarball is in place"
}

test_fetch_verified_refuses_a_mismatch_and_removes_the_download() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    local ver plat sha wrong dest="$SANDBOX/dl2"
    read -r ver plat sha <<<"$(fixture_row betterleaks)"
    wrong="${sha//[0-9]/a}"
    mkdir -p -- "$dest"
    tl tools_fetch_verified betterleaks "$ver" "$plat" "$wrong" "$dest"
    assert_rc 1 "mismatch refused"
    assert_contains "$ERR" "SHA-256 mismatch" "says what is wrong"
    assert_contains "$ERR" "expected $wrong" "names the expected hash"
    assert_contains "$ERR" "got $sha" "names the actual hash"
    assert_contains "$ERR" "download removed" "says the file is gone"
    assert_empty "$(ls -A "$dest")" "nothing is left in the download dir"
    tl tools_fetch_verified betterleaks "$ver" "$plat" "not-a-sha" "$dest"
    assert_rc 1 "a malformed expected hash is refused before any download"
    assert_contains "$ERR" "not a SHA-256" "says why"
    assert_empty "$(ls -A "$dest")" "and nothing was downloaded"
    tl tools_fetch_verified betterleaks 9.9.9 "$plat" "$sha" "$dest"
    assert_rc 1 "a download that fails is refused"
    assert_contains "$ERR" "failed (curl exit" "says why"
    assert_empty "$(ls -A "$dest")" "and leaves no partial file"
}

test_downloads_are_https_only_unless_the_test_base_url_is_set() {
    lc_begin || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "$*" >>"%s/curl.log"\nexit 7\n' "$SANDBOX" >"$SANDBOX/pathbin/curl" || return 1
    chmod 755 "$SANDBOX/pathbin/curl" || return 1
    local sha=3c7b0d1dc4278294269bfdd7594bca8bb28c78da0a4a06ad202ded37b48deca4
    set_env PATH="$SANDBOX/pathbin:/usr/bin:/bin"
    tl tools_fetch_verified betterleaks 1.9.0 linux_x64 "$sha" "$SANDBOX"
    assert_rc 1 "the recording curl fails the download"
    assert_contains "$(<"$SANDBOX/curl.log")" "--proto =https --proto-redir =https" "production default: https only, also across redirects"
    assert_not_contains "$(<"$SANDBOX/curl.log")" ",file" "no file protocol by default"
    assert_contains "$(<"$SANDBOX/curl.log")" "https://github.com/betterleaks/betterleaks/releases/download/v1.9.0/betterleaks_1.9.0_linux_x64.tar.gz" "the vendor URL"
    : >"$SANDBOX/curl.log"
    set_env GSG_TOOLS_BASE_URL="file:///nowhere"
    tl tools_fetch_verified betterleaks 1.9.0 linux_x64 "$sha" "$SANDBOX"
    assert_contains "$(<"$SANDBOX/curl.log")" "--proto =https,file --proto-redir =https" "override: file allowed for the first request only"
}

test_extract_takes_only_the_tool_binary_and_refuses_odd_tarballs() {
    lc_begin && lc_make_fixtures || return 1
    local ver plat sha dest="$SANDBOX/ex1" odd="$SANDBOX/odd"
    read -r ver plat sha <<<"$(fixture_row betterleaks)"
    mkdir -p -- "$dest" "$odd"
    tl tools_extract_binary "$LC_FIX/betterleaks_${ver}_${plat}.tar.gz" betterleaks "$dest"
    assert_rc 0 "extract"
    assert_eq "$(ls -A "$dest")" "betterleaks" "only the binary, no LICENSE or README"
    [ -x "$dest/betterleaks" ] || fail "the binary is not executable"
    assert_eq "$("$dest/betterleaks")" "betterleaks version $ver" "it is the tarball's binary"

    printf 'x\n' >"$odd/LICENSE" && tar -czf "$SANDBOX/nobin.tar.gz" -C "$odd" LICENSE || return 1
    tl tools_extract_binary "$SANDBOX/nobin.tar.gz" betterleaks "$SANDBOX/ex2"
    assert_rc 1 "no binary in the tarball"
    assert_contains "$ERR" "does not contain a file named betterleaks" "says why"

    rm -rf -- "$odd" && mkdir -p -- "$odd" && ln -s /bin/sh "$odd/betterleaks" && tar -czf "$SANDBOX/link.tar.gz" -C "$odd" betterleaks || return 1
    mkdir -p -- "$SANDBOX/ex3"
    tl tools_extract_binary "$SANDBOX/link.tar.gz" betterleaks "$SANDBOX/ex3"
    assert_rc 1 "a symlink in place of the binary"
    assert_contains "$ERR" "not a regular file" "says why"
    assert_empty "$(ls -A "$SANDBOX/ex3")" "and nothing is left behind"

    printf 'not a tarball\n' >"$SANDBOX/bad.tar.gz"
    tl tools_extract_binary "$SANDBOX/bad.tar.gz" betterleaks "$SANDBOX/ex3"
    assert_rc 1 "a corrupt archive"
    assert_contains "$ERR" "cannot list" "says why"
}

test_extract_reports_a_destination_it_cannot_write() {
    lc_begin && lc_make_fixtures || return 1
    local ver plat sha dest="$SANDBOX/ex-ro"
    read -r ver plat sha <<<"$(fixture_row betterleaks)"
    mkdir -p -- "$dest" && chmod 555 "$dest" || return 1
    tl tools_extract_binary "$LC_FIX/betterleaks_${ver}_${plat}.tar.gz" betterleaks "$dest"
    chmod 755 "$dest"
    assert_rc 1 "a read-only destination"
    assert_contains "$ERR" "cannot extract betterleaks" "says why"
}

test_lock_lookup_refuses_a_lock_with_too_many_lines() {
    local f="$SANDBOX/lock-long" i
    : >"$f"
    for ((i = 0; i < 1001; i++)); do printf '# comment %s\n' "$i" >>"$f"; done
    tl tools_lock_lookup "$f" betterleaks linux_x64
    assert_rc 2 "1001 lines"
    assert_contains "$ERR" "has more than 1000 lines" "says why"
}

run_file_tests
