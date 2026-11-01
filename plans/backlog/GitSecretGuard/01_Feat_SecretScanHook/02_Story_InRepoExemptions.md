# Story: In-repo exemptions

**Feature:** 01_Feat_SecretScanHook

## Overview
As a **developer sharing a repository with others**, I want false-positive exemptions recorded in the
repository itself, **so that** everyone who clones it gets the same result, every exemption is versioned
and reviewed, and no exemption takes effect without first being committed.

**Value after this story:** a team commits `.secret-scan-ignore`, inline `trufflehog:ignore` /
`gitleaks:allow` markers, or its existing `.gitleaks.toml` / `.gitleaksignore`, and every
git-secret-guard user honours them the same way.

## Acceptance Criteria

```gherkin
Scenario: Excluded paths are not scanned, the rest is
  Given .secret-scan-ignore at HEAD contains "tests/fixtures/**   # synthetic keys for parser tests"
  When I commit a finding under tests/fixtures/ and a finding in src/
  Then only the src/ finding is reported and the commit is blocked
  And the output says how many staged files were excluded by .secret-scan-ignore

Scenario: An exemption only counts once committed (read from HEAD)
  Given .secret-scan-ignore is not at HEAD
  When I stage a new .secret-scan-ignore excluding a path AND a finding in that path, in one commit
  Then the finding is reported and the commit is blocked
  And after .secret-scan-ignore is committed on its own, the next commit of that path is not scanned

Scenario: The ignore file itself is always scanned
  Given .secret-scan-ignore contains a pattern matching itself
  When I commit a finding inside .secret-scan-ignore
  Then the finding is reported

Scenario: Every pattern needs a reason
  Given .secret-scan-ignore at HEAD has a pattern line without "# reason"
  When I commit
  Then the commit is blocked, naming the line number of the invalid entry

Scenario: Catch-all patterns are allowed but loud
  Given .secret-scan-ignore at HEAD contains "**" or "*" with a reason
  When I commit
  Then the commit proceeds and every commit prints a warning that the whole repository is exempt
  # implemented behaviour (git glob pathspecs): "**", "**/*", "**/**", "/**", "./**" exempt the whole repository and
  # the warning says so. "*" does not cross "/" in git's glob syntax, so it exempts only top-level files and "*/**"
  # only files below the top level; both still warn, but with their real scope ("every top-level file", "every file
  # below the top level") instead of claiming the whole repository. Patterns that together leave no tracked file,
  # or a commit whose every staged file is excluded, also warn.

Scenario: Native inline markers work
  Given an added line containing a fake secret and "trufflehog:ignore"
  Then trufflehog does not report it
  Given an added line containing a fake secret and "gitleaks:allow"
  Then gitleaks does not report it
  Given both markers on one line
  Then neither tool reports it and the commit succeeds
  # if a real-binary test shows a marker does not hold, the README must not claim it

Scenario: The repository's own gitleaks configuration is honoured
  Given .gitleaks.toml and/or .gitleaksignore at HEAD
  When I commit
  Then gitleaks uses that config (custom rules and allowlists apply)
  And a .gitleaksignore fingerprint "<path>:<rule>:<line>" suppresses exactly that finding
```

