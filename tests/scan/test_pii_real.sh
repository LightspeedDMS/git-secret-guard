#!/usr/bin/env bash
# ^ external real betterleaks reads lib/scan/betterleaks-rule.toml => the pii-* rules are judged by the binary, never by parsing the TOML
# ^ security every sample is built at run time from fragments, never a literal, never printed => no_leak asserts absence; see docs/scan.md#pii-rules
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/scan/guidance_helpers.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/guidance_helpers.sh"

PII_EXCERPT=400
# ^ why published sample parts, not random ones; they pass every structure check of pii-us-ssn and each negative case varies one part
SSN_AREA=078 SSN_GROUP=05 SSN_SERIAL=1120
# ^ why a second sample; the JSON-key case must prove another number is caught and redacted too, not only the first
SSN2_AREA=219
SSN2_GROUP=09
SSN2_SERIAL=9999

need_real_tools() {
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    [ -x "$REAL_BETTERLEAKS" ] || skip_test "betterleaks not found at $REAL_BETTERLEAKS"
    use_real_tools
}

# ^ invariant ssn_dashed [AREA [GROUP [SERIAL]]]; a part left out is the sample part above
ssn_dashed() { printf '%s-%s-%s' "${1:-$SSN_AREA}" "${2:-$SSN_GROUP}" "${3:-$SSN_SERIAL}"; }

CASES=()
# ^ invariant case_file NAME EXPECT LINE... stages cases/NAME.txt; EXPECT is a rule ID or "none"; a staging failure fails the test, the case is never dropped
case_file() {
    local name="$1" expect="$2"
    shift 2
    if ! stage_file "cases/$name.txt" "$@"; then
        fail "could not stage cases/$name.txt"
        return 1
    fi
    CASES+=("cases/$name.txt $expect")
}
# ^ invariant a finding row reads "betterleaks  RULE (match)  FILE:LINE", the " (match)" after RULE keeps pii-us-ssn apart from pii-us-ssn-context
# ^ invariant a "none" case is judged by the file name and a colon anywhere in the output, the form every report row has
check_cases() {
    local spec file expect
    for spec in "${CASES[@]}"; do
        read -r file expect <<<"$spec"
        if [ "$expect" = none ]; then
            case "$ERR" in *"$file:"*) fail "[$file] is reported and must not be: ${ERR:0:PII_EXCERPT}" ;; esac
        elif [[ ! "$ERR" =~ betterleaks\ +$expect\ \(match\)\ +"$file":1 ]]; then
            fail "[$file] is not reported as $expect: ${ERR:0:PII_EXCERPT}"
        fi
    done
}

test_real_pii_bare_and_spaced_ssns_block_only_with_an_ssn_keyword() {
    need_real_tools
    local bare spaced json_ssn
    bare="$(ssn_dashed | tr -d -)" spaced="$(ssn_dashed | tr - ' ')"
    json_ssn="$(ssn_dashed "$SSN2_AREA" "$SSN2_GROUP" "$SSN2_SERIAL" | tr -d -)"
    new_repo pssn2 || return 1
    CASES=()
    case_file kw_bare pii-us-ssn-context "ssn: $bare"
    case_file kw_json pii-us-ssn-context "\"socialSecurityNumber\": \"$json_ssn\""
    case_file kw_spaced pii-us-ssn-context "SSN $spaced"
    case_file nokw_bare none "order $bare"
    case_file nokw_spaced none "$spaced"
    case_file kw_previous_line none "ssn:" "$bare"
    commit_cap "context ssns"
    assert_rc 1 "the three keyword lines block"
    check_cases
    assert_contains "$ERR" "3 potential secret(s)" "three SSN rows, no more (trufflehog reports none)"
    no_leak "$bare"
    no_leak "$spaced"
    no_leak "$json_ssn"
}

