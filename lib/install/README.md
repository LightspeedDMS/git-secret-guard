# lib/install: install, uninstall and their tools

CLI only. `install.sh` (the install flow and share copy), `install_tools.sh` and `tools.sh` (scanner and jq binaries from
`tools.lock`), `uninstall.sh`, `hookspath.sh` (`core.hooksPath` handling and the hook listing probe), `install_path.sh` (the CLI folder
on `PATH`: the one comparison, install's plan, apply and report, and uninstall's undo), `install_created.sh` (the files and directories
install brings into being: their record in the state and uninstall's removal of the empty ones) and `install_cmd.sh` (the
Windows `.cmd` front end text written at install time).

- **May depend on:** `lib/core/` and the other CLI contexts as `bin/git-secret-guard` loads them.
- **Never loaded by the hook.**
