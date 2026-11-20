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

| Value | What it means | What the organisation must do |
|---|---|---|
| **Hook** | git-secret-guard stops it on the developer machine (for an Allow row: lets it through), proven by an automated test | Nothing beyond keeping the hook installed |
| **Hook gap** | A known hole the hook cannot close (the test or the docs show it, e.g. [scan.md](scan.md#limits)) | Catch it elsewhere: server-side secret scanning, push protection, alerting |
| **Org** | Outside the hook entirely | Provide it: endpoint protection, device management, the server-side gate, IT procedures |
| **Record** | A question to answer or a fact to log, not a control | Answer it and keep the record |
| **Undecided** | No test or document settles it yet | Treat it as not covered until a test decides it |
| **N/A** | Does not apply to this hook | Nothing |
| **Several**, e.g. Hook (PEM); Hook gap (`.ppk`) | The scenario has parts that are covered differently; each value names the part it applies to, in parentheses | Handle each part by its own value (the weakest part decides whether the scenario as a whole is covered) |

Most tests behind these values are listed in [Automated coverage](#automated-coverage). A01, A11, B01 and F08 also rest on `tests/scan/test_real.sh` and `tests/scan/test_exemptions_real.sh`, D21 on a probe by hand on the Windows test machine (described in the row), D22 on [platform-testing.md](platform-testing.md#github-desktops-bundled-git), D24 on JetBrains' documentation and source (cited in the row), F01–F03 on the `windows`, `windows-suite`, `macos-suite` and `suite` CI jobs, and F05 on `tests/platform/wsl-ci.sh`.

---

## A. Baseline detection (the hook works)

| ID | Scenario | Expected | Who covers it |
|---|---|---|---|
| A01 | Commit a file with an AWS access key + secret | Block | Hook |
| A02 | GitLab PAT (`glpat-…`) | Block | Hook |
| A03 | GitHub PAT or fine-grained token | Block | Hook |
| A04 | Private key (PEM, OpenSSH, PuTTY `.ppk`) | Block | Hook (PEM, OpenSSH; `.ppk` by our rule `putty-private-key`) |
| A05 | Slack token or webhook URL | Block | Hook |
| A06 | Azure storage key, SAS token, or client secret | Block | Hook (storage key, client secret; a service SAS also by trufflehog `AzureSasToken`, an account or service SAS by our rule `azure-sas-signature`) |
| A07 | DB connection string with password (JDBC, SQL Server, Postgres URI) | Block | Hook |
| A08 | JWT / bearer token | Block | Hook (JWT; a bearer header in a `curl` command, and in code or an HTTP request file by our rule `authorization-bearer-token`) |
| A09 | `.env`, `application.properties`, or `appsettings.json` with secrets | Block | Hook |
| A10 | Basic-auth credentials in a URL (a user name and password written before the host name) | Block | Hook |
| A11 | Generic high-entropy password assigned to a variable | Block (verify rule exists) | Hook (names with `passw`, `_pw`, `secret`, `token`, `key`, `auth`, `credential`; `pass`, `pwd`, `pw`, `passphrase`, `db_pass`, `userpass`, `DB_PASS` by our rules `password-assignment` (quoted) and `password-assignment-bare` (unquoted), in env, YAML, JSON, properties, Go and PHP forms) |
| A12 | Secret in a file staged with `git add -p` (partial staging) | Block | Hook |
| A13 | Secret in a renamed or moved file | Block | Hook (token added); Hook gap (pure rename) |
| A14 | Secret in the commit message | Block (the `commit-msg` event) | Hook |
| A15 | Secret introduced via `git commit --amend` | Block | Hook |
| A16 | Secret in a file with CRLF endings, UTF-16 encoding, or a path with spaces/unicode | Block | Hook (CRLF, path); Hook gap (UTF-16) |
| A17 | Secret in a large file, a binary, or a Git LFS-tracked file | Record behavior | Hook (large text, LFS object); Hook gap (binary) |
| A18 | Secret in a Jupyter notebook or other JSON blob | Block | Hook |

### AI vendor API keys

Each key is tested in three forms: bare on a line, in a `.env` (`<VENDOR>_API_KEY=...`) and in a client call (`Vendor(api_key="...")`).
"Built-in" names the betterleaks 1.9.0 rule or trufflehog detector; rules of ours are listed in [scan.md](scan.md#credential-rules).
A key with no shape of its own (no prefix) written bare is a Hook gap: a rule for it would block every hash and id of that length.

| ID | Scenario | Expected | Who covers it |
|---|---|---|---|
| A19 | Anthropic API key (`sk-ant-api03-`) and admin key (`sk-ant-admin01-`) | Block | Hook (built-in `anthropic-api-key`, `anthropic-admin-api-key`, trufflehog `Anthropic`) |
| A20 | OpenAI key, `sk-proj-` and legacy `sk-` | Block | Hook (built-in `openai-api-key`, trufflehog `OpenAI`) |
| A21 | Voyage AI key (`pa-`) | Block | Hook (built-in `voyageai-api-key` next to the name; bare by our rule `voyageai-api-key-bare`) |
| A22 | Google Gemini / GCP API key (`AIza`) | Block | Hook (built-in `gcp-api-key`) |
| A23 | Mistral key (32 characters, no prefix) | Block | Hook (`.env`: built-in `mistral-api-key`; code: `generic-api-key`); Hook gap (bare) |
| A24 | Cohere key (40 characters, no prefix) | Block | Hook (`.env`: built-in `cohere-api-token`; code: `generic-api-key`); Hook gap (bare) |
| A25 | Groq key (`gsk_`) | Block | Hook (built-in `groq-api-key`, trufflehog `Groq`) |
| A26 | xAI key (`xai-`) | Block | Hook (built-in `xai-api-key`, trufflehog `XAI`) |
| A27 | DeepSeek key (`sk-` and 32 hex) | Block | Hook (built-in `deepseek-api-key` next to the name, trufflehog `DeepSeek`; bare by our rule `deepseek-api-key-bare`) |
| A28 | Perplexity key (`pplx-`) | Block | Hook (built-in `perplexity-api-key`) |
| A29 | Together AI key (64 hex, no prefix) | Block | Hook (`.env`, code: `generic-api-key`); Hook gap (bare) |
| A30 | Cerebras key (`csk-`) | Block | Hook (built-in `cerebras-api-key`) |
| A31 | OpenRouter key (`sk-or-v1-`) | Block | Hook (built-in `openrouter-api-key`, trufflehog `OpenRouter`) |
| A32 | Replicate token (`r8_`) | Block | Hook (built-in `replicate-api-token`, trufflehog `Replicate`) |
| A33 | Hugging Face token (`hf_`) | Block | Hook (built-in `huggingface-access-token`, trufflehog `HuggingFace`) |
| A34 | LangSmith key (`lsv2_pt_`) | Block | Hook (built-in `langchain-langsmith-personal-access-token`, trufflehog `LangSmith`) |
| A35 | ElevenLabs key (`sk_` and 48 hex) | Block | Hook (built-in `elevenlabs-api-key` next to the name, trufflehog `ElevenLabs`; bare by our rule `elevenlabs-api-key-bare`) |
| A36 | Deepgram key (40 hex, no prefix) | Block | Hook (`.env`: built-in `deepgram-api-key`, trufflehog `Deepgram`; code: `generic-api-key`); Hook gap (bare) |
| A37 | AssemblyAI key (32 hex, no prefix) | Block | Hook (`.env`: built-in `assemblyai-api-key`, trufflehog `AssemblyAI`; code: `generic-api-key`); Hook gap (bare) |
| A38 | Stability AI key (`sk-` and 48 characters) | Block | Hook (built-in `stability-ai-api-key` next to the name; bare by our rule `stability-ai-api-key-bare`) |
| A39 | NVIDIA key (`nvapi-`) | Block | Hook (built-in `nvidia-api-key`, trufflehog `NVAPI`) |
| A40 | Weights & Biases key (40 hex, no prefix) | Block | Hook (`.env`: built-in `weights-and-biases-api-key`, trufflehog `WeightsAndBiases`; code: `generic-api-key`); Hook gap (bare) |
| A41 | Pinecone key, `pcsk_` and the legacy UUID | Block | Hook (`pcsk_`: built-in `pinecone-api-key.2`, trufflehog `Pinecone`; a legacy UUID after a `pinecone` name: built-in `pinecone-api-key.1`; in a client call: `generic-api-key`); Hook gap (a legacy UUID bare) |
| A42 | Azure OpenAI key (32 hex or 84 characters, no prefix) | Block | Hook (our rules: `azure-openai-api-key` for `AZURE_OPENAI_API_KEY` / `AZURE_OPENAI_KEY` and `AzureOpenAI(api_key=...)`, `azure-openai-api-key-header` for an `api-key` header near an Azure endpoint; trufflehog `AzureOpenAI` in the client call); Hook gap (bare) |

## B. False positives and noise

| ID | Scenario | Expected | Who covers it |
|---|---|---|---|
| B01 | AWS docs `EXAMPLE` keys and obvious placeholders (`changeme`, `<TOKEN>`) | Allow | Hook (betterleaks passes a lone `EXAMPLE` key ID and an all-`A` placeholder); Record (the whole commit, the rest) |
| B02 | Lockfiles, hashes, UUIDs, base64-embedded images | Allow | Hook |
| B03 | Commit latency on a large change (~10k files) | Record latency | Record |
| B04 | Normal commit with no secrets | Allow, and no alert fires | Hook |

## C. Suppression and allowlist abuse (no admin needed)

| ID | Scenario | Expected | Who covers it |
|---|---|---|---|
| C01 | Inline ignore comment (e.g. `gitleaks:allow`, `# nosec`) on a real-format secret | Detect, or apply policy decision | Hook gap |
| C02 | Add the secret's path/fingerprint to a repo-level allowlist or ignore file in the same commit | Detect | Hook |
| C03 | Edit a user-level scanner config or rules file, if one exists in a user-writable path | Detect | Hook (shipped rule file removed; a scanner path or the timeout edited in the settings file: fails closed); Hook gap (rule file edited: betterleaks is muted, trufflehog still blocks its own kinds; a line ending the shell, e.g. `exit 0`, in the settings file: no scan, no output; see #26) |
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
| D21 | Portable Git / MinGit unzipped into the user profile (ignores managed system config) | Detect | Hook gap (a git older than 2.54); Hook, by accident (2.54 or newer on a machine without a WSL distribution: MinGit 2.56.1 runs the global config hook, but it has no bash of its own, so its `sh` resolves the script's `env bash` to `C:\Windows\System32\bash.exe`, the WSL launcher; the launcher fails and git refuses the commit unscanned. The refusal is the launcher failing, not the hook's doing; probed by hand on the Windows test machine); Hook gap (the same with a WSL distribution installed: the hook would run inside it, untested; see #28) |
| D22 | GUI client with bundled git (GitHub Desktop, SourceTree embedded git) | Block / Detect (record) | Hook gap (a bundled git older than 2.54, e.g. GitHub Desktop's; the other clients were not checked and count as a gap until one is) |
| D23 | VS Code with `git.allowNoVerifyCommit` on, using "Commit (No Verify)" | Detect | Hook gap |
| D24 | JetBrains IDE with "Run Git hooks" unchecked | Detect | Hook gap (the IDE commits with `--no-verify`, like D01: [JetBrains help, Commit changes locally](https://www.jetbrains.com/help/idea/commit-and-push-changes.html) says clearing the checkbox disables Git hooks for that commit, and `GitRepositoryCommitter.kt` in `JetBrains/intellij-community` adds `--no-verify` when `isSkipHooks` is set) |
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
| N02 | Shadow `find` with a no-op earlier in the user `PATH` | Block | Hook (the hook runs no `find`: it reads the scan tree with bash globs, so a shadowing one is never run) |
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

`tests/scan/test_bypass_catalog.sh` and `tests/scan/test_bypass_formats_real.sh` (credential formats, edited rule and settings files, a shadowed `find`) run the scenarios below on every CI run (`.github/workflows/tests.yml`, Ubuntu 24.04, git from the git-core PPA, the pinned scanners; the Windows and macOS suites run them too). They use the same sandbox as the rest of the suite: scratch `HOME`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_NOSYSTEM=1`. The real `~/.gitconfig` is never read or written, which is stricter than backing it up and restoring it. Every sample is built at run time from fragments and random parts, so the tree holds no credential-looking literal. Run them locally with `tests/run.sh tests/scan/test_bypass_catalog.sh tests/scan/test_bypass_formats_real.sh`.

- **What a test asserts.** Each test asserts the hook's **current** behaviour. A Block row asserts the block. A Gap or Detect row that is a known hole asserts the hole, the way the suite pins its other documented limits. A test going red means the behaviour changed, in either direction.
- **The results table.** With `GSG_CATALOG_REPORT=<file>` set, each scenario appends one TSV row: ID, Expected, Actual (Blocked / Blocked-unscanned / Allowed / Error), Verdict (PASS / FAIL / ERROR / PENDING-SEC / RECORDED), UTC, host, OS, git version, command and hook output. CI sets the variable, publishes the table in the job summary and uploads it as the `catalog-head` artifact. PENDING-SEC means the bypass worked; Security must confirm whether an alert fired at that UTC time (Section G).
- **The current answers the tests pin** where the Expected column alone does not say it:
  - **A13:** a pure rename adds no lines and commits (`no added lines to scan`; the secret is already in history); a token added to the renamed file is blocked.
  - **A14:** a token only in the commit message is blocked by the `commit-msg` event, with the finding at `commit message:<line>`.
  - **A17:** a file with a NUL byte is binary to git and commits unscanned; a 3 MB text file is scanned and blocked.
  - **C04, D07, D08b, D09, N05, N08:** disabling the hook (`hook.git-secret-guard.enabled=false` by `-c`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`, local config or an include), an empty `GIT_CONFIG_GLOBAL`, a replaced or removed `hook.git-secret-guard.command`, and an alias with `--no-verify` all commit with no hook output at all.
  - **D03, D04, D05, D08a:** `core.hooksPath` (empty, an empty directory, global, local, through an include) does not switch the config hook off; the commit is blocked.
  - **D11:** a hook script without its exec bit makes the commit fail (git cannot start it).
  - **D12:** scanners shadowed on `PATH` are not used (tool paths come from the settings file); the commit is blocked. **N02:** a no-op `find` first on `PATH` is never run (the hook runs no `find`): the token is found and the commit is blocked.
  - **A04, A06, A08, A11, A19–A42:** every sample is blocked with the rule or detector named in the test. A PuTTY `.ppk` key, an account SAS, a bearer header outside a `curl` command, a password under `pass`, `pwd`, `pw` or `db_pass`, the bare DeepSeek, ElevenLabs, Stability AI and Voyage AI keys and the Azure OpenAI keys in context passed both scanners before; they are blocked by the [credential rules](scan.md#credential-rules) of `lib/scan/betterleaks-rule.toml`. A bare key with no prefix (A23, A24, A29, A36, A37, A40, A41 legacy, A42) is scanned and passes, pinned by the test. Placeholders (`changeme`, `<password>`, `${VAR}`, templates), paths (`PWD=/home/...`), `os.getenv(...)`, prose, bearer templates, a plain UUID and hex hashes without vendor context commit with only the pass line.
  - **C03:** a match-all allowlist appended to the shipped rule file mutes betterleaks (a lone AWS key ID commits; a GitHub token is still blocked by trufflehog); `exit 0` appended to the settings file commits with no hook output; a scanner path set to a no-op script, or `SCAN_TIMEOUT_SECONDS=1` with a scanner slower than that, blocks.
  - **D13:** a missing scanner blocks with `nothing was scanned`; a crashing scanner blocks with `scan failed (exit N)`, a missing shipped rule file with `the shipped rule file ...`.
  - **D14, D15a, D16:** a plumbing commit, a merge that `git merge` commits by itself, and `cherry-pick`, `rebase` and `am` of a commit made with `--no-verify` run no scan and commit. **D15b:** a conflicted merge finished with `git commit` is scanned and blocked.
  - **N01:** a hook script overwritten with `exit 0` commits with no hook output.
- **No verification.** trufflehog runs with `--no-verification`, so a fake token is a plain `match` ([scan.md](scan.md#limits)); the tests also set a dead proxy, as extra isolation only. This matches the rest of the real-scanner suite.

| Rows | Test (in `tests/scan/test_bypass_catalog.sh` unless named) |
|---|---|
| A02, A03, A04 (PEM, OpenSSH), A09, A12, A13, A14, A15, A16 (CRLF, path), A17 (binary, large), A18 | `test_real_catalog_a*` |
| A16 UTF-16 | `test_real.sh` (`test_real_utf16_and_nul_byte_files_commit_unscanned_a_documented_limit`) |
| A04 (`.ppk`), A05–A11, A19–A42, B02, C03 (rule file or settings edited), N02 | `test_bypass_formats_real.sh` (`test_real_formats_*`) |
| B01, B04 | `test_real_catalog_b*` |
| C01 | `test_exemptions_real.sh`: `test_real_trufflehog_ignore_mutes_trufflehog_only`, `test_real_gitleaks_allow_mutes_betterleaks_only`, `test_real_both_markers_on_one_line_let_the_commit_succeed_in_either_order` |
| C02 | `test_exemptions_real.sh`: `test_real_an_exemption_counts_only_from_the_commit_after_it_is_committed`, `test_real_a_staged_gitleaks_config_cannot_replace_the_one_at_head` |
| C04, C05 (recorded) | `test_real_catalog_c*` |
| D01–D05, D07–D09, D11–D16, D18–D20 | `test_real_catalog_d*` |
| D06 | no test of its own: every test runs with `GIT_CONFIG_NOSYSTEM=1` and the hook in the global config, so each Block row above shows it is still blocked |
| N01 (replaced hook script), N05/N08 (hook config removed or overridden) | `test_real_catalog_n*` |
| N03 catch-all, N04 `.gitleaks.toml` without defaults | `test_exemptions_real.sh` (`test_real_catch_all_patterns_...`, `test_real_a_repo_config_without_use_default_runs_only_its_own_rules`) |
| N07 inherited config | `test_inherited_config.sh` |

**Not automated, and why:**

- **A01 in the catalog files:** the AWS documentation keys are allowlisted on purpose (B01). A non-example key with its secret is blocked in `test_real.sh`, which is what the Hook value rests on.
- **B03:** latency is better measured outside CI.
- **D10, D17:** not applicable.
- **D21:** needs a separate git build on Windows; probed by hand (the row). The refusal seen there comes from the WSL launcher failing, not from the hook; a git without bash runs the hook through the WSL `bash.exe` (#28).
- **D22, D23, D25:** need GUI clients or IDEs. **D24** is settled from JetBrains' documentation and source (the row).
- **E:** elevated scenarios, run by IT.
- **F:** F01–F03 rest on the `windows`, `windows-suite`, `macos-suite` and `suite` CI jobs, F05 on `tests/platform/wsl-ci.sh` (the `wsl` workflow); none of them runs as a standard or non-admin user (F01, F02), and F04, F06 and F07 need images or VMs CI does not have.
- **G:** needs a throwaway GitLab project and credentials; CI must never push.
