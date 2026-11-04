# Exemptions

False positives are recorded **in the repository**, so everyone who clones it gets the same result and every exemption
is versioned and reviewable. Three in-repo mechanisms exist, plus three local switches. All the in-repo files are read
**from HEAD**, never from the index or the work tree: a commit cannot exempt itself, and the first commit that an
exemption covers is the one after it was committed.

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
| Line format | `<glob><whitespace>#<whitespace><reason>`. A blank line or a line starting with `#` is a comment. |
| Reason is mandatory | A pattern line with no reason (no `#`, or nothing after it) **blocks the commit**, and the message names each offending line (`git-secret-guard: .secret-scan-ignore line 3: a reason is required ...`). Control characters, `..` components, an empty pattern and more than 1000 lines are rejected the same way. |
| Globs | git's `glob` pathspecs relative to the repository root. `*` does **not** cross `/`, `**` does: `*.lock` matches top-level lock files only, `**/*.lock` matches them at any depth. A plain name (`vendor`, `docs/`) excludes everything below it, but only at that path. A leading `/` or `./` is dropped. There is no `!` negation (a leading `!` is just part of the name). |
| What happens | Excluded files are given to neither trufflehog nor betterleaks. When any staged file was excluded, the commit prints `N staged file(s) excluded by .secret-scan-ignore` (a count, never names or content). |
| HEAD only | The file is read from HEAD's tree (`git ls-tree`, then `git cat-file blob`), never from the index or the work tree. With no HEAD (the first commit) or no entry there are no excludes. It must be a **regular file** (mode 100644 or 100755): a symlink (which would read as its target text), a directory, or a tree git cannot read blocks the commit. Staging a new or edited `.secret-scan-ignore` and a finding in the same commit still reports the finding. |
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
   `.secret-scan-ignore` itself left out) to scan, the commit prints
   `WARNING: the patterns in .secret-scan-ignore together exempt every tracked file`. This catches shapes no probe
   can, such as `**/*[!t]` plus `**/*t`, `**/[!a]*`, or a list of directories that covers the tree. It does not warn
   about patterns that exempt *most* of the tree.
3. **This commit**: when every staged file with added lines is excluded it prints `WARNING: every staged file with
   added lines is excluded ...; nothing else in this commit was scanned`.

Every commit prints these warnings, even one that has nothing to scan:

```
git-secret-guard: WARNING: .secret-scan-ignore line 1 (pattern '**') exempts the whole repository from scanning
```

The pattern is quoted as you wrote it (`./**` stays `./**`, not the normalized `**`), cut at 60 characters; control
characters never reach the output because such a line is rejected.

Because `*` does not cross `/` in git's glob syntax, `*` exempts **only top-level files** (the warning says so and
points at `**`) and `*/**` exempts only files below the top level; both are warned about as well.

## Inline markers: skip one line, per tool

Verified with the real trufflehog 3.99.2 and betterleaks 1.9.0
(`tests/test_exemptions_real.sh`, `tests/test_real.sh`; the dead-proxy trick in `CLAUDE.md` makes trufflehog report
`unknown` offline):

| Marker on the same line as the secret | trufflehog | betterleaks | Commit |
|---|---|---|---|
| `trufflehog:ignore` | silent | **still reports** | blocked by betterleaks |
| `gitleaks:allow` or `betterleaks:allow` | **still reports** | silent | blocked by trufflehog |
| both tools' markers, in either order, after any comment prefix (`# trufflehog:ignore gitleaks:allow`) | silent | silent | succeeds |

betterleaks honours both of its markers natively, `gitleaks:allow` (so markers written for the previous scanner keep
working) and `betterleaks:allow`. The marker must be on the **same line** as the value; a marker on the line above
mutes nothing. A secret that only one of the tools detects needs only that tool's marker.

## The repository's own betterleaks configuration

