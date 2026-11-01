# Story: Dual-scanner pre-commit scan

**Feature:** 01_Feat_SecretScanHook

## Overview
As a **developer on this machine**, I want every commit's added lines scanned by trufflehog and gitleaks
before the commit is created, with my repository's own hooks still running, **so that** a secret never
lands in history unnoticed, whatever hook tooling a repository uses.

**Value after this story:** with `hook.git-secret-guard.{event,command}` pointing at `hooks/secret-scan`,
every commit in every repo is scanned by both tools, including husky, pre-commit-framework and
custom-hooksPath repos.

## Acceptance Criteria

```gherkin
Scenario: Clean commit passes quietly
  Given a repository with the git-secret-guard config hook
  When I commit a change whose added lines contain no secret
  Then the commit succeeds
  And the scan prints nothing on success

Scenario: A finding from either scanner blocks without revealing the value
  Given trufflehog OR gitleaks reports a finding (verified or unknown) in an added line
  When I commit
  Then the commit is blocked with exit status 1
  And the output names scanner, detector, status, file path and line number
  And the secret value never appears in stdout or stderr
  And the output tells me how to bypass once with git commit --no-verify

Scenario: Scanner errors block
  Given a scanner exits with an unexpected status, or trufflehog writes an error-level log line while exiting 0
  When I commit
  Then the commit is blocked and the error is shown (only log "msg" fields, never structured fields)

Scenario: Missing prerequisites block loudly
  Given trufflehog, gitleaks or jq is missing or not executable
  When I commit
  Then the commit is blocked with a message naming the missing tool and saying nothing was scanned

Scenario: Nothing added means no scanner starts
  Given the staged diff is empty or contains only deletions
  When I commit (e.g. --allow-empty, or deleting a file)
  Then neither trufflehog nor gitleaks is started
  And the commit succeeds

Scenario: Binary files are not scanned
  Given a staged binary file
  When I commit
  Then the binary content is not passed to the scanners (documented limit)

Scenario: Bypass and automation exemption
  Given a commit containing a finding
  When I run git commit --no-verify
  Then the scan does not run and the commit succeeds
  When instead the process has GIT_CONFIG_PARAMETERS="'hook.git-secret-guard.enabled'='false'"
  Then the scan does not run and the repo's own hooks still run

Scenario: Missing scan script fails closed
  Given hook.git-secret-guard.command points at a path that does not exist
  When I commit
  Then the commit fails with an error (it never silently passes)

Scenario: Repository hooks keep working with their exit codes
  Given repo hooks pre-commit, prepare-commit-msg, commit-msg, post-commit, post-checkout, post-merge,
        pre-push and reference-transaction in .git/hooks
  When I exercise each event
  Then each repo hook runs with the arguments and stdin git gives it
  And a failing blocking hook still blocks
  And the scan runs before the repo's pre-commit hook

Scenario: Server-side hooks of a local remote still run on push
  Given a local bare remote with pre-receive, update and post-receive hooks
  When I push to it
  Then a rejecting pre-receive or update blocks the push and post-receive runs on success

Scenario: Husky-style repository is covered
  Given a repo with local core.hooksPath=.husky/_ using husky 9.1.7's real "h" layout and .husky/pre-commit
  When I commit a finding
  Then the scan blocks the commit
  And on a clean commit both the scan and the husky hook run

Scenario: pre-commit framework repository keeps its checks
  Given a repo with .pre-commit-config.yaml and no global core.hooksPath
  When I run pre-commit install and then commit
  Then pre-commit install succeeds and both its checks and the scan run

Scenario: Service environment is scanned (cidx-server, decision B)
  Given cidx-server's environment (its user, PATH and HOME from systemctl show)
  When a commit runs in that environment
  Then both scanners are reached and the result is decided by findings, not by environment errors
```

## Implementation Status
- [x] Added-line extraction at real paths and real line numbers (port of the current awk parser)
- [x] trufflehog adapter (`--results=verified,unknown --fail --no-update --json`, error-log detection)
- [x] gitleaks adapter (`dir` mode, `--redact`, JSON report, exit-code interpretation)
- [x] Parallel run, report merge, block decision
- [x] Prerequisite checks, private temp dir with trap cleanup
- [x] Tests: stand-ins for both tools, real-binary smoke tests, coexistence suites
- [x] shellcheck clean
- [x] Review round 1 (B1) committed `.gitattributes` cannot hide added text (`--attr-source` = empty tree); local attribute files documented
- [x] Review round 1 (B2) trufflehog must report a completed scan (`finished scanning`, `chunks >= 1`) or the commit is blocked
- [x] Review round 1 (B3) TERM/INT stop both scanner process groups before the temp dir is removed
- [x] Review round 1 (non-blocking) gitleaks log lines msg-only and capped, awk strictness, EXIT trap before `mktemp`, coded comments, gitleaks default allowlist documented and tested

## Technical Requirements (pseudocode only)
```
secret-scan:
  require jq, TRUFFLEHOG_BIN, GITLEAKS_BIN executable      else block("missing <tool>")
  work = private temp dir (umask 077, chmod 700); trap remove on EXIT/HUP/INT/TERM
  extract added lines of staged diff → work/scan/<real path>, line N at position N
  if no file written → exit 0
  start trufflehog adapter & gitleaks adapter in background; wait for both (bounded by their own timeouts)
  rows = union of normalized rows;  errors = union of adapter errors
  if errors → print errors; block
  if rows   → print rows (never values); block
  exit 0
```
- Tool paths are absolute (written at install time; tests inject stand-ins through the same setting).
- Only these fields are taken from tool JSON: detector/rule name, verified flag, file, line.
- trufflehog: rc 183 means findings; any other nonzero rc is an error; an error-level log line is an error (lesson 3).
- gitleaks: findings come from the JSON report; the meaning of each exit code is verified against 8.30.1 in tests.

## Testing Requirements
- Sandboxed: scratch HOME, `GIT_CONFIG_GLOBAL` pointing at a scratch file, `GIT_CONFIG_NOSYSTEM=1`,
  `/usr/local/bin/git` used explicitly, sandbox removed at the end.
- Stand-ins for both tools on PATH emit synthetic records chosen by environment variable. A unique marker
  string is asserted absent from all output.
- Real-binary smoke tests: clean diff passes with both tools. gitleaks catches a runtime-built fake key,
  shown redacted. The lesson 3 behaviour is re-checked with the pinned trufflehog. Network-dependent
  cases are reported as SKIPPED, never as passed.

## Performance Requirements
- An empty or deletion-only diff starts no scanner.
- Wall time ≈ max(trufflehog, gitleaks), not the sum.

## Definition of Done
- All scenarios pass in the automated suite, code-reviewer approves, and manual-test-executor verifies
  end to end with evidence. shellcheck is clean, and no secret value appears in any captured output.
