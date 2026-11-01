# Epic: git-secret-guard — machine-wide pre-commit secret scanning

## Epic Completion Status: **✅ COMPLETE**

**Story Completion:** 6/6 stories complete

✅ **COMPLETED STORIES:**
- 01.01 [Dual-scanner pre-commit scan](01_Feat_SecretScanHook/01_Story_DualScannerPreCommitScan.md) ✅ (151 tests, review approved after 1 rejection, manual E2E 13/13 PASS)
- 01.02 [In-repo exemptions](01_Feat_SecretScanHook/02_Story_InRepoExemptions.md) ✅ (241 tests, review approved after 2 rejections, manual E2E failed once on the useDefault warning, fixed, then PASS)

- 02.01 [Install, upgrade, uninstall](02_Feat_Lifecycle/01_Story_InstallUpgradeUninstall.md) ✅ (369 tests, approved on review round 4, all manual E2E rounds PASS)

- 03.01 [Doctor coverage report](03_Feat_CoverageAssurance/01_Story_DoctorCoverageReport.md) ✅ (475 tests, approved on review round 2, manual E2E PASS twice)

- 04.01 [Ubuntu 24.04 support](04_Feat_Portability/01_Story_UbuntuSupport.md) ✅ (565 tests; Ubuntu container 563/0/2, host 558/0/7; approved on review round 5 after 4 rejections, mostly on container isolation; manual E2E PASS in rounds 1, 2, 4 and 5)

- 05.01 [Migrate this machine](05_Feat_MachineRollout/01_Story_MigrateThisMachine.md) ✅ (user-approved 2026-11-01; backup, real install, smoke tests PASS incl. cidx-server env, doctor 54/54 repos covered)

**Out of scope for this epic:** macOS support. The user will port it on a Mac.

**Overall Progress:** 100% complete

---

## Intent

Every commit made on this machine is scanned for secrets in the lines it adds, by **trufflehog** and
**gitleaks** together. Each repository's own hooks keep running (husky, the pre-commit framework, plain
`.git/hooks`, server-side hooks), and that holds for repositories cloned or pulled later. The package
replaces a hand-built `core.hooksPath` setup (`~/.config/git/hooks`), which does not reach repositories
that set their own `core.hooksPath`.

## Decisions (made with the user, with evidence)

| Decision | Evidence / reason |
|---|---|
| Use git **config-based hooks** (`hook.<name>.command/.event`), not a global `core.hooksPath` | Needs git ≥ 2.54 (release notes 2.54.0). Verified on 2.56.0: the hook runs **in addition to** a repo-local `core.hooksPath` (husky `.husky/_`), and also when that path is missing. |
| git 2.56.0 installed from source at `/usr/local` | `/usr/bin/git` 2.52 (RPM) ignores config hooks without any message. Commits made with it are not scanned, and doctor warns about this. |
| Scanners: **trufflehog 3.99.2 + gitleaks 8.30.1**, run in parallel, both pinned with vendor SHA-256 | User decision. GitGuardian was rejected: content goes to a cloud API, it needs an account, and it publishes no checksums. |
| Block on any finding (verified or unknown) **or** any scanner error | Anti-fallback. Offline verification makes trufflehog report "unknown", which blocks. |
| Exemptions live **in the repo** (`.secret-scan-ignore`, read from HEAD) plus each tool's native inline markers (`trufflehog:ignore`, `gitleaks:allow`) | They are shared with other developers, versioned and reviewed. Reading from HEAD means a commit cannot exempt itself. |
| cidx-server is **scanned** (no exemption) | User decision (option B). The drop-in stays unchanged. |
| No global `core.hooksPath`, no dispatcher, no passthrough dir, no husky init.sh, no pre-commit bridge, no `fix` | Config hooks make all of these unnecessary. |
| `hook.git-secret-guard.command` uses an absolute path | Lesson 1: `~` breaks under a scratch HOME. A missing script fails the commit (fail closed) instead of disabling every hook. |

## Architecture

```
git commit (git >= 2.54)
  ├─ config hook "git-secret-guard"  →  <share>/hooks/secret-scan
  │     ├─ read .secret-scan-ignore @HEAD → exclude pathspecs (reasons mandatory)
  │     ├─ extract ADDED lines of staged diff → private temp dir (mode 700, trap cleanup)
  │     │     files at real relative paths, added lines at real line numbers (others blank)
  │     ├─ nothing added → exit 0 (no scanner started)
  │     ├─ run in parallel:  trufflehog adapter  |  gitleaks adapter (+ repo .gitleaks.toml/.gitleaksignore @HEAD)
  │     │     each → normalized rows: scanner, detector, status, file, line   (never the value)
  │     └─ any finding or any scanner error → block (exit 1), else exit 0
  └─ hookdir hook (repo's own: .git/hooks, husky .husky/_, pre-commit shim)  — run by git itself
```

| Component | Purpose |
|---|---|
| `bin/git-secret-guard` | CLI: install, uninstall, doctor, status, version |
| `hooks/secret-scan` | the pre-commit scan, run by git through the config hook |
| `lib/scanners/{trufflehog,gitleaks}.sh` | run one tool and turn its output into normalized rows |
| `lib/install.sh`, `lib/doctor.sh`, `lib/common.sh` | lifecycle, coverage checks, shared paths and state |
| `tools.lock` | pinned versions and SHA-256 per platform for both tools |
| `systemd/` | optional user timer that runs doctor weekly, output to the journal |
| `tests/` | bash test runner and sandboxed suites (scratch HOME, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_NOSYSTEM=1`) |

Technologies: bash (Linux: RHEL 9-compatible, tested on Rocky Linux 9.7, and Ubuntu 24.04; macOS out of scope, to be ported on a Mac), git ≥ 2.54, trufflehog, gitleaks, jq, shellcheck, systemd user units.

## Features (implementation order)

1. **01_Feat_SecretScanHook**: the scan itself and its in-repo exemptions.
2. **02_Feat_Lifecycle**: install, upgrade and uninstall, including the pinned tools.
3. **03_Feat_CoverageAssurance**: doctor and the optional timer.
4. **04_Feat_Portability**: Ubuntu 24.04 verified in a podman container (mawk, git from the PPA).
5. **05_Feat_MachineRollout**: real migration of this machine and a doctor report over `~/Dev`.

## Cross-cutting rules (apply to every story)

- No secret value is ever printed: not in hook output, logs, test output or doctor output.
- Test fixtures build fake secrets at runtime from fragments. No committed file contains anything that
  looks like a credential.
- Tests never touch the real `~/.gitconfig`, `~/.local` or `~/.config`.
- shellcheck reports zero warnings.
- No other repository's config is changed without explicit per-repo user approval.
