#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# ^ order sourced after tests/lib.sh and tests/lifecycle.sh => the helpers here build on lc_begin and the lifecycle PATH
# ^ security every tool the upgrade reaches (sudo, dnf, rpm, make, restorecon, df) is a recording stand-in first on PATH => no test can touch the real machine

# ^ invariant the libraries the CLI loads for install, in its order (install_tools holds install_cleanup, also removing the build dir)
# shellcheck disable=SC2016
GU_PRELUDE='set -u; GSG_ROOT="$1"; shift
for lib in brew common state tools hookspath install install_tools gitup gitup_source; do source "$GSG_ROOT/lib/$lib.sh" || exit 9; done
'

# ^ invariant gu_run BODY ARGS... runs BODY after the CLI libraries load in a clean shell; the lifecycle env and PATH apply
gu_run() {
    local body="$1"
    shift
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" bash -c "$GU_PRELUDE$body" _ "${GU_RUN_ROOT:-$GSG_PROJECT}" "$@"
}

# ^ invariant gu_call FN ARGS... runs one product function in the shell of gu_run
# shellcheck disable=SC2016
gu_call() { gu_run '"$@"' "$@"; }

# ^ invariant gu_reply FN ARGS... is gu_call for functions answering in REPLY; stdout is REPLY and the function's own output is dropped
# shellcheck disable=SC2016
gu_reply() { gu_run '"$@" >/dev/null || exit; printf "%s" "$REPLY"' "$@"; }

# ^ invariant a fixture os-release in the sandbox; GSG_OS_RELEASE points at it and no test reads the host's /etc/os-release
gu_os_release() {
    printf '%s\n' "$@" >"$SANDBOX/os-release" && set_env GSG_OS_RELEASE="$SANDBOX/os-release"
}

# ^ invariant gu_tree_with_module NAME CLASS reads the module source on stdin, copies the product to $GU_TREE, writes lib/gitup_NAME.sh
# ^ invariant and replaces the one reserved registry line of CLASS; a module is a file and a line, and lib/gitup.sh logic stays untouched
GU_TREE=""
gu_tree_with_module() {
    GU_TREE="$SANDBOX/proj"
    rm -rf -- "$GU_TREE" && mkdir -p -- "$GU_TREE" || return 1
    cp -a -- "$GSG_PROJECT/bin" "$GSG_PROJECT/lib" "$GSG_PROJECT/hooks" "$GSG_PROJECT/tools.lock" "$GSG_PROJECT/VERSION" "$GU_TREE/" || return 1
    gu_tree_add_module "$@"
}

# ^ invariant gu_tree_add_module NAME CLASS reads the module source on stdin into the existing GU_TREE and takes the reserved registry line of CLASS
gu_tree_add_module() {
    local name="$1" class="$2"
    cat >"$GU_TREE/lib/gitup_$name.sh" || return 1
    sed -i "s/^\\( *\\)$class) REPLY=\"\" ;;\$/\\1$class) REPLY=$name ;;/" "$GU_TREE/lib/gitup.sh" || return 1
    grep -q "^ *$class) REPLY=$name ;;\$" "$GU_TREE/lib/gitup.sh" || { printf 'gu_tree_with_module: no reserved line for %s\n' "$class" >&2; return 1; }
}

# ^ invariant gu_tree_add_class CLASS [MODULE] adds a synthetic class line to the registry of GU_TREE; no reserved line of a real class is read or changed
# ^ why a synthetic class, not debian or windows; real module branches take those lines and would each have to edit the same test
gu_tree_add_class() {
    sed -i "s/^\\( *\\)\\*) return 1 ;;\$/\\1$1) REPLY=\"${2:-}\" ;;\\n\\1*) return 1 ;;/" "$GU_TREE/lib/gitup.sh" || return 1
    grep -q "^ *$1) REPLY=\"${2:-}\" ;;\$" "$GU_TREE/lib/gitup.sh" || { printf 'gu_tree_add_class: the registry line for %s is missing\n' "$1" >&2; return 1; }
}

