BEGIN {
    TAGS = "^(hazard|coupled|security|invariant|external|order|why|see|perf|todo)$"
    MAX_CHARS = 160
    MAX_RUN = 3
}

function fail(msg) { printf "%s:%d: %s\n", FILENAME, FNR, msg }

# ^ invariant sets comment_pos = first unquoted word-start "#" (0 if none) and carries in_s/in_d to the next line
function tokenize(line,    i, n, c, p) {
    comment_pos = 0
    n = length(line)
    for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (in_s) {
            if (in_ansi && c == "\\") { i++; continue }
            if (c == "'") in_s = 0
            continue
        }
        if (in_d) {
            if (c == "\\") { i++; continue }
            if (c == "\"") in_d = 0
            continue
        }
        if (c == "\\") { i++; continue }
        p = (i > 1) ? substr(line, i - 1, 1) : " "
        if (c == "'") { in_s = 1; in_ansi = (p == "$"); continue }
        if (c == "\"") { in_d = 1; continue }
        if (c == "#" && p ~ /[ \t;&|]/) { comment_pos = i; return }
    }
}

# ^ external here-string "<<<" is not a heredoc; only "<<WORD" and "<<-WORD" (quoted or bare) open a body
function heredoc_tag(line,    t) {
    gsub(/<<</, "   ", line)
    if (match(line, /<<-?[ \t]*["']?[A-Za-z_][A-Za-z0-9_]*["']?/) == 0) return ""
    t = substr(line, RSTART, RLENGTH)
    heredoc_dash = (t ~ /^<<-/)
    sub(/^<<-?[ \t]*["']?/, "", t)
    sub(/["']$/, "", t)
    return t
}

function check_coded(line,    tag, t) {
    run++
    if (run > MAX_RUN) fail("more than " MAX_RUN " coded lines in a row")
    if (match(line, /# \^ [a-z]*/) == 0) { fail("unknown tag: " line); return }
    tag = substr(line, RSTART + 4, RLENGTH - 4)
    if (tag !~ TAGS) fail("unknown tag [" tag "]: " line)
    if (tag == "why" && line !~ /, not /) fail("why needs ', not <alternative>': " line)
    if (line ~ / (so|but|because|which|that|then|however|while) /) fail("prose glue word: " line)
    t = line
    gsub(/(test|doc|see):[^ ;]+/, "", t)
    sub(/^[ \t]*# \^ [a-z]+ /, "", t)
    if (t ~ /: /) fail("colon glue: " line)
    if (tag == "order" && line !~ / (before|after) /) fail("order tag without before/after: " line)
    if (length(line) > MAX_CHARS) fail("longer than " MAX_CHARS " characters")
}

FNR == 1 {
    run = 0; in_s = 0; in_d = 0; in_ansi = 0; heredoc = ""; heredoc_dash = 0
    is_awk = (FILENAME ~ /\.awk$/)
}

heredoc != "" {
    t = $0
    if (heredoc_dash) sub(/^\t+/, "", t)
    if (t == heredoc) heredoc = ""
    next
}

{
    inside_quote = (in_s || in_d)
    if (!is_awk) tokenize($0)
    if (inside_quote) { run = 0; next }
}

/^[ \t]*#!/ { run = 0; next }
/^[ \t]*# shellcheck / { next }
/^[ \t]*# \^ / { check_coded($0); next }

{
    run = 0
    if ($0 ~ /^[ \t]*#/) fail("free comment: " $0)
    else if (!is_awk && comment_pos > 0) fail("trailing comment: " $0)
    if (!is_awk) heredoc = heredoc_tag($0)
}
