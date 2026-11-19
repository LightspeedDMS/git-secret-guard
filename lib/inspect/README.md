# lib/inspect: the report views

CLI only. `status.sh` (the status command) and `doctor.sh`, `doctor_repos.sh`, `doctor_findings.sh` (the doctor command and its
findings record).

- **May depend on:** `lib/core/`, `lib/scan/` (the exemption readers doctor reuses), and the other CLI contexts as
  `bin/git-secret-guard` loads them.
- **Never loaded by the hook.** The hook starts `doctor --recheck` as a separate process.