# ^ invariant gsg_tree runs the CLI of the copied tree with the lifecycle env; GU_TM_* variables reach the test module through EXTRA_ENV
gsg_tree() { run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GU_TREE/bin/git-secret-guard" "$@"; }

# ^ invariant the test module; plan prints a line and one privileged command, apply logs and can fail, hand off or install a git running the real one
GU_MODULE_OK='
gitup_testmod_plan() {
    if [ "$1" = refresh ]; then
        if [ -z "${GU_TM_REFRESH:-}" ]; then return 1; fi
        printf "  the test build is older than the pin\n"
    fi
    GITUP_ROUTE=${GU_TM_ROUTE:-testroute}
    GITUP_FOUND_GIT=${GU_TM_FOUND:-}
    printf "  testmod plan (%s): install a git with the test route\n" "$1"
    gitup_plan_priv "testmod-upgrade-git --as-root"
    return ${GU_TM_PLAN_RC:-0}
}
gitup_testmod_apply() {
    if declare -F gitup_testmod_hook >/dev/null; then gitup_testmod_hook || return $?; fi
    printf "apply\n" >>"$GU_TM_LOG"
    GITUP_NEXT=${GU_TM_NEXT:-}
    GITUP_NEW_GIT=$GU_TM_NEWGIT
    mkdir -p "${GU_TM_NEWGIT%/*}"
    if [ -n "${GU_TM_CHANGED:-}" ]; then GITUP_CHANGED="$GU_TM_CHANGED"; fi
    if [ "${GU_TM_APPLY_RC:-0}" -ne 0 ]; then return "$GU_TM_APPLY_RC"; fi
    printf "#!/bin/sh\nif [ \"\$1\" = --version ]; then echo \"git version %s\"; exit 0; fi\nexec %s \"\$@\"\n" "${GU_TM_NEWVER:-2.56.0}" "$GU_TM_REAL_GIT" >"$GU_TM_NEWGIT"
    chmod 755 "$GU_TM_NEWGIT"
}
'

# ^ invariant sets the env a test module reads; the log it appends to, the fake git it writes on apply (first on PATH) and the real git behind it
gu_module_env() {
    set_env GU_TM_LOG="$SANDBOX/testmod.log" GU_TM_NEWGIT="$SANDBOX/pathbin/git" GU_TM_REAL_GIT="$GIT" GSG_GITUP_ROOT="$SANDBOX/root"
    rm -f -- "$SANDBOX/testmod.log"
}

# ^ invariant gu_pty INPUT CMD... runs CMD with stdin, stdout and stderr on a pseudo-terminal and feeds INPUT to it; OUT holds the terminal text, ERR is empty
# ^ external util-linux script takes -qec on Linux; macOS has only the BSD /usr/bin/script (script -q FILE CMD...), Homebrew's util-linux ships no script
GU_PTY_LEAD_SECONDS=1 GU_PTY_HOLD_SECONDS=3
# ^ invariant a Mac test file sets GU_PTY_BSD=1 to run its prompt tests; the RPM and core prompt tests stay skipped on a Mac
: "${GU_PTY_BSD:=0}"
# ^ external BSD script sends EOF first when its stdin ends at once; input follows a lead and stdin stays open for a hold
gu_pty_bsd() {
    local input="$1"
    shift
    { sleep "$GU_PTY_LEAD_SECONDS"; printf '%s' "$input"; sleep "$GU_PTY_HOLD_SECONDS"; } | /usr/bin/script -q /dev/null "$@"
}

gu_pty() {
    local input="$1" cmd
    shift
    if [ "$TEST_OS" = Darwin ] && [ "$GU_PTY_BSD" != 1 ]; then skip_test "the prompt tests use the util-linux script"; fi
    if [ "$TEST_OS" = Darwin ]; then
        run_cap gu_pty_bsd "$input" "$@"
    else
        command -v script >/dev/null 2>&1 || skip_test "script (util-linux) is not available for a pseudo-terminal"
        printf -v cmd '%q ' "$@"
        run_cap script -qec "$cmd" /dev/null <<<"$input"
    fi
    OUT="${OUT//$'\r'/}"
}

gsg_pty() { gu_pty "$1" env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "${GU_BIN:-$GSG_PROJECT/bin/git-secret-guard}" "${@:2}"; }

# ^ invariant gu_old_git VERSION puts first on the sandbox PATH a wrapper reporting VERSION and running the real git otherwise
gu_old_git() {
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version %s"; exit 0; fi\nexec %s "$@"\n' "$1" "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git"
}

# ^ invariant lc_make_git_fixtures VERSION writes two kernel.org style tarballs into $LC_FIX and appends their pins to fixture.lock after lc_make_fixtures
lc_make_git_fixtures() {
    local v="$1" src="$LC_FIX/src" gsha msha
    mkdir -p -- "$src/git-$v" "$src/man/man1" || return 1
    printf 'all:\n\t@true\n' >"$src/git-$v/Makefile" || return 1
    printf 'man page\n' >"$src/man/man1/git.1" || return 1
    tar -cJf "$LC_FIX/git-$v.tar.xz" -C "$src" "git-$v" || return 1
    tar -cJf "$LC_FIX/git-manpages-$v.tar.xz" -C "$src/man" man1 || return 1
    gsha="$(sha256sum "$LC_FIX/git-$v.tar.xz" | cut -d' ' -f1)" || return 1
    msha="$(sha256sum "$LC_FIX/git-manpages-$v.tar.xz" | cut -d' ' -f1)" || return 1
    printf 'git %s source %s\ngit-manpages %s source %s\n' "$v" "$gsha" "$v" "$msha" >>"$LC_FIX/fixture.lock" || return 1
}

# ^ invariant gu_rpm_setup [OLD [PIN]] leaves a Rocky machine with git OLD (default 2.52.0) behind a wrapper and fixtures for pin PIN (default 2.56.0)
# ^ security GSG_GITUP_ROOT moves /usr, /var and /etc into the sandbox and the build PATH finds the make stand-in => nothing outside the sandbox is reachable
GU_ROOT=""
gu_rpm_setup() {
    # ^ why a skip, not a fix; the RPM module runs only on Rocky, RHEL and Fedora, and its source route lists files with GNU find -printf and -perm /111
    if ! env PATH="$TEST_BASE_PATH" find / -maxdepth 0 -printf x >/dev/null 2>&1; then skip_test "the RPM source route needs GNU find; this PATH has only BSD find"; fi
    lc_begin && gu_os_release 'ID="rocky"' 'ID_LIKE="rhel centos fedora"' && gu_old_git "${1:-2.52.0}" || return 1
    lc_make_fixtures && lc_make_git_fixtures "${2:-2.56.0}" && lc_use_fixtures || return 1
    GU_ROOT="$SANDBOX/root"
    rm -rf -- "$SANDBOX/tmp" || return 1
    mkdir -p -- "$GU_ROOT/usr/local/bin" "$GU_ROOT/usr/bin" "$GU_ROOT/etc/dnf" "$SANDBOX/tmp" || return 1
    set_env GSG_GITUP_ROOT="$GU_ROOT" GSG_GITUP_BUILD_PATH="$SANDBOX/pathbin:/usr/bin:/bin" GSG_GITUP_QUERY_TIMEOUT=3 \
        PATH="$GU_ROOT/usr/local/bin:$SANDBOX/pathbin:$TEST_BASE_PATH" || return 1
    gu_module_env || return 1
}

# ^ invariant gu_old_build VERSION leaves a build of ours in the sandbox /usr/local; a git wrapper reporting VERSION (hooks skipped when newgit.broken exists)
# ^ invariant one wrapper per sibling, an obsolete man page and the MANIFEST at share/doc/git-VERSION-local listing them
gu_old_build() {
    local v="$1" b="$GU_ROOT/usr/local/bin" doc="$GU_ROOT/usr/local/share/doc/git-$1-local" s manifest
    manifest="$doc/MANIFEST"
    mkdir -p -- "$b" "$doc" "$GU_ROOT/usr/local/share/man/man1" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version %s"; exit 0; fi\ncase " $* " in *" commit "*) if [ -f "%s/newgit.broken" ]; then exit 0; fi ;; esac\nexec %s "$@"\n' \
        "$v" "$SANDBOX" "$GIT" >"$b/git" || return 1
    chmod 755 "$b/git" || return 1
    printf '%s\n' "$b/git" >"$manifest" || return 1
    for s in receive-pack upload-pack upload-archive; do
        # shellcheck disable=SC2016
        printf '#!/bin/sh\nexec %s %s "$@"\n' "$GIT" "$s" >"$b/git-$s" || return 1
        chmod 755 "$b/git-$s" || return 1
        printf '%s\n' "$b/git-$s" >>"$manifest" || return 1
    done
    for s in git-shell scalar; do
        printf '#!/bin/sh\nexit 0\n' >"$b/$s" || return 1
        chmod 755 "$b/$s" || return 1
        printf '%s\n' "$b/$s" >>"$manifest" || return 1
    done
    printf 'old man page\n' >"$GU_ROOT/usr/local/share/man/man1/obsolete.1" || return 1
    printf '%s\n' "$GU_ROOT/usr/local/share/man/man1/obsolete.1" >>"$manifest" || return 1
}

GU_TK_NAMES=(git git-receive-pack git-shell git-upload-archive git-upload-pack scalar)

# ^ invariant gu_tk_setup leaves a Rocky sandbox with the RPM git 2.52.0 in /usr/bin (six files, distinct contents) and a build of ours at 2.56.0 first on PATH
# ^ invariant the rpm stand-in describes git-core 2.52.0 with the sibling packages git, git-core-doc and perl-Git
gu_tk_setup() {
    local n
    gu_rpm_setup 2.52.0 "${1:-2.56.0}" && gu_old_build 2.56.0 || return 1
    : >"$SANDBOX/rpm.files" || return 1
    for n in "${GU_TK_NAMES[@]}"; do
        case "$n" in
            git-receive-pack | git-upload-archive | git-upload-pack) ln -s git "$GU_ROOT/usr/bin/$n" || return 1 ;;
            *)
                # shellcheck disable=SC2016
                printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.52.0"; exit 0; fi\necho "rpm original %s"\n' "$n" >"$GU_ROOT/usr/bin/$n" || return 1
                chmod 755 "$GU_ROOT/usr/bin/$n" || return 1
                ;;
        esac
        printf '/usr/bin/%s\n' "$n" >>"$SANDBOX/rpm.files" || return 1
    done
    printf '/usr/libexec/git-core/git\n/usr/share/doc/git-core/README\n' >>"$SANDBOX/rpm.files" || return 1
    printf 'git-core\n' >"$SANDBOX/rpm.owner" || return 1
    printf 'git-core-2.52.0-1.el9.x86_64\n' >"$SANDBOX/rpm.nevra" || return 1
    printf 'git-2.52.0-1.el9.src.rpm\n' >"$SANDBOX/rpm.srpm" || return 1
    printf 'git git-2.52.0-1.el9.src.rpm\ngit-core git-2.52.0-1.el9.src.rpm\ngit-core-doc git-2.52.0-1.el9.src.rpm\nperl-Git git-2.52.0-1.el9.src.rpm\nbash bash-5.1.8-9.el9.src.rpm\n' \
        >"$SANDBOX/rpm.all" || return 1
    printf '[main]\ngpgcheck=1\ntsflags=nodocs\n' >"$GU_ROOT/etc/dnf/dnf.conf" || return 1
    GU_TK_DIR="$GU_ROOT/var/lib/git-secret-guard/system-git"
}