# ^ invariant the control line keeps the test red with no rule in place, a list of "none" cases alone passes with no rule at all
test_real_pii_invalid_ssn_structures_and_ssn_like_numbers_never_match() {
    need_real_tools
    new_repo pssn3 || return 1
    CASES=()
    case_file control pii-us-ssn "employee $(ssn_dashed)"
    case_file area000 none "x $(ssn_dashed 000)"
    case_file area666 none "x $(ssn_dashed 666)"
    case_file area9xx none "x $(ssn_dashed 912)"
    case_file group00 none "x $(ssn_dashed '' 00)"
    case_file serial0000 none "x $(ssn_dashed '' '' 0000)"
    case_file kw_area000 none "ssn $(ssn_dashed 000 | tr -d -)"
    case_file kw_group00 none "ssn $(ssn_dashed '' 00 | tr -d -)"
    case_file kw_serial0000 none "ssn $(ssn_dashed '' '' 0000 | tr -d -)"
    local yr=2024 mo=11 dy=17 tf1=1 tf2=800 tf3=555 tf4=0199 d2=12 d3=345 d4=6789
    case_file date none "date $yr-$mo-$dy"
    case_file tollfree none "call $tf1-$tf2-$tf3-$tf4"
    case_file digits232 none "id $d2-$d3-$d4"
    case_file longer none "id $(ssn_dashed 1078 05 11201)"
    commit_cap "ssn look-alikes"
    assert_rc 1 "the control SSN blocks"
    check_cases
    assert_contains "$ERR" "1 potential secret(s)" "the control row is the only one"
    no_leak "$(ssn_dashed)"
    no_leak "$SSN_AREA$SSN_GROUP$SSN_SERIAL"
}

# ^ invariant luhn_complete PREFIX LENGTH pads PREFIX with zeros to LENGTH-1 digits and appends the check digit of a Luhn-valid number
luhn_complete() {
    local s="$1" len="$2" i d sum=0 n
    while [ "${#s}" -lt $((len - 1)) ]; do s="${s}0"; done
    n="${#s}"
    for ((i = 0; i < n; i++)); do
        d="${s:n-1-i:1}"
        if [ $((i % 2)) -eq 0 ]; then
            d=$((d * 2))
            if [ "$d" -gt 9 ]; then d=$((d - 9)); fi
        fi
        sum=$((sum + d))
    done
    printf '%s%s' "$s" $(((10 - sum % 10) % 10))
}
# ^ invariant luhn_break NUMBER has the same shape and fails Luhn, the last digit moves by one
luhn_break() { printf '%s%s' "${1%?}" $(((${1: -1} + 1) % 10)); }

test_real_pii_a_card_finding_prints_the_betterleaks_only_guidance_and_its_marker_passes() {
    need_real_tools
    new_repo pguide || return 1
    local card marker
    card="$(luhn_complete 4 16)"
    stage_file tests/cards.txt "ok" "card $card" || return 1
    commit_cap "blocked"
    assert_rc 1 "the card blocks"
    assert_contains "$ERR" $'       betterleaks: betterleaks:allow\n' "only the betterleaks marker"
    assert_not_contains "$ERR" "trufflehog" "trufflehog is not named"
    assert_contains "$ERR" $'       tests/cards.txt:pii-credit-card:2\n' "the exact fingerprint line of the row"
    marker="$(guidance_marker)" || fail "no marker line in the output"
    assert_eq "$marker" "betterleaks:allow" "the marker, as printed"
    stage_file tests/cards.txt "ok" "card $card $marker" || return 1
    commit_cap "marked"
    assert_rc 0 "the printed marker passes in the same commit"
    no_leak "$card"
}

