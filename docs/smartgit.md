# SmartGit

git-secret-guard scans a commit only when the git that makes the commit is **2.54 or newer** (an older git ignores config hooks without a word, see [the limits](../README.md#limits)). SmartGit runs its own git, so the git on your `PATH` does not decide anything there: **SmartGit has to be pointed at a git 2.54 or newer**, or its commits are not scanned.

SmartGit offers two settings (Preferences, Commands, *Git Executable*; the setup wizard asks the same on first start):

| Setting | Meaning |
|---|---|
| **Bundled Git** | the git shipped inside SmartGit. SmartGit recommends it, and it can be older than 2.54 (the Flatpak of SmartGit 26.1 bundled 2.53.0; it is a different git from the one on your `PATH`). |
| **Other Git Executable** | a git you installed yourself. SmartGit shows the git and Git LFS versions next to the field, and a red cross means it cannot use that executable. |

SmartGit says some of its features may not work correctly without the bundled git. Nothing here was found broken on Linux with the git described below, but that is one machine: see [what was and was not checked](#what-was-and-was-not-checked).

Install git-secret-guard first ([install.md](install.md)), then follow the section for your platform. `git-secret-guard status` must say that commits can be scanned.

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
| Fedora, RHEL, Rocky, AlmaLinux | `sudo dnf install git-lfs` (on RHEL-compatible systems from EPEL) |
| Ubuntu, Debian | `sudo apt install git-lfs` |
| macOS | `brew install git-lfs` |
| Windows | nothing to install: Git for Windows includes Git LFS |

```bash
git lfs version        # git-lfs/3.x
git lfs install        # per user; writes the filter.lfs.* settings to ~/.gitconfig
```

## Linux, Flatpak (verified)

The Flatpak of SmartGit (`com.syntevo.SmartGit`) runs in a sandbox that cannot see the host's `/usr/bin`. Picking `/usr/bin/git` in the file chooser does not work: Flatpak hands SmartGit a copy through its document portal (`/run/user/<uid>/doc/<id>/git`), and the sandbox has no `git-lfs` either. The way that worked is a small wrapper that runs the **host** git, so the host's git 2.54 or newer, `git-lfs` and the global hook are all used.

Each of the four steps below is needed; skipping one fails in the way described next to it.

1. **Allow SmartGit to run host commands.** `sudo flatpak override --system --talk-name=org.freedesktop.Flatpak com.syntevo.SmartGit`. This lets the app call `flatpak-spawn --host`, which **removes the sandbox for SmartGit**: it can then run any command on the host as you. Decide that on purpose. It applies from the next start of SmartGit; a running instance keeps the old permissions, and SmartGit then reports `Git executable is not valid` because the wrapper prints nothing.
2. **Create the wrapper** at `~/.local/share/smartgit/host-bin/git` (`chmod 755`). Your home directory is shared with the sandbox under the same path, which is why the wrapper can live there:

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
3. **Move SmartGit's temporary directory into your home.** SmartGit writes the commit message to a file in its Java temp directory and passes the path to git; the sandbox's `/tmp` does not exist on the host, so the host git fails with `could not read log file '/tmp/smartgit.../commit....tmp': No such file or directory` (the hook has already run by then). Add one line to the file `~/.var/app/com.syntevo.SmartGit/config/smartgit/smartgit.vmoptions`, creating the directory first:

   ```
   -Djava.io.tmpdir=/home/<you>/.cache/smartgit-tmp
   ```

   Use your real home path (no `~`, no variables), and `mkdir -p ~/.cache/smartgit-tmp`. SmartGit reads that file at start, so restart it.
4. **Point SmartGit at the wrapper.** In the setup wizard or Preferences, Commands, choose *Other Git Executable* and **type** `/home/<you>/.local/share/smartgit/host-bin/git` (the file chooser is what produced the portal path above). `git --version` through the wrapper must say 2.54 or newer, and `git lfs version` must work:

   ```bash
   flatpak run --command=sh com.syntevo.SmartGit -c '~/.local/share/smartgit/host-bin/git --version'
   ```

   Run from inside the sandbox like this, the wrapper shows what SmartGit will see.

Not affected: your scanners and the hook stay in `~/.local/bin` and `~/.local/share/git-secret-guard`, which the host git uses; nothing of git-secret-guard is installed inside the Flatpak.

The [setup-dev-rocky](https://github.com/jsbattig/setup-dev-rocky) repository automates all four steps in its `smartgit` module (`modules/smartgit.sh`), for Fedora and Rocky, and re-running it is safe.

## Linux, tarball or distribution package

No sandbox is involved. In Preferences, Commands, choose *Other Git Executable* and give the path of the git that [`git-secret-guard status`](install.md#status-and-version) reports as the one in use (`command -v git`, for example `/usr/local/bin/git` after a source build on RHEL-compatible systems). The [git upgrade](platforms.md) that `install` offers is what produces a git of 2.54 or newer there. Install `git-lfs` as in the table above.

## macOS

**Not run on a Mac by the author. These steps follow SmartGit's documentation and the platform notes of this package; check them on your machine.**

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
| Linux tarball or distribution package of SmartGit | Not run. |
| macOS | Not run. The bundled-git statement comes from SmartGit's download page; the path names are Homebrew's defaults. |
| Windows | Not run. The bundled-git statement comes from SmartGit's download page; the path is Git for Windows' default. |
| Whether any SmartGit feature misbehaves with an external git | Not tested beyond commit and the checks above. |

Sources: SmartGit's manual, [Preferences, Commands](https://docs.smartgit.dev/24.1/Manual/GUI/Preferences/Commands) (the *Git Executable* settings, the LFS and version indicators, the warning about not using the bundled git), and its [download page](https://www.smartgit.dev/download/) (the "without Git" builds for Windows and macOS).
