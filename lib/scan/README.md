# lib/scan: what the hook runs on a commit

Loaded by the hook; the CLI also loads `exempt.sh` (doctor reuses its exemption readers). Extraction of the added lines (`extract.sh`, `extract.awk`), exemptions (`exempt.sh`), the report and the coverage
reminder (`report.sh`), the scanner runner (`run-scanner.sh`), the adapters (`scanners/trufflehog.sh`, `scanners/betterleaks.sh`)
and our betterleaks rule file (`betterleaks-rule.toml`).

- **May depend on:** `lib/core/` only.
- **Hook loading:** the libraries and files of this folder that the hook reads are listed in `GSG_HOOK_LIBS` and `GSG_HOOK_FILES`
  in `core/common.sh`, relative to `lib/` (for example `scan/extract.sh`). A new hook library goes into that list and nowhere else.
- **Not here:** anything only the CLI uses (install, doctor, upgrade); those live in the other context folders and the hook never
  loads them.
