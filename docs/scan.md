# The scan

`hooks/secret-scan` is the scan; the installed copy is what git runs.

## How it works

1. Git (>= 2.54) runs `hook.git-secret-guard.command` for the `pre-commit` event, from the repo root, before the
   repository's own hook. Both run even if the first fails; the commit is blocked if either fails.
2. The script reads tool locations from `settings`, an installed file next to `hooks/` and `lib/`. Missing or
   non-executable `jq`, `trufflehog`, `betterleaks`, `setsid` or `timeout`, or a relative path, blocks the commit and says
   nothing was scanned. `setsid`, `timeout`, `jq` and both scanners come from the settings file only (no environment
   override, no `PATH` lookup), so a planted `setsid` earlier on `PATH` cannot take over the scanner start. (On Git for Windows
   `taskkill` from the settings file, `TASKKILL_BIN`, takes the place of `setsid`.) **Everything
   else the hook runs is found through `PATH`**: `bash` itself on Linux (the `#!/usr/bin/env bash` shebang of the
   hook), `git`, `awk`, `sed`, `cp`, `rm`, `mkdir`, `mktemp`, `realpath`, `find` and the other coreutils. Git prepends
   its own exec-path to `PATH` when it runs a hook, which puts git's directory first; a `PATH` you control decides the
   rest. The shebang is not pinned to an absolute `bash`. On macOS the hook command names the recorded `BASH_BIN`
   instead. Child scripts (`lib/run-scanner.sh`, the coverage re-check) run under the same bash binary as the hook
   (`$BASH`), not through a new lookup.
