# tests/integrations/smartgit: the SmartGit settings

`test_smartgit.sh`, `test_smartgit_linux.sh` and `test_smartgit_windows.sh`.

- **Covers:** `lib/integrations/smartgit/`.
- **Helpers owned:** `smartgit_linux.sh` and `smartgit_windows.sh`, one per test file of that name. `tests/support/smartgit.sh` is shared with `tests/install/`, so it lives in `tests/support/`.
- **Runs:** `tests/run.sh tests/integrations/smartgit`.
