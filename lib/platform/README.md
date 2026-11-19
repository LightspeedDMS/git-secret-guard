# lib/platform: operating system specifics

CLI only. `brew.sh` (the Homebrew bootstrap, bash 3.2 safe, loaded first), `launchd.sh` (macOS agents), `schtasks.sh` and
`winupdate.sh` (Windows scheduled update), `wsl.sh` (WSL notices and pins).

- **May depend on:** `lib/core/`, and the other CLI contexts as `bin/git-secret-guard` loads them. `brew.sh` sources nothing.
- **Never loaded by the hook.**
