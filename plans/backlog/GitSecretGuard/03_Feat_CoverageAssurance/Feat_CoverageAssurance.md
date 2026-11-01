# Feature 03: Coverage assurance

## Objective
Make every gap visible. The hook cannot report a repository where it never runs, so a read-only `doctor`
checks the machine and every repository under the configured roots, and an optional timer runs it weekly.

## Architecture
- `doctor` only reads: `git config --show-origin`, `git hook list pre-commit`, `git show HEAD:<file>`, tool `--version`.
- The timer is a systemd user `.service` + `.timer`, writing output to the journal. It never edits anything.

## Dependencies
- Feature 02 (the config keys and state it checks).

## Stories (implementation order)
- [x] 01_Story_DoctorCoverageReport
