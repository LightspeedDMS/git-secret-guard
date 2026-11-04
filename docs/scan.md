# The scan

`hooks/secret-scan` is the scan; the installed copy is what git runs.

## How it works

1. Git (>= 2.54) runs `hook.git-secret-guard.command` for the `pre-commit` event, from the repo root, before the
   repository's own hook. Both run even if the first fails; the commit is blocked if either fails.
2. The script reads tool locations from `settings`, an installed file next to `hooks/` and `lib/`. Missing or
   non-executable `jq`, `trufflehog`, `betterleaks`, `setsid` or `timeout`, or a relative path, blocks the commit and says
   nothing was scanned. `setsid`, `timeout`, `jq` and both scanners come from the settings file only (no environment
   override, no `PATH` lookup), so a planted `setsid` earlier on `PATH` cannot take over the scanner start. **Everything
   else the hook runs is found through `PATH`**: `bash` (the `#!/usr/bin/env bash` shebang of the hook and of
   `lib/run-scanner.sh`), `git`, `awk`, `sed`, `cp`, `rm`, `mkdir`, `mktemp`, `realpath`, `find` and the other coreutils.
   Git prepends its own exec-path to `PATH` when it runs a hook, which puts git's directory first; a `PATH` you control
   decides the rest. The shebang is not pinned to an absolute `bash`.
3. `git diff --cached` (fixed flags, `-U0`) is turned into a private scan tree under `${TMPDIR:-$HOME/.tmp}`
   (mode 700, removed on exit and on HUP/INT/TERM): each touched file at its real relative path, each **added** line
   at its real line number, every other line blank. Nothing added (empty commit, deletions only, binary only) means no
   scanner is started and the commit proceeds.
4. `trufflehog filesystem` and `betterleaks dir` run in parallel, each through `lib/run-scanner.sh` in its own session
   (`setsid`) and under a timeout. On HUP/INT/TERM the hook signals both process groups, waits for them, and only
   then removes the temp dir, so no scanner outlives the commit. Results become rows of scanner, detector, status
   (`verified`, `unknown` or `finding`), file and line. Only those are printed, never a value; log lines are reduced
   to their message words. betterleaks never validates a finding against a live API (its `--validation` flag is never
   passed), so it makes no network request. A repository with its own `.gitleaks.toml` at HEAD gets a second, small
   betterleaks run that enables only the `aws-access-key-id` rule (`--enable-rule`), see "A lone AWS access key ID" under Limits.
5. Any finding, any scanner error (unexpected exit status, timeout, unreadable report, error-level log line, skipped
   file, an oversized betterleaks log, or trufflehog exiting 0 without its `finished scanning` line with `chunks >= 1`)
   blocks with exit 1 and the hint `git commit --no-verify`.
6. A passing commit prints one line on stderr, so a clean scan can be told from a hook that never ran (a repository-local
   `hook.git-secret-guard.enabled=false`, a leftover `core.hooksPath`, a git older than 2.54 that ignores config hooks):
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
  an unusable `TMPDIR`. Those blocks name their own cause; `doctor` reports them as machine problems.
- Only PROBLEM lines doctor already cleaned are printed, never a value, secret or file content.

## The settings file

The hook reads `<share>/settings` (`<share>` = two levels above the resolved script path), written by `install`:
absolute `TRUFFLEHOG_BIN`, `BETTERLEAKS_BIN`, `JQ_BIN`, `SETSID_BIN`, `TIMEOUT_BIN`, the pinned `TRUFFLEHOG_VERSION` and
`BETTERLEAKS_VERSION` (shown on the pass line only) and `SCAN_TIMEOUT_SECONDS`. The `GITLEAKS_*` keys of the previous
build are neither written nor read (an inherited `GITLEAKS_BIN` is discarded like any other). A missing,
relative or non-executable entry blocks the commit and says nothing was scanned; an inherited environment variable of
the same name is discarded before the file is read.
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

Runtime needs bash, `setsid` (util-linux), `timeout` (coreutils), awk, `jq` and, for `install`, `curl` and `tar`. The
tests also need `/usr/local/bin/git` (>= 2.54), `shellcheck`, `pre-commit`, and the real `trufflehog` and `betterleaks`
(paths overridable with `GSG_TEST_TRUFFLEHOG`, `GSG_TEST_BETTERLEAKS`, `GSG_TEST_JQ`, `GSG_TEST_SHELLCHECK`,
`GSG_TEST_SETSID`, `GSG_TEST_TIMEOUT`).

## Limits

- **Git >= 2.54 only.** Older git (e.g. `/usr/bin/git` 2.52) ignores config hooks without any message; its commits are
  not scanned.
- **Only the `pre-commit` event.** Commits that do not fire `pre-commit` are not scanned: merge commits (they fire
  `pre-merge-commit`), `git cherry-pick`, `git rebase` and `git am`. Probed on the real install (git 2.56): a fake key
  committed on a branch with `--no-verify` reached `main` through `cherry-pick` and through `rebase` with exit 0 and no
  scan. Scan before a branch is shared; `--no-verify` there is the hole, not the replay.
- **About 2 seconds per commit.** Both scanners start on every commit that adds lines (measured 2.0 to 2.2 s per commit
  on this machine). Commits that add nothing (deletions only, empty) start no scanner.
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
  written to match what gitleaks 8.30.1's `aws-access-token` did: the regex with the `A3T` prefix (`A3T`, `AKIA`, `ASIA`,
  `ABIA` or `ACCA` plus 16 characters), `entropy = 3`, and an allowlist for values ending in `EXAMPLE` (so AWS's documented
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
- **Fail closed on timeout.** A scanner running longer than `SCAN_TIMEOUT_SECONDS` (default 300) blocks the commit.
