# tests/support: the harness and the shared helpers

No test file lives here. The harness: `lib.sh` (sandbox, assertions, the runner of a file's tests), `lifecycle.sh` (an installed
machine in the sandbox, with recording stand-ins) and `apt.sh` (loaded by `lifecycle.sh`). The helpers that tests of more than one
folder load: `doctor.sh`, `gitup.sh`, `gitup_macos.sh`, `gitup_windows.sh`, `smartgit.sh` and `autoupdate_units.sh`.

- **Rule:** a test file or helper loads test helpers only from this folder and from its own folder
  (`test_every_test_helper_source_resolves_to_tests_support_or_the_files_own_folder`).
- **A new helper:** it goes here when tests of two or more folders load it; otherwise it lives in the folder of the one context that does.
- **Not here:** `tests/stubs/` and `tests/fixtures/` stay where they are; they are data reached through the project root.