# ^ invariant prints the SHA-256 and the link state of the six /usr/bin files, one line each; two equal outputs mean the files are byte for byte the same
gu_hashes() {
    local n sum
    for n in "${GU_TK_NAMES[@]}"; do
        if [ -L "$GU_ROOT/usr/bin/$n" ]; then
            printf '%s symlink-to %s\n' "$n" "$(readlink "$GU_ROOT/usr/bin/$n")" || return 1
        else
            sum="$(sha256sum "$GU_ROOT/usr/bin/$n")" || return 1
            printf '%s %s\n' "$n" "${sum%% *}" || return 1
        fi
    done
}

# ^ invariant the classes of tests/gitup.sh fixtures; id|id_like|class
GU_CLASS_TABLE=(
    'rocky|rhel centos fedora|rpm'
    'rhel|fedora|rpm'
    'almalinux|rhel centos fedora|rpm'
    'centos|rhel fedora|rpm'
    'fedora||rpm'
    'ubuntu|debian|ubuntu'
    'debian||debian'
    'linuxmint|ubuntu debian|ubuntu'
    'alpine||other'
)

gu_log() { if [ -f "$SANDBOX/gitup.log" ]; then cat -- "$SANDBOX/gitup.log"; fi; }
gu_conf() { cat -- "$GU_ROOT/etc/dnf/dnf.conf"; }

