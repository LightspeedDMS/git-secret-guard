# Install, upgrade and uninstall

Every command below works the same in Git Bash on Windows. From PowerShell or cmd, a checkout uses
`bin\git-secret-guard.cmd` in place of `bin/git-secret-guard`, and once installed plain `git-secret-guard` works there too.

```bash
git clone <this repository> && cd git-secret-guard
bin/git-secret-guard install        # also the upgrade: run it again from a newer checkout
git-secret-guard status             # what is installed, and whether the global config still matches
git-secret-guard doctor             # which repositories are not protected, and why (read-only except its findings record, see below)
bin/git-secret-guard install --with-timer   # optional: also run doctor weekly (systemd user timer, a LaunchAgent on macOS; on Windows see doctor.md)
git-secret-guard uninstall          # put back what was there before
```

**Requirements.** Linux on x86_64 or arm64, macOS arm64 with Homebrew (macOS x86_64 is mapped, not tested), or Windows x86_64 with Git for Windows (details in [platforms.md](platforms.md#windows-git-for-windows): there `install` downloads a missing `jq`, and `taskkill` replaces `setsid`). bash 4.4 or newer,
**git >= 2.54 first on `PATH`**, `jq`, `setsid`, `timeout`, and `curl` plus `tar` when a scanner has to be downloaded. On
macOS, `install` lists whichever of bash 4.4 or newer, `coreutils` (`timeout`), `util-linux` (`setsid`) and `jq` is missing, installs them
with `brew install` only after its other checks have passed, the `tools.lock` lookup included (with a GNU `timeout` already present, the scanner
downloads are verified first too; under the system bash 3.2 it first installs `bash` alone), and refuses, changing
nothing, when Homebrew is not on `PATH`: details in
[platforms.md](platforms.md#macos-homebrew). Older git ignores config hooks without any message, so when the git on `PATH` is older
than 2.54 or missing, `install` offers to upgrade it on RHEL, Rocky, AlmaLinux and Fedora (see
[platforms.md](platforms.md#rhel-rocky-and-fedora-rpm)), on Ubuntu and Debian (see [platforms.md](platforms.md#ubuntu-and-debian-apt)) and on macOS (see [platforms.md](platforms.md#macos-homebrew)) and on Windows (see [platforms.md](platforms.md#upgrading-git-for-windows)).
If you decline, and on every other platform, it refuses and prints how to get a newer git.

> **Warning, old git.** On Windows, check the git your IDE or GUI client bundles: it is often not the one on `PATH`. The
> example below is the RHEL host, where `/usr/bin/git` is 2.52.
>
> Any git older than 2.54 ignores config hooks: no error, no scan. `install` warns
> for every other reachable git older than 2.54 (all `git` on `PATH` plus `/usr/bin/git` and the git GitHub Desktop bundles at `/usr/lib/github-desktop/resources/app/git/bin/git`, for which the warning says only that whether its commits are scanned has not been tested; on this machine
> `/usr/bin/git` is 2.52) and goes on, because the git that matters is the one your commits run. Commits made with the
> old one are **not scanned**; call `/usr/local/bin/git` (or put it first on `PATH`) wherever you commit. On RHEL, Rocky and
> AlmaLinux, `install --take-over-system-git` points an old package `/usr/bin/git` at the new build, which also covers cron
> jobs and scripts that call it by full path (undo: `restore-system-git`).

## What `install` does

| Step | Result |
|---|---|
| Prechecks | git >= 2.54 on `PATH`, `jq`, `setsid` (`taskkill` on Windows), `timeout` found (their **absolute paths** are written to the settings file, the hook never resolves them through `PATH`), a supported platform, absolute `HOME`/`XDG_*`. A refusal happens before anything is changed, with two exceptions: after a git upgrade you accepted, and on a Mac where the system bash 3.2 first needs `brew install bash`. In both cases the refusal says what changed. |
| Git upgrade | Only on RHEL, Rocky, AlmaLinux and Fedora (see [platforms.md](platforms.md#rhel-rocky-and-fedora-rpm)), on Ubuntu and Debian (see [platforms.md](platforms.md#ubuntu-and-debian-apt)) and on macOS with Homebrew (see [platforms.md](platforms.md#macos-homebrew)) and on Windows (see [platforms.md](platforms.md#upgrading-git-for-windows)), and only if you agree at the prompt (default No) or pass the flag. Every other platform keeps the refusal, which prints how to get a newer git. `--upgrade-git` handles an old or missing git, or a build of ours older than the pin; `--take-over-system-git` (RPM systems only; refused on Ubuntu and Debian, a note that changes nothing on macOS) handles an old package git left in `/usr/bin`. The plan, with every privileged command, is printed first. |
| Scanners | `~/.local/bin/trufflehog` and `~/.local/bin/betterleaks` (`trufflehog.exe` and `betterleaks.exe` on Windows, where a missing `jq` is downloaded the same way as `jq.exe`). A tool that already reports the pinned version (`trufflehog` 3.99.2, `betterleaks` 1.9.0) is **kept**. Otherwise the platform tarball is downloaded from the vendor's GitHub release, its **SHA-256 is checked against `tools.lock`**, only the tool binary is extracted, and its `--version` is checked against the pin. A checksum mismatch deletes the download, installs nothing (neither scanner) and refuses. curl runs with `-q` as its first argument, so a `~/.curlrc` (proxy, protocol, output or `head` settings) cannot change a verified download. **A file already at that path that does not report the pinned version (your own build, a symlink, an older release) is never overwritten:** it is moved aside to `<tool>.gsg-replaced-<UTC stamp>` in the same directory (byte-identical, same mode), the output says where, and the state records the aside name with the SHA-256 of what install put in its place. Such a tool is never recorded as downloaded by install, so it is never "ours to delete". Install also records the SHA-256 of **every** file it places (`tools_placed` in the state), also on an empty path. On an upgrade that bumps the pins, a file that still has that hash is install's own and is **replaced in place** (no aside file, and a downloaded tool stays removable with `--remove-tools`); only a file install did not place is moved aside, and the first original ever moved aside is the one uninstall restores. The aside names and hashes are written to the state **before** the file is moved, so a failure afterwards (state write, second tool, share dir) cannot lose the original: a later uninstall, or a rerun of install, still finds it. |
| Files | `hooks/`, `lib/`, `bin/`, `tools.lock`, `VERSION` copied to `${XDG_DATA_HOME:-~/.local/share}/git-secret-guard/` (the new tree is built complete beside the old one and swapped in with two renames, old out, new in, so a commit during an upgrade runs the old or the new hook, never half of either; in the instant between the two renames the hook path is missing and a commit started then fails. If the second rename fails the previous tree is moved back; if that fails too, the message names where it is, `<share>.old.XXXXXX/previous`), plus the generated `settings` file with absolute `TRUFFLEHOG_BIN`, `BETTERLEAKS_BIN`, `JQ_BIN`, `SETSID_BIN`, `TIMEOUT_BIN`, the pinned `TRUFFLEHOG_VERSION` and `BETTERLEAKS_VERSION` (the hook prints them on a passing commit) and `SCAN_TIMEOUT_SECONDS=300` (on macOS also the absolute `BASH_BIN` and `GNUBIN_DIR`; on Windows `TASKKILL_BIN` in place of `SETSID_BIN`, and `JQ_BIN` names a small wrapper in the share dir). `settings` is rewritten by every install. |
| Global git config | `hook.git-secret-guard.event=pre-commit` and `hook.git-secret-guard.command=<absolute path of the installed hooks/secret-scan>`, written with `git config --global --replace-all`, so each stays single-valued however often you run `install`. On macOS the command is `'<recorded bash>' '<installed hooks/secret-scan>'`, so the hook runs under bash 4.4 or newer whatever `PATH` the git client has. On Windows the path is in the mixed form `C:/Users/...`, the form native git keeps. |
| CLI | `~/.local/bin/git-secret-guard` is a symlink to the installed copy. On Windows it is a small wrapper script instead, next to `git-secret-guard.cmd` for PowerShell and cmd. Make sure `~/.local/bin` is on your `PATH`. |
| Timer | Only with `--with-timer`: two systemd **user** units and `systemctl --user enable --now git-secret-guard-doctor.timer`, see [The weekly timer](doctor.md#the-weekly-timer). Without the flag no unit is written and `systemctl` is never called (when the state already records a timer, its own units or plist are only refreshed if their text changed, never enabled). On macOS the flag installs a LaunchAgent plist in `~/Library/LaunchAgents` and loads it with `launchctl bootstrap gui/<uid>`, see [the launchd section](doctor.md#the-weekly-timer-on-macos-launchd). Windows has no `--with-timer`: see [the Task Scheduler recipe](doctor.md#a-weekly-run-on-windows-task-scheduler). In WSL `--with-timer` needs systemd running and is refused before any change without it, see [WSL](platforms.md#wsl-windows-subsystem-for-linux). |
| State | `${XDG_STATE_HOME:-~/.local/state}/git-secret-guard/state` (mode 600 in a 700 directory): version, the previous `core.hooksPath` (or `unset`), which tools install itself downloaded, the backup path, and `timer_installed` (`yes` or `no`). |

Install is idempotent. A second run replaces the files, keeps the config single-valued, downloads nothing that is
already at the pin, and **never overwrites a recorded previous `core.hooksPath`** or forgets which tools it downloaded.
Running it from the installed copy (`git-secret-guard install`) re-installs that copy.

### Upgrading from the gitleaks build

Earlier versions installed **gitleaks** as the second scanner; it is **betterleaks** now (gitleaks is in
security-patch-only mode, and its author moved to betterleaks). Running `install` from the new checkout upgrades a
machine the old build installed, in this order (the new hook and settings are live before anything is removed, so a
commit during the upgrade is never left without a scanner):

- betterleaks 1.9.0 is downloaded, checked against `tools.lock` and placed like any scanner, and the settings file is
  rewritten with `BETTERLEAKS_BIN` and `BETTERLEAKS_VERSION` and **no** `GITLEAKS_*` key.
- A `~/.local/bin/gitleaks` that the old install placed (its SHA-256 is in the state's `tools_placed`) is **removed**,
  and the line `removed ~/.local/bin/gitleaks (placed by an earlier install; ...)` says so.
- If the old install had moved **your own** gitleaks aside (`gitleaks.gsg-replaced-<UTC stamp>`), it is moved **back**
  onto the empty path, byte for byte with its mode, and the record of the move is dropped.
- A `gitleaks` at that path that is **not** the file the old install placed (you replaced it since) is never deleted:
  install prints `... is not the file an earlier install placed; left in place` and keeps the aside record.
- The state drops the gitleaks entries it settled (`tools_installed_by_us`, `tools_placed`, and the aside record of a
  restored original). An aside record whose original stays aside (the foreign file case above, or a second aside file
  after the first was restored) is kept, so `uninstall` can still report it.

`uninstall` after the upgrade returns the machine to its state before the first install. `uninstall` also accepts a
state file the gitleaks build wrote (it still restores your moved-aside gitleaks and, with `--remove-tools`, removes
the one the old install placed), so you can uninstall without upgrading. Your repositories' exemptions need no change:
`.gitleaks.toml`, `.gitleaksignore` and `gitleaks:allow` mean the same thing, see [Exemptions](exemptions.md).

## Upgrading an old git: `--upgrade-git` and `--take-over-system-git`

On a system whose class has an upgrade module (RHEL, Rocky, AlmaLinux, CentOS and Fedora: [the RPM section of platforms.md](platforms.md#rhel-rocky-and-fedora-rpm);
Ubuntu, Debian and their derivatives: [the apt section](platforms.md#ubuntu-and-debian-apt); macOS: `brew install git` or `brew upgrade git` as your user, no takeover since `/usr/bin/git` is protected, [the macOS section](platforms.md#macos-homebrew); Windows: [Upgrading Git for Windows](platforms.md#upgrading-git-for-windows)), `install` no longer stops at an old or missing git. It
finishes every other check first (`jq`, `setsid`, `timeout`, `core.hooksPath`, the CLI link, the platform), reports their problems together, and only then offers
the upgrade, so a run that would be refused anyway changes nothing. An old git can still read the config, so the `core.hooksPath` checks run before the upgrade;
with no git at all they run right after it.

| Offer | Asked when | If you decline, or there is no terminal and no flag |
|---|---|---|
| Upgrade git | git is missing or older than 2.54 | install refuses as before and names `--upgrade-git`; nothing changed |
| Rebuild | the git first on `PATH` is a build of ours (listed in a `MANIFEST`) older than the git `tools.lock` pins | git is left as it is and install continues |
| Take over the system git | an old package git (`/usr/bin/git`) remains next to a qualifying build of ours | nothing changes in `/usr/bin`, no dnf config is written, install continues |

- **Consent.** `--upgrade-git` answers yes to the first two; `--take-over-system-git` answers yes to the third (each offer names its flag). In a terminal install
  prints the plan, with every privileged command, and asks `[y/N]`; the default is No. It prompts only when stdin **and** stderr are terminals,
  so a script, cron or CI never hangs. Without a terminal and without the flag it prints the flag and goes on.
- **Umask.** `install` tightens its umask to at least `022` (a stricter one of yours, such as `077`, is kept), so the settings file the hook sources, the share tree, the CLI link and the state do not depend on the caller (WSL 1 starts every shell at `umask 000`).
- **Privileges.** Privileged steps run directly as root, or through `sudo`, under `umask 022`; every privileged tool is looked up only in the fixed
  system path (`/usr/bin:/bin:/usr/sbin:/sbin`) and must be root-owned and not writable by group or others, and the plan prints the full path of each. With neither root nor
  sudo, install prints the commands to run as root that can be typed by hand (the copy from the build directory cannot, and the message says so) and changes nothing. On Ubuntu, the PPA route, and any case where a PPA has to be moved aside, cannot be typed by hand: there install says to run it as root instead (see [platforms.md](platforms.md#ubuntu-and-debian-apt)).
- **After the upgrade** install reads `PATH` again; a git still older than 2.54 (for example the new git is not first on `PATH`) is a refusal that gives the exact
  `export PATH=...` line for the directory of the git the module installed (`/usr/bin` for the package route, `/usr/local/bin` for the source route; no shell
  profile is edited). Every refusal after the upgrade says what the upgrade changed, as it does after a Homebrew install on macOS.
- **A rerun does nothing to git:** a git that qualifies, at the pin or not a build of ours, with no old package git behind it, means no prompt, no download of git and no
  `sudo`, `dnf` or `make` call.
- **Exit status 3** is reserved for a module that must finish the upgrade outside the install process; install stops, prints the next step and changes nothing else.
  Windows uses it: the upgrade replaces the bash install runs in, so `git-secret-guard.cmd` runs it after bash has ended and then runs your command again; from Git Bash
  you get the exact PowerShell command instead.
- **Windows has no `sudo`:** the plan says whether the upgrade is machine-wide (a UAC prompt unless the prompt is already elevated) or per-user, and never switches one into the
  other. A declined UAC prompt should stop the upgrade before the installer starts (the runner handles that case; a person has not yet declined the real dialog). The IDE and GUI client warning above still applies: the upgrade changes the Git for Windows your `PATH` finds, not the git
  an IDE bundles.
- **Takeover.** `git-secret-guard restore-system-git` undoes it from the saved originals without a network. `uninstall` stops while a takeover is active
  (it would take the restore command with it) and names `restore-system-git` and `uninstall --keep-system-git`. `status` and `doctor` report the takeover, and one that
  something else undid, which leaves commits through `/usr/bin/git` unscanned.
- The install warning about another old git now also names the git in use, and (where the takeover exists) that cron jobs and scripts calling it by full path are not scanned.

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
  (52428800 bytes, the sum of the `lstat` sizes of every entry below it) or to one holding more than 10000 files
  (every entry counts: files, directories and symlinks) is refused before anything changes, so a mistaken `~`
  cannot be archived into the state directory.

## Pinned tools: `tools.lock`

`tools.lock` holds one line per tool and platform: name, version, platform, SHA-256 of the vendor's release tarball
(the vendors' checksums, fetched 2026-10-30; vendors name platforms differently, `linux_amd64` against `linux_x64`).
Linux x86_64 and arm64, macOS arm64 and Windows x86_64 are used; the macOS x86_64 rows are mapped but not tested. The `jq` row is Windows only: elsewhere `jq` is a system prerequisite. A lock that is unreadable or has a
malformed line anywhere is refused as a whole; two rows for the tool and platform being looked up are refused as
ambiguous (duplicates for another platform are not looked at), and a missing row is a refusal, never a skip.

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
**verbatim** (or leaves it unset when none was recorded), and removes the share dir, the CLI link and the state file, together with doctor's findings record (`findings`), its
leftover `findings.XXXXXX` temp files. Uninstall takes `findings.lock` **before it changes anything** (a dead or old lock is
taken over). When a live doctor run holds it, uninstall changes nothing (the hook section, the CLI link, the share dir and
the state all stay), exits 1 and says to run `git-secret-guard uninstall` again; the installed CLI is still there, and the
rerun finishes once the run is gone.
`trufflehog` and `betterleaks` (on Windows also a `jq.exe` install downloaded) stay unless `--remove-tools` is given; then only the ones the state lists as downloaded by
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
  config and before the share dir (on macOS the LaunchAgent is booted out and its plist removed at the same point):
  [the details are in the doctor chapter](doctor.md#the-weekly-timer). Without a recorded timer,
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

## Maintainer notes

- **`git config` exit codes** (2.56): a plain set exits 5 on a multi-valued key (hence `--replace-all`); `--get-all` exits 1
  when the key is absent and also when `GIT_CONFIG_GLOBAL` is a directory; `--global --list` exits 128 for a missing file
  and for a directory, so "unwritable" is probed by setting and removing a `gsg-install-probe` section
  (`install_check_config_writable`). Values are read with `-z --get-all` and stored verbatim. To test "cannot write", make
  the config **directory** unwritable (git writes through a lock file; a read-only file is not enough).
- **Release tarballs**: `trufflehog_<v>_linux_{amd64,arm64}`, `betterleaks_<v>_linux_{x64,arm64}`; betterleaks ships
  `.tar.gz` for Linux and macOS, with checksums in its `checksums.txt`. `tools_version_matches` accepts the pin only as a
  whole word, `v<pin>` or `jq-<pin>`, after dropping carriage returns.
- **jq on Windows** (`install_manage_jq`, after `state_read`): no jq on `PATH`, or `jq:` in `tools_placed`, appends `jq` to
  `GSG_TOOL_NAMES` for this install run only, so lock, staging, ownership and asides come from the scanner path; status and
  doctor keep seeing the two scanners, and `install_write_settings` skips its `_VERSION` key. The asset is a bare `.exe`
  (`tools_extract_binary` copies it). A jq install did not place stays in use. Linux keeps its package-manager hint (no
  silent sudo).
- **Step order** (refusable steps before any lasting change; exceptions: the macOS `brew install bash` bootstrap, the
  config write probe that sets and removes its section, and on a Mac without GNU `timeout` the staging that follows the
  one `brew install`): `install_check_prerequisites`, platform, `core.hooksPath`
  read and refusal, CLI link, config write probe, state, `install_plan_lock`, download + SHA-256 + `--version` into one
  stage, `install_hash_staged`, backup, **state write**, tools, share tree, CLI link, `git config --replace-all`, unset
  `core.hooksPath` **last** (`test_install_keeps_scanning_when_the_final_hooks_path_unset_fails`). Uninstall restores
  `core.hooksPath` **first** (`test_uninstall_restores_core_hooks_path_before_removing_the_hook_config`): never leave a
  machine with neither hook nor `core.hooksPath`.
- **State keys**: `version`, `previous_hooks_path_set`, `previous_hooks_path`, `tools_installed_by_us`, `backup_path`,
  `tools_replaced`, `tools_placed`, `timer_installed`. `state_write` writes all eight; `state_read` still accepts the older
  five- and six-key files and refuses anything odd. A recorded `no` is replaced by a later takeover
  (`test_a_hooks_path_taken_over_after_a_plain_install_is_recorded`); a differing recorded value refuses
  (`install_check_recorded_hooks_path`).
- **Scanner ownership.** `install_owns_file` = the file's hash is in `tools_placed`. `install_write_state pending` records
  the old and the new hash before `install_commit_tools`, `final` keeps the new one. `mv -T -n` is followed by a check of
  both paths (coreutils 8.32 exits 0 when `-n` skips). `uninstall_restore_replaced` validates records with `GSG_ASIDE_RE`
  and `GSG_STATE_TOOL_NAMES`; `uninstall_tools` deletes only regular files whose hash is in `UN_PLACED`. Pin bumps are
  tested in `tests/test_upgrade.sh` (`bump_pins`).
- **Legacy gitleaks.** `GSG_STATE_TOOL_NAMES` (current plus `GSG_LEGACY_TOOL_NAMES`) is what uninstall and doctor validate
  state words against. `install_note_legacy` keeps the legacy placed hashes in `GSG_LEGACY_PLACED` through the pending and
  final writes; `install_retire_legacy_tools` runs last, after the new hook is live, and a failed step returns before the
  clear so the next install retries. The state is rewritten without our hash **before** the user's file is moved back
  (`test_an_interruption_after_the_restore_never_lets_the_rerun_delete_the_users_gitleaks`). Tests:
  `tests/test_legacy_gitleaks.sh`.
- **`core.hooksPath` reader**: `lifecycle_read_hooks_path` (sets only `GSG_HP_*`; `GSG_PREV`/`GSG_PREV_SET` are install's)
  also runs `git -C / config --show-scope --show-origin -z --list`; `hp_walk_includes` reads every include target (bound
  `GSG_HP_MAX_INCLUDES`), `hp_include_target` skips missing targets like git, `hp_report_unresolved` refuses unresolvable
  ones. `lifecycle_realpath_m` works without GNU `realpath -m`; `lifecycle_note_global_config` prints the
  `GIT_CONFIG_GLOBAL` note (every lifecycle test's stderr has it).
- **Backup bounds** (`install_check_backup_bounds`): test `/` only at the resolver level
  (`test_the_resolver_refuses_root_before_anything_could_back_it_up`), never by running install.
- **Download override**: `GSG_TOOLS_BASE_URL` + `GSG_TOOLS_LOCK` cannot skip verification
  (`test_the_base_url_override_cannot_skip_verification`); curl runs with `-q` first and `--proto =https --proto-redir =https`.
- **`/etc/os-release` is data, never sourced** (`install_os_release_field`; `GSG_OS_RELEASE` in tests;
  `test_the_container_script_reads_os_release_as_data`). Hints: `install_os_family`, `install_fix_hint`, `install_git_hint`
  (`tests/test_prerequisites.sh`).