## Implementation Status
- [x] `.secret-scan-ignore` parser (HEAD blob, comments, mandatory reasons, catch-all detection) — `lib/exempt.sh`
- [x] Patterns applied as `:(exclude,top,glob)` pathspecs on the extraction diff; ignore file never excluded (second extraction pass)
- [x] Excluded-file count notice and catch-all warning
- [x] gitleaks adapter passes the repo's HEAD `.gitleaks.toml` / `.gitleaksignore` (materialized in the temp dir)
- [x] Tests (stand-in and real-binary), including the inline-marker verification
- [x] README section on exemptions
- [x] Review rejection 1, B1: a HEAD `.gitleaks.toml` with `[extend] path` is refused (gitleaks resolves it against the scan tree)
- [x] Review rejection 1, B2: `GIT_LITERAL_PATHSPECS` and the other pathspec variables are unset before any diff
- [x] Review rejection 1, B3: every comment in the project follows coded-comments (enforced by `test_every_comment_follows_the_coded_comments_rules`)
- [x] Review rejection 1, S1: union of all patterns checked against the tracked files; warning when every staged file is excluded
- [x] Review rejection 1, S2: `git commit --amend` documented as a limit and pinned by a test
- [x] Review rejection 1, S3: HEAD files are read with `git ls-tree`; only regular files (100644/100755) are accepted
- [x] Review rejection 1, S4: patterns without `*`, `?` or `[` are not probed (probe repo built lazily)
- [x] Review rejection 1, S5: README wording matches the code; `*` deviation recorded above
- [x] Review rejection 2, R1: the HEAD `.gitleaks.toml` is loaded by the real gitleaks from an empty directory before scanning (replaces the unsound regex detector); 22 spellings tested with the real binary; absolute-path residual documented
- [x] Review rejection 2, R2: `core.bigFileThreshold` and `core.attributesFile` pinned; 28-setting matrix in three config forms (`tests/test_inherited_config.sh`); unpinnable local files documented
- [x] Review round 3 follow-up F1: `GIT_NO_REPLACE_OBJECTS=1` in the hook (replace refs cannot substitute HEAD's exemption files)
- [x] Review round 3 follow-up F2: gitleaks colour codes stripped before log matching (pre-flight message and adapter errors show the message words)
- [x] Review round 3 follow-up F3: the pre-flight timeout is an explicit required argument, fail closed when missing
- [x] Review rejection 2, R3: `why` needs `, not <alternative>`; comment lint rewritten (tag vocabulary, quote-aware trailing comments, heredocs) with fixture tests for every planted violation
- [x] E2E bug 1: the "built-in rules are off" warning no longer reads TOML lines (a `useDefault` text inside a multi-line string was missed; `[Extend]`/`UseDefault`, `[EXTEND]`/`usedefault`, inline-table, dotted and quoted-dotted spellings warned falsely). The pre-flight gitleaks run now also scans a probe file holding a run-time-built AWS key ID; not reported means the behavioural warning. `gitleaks_config_extends_default` removed; `gitleaks_config_loads_alone` became `gitleaks_config_preflight`. Cost: no extra process; pre-flight 45.7 to 47.0 ms with the probe vs 47.2 to 48.8 ms without (3 rounds of 40 calls), no measurable cost.
- [x] E2E cosmetic (a): the catch-all warning quotes the pattern as written (`./**`, `/**`), cut at 60 characters (`scan_ignore_parse` prints a third column)
- [x] E2E cosmetic (b): `.secret-scan-ignore line N: ...` complaints carry the `git-secret-guard:` prefix

## Technical Requirements (pseudocode only)
```
ignore = git show HEAD:.secret-scan-ignore (absent → no excludes)
for each non-blank, non-comment line:
  split pattern / "# reason";  reason empty → block("line N: reason required")
  pattern in {"*", "**"} → catch_all = true
  add ":(exclude,glob)<pattern>" to pathspecs
always scan the ignore file in its own second extraction pass (a pathspec exclude cannot be re-included)
(implemented pathspec form: ":(exclude,top,glob)<pattern>"; "top" keeps "/x" and "../x" from aborting git)
excluded_count = staged added files matching excludes → print notice when > 0
gitleaks: if HEAD has .gitleaks.toml → --config <temp copy>; .gitleaksignore → --gitleaks-ignore-path <temp copy>
```
- Real paths and real line numbers in the temp dir (story 01) are what make `.gitleaksignore`
  fingerprints match without any translation.

## Testing Requirements
- Every scenario has an automated test. Inline markers and gitleaks config are tested with the real
  gitleaks 8.30.1 and trufflehog 3.99.2, using fake values built at runtime.

## Definition of Done
- All scenarios pass, code-reviewer approves, manual-test-executor verifies, and the README documents the
  file format, the HEAD rule, the markers and the limits.
