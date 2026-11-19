# lib/gitup: the git upgrade

CLI only. `gitup.sh` holds the shared plan, the registry and the OS class detection; each operating system plugs in as one module
file `gitup_<name>.sh` plus one registry line (`apt`, `rpm`, `macos`, `windows`, `wsl`). `gitup_source.sh` is the shared pinned
source build the modules call (loaded by `bin/git-secret-guard`); `gitup_takeover.sh` is the system git takeover of the `rpm` module.

- **May depend on:** `lib/core/`, `lib/install/` (`install_find_bin`), and the other CLI contexts as `bin/git-secret-guard`
  loads them. `gitup_rpm.sh` loads `gitup_takeover.sh` itself.
- **Adding an OS module:** see CONTRIBUTING.md, "Adding an OS module".
- **Never loaded by the hook.**
