# lib/platform: operating system specifics

CLI only. `brew.sh` (the Homebrew bootstrap, bash 3.2 safe, loaded first), `launchd.sh` (macOS agents), `schtasks.sh` and
`winupdate.sh` (Windows scheduled update), `macpath.sh` (the macOS startup-file block that puts the CLI folder on `PATH`, and its undo),
`winpath.sh` (the adapter to the Windows user `Path`: it runs `bin/gsg-path.ps1` in Windows PowerShell 5.1) and `wsl.sh` (WSL notices and pins).

- **May depend on:** `lib/core/`, and the other CLI contexts as `bin/git-secret-guard` loads them. `brew.sh` sources nothing.
- **Never loaded by the hook.**
