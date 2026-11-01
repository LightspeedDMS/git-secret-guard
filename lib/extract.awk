# ^ order hunk-counter rule before the +++ rule => an added line "++x" (shown "+++x") is content, not a header; port of ~/.config/git/hooks/pre-commit

function die(msg) {
    print "extract: " msg > "/dev/stderr"
    failed = 1
    exit 2
}

function clean(s) {
    gsub(/[^ -~]/, "?", s)
    return s
}

function shq(s) {
    gsub(/'/, "'\\''", s)
    return "'" s "'"
}

# ^ external git C-quotes odd names (\a \b \t \n \v \f \r \" \\ and \ooo); core.quotePath=false keeps bytes >= 0x80 raw
function unquote(s,    out, i, len, c, oct, n) {
    out = ""
    i = 1
    len = length(s)
    while (i <= len) {
        c = substr(s, i, 1)
        if (c != "\\") { out = out c; i++; continue }
        c = substr(s, i + 1, 1)
        if (c ~ /[0-7]/) {
            oct = substr(s, i + 1, 3)
            if (oct !~ /^[0-7][0-7][0-7]$/) die("bad octal escape in a quoted path")
            n = substr(oct, 1, 1) * 64 + substr(oct, 2, 1) * 8 + substr(oct, 3, 1)
            if (n == 0 || n > 127) die("unsupported byte escape in a quoted path")
            out = out sprintf("%c", n)
            i += 4
        } else if (c == "a") { out = out sprintf("%c", 7); i += 2 }
        else if (c == "b") { out = out sprintf("%c", 8); i += 2 }
        else if (c == "t") { out = out sprintf("%c", 9); i += 2 }
        else if (c == "n") { out = out sprintf("%c", 10); i += 2 }
        else if (c == "v") { out = out sprintf("%c", 11); i += 2 }
        else if (c == "f") { out = out sprintf("%c", 12); i += 2 }
        else if (c == "r") { out = out sprintf("%c", 13); i += 2 }
        else if (c == "\"" || c == "\\") { out = out c; i += 2 }
        else die("unknown escape in a quoted path")
    }
    return out
}

# ^ security every write stays inside the scan dir => reject empty, ".", ".." components and absolute paths
function check_path(p,    n, parts, i) {
    if (p == "") die("empty path")
    if (substr(p, 1, 1) == "/") die("absolute path refused: " clean(p))
    n = split(p, parts, "/")
    for (i = 1; i <= n; i++) {
        if (parts[i] == "" || parts[i] == "." || parts[i] == "..") die("unsafe path refused: " clean(p))
    }
}

function finish_file() {
    if (out != "" && close(out) != 0) die("write error on " clean(path))
    out = ""
}

function start_file(    slash, d) {
    if (path in seen) die("file appears twice in the diff: " clean(path))
    seen[path] = 1
    out = root "/" path
    outline = 0
    slash = match(path, /\/[^\/]*$/)
    if (slash > 0) {
        d = substr(path, 1, slash - 1)
        if (!(d in made)) {
            if (system("mkdir -p -- " shq(root "/" d)) != 0) die("cannot create directory for " clean(path))
            made[d] = 1
        }
    }
}

function add_line(text) {
    if (path == "") die("added line outside any file")
    if (out == "") start_file()
    if (lineno <= outline) die("non-increasing line numbers in " clean(path))
    while (outline < lineno - 1) { print "" > out; outline++ }
    print text > out
    outline++
}

BEGIN {
    root = ENVIRON["GSG_SCAN_DIR"]
    if (root == "") die("GSG_SCAN_DIR is not set")
}

(old > 0 || new > 0) {
    c = substr($0, 1, 1)
    if (c == "+") { add_line(substr($0, 2)); lineno++; new-- }
    else if (c == "-") { old-- }
    else if (c == " ") { lineno++; old--; new-- }
    else if (c != "\\") die("unexpected line inside a hunk")
    next
}

/^\+\+\+ / {
    finish_file()
    p = substr($0, 5)
    sub(/\t$/, "", p)
    path = ""
    if (p == "/dev/null") next
    if (substr(p, 1, 1) == "\"") {
        if (length(p) < 2 || substr(p, length(p), 1) != "\"") die("unterminated quoted path")
        p = unquote(substr(p, 2, length(p) - 2))
    }
    if (substr(p, 1, 2) != "b/") die("diff path without the b/ prefix: " clean(p))
    p = substr(p, 3)
    check_path(p)
    path = p
    next
}

/^@@ / {
    if ($0 !~ /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/) die("unparsable hunk header")
    split($0, f, " ")
    split(substr(f[2], 2), o, ",")
    split(substr(f[3], 2), w, ",")
    old = (o[2] == "" ? 1 : o[2] + 0)
    lineno = w[1] + 0
    new = (w[2] == "" ? 1 : w[2] + 0)
    next
}

END {
    if (!failed && (old > 0 || new > 0)) die("diff ended inside a hunk")
    if (!failed) finish_file()
}
