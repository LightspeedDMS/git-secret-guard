# tests/scan: what the hook runs on a commit

Tests of the hook and of `lib/scan/`: extraction of the added lines, exemptions, the two scanner adapters, the commit message scan,
the coverage reminder, Git LFS pointers, coexistence with other hooks, signals, the PII rules and the bypass catalog. The `*_real.sh`
files run the pinned scanners; the others use the stand-ins of `tests/stubs/`.

- **Covers:** `hooks/secret-scan`, `lib/scan/`, and `lib/core/` as the hook loads it.
- **Helpers owned:** `guidance_helpers.sh` (reads the marker and the fingerprint the hook printed, loaded by the real-scanner files that apply
  the block guidance of #3; `test_guidance.sh` pins its text with stand-ins). The tests load `tests/support/lib.sh`, and `tests/support/lifecycle.sh` or `tests/support/doctor.sh` where they install first.
- **Runs:** `tests/run.sh tests/scan`.
