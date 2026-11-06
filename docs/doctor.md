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
(system data, and reading it raises privacy prompts), and the first run still asks for access to folders such as Desktop,
Documents and Downloads: allow it, or those folders are listed as unreadable. `--roots ~/Library` searches it anyway.

**It is read-only except for its findings record** ([below](#the-findings-record-and---recheck)). It runs `git config`,
`git hook list pre-commit`, `git rev-parse`, `git ls-tree`, `git cat-file`, `git ls-files`, `<tool> --version` and, for a
repository with a `.gitleaks.toml` at HEAD, the same betterleaks pre-flight the hook runs. It writes no repository file, no
git config and no install state; the record is its one and only write (with its lock and temp file beside it, and the
state directory, mode 700, created if it is missing). Its only scratch space is one private directory
under `$TMPDIR` (or `/tmp`), removed on exit. `tests/test_doctor_readonly.sh` checksums every file of a sandbox (hashes,
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
`cannot be inspected: fatal: detected dubious ownership ...`, not a doctor error. `tests/test_doctor_readonly.sh` plants a
marker-writing fsmonitor and hooks, and a `--filter=blob:none` partial clone served by a local `file://` remote with a
marker-writing `uploadpack`, and requires no marker file and an unchanged object store.

**It is time-bounded.** Every git call of the repository phase runs under the settings' `timeout`, limited by
`DOCTOR_TIMEOUT_SECONDS` in the settings file (default 30, a whole number from 1 to 999999; an invalid value is a machine
PROBLEM). A
repository whose config makes git block (an `include.path` pointing at a FIFO, say) becomes `cannot be inspected: timed out
after 30s` or `cannot read the hooks git runs (... exit 124: timed out after 30s)`, and the run goes on. The betterleaks
pre-flight uses the smaller of that value and `SCAN_TIMEOUT_SECONDS`; its timeout reads `betterleaks timed out after Ns loading
.gitleaks.toml at HEAD (doctor's limit; the hook allows 300s)`. If `timeout` itself is unusable no git is run in the
repository phase and every repository is listed as not inspected. The timer's service adds `TimeoutStartSec=1h` as the
outer bound.

## Machine checks

| Check | Problem when |
|---|---|
| Installed | no state file (`not installed`) or an unreadable one |
| State records | `tools_installed_by_us`, `tools_placed` or `tools_replaced` hold an invalid word or a tool install does not manage (PROBLEM); two hashes for one tool (an install did not finish placing it) or an aside file recorded in `tools_replaced` that is gone (WARNING) |
| Hook config | `hook.git-secret-guard.event` is not exactly one `pre-commit`, `.command` is not exactly one value equal to the installed `hooks/secret-scan`, that file is missing or not executable, or `enabled` is false in the global or system config. A wrong count is reported as `has 2 values (global <file>; global <file>), 1 of them the installed hook`: **never the values**, a global command can hold a token and the timer writes this output to the journal |
| Tools | the settings file is missing, or `TRUFFLEHOG_BIN`, `BETTERLEAKS_BIN`, `JQ_BIN`, `SETSID_BIN` (`TASKKILL_BIN` on Git for Windows), `TIMEOUT_BIN` is not an absolute executable, or a scanner does not report the version `tools.lock` pins (judged exactly like `install` and `status`); on macOS also a recorded `BASH_BIN` that is not executable or is older than bash 4.4 |
| `core.hooksPath` | any global value is left, including one in the XDG config or in an included file (the file is named) |
| git | WARNING for every reachable git older than 2.54: all `git` on `PATH` plus `/usr/bin/git` (2.52 on the RHEL host) and the git GitHub Desktop bundles (`/usr/lib/github-desktop/resources/app/git/bin/git`, which the warning names: a commit made by it was measured to skip the scan, see [CI on real platforms](platforms.md#ci-on-real-platforms)), by path and version. Such a git ignores config hooks silently, so commits made with it are **not scanned**. Doctor itself needs the git first on `PATH` to be 2.54 or newer (otherwise it exits 2) |
| Timer | only when the state says a timer is installed: both unit files exist, were written by install, and `SYSTEMCTL_BIN` in the settings is usable; on macOS the LaunchAgent plist exists, was written by install, and `LAUNCHCTL_BIN` is usable |

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
parent is judged on its own). Bare repositories have no `.git` entry and are not found.

## Per-repository checks

| Check | Result |
|---|---|
| Is the hook effective? | `git-secret-guard` must be listed, with no prefix, by `git hook list pre-commit`. A `disabled` or `event-disabled` line means `hook.git-secret-guard.enabled=false` or `hook.pre-commit.enabled=false`; the report says `disabled in local config: <key>=<value> (<file>)` and names the scope that holds the key (local, global, worktree, command) and the file git read it from (`--show-origin`, also an included file). Not listed at all means no `hook.git-secret-guard.event=pre-commit` reaches the repository; an event without its command (git refuses) reads `hook not reached: the global hook config is incomplete (see machine section)`. **This check runs in the main checkout and in every linked worktree**: with `extensions.worktreeConfig=true` a worktree can switch the hook off in its own `config.worktree`, and the finding is shown under the main repository as `worktree <path>: disabled in worktree config: ...`. A finding the main checkout already has (shared config) is not repeated per worktree. PROBLEM |
| Command overridden? | the last `hook.git-secret-guard.command` comes from a non-global scope and is not the installed script: `command overridden in local config: hook.git-secret-guard.command (<file>)`. The value is never printed. PROBLEM |
| HEAD `.secret-scan-ignore` | validated with the hook's own code (`scan_ignore_parse`, `scan_ignore_scope`): a line without a reason is a PROBLEM with its line number, as are a symlink or directory, a control character in a pattern, a `..` component and more than 1000 lines (the hook blocks every commit on these); a catch-all (`**`, `./**`, a union of patterns that covers every tracked file, `*` for top-level files) is a WARNING that quotes the pattern as written, cut at 60 characters (a cut is always marked with `…`). Only HEAD counts, never the index or the work tree, and a `git replace` ref cannot substitute it |
| HEAD `.gitleaks.toml` | the hook's own pre-flight (`betterleaks_config_preflight`, under the smaller of `DOCTOR_TIMEOUT_SECONDS` and `SCAN_TIMEOUT_SECONDS`): a config that does not load (a relative `[extend] path`, a syntax error, a timeout) is a PROBLEM; one that loads but leaves betterleaks' built-in rules off is the hook's WARNING sentence. If betterleaks or timeout is unusable the check is reported as not done (WARNING), never skipped silently |
| `.pre-commit-config.yaml` | info when `<common-dir>/hooks/pre-commit` is not the pre-commit framework's hook (`pre-commit install not run`) |
| Repo-local `core.hooksPath` | info (husky and similar): config hooks run whatever it says, so it is harmless, and it is listed so you can see it |

## Output and exit status

```
machine:
  ok       installed: version 0.1.0 (state /home/me/.local/state/git-secret-guard/state)
  ok       state records: 2 placed hash(es), 0 original(s) moved aside
  ok       hook: hook.git-secret-guard.event=pre-commit, command=/home/me/.local/share/git-secret-guard/hooks/secret-scan (executable)
  ok       trufflehog: /home/me/.local/bin/trufflehog 3.99.2 (pinned 3.99.2)
  ok       betterleaks: /home/me/.local/bin/betterleaks 1.9.0 (pinned 1.9.0)
  ok       jq: /usr/bin/jq
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

The machine section is always printed in full. Only repositories with a finding follow it. A repository counts as
**covered** when it has no PROBLEM (warnings and info do not change that). `warnings:` appears only when there are some.

| Exit status | Meaning |
|---|---|
| exit status 0 | no PROBLEM anywhere (WARNING and info lines can still be printed) |
| exit status 1 | at least one PROBLEM, on the machine or in a repository |
| exit status 2 | doctor could not run or finish: git first on `PATH` older than 2.54, a root that is not a directory (the home directory is the default root and must exist, else pass `--roots DIR`), a global git config that cannot be read, a bound exceeded, a `find` failure that is not a permission problem, a usage error. (An unreadable directory is normally a PROBLEM line and exit status 1, see discovery) |

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
machine<TAB>hook: hook.git-secret-guard.event is [unset], want exactly [pre-commit]; run git-secret-guard install
repo<TAB>/home/me/Dev/legacy<TAB>-<TAB>disabled in local config: hook.git-secret-guard.enabled=false (...); remove that key ...
repo<TAB>/home/me/Dev/m<TAB>/home/me/Dev/wt<TAB>worktree /home/me/Dev/wt: disabled in worktree config: ...
```

The scope is `machine` or `repo` with the absolute path and the worktree the finding belongs to (`-` for the main
checkout). The `time` line is the time of the last **full** search; a `--recheck` rewrites the findings but keeps it (the
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

`--recheck` re-runs the machine checks and, for every recorded repository (and recorded worktree), the full per-repository
checks. **It never searches for repositories**, has **no limit on the number of items and no total-time limit** (you run
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
another process cannot hold it forever); a live, recent holder is waited for (300 attempts of 0.1 s) and then refused with
`if no doctor run is active, remove <lock>`. Under the lock, `findings.XXXXXX` temp files older than a minute (left by a
killed run) are removed. `uninstall` takes the same lock before it changes anything; when a live run holds it, uninstall
changes nothing (the installed CLI, the hook section, the share dir and the state stay), exits 1 and says to run `uninstall`
again. Otherwise it removes the record and such temp files with the rest and releases the lock before the state directory
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
- **Discovery**: `find ROOT -maxdepth 32 ... -name node_modules -type d -prune -o -name .git -prune -print0` under
  `LC_ALL=C`, bound `GSG_DOCTOR_MAX_ENTRIES`; `doctor_prune_args` adds the macOS skips (`-samefile`, see its comment) to
  both finds. Repositories are grouped by `--git-common-dir` (two separate `rev-parse` calls; names may hold newlines).
  `doctor_resolves_here` catches an empty `.git` that git answers for the parent (on Windows it compares in git's `C:/` long
  form, `cygpath -m -l`). A find that fails only with
  `Permission denied` or `Operation not permitted` goes to `doctor_unreadable`, which returns 1 (exit 2) unless its second
  find names 1 to `GSG_DOCTOR_MAX_ENTRIES` unreadable directories; any other failure exits 2. Tests:
  `tests/test_doctor_home.sh`, `tests/test_doctor_repos.sh`.
- **Worktrees**: `doctor_check_worktrees` runs `doctor_repo_hook` per checkout; repeats are dropped through `DR_SEEN` and
  `DR_TREE_LABEL`.
- **Time bounds**: `doctor_bound_git` writes a `git` shim (first on `PATH`, also `GSG_GIT`) that runs git under
  `"$TIMEOUT_BIN" -k 5 $DR_LIMIT` **without `--foreground`**, so the whole group dies
  (`test_a_timed_out_doctor_run_leaves_no_process_behind`); the hook adapters keep `--foreground` on purpose.
- **Reuse, don't copy**: `exempt_warn_rows`, `GSG_MSG_BUILTIN_RULES_OFF`, `tools_probe_version`, `settings_tool_bin`,
  `install_collect_gits` (it looks up `PATH`, hence lives in `lib/install.sh`). Values are cut only through `trunc_text`
  (sanitise first) and git stderr files are read through `first_message`. Configured hook `command` and `event` values are never
  printed (`doctor_values_text`; `test_the_machine_section_never_prints_a_hook_config_value`); a disabling `enabled` value is.
- **Findings record** (`lib/doctor_findings.sh`): validated per line (`doctor_rec_line_ok`); `DR_REC_OLD` is assigned only
  after the whole file validated; the limits `GSG_FINDINGS_MAX_*` have one definition for reader and writer;
  `doctor_rec_check_size` refuses an over-limit temp file before the `mv`. Per-line checks must stay linear
  (`${line//[^$'\t']/}` is quadratic: minutes on a 1 MiB line). `DR_RECHECK` picks the invalid-record wording;
  `DR_FIND_TREE` runs parallel to `DR_FIND` so a worktree finding is recorded with its worktree. `--recheck` validates the
  record before `doctor_require_git` (`test_recheck_with_no_record_or_an_empty_one_prints_nothing_and_runs_no_git`). It runs
  no discovery `find`; the lock-age check and the temp cleanup still use `find`.
- **Lock** (`doctor_rec_lock`): stale when the holder is dead or the link is older than a minute (`doctor_rec_lock_old`).
  Git Bash `ln -s` refuses a missing target, so the lock sets `MSYS=winsymlinks:sys` inline; uninstall needs this lock too. Tests shorten the wait with a stand-in `sleep` on the sandbox `PATH`, not a production flag. `uninstall_run` takes the lock
  right after `state_read`, holds it through `uninstall_steps`, releases it on every return path and only then removes the
  state dir; the refused-lock test reruns with the **installed** CLI (a checkout-run test once hid a half-done uninstall).
  The lock-scope guard is a source test, because the probes are bash builtins no `PATH` stand-in can see.
- **systemd timer**: units carry `GSG_TIMER_MARKER` on line 1 and only marked files are touched. `SYSTEMCTL_BIN` is in the
  settings only when a timer is wanted or recorded; `install_refresh_timer_units` rewrites without enabling, only
  `--with-timer` sets `INSTALL_TIMER_ENABLE`. Units get `PATH` (`timer_unit_path`) and `GSG_TIMER_ENV_NAMES` as
  `Environment=`; `timer_check_values` refuses unescapable values. `systemd-analyze --user verify` needs
  `XDG_RUNTIME_DIR`: tests give it a sandbox dir (`verify_units` in `tests/test_timer.sh`); the Ubuntu container starts
  `dbus-daemon --system --fork`.
- **launchd**: `INSTALL_TIMER_BIN` is systemctl or launchctl by OS; the one `type -P launchctl` is in
  `install_find_timer_bin`. Plist layout: line 1 the XML declaration, line 2 the DOCTYPE, line 3 the marker comment
  (`launchd_plist_is_ours` checks lines 1 and 3). `GSG_LAUNCHD_LABEL` lives in `lib/state.sh` because `paths_init` builds
  `GSG_AGENT_PLIST` from it under `set -u`. `launchd_string` quotes its `${v//&/"&amp;"}` replacements (bash 5.2
  `patsub_replacement` turns a bare `&` into the match). `launchd_write_plist` creates the state dir that holds the log
  (launchd opens the log file but makes no directories). The stand-in `lc_launchctl_standin` is stateful (`launchctl.loaded`) and fails an unmodeled subcommand loudly.
