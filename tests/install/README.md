# tests/install: install, upgrade and uninstall

Tests of `lib/install/`: install and its adopt and network paths, uninstall, upgrade, the `core.hooksPath` handling, the tool
downloads, the prerequisites, the whole lifecycle end to end, the restore flows shown by the UI, the files install writes or leaves alone
(`test_install_written_files.sh`), its warning about other gits on the machine (`test_install_other_gits.sh`), the CLI folder on `PATH` (`test_install_path.sh`, and the Windows user `Path` adapter against a recording PowerShell stand-in in `test_winpath.sh`), and the shared per-file install copy
`fresh_install` of `tests/support/lifecycle.sh` (`test_fresh_install.sh`).

- **Covers:** `lib/install/`.
- **Helpers owned:** none. The tests load `tests/support/lib.sh` and `tests/support/lifecycle.sh`; `test_ui_restore.sh` also loads the gitup, smartgit and Windows helpers of `tests/support/`, and the two files above load `gitup.sh` and `product_call.sh`.
- **Runs:** `tests/run.sh tests/install`.
