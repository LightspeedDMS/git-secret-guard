# shellcheck shell=bash
# ^ invariant these helpers read the guidance the hook printed in ERR; a remedy is applied as printed, never as the test wrote it
# ^ coupled lib/scan/report.sh:_report_guidance prints the step texts matched below; a reworded step fails these helpers first

GUIDANCE_STEP2="  2. A false positive or a test value, one line: put the marker of every scanner that reports the line on that same line."
GUIDANCE_STEP3="  3. A betterleaks finding on a line that cannot hold a marker: add its line to .gitleaksignore at the repository root:"

# ^ coupled lib/scan/report.sh:_report_guidance indents the lines under a step by this fixed prefix
GUIDANCE_INDENT="       "

# ^ invariant prints the line after the first line equal to $1 in ERR, without the fixed indent; fails and prints nothing when the line is missing
guidance_line_after() {
    local after line
    case "$ERR" in *"$1"$'\n'*) ;; *) return 1 ;; esac
    after="${ERR#*"$1"$'\n'}"
    line="${after%%$'\n'*}"
    printf '%s' "${line#"$GUIDANCE_INDENT"}"
}

# ^ invariant prints the marker text of step 2 to put on the line; the "both:" form when it is printed, else the one marker after its scanner name
guidance_marker() {
    local line
    line="$(guidance_line_after "$GUIDANCE_STEP2")" || return 1
    case "$line" in
        *"both: "*) printf '%s' "${line##*both: }" ;;
        *) printf '%s' "${line#*: }" ;;
    esac
}

# ^ invariant prints the first fingerprint line of step 3 exactly as printed (the file may hold a space)
guidance_fingerprint() { guidance_line_after "$GUIDANCE_STEP3"; }
