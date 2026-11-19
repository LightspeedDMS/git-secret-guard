# ^ external bash -x prints a command at the line where it starts; later lines of a multi-line command are never traced
function relpath(p,    i) {
    i = index(p, "/share/")
    if (i > 0) return substr(p, i + 7)
    sub(/^.*\/git-secret-guard\//, "", p)
    return p
}

function structural(l) {
    if (l == "" || l ~ /^#/) return 1
    if (l ~ /^(then|else|fi|do|done|esac|\{|\}|\(|\)|;;)/) return 1
    if (l ~ /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/) return 1
    if (l ~ /;; *$/) return 1
    if (l ~ /\) *$/ && l !~ /=/ && l !~ /^(if|elif|while|for|case)/) return 1
    return 0
}

BEGIN {
    while ((getline rec < trace) > 0) {
        # ^ external bash repeats the first PS4 character once per subshell level => "TTRACE" inside $( )
        if (match(rec, /^T+RACE [^:]+:[0-9]+:/)) {
            rec = substr(rec, index(rec, " ") + 1, RLENGTH - index(rec, " ") - 1)
            split(rec, parts, ":")
            hit[relpath(parts[1]) ":" parts[2]] = 1
        }
    }
    close(trace)
}

FNR == 1 { in_string = 0; continued = 0 }

{
    text = $0
    sub(/^[ \t]+/, "", text)
    skip = in_string || continued || structural(text)
    continued = ($0 ~ /\\$/)
    tmp = $0
    if (text !~ /^#/ && gsub(/\x27/, "", tmp) % 2 == 1) in_string = !in_string
    if (skip) next
    total[FILENAME]++
    if ((relpath(FILENAME) ":" FNR) in hit) covered[FILENAME]++
    else miss[FILENAME] = miss[FILENAME] sprintf("    %d: %s\n", FNR, text)
}

END {
    for (f in total) {
        printf "%-34s %3d/%-3d %5.1f%%\n", relpath(f), covered[f] + 0, total[f], (covered[f] + 0) * 100 / total[f]
        printf "%s", miss[f]
        all += total[f]
        allc += covered[f] + 0
    }
    printf "TOTAL %d/%d %.1f%%\n", allc, all, (all ? allc * 100 / all : 0)
}