test_real_pii_card_numbers_block_when_luhn_valid_and_nothing_else_does() {
    need_real_tools
    local v16 v13 v19 mc5 mc2 amex disc d65 d644 sp mcsp uuid
    v16="$(luhn_complete 4 16)" v13="$(luhn_complete 4 13)" v19="$(luhn_complete 4 19)" mc5="$(luhn_complete 55 16)"
    mc2="$(luhn_complete 2223 16)" amex="$(luhn_complete 37 15)" disc="$(luhn_complete 6011 16)" d65="$(luhn_complete 65 16)"
    d644="$(luhn_complete 644 19)"
    sp="${v16:0:4} ${v16:4:4} ${v16:8:4} ${v16:12:4}" mcsp="${mc5:0:4} ${mc5:4:4} ${mc5:8:4} ${mc5:12:4}"
    uuid="$(printf '%s-%s-%s-%s-%s' 3f2a9c1e 7b4d 4e8a 9c05 d1e2f3a4b5c6)"
    new_repo pcard || return 1
    CASES=()
    case_file visa16 pii-credit-card "card $v16"
    case_file visa13 pii-credit-card "card $v13"
    case_file visa13_spaced pii-credit-card "card ${v13:0:4} ${v13:4:4} ${v13:8:5}"
    case_file visa13_dashed pii-credit-card "card ${v13:0:4}-${v13:4:4}-${v13:8:5}"
    case_file visa19 pii-credit-card "card $v19"
    case_file visa19_spaced pii-credit-card "card ${v19:0:4} ${v19:4:4} ${v19:8:4} ${v19:12:4} ${v19:16:3}"
    case_file visa16_then_cvv pii-credit-card "card $v16 123"
    case_file discover16_then_two pii-credit-card "card $disc 45"
    case_file luhn_fails_then_cvv none "card $(luhn_break "$v16") 123"
    case_file visa_spaced pii-credit-card "card $sp"
    case_file visa_dashed pii-credit-card "card ${sp// /-}"
    case_file mc_51_55 pii-credit-card "card $mc5"
    case_file mc_2221_2720 pii-credit-card "card $mc2"
    case_file mc_spaced pii-credit-card "$mcsp"
    case_file amex pii-credit-card "amex $amex"
    case_file amex_spaced pii-credit-card "amex ${amex:0:4} ${amex:4:6} ${amex:10:5}"
    case_file discover6011 pii-credit-card "card $disc"
    case_file discover65 pii-credit-card "card $d65"
    case_file discover644_19 pii-credit-card "card $d644"
    local p
    for p in 51 55 2221 2720 644 649 65; do case_file "edge_in_$p" pii-credit-card "card $(luhn_complete "$p" 16)"; done
    case_file edge_in_34 pii-credit-card "amex $(luhn_complete 34 15)"
    for p in 50 56 2220 2721 643; do case_file "edge_out_$p" none "card $(luhn_complete "$p" 16)"; done
    case_file edge_out_35 none "card $(luhn_complete 35 15)"
    case_file luhn_fails none "card $(luhn_break "$v16")"
    case_file luhn_fails_spaced none "card $(luhn_break "$mc5" | sed -E 's/(.{4})/\1 /g')"
    case_file no_card_prefix none "num $(luhn_complete 1 16)"
    case_file git_sha none "commit $(printf a | sha1sum | cut -c1-40)"
    case_file md5 none "md5 $(printf a | md5sum | cut -c1-32)"
    case_file uuid none "id $uuid"
    case_file inside_alnum none "tok x${v16}y"
    commit_cap "cards"
    assert_rc 1 "the Luhn-valid numbers block"
    check_cases
    no_leak "$v16"
    no_leak "$amex"
    no_leak "$sp"
    no_leak "$d644"
    no_leak "$disc"
}

