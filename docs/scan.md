# The scan

`hooks/secret-scan` is the scan; the installed copy is what git runs. This page covers what one commit runs and prints
(the added lines, the commit message, the coverage reminder), the settings file the hook reads, what happens on Ctrl-C,
how to run the tests, and the limits of the scan. Exemptions have their own page, [exemptions.md](exemptions.md).

## How it works

1. Git (>= 2.54) runs `hook.git-secret-guard.command` for the `pre-commit` event (the lines the commit adds) and for the
   `commit-msg` event (the message, see [The commit message](#the-commit-message)), from the repo root, before the
   repository's own hook. Both run even if the first fails; the commit is blocked if either fails. The hook tells the
   events apart by its arguments: `pre-commit` passes none, `commit-msg` passes the message file.
2. The script reads tool locations from `settings`, an installed file next to `hooks/` and `lib/`. Missing or
   non-executable `jq`, `trufflehog`, `betterleaks`, `setsid` or `timeout`, or a relative path, blocks the commit and says
   nothing was scanned. `setsid`, `timeout`, `jq` and both scanners come from the settings file only (no environment
   override, no `PATH` lookup), so a planted `setsid` earlier on `PATH` cannot take over the scanner start. (On Git for Windows
   `taskkill` from the settings file, `TASKKILL_BIN`, takes the place of `setsid`.) Each unusable tool prints one line
   (`<tool> is not configured in the settings file`, `<tool> must be an absolute path, got [...]`, `<tool> is missing or not
   executable (<path>)`), then `git-secret-guard: commit blocked; nothing was scanned.` Two more checks come first: a bash
   older than 4.4 blocks with `this hook needs bash 4.4 or newer and is running under bash <version>; run git-secret-guard
   install again ...`, and a `GNUBIN_DIR` that is not an absolute directory blocks with `GNUBIN_DIR in the settings file is
   not an absolute directory (...)`. **`bash` itself comes from the settings
   file too**: install records the bash that ran it as `BASH_BIN` on every platform (Homebrew's on macOS), and the hook command checks it
   and starts the hook with it (`[ -f '<bash>' ] && [ -x '<bash>' ] || { <message>; exit 1; }; exec '<bash>' '<hook>'`), so the
   `#!/usr/bin/env bash` shebang never chooses the interpreter: a `bash` earlier on `PATH` (a stand-in, an old bash, the WSL launcher on
   Windows, #28, #31) is never started, and a recorded bash that is gone blocks with `cannot start the bash the install recorded (<bash>);
   nothing was scanned; run git-secret-guard install`. **Everything
   else the hook runs is found through `PATH`**: `git`, `awk`, `sed`, `cp`, `rm`, `mkdir`, `mktemp` and the other coreutils (not `find`: the hook runs none, it reads the scan tree with bash globs, so a `find` that prints nothing cannot make a commit look empty; not `realpath`: macOS 12 has none, the hook walks its own links with `readlink`). Git prepends
   its own exec-path to `PATH` when it runs a hook, which puts git's directory first; a `PATH` you control decides the
   rest, so a no-op `awk`, `head`, `mv` or `wc` earlier on it is still used; the rows that are left open are Hook gaps in
   [bypass-detection-scenarios.md](bypass-detection-scenarios.md) (N11, N12). Two losses are closed by a cross-check instead of a trusted
   `PATH`: see step 5. Child scripts (`lib/scan/run-scanner.sh`, the coverage re-check) run under the same bash binary as the hook
   (`$BASH`), not through a new lookup.
3. The staged content (the index written as a tree, diffed against HEAD's tree; fixed flags, `-U0`) is turned into a private scan tree under `${TMPDIR:-$HOME/.tmp}`
   (on Windows a `TMPDIR` outside your home is ignored and `~/.tmp` is used, because NTFS ignores `chmod` and only your
   profile's permissions keep the staged lines private) (mode 700, removed on exit and on HUP/INT/TERM): each touched file at its real relative path, each **added** line
   at its real line number, every other line blank. Nothing added (empty commit, deletions only, binary only) means no
   scan is started and the commit proceeds, but only when the extraction also counted no added line: a scan tree with no file
   after the extraction counted lines blocks with `the extraction counted N added lines in M files but the scan tree holds no
   file; nothing was scanned.` The exemptions are loaded before that point, so a repository with a
   `.gitleaks.toml` at HEAD still gets its betterleaks pre-flight ([Exemptions](exemptions.md)), and a config that
   does not load blocks even a commit with nothing to scan. A staged Git LFS pointer is replaced in that tree by its
   object's content (or the commit is blocked), see "Files tracked by Git LFS" under Limits. Blocks of this step, each
   ending in `nothing was scanned.`: `neither TMPDIR nor HOME is set`, `cannot create the temp base directory ...`,
   `cannot create a private temp directory under ...`, `cannot make the temp directory private`, `git write-tree failed (an
   unmerged entry or a missing object in the index)` followed by `cannot write the staged tree ...`, and `extracting the added
   lines of the staged diff failed (...)` after the `extract: ...` line that names the cause.
4. `trufflehog filesystem` and `betterleaks dir` run in parallel, each through `lib/scan/run-scanner.sh` in its own session
   (`setsid`) and under a timeout. The whole scan itself runs as a worker the hook's first process only waits for, so HUP, INT and TERM
   sent to the hook stop even a slow git at once. On HUP/INT/TERM the hook signals both process groups, waits for them, and only
   then removes the temp dir, so no scanner outlives the commit. Windows has no process groups: there the hook finds every
   process below each scanner and stops them with `taskkill /T /F`, without a grace period. If the temp dir cannot be removed
   (Windows keeps a directory with an open file) the hook says so: `could not remove the temporary scan directory <dir>; it
   holds the added lines of your staged changes, delete it by hand`. Results become rows of scanner, detector, status
   (always `match`: a pattern matched, nothing was verified), file and line. Only those are printed, never a value; log lines are
   reduced to their message words. No scanner tests a credential against a vendor: trufflehog runs with `--no-verification`
   and betterleaks never gets its `--validation` flag. Both also run with a dead proxy (`http://127.0.0.1:9`) in their
   environment, see [No verification](#limits). A repository with its own `.gitleaks.toml` at HEAD gets a second, small
   betterleaks run that enables only the `aws-access-key-id` rule (`--enable-rule`), see "A lone AWS access key ID" under Limits.
5. Any finding, any scanner error (unexpected exit status, timeout, unreadable report, error-level log line, skipped
   file, an oversized betterleaks log (more than 5000 lines), a `.gitleaksignore` at HEAD of more than 20000 lines, or
   trufflehog exiting 0 without its `finished scanning` line with `chunks >= 1`) blocks with exit 1 and the hint
   `git commit --no-verify`. A finding prints (real run, a fake GitHub token on line 2 of `c.txt`):

```
git-secret-guard: 2 potential secret(s) in lines this commit adds:
  betterleaks github-pat (match)  c.txt:2
  trufflehog  Github (match)  c.txt:2
  (values are not shown; remove them and rotate any real credential)
What to do:
  1. A real credential: remove it from the change and rotate it. Nothing below is for a real credential.
  2. A false positive or a test value, one line: put the marker of every scanner that reports the line on that same line.
       trufflehog: trufflehog:ignore    betterleaks: betterleaks:allow    both: trufflehog:ignore betterleaks:allow
     A marker works in this commit.
  3. A betterleaks finding on a line that cannot hold a marker: add its line to .gitleaksignore at the repository root:
       c.txt:github-pat:2
  4. A whole path of test data: add "<glob>  # <reason>" to .secret-scan-ignore at the repository root.
     trufflehog has no per-finding file: its finding on a line that cannot hold a marker needs this step.
  .gitleaksignore and .secret-scan-ignore are read from the last commit, never from the commit being made:
  commit the entry by itself first (git add <file> && git commit -m "<message>" <file>), then commit this change.
An automated agent asks its user before adding an exemption or using --no-verify.
To bypass this check for one commit: git commit --no-verify
```

   The guidance (`report_results`, `lib/scan/report.sh`) is built from the scanner, rule, file and line of the rows and fixed text,
   in one awk run, and never reads a value. Step 2 names only the scanners that have a row (`trufflehog: trufflehog:ignore` alone
   for a trufflehog-only block, `betterleaks: betterleaks:allow` alone for a betterleaks-only one, the `both:` form when each has a
   row). Step 3 lists one fingerprint per betterleaks row, at most 10, then `... and N more (<path>:<rule>:<line> of each
   betterleaks row above)`. No fingerprint is printed for a row whose line is `?`, whose file holds `?` or `\`, or whose file is a
   root `.gitleaksignore` or `.betterleaksignore` (scanned under another name, so the row may not show the path betterleaks
   matches); when every betterleaks row is left out, or none exists, step 3 is not printed, the path step is numbered 3 and the
   closing sentence starts with `.secret-scan-ignore`. The path step never builds a pattern from a path (a git glob pathspec).
   `git commit <path>` gives the hook a temporary index, so the printed command scans and commits only the entry file and leaves
   the flagged file staged (`test_real_the_printed_fingerprint_committed_by_itself_with_the_flagged_file_staged_lets_the_change_pass`).
   The icon and the colour stay on the heading; no guidance line has either. A "nothing was scanned" block prints no guidance.
   If the awk run fails, `report_results` returns 1 after the rows, so the commit stays blocked.

   **Cross-check (#31).** Before it decides, `report_results` checks, with bash builtins only, that nothing was lost between the scanners
   and the verdict. A scanner whose exit status said findings (trufflehog 183, betterleaks 42) leaves a `<scanner>.found` marker, and
   one of its rows must be in the sorted rows; a scanner whose own errors file is not empty needs a non-empty collected errors file.
   Otherwise the commit is blocked with `<scanner> reported findings but none reached the report; nothing was decided` (or `recorded
   errors but none reached the report`). A no-op `cat` or `sort` earlier on `PATH` empties the merged files and used to read as a clean
   scan.

   A scanner error prints `git-secret-guard: a scanner did not complete, so the commit is blocked:` and one indented line
   per error (`trufflehog: timed out after 300s; the scan did not complete`, `betterleaks: scan failed (exit <n>)`, ...); the
   second betterleaks run names itself `betterleaks (aws-access-key-id rule)`.
6. A passing commit prints one summary line on stderr, so a clean scan can be told from a hook that never ran (a
   repository-local `hook.git-secret-guard.enabled=false`, a git older than 2.54 that ignores config hooks; a
   `core.hooksPath` does not stop config hooks). Exemption notices and warnings (`using .gitleaks.toml from HEAD ...`,
   `N staged file(s) excluded ...`) come before it and [the coverage reminder](#the-coverage-reminder) after it, when
   they apply:
   - **Scanned:** `git-secret-guard: scanned 3 files, 214 added lines (trufflehog 3.99.2, betterleaks 1.9.0): no findings, 1s`.
   - **Nothing to scan** (only deletions, binary files, mode changes, an empty commit): `git-secret-guard: no added lines to scan`.
   - **Exemptions:** when `.secret-scan-ignore` at HEAD excluded staged files with added lines, the scanned line adds
     `, 2 files exempted` before the time, and a commit whose files are all exempted says
     `git-secret-guard: no added lines to scan (2 files exempted)`. The existing `N staged file(s) excluded` line stays.

   The file and line counts come from the extraction (the scan tree), never from scanner output. The versions are the pinned
   ones `install` verified and recorded in the settings file; the hook never runs `--version`, and a settings file from an older
   install (or a value that is not digits and dots) prints the tool names without versions. The time is whole seconds
   (`$SECONDS`, because bash 4.4 and BSD `date` have no sub-second clock), so it can be off by one. The line holds no path, no
   candidate value and no scanner text. The counts are what was handed to both scanners; betterleaks' default config still skips some
   paths itself (`node_modules/`, lockfiles, `go.sum`, ...), see "Betterleaks' default config skips whole paths" under Limits. Findings and every block keep their output and print no pass line. The `commit-msg` run comes after
   `pre-commit`, so its output follows the pass line: a blocked message prints its findings below the pass line of the lines
   (the lines passed, the message did not), and in a repository with a `.gitleaks.toml` at HEAD its `using .gitleaks.toml from
   HEAD ...` line is printed again after the pass line. There is no switch
   to silence it: `settings` is rewritten by every install, so a hand edit would be lost.

## The commit message

A commit message is pushed and published like code, so a token in it is a leak too. The `commit-msg` event scans it.

- **What is scanned.** The text that becomes the message, from the file git passes (`.git/COMMIT_EDITMSG`, `.git/MERGE_MSG`).
  git runs the event **before** its own cleanup, so the file still holds the comment lines of the editor template. They are
  scanned too: with `--cleanup=verbatim` they stay in the message and the hook cannot know the mode. git's own comment lines
  hold paths, branch names and status words only. With `commit -v` or `commit.verbose` the file also holds the whole diff
  below git's cut line (`<comment char> ------------------------ >8 ------------------------`); that diff is **not** scanned
  **when it is git's own** (see "The cut line"), so a secret that only the removed lines of a `commit -v` diff hold does not
  block. The added lines of the same diff are scanned by the `pre-commit` run.
- **How.** The message becomes one scan file, `COMMIT_EDITMSG`, with its own line numbers, and goes through the same adapters,
  the same HEAD `.gitleaks.toml` and `.gitleaksignore` handling, the same timeouts and the same fail-closed rules as the
  lines. The exemption file `.secret-scan-ignore` names paths and a message has none, so **path exemptions do not apply to
  a message**. A fingerprint in `.gitleaksignore` at HEAD can name it (`COMMIT_EDITMSG:<rule>:<line>`) like any file, and then
  **mutes that rule on that line of every future message** in the repository (line 1, the subject, is the likely one): write such a
  fingerprint only on purpose.
- **Output.** A clean message prints nothing of its own: the pass line of the commit is the only line, and the coverage reminder
  runs only from `pre-commit`. HEAD's betterleaks files are announced as in the lines run (`using .gitleaks.toml from HEAD`,
  `using .gitleaksignore from HEAD`, the built-in-rules WARNING), also by the message run, because a merge and a reword never
  run `pre-commit` and no other run would say what mutes; in a repository that has those files a commit therefore prints
  those lines twice. A finding blocks (exit 1) and prints, without the value, the file shown as `commit message` (real run, a
  fake GitHub token in the body, line 3 of the message file):

```
git-secret-guard: 2 potential secret(s) in the commit message:
  betterleaks github-pat (match)  commit message:3
  trufflehog  Github (match)  commit message:3
  (values are not shown; remove them and rotate any real credential)
What to do:
  1. Write the message again without the value, and rotate a real credential.
  2. A false positive that must stay in the message: put the marker of every scanner that reports the line on that same line
     (trufflehog: trufflehog:ignore, betterleaks: betterleaks:allow). The marker stays in the commit message.
An automated agent asks its user before adding an exemption or using --no-verify.
To bypass this check for one commit: git commit --no-verify
```

  The four guidance lines are fixed text and never name `.secret-scan-ignore`, `.gitleaksignore` or `COMMIT_EDITMSG` (a path
  exemption does not apply to a message, and a fingerprint would mute that rule on that line of every later message). Inline
  markers apply to a message like to any scanned line: `trufflehog:ignore` and `betterleaks:allow` on the line of the value
  silence the tools (`test_real_the_message_guidance_is_printed_and_both_markers_on_the_token_line_make_the_commit_pass`).

  An empty message file is not scanned. A run with more than one argument blocks with `the commit-msg run needs exactly one
  argument, the message file, and got N; nothing was scanned.`, a message file that is missing or unreadable with `cannot read
  the commit message file git passed; nothing was scanned.`, and a HEAD betterleaks file that cannot be applied with `could not
  apply the repository's betterleaks files from HEAD; nothing was scanned.`
- **The cut line.** git writes the diff below its cut line only for `commit -v` (also `commit.verbose`, `-v -v`) and the
  template of `--cleanup=scissors`, and cuts there only under those modes; with `-F` of a file that holds a cut block (a
  reused `.git/COMMIT_EDITMSG`) the text below it is **committed**. So the hook skips text below a cut line only when it is
  **provably git's own diff**: after the cut line and its comment lines, the text up to the next comment line must equal, byte
  for byte, `git diff --cached` (the staged diff; base `HEAD`, `HEAD^` or the empty tree). **Hidden text is only ever a real diff
  between `HEAD` or `HEAD^` and the staged tree; a secret it contains is already in history** (its removed lines are in a commit
  of the history, its added lines are in the tree being committed, which `pre-commit` scans), so hiding it puts nothing into the
  repository that is not already there. `HEAD^` is tried on an ordinary commit too: that is safe for the same reason (it is the
  base of `--amend`, which the hook cannot tell from a plain commit). The comparison runs in the hook's own repository and index
  under the hook's timeout (`TIMEOUT_BIN`, `SCAN_TIMEOUT_SECONDS`, `--foreground`; a timeout or a failure is a mismatch) with
  `--no-color --no-ext-diff --no-textconv` and `core.fsmonitor=false`, so it never runs a command the repository configures; the
  user's `diff.*` settings apply as for `commit -v`, and `diff.mnemonicPrefix` may be as configured or on (`-v -v` forces it).
  **The work tree part of `commit -v -v`** (after `# Changes not staged for commit:`) is **never hidden**: `git diff` of the
  work tree converts files (it runs `filter.<x>.clean`), and its text is in no tree and in no commit, so a token on an unstaged
  line must not pass through a message file reused with `-F`. Everything else is scanned too, including the cut line, the comment
  lines under it and any text that is not that diff: a copied or forged cut block hides nothing. Matching lines become blank
  lines, so line N of the scan file stays line N of the message. A diff the hook cannot rebuild (a `textconv` driver on a staged
  file, an amend of a commit whose base cannot be found, a diff git cannot print in time) is scanned too. **A false block is
  possible**: a secret-looking removed line in the work tree diff of `-v -v`, or in a diff the hook cannot rebuild, blocks the
  commit; the hook fails safe, and `-m`, or no `-v`, avoids it. The comment characters come from the cut line itself, not from
  `core.commentChar`, because `auto` picks a character the config does not hold.
- **Bypass.** `git commit --no-verify` skips both events, as it skips `pre-commit`.

Which commands run `commit-msg` (git 2.56, probed, see the maintainer notes):

| Command | Event runs | Scanned |
|---|---|---|
| `git commit` (`-m`, `-F`, editor, `-v`, `--amend`, `--cleanup=...`) | yes | yes |
| `git merge` that makes a commit, `git commit` after a merge or `merge --squash` | yes | yes (the lines of an automatic merge are not: it fires `pre-merge-commit`) |
| `git rebase -i` with `reword` | yes | yes |
| `git rebase -i` with `squash`, `fixup` (also `fixup -C`) | no | **no** (the combined message is committed unscanned) |
| `git revert`, `git cherry-pick` (also `-e`), a pick of a rebase, `git am` | no | **no** (`am` runs `applypatch-msg`) |
| `git tag -a`, `git notes` | no | **no** |

## The coverage reminder

A repository where the hook is switched off never runs it, so the reminder shows up in the commits of the repositories that
are still covered. When `doctor` has recorded PROBLEMs ([the findings record](doctor.md#the-findings-record-and---recheck)),
every commit ends with:

```
git-secret-guard: scanned 1 file, 1 added line (trufflehog 3.99.2, betterleaks 1.9.0): no findings, 1s
git-secret-guard: 2 coverage problems still open (doctor run 2026-11-03):
  machine: hook: hook command is missing or not executable (...); run git-secret-guard install
  /home/me/Dev/legacy: disabled in local config: hook.git-secret-guard.enabled=false (...); remove that key to cover this repository
  run git-secret-guard doctor for the full report
```

- **When.** After the hook has decided the commit: after the pass line, after the findings block and its
  `git commit --no-verify` hint, after a "nothing was scanned" block, after "no added lines to scan". The `date` is the
  `time` line of the record (the last full search). The count and the lines come from what `doctor --recheck` still finds
  broken, so a repository you fixed stops being listed on the next commit and leaves the record.
- **How.** The hook starts `<share>/bin/git-secret-guard doctor --recheck` as a separate process (its own session, through
  the same `bash` the hook runs under), never by loading doctor code. Every recorded repository is re-checked, with no limit
  on their number and no total time limit; each git call keeps `DOCTOR_TIMEOUT_SECONDS`. The `GIT_*` variables git sets for
  a commit (`GIT_INDEX_FILE`, ...) are removed first, so the re-check of another repository reads that repository.
- **Nothing on record costs nothing.** No findings file, an empty one, or one that holds only its two header lines (a
  clean full run) starts no process. A damaged record is re-checked, so doctor says so.
- **The commit never changes.** A pass stays a pass and a block stays a block with its own exit status, whatever the
  re-check does. If it fails (exit 2, killed, the CLI missing, output that cannot be read) one line says so, and nothing
  from doctor's stderr is copied: `git-secret-guard: coverage re-check failed (doctor --recheck exit 2); run git-secret-guard doctor`.
  The other reasons in the parentheses: `doctor --recheck printed nothing readable` (exit 1 without a PROBLEM line), `neither
  XDG_STATE_HOME nor HOME is set`, `the state directory is not an absolute path`, `git rev-parse --local-env-vars failed` and
  `cannot clear the work dir`. The record is `$XDG_STATE_HOME/git-secret-guard/findings`, or
  `~/.local/state/git-secret-guard/findings` without `XDG_STATE_HOME`.
- **The scan tree is gone first.** Before the re-check starts, the hook empties its private temp dir (the scan tree with the
  added lines and the scanner files), so nothing of the commit stays on disk while doctor runs.
- **Ctrl-C** during the re-check stops doctor and its process group before the hook exits. One exception: doctor runs each
  git call under `timeout` without `--foreground` on purpose (so a timeout kills the whole git group), which puts that call
  in its own group. A git call already running when Ctrl-C arrives is therefore not reached by the hook's group kill; it
  ends by itself within `DOCTOR_TIMEOUT_SECONDS` (plus 5 seconds for the kill).
- **No reminder** when the hook blocks before it has a private temp dir: a missing or unusable tool in the settings file,
  an unusable `TMPDIR`. Those blocks name their own cause. `doctor` reports an unusable tool as a machine problem; an
  unusable `TMPDIR` stops doctor itself (`cannot create a temp directory`, exit status 2).
- Only PROBLEM lines doctor already cleaned are printed, never a value, secret or file content.

## The settings file

The hook reads `<share>/settings` (`<share>` = two levels above the resolved script path), written by `install` (`install_write_settings`, with `printf %q`, because the hook sources it):
absolute `TRUFFLEHOG_BIN`, `BETTERLEAKS_BIN`, `JQ_BIN`, `SETSID_BIN` (`TASKKILL_BIN` on Windows), `TIMEOUT_BIN`, the pinned `TRUFFLEHOG_VERSION` and
`BETTERLEAKS_VERSION` (shown on the pass line only) and `SCAN_TIMEOUT_SECONDS`, `BASH_BIN` (every platform), plus the macOS key `GNUBIN_DIR`
and the timer key `SYSTEMCTL_BIN`, `LAUNCHCTL_BIN` (macOS) or `SCHTASKS_BIN` (Windows) (see [install.md](install.md)). On Windows `JQ_BIN` is the
wrapper `<share>/jq` that install writes, which runs the `jq` it found or installed with `-b`. `DOCTOR_TIMEOUT_SECONDS` is read when present
(by `doctor`, see [doctor.md](doctor.md)) but install never writes it. A missing,
relative or non-executable tool path blocks the commit and says nothing was scanned. A missing `SCAN_TIMEOUT_SECONDS`
means 300; only an integer from 1 to 999999 written without a leading zero is accepted, anything else blocks (empty, a non-digit, `0`, `00`, `007`, `1000000`). GNU `timeout` reads `00` as no limit and fails open on a value of about 20 digits, so those must never reach it; `007` would mean 7 and is refused only to keep one strict form, the same as the pre-flight; missing or non-numeric versions only drop the versions from
the pass line. An inherited environment variable of the same name as any key is discarded before the file is read.
A missing or unreadable file prints `settings file is missing or unreadable: <path>`, a bad timeout `SCAN_TIMEOUT_SECONDS
must be a positive integer, got [...]`; both then block with `cannot read the settings file; nothing was scanned.`
Skip once with `git commit --no-verify`; automation can disable only this hook with
`GIT_CONFIG_PARAMETERS="'hook.git-secret-guard.enabled'='false'"` (the repository's own hooks still run).

## Signals

Ctrl-C (SIGINT), SIGHUP (a closed terminal) and SIGTERM stop a running hook at once, in any phase: a slow `git write-tree` or
`git diff-tree`, the scanners, the message run's `git diff --cached`, the coverage re-check (one exception there, see
**Ctrl-C** under [The coverage reminder](#the-coverage-reminder)).
The hook exits 130, 129 or 143, so git aborts the
commit. Before it exits, every process of the run gets TERM, then KILL if it is still running after a grace period (5 s for
the scanners, 15 s for the scan as a whole), and the private temp dir with
the added lines is removed; on Git for Windows the processes are stopped with `taskkill /T /F`. A signal sent to the hook's
pid alone (`kill <pid>`) works the same as one sent to its process group. A shell job line such as `Terminated  staged_diff |
extract_added_lines ...` may be printed during the stop; it is expected. A `kill -KILL` of the hook cannot be handled: the
worker it started keeps running in its own process group until the scan finishes (the scanners have time limits,
extraction has none), and nothing removes its temp dir early. How the hook does this: [Supervisor and worker](#maintainer-notes).

## Tests

```bash
tests/run.sh                 # all suites; PASS/FAIL/SKIPPED per test, nonzero exit on any failure
tests/run.sh tests/scan/test_hook.sh
tests/coverage.sh            # same suites under xtrace, prints shell line coverage
```

Every suite runs in a sandbox: a scratch `HOME`, scratch `XDG_*` directories, `GIT_CONFIG_GLOBAL` and
`GIT_CONFIG_NOSYSTEM=1`, so the real `~/.gitconfig`, `~/.local` and `~/.config` are never touched. The lifecycle suites
(every file that starts its tests with `lc_begin` from `tests/support/lifecycle.sh`: `test_install.sh`, `test_uninstall.sh`,
`test_status.sh`, `test_tools.sh`, `test_cli.sh`, `test_lifecycle_e2e.sh`, `test_timer.sh`, several `test_gitup*.sh`, the
`test_desktop_git*.sh` and platform files, ...) install from local fake tarballs through `GSG_TOOLS_BASE_URL` and
`GSG_TOOLS_LOCK`; `test_install_network.sh` downloads the real tarballs and is reported as `SKIPPED` (never as passed) when
GitHub is not reachable. Every lifecycle test finds recording `systemctl` and `brew` stand-ins first on its `PATH`. The doctor
suites (`test_doctor*.sh` and `test_reminder.sh`, through `dr_begin` from `tests/support/doctor.sh`) use the same sandbox, with
repositories under a scratch root.

Runtime needs bash 4.4 or newer, `setsid` (util-linux; `taskkill` on Windows), `timeout` (coreutils), awk, `jq` and, for
`install`, `curl` and `tar`. The tests drive `GSG_TEST_GIT` (default `/usr/local/bin/git` on Linux, `/usr/bin/git` on macOS,
the one on `PATH` on Windows; it must be >= 2.54).
`shellcheck` 0.11.0, `pre-commit` and the real `trufflehog` and `betterleaks` are optional: the tests that need one skip
with a reason when it is absent. `tests/fetch-test-tools.sh` downloads the pinned scanners (SHA-256 checked) into
`~/.cache/git-secret-guard-test-tools`, where the Windows and macOS harness looks by default; on Linux point
`GSG_TEST_TRUFFLEHOG` and `GSG_TEST_BETTERLEAKS` at them. Other overrides: `GSG_TEST_JQ`, `GSG_TEST_SHELLCHECK`,
`GSG_TEST_SETSID`, `GSG_TEST_TIMEOUT`.

## Credential rules

betterleaks runs its built-in rules plus the rules of `lib/scan/betterleaks-rule.toml` (the generated config has `[extend] useDefault = true`).
Besides `aws-access-key-id` ([Limits](#limits)), that file holds credential rules for shapes both scanners let through: each was
written only after a test showed the built-in rules and trufflehog miss it (`tests/scan/test_bypass_formats_real.sh`). They are
offline and pattern-only (no `validate`, no network) and run in the main betterleaks run.

| Rule | Blocks | Needs |
|---|---|---|
| `putty-private-key` | a PuTTY private key file (`.ppk`), format 2 or 3, encrypted or not | its header line at the start of a line |
| `azure-sas-signature` | an Azure shared access signature, account or service (trufflehog's `AzureSasToken` covers only a service SAS, `sr=`) | `sv=<yyyy-mm-dd>` before `sig=` on the same line; a signature of 40-120 base64 or percent-encoded characters, entropy 3.5 |
| `authorization-bearer-token` | a token after the word `Bearer` (an `Authorization` header in code, a `.http` file, a config); betterleaks' `curl-auth-header` covers only a `curl` command | 20 or more token characters with a letter, a digit and entropy 3.5, plus an uppercase letter, a run of 20 letters and digits, or 4 digits (a UUID token) |
| `password-assignment` | a quoted password assigned to a name ending in `pass`, `pwd` or `passphrase` (`db_pass`, `userpass`, `DB_PASS`, `app.db.pass`), or to `pw` | `=`, `:=`, `=>` or `:` and a quoted value of 8-128 characters with a digit or a symbol, entropy 2.7; not a template or an interpolation (`${...}`, `$VAR`, `$VAR/...`, `$(...)`, `#{...}`, `$env:`, `%env(...)%`, `{name}`, `{{`, `<...>`, `%(`, `@Microsoft.KeyVault(...)`), a path, a placeholder word, or lowercase words joined by `_` or `-` without a part of two or more digits (`tokenize_v2` passes, `hunter_2024` blocks) |
| `password-assignment-bare` | the same names with an unquoted value (env files, properties, YAML) | `=`, `:=` or `=>`, or `<name>: <value>` as a YAML key at the start of a line (also a `- ` list item); the conditions above, and not a member access or reference (`user.password`, `process.env.DB_PWD`, `var.db_pass`), a relative path (`refs/heads/main`), a secret-manager reference (`arn:`, `vault:`, `sm:`, `ssm:`, `op:`, `gcp:`, `azure:`, `keyvault:`) or a value starting with `$ % { < @ # . / ~ \` |
| `deepseek-api-key-bare` | a DeepSeek key, `sk-` and 32 hex digits | nothing else (betterleaks' `deepseek-api-key` needs the word deepseek before it) |
| `elevenlabs-api-key-bare` | an ElevenLabs key, `sk_` and 48 hex digits | the same, for `elevenlabs-api-key` |
| `stability-ai-api-key-bare` | a Stability AI key, `sk-` and 48 letters or digits (an old-style OpenAI key has the same shape and is reported by it too) | entropy 3.5 |
| `voyageai-api-key-bare` | a Voyage AI key, `pa-` or `al-` and 43 URL-safe characters | entropy 4 |
| `azure-openai-api-key` | an Azure OpenAI key (32 hex digits, or 84 letters and digits) | assigned to `AZURE_OPENAI_API_KEY` or `AZURE_OPENAI_KEY` (any case, `_`, `-` or `.`), or passed as `api_key=` inside `AzureOpenAI(...)` on one line |
| `azure-openai-api-key-header` | the same key in an `api-key:` header | an `*.openai.azure.com` or `*.cognitiveservices.azure.com` endpoint within 5 lines (the hidden helper rule `azure-openai-endpoint`) |

**The built-in rules cover the rest**, and no rule here repeats one: `password`, `passwd`, `*_PASSWORD`, `PGPASSWORD` and `*_pw` are
betterleaks' `generic-password`, `secret`, `token` and `*_key` names its `generic-api-key`; Slack, Azure storage keys, Entra ID client secrets,
JWTs, connection strings, user:password URLs and the AI vendor keys of [bypass-detection-scenarios.md](bypass-detection-scenarios.md#ai-vendor-api-keys)
have rules or detectors of their own. Where a bare-key rule here matches the same key as a built-in vendor rule (a DeepSeek key after
`DEEPSEEK_API_KEY=`), both findings are reported. A low-confidence generic built-in (`generic-password`, `generic-api-key`) on the same
value can be left out next to ours: that is why the two `password-assignment` rules do not list the names those two already cover.

**Not detected:** a key with no shape of its own written bare on a line (Mistral, Cohere, Together AI, Deepgram, AssemblyAI, Weights &
Biases, Azure OpenAI, and a legacy Pinecone key, which is a plain UUID): it looks like any hash or id, so only the vendor's name, a key
variable or a client call next to it makes it a finding (betterleaks' vendor rules, `generic-api-key`, the two Azure OpenAI rules above; the
legacy Pinecone key needs `pinecone` before it, `pinecone-api-key.1`). A SAS whose `sig=` comes before `sv=`, a password with a space in it,
a password of letters only or under 8 characters (`hunter2`), one of 8-9 characters with several repeated characters (entropy
below 2.7), joined lowercase words without a two-digit part (`blue_sky_7`), an unquoted password shaped like a
reference or a relative path (`DB_PASS=My.Secret2024`; quoted, it blocks), and a password under a name these rules and the built-in ones
do not list (`bypass`, `mypass`).

**False positives.** A test value or a real-looking example blocks like a real one: an `sk-`-shaped id, a `Bearer` sample in documentation,
a test password in a fixture, a documentation line that starts with the `.ppk` header, a hash prefix or a version string under a
password name (`pw = "sha256$..."`, `pass: v1.2.3-rc4`). Placeholders pass: `changeme`, `<password>`, `${VAR}`, `{{ .Values.x }}`, `$VAR`, `********`, `xxxx...`,
values with `example`, `placeholder`, `redacted`, `dummy` or starting with `your`, all-digit values, paths (`PWD=/home/...`), function
calls (`os.getenv(...)`), member access and references (`user.password`, `process.env.DB_PWD`, `var.db_pass`), relative paths,
compiler-pass names of lowercase words joined by `_` or `-` (`first_pass = "tokenize_v2"`; a dotted one such as `lexer.v2` blocks), interpolation (`"#{ENV[...]}"`, `"$env:X"`, `"$(X)"`, `"$PWD/out"`, `'%env(X)%'`),
Key Vault and secret-manager references (`@Microsoft.KeyVault(...)`, `arn:...`, `vault:...`), prose after `bearer`, and the shell's `PWD`/`OLDPWD`. Accept one like any finding: a `.secret-scan-ignore` entry committed at HEAD, or
`betterleaks:allow` on the line ([Exemptions](exemptions.md)).

**Tests:** `tests/scan/test_bypass_formats_real.sh`, through the hook with both real scanners: a blocked case for every rule and form,
the placeholders, templates, paths and prose above in a commit that must pass, and a plain UUID and hex hashes without vendor context.

**Limit: a `.gitleaks.toml` at HEAD turns these rules off,** as it does the PII rules (below).

## PII rules

Besides credentials, the hook blocks personal data the way it blocks a secret: the finding names the rule, the file and the line, and
the value is never printed. The rules are betterleaks rules of ours (`lib/scan/betterleaks-rule.toml`), offline and pattern-only (no
`validate`, no network). They run in the main betterleaks run, together with the built-in rules.

| Rule | Blocks | Needs |
|---|---|---|
| `pii-us-ssn` | a US Social Security number written `NNN-NN-NNNN` | nothing (no keyword needed); not inside a longer digit or dash run; area not 000, 666 or 900-999, group not 00, serial not 0000 |
| `pii-us-ssn-context` | the same number as 9 bare digits or `NNN NN NNNN` | an SSN keyword on the **same line** (`ssn`, `social security`, `socialSecurityNumber`, `soc sec`, `taxpayer id`, `tin`, any case) |
| `pii-credit-card` | Visa (13, 16 or 19 digits), Mastercard (51-55, 2221-2720), Amex (34, 37), Discover (6011, 65, 644-649), with optional spaces or dashes | a passing **Luhn check**; not inside a longer alphanumeric run |
| `pii-iban` | an IBAN, compact or in groups of four | a passing **mod-97 check**; not inside a longer alphanumeric run |
| `pii-phone-context` | an E.164 number (`+` and 8-15 digits) or a North American number | a phone keyword (`phone`, `mobile`, `tel`, `cell`, any case) on the **same line**; for a North American number the area code and the exchange do not start with 0 or 1 |

A keyword on the line above does not count (`ssn:` then the number on the next line is not reported).

**Not detected:** email addresses; bare high-entropy strings with no keyword (betterleaks' own `generic-api-key` still catches those next
to a keyword); an SSN without dashes and without a keyword; phone numbers without a phone keyword; PII of other countries; card numbers
and IBANs that fail their checksum.

**Checksums.** The `filter` key of a betterleaks rule is an expression (expr-lang) that drops a finding
when it is true. It computes the Luhn sum and the IBAN mod-97 without any network call, so a card or IBAN that is only shaped like one
is **not** reported. Both filters first check the shape of the secret, because `betterleaks config check` runs each filter on a dummy value.

**False positives.** Every rule can block legitimate data:

- a dashed `NNN-NN-NNNN` that passes the structure checks blocks without a keyword (a part number written that way, for example);
- a Luhn-valid or mod-97-valid identifier that is not a card or an account still blocks, as does a published test card number;
- a 17-19 digit number whose first 16 digits pass Luhn, or a spaced IBAN-shaped value that passes mod-97 without its last group, blocks too;
- the context rules block an unrelated number of the right shape when their keyword is on the line;
- known test values are not allow-listed by default.

Accept one like any other finding: a `.secret-scan-ignore` entry with a reason, committed at HEAD, or the inline `betterleaks:allow`
marker on the line ([Exemptions](exemptions.md#accepting-a-pii-false-positive)). The tests are `tests/scan/test_pii_real.sh` (real betterleaks,
every rule with positive and negative cases) and the PII tests of `tests/scan/test_adapter_betterleaks.sh`.

**Limit: a `.gitleaks.toml` at HEAD turns the PII rules off** (and the [credential rules](#credential-rules)). A repository config runs
exactly as written and replaces our config, so the PII rules do not run. Only `aws-access-key-id` still runs, in its own isolated run ([A lone AWS access key ID](#limits)); a PII value
is not reported by that run (`test_real_pii_the_isolated_aws_run_reports_no_pii_and_existing_detection_is_unchanged`). A repository that wants
PII detection together with its own config can put the same rules into that config (not tested here).

## Limits

- **Git >= 2.54 only.** Older git (e.g. `/usr/bin/git` 2.52) ignores config hooks without any message; its commits are
  not scanned.
- **Two events only.** The lines are scanned by `pre-commit` and the message by `commit-msg` ([table](#the-commit-message)).
  Not scanned: the lines of commits that do not fire `pre-commit` (a merge commit that `git merge` makes by itself, it fires
  `pre-merge-commit`; `git cherry-pick`, `git rebase` and `git am`), and the messages of commits that do not fire `commit-msg`
  (`git revert`, `git cherry-pick`, `git am`, the picks, `squash` and `fixup` of a rebase), of tags (`git tag -a`) and of `git notes`. A merge
  finished with `git commit` fires both events and is scanned. Probed on the real install (git 2.56): a fake key
  committed on a branch with `--no-verify` reached `main` through `cherry-pick` and through `rebase` with exit 0 and no
  scan. Scan before a branch is shared; `--no-verify` there is the hole, not the replay.
- **Tag messages and notes.** An annotated tag message and `git notes` are not scanned: `git tag -a` and `git notes add`
  run neither `pre-commit` nor `commit-msg`.
- **A cut block hides only the staged diff of git.** Text below a cut line is skipped only when it equals `git diff --cached`
  against `HEAD` or `HEAD^` ([The cut line](#the-commit-message)): hidden text is only a real diff between `HEAD` or `HEAD^` and
  the staged tree, and a secret it contains is already in history. A copied, edited or forged block, and the work tree part of
  `commit -v -v`, are scanned, so a secret-looking removed line there can block (a false block, the hook fails safe).
- **About 2 seconds per commit for the lines, about 2 more for the message.** Both scanners start on every commit that adds
  lines (measured 1.8 s per commit on this machine, git 2.56, the pinned scanners) and on every commit message (measured
  1.7 s more, 3.5 s per commit in all). The cost is trufflehog's start-up (1.6 s on a one-line directory; betterleaks
  needs 0.05 s and the hook itself 0.1 s), so a short message costs as much as a long one. Commits that add nothing
  (deletions only, empty) start no lines scan (only the betterleaks pre-flight, when there is a `.gitleaks.toml` at HEAD).
- **The repository's own hooks still run when the scan blocks.** git runs every hook configured for `pre-commit`, the
  config hook and the repository's hookdir hook (`.git/hooks`, husky, the pre-commit framework); a blocked scan does not
  stop the repository's hook from running (probed: its marker file was written while the commit exited 1).
- **Test harnesses that copy `~/.gitconfig` get the hook too.** A sandbox whose `HOME` holds a copy of your global config
  runs the scan on its own test commits (probed: a fake key in a copied-config sandbox was blocked). Such a harness should
  set `hook.git-secret-guard.enabled=false` in its copy, or pass `-c hook.git-secret-guard.enabled=false`, or set
  `GIT_CONFIG_PARAMETERS="'hook.git-secret-guard.enabled'='false'"`.
- **Only added lines of text files.** Anything git treats as binary is not scanned, because git shows no content for
  it. That includes **UTF-16 text** (with or without a BOM, e.g. a file saved by Windows tools) and any file that
  contains a NUL byte: a UTF-16LE file holding a credential commits unscanned (the hook says `no added lines to scan`, because git treats the file as binary)
  (`test_real_utf16_and_nul_byte_files_commit_unscanned_a_documented_limit`). Convert such files to UTF-8 first. Pure
  renames and mode changes add no lines. A symlink's blob is its target path, scanned as a one-line file, so a token
  written as a link target is blocked. A submodule is its own repository: commits made in it run this hook there
  (`test_real_catalog_d18_d19_d20_worktrees_submodules_and_new_repositories_are_covered`), and in the superproject the
  gitlink adds one line, `Subproject commit <id>`.
- **Files tracked by Git LFS: the object is scanned, or the commit is blocked.** git commits the 3-line pointer of an
  LFS-tracked file; the content sits in the LFS storage and goes to the server on push.
  The hook never runs `git-lfs`. A staged blob is a
  pointer when its content (under 1024 bytes, as git-lfs counts) is read **the way git-lfs 3.7.1 reads it**, whatever `.gitattributes`
  says; anything else is scanned as text. That is wider than the spec text: the blob is trimmed of Unicode white space, split at LF,
  a trailing CR dropped, empty lines skipped; the lines are `version` (one of `https://git-lfs.github.com/spec/v1`,
  `https://hawser.github.com/spec/v1`, `http://git-media.io/v/2`), `oid sha256:<64 lowercase hex>` and `size <n>` in that
  order, with any number of `ext-<digit>-<word character>... sha256:<64 hex>` lines before the size line; the size may carry a `+`
  or leading zeros (up to int64). Every form in this paragraph was probed with `git lfs pointer --check` and pushes its
  object; `test_real_the_hook_recognises_exactly_the_pointers_git_lfs_accepts` compares the hook with git-lfs on 46 fixtures.
  A pointer with an **`ext-` line is recognised and then blocked**: a Git LFS extension (`lfs.extension.<name>.clean`, for
  example `gzip -nc`) makes git-lfs store the output of a command from the repository's config, so the object is the
  transformed bytes and not the file (measured with a gzip extension: a binary object holding the key, pushed). The block
  line is `git-secret-guard: Git LFS file <path>: it uses the Git LFS extension <name>, so its stored object is transformed
  and cannot be scanned`. The hook never runs the configured command. git-lfs pushes only blobs under 1024 bytes, so a blob
  of 1024 bytes or more is scanned as text. The object is read from
  `<storage>/objects/<oid[0:2]>/<oid[2:4]>/<oid>`, where the storage is `<git common dir>/lfs` (so linked worktrees work) or
  the `lfs.storage` of any git config scope (repository, global, system, `-c`; a relative value is taken from the common
  dir). A committed `.lfsconfig` is never read. The location decides nothing about safety, because size and SHA-256 are
  checked on the copy. The object must be a regular file (not a symlink), have the size the pointer says and the SHA-256 the oid says; its copy is then scanned as the added file, with
  the pointer's path, and the pass line counts its lines instead of the pointer's. A binary object (a NUL in the first 8000
  bytes) is verified and adds no lines, like any binary file. When the object is missing, unreadable, a symlink, or fails the
  size or SHA-256 check, the commit is **blocked** (there is no warn-and-pass) with one line per file, e.g.
  `git-secret-guard: Git LFS file data/big.dat: its object is not in the LFS storage (/repo/.git/lfs)`, then
  `...could not be scanned..., so nothing was committed; run 'git lfs install', then 'git add' the file again, or commit from the
  machine that has the content.` When the only problems are extension pointers the advice is `a file stored through a Git LFS
  extension cannot be scanned: commit it without the extension (remove its lfs.extension setting for this path and 'git add' it
  again)`, and when both kinds occur both pieces are printed (`lfs_block_text`). There is no size limit on an object: SHA-256 and the copy read the whole file, outside the
  scanner timeout. A pointer committed earlier without this check is not rescanned (only changed pointers are). Needs
  `sha256sum` (coreutils; on macOS through `GNUBIN_DIR`, with Git for Windows); a missing or failing one blocks with
  `the SHA-256 of its object cannot be computed (sha256sum is missing or failed)`. The other reasons after
  `Git LFS file <path>:` are `its object is a symbolic link, not a regular file (<object>)`, `its object is not a regular file
  (<object>)`, `its object cannot be read (<object>)`, `its object is <n> bytes, the pointer says <m> (<object>)` and `its
  object does not match the pointer (SHA-256 differs from the oid; <object>)`. A git failure while looking for pointers blocks
  with `cannot read the staged blobs to look for Git LFS pointers` or `cannot find the Git LFS storage or count the staged
  lines`. SmartGit's Git LFS: [smartgit.md](smartgit.md#git-lfs).
- **Attributes: committed and user ones cannot hide text, two machine-local files can.** The diff runs with
  `--attr-source` set to the empty tree, so a `.gitattributes` in the same commit (`* -diff`, `*.txt binary`) has no
  effect, and with `-c core.attributesFile=/dev/null`, so the user's attributes file (and the XDG default) has none
  either. `$GIT_DIR/info/attributes` and the system-wide gitattributes file still apply (probed on git 2.56): a `-diff`
  or `binary` rule there hides the matching files. They are local, uncommitted, machine configuration that git offers
  no per-command switch for (the system file is root-owned and could not be exercised by a test). The diff is between
  two trees, so what is scanned is always the staged blob: `working-tree-encoding` and a clean filter cannot show the
  scanner the work tree file instead.
- **Inherited git configuration cannot change the extraction.** `-c core.bigFileThreshold=100g` is pinned, because a
  lower threshold (`git -c core.bigFileThreshold=1 commit`, or the same key in the repository config) makes git treat
  every file as binary and show no added lines, so a token would commit with no output. The command-line pin wins over
  the repository config, `GIT_CONFIG_PARAMETERS` and `GIT_CONFIG_COUNT`
  (`test_real_core_big_file_threshold_cannot_make_a_token_commit_silently`). The pin is also the ceiling: a text file
  bigger than 100 GiB (4095 MiB on Windows, where Git for Windows keeps the value in 32 bits) is binary to git and is
  not scanned, whatever your own setting says. 27 other values of 25 settings (`diff.*`, `core.autocrlf`,
  `core.eol`, `core.safecrlf`, `color.*`, `core.quotePath`, encodings, ...) are swept in all three forms; none changes
  the result (`CONFIG_MATRIX` in `tests/scan/test_inherited_config.sh`).
- **Local overrides win.** A repository-local `hook.git-secret-guard.enabled=false` or a different `.command` in its
  own config replaces the global one (last value parsed wins). `--no-verify` skips the scan.
- **No verification.** Every pattern match blocks, real or not: nothing is tested against the vendor. Why: sending a
  candidate credential to a vendor's API is an intrusion on a third party, and a commit's added lines must not cause network
  traffic with the secret in it. The cost: more false positives, for example a fake token in a test fixture or a documented
  example, which a scan with verification would have dropped as `unverified`. How to accept one: list its path in a
  `.secret-scan-ignore` committed at HEAD (with a reason after `#`), or put the inline marker for that tool on the line;
  see [Exemptions](exemptions.md). An entry only staged in the same commit does not count.
- **Tool-native markers apply.** `gitleaks:allow` and `betterleaks:allow` (both are honoured by betterleaks) and
  `trufflehog:ignore` on a line mute that line for that tool; see [Exemptions](exemptions.md).
- **A lone AWS access key ID.** betterleaks 1.9.0 reports an AWS key ID (`aws-access-token`) only with the secret access
  key within 5 lines, and trufflehog needs the pair as well. A bare `AKIA...` line
  would therefore commit unnoticed, so the package ships its own rule, `aws-access-key-id` (`lib/scan/betterleaks-rule.toml`):
  the regex with the `A3T` prefix (`A3T` plus one letter or digit, or
  `AKIA`, `ASIA`, `ABIA`, `ACCA`, followed by 16 characters from `A-Z` and `2-7`), `entropy = 3`, and an allowlist for values ending in `EXAMPLE` (so AWS's documented
  example ID and an all-`A` placeholder pass; `test_real_our_aws_rule_reports_a_lone_normal_id_and_passes_the_documented_example_and_a_placeholder`).
  The hook always generates one config, the default rules plus this rule. With no `.gitleaks.toml` at HEAD that config is
  the one betterleaks run. With one, the repository's config runs exactly as written and a second betterleaks run uses the
  generated config with `--enable-rule aws-access-key-id`, so only this rule runs, under the same default skip list, with
  the same timeout, redaction and exit-code handling, the same neutralised ignore files and inline markers, and nothing
  read from the repository; its findings are printed as betterleaks findings. The verdict is the same with or without a
  repository config (`test_real_a_lone_aws_key_id_under_a_skipped_path_passes_with_and_without_a_repo_config`), and a
  repository config cannot switch the rule off (an allowlist or a config without `[extend]` does not hide a lone ID); a
  `.gitleaksignore` fingerprint or an inline marker does. A fingerprint `<path>:aws-access-token:<line>`
  also mutes a lone ID: when HEAD's `.gitleaksignore` is handed to betterleaks, every such line gets a twin
  `<path>:aws-access-key-id:<line>` (a plain data transform, bounded at 20000 lines;
  `test_real_an_aws_access_token_fingerprint_at_head_also_mutes_a_lone_key_id`). A key with its secret is reported once,
  as `aws-access-token` (the `aws-access-key-id` row on the same line is dropped).
- **Betterleaks' default config skips whole paths; trufflehog has no such list.** Read from the 1.9.0 binary
  (`betterleaks config show`, the `prefilter` expression), the global allowlist skips (regexes, unanchored unless shown): the name `gitleaks.toml`; images `bmp gif jpe?g png svg
  tiff?`; fonts `eot otf ttf woff2?`; documents and binaries `docx? xlsx? pdf bin socket vsidx v2 suo wsuo dll pdb exe
  gltf`; `go.mod go.sum go.work go.work.sum`; `vendor/modules.txt` and `vendor/` under `github.com`, `golang.org/x`,
  `google.golang.org`, `gopkg.in`, `istio.io`, `k8s.io`, `sigs.k8s.io`; `gradlew`, `gradle.lockfile`, `mvnw`,
  `.mvn/wrapper/MavenWrapperDownloader.java`; `node_modules/`, `bower_components/`; `deno.lock`,
  `npm-shrinkwrap.json`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`; bundled angular, bootstrap, jquery,
  jquery-ui, plotly and swagger-ui scripts and `javascript.json`; `Pipfile.lock`, `poetry.lock`; Python
  `env`/`venv`/`virtualenv` `lib` trees, `lib/python2|3.x` trees and `*.dist-info`; `vendor/bundle`, `vendor/ruby`,
  `*.gem`; `verification-metadata.xml`, `Database.refactorlog`; a path ending in `.git`. It also drops values that are
  placeholders such as `true`, `${VAR}` and `{{ name }}`. Verified with the real tools
  (`test_real_betterleaks_default_path_allowlist_hides_a_key_id_but_trufflehog_still_covers_its_own_kinds`): an AWS access
  key ID on its own, a kind only betterleaks detects, **passes** under `node_modules/`, `package-lock.json`, `*.svg`,
  `go.sum`, `vendor/github.com/` and `*.pdf`, and is blocked at a normal path. A GitHub token under `node_modules/` is
  still blocked, by trufflehog.
- **A commit cannot mute itself with a betterleaks config or ignore file.** `--config` and `--gitleaks-ignore-path` point at
  private files, and a root `.gitleaksignore` or `.betterleaksignore` added by the commit is scanned under another name
  (`<name>.gsg-committed`) instead of being honored (betterleaks reads both at the target root whatever
  `--gitleaks-ignore-path` says, probed on 1.9.0). A committed `.betterleaks.toml` or `.gitleaks.toml` cannot load either,
  because `--config` always names a private file. Only the versions of `.gitleaks.toml` and `.gitleaksignore` at HEAD
  count, see [Exemptions](exemptions.md).
- **Fail closed on timeout.** A scanner run lasting longer than `SCAN_TIMEOUT_SECONDS` (default 300) blocks the commit.
  The limit applies to each run, not to the whole hook: with a `.gitleaks.toml` at HEAD the betterleaks pre-flight and
  the two betterleaks runs (one after the other, next to trufflehog) each get it.

## Maintainer notes

Why the scan code is shaped this way; each point was probed on the pinned versions.

- **Tools lost on `PATH` (#31, #28).** A tool the hook takes from `PATH` can be shadowed by a no-op that exits 0. Closed: (1) the
  cross-check above (`_report_cross_check`, `<scanner>.found` written by `scan_trufflehog` and `betterleaks_collect`, no `cat`, `sort`,
  `wc`, `grep` or `awk` in it) covers `cat` and `sort` of `report_results`, a no-op `awk` of `betterleaks_drop_pair_key_rows` and any later
  tool that loses rows; (2) `bash` is named by the hook command (`hook_command_text`: check, then `exec '<bash>' '<hook>'`; git appends
  ` "$@"` after the exec, so `commit-msg` still gets the message file); (3) commit-msg `cat` (`message_scan_prepare`: a non-empty source with
  an empty copy fails) and `cmp` (`_message_matches_git`: an "equal" is confirmed by comparing `$(<a)` and `$(<b)` in bash). Open, pinned
  by `tests/scan/test_path_tool_gaps.sh`: a counts-lying `awk` (N11) and the LFS `mv` and `head` (N12; a no-op `tr` or a `wc` printing 0 block, with
  misleading reasons, and are pinned as blocks); a lying answer there has no second reading to check against, a stand-in must know the hook's own arguments, and a trusted `PATH` for every tool is out of scope.

- **The hook runs no `find`** (#25). `find` came from `PATH`, and a no-op one printed nothing and exited 0, which read as "the scan tree
  holds no file": the commit passed with `no added lines to scan` (`extract_lfs_objects` skipped the LFS swap the same way, and the
  work dir was emptied by `find -delete`). There is no `FIND_BIN` setting on purpose: an existing install keeps working after an
  auto-update without a reinstall, and `type -P find` can find Windows' `find.exe`. `lib/scan/extract.sh` has the bash-only
  replacements: `scan_tree_has_file` (`globstar dotglob nullglob` in a subshell, any depth, hidden files too), `scan_dir_clear`
  (the reminder's work dir) and `scan_tree_verdict`, the second layer: `GSG_EXTRACT_FILES`/`GSG_EXTRACT_LINES` count only files
  that got a line (exempt files and binary LFS objects leave the counts), so counts above zero with an empty tree is a broken
  extraction and blocks; only two zero counts are "nothing to scan". Pinned by `test_the_hook_runs_no_find_command` (no code
  line of the hook, `GSG_HOOK_LIBS` or `GSG_HOOK_FILES` runs `find`), `test_scan_tree_*` and
  `test_real_formats_n02_a_no_op_find_first_on_path_still_blocks_a_token`. No end-to-end path to "counts above zero, empty tree"
  was found besides a failing tool; the invariant is tested at row level.

- **trufflehog 3.99.2** exits 0 on unreadable input even with `--fail-on-scan-errors` and only logs an error-level JSON
  line: those lines are scan errors, and only their `msg` is printed (other fields can hold verifier URLs with the
  candidate). Findings exit 183. Exit 0 or 183 counts only with `{"msg":"finished scanning","chunks":N}`, `N >= 1`, so
  `/bin/true` as `TRUFFLEHOG_BIN` is an error. `tests/scan/test_real.sh` pins this and fails if a newer version changes it.
- **No verification.** trufflehog runs `--no-verification --no-update` with `--results=verified,unverified,unknown`.
  Measured on 3.99.2: with `--no-verification` every result has `Verified=false` and no `VerificationError`, and
  `--results` still filters, so the old `--results=verified,unknown` returns nothing at exit 0 (a silent pass); `unverified`
  must be listed. The scan makes no `connect`, `sendto` or `sendmsg` to a non-loopback address
  (`strace -f -e trace=connect,sendto,sendmsg`; `unshare -rn` runs it to the same result); without the flag the same scan made 2.
  betterleaks 1.9.0 validates online only behind `--validation`, which is never passed (0 connects). Second line of defence:
  `scanner_dead_proxy_env` (`lib/core/common.sh`) exports `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` and the lowercase forms as
  `http://127.0.0.1:9` and empties `NO_PROXY`/`no_proxy`, inside the subshell that starts each scanner (both betterleaks
  runs and the pre-flight probe, trufflehog), never in the hook itself; a real proxy in the user's environment never reaches
  a scanner. Tests need no proxy: `test_real_a_fake_token_blocks_with_no_proxy_variable_set_at_all`, the zero-connect proof is
  `test_real_a_hook_scan_makes_no_connect_to_a_non_loopback_address` (skips, naming why, without strace or ptrace), and
  `test_real_a_fake_credential_blocks_even_with_network_access` skips offline. `DEAD_PROXY` arrays left in other test files
  are extra isolation only.
- **betterleaks 1.9.0 exit codes and logs.** Clean is 0 and `[]`. The default leak status 1 equals the fatal status, so the
  adapter passes `--exit-code 42` (`GSG_BETTERLEAKS_LEAK_RC`). `WRN skipping ...` still exits 0 or the leak status, so it
  counts as an error. Only the message words of ERR, FTL and `WRN skipping` lines are printed, cut at the first `key=`
  word (`msg_words`); FTL lines are ANSI-coloured even with `--no-color` (`strip_ansi` before matching); more than 5000 log
  lines is an error. Pinned by `test_real_betterleaks_exit_code_semantics_1_9_0` and the other `test_real_betterleaks_*` tests.
- **betterleaks runs with cwd = the scan dir and target `.`**, so `File` and `Fingerprint` are repo-relative
  (`src/a.txt:aws-access-key-id:4`), the form `.gitleaksignore` needs; with an absolute target no ignore entry matches
  (tests use `env -C DIR ... dir .`). Root `.gitleaks.toml`/`.betterleaks.toml` load only without `--config`; `--config`
  beats them and `BETTERLEAKS_CONFIG[_TOML]`/`GITLEAKS_CONFIG[_TOML]`. `--ignore-gitleaks-allow` turns both inline markers off.
- **The lone AWS key ID.** `aws-access-token` is a composite rule (it needs an `aws-secret-access-key` within 5 lines). The
  adapter always writes `$out/betterleaks.toml` (`[extend] useDefault = true` plus `lib/scan/betterleaks-rule.toml`); 1.9.0 logs
  `Isolating rules` on the `--enable-rule` run. `betterleaks_write_ignore` adds the twins (bounded by
  `GSG_BETTERLEAKS_IGNORE_MAX_LINES`); `betterleaks_drop_pair_key_rows` drops the key-ID row of a pair. The stand-in tells
  the runs apart by `--enable-rule` (`STUB_GL_EXTRA_FINDINGS`, `STUB_GL_EXTRA_RC`).
- **The credential rules** ([Credential rules](#credential-rules)) sit after the AWS rule, before the PII rules. Before adding one,
  test the shape with both real scanners through the hook: a built-in rule or a trufflehog detector may already cover it, sometimes only
  next to a keyword, and a rule of ours on the same value can leave a low-confidence generic built-in finding out (a vendor rule's
  finding stays beside ours). Each rule's positive and negative
  cases live in `tests/scan/test_bypass_formats_real.sh`, with samples from its seeded `det_chars` (a random value can fall under an
  entropy filter now and then; a fixed one never flakes). `azure-openai-api-key-header` uses `[[rules.required]]` with `withinLines = 5`
  and the hidden `azure-openai-endpoint`, the PII context pattern below with a wider window.
- **The PII rules.** They sit after the AWS rule and the credential rules in `lib/scan/betterleaks-rule.toml`; the adapter code knows no `pii-` ID (rows
  pass through, `betterleaks_drop_pair_key_rows` drops only a key-ID row). Patterns that bite: RE2 has no lookaround, so a value is
  bounded by a class that excludes a longer run (`[^0-9\n-]`, `[^0-9A-Za-z\n]`) with `(?m)` and `\n` excluded, else a keyword or a
  number on the neighbouring line would match across the newline; the structure exclusions are alternations. The context rules use
  `[[rules.required]]` naming a hidden keyword rule (`skipReport = true`) with `withinLines = 0`, which keeps the keyword on the
  value's line. The checksums are `filter` expressions (expr-lang, true drops the finding): Luhn sums every second digit from the right,
  mod-97 folds the rearranged IBAN one character at a time (letters are two digits), so no big integer is needed. `config check`
  evaluates a filter on the dummy secret `b`, so each filter starts with a `matchesAny` shape test that drops anything not shaped like
  a card or IBAN. A filter drop never retries a shorter match, so the card filter also accepts Luhn on the first 16 digits of a longer
  match (a CVV after a card) and the IBAN filter mod-97 without its last space-separated token (a currency after an IBAN); the IBAN
  retry drops only one trailing token, so a multiple-of-4 spaced IBAN followed by two short tokens (a currency, then a number) is not
  reported (a known false negative). The closing boundary class consumes one character after a match: two values separated by a
  single character report only the first (the commit still blocks), and a longer 4-4-5-x digit run can report its first 13 digits.
  Never use the rule key `validate` (live API). A new rule needs a positive and a negative case in
  `tests/scan/test_pii_real.sh`; samples are built at run time from fragments (a literal sample would be found by these rules in the tree;
  `test_the_project_tree_holds_no_credential_looking_literals` scans with the default rules only, so scan the tree with
  `lib/scan/betterleaks-rule.toml` too, and list the hits without their values).
- **Fixtures.** A finding only a built-in rule makes is `generic_key`/`builtin_line` in `tests/scan/test_exemptions_real.sh`;
  `fake_aws_secret` is random per call. The pre-flight probe `betterleaks_probe_secret` is a bare fake GitHub token, where
  `github-pat` fires alone (a `token = "..."` line would also fire `generic-api-key`; an AWS ID is no use because of the
  composite rule and our own rule). A `..._KEY=<40 hex>` literal trips betterleaks' `generic-api-key` in `tests/project/test_quality.sh`, which scans the tree.
- **Extraction.** Added line N sits at line N, the rest blank: never count scan-tree lines. The counts come from
  `lib/scan/extract.awk` through `GSG_EXTRACT_COUNTS` (written in `END` only on success), and `exempt_extract_tree` sums both
  passes into `GSG_EXTRACT_FILES`/`GSG_EXTRACT_LINES` (`test_a_missing_or_garbage_counts_file_blocks_and_never_reports_zero`).
  The awk unquotes C-quoted names, refuses `..`, `.`, empty components and absolute paths (exit 2), and dies on a hunk
  line that is not `+ - space \` or a diff that ends early. Its stderr goes through `_extract_clean_stderr` and its status
  comes from `PIPESTATUS` (`test_an_extraction_write_failure_blocks_with_a_message_about_extraction_and_keeps_the_awk_line`).
- **The staged tree.** Every diff of the hook (`_staged_git_diff`: the extraction, the exemption second pass,
  `staged_added_file_count`, and the `--raw -z` and `--numstat -z` of the LFS code) is
  `GIT_INDEX_FILE=<work dir>/no-index git --attr-source=<empty tree> ... diff-tree -r -M <HEAD tree> <staged tree>`, where
  `staged_trees_init` ran `git write-tree` once (the tree objects `git commit` writes next; the empty tree before the
  first commit). Why not `diff --cached`: `--attr-source` hides the attributes, so git concludes that a stat-clean entry
  needs no conversion and reads the **work tree file** as the new side (`reuse_worktree_file` in git's `diff.c`).
  With `*.txt working-tree-encoding=UTF-16LE` in a committed `.gitattributes`, or a local clean filter that adds content,
  that file differs from the blob and a staged key was committed unscanned. A racy-fresh file (same second as the
  index) makes git read the blob, which hid the bug: **tests must `touch -d '2 hours ago'` their files**. No switch turns
  the reuse off (`GIT_WORK_TREE` at an empty directory, `diff-tree` with the index loaded and `-c` settings all failed);
  with no index to consult git has only the two trees. `-M` and `-r` are passed because plumbing neither detects
  renames nor recurses by default (it ignores `diff.renames`, so `diff.renames=copies` and `diff.renames=false` no longer matter; with `false` the old diff scanned a renamed and edited file
  whole, 10 lines, and now only its added lines, 1, which is git's default behaviour). A failing
  `write-tree` (an unmerged entry or a missing object) blocks with `git write-tree failed`
  (`test_real_a_commit_whose_index_cannot_be_written_as_a_tree_is_blocked`). Callers of `staged_diff` outside the hook
  call `staged_trees_init <dir>` first (`tests/scan/test_extract.sh`). Not moved: `git ls-files --cached` in
  `_warn_if_union_covers_tree` and the probe repository's `diff --cached --name-only` in `scan_ignore_scope` only read
  names, never content (doctor shares them and is unchanged). Tests: `test_real_a_key_staged_through_working_tree_encoding_is_scanned_from_the_blob`,
  `test_real_a_clean_filter_that_adds_content_cannot_hide_it_from_the_scan`.
- **Git LFS.** `extract_lfs_objects` (`lib/scan/extract.sh`) runs after `exempt_extract_tree` and starts no git process per
  file (`test_small_plain_files_cost_no_git_process_per_file` counts runs with `GIT_TRACE`): `_lfs_staged_blobs` takes the
  regular files of one `diff-tree --raw -z --no-abbrev` (the extraction's flags) that have a scan file, so exclusions
  are honoured; `_lfs_find_pointers` asks one `git cat-file --batch-check` for the sizes and one `--batch` for the blobs of
  at most 1023 bytes (`GSG_LFS_POINTER_MAX`), with NUL mapped to 0x01 by `tr` before bash reads them (3000 small plain files: 0.36 s for the whole
  step, 2 `cat-file` runs; the per-file version measured +29.7 s). Only a blob holding `oid sha256:` is parsed. The blob
  and not the scan file is read because a changed pointer shows only its changed lines there.
  `_lfs_parse_pointer` mirrors git-lfs 3.7.1's decoder, read from the tool with `git lfs pointer --check --file`: whole
  blob `TrimSpace`d (Unicode, `GSG_LFS_SPACE`), LF split, one CR dropped, empty lines skipped, lines are not trimmed, a
  space-only line is invalid; non-`ext` lines are exactly `version`, `oid`, `size` in that order, `ext-<digit>-<word
  char>` keys (any bytes after the first name character) may come anywhere before the size line with a `sha256:<64 hex>`
  value, nothing after the size line; the size is `ParseInt` (a `+`, leading zeros, `-0`, at most int64; `_lfs_parse_size`
  normalises it before the comparison). An `ext-` line sets `LFS_EXT` (the first extension name) and `extract_lfs_objects`
  blocks such a pointer before it looks for the object (`test_a_pointer_with_an_extension_line_blocks_even_when_its_object_verifies`,
  and `test_real_a_git_lfs_gzip_extension_commit_is_blocked` with a real `lfs.extension.gz.clean='gzip -nc'`); recognition
  itself is unchanged, so the table test still compares the ext fixtures with git-lfs. `git lfs ls-files` and `git lfs push`
  only consider blobs under 1024 bytes (probed: 1023 is listed and pushed, 1024, 1025 and 1036 are not; `test_only_blobs_under_1024_bytes_are_pointers`),
  while `git lfs pointer --check` reads the first 1024 bytes only, so it is the wrong oracle above 1023 and a pointer padded
  past that size passes `--check` but is neither pushed nor followed. A pure rename of an LFS file changes no pointer and
  prints exactly `no added lines to scan` (it showed 1 file, 6 lines while git read the work tree file,
  see "The staged tree" above; the test sets an old mtime). `_lfs_storage_dir` takes `git config --type=path --get lfs.storage` (any scope, last wins),
  `_lfs_fetch_object` copies the object into the work dir and checks size and SHA-256 **on the copy**, then `mv` replaces
  the pointer's scan file. Counts: the pointer's added lines come from `diff-tree --numstat -z` (`_lfs_added_lines`), so
  `GSG_EXTRACT_LINES` stays exact for renames; a binary object removes its file and one from the file count. The hook prints
  one line per failing file, naming the path (control characters mapped to `?`) and never the content. Tests:
  `tests/scan/test_lfs.sh` (hand-built pointers and objects; `test_real_*` use the real scanners and the real `git lfs` and skip
  when absent). The `lfs.storage` tests unset the global key in `begin`: the sandbox's global config is shared by the file.
  `tests/windows-skips.list` names the three tests that cannot run there (symlink, unreadable and FIFO objects).
- **Which CI runners have git-lfs.** Read on 2026-11-12 from the runner-images READMEs on `main` (image versions
  `ubuntu` 20261101.360.1, `macos-26` arm64 20261102.0473.1, `windows-2025` 20261101.318.1): all three list `Git LFS 3.8.1`.
  Verified: that listing. Assumed: that the tests find it, as `git lfs` through git's exec path on Windows and through
  `TEST_BASE_PATH` (Homebrew's `bin`) on macOS; where `git lfs version` fails the `test_real_*` LFS tests skip with a reason,
  the hand-built ones need no git-lfs and the hook itself never runs it.
- **Doctor has no LFS gap.** It reads no staged or work-tree content and scans none. Its only scanner run is the betterleaks
  config pre-flight (`doctor_repo_betterleaks` calls `betterleaks_config_preflight`): HEAD's `.gitleaks.toml` against a
  built-in probe file. None of `lib/inspect/doctor*.sh` mentions trufflehog, `staged_diff` or `extract_added_lines`; it checks
  configuration and tool paths, so a pointer cannot be mis-scanned by it.
- **Config pins.** A command-line `-c` beats repository config, `GIT_CONFIG_PARAMETERS` and `GIT_CONFIG_COUNT`.
  `tests/scan/test_inherited_config.sh` sets the keys of `CONFIG_MATRIX` in all three forms; add any new one there
  (`test_no_config_passed_with_git_dash_c_or_in_the_parameters_variable_changes_what_is_extracted`,
  `test_no_config_passed_through_the_config_count_variables_changes_what_is_extracted`,
  `test_no_repo_local_config_changes_what_is_extracted`). `GIT_DIFF_OPTS`, `GIT_EXTERNAL_DIFF` and a set of diff keys in one
  `GIT_CONFIG_PARAMETERS` are `test_other_inherited_git_settings_cannot_change_what_is_extracted` in `tests/scan/test_exemptions.sh`. `core.bigFileThreshold` is `100g`, `4095m` on Windows. `replace_head_with_permissive_commit` is the
  helper for the replace-ref tests.
- **Signals.** Scanners start as `setsid bash lib/scan/run-scanner.sh` (pid = group id) through `proc_start_runner` and stop
  through `proc_stop_group`. `cleanup` sends TERM to the group, waits, polls (bounded), sends KILL, and only then removes
  the work dir (a surviving `cp -a` could re-create files holding added lines). Adapters use `timeout --foreground`: plain
  `timeout` makes its own group, which the group kill misses. The process groups and the TERM-then-KILL sequence are Linux and macOS;
  on Git for Windows there are no groups. MSYS `exec` replaces the Windows process but keeps the MSYS pid, so a Windows pid read
  at start goes stale and `taskkill /T` stops at the gap: `proc_windows_tree` walks `/proc/*/ppid` at stop time and
  `proc_stop_group` names each current `winpid` to `taskkill /T /F` (no grace period). A survivor keeps the work dir busy, so the staged lines stay on disk
  (`test_windows_only_an_interrupted_scan_leaves_no_native_process_and_no_work_dir`). The coverage reminder starts through plain `"$BASH"` there, because the settings hold no `SETSID_BIN`. Background jobs start with SIGINT ignored, so INT tests run
  git with `env --default-signal=INT`.
- **The supervisor never blocks in `wait`.** The test `test_a_hup_right_after_ctrl_c_leaves_no_work_dir_behind` (INT to the hook's group, HUP to its pid
  right after) failed about 0.27 % of runs on bash 5.3.15 (4 in 1460): the supervisor aborted with `free(): double free detected in tcache 2` (status 134)
  and left its worker, the worker's git and the work dir behind. Backtrace: `set_pipestatus_array`, called from `set_pipestatus_from_exit`, right after the
  `wait` builtin returned. Mechanism (bash source of 5.2 and 5.3, reproduced on 5.3.15 only): while bash blocks in `wait`, its SIGINT handler
  (`wait_sigint_handler`) calls `set_exit_status(130)` in signal context, which frees the old `PIPESTATUS[0]` and allocates a new one. A HUP arriving in that
  window finds `this_shell_builtin == wait_builtin` and `waiting_for_child`, so `trap_handler` `longjmp`s out of the INT handler and leaves `PIPESTATUS[0]`
  pointing at freed memory; the next status update frees it again. It is a bash bug (heap work in a signal handler plus a `longjmp` out of it), not our trap
  texts. With a foreground child neither path exists: the handlers only set flags and the trap runs when the child returns. So `proc_supervise` polls:
  up to `GSG_PROC_SUPERVISE_MAX_TICKS` (36000, at least an hour: each tick also costs a fork and `kill -0`) times `kill -0` on the worker, then a foreground `sleep "$GSG_PROC_SUPERVISE_TICK_S"` (0.1 s);
  a trap runs within one tick, or at once when Ctrl-C also stops the `sleep`. A run pays up to one tick (0.1 s) after the worker ends before the supervisor returns, and git runs the hook twice per commit (`pre-commit`, `commit-msg`). When the worker is gone, `{ wait "$SUP_PID"; }` only reaps the job bash already
  recorded (its SIGCHLD handler reaps while it runs foreground children), so the status, 137 for a KILLed worker included, is unchanged. A missing or failing
  `sleep` ends the poll and falls through to the blocking `wait` (the old behaviour, no spin); past the cap the `wait` blocks as before. The worker's own
  `wait "$tpid"` in `run_scanners` is left alone: it only ever receives the supervisor's single TERM. The race is sub-microsecond, so no test can fail
  before the fix reliably; `test_the_supervisor_polls_with_a_foreground_sleep_never_a_blocking_wait` pins the design (a direct `sleep` child of the supervisor).
- **Supervisor and worker.** A HUP or TERM sent to the hook's own pid used to wait for the foreground git it was running: bash runs a trap
  only after its foreground child returns. Measured on bash 5.3: a plain foreground command, a `$(...)` and a pipeline all delay the trap by the
  whole run of the child, while `wait` and a `read` builtin are interrupted at once. The foreground calls are many (`write-tree`, `diff-tree`,
  `ls-tree`, `cat-file`, the pipelines into `lib/scan/extract.awk`, the `$(...)` captures of `lib/scan/extract.sh`, `lib/scan/exempt.sh` and
  `lib/core/message.sh`, the betterleaks pre-flight), so the fix is one place: `hooks/secret-scan` without `GSG_SCAN_WORKER` calls `proc_supervise`, which
  starts the worker as a unit (`proc_start_group`: `setsid` on Linux and macOS, a plain background job on Windows; the worker unsets the variable at once
  so the doctor re-check and the scanners never inherit it) and only polls it with a foreground `sleep` (the bullet above). Its HUP, INT and TERM traps exit 129, 130 and 143,
  and its EXIT trap `proc_supervise_stop` calls `proc_stop_worker`. A signal that arrives before the pid is recorded (between the `&` and the
  `printf -v`) only sets `SUP_SIGNAL`; it is acted on right after the start (`test_a_signal_before_the_worker_pid_is_recorded_still_stops_the_worker`
  holds the record with a `printf` function). On Linux and macOS the stop is `proc_stop_group` (TERM to the worker's group, so its git, awk and the
  worker itself stop, the worker's own trap runs `cleanup`, which stops the scanner groups and removes the work dir). The wait for the worker is
  a bounded poll (`proc_running`: `kill -0` plus `ps` state, because a zombie child still answers `kill -0`), then KILL and a reap, so a child that
  ignores TERM cannot block the supervisor. **The two bounds are tied.** The worker's `cleanup` sends TERM to the trufflehog, betterleaks and
  reminder groups first and then waits for all three in one shared poll (`proc_signal_group`, `proc_wait_groups`), so scanners that ignore TERM
  cost one grace period of `GSG_PROC_GRACE_TICKS` x 0.1 s (5 s), then KILL, then the `rm` (and on Windows one retry after 1 s). The supervisor's
  poll is `GSG_PROC_WORKER_GRACE_TICKS` (15 s), strictly above that sum, so it never KILLs a worker that is still removing the staged lines
  (`test_two_scanners_that_ignore_term_are_stopped_before_the_work_dir_is_removed`). **The seconds are nominal:** both bounds count ticks, and a tick
  is `sleep 0.1` plus `kill -0` and, in the scanner wait, a `ps` (5.4 s for 50 ticks on Linux, 4 ms of it `ps`; 9.6 s on the macOS CI runner). The
  supervisor's tick has no `ps`, so the ratio between the two bounds holds; the tests allow 14 s for the 5 s grace. Stopping the groups one after the other took 10 s and lost
  the work dir. Changing either constant means checking the other. On Windows, where `taskkill /F` would skip that cleanup, TERM goes to the worker first (its trap is pending
  when the child dies, so no false "git write-tree failed" line and no next child), then every descendant is taskkilled (`proc_windows_tree`), and
  `proc_stop_group` takes the whole tree, worker included, only after the same 15 s the worker is given on Linux
  (`test_stopping_a_worker_on_windows_waits_for_a_slow_cleanup_before_any_force_kill`). Without a Windows pid for the worker nothing is taskkilled (it could not be told from its
  descendants). A worker status above 128 keeps the group, so the exit trap stops what a SIGKILLed worker left running; its work dir stays, a KILL
  runs no cleanup. Every signal trap that exits, in both processes, starts with `trap '' HUP INT TERM` (the supervisor's
  traps before the start only set `SUP_SIGNAL`): a second signal (a `pkill -f` that matches both
  processes does it) must not cut the exit trap short. When two signals are pending together bash runs their traps in signal-number order, so
  either may set the status. The exit status, stdout and stderr are
  the worker's; its stdin is `/dev/null` (a background job), which the hook never reads. The worker has its own session, so a terminal's Ctrl-C
  (SIGINT to the foreground group) reaches the supervisor only, whose trap stops the worker: 16 ms measured with a slow `diff-tree`. A background
  job starts with SIGINT ignored, so the worker could not trap it anyway; nothing relies on that. A `kill -KILL` of the supervisor leaves the
  worker running, as before it left git running.
  **A "Terminated" job line may appear, on purpose.** Bash reports a foreground job killed by TERM or HUP on stderr (`Terminated   staged_diff | extract_added_lines ...`);
  it is accepted. The stop does not send SIGPIPE to the worker's children to avoid it: gawk 5.4.1 runs with SIGPIPE ignored, git dies of it
  in the middle of `diff-tree`, awk reads a cut-off diff and prints `extract: diff ended inside a hunk`, a false failure worse than the line
  (measured under a pty, 8 of 8 Ctrl-C runs). The stop is the plain group TERM (`proc_stop_group`); awk and git die together, and the group
  signal gives awk no time to read the cut. Windows has no groups and uses the taskkill path (not measured there). Tests:
  `test_{term,hup,ctrl_c}_during_real_diff_tree_output_prints_no_extraction_error` stop the hook while a real `git diff-tree` of 60 MB is in
  flight (`real_diff_begin`: ready when the work dir holds 1 MB) and assert no `extract:` line. git runs its hooks with SIGPIPE ignored and every
  process of the worker inherits that; the stderr sanitizer (`tr`) then survives a SIGPIPE and passes awk's false error on. A test run directly
  has the default action, `tr` dies and the error has no reader, so the old SIGPIPE stop passed (20 of 20 runs). `sig_start` therefore starts the hook with
  `env --ignore-signal=PIPE`, as git does; with it the old stop fails these tests. **Cost.** The supervisor sources `common.sh` and `proc.sh`, reads the settings and checks
  `SETSID_BIN` (`tool_unusable`, the check the worker makes too; skipped on Windows, which starts the worker without it), then starts the worker with `GSG_SCAN_WORKER=1` as a function-scoped assignment
  (no `env` exec). Every other library, tool probe and check stays in the worker. If a supervisor step fails the hook goes on unsupervised through
  those same checks, which block as before, so nothing passes by this path. Median of 40 direct runs with stub scanners, supervised against the
  base commit, five interleaved rounds: +16 ms (135 against 119 ms; the host alternates between two clock speeds, +10 ms in the fast rounds).
  **No timeout on the extraction git calls, on purpose.** `SCAN_TIMEOUT_SECONDS` (300) bounds the scanners and the message run's git; a bound on
  `write-tree` and `diff-tree` would block, with "nothing was scanned", a legitimate commit of a very large staged tree on a slow disk, and the
  user's way out would be `--no-verify`. Ctrl-C, HUP and TERM now stop it at once, which is what the issue needed.
  Tests: `tests/scan/test_hook_signals.sh` (HUP and TERM to the hook pid only, a slow `write-tree`, `diff-tree` and the message run's `git diff --cached`;
  INT to the group; each asserts the status, under 3 s, no process of the run, work dir gone); the slow git is a script first on `PATH`, which works
  because git run by hand does not prepend its exec-path. `test_stopping_a_worker_on_windows_*` (`tests/platform/test_windows.sh`, a fake process table)
  cover the Windows stop on any host; the real Windows run is `test_windows_only_an_interrupted_scan_leaves_no_native_process_and_no_work_dir`.
- **Pass line.** `report_pass_line` and `report_nothing_line`; tests use `assert_pass_line_only`. Finding rows print the
  scanner in an 11-character column (`betterleaks` is 11).
- **Reminder.** `run_reminder` in the hook; `report_reminder_due`, `report_reminder` and `report_reminder_failed` in
  `lib/scan/report.sh`. It runs only once `REMINDER_READY=1` (the work dir exists). The child is `rpid`/`rpgid`, killed by
  `cleanup` like the scanners; `{ wait "$rpid"; } 2>/dev/null` hides bash's own `Killed` message. The record path comes from
  `state_dir_path` and `GSG_FINDINGS_MAGIC` (`lib/core/common.sh`, shared with doctor). The `git rev-parse --local-env-vars`
  names are unset in the child; `test_the_commits_environment_does_not_reach_the_recheck_of_other_repositories` reads them
  from a `setsid` stand-in, because a fake `git` on `PATH` never runs inside a hook. Tests: `tests/scan/test_reminder.sh`.
- **Test helpers.** `write_settings` (`tests/support/lib.sh`) writes `TEST_SETSID`/`TEST_TIMEOUT` and the versions `1.2.3`/`4.5.6`.
  Lifecycle (`tests/support/lifecycle.sh`): `lc_begin` wipes the sandbox and installs `lc_systemctl_standin` (log in
  `$SANDBOX/systemctl.log`, failures from `$SANDBOX/systemctl.fail`) and `lc_brew_standin` (`brew.map`, `brew.fail`,
  `brew.failon`, `brew.nopopulate`); `gsg` runs the CLI under `env -i`; also `lc_make_fixtures`/`lc_use_fixtures`,
  `lc_path_without TOOL`, `lc_git_wrapper '<sh condition>'` and `lc_real_lookup` with `gitreal`. Doctor (`tests/support/doctor.sh`):
  `dr_begin`, `dr_repo NAME`, `doctor`. Stand-ins: betterleaks without `--report-path` is the pre-flight
  (`STUB_GL_PREFLIGHT_RC`, `STUB_GL_PREFLIGHT_ERROR`, `STUB_GL_PREFLIGHT_SLEEP`, which delays only the `dir` call); only
  real-betterleaks tests settle what a config means; `STUB_VERSION` makes `--version` answer that version (the pin, for a test
  whose machine section must be clean), and without it `--version` prints nothing. `tests/fixtures/husky/h` is husky
  9.1.7's real `h` (MIT, verbatim). `tests/coverage.sh` measures shell lines through xtrace (not `lib/scan/extract.awk`).

### The commit-msg event

Code: `lib/core/message.sh` (`message_scan_prepare`, `_message_split_cut`, `_message_matches_git`, `_message_bases`, in `GSG_HOOK_LIBS`), the `commit-msg` branch of
`hooks/secret-scan` (before `run_reminder` and `REMINDER_READY`, so a block never starts the reminder), `run_scanners`, `report_results ... message`,
`exempt_load_config_only` (HEAD's betterleaks files, announced, no `.secret-scan-ignore`). Tests: `tests/scan/test_message.sh` (stand-ins, the hook
run by hand and through git), `tests/scan/test_message_real.sh` (real scanners), `test_real_catalog_a14_a_token_in_the_commit_message_is_blocked`.
`enable_message_hook` (`tests/support/lib.sh`) adds the second event for a test; `configure_hook` keeps `pre-commit` only so the stand-in suites
do not count a second scan. Facts measured on git 2.56.0 in a scratch `HOME` and `GIT_CONFIG_GLOBAL`, with a probe command logging `$#`, `$1`,
`$PWD` and `cat -A "$1"`:

- **Several events.** `git config --global --add hook.p.event pre-commit` and `--add hook.p.event commit-msg`, one `hook.p.command`:
  `git hook list pre-commit` and `git hook list commit-msg` both print `p`. `-c hook.commit-msg.enabled=false` makes
  `git hook list commit-msg` print `event-disabled<TAB>p` and leaves `pre-commit` alone; `-c hook.p.enabled=false` prints `disabled<TAB>p` for
  both. `--replace-all hook.p.event pre-commit` drops `commit-msg`: `git hook list commit-msg` says `no hooks found` (exit 1). A plain
  `git config hook.p.event X` on two values exits 5, so `install_set_config` writes with `--replace-all` and a value pattern.
- **The argument.** `GIT_TRACE=1 git commit -m x` shows the command run as `<command> .git/COMMIT_EDITMSG`: git appends the path to the
  command line, also for the macOS form `'<bash>' '<hook>'` (hook path with a space and a quote: the hook got `$# = 1`). The
  pre-commit run shows `<command>` with no argument. A merge passes `.git/MERGE_MSG`. The path is relative to the work tree root
  (cwd of the hook) in the main work tree, and absolute (`<common>/worktrees/<name>/COMMIT_EDITMSG`, with `GIT_DIR` set) in a linked
  work tree; a commit from a subdirectory still passes `.git/COMMIT_EDITMSG`. The Windows form is the same command written with a
  mixed path (`hook_command_text`): git runs it the same way, but no Windows run was possible here, only CI.
- **Layout (before cleanup).** `-m x`, `-F f`: the file is the message, nothing else. The editor: the template (empty line, then comment
  lines: help text, `On branch`, `Changes to be committed:` with paths) with what the editor changed. `-v` with an editor: the template, then
  `<c> ------------------------ >8 ------------------------`, `<c> Do not modify or remove the line above.`,
  `<c> Everything below it will be ignored.`, then the diff from `diff --git` on, removed lines included. `-v -m x`: no diff (git writes the diff
  only into the editor template). `--cleanup=verbatim`: the template says `with '#' will be kept` and the comment lines stay in the commit.
  `--cleanup=scissors` without `-v`: the template has the cut block and status comments, no diff. `core.commentChar=';'` and
  `core.commentString=//` replace `#` in every one of those lines; `core.commentChar=auto` with a message starting with `#` picks `;`
  (so the character cannot be read from the config, `_message_split_cut` takes it from the line). The cut line text is not translated, the lines under it are.
- **Is the `-v` text equal to `git diff`?** Measured on git 2.56.0 inside a `commit-msg` probe that cut the file after the cut line and its comment
  lines and `cmp`ed the rest with `git diff --cached --no-color --no-ext-diff --no-textconv` (same repository, `GIT_INDEX_FILE` as git hands it):
  byte-identical for the initial commit, modify, add, delete, rename, binary file, mode change, CRLF content, `diff.noprefix`,
  `diff.mnemonicPrefix`, `diff.algorithm=patience|minimal`, `diff.context`, `diff.renames=false`, `diff.interHunkContext`, `diff.indentHeuristic`,
  `diff.srcPrefix`, `diff.colorMoved`, `core.abbrev`, `core.quotePath`, `diff.submodule=log`, `commit -a` and `commit <path>` (git hands the hook its
  temporary index, which `git diff --cached` follows). Not identical: **colour** (`color.ui=always` colours `git diff`, never the template, hence
  `--no-color`); **`diff.external`** (the template ignores it, `git diff` runs it, hence `--no-ext-diff`); **textconv** (the template runs it, so
  `--no-textconv` differs for a file with a driver, which is then scanned: the hook never runs a repository's textconv command);
  **`--amend`** (the base is `HEAD^`; `git diff --cached` against `HEAD` is a subset, so `HEAD^` is a second candidate; a root commit amended
  has the empty tree as base, which needs a scratch object directory because the empty tree is not an object in the repository); and **`-v -v`**
  (forces mnemonic prefixes `c/ i/ w/`, writes `# Changes to be committed:` before the staged diff and, after a line of dashes and
  `# Changes not staged for commit:`, the worktree `git diff`; only the staged part is matched by `_message_matches_git`, the work tree part
  is scanned: matching it would run `filter.<x>.clean` (a counter log showed 4 runs for one hook run) and hide text that is in no tree).
  CRLF content and files without a final newline match as they are: the carriage returns and git's `\ No newline at end of file` line
  are part of the compared bytes (`test_a_crlf_diff_below_the_cut_matches_byte_for_byte_and_is_blanked`,
  `test_a_diff_with_no_newline_at_end_of_file_matches_and_a_missing_final_newline_is_normalised`); a message file without its last newline
  is read as if it had one (awk adds it), the same lines. Tests: `test_the_scan_file_blanks_gits_own_verbose_diff_and_keeps_the_numbering`,
  `test_a_cut_block_over_text_that_is_not_gits_diff_is_scanned_whole`, `test_the_message_run_never_runs_a_clean_filter_and_scans_the_worktree_part`,
  `test_a_hanging_git_diff_is_a_mismatch_bounded_by_the_timeout` (a stand-in git whose `diff` sleeps), `test_a_root_commit_amend_diff_matches_through_the_scratch_empty_tree`,
  `test_a_diff_against_head_parent_is_hidden_on_an_ordinary_commit_because_its_removed_lines_are_in_history`,
  `test_real_a_head_parent_diff_with_an_added_token_not_in_the_staged_tree_blocks`, `test_real_a_vv_file_reused_with_dash_f_blocks_the_unstaged_token`,
  `test_real_commit_v_v_passes_a_token_only_in_the_removed_lines_of_the_staged_diff`, `test_real_commit_v_v_blocks_a_token_in_a_removed_line_of_the_worktree_diff_a_documented_false_block`,
  `test_real_amend_v_passes_a_token_removed_since_the_parent`, `test_real_a_cut_block_copied_into_a_dash_f_file_hides_nothing`.
- **Commands.** `commit-msg` ran for: `commit` (`-m`, `-F`, editor, `-v`, `--amend`), `merge` that makes a commit (also `--no-edit`, `-m`), `commit`
  after a conflicted merge and after `merge --squash`, and a `reword` of `rebase -i`. It did **not** run for `revert` (with or without
  `--no-edit`), `cherry-pick` (also `-e`), `am` (it runs `applypatch-msg` with `.git/rebase-apply/final-commit`), a plain `pick`, a `squash`
  or a `fixup` (also `-C`) of a rebase (the token committed), `tag -a`, `notes add`, nor with `--no-verify`. A bare `git revert` without a
  terminal implies `--no-edit`, so the revert limit is tested with `revert --edit`. Probed twice, with a probe config hook and with a `.git/hooks/commit-msg` script.
  `tests/scan/test_message_real.sh` pins each of them (`..._the_event`, `..._do_not_run_the_event_a_documented_limit`).
- **Decisions.** Comment lines above the cut are scanned (`test_real_a_token_in_a_comment_line_above_the_scissors_blocks`; a
  clean template adds no finding, `test_real_a_token_typed_in_the_editor_blocks_and_git_own_comment_lines_do_not`). The scan file is the
  message itself, so its line N is the message line N and no blank padding is needed. `.secret-scan-ignore` does not apply
  (`test_real_a_catch_all_exemption_at_head_does_not_exempt_the_message`). The scan file name `COMMIT_EDITMSG` is shown as `commit message`
  (`report_results`); a fingerprint of `.gitleaksignore` keeps the real name. An empty file skips the scan: trufflehog's completion check needs
  `chunks >= 1` and logs 0 for an empty tree. Argument errors and an unreadable file block with "nothing was scanned"
  (`test_a_bad_argument_list_blocks_before_any_scan`).
- **Cost.** `trufflehog filesystem` on a one-line directory 1.62 s, `betterleaks dir .` 0.05 s, the hook with stand-in scanners 0.10 s, a
  `commit-msg` run with the real tools 1.72 s; 12 commits with `pre-commit` only 1.78 s each, with both events 3.49 s each.
