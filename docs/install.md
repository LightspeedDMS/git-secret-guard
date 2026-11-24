# Install, upgrade and uninstall

This page covers the commands that change or report the machine setup: `install` and its flags, `uninstall`,
`restore-system-git`, `restore-smartgit`, `unlink-desktop-git`, `update`, `status`, `version` and `help`. `doctor` has its own page,
[doctor.md](doctor.md). `git-secret-guard help` prints the same commands in short (`lib/cli/usage.md`). A missing or unknown command, an
unknown option, or an argument a command does not take, prints that text on stderr and exits 2, changing nothing.

Every command below works the same in Git Bash on Windows. From PowerShell or cmd, a checkout uses
`bin\git-secret-guard.cmd` in place of `bin/git-secret-guard`, and once installed plain `git-secret-guard` works there too, in a window opened after the
install: on Windows `install` puts the CLI folder on your user `Path` (the CLI row below).

```bash
git clone <this repository> && cd git-secret-guard
bin/git-secret-guard install        # also the upgrade: run it again from a newer checkout
git-secret-guard status             # what is installed, and whether commits can still be scanned (git, hook config, tools)
git-secret-guard doctor             # which repositories are not protected, and why (read-only except its findings record, see below)
bin/git-secret-guard install --with-timer   # optional: also run doctor weekly (systemd user timer, a LaunchAgent on macOS; on Windows see doctor.md)
bin/git-secret-guard install --auto-update  # optional, Linux, macOS and Windows: also follow the checkout's released tags hourly (see Auto-update below)
bin/git-secret-guard install --dont-change-path  # optional: leave PATH alone and print the step to do by hand (the CLI row below)
git-secret-guard uninstall          # put back what was there before
```

