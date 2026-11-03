# git-secret-guard

Scans each commit made on this machine (with git 2.54 or newer) for secrets before it is made. The lines a
commit adds are checked by **trufflehog** and **betterleaks** in parallel, and any finding blocks the commit. It is a
git config-based hook, so it runs alongside whatever hooks a repository brings (husky, the pre-commit framework,
`.git/hooks`), also in repositories cloned later.

## Requirements

- Linux on x86_64 or arm64 (tested on RHEL 9-compatible Rocky Linux 9.7 and on Ubuntu 24.04 in a podman container), or
  macOS arm64 with Homebrew (tested on macOS 26.7.1; macOS x86_64 is mapped but not tested).
- **git 2.54 or newer, first on `PATH`.** Older git ignores config hooks without any message. Ubuntu 24.04 ships
  2.43: see [docs/platforms.md](docs/platforms.md) for the PPA or a source build.
- bash, `jq`, `setsid`, `timeout`, and `curl` plus `tar` to download the scanners. On macOS, `install` installs the missing
  bash 4.4+, `coreutils`, `util-linux` and `jq` with `brew install`, after its other checks have passed.

## Install

```bash
git clone <this repository> && cd git-secret-guard
bin/git-secret-guard install
```

This puts trufflehog and betterleaks in `~/.local/bin` at the versions pinned in `tools.lock`. A tool already at the
pinned version is kept; otherwise it is downloaded and its SHA-256 checked, and a file install did not place there
is moved aside, never overwritten. Install also links the `git-secret-guard` command into `~/.local/bin` (keep it on
your `PATH`), copies the package to `~/.local/share/git-secret-guard`, and adds the hook to your global git config.
If you already have a global `core.hooksPath`, install refuses; `install --replace-hooks-path` backs it up and takes
it over. To upgrade, run `install` again from a newer checkout; a machine installed by the earlier build that used
**gitleaks** is upgraded the same way (the gitleaks that build placed is removed, yours is restored). Details:
[docs/install.md](docs/install.md).

## Use

```bash
git commit ...                          # scanned automatically
git-secret-guard status                 # what is installed, and whether the config still matches
git-secret-guard doctor                 # which repositories under ~/Dev are not protected, and why
git-secret-guard uninstall              # restore what was there before (--remove-tools: also the scanners it downloaded)
```

A blocked commit lists the scanner, rule, file and line of each finding, never the secret itself. A passing commit prints
one line, so a clean scan can be told from a hook that never ran:

```
git-secret-guard: scanned 3 files, 214 added lines (trufflehog 3.99.2, betterleaks 1.9.0): no findings, 1s
git-secret-guard: no added lines to scan                      # only deletions, binary files, mode changes, an empty commit
git-secret-guard: scanned 3 files, ..., no findings, 2 files exempted, 1s   # .secret-scan-ignore excluded staged files
```

No line at all on a commit means the hook did not run (see `docs/scan.md`). The counts come from the extraction, the line
holds no path or value, and there is no switch to turn it off.

## False positives

| To skip | Do this |
|---|---|
| Paths | Add `<glob>  # <reason>` lines to `.secret-scan-ignore` at the repository root |
| One line | Put `trufflehog:ignore gitleaks:allow` on that line (each marker mutes only its own tool; `betterleaks:allow` works too) |
| betterleaks rules or findings | Commit a `.gitleaks.toml` or `.gitleaksignore` (the file names are unchanged from the gitleaks days) |
| One commit | `git commit --no-verify` |

Exemption files are read from the last commit (HEAD), so commit them first: a commit cannot exempt itself.
Details: [docs/exemptions.md](docs/exemptions.md).

## Limits

- Commits made with git older than 2.54 (on this machine `/usr/bin/git` 2.52) are not scanned.
- Only `pre-commit` runs the scan: merges, cherry-picks, rebases and `git am` are not scanned.
- Binary files, including UTF-16 text, are not scanned.
- Offline, trufflehog cannot verify a candidate and reports it as `unknown`, which blocks.
- About 2 seconds per commit that adds lines.

The scan's limits are in [docs/scan.md](docs/scan.md#limits); install, exemptions and doctor list their own.

## Documentation

| Doc | Covers |
|---|---|
| [docs/install.md](docs/install.md) | install, upgrade (also from the gitleaks build), uninstall, `core.hooksPath` takeover, pinned tools, `status` |
| [docs/scan.md](docs/scan.md) | how the scan works, the settings file, tests, the scan's limits |
| [docs/exemptions.md](docs/exemptions.md) | `.secret-scan-ignore`, inline markers, betterleaks config, local switches |
| [docs/doctor.md](docs/doctor.md) | the coverage report, its checks and exit status, the weekly timer |
| [docs/platforms.md](docs/platforms.md) | supported platforms, Ubuntu setup, the Ubuntu container test |
