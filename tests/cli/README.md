# tests/cli: the command line

`test_cli.sh` tests `bin/git-secret-guard` and its help text; `test_cli_interrupt.sh` tests what it says when ctrl-c arrives while it starts.

- **Covers:** `lib/cli/` and `bin/git-secret-guard`.
- **Helpers owned:** none. `test_cli.sh` loads `tests/support/lib.sh` and `tests/support/lifecycle.sh`; `test_cli_interrupt.sh` loads only `tests/support/lib.sh`.
- **Runs:** `tests/run.sh tests/cli`.
