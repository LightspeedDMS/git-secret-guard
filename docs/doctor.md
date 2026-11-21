# Coverage report: `doctor`

The hook cannot report a repository where it never runs. `git-secret-guard doctor [--roots DIR...]` checks the machine and
every repository under the roots and lists what is not protected, with the config file responsible.

```bash
git-secret-guard doctor                          # machine + every repository under your home directory
git-secret-guard doctor --roots ~/Dev ~/work     # only these roots (several allowed), faster on a large home
```

The default root is your home directory on every platform, so a repository is covered wherever it was cloned. The search
goes through everything below it, hidden directories and caches included, and takes as long as your home is large; the
repository checks then cost a few git calls each. `--roots` narrows it. **On macOS** a default run leaves out `~/Library`
(system data, and reading it raises privacy prompts) and `~/.Trash`, and the first run still asks for access to folders such
as Desktop, Documents and Downloads: allow it, or those folders are listed as unreadable. `--roots ~/Library` searches it anyway.

`--roots` takes one or more directories (relative ones are resolved; overlapping roots count a repository once) and cannot
be combined with `--recheck`. `--roots` with no directory, an unknown option or a stray argument is a usage error (exit
status 2, the usage text on stderr).

**It is read-only except for its findings record** ([below](#the-findings-record-and---recheck)). It runs `git config`,
`git hook list pre-commit`, `git hook list commit-msg`, `git rev-parse`, `git ls-tree`, `git cat-file`, `git ls-files`,
`find`, `--version` of the scanners and of every git it lists (for the SmartGit Flatpak through `flatpak run`, see below)
and, for a repository with a `.gitleaks.toml` at HEAD, the same betterleaks pre-flight the hook runs. It writes no repository file, no
git config and no install state; the record is its one and only write (with its lock and temp file beside it, and the
state directory, mode 700, created if it is missing). Its only scratch space is one private directory
under `$TMPDIR` (or `/tmp`), removed on exit. `tests/inspect/test_doctor_readonly.sh` checksums every file of a sandbox (hashes,
modes, sizes, modification times: config files, repositories, state and share dirs) before and after a run, and a
`--recheck`, over repositories with every kind of problem, leaving out only the record and its lock, and requires the temp
directory to be empty afterwards. Before any HEAD read it exports
`GIT_NO_REPLACE_OBJECTS=1`, unsets the four `GIT_*_PATHSPECS` variables and every repository-local `GIT_*` variable (a
`GIT_DIR` inherited from a calling hook cannot point every check at one repository), and sets `GIT_OPTIONAL_LOCKS=0`.

**It runs nothing a repository configures, and it contacts no remote.** The repositories it reads are other people's
checkouts, so after the variable cleanup above doctor exports `GIT_NO_LAZY_FETCH=1` (a missing blob or tree in a partial
clone is reported as unreadable, never fetched through the promisor remote: no `uploadpack`, `sshCommand` or credential
helper runs) and forces `core.fsmonitor=false` through `GIT_CONFIG_COUNT` (command scope beats repository config; reading
the index would otherwise start the repository's fsmonitor command). This is doctor-only: the hook runs inside the
committer's own repository, where git already runs that config, and it never loads the doctor code. Checked and found
harmless: `gc.auto` and `maintenance.auto` (no command doctor runs triggers them), `core.hooksPath` hooks such as
`reference-transaction` and `post-index-change` (doctor updates no ref and writes no index), diff and textconv drivers
(doctor diffs nothing in the repositories). A repository git refuses for ownership reasons (`safe.directory`) is listed as
`cannot be inspected: fatal: detected dubious ownership ...`, not a doctor error. `tests/inspect/test_doctor_readonly.sh` plants a
marker-writing fsmonitor and hooks, and a `--filter=blob:none` partial clone served by a local `file://` remote with a
marker-writing `uploadpack`, and requires no marker file and an unchanged object store.

**It is time-bounded.** Every git call of the repository phase runs under the settings' `timeout`, limited by
`DOCTOR_TIMEOUT_SECONDS` in the settings file (default 30, a whole number from 1 to 999999; an invalid value is a machine
PROBLEM, `settings: DOCTOR_TIMEOUT_SECONDS must be a positive integer, got [...]`). Install does not write this key and
rewrites the settings file on every run, so a value you add is gone after the next `install`. The machine section's two
`git hook list` calls run under a fixed 30 seconds (the settings' `timeout`, `--foreground`). A
repository whose config makes git block (an `include.path` pointing at a FIFO, say) becomes `cannot be inspected: timed out
after 30s` or `cannot read the hooks git runs (... exit 124: timed out after 30s)`, and the run goes on. The betterleaks
pre-flight uses the smaller of that value and `SCAN_TIMEOUT_SECONDS`; its timeout reads `betterleaks timed out after Ns loading
.gitleaks.toml at HEAD (doctor's limit; the hook allows 300s), so doctor could not judge it`. If `timeout` itself is
unusable, or `DOCTOR_TIMEOUT_SECONDS` is invalid, no git is run in the repository phase and every repository is listed as
`cannot be inspected: git was not run: timeout or DOCTOR_TIMEOUT_SECONDS is unusable (see machine section)`. The timer's service adds `TimeoutStartSec=1h` as the
outer bound.

## Machine checks

| Check | Problem when |
|---|---|
| Installed | no state file (`not installed`) or an unreadable one |
| State records | `tools_installed_by_us`, `tools_placed` or `tools_replaced` hold an invalid word or a tool install does not manage (PROBLEM); two hashes for one tool (an install did not finish placing it) or an aside file recorded in `tools_replaced` that is gone (WARNING) |
| Hook config | `hook.git-secret-guard.event` is not exactly two values, one `pre-commit` and one `commit-msg` (the text counts the "wanted events" among the values and never prints a value), `.command` is not exactly one value equal to the command install writes (the check of the recorded bash and `exec '<recorded bash>' '<hook>'` on every platform, the `C:/...` form of the paths on Git for Windows; an unset `BASH_BIN` leaves the bare hook path as the wanted command), that file is missing or not executable, or git does not run the hook: the machine section asks `git hook list pre-commit` and `git hook list commit-msg` in an empty bare repository (the reader `status` shares; an event missing because the config shape is wrong is explained by the config line, not reported twice), and `disabled` or `event-disabled` is a PROBLEM that names the setting git blamed (key, scope, file; the value of an `enabled` key is shown, cut at 40 characters, never a `command` or `event`; `hook.commit-msg.enabled=false` reads `disables the commit-msg event: commit messages are not scanned (lines still are)`, the other keys `switches the hook off everywhere`), located by a scan that parses each value with git's own boolean parser (the last valid value is the one named; it never decides); when the scan cannot name it the line says `git reports the hook disabled; the setting could not be located`. A key without a value in any scope is a PROBLEM too (every git command fails with exit 128 until it is removed; `git hook list` fails in the probe). An absent hook or a failed step is a PROBLEM only when no config-shape problem above explains it. A wrong count is reported as `has 2 values (global <file>; global <file>), 1 of them the installed hook`: **never the values**, a global command can hold a token and the timer writes this output to the journal |
| Tools | the settings file is missing, unreadable or invalid (also a bad `SCAN_TIMEOUT_SECONDS`): one `settings:` PROBLEM and no tool line follows; or `TRUFFLEHOG_BIN`, `BETTERLEAKS_BIN`, `JQ_BIN`, `SETSID_BIN` (`TASKKILL_BIN` on Git for Windows), `TIMEOUT_BIN` is not an absolute executable, or a scanner does not report the version `tools.lock` pins (judged exactly like `install` and `status`); a scanner is also a PROBLEM when `tools.lock` has no pinned version for this platform or when `timeout` is unusable (`version not checked, timeout is unusable`); a `BASH_BIN` (install writes it on every platform) that is missing from the settings (an install from before it), not executable or older than bash 4.4 |
| `core.hooksPath` | any global value is left, including one in the XDG config or in an included file (the file is named) |
| System git takeover | only where the OS module supports `install --take-over-system-git` (the RPM module, also for an RPM distribution in WSL): `ok` while it is active, a PROBLEM when it is half done, partly undone or its record is missing or unreadable (the line names `restore-system-git` or `install --take-over-system-git`); no line when there is none, see [install.md](install.md) |
| git build | WARNING `UNFINISHED: an interrupted copy of git into <prefix> left <MANIFEST.partial>; run: git-secret-guard install --upgrade-git to finish it` when an upgrade's copy was interrupted |
| git | WARNING for every reachable git older than 2.54: all `git` on `PATH` plus `/usr/bin/git` (2.52 on the RHEL host) and the git GitHub Desktop bundles (`/usr/lib/github-desktop/resources/app/git/bin/git`, which the warning names: a commit made by it was measured to skip the scan, see [CI on real platforms](platform-testing.md#ci-on-real-platforms)), by path and version. Such a git ignores config hooks silently, so commits made with it are **not scanned**. Doctor itself needs the git first on `PATH` to be 2.54 or newer (otherwise it exits 2) |
| Timer | only when the state says a timer is installed: both unit files exist, were written by install, and `SYSTEMCTL_BIN` in the settings is usable; on macOS the LaunchAgent plist exists, was written by install, and `LAUNCHCTL_BIN` is usable |

**SmartGit.** Each SmartGit settings directory found (one per major version; macOS `~/Library/Preferences/SmartGit/<major>`, Linux `~/.config/smartgit/<major>` and the Flatpak's, Windows `%APPDATA%\syntevo\SmartGit\<major>`) gets one line: `ok` when its Git Executable runs git 2.54 or newer, a PROBLEM `SmartGit <major> (<dir>): Git Executable is the bundled git 2.53.0 ... run: git-secret-guard install --configure-smartgit` when it is older (the version is read from the git it names, never assumed; for the Flatpak, whose `/app` paths exist only inside its sandbox, through `flatpak run --command=<git> com.syntevo.SmartGit --version` under the doctor time bound; a Flatpak or tarball still on its bundled git 2.53.0 is this PROBLEM; a `~/...` Git Executable, as SmartGit writes it for the Flatpak wrapper, is read as that path in your home), and a WARNING when the version cannot be read, the directory is a symbolic link or not yours, the file has an unexpected shape (the link, owner and shape cases say `cannot tell whether SmartGit's commits are scanned` and give the check by hand: Preferences, Commands, Git Executable must be a git 2.54 or newer), or no SmartGit installation was found for the directory. A new SmartGit major version shows up as its own line after the update. Within one settings root the newest major SmartGit has set up is the one it uses (a newer directory with no `preferences.yml`, no `startup` file off macOS, or that is a symbolic link or not yours demotes nothing; a newer directory with a `startup` file whose `preferences.yml` cannot be read is a WARNING, never a PROBLEM, and the older one is left over); after an upgrade run `doctor` once, so a record written by the older install stops reminding after commits; an older major counts only when a detected install has exactly that major (read on macOS and for the Flatpak). Any other older major is **left over** (what a major update leaves behind): it gets one `info` line (`SmartGit <major> (<dir>): left over, SmartGit uses the newer <major> here; this directory is not edited or counted and can be deleted once SmartGit <major> is no longer used`), is never a PROBLEM or a WARNING, is not recorded (the commit reminder never names it) and is never edited. A directory in use whose major this tool has not recorded (it edits 26.1 only) and whose git is older gets the by-hand step (`by hand: in SmartGit open Preferences, Commands, choose "Other Git Executable" ...`) in place of `run: git-secret-guard install --configure-smartgit`, which would refuse it. The portable SmartGit archive for Windows keeps its settings in its own directory and is not found, so it gets no line: an `ok` here says nothing about it ([smartgit.md](smartgit.md#windows-portable-smartgit-not-detected)). See [smartgit.md](smartgit.md).

**GitHub Desktop.** On Linux one line, and only when Desktop's bundled git is found or a link of ours exists. Not linked and the bundled git older than 2.54: `info`, `GitHub Desktop: git 2.45.3 is not linked, so commits made in Desktop are not scanned; run: git-secret-guard install --link-desktop-git` (never a PROBLEM or a WARNING: the link is opt-in; the install warning about the old git stays). A bundled git of 2.54 or newer: `info`, no link needed. Linked and current: `ok` (27 wrappers, no `reference-transaction` one: a repository's own hook of that name does not run in Desktop), and the old-git WARNING of the `git` row above is not printed for Desktop's bundled git then. Linked with a wrapper or the shared file missing, changed or not executable, a launcher entry missing, the system launcher entry it is made from unreadable, or Desktop gone while its link is left: a PROBLEM that says `MISMATCH`, names up to three files and gives the command (`install --link-desktop-git`, or `unlink-desktop-git` when Desktop is gone). A launcher entry that only differs from what would be written now (a Desktop update changed the system entry) is a WARNING with the same text, and only when the entry still has an `Exec=` line and every `Exec=` line starts with our exact `env "GIT_CONFIG_PARAMETERS='core.hooksPath=<our hooks directory>'"` argument (`desktop_git_launcher_sets_path`; a line counts as an `Exec` key in every spelling GLib reads, with blanks before the key or around `=`, because the last duplicate key wins there): then commits are still scanned (`status` still exits 1 on it). An entry that lost the argument, names another directory, has an `Exec=` line without it or has no `Exec=` line starts Desktop unscanned: a PROBLEM, `MISMATCH the launcher entry no longer sets core.hooksPath for Desktop`, like a missing entry. On macOS and Windows one `info` line when Desktop is found in the default place, recommending the latest release ([install.md](install.md#github-desktop-on-linux---link-desktop-git-and-unlink-desktop-git)).

**Auto-update** ([install.md](install.md#auto-update---auto-update-and-update)). Judged from the state, the update record and plain files only: doctor never runs `systemctl`, `loginctl`, `launchctl` (macOS) or `schtasks` (Windows). A state file without `source_checkout` (an install whose state predates that key, or one run from a copy that is no checkout) gets no finding of any kind.

| `auto_update` | Line | Severity |
|---|---|---|
| not `yes` | `auto-update: off` | info |
| any, checkout recorded and present | `auto-update: the installed version <installed> is older than <checkout>/VERSION (<checkout version>); install from the checkout: <checkout>/bin/git-secret-guard install`, when the checkout's plain `VERSION` file is newer than the state's `version` **or** the installed copy's `VERSION` (the version-gap rule of `update`). The plain file is read, never git objects, so a follower can read it. A version that is not `x.y.z` gives no line | PROBLEM |
| `yes` | `auto-update: the recorded checkout <path> is missing; ...` | PROBLEM |
| `yes` | `auto-update: timer inactive: <why>`, at most one: an update unit is missing or not ours, `timers.target.wants/git-secret-guard-update.timer` is missing (the timer is not enabled), the timer unit has no `OnUnitActiveSec` line install writes, the record cannot be read or its `checked_at` is not a UTC time, or the last check is older than 3 × the interval + 1h (the interval comes from the timer unit: `1h`, or the test value `<n>s`). Without a record the timer unit's modification time stands in for the last check, so a timer that never ran is reported once the same limit has passed | PROBLEM |
| `yes` | `auto-update: linger is off for <user> (/var/lib/systemd/linger/<user> is missing); ... run: loginctl enable-linger` | WARNING |
| `yes`, none of the PROBLEMs | `auto-update: on, following <checkout> every 1h; last check <checked_at> <result> <reason>` (or `no update run is recorded yet`) | ok |

**On macOS** the update LaunchAgent plist (`com.lightspeeddms.git-secret-guard.update.plist`) takes the place of the two units: the same `timer inactive` finding names the plist, the interval is its `StartInterval`, the age rule reads its mtime when no run is recorded and its hint names `update.log`, and there is no `timers.target.wants` check and no linger warning ([install.md](install.md#auto-update---auto-update-and-update)).

**On Windows** the update wrapper `update-task.cmd` takes the place of the two units: `auto-update: timer inactive: <path> is missing` (or `was not written by git-secret-guard`) is the unit finding, the interval is always `1h`, the age rule reads the wrapper's mtime when no run is recorded and its hint names `update.log`, there is no linger line, and `schtasks` is never run.

These are machine lines like the others: a PROBLEM is recorded in the findings record and comes back in `--recheck`.

## Repository discovery

With no `--roots` the root is **your home directory** (`$HOME`), on Linux, macOS and Windows; `--roots` searches exactly
the directories it names. Every directory at most **31 levels** below a root that holds a `.git` entry (directory or
file) is a repository: `ROOT/a`, `ROOT/a/b`, ... down to `ROOT/d1/.../d31`, and the root itself. The search is bounded on purpose; a repository
deeper than that is not found. `node_modules` directories are not entered, at any depth. Symlinks are not followed.
**On macOS a default run leaves out `~/Library`** (system data; reading it raises privacy prompts) **and `~/.Trash`**
(blocked without Full Disk Access, it would be a PROBLEM on every run). `doctor --roots ~/Library` or `--roots ~/.Trash`
searches it, and a `Library` folder anywhere else (a Unity project, say) is searched. Repositories are
deduplicated by `git rev-parse --git-common-dir`, so a **worktree** is reported once, under its main repository (shown as
`worktrees: ...`; when the main repository is outside the roots it is still named, from its common dir). Bounds, all
fail-closed: more than 20000 `.git` entries, a root that is not a directory (a home directory that does not exist: pass
`--roots DIR`), or a `find` failure that is not a permission problem is a doctor error (exit status 2), never a silently
shorter list. **A directory the user cannot read** (a database data dir, a folder macOS privacy protection blocks, where
`find` says `Operation not permitted`) does not stop the report: it is listed under `not searched:` as `PROBLEM  cannot
read <dir>; repositories below it are not checked`, the rest is checked, and the exit status is 1. This holds when a second
search names the unreadable directories (1 to 20000 of them); a permission error it cannot pin on a directory, or more
than 20000, is a doctor error (exit status 2). A `.git` that git cannot open is **listed**
(`cannot be inspected: ...`), not skipped; so is a `.git` entry that does not resolve to its own directory (an empty
`parent/fixtures/sub/.git` makes git answer for `parent`: it is reported as `sub`, `git resolves it to <parent>`, and the
parent is judged on its own). Bare repositories have no `.git` entry and are not found; a linked worktree of a bare
repository is, and it is reported under the bare repository's path (its common dir), like any other worktree.

## Per-repository checks

| Check | Result |
|---|---|
| Is the hook effective? | `git-secret-guard` must be listed, with no prefix, by `git hook list pre-commit` **and** by `git hook list commit-msg` (the message scan). A `disabled` or `event-disabled` line means `hook.git-secret-guard.enabled=false`, `hook.pre-commit.enabled=false` or `hook.commit-msg.enabled=false` (a key that switches off both events is reported once); the report says `disabled in local config: <key>=<value> (<file>)` and names the scope that holds the key (local, global, worktree, command) and the file git read it from (`--show-origin`, also an included file). When git reports the hook disabled and no config key explains it, the line is `git hook list <event> shows git-secret-guard as <status>, and no config key says why`. Not listed at all is reported per event: `git-secret-guard is not in 'git hook list <event>'; no hook.git-secret-guard.event=<event> reaches this repository`; an event without its command (git refuses) reads `hook not reached: the global hook config is incomplete (see machine section)`. **This check runs in the main checkout and in every linked worktree**: with `extensions.worktreeConfig=true` a worktree can switch the hook off in its own `config.worktree`, and the finding is shown under the main repository as `worktree <path>: disabled in worktree config: ...`. A finding the main checkout already has (shared config) is not repeated per worktree. PROBLEM |
| Command overridden? | the last `hook.git-secret-guard.command` comes from a non-global scope and is not the installed script: `command overridden in local config: hook.git-secret-guard.command (<file>)`. The value is never printed. PROBLEM |
| HEAD `.secret-scan-ignore` | validated with the hook's own code (`scan_ignore_parse`, `scan_ignore_scope`): a line without a reason is a PROBLEM with its line number, as are a symlink or directory, a control character in a pattern, a `..` component and more than 1000 lines (the hook blocks every commit on these); a catch-all (`**`, `./**`, a union of patterns that covers every tracked file, `*` for top-level files) is a WARNING that quotes the pattern as written, cut at 60 characters (a cut is always marked with `…`). At most 20 notes of one file are shown, then `more problems follow; fix these first and run doctor again`. A file that cannot be read at HEAD (a missing object is never fetched) is a PROBLEM too. Only HEAD counts, never the index or the work tree, and a `git replace` ref cannot substitute it |
| HEAD `.gitleaks.toml` | a symlink or directory at HEAD, or a file git cannot read, is a PROBLEM (the hook blocks every commit); otherwise the hook's own pre-flight (`betterleaks_config_preflight`, under the smaller of `DOCTOR_TIMEOUT_SECONDS` and `SCAN_TIMEOUT_SECONDS`): a config that does not load (a relative `[extend] path`, a syntax error, a timeout) is a PROBLEM; one that loads but leaves betterleaks' built-in rules off is the hook's WARNING sentence. If betterleaks or timeout is unusable the check is reported as not done (WARNING), never skipped silently |
| `.pre-commit-config.yaml` | info when `<common-dir>/hooks/pre-commit` is not the pre-commit framework's hook (`pre-commit install not run`) |
| Repo-local `core.hooksPath` | info (husky and similar): config hooks run whatever it says, so it is harmless, and it is listed so you can see it |
| A check that cannot run | PROBLEM, never silence: `cannot read the hook config (git config exit N: ...)`, `cannot read core.hooksPath (...)`, `cannot read the hooks git runs (...)`, a checkout or worktree that `cannot be entered` |

## Output and exit status

The text below is what `doctor` prints to a pipe, a file or a log, and it is byte-stable. On a terminal with a UTF-8 locale (or with
`CLICOLOR_FORCE` set, unless `NO_COLOR` is set or `TERM` is `dumb`) each tag is drawn as its icon, `✗` red for `PROBLEM`, `▲` yellow for
`WARNING`, `✓` green for `ok`, `•` dim for `info`, for the machine lines and the repository findings (`doctor --recheck` too), and the
`summary:` line starts with the icon of the worst level present. The rules are in [install.md](install.md#sections-levels-and-the-summary);
`status` uses the same four levels.

```
machine:
  ok       installed: version <x.y.z> (state /home/me/.local/state/git-secret-guard/state)
  ok       state records: 2 placed hash(es), 0 original(s) moved aside
  ok       hook: hook.git-secret-guard.event=pre-commit and commit-msg, command=/home/me/.local/share/git-secret-guard/hooks/secret-scan (executable)
  ok       trufflehog: /home/me/.local/bin/trufflehog 3.99.2 (pinned 3.99.2)
  ok       betterleaks: /home/me/.local/bin/betterleaks 1.9.0 (pinned 1.9.0)
  ok       jq: /usr/bin/jq
  ok       setsid: /usr/bin/setsid
  ok       timeout: /usr/bin/timeout
  ok       core.hooksPath: no global value
  ok       git: /usr/local/bin/git 2.56.0
  WARNING  git: /usr/bin/git is git 2.52.0; it ignores config-based hooks without any message, so commits made with it are NOT scanned
repos with findings:
  /home/me/Dev/legacy
    PROBLEM  disabled in local config: hook.git-secret-guard.enabled=false (/home/me/Dev/legacy/.git/config); remove that key to cover this repository
  /home/me/Dev/web
    info     core.hooksPath=.husky/_ in local config (/home/me/Dev/web/.git/config); harmless, config hooks run whatever it says
summary: 57 repos, 56 covered
warnings: 1 (listed above, they do not change the exit status)
```

`<x.y.z>` stands for the installed version (the `VERSION` the state records). The machine section is always printed in full, in this order: install and state records, hook config, tools, timer,
`core.hooksPath`, system git takeover, SmartGit, GitHub Desktop, auto-update, an unfinished git build, then every reachable git. Unreadable
directories follow under `not searched:` (see discovery). Only repositories with a finding follow it. A repository counts as
**covered** when it has no PROBLEM (warnings and info do not change that). `warnings:` appears only when there are some.

| Exit status | Meaning |
|---|---|
| exit status 0 | no PROBLEM anywhere (WARNING and info lines can still be printed) |
| exit status 1 | at least one PROBLEM, on the machine or in a repository |
| exit status 2 | doctor could not run or finish: git first on `PATH` older than 2.54, a root that is not a directory (the home directory is the default root and must exist, else pass `--roots DIR`), a global git config that cannot be read, a bound exceeded, a `find` failure that is not a permission problem, a usage error, no temp directory, the findings record that cannot be written or whose lock stays taken, or a directory (or a link to one) where the lock `findings.lock` goes (it names the path; move it away). (An unreadable directory is normally a PROBLEM line and exit status 1, see discovery) |

These are doctor's own statuses. A failure of the CLI before doctor starts (a library that cannot be read, the macOS bash
bootstrap, a missing GNU tools directory on macOS) exits 1 with its message and no report.

PROBLEM, WARNING and info are the three severities; a PROBLEM names what to do (`run git-secret-guard install`, remove a
key from a named file). Nothing from a file's content, a secret or the environment is printed: not a reason text, not a
command override value, not the probe value of the pre-flight. Repository names, paths and tool-provided text pass
through a filter that turns control characters into `?`, as the hook does. Values doctor cuts (a
repository-local `core.hooksPath` value at 120 characters, a catch-all pattern at 60, state record words at 80, git's own
error text at 200) end with `…`, and a value that fits is printed whole, so a cut path is never mistaken for a complete,
different one. Two exceptions: a global `core.hooksPath` value in the machine section is printed whole, and the line
quoted from a malformed state file is cut at 80 characters without `…` (the message around it is cut at 200 with `…`).

**Limits.** The hook-effective check runs in every worktree, but the HEAD files (`.secret-scan-ignore`, `.gitleaks.toml`)
are read at the HEAD of one checkout: the main checkout when the search found it, otherwise the first linked worktree it
found. Another worktree on another branch can carry a different `.secret-scan-ignore`, which is not read. A linked worktree outside `--roots` is not checked: only `.git` entries under the roots are looked at, even when its
main repository is inside them. Bare repositories and repositories deeper than 31 levels below a root are not found.
Doctor reports what the config files say: before it looks it drops every variable that `git rev-parse --local-env-vars`
lists, `GIT_CONFIG_PARAMETERS` and `GIT_CONFIG_COUNT` included, so a switch-off exported in your shell (or `--no-verify`)
is not visible to it. A git older than 2.54 shows up only as the git warning above. `doctor` does not ask systemd whether
the timer is enabled (see below).

## The findings record and `--recheck`

A finished full run (manual or from the timer) writes `${XDG_STATE_HOME:-~/.local/state}/git-secret-guard/findings`: the run
time and one line per **PROBLEM**, the text exactly as printed (so already free of values and control characters). WARNING
and info are never recorded. It is **doctor's one and only write**; a run that ends with exit status 2 does not touch it,
and a write that fails makes the run exit 2.

```
git-secret-guard findings 1
time 2026-11-03T09:00:00Z
machine<TAB>hook: hook.git-secret-guard.event is [unset], want exactly [pre-commit, commit-msg]; run git-secret-guard install
repo<TAB>/home/me/Dev/legacy<TAB>-<TAB>disabled in local config: hook.git-secret-guard.enabled=false (...); remove that key ...
repo<TAB>/home/me/Dev/m<TAB>/home/me/Dev/wt<TAB>worktree /home/me/Dev/wt: disabled in worktree config: ...
```

The scope is `machine` or `repo` with the absolute path and the worktree the finding belongs to (`-` for the main
checkout). The finding lines are sorted (C locale) with duplicates removed, and the file is created with mode 600. The
`time` line is the time of the last **full** search; a `--recheck` rewrites the findings but keeps it (the
caller can say "as of <time>"). A full run replaces the machine records and the records of every repository it saw, and
keeps the rest, also under its own roots: a record under the roots is dropped only when the repository is **proven gone**
(no `.git` there and every directory above it searchable). A repository the search cannot reach (deeper than 31 levels,
below `node_modules`, below an unreadable directory, under `~/Library` or `~/.Trash` on a default macOS run) therefore keeps its record across full runs until a recheck reaches it. A full run that finds nothing leaves a
record with no findings of its own (kept records of repositories it did not reach stay). A repository whose path the record cannot hold (a control character) is named on stderr (`not recorded`), never
silently lost. **Unreadable directories (`not searched:`) are listed as PROBLEMs by the full run but are not recorded**: only
discovery finds them and a recheck never discovers, so the recheck could not confirm them.

```bash
git-secret-guard doctor --recheck
```

`--recheck` re-runs the machine checks (all but the list of reachable gits, which has no PROBLEM) and, for every recorded
repository (and recorded worktree), the full per-repository checks. **It never searches for repositories**, has **no limit on the number of items and no total-time limit** (you run
what you found broken; each git call keeps the `DOCTOR_TIMEOUT_SECONDS` bound), and keeps every protection of a full run
(`GIT_NO_LAZY_FETCH`, `core.fsmonitor=false`, repository-local `GIT_*` variables dropped). It rewrites the record with what
is still a PROBLEM: a fixed item is dropped, a recorded repository with a different PROBLEM now gets the new one, a
repository that no longer exists (or has no `.git`) is dropped with one line on **stderr**
(`<path> no longer exists; dropped from the findings record`), but only when it is **proven gone** (no `.git` there and every
directory above it searchable). A repository or worktree behind a directory you cannot search is neither re-checked nor
claimed gone: its recorded PROBLEMs are kept unchanged, printed as still open, counted (exit status 1), with one stderr line
`<path> cannot be reached; kept in the findings record`. **stdout carries only what is still open**, in the full run's
shape (`machine:` and `repos with findings:`, PROBLEM lines only), so a caller can show it as it is.

| `--recheck` exit status | Meaning |
|---|---|
| 0 | nothing remains. No findings file, a zero-byte one or one without findings: **nothing is printed and no git runs** |
| 1 | at least one PROBLEM remains (printed) |
| 2 | it could not run: invalid record, git older than 2.54, a record that cannot be written, a lock that stays taken |

**The commit hook runs `--recheck` for you.** While the record holds findings, every commit starts `doctor --recheck` after
its own output and prints what is still open as a short reminder; a fixed item stops being listed on the next commit. How
it is printed, and what it does when the re-check fails, is in
[docs/scan.md](scan.md#the-coverage-reminder).

The record is **data, never sourced**, and validated line by line: header, time, then only `machine` and `repo` lines in
their exact shape (absolute paths, no control character, not empty, a regular file that is not a symlink, at most 64 MiB
and 100000 lines, the size checked before the file is read). **Doctor never writes what it cannot read**: a run whose new
record would exceed either limit removes its temp file, keeps the previous record untouched, prints `the findings record
would exceed <limit>; the previous record is kept` and exits 2. A malformed or foreign file is reported (`the findings record
<file> is invalid (line N is malformed); run git-secret-guard doctor to replace it`, the `--recheck` wording; a full run says
`...; replacing it`), nothing in it is acted on, **not even the lines before the bad one**, and the next full run replaces
it with only what it found itself.

Updates are serialised: the record is rewritten by renaming a temp file made in the same directory (a reader sees the old
file or the new one) while holding the lock `findings.lock`, a symlink whose text is the holder's pid (macOS has no
`flock`; creating a symlink is atomic and names the owner in one step). The lock is held only for the read-merge-rename, never
while checks run, and the record is read again under it, so a full run and a recheck started together lose no record. A lock
whose process is dead is taken over, and so is one older than a minute (it is held for milliseconds, so a pid reused by
another process cannot hold it forever); a live, recent holder is waited for (300 attempts of 0.1 s, on Git for Windows
at most 45 seconds) and then refused with `another run holds <lock> (process N); gave up after N attempts; if no doctor run
is active, remove <lock>`. A lock that can be neither created nor read is `cannot create the lock <lock>`. Under the lock,
`findings.XXXXXX` temp files older than a minute (left by a killed run) are removed. `uninstall` takes the same lock
before it changes anything; when a live run holds it, uninstall changes nothing (the installed CLI, the hook section, the
share dir and the state stay), exits 1 and says to run `uninstall` again once no doctor run is active. Otherwise it removes
the record and every `findings.XXXXXX` temp file with the rest and releases the lock before the state directory
goes. Residual: two
runs that both find the same dead holder can each remove a lock the other just made, a window of microseconds that needs a
crashed holder first.

## The weekly timer

```bash
bin/git-secret-guard install --with-timer      # or: git-secret-guard install --with-timer
journalctl --user -u git-secret-guard-doctor.service     # read the reports
systemctl --user list-timers git-secret-guard-doctor.timer
```

`install --with-timer` writes `git-secret-guard-doctor.service` (a one-shot `ExecStart="<share>/bin/git-secret-guard" doctor`,
with the `PATH` of the git install found first, followed by `/usr/local/bin:/usr/bin:/bin`, each directory once, because
the user manager has its own; `TimeoutStartSec=1h`, because systemd gives a one-shot service no start timeout otherwise; and
an `Environment=` line for each of `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CONFIG_HOME` and `GIT_CONFIG_GLOBAL` that was set
when you ran install, because the user manager does not pass your login environment on and a custom one would make the
timer's doctor report `not installed`) and `git-secret-guard-doctor.timer`
(`OnCalendar=weekly`, `Persistent=true`, `WantedBy=timers.target`) into `${XDG_CONFIG_HOME:-~/.config}/systemd/user/`, then
runs `systemctl --user enable --now git-secret-guard-doctor.timer`. The service output goes to the journal. The service
passes no `--roots`, so it checks your whole home directory (`HOME` comes from the user manager, and doctor refuses to start
without an absolute `HOME`). Because doctor
exits 1 on a PROBLEM, the unit is shown as failed in `systemctl --user status git-secret-guard-doctor.service` whenever
the machine has a finding, which is what a timer can act on.

- **Without `--with-timer` nothing is installed**, and `systemctl` is never called (a timer an earlier install recorded
  only has its own units refreshed, see below).
- **In WSL** `--with-timer` needs systemd running in the distribution; without it (and always on WSL 1) install refuses
  before any change, see [WSL](platforms.md#wsl-windows-subsystem-for-linux).
- `systemctl` is looked up on `PATH` at install time, and its absolute path is written to the settings file as
  `SYSTEMCTL_BIN`, like `jq`, `setsid` and `timeout`. Uninstall and doctor use that path and never search `PATH`
  (`test_systemctl_is_looked_up_only_in_lib_install_sh`). A missing `systemctl` refuses the install before anything changes.
- The state records `timer_installed=yes` before the units are written, so an interrupted install can still be uninstalled.
  A plain `install` over an installed timer **keeps it recorded and leaves its enablement alone**: a timer you disabled
  stays disabled, `systemctl` is never called and is not needed (a machine that lost it can still upgrade the hook; the
  settings get the `systemctl` found on `PATH` now, or else the recorded `SYSTEMCTL_BIN`, for `uninstall`). Units are rewritten only when they are ours and their text
  changed, with a hint to run `systemctl --user daemon-reload`; a foreign unit is left alone, and a value that cannot go into
  a unit file skips the refresh with a message. Only `--with-timer` writes and enables. `uninstall` is the way to remove it.
- Units are written atomically and carry a marker line. Install refuses to overwrite a unit of the same name that it did not
  write, and uninstall leaves such a unit alone and says so. A share, config or git path containing a quote, a backslash,
  `%`, `$` or a control character is refused (a unit file cannot carry it safely); spaces are quoted.
- A failing `systemctl --user enable --now` leaves the hook installed and scanning and says so; run
  `install --with-timer` again once the cause (usually no user manager reachable) is fixed.
- `uninstall` runs `systemctl --user disable --now git-secret-guard-doctor.timer`, removes both unit files, then runs
  `systemctl --user daemon-reload`, all before the share dir goes (the settings that name `systemctl` live there). If a
  step fails it stops and says what to run: the share dir and the state are kept, and so are the units when the failure
  comes before their removal (a failed `daemon-reload` comes after it, so the units are already gone); running
  `uninstall` again finishes.
  If `systemctl` from the settings cannot run, it prints the manual `systemctl --user disable --now ...` command. A
  `timers.target.wants/git-secret-guard-doctor.timer` enable link that dangles because the timer file is already gone is
  removed too, but only a symlink whose own text is our timer unit path (a link to anything else, a live link and a regular
  file stay).
- **Tests never touch the real user manager.** Lifecycle tests put a recording `systemctl` stand-in first on every `PATH`
  they use, write units into a scratch `XDG_CONFIG_HOME`, and validate the generated units with the real
  `systemd-analyze --user verify` (a parser; it runs in an in-process test manager with a scratch `XDG_RUNTIME_DIR`).

## A weekly run on Windows (Task Scheduler)

Windows has no `--with-timer` (`install --with-timer` stops with a message), so nothing is scheduled for you. A scheduled task you create yourself does the same job and
works with the installed command. From cmd:

```bat
schtasks /Create /SC WEEKLY /D MON /ST 09:00 /TN git-secret-guard-doctor /TR "\"%USERPROFILE%\.local\bin\git-secret-guard.cmd\" doctor"
schtasks /Query /TN git-secret-guard-doctor
schtasks /Delete /TN git-secret-guard-doctor /F
```

- The task keeps the coverage reminder current: doctor rewrites its findings record on every run, and commits read it.
- Like a failed systemd unit, the task shows last result `1` whenever doctor found a PROBLEM.
- This task is yours: `uninstall` does not know about it, so delete it before you uninstall, or it fails every week.

## The weekly timer on macOS (launchd)

On macOS `install --with-timer` schedules the same weekly doctor run with a LaunchAgent instead of systemd units.

```bash
git-secret-guard install --with-timer
launchctl print gui/$(id -u)/com.lightspeeddms.git-secret-guard.doctor     # is it loaded
tail ~/.local/state/git-secret-guard/doctor.log                            # read the reports
```

It writes `~/Library/LaunchAgents/com.lightspeeddms.git-secret-guard.doctor.plist` and loads it with
`launchctl bootstrap gui/<uid> <plist>`. The plist runs `<recorded bash> <share>/bin/git-secret-guard doctor` (the bash recorded
as `BASH_BIN`, because the CLI needs bash 4.4 and a LaunchAgent does not use your shell), every Monday at 10:00
(`StartCalendarInterval`; launchd runs a slot missed while the Mac slept once it wakes, but not a slot missed while the Mac
was powered off, so unlike `Persistent=true` on Linux a week can pass without a run). Its
`EnvironmentVariables` hold the `PATH` of the git install found first followed by `/usr/local/bin:/usr/bin:/bin`, and each of
`XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CONFIG_HOME` and `GIT_CONFIG_GLOBAL` that was set when you ran install (a LaunchAgent
starts with a bare environment). Stdout and stderr go to `doctor.log` in the state directory, which uninstall removes.

- **Without `--with-timer` nothing is installed**, no `LaunchAgents` directory is created and `launchctl` is never called.
- `launchctl` is looked up on `PATH` once, at install time, and its absolute path is written to the settings file as
  `LAUNCHCTL_BIN`, like `SYSTEMCTL_BIN` on Linux. Uninstall and doctor use that path and never search `PATH`
  (`test_launchctl_is_looked_up_only_in_lib_install_sh`). A missing `launchctl` refuses the install before anything changes.
- The state records `timer_installed=yes` before the plist is written, so an interrupted install can still be uninstalled.
  The plist is written atomically. It starts with the xml declaration and the DOCTYPE; the marker is an XML comment on line 3
  (Python's `plistlib` rejects a comment ahead of the DOCTYPE and launchd's libxpc parser is not CoreFoundation, so
  `plutil -lint` passing proves nothing about launchd; the standard header is used. An XML comment
  cannot hold a double hyphen, so the marker differs from the systemd one). Install refuses to overwrite a plist with the same label that it did not write, before
  anything changes; uninstall leaves such a plist alone and says so.
- A path or variable is XML-escaped (`&`, `<`, `>`, `"`); a control character cannot be written into a plist at all and
  refuses the install. A relative `GIT_CONFIG_GLOBAL` is refused like on Linux.
- `install --with-timer` over a loaded agent boots it out first and bootstraps again (a bootstrap of a loaded label fails and
  a reload reads a changed plist). A failing `launchctl bootstrap` is retried exactly once after a `bootout` and a one second pause
  (a bootstrap right after a bootout can fail while the old job is going away); a second failure leaves the hook installed
  and scanning, says so, and a rerun of `install --with-timer` finishes.
- A plain `install` over an installed timer **keeps it recorded and does not load or unload anything**; `launchctl` is not
  called and not needed (the settings get the `launchctl` found on `PATH` now, or else the recorded `LAUNCHCTL_BIN`, for
  `uninstall`). The plist is rewritten only when
  it is ours and its text changed, with the two `launchctl` commands that make launchd read it; a foreign plist is left alone.
- `uninstall` runs `launchctl bootout gui/<uid>/com.lightspeeddms.git-secret-guard.doctor` when the agent is loaded (an agent
  you unloaded yourself is not an error; a job still loaded after its plist file vanished is booted out by label too, and
  with the plist gone and `launchctl` unusable uninstall says so and goes on), removes the plist and the log, all before the share dir goes (the settings that name
  `launchctl` live there). If a step fails it stops and keeps the share dir, the state and whatever it has not
  removed yet (a failed log removal comes after the plist is gone), prints the manual `launchctl bootout` command when
  the unload is what failed, and running `uninstall` again finishes.
- `doctor` reports a PROBLEM when the state says a timer is installed and the plist is missing or not ours, or `LAUNCHCTL_BIN`
  in the settings cannot run. It does not ask launchd whether the agent is loaded.
- **macOS 13 and later shows a "Background Items Added" notice** when the agent is first loaded; the item is named `bash`,
  because the plist runs the Homebrew bash. If you turn it off in System Settings (Login Items, Allow in the Background),
  macOS stops running the agent. `doctor` cannot detect that (it reads the plist and the settings, it does not ask launchd),
  so a report that stops arriving is the sign; turn the item back on there.
- **Tests never touch the real launchd.** Lifecycle tests put a recording `launchctl` stand-in first on every `PATH` they use
  (`$SANDBOX/launchctl.log`, failures injected through `$SANDBOX/launchctl.fail`), write the plist into the sandbox home, and
  validate it with the real `plutil -lint` and read it back with `plutil -extract` (skipped where `plutil` is absent).

## Maintainer notes

- **Worktree lists are split by `split_lines`** (`lib/core/common.sh`), never by `mapfile <<<`: `DR_LINKED` and the recorded
  `DR_REC_TREES` have no size bound, and Git for Windows bash never returns on a here-string of 65,537 to 65,664 bytes
  ([platforms.md#maintainer-notes](platforms.md#maintainer-notes)). A state line over `GSG_STATE_LINE_MAX` (8192 characters) is a malformed
  state, which keeps the `tools_*` word lists bounded.
- **`git hook list pre-commit`** (2.56) prints `git-secret-guard`, `disabled<TAB>git-secret-guard`,
  `event-disabled<TAB>...` (`hook.pre-commit.enabled=false`) and `hook from hookdir`. Nothing configured = exit 1 with
  `warning: no hooks found for event 'pre-commit'` (empty, not a failure); only the command key missing = exit 128. A local
  `.event=pre-push` adds an event, it never removes the global one. A repository-local `.enabled=false` or `.command` wins.
- **`git config -z` layouts**: `--show-origin --get-all` = `origin NUL value NUL`; `--list`/`--get-regexp` with scope and
  origin = `scope NUL origin NUL key NL value NUL`, a valueless key is just `key` (`doctor_split_record`); `--file F
  --get-all` = `value NUL`. Repository-local origins print relative to the cwd (`doctor_origin_text` makes them absolute).
  `includeIf "gitdir:"` values show scope `global` with the included file as origin.
- **Environment order.** `doctor_start` unsets the pathspec variables and every `git rev-parse --local-env-vars` name
  (`GIT_DIR`, `GIT_CONFIG_COUNT` included) and only **then** sets `GIT_CONFIG_COUNT/KEY_0/VALUE_0` = `core.fsmonitor=false`.
  Tests: `test_doctor_runs_no_command_a_repository_configures`, `test_doctor_never_lazy_fetches_from_a_promisor_remote`,
  `test_an_inherited_git_dir_cannot_point_every_check_at_one_repository`.
- **GitHub Desktop link** (`lib/integrations/desktop/desktop_git_report.sh`): `desktop_git_state` compares every file with the text install would write now (`desktop_git_stale_names`, the generated shared file, wrappers and launcher), so a changed recorded bash, share path or product version shows as the stale file it is, never as a version number. Both `status` and `doctor` read it; neither writes. The platform split is `desktop_git_linux_state` (macOS and Windows get information lines from `desktop_git_other_status` and `desktop_git_other_doctor`). Tests: `tests/integrations/desktop/test_desktop_git_status.sh`.
- **Auto-update report** (`lib/autoupdate/autoupdate_report.sh`): `autoupdate_status_lines` (none of its lines is a PROBLEM; its last check line adds the recorded detail through `AR_STATUS_TEXT`, doctor keeps `AR_LAST_TEXT`) and `autoupdate_doctor_lines`, called right after the Desktop lines. The older check is `autoupdate_needs_install` of `lib/autoupdate/autoupdate.sh` on `<checkout>/VERSION`, so `update` and doctor share one version-gap rule and one strict `x.y.z` test. `checked_at` must match `^YYYY-MM-DDTHH:MM:SSZ$` before `date -u -d` sees it (GNU `date -d` accepts free text such as `next year`). The linger file is `$GITUP_ROOT/var/lib/systemd/linger/<id -un>`, so tests move it with `GSG_GITUP_ROOT` like the other system paths; "now" is the real clock, and the stale cases write an old `checked_at` or `touch -d` the timer unit. The systemctl stand-in does not write the `timers.target.wants` link: `ar_begin` in the test makes it. Tests: `tests/autoupdate/test_autoupdate_report.sh` (`ar_no_tool_calls` proves no `systemctl` or `loginctl` call). `<checkout>/VERSION` is read by `autoupdate_first_line`, which opens only a regular file (a link counts when its target is one) and reads at most `GSG_UPDATE_LINE_MAX` (1024) characters of line 1: a FIFO or a device there is "no version", never a hang (`test_a_fifo_as_the_checkout_version_does_not_hang_doctor`, bounded by `timeout`). Version parts are 1 to 9 digits (`GSG_UPDATE_VERSION_RE`), so a huge one-line VERSION is no version and is never printed. A checkout path is printed cut at `GSG_UPDATE_PATH_SHOW_MAX` (200) characters with `…` (`AR_CO_SHOW`); `-d` and the VERSION read use the path as recorded.
- **Discovery**: `find ROOT -maxdepth 32 ... -name node_modules -type d -prune -o -name .git -prune -print0` under
  `LC_ALL=C`, bound `GSG_DOCTOR_MAX_ENTRIES`; `doctor_prune_args` adds the macOS skips (`-samefile`, see its comment) to
  both finds. Repositories are grouped by `--git-common-dir` (two separate `rev-parse` calls; names may hold newlines).
  `doctor_resolves_here` catches an empty `.git` that git answers for the parent (on Windows it compares in git's `C:/` long
  form, `cygpath -m -l`). A find that fails only with
  `Permission denied` or `Operation not permitted` goes to `doctor_unreadable`, which returns 1 (exit 2) unless its second
  find names 1 to `GSG_DOCTOR_MAX_ENTRIES` unreadable directories; any other failure exits 2. Tests:
  `tests/inspect/test_doctor_home.sh`, `tests/inspect/test_doctor_repos.sh`.
- **Ctrl-C and the discovery finds.** A run on the hosted Mac (bash 5.3.20) measured that a child started by a process
  substitution ignores SIGINT, which made `git hook list` outlive Ctrl-C (`hooklist_read`). Both finds of `doctor_repos.sh`
  (`doctor_discover`, `doctor_unreadable`) used the same shape, so they now run as foreground commands writing
  `$DR_WORK/find.out` / `find2.out`, read after the exit status is taken (`rc=$?`, no `wait "$!"`). Cost: the repository count
  limit (`GSG_DOCTOR_MAX_ENTRIES`) is checked after the whole walk, and the walk's output sits in the work dir until doctor ends.
  Tests: `test_an_interrupt_during_discovery_stops_doctor_and_leaves_no_find_behind` (stalled `find` stand-in, Ctrl-C to doctor's
  group, exit 130, stand-in gone) and `test_the_discovery_finds_run_in_the_foreground_not_in_a_process_substitution`.
  Bash defers a trap until the foreground child exits, so a TERM or HUP sent to doctor's pid alone now waits for the walk (Ctrl-C, the timeout and cgroup stops signal the group and are unaffected); same trade-off as `hooklist_read`.
  **Measured on Linux (bash 5.3.9, Fedora 44):** against the old process-substitution code the behaviour test fails (`find (pid ...) was
  still running after SIGINT ended doctor`), so the leak was real there too, not only on the Mac; it passes with the foreground
  form. **Mac (`macos-suite`, macOS 26.7.2 arm64, Homebrew bash 5.3.20):** both new tests PASS with the foreground form.
  The old code was not run on the Mac, so the Mac leak itself stays unmeasured; the Linux failure on the same bash series is the evidence.
- **Worktrees**: `doctor_check_worktrees` runs `doctor_repo_hook` per checkout; repeats are dropped through `DR_SEEN` and
  `DR_TREE_LABEL`.
- **Time bounds**: `doctor_bound_git` writes a `git` shim (first on `PATH`, also `GSG_GIT`) that runs git under
  `"$TIMEOUT_BIN" -k 5 $DR_LIMIT` **without `--foreground`**, so the whole group dies
  (`test_a_timed_out_doctor_run_leaves_no_process_behind`); the hook adapters keep `--foreground` on purpose.
- **Reuse, don't copy**: `exempt_warn_rows`, `GSG_MSG_BUILTIN_RULES_OFF`, `tools_probe_version`, `settings_tool_bin`,
  `install_collect_gits` (it looks up `PATH`, hence lives in `lib/install/install.sh`). Values are cut only through `trunc_text`
  (sanitise first) and git stderr files are read through `first_message`. Configured hook `command` and `event` values are never
  printed (`doctor_values_text`; `test_the_machine_section_never_prints_a_hook_config_value`); a disabling `enabled` value is.
- **Findings record** (`lib/inspect/doctor_findings.sh`): validated per line (`doctor_rec_line_ok`); `DR_REC_OLD` is assigned only
  after the whole file validated; the limits `GSG_FINDINGS_MAX_*` have one definition for reader and writer;
  `doctor_rec_check_size` refuses an over-limit temp file before the `mv`. An unreached repository's record is dropped only when proven gone (`doctor_rec_proven_gone`). Per-line checks must stay linear
  (`${line//[^$'\t']/}` is quadratic: minutes on a 1 MiB line). `DR_RECHECK` picks the invalid-record wording;
  `DR_FIND_TREE` runs parallel to `DR_FIND` so a worktree finding is recorded with its worktree. `--recheck` validates the
  record before `doctor_require_git` (`test_recheck_with_no_record_or_an_empty_one_prints_nothing_and_runs_no_git`). It runs
  no discovery `find`; the lock-age check and the temp cleanup still use `find`.
- **Lock** (`doctor_rec_lock`): stale when the holder is dead or the link is older than a minute (`doctor_rec_lock_old`).
  On Windows the wait also stops at `GSG_FINDINGS_LOCK_WAIT_SECONDS_WINDOWS` (45): 300 attempts there outlast the one-minute
  stale age (probed), and a live holder would be broken instead of refused.
  **A directory at the lock path:** `ln -s PID DIR` makes `DIR/PID` and returns 0, so every run would think it holds the
  lock. A symlink whose text is all digits is a lock link whatever it points at (`doctor_rec_pid_link`; a directory named
  like the pid may exist, `-d` follows the relative target): `doctor_rec_attempt` never runs `ln` on it, because `ln` would
  write inside that directory, and the loop reads the holder as always. Any other `[ -d lock ]` (also a link to a
  directory) is refused before `ln`: no stale break (it would remove someone's link and take the lock), no wait, flag
  `DR_REC_LOCK_NOT_LINK=1`, one stderr line naming the path, rc 1. The race (a directory appears between that check and
  `ln`) is closed after `ln` in `doctor_rec_try_lock`: the lock counts as taken only when it is a symlink, `readlink` reads
  our pid and `lock/PID` is no link. `ln` never overwrites and no other live process has our pid, so that proves
  `symlink(2)` created exactly the lock path; an existing `lock/PID` after a 0 from `ln` is the stray `ln` made inside a
  directory, removed only if it reads our pid, and only then the flag is set. A read-back that fails otherwise (another
  run's `doctor_rec_break` replaced our link) is no directory: no flag, the loop reads the new holder. It relies only on
  `symlink(2)` failing with EEXIST plus a read-back, so it is atomic on Linux, macOS (BSD `ln`) and Git Bash (GNU `ln`,
  `winsymlinks:sys`). Not `ln -T` (GNU only), not a temp name plus `rename` (`rename(2)` replaces an existing link, i.e.
  steals a live lock; `mv -n` is a check then rename, `mv -T` GNU only). `autoupdate_lock_take` returns 1 for the flag:
  update records `skipped locked` (detail `a directory, not a lock, is at <path>`, the reason first because the detail is
  cut at 160 characters), install and uninstall refuse as for a live holder.
  Git Bash `ln -s` refuses a missing target, so the lock sets `MSYS=winsymlinks:sys` inline; uninstall needs this lock too. Tests shorten the wait with a stand-in `sleep` on the sandbox `PATH`, not a production flag. `uninstall_run` takes the lock
  right after `state_read`, holds it through `uninstall_steps`, releases it on every return path and only then removes the
  state dir; the refused-lock test reruns with the **installed** CLI (a checkout-run test once hid a half-done uninstall).
  The lock-scope guard is a source test, because the probes are bash builtins no `PATH` stand-in can see.
- **systemd timer**: units carry `GSG_TIMER_MARKER` on line 1 and only marked files are touched. `SYSTEMCTL_BIN` is in the
  settings only when a timer (or auto-update) is wanted or recorded; `install_refresh_units doctor` rewrites without enabling, only
  `--with-timer` sets `INSTALL_TIMER_ENABLE`. Units get `PATH` (`timer_unit_path`) and `GSG_TIMER_ENV_NAMES` as
  `Environment=`; `timer_check_values` refuses unescapable values. `systemd-analyze --user verify` needs
  `XDG_RUNTIME_DIR`: tests give it a sandbox dir (`verify_units` in `tests/autoupdate/test_timer.sh`); the Ubuntu container starts
  `dbus-daemon --system --fork`.
- **launchd**: `INSTALL_TIMER_BIN` is systemctl or launchctl by OS (schtasks on Windows, for `--auto-update` only); the one `type -P launchctl` is in
  `install_find_timer_bin`. Plist layout: line 1 the XML declaration, line 2 the DOCTYPE, line 3 the marker comment
  (`launchd_plist_is_ours` checks lines 1 and 3). `GSG_LAUNCHD_LABEL` lives in `lib/core/state.sh` because `paths_init` builds
  `GSG_AGENT_PLIST` from it under `set -u`. `launchd_string` quotes its `${v//&/"&amp;"}` replacements (bash 5.2
  `patsub_replacement` turns a bare `&` into the match). `launchd_write_plist` creates the state dir that holds the log
  (launchd opens the log file but makes no directories). The stand-in `lc_launchctl_standin` is stateful (`launchctl.loaded`) and fails an unmodeled subcommand loudly.
- **Severity icons**: `lib/core/common.sh` (a hook library) holds the only escape sequences and icons: `ui_decide` (the rules of
  [install.md](install.md#sections-levels-and-the-summary)), `ui_terminal STREAM` (decides once per process and stream, `GSG_UI_OUT` and `GSG_UI_ERR`), `ui_mark STREAM TAG`
  (the tag padded to 8 in plain mode, so `printf '  %s %s\n'` is byte-identical to the old `'  %-8s %s\n'`; the icon in terminal mode), `ui_prefix` (nothing, or
  `<icon> `, for a line that starts with an icon) and `ui_worst` (the tag of
  the worst level for a summary icon). A lifecycle command marks the outcome line it prints anyway with `ui_prefix` and never adds a line: terminal output has the lines of plain output. Text is cleaned of control characters before it reaches the helper. `status_line LEVEL LABEL TEXT` counts the PROBLEM and WARNING
  lines itself; the hook-listing subshell cannot, so its exit status (0, 1 or 2) is its number of PROBLEM lines and `status_hook_listing` adds it; any other status prints one `hook list: the check ended with exit N` PROBLEM line and counts 1.
  `status_git_lines` goes on to the system git and unfinished copy lines after a failed `core.hooksPath` read and still returns 1. `update` starts its child `install` with `env -u CLICOLOR_FORCE` (its output reaches `update.log` and the record's detail). The hook starts `doctor --recheck` with `CLICOLOR_FORCE`
  unset: its stdout goes to a file the reminder parses by the plain `  PROBLEM  ` prefixes (`test_in_terminal_mode_the_reminder_heading_gets_the_warning_icon_and_the_recheck_stays_plain`).
  Tests: `tests/inspect/test_ui_levels.sh` (decision, marks, status, doctor), `tests/scan/test_ui_hook.sh`, `tests/install/test_ui_lifecycle.sh`, `tests/install/test_ui_restore.sh`, `tests/autoupdate/test_ui_update.sh`, `tests/inspect/test_ui_status.sh` (stand-ins for inputs, libraries loaded as the CLI does); they force terminal mode with `CLICOLOR_FORCE=1 TERM=xterm LC_ALL=en_US.UTF-8`
  because the harness has no terminal.
