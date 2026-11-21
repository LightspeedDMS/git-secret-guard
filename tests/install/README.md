# tests/install: install, upgrade and uninstall

Tests of `lib/install/`: install and its adopt and network paths, uninstall, upgrade, the `core.hooksPath` handling, the tool
downloads, the prerequisites, the whole lifecycle end to end, the restore flows shown by the UI, the files install writes or leaves alone
(`test_install_written_files.sh`) and its warning about other gits on the machine (`test_install_other_gits.sh`).

- **Covers:** `lib/install/`.
- **Helpers owned:** none. The tests load `tests/support/lib.sh` and `tests/support/lifecycle.sh`; `test_ui_restore.sh` also loads the gitup, smartgit and Windows helpers of `tests/support/`, and the two files above load `gitup.sh` and `product_call.sh`.
- **Runs:** `tests/run.sh tests/install`.