gu_all_symlinks() {
    local n
    for n in "${GU_TK_NAMES[@]}"; do
        if [ ! -L "$GU_ROOT/usr/bin/$n" ] || [ "$(readlink "$GU_ROOT/usr/bin/$n")" != "$GU_ROOT/usr/local/bin/$n" ]; then return 1; fi
    done
}

# ^ invariant needs GU_BEFORE and GU_CONF_BEFORE from gu_tk_start; the machine is exactly as the RPM left it
gu_untouched() {
    assert_eq "$(gu_hashes)" "$GU_BEFORE" "$1: the six originals are byte for byte the same (links stay links)"
    assert_eq "$(gu_conf)" "$GU_CONF_BEFORE" "$1: dnf.conf is as it was"
    assert_no_file "$GU_TK_DIR" "$1: no backup directory"
    assert_eq "$("$GU_ROOT/usr/bin/git" --version)" "git version 2.52.0" "$1: /usr/bin/git works"
}

gu_tk_start() {
    gu_tk_setup "${GU_TK_PIN:-}" || return 1
    GU_BEFORE="$(gu_hashes)" GU_CONF_BEFORE="$(gu_conf)"
}

GU_POLL_INTERVAL=0.1 GU_STALL_WAIT_TICKS=200 GU_EXIT_WAIT_TICKS=300