3. `git diff --cached` (fixed flags, `-U0`) is turned into a private scan tree under `${TMPDIR:-$HOME/.tmp}`
   (on Windows a `TMPDIR` outside your home is ignored and `~/.tmp` is used, because NTFS ignores `chmod` and only your
   profile's permissions keep the staged lines private) (mode 700, removed on exit and on HUP/INT/TERM): each touched file at its real relative path, each **added** line
   at its real line number, every other line blank. Nothing added (empty commit, deletions only, binary only) means no
   scan is started and the commit proceeds. The exemptions are loaded before that point, so a repository with a
   `.gitleaks.toml` at HEAD still gets its betterleaks pre-flight ([Exemptions](exemptions.md)), and a config that
   does not load blocks even a commit with nothing to scan.
4. `trufflehog filesystem` and `betterleaks dir` run in parallel, each through `lib/run-scanner.sh` in its own session
   (`setsid`) and under a timeout. On HUP/INT/TERM the hook signals both process groups, waits for them, and only
   then removes the temp dir, so no scanner outlives the commit. Windows has no process groups: there the hook finds every
   process below each scanner and stops them with `taskkill /T /F`, without a grace period. Results become rows of scanner, detector, status
   (`verified`, `unknown` or `finding`), file and line. Only those are printed, never a value; log lines are reduced
   to their message words. betterleaks never validates a finding against a live API (its `--validation` flag is never
   passed), so it makes no network request. A repository with its own `.gitleaks.toml` at HEAD gets a second, small
   betterleaks run that enables only the `aws-access-key-id` rule (`--enable-rule`), see "A lone AWS access key ID" under Limits.
5. Any finding, any scanner error (unexpected exit status, timeout, unreadable report, error-level log line, skipped
   file, an oversized betterleaks log, or trufflehog exiting 0 without its `finished scanning` line with `chunks >= 1`)
   blocks with exit 1 and the hint `git commit --no-verify`.
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
   paths itself (`node_modules/`, lockfiles, `go.sum`, ...), see "Betterleaks' default config skips whole paths" under Limits. Findings and every block keep their output and print no pass line. There is no switch
   to silence it: `settings` is rewritten by every install, so a hand edit would be lost.

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

The hook reads `<share>/settings` (`<share>` = two levels above the resolved script path), written by `install`:
absolute `TRUFFLEHOG_BIN`, `BETTERLEAKS_BIN`, `JQ_BIN`, `SETSID_BIN` (`TASKKILL_BIN` on Windows), `TIMEOUT_BIN`, the pinned `TRUFFLEHOG_VERSION` and
`BETTERLEAKS_VERSION` (shown on the pass line only) and `SCAN_TIMEOUT_SECONDS`. The `GITLEAKS_*` keys of the previous
build are neither written nor read (an inherited `GITLEAKS_BIN` is discarded like any other). A missing,
relative or non-executable tool path blocks the commit and says nothing was scanned. A missing `SCAN_TIMEOUT_SECONDS`
means 300; only an integer from 1 to 999999 written without a leading zero is accepted, anything else blocks (empty, a non-digit, `0`, `00`, `007`, `1000000`). GNU `timeout` reads `00` as no limit and fails open on a value of about 20 digits, so those must never reach it; `007` would mean 7 and is refused only to keep one strict form, the same as the pre-flight; missing or non-numeric versions only drop the versions from
the pass line. An inherited environment variable of the same name as any key is discarded before the file is read.
Skip once with `git commit --no-verify`; automation can disable only this hook with
`GIT_CONFIG_PARAMETERS="'hook.git-secret-guard.enabled'='false'"` (the repository's own hooks still run).

## Tests

```bash
tests/run.sh                 # all suites; PASS/FAIL/SKIPPED per test, nonzero exit on any failure
tests/run.sh tests/test_hook.sh
tests/coverage.sh            # same suites under xtrace, prints shell line coverage
```

Every suite runs in a sandbox: a scratch `HOME`, scratch `XDG_*` directories, `GIT_CONFIG_GLOBAL` and
`GIT_CONFIG_NOSYSTEM=1`, so the real `~/.gitconfig`, `~/.local` and `~/.config` are never touched. The lifecycle suites
(`test_install.sh`, `test_uninstall.sh`, `test_status.sh`, `test_tools.sh`, `test_cli.sh`, `test_lifecycle_e2e.sh`)
install from local fake tarballs through `GSG_TOOLS_BASE_URL` and `GSG_TOOLS_LOCK`;
`test_install_network.sh` downloads the real tarballs and is reported as `SKIPPED` (never as passed) when GitHub is
not reachable. The doctor suites (`test_doctor.sh`, `test_doctor_repos.sh`, `test_doctor_exempt.sh`,
`test_doctor_betterleaks.sh`, `test_doctor_info.sh`, `test_doctor_readonly.sh`) and `test_timer.sh` use the same sandbox,
with repositories under a scratch root; every lifecycle test finds a recording `systemctl` stand-in first on its `PATH`.

Runtime needs bash 4.4 or newer, `setsid` (util-linux; `taskkill` on Windows), `timeout` (coreutils), awk, `jq` and, for
`install`, `curl` and `tar`. The tests drive `GSG_TEST_GIT` (default `/usr/local/bin/git` on Linux, `/usr/bin/git` on macOS,
the one on `PATH` on Windows; it must be >= 2.54).
`shellcheck` 0.11.0, `pre-commit` and the real `trufflehog` and `betterleaks` are optional: the tests that need one skip
with a reason when it is absent. `tests/fetch-test-tools.sh` downloads the pinned scanners (SHA-256 checked) into
`~/.cache/git-secret-guard-test-tools`, where the Windows and macOS harness looks by default; on Linux point
`GSG_TEST_TRUFFLEHOG` and `GSG_TEST_BETTERLEAKS` at them. Other overrides: `GSG_TEST_JQ`, `GSG_TEST_SHELLCHECK`,
`GSG_TEST_SETSID`, `GSG_TEST_TIMEOUT`.

## Limits

- **Git >= 2.54 only.** Older git (e.g. `/usr/bin/git` 2.52) ignores config hooks without any message; its commits are
  not scanned.
- **Only the `pre-commit` event.** Commits that do not fire `pre-commit` are not scanned: a merge commit that
  `git merge` makes by itself (it fires `pre-merge-commit`), `git cherry-pick`, `git rebase` and `git am`. A merge finished
  with `git commit` (after resolving conflicts, or after `git merge --no-commit`) fires `pre-commit` and is scanned. Probed on the real install (git 2.56): a fake key
  committed on a branch with `--no-verify` reached `main` through `cherry-pick` and through `rebase` with exit 0 and no
  scan. Scan before a branch is shared; `--no-verify` there is the hole, not the replay.
- **About 2 seconds per commit.** Both scanners start on every commit that adds lines (measured 2.0 to 2.2 s per commit
  on this machine). Commits that add nothing (deletions only, empty) start no scan (only the betterleaks
  pre-flight, when there is a `.gitleaks.toml` at HEAD).
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
  renames and mode changes add no lines.
- **Attributes: committed and user ones cannot hide text, two machine-local files can.** The diff runs with
  `--attr-source` set to the empty tree, so a `.gitattributes` in the same commit (`* -diff`, `*.txt binary`) has no
  effect, and with `-c core.attributesFile=/dev/null`, so the user's attributes file (and the XDG default) has none
  either. `$GIT_DIR/info/attributes` and the system-wide gitattributes file still apply (probed on git 2.56): a `-diff`
  or `binary` rule there hides the matching files. They are local, uncommitted, machine configuration that git offers
  no per-command switch for (the system file is root-owned and could not be exercised by a test).
- **Inherited git configuration cannot change the extraction.** `-c core.bigFileThreshold=100g` is pinned, because a
  lower threshold (`git -c core.bigFileThreshold=1 commit`, or the same key in the repository config) makes git treat
  every file as binary and show no added lines, so a token would commit with no output. The command-line pin wins over
  the repository config, `GIT_CONFIG_PARAMETERS` and `GIT_CONFIG_COUNT`. 26 other settings (`diff.*`, `core.autocrlf`,
  `core.eol`, `core.safecrlf`, `color.*`, `core.quotePath`, encodings, ...) were swept in all three forms; none changes
  the result (`tests/test_inherited_config.sh`).
- **Local overrides win.** A repository-local `hook.git-secret-guard.enabled=false` or a different `.command` in its
  own config replaces the global one (last value parsed wins). `--no-verify` skips the scan.
- **Offline vs online verification.** Only `verified` and `unknown` trufflehog results block. With network access a
  fake credential that the vendor rejects is `unverified` and does not block; offline, verification fails and the same
  candidate is `unknown` and blocks.
- **Tool-native markers apply.** `gitleaks:allow` and `betterleaks:allow` (both are honoured by betterleaks) and
  `trufflehog:ignore` on a line mute that line for that tool; see [Exemptions](exemptions.md).
- **A lone AWS access key ID.** betterleaks 1.9.0 reports an AWS key ID (`aws-access-token`) only with the secret access
  key within 5 lines; gitleaks 8.30.1 flagged a lone ID, and trufflehog needs the pair as well. A bare `AKIA...` line
  would therefore commit unnoticed, so the package ships its own rule, `aws-access-key-id` (`lib/betterleaks-rule.toml`),
  written to match what gitleaks 8.30.1's `aws-access-token` did: the regex with the `A3T` prefix (`A3T` plus one letter or digit, or
  `AKIA`, `ASIA`, `ABIA`, `ACCA`, followed by 16 characters from `A-Z` and `2-7`), `entropy = 3`, and an allowlist for values ending in `EXAMPLE` (so AWS's documented
  example ID and an all-`A` placeholder pass, as before; `test_real_our_aws_rule_matches_what_gitleaks_aws_access_token_did`).
  The hook always generates one config, the default rules plus this rule. With no `.gitleaks.toml` at HEAD that config is
  the one betterleaks run. With one, the repository's config runs exactly as written and a second betterleaks run uses the
  generated config with `--enable-rule aws-access-key-id`, so only this rule runs, under the same default skip list, with
  the same timeout, redaction and exit-code handling, the same neutralised ignore files and inline markers, and nothing
  read from the repository; its findings are printed as betterleaks findings. The verdict is the same with or without a
  repository config (`test_real_a_lone_aws_key_id_under_a_skipped_path_passes_with_and_without_a_repo_config`), and a
  repository config cannot switch the rule off (an allowlist or a config without `[extend]` does not hide a lone ID); a
  `.gitleaksignore` fingerprint or an inline marker does. A fingerprint written for gitleaks, `<path>:aws-access-token:<line>`,
  keeps muting a lone ID: when HEAD's `.gitleaksignore` is handed to betterleaks, every such line gets a twin
  `<path>:aws-access-key-id:<line>` (a plain data transform, bounded at 20000 lines;
  `test_real_an_old_aws_access_token_fingerprint_at_head_still_mutes_a_lone_key_id`). A key with its secret is reported once,
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
- **A commit cannot mute itself with a betterleaks or gitleaks file.** `--config` and `--gitleaks-ignore-path` point at
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

- **trufflehog 3.99.2** exits 0 on unreadable input even with `--fail-on-scan-errors` and only logs an error-level JSON
  line: those lines are scan errors, and only their `msg` is printed (other fields can hold verifier URLs with the
  candidate). Findings exit 183. Exit 0 or 183 counts only with `{"msg":"finished scanning","chunks":N}`, `N >= 1`, so
  `/bin/true` as `TRUFFLEHOG_BIN` is an error. `tests/test_real.sh` pins this and fails if a newer version changes it.
- **Offline tests.** A fake credential the vendor rejects is `unverified` (hidden by `--results=verified,unknown`); a dead
  proxy (`HTTPS_PROXY=http://127.0.0.1:9`) makes it `unknown` deterministically, which the real-binary tests use. The one
  online test, `test_real_trufflehog_online_fake_credential_is_unverified_and_not_reported`, skips offline.
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
  adapter always writes `$out/betterleaks.toml` (`[extend] useDefault = true` plus `lib/betterleaks-rule.toml`); 1.9.0 logs
  `Isolating rules` on the `--enable-rule` run. `betterleaks_write_ignore` adds the twins (bounded by
  `GSG_BETTERLEAKS_IGNORE_MAX_LINES`); `betterleaks_drop_pair_key_rows` drops the key-ID row of a pair. The stand-in tells
  the runs apart by `--enable-rule` (`STUB_GL_EXTRA_FINDINGS`, `STUB_GL_EXTRA_RC`).
- **Fixtures.** A finding only a built-in rule makes is `generic_key`/`builtin_line` in `tests/test_exemptions_real.sh`;
  `fake_aws_secret` is random per call. The pre-flight probe `betterleaks_probe_secret` is a bare fake GitHub token, where
  `github-pat` fires alone (a `token = "..."` line would also fire `generic-api-key`; an AWS ID is no use because of the
  composite rule and our own rule).
- **Extraction.** Added line N sits at line N, the rest blank: never count scan-tree lines. The counts come from
  `lib/extract.awk` through `GSG_EXTRACT_COUNTS` (written in `END` only on success), and `exempt_extract_tree` sums both
  passes into `GSG_EXTRACT_FILES`/`GSG_EXTRACT_LINES` (`test_a_missing_or_garbage_counts_file_blocks_and_never_reports_zero`).
  The awk unquotes C-quoted names, refuses `..`, `.`, empty components and absolute paths (exit 2), and dies on a hunk
  line that is not `+ - space \` or a diff that ends early. Its stderr goes through `_extract_clean_stderr` and its status
  comes from `PIPESTATUS` (`test_an_extraction_write_failure_blocks_with_a_message_about_extraction_and_keeps_the_awk_line`).
- **Config pins.** A command-line `-c` beats repository config, `GIT_CONFIG_PARAMETERS` and `GIT_CONFIG_COUNT`.
  `tests/test_inherited_config.sh` sets its keys in all three forms; add any new one there
  (`test_other_inherited_git_settings_cannot_change_what_is_extracted`). `replace_head_with_permissive_commit` is the
  helper for the replace-ref tests.
- **Signals.** Scanners start as `setsid bash lib/run-scanner.sh` (pid = group id) through `proc_start_runner` and stop
  through `proc_stop_group`. `cleanup` sends TERM to the group, waits, polls (bounded), sends KILL, and only then removes
  the work dir (a surviving `cp -a` could re-create files holding added lines). Adapters use `timeout --foreground`: plain
  `timeout` makes its own group, which the group kill misses. The process groups and the TERM-then-KILL sequence are Linux and macOS;
  on Git for Windows there are no groups. MSYS `exec` replaces the Windows process but keeps the MSYS pid, so a Windows pid read
  at start goes stale and `taskkill /T` stops at the gap: `proc_windows_tree` walks `/proc/*/ppid` at stop time and
  `proc_stop_group` names each current `winpid` to `taskkill /T /F` (no grace period). A survivor keeps the work dir busy, so the staged lines stay on disk
  (`test_windows_only_an_interrupted_scan_leaves_no_native_process_and_no_work_dir`). The coverage reminder starts through plain `"$BASH"` there, because the settings hold no `SETSID_BIN`. Background jobs start with SIGINT ignored, so INT tests run
  git with `env --default-signal=INT`.
- **Pass line.** `report_pass_line` and `report_nothing_line`; tests use `assert_pass_line_only`. Finding rows print the
  scanner in an 11-character column (`betterleaks` is 11).
- **Reminder.** `run_reminder` in the hook; `report_reminder_due`, `report_reminder` and `report_reminder_failed` in
  `lib/report.sh`. It runs only once `REMINDER_READY=1` (the work dir exists). The child is `rpid`/`rpgid`, killed by
  `cleanup` like the scanners; `{ wait "$rpid"; } 2>/dev/null` hides bash's own `Killed` message. The record path comes from
  `state_dir_path` and `GSG_FINDINGS_MAGIC` (`lib/common.sh`, shared with doctor). The `git rev-parse --local-env-vars`
  names are unset in the child; `test_the_commits_environment_does_not_reach_the_recheck_of_other_repositories` reads them
  from a `setsid` stand-in, because a fake `git` on `PATH` never runs inside a hook. Tests: `tests/test_reminder.sh`.
- **Test helpers.** `write_settings` (`tests/lib.sh`) writes `TEST_SETSID`/`TEST_TIMEOUT` and the versions `1.2.3`/`4.5.6`.
  Lifecycle (`tests/lifecycle.sh`): `lc_begin` wipes the sandbox and installs `lc_systemctl_standin` (log in
  `$SANDBOX/systemctl.log`, failures from `$SANDBOX/systemctl.fail`) and `lc_brew_standin` (`brew.map`, `brew.fail`,
  `brew.failon`, `brew.nopopulate`); `gsg` runs the CLI under `env -i`; also `lc_make_fixtures`/`lc_use_fixtures`,
  `lc_path_without TOOL`, `lc_git_wrapper '<sh condition>'` and `lc_real_lookup` with `gitreal`. Doctor (`tests/doctor.sh`):
  `dr_begin`, `dr_repo NAME`, `doctor`. Stand-ins: betterleaks without `--report-path` is the pre-flight
  (`STUB_GL_PREFLIGHT_RC`, `STUB_GL_PREFLIGHT_ERROR`, `STUB_GL_PREFLIGHT_SLEEP`); only real-betterleaks tests settle what a
  config means; timing assertions allow one extra sleep for the `--version` probe. `tests/fixtures/husky/h` is husky
  9.1.7's real `h` (MIT, verbatim). `tests/coverage.sh` measures shell lines through xtrace (not `lib/extract.awk`).
