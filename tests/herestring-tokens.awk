# ^ invariant prints "FILE TOKEN" per here-string or here-doc operator outside comment lines; TOKEN = the operator and the next word
# ^ why the word after the operator, not the line; a token survives edits around it, and tests/herestring-bounded.list names it once per use
# ^ invariant quoted or inline-comment text can only add tokens => the lint fails, it never hides a real here-string
/^[[:space:]]*#/ { next }
{
    line = $0
    while ((i = index(line, "<<")) > 0) {
        rest = substr(line, i)
        op = "<<"
        if (substr(rest, 1, 3) == "<<<") op = "<<<"
        word = substr(rest, length(op) + 1)
        sub(/^[[:space:]]+/, "", word)
        sub(/[[:space:]].*$/, "", word)
        print FILENAME, op word
        line = substr(rest, length(op) + 1)
    }
}
