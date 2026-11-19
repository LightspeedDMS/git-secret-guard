# tests/install: install, upgrade and uninstall

Tests of `lib/install/`: install and its adopt and network paths, uninstall, upgrade, the `core.hooksPath` handling, the tool
downloads, the prerequisites, the whole lifecycle end to end, and the restore flows shown by the UI.

- **Covers:** `lib/install/`.
- **Helpers owned:** none. The tests load `tests/support/lib.sh` and `tests/support/lifecycle.sh`; `test_ui_restore.sh` also loads the gitup, smartgit and Windows helpers of `tests/support/`.
- **Runs:** `tests/run.sh tests/install`.
