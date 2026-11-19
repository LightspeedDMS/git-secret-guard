# Exemptions

False positives are recorded **in the repository**, so everyone who clones it gets the same result and every exemption
is versioned and reviewable. Three in-repo mechanisms exist, plus three local switches. All the in-repo files are read
**from HEAD**, never from the index or the work tree: a commit cannot exempt itself, and the first commit that an
exemption covers is the one after it was committed. The one exception: `git commit --amend` of the commit that added an
exemption is covered by it, because HEAD already holds it (the `git commit --amend` row below).

Every message quoted on this page is printed with a leading `git-secret-guard: `, left out here unless shown.

## `.secret-scan-ignore`: skip paths

A file at the repository root, one pattern per line:

```
# comment lines and blank lines are ignored
tests/fixtures/**    # synthetic keys for the parser tests
**/*.pem             # public certificates
vendor               # third-party code
```

| Rule | Detail |
|---|---|
| Line format | `<glob><whitespace>#<reason>`: whitespace before the `#` is required (a `#` touching the glob is part of the glob), after it optional. A blank line or a line starting with `#` is a comment. |
| Reason is mandatory | A pattern line with no reason (no `#`, or nothing after it) **blocks the commit**, and the message names each offending line (`git-secret-guard: .secret-scan-ignore line 3: a reason is required, written as "pattern  # why it is safe to skip"`). A control character or a `..` component in the pattern, an empty pattern and more than 1000 lines are rejected the same way (`line N: the pattern is empty or holds a control character`, `line N: a ".." component cannot match inside the repository`, `.secret-scan-ignore has more than 1000 lines; split the exemptions or use broader patterns`); the reason text is not checked and never printed. Every rejection ends with `.secret-scan-ignore at HEAD is invalid (see above); commit blocked, nothing was scanned.` Leading and trailing white space and a CR at the end of a line are ignored. |
| Globs | git's `glob` pathspecs relative to the repository root. `*` does **not** cross `/`, `**` does: `*.lock` matches top-level lock files only, `**/*.lock` matches them at any depth. A plain name (`vendor`, `docs/`) excludes everything below it, but only at that path. A leading `/` or `./` is dropped. There is no `!` negation (a leading `!` is just part of the name). |
| What happens | Excluded files are given to neither trufflehog nor betterleaks. When any staged file with added lines was excluded, the commit prints `N staged file(s) excluded by .secret-scan-ignore` (a count, never names or content), and the pass line adds `, N files exempted` (or says `no added lines to scan (N files exempted)`, see [the scan](scan.md#how-it-works)). A file whose change adds no line (a deletion, a binary file) is not counted. |
| HEAD only | The file is read from HEAD's tree (`git ls-tree`, then `git cat-file blob`), never from the index or the work tree. With no HEAD (the first commit) or no entry there are no excludes. It must be a **regular file** (mode 100644 or 100755): a symlink (which would read as its target text), a directory, or a tree git cannot read blocks the commit (`.secret-scan-ignore at HEAD must be a regular file (a symlink or directory is refused); commit blocked, nothing was scanned.`, `cannot read .secret-scan-ignore at HEAD (git said: ...); commit blocked, nothing was scanned.`). The same rule and messages apply to `.gitleaks.toml` and `.gitleaksignore`. Staging a new or edited `.secret-scan-ignore` and a finding in the same commit still reports the finding. |
| `git commit --amend` | Documented limit: when HEAD is the commit that added the ignore file, `--amend` can add the exempted files to that same commit, because HEAD already holds the exemption. Git gives the hook no signal that tells an amend from an ordinary next commit (same environment, same repository state; probed), so there is no reliable fix inside the hook. Review is the control: the commit shows the new pattern and the exempted path together (`test_amend_can_fold_an_exemption_and_the_exempted_file_into_one_commit_a_documented_limit`). |
| Replace refs | The hook exports `GIT_NO_REPLACE_OBJECTS=1`. Without it, `git replace <HEAD commit> <another commit>` makes `git ls-tree HEAD` return that other commit's files, so a `.secret-scan-ignore` or `.gitleaks.toml` that is not in the branch history would be read as the exemption of the real HEAD (verified with the real tools: a substituted catch-all and a substituted allowlist both let a finding through before the pin). The pin covers every HEAD read and the staged diff. |
| Inherited git settings | The hook unsets `GIT_LITERAL_PATHSPECS`, `GIT_GLOB_PATHSPECS`, `GIT_NOGLOB_PATHSPECS` and `GIT_ICASE_PATHSPECS` (also set by `git --literal-pathspecs`) before any diff; in literal mode every exclude matches nothing and the commit would pass unscanned. Diff settings such as `diff.context`, `diff.noprefix`, `diff.mnemonicPrefix`, `diff.renames`, `GIT_DIFF_OPTS` and `GIT_EXTERNAL_DIFF` cannot change what is extracted either (pinned by a test). |
| The ignore file is always scanned | Even a pattern that matches `.secret-scan-ignore` itself (or a catch-all) cannot hide it: git cannot re-include a path once excluded, so the hook extracts the ignore file in a separate pass. |
| An invalid file at HEAD blocks every commit | That includes the commit that repairs it, because HEAD is what is read. Repair it with `git commit --no-verify`. |

**Catch-all patterns are allowed but loud.** Three checks, all using git's own pathspec matching instead of string
comparison:

1. **Per pattern**: a pattern containing `*`, `?` or `[` is tested against probe paths at several depths and name
   shapes, so `**`, `**/*`, `**/**`, `/**` and `./**` are all caught. A pattern with none of those characters is a
   plain path prefix and cannot be a catch-all, so it is not probed.
2. **Union of all patterns against the tracked files**: if the patterns together leave no tracked file (index,
   `.secret-scan-ignore` itself left out) to scan, the commit prints (unless a single pattern already got the "whole
   repository" warning) `WARNING: the patterns in .secret-scan-ignore together exempt every tracked file; only .secret-scan-ignore itself is
   scanned`. This catches shapes no probe can, such as `**/*[!t]` plus `**/*t`, `**/[!a]*`, or a list of directories
   that covers the tree. It does not warn about patterns that exempt *most* of the tree.
3. **This commit**: when every staged file with added lines is excluded it prints `WARNING: every staged file with
   added lines is excluded ...; nothing else in this commit was scanned`.

Every commit prints these warnings, even one that has nothing to scan:

```
git-secret-guard: WARNING: .secret-scan-ignore line 1 (pattern '**') exempts the whole repository from scanning
```

The pattern is quoted as you wrote it (`./**` stays `./**`, not the normalized `**`), cut at 60 characters; control
characters never reach the output because such a line is rejected.

Because `*` does not cross `/` in git's glob syntax, `*` exempts **only top-level files** (the warning says so and
points at `**`) and `*/**` exempts only files below the top level; both are warned about as well:
`... (pattern '*') exempts every top-level file (git's glob '*' does not cross '/'; '**' covers the whole repository) from
scanning` and `... (pattern '*/**') exempts every file below the top level from scanning`.

If git cannot run these checks the commit is blocked: `cannot build the pattern probe repository`, `cannot evaluate
.secret-scan-ignore line N with git` or `cannot list the tracked files with git`, each followed by `commit blocked,
nothing was scanned.`

## Inline markers: skip one line, per tool

Verified with the real trufflehog 3.99.2 and betterleaks 1.9.0
(`tests/scan/test_exemptions_real.sh`, `tests/scan/test_real.sh`; trufflehog runs without verification, so a fake token is a plain match, see [scan.md](scan.md#limits)):

| Marker on the same line as the secret | trufflehog | betterleaks | Commit |
|---|---|---|---|
| `trufflehog:ignore` | silent | **still reports** | blocked by betterleaks |
| `gitleaks:allow` or `betterleaks:allow` | **still reports** | silent | blocked by trufflehog |
| both tools' markers, in either order, after any comment prefix (`# trufflehog:ignore gitleaks:allow`) | silent | silent | succeeds |

betterleaks honours both of its markers natively, `gitleaks:allow` (so markers written for the previous scanner keep
working) and `betterleaks:allow`. The marker must be on the **same line** as the value; a marker on the line above
mutes nothing. A secret that only one of the tools detects needs only that tool's marker.

## Accepting a PII false positive

The PII rules (`pii-us-ssn`, `pii-us-ssn-context`, `pii-credit-card`, `pii-iban`, `pii-phone-context`, see [scan.md](scan.md#pii-rules))
are betterleaks findings, so the same two ways out apply; both are tested with a published test card number in
`tests/scan/test_pii_real.sh`:

- **A path** (a fixture file of test cards): add `<glob>  # <reason>` to `.secret-scan-ignore` and commit that file **first**. It is read
  from HEAD: while the entry is only staged, the commit still blocks; the next commit that touches the path passes.
- **One line:** put `betterleaks:allow` (or `gitleaks:allow`) on the same line. The PII rules are betterleaks-only, so trufflehog needs no marker.

No test value is allow-listed by default: a published test card number blocks until one of these is in place.

## The repository's own betterleaks configuration

**Which names work.** `.gitleaks.toml` and `.gitleaksignore` are betterleaks' own file names for its config and its
fingerprint list, and they are the two names read from HEAD. betterleaks has names of its own, `.betterleaks.toml` and `.betterleaksignore`, and it loads
them from the scan tree by itself; the hook never reads them from HEAD and **neutralises** them: `--config` always names
a private file (a committed `.betterleaks.toml` or `.gitleaks.toml` therefore cannot load), and a root `.gitleaksignore`
or `.betterleaksignore` in the commit is scanned under the name `<name>.gsg-committed`, so it mutes nothing. Rename a
`.betterleaks.toml` or `.betterleaksignore` to `.gitleaks.toml` or `.gitleaksignore` to have it read. One
case needs care: a **lone AWS access key ID** is reported through git-secret-guard's own rule `aws-access-key-id`
(a key with its secret is reported by betterleaks' `aws-access-token`). So when
HEAD's `.gitleaksignore` is handed to betterleaks, every `<path>:aws-access-token:<line>` line also gets a
`<path>:aws-access-key-id:<line>` twin (a data transform, no TOML parsing), and an `aws-access-token` fingerprint mutes a
lone ID too (`test_real_an_aws_access_token_fingerprint_at_head_also_mutes_a_lone_key_id`). Fingerprints can use
either name; the finding names the rule that fires, which tells you the fingerprint (`<path>:<rule>:<line>`).

- `.gitleaks.toml` at HEAD is passed to betterleaks with `--config`: its custom rules fire and its allowlists apply.
- `.gitleaksignore` at HEAD is passed with `--gitleaks-ignore-path`. A fingerprint `<path>:<rule>:<line>` (for
  example `src/k.txt:generic-api-key:1`) suppresses exactly that finding and no other; the line is the line number in
  the version being committed, so edits above it shift the fingerprint. One exception: a finding inside a root
  `.gitleaksignore` or `.betterleaksignore` that the commit adds is scanned under the renamed path (see above), so its
  fingerprint is `.gitleaksignore.gsg-committed:<rule>:<line>`, although the finding row prints `.gitleaksignore`.
- Versions in the index or work tree are never honored. A commit that stages its own `.gitleaks.toml` or
  `.gitleaksignore` is scanned with the HEAD versions (or the defaults), and the staged file is just scanned as text.
- Each applied file prints one line, so the exemption is never silent: `using .gitleaks.toml from HEAD (this
  repository's betterleaks rules and allowlists apply)` and `using .gitleaksignore from HEAD (its fingerprints suppress
  betterleaks findings)`. A `.gitleaksignore` of more than 20000 lines is a scanner error (`betterleaks: .gitleaksignore at
  HEAD has more than 20000 lines; nothing was scanned`) and blocks.
- The commit message is scanned with these two files too (they are announced again by that run, after the pass line), but
  `.secret-scan-ignore` does not apply to it: [the commit message](scan.md#the-commit-message).
- **The `aws-access-key-id` rule is not part of your config and cannot be switched off by it.** betterleaks 1.9.0 reports
  an AWS key ID only together with its secret key, so git-secret-guard ships a rule for a lone ID (see
  [the scan](scan.md#limits)); AWS's documented example ID and
  other values ending in `EXAMPLE` pass, as do low-entropy placeholders. With a `.gitleaks.toml` at HEAD a second
  betterleaks run uses git-secret-guard's generated config (default rules plus this rule) with `--enable-rule`, reading
  nothing from the repository and under the same default skip list as without a config: an `allowlist`, `disabledRules` or
  a missing `[extend]` do not hide a lone ID. A `.gitleaksignore` fingerprint (`src/k.txt:aws-access-key-id:1`, or
  `src/k.txt:aws-access-token:1`) or an inline marker does.
- **A HEAD `.gitleaks.toml` must load on its own, which refuses a relative `[extend] path`** (an absolute one is a
  residual, see the end of this point). Verified on 1.9.0: betterleaks
  resolves `extend.path` against its working directory, which here is the scan tree of added lines, not the config's
  directory. A commit could therefore stage the file a HEAD config extends and have betterleaks honor it (for example an
  allowlist that mutes everything), and a legitimate `path = "ci/base.toml"` would fail every scan. No line-based
  detector is sound against TOML (key and table names are case-insensitive, a multi-line string can hide
  a `[` line, `"path"` is the key `path`, `"extend".path`, `Extend.Path` and inline tables are all valid), so the
  hook asks betterleaks itself: before scanning it runs the real binary with the HEAD copy from an **empty working
  directory** (over a separate probe directory, see the next bullet), under the scan timeout. Any failure (a relative path cannot be opened there, a syntax error, a timeout, any
  exit status other than 0 or the leak status the hook asks for, 42) **blocks the commit** with `.gitleaks.toml at HEAD does not load on its own (betterleaks said: ...); a base config reached through [extend] path must be inlined; commit blocked, nothing was scanned.`
  (a timeout says `betterleaks did not finish loading .gitleaks.toml at HEAD within <n>s` instead);
  only the message words of betterleaks' first error line are shown (its colour codes are stripped first: 1.9.0 colours
  fatal lines even with `--no-color`), never its `key=value` fields. Inline the base config into
  `.gitleaks.toml`. Verified spellings: 22 (`test_real_every_spelling_of_extend_path_is_refused`).
  **Residual:** an *absolute* path to a file that exists outside the scan tree still loads, because it does not
  depend on the working directory; it is local configuration reviewed at HEAD, so it is accepted
  (`test_real_an_absolute_extend_path_to_an_existing_file_still_loads_a_documented_residual`).
- **A `.gitleaks.toml` without `[extend]` / `useDefault = true` turns betterleaks' built-in rules off.** Verified with the
  real binary: betterleaks then runs only the rules in that file, so a bare GitHub token is no longer reported, and a
  file with no rules detects nothing at all (exit 0). trufflehog is unaffected: the hook never gives it a repository
  configuration. The `aws-access-key-id` rule of git-secret-guard still runs (see above).
- **The warning is behavioural, not a reading of the TOML.** No line scan can tell whether `useDefault` is in force
  (`[Extend]` / `UseDefault`, `extend = { useDefault = true }`, `extend.useDefault = true` and `"extend".useDefault`
  all keep the defaults; the same text inside a multi-line string keeps nothing). So the pre-flight run described
  above also scans one probe file, built at run time, holding a GitHub token that only betterleaks' built-in
  `github-pat` rule detects. If betterleaks does not report it, the commit prints
  `WARNING: with .gitleaks.toml at HEAD, betterleaks does not detect its own built-in rules (e.g. GitHub tokens): either
  [extend] useDefault = true is missing, or an allowlist or disabledRules turns them off; trufflehog and the AWS access key ID rule of git-secret-guard still run`.
  The probe is one extra small file in the same betterleaks process that already checks the config (no extra process).
  It is named `gsg-probe-builtin-rule` (no extension)
  so an ordinary allowlist does not match it, but a **global allowlist that covers everything** (`paths = ['''.*''']`)
  does, and then the warning is true: the built-in rules are off for the commit. A repository rule that itself
  matches a GitHub token also counts as "detected", so such a config is not warned about. If the probe run fails, the
  commit is blocked like any other pre-flight failure. The probe value is never printed.
  The probe covers **one** built-in rule (`github-pat`). `disabledRules` naming other built-in rules (e.g.
  `disabledRules = ["generic-api-key"]`) turns those off with no warning, and trufflehog still covers its own kinds.
  Because the probe file sits under the private work directory
  (normally `~/.tmp/...`), a repository allowlist that matches that path (e.g. `\.tmp/`) can produce a false warning;
  it never hides a finding.

## Local switches

For a repository you do not control, where an in-repo file is not an option:

- `git config hook.git-secret-guard.enabled false` inside that repository disables only this hook there (the
  repository's own hooks still run). [`doctor`](doctor.md) reports every repository that does this, with
  the config file that holds the key.
- Automation can do the same for one process without touching any file:
  `GIT_CONFIG_PARAMETERS="'hook.git-secret-guard.enabled'='false'"`.
- `git commit --no-verify` skips the scan for one commit.

## Maintainer notes

- **The rows never go through a here-string**. `exempt_warn_rows` writes the parsed rows to `<probe dir>.rows` in the caller's work dir
  and reads the loop from that file: the file holds at most 1,000 lines of any length, and Git for Windows bash never returns on a here-string
  of 65,537 to 65,664 bytes ([platforms.md#maintainer-notes](platforms.md#maintainer-notes);
  `test_an_ignore_file_whose_rows_reach_64_kib_is_applied_without_hanging`).
- **HEAD reads** go through `exempt_head_blob` (`git ls-tree --full-tree HEAD -- <path>`, then `git cat-file blob`); git's
  stderr lands in `EXEMPT_GIT_ERR` and becomes `cannot read X at HEAD (git said: ...)`. `.gitleaks.toml` and `.gitleaksignore` are
  materialised as `repo-gitleaks.toml` and `repo-gitleaksignore`. A root `.gitleaksignore` or `.betterleaksignore` in the scanned tree is
  renamed `<name>.gsg-committed` (`betterleaks_stage_tree`), so a commit cannot mute itself through them. Tests: `tests/scan/test_exemptions.sh`,
  `tests/scan/test_exemptions_real.sh`.
- **Pathspecs** (git 2.56): each pattern becomes `:(exclude,top,glob)<p>`. `top` is required: without it `/x` and `../x`
  abort and `.` excludes everything. `**/` and `[` exclude nothing; malformed globs never fail. `scan_ignore_parse`
  rows are `LINE<TAB>pattern<TAB>as-written`.
- **Excludes cannot be re-included**, so with excludes `exempt_extract_tree` runs two diffs: everything but the ignore
  file with the excludes, then the ignore file alone.
- **Catch-all checks.** `_warn_if_catch_all` has `scan_ignore_probe_init` build a throwaway repository (`git init
  --template=` in the work dir) the first time a pattern holds `*`, `?` or `[`; `scan_ignore_scope` then classifies each
  such pattern with git's own `diff --cached --name-only`; the `git rev-parse
  --local-env-vars` names are unset for it (`GIT_INDEX_FILE` is set during `commit -a`). `_warn_if_union_covers_tree`
  compares `git ls-files -z --cached` counts with and without all excludes (per-pattern probes miss `src/** lib/**`).
  `exempt_warn_rows` is shared with doctor.
- **Pre-flight directories.** `betterleaks_config_preflight` runs the HEAD config with cwd = an empty
  `$work/preflight/empty` (made before the scan tree exists) on the target `$work/preflight/probe`; the timeout is an
  explicit argument, and a missing one, or one outside 1 to 999999, is refused.
- **Built-in-rules status is decided by behaviour, never by parsing TOML.** A TOML-aware awk and a regex detector were
  tried and were unsound both ways (multi-line strings; case-insensitive, dotted, inline and quoted keys); do not
  reintroduce them (`test_real_every_spelling_that_keeps_the_default_rules_prints_no_warning`,
  `test_real_a_use_default_setting_hidden_in_a_multi_line_string_still_warns`,
  `test_real_an_allowlist_that_covers_everything_also_warns_that_the_built_in_rules_are_off`).