**Which names work.** Existing exemptions keep their meaning: `.gitleaks.toml` and `.gitleaksignore` at HEAD mean the
same to betterleaks as they did to gitleaks (the config format and the fingerprint format are the same). Only these two
names are read from HEAD. betterleaks has names of its own, `.betterleaks.toml` and `.betterleaksignore`, and it loads
them from the scan tree by itself; the hook never reads them from HEAD and **neutralises** them: `--config` always names
a private file (a committed `.betterleaks.toml` or `.gitleaks.toml` therefore cannot load), and a root `.gitleaksignore`
or `.betterleaksignore` in the commit is scanned under the name `<name>.gsg-committed`, so it mutes nothing. Rename a
`.betterleaks.toml` or `.betterleaksignore` to the gitleaks name to have it read. Rule ids are the same as gitleaks'
for `github-pat`, `generic-api-key` and the other rules betterleaks inherited, so those fingerprints keep matching. One
case differs: gitleaks 8.30.1 reported a **lone AWS access key ID** as `aws-access-token`, while betterleaks reports it
through git-secret-guard's own rule `aws-access-key-id` (a key with its secret is still `aws-access-token`). So when
HEAD's `.gitleaksignore` is handed to betterleaks, every `<path>:aws-access-token:<line>` line also gets a
`<path>:aws-access-key-id:<line>` twin (a data transform, no TOML parsing), and an old fingerprint mutes a lone ID exactly
as before (`test_real_an_old_aws_access_token_fingerprint_at_head_still_mutes_a_lone_key_id`). New fingerprints can use
either name; the finding names the rule that fires, which tells you the fingerprint (`<path>:<rule>:<line>`).

- `.gitleaks.toml` at HEAD is passed to betterleaks with `--config`: its custom rules fire and its allowlists apply.
- `.gitleaksignore` at HEAD is passed with `--gitleaks-ignore-path`. A fingerprint `<path>:<rule>:<line>` (for
  example `src/k.txt:generic-api-key:1`) suppresses exactly that finding and no other; the line is the line number in
  the version being committed, so edits above it shift the fingerprint.
- Versions in the index or work tree are never honored. A commit that stages its own `.gitleaks.toml` or
  `.gitleaksignore` is scanned with the HEAD versions (or the defaults), and the staged file is just scanned as text.
- Each applied file prints one line (`using .gitleaks.toml from HEAD ...`), so the exemption is never silent.
- **The `aws-access-key-id` rule is not part of your config and cannot be switched off by it.** betterleaks 1.9.0 reports
  an AWS key ID only together with its secret key, so git-secret-guard ships a rule for a lone ID (see
  [the scan](scan.md#limits)); it matches what gitleaks' `aws-access-token` matched (so AWS's documented example ID and
  other values ending in `EXAMPLE` pass, as do low-entropy placeholders). With a `.gitleaks.toml` at HEAD a second
  betterleaks run uses git-secret-guard's generated config (default rules plus this rule) with `--enable-rule`, reading
  nothing from the repository and under the same default skip list as without a config: an `allowlist`, `disabledRules` or
  a missing `[extend]` do not hide a lone ID. A `.gitleaksignore` fingerprint (`src/k.txt:aws-access-key-id:1`, or the old
  `src/k.txt:aws-access-token:1`) or an inline marker does.
- **A HEAD `.gitleaks.toml` must load on its own, which refuses every `[extend] path`.** Verified on 1.9.0: betterleaks
  resolves `extend.path` against its working directory, which here is the scan tree of added lines, not the config's
  directory. A commit could therefore stage the file a HEAD config extends and have betterleaks honor it (for example an
  allowlist that mutes everything), and a legitimate `path = "ci/base.toml"` would fail every scan. No line-based
  detector is sound against TOML (key and table names are case-insensitive, a multi-line string can hide
  a `[` line, `"path"` is the key `path`, `"extend".path`, `Extend.Path` and inline tables are all valid), so the
  hook asks betterleaks itself: before scanning it runs the real binary with the HEAD copy from an **empty working
  directory** (over a separate probe directory, see the next bullet), under the scan timeout. Any failure (a relative path cannot be opened there, a syntax error, a timeout, any
  non-zero exit) **blocks the commit** with `.gitleaks.toml at HEAD does not load on its own (betterleaks said: ...)`;
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
