# SmartGit

git-secret-guard scans a commit only when the git that makes the commit is **2.54 or newer** (an older git ignores config hooks without a word, see [the limits](../README.md#limits)). SmartGit runs its own git, so the git on your `PATH` does not decide anything there: **SmartGit has to be pointed at a git 2.54 or newer**, or its commits are not scanned.

SmartGit offers two settings (Preferences, Commands, *Git Executable*; the setup wizard asks the same on first start):

| Setting | Meaning |
|---|---|
| **Bundled Git** | the git shipped inside SmartGit. SmartGit recommends it, and it can be older than 2.54 (the Flatpak of SmartGit 26.1 bundled 2.53.0; it is a different git from the one on your `PATH`). |
| **Other Git Executable** | a git you installed yourself. SmartGit shows the git and Git LFS versions next to the field, and a red cross means it cannot use that executable. |

SmartGit says some of its features may not work correctly without the bundled git. Nothing here was found broken on Linux with the git described below, but that is one machine: see [what was and was not checked](#what-was-and-was-not-checked).

Install git-secret-guard first ([install.md](install.md)), then follow the section for your platform. `git-secret-guard status` must say that commits can be scanned.

## The automatic way: `install --configure-smartgit`

`git-secret-guard install` looks for SmartGit (macOS app, Linux tarball or package, Flatpak, Snap, Windows install directories) and its settings directories, one per major version. `status` and `doctor` report each one with the git it is set to and its version; a SmartGit on a git older than 2.54 is a PROBLEM in `doctor` with the command to run. A settings directory this tool cannot judge (a symbolic link, not yours, or `preferences.yml` not of the recorded shape) is shown as `cannot tell whether SmartGit's commits are scanned`, with the check by hand: in SmartGit, Preferences, Commands, *Git Executable* must be a git 2.54 or newer. `status` still exits 0 for it, because only `MISMATCH` or `MISSING` change that exit status and an exit 1 you cannot clear would be wrong; `doctor` reports it as a WARNING. Without `--configure-smartgit`, `install` only prints a hint, or at a terminal asks (default No) after printing the plan.

```bash
git-secret-guard install --configure-smartgit        # plan, one question (or the flag), then the change
git-secret-guard restore-smartgit                    # undo; uninstall does the same
```

What it does, in order, and what it refuses:

- **Plan first.** Every file it will write and every command it will run (privileged ones with their full path) is printed before anything runs.
- **Edits only two lines.** In `preferences.yml` of the settings directory it replaces the `executable:` line (and `executable.absolute:` when the file has one) inside the `git:` block, by a line edit through a temporary file in the same directory. Every other byte stays; the YAML is never re-serialised. The original is copied first to `~/.local/state/git-secret-guard/smartgit/` with a manifest (hash, old and new values).
- **Which SmartGit is edited (SmartGit 26.1 only).** The macOS app and a Linux tarball or distribution package (settings in `~/.config/smartgit/<major>`) get the two-line edit, pointing at the git `status` reports. The Linux Flatpak gets the [four steps](#linux-flatpak) as one unit, each one written to a record before it runs, so `restore-smartgit` undoes exactly what was done: the `--user` override, the marked wrapper, the `smartgit.vmoptions` line with its temp directory, and the two-line edit pointing at the wrapper. Step 1 removes the SmartGit sandbox, so it needs **its own yes**: a second question at a terminal (default No), or `--allow-smartgit-sandbox-removal` together with `--configure-smartgit`. Without a terminal and without that flag the Flatpak is refused with the manual steps and nothing is changed. Snap and Windows are detected and reported by `status` and `doctor`, and refused with the manual steps.
- **Refuses, changing nothing,** while SmartGit is running (checked again immediately before the file is replaced, so a SmartGit started while the plan was shown is caught; exit it with *Repository, Exit*; on Linux a java of yours running `lib/bootloader.jar`, which also matches another Syntevo app and the refusal says so; for the Flatpak an entry of `flatpak ps` whose process still exists), when the target git is older than 2.54 or does not run, when `preferences.yml` is a symbolic link, not yours or not of the recorded shape, when the settings directory itself is a symbolic link or not yours, on Linux when the settings directory has no `startup` file (SmartGit's setup wizard writes it only when it reaches *Finish*; start SmartGit once, finish the wizard and exit it), and for any SmartGit version not recorded (only 26.1 was). For the Flatpak also: no `flatpak` command, no `flatpak-spawn` inside the sandbox, a wrapper at the same path that this tool did not write (made by hand), and a `smartgit.vmoptions` that is a symbolic link, not yours or lacks a final newline, and a `~/.cache/smartgit-tmp` that is a symbolic link, not a directory or not yours (all of these are checked before step 1 removes the sandbox). Then it prints the manual steps below instead.
- **Git LFS** is installed for the target git only when `git lfs version` fails through it. On macOS that check runs with the environment SmartGit gives git (see the [measurement](#maintainer-notes-the-macos-spike-smartgit-261)): `PATH` is the directory of the target git, then `/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`, so a `git-lfs` that your shell finds but SmartGit would not (for example one in `/usr/local/bin` or a profile directory) does not count; the refusal names SmartGit's own advice, absolute paths in the `filter.lfs.*` settings, which this tool does not write for you. On Linux the check uses `PATH` = the directory of the target git, then `/usr/local/bin:/usr/bin:/bin` (not measured: the Linux launcher passes the desktop session's `PATH` on, and this is the part every session has); for the Flatpak, LFS is the host's, checked through the wrapper. The install is `brew install git-lfs` on macOS, run as you. On RPM systems it is `dnf install -y git-lfs` as root, after a bounded, non-interactive `dnf repoquery --available` (stdin from `/dev/null`, `--assumeno`) shows that an enabled repository offers it; when none does, the run is refused and no repository is enabled for you; a failing repoquery is its own refusal. The plan says that `dnf install -y` answers yes to every prompt, a repository signing key import included (the query imported none). On Ubuntu and Debian a bounded `apt-cache policy git-lfs` (C locale, stdin from `/dev/null`) runs first: no candidate, or a failed query, is a refusal in the plan and no repository is enabled; then `apt-get install -y git-lfs` as root, non-interactive (`DEBIAN_FRONTEND=noninteractive`, a lock timeout), as the [git upgrade](platforms.md#ubuntu-and-debian-apt) runs apt. Both root commands are in the plan with their full paths and go through `sudo` (or run directly as root). Any other Linux is refused: install `git-lfs` yourself as in the [Git LFS](#git-lfs) section. Then `git lfs install --skip-repo` runs only when no `filter.lfs.*` is set. Its record is written as `pending` before the command and as `yes` once the settings are seen afterwards, so a run stopped around the command never lets a later restore remove a section you made yourself: a `pending` record is only dropped, and the settings it may have met stay (the message gives `git config --global --remove-section filter.lfs` for a section you did not add yourself). A rerun that finds the settings present and the record `pending` drops the record, keeps the settings and prints `git config --global --remove-section filter.lfs` for a user who did not add them, because nothing can tell the tool's own section from one you ran `git lfs install` for meanwhile; so a restore never removes a section the tool cannot prove it added. A `git lfs install` that exits non-zero is reported as failed with its status and taken back.
- **Verifies.** The configured git must run and be 2.54 or newer, `git lfs version` must work, a commit of a fake token (made up at run time, never printed) in a scratch repository (created without templates, so none can run a hook) must be blocked, and a clean commit must print the summary line. The Git LFS check, `git lfs install` with its filter check, and both commits run under `env -i` with `HOME` and the same `PATH` as above; only the location of the global git config is passed on when it is set, so the commits read the config that install wrote. For the Flatpak every check runs through the wrapper inside the sandbox (`flatpak run --command=<wrapper> com.syntevo.SmartGit ...`) in the environment of the install itself, because `flatpak run` needs the desktop session (under `env -i` it cannot find the D-Bus session bus), with `--cwd` and the scratch repository both under `~/.cache/smartgit-tmp` (the sandbox has its own `/tmp`; that directory has the same path inside and outside). Any failure restores the backup and, for the Flatpak, undoes every step from its record.
- **Order and interruption.** The backup and a pending manifest are written before `preferences.yml` is touched, the manifest is made final only after the edit, and an existing backup that differs is kept aside under a dated name instead of being overwritten. If the run is stopped between those steps, `restore-smartgit` or a rerun of the same command completes it (tested by stopping the run at each rename); a manifest never claims an edit that did not happen.
- **Undo.** `restore-smartgit` puts the two lines back only while they are still the ones this tool wrote; a value you changed since is left alone and reported. A backup that does not match the manifest stops the restore and prints the by-hand step. Git LFS packages are never removed; the `filter.lfs.*` settings only when this tool added them. For the Flatpak the record decides: the `--user` override is reset only when it held nothing before this tool added its line and holds nothing else now (otherwise the by-hand step to remove that one line is printed; an override that was already there is never touched), the wrapper is removed only while it carries the tool's marker line, exactly the added `smartgit.vmoptions` line is removed (every other byte and the mode stay), and the temp directory only when it is empty. `restore-smartgit` and `uninstall` decide every refusal before the first restore (each manifest: valid, backup matches, settings file readable, SmartGit not running; then the Git LFS record and the global config; then the Flatpak record: readable, `flatpak` present and its `--user` override readable when the record holds the override, `smartgit.vmoptions` not a symbolic link or someone else's when the record holds its line), so such a refusal changes nothing. `uninstall` restores SmartGit first, before it touches `core.hooksPath`, the CLI link or the share directory. With no refusal it finishes in one run. Only after a refusal (SmartGit running, for instance) does it change nothing and tell you to fix what it names and run `uninstall` again. What no check can predict is a write that fails midway (a full disk, for example): that is reported, the records are kept and a rerun finishes the rest.
- **After a SmartGit update** a new major version has a new settings directory: `status` and `doctor` show it as not configured, with the command to rerun.

The manual steps below remain the fallback for everything this refuses. See [what was and was not checked](#what-was-and-was-not-checked) and the [maintainer notes](#maintainer-notes-the-macos-spike-smartgit-261).

## How to tell that SmartGit's commits are scanned

A scanned commit prints the summary line of [the README](../README.md#use) in SmartGit's command output (the log pane or the commit error dialog):

```
git-secret-guard: scanned 3 files, 244 added lines (trufflehog 3.99.2, betterleaks 1.9.0): no findings, 3s
```

No such line means the hook did not run: the git SmartGit uses is too old, or it is not the one you configured. Check the path in Preferences, Commands.

## Git LFS

SmartGit shows the Git LFS version next to the git executable. LFS is a separate program (`git-lfs`) that the configured git must find. Install it for the git you point SmartGit at, then run `git lfs install` once per user (a package may do the system-wide equivalent for you: `git config --system --get-regexp filter.lfs` shows it):

| Platform | Install |
|---|---|
| Fedora, RHEL, Rocky, AlmaLinux | `sudo dnf install git-lfs` (checked with `dnf repoquery git-lfs` in container images of Rocky 9.7, Rocky 8.10 and Fedora 44: git-lfs 3.7.1 and 3.4.1 sit in the AppStream repository of Rocky and in the Fedora repositories, so no EPEL is needed there; other RHEL-compatible systems were not checked) |
| Ubuntu, Debian | `sudo apt install git-lfs` |
| macOS | `brew install git-lfs` |
| Windows | nothing to install: Git for Windows includes Git LFS |

```bash
git lfs version        # git-lfs/3.x
git lfs install        # per user; writes the filter.lfs.* settings to ~/.gitconfig
```

## Linux, Flatpak

`install --configure-smartgit` runs these four steps for you, as one unit with its own consent for step 1 (see [the automatic way](#the-automatic-way-install---configure-smartgit)); a refusal prints them. Below is the same setup done by hand.

The Flatpak of SmartGit (`com.syntevo.SmartGit`) runs in a sandbox that cannot see the host's `/usr/bin`. Picking `/usr/bin/git` in the file chooser does not work: Flatpak hands SmartGit a copy through its document portal (`/run/user/<uid>/doc/<id>/git`), and the sandbox has no `git-lfs` either. The way that worked is a small wrapper that runs the **host** git, so the host's git 2.54 or newer, `git-lfs` and the global hook are all used.

Each of the four steps below is needed; skipping one fails in the way described next to it.

**1. Allow SmartGit to run host commands.** `flatpak override --user --talk-name=org.freedesktop.Flatpak com.syntevo.SmartGit` (no root; the by-hand check on Fedora used `sudo flatpak override --system ...`, which works too and which the tool leaves alone when it finds it). This lets the app call `flatpak-spawn --host`, which **removes the sandbox for SmartGit**: it can then run any command on the host as you. Decide that on purpose. It applies from the next start of SmartGit; a running instance keeps the old permissions, and SmartGit then reports `Git executable is not valid` because the wrapper prints nothing.
**2. Create the wrapper** at `~/.local/share/smartgit/host-bin/git` (`chmod 755`). Your home directory is shared with the sandbox under the same path, which is why the wrapper can live there:

```sh
#!/bin/sh
# run the HOST git from the SmartGit Flatpak.
# SmartGit passes credential.helper=/app/bin/smartgit.sh ..., a path that only exists
# inside the sandbox, so rewrite it to launch that helper through the host's flatpak.
n=$#
while [ "$n" -gt 0 ]; do
    a=$1; shift
    case "$a" in
        "credential.helper=/app/bin/smartgit.sh "*)
            a="credential.helper=!flatpak run --command=/app/bin/smartgit.sh com.syntevo.SmartGit ${a#credential.helper=/app/bin/smartgit.sh }"
            ;;
    esac
    set -- "$@" "$a"
    n=$((n - 1))
done
exec flatpak-spawn --host /usr/bin/git "$@"
```

Use the absolute path of the git that `git-secret-guard status` reports (here `/usr/bin/git`): a bare `git` is looked up on the `PATH` of the host process, which may find an older git. The tool's wrapper carries one more line, a marker (`# git-secret-guard: written by install --configure-smartgit; undone by restore-smartgit`); a wrapper without it is yours and is never replaced or removed. Without the rewrite, a commit works and a push that needs credentials fails, because the host cannot run `/app/bin/smartgit.sh`.

**3. Move SmartGit's temporary directory into your home.** SmartGit writes the commit message to a file in its Java temp directory and passes the path to git; the sandbox's `/tmp` does not exist on the host, so the host git fails with `could not read log file '/tmp/smartgit.../commit....tmp': No such file or directory` (the hook has already run by then). Add one line to the file `~/.var/app/com.syntevo.SmartGit/config/smartgit/smartgit.vmoptions`, creating the directory first:

```
-Djava.io.tmpdir=/home/<you>/.cache/smartgit-tmp
```

Use your real home path (no `~`, no variables), and `mkdir -p ~/.cache/smartgit-tmp`. SmartGit reads that file at start, so restart it.

**4. Point SmartGit at the wrapper.** In the setup wizard or Preferences, Commands, choose *Other Git Executable* and **type** `/home/<you>/.local/share/smartgit/host-bin/git` (the file chooser is what produced the portal path above). `git --version` through the wrapper must say 2.54 or newer, and `git lfs version` must work:

```bash
flatpak run --command=sh com.syntevo.SmartGit -c '~/.local/share/smartgit/host-bin/git --version'
```

Run from inside the sandbox like this, the wrapper shows what SmartGit will see.

Not affected: your scanners and the hook stay in `~/.local/bin` and `~/.local/share/git-secret-guard`, which the host git uses; nothing of git-secret-guard is installed inside the Flatpak.

## Linux, tarball or distribution package

No sandbox is involved, and `install --configure-smartgit` makes the same two-line edit as on macOS in `~/.config/smartgit/<major>/preferences.yml` (refused until SmartGit's setup wizard has reached *Finish* once). By hand: in Preferences, Commands, choose *Other Git Executable* and give the path of the git that [`git-secret-guard status`](install.md#status-and-version) reports as the one in use (`command -v git`, for example `/usr/local/bin/git` after a source build on RHEL-compatible systems). The [git upgrade](platforms.md) that `install` offers is what produces a git of 2.54 or newer there. Install `git-lfs` as in the table above.

## macOS

**The setting itself was checked on a real Mac (SmartGit 26.1.056, macOS 26, arm64; see the [maintainer notes](#maintainer-notes-the-macos-spike-smartgit-261)); the Homebrew path below was not run through SmartGit's GUI.** `install --configure-smartgit` does this for you.

The standard SmartGit disk image includes a bundled git (the download page also lists "without Git" images for special setups, which are not needed here). Use a git from Homebrew, which git-secret-guard needs on macOS anyway:

```bash
brew install git git-lfs          # git-secret-guard's install offers the git part: install --upgrade-git
git lfs install
which -a git                       # Apple Git (/usr/bin/git) and Homebrew's are different files
```

The Homebrew git is `/opt/homebrew/bin/git` on Apple Silicon and `/usr/local/bin/git` on an Intel Mac (Intel is [not tested](platforms.md#macos-homebrew) for git-secret-guard itself). Run `<that path> --version` and check for 2.54 or newer.

In SmartGit open *Preferences* (the *SmartGit* menu on macOS), Commands, choose *Other Git Executable* and select that path. Apple Git in `/usr/bin` cannot be upgraded in place (SIP), so SmartGit has to be told the Homebrew path: a GUI client started from the Dock does not use your shell's `PATH`, so it does not find the Homebrew git by itself.

## Windows

**Not run on Windows with SmartGit by the author. These steps follow SmartGit's documentation and the notes in [platforms.md](platforms.md#windows-git-for-windows); check them on your machine.**

Yes, SmartGit for Windows has its own git too: the standard installer and the portable archive include a bundled git (the download page also lists "without Git" builds for special setups, not needed here). It is separate from the Git for Windows on your `PATH`, so installing or upgrading Git for Windows does not change what SmartGit commits with.

1. Install [Git for Windows](https://git-scm.com/download/win) 2.54 or newer (git-secret-guard needs it anyway; `install --upgrade-git` offers the upgrade, see [Upgrading Git for Windows](platforms.md#upgrading-git-for-windows)). It includes Git LFS; check with `git lfs version` in a new terminal, and run `git lfs install` once if `git config --global --get-regexp filter.lfs` shows nothing.
2. In SmartGit open *Edit*, *Preferences*, Commands, choose *Other Git Executable* and browse to `C:\Program Files\Git\cmd\git.exe` (the default location; `where git` shows yours).
3. Watch the version and LFS indicators: green means SmartGit accepts it.

After an upgrade of Git for Windows the path normally stays the same. After a reinstall to a different folder, set it again.

## What was and was not checked

| Item | State |
|---|---|
| Linux, Flatpak SmartGit 26.1 on Fedora, host git 2.55.0 through the wrapper | **Checked.** The wrapper ran `git --version` and `git lfs version` from inside the sandbox, SmartGit accepted the path, and a SmartGit commit printed the git-secret-guard summary line (the output in [How to tell that SmartGit's commits are scanned](#how-to-tell-that-smartgits-commits-are-scanned) is from that run). An authenticated push through the rewritten credential helper was **not** tested; a GitHub remote that uses `gh auth git-credential` from your `~/.gitconfig` does not need it. |
| The bundled git in the Flatpak is older than 2.54 | Checked on that machine (2.53.0). Commits made with it are not scanned: that is the premise of this page, and git-secret-guard's own measurement for another client is in [GitHub Desktop's bundled git](platforms.md#github-desktops-bundled-git). |
| Linux tarball of SmartGit 26.1.057 on Fedora | **Measured by hand** (see the Linux maintainer notes): the settings directory, the bundled state, that SmartGit accepts the two lines edited from outside while it is closed and runs that git, the `startup` file, the running process. The automated edit is covered by tests against stand-ins and a fixture of the real file; **not run:** `install --configure-smartgit` against a real SmartGit and a commit through the GUI after it. |
| Linux `.deb` or `.rpm` package of SmartGit | **Not run.** Assumed to behave like the tarball (same launcher); detected through the install directories, settings in `~/.config/smartgit`. |
| Snap | **Not run.** Detected, refused with the manual steps. |
| macOS, SmartGit 26.1.056 on a real Mac | **Checked** (spike, see the maintainer notes): where the Git Executable is stored, that SmartGit accepts a `preferences.yml` edited while it is closed and runs that git, and that an edit made while it runs survives a clean quit. **Not checked:** a commit made through the SmartGit GUI, SmartGit older or newer than 26.1, an Intel Mac, and whether SmartGit itself runs `git lfs` with a Homebrew `git-lfs` (the PATH it gives git was measured, see the maintainer notes, but no `git-lfs` outside the SmartGit bundle exists on that Mac). The automated flow is covered by tests against stand-ins and a fixture of the real file. |
| Linux Flatpak automation | **Checked on a real machine** on 2026-11-11 (Fedora 45, Flatpak SmartGit 26.1.057, host git 2.56.0, flatpak 1.18.4; see the Linux maintainer notes): `install --configure-smartgit --allow-smartgit-sandbox-removal` ran the four steps (rc 0) and its own verify passed inside the sandbox (a fake-token commit blocked, a clean commit printed the summary line); the `--user` override alone was enough; a rerun said "nothing to change"; `status` and `doctor` said the commits are scanned; `restore-smartgit` put `preferences.yml` back byte for byte and removed the wrapper, the `smartgit.vmoptions` line, the override and the record. **A commit through the SmartGit GUI** after that setup printed the summary line, and a commit of a fake AWS key was refused. **Tests against stand-ins only:** a stop at each step and rename, an override that was already there, a hand-made wrapper, the second question at a real terminal (the test needs `script`, missing where the tests ran). **Not run:** an authenticated push through the rewritten credential helper. |
| Windows | Not run. Detection paths are implemented, nothing is edited (no settings key recorded); the manual steps apply. |
| Whether any SmartGit feature misbehaves with an external git | Not tested beyond commit and the checks above. |

## Maintainer notes: the macOS spike (SmartGit 26.1)

Measured on a real Mac (macOS 26.7.1, arm64) with SmartGit 26.1.056 from `brew install --cask smartgit`; nothing below is inferred from the manual.

- **Bundle.** `/Applications/SmartGit.app`, `Contents/Info.plist`: `CFBundleShortVersionString` 26.1.056, `CFBundleVersion` 261056, `CFBundleIdentifier` com.syntevo.smartgit, launcher `Contents/MacOS/SmartGit`. The bundle holds a git at `Contents/Resources/git/bin/git` (**2.53.0**, older than 2.54: not scanned) and a `git-lfs` beside it (**3.7.1**, so the macOS bundle does include LFS).
- **Settings directory.** `~/Library/Preferences/SmartGit/<major>.<minor>` (here `26.1`), next to `smartgit.vmoptions` one level up. Files: `preferences.yml` (mode 0600), `smartgit.properties`, `logs/log.txt.0`, and secret files (`credentials.yml`, `passwords`, `evaluation`) that this tool never reads. The fixture `tests/fixtures/smartgit/macos-26.1/preferences.yml` is the real file with identifying values scrubbed.
- **The Git Executable.** Block `git:` of `preferences.yml` (2-space indent, flow-style lists elsewhere). *Bundled Git* after the setup wizard:

```
git:
  maxCount: 3
  alternatives: [/usr/bin/git, '${smartgit.install}/git/bin/git']
  executable: ${smartgit.install}/git/bin/git
  executable.absolute: /Applications/SmartGit.app/Contents/Resources/git/bin/git
  useOwnCredentialHelper: true
```

- **A plain absolute path works** in `executable:` (checked with `/usr/bin/git`, Apple Git 2.54.0, and with a symlink to it outside `alternatives:`): SmartGit logged `Git version is 'git version 2.54.0 ...'` and ran `<path> --version`, then used that git and read `~/.gitconfig` (including `hook.git-secret-guard.*`). `executable.absolute:` may equal the path or be absent (checked): SmartGit did not add it back.
- **Edited while closed:** accepted at the next start, and SmartGit rewrote the file during the run only in `vcsRecords.lastGitUsage` (a timestamp); `alternatives:` was not rewritten.
- **Edited while running:** the edit survived a clean quit (`osascript -e 'tell application "SmartGit" to quit'`) in this one run. SmartGit does rewrite the file while it runs, so a pending in-memory change could still overwrite an outside edit; hence the refusal while it runs.
- **"Other Git Executable"** was not clicked in the GUI; the written form above was run and accepted instead. Whether the wizard writes anything else (for example to `alternatives:`) for that choice is unknown.
- **The environment SmartGit gives git (measured for the Git LFS check).** SmartGit never ran `git lfs version` itself at startup (its log shows `git --version` and the `filter.lfs.*` lines of the git config only). With a logging wrapper as the Git Executable, the `PATH` seen by git was `<wrapper directory>:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin` when SmartGit was started the way the Dock does (`env -i HOME USER LOGNAME PATH=/usr/bin:/bin:/usr/sbin:/sbin open -a SmartGit`): SmartGit puts the directory of the Git Executable and `/opt/homebrew/bin` in front of what it inherited. Started from an interactive shell it also carried that shell's entries. `/usr/local/bin` (Intel Homebrew) did not appear; Intel was not measured. This is why the macOS LFS check runs under `env -i HOME PATH=<git directory>:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin` (override for tests only: `GSG_SMARTGIT_LAUNCH_PATH`). The measurement edited the real settings and `~/.gitconfig` with SmartGit closed, from full copies restored byte for byte afterwards.
- **The Linux Git LFS routes are back** (`smartgit_lfs_plan_dnf`, `smartgit_lfs_plan_apt`): the dnf refusal no longer names EPEL, which the repoquery checks of Rocky 8, Rocky 9 and Fedora 44 showed to be wrong there.
- **Not measured on a Mac:** other major versions and a commit through the GUI. Linux: see the next section.

## Maintainer notes: the Linux spike (SmartGit 26.1)

Measured on Fedora 45 (host git `/usr/bin/git` 2.56.0, Flatpak 1.18.4) with the Flatpak `com.syntevo.SmartGit` 26.1.057 from Flathub and the official tarball `smartgit-26_1_057-linux-amd64.tar.gz`; nothing below is inferred.

- **Flatpak version.** `flatpak info` prints `Version: 26_1_057`; underscores are read as dots (`smartgit_find_flatpak`).
- **Settings.** Flatpak `~/.var/app/com.syntevo.SmartGit/config/smartgit/26.1/`, tarball `${XDG_CONFIG_HOME:-~/.config}/smartgit/26.1/`, `smartgit.vmoptions` one level up. Bundled state: `executable: ${smartgit.install}/git/bin/git` with `executable.absolute:` `/app/git/bin/git` (Flatpak) or `<install>/git/bin/git` (tarball, key order not kept). The flow list of `alternatives:` can wrap onto a continuation line. Fixtures: `tests/fixtures/smartgit/linux-flatpak-26.1`, `linux-flatpak-26.1-byhand`, `linux-tarball-26.1`.
- **After the four manual steps** SmartGit wrote `executable: ~/.local/share/smartgit/host-bin/git` and `executable.absolute: /home/<user>/...`: a `~/` value is read as that path (the absolute line wins) and judged inside the sandbox.
- **Bundled git.** 2.53.0 in both (`flatpak run --command=/app/git/bin/git com.syntevo.SmartGit --version` says `git version 2.53.0.dirty`; the `/app` path does not exist on the host, so the Flatpak's git is read through `flatpak run`, under the doctor time bound). `flatpak-spawn` is `/usr/bin/flatpak-spawn` inside the sandbox.
- **`flatpak ps`** keeps listing an instance for up to about ten seconds after a `flatpak run --command=...` ended, with a pid already gone; `--columns=pid,application` prints tab-separated lines without a header. The running check counts only live pids, so the tool's own probes never look like a running SmartGit.
- **`flatpak run` needs the session.** Under `env -i HOME PATH` it fails (`Can't find bus`), so the Flatpak verify runs in the installer's environment.
- **Cost.** Each Flatpak settings directory with a Git Executable (the bundled `/app/git/bin/git` or the wrapper) adds one `flatpak run --command=<git> ... --version`, under doctor's time bound, to `status`, `doctor` and `doctor --recheck` (`smartgit_add_settings`). Accepted: the git SmartGit runs is judged where SmartGit runs it.
- **Working directory.** The verify runs `flatpak run --cwd=~/.cache/smartgit-tmp` (an absolute path in the call), a directory under your home with the same path inside the sandbox, so it never depends on the directory install was started from. Confirmed by the real run of 2026-11-11.
- **Overrides.** In the by-hand spike `--user --show` was empty and `--system --show` held the permission made by hand. **The `--user` override alone is enough** (2026-11-11, `--system --show` empty): `flatpak-spawn --host /usr/bin/git --version` worked inside the sandbox; after `restore-smartgit` it fails again (`Portal call failed: org.freedesktop.DBus.Error.ServiceUnknown`, with the hint that `--host` only works when the Flatpak is allowed to talk to `org.freedesktop.Flatpak`).
- **Real run of the automated unit** (2026-11-11, Fedora 45, flatpak 1.18.4, SmartGit 26.1.057, host git 2.56.0). Install (rc 0), its verify inside the sandbox, a rerun ("nothing to change", every hash unchanged), `status`/`doctor` ("commits are scanned"), restore and a second install all ran as described above. The one leftover of a restore is an empty `~/.local/share/flatpak/overrides/` directory, made by `flatpak override --user` itself; it is not removed and is harmless. A pre-existing `~/.cache/smartgit-tmp` was used as it was (record `tmpdir=no`) and kept. **GUI commit** after that setup: a clean commit printed the summary line, a commit of a fake AWS key was refused, and SmartGit's log showed `Executing ... host-bin/git --version`, `Git version is 'git version 2.56.0'` and `host-bin/git lfs --version`.
- **Clicking OK in Preferences re-serialises the whole `preferences.yml`**: never edit while SmartGit runs.
- **Setup wizard.** A version directory whose wizard never reached *Finish* shows the wizard on every start; `startup` (with `evaluation`, `passwords`, `.backup/`) appears only after *Finish*, which also contacts the license server and writes `~/.gitconfig` with the wizard's name and email.
- **Running.** A java of the user whose command line holds `<install>/lib/bootloader.jar` (the Flatpak's shows `/app/lib/bootloader.jar`); `pgrep -u <uid> -f 'lib/bootloader\.jar'`.
- **Outside edit proven** (tarball): with SmartGit closed, both lines edited to a path outside `alternatives:`; at start SmartGit ran `<path> --version`, logged the version and left the file unchanged.
- **PATH.** The launcher (`#!/bin/bash --login`) passes the desktop session's `PATH` on; what git sees was not measured, hence the `/usr/local/bin:/usr/bin:/bin` suffix of the LFS check. SmartGit runs `git lfs` only on the wizard's Git page.
- **Not measured:** `install --configure-smartgit` on a real tarball, `.deb` or `.rpm` install (only the outside edit was proven, above), Snap, an authenticated push through the rewritten credential helper, and the `PATH` the Linux launcher gives git.

Sources: SmartGit's manual, [Preferences, Commands](https://docs.smartgit.dev/24.1/Manual/GUI/Preferences/Commands) (the *Git Executable* settings, the LFS and version indicators, the warning about not using the bundled git), and its [download page](https://www.smartgit.dev/download/) (the "without Git" builds for Windows and macOS).
