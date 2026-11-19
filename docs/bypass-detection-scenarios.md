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
| **Allow** | The commit must pass (a clean change). |
| **Record** | Record the behaviour, never counted as a failure. |
| **FailClosed** | The hook stops it before scanning (`nothing was scanned`). |

### Legend for "Who covers it"

Each row also says who is responsible for it. **Hook**: git-secret-guard stops it (or, for an Allow row, passes it) and an automated test pins that. **Hook gap**: a known hole the hook cannot close, pinned by a test or stated as a limit in [scan.md](scan.md#limits) or this catalog; the organisation's server-side scan or alerting must catch it. **Org**: entirely the organisation's job (endpoint protection, device management, the server-side gate, IT procedures). **Record**: a question to answer or a fact to log, not a control. **Undecided**: no test or document settles it yet. **N/A**: the scenario does not apply to this hook. A row with several parts names each. Most tests behind these values are listed in [Automated coverage](#automated-coverage); A01, A11, B01 and F08 also rest on `tests/scan/test_real.sh` and `tests/scan/test_exemptions_real.sh`, D22 on [platform-testing.md](platform-testing.md#github-desktops-bundled-git), F01–F03 on the `windows`, `windows-suite`, `macos-suite` and `suite` CI jobs, and F05 on `tests/platform/wsl-ci.sh`.

---

## A. Baseline detection (the hook works)

| ID | Scenario | Expected | Who covers it |
|---|---|---|---|
| A01 | Commit a file with an AWS access key + secret | Block | Hook |
| A02 | GitLab PAT (`glpat-…`) | Block | Hook |
| A03 | GitHub PAT or fine-grained token | Block | Hook |
| A04 | Private key (PEM, OpenSSH, PuTTY `.ppk`) | Block | Hook (PEM, OpenSSH); Undecided (`.ppk`) |
| A05 | Slack token or webhook URL | Block | Undecided |
| A06 | Azure storage key, SAS token, or client secret | Block | Undecided |
| A07 | DB connection string with password (JDBC, SQL Server, Postgres URI) | Block | Undecided |
| A08 | JWT / bearer token | Block | Undecided |
| A09 | `.env`, `application.properties`, or `appsettings.json` with secrets | Block | Hook (`.env`, `appsettings.json`); Undecided (`application.properties`) |
| A10 | Basic-auth credentials in a URL (a user name and password written before the host name) | Block | Undecided |
| A11 | Generic high-entropy password assigned to a variable | Block (verify rule exists) | Hook (`api_key = "<random>"`); Undecided (other variable names) |
| A12 | Secret in a file staged with `git add -p` (partial staging) | Block | Hook |
| A13 | Secret in a renamed or moved file | Block | Hook (token added); Hook gap (pure rename) |
| A14 | Secret in the commit message | Block (the `commit-msg` event) | Hook |
| A15 | Secret introduced via `git commit --amend` | Block | Hook |
| A16 | Secret in a file with CRLF endings, UTF-16 encoding, or a path with spaces/unicode | Block | Hook (CRLF, path); Hook gap (UTF-16) |
| A17 | Secret in a large file, a binary, or a Git LFS-tracked file | Record behavior | Hook (large text, LFS object); Hook gap (binary) |
| A18 | Secret in a Jupyter notebook or other JSON blob | Block | Hook |

## B. False positives and noise

| ID | Scenario | Expected | Who covers it |
|---|---|---|---|
| B01 | AWS docs `EXAMPLE` keys and obvious placeholders (`changeme`, `<TOKEN>`) | Allow | Hook (betterleaks passes a lone `EXAMPLE` key ID and an all-`A` placeholder); Record (the whole commit, the rest) |
| B02 | Lockfiles, hashes, UUIDs, base64-embedded images | Allow | Undecided |
| B03 | Commit latency on a large change (~10k files) | Record latency | Record |
| B04 | Normal commit with no secrets | Allow, and no alert fires | Hook |

## C. Suppression and allowlist abuse (no admin needed)

| ID | Scenario | Expected | Who covers it |
|---|---|---|---|
| C01 | Inline ignore comment (e.g. `gitleaks:allow`, `# nosec`) on a real-format secret | Detect, or apply policy decision | Hook gap |
| C02 | Add the secret's path/fingerprint to a repo-level allowlist or ignore file in the same commit | Detect | Hook |
| C03 | Edit a user-level scanner config or rules file, if one exists in a user-writable path | Detect | Hook (shipped rule file removed); Undecided (rule file or settings edited) |
| C04 | Set any env-var kill switch found in the code (e.g. `SKIP=`, `*_DISABLE=1`) | Detect | Hook gap |
| C05 | Obfuscated secret: base64-encoded, split across lines, or string-concatenated | Gap (record) | Hook gap |

## D. Client bypass without admin rights

| ID | Scenario | Expected | Who covers it |
|---|---|---|---|
| D01 | `git commit --no-verify` | Detect | Hook gap |
| D02 | `git commit -n` | Detect | Hook gap |
| D03 | `git -c core.hooksPath= commit` (empty value or a path with no hooks) | Detect | Hook |
| D04 | `git config --global core.hooksPath <other dir>` | Detect + remediation restores | Hook |
| D05 | `git config --local core.hooksPath <other dir>` | Detect + remediation restores | Hook |
| D06 | `GIT_CONFIG_NOSYSTEM=1 git commit` | Detect | Hook |
| D07 | `GIT_CONFIG_GLOBAL=<alt file>`, or injection via `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` / `GIT_CONFIG_VALUE_0` | Detect | Hook gap |
| D08 | `include.path` pointing to a config that overrides `hooksPath` | Detect | Hook (`hooksPath`); Hook gap (an include that disables the hook) |
| D09 | Alias: `git config --global alias.ci "commit --no-verify"` | Detect | Hook gap |
| D10 | Delete, empty, or replace `.git/hooks/pre-commit` (if hooks are per-repo) | Detect + remediation restores | N/A |
| D11 | Make the hook non-executable with `chmod -x` (macOS/Linux) | Detect | Hook |
| D12 | Shadow the scanner with a dummy binary earlier in the user `PATH` | Block (hook should call scanner by absolute path), else Detect | Hook |
| D13 | Scanner crashes, times out, or its rules file is removed — does the hook fail open? | Block (must fail closed) | Hook |
| D14 | Plumbing commit: `git hash-object -w` + `git commit-tree` + `git update-ref` (no hooks run) | Detect / Server | Hook gap |
| D15 | Secret introduced via `git merge` (only pre-merge-commit hook runs) | Block if covered, else Server | Hook gap (merge commit); Hook (conflict finished with `git commit`) |
| D16 | Secret introduced via `git cherry-pick`, `git rebase`, or `git am` (pre-commit doesn't run) | Gap → pre-push / Server | Hook gap |
| D17 | `git push --no-verify` (if a pre-push hook exists) | Detect / Server | N/A; Org (server gate) |
| D18 | `git worktree add`, then commit in the worktree | Block | Hook |
| D19 | Commit inside a submodule | Block | Hook |
| D20 | New repo via `git init`, or `git clone --template=<empty dir>` | Block | Hook |
| D21 | Portable Git / MinGit unzipped into the user profile (ignores managed system config) | Detect | Hook gap (a git older than 2.54); Undecided (2.54 or newer) |
| D22 | GUI client with bundled git (GitHub Desktop, SourceTree embedded git) | Block / Detect (record) | Hook gap (a bundled git older than 2.54, e.g. GitHub Desktop's); Undecided (the rest) |
| D23 | VS Code with `git.allowNoVerifyCommit` on, using "Commit (No Verify)" | Detect | Hook gap |
| D24 | JetBrains IDE with "Run Git hooks" unchecked | Detect | Undecided |
| D25 | libgit2- or JGit-based client (e.g. Eclipse EGit) that may not run hooks | Record → Server | Record |

## E. Elevated bypass — MANUAL, test VM only, run by IT

Testers without admin rights must not run these. IT runs them in a dedicated test VM, through the organisation's elevation process.

| ID | Scenario | Expected | Who covers it |
|---|---|---|---|
| E01 | Elevate PowerShell through the elevation tool with a business justification; record what its log captures | Log has user, app, justification | Org |
| E02 | Elevated: edit the system gitconfig to remove `hooksPath` | Detect (endpoint detection alert + device marked noncompliant) | Org |
| E03 | Elevated: delete or replace the hook binary under Program Files | Detect + remediation reinstalls | Org |
| E04 | Elevated: uninstall git-secret-guard via Apps & Features | Detect + reinstall | Org |
| E05 | Elevated: stop/disable the device-management agent service or delete its scheduled tasks | Detect | Org |
| E06 | Elevated: add an endpoint-protection exclusion for the hook path | Blocked by tamper protection + alert | Org |
| E07 | Elevated: install a second git system-wide | Detect | Org |
| E08 | Is generic PowerShell/Terminal elevation confirmed by the user alone, or approved by support? | Record | Record |

## F. Platforms and environments

Run sections A–D on each environment where they apply.

| ID | Environment | Notes | Who covers it |
|---|---|---|---|
| F01 | Windows, standard user | Primary target | Hook (elevated CI runner); Undecided (standard user) |
| F02 | macOS, non-admin and admin user | Validate how configuration drift is reported | Hook (CI runner account); Undecided (non-admin user); Org (drift reporting) |
| F03 | Ubuntu workstation | Validate how configuration drift is reported | Hook; Org (drift reporting) |
| F04 | Managed Windows VM and Linux VM | Confirm hook is baked into the golden image | Org |
| F05 | WSL distro on a managed laptop (Linux git) | Expected Gap → Detect / Server | Hook (installed in the distribution); Hook gap (a distribution without it) |
| F06 | Dev container / Docker with git inside | Expected Gap → Server | Hook gap |
| F07 | Unmanaged local VM (Hyper-V, VirtualBox) | Expected Gap → Server | Hook gap |
| F08 | Hook running offline or behind a proxy | Fails closed? Telemetry queued and sent later? | Hook (scan needs no network); Org (telemetry) |

## G. Server side and alert validation

Requires Security and IT to confirm results from their consoles, using the UTC timestamps logged by the tester.

| ID | Scenario | Expected | Who covers it |
|---|---|---|---|
| G01 | Push a commit with a secret to the throwaway GitLab project | Server blocks (secret push protection) | Org |
| G02 | `git push -o secret_push_protection.skip_all` | Allowed + audit event + alert to the security team | Org |
| G03 | `[skip secret push protection]` in the commit message | Allowed + audit event + alert | Org |
| G04 | Secret in a file >1 MiB, a binary, or the initial push that creates the repo | Missed by push protection → caught by pipeline secret detection | Org |
| G05 | Secret in a path excluded from push protection | Pipeline detection catches it | Org |
| G06 | Commit via GitLab Web IDE / web editor | Server blocks | Org |
| G07 | Commit via GitLab REST API (commits endpoint) | Record whether push protection applies | Record |
| G08 | Push to a GitHub public repo | Record coverage (still to be confirmed) | Record |
| G09 | Heartbeat correlation: pushed commit with no matching hook scan event (from D01, D14, F05) | Bypass alert fires | Org |
| G10 | For every **Detect** row: which detector fired (endpoint detection rule, remediation script, device compliance, heartbeat, audit event), latency, and whether the alert reached the security team | Record | Record |
| G11 | Device marked noncompliant: is its access to GitLab blocked? | Access blocked | Org |
| G12 | Time for remediation to restore the hook after D04, D05, D10 | Record vs. target SLA | Record |

## N. Found while testing

Scenarios added while the catalog was automated. There is no N06.

| ID | Scenario | Expected | Who covers it |
|---|---|---|---|
| N01 | Overwrite the installed hook script (`~/.local/share/git-secret-guard/hooks/secret-scan`, user-writable) with `exit 0` | Detect | Hook gap |
| N02 | Shadow `find` with a no-op earlier in the user `PATH` | Block | Undecided |
| N03 | Commit a catch-all pattern (`*`, `**`) to the repository's exemption file, then commit a secret | Detect (the hook warns on every commit) | Hook gap (the hook warns) |
| N04 | Commit a `.gitleaks.toml` without `[extend] useDefault = true`, turning betterleaks' built-in rules off | Detect (the hook warns on every commit) | Hook gap (the hook warns) |
| N05 | `git config --global --remove-section hook.git-secret-guard` | Detect | Hook gap |
| N07 | Config that changes how git prints a diff (`-c`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`, repository config), to hide added lines from extraction | Block | Hook |
| N08 | `git config --local hook.git-secret-guard.command true` | Detect | Hook gap |

---

## Priority rows for the rollout decision

**D13, D14, D16, D21, F05–F07.** These show whether the hook fails closed, and how much protection actually rests on the server gate and on hook-telemetry-vs-push correlation rather than on the client hook.

---

## Automated coverage

`tests/scan/test_bypass_catalog.sh` runs the scenarios below on every CI run (`.github/workflows/tests.yml`, Ubuntu 24.04, git from the git-core PPA, the pinned scanners). It uses the same sandbox as the rest of the suite: scratch `HOME`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_NOSYSTEM=1`. The real `~/.gitconfig` is never read or written, which is stricter than backing it up and restoring it. Run it locally with `tests/run.sh tests/scan/test_bypass_catalog.sh`.

- **What a test asserts.** Each test asserts the hook's **current** behaviour. A Block row asserts the block. A Gap or Detect row that is a known hole asserts the hole, the way the suite pins its other documented limits. A test going red means the behaviour changed, in either direction.
- **The results table.** With `GSG_CATALOG_REPORT=<file>` set, each scenario appends one TSV row: ID, Expected, Actual (Blocked / Blocked-unscanned / Allowed / Error), Verdict (PASS / FAIL / ERROR / PENDING-SEC / RECORDED), UTC, host, OS, git version, command and hook output. CI sets the variable, publishes the table in the job summary and uploads it as the `catalog-head` artifact. PENDING-SEC means the bypass worked; Security must confirm whether an alert fired at that UTC time (Section G).
- **The current answers the tests pin** where the Expected column alone does not say it:
  - **A13:** a pure rename adds no lines and commits (`no added lines to scan`; the secret is already in history); a token added to the renamed file is blocked.
  - **A14:** a token only in the commit message is blocked by the `commit-msg` event, with the finding at `commit message:<line>`.
  - **A17:** a file with a NUL byte is binary to git and commits unscanned; a 3 MB text file is scanned and blocked.
  - **C04, D07, D08b, D09, N05, N08:** disabling the hook (`hook.git-secret-guard.enabled=false` by `-c`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`, local config or an include), an empty `GIT_CONFIG_GLOBAL`, a replaced or removed `hook.git-secret-guard.command`, and an alias with `--no-verify` all commit with no hook output at all.
  - **D03, D04, D05, D08a:** `core.hooksPath` (empty, an empty directory, global, local, through an include) does not switch the config hook off; the commit is blocked.
  - **D11:** a hook script without its exec bit makes the commit fail (git cannot start it).
  - **D12:** scanners shadowed on `PATH` are not used (tool paths come from the settings file); the commit is blocked. **N02** (`find` shadowed) is recorded, not asserted.
  - **D13:** a missing scanner blocks with `nothing was scanned`; a crashing scanner blocks with `scan failed (exit N)`, a missing shipped rule file with `the shipped rule file ...`.
  - **D14, D15a, D16:** a plumbing commit, a merge that `git merge` commits by itself, and `cherry-pick`, `rebase` and `am` of a commit made with `--no-verify` run no scan and commit. **D15b:** a conflicted merge finished with `git commit` is scanned and blocked.
  - **N01:** a hook script overwritten with `exit 0` commits with no hook output.
- **No verification.** trufflehog runs with `--no-verification`, so a fake token is a plain `match` ([scan.md](scan.md#limits)); the tests also set a dead proxy, as extra isolation only. This matches the rest of the real-scanner suite.

| Rows | Test (in `tests/scan/test_bypass_catalog.sh` unless named) |
|---|---|
| A02, A03, A04 (PEM, OpenSSH), A09, A12, A13, A14, A15, A16 (CRLF, path), A17 (binary, large), A18 | `test_real_catalog_a*` |
| A16 UTF-16 | `test_real.sh` (`test_real_utf16_and_nul_byte_files_commit_unscanned_a_documented_limit`) |
| B01, B02 (recorded, no assertion), B04 | `test_real_catalog_b*` |
| C01 | `test_exemptions_real.sh`: `test_real_trufflehog_ignore_mutes_trufflehog_only`, `test_real_gitleaks_allow_mutes_betterleaks_only`, `test_real_both_markers_on_one_line_let_the_commit_succeed_in_either_order` |
| C02 | `test_exemptions_real.sh`: `test_real_an_exemption_counts_only_from_the_commit_after_it_is_committed`, `test_real_a_staged_gitleaks_config_cannot_replace_the_one_at_head` |
| C04, C05 (recorded) | `test_real_catalog_c*` |
| D01–D05, D07–D09, D11–D16, D18–D20 | `test_real_catalog_d*` |
| D06 | no test of its own: every test runs with `GIT_CONFIG_NOSYSTEM=1` and the hook in the global config, so each Block row above shows it is still blocked |
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
