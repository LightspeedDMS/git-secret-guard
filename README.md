# git-secret-guard

[![tests](https://github.com/LightspeedDMS/git-secret-guard/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/LightspeedDMS/git-secret-guard/actions/workflows/tests.yml?query=branch%3Amain)

A machine-wide git hook that blocks commits containing secrets. Every commit made on the machine has its added lines
and its message scanned by [trufflehog](https://github.com/trufflesecurity/trufflehog) and
[betterleaks](https://github.com/betterleaks/betterleaks) before it is created; any finding blocks the commit.

- **Global and additive.** It is a git config-based hook (git 2.54+), so it covers every repository, including ones cloned
  later, and runs alongside the hooks a repository brings (husky, the pre-commit framework, `.git/hooks`).
- **Fails closed.** A missing tool, a broken setting or a scanner error blocks the commit; it never passes unscanned.
- **Never prints a secret.** Findings name the scanner, rule, file and line, never the value.
- **Pinned, verified tools.** The scanners are downloaded at the versions in `tools.lock` and checked by SHA-256.
- **Coverage report.** `doctor` finds the repositories and git installs on the machine that are not protected, and why.

## Requirements

| Platform | You need | `install` handles |
|---|---|---|
| Linux x86_64 / arm64 | bash, `jq`, `setsid`, `timeout`, `awk`, `curl`, `tar` | an old or missing git on RHEL, Rocky, AlmaLinux, Fedora, Ubuntu and Debian, if you agree |
| macOS arm64 | Homebrew | bash 4.4+, `coreutils`, `util-linux`, `jq` and git, with Homebrew |
| macOS x86_64 (Intel) | Homebrew, set up by hand | the same as arm64 (tested on macOS 12.7.6): [Homebrew on an Intel Mac](docs/platforms.md#homebrew-on-an-intel-mac) |
| Windows x86_64 | [Git for Windows](https://git-scm.com/download/win) | `jq`, and an upgrade of Git for Windows if you agree |
| WSL | as Linux | as Linux; WSL and Windows are separate git setups |

**git 2.54 or newer must be first on `PATH`**: older git ignores config hooks without a word. Tested versions, the git
upgrade per platform and the known platform limits: [docs/platforms.md](docs/platforms.md).

## Quick start

```bash
git clone https://github.com/LightspeedDMS/git-secret-guard.git
cd git-secret-guard
bin/git-secret-guard install --auto-update   # Windows PowerShell or cmd: bin\git-secret-guard.cmd install --auto-update
```

`install` places the pinned scanners and the `git-secret-guard` command in `~/.local/bin` (keep it on your `PATH`) and adds
the hook to your global git config. It refuses to replace an existing global `core.hooksPath` unless you pass
`--replace-hooks-path`. Every flag and step: [docs/install.md](docs/install.md).

**`--auto-update` is the recommended install** (Linux, macOS and Windows): an hourly job of your own user fetches this clone,
fast-forwards it to the newest released tag and installs that, so keep the clone where it is: [how](docs/install.md#auto-update---auto-update-and-update).
Where the job cannot run (WSL without systemd, no `systemctl`, `launchctl` or `schtasks`), install refuses before changing
anything: run plain `install`, and run it again from a newer checkout to upgrade.

## Usage

```bash
git commit ...                      # scanned automatically
git-secret-guard status             # what is installed and what git resolves; exit 1 on any MISMATCH or MISSING
git-secret-guard doctor             # which repositories and gits on this machine are not protected, and why
git-secret-guard uninstall          # restore what was there before
git-secret-guard help               # every command and flag
```

A clean commit prints one line, so a scan that ran can be told from a hook that never ran:

```
git-secret-guard: scanned 2 files, 3 added lines (trufflehog 3.99.2, betterleaks 1.9.0): no findings, 2s
```

A blocked commit lists each finding without its value. While `doctor` has a coverage problem on record, each commit also
ends with a reminder such as `1 coverage problem still open`; it never changes the commit's outcome.
Output, settings and internals: [docs/scan.md](docs/scan.md); the coverage report: [docs/doctor.md](docs/doctor.md).

## False positives

| To skip | Do this |
|---|---|
| Paths | Add `<glob>  # <reason>` lines to `.secret-scan-ignore` at the repository root |
| One line | Put `trufflehog:ignore gitleaks:allow` on it (each marker mutes only its own tool) |
| betterleaks rules or findings | Commit a `.gitleaks.toml` or `.gitleaksignore` |
| One commit | `git commit --no-verify` |

Exemptions are read from the last commit (HEAD), so a commit cannot exempt itself: commit them first.
Details: [docs/exemptions.md](docs/exemptions.md).

## Limits

- Commits made by a git older than 2.54 are not scanned: check the git your IDE or GUI client bundles
  ([SmartGit](docs/smartgit.md), [GitHub Desktop on Linux](docs/install.md#github-desktop-on-linux---link-desktop-git-and-unlink-desktop-git)).
- Git runs no `pre-commit` hook for automatic merges, cherry-picks, rebases and `git am`, so their lines are not scanned, and no
  `commit-msg` hook for reverts, cherry-picks, `git am`, `rebase -i` squash and fixup, tags and notes, so their messages are not.
- Binary files, including UTF-16 text, are not scanned.
- PII is blocked too (US SSN, credit cards, IBAN, phone numbers), with limits: cards and IBANs only when their checksum passes, bare or
  spaced SSNs and phone numbers only next to a keyword on the same line, no email addresses; a `.gitleaks.toml` at HEAD turns these
  rules off, and a legitimate value that matches blocks until it is accepted
  ([docs/scan.md#pii-rules](docs/scan.md#pii-rules), [docs/exemptions.md](docs/exemptions.md#accepting-a-pii-false-positive)).
- Scanning is pattern-only: no credential is ever tested against a vendor, so every match blocks, real or not (a fake token in a
  test fixture does too). Accept a false positive with a committed `.secret-scan-ignore` entry or the inline markers
  ([docs/exemptions.md](docs/exemptions.md)).
- Each commit costs a few seconds, mostly trufflehog's start-up.

The full list: [docs/scan.md#limits](docs/scan.md#limits).

## Documentation

| Doc | Covers |
|---|---|
| [docs/install.md](docs/install.md) | install, upgrade, uninstall, `status`, the `core.hooksPath` takeover, GitHub Desktop on Linux |
| [docs/scan.md](docs/scan.md) | how a scan runs, its output, the settings file, signals, Git LFS, the scan's limits |
| [docs/exemptions.md](docs/exemptions.md) | `.secret-scan-ignore`, inline markers, betterleaks config, local switches |
| [docs/doctor.md](docs/doctor.md) | the coverage report, its checks and exit status, the weekly timer |
| [docs/platforms.md](docs/platforms.md) | supported platforms and the git upgrade on Linux, macOS, Windows and WSL |
| [docs/smartgit.md](docs/smartgit.md) | using SmartGit with a git 2.54+ instead of its bundled git, and installing Git LFS |
| [docs/platform-testing.md](docs/platform-testing.md) | how each platform is tested: containers, VMs, CI on real platforms, recorded results |
| [docs/bypass-detection-scenarios.md](docs/bypass-detection-scenarios.md) | the bypass and detection scenario catalog and what the hook answers |
| [CONTRIBUTING.md](CONTRIBUTING.md) | development setup, running the tests, rules for changes, signing off commits ([DCO.txt](DCO.txt)) |
| [SECURITY.md](SECURITY.md) | how to report a vulnerability privately |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | how people working on the project treat each other, and how to report a problem privately |
| [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES) | the third-party components `install` downloads |

## License and maintainers

Licensed under the terms in [LICENSE](LICENSE). Maintained by [jsbattig](https://github.com/jsbattig) (Lightspeed DMS) and
[juanpio](https://github.com/juanpio). Report vulnerabilities as described in [SECURITY.md](SECURITY.md), not in a public issue.
