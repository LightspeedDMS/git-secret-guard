# git-secret-guard

[![tests](https://github.com/LightspeedDMS/git-secret-guard/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/LightspeedDMS/git-secret-guard/actions/workflows/tests.yml?query=branch%3Amain)

Scans each commit made on this machine (with git 2.54 or newer) for secrets before it is made. The lines a
commit adds are checked by **trufflehog** and **betterleaks** in parallel, and any finding blocks the commit. It is a
git config-based hook, so it runs alongside whatever hooks a repository brings (husky, the pre-commit framework,
`.git/hooks`), also in repositories cloned later.

## Requirements

| Platform | You need | `install` takes care of |
|---|---|---|
| **Windows x86_64** (tested on Windows Server 2019) | [Git for Windows](https://git-scm.com/download/win) with git 2.54 or newer | `jq` (a pinned, checksum-verified `jq.exe`); `taskkill`, `timeout`, `curl` and `tar` come with Windows and Git for Windows |
| **macOS arm64** (tested on macOS 26.7.1; x86_64 is mapped but not tested) | Homebrew | bash 4.4+, `coreutils`, `util-linux` and `jq`, with `brew install`, after its other checks have passed |
| **Linux** x86_64 or arm64 (the suite and install E2E ran in podman containers on Rocky Linux 9.7, Ubuntu 24.04, Ubuntu 22.04 and Debian 13; the git upgrade ran for real in podman containers on hosted x86_64 runners (Ubuntu 24.04 and 22.04, Debian 13, Rocky 9.7, Fedora 44), in a Rocky 9.8 VM, on Ubuntu 24.04 and Debian 13 in podman on an arm64 Mac, and in real-apt chroots on 22.04, 24.04, Debian 13 and 20.04: [record](docs/platforms.md#results)) | bash, `jq`, `setsid`, `timeout`, and `curl` plus `tar` to download the scanners; git 2.54 or newer, unless `install` can upgrade it for you | on RHEL, Rocky, AlmaLinux, Fedora, Ubuntu and Debian, an old or missing git, if you agree; anything else it names, with how to get it |

**WSL** (Ubuntu, Debian or an RPM distribution inside Windows Subsystem for Linux) takes the Linux row above, with the same git upgrade offer. WSL and Windows are two separate git setups, and installing in one does not cover commits made by the other. Fixture-tested and run for real on hosted WSL 1 and WSL 2 (Ubuntu 22.04 and 24.04; Rocky 9.8 and Fedora 44 on WSL 2 only); other distributions are not run, and WSL 1 on Windows Server 2019 blue-screened the maintainer's host twice (cause not established): see [docs/platforms.md](docs/platforms.md#wsl-windows-subsystem-for-linux).

**git 2.54 or newer has to be first on `PATH`** on every platform: older git ignores config hooks without any message.
When `install` finds an older or missing git, what happens depends on the platform (on other platforms `install` refuses and prints how to get a newer git):

- **RHEL, Rocky, AlmaLinux and Fedora:** `install` shows its plan and offers to upgrade git (the default is No; with no terminal, pass `--upgrade-git`). It uses the
  distribution's package when that is new enough, and otherwise builds the pinned source into `/usr/local`. If an old package git stays in `/usr/bin`, `install` also offers
  `--take-over-system-git`, which points it at the new build (undo: `restore-system-git`). See [docs/platforms.md](docs/platforms.md#rhel-rocky-and-fedora-rpm).
- **Ubuntu and Debian (and derivatives such as Linux Mint):** `install` shows its plan and offers to upgrade git the same way. It uses the distribution's package when that is new enough; on Ubuntu otherwise the git-core PPA (`ppa:git-core/ppa`, signing key checked against a pinned fingerprint), and on Debian, when the PPA lags, or on Linux Mint (its `add-apt-repository` has no `-n`, read from source, not run), the pinned source build. Ubuntu 22.04 ships 2.34 and 24.04 ships 2.43. See [docs/platforms.md](docs/platforms.md#ubuntu-and-debian-apt).
- **Windows:** `install` offers to upgrade Git for Windows (default No; no terminal: `--upgrade-git`) with winget or the pinned, checked installer: [docs/platforms.md](docs/platforms.md#upgrading-git-for-windows).
- **macOS:** `install` shows its plan and offers to upgrade git with Homebrew (default No; no terminal: `--upgrade-git`): `brew upgrade git` for an older Homebrew git, `brew install git` when there is none, run as you, never with `sudo`. A new enough Homebrew git that is not first on `PATH` gets the exact `export PATH=...` line instead (no shell profile is edited). Apple's `/usr/bin/git` cannot be replaced (SIP), so GUI clients that use it are still not scanned. See [docs/platforms.md](docs/platforms.md#macos-homebrew).

## Install

Git Bash, Linux or macOS:

```bash
git clone <this repository> && cd git-secret-guard
bin/git-secret-guard install
```

PowerShell or cmd on Windows:

```powershell
git clone <this repository>
cd git-secret-guard
bin\git-secret-guard.cmd install
```

This puts trufflehog and betterleaks in `~/.local/bin` (on Windows `%USERPROFILE%\.local\bin`, as `.exe` files) at the versions pinned in `tools.lock`. A tool already at the
pinned version is kept; otherwise it is downloaded and its SHA-256 checked, and a file install did not place there
is moved aside, never overwritten. Install also puts the `git-secret-guard` command into `~/.local/bin` (keep it on
your `PATH`; on Windows it works from Git Bash, PowerShell and cmd alike), copies the package to `~/.local/share/git-secret-guard`, and adds the hook to your global git config.
If you already have a global `core.hooksPath`, install refuses; `install --replace-hooks-path` backs it up and takes
it over. To upgrade, run `install` again from a newer checkout; a machine installed by the earlier build that used
**gitleaks** is upgraded the same way (the gitleaks that build placed is removed, yours is restored). Details:
[docs/install.md](docs/install.md).

## Use

```bash
git commit ...                          # scanned automatically
git-secret-guard status                 # what is installed, and whether commits can still be scanned
git-secret-guard doctor                 # which repositories under your home directory are not protected, and why (records the PROBLEMs)
git-secret-guard doctor --recheck       # re-check only the recorded PROBLEMs, no search
git-secret-guard uninstall              # restore what was there before (--remove-tools: also the scanners it downloaded)
```

These are the same in every shell. On Windows, commits are scanned from Git Bash, PowerShell, cmd and GUI clients that
use a git 2.54 or newer.

A blocked commit lists the scanner, rule, file and line of each finding, never the secret itself. A passing commit prints
one summary line (plus any exemption notices and the reminder below), so a clean scan can be told from a hook that never ran:

```
git-secret-guard: scanned 3 files, 214 added lines (trufflehog 3.99.2, betterleaks 1.9.0): no findings, 1s
git-secret-guard: no added lines to scan                      # only deletions, binary files, mode changes, an empty commit
git-secret-guard: scanned 3 files, ..., no findings, 2 files exempted, 1s   # .secret-scan-ignore excluded staged files
```

No line at all on a commit means the hook did not run (see `docs/scan.md`). The counts come from the extraction, the line
holds no path or value, and there is no switch to turn it off.

While `doctor` has coverage problems on record (a repository with the hook switched off, a broken tool), every commit
also ends with a reminder, until they are fixed. The commit itself is never affected:

```
git-secret-guard: 1 coverage problem still open (doctor run 2026-11-03):
  /home/me/Dev/legacy: disabled in local config: hook.git-secret-guard.enabled=false (...); remove that key to cover this repository
  run git-secret-guard doctor for the full report
```

Details: [docs/scan.md](docs/scan.md#the-coverage-reminder).

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

- Commits made with git older than 2.54 are not scanned (check the git your IDE or GUI client bundles; for SmartGit see [docs/smartgit.md](docs/smartgit.md)).
- Only `pre-commit` runs the scan: automatic merge commits, cherry-picks, rebases and `git am` are not scanned (a merge
  finished with `git commit` is).
- Binary files, including UTF-16 text, are not scanned. On Windows that matters more than elsewhere: Windows PowerShell 5.1 can write UTF-16 with `>` and `Out-File`, so a secret saved that way is invisible to the scan.
- A staged Git LFS pointer is followed to its object in the local LFS storage and that content is scanned; a commit whose object is missing, does not match the pointer or was transformed by a Git LFS extension is blocked, never passed unscanned ([docs/scan.md](docs/scan.md#limits)).
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
| [docs/platforms.md](docs/platforms.md) | supported platforms, setup on Windows, macOS and Ubuntu, the container tests |
| [docs/smartgit.md](docs/smartgit.md) | using SmartGit with a git 2.54 or newer instead of its bundled git (macOS, Linux tarball or package, Linux Flatpak, Windows), and installing Git LFS |
| [CONTRIBUTING.md](CONTRIBUTING.md) | development setup on every platform, running the tests, rules for changes, signing off commits |
| [DCO.txt](DCO.txt) | the Developer Certificate of Origin 1.1 that every commit's `Signed-off-by:` line refers to |
| [SECURITY.md](SECURITY.md) | how to report a vulnerability privately, and what to expect |
| [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) | the third-party components `install` downloads, with version, license and copyright |

## Maintainers

[jsbattig](https://github.com/jsbattig) (Lightspeed DMS) and [juanpio](https://github.com/juanpio) maintain git-secret-guard and are responsible for its
issues, reviews and releases. To contribute, read [CONTRIBUTING.md](CONTRIBUTING.md); to report a vulnerability, follow
[SECURITY.md](SECURITY.md) and do not open a public issue.