**Requirements.** Linux on x86_64 or arm64, macOS arm64 with Homebrew (macOS x86_64 too, with Homebrew set up by hand: [Homebrew on an Intel Mac](platforms.md#homebrew-on-an-intel-mac)), or Windows x86_64 with Git for Windows (details in [platforms.md](platforms.md#windows-git-for-windows): there `install` downloads a missing `jq`, and `taskkill` replaces `setsid`). bash 4.4 or newer,
**git >= 2.54 first on `PATH`**, `jq`, `setsid`, `timeout`, `awk` (Linux and WSL; the hook runs it, and a Fedora WSL image without it blocked every commit), and `curl` plus `tar` when a scanner has to be downloaded. On
macOS, `install` lists whichever of bash 4.4 or newer, `coreutils` (`timeout`), `util-linux` (`setsid`) and `jq` is missing, installs them
with `brew install` only after its other checks have passed, the `tools.lock` lookup included (with a GNU `timeout` already present, the scanner
downloads are verified first too; under the system bash 3.2 it first installs `bash` alone), and refuses, changing
nothing, when Homebrew is not on `PATH`: details in
[platforms.md](platforms.md#macos-homebrew). Older git ignores config hooks without any message, so when the git on `PATH` is older
than 2.54 or missing, `install` offers to upgrade it on RHEL, Rocky, AlmaLinux, CentOS and Fedora (see
[platforms.md](platforms.md#rhel-rocky-and-fedora-rpm)), on Ubuntu and Debian (see [platforms.md](platforms.md#ubuntu-and-debian-apt)), inside WSL when the distribution is one of those (see [platforms.md](platforms.md#wsl-windows-subsystem-for-linux)), on macOS (see [platforms.md](platforms.md#macos-homebrew)) and on Windows (see [platforms.md](platforms.md#upgrading-git-for-windows)).
If you decline, and on every other platform, it refuses and prints how to get a newer git.

> **Warning, old git.** On Windows, check the git your IDE or GUI client bundles: it is often not the one on `PATH`. The
> example below is the RHEL host, where `/usr/bin/git` is 2.52.
>
> Any git older than 2.54 ignores config hooks: no error, no scan. `install` warns
> for every other reachable git older than 2.54 (all `git` on `PATH` plus `/usr/bin/git` and the git GitHub Desktop bundles at `/usr/lib/github-desktop/resources/app/git/bin/git`, which the warning names: a commit made by it was measured to skip the scan, see [CI on real platforms](platform-testing.md#ci-on-real-platforms); no warning for it once [the Desktop link](#github-desktop-on-linux---link-desktop-git-and-unlink-desktop-git) is current; on this machine
> `/usr/bin/git` is 2.52) and goes on, because the git that matters is the one your commits run. Commits made with the
> old one are **not scanned**; call `/usr/local/bin/git` (or put it first on `PATH`) wherever you commit. On RHEL, Rocky and
> AlmaLinux (where `/bin` is a link to `/usr/bin`, the prompt, the warnings, `status` and `doctor` show a path below `/bin` as `/usr/bin/git`; this changes the words only), `install --take-over-system-git` points an old package `/usr/bin/git` at the new build, which also covers cron
> jobs and scripts that call it by full path (undo: `restore-system-git`).

## What `install` does

| Step | Result |
|---|---|
| Prechecks | git >= 2.54 on `PATH`, `jq`, `setsid` (`taskkill` on Windows), `timeout` found (their **absolute paths** are written to the settings file, the hook never resolves them through `PATH`), `awk` on `PATH` on Linux (checked only: the hook runs it from `PATH`, like `sed`), a supported platform, absolute `HOME`/`XDG_*`. A refusal happens before anything is changed, with two exceptions: after a git upgrade you accepted, and on a Mac where the system bash 3.2 first needs `brew install bash`. In both cases the refusal says what changed. |
| Git upgrade | Only on RHEL, Rocky, AlmaLinux, CentOS and Fedora (see [platforms.md](platforms.md#rhel-rocky-and-fedora-rpm)), on Ubuntu and Debian (see [platforms.md](platforms.md#ubuntu-and-debian-apt)), inside WSL running one of those (see [WSL](platforms.md#wsl-windows-subsystem-for-linux)) and on macOS with Homebrew (see [platforms.md](platforms.md#macos-homebrew)) and on Windows (see [platforms.md](platforms.md#upgrading-git-for-windows)), and only if you agree at the prompt (default No) or pass the flag. Every other platform keeps the refusal, which prints how to get a newer git. `--upgrade-git` handles an old or missing git, or a build of ours older than the pin; `--take-over-system-git` (RPM systems only; refused on Ubuntu and Debian, a note that changes nothing on macOS) handles an old package git left in `/usr/bin`. The plan, with every privileged command, is printed first. |
| Scanners | `~/.local/bin/trufflehog` and `~/.local/bin/betterleaks` (`trufflehog.exe` and `betterleaks.exe` on Windows, where a missing `jq` is downloaded the same way as `jq.exe`). A tool that already reports the pinned version (`trufflehog` 3.99.2, `betterleaks` 1.9.0) is **kept**. Otherwise the platform tarball is downloaded from the vendor's GitHub release, its **SHA-256 is checked against `tools.lock`**, only the tool binary is extracted, and its `--version` is checked against the pin. A checksum mismatch deletes the download, installs nothing (neither scanner) and refuses. curl runs with `-q` as its first argument, so a `~/.curlrc` (proxy, protocol, output or `head` settings) cannot change a verified download. **A file already at that path that does not report the pinned version (your own build, a symlink, an older release) is never overwritten:** it is moved aside to `<tool>.gsg-replaced-<UTC stamp>` in the same directory (byte-identical, same mode), the output says where, and the state records the aside name with the SHA-256 of what install put in its place. Such a tool is never recorded as downloaded by install, so it is never "ours to delete". Install also records the SHA-256 of **every** file it places (`tools_placed` in the state), also on an empty path. On an upgrade that bumps the pins, a file that still has that hash is install's own and is **replaced in place** (no aside file, and a downloaded tool stays removable with `--remove-tools`); only a file install did not place is moved aside, and the first original ever moved aside is the one uninstall restores. The aside names and hashes are written to the state **before** the file is moved, so a failure afterwards (state write, second tool, share dir) cannot lose the original: a later uninstall, or a rerun of install, still finds it. |
| Files | `hooks/`, `lib/`, `bin/`, `tools.lock`, `VERSION` copied to `${XDG_DATA_HOME:-~/.local/share}/git-secret-guard/` with every group and other write bit removed (a checkout on a WSL drive is mode 777), and an existing `desktop-hooks/` directory carried over (the new tree is built complete beside the old one and swapped in with two renames, old out, new in, so a commit during an upgrade runs the old or the new hook, never half of either; in the instant between the two renames the hook path is missing and a commit started then fails. If the second rename fails the previous tree is moved back; if that fails too, the message names where it is, `<share>.old.XXXXXX/previous`), plus the generated `settings` file with absolute `TRUFFLEHOG_BIN`, `BETTERLEAKS_BIN`, `JQ_BIN`, `SETSID_BIN`, `TIMEOUT_BIN`, the pinned `TRUFFLEHOG_VERSION` and `BETTERLEAKS_VERSION` (the hook prints them on a passing commit) and `SCAN_TIMEOUT_SECONDS=300` (the absolute `BASH_BIN`, the bash that ran install, on every platform, and on macOS also `GNUBIN_DIR`; the hook command is a check of that bash and an `exec` of it with the hook, so the script's shebang never picks the interpreter; an install from before this is upgraded by the next `install`, which an auto-update runs; on Windows `TASKKILL_BIN` in place of `SETSID_BIN`, and `JQ_BIN` names a small wrapper in the share dir whose shebang is the recorded bash (rewritten by every install; an install refuses a bash path with whitespace or over 100 characters there); with `--with-timer` or `--auto-update`, or a timer or auto-update the state records, also the absolute `SYSTEMCTL_BIN`, `LAUNCHCTL_BIN` on macOS, `SCHTASKS_BIN` on Windows for `--auto-update`). `settings` also records `BETTERLEAKS_RULE_SHA256`, the SHA-256 of the `lib/scan/betterleaks-rule.toml` the share holds (#26): the hook blocks the commit, `status` and `doctor` flag it, when that file no longer matches. Run from the installed copy, install keeps the recorded value only while the share's rule file still matches it; an edited file **refuses the install** (exit 1, nothing changed by this step: install from a checkout or a release; a git upgrade you accepted earlier in the same run may already have happened, as for the other refusals), and the first install after an upgrade from before this check records the file as it is on disk. `settings` is rewritten by every install. |
| Global git config | `hook.git-secret-guard.event` twice, `pre-commit` (the added lines) and `commit-msg` (the message, [scan.md](scan.md#the-commit-message)), and `hook.git-secret-guard.command=[ -f '<recorded bash>' ] && [ -x '<recorded bash>' ] || { <message>; exit 1; }; exec '<recorded bash>' '<installed hooks/secret-scan>'` (see [scan.md](scan.md#how-it-works) step 2), written with `git config --global --replace-all`. The event set is exactly those two, in that order, however often you run `install`: an old install that has `pre-commit` only gets the second, a stale or duplicate event is removed, and a set that is already exact is not rewritten (the file stays byte for byte as it was). The command stays single-valued. The command is the same form on every platform, so the hook runs under the recorded bash (4.4 or newer) whatever `PATH` the git client has; a relative bash is refused (nothing is written). On Windows both paths are in the mixed form `C:/Users/...`, the form native git keeps. |
| CLI | `~/.local/bin/git-secret-guard` is a symlink to the installed copy. On Windows it is a small wrapper script instead, next to `git-secret-guard.cmd` for PowerShell and cmd. Install then prints `git-secret-guard: CLI: <folder>/git-secret-guard` and one `PATH:` line, and puts the folder on `PATH` where a new shell would not find the CLI otherwise. **Nothing is changed when the folder is already on `PATH`** (`PATH: <folder> is already on PATH; nothing was changed`; trailing slashes do not matter, nor case and the drive-letter spelling on Windows), and your own entry is never duplicated or reordered. **Linux:** no file is changed (most distributions add `~/.local/bin` themselves); when it is missing install says `PATH: <folder> is not on PATH (install changes no file on this platform); to run git-secret-guard by name, add this line to your shell startup file: export PATH="$HOME/.local/bin:$PATH"`. **macOS:** one marked block (`# begin git-secret-guard PATH`, that same `export` line, `# end git-secret-guard PATH`) is appended to `~/.zprofile` for zsh or `~/.bash_profile` for bash, the login shell of the account as `dscl` reports it (not `$SHELL`): `PATH: added a marked block to <file>`. A file that is a symbolic link, not a regular file of yours, over 1 MiB, holding a NUL byte, or already holding our marker without a record of ours is left alone, and so is any other login shell or one `dscl` cannot name: the `is not on PATH (<reason>); ...` line above is printed instead. **Windows:** the folder is appended to the `Path` of your Windows user (never the machine `Path`, no administrator rights; the registry type and every other entry stay as they were): `PATH: added <folder> to the user Path`; when that cannot be done the hint reads `add <folder as a Windows path> to the Path of your Windows user (System Properties, Environment Variables)`; details in [platforms.md](platforms.md#windows-git-for-windows). After a change, and when the user `Path` already held the folder (`PATH: the user Path already holds <folder>; nothing was changed`), a second line says `PATH: a shell opened before this install does not see the change; open a new one`. **`--dont-change-path`** leaves `PATH` alone for that run (`... is not on PATH (--dont-change-path was given); to run ...`), and so does [the unattended install of auto-update](#what-one-run-does) (`the unattended install of update never changes PATH`). A change that fails is reported with its reason and the same hint (marked `▲` in a terminal, `•` for a refusal) and does not make install fail or undo anything else. What install adds is recorded in the state (`cli_path`) right before it is made, never earlier (an install that stops before that step leaves no record), and the earlier record or none comes back when nothing was written; `uninstall` removes exactly what is recorded ([Uninstall](#uninstall)). A file at that path that is not a symlink (on Windows: not the wrapper install writes, at either name) is refused before any change: `... exists and is not a symlink; remove it and run install again`. The CLI finds its share by following that link with `readlink` and `cd -P`, never `realpath` (macOS 12 has none), in at most 40 steps (39 links); a chain that does not end at a file exits 1 with `cannot resolve the location of this script`. |
| Timer | Only with `--with-timer`: two systemd **user** units and `systemctl --user enable --now git-secret-guard-doctor.timer`, see [The weekly timer](doctor.md#the-weekly-timer). Without the flag no unit is written and `systemctl` is never called (when the state already records a timer, its own units or plist are only refreshed if their text changed, never enabled). On macOS the flag installs a LaunchAgent plist in `~/Library/LaunchAgents` and loads it with `launchctl bootstrap gui/<uid>`, see [the launchd section](doctor.md#the-weekly-timer-on-macos-launchd). On Windows install refuses `--with-timer` before any change (`--with-timer needs systemd, which Windows does not have`): see [the Task Scheduler recipe](doctor.md#a-weekly-run-on-windows-task-scheduler). In WSL `--with-timer` needs systemd running and is refused before any change without it, see [WSL](platforms.md#wsl-windows-subsystem-for-linux). |
| Auto-update | Only with `--auto-update` (Linux, macOS, Windows): one more scheduled job of your own user that runs `git-secret-guard update` hourly, two systemd **user** units enabled with `systemctl --user enable --now git-secret-guard-update.timer` on Linux, a LaunchAgent plist loaded with `launchctl bootstrap gui/<uid>` on macOS, one hourly Task Scheduler task on Windows (see [Auto-update on Windows](#auto-update-on-windows)), see [Auto-update](#auto-update---auto-update-and-update) (the per-platform table). Without the flag no job file is written (when the state already records auto-update, its own files are only refreshed if their text changed, never enabled). Refused before any change in WSL without systemd, when the systemd user manager cannot be reached, and without `systemctl`, `launchctl` or `schtasks`. |
| State | `${XDG_STATE_HOME:-~/.local/state}/git-secret-guard/state` (mode 600 in a 700 directory): version, the previous `core.hooksPath` (or `unset`), which tools install itself downloaded, the backup path, the originals it moved aside (`tools_replaced`), the SHA-256 of every file it placed (`tools_placed`), `timer_installed` (`yes` or `no`), `auto_update` (`yes` or `no`), `source_checkout` (the real path of the git checkout install last ran from, empty when it never ran from one) and `cli_path` (what install added to `PATH`: empty, `macos-block <created 0|1> <no final newline 0|1> <file>` or `windows-user-path <text>`; see the CLI row and [the maintainer notes](#maintainer-notes)). |
| Last | The summary (`installed git-secret-guard <x.y.z>`, the hook command, one line per tool: downloaded or kept), then the timer, auto-update, [SmartGit](#smartgit---configure-smartgit-and-restore-smartgit) and [GitHub Desktop](#github-desktop-on-linux---link-desktop-git-and-unlink-desktop-git) steps. All four run even when one fails, and any failure makes the exit status 1; the hook is installed by then. |

Install is idempotent. A second run replaces the files, keeps the config single-valued, downloads nothing that is
already at the pin, and **never overwrites a recorded previous `core.hooksPath`** or forgets which tools it downloaded.
Running it from the installed copy (`git-secret-guard install`) re-installs that copy; on Windows and in WSL 1, where a
directory holding a running script cannot be renamed, that run rewrites only the generated `settings` file (and the `jq`
wrapper on Windows) and leaves the share tree as it is.

**Exit status.** 0 installed; 1 refused (nothing changed, or the message says what did) or a step failed; 2 a usage error;
3 a git upgrade handed off to finish outside install ([below](#upgrading-an-old-git---upgrade-git-and---take-over-system-git));
129, 130 or 143 when a hang-up, Ctrl-C or terminate signal stopped it. A `PATH` change that fails does not change the status; only a state file that
cannot be written does (status 1, the other steps still run). Before the change: `git-secret-guard: PATH: could not write the state file <path> before the PATH change; nothing was written to PATH` (the change is not made and the hint is printed). After a change that failed: `git-secret-guard: PATH: could not rewrite the state file <path> after the PATH change failed; the cli_path record in it is stale (nothing was written to PATH), so uninstall could remove an entry of the same text that you add by hand`.

## Upgrading an old git: `--upgrade-git` and `--take-over-system-git`

On a system whose class has an upgrade module (RHEL, Rocky, AlmaLinux, CentOS and Fedora: [the RPM section of platforms.md](platforms.md#rhel-rocky-and-fedora-rpm);
Ubuntu, Debian and their derivatives: [the apt section](platforms.md#ubuntu-and-debian-apt); WSL running one of those, through that distribution's module: [WSL](platforms.md#wsl-windows-subsystem-for-linux); macOS: `brew install git` or `brew upgrade git` as your user, no takeover since `/usr/bin/git` is protected, [the macOS section](platforms.md#macos-homebrew); Windows: [Upgrading Git for Windows](platforms.md#upgrading-git-for-windows)), `install` no longer stops at an old or missing git. It
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

## SmartGit: `--configure-smartgit` and `restore-smartgit`

SmartGit commits with its own git, so a bundled git older than 2.54 leaves its commits unscanned. After a successful install, `install` looks for SmartGit (see [smartgit.md](smartgit.md) for the full behaviour). Without a flag it prints a hint (no terminal) or the plan and one question (terminal, default No). `install --configure-smartgit` makes the question's answer yes. Order: refusals and the whole plan first, one consent, then Git LFS (if `git lfs version` fails through the git in use: `brew install git-lfs` as you on macOS; on Linux `dnf install -y git-lfs` after a bounded `dnf repoquery` shows an enabled repository offering it, or `apt-get install -y git-lfs` non-interactively, both as root with their full paths in the plan; on Windows nothing is installed, Git for Windows ships Git LFS), a backup with manifest, the two-line edit of `preferences.yml`, and a verify step; any failure restores the backup. The flag exits 1 when it refuses (the install itself is already done); a SmartGit settings directory of a version or platform not recorded gets the manual steps instead of an edit.

The two-line edit runs for the macOS app, a Linux tarball or package and a Windows install (SmartGit 26.1; on Linux and Windows only once its setup wizard has written `startup`; on Windows the value is the `cmd\git.exe` of the Git for Windows in use, written in the backslash form SmartGit writes itself, and no Git LFS is ever installed there: a git without it is refused with the advice to repair Git for Windows). The Linux Flatpak gets its four steps as one unit (a `--user` flatpak override, a marked wrapper running the git in use through `flatpak-spawn --host`, a `smartgit.vmoptions` line, the edit pointing at the wrapper), each recorded in `<state dir>/smartgit/flatpak.record` before it runs. Step 1 removes the SmartGit sandbox, so it needs its own yes: a second question at a terminal (default No) or `--allow-smartgit-sandbox-removal`, which is a usage error (exit 2) without `--configure-smartgit`; without either, the Flatpak is refused with the manual steps and nothing changes. A Snap install is only detected and listed by `status`; no Snap-specific settings location is searched, so nothing is edited for it and it is set by hand (see [smartgit.md](smartgit.md)). `restore-smartgit` and `uninstall` undo the change from the manifests and the Flatpak record in `<state dir>/smartgit/`; both decide every refusal (a manifest, SmartGit running, the Git LFS record) before the first restore, so a refusal changes nothing; `uninstall` restores SmartGit first, before it changes anything else, and after a refusal says to run it again once what it names is fixed. Test seams: `GSG_SMARTGIT_INSTALL_DIRS`, `GSG_SMARTGIT_TOOL_DIR`, `GSG_SMARTGIT_SETTINGS_BASE`, `GSG_SMARTGIT_FLATPAK_BASE`, `GSG_SMARTGIT_LAUNCH_PATH` (the PATH of the Git LFS check). They are announced on stderr as `TEST OVERRIDE active` when one is set and SmartGit is found or `--configure-smartgit` is given, like the download override below; none skips a check.

## GitHub Desktop on Linux: `--link-desktop-git` and `unlink-desktop-git`

GitHub Desktop commits with its own bundled git (2.45.3 in the community build `github-desktop` 3.4.13), which ignores the config hook without a word, so a commit made in Desktop is not scanned. No newer Linux build exists, and Desktop's renderer sets `LOCAL_GIT_DIRECTORY` to its own directory at every start, so a different git cannot be put in its place. What does work (measured with Desktop's real `bin/git`) is `core.hooksPath` passed through the environment: it is scope `command`, it beats a repository's own `core.hooksPath` (a husky directory, scope `local`), and `git config --show-scope --get-all core.hooksPath` still lists the repository's value. Details and the owner's GUI check: [platforms.md](platforms.md#github-desktop-on-linux).

A plain `install` on Linux with Desktop found (the RPM and deb layout, `/usr/lib/github-desktop/resources/app/git/bin/git`) and a bundled git older than 2.54 prints one note naming the flag and, as for every other old git, the warning that its commits are not scanned; it changes nothing (a bundled git whose version cannot be read gets a note too: `... did not report a git version; if it is older than 2.54 its commits are not scanned`). A run with `--link-desktop-git` leaves that warning out for Desktop's git, because it is about to scan those commits; the warning is held and printed once as install exits (`install_cleanup`, on its exit trap) on every outcome except a good link: after a failed self-check and rollback it follows the "was not linked" lines, and it is also printed when install fails earlier or is stopped by Ctrl-C or TERM during the link (a refusal before any change stops install first, with its own message). `install --link-desktop-git` does this, in this order, after the normal install:

1. It writes `<share>/desktop-hooks/`: 27 wrappers, one per hook of githooks(5) except `reference-transaction` (the list is in `lib/integrations/desktop/desktop_git.sh`), and one shared file `gsg-desktop-chain` (the body of `lib/integrations/desktop/desktop-chain.sh` with the scan command filled in). Each wrapper is a relative symbolic link to the shared file, so the hook event is the name it was started under and one bash runs per hook. For `pre-commit` and `commit-msg` the shared file runs the installed `hooks/secret-scan` with the same arguments and blocks on failure; when the running git is 2.54 or newer it skips that, because the config hook already scans. For every event it then runs the repository's own hook, as git would have without our setting. It asks git for the path with one call, `git rev-parse --git-path hooks/<event>`, with only our own `'core.hooksPath=<dir>'` entry removed from `GIT_CONFIG_PARAMETERS` for that call (the user's entries, such as an `include.path` that sets `core.hooksPath`, and Desktop's stay; if our entry is not there exactly once the whole value is emptied), so git's own rules apply (every scope except `command`, an empty value meaning no hook, `~` and `~user/`, worktrees); the answer is relative to the directory the hook runs in. Arguments, standard input and exit status pass through (`exec`). A hook that is missing is success, one that is a file but not executable gets git's own hint (`hint: The '<path>' hook was ignored because it's not set as executable.`, silenced by `advice.ignoredHook=false`), and a git that cannot say where the hooks are makes the wrapper fail with a message instead of skipping the repository's hook. `GSG_DESKTOP_CHAIN_PID` stops a copy of the wrapper in the repository's hooks directory from executing itself for ever (exec keeps the pid, a nested git has another); it is checked after the scan, so a stale value can never skip a scan. `unlink-desktop-git` and `uninstall` also remove the temp links and files an interrupted write left in the directory (`.<event>.new.*` links to the shared file, `gsg-desktop-chain.new.*` copies).
2. It runs the self-check with Desktop's own git, under the environment dugite gives it (`GIT_EXEC_PATH`, `GIT_CONFIG_SYSTEM`, `GIT_TEMPLATE_DIR`, `PREFIX`, all inside Desktop's bundle) plus our `core.hooksPath` in `GIT_CONFIG_PARAMETERS`, in scratch repositories: a fake token in a file is blocked, a fake token only in the message is blocked, a clean commit prints the pass line, a husky-style repository `core.hooksPath` hook and a `.git/hooks/pre-commit` hook still run, and Desktop's credential entries coexist with ours in both branches of its code, the default one (`GIT_CONFIG_COUNT=2` with `credential.helper=` and `credential.helper=desktop`) and the preview one (taken only with `GITHUB_DESKTOP_PREVIEW_FEATURES=1`, which appends `'credential.helper=' 'credential.helper=desktop'` to `GIT_CONFIG_PARAMETERS`). Any failure removes the files of the link (the wrappers, the shared file and the launcher entry, also those an earlier run wrote; only files of ours) and says so (exit 1). On success it prints which checks held.
3. Only then it writes `${XDG_DATA_HOME:-~/.local/share}/applications/github-desktop.desktop`: a copy of the system entry (`/usr/share/applications/github-desktop.desktop`) with a marker line first and every `Exec=` line (in any spelling GLib reads as that key) rewritten to `Exec=env "GIT_CONFIG_PARAMETERS='core.hooksPath=<dir>'" <the original command>`, for the community build `github-desktop %U`. The user data directory wins over `/usr/share`. The argument is quoted for git's parameter syntax, for the Exec double quotes and for the desktop-entry string layer, so a path with spaces, quotes, `$`, backticks, backslashes or `%` survives (tested by launching the entry through GLib). The link needs `iconv` (from glibc or libiconv) to check this: a launcher path or hooks directory that is not valid UTF-8 is refused, because GLib returns no launcher for it and Desktop would start unscanned; without `iconv` the run stops with "iconv is not installed" and changes nothing.

`GIT_CONFIG_PARAMETERS` is used, not `GIT_CONFIG_COUNT`, because Desktop's default branch sets a count of its own and would overwrite one of ours; both branches keep the parameters (measured, and the check covers both). There is no `environment.d` file: it would change every git in the session, not only Desktop's. The launcher's `env` replaces any `GIT_CONFIG_PARAMETERS` you had in the session that starts Desktop. The variable is inherited by whatever Desktop starts (a terminal, an editor); that is harmless, because the system git there is 2.54 or newer, which scans once through the config hook and which the shared file skips.

**A stated limit: `reference-transaction`.** There is no wrapper for it, because git runs that hook up to three times per ref update and each wrapper run costs a few milliseconds (a fetch of 2000 tags was 4000 runs and 50 seconds in the first design). Under the link a repository's own `reference-transaction` hook therefore does not run in Desktop; every other hook of githooks(5) is chained. Measured cost of the rest: [platforms.md](platforms.md#github-desktop-on-linux).

**Refusals, before any change** (exit 1, "nothing was changed"): not Linux (on macOS and Windows see below), Desktop's bundled git not found (only the RPM and deb layout is looked for, not Flatpak, Snap or `/opt`), the system launcher entry unreadable, a launcher path or hooks directory that is not valid UTF-8, a symbolic link or a file at the hooks-directory path (install never writes through it), a launcher file of the user's own at the user path or any file in the hooks directory that is not ours (named, kept, never replaced). The flag needs the normal install, which runs in the same command, so there is no separate "hook not installed" case.

**Ownership.** A wrapper is ours when it is a relative link to the shared file; the shared file and the launcher carry the marker line. Only files of ours are rewritten or removed. A rerun rewrites a file only when its text or mode differs, so a current link changes nothing and the "restart GitHub Desktop" note is printed only when something was written. A plain `install` after that keeps and refreshes the link (the share dir is replaced, the hooks directory is carried over first so a commit in Desktop during an upgrade still finds its wrappers). A run killed after the wrappers and before the launcher leaves the wrappers; `status` says the launcher entry is missing, and the next `install` (flag or not) runs the check and writes it.

**Undo.** `git-secret-guard unlink-desktop-git` removes the launcher entry first, then the wrappers and the shared file, then the directory when it is empty; a file without the marker (a wrapper name, the shared file's name or any other name such as `notes.txt`) is named and kept, and so is the directory around it. `uninstall` does the same before it removes the share dir, and because the hooks directory lives inside the share dir it then stops (exit 1, "uninstall stopped ... move them away and run uninstall again"): the launcher entry and our wrappers are already removed and SmartGit is already restored (those steps run first), while the share dir, the hook configuration and the state stay, so a rerun after the file is moved away finishes the job. The same stop applies to a symbolic link or a file at the hooks-directory path. Neither touches Desktop's files, `/usr` or another launcher file. Desktop must be restarted from the menu to start using or stop using the link; Desktop started any other way (a terminal, an autostart entry that names the program) is not covered.

**macOS and Windows: a note only.** Upstream Desktop 3.6.10 for macOS and Windows embeds git 2.56.0 (read from its code, not run), so nothing is linked. When `install` finds Desktop in the default place (`/Applications/GitHub Desktop.app` or `~/Applications/GitHub Desktop.app`; `%LOCALAPPDATA%\GitHubDesktop`) it prints a note to update Desktop to the latest release; `status` and `doctor` show the same as information. Another place is not found, so no note appears there; the version of the bundled git is not read.

## Auto-update: `--auto-update` and `update`

An install is a copy: it does not move when the checkout it came from does. On a development machine a second user's install
was found several releases behind the checkout. `install --auto-update` (Linux, macOS and Windows) adds an hourly job of your own user that
keeps your install at the newest **released tag** of the checkout it was installed from.

```bash
/path/to/checkout/bin/git-secret-guard install --auto-update   # from the checkout the install is to follow
git-secret-guard update                                      # one cycle by hand: the command the timer runs
cat ~/.local/state/git-secret-guard/update                   # what the last run decided
journalctl --user -u git-secret-guard-update.service         # Linux: the output of every run
systemctl --user list-timers git-secret-guard-update.timer   # Linux: when it runs next
cat ~/.local/state/git-secret-guard/update.log               # macOS: the output of every run, each line stamped with its UTC time
```

`install --auto-update` does the normal install and then:

- **Records** `auto_update=yes` and `source_checkout=<the real path of the checkout>` in the state, before the units are
  written. Every install run from a checkout (a directory with a `.git`) records `source_checkout`, with or without the
  flag; one run from a copy that is no checkout (the installed copy, a tag export) keeps the recorded one. Whenever
  auto-update is on and the recorded checkout changes, also on the first `--auto-update`, install prints
  `auto-update now follows <path>`.
- **Writes one scheduled job of its own** (the table below): two systemd user units on Linux, one LaunchAgent plist on macOS (on Windows a Task Scheduler task, below). Both
  run exactly `"<share>/bin/git-secret-guard" update`, with the `PATH` of the git install found first, then the directories of the recorded tools (see the table), and the same variables as
  [the weekly doctor job](doctor.md#the-weekly-timer) plus the test knob. Every job file carries a marker line, and only files
  with it are ever rewritten, unloaded or removed. Then it enables the job and prints
  `auto-update timer enabled (<job file>); read its output with: <command>`. The absolute path of `systemctl` (`launchctl` on
  macOS) goes into the settings file as `SYSTEMCTL_BIN` (`LAUNCHCTL_BIN`; `SCHTASKS_BIN` on Windows).
- **Prints the linger hint** on Linux only, and does not act on it, see [Linger](#linger).
- **On Windows** a Task Scheduler task takes the place of the two systemd units and of the linger hint, see [Auto-update on Windows](#auto-update-on-windows).

| | Linux | macOS |
|---|---|---|
| Job files | `git-secret-guard-update.service` (one-shot, `TimeoutStartSec=1h`) and `git-secret-guard-update.timer` (`WantedBy=timers.target`) in `${XDG_CONFIG_HOME:-~/.config}/systemd/user/` | `com.lightspeeddms.git-secret-guard.update.plist` in `~/Library/LaunchAgents`, label `com.lightspeeddms.git-secret-guard.update` (the doctor agent's label with `.update` for `.doctor`) |
| Marker | first line `# generated by git-secret-guard install --auto-update; uninstall removes this file` | line 3 `<!-- generated by git-secret-guard install auto-update; uninstall removes this file -->` (an XML comment holds no double hyphen) |
| Schedule key | `OnBootSec=5min`, `OnUnitActiveSec=1h` | `StartInterval` 3600, `RunAtLoad` true |
| First run | right after enable when the machine has been up for 5 minutes, else 5 minutes after boot; then every hour | when the agent is loaded (at install and at each login); then every hour |
| Test knob | `GSG_TEST_UPDATE_INTERVAL_SECONDS=<n>` gives `OnUnitActiveSec=<n>s` | the same knob gives `StartInterval` `<n>` |
| PATH of the job | the same on both: the git directory, the directories of the recorded `jq`, `setsid` and `timeout` (and `bash` on macOS) once each, then `/usr/local/bin:/usr/bin:/bin`; with the tools in those directories the text is what it always was | |
| Enabled with | `systemctl --user enable --now git-secret-guard-update.timer` | `launchctl bootstrap gui/<uid> <plist>`, a loaded agent booted out first |
| Output of a run | the journal: `journalctl --user -u git-secret-guard-update.service` | `update.log` in the state dir: `cat <state dir>/update.log`; runs are appended, each starts with a line `<UTC time> git-secret-guard: update: run started, <version> is installed` and the lines of the run carry their time (not the few bash prints before the update starts, such as a failure to start; [maintainer notes](autoupdate-maintainer.md#maintainer-notes-auto-update)); a log over 1 MiB becomes `update.log.1` before the next run (one earlier file is kept) |
| Linger | yes: the hint at install, a warning in `doctor` ([Linger](#linger)) | none, the agent belongs to the login session |
| Refused before any change | WSL without systemd; no `systemctl`; user manager not reachable | no `launchctl` |

`--auto-update` and `--with-timer` are independent: each has its own job files and its own marker line, and neither implies
the other. A later plain `install` keeps `auto_update=yes`, rewrites a job file only when it is ours and its text changed (it
then says to run `systemctl --user daemon-reload`, or names the `launchctl bootout` and `bootstrap` commands), enables nothing
and never calls the manager. If enabling fails, install says `could not enable <timer unit or label> (<systemctl or launchctl> exit <n>); the hook is installed and scanning; fix the cause and run install --auto-update again`
and exits 1; the state already says `auto_update=yes`, so `uninstall` still removes the job.

`status` and `doctor` report all platforms the same way, from files only: the interval is the schedule key of the job file
(`every 1h`, `every <n>s` under the test knob; a missing or foreign file gives `interval unknown, <file> is missing or not
ours`; on Windows the job file is the wrapper `update-task.cmd`, ours by its marker line, and the interval is the fixed hour), doctor's timer-inactive problem checks that every job file is ours and the schedule key is there (on Linux also the
`timers.target.wants` link), and the age check falls back to the modification time of the schedule file and points at the
output of a run. They read the files, not the manager's loaded state: none of `systemctl`, `loginctl`, `launchctl` and `schtasks` is run,
so a job the user stopped by hand is noticed only when its record goes stale. The linger warning is the one Linux-only item (neither macOS nor Windows has it).

**Refusals, before any change** (exit 1, each message says `nothing was changed`; they are decided before the git
upgrade offers, and the unit checks are repeated with the final git after an upgrade you accepted, where the message says
what that upgrade changed):

| Case | Message |
|---|---|
| WSL without systemd | the `--with-timer` text naming `--auto-update`, see [WSL](platforms.md#wsl-windows-subsystem-for-linux); on WSL 1 it ends `install without --auto-update and run git-secret-guard update by hand` |
| No `systemctl` on `PATH` (`launchctl` on macOS) | `systemctl is required for --auto-update but was not found on PATH` |
| A file at an update unit or plist path that install did not write (also one with the doctor marker) | `<path> exists and was not written by git-secret-guard; move it away and run install again` |
| A path or variable a unit cannot carry (a quote, a backslash, `%`, `$`, a control character; a relative `GIT_CONFIG_GLOBAL`) | as for `--with-timer` |
| Your systemd user manager does not answer `systemctl --user show --property=Version` | `--auto-update needs your systemd user manager, and it cannot be reached (systemctl --user exit <n>: <its first line>); log in with a full session, or have loginctl enable-linger run for your user, then run install --auto-update again` |
| No checkout is recorded and the installer does not run from one | `--auto-update needs a git checkout of git-secret-guard to follow: none is recorded and <dir> is not one; run install --auto-update from the checkout` |

### Owner and follower

The role is decided on every run from the two paths alone: you are the **owner** when your user owns both the checkout
directory and its `.git` directory, and a **follower** otherwise. Nothing records the role and no user acts for another:
there is no root service and no `sudo`, each user's timer runs `update` as that user.

On Windows "owns" is git's own answer, not `[ -O ]`, which is true for a checkout of any account under MSYS (probed with Guest, SYSTEM and
half-owned repositories): the owner is a user for whom `git -c safe.directory= -C <checkout> rev-parse --git-dir` succeeds, that is, the
checkout and its `.git` belong to that user (or to the Administrators group, as git itself accepts for an elevated user). Anyone else is a
follower. A `safe.directory=*` of your own config cannot make another account's checkout yours.

- The **owner** fetches `origin` and fast-forwards the checkout to the newest released tag, then installs.
- A **follower** never fetches, merges or writes to the checkout. It reads it with `git rev-parse`, `git show` and
  `git archive`, each with `-c safe.directory=<the recorded checkout>` on the command line (the exact path, never `*`, never
  written to a config file), and installs only its own copy. It therefore gets a new release on its first run after the
  owner's run has moved the checkout.

A checkout whose `.git` is a file (a linked worktree or a submodule) is recorded by install and skipped by every `update`
(`not-a-plain-checkout`).

### What one run does

1. With `auto_update` not `yes` (or nothing installed) `update` prints `git-secret-guard: auto-update is off`, takes no
   lock, writes no record and exits 0.
2. It takes [the update lock](#the-update-lock); a live holder is the skip `locked`.
3. The recorded checkout must exist and have a `.git` directory, and the installed version (the state's and the installed
   copy's `VERSION`) must be `x.y.z`; this is judged before any fetch.
4. **Owner only.** In this order, the first that holds names the skip: a shallow repository (`shallow`), no `origin` remote
   (`no-origin`), `HEAD` not on `refs/heads/main` (`not-on-main`), changes to tracked files (`dirty`; untracked files do
   not count). Then one bounded fetch (120 seconds, no terminal, `GIT_TERMINAL_PROMPT=0`) of `origin`'s `main` and its `v*`
   tags, never forcing a tag: a failure is `fetch-failed`. A tag moved on `origin` is such a failure (git rejects it, the
   local tag stays), every hour until the local tag is corrected by hand.
5. **Owner only.** The target is the highest **valid** tag that still needs installing. A tag is valid when its name is
   `vX.Y.Z` (digits only), it is merged into `origin/main`, and the `VERSION` file at the tag says `X.Y.Z`. Signed tags are
   not required. None: the result is `current`, and commits on `origin/main` that no tag covers are never merged. If `HEAD`
   is not an ancestor of the tag (local commits, or a checkout pulled past it), the skip is `ahead-of-tag`. Otherwise
   `git merge --ff-only` moves the checkout to the tag's commit: no merge commit, `HEAD` ends exactly at the tag and never
   past it, and the owner's own git hooks run as in any merge.
6. **Every user.** `X` is read from git (`HEAD:VERSION`), never from the work tree. `HEAD` must be the commit of tag `vX`,
   or the skip is `not-at-tag` (the owner is mid-way, or `HEAD` is past a tag). `X` needs installing when it is newer than
   the version the state records **or** newer than the installed copy's `VERSION` (an install that failed while copying
   leaves the two apart); otherwise the result is `current`.
7. The tag is exported with `git archive` into a private directory in the state dir, and the installer **of that export**
   runs as a child: `install` with no flags and no input, for at most 30 minutes. It can therefore never upgrade git, take
   over the system git or replace a `core.hooksPath`, and it never changes `PATH` (its `PATH:` line says `the unattended install of update never changes PATH`,
   and the line is in the child's output; a person's own `install` adds the entry). The result is `updated` only when the child exits 0 **and** the
   installed `VERSION` is `X`; anything else is `failed` with `install-failed`, the previous copy stays live (a commit with a
   secret is still blocked) and the next run tries again. There is no backoff.
8. The record is written, one line is printed (`update: updated 1.0.0 -> 1.1.0`, `update: current, 1.0.0 is installed`,
   `update: skipped (dirty):  M lib/cli/usage.md`; a failure goes to stderr), and the lock is released. The installer's own
   output and git's error lines are in the journal too.

**Exit status of `update`.** 0 for `current`, `updated` and `skipped` (a skip is a decision, not an error; the unit is not
shown as failed); 1 for `failed`, and when the record cannot be written or the lock not released; 2 for a usage error
(`update` takes no arguments); 129, 130 or 143 when a signal stopped it (no record is written then; a signal during the
child install is acted on only when that install returns or times out).

### The update record

`${XDG_STATE_HOME:-~/.local/state}/git-secret-guard/update` (mode 600) is replaced by every run that gets past step 1,
skips included, by renaming a temp file over it; the `state` file is never written by `update` itself. `status` shows it as
the `last check:` line ([status](#status-and-version)); `doctor` judges its age ([doctor.md](doctor.md#machine-checks)).

```
checked_at=2026-11-15T17:00:04Z
role=owner
result=updated
reason=
detail=
from=1.0.0
to=1.1.0
```

| Key | Value |
|---|---|
| `checked_at` | when the record was written, UTC |
| `role` | `owner` or `follower`; empty when the run ended before the checkout could be judged |
| `result` | `updated`, `current`, `skipped` or `failed` |
| `reason` | one word from the table below; empty for `updated` and `current`, and for a `failed` the list has no word for |
| `detail` | one line, control characters replaced by `?`, at most 160 characters: git's or the installer's first error line, or a sentence of ours |
| `from` | the `VERSION` of the installed copy when the run started |
| `to` | the version aimed at, empty when the run ended before one was known |

| `reason` | `result` | Means | Who |
|---|---|---|---|
| `locked` | skipped | another `update`, `install` or `uninstall` of this user holds the lock | all |
| `checkout-missing` | skipped | no checkout is recorded, or it is gone or has no `.git` | all |
| `not-a-plain-checkout` | skipped | `.git` is not a directory (a worktree or a submodule), the detail reads `<co>/.git is not a directory or no repository`; on Windows also a directory git does not take as a repository (an empty or damaged `.git`) | all |
| `bad-version` | skipped | the state's version, the installed `VERSION` or `VERSION` at `HEAD` is not `x.y.z` (`1.0.0-rc2`), or `HEAD:VERSION` cannot be read | all |
| `shallow` | skipped | the checkout is a shallow clone | owner |
| `no-origin` | skipped | there is no `origin` remote | owner |
| `not-on-main` | skipped | `HEAD` is detached or on another branch | owner |
| `dirty` | skipped | tracked files are changed or staged; the detail is the first `git status` line | owner |
| `fetch-failed` | skipped | the fetch failed or ran out of time; the detail is git's first error line | owner |
| `ahead-of-tag` | skipped | `HEAD` is not an ancestor of the target tag | owner |
| `not-at-tag` | skipped | `HEAD` is not the commit of the tag its `VERSION` names | all |
| `install-failed` | failed | the export failed, the child install exited non-zero, or it exited 0 and the installed `VERSION` is not the target | all |
| (empty) | failed | a git command that should not fail did (`merge --ff-only`, `merge-base`, `status`, `tag`), `HEAD` is not at the tag after the fast-forward, the settings, `timeout` or `setsid` are unusable, or the lock could not be made; the detail says which | all |

After every skip the installed copy, the checkout's `HEAD` and work tree and the `state` file are as they were. A failed
fetch can still have moved `refs/remotes/origin/main` (observed with a rejected tag).

### The update lock

`update.lock` in the state dir is a symbolic link named after the pid of its holder, held for a whole run. `update` makes
one attempt and never waits: a live holder is the skip `locked`, and so is a directory (or a link to one) at the lock
path (detail `a directory, not a lock, is at <path>`; move it away, nothing is created inside it). A lock whose holder
is dead, or that is older than 120 minutes, is taken over. `install` (once a state dir exists) and `uninstall` take the
same lock, so a hand install during an update run is refused (`install did not get the update lock <path> and stops here; run install again once no other run is active`),
and so is an uninstall. Only the child install of the run that holds the lock is let in.

### Auto-update on Windows

On Windows (Git for Windows bash) `install --auto-update` registers one hourly **Task Scheduler** task of your own user in place of the
systemd units, and the rest is the same: the cycle above, the update record, the lock, `status` and `doctor`.

```bash
bin/git-secret-guard install --auto-update           # from the checkout; Git Bash
git-secret-guard update                              # one cycle by hand (cmd and PowerShell: git-secret-guard.cmd update)
schtasks /Run /TN git-secret-guard-update            # one cycle through the task (only while you are logged on, see below)
type %USERPROFILE%\.local\state\git-secret-guard\update.log   # the output of the runs, each line stamped with its UTC time (cmd)
```

- **The task** is `git-secret-guard-update`, created with `schtasks /Create /TN git-secret-guard-update /SC HOURLY /TR "<wrapper>" /F`.
  `/F` is always given (without it schtasks asks a question). The task has no password and no elevation: it runs as you, **only while you
  are logged on**, the Windows counterpart of [Linger](#linger). Task Scheduler's defaults also apply (no start on battery power).
- **What install prints.** On Windows the `auto-update timer enabled` line is replaced by two:
  `auto-update task registered (git-secret-guard-update, every hour); its output goes to <state dir>/update.log` and
  `the task runs only while you are logged on`.
- **The first scheduled run is one hour after install.** The task's trigger starts at the minute of the install and repeats every hour;
  `schtasks /Query /TN git-secret-guard-update /V /FO LIST` shows the `Next Run Time`.
- **With nobody logged on nothing runs, and for the first hours nothing says so** (measured on Windows Server 2019 with the real Task Scheduler,
  [platform-testing.md](platform-testing.md#auto-update-through-the-real-task-scheduler)). `schtasks /Run /TN git-secret-guard-update` still answers
  `SUCCESS: Attempted to run the scheduled task "git-secret-guard-update".` and exits 0, but the task is not started: its `Last Run Time` and
  `Last Result` do not change and no `update.log` is written. A trigger time is skipped the same way (seen with a replaced trigger). 13 minutes
  after such an install `status` still showed `ok` and no `last check:` line, and `doctor` `ok` with `no update run is recorded yet`, both with
  exit 0. Doctor's age rule (no run recorded and the wrapper older than 3 × the interval + 1h, [doctor.md](doctor.md#machine-checks)) is there to
  report such a task as `timer inactive`; these runs did not last long enough to see it. A run that happened is known by its lines in
  `update.log` and by the `last check: <UTC time> <result>` line of `status`; while both are missing, no run has happened. A login over ssh with
  a key is not a logon in this sense, so the task of a machine reached only that way never runs.
- **The action is a wrapper**, `update-task.cmd` in the state dir, because a task runs no shell. It sets `HOME` (the logon profile's may differ, and the child install writes the CLI link under it), the XDG variables and
  `GIT_CONFIG_GLOBAL` this install ran with, runs `"<Git for Windows>\bin\bash.exe" "<share>/bin/git-secret-guard" update` and
  appends both streams to `update.log` beside it. After the run a line of `cmd` moves a log over 1 MiB to `update.log.1` (one earlier file is kept,
  an older one is replaced), so the log never grows without bound; the wrapper exits with the status of `update` either way. `update` itself stamps the lines of its output with its UTC time and starts a run with
  a line `<UTC time> git-secret-guard: update: run started, <version> is installed` (lines bash prints before `update` starts carry no time; see the
  [maintainer notes](autoupdate-maintainer.md)). A directory at `update.log.1` defeats the rotation (`cmd`'s `move` would put the log inside it): remove it. A wrapper of an earlier install overwrote the log of the last run; the
  child install of the update that brings this version rewrites it (a plain install does too). The
  wrapper lives in the state dir, not in the share: a running wrapper would hold the share directory. Line 2 is the marker
  `rem generated by git-secret-guard install --auto-update; uninstall removes this file`; only a file with it is ever rewritten or removed. Line 3 is `setlocal DisableDelayedExpansion`, so a `!` in a path survives a cmd with delayed expansion on; a wrapper of an earlier install lacks it and a plain install writes it again.
- **`GSG_TEST_UPDATE_INTERVAL_SECONDS` is ignored.** `/SC HOURLY` cannot express seconds, so install announces
  `GSG_TEST_UPDATE_INTERVAL_SECONDS is ignored on Windows; the update task runs every hour` on stderr and the schedule stays hourly.
- **Refusals, before any change** (in addition to the ones above): no `schtasks` on `PATH`; a task named `git-secret-guard-update` that
  does not run our wrapper; a file at the wrapper path without the marker; a task action longer than the 261 characters `schtasks /TR`
  takes (shorten the state dir with `XDG_STATE_HOME`); a path or variable the wrapper cannot carry (a quote or a control character).
  `--with-timer` stays refused on Windows, and `--auto-update` stays independent of it.
- **A plain install** over a recorded auto-update rewrites the wrapper when it is ours and its text changed, and never calls `schtasks`.
- **`status` and `doctor` run no `schtasks`.** They read files: the wrapper and its marker (the interval is always `1h`), the update
  record and its age, and the age of the wrapper when no run is recorded. A missing or foreign wrapper is the timer-inactive problem; its fix is `install --auto-update` (a foreign file is to be moved away first), and only the age
  findings name `update.log`. There is no linger warning on Windows.
- **`uninstall`** deletes the task (`schtasks /Delete /TN git-secret-guard-update /F`, with the `SCHTASKS_BIN` of the settings) only when it
  runs our wrapper, then removes the wrapper, the log and `update.log.1`, the record and the state dir. A task or wrapper that is not ours is named and left; a
  refused delete keeps everything for a rerun. A task you deleted yourself is not an error. Real `schtasks` exits 1 both for a missing task
  and for a failed query, so the task is looked up in the list of all tasks (`/Query /FO CSV /NH`, which succeeds while Task Scheduler
  answers) by its exact name. When that list cannot be read, `install` refuses before any change (`could not ask Task Scheduler whether the
  task ... exists`) and `uninstall` keeps the wrapper, the share dir and the state and exits 1.

### Linger

A systemd user manager, and with it the timer, runs only while the user has a session. Install prints

```
git-secret-guard: the updater runs only while you have a session; to keep it running after you log out, run: loginctl enable-linger
```

and never runs `loginctl` itself. Without linger an install is not updated while its user is logged out. Where no user
manager answers at install time, `install --auto-update` refuses with the "cannot be reached" message above.

### The two-checkout setup

On a development machine keep **two checkouts**: one you work in, and one used **only to run the installer**
(`install --auto-update` from it, by every user who is to follow it). The updater needs its checkout on `main`, clean and
never ahead of the tags: a work checkout on a branch, with edits or with local commits answers `not-on-main`, `dirty` or
`ahead-of-tag` every hour and nothing is updated. Do not `git pull` the installer checkout by hand either: a `HEAD` past the
last tag makes every follower skip with `not-at-tag`, and the owner with `ahead-of-tag`, until a newer tag exists. The
updater moves it itself, to tags only.

Other users need read access to the checkout and its `.git` (and search permission on the directories above it). They run
its `bin/git-secret-guard install --auto-update` themselves; `update` never acts on another user's install.

### Trust

- **The owner of the checkout is trusted by every follower.** A follower runs the installer the owner's repository holds,
  as the follower. `git archive` **does run the filters the checkout's own configuration names** (observed with git
  2.56.0: a filter set in `.git/config` and assigned in `.git/info/attributes` ran during `git archive --format=tar <tag>`;
  `export-subst` was expanded and `export-ignore` files left out, too). A follower's git reads that same configuration,
  because it is given `safe.directory` for the checkout. An export is therefore not "just the tag".
- **A group-writable `.git` (mode 775) makes every member of the group trusted.** Any member can plant a tag, a filter or a
  hook there; the owner's `update` runs the checkout's hooks during the fast-forward, and every follower's `update` runs the
  filters and the installer. A follower does not check tags against the remote. Keep `.git` writable by the owner alone
  unless you trust the whole group as you trust the owner.
- **Whoever can push a `vX.Y.Z` tag that is merged into `origin/main` decides what gets installed.** Tags are not required
  to be signed and no signature is checked.
- A moved tag is never followed: the fetch does not force tags, so it fails (`fetch-failed`) and nothing is installed.

### An SSH origin

The fetch has no terminal and `GIT_TERMINAL_PROMPT=0`, and the unit passes on only `PATH`, the `XDG_*` variables and
`GIT_CONFIG_GLOBAL` that were set at install time, not your shell's `SSH_AUTH_SOCK`. An SSH `origin` whose key needs an
agent or a passphrase therefore cannot authenticate from the timer: every run is `skipped` with `fetch-failed` and git's
first error line as the detail, and the origin URL is never rewritten. Use an **HTTPS origin** for the installer checkout, or
a **deploy key without a passphrase** that ssh finds by itself (an `IdentityFile` in `~/.ssh/config`). `git-secret-guard update`
typed in your own shell keeps that shell's environment, its agent included, so a run by hand can fetch where the timer cannot.

### Uninstalling it

`uninstall` takes the update lock before it changes anything, and with `auto_update=yes` recorded it disables and removes
the update units (and a dangling `timers.target.wants` link to our timer) before the doctor timer and the share dir, then
the update record with the state: see [Uninstall](#uninstall). There is no command that only turns auto-update off;
`systemctl --user disable --now git-secret-guard-update.timer` stops the runs and leaves it recorded (on Windows, `schtasks /Change /TN git-secret-guard-update /DISABLE`).

**Test-only override.** `GSG_TEST_UPDATE_INTERVAL_SECONDS=<1..999999>` at install time makes the timer run every that many
seconds; it is announced on stderr (`TEST OVERRIDE active (GSG_TEST_UPDATE_INTERVAL_SECONDS=[20]); the update timer runs every 20 seconds, not hourly`),
written into the update job (an `Environment=` line of the service, an `EnvironmentVariables` entry of the plist on macOS) so that the child install keeps it, and any other value refuses
before any change. For users the hour is fixed. On Windows the knob is ignored, see [Auto-update on Windows](#auto-update-on-windows). Internals: [maintainer notes](autoupdate-maintainer.md).

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

`tools.lock` holds one line per tool and platform: name, version, platform, SHA-256 of the vendor's release asset (a tarball for the scanners; betterleaks ships a `.zip` for Windows), and for the scanners a fifth column, the SHA-256 of the binary extracted from it (computed locally from the verified archives on 2026-11-13, not vendor-published; checked on install, used to recognise a scanner an earlier `uninstall` kept; [maintainer notes](#maintainer-notes))
(the archive checksums are the vendors': trufflehog fetched 2026-10-30, betterleaks 2026-11-02, the Windows rows 2026-11-02 and 2026-11-03; vendors name platforms differently, `linux_amd64` against `linux_x64`).
The current pins are trufflehog 3.99.2 and betterleaks 1.9.0.
Linux x86_64 and arm64, macOS arm64 and Windows x86_64 are used; the macOS x86_64 rows are used on an Intel Mac (tested on macOS 12.7.6: [platforms.md](platforms.md#homebrew-on-an-intel-mac)). The `jq` row (1.8.2, a bare `.exe`) is Windows only: elsewhere `jq` is a system prerequisite. The `git` and `git-manpages` rows (2.56.0, platform `source`) and the `git-for-windows` row (the 2.56.0.4 installer, with its Authenticode signer on a `# gsg-signer` comment line) serve [`--upgrade-git`](#upgrading-an-old-git---upgrade-git-and---take-over-system-git), not the scanners. A lock that is unreadable or has a
malformed line anywhere is refused as a whole; two rows for the tool and platform being looked up are refused as
ambiguous (duplicates for another platform are not looked at), and a missing row is a refusal, never a skip.

**Test-only overrides.** `GSG_TOOLS_BASE_URL` (a directory URL such as `file:///tmp/fixtures`, tarballs named like the
vendor's) and `GSG_TOOLS_LOCK` (a lock file) let the test suite install from local fake tarballs. They are announced
on stderr (`TEST OVERRIDE active`) and **cannot skip verification**: every download is still verified against *some*
lock, and the checksum has to match, so an override alone only changes where the tarball comes from or which lock is
trusted. Without the base-URL variable curl is restricted to `https` (`--proto =https`, also across redirects). Do not
set either in production: they change which lock you trust and where you download from. The other test seams are
announced the same way: `GSG_GITUP_ROOT`, `GSG_GITUP_BUILD_PATH`, `GSG_GITUP_QUERY_TIMEOUT` and `GSG_OS_RELEASE` (the git upgrade: system
paths move and the current user counts as the trusted owner), `GSG_WSL_OSRELEASE`, `GSG_WSL_INTEROP` and `GSG_WSL_SYSTEMD_DIR` (WSL detection), `GSG_WINPATH_ROOT` (a directory whose `windows/System32` holds the Windows PowerShell that changes the user `Path`; it skips no check),
`GSG_TEST_UPDATE_INTERVAL_SECONDS` (the interval of [the auto-update timer](#auto-update---auto-update-and-update)), and
the SmartGit ones listed [above](#smartgit---configure-smartgit-and-restore-smartgit).

## Uninstall

```bash
git-secret-guard uninstall                 # keeps the scanners
git-secret-guard uninstall --remove-tools  # also removes the scanners that install itself downloaded
git-secret-guard uninstall --keep-system-git  # only with a system git takeover: uninstall anyway and print its undo by hand
```

While a [system git takeover](#upgrading-an-old-git---upgrade-git-and---take-over-system-git) is active or half done,
uninstall changes nothing, exits 1 and names `restore-system-git` (run it first) and `uninstall --keep-system-git` (leave the
takeover in place; the commands that undo it by hand are printed, since uninstall removes `restore-system-git`).

Removes the `hook.git-secret-guard` section from the global config, restores the recorded previous `core.hooksPath`
**verbatim** (or leaves it unset when none was recorded), and removes the share dir, the CLI link and the state file, together with doctor's findings record (`findings`), its
leftover `findings.XXXXXX` temp files, and the update record (`update`) with the leftovers of a killed `update` run. Uninstall takes `update.lock` and then `findings.lock`
**before it changes anything** (a dead or old lock is
taken over). When a live doctor run holds the findings lock, or a live `update` or `install` run [the update lock](#the-update-lock)
(`uninstall changed nothing: it did not get the update lock <path>; run git-secret-guard uninstall again once no other run is active`),
uninstall changes nothing (the hook section, the CLI link, the share dir and
the state all stay), exits 1 and says to run `git-secret-guard uninstall` again; the installed CLI is still there, and the
rerun finishes once the run is gone.
`trufflehog` and `betterleaks` (on Windows also a `jq.exe` install downloaded) stay unless `--remove-tools` is given; then only the ones the state lists as downloaded by
install onto an empty path are removed (`--remove-tools` has to be given on the run that removes the state, since the
record is gone afterwards). A tool is deleted only when it is a regular file whose SHA-256 is one install recorded for
it. Your own build of the same version, a symlink, or any file install cannot prove it placed (for instance when the
state comes from an older install that recorded no hashes) stays, and uninstall says `<path> is not the file install put
there; left in place` (or that no hash was recorded).

A scanner that an earlier `uninstall` kept is install's own again after the next `install`, when it is a regular file (not a link)
whose SHA-256 equals the one `tools.lock` names for the binary of the pinned version: the next `install` records it, so
`--remove-tools` removes it and a pin bump replaces it in place. Any other file, a link, or a scanner kept from an
**older** pin (the new lock names another binary) is yours: it stays, and a bump moves it aside, and `uninstall` puts it back.
As for `jq`, the test is the hash alone, so a byte-identical copy you put there yourself counts as ours.

- **Your own scanner comes back.** A file install moved aside as `<tool>.gsg-replaced-<UTC stamp>` is moved back over
  the tool install put there, on every uninstall, with or without `--remove-tools`: same bytes, same mode. This happens
  only while the path still holds exactly the file install last placed (its recorded `tools_placed` SHA-256) or nothing. The **first** original ever moved aside is the one restored; if a later file of yours had to be moved aside too, it is only reported and kept. If you
  changed it since (or made it a symlink), it is left alone, the original stays aside, and the message says where. A
  missing original is reported and the tool at the path is left, never deleted. If an install stopped before it moved
  your file (the state is written first), uninstall says `the planned move of <path> never happened; it is still in
  place`: your file never left its path. After an interrupted upgrade both the old and the new hash of a tool count as
  install's own until a rerun confirms the placement, so install never mistakes its own half-upgraded file for yours. A scanner install did not replace is
  never touched.
- **Order.** After the takeover check, the update lock and the findings lock: SmartGit is restored, the GitHub Desktop link is removed,
  the recorded `core.hooksPath` is restored, the `hook.git-secret-guard` section is removed, then the auto-update timer and the
  weekly timer (or the LaunchAgent),
  the CLI link (and on Windows `git-secret-guard.cmd`), the `PATH` entry, the share dir, the moved-aside originals are put back, the
  downloaded tools go (`--remove-tools`), on Windows the files of a git upgrade hand-off (`handoff.txt`, `Git-*-64-bit.exe`),
  and last doctor's findings record, the update record and the state file. A step that fails stops uninstall there, so a rerun finds what is
  left. The `core.hooksPath` restore comes before the hook section is removed. If git refuses the restore, uninstall stops with `core.hooksPath not restored`, the hook config, share dir and
  state stay, commits stay scanned, and running `uninstall` again finishes the job.

- **The backup is kept.** Uninstall removes the state *file* but not the state directory when it still holds
  `hooks-path-backup-*.tar.gz`; it prints the tarball's location. It is the safety net for your old hooks directory.
- A `core.hooksPath` that was set again after install is **not overwritten** by the recorded one (a notice is printed).
  Without a state file the global `core.hooksPath` is left alone, because nothing says what it used to be.
- A link or file at `~/.local/bin/git-secret-guard` that install did not create is left in place and reported.
- **The `PATH` entry** (only when the state's `cli_path` names one; with no record nothing is touched, whatever a startup file or the `Path` holds) goes right after the
  CLI link and before the share dir, and only what the record names, only while it is unchanged. On macOS the exact marked block install wrote is cut from the
  recorded file and every other byte stays (a file install created is removed again when nothing else is in it): `removed the marked PATH block from <file>`, or
  `... from <file> and the file itself, which install created`. A block you edited, a marker without the block (also a marker line with a changed ending, as a CRLF conversion or a trailing space makes), or a file that is now a symbolic link, not a regular
  file of yours or unreadable is left as it is and named (`<file> has the PATH marker but not the block install wrote; left as it is`); a block already gone says
  nothing. A record that names any file but `~/.zprofile` or `~/.bash_profile` of the account (a hand-edited state) touches nothing and is named:
  `the record names <file>, which is not ~/.zprofile or ~/.bash_profile; left as it is`. On Windows the recorded text, or the one entry equal to the folder byte for byte with one adjacent separator, is cut from the user `Path` (entries added after
  install stay): `removed <folder> from the user Path`, with `; running programs could not be told, so sign out and in` when the broadcast failed. An entry you respelled
  is named and left: `the user Path holds <folder> in another spelling than install wrote; left as it is`. `<folder>` is the folder of the record in its Windows form (`C:\Users\...`), not the folder of the install that runs uninstall. A write that fails stops uninstall (`cannot take the PATH block
  out: <reason>; fix that and run git-secret-guard uninstall again`, on Windows `cannot take the folder out of the user Path: <reason>; fix that and run git-secret-guard uninstall again`): the state stays and a rerun
  finishes the job. On Windows uninstall stops there and removes nothing after that step (the share dir, the state file and the rest stay) while PowerShell cannot answer. When
  Windows PowerShell can never run on the machine, delete the `cli_path=` line from the state file (`${XDG_STATE_HOME:-~/.local/state}/git-secret-guard/state`, the State row
  above), take the entry out of your user `Path` by hand (System Properties, Environment Variables), then run `git-secret-guard uninstall` again.
- A second run reports `nothing to do, git-secret-guard is not installed` and exits 0. A malformed state file is
  refused with nothing changed (a `cli_path` that is no record of ours is one, a Windows record whose folder is not an absolute Windows path without `;`, `%`, `"` or a control character included).
- **The weekly timer** (only when the state records `timer_installed=yes`) is disabled and removed right after the hook
  config and before the share dir (on macOS the LaunchAgent is booted out and its plist removed at the same point):
  [the details are in the doctor chapter](doctor.md#the-weekly-timer). Without a recorded timer,
  uninstall never calls `systemctl`.
- **The auto-update timer** (only when the state records `auto_update=yes`) goes the same way, just before the weekly
  timer, so the updater is stopped before anything else of the install is removed: `systemctl --user disable --now
  git-secret-guard-update.timer` with the recorded `systemctl`, then the two unit files, only those carrying the
  `--auto-update` marker line (another file at that path is named and left; a `timers.target.wants` link to our timer whose
  unit file is already gone is removed). A failing `disable` stops uninstall with the units, the share dir and the state in
  place. The update record goes with the state, whatever `auto_update` says, and with it what a killed `update` run left
  beside it: `update-tmp.XXXXXX` files and `update-work.XXXXXX` directories (the export of a tag). Only a real directory of
  that name is removed; a link or a file there is named (`... is not a directory an update run made; left in place`) and
  kept, and the state dir then stays too.
- **On macOS** the same order holds with the LaunchAgents: with `auto_update=yes` recorded, the update agent is booted out
  (`launchctl bootout gui/<uid>/com.lightspeeddms.git-secret-guard.update`), its plist (marker line of `--auto-update`) and
  `update.log` and `update.log.1` are removed (a regular file only, never a link), then the doctor agent is handled as before. A plist that is not ours is named and left.

## `status` and `version`

`git-secret-guard status` names the git in use (the first on `PATH`, shown below `/usr/bin` where `/bin` is a link) and its version on every run, then prints the installed version, the share dir, the hook command path, the hook libraries, whether the global config matches (both events, in either order, and the command install would write), whether git runs the hook (below), the
recorded previous `core.hooksPath`, the **effective** `core.hooksPath` (every global-scope value with the file it
lives in, also from the XDG config and included files; informational, config hooks run whatever it says), the backup
path, the tools installed by us, the originals install moved aside, and each tool's path with its detected and
pinned version, followed by the `system git takeover`, `SmartGit install`, `SmartGit settings` and `GitHub Desktop` lines where they apply,
the auto-update lines (`auto-update: off`, or `auto-update: on (checkout <path>, every 1h)` with the interval read from the job file
(the timer unit, the plist on macOS, or the wrapper on Windows), `<n>s` under the test knob, followed by `last check: <checked_at> <result> <reason>` from [the update record](#the-update-record)
when one exists; information only: a stale updater or an install behind its checkout never changes the exit status, `doctor`
reports those), and a `git build` line with the next step when a source build of git was interrupted while it was copied (information only). Without a state
file it prints `not installed (no state file at <path>)` (plus a takeover line if there is one) and exits 1. A tool counts as `ok` only when it reports the pinned version the way install judges it (the version
as a whole word, or with a `v` prefix), so `8.30.1-rc1` is a `MISMATCH` here exactly as install would replace it. It exits 0 when everything matches and 1 when it is not installed or a line says `MISMATCH` or
`MISSING`. A `SmartGit settings` line for a directory it cannot judge (a symbolic link, not yours, or an unknown shape of `preferences.yml`) says `cannot tell whether SmartGit's commits are scanned` and gives the check by hand (Preferences, Commands, *Git Executable* must be a git 2.54 or newer); it does not change the exit status, since an exit 1 you could not clear would be wrong. A `SmartGit settings` line that says `commits are NOT scanned MISMATCH` exits 1 only while a SmartGit installation is found (a settings directory without one is left over). `git-secret-guard version` (also `--version`) prints `git-secret-guard <x.y.z>` from the `VERSION` file and exits 1 when that file is not `x.y.z`. `git-secret-guard help` (also `--help`, `-h`) prints `lib/cli/usage.md`. `status` looks at the machine (the
installation, the git in use and the hook as git resolves it); the repositories are the job of [`doctor`](doctor.md).

### Sections, levels and the summary

The output is grouped under `install:`, `git:`, `tools:`, `clients:` (SmartGit and GitHub Desktop, only when there is a line) and
`auto-update:`, as `doctor` groups its `machine:` lines, and ends with `summary: N problems, M warnings` (`1 problem`, `1 warning` in the
singular). Every line has one of the four levels `doctor` already uses, written `  <level padded to 8> <label>: <text>`:

| level | terminal | plain | meaning |
|-------|----------|-------|---------|
| problem | red `✗` | `PROBLEM` | commits may go unscanned; the exit status is 1 (the wording `MISMATCH` / `MISSING` stays in the text) |
| warning | yellow `▲` | `WARNING` | the user should act; never changes the exit status |
| ok | green `✓` | `ok` | checked and good: the git in use, the hook command, the hook libraries, the global config, each tool, `bash`, `GNUBIN_DIR` and the `rule file` (the share's betterleaks rule file against the SHA-256 install recorded; a difference or a missing record is a PROBLEM, wording in the maintainer notes), a SmartGit settings directory that is scanned, a GitHub Desktop link that is current (Linux), `auto-update: on` |
| info | dim `•` | `info` | everything else: share dir, previous `core.hooksPath`, the effective `core.hooksPath`, backup, tools installed by us, originals moved aside, conditional includes, the lines locating a disabled hook, a takeover that is active or absent, SmartGit install and left-overs, `auto-update: off`, and a last check that is `current`, `updated` or `skipped` |

WARNING lines: the GitHub Desktop update advice on macOS and Windows, a GitHub Desktop on Linux whose bundled old git is not linked, an interrupted `git build` copy, `auto-update: on` with an
unknown interval, an update record that cannot be read, a last check that `failed`, and a SmartGit settings directory that cannot be judged,
whose git version could not be read, or that is not scanned while no SmartGit installation is found (as `doctor` grades them). The exit status is 1
exactly when a PROBLEM line was printed (`STATUS_PROBLEMS` counts them in `status_line`); a not-installed machine prints one `installed:` PROBLEM
line, the `git:` section and the summary. `last check` shows the recorded reason and detail of a skip or a failure, for example
`last check: 2026-11-15T17:00:04Z skipped locked: process 4242 holds <state dir>/update.lock`.

When the CLI folder is not on the `PATH` the command runs with, `status` adds one `info` line to the `install:` section (never a warning, never an exit status):
`  info     CLI folder: <folder> is not on the PATH this shell runs with, so git-secret-guard is found by its full path only; <hint>`, where the hint is the one `install`
prints (the line to add on Linux and macOS, the user `Path` step on Windows). A shell opened before the install shows it too; with the folder on `PATH` the line is not printed.

**Terminal mode** (`lib/core/common.sh`: `ui_terminal`, `ui_mark`, `ui_prefix`): the icon replaces the level word and only the icon is coloured.
It applies to a stream that is a terminal (`[ -t 1 ]` for `status`, `doctor` and install's stdout lines, `[ -t 2 ]` for stderr lines) or when `CLICOLOR_FORCE`
is non-empty, unless `NO_COLOR` is non-empty (it wins), `TERM` is unset or `dumb`, or the first non-empty of `LC_ALL`, `LC_CTYPE`, `LANG` does not name UTF-8.
It is decided once per process and stream. Pipes, `journald`, `doctor.log`, `update.log` and the test suite get the plain text, which is
byte-identical to what each command printed before. In terminal mode `install`, `uninstall`, `restore-system-git`, `restore-smartgit`,
`unlink-desktop-git` and `update` mark a line they print anyway and never add one, so the lines are the plain ones: `✓` on the final success line or the "nothing to
do" / "nothing to restore" / "nothing to unlink" line (uninstall: `removed the state`; restore-smartgit: each restored or already-original line), `▲` on the git
upgrade hand-off line (exit 3). Refusal and failure lines of these commands are not marked: no helper prints them, each call site prints its own text. `update`
marks its outcome line `✓` for `current` and `updated`, `•` for every skip and `✗` (stderr) for `failed`, as `status` grades `last check`. The child `install` of
`update` runs without `CLICOLOR_FORCE`, so its output, `update.log` and the record's detail stay plain.
The hint to run `loginctl enable-linger` and the GitHub Desktop notes get `▲`.

Besides the `MISMATCH` and `MISSING` lines above, `status` reports whether commits can be scanned, and exits 1 for each of these cases:

- **The git in use.** On an installed machine every run prints `git in use: <path> (git <version>)`. A git older than 2.54 ignores
  config-based hooks without any message; the line then says `MISMATCH`, that commits made with it are not scanned and to run
  `install --upgrade-git`, and the exit status is 1. A version that cannot be read is the same `MISMATCH`. The hook check below is
  skipped then, so there is one clear line (and below git 2.26, which has no `--show-scope`, the `core.hooksPath` line says it was not
  read). Only the first git counts: a second, older git later on `PATH` (the package git 2.52 stays reachable next to a build in
  `/usr/local`) does not change `status`; [`doctor`](doctor.md) lists it. With no git on `PATH` at all `status` prints
  `git is not on PATH` on stderr and exits 1.
- **A hook git does not run.** `status` does not judge an `enabled` value; it asks git. It writes an empty bare repository by hand (`HEAD`, `objects/`, `refs/`; never `git init`, which writes `HEAD` and fires the user's `reference-transaction` hooks, from `core.hooksPath` and from config) in
  `TMPDIR`, removes the repository variables of the caller (`GIT_DIR`, `GIT_COMMON_DIR` and the like, and `GIT_DEFAULT_HASH`
  and `GIT_DEFAULT_REF_FORMAT`, which only break the new repository; `GIT_CONFIG_COUNT` and `-c` settings stay), and reads
  `git hook list pre-commit` and `git hook list commit-msg` there (one probe repository for both events, one verdict each; a
  disabling key that switches off both is named once). It runs from the current directory with absolute paths, so a relative `PATH` entry for git
  works. System, global and command-line config therefore count, a repository's own config does not, and neither does a conditional include (`includeIf`): that is `doctor`'s job (known limits below).
  Exit 1, with a `hook enabled: MISMATCH` line, when git lists the hook as `disabled` (`hook.git-secret-guard.enabled`) or
  `event-disabled` (`hook.pre-commit.enabled`, which stops every pre-commit config hook, or `hook.commit-msg.enabled`, which stops the
  message scan; the line then reads `git hook list commit-msg shows ... so commit messages are not scanned`, and the locating line says
  `disables the commit-msg event: commit messages are not scanned (lines still are)`, as doctor does): any value git reads as off (`false`, `no`,
  `off`, `0`, an empty value, `00`, `0k`, `0x0`, `-0`; a value git cannot read after `false` leaves it off, and a lone value git
  cannot read leaves the hook working and is not reported). Exit 1 with a `hook list: MISMATCH` line when the hook is not in the
  listing, or when a step fails: a key without a value or an `event` without its `command` makes `git hook list` itself fail ("missing value", exit 128) and every commit die,
  a failed `mktemp` leaves nothing to ask. When git says off, a second line **locates** the setting: `<key>=<value> in the <scope> config
  (<file>)` with how to remove it (`run: git config --global --unset <key>` only for the main global file, otherwise "remove the line
  from <file>", as root for the system config, or "unset the setting in the environment" for a command-line setting). That line comes
  from a scan of the config records that never decides: it parses each value with git's own boolean parser, the last valid one is the one
  named, and when the scan finds nothing, fails, or its boolean probe fails, the line says `git reports the hook disabled; the setting
  could not be located` and the verdict stays git's. A key without a value is named by the same scan after the failed `init`. The value
  of an `enabled` key is printed, never a configured `command` or `event`. The empty repository is removed on every exit. Ctrl-C (or a
  terminate signal) during the check ends `status` at once with exit 130 (143) and prints no further line.
- **Missing runtime tools.** `jq`, `setsid` (`taskkill` on Windows) and `timeout` count like the scanners: `MISSING or not
  executable` exits 1, because the hook blocks every commit in that state. So does a `hook command` line that says
  `MISSING or not executable` (the installed `hooks/secret-scan`).
- **A system git takeover that is broken or undone** (RPM systems): `system git takeover: MISMATCH ...`, exit 1; commits through
  `/usr/bin/git` are not scanned then. An active takeover, or none, is one information line.
- **The GitHub Desktop link** (Linux): `GitHub Desktop: MISMATCH ...` exits 1 when the link exists but a wrapper or the shared file is
  missing or changed, the launcher entry is missing, differs from the system entry or no longer sets `core.hooksPath`, the system entry
  cannot be read, or Desktop is gone while the link is left (the line names `install --link-desktop-git` or `unlink-desktop-git`).
  `linked` is `ok`, `not linked` (an old bundled git, opt-in) is a WARNING (it never changes the exit status) and `runs the scan hook itself` is information. On macOS and Windows a Desktop found
  in the default place gets one information line recommending the latest release. [doctor.md](doctor.md) grades the same states.
- **A share of another version.** When a library this CLI lists is missing from a share whose own `VERSION` differs from the CLI's (an older install checked by a newer CLI, before `install` ran), `status` prints one line, `hook libraries: MISMATCH (the installed hook is git-secret-guard <installed>, this CLI is <cli version>; run git-secret-guard install)`, and exits 1. It does not say the hook blocks commits: the installed hook loads its own list (`test_status_names_the_version_difference_when_the_installed_share_lacks_a_library`).
- **A damaged share directory.** The line `hook libraries: <n> files present and readable` is printed on every installed run. A file the hook
  sources or runs from `<share>/lib` that is missing, unreadable, or not a regular file (`common.sh`, `extract.sh`, `exempt.sh`, `report.sh`,
  `proc.sh`, `message.sh`, `extract.awk`, `run-scanner.sh`, `scanners/trufflehog.sh`, `scanners/betterleaks.sh`, `betterleaks-rule.toml`) gets one
  `hook libraries: MISMATCH (cannot read <path>: <reason>; the hook blocks every commit: nothing is scanned)` line each and exit 1, with the reason
  `missing` for an absent path and `not a readable file` for a file without read permission, a directory or a dangling link. The names come
  from the same lists the hook loads from (`GSG_HOOK_LIBS`, `GSG_HOOK_FILES` in `lib/core/common.sh`). A readable file is enough: `status` never
  sources them and does not judge their content. When `GSG_HOOK_LIBS` is unset or empty (`()` or only empty names) the hook blocks every commit
  (`cannot load the hook library list ...; nothing was scanned`) and `status` prints `hook libraries: MISMATCH (GSG_HOOK_LIBS in <share>/lib/core/common.sh
  is unset or empty; ...)` and exits 1, through the same `hook_libs_listed` (`lib/core/common.sh`). `status` reads the lists from the `common.sh` of
  the CLI that runs: the installed `<share>/bin/git-secret-guard` reads the share's, so it sees this damage; a checkout CLI reads the checkout's
  own and cannot (the file checks above still look at the share).
  **`common.sh` and `exempt.sh` are the exception for the installed CLI.** It sources both itself at startup, so with either missing or
  unreadable it never reaches `status`: bash prints its own error, `<start path>: line <n>: <share>/lib/scan/exempt.sh: No such file or
  directory` (`Permission denied` when unreadable), where `<start path>` is the path the CLI was started from (by name: `~/.local/bin/git-secret-guard`;
  `<share>/bin/git-secret-guard` only when the share copy is run directly), nothing goes to stdout, and the exit status is 1; there is no `hook libraries` line. The file
  is named and the exit code is right, the documented line is not printed. Every other listed file gets its `hook libraries: MISMATCH` line from the
  installed CLI as well (`test_the_installed_cli_reports_every_missing_file_the_hook_reads`, `test_the_installed_cli_reports_every_unreadable_file_the_hook_reads`).
- **Settings keys install records** (the `bash:` line exists on every platform since #28 and #31; `launchctl:` on macOS only; `GNUBIN_DIR:` is checked on every platform
  whenever the key is set, because the hook blocks on it everywhere, and an unset key prints nothing). `BASH_BIN` must be an absolute executable file that
  reports bash 4.4 or newer when asked (the check `doctor` uses, `brew_bash_ok`; the file is run with `-c` to print its version, nothing else). Otherwise
  `bash: MISMATCH (...)`, exit 1, each with its own reason: an absolute path that is missing or not executable makes the hook command stop with its own
  message and block every commit; an
  unset `BASH_BIN` (an install from before the recorded bash, with the bare hook path as the command, until `install` runs again) lets the script's shebang choose the bash, and a relative one is refused when the command is built (install and doctor fail, the hook config line is a PROBLEM);
  an old bash makes the hook block, and a program
  that is no bash and exits 0 makes git commit **without a scan** ([observed](platforms.md#macos-homebrew), fake-uname harness only). A `GNUBIN_DIR` that is
  set and not an absolute existing directory is `GNUBIN_DIR: MISMATCH (...)` (the hook blocks on it, same rule); unset is silent and fine. When
  the state records a timer, `LAUNCHCTL_BIN` is judged like `jq` (`launchctl: <path> (MISSING or not executable)`); without a timer it is not read.
  **`rule file:`** (every platform, after `GNUBIN_DIR:`) judges `<share>/lib/scan/betterleaks-rule.toml` against `BETTERLEAKS_RULE_SHA256` with
  `rule_file_hash_check`, the hook's own verdict: `ok` with `<path> matches the SHA-256 install recorded`; `rule file: MISMATCH (<path> does not match the
  SHA-256 install recorded; the hook blocks every commit: nothing is scanned; reinstall from a checkout or a release: bin/git-secret-guard install)`
  for a different file, a recorded value that is not a SHA-256 or a file that cannot be hashed; and `rule file: MISMATCH (no SHA-256 of <path> is recorded
  in the settings file, an install from before this check, so an edit of it is not noticed; run: git-secret-guard install)` when the key is missing or
  empty (the hook keeps scanning there, so a plain `install` is the fix). A file that cannot be read prints no line (`hook libraries` reports it).

**Conditional includes are not seen.** git alone decides what an `enabled` value means, but only for the throwaway repository, and a conditional
include (`includeIf "gitdir:..."`, `onbranch:`, `hasconfig:remote.*.url:`) never matches it. A setting reached through one, for example an
`enabled = false` that applies only below a directory, does not change `status` (a commit under that directory still runs unscanned). When the global
or system config holds any `includeIf`, `status` prints one informational line naming the file that holds it (never the condition or the included
path); [`doctor`](doctor.md) checks each repository and finds such a disable.

Known limits: `status` checks that the hook's library files are readable, not what is in them (a library that is readable but edited is the
hook's to reject). The file list is read from the `common.sh` of the CLI that runs, so a checkout CLI run against an older installed share can
flag a file that share's hook does not use, and cannot see a list that is damaged in the share's own `common.sh`. `status_config` builds the wanted
command from the recorded bash on every platform (`hook_command_text`), and `install` writes the same text, so a fresh install matches. On macOS `status` runs the recorded `BASH_BIN` with `-c` and no timeout, as `doctor` does, so a `BASH_BIN` that hangs hangs
`status`. A relative `GIT_CONFIG_GLOBAL` is read from the directory `status` runs in, while git inside a repository reads it from the top of that
repository, so only an absolute value gives a reliable answer.

## Maintainer notes

- **Bounded here-strings** ([platforms.md#maintainer-notes](platforms.md#maintainer-notes)). `state_read` refuses a line over
  `GSG_STATE_LINE_MAX` (8192 characters), so the `tools_*` word lists that install, uninstall and doctor split with `read -a <<<` stay well below
  64 KiB; `tools_version_matches` reads only the first `GSG_VERSION_OUTPUT_MAX` (4096) characters of a `--version` output.
- **`status` and "can commits be scanned".** `status_git` judges `$GSG_GIT` (the first git on `PATH`, set by `lifecycle_require_git`) with
  `install_git_version` and `install_git_is_new_enough` and returns 1 for an old or unreadable git; `status_run` then skips the hook check
  (`test_status_skips_the_hook_check_when_the_git_is_too_old_or_unreadable`). It must not look at any other git
  (`test_status_ignores_an_old_git_that_is_not_first_on_path`). `status_hook_listing` runs `status_hook_ask` in a subshell (its traps never
  touch `status`): traps first, then `mktemp -d`, then `hooklist_probe_line` (`lib/install/hookspath.sh`; prints `ok`, the `pre-commit` status and the
  `commit-msg` status, one `hooklist_read ERRFILE EVENT` per entry of `GSG_HOOK_EVENTS`, judged by `status_hook_event` and, in doctor, `doctor_hook_event`
  and `doctor_repo_hook_status`; tests `test_status_flags_an_old_install_that_has_only_the_pre_commit_event`, `test_status_flags_commit_msg_switched_off_by_its_event_key`
  and the doctor ones in `tests/inspect/test_doctor.sh` and `tests/inspect/test_doctor_repos.sh`): `git rev-parse --local-env-vars` unset
  except `GIT_CONFIG_PARAMETERS` and `GIT_CONFIG_COUNT` (`test_status_ignores_the_repository_a_caller_points_git_at`,
  `test_status_sees_a_disable_given_through_the_environment`), a bare repository written by hand (`HEAD`, `objects/`, `refs/`; never `git init`, which writes `HEAD` through a ref transaction and fires the user's `reference-transaction` hooks), and `hooklist_read` (the same reading
  `doctor_repo_hook` uses). **One verdict**: git's. `doctor`'s machine section calls the same `hooklist_probe_line` in `DR_WORK`
  (`doctor_hook_verdict`), so the two commands cannot disagree. `hp_hook_enabled_scan` stays only to locate the setting git blamed (key,
  scope, file, advice) and never decides: no word list, no version gate for `hook.pre-commit.enabled` (git reports `event-disabled` only
  where it reads that key; the old 2.55 gate is gone because of that). A key without a value is the one finding the scan reports without
  git's blame, after `git hook list` has failed. Plain `git -C / hook list` does not do: outside a repository it does not report
  `event-disabled`. Cleanup is pinned by `test_status_leaves_no_temp_directory_after_a_normal_run` and
  `test_an_interrupted_status_leaves_no_temp_directory`; the failure lines by `test_status_reports_each_failing_git_step_and_prints_no_control_character`
  and `test_status_exits_1_when_only_its_own_mktemp_fails`; Ctrl-C by `test_an_interrupt_during_the_hook_check_stops_status_with_130`. The hand-built repository
  has no `config` and no hooks, so a template `config` cannot leak in; a template is
  repository-level and `doctor`'s job (`test_status_ignores_a_template_config_that_only_a_new_repository_would_copy`). Nothing the user configured
  runs while `status` asks (`test_status_runs_no_hook_of_the_users_while_it_asks_git`, `test_the_machine_section_runs_no_hook_of_the_users`), and
  `git hook list` runs under the settings' `timeout --foreground` binary, 30 seconds (git stays in status's process group, so Ctrl-C ends it too) (`test_status_bounds_the_hook_listing_with_the_settings_timeout`); without usable
  settings it is unbounded, but it runs no user hook either. Every path is absolute
  and nothing changes directory (`test_status_accepts_a_git_found_through_a_relative_path_entry`); on Windows the repository path is given to
  native git as `C:/...` (`cygpath -m`). The PROBLEM sites of `status_line`: `global config` (`status_config`), `hook command`, `settings` and the
  tool lines (`status_hook_command`, `status_tools`, `status_plain_tool`), `hook libraries` (`status_hook_files`), the macOS lines
  (`status_settings_keys`: `status_bash` and `status_launchctl` on macOS, `status_gnubin` and `status_rule_file` everywhere), `git in use` (`status_git`), the hook listing (`status_hook_listing`) and
  `system git takeover` (`status_system_git`), plus `smartgit_status_lines` (`lib/integrations/smartgit/smartgit_report.sh`) and `desktop_git_status_lines`
  (`lib/integrations/desktop/desktop_git_report.sh`).
- **`status` and the share directory.** The hook sources `common.sh`, then every name in `GSG_HOOK_LIBS` (`lib/core/common.sh`), and runs or reads the
  names in `GSG_HOOK_FILES`; `status_hook_files` walks those same arrays, so there is no second list. The hook's own `for` loop took its list from
  the array, pinned by `test_the_hook_loads_exactly_the_libraries_in_the_shared_list` (each listed library moved away in turn makes the real
  commit say `cannot load <path>`; every library not listed moved away at once does not) and `test_the_hook_blocks_when_a_file_it_reads_is_missing`
  (the five files). `test_status_exits_1_and_names_each_file_the_hook_reads_when_it_is_missing` loops the same lists through `status`;
  `test_status_flags_an_unreadable_file_a_directory_and_a_dangling_link_in_place_of_a_library` (skipped as root and on Windows) and
  `test_status_prints_one_line_per_damaged_file_and_still_exits_1` cover the other shapes. A new library the hook sources must be added to the
  array or the first test fails. `test_the_hook_blocks_on_its_own_when_the_library_list_is_empty_or_unset` pins the hook's own block for a list that
  is unset, `()` or `("")`; `test_status_exits_1_when_the_hook_library_list_is_empty_or_unset` pins the `status` side with the installed CLI (and
  that the checkout CLI does not see it). `test_status_on_macos_runs_the_recorded_bash_with_stdin_closed` gives status an open pipe on stdin and a recorded bash
  that reads it: `status_bash` closes stdin for `brew_bash_ok` or the run times out (rc 124). `status_tools` calls `status_settings_keys` at its end (it loads the settings; the keys are read
  as loaded, so a settings failure already printed its own line; `status_bash` and `status_launchctl` run only when `brew_is_macos`). The `GNUBIN_DIR` rule is `gnubin_dir_unusable` in `lib/core/common.sh`, called
  by the hook and by `status_gnubin` (`test_status_on_macos_exits_1_when_gnubin_dir_is_not_an_absolute_directory` runs a real commit for each case
  and compares the two messages); it adds no install-time library to the hook's load path. `status_bash` is `tool_unusable` then `brew_bash_ok`, the
  two calls `doctor_check_tools` makes (`test_status_on_macos_exits_1_when_the_recorded_bash_is_not_an_executable_bash_4_4` breaks the file at the
  recorded path, so `global config` still matches and only the new line fails the run); `status_launchctl` reads `ST_TIMER`
  (`test_status_on_macos_checks_launchctl_only_when_a_timer_is_recorded`). Linux and Windows print no `bash:` or `launchctl:` line and `GNUBIN_DIR:`
  only when the key is set (`test_status_checks_gnubin_dir_on_every_platform`, a plain install that also runs on Windows: a relative `GNUBIN_DIR` is a
  `MISMATCH` with exit 1 and a real commit is blocked by the hook, a bad `LAUNCHCTL_BIN` without a timer changes nothing;
  `test_status_ignores_launchctl_bin_on_linux_even_with_a_timer`, a Linux install with a timer, skipped on Windows: the output stays byte-identical;
  `BASH_BIN` is covered by neither, see the known limit below).
  Everything macOS here runs through the fake `uname` on a Linux host. The temp directory is a plain `mktemp -d` like doctor's: it holds an empty repository, no scanned content, so the hook's
  rule about a `TMPDIR` outside `HOME` on Windows does not apply. The not-installed path prints the git line and no hook check.
- **`git config` exit codes** (2.56): a plain set exits 5 on a multi-valued key (hence `--replace-all`); `--get-all` exits 1
  when the key is absent and also when `GIT_CONFIG_GLOBAL` is a directory; `--global --list` exits 128 for a missing file
  and for a directory, so "unwritable" is probed by setting and removing a `gsg-install-probe` section
  (`install_check_config_writable`). Values are read with `-z --get-all` and stored verbatim. To test "cannot write", make
  the config **directory** unwritable (git writes through a lock file; a read-only file is not enough).
- **Release tarballs**: `trufflehog_<v>_linux_{amd64,arm64}`, `betterleaks_<v>_linux_{x64,arm64}`; betterleaks ships
  `.tar.gz` for Linux and macOS, with checksums in its `checksums.txt`. `tools_version_matches` accepts the pin only as a
  whole word, `v<pin>` or `jq-<pin>`, after dropping carriage returns.
- **jq on Windows** (`install_manage_jq`, after `state_read`): no jq on `PATH`, `jq:` in `tools_placed`, or the adopted file below, appends `jq` to
  `GSG_TOOL_NAMES` for this install run only, so lock, staging, ownership and asides come from the scanner path; status and
  doctor keep seeing the two scanners, and `install_write_settings` skips its `_VERSION` key. The asset is a bare `.exe`
  (`tools_extract_binary` copies it). A jq install did not place stays in use, except a regular file at `~/.local/bin/jq.exe`
  with the pinned SHA-256 (the `PATH` jq, or no jq found at all):
  `install_adopt_jq` appends `jq:<sha>` to `ST_PLACED` and `jq` to `ST_TOOLS` (`test_a_jq_left_by_an_earlier_install_is_adopted_and_recorded`,
  `test_a_jq_at_the_pin_is_adopted_when_the_install_dir_is_not_on_path`). Linux keeps its package-manager hint (no
  silent sudo).
- **Scanners kept by an uninstall:** the scanner pins in
  `tools.lock` are hashes of the release archives, so a row carries an optional fifth column, the SHA-256 of the binary inside the archive
  (`tools_lock_lookup` still prints `<version> <archive sha256>`; `tools_lock_binary_sha` prints the fifth column, empty when absent;
  both share one parse, which rejects a malformed fifth field and a sixth). Two uses: `install_check_binary_sha` (in `install_stage_tools`, after
  `tools_extract_binary`, before the version probe) refuses an extracted binary that differs, and `install_adopt_scanners` (in
  `install_run_state_checks`, after `state_read`, before `install_manage_jq`) records a regular file (not a link) at `$GSG_BIN_DIR` whose
  SHA-256 equals it, when `tools_placed` holds no hash for that scanner: `install_adopt_if_hash` appends `<tool>:<sha>` to `ST_PLACED` and the tool to
  `ST_TOOLS`, the same helper `install_adopt_jq` now uses. There is no `PATH` condition, scanners are always at `$GSG_BIN_DIR`. A row without the fifth
  column adopts nothing and checks nothing (the test locks of stand-in tarballs; `LC_BINSHA=1` in `lc_make_fixtures` adds it).
  `test_the_real_lock_gives_every_scanner_row_a_binary_hash_and_no_other_row` makes a pin bump carry the hash. Known limit: a kept scanner
  at an OLDER pin (uninstall, then an install with a bumped lock) does not match the new row, so it is moved aside as the user's and `uninstall`
  puts it back (`test_a_scanner_kept_at_an_older_pin_is_still_moved_aside_as_the_users`). Tests, all through the real install, uninstall and state files:
  `tests/install/test_install_adopt.sh` (`test_scanners_kept_by_an_uninstall_are_adopted_and_removed_by_remove_tools`,
  `test_an_adopted_scanner_is_replaced_in_place_by_a_pin_bump_never_moved_aside`, the never-adopted cases, and
  `test_install_refuses_when_the_extracted_binary_is_not_the_one_the_lock_names`); the `.exe` names in `tests/platform/test_windows.sh`.
- **Step order** (refusable steps before any lasting change; exceptions: the macOS `brew install bash` bootstrap, the
  config write probe that sets and removes its section, and on a Mac without GNU `timeout` the staging that follows the
  one `brew install`): `install_check_prerequisites`, platform, `core.hooksPath`
  read, CLI link check and `desktop_git_precheck`, `install_precheck_timer`, `core.hooksPath` refusal, `install_run_state_checks`
  (hooks dir, config write probe, state, scanner and jq adoption, recorded value, `install_plan_lock`),
  `install_prepare_update pre` (every `--auto-update` refusal that needs no final git), `gitup_offers`
  (with a git older than 2.26 or none, the `core.hooksPath` checks and the state checks come after the offers), other-git warning,
  timer preparation, `install_prepare_update` (the unit check again with the final git, then the update lock),
  download + SHA-256 + `--version` into one stage, `install_hash_staged`, backup, **state write**, tools, share
  tree, CLI link, `git config --replace-all`, unset `core.hooksPath` **last** of the hook changes
  (`test_install_keeps_scanning_when_the_final_hooks_path_unset_fails`), then the summary, and the
  timer, auto-update, SmartGit and Desktop steps (each runs, any failure is exit 1). Uninstall restores
  `core.hooksPath` **first** (`test_uninstall_restores_core_hooks_path_before_removing_the_hook_config`): never leave a
  machine with neither hook nor `core.hooksPath`.
- **State keys**: `version`, `previous_hooks_path_set`, `previous_hooks_path`, `tools_installed_by_us`, `backup_path`,
  `tools_replaced`, `tools_placed`, `timer_installed`, `auto_update`, `source_checkout`. `state_write` writes all ten and
  refuses a call with any other number of values (`GSG_STATE_VALUES`; a default would turn a recorded `auto_update=yes` into
  `no` without a word); `state_read` still accepts the older five-, six- and eight-key files and refuses anything odd.
  `auto_update` is `yes` or `no` (a missing key reads as `no`), validated like `timer_installed`; `source_checkout` is an
  absolute path or empty (a missing key reads as empty, a relative value is refused): the real path of the checkout the
  last install from a checkout ran from (`install_prepare_update`), read by `update` as the checkout to follow. `paths_init`
  names the two files beside the state, `GSG_UPDATE_RECORD` (`update`) and `GSG_UPDATE_LOCK` (`update.lock`)
  (`tests/core/test_state.sh`). A recorded `no` is replaced by a later takeover
  (`test_a_hooks_path_taken_over_after_a_plain_install_is_recorded`); a differing recorded value refuses
  (`install_check_recorded_hooks_path`).
- **Scanner ownership.** `install_owns_file` = the file's hash is in `tools_placed`. `install_write_state pending` records
  the old and the new hash before `install_commit_tools`, `final` keeps the new one. `mv -T -n` is followed by a check of
  both paths (coreutils 8.32 exits 0 when `-n` skips). `uninstall_restore_replaced` validates records with `GSG_ASIDE_RE`
  and `GSG_STATE_TOOL_NAMES`; `uninstall_tools` deletes only regular files whose hash is in `UN_PLACED`. Pin bumps are
  tested in `tests/install/test_upgrade.sh` (`bump_pins`).
- **`core.hooksPath` reader**: `lifecycle_read_hooks_path` (sets only `GSG_HP_*`; `GSG_PREV`/`GSG_PREV_SET` are install's)
  also runs `git -C / config --show-scope --show-origin -z --list`; `hp_walk_includes` reads every include target (bound
  `GSG_HP_MAX_INCLUDES`), `hp_include_target` skips missing targets like git, `hp_report_unresolved` refuses unresolvable
  ones. `lifecycle_realpath_m` works without GNU `realpath -m`; `lifecycle_note_global_config` prints the
  `GIT_CONFIG_GLOBAL` note (every lifecycle test's stderr has it).
- **Backup bounds** (`install_check_backup_bounds`): test `/` only at the resolver level
  (`test_the_resolver_refuses_root_before_anything_could_back_it_up`), never by running install.
- **Download override**: `GSG_TOOLS_BASE_URL` + `GSG_TOOLS_LOCK` cannot skip verification
  (`test_the_base_url_override_cannot_skip_verification`); curl runs with `-q` first, `--proto =https --proto-redir =https`, `--max-time 600` and `--max-filesize`; install prints `downloading TOOL VERSION` before each scanner download (not before the git source or the other downloads of the upgrade), see `test_install_names_each_scanner_before_it_downloads_it`.
- **`/etc/os-release` is data, never sourced** (`install_os_release_field`; `GSG_OS_RELEASE` in tests;
  `test_the_container_script_reads_os_release_as_data`). Hints: `install_os_family`, `install_fix_hint`, `install_git_hint`
  (`tests/install/test_prerequisites.sh`).
- **The CLI ends with `main "$@"; exit`**, so bash never reads a file `install` just replaced (`bin/git-secret-guard`).
- **Conditional includes in `status`.** `status_conditional_includes` prints the one informational line for them: the probe cannot see an
  `includeIf`, and `doctor` checks each repository.
- **Historical host note.** The reference RHEL host had `/usr/local/bin/git` 2.56 (built from source) and `/usr/bin/git` 2.52, which silently
  ignores `hook.<name>.*`; that 2.52 stays reachable, so `doctor` reports it as a WARNING (exit 1 is only for a PROBLEM). Tests pick their git with `GSG_TEST_GIT`
  (`tests/support/lib.sh`: `/usr/local/bin/git` on Linux, `/usr/bin/git` on macOS, the one on `PATH` on Windows); set it where that path does not exist.
- **The `lib/` layout and the one-time upgrade limit.** `lib/` holds one folder per bounded context (`lib/core/`, `lib/scan/`, ...; each README
  says what belongs there), and `GSG_HOOK_LIBS` and `GSG_HOOK_FILES` name their entries relative to `lib/`. An upgrade needs no cleanup logic:
  the install builds the complete new tree and swaps it in whole (see **Files** above), so no file of an older layout survives. One case stays:
  a hook process that started from a release that kept the scanner runner directly in `lib/` has its libraries loaded already and looks the
  runner up later, in its own `proc_start_runner`, at its old place directly in the share's `lib/` (now `lib/scan/`). If the swap happens
  between the start of that commit and the start of its scanners, that runner is missing, both scanner wrappers fail (exit 127) and the old hook
  blocks the commit with its own text, `a scanner did not complete, so the commit is blocked:` and `failing closed` per scanner. It never
  passes unscanned, and the next commit starts from the new tree and is scanned. This limit applies once, to a commit that runs during the
  upgrade across that release.
  Tests: `test_the_hook_lists_name_only_files_under_lib_core_and_lib_scan` and the other dependency tests of `tests/project/test_quality.sh`.
- **The CLI on `PATH`** (#72: `lib/install/install_path.sh`, `lib/platform/macpath.sh`, `lib/platform/winpath.sh`, `bin/gsg-path.ps1`). (1) **Order.** `install_path_plan`
  runs among the checks, after `install_prepare_update` and before the first lasting change, reads only and never refuses: an unusable answer or a file it must not edit
  is a hint. The plan puts this run's new record in `INSTALL_PATH_NEWREC` and leaves `INSTALL_PATH_RECORD`, the one `install_write_state` writes in the pending and the final state, at the
  earlier install's record (`ST_CLI_PATH`) or none. `install_path_apply` runs after the hook config is set and moves the new record into `INSTALL_PATH_RECORD`, writes the final
  state (`install_write_state final`) and only then calls `macpath_apply` or `winpath_apply`, which read that same `INSTALL_PATH_RECORD`: recorded before made, nothing written =
  no record, on every path. A step before it that stops install (tools, share, CLI link, hook config, a signal) therefore leaves no record of a change never made, and a crash
  between the state write and the change leaves a record `uninstall` can act on (it finds nothing and says nothing). If that state write fails the change is not made, one line says so
  and install's status is 1. When the change reports that nothing was written `install_path_unrecord` writes the final state again with the earlier record or none, so a later
  `uninstall` never removes a byte-identical entry or block you added by hand afterwards. A change that was written but not announced (`added-nobroadcast`) keeps its
  record. A PowerShell that times out or answers something unexpected counts as nothing written: an entry nobody removes costs less than a stale record. A state that
  cannot be written again is install's status 1, as every failed state write is; the other steps still run. Tests: `test_an_install_that_stops_before_the_path_step_leaves_no_record_and_no_file`,
  `test_the_windows_flow_writes_the_state_with_the_new_record_before_the_change_and_takes_it_back_when_nothing_was_written`. (2) **The update child.** `install_path_is_update_child` is the one
  place that decides: `AU_LET_IN` is 1 only after `autoupdate_lock_take` let this process in as the child of the run that holds the lock. `GSG_UPDATE_LOCK_PID` alone proves
  nothing (any environment can hold it): `test_the_child_install_of_update_never_changes_path_but_a_bare_variable_does_not_make_a_child`. (3) **The comparison.**
  `install_path_has_dir` walks `PATH` entry by entry and compares the folder in one form for every platform, trailing slashes cut; on Windows the folder goes through one
  `cygpath -m -l` and the whole `PATH` through one `cygpath -m -l -p` (a `;`-separated list, split by a bounded loop, never a here-string), both in lower case: two `cygpath`
  starts however long `PATH` is. Empty entries are cut from the list before `cygpath` sees it (it may turn one into `.` or drop it; an empty entry never matches), a `PATH` of separators only matches nothing; a name `cygpath` cannot read, or a `PATH` it cannot convert, never matches (no guessing). `status`, `doctor` and the plan use it. (4) **Records carried.** A record of an
  earlier install stays in every run that writes none (folder on `PATH`, `--dont-change-path`, the update child, a hint); on macOS the plan is `present` while the recorded
  file still holds the marker line, whatever the login shell says now. There is one record slot, so a record is never replaced while its block or entry may still be there:
  on macOS a recorded file that `macpath_read` cannot read (over the limit, a NUL byte, unreadable) or that holds the marker text in any other form (a CRLF conversion, a trailing space)
  makes the plan a hint (`<why>; the state records a block of ours in <file>; install left it alone and kept the record`), also when the login shell is another one now; on Windows a record
  for another folder than the one install would add (the home or profile moved; compared without case) makes it a hint (`the state records an entry for another folder, <folder>, which
  git-secret-guard uninstall removes; install left the user Path alone`), and `uninstall` removes that entry. The plan asks `winpath_plan` about the recorded folder too (read-only): `absent`
  (you took that entry out by hand) means the record protects nothing and install adds the current folder and records it; `present` keeps the hint and the record, and so does `unusable` (a record is never dropped on a failed question). `macpath_check_file` (install) and `macpath_remove` (uninstall)
  detect the marker with the same test, `macpath_mentions_marker`. Tests: `tests/install/test_install_path.sh`, `tests/install/test_winpath.sh`, `tests/platform/test_macos_path.sh`,
  `tests/platform/test_windows_path.sh`; the per-platform notes are in [platforms.md](platforms.md#maintainer-notes).

## Maintainer notes: git upgrade

Behaviour: [the RPM](platforms.md#rhel-rocky-and-fedora-rpm), [the apt](platforms.md#ubuntu-and-debian-apt) and
[the Windows](platforms.md#upgrading-git-for-windows) sections; module contract: [CONTRIBUTING.md](../CONTRIBUTING.md#adding-an-os-module).
Internals only here.

- **Plan equals log.** The plan lists every command that can run, full path first; conditional ones end in two spaces plus
  `[only when ...]`, which `check_plan_matches_log` (`tests/support/gitup.sh`) strips before it compares whole normalized commands with the
  sudo log. The build runs with `PATH=/usr/bin:/bin` (`GSG_GITUP_BUILD_PATH` in tests). `gitup_apt_plan_fallback` captures
  `gitup_source_print_plan` in a temp file: a command substitution would lose the `GITUP_PRIV_CMDS` it fills. Every apt command is
  one array, `gitup_apt_cmd` (`env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none ...`), because `sudo` drops the environment.
- **Takeover internals.** `active` needs the real `excludepkgs` line (`gitup_tk_entry_present`, spaces or commas), not only the
  marker; identity is link-aware (`gitup_tk_id`); links by `ln -sfT` then `mv -T`; one undo, `gitup_tk_restore_core`, serves
  rollback, interrupt and `restore-system-git`.
- **Source route records.** `MANIFEST.partial` is saved before the copy and renamed `MANIFEST` after it; `gitup_source_read_manifests` reads both into
  `GITUP_KNOWN` (every listed path), `GITUP_DONE` (paths of finished MANIFESTs) and `GITUP_PARTIALS` (the `.partial` files); the
  "partly copied" clause enters `GITUP_CHANGED` before the `cp` (an interrupt ends the shell) and `gitup_changed_drop` removes it
  after. The `make` words are one array, `gitup_source_make_words` (`sysconfdir=$GITUP_SYSCONFDIR`), for the plan line and both
  runs. A failed build keeps `make.log` as `$TMPDIR/gsg-git-build-failed.*.log`.
- **Ctrl-C.** A bash script without a trap ignores SIGINT when the child it waits for survives it (`sudo`, `cp` finishing normally),
  so `install` and `restore-system-git` trap INT/TERM/HUP (`gitup_tk_restore_stopped`: state, next command, work dir removed).
  Interrupt tests: `gu_interrupt_run` (the `sudo.stall` knob; signals only the group it started with `setsid`, never `pkill -f`).
- **apt internals.** `gitup_apt_upstream` drops epoch and suffix (tests `test_ubuntu_2404_*`, `test_ubuntu_2204_*`,
  `test_a_ppa_that_lags_*`); `gitup_apt_preflight` records existing PPA state first; `gitup_apt_adder_ok` probes `--help` for `-n`;
  `gitup_apt_ppa_disable` removes both file forms and `trusted.gpg.d/git-core-ubuntu-ppa.gpg*` (apt trusts it for every repository);
  `GITUP_APT_PPA_PENDING` plus `gitup_apt_abort` disable an unchecked PPA on Ctrl-C. Real `add-apt-repository` merges the key into
  an existing keyring, so a keyring holding the pin plus any other key is not the pin.
- **Windows internals.** `gitup_windows_apply` returns 2 and the core exits 3; the `.cmd` (`install_cli_cmd_text`, `goto :handoff`)
  is straight-line code: one runner call, one rerun of bash, no loop. `gitup_windows_handoff_place` and `gitup_windows_no_links`
  (MSYS shows junctions as links) check `GSG_HANDOFF` (only `git-upgrade/handoff.txt` below `LOCALAPPDATA`, no `..`); the directory
  is emptied of `Git-*-64-bit.exe` and `handoff.txt*` only; `uninstall_gitup_handoff` cleans both places. Elevation = mandatory
  label `S-1-16-12288` in `whoami /groups` (`gitup_windows_detect` reads `Git_is1` with `reg.exe` from `System32`).
- **Test seams.** `lc_begin` adds the stand-ins `sudo dnf rpm restorecon make df ldd` and user-owned exec wrappers of
  `cp rm mv mkdir install ln rmdir touch env`; `tests/platform/rpm.sh` needs `policycoreutils` in the image for `restorecon`. Windows: the `.cmd`
  tests copy the product and replace only `bin/git-secret-guard`, because Git for Windows' `bin\bash.exe` prepends its own git to `PATH`; run a
  native `cmd` as `cmd.exe //c` (`MSYS2_ARG_CONV_EXCL` would reach the bash below); a Windows path in a `sed` replacement hits
  GNU `\U`; certificate writers run under `wu_with_cert_lock` and never count the whole Keys directory.
- **Windows runner seams** (`tests/support/gitup_windows.sh`: `wu`, `wu_begin`). The runner reads no environment (a test asserts no `$env:`); tests run a
  sandbox copy with its own `tools.lock`, and `wu_runner_seam` changes exactly one line of the copy (the status, the one-line `Test-Elevated`).
  `wu_runner_shadow` wraps `Start-Process` to record the verb, hold between the checks and the start (`GSG_TEST_HOLD` belongs to the wrapper),
  or throw `Win32Exception(1223)`; its `norun` mode lets `test_real_the_pinned_installer_...` check the real cached asset against the unmodified
  runner and lock. The signed stand-in is built once into the tools cache (`gsg-test-standin`); its key and CA copy are deleted (`-DeleteKey`),
  and the build records its own key file name (`key.name`). Windows runs test files in parallel and they share the user's certificate store: every
  writer runs under `wu_with_cert_lock` (`wu_build_standin`; the safety tests use `wu_build_standin_unlocked` inside it). Windows-only tests need an
  elevated prompt (`fltmc`), or a machine-wide run would show a UAC prompt.
- **apt stand-ins** (`tests/support/apt.sh`). A `STUBGARBAGE` line makes the gpg stand-in exit 2, and an input with no `STUBKEY` also exits 2 like the real
  tool. Fixtures: `gu_apt_setup`, `gu_apt_fixture sources|list`, `gu_apt_without_sps`; `gua_run`/`gua_reply` call module functions directly.
  `lc_begin` installs the stand-ins; they use `printf`, not `echo` (Ubuntu's `/bin/sh` is dash), and read an entry as active only on a
  non-comment line without `Enabled: no`.

## Maintainer notes: auto-update

Moved to [autoupdate-maintainer.md](autoupdate-maintainer.md) to keep this file under 1000 lines.
