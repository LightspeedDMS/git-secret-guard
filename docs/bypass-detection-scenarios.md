# git-secret-guard — Bypass & Detection Test Scenarios

Scenario catalog for validating the `LightspeedDMS/git-secret-guard` rollout: hook coverage, bypass resistance, detection/alerting, and the server-side gate.

## How to run the scenarios

**Before you start**, know what the hook does: which hook events it registers and how (`README.md`, `docs/install.md`), which scanners and rules it runs and whether it fails closed (`docs/scan.md`), and how exemptions work (`docs/exemptions.md`). Mark a scenario **N/A** if it does not apply, and add one for any behaviour this catalog misses.

**Rules:**

- Use **only fake secrets**: AWS documentation example keys, fake `glpat-` / `ghp_` tokens, and a freshly generated throwaway PEM key.
- Work only in **local sandbox repos**, plus **one throwaway GitLab project** for push tests. Never push to real repos.
- **Never request elevation.** Section E is run manually by IT in a test VM.
- Back up `~/.gitconfig` before each test and restore it afterwards.
- Log for every test: exact command, UTC timestamp, host, OS, result (Blocked / Allowed / Error), and hook output. Timestamps are needed so Security/IT can correlate alerts (Section G).

**Output:**

1. A results table: `ID | Expected | Actual | Pass/Fail | Notes`.
2. A gap list ordered by severity.

### Legend for "Expected"

| Value | Meaning |
|---|---|
| **Block** | The local hook stops it. |
| **Detect** | The bypass succeeds, but an alert should fire. |
| **Server** | The GitLab push gate stops it. |
| **Gap** | Known limitation — record it, don't count it as a failure. |

---

## A. Baseline detection (the hook works)

| ID | Scenario | Expected |
|---|---|---|
| A01 | Commit a file with an AWS access key + secret | Block |
| A02 | GitLab PAT (`glpat-…`) | Block |
| A03 | GitHub PAT or fine-grained token | Block |
| A04 | Private key (PEM, OpenSSH, PuTTY `.ppk`) | Block |
| A05 | Slack token or webhook URL | Block |
| A06 | Azure storage key, SAS token, or client secret | Block |
| A07 | DB connection string with password (JDBC, SQL Server, Postgres URI) | Block |
| A08 | JWT / bearer token | Block |
| A09 | `.env`, `application.properties`, or `appsettings.json` with secrets | Block |
| A10 | Basic-auth credentials in a URL (a user name and password written before the host name) | Block |
| A11 | Generic high-entropy password assigned to a variable | Block (verify rule exists) |
| A12 | Secret in a file staged with `git add -p` (partial staging) | Block |
| A13 | Secret in a renamed or moved file | Block |
| A14 | Secret in the commit message | Block (the `commit-msg` event, since 0.4.0) |
| A15 | Secret introduced via `git commit --amend` | Block |
| A16 | Secret in a file with CRLF endings, UTF-16 encoding, or a path with spaces/unicode | Block |
| A17 | Secret in a large file, a binary, or a Git LFS-tracked file | Record behavior |
| A18 | Secret in a Jupyter notebook or other JSON blob | Block |

## B. False positives and noise

| ID | Scenario | Expected |
|---|---|---|
| B01 | AWS docs `EXAMPLE` keys and obvious placeholders (`changeme`, `<TOKEN>`) | Allow |
| B02 | Lockfiles, hashes, UUIDs, base64-embedded images | Allow |
| B03 | Commit latency on a large change (~10k files) | Record latency |
| B04 | Normal commit with no secrets | Allow, and no alert fires |

## C. Suppression and allowlist abuse (no admin needed)

| ID | Scenario | Expected |
|---|---|---|
| C01 | Inline ignore comment (e.g. `gitleaks:allow`, `# nosec`) on a real-format secret | Detect, or apply policy decision |
| C02 | Add the secret's path/fingerprint to a repo-level allowlist or ignore file in the same commit | Detect |
| C03 | Edit a user-level scanner config or rules file, if one exists in a user-writable path | Detect |
| C04 | Set any env-var kill switch found in the code (e.g. `SKIP=`, `*_DISABLE=1`) | Detect |
| C05 | Obfuscated secret: base64-encoded, split across lines, or string-concatenated | Gap (record) |

## D. Client bypass without admin rights

