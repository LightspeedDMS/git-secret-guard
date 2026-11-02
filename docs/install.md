# Install, upgrade and uninstall

```bash
git clone <this repository> && cd git-secret-guard
bin/git-secret-guard install        # also the upgrade: run it again from a newer checkout
git-secret-guard status             # what is installed, and whether the global config still matches
git-secret-guard doctor             # which repositories are not protected, and why (read-only, see below)
bin/git-secret-guard install --with-timer   # optional: also run doctor weekly through a systemd user timer
git-secret-guard uninstall          # put back what was there before
```

**Requirements.** Linux on x86_64 or arm64, or macOS arm64 with Homebrew (macOS x86_64 is mapped, not tested). bash,
**git >= 2.54 first on `PATH`**, `jq`, `setsid`, `timeout`, and `curl` plus `tar` when a scanner has to be downloaded. On
macOS, `install` lists whichever of bash 4.4 or newer, `coreutils` (`timeout`), `util-linux` (`setsid`) and `jq` is missing, installs them
with `brew install` only after its other checks have passed, the `tools.lock` lookup included (with a GNU `timeout` already present, the scanner
downloads are verified first too; under the system bash 3.2 it first installs `bash` alone), and refuses, changing
nothing, when Homebrew is not on `PATH`: details in
[platforms.md](platforms.md#macos-homebrew). `install` refuses when the git on `PATH` is older than 2.54, because older git
ignores config hooks without any message.

> **Warning, `/usr/bin/git` 2.52.** Any git older than 2.54 ignores config hooks: no error, no scan. `install` warns
> for every other reachable git older than 2.54 (all `git` on `PATH` plus `/usr/bin/git`; on this machine
> `/usr/bin/git` is 2.52) and goes on, because the git that matters is the one your commits run. Commits made with the
> old one are **not scanned**; call `/usr/local/bin/git` (or put it first on `PATH`) wherever you commit.

## What `install` does

| Step | Result |
|---|---|
| Prechecks | git >= 2.54 on `PATH`, `jq`, `setsid`, `timeout` found (their **absolute paths** are written to the settings file, the hook never resolves them through `PATH`), Linux, absolute `HOME`/`XDG_*`. Any refusal happens before anything is changed. |
| Scanners | `~/.local/bin/trufflehog` and `~/.local/bin/gitleaks`. A tool that already reports the pinned version (`trufflehog` 3.99.2, `gitleaks` 8.30.1) is **kept**. Otherwise the platform tarball is downloaded from the vendor's GitHub release, its **SHA-256 is checked against `tools.lock`**, only the tool binary is extracted, and its `--version` is checked against the pin. A checksum mismatch deletes the download, installs nothing (neither scanner) and refuses. curl runs with `-q` as its first argument, so a `~/.curlrc` (proxy, protocol, output or `head` settings) cannot change a verified download. **A file already at that path that does not report the pinned version (your own build, a symlink, an older release) is never overwritten:** it is moved aside to `<tool>.gsg-replaced-<UTC stamp>` in the same directory (byte-identical, same mode), the output says where, and the state records the aside name with the SHA-256 of what install put in its place. Such a tool is never recorded as downloaded by install, so it is never "ours to delete". Install also records the SHA-256 of **every** file it places (`tools_placed` in the state), also on an empty path. On an upgrade that bumps the pins, a file that still has that hash is install's own and is **replaced in place** (no aside file, and a downloaded tool stays removable with `--remove-tools`); only a file install did not place is moved aside, and the first original ever moved aside is the one uninstall restores. The aside names and hashes are written to the state **before** the file is moved, so a failure afterwards (state write, second tool, share dir) cannot lose the original: a later uninstall, or a rerun of install, still finds it. |
| Files | `hooks/`, `lib/`, `bin/`, `tools.lock`, `VERSION` copied to `${XDG_DATA_HOME:-~/.local/share}/git-secret-guard/` (the new tree is built beside the old one and swapped in, so a commit during an upgrade sees the old or the new hook, never half of either; if the final rename fails, the previous tree is moved back, so the share dir is never left missing), plus the generated `settings` file with absolute `TRUFFLEHOG_BIN`, `GITLEAKS_BIN`, `JQ_BIN`, `SETSID_BIN`, `TIMEOUT_BIN`, the pinned `TRUFFLEHOG_VERSION` and `GITLEAKS_VERSION` (the hook prints them on a passing commit) and `SCAN_TIMEOUT_SECONDS=300` (on macOS also the absolute `BASH_BIN` and `GNUBIN_DIR`). `settings` is rewritten by every install. |
| Global git config | `hook.git-secret-guard.event=pre-commit` and `hook.git-secret-guard.command=<absolute path of the installed hooks/secret-scan>`, written with `git config --global --replace-all`, so each stays single-valued however often you run `install`. On macOS the command is `'<recorded bash>' '<installed hooks/secret-scan>'`, so the hook runs under bash 4.4 or newer whatever `PATH` the git client has. |
| CLI | `~/.local/bin/git-secret-guard` is a symlink to the installed copy. Make sure `~/.local/bin` is on your `PATH`. |
| Timer | Only with `--with-timer`: two systemd **user** units and `systemctl --user enable --now git-secret-guard-doctor.timer`, see [The weekly timer](doctor.md#the-weekly-timer). Without the flag no unit is written and `systemctl` is never called. On macOS the flag is refused (`launchd is not supported yet`) and nothing is changed. |
| State | `${XDG_STATE_HOME:-~/.local/state}/git-secret-guard/state` (mode 600 in a 700 directory): version, the previous `core.hooksPath` (or `unset`), which tools install itself downloaded, the backup path, and `timer_installed` (`yes` or `no`). |

Install is idempotent. A second run replaces the files, keeps the config single-valued, downloads nothing that is
already at the pin, and **never overwrites a recorded previous `core.hooksPath`** or forgets which tools it downloaded.
Running it from the installed copy (`git-secret-guard install`) re-installs that copy.

## An existing global `core.hooksPath`

A global `core.hooksPath` is what this package replaces, so `install` **refuses** when one is set (it prints the value
and changes nothing). To take it over:

```bash
bin/git-secret-guard install --replace-hooks-path
```

This records the value **verbatim** in the state (a `~/.config/git/hooks` stays `~/.config/git/hooks`, it is not
expanded), packs the directory it resolves to into
`${XDG_STATE_HOME:-~/.local/state}/git-secret-guard/hooks-path-backup-<UTC time>.<random>.tar.gz` (mode 600, location
printed and recorded in the state), and unsets the global setting. **The old directory is left in place.** A
`core.hooksPath` that is relative, has several values or contains a newline is refused, because there is no single
directory to back up or record. If the directory does not exist there is nothing to back up and the install goes on.

- **Only the recorded value can be taken over again.** When the state already records a value and the global value
  now differs, install refuses (the recorded value differs from the global one: both values are printed, nothing
  is changed, no tarball is made). Run `uninstall` (it keeps the current value and the backup tarballs) and then
  `install --replace-hooks-path` to record the new one. Taking over the same value again is fine and makes a second
  tarball.
- **Values git reads from other files are found too.** `git config --global` reads only the one file it edits, but a
  `core.hooksPath` in the XDG config (`$XDG_CONFIG_HOME/git/config`, read next to `~/.gitconfig`) or in a file pulled
  in with `[include]` or `[includeIf]` still applies with global scope. Install looks at the effective config from a
  directory that is no repository, and also reads every include target as if its condition held (`includeIf "gitdir:..."`
  and `onbranch:` conditions only exist inside a repository, so git cannot show them from outside; at most 64 files
  are read, more is a refusal). A value found in a file install does not write to is refused **even with
  `--replace-hooks-path`**, naming the file, because install could neither record nor unset it. Install never writes
  into an included file, and a symlinked `~/.gitconfig` stays a symlink (the write goes to its target).
- **Limits of the include walk.** Include paths that begin with `~user/` (another user's home) or `%(prefix)/` are not
  expanded by the walk, so a `core.hooksPath` behind such an include is not found when git does not show it either
  (git itself does expand them, and those that apply outside a repository are reported by the effective-config
  listing). A relative include written inside a symlinked included file is resolved by git against the directory of the
  path as written (the symlink's directory), but by the walk against the file's real directory, so for a conditional
  include behind a symlink the two can differ. Both are limits of the conservative walk, not guarantees.
- **Which file, and why a read failed.** When `GIT_CONFIG_GLOBAL` is set, install, uninstall and status print a one-line
  note naming the file they use. If the global config cannot be read, the message carries git's own first error line,
  and names `GIT_CONFIG` when that variable is set (it makes `git config --global` refuse with exit 129).
- **The backup is bounded.** A `core.hooksPath` that resolves to your home directory or `/`, to a directory over 50 MB
  (52428800 bytes) or to one holding more than 10000 files is refused before anything changes, so a mistaken `~`
  cannot be archived into the state directory.

## Pinned tools: `tools.lock`

`tools.lock` holds one line per tool and platform: name, version, platform, SHA-256 of the vendor's release tarball
(the vendors' checksums, fetched 2026-10-30; vendors name platforms differently, `linux_amd64` against `linux_x64`).
Linux x86_64 and arm64 and macOS arm64 are used; the macOS x86_64 rows are mapped but not tested. A lock that is unreadable, malformed
or ambiguous (two rows for one tool and platform) is refused as a whole, and a missing row is a refusal, never a skip.

**Test-only overrides.** `GSG_TOOLS_BASE_URL` (a directory URL such as `file:///tmp/fixtures`, tarballs named like the
vendor's) and `GSG_TOOLS_LOCK` (a lock file) let the test suite install from local fake tarballs. They are announced
on stderr (`TEST OVERRIDE active`) and **cannot skip verification**: every download is still verified against *some*
lock, and the checksum has to match, so an override alone only changes where the tarball comes from or which lock is
trusted. Without the base-URL variable curl is restricted to `https` (`--proto =https`, also across redirects). Do not
set either in production: they change which lock you trust and where you download from.

## Uninstall

```bash
git-secret-guard uninstall                 # keeps the scanners
git-secret-guard uninstall --remove-tools  # also removes the scanners that install itself downloaded
```

Removes the `hook.git-secret-guard` section from the global config, restores the recorded previous `core.hooksPath`
**verbatim** (or leaves it unset when none was recorded), and removes the share dir, the CLI link and the state file.
`trufflehog` and `gitleaks` stay unless `--remove-tools` is given; then only the ones the state lists as downloaded by
install onto an empty path are removed (`--remove-tools` has to be given on the run that removes the state, since the
record is gone afterwards). A tool is deleted only when it is a regular file whose SHA-256 is one install recorded for
it. Your own build of the same version, a symlink, or any file install cannot prove it placed (for instance when the
state comes from an older install that recorded no hashes) stays, and uninstall says `<path> is not the file install put
there; left in place` (or that no hash was recorded).

- **Your own scanner comes back.** A file install moved aside as `<tool>.gsg-replaced-<UTC stamp>` is moved back over
  the tool install put there, on every uninstall, with or without `--remove-tools`: same bytes, same mode. This happens
  only while the path still holds exactly the file install last placed (its recorded `tools_placed` SHA-256) or nothing. The **first** original ever moved aside is the one restored; if a later file of yours had to be moved aside too, it is only reported and kept. If you
  changed it since (or made it a symlink), it is left alone, the original stays aside, and the message says where. A
  missing original is reported and the tool at the path is left, never deleted. If an install stopped before it moved
  your file (the state is written first), uninstall says `the planned move of <path> never happened; it is still in
  place`: your file never left its path. After an interrupted upgrade both the old and the new hash of a tool count as
  install's own until a rerun confirms the placement, so install never mistakes its own half-upgraded file for yours. A scanner install did not replace is
  never touched.
- **Order.** The recorded `core.hooksPath` is restored first and the `hook.git-secret-guard` section is removed after
  it. If git refuses the restore, uninstall stops with `core.hooksPath not restored`, the hook config, share dir and
  state stay, commits stay scanned, and running `uninstall` again finishes the job.

- **The backup is kept.** Uninstall removes the state *file* but not the state directory when it still holds
  `hooks-path-backup-*.tar.gz`; it prints the tarball's location. It is the safety net for your old hooks directory.
- A `core.hooksPath` that was set again after install is **not overwritten** by the recorded one (a notice is printed).
  Without a state file the global `core.hooksPath` is left alone, because nothing says what it used to be.
- A link or file at `~/.local/bin/git-secret-guard` that install did not create is left in place and reported.
- A second run reports `nothing to do, git-secret-guard is not installed` and exits 0. A malformed state file is
  refused with nothing changed.
- **The weekly timer** (only when the state records `timer_installed=yes`) is disabled and removed right after the hook
  config and before the share dir: [the details are in the doctor chapter](doctor.md#the-weekly-timer). Without a recorded timer,
  uninstall never calls `systemctl`.

## `status` and `version`

`git-secret-guard status` prints the installed version, hook command path, whether the global config matches, the
recorded previous `core.hooksPath`, the **effective** `core.hooksPath` (every global-scope value with the file it
lives in, also from the XDG config and included files; informational, config hooks run whatever it says), the backup
path, the tools installed by us, the originals install moved aside, and each tool's path with its detected and
pinned version. A tool counts as `ok` only when it reports the pinned version the way install judges it (the version
as a whole word, or with a `v` prefix), so `8.30.1-rc1` is a `MISMATCH` here exactly as install would replace it. It exits 0 when everything matches and 1 when it is not installed or a line says `MISMATCH` or
`MISSING`. `git-secret-guard version` prints `git-secret-guard <x.y.z>`. `git-secret-guard help` lists the commands. `status` looks at the installation only; the repositories are the job
of [`doctor`](doctor.md).