# ^ invariant one line per saved original, the name and the link target or the SHA-256 of a regular file; a link is never followed; rc 1 = no original
gu_orig_ids() {
    local f t sum seen=0
    for f in "$GU_TK_DIR"/orig/*; do
        if [ ! -e "$f" ] && [ ! -L "$f" ]; then return 1; fi
        seen=1
        if [ -L "$f" ]; then
            t="$(readlink -- "$f")" || return 1
            printf '%s -> %s\n' "${f##*/}" "$t"
        else
            sum="$(sha256sum -- "$f")" || return 1
            printf '%s %s\n' "${f##*/}" "${sum%% *}"
        fi
    done
    [ "$seen" -eq 1 ]
}

# ^ invariant gu_poll TICKS CMD... runs CMD at most TICKS times, GU_POLL_INTERVAL seconds apart; rc 0 as soon as CMD succeeds
gu_poll() {
    local ticks="$1" n
    shift
    for ((n = 0; n < ticks; n++)); do
        if "$@"; then return 0; fi
        sleep "$GU_POLL_INTERVAL"
    done
    return 1
}

gu_pid_gone() { ! kill -0 "$1" 2>/dev/null; }

# ^ security only the session this function started is signalled; setsid makes the child its own group leader; kill -SIG -- -PID reaches its group only
# ^ invariant gu_interrupt_run TEXT SKIP SIGNAL CMD... stalls the sudo stand-in at call SKIP+1 with TEXT in its arguments, sends SIGNAL, waits; OUT = CMD output
gu_interrupt_run() {
    local text="$1" skip="$2" sig="$3" pid
    shift 3
    if ! printf '%s' "$text" >"$SANDBOX/sudo.stall" || ! printf '%s' "$skip" >"$SANDBOX/sudo.stallskip"; then
        fail "could not arm the sudo stall knob"
        return 1
    fi
    rm -f -- "$SANDBOX/sudo.stalled"
    (setsid env --default-signal=INT env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$@" >"$SANDBOX/int.out" 2>&1 </dev/null & echo $! >"$SANDBOX/int.pid")
    pid="$(<"$SANDBOX/int.pid")"
    if [ -z "$pid" ]; then fail "no pid for the started command"; return 1; fi
    gu_poll "$GU_STALL_WAIT_TICKS" test -e "$SANDBOX/sudo.stalled" || { kill -KILL -- "-$pid" 2>/dev/null; fail "the command never reached the stalled privileged step [$text]"; return 1; }
    kill "-$sig" -- "-$pid" 2>/dev/null
    if ! gu_poll "$GU_EXIT_WAIT_TICKS" gu_pid_gone "$pid"; then
        kill -KILL -- "-$pid" 2>/dev/null
        fail "the command did not end after SIG$sig"
        return 1
    fi
    OUT="$(<"$SANDBOX/int.out")"
}

# ^ invariant the plan lines of a command output without the as-root prefix; the annotation [only when ...] marks a command run only in its own case
plan_lines() { grep -E '^  as root: ' <<<"$1" | sed -E 's/^  as root: //'; }
# ^ invariant a command with the machine specific parts replaced by the placeholders the plan uses, <build dir>, <work dir> and <file> for each of the six files
norm_cmd() {
    sed -E \
        -e "s#[^ ]*/gsg-git-build\\.[A-Za-z0-9]+#<build dir>#g" \
        -e "s#$SANDBOX/tmp/tmp\\.[A-Za-z0-9]+#<work dir>#g" \
        -e 's#(rm -f -- )<the git-core PPA files[^>]*>#\1<ppa files>#' \
        -e 's#(rm -f -- )[^<]*git-core-ubuntu-ppa.*$#\1<ppa files>#' \
        -e 's#(/\.?)(git-receive-pack|git-upload-archive|git-upload-pack|git-shell|scalar|git)(\.gsg-new|\.gsg-restore)?( |$)#\1<file>\3\4#g'
}
sudo_cmds() { gu_log | grep -E '^sudo -- ' | sed 's/^sudo -- //' | norm_cmd | LC_ALL=C sort -u; }
plan_all_cmds() { plan_lines "$1" | sed -E 's/  \[only when [^]]*\]$//' | norm_cmd | LC_ALL=C sort -u; }
plan_required_cmds() { plan_lines "$1" | grep -v '\[only when ' | norm_cmd | LC_ALL=C sort -u; }

# ^ invariant check_plan_matches_log compares whole commands, not tool paths => a second use of a tool with other arguments cannot slip through
check_plan_matches_log() {
    assert_eq "$(comm -13 <(plan_all_cmds "$1") <(sudo_cmds))" "" "$2: every command sudo ran is a command of the plan"
    assert_eq "$(comm -23 <(plan_required_cmds "$1") <(sudo_cmds))" "" "$2: every command of the plan without an annotation ran"
}

# ^ invariant gua_run BODY ARGS... is gu_run with the apt module loaded, the paths set and the class ubuntu (GU_CLASS overrides it)
# shellcheck disable=SC2016
gua_run() {
    local body="$1"
    shift
    gu_run 'source "$GSG_ROOT/lib/gitup_apt.sh" || exit 9; gitup_paths || exit 9; GITUP_CLASS="${GU_CLASS:-ubuntu}"; INSTALL_TIMEOUT_BIN="$(type -P timeout)"; '"$body" "$@"
}

# ^ invariant gua_reply FN ARGS... is gu_reply for the apt module; stdout is REPLY and the function's own output is dropped
# shellcheck disable=SC2016
gua_reply() { gua_run '"$@" >/dev/null; rc=$?; printf "%s" "$REPLY"; exit "$rc"' "$@"; }
