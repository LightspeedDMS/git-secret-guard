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
- **The edit is automatic on macOS only (SmartGit 26.1).** That is the one platform and version this tool has seen. The Linux Flatpak, a Linux tarball or package, Snap and Windows are detected and reported by `status` and `doctor`, but `install --configure-smartgit` refuses to edit them and prints the manual steps below. For the Flatpak the four verified steps are printed as they are; automating them is deferred until they can be tried on a real Linux machine with this tool, because step 1 removes the SmartGit sandbox. Nothing about a Flatpak directory is changed.
- **Refuses, changing nothing,** while SmartGit is running (checked again immediately before the file is replaced, so a SmartGit started while the plan was shown is caught; exit it with *Repository, Exit*), when the target git is older than 2.54 or does not run, when `preferences.yml` is a symbolic link, not yours or not of the recorded shape, when the settings directory itself is a symbolic link or not yours, and for any SmartGit version not recorded (only 26.1 was). Then it prints the manual steps below instead.
- **Git LFS** is installed for the target git only when `git lfs version` fails through it. On macOS that check runs with the environment SmartGit gives git (see the [measurement](#maintainer-notes-the-macos-spike-smartgit-261)): `PATH` is the directory of the target git, then `/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`, so a `git-lfs` that your shell finds but SmartGit would not (for example one in `/usr/local/bin` or a profile directory) does not count; the refusal names SmartGit's own advice, absolute paths in the `filter.lfs.*` settings, which this tool does not write for you. The install is `brew install git-lfs`, run as you, and only on macOS. Linux packages and Windows are not automated: those settings directories are refused as above, so install `git-lfs` yourself as in the [Git LFS](#git-lfs) section. Then `git lfs install --skip-repo` runs only when no `filter.lfs.*` is set. Its record is written as `pending` before the command and as `yes` once the settings are seen afterwards, so a run stopped around the command never lets a later restore remove a section you made yourself: a `pending` record is only dropped, and the settings it may have met stay (the message gives `git config --global --remove-section filter.lfs` for a section you did not add yourself). A rerun that finds the settings present and the record `pending` drops the record, keeps the settings and prints `git config --global --remove-section filter.lfs` for a user who did not add them, because nothing can tell the tool's own section from one you ran `git lfs install` for meanwhile; so a restore never removes a section the tool cannot prove it added. A `git lfs install` that exits non-zero is reported as failed with its status and taken back.
- **Verifies.** The configured git must run and be 2.54 or newer, `git lfs version` must work, a commit of a fake token (made up at run time, never printed) in a scratch repository (created without templates, so none can run a hook) must be blocked, and a clean commit must print the summary line. The Git LFS check, `git lfs install` with its filter check, and both commits run under `env -i` with `HOME` and the same measured `PATH`; only the location of the global git config is passed on when it is set, so the commits read the config that install wrote. Any failure restores the backup.
- **Order and interruption.** The backup and a pending manifest are written before `preferences.yml` is touched, the manifest is made final only after the edit, and an existing backup that differs is kept aside under a dated name instead of being overwritten. If the run is stopped between those steps, `restore-smartgit` or a rerun of the same command completes it (tested by stopping the run at each rename); a manifest never claims an edit that did not happen.
- **Undo.** `restore-smartgit` puts the two lines back only while they are still the ones this tool wrote; a value you changed since is left alone and reported. A backup that does not match the manifest stops the restore and prints the by-hand step. Git LFS packages are never removed; the `filter.lfs.*` settings only when this tool added them. `restore-smartgit` and `uninstall` decide every refusal before the first restore (each manifest: valid, backup matches, settings file readable, SmartGit not running; then the Git LFS record and the global config), so such a refusal changes nothing. `uninstall` restores SmartGit first, before it touches `core.hooksPath`, the CLI link or the share directory. With no refusal it finishes in one run. Only after a refusal (SmartGit running, for instance) does it change nothing and tell you to fix what it names and run `uninstall` again. What no check can predict is a write that fails midway (a full disk, for example): that is reported, the records are kept and a rerun finishes the rest.
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

## Linux, Flatpak (verified by hand; not automated)

`install --configure-smartgit` does not run these steps: it refuses a Flatpak settings directory and prints them. Automating them is deferred until they can be tried on a real Linux machine with this tool.

The Flatpak of SmartGit (`com.syntevo.SmartGit`) runs in a sandbox that cannot see the host's `/usr/bin`. Picking `/usr/bin/git` in the file chooser does not work: Flatpak hands SmartGit a copy through its document portal (`/run/user/<uid>/doc/<id>/git`), and the sandbox has no `git-lfs` either. The way that worked is a small wrapper that runs the **host** git, so the host's git 2.54 or newer, `git-lfs` and the global hook are all used.

Each of the four steps below is needed; skipping one fails in the way described next to it.

**1. Allow SmartGit to run host commands.** `sudo flatpak override --system --talk-name=org.freedesktop.Flatpak com.syntevo.SmartGit`. This lets the app call `flatpak-spawn --host`, which **removes the sandbox for SmartGit**: it can then run any command on the host as you. Decide that on purpose. It applies from the next start of SmartGit; a running instance keeps the old permissions, and SmartGit then reports `Git executable is not valid` because the wrapper prints nothing.
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
exec flatpak-spawn --host git "$@"
```

Without the rewrite, a commit works and a push that needs credentials fails, because the host cannot run `/app/bin/smartgit.sh`.

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

No sandbox is involved. In Preferences, Commands, choose *Other Git Executable* and give the path of the git that [`git-secret-guard status`](install.md#status-and-version) reports as the one in use (`command -v git`, for example `/usr/local/bin/git` after a source build on RHEL-compatible systems). The [git upgrade](platforms.md) that `install` offers is what produces a git of 2.54 or newer there. Install `git-lfs` as in the table above.

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
| Linux tarball or distribution package of SmartGit | Not run. `install --configure-smartgit` detects it and refuses to edit (no settings key recorded); the manual steps apply. |
| macOS, SmartGit 26.1.056 on a real Mac | **Checked** (spike, see the maintainer notes): where the Git Executable is stored, that SmartGit accepts a `preferences.yml` edited while it is closed and runs that git, and that an edit made while it runs survives a clean quit. **Not checked:** a commit made through the SmartGit GUI, SmartGit older or newer than 26.1, an Intel Mac, and whether SmartGit itself runs `git lfs` with a Homebrew `git-lfs` (the PATH it gives git was measured, see the maintainer notes, but no `git-lfs` outside the SmartGit bundle exists on that Mac). The automated flow is covered by tests against stand-ins and a fixture of the real file. |
| Linux Flatpak automation | **Not offered.** The four steps are the ones verified by hand and are only printed by `install --configure-smartgit`. The Flatpak `preferences.yml` key was not recorded, so nothing in a Flatpak directory is edited. Deferred until a Linux spike. |
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
- **Removed until the Linux spike.** The dnf route (`dnf repoquery git-lfs`, bounded and non-interactive, refusing when no enabled repository offers it; its refusal text named EPEL as the likely source, which the repoquery checks of Rocky 8, Rocky 9 and Fedora 44 showed to be wrong there, so a returning route must not say that), the apt route and the Windows refusal of the Git LFS install were written and tested, then removed because no product path reaches them (every non-macOS settings directory is refused before the plan). They are in commit 4752975 and come back with the Linux automation.
- **Not measured:** SmartGit on Linux (non-Flatpak), Windows, Snap, the Flatpak `preferences.yml` (its key is not recorded and nothing there is edited), other major versions, and a commit through the GUI.

Sources: SmartGit's manual, [Preferences, Commands](https://docs.smartgit.dev/24.1/Manual/GUI/Preferences/Commands) (the *Git Executable* settings, the LFS and version indicators, the warning about not using the bundled git), and its [download page](https://www.smartgit.dev/download/) (the "without Git" builds for Windows and macOS).