# ^ invariant group4 STRING SEPARATOR cuts STRING in blocks of four, the print form of an IBAN
group4() {
    local s="$1" out="" i
    for ((i = 0; i < ${#s}; i += 4)); do out="${out:+$out$2}${s:i:4}"; done
    printf '%s' "$out"
}
# ^ why fragments, not a literal; this is the published example IBAN, valid by mod-97, and a literal would trip pii-iban in the tree scan
iban_valid() { printf '%s%s%s%s' "GB82WE" "ST1234" "5698" "765432"; }

# ^ invariant iban_build COUNTRY BBAN prints the IBAN with its mod-97 check digits computed, letters count as 10..35
iban_build() {
    local t="$2${1}00" i c n=0
    for ((i = 0; i < ${#t}; i++)); do
        c="${t:i:1}"
        case "$c" in [A-Z]) c=$(($(printf '%d' "'$c") - 55)) ;; esac
        n=$(((n * 10 ** ${#c} + c) % 97))
    done
    printf '%s%02d%s' "$1" $((98 - n)) "$2"
}

# ^ why a 24-character IBAN, not a shorter one; its last group is full and a word or number after it joins the match, the filter retries without it
test_real_pii_a_spaced_iban_followed_by_a_word_or_number_is_still_checked() {
    need_real_tools
    local b1=2100 b2=0418 b3=4502 b4=0005 b5=1332 es es_bad k
    es="$(iban_build ES "$b1$b2$b3$b4$b5")"
    k=$((10#${es:2:2}))
    es_bad="ES$(printf '%02d' $((k < 98 ? k + 1 : k - 1)))${es:4}"
    new_repo piban24 || return 1
    CASES=()
    case_file es_then_currency pii-iban "iban $(group4 "$es" ' ') EUR"
    case_file es_then_number pii-iban "iban $(group4 "$es" ' ') $b3"
    case_file es_bad_then_currency none "iban $(group4 "$es_bad" ' ') EUR"
    commit_cap "ibans with a tail"
    assert_rc 1 "the valid spaced IBANs block"
    check_cases
    no_leak "$es"
    no_leak "$es_bad"
    no_leak "$(group4 "$es" ' ')"
}

test_real_pii_ibans_block_when_mod97_valid_and_nothing_else_does() {
    need_real_tools
    local iban bad
    iban="$(iban_valid)" bad="GB83${iban:4}"
    new_repo piban || return 1
    CASES=()
    case_file compact pii-iban "iban $iban"
    case_file spaced pii-iban "iban $(group4 "$iban" ' ')"
    case_file mod97_fails none "iban $bad"
    case_file mod97_fails_spaced none "iban $(group4 "$bad" ' ')"
    case_file ulid none "id 01ARZ3NDEKTSV4RRFFQ69G5FAV"
    case_file aws_style_user_id none "user AIDAJQABLZS4A3QDU576Q"
    case_file inside_alnum none "x${iban}y"
    commit_cap "ibans"
    assert_rc 1 "the mod-97-valid IBANs block"
    check_cases
    no_leak "$iban"
    no_leak "$(group4 "$iban" ' ')"
}

# ^ why NANP-valid parts, not random digits; area and exchange start with 2-9, the structure check of pii-phone-context
test_real_pii_phone_numbers_need_a_phone_keyword_on_the_line() {
    need_real_tools
    local area=415 exchange=555 line=2671 e164 nanp intl
    e164="+1 $area $exchange $line" nanp="($area) $exchange-$line" intl="$(printf '+%s%s%s' 44 2079 460958)"
    new_repo pphone || return 1
    CASES=()
    case_file e164 pii-phone-context "phone: $e164"
    case_file nanp pii-phone-context "tel: $nanp"
    case_file intl pii-phone-context "mobile $intl"
    case_file json_key pii-phone-context "\"cellNumber\": \"$area-$exchange-$line\""
    case_file version none "version 1.$area.$exchange.$line"
    local yr=2026 mo=11 dy=17 o1=192 o2=168 o3=100 o4=200
    case_file date none "date $yr-$mo-$dy"
    case_file ip none "host $o1.$o2.$o3.$o4"
    case_file bare none "$e164"
    case_file keyword_version none "phone app version 1.4.5"
    case_file keyword_previous_line none "phone:" "$e164"
    commit_cap "phones"
    assert_rc 1 "the keyword lines block"
    check_cases
    assert_contains "$ERR" "4 potential secret(s)" "four phone rows, no more"
    no_leak "$e164"
    no_leak "$nanp"
    no_leak "$area-$exchange-$line"
    no_leak "$intl"
}

# ^ invariant stage_samples stages one file each for a dashed SSN, a Luhn-valid card, a lone AWS key ID and a fake GitHub token
stage_samples() {
    stage_file s/ssn.txt "employee $(ssn_dashed)" &&
        stage_file s/card.txt "card $(luhn_complete 4 16)" &&
        stage_file s/aws.txt "$(fake_aws_key)" &&
        stage_file s/token.txt "token = \"$(fake_github_token)\""
}

# ^ invariant a HEAD .gitleaks.toml replaces the main run's config and the extra run is --enable-rule aws-access-key-id only => no pii row from either run
test_real_pii_the_isolated_aws_run_reports_no_pii_and_existing_detection_is_unchanged() {
    need_real_tools
    new_repo piso0 || return 1
    stage_samples || return 1
    commit_cap "no repo config"
    assert_rc 1 "control: with no repo config the main run reports the PII samples"
    [[ "$ERR" =~ betterleaks\ +pii-us-ssn\ \(match\)\ +s/ssn\.txt:1 ]] || fail "control: pii-us-ssn row missing: ${ERR:0:PII_EXCERPT}"
    [[ "$ERR" =~ betterleaks\ +pii-credit-card\ \(match\)\ +s/card\.txt:1 ]] || fail "control: pii-credit-card row missing: ${ERR:0:PII_EXCERPT}"
    new_repo pii1 || return 1
    stage_file .gitleaks.toml '[extend]' 'useDefault = true' && gitx commit -q --no-verify -m config || return 1
    stage_samples || return 1
    commit_cap "repo config at HEAD"
    assert_rc 1 "the existing detection still blocks"
    assert_not_contains "$ERR" "pii-" "neither the main run nor the isolated run reports a PII rule"
    [[ "$ERR" =~ betterleaks.*aws-access-key-id.*\(match\)\ +s/aws\.txt:1 ]] || fail "the lone AWS key ID is not reported: ${ERR:0:PII_EXCERPT}"
    [[ "$ERR" =~ betterleaks\ +github-pat\ \(match\)\ +s/token\.txt:1 ]] || fail "the fake GitHub token is not reported by betterleaks: ${ERR:0:PII_EXCERPT}"
    [[ "$ERR" =~ trufflehog\ +Github\ \(match\)\ +s/token\.txt:1 ]] || fail "the fake GitHub token is not reported by trufflehog: ${ERR:0:PII_EXCERPT}"
    no_leak "$(fake_aws_key)"
    no_leak "$(fake_github_token)"
    no_leak "$(ssn_dashed)"
    no_leak "$(luhn_complete 4 16)"
}

# ^ external strace -f follows the scanners the hook starts; a "connect(" line with AF_INET/AF_INET6 and a non-loopback address is an outbound connection
# ^ invariant a skip names its reason => no strace or no ptrace permission leaves the zero-connect claim unproven on this host
test_real_pii_a_commit_holding_the_samples_makes_no_connect_to_a_non_loopback_address() {
    need_real_tools
    command -v strace >/dev/null 2>&1 || skip_test "strace is not installed: the zero-connect claim is not proven on this host"
    strace -o /dev/null -e trace=none true 2>/dev/null || skip_test "strace cannot trace here (ptrace is not allowed): the zero-connect claim is not proven on this host"
    local trace="$SANDBOX/connects.trace" outbound p_area=415 p_exchange=555 p_line=2671 tail_from
    local -a seccomp=()
    # ^ why probe --seccomp-bpf, not assume it; it cuts the tracing slowdown (a scanner can time out) and some hosts refuse it
    if strace --seccomp-bpf -f -o /dev/null -e trace=connect true 2>/dev/null; then seccomp=(--seccomp-bpf); fi
    new_repo pstrace || { fail "setup: new_repo pstrace"; return 1; }
    stage_samples || { fail "setup: stage_samples"; return 1; }
    stage_file s/iban.txt "iban $(iban_valid)" || { fail "setup: stage s/iban.txt"; return 1; }
    stage_file s/phone.txt "phone: +1 $p_area $p_exchange $p_line" || { fail "setup: stage s/phone.txt"; return 1; }
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" strace "${seccomp[@]}" -f -qq -e trace=connect,sendto,sendmsg -o "$trace" "$GIT" commit -q -m leak
    assert_rc 1 "the commit is blocked under strace"
    assert_not_contains "$ERR" "timed out" "a scanner timed out under strace"
    tail_from=$((${#ERR} > PII_EXCERPT ? ${#ERR} - PII_EXCERPT : 0))
    [[ "$ERR" =~ betterleaks\ +pii-credit-card\ \(match\) ]] || fail "the Luhn filter did not run under strace: ${ERR:tail_from}"
    [[ "$ERR" =~ betterleaks\ +pii-iban\ \(match\) ]] || fail "the mod-97 filter did not run under strace: ${ERR:tail_from}"
    [[ "$ERR" =~ trufflehog\ +Github\ \(match\) ]] || fail "trufflehog did not report under strace: ${ERR:tail_from}"
    [ -s "$trace" ] || { fail "strace wrote no trace: the check proved nothing"; return 1; }
    outbound="$(grep -E 'sa_family=AF_INET6?, ' "$trace" | grep -vE 'sin_addr=inet_addr\("127\.|inet_pton\(AF_INET6, "(::1|::ffff:127\.[0-9.]+)"' || true)"
    assert_empty "$outbound" "no connect to a non-loopback address by git, the hook or either scanner"
    no_leak "$(iban_valid)"
    no_leak "$(fake_github_token)"
    no_leak "$(fake_aws_key)"
}

run_file_tests