| ID | Scenario | Expected |
|---|---|---|
| D01 | `git commit --no-verify` | Detect |
| D02 | `git commit -n` | Detect |
| D03 | `git -c core.hooksPath= commit` (empty value or a path with no hooks) | Detect |
| D04 | `git config --global core.hooksPath <other dir>` | Detect + remediation restores |
| D05 | `git config --local core.hooksPath <other dir>` | Detect + remediation restores |
| D06 | `GIT_CONFIG_NOSYSTEM=1 git commit` | Detect |
| D07 | `GIT_CONFIG_GLOBAL=<alt file>`, or injection via `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0` | Detect |
| D08 | `include.path` pointing to a config that overrides `hooksPath` | Detect |
| D09 | Alias: `git config --global alias.ci "commit --no-verify"` | Detect |
| D10 | Delete, empty, or replace `.git/hooks/pre-commit` (if hooks are per-repo) | Detect + remediation restores |
| D11 | Make the hook non-executable with `chmod -x` (macOS/Linux) | Detect |
| D12 | Shadow the scanner with a dummy binary earlier in the user `PATH` | Block (hook should call scanner by absolute path), else Detect |
| D13 | Scanner crashes, times out, or its rules file is removed — does the hook fail open? | Block (must fail closed) |
| D14 | Plumbing commit: `git hash-object -w` + `git commit-tree` + `git update-ref` (no hooks run) | Detect / Server |
| D15 | Secret introduced via `git merge` (only pre-merge-commit hook runs) | Block if covered, else Server |
| D16 | Secret introduced via `git cherry-pick`, `git rebase`, or `git am` (pre-commit doesn't run) | Gap → pre-push / Server |
| D17 | `git push --no-verify` (if a pre-push hook exists) | Detect / Server |
| D18 | `git worktree add`, then commit in the worktree | Block |
| D19 | Commit inside a submodule | Block |
| D20 | New repo via `git init`, or `git clone --template=<empty dir>` | Block |
| D21 | Portable Git / MinGit unzipped into the user profile (ignores managed system config) | Detect |
| D22 | GUI client with bundled git (GitHub Desktop, SourceTree embedded git) | Block / Detect (record) |
| D23 | VS Code with `git.allowNoVerifyCommit` on, using "Commit (No Verify)" | Detect |
| D24 | JetBrains IDE with "Run Git hooks" unchecked | Detect |
| D25 | libgit2- or JGit-based client (e.g. Eclipse EGit) that may not run hooks | Record → Server |

## E. Elevated bypass — MANUAL, test VM only, run by IT

Testers without admin rights must not run these. IT runs them in a dedicated test VM, through the organisation's elevation process.

| ID | Scenario | Expected |
|---|---|---|
| E01 | Elevate PowerShell through the elevation tool with a business justification; record what its log captures | Log has user, app, justification |
| E02 | Elevated: edit the system gitconfig to remove `hooksPath` | Detect (endpoint detection alert + device marked noncompliant) |
| E03 | Elevated: delete or replace the hook binary under Program Files | Detect + remediation reinstalls |
| E04 | Elevated: uninstall git-secret-guard via Apps & Features | Detect + reinstall |
| E05 | Elevated: stop/disable the device-management agent service or delete its scheduled tasks | Detect |
| E06 | Elevated: add an endpoint-protection exclusion for the hook path | Blocked by tamper protection + alert |
| E07 | Elevated: install a second git system-wide | Detect |
| E08 | Is generic PowerShell/Terminal elevation confirmed by the user alone, or approved by support? | Record |

## F. Platforms and environments

Run sections A–D on each environment where they apply.

| ID | Environment | Notes |
|---|---|---|
| F01 | Windows, standard user | Primary target |
| F02 | macOS, non-admin and admin user | Validate how configuration drift is reported |
| F03 | Ubuntu workstation | Validate how configuration drift is reported |
| F04 | Managed Windows VM and Linux VM | Confirm hook is baked into the golden image |
| F05 | WSL distro on a managed laptop (Linux git) | Expected Gap → Detect / Server |
| F06 | Dev container / Docker with git inside | Expected Gap → Server |
| F07 | Unmanaged local VM (Hyper-V, VirtualBox) | Expected Gap → Server |
| F08 | Hook running offline or behind a proxy | Fails closed? Telemetry queued and sent later? |

## G. Server side and alert validation

Requires Security and IT to confirm results from their consoles, using the UTC timestamps logged by the tester.

| ID | Scenario | Expected |
|---|---|---|
| G01 | Push a commit with a secret to the throwaway GitLab project | Server blocks (secret push protection) |
| G02 | `git push -o secret_push_protection.skip_all` | Allowed + audit event + alert to the security team |
| G03 | `[skip secret push protection]` in the commit message | Allowed + audit event + alert |
| G04 | Secret in a file >1 MiB, a binary, or the initial push that creates the repo | Missed by push protection → caught by pipeline secret detection |
| G05 | Secret in a path excluded from push protection | Pipeline detection catches it |
| G06 | Commit via GitLab Web IDE / web editor | Server blocks |
| G07 | Commit via GitLab REST API (commits endpoint) | Record whether push protection applies |
| G08 | Push to a GitHub public repo | Record coverage (still to be confirmed) |
| G09 | Heartbeat correlation: pushed commit with no matching hook scan event (from D01, D14, F05) | Bypass alert fires |
| G10 | For every **Detect** row: which detector fired (endpoint detection rule, remediation script, device compliance, heartbeat, audit event), latency, and whether the alert reached the security team | Record |
| G11 | Device marked noncompliant: is its access to GitLab blocked? | Access blocked |
| G12 | Time for remediation to restore the hook after D04, D05, D10 | Record vs. target SLA |

---

## Priority rows for the rollout decision

**D13, D14, D16, D21, F05–F07.** These show whether the hook fails closed, and how much protection actually rests on the server gate and on hook-telemetry-vs-push correlation rather than on the client hook.

---

## Automated coverage

`tests/test_bypass_catalog.sh` runs the scenarios below on every CI run (`.github/workflows/tests.yml`, Ubuntu 24.04, git from the git-core PPA, the pinned scanners). It uses the same sandbox as the rest of the suite: scratch `HOME`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_NOSYSTEM=1`. The real `~/.gitconfig` is never read or written, which is stricter than backing it up and restoring it. Run it locally with `tests/run.sh tests/test_bypass_catalog.sh`.

- **What a test asserts.** Each test asserts the hook's **current** behaviour. A Block row asserts the block. A Gap or Detect row that is a known hole asserts the hole, the way the suite pins its other documented limits. A test going red means the behaviour changed, in either direction.
- **The results table.** With `GSG_CATALOG_REPORT=<file>` set, each scenario appends one TSV row: ID, Expected, Actual (Blocked / Allowed / Error), Verdict (PASS / FAIL / PENDING-SEC / RECORDED), UTC, host, OS, git version, command and hook output. CI sets the variable, publishes the table in the job summary and uploads it as the `catalog-head` artifact. PENDING-SEC means the bypass worked; Security must confirm whether an alert fired at that UTC time (Section G).
- **Offline verification.** Fake tokens are scanned behind a dead proxy, so trufflehog reports them as `unknown` instead of dropping them as `unverified`. This matches the rest of the real-scanner suite.

| Rows | Test (in `tests/test_bypass_catalog.sh` unless named) |
|---|---|
| A02, A03, A04 (PEM, OpenSSH), A09, A12, A13, A14, A15, A16 (CRLF, path), A17 (binary, large), A18 | `test_real_catalog_a*` |
| A16 UTF-16 | `test_real.sh` (`test_real_utf16_and_nul_byte_files_commit_unscanned_a_documented_limit`) |
| B01, B02 (recorded, no assertion), B04 | `test_real_catalog_b*` |
| C01 | `test_exemptions_real.sh`: `test_real_trufflehog_ignore_mutes_trufflehog_only`, `test_real_gitleaks_allow_mutes_betterleaks_only`, `test_real_both_markers_on_one_line_let_the_commit_succeed_in_either_order` |
| C02 | `test_exemptions_real.sh`: `test_real_an_exemption_counts_only_from_the_commit_after_it_is_committed`, `test_real_a_staged_gitleaks_config_cannot_replace_the_one_at_head` |
| C04, C05 (recorded) | `test_real_catalog_c*` |
| D01–D09, D11–D16, D18–D20 | `test_real_catalog_d*` |
| N01 (replaced hook script), N02 (`find` shadowed on PATH, recorded), N05/N08 (hook config removed or overridden) | `test_real_catalog_n*` |
| N03 catch-all, N04 `.gitleaks.toml` without defaults | `test_exemptions_real.sh` (`test_real_catch_all_patterns_...`, `test_real_a_repo_config_without_use_default_runs_only_its_own_rules`) |
| N07 inherited config | `test_inherited_config.sh` |

**Not automated, and why:**

- **A01:** under the test rules only AWS documentation keys may be used, and those are allowlisted on purpose (B01).
- **A04 `.ppk`:** needs puttygen.
- **A05–A08, A10, A11:** formats outside the permitted fake-secret set.
- **B03:** latency is better measured outside CI.
- **D10, D17:** not applicable.
- **D21–D25:** need GUI tools, IDEs or other git builds.
- **E:** elevated scenarios, run by IT.
- **F:** each platform needs its own runner. F01 is partly covered by the `windows` CI job.
- **G:** needs a throwaway GitLab project and credentials; CI must never push.
