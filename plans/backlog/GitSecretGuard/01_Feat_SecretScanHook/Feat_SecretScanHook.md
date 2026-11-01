# Feature 01: Secret scan hook

## Objective
Every `git commit` made with git ≥ 2.54 scans the lines it adds with trufflehog and gitleaks and blocks
on any finding or scanner error. The repository's own hooks keep working unchanged, and exemptions are
recorded in the repository so that every developer gets the same result.

## Architecture
- git runs `hooks/secret-scan` through the global config hook `hook.git-secret-guard`. It runs before
  the repo's hookdir hook, and git runs both (verified on 2.56: T4/T5).
- Extraction: added lines of `git diff --cached` (ACMRT, no colour, no external diff or textconv, fixed
  prefixes, `-U0`) are written into a private temp dir, at real paths and real line numbers.
- Scanner adapters run in parallel on the temp dir and produce normalized rows. The hook combines them
  into one report.

## Dependencies
- git ≥ 2.54 on PATH; trufflehog and gitleaks at absolute paths; jq.
- Story 02 builds on story 01's extraction step (pathspec excludes).

## Stories (implementation order)
- [x] 01_Story_DualScannerPreCommitScan
- [x] 02_Story_InRepoExemptions

## Integration points
- The global git config, written by Feature 02 (in story 01 tests it is written directly).
- doctor (Feature 03) reads the same config keys.
