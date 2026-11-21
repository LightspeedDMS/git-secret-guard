# tests/integrations/smartgit: the SmartGit settings

`test_smartgit.sh`, `test_smartgit_linux.sh`, `test_smartgit_windows.sh` and `test_smartgit_record_refusals.sh` (the manifest and Flatpak records the undo refuses).

- **Covers:** `lib/integrations/smartgit/`.
- **Helpers owned:** `smartgit_linux.sh` (loaded by `test_smartgit_linux.sh` and `test_smartgit_record_refusals.sh`) and `smartgit_windows.sh` (loaded by `test_smartgit_windows.sh`). `tests/support/smartgit.sh` is shared with `tests/install/`, so it lives in `tests/support/`.
- **Runs:** `tests/run.sh tests/integrations/smartgit`.
