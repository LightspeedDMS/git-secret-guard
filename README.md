# git-secret-guard

Machine-wide pre-commit secret scanning: every commit's added lines are scanned by **trufflehog** and **gitleaks**
in parallel, through a git config-based hook, so repositories that bring their own hook tooling (husky, the
pre-commit framework, a custom `core.hooksPath`) are covered too. See `plans/backlog/GitSecretGuard/` for the epic.

## Install, upgrade and uninstall

```bash
git clone <this repository> && cd git-secret-guard
bin/git-secret-guard install        # also the upgrade: run it again from a newer checkout
git-secret-guard status             # what is installed, and whether the global config still matches
git-secret-guard doctor             # which repositories are not protected, and why (read-only, see below)
bin/git-secret-guard install --with-timer   # optional: also run doctor weekly through a systemd user timer
git-secret-guard uninstall          # put back what was there before
```

**Requirements.** Linux on x86_64 or arm64 (macOS is not tested and not claimed: `install` refuses it, although
`tools.lock` already records the darwin checksums for later). bash, **git >= 2.54 first on `PATH`**, `jq`, `setsid`,
`timeout`, and `curl` plus `tar` when a scanner has to be downloaded. `install` refuses when the git on `PATH` is older
than 2.54, because older git ignores config hooks without any message.

> **Warning, `/usr/bin/git` 2.52.** Any git older than 2.54 ignores config hooks: no error, no scan. `install` warns
> for every other reachable git older than 2.54 (all `git` on `PATH` plus `/usr/bin/git`; on this machine
> `/usr/bin/git` is 2.52) and goes on, because the git that matters is the one your commits run. Commits made with the
> old one are **not scanned**; call `/usr/local/bin/git` (or put it first on `PATH`) wherever you commit.

### What `install` does

| Step | Result |
|---|---|
| Prechecks | git >= 2.54 on `PATH`, `jq`, `setsid`, `timeout` found (their **absolute paths** are written to the settings file, the hook never resolves them through `PATH`), Linux, absolute `HOME`/`XDG_*`. Any refusal happens before anything is changed. |
| Scanners | `~/.local/bin/trufflehog` and `~/.local/bin/gitleaks`. A tool that already reports the pinned version (`trufflehog` 3.99.2, `gitleaks` 8.30.1) is **kept**. Otherwise the platform tarball is downloaded from the vendor's GitHub release, its **SHA-256 is checked against `tools.lock`**, only the tool binary is extracted, and its `--version` is checked against the pin. A checksum mismatch deletes the download, installs nothing (neither scanner) and refuses. curl runs with `-q` as its first argument, so a `~/.curlrc` (proxy, protocol, output or `head` settings) cannot change a verified download. **A file already at that path that does not report the pinned version (your own build, a symlink, an older release) is never overwritten:** it is moved aside to `<tool>.gsg-replaced-<UTC stamp>` in the same directory (byte-identical, same mode), the output says where, and the state records the aside name with the SHA-256 of what install put in its place. Such a tool is never recorded as downloaded by install, so it is never "ours to delete". Install also records the SHA-256 of **every** file it places (`tools_placed` in the state), also on an empty path. On an upgrade that bumps the pins, a file that still has that hash is install's own and is **replaced in place** (no aside file, and a downloaded tool stays removable with `--remove-tools`); only a file install did not place is moved aside, and the first original ever moved aside is the one uninstall restores. The aside names and hashes are written to the state **before** the file is moved, so a failure afterwards (state write, second tool, share dir) cannot lose the original: a later uninstall, or a rerun of install, still finds it. |
| Files | `hooks/`, `lib/`, `bin/`, `tools.lock`, `VERSION` copied to `${XDG_DATA_HOME:-~/.local/share}/git-secret-guard/` (the new tree is built beside the old one and swapped in, so a commit during an upgrade sees the old or the new hook, never half of either; if the final rename fails, the previous tree is moved back, so the share dir is never left missing), plus the generated `settings` file with absolute `TRUFFLEHOG_BIN`, `GITLEAKS_BIN`, `JQ_BIN`, `SETSID_BIN`, `TIMEOUT_BIN` and `SCAN_TIMEOUT_SECONDS=300`. `settings` is rewritten by every install. |
| Global git config | `hook.git-secret-guard.event=pre-commit` and `hook.git-secret-guard.command=<absolute path of the installed hooks/secret-scan>`, written with `git config --global --replace-all`, so each stays single-valued however often you run `install`. |
| CLI | `~/.local/bin/git-secret-guard` is a symlink to the installed copy. Make sure `~/.local/bin` is on your `PATH`. |
| Timer | Only with `--with-timer`: two systemd **user** units and `systemctl --user enable --now git-secret-guard-doctor.timer`, see [The weekly timer](#the-weekly-timer). Without the flag no unit is written and `systemctl` is never called. |
| State | `${XDG_STATE_HOME:-~/.local/state}/git-secret-guard/state` (mode 600 in a 700 directory): version, the previous `core.hooksPath` (or `unset`), which tools install itself downloaded, the backup path, and `timer_installed` (`yes` or `no`). |

Install is idempotent. A second run replaces the files, keeps the config single-valued, downloads nothing that is
already at the pin, and **never overwrites a recorded previous `core.hooksPath`** or forgets which tools it downloaded.
Running it from the installed copy (`git-secret-guard install`) re-installs that copy.

### An existing global `core.hooksPath`

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

### Pinned tools: `tools.lock`

`tools.lock` holds one line per tool and platform: name, version, platform, SHA-256 of the vendor's release tarball
(the vendors' checksums, fetched 2026-10-30; vendors name platforms differently, `linux_amd64` against `linux_x64`).
Only Linux x86_64 and arm64 are used; the darwin rows are recorded, not claimed. A lock that is unreadable, malformed
or ambiguous (two rows for one tool and platform) is refused as a whole, and a missing row is a refusal, never a skip.

**Test-only overrides.** `GSG_TOOLS_BASE_URL` (a directory URL such as `file:///tmp/fixtures`, tarballs named like the
vendor's) and `GSG_TOOLS_LOCK` (a lock file) let the test suite install from local fake tarballs. They are announced
on stderr (`TEST OVERRIDE active`) and **cannot skip verification**: every download is still verified against *some*
lock, and the checksum has to match, so an override alone only changes where the tarball comes from or which lock is
trusted. Without the base-URL variable curl is restricted to `https` (`--proto =https`, also across redirects). Do not
set either in production: they change which lock you trust and where you download from.

### Uninstall

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
  config and before the share dir: [the details are in the doctor chapter](#the-weekly-timer). Without a recorded timer,
  uninstall never calls `systemctl`.

### `status` and `version`

`git-secret-guard status` prints the installed version, hook command path, whether the global config matches, the
recorded previous `core.hooksPath`, the **effective** `core.hooksPath` (every global-scope value with the file it
lives in, also from the XDG config and included files; informational, config hooks run whatever it says), the backup
path, the tools installed by us, the originals install moved aside, and each tool's path with its detected and
pinned version. A tool counts as `ok` only when it reports the pinned version the way install judges it (the version
as a whole word, or with a `v` prefix), so `8.30.1-rc1` is a `MISMATCH` here exactly as install would replace it. It exits 0 when everything matches and 1 when it is not installed or a line says `MISMATCH` or
`MISSING`. `git-secret-guard version` prints `git-secret-guard <x.y.z>`. `git-secret-guard help` lists the commands. `status` looks at the installation only; the repositories are the job
of [`doctor`](#coverage-report-doctor).

## Supported platforms

| Platform | Status |
|---|---|
| RHEL 9-compatible (x86_64) | Supported. RHEL 9-compatible (tested on Rocky Linux 9.7); there `/usr/local/bin/git` is built from source and `/usr/bin/git` 2.52 is left alone. |
| Ubuntu 24.04 LTS | Supported. The whole suite and an install E2E with real downloads run in a podman `ubuntu:24.04` container, as a non-root user, with mawk as the default awk: `tests/platform/ubuntu.sh`. |
| macOS | **macOS is not supported yet.** `install` refuses it; the darwin rows of `tools.lock` are data only. The port is planned on a Mac. |
| Other Linux | Not tested. `install` names what is missing and falls back to generic advice when `/etc/os-release` is not Ubuntu or Debian. |

### Ubuntu 24.04: prerequisites

Ubuntu 24.04 ships git 2.43, which ignores config-based hooks without any message. `install` refuses it, changes nothing and
prints the fix below. Get a git >= 2.54 first:

```bash
sudo apt install jq curl ca-certificates          # setsid (util-linux) and timeout (coreutils) are already there
sudo add-apt-repository ppa:git-core/ppa && sudo apt install git     # add-apt-repository: sudo apt install software-properties-common
git --version                                     # must say 2.54 or newer, first on PATH
```

The PPA (`ppa:git-core/ppa`) carried git 2.56.0 (`1:2.56.0-0ppa1~ubuntu24.04.2`) when this was tested. Debian has no PPA, and a PPA
may lag behind: then build git from source. The tarball is accepted only when its SHA-256 matches:

```bash
sudo apt install build-essential libcurl4-openssl-dev libssl-dev libexpat1-dev zlib1g-dev perl
curl -fsSLO https://www.kernel.org/pub/software/scm/git/git-2.56.0.tar.xz
echo '26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3  git-2.56.0.tar.xz' | sha256sum -c -
tar -xf git-2.56.0.tar.xz && cd git-2.56.0
make -j"$(nproc)" prefix=/usr/local NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 all
sudo make prefix=/usr/local NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 install     # /usr/local/bin must come before /usr/bin on PATH
```

Then `git clone <this repository> && cd git-secret-guard && bin/git-secret-guard install` works as on RHEL. `install` names the missing
prerequisite with its fix, always before it changes anything: git (the PPA command on Ubuntu and its derivatives, a build pointer on
Debian, generic text elsewhere), `jq` (`sudo apt install jq`), `setsid` (`util-linux`), `timeout` (`coreutils`), `curl`, and
`systemctl` for `--with-timer` (`systemd`). It checks all of them first and names **every** missing one with its fix in a single refusal
(with the count when there are several), so one run is enough to see everything to install. The distribution is read from `/etc/os-release`
as data (never sourced); a missing or unreadable file gives the generic hint and no shell error.

### What differs on Ubuntu, and what was checked

- **awk.** Ubuntu's default `awk` is **mawk**, RHEL's is **gawk**. Every awk program of the project (`lib/extract.awk`, the inline programs in
  `lib/extract.sh`, `lib/install.sh` and `lib/report.sh`, and `tests/comment-rules.awk`, `tests/coverage.awk`) is portable: it gives
  identical results under both, so there is **no gawk dependency**. `tests/test_awk_portability.sh` runs them under each interpreter that is
  installed and compares mawk with gawk when both are (the platform test installs both; on a machine with one of them the other tests skip with
  a reason). The corpus includes odd file names, `++`/`--`/`@@` lookalike lines, a 25000-line file, a 200000-character line, backslashes,
  malformed diffs, and numeric edge cases (9 against 10, a 3 GB file against a 2 GiB bound).
- **Checked and found identical:** `realpath -m`, `find -printf`, `stat`, `sha256sum`, `setsid`, `timeout --foreground`, `mktemp --suffix`,
  `tar`, `sed -E`, coreutils 9.4, bash 5.2, and dash as `/bin/sh` (the hook and the CLI use no `sh -c`; the test stand-ins use `#!/bin/sh`).
- **Test infrastructure that moved:** the suite drives `$GSG_TEST_GIT` (default `/usr/local/bin/git`), because the PPA git lives in
  `/usr/bin/git`; the timer tests compute the unit `PATH` from the first git on the lifecycle `PATH`.

### `tests/platform/ubuntu.sh`: the repeatable container run

```bash
tests/platform/ubuntu.sh                 # PPA first, source build when the PPA has no git >= 2.54 (--git ppa|source|auto)
tests/platform/ubuntu.sh --dry-run       # prints the exact podman command and the facts about the copy, runs nothing
```

It needs podman (5.x tested) and network access (apt, the PPA, GitHub, kernel.org). The script is executable, so `tests/platform/ubuntu.sh` runs as
written. It pulls the image when it is absent and runs it with `--rm --init`. The image is pinned by its manifest-list digest,
`docker.io/library/ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852`, so a moved tag cannot change the base.
**The container sees nothing of the host:**

- No `--env-host`, no `-e`, no mount of `$HOME`, `~/.gitconfig` or `~/.ssh`. Podman's forwarding of the host's proxy variables is switched off with `--http-proxy=false`.
- **Podman itself starts under `env -i`** with only `HOME`, `XDG_CONFIG_HOME` and `CONTAINERS_CONF` (all three point into a scratch directory),
  `PATH`, `XDG_RUNTIME_DIR`, `XDG_DATA_HOME` (the real image store, because `--pull=never` uses the image that is already there), `LANG` and the
  sentinel. Podman forwards any host variable that a `containers.conf` `env` entry names (by name or `PREFIX*` glob, from every configuration
  layer, also through `CONTAINERS_CONF` and `CONTAINERS_CONF_OVERRIDE` inherited from the caller); with this list there is no host variable left
  for such an entry to forward, so API keys in your shell never reach podman.
- **The container checks itself before any apt or network step, and a failed check aborts the run.**
  - The NAMES of its variables (read NUL-safely from `/proc/1/environ` and from the shell, never a value) must all be on an allow-list
    (`PATH HOME HOSTNAME container PWD SHLVL _ OLDPWD`). `/src` must be read-only, `/run/secrets` empty (a count, never a name), and there must be no
    `~/.ssh`, `~/.gitconfig` or `.git`.
  - Every mount point (field 5 of `/proc/self/mountinfo`) must be on an **exact list of mount points**: the 33 of an unmodified rootless podman 5
    container under this launcher, plus three masked files that other kernels add (`/proc/latency_stats`, `/proc/sched_debug`,
    `/proc/timer_stats`; their names come from the podman 5.6.0 binary and their fstype is by analogy, not probed here) and the masked directory
    `/sys/devices/virtual/powercap` (`tmpfs`, present on hosts with a powercap driver such as RAPL on physical Intel/AMD machines; absent on
    this VM, so a podman mask of another `/sys/devices/virtual` directory was probed
    to show a `tmpfs` mount). There are no `/proc`,
    `/dev` or `/sys` wildcards. Each mount point may appear once (a second mount over `/src`, `/dev/shm`, ... is named `mounted more than once`).
    For the targets podman creates itself the **fstype** (the word after the `-` separator) must be the expected one: `tmpfs` for `/etc/hosts`,
    `/etc/hostname`, `/etc/resolv.conf`, `/run/.containerenv` and `/dev/shm`, `mqueue` for `/dev/mqueue`, `devpts` for `/dev/pts`, `proc`, `sysfs`,
    `cgroup2` and so on. `/`, `/src` and `/run/podman-init` live on the host's filesystems and accept any fstype.
  - The tree of `/dev` to depth 4 may hold only the 17 baseline entries (plus `pts/<digits>` for a pty), at most 500 entries are read, and a
    subdirectory that cannot be listed fails the check. Below `/dev/shm`, `/dev/mqueue` and `/dev/pts` a stray entry is only counted
    (`shm/* (count 2)`), because its name can be a host file name.
  - The cgroup, ipc, net, pid and uts **namespaces** must differ from the launcher's: the launcher passes its own `/proc/self/ns` ids as
    `--host-ns` arguments (never as environment) and the container compares them with `/proc/1/ns`, naming only the namespace. Probed with
    `netns`, `ipcns`, `utsns` and `cgroupns` set to `host` (each named exactly); `pidns = host` is refused by podman itself under `--init`. The
    `time` namespace is shared with the host by default and the `user` namespace is **not compared** (rootful podman shares it).
  - Only stray names, mount points (with the observed fstype name when it is the wrong one), the `/dev` paths a config named and namespace names are
    printed, sanitized. No value, no mountinfo root (field 4) and no source (field 10) is. A source that cannot be read, a mount table without a
    root mount and launcher ids that never arrived fail the check; none counts as an empty list.
- **No `containers.conf` is read at all.** `containers.conf` can put host paths (`volumes`, `devices`), host namespaces (`netns`, `ipcns`) and OCI
  hooks (`hooks_dir`) into a container. containers.conf(5): "If the CONTAINERS_CONF environment variable is set, all system and user config files
  are ignored and only the specified config file will be loaded". The launcher therefore sets `CONTAINERS_CONF` to a file in the scratch `HOME`
  that holds one `[engine]` table with `hooks_dir` pointing at an **empty scratch directory**. `/etc/containers/containers.conf`, its
  `containers.conf.d` drop-ins, `/usr/share/containers/containers.conf` and `~/.config/containers/containers.conf` are never read. Probed with
  real containers (a user layer in the scratch home stands in for a system layer; nothing in `/etc` is touched): with `CONTAINERS_CONF` set a
  `volumes` layer was ignored (without it the volume was visible), `net.ipv4.ping_group_range` moved from the system default `0 0` to podman's own
  `65534 65534` and the container still ran, and an OCI hook placed in a `hooks_dir` **ran** when that directory was configured (positive control)
  and **did not run** with the empty one. `CONTAINERS_CONF_OVERRIDE`, which podman reads last even when `CONTAINERS_CONF` is set, is dropped by
  `env -i`. The same hostile layers fed through that override channel (the in-container check stays the second line of defence) aborted the run
  naming only mount points, fstypes and namespaces: `volumes` onto `/dev/shm`, `/dev/shm/x`, `/etc/hosts`, `/run/.containerenv` and
  `/dev/mqueue`, `devices` onto `/dev/shm/gsgfuse`, `ipcns = host`, `netns = host`. A `volumes` entry onto `/src` changes nothing: the
  command-line `-v` of the copy wins over a config `volumes` entry for the same target. `storage.conf`, `registries.conf` and `policy.json` are
  separate files that `CONTAINERS_CONF` does not cover (see "What the platform run trusts").
- **`/run/secrets`.** On a RHEL-family host `/usr/share/containers/mounts.conf` mounts `/usr/share/rhel/secrets` at `/run/secrets` in every
  container, which would carry the entitlement certificates and keys of a subscribed host. The scratch `HOME` holds an **empty
  `.config/containers/mounts.conf`**, which rootless podman reads before the system file, so the mount is not made. Probed again under
  `CONTAINERS_CONF`: a mounts file mapping a scratch directory is still honoured (its marker file was visible), an empty one hides it, and
  `default_mounts_file` in the `CONTAINERS_CONF` file had no effect for rootless podman (marker absent). The empty user file is therefore still
  needed. The container also fails its check when `/run/secrets` holds any entry (it counts them and never prints a name).
- The only mount is a **fresh copy of the checkout**, made when the script starts, read-only at `/src` (`:ro,Z`); the container copies it to the
  test user's home. The copy holds exactly the files `git ls-files -co --exclude-standard` lists: tracked files plus untracked files that are not
  ignored, so no `.git`. Note that **untracked files that are not ignored are copied**, whatever they hold. The project `.gitignore` lists exactly
  the scratch paths of the knowledge-base standard, `.tmp/`, `.analysis/` and `reports/troubleshooting/`, plus `.env*`, so those stay out
  (pinned by `test_the_project_gitignore_keeps_scratch_and_secret_paths_out_of_the_container_copy`). `reports/bugs/` (the bug tracker when
  there is no remote) and `reports/reviews/` are **not** ignored: they are committable, and while untracked they are copied. A secret file of
  another name that sits untracked in your checkout is copied unless you ignore it. Look at the `copy-file:` list that
  `tests/platform/ubuntu.sh --dry-run` prints before a first run.
- The cleanup `podman rm -f` runs under `timeout` (60 seconds), so a hung podman cannot keep the script from exiting.
- **The time limit fires.** Bash is PID 1 in the container and has no `TERM` trap, so the signal podman forwards used to be dropped. `podman run --init`
  puts an init process in front, and the outer call is `timeout --foreground -k 60 <limit>`; a 20 second cap ended a run at 21 seconds in the check.

`tests/test_platform.sh` pins the command line (`--dry-run`), the checks, the abort and the copy rule. The run ends with
`UBUNTU PLATFORM TEST: PASS (image <reference with its digest>)`, and the container's summary names the same **image digest**.

#### What the platform run enforces

- No host variable reaches podman (`env -i`) or the container (names checked), and the container has no `~/.ssh`, `~/.gitconfig` or `.git`.
- **No `containers.conf` layer is read** (`CONTAINERS_CONF` in the scratch home), so no `volumes`, `devices`, `env`, namespace, `default_sysctls` or
  `hooks_dir` of a system or user layer applies, and the OCI hooks directory is empty. Held by construction and probed with real containers,
  hook positive control included.
- A container that still differs aborts the run before any apt or network step: a mount point outside the exact list, one with the wrong
  fstype, one mounted twice, a stray entry in the `/dev` tree to depth 4, a cgroup, ipc, net, pid or uts namespace shared with the launcher, a
  writable `/src`, a non-empty `/run/secrets`, a variable name off the allow-list, or a check whose input could not be read.
- Only a fresh copy of the checkout is mounted, read-only.
- The exact mount table is host-specific. On a new host a false abort names the mount point; confirm it is a podman mask, then adjust
  `ISOLATION_MOUNT_RULES` in `tests/platform/ubuntu-container.sh`. A cgroup v1 host aborts by design (`/sys/fs/cgroup` is not `cgroup2`).

#### What the platform run trusts

- The software that starts the container: the podman found first on your `PATH` (the launcher passes your `PATH` on, so a podman earlier on it
  wins), its OCI runtime, the kernel, and the root-owned files `CONTAINERS_CONF` does not cover (`storage.conf`, `registries.conf`,
  `policy.json`, and the seccomp profile: `/etc/containers/seccomp.json` when it exists, else `/usr/share/containers/seccomp.json`, the one
  `podman info` reports on this host). The image is run with `--pull=never` from the local store and
  pinned by digest.
- A host path mounted over a target podman fills with a `tmpfs` (`/etc/hosts`, `/dev/shm`, ...) from a host `tmpfs` shows the expected fstype, so
  the fstype check alone cannot tell it from podman's own mount. The route to put it there is a `containers.conf` layer or a command-line flag,
  and the launcher reads no layer and passes only its own flags; the content check of the `/dev` tree still counts entries below `/dev/shm`.
- The `user` namespace is **not compared** (rootless is assumed; rootful podman shares it), the `time` namespace is shared by default, the
  children of `/proc` and `/sys` are not enumerated (only their mount points are), and the fstype of the three optional masked files is by
  analogy. Capabilities and sysctls are podman's built-in defaults once the layers are ignored, and the seccomp profile is the root-owned file
  named above (both paths appear in the podman 5.6.0 binary; that the `/etc` file takes precedence is from the containers/common source, not
  probed here, since that would mean writing to `/etc`); the container does not inspect any of them.
- Downloads inside the container: the PPA (key fingerprint pinned, checked before any apt run), the kernel.org tarball (SHA-256), shellcheck
  (SHA-256) and the scanners (SHA-256 in `tools.lock`).

Inside, as root: apt-install the prerequisites (jq, curl, pre-commit, systemd for `systemd-analyze`, dbus, gawk next to mawk), make **mawk** the default
awk, install **shellcheck 0.11.0** from its release tarball (SHA-256 pinned; apt's 0.9.0 reports other infos than the 0.11 the suite is clean on),
get git (PPA, else the SHA-256 verified tarball above), create a **non-root user**, then as that user under `env -i`: the **install E2E**
(`tests/platform/ubuntu-e2e.sh`: install with real downloads, a runtime-built fake token blocked by trufflehog and gitleaks, upgrade, uninstall,
second uninstall, no value printed) and `tests/run.sh` (some tests use `chmod 000`, which root ignores). Every step runs under `timeout`; the
run ends with a summary, the list of skipped tests with their reasons, and exits nonzero on any failure. Tests that need something the container
lacks skip with a reason (`cidx-server unit cannot be read` is the host's own service); none is faked.

#### What the container run trusts

- **The PPA signing key** is fetched from Launchpad over TLS by `add-apt-repository` the first time, so the channel is TLS plus Launchpad itself. The
  run adds the repository with `add-apt-repository -y -n` (which runs no apt update), compares the fingerprint of the key in
  `/etc/apt/sources.list.d/git-core-ubuntu-ppa-*.sources` with the pinned `F911AB184317630C59970973E363C90F8F1B6217`, and only then runs
  `apt-get update`. A mismatch fails the PPA path: the `.sources` file is deleted and `apt-get update` runs again, so the SHA-256 verified source
  build that follows in `auto` mode never runs apt as root with the unchecked PPA enabled.
- **apt packages are not version-pinned.** `jq`, `curl`, `gawk`, `mawk`, `pre-commit`, `dbus` and the others come from the Ubuntu archive (signed by
  apt's own keyring) and the PPA at whatever version they carry on the day; the summary prints the versions that were used.
- **Pinned by SHA-256:** the `git-2.56.0.tar.xz` source tarball from kernel.org and the shellcheck 0.11.0 release tarballs. **Pinned by digest:** the
  base image. **Pinned in `tools.lock`:** trufflehog and gitleaks, which the install E2E downloads for real.

## The scan (story 01.01)

`hooks/secret-scan` is the scan; the installed copy is what git runs.

### How it works

1. Git (>= 2.54) runs `hook.git-secret-guard.command` for the `pre-commit` event, from the repo root, before the
   repository's own hook. Both run even if the first fails; the commit is blocked if either fails.
2. The script reads tool locations from `settings`, an installed file next to `hooks/` and `lib/`. Missing or
   non-executable `jq`, `trufflehog`, `gitleaks`, `setsid` or `timeout`, or a relative path, blocks the commit and says
   nothing was scanned. `setsid`, `timeout`, `jq` and both scanners come from the settings file only (no environment
   override, no `PATH` lookup), so a planted `setsid` earlier on `PATH` cannot take over the scanner start. **Everything
   else the hook runs is found through `PATH`**: `bash` (the `#!/usr/bin/env bash` shebang of the hook and of
   `lib/run-scanner.sh`), `git`, `awk`, `sed`, `cp`, `rm`, `mkdir`, `mktemp`, `realpath`, `find` and the other coreutils.
   Git prepends its own exec-path to `PATH` when it runs a hook, which puts git's directory first; a `PATH` you control
   decides the rest. The shebang is not pinned to an absolute `bash`.
3. `git diff --cached` (fixed flags, `-U0`) is turned into a private scan tree under `${TMPDIR:-$HOME/.tmp}`
   (mode 700, removed on exit and on HUP/INT/TERM): each touched file at its real relative path, each **added** line
   at its real line number, every other line blank. Nothing added (empty commit, deletions only, binary only) means no
   scanner is started and the commit proceeds.
4. `trufflehog filesystem` and `gitleaks dir` run in parallel, each through `lib/run-scanner.sh` in its own session
   (`setsid`) and under a timeout. On HUP/INT/TERM the hook signals both process groups, waits for them, and only
   then removes the temp dir, so no scanner outlives the commit. Results become rows of scanner, detector, status
   (`verified`, `unknown` or `finding`), file and line. Only those are printed, never a value; log lines are reduced
   to their message words.
5. Any finding, any scanner error (unexpected exit status, timeout, unreadable report, error-level log line, skipped
   file, an oversized gitleaks log, or trufflehog exiting 0 without its `finished scanning` line with `chunks >= 1`)
   blocks with exit 1 and the hint `git commit --no-verify`. A clean scan prints nothing.

### The settings file

The hook reads `<share>/settings` (`<share>` = two levels above the resolved script path), written by `install`:
absolute `TRUFFLEHOG_BIN`, `GITLEAKS_BIN`, `JQ_BIN`, `SETSID_BIN`, `TIMEOUT_BIN` and `SCAN_TIMEOUT_SECONDS`. A missing,
relative or non-executable entry blocks the commit and says nothing was scanned; an inherited environment variable of
the same name is discarded before the file is read.
Skip once with `git commit --no-verify`; automation can disable only this hook with
`GIT_CONFIG_PARAMETERS="'hook.git-secret-guard.enabled'='false'"` (the repository's own hooks still run).

### Tests

```bash
tests/run.sh                 # all suites; PASS/FAIL/SKIPPED per test, nonzero exit on any failure
tests/run.sh tests/test_hook.sh
tests/coverage.sh            # same suites under xtrace, prints shell line coverage
```

Every suite runs in a sandbox: a scratch `HOME`, scratch `XDG_*` directories, `GIT_CONFIG_GLOBAL` and
`GIT_CONFIG_NOSYSTEM=1`, so the real `~/.gitconfig`, `~/.local` and `~/.config` are never touched. The lifecycle suites
(`test_install.sh`, `test_uninstall.sh`, `test_status.sh`, `test_tools.sh`, `test_cli.sh`, `test_lifecycle_e2e.sh`)
install from local fake tarballs through `GSG_TOOLS_BASE_URL` and `GSG_TOOLS_LOCK`;
`test_install_network.sh` downloads the real tarballs and is reported as `SKIPPED` (never as passed) when GitHub is
not reachable. The doctor suites (`test_doctor.sh`, `test_doctor_repos.sh`, `test_doctor_exempt.sh`,
`test_doctor_gitleaks.sh`, `test_doctor_info.sh`, `test_doctor_readonly.sh`) and `test_timer.sh` use the same sandbox,
with repositories under a scratch root; every lifecycle test finds a recording `systemctl` stand-in first on its `PATH`.

Runtime needs bash, `setsid` (util-linux), `timeout` (coreutils), awk, `jq` and, for `install`, `curl` and `tar`. The
tests also need `/usr/local/bin/git` (>= 2.54), `shellcheck`, `pre-commit`, and the real `trufflehog` and `gitleaks`
(paths overridable with `GSG_TEST_TRUFFLEHOG`, `GSG_TEST_GITLEAKS`, `GSG_TEST_JQ`, `GSG_TEST_SHELLCHECK`,
`GSG_TEST_SETSID`, `GSG_TEST_TIMEOUT`).

### Limits this story introduces

- **Git >= 2.54 only.** Older git (e.g. `/usr/bin/git` 2.52) ignores config hooks without any message; its commits are
  not scanned.
- **Only the `pre-commit` event.** Commits that do not fire `pre-commit` are not scanned: merge commits (they fire
  `pre-merge-commit`), `git cherry-pick`, `git rebase` and `git am`. Probed on the real install (git 2.56): a fake key
  committed on a branch with `--no-verify` reached `main` through `cherry-pick` and through `rebase` with exit 0 and no
  scan. Scan before a branch is shared; `--no-verify` there is the hole, not the replay.
- **About 2 seconds per commit.** Both scanners start on every commit that adds lines (measured 2.0 to 2.2 s per commit
  on this machine). Commits that add nothing (deletions only, empty) start no scanner.
- **The repository's own hooks still run when the scan blocks.** git runs every hook configured for `pre-commit`, the
  config hook and the repository's hookdir hook (`.git/hooks`, husky, the pre-commit framework); a blocked scan does not
  stop the repository's hook from running (probed: its marker file was written while the commit exited 1).
- **Test harnesses that copy `~/.gitconfig` get the hook too.** A sandbox whose `HOME` holds a copy of your global config
  runs the scan on its own test commits (probed: a fake key in a copied-config sandbox was blocked). Such a harness should
  set `hook.git-secret-guard.enabled=false` in its copy, or pass `-c hook.git-secret-guard.enabled=false`, or set
  `GIT_CONFIG_PARAMETERS="'hook.git-secret-guard.enabled'='false'"`.
- **Only added lines of text files.** Anything git treats as binary is not scanned, because git shows no content for
  it. That includes **UTF-16 text** (with or without a BOM, e.g. a file saved by Windows tools) and any file that
  contains a NUL byte: a UTF-16LE file holding a credential commits silently and unscanned
  (`test_real_utf16_and_nul_byte_files_commit_unscanned_a_documented_limit`). Convert such files to UTF-8 first. Pure
  renames and mode changes add no lines.
- **Attributes: committed and user ones cannot hide text, two machine-local files can.** The diff runs with
  `--attr-source` set to the empty tree, so a `.gitattributes` in the same commit (`* -diff`, `*.txt binary`) has no
  effect, and with `-c core.attributesFile=/dev/null`, so the user's attributes file (and the XDG default) has none
  either. `$GIT_DIR/info/attributes` and the system-wide gitattributes file still apply (probed on git 2.56): a `-diff`
  or `binary` rule there hides the matching files. They are local, uncommitted, machine configuration that git offers
  no per-command switch for (the system file is root-owned and could not be exercised by a test).
- **Inherited git configuration cannot change the extraction.** `-c core.bigFileThreshold=100g` is pinned, because a
  lower threshold (`git -c core.bigFileThreshold=1 commit`, or the same key in the repository config) makes git treat
  every file as binary and show no added lines, so a token would commit with no output. The command-line pin wins over
  the repository config, `GIT_CONFIG_PARAMETERS` and `GIT_CONFIG_COUNT`. 26 other settings (`diff.*`, `core.autocrlf`,
  `core.eol`, `core.safecrlf`, `color.*`, `core.quotePath`, encodings, ...) were swept in all three forms; none changes
  the result (`tests/test_inherited_config.sh`).
- **Local overrides win.** A repository-local `hook.git-secret-guard.enabled=false` or a different `.command` in its
  own config replaces the global one (last value parsed wins). `--no-verify` skips the scan.
- **Offline vs online verification.** Only `verified` and `unknown` trufflehog results block. With network access a
  fake credential that the vendor rejects is `unverified` and does not block; offline, verification fails and the same
  candidate is `unknown` and blocks.
- **Tool-native markers apply.** `gitleaks:allow` and `trufflehog:ignore` on a line mute that line for that tool;
  see [Exemptions](#exemptions).
- **Gitleaks' default config skips whole paths; trufflehog has no such list.** Extracted from the 8.30.1 binary, the
  global allowlist skips (regexes, unanchored unless shown): the name `gitleaks.toml`; images `bmp gif jpe?g png svg
  tiff?`; fonts `eot otf ttf woff2?`; documents and binaries `docx? xlsx? pdf bin socket vsidx v2 suo wsuo dll pdb exe
  gltf`; `go.mod go.sum go.work go.work.sum`; `vendor/modules.txt` and `vendor/` under `github.com`, `golang.org/x`,
  `google.golang.org`, `gopkg.in`, `istio.io`, `k8s.io`, `sigs.k8s.io`; `gradlew`, `gradle.lockfile`, `mvnw`,
  `.mvn/wrapper/MavenWrapperDownloader.java`; `node_modules/`, `bower_components/`; `deno.lock`,
  `npm-shrinkwrap.json`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`; bundled angular, bootstrap, jquery,
  jquery-ui, plotly and swagger-ui scripts and `javascript.json`; `Pipfile.lock`, `poetry.lock`; Python
  `env`/`venv`/`virtualenv` `lib` trees, `lib/python2|3.x` trees and `*.dist-info`; `vendor/bundle`, `vendor/ruby`,
  `*.gem`; `verification-metadata.xml`, `Database.refactorlog`; a path ending in `.git`. It also drops values that are
  placeholders such as `true`, `${VAR}` and `{{ name }}`. Verified with the real tools
  (`test_real_gitleaks_default_path_allowlist_hides_a_key_id_but_trufflehog_still_covers_its_own_kinds`): an AWS access
  key ID on its own, a kind only gitleaks detects, **passes** under `node_modules/`, `package-lock.json`, `*.svg`,
  `go.sum`, `vendor/github.com/` and `*.pdf`, and is blocked at a normal path. A GitHub token under `node_modules/` is
  still blocked, by trufflehog.
- **A commit cannot mute itself with a gitleaks file.** `--config` and `--gitleaks-ignore-path` point at private files,
  and a root `.gitleaksignore` added by the commit is scanned under another name instead of being honored. Only the
  versions at HEAD count, see [Exemptions](#exemptions).
- **Fail closed on timeout.** A scanner running longer than `SCAN_TIMEOUT_SECONDS` (default 300) blocks the commit.

## Exemptions

False positives are recorded **in the repository**, so everyone who clones it gets the same result and every exemption
is versioned and reviewable. Three in-repo mechanisms exist, plus three local switches. All the in-repo files are read
**from HEAD**, never from the index or the work tree: a commit cannot exempt itself, and the first commit that an
exemption covers is the one after it was committed.

### `.secret-scan-ignore`: skip paths

A file at the repository root, one pattern per line:

```
# comment lines and blank lines are ignored
tests/fixtures/**    # synthetic keys for the parser tests
**/*.pem             # public certificates
vendor               # third-party code
```

| Rule | Detail |
|---|---|
| Line format | `<glob><whitespace>#<whitespace><reason>`. A blank line or a line starting with `#` is a comment. |
| Reason is mandatory | A pattern line with no reason (no `#`, or nothing after it) **blocks the commit**, and the message names each offending line (`git-secret-guard: .secret-scan-ignore line 3: a reason is required ...`). Control characters, `..` components, an empty pattern and more than 1000 lines are rejected the same way. |
| Globs | git's `glob` pathspecs relative to the repository root. `*` does **not** cross `/`, `**` does: `*.lock` matches top-level lock files only, `**/*.lock` matches them at any depth. A plain name (`vendor`, `docs/`) excludes everything below it, but only at that path. A leading `/` or `./` is dropped. There is no `!` negation (a leading `!` is just part of the name). |
| What happens | Excluded files are given to neither trufflehog nor gitleaks. When any staged file was excluded, the commit prints `N staged file(s) excluded by .secret-scan-ignore` (a count, never names or content). |
| HEAD only | The file is read from HEAD's tree (`git ls-tree`, then `git cat-file blob`), never from the index or the work tree. With no HEAD (the first commit) or no entry there are no excludes. It must be a **regular file** (mode 100644 or 100755): a symlink (which would read as its target text), a directory, or a tree git cannot read blocks the commit. Staging a new or edited `.secret-scan-ignore` and a finding in the same commit still reports the finding. |
| `git commit --amend` | Documented limit: when HEAD is the commit that added the ignore file, `--amend` can add the exempted files to that same commit, because HEAD already holds the exemption. Git gives the hook no signal that tells an amend from an ordinary next commit (same environment, same repository state; probed), so there is no reliable fix inside the hook. Review is the control: the commit shows the new pattern and the exempted path together (`test_amend_can_fold_an_exemption_and_the_exempted_file_into_one_commit_a_documented_limit`). |
| Replace refs | The hook exports `GIT_NO_REPLACE_OBJECTS=1`. Without it, `git replace <HEAD commit> <another commit>` makes `git ls-tree HEAD` return that other commit's files, so a `.secret-scan-ignore` or `.gitleaks.toml` that is not in the branch history would be read as the exemption of the real HEAD (verified with the real tools: a substituted catch-all and a substituted allowlist both let a finding through before the pin). The pin covers every HEAD read and the staged diff. |
| Inherited git settings | The hook unsets `GIT_LITERAL_PATHSPECS`, `GIT_GLOB_PATHSPECS`, `GIT_NOGLOB_PATHSPECS` and `GIT_ICASE_PATHSPECS` (also set by `git --literal-pathspecs`) before any diff; in literal mode every exclude matches nothing and the commit would pass unscanned. Diff settings such as `diff.context`, `diff.noprefix`, `diff.mnemonicPrefix`, `diff.renames`, `GIT_DIFF_OPTS` and `GIT_EXTERNAL_DIFF` cannot change what is extracted either (pinned by a test). |
| The ignore file is always scanned | Even a pattern that matches `.secret-scan-ignore` itself (or a catch-all) cannot hide it: git cannot re-include a path once excluded, so the hook extracts the ignore file in a separate pass. |
| An invalid file at HEAD blocks every commit | That includes the commit that repairs it, because HEAD is what is read. Repair it with `git commit --no-verify`. |

**Catch-all patterns are allowed but loud.** Three checks, all using git's own pathspec matching instead of string
comparison:

1. **Per pattern**: a pattern containing `*`, `?` or `[` is tested against probe paths at several depths and name
   shapes, so `**`, `**/*`, `**/**`, `/**` and `./**` are all caught. A pattern with none of those characters is a
   plain path prefix and cannot be a catch-all, so it is not probed.
2. **Union of all patterns against the tracked files**: if the patterns together leave no tracked file (index,
   `.secret-scan-ignore` itself left out) to scan, the commit prints
   `WARNING: the patterns in .secret-scan-ignore together exempt every tracked file`. This catches shapes no probe
   can, such as `**/*[!t]` plus `**/*t`, `**/[!a]*`, or a list of directories that covers the tree. It does not warn
   about patterns that exempt *most* of the tree.
3. **This commit**: when every staged file with added lines is excluded it prints `WARNING: every staged file with
   added lines is excluded ...; nothing else in this commit was scanned`.

Every commit prints these warnings, even one that has nothing to scan:

```
git-secret-guard: WARNING: .secret-scan-ignore line 1 (pattern '**') exempts the whole repository from scanning
```

The pattern is quoted as you wrote it (`./**` stays `./**`, not the normalized `**`), cut at 60 characters; control
characters never reach the output because such a line is rejected.

Because `*` does not cross `/` in git's glob syntax, `*` exempts **only top-level files** (the warning says so and
points at `**`) and `*/**` exempts only files below the top level; both are warned about as well.

### Inline markers: skip one line, per tool

Verified with the real trufflehog 3.99.2 and gitleaks 8.30.1
(`tests/test_exemptions_real.sh`; the dead-proxy trick in `CLAUDE.md` makes trufflehog report `unknown` offline):

| Marker on the same line as the secret | trufflehog | gitleaks | Commit |
|---|---|---|---|
| `trufflehog:ignore` | silent | **still reports** | blocked by gitleaks |
| `gitleaks:allow` | **still reports** | silent | blocked by trufflehog |
| both, in either order, after any comment prefix (`# trufflehog:ignore gitleaks:allow`) | silent | silent | succeeds |

The marker must be on the **same line** as the value; a marker on the line above mutes nothing. A secret that only
one of the tools detects needs only that tool's marker.

### The repository's own gitleaks configuration

- `.gitleaks.toml` at HEAD is passed to gitleaks with `--config`: its custom rules fire and its allowlists apply.
- `.gitleaksignore` at HEAD is passed with `--gitleaks-ignore-path`. A fingerprint `<path>:<rule>:<line>` (for
  example `src/k.txt:aws-access-token:1`) suppresses exactly that finding and no other; the line is the line number in
  the version being committed, so edits above it shift the fingerprint.
- Versions in the index or work tree are never honored. A commit that stages its own `.gitleaks.toml` or
  `.gitleaksignore` is scanned with the HEAD versions (or the defaults), and the staged file is just scanned as text.
- Each applied file prints one line (`using .gitleaks.toml from HEAD ...`), so the exemption is never silent.
- **A HEAD `.gitleaks.toml` must load on its own, which refuses every `[extend] path`.** Verified on 8.30.1: gitleaks
  resolves `extend.path` against its working directory, which here is the scan tree of added lines, not the config's
  directory. A commit could therefore stage the file a HEAD config extends and have gitleaks honor it (for example an
  allowlist that mutes everything), and a legitimate `path = "ci/base.toml"` would fail every scan. No line-based
  detector is sound against TOML (key and table names are case-insensitive for gitleaks, a multi-line string can hide
  a `[` line, `"path"` is the key `path`, `"extend".path`, `Extend.Path` and inline tables are all valid), so the
  hook asks gitleaks itself: before scanning it runs the real binary with the HEAD copy from an **empty working
  directory** (over a separate probe directory, see the next bullet), under the scan timeout. Any failure (a relative path cannot be opened there, a syntax error, a timeout, any
  non-zero exit) **blocks the commit** with `.gitleaks.toml at HEAD does not load on its own (gitleaks said: ...)`;
  only the message words of gitleaks' first error line are shown (its colour codes are stripped first: 8.30.1 colours
  fatal lines even with `--no-color`), never its fields. Inline the base config into
  `.gitleaks.toml`. Verified spellings: 22, including the 13 a regex missed
  (`test_real_every_spelling_of_extend_path_is_refused`). `extend.url` is ignored by 8.30.1.
  **Residual:** an *absolute* path to a file that exists outside the scan tree still loads, because it does not
  depend on the working directory; it is local configuration reviewed at HEAD, so it is accepted
  (`test_real_an_absolute_extend_path_to_an_existing_file_still_loads_a_documented_residual`).
- **A `.gitleaks.toml` without `[extend]` / `useDefault = true` turns gitleaks' built-in rules off.** Verified with the
  real binary: gitleaks then runs only the rules in that file, so a bare AWS access key ID is no longer reported, and a
  file with no rules detects nothing at all (exit 0). trufflehog is unaffected: the hook never gives it a repository
  configuration.
- **The warning is behavioural, not a reading of the TOML.** No line scan can tell whether `useDefault` is in force
  (`[Extend]` / `UseDefault`, `extend = { useDefault = true }`, `extend.useDefault = true` and `"extend".useDefault`
  all keep the defaults; the same text inside a multi-line string keeps nothing). So the pre-flight run described
  above also scans one probe file, built at run time, holding an AWS access key ID that only gitleaks' built-in
  `aws-access-token` rule detects. If gitleaks does not report it, the commit prints
  `WARNING: with .gitleaks.toml at HEAD, gitleaks does not detect its own built-in rules (e.g. AWS access keys): either
  [extend] useDefault = true is missing, or an allowlist or disabledRules turns them off; trufflehog still runs`.
  The probe is one extra small file in the same gitleaks process that already checks the config (no extra process;
  measured over 3 rounds of 40 calls: 45.7 to 47.0 ms for the pre-flight with the probe against 47.2 to 48.8 ms without it, i.e. no measurable cost). It is named `gsg-probe-builtin-rule` (no extension)
  so an ordinary allowlist does not match it, but a **global allowlist that covers everything** (`paths = ['''.*''']`)
  does, and then the warning is true: the built-in rules are off for the commit. A repository rule that itself
  matches an AWS key ID also counts as "detected", so such a config is not warned about. If the probe run fails, the
  commit is blocked like any other pre-flight failure. The probe value is never printed.
  The probe covers **one** built-in rule (`aws-access-token`). `disabledRules` naming other built-in rules (e.g.
  `disabledRules = ["github-pat"]`) turns those off with no warning; that was verified end to end, and trufflehog still
  blocked the GitHub token in that run. Because the probe file sits under the private work directory
  (normally `~/.tmp/...`), a repository allowlist that matches that path (e.g. `\.tmp/`) can produce a false warning;
  it never hides a finding.

### Local switches

For a repository you do not control, where an in-repo file is not an option:

- `git config hook.git-secret-guard.enabled false` inside that repository disables only this hook there (the
  repository's own hooks still run). [`doctor`](#coverage-report-doctor) reports every repository that does this, with
  the config file that holds the key.
- Automation can do the same for one process without touching any file:
  `GIT_CONFIG_PARAMETERS="'hook.git-secret-guard.enabled'='false'"`.
- `git commit --no-verify` skips the scan for one commit.

## Coverage report: `doctor`

The hook cannot report a repository where it never runs. `git-secret-guard doctor [--roots DIR...]` checks the machine and
every repository under the roots and lists what is not protected, with the config file responsible.

```bash
git-secret-guard doctor                          # machine + every repository under ~/Dev
git-secret-guard doctor --roots ~/Dev ~/work     # other roots (several allowed)
```

**It is read-only.** It runs `git config`, `git hook list pre-commit`, `git rev-parse`, `git ls-tree`, `git cat-file`,
`git ls-files`, `<tool> --version` and, for a repository with a `.gitleaks.toml` at HEAD, the same gitleaks pre-flight the
hook runs. It writes nothing: no file, no git config, no state. Its only scratch space is one private directory under
`$TMPDIR` (or `/tmp`), removed on exit. `tests/test_doctor_readonly.sh` checksums every file of a sandbox (hashes, modes,
sizes, modification times: config files, repositories, state and share dirs) before and after a run over repositories
with every kind of problem, and requires the temp directory to be empty afterwards. Before any HEAD read it exports
`GIT_NO_REPLACE_OBJECTS=1`, unsets the four `GIT_*_PATHSPECS` variables and every repository-local `GIT_*` variable (a
`GIT_DIR` inherited from a calling hook cannot point every check at one repository), and sets `GIT_OPTIONAL_LOCKS=0`.

**It runs nothing a repository configures, and it contacts no remote.** The repositories it reads are other people's
checkouts, so after the variable cleanup above doctor exports `GIT_NO_LAZY_FETCH=1` (a missing blob or tree in a partial
clone is reported as unreadable, never fetched through the promisor remote: no `uploadpack`, `sshCommand` or credential
helper runs) and forces `core.fsmonitor=false` through `GIT_CONFIG_COUNT` (command scope beats repository config; reading
the index would otherwise start the repository's fsmonitor command). This is doctor-only: the hook runs inside the
committer's own repository, where git already runs that config, and it never loads the doctor code. Checked and found
harmless: `gc.auto` and `maintenance.auto` (no command doctor runs triggers them), `core.hooksPath` hooks such as
`reference-transaction` and `post-index-change` (doctor updates no ref and writes no index), diff and textconv drivers
(doctor diffs nothing in the repositories). A repository git refuses for ownership reasons (`safe.directory`) is listed as
`cannot be inspected: fatal: detected dubious ownership ...`, not a doctor error. `tests/test_doctor_readonly.sh` plants a
marker-writing fsmonitor and hooks, and a `--filter=blob:none` partial clone served by a local `file://` remote with a
marker-writing `uploadpack`, and requires no marker file and an unchanged object store.

**It is time-bounded.** Every git call of the repository phase runs under the settings' `timeout`, limited by
`DOCTOR_TIMEOUT_SECONDS` in the settings file (default 30, a positive integer; an invalid value is a machine PROBLEM). A
repository whose config makes git block (an `include.path` pointing at a FIFO, say) becomes `cannot be inspected: timed out
after 30s` or `cannot read the hooks git runs (... exit 124: timed out after 30s)`, and the run goes on. The gitleaks
pre-flight uses the smaller of that value and `SCAN_TIMEOUT_SECONDS`; its timeout reads `gitleaks timed out after Ns loading
.gitleaks.toml at HEAD (doctor's limit; the hook allows 300s)`. If `timeout` itself is unusable no git is run in the
repository phase and every repository is listed as not inspected. The timer's service adds `TimeoutStartSec=1h` as the
outer bound.

### Machine checks

| Check | Problem when |
|---|---|
| Installed | no state file (`not installed`) or an unreadable one |
| State records | `tools_installed_by_us`, `tools_placed` or `tools_replaced` hold an invalid word or a tool install does not manage (PROBLEM); two hashes for one tool (an install did not finish placing it) or an aside file recorded in `tools_replaced` that is gone (WARNING) |
| Hook config | `hook.git-secret-guard.event` is not exactly one `pre-commit`, `.command` is not exactly one value equal to the installed `hooks/secret-scan`, that file is missing or not executable, or `enabled` is false in the global or system config. A wrong count is reported as `has 2 values (global <file>; global <file>), 1 of them the installed hook`: **never the values**, a global command can hold a token and the timer writes this output to the journal |
| Tools | the settings file is missing, or `TRUFFLEHOG_BIN`, `GITLEAKS_BIN`, `JQ_BIN`, `SETSID_BIN`, `TIMEOUT_BIN` is not an absolute executable, or a scanner does not report the version `tools.lock` pins (judged exactly like `install` and `status`) |
| `core.hooksPath` | any global value is left, including one in the XDG config or in an included file (the file is named) |
| git | WARNING for every reachable git older than 2.54: all `git` on `PATH` plus `/usr/bin/git` (2.52 on this machine), by path and version. Such a git ignores config hooks silently, so commits made with it are **not scanned**. Doctor itself needs the git first on `PATH` to be 2.54 or newer (otherwise it exits 2) |
| Timer | only when the state says a timer is installed: both unit files exist, were written by install, and `SYSTEMCTL_BIN` in the settings is usable |

### Repository discovery

Every `.git` entry (directory or file) at most **three levels** below a root is a repository: `ROOT/a`, `ROOT/a/b`,
`ROOT/a/b/c`, and the root itself. `node_modules` directories are not entered. Symlinks are not followed. Repositories are
deduplicated by `git rev-parse --git-common-dir`, so a **worktree** is reported once, under its main repository (shown as
`worktrees: ...`; when the main repository is outside the roots it is still named, from its common dir). Bounds, all
fail-closed: more than 2000 `.git` entries, a root that is not a directory, or a `find` failure that is not a permission
problem is a doctor error (exit status 2), never a silently shorter list. **A directory the user cannot read** (a database
data dir, say) does not stop the report: it is listed under `not searched:` as `PROBLEM  cannot read <dir>; repositories
below it are not checked`, the rest is checked, and the exit status is 1. A `.git` that git cannot open is **listed**
(`cannot be inspected: ...`), not skipped; so is a `.git` entry that does not resolve to its own directory (an empty
`parent/fixtures/sub/.git` makes git answer for `parent`: it is reported as `sub`, `git resolves it to <parent>`, and the
parent is judged on its own). Bare repositories have no `.git` entry and are not found.

### Per-repository checks

| Check | Result |
|---|---|
| Is the hook effective? | `git-secret-guard` must be listed, with no prefix, by `git hook list pre-commit`. A `disabled` or `event-disabled` line means `hook.git-secret-guard.enabled=false` or `hook.pre-commit.enabled=false`; the report says `disabled in local config: <key>=<value> (<file>)` and names the scope that holds the key (local, global, worktree, command) and the file git read it from (`--show-origin`, also an included file). Not listed at all means no `hook.git-secret-guard.event=pre-commit` reaches the repository; an event without its command (git refuses) reads `hook not reached: the global hook config is incomplete (see machine section)`. **This check runs in the main checkout and in every linked worktree**: with `extensions.worktreeConfig=true` a worktree can switch the hook off in its own `config.worktree`, and the finding is shown under the main repository as `worktree <path>: disabled in worktree config: ...`. A finding the main checkout already has (shared config) is not repeated per worktree. PROBLEM |
| Command overridden? | the last `hook.git-secret-guard.command` comes from a non-global scope and is not the installed script: `command overridden in local config: hook.git-secret-guard.command (<file>)`. The value is never printed. PROBLEM |
| HEAD `.secret-scan-ignore` | validated with the hook's own code (`scan_ignore_parse`, `scan_ignore_scope`): a line without a reason is a PROBLEM with its line number, as are a symlink or directory, a control character, a `..` component and more than 1000 lines (the hook blocks every commit on these); a catch-all (`**`, `./**`, a union of patterns that covers every tracked file, `*` for top-level files) is a WARNING that quotes the pattern as written, cut at 60 characters (a cut is always marked with `…`). Only HEAD counts, never the index or the work tree, and a `git replace` ref cannot substitute it |
| HEAD `.gitleaks.toml` | the hook's own pre-flight (`gitleaks_config_preflight`, under `SCAN_TIMEOUT_SECONDS` from the settings): a config that does not load (an `[extend] path`, a syntax error, a timeout) is a PROBLEM; one that loads but leaves gitleaks' built-in rules off is the hook's WARNING sentence. If gitleaks or timeout is unusable the check is reported as not done (WARNING), never skipped silently |
| `.pre-commit-config.yaml` | info when `<common-dir>/hooks/pre-commit` is not the pre-commit framework's hook (`pre-commit install not run`) |
| Repo-local `core.hooksPath` | info (husky and similar): config hooks run whatever it says, so it is harmless, and it is listed so you can see it |

### Output and exit status

```
machine:
  ok       installed: version 0.1.0 (state /home/me/.local/state/git-secret-guard/state)
  ok       state records: 2 placed hash(es), 0 original(s) moved aside
  ok       hook: hook.git-secret-guard.event=pre-commit, command=/home/me/.local/share/git-secret-guard/hooks/secret-scan (executable)
  ok       trufflehog: /home/me/.local/bin/trufflehog 3.99.2 (pinned 3.99.2)
  ok       gitleaks: /home/me/.local/bin/gitleaks 8.30.1 (pinned 8.30.1)
  ok       jq: /usr/bin/jq
  ok       core.hooksPath: no global value
  ok       git: /usr/local/bin/git 2.56.0
  WARNING  git: /usr/bin/git is git 2.52.0; it ignores config-based hooks without any message, so commits made with it are NOT scanned
repos with findings:
  /home/me/Dev/legacy
    PROBLEM  disabled in local config: hook.git-secret-guard.enabled=false (/home/me/Dev/legacy/.git/config); remove that key to cover this repository
  /home/me/Dev/web
    info     core.hooksPath=.husky/_ in local config (/home/me/Dev/web/.git/config); harmless, config hooks run whatever it says
summary: 57 repos, 56 covered
warnings: 1 (listed above, they do not change the exit status)
```

The machine section is always printed in full. Only repositories with a finding follow it. A repository counts as
**covered** when it has no PROBLEM (warnings and info do not change that). `warnings:` appears only when there are some.

| Exit status | Meaning |
|---|---|
| exit status 0 | no PROBLEM anywhere (WARNING and info lines can still be printed) |
| exit status 1 | at least one PROBLEM, on the machine or in a repository |
| exit status 2 | doctor could not run or finish: git first on `PATH` older than 2.54, a root that is not a directory (`~/Dev` is the default root and must exist), a global git config that cannot be read, a bound exceeded, a `find` failure that is not a permission problem, a usage error. (An unreadable directory is a PROBLEM line and exit status 1, see discovery) |

PROBLEM, WARNING and info are the three severities; a PROBLEM names what to do (`run git-secret-guard install`, remove a
key from a named file). Nothing from a file's content, a secret or the environment is printed: not a reason text, not a
command override value, not the probe value of the pre-flight. Repository names, paths and tool-provided text pass
through a filter that turns control characters into `?`, as the hook does. Every value doctor cuts (a `core.hooksPath`
value at 120 characters, a catch-all pattern at 60, state entries at 80, git's own error text at 200) ends with `…`, and a
value that fits is printed whole, so a cut path is never mistaken for a complete, different one.

**Limits.** The hook-effective check runs in every worktree, but the HEAD files (`.secret-scan-ignore`, `.gitleaks.toml`)
are read at the main repository's HEAD: a linked worktree on another branch can carry a different `.secret-scan-ignore`,
which is not read. A linked worktree outside `--roots` is not checked: only `.git` entries under the roots are looked at, even when its
main repository is inside them. Bare repositories and repositories deeper than three levels are not found.
Doctor reports what the config files say: before it looks it drops every variable that `git rev-parse --local-env-vars`
lists, `GIT_CONFIG_PARAMETERS` and `GIT_CONFIG_COUNT` included, so a switch-off exported in your shell (or `--no-verify`)
is not visible to it. A git older than 2.54 shows up only as the git warning above. `doctor` does not ask systemd whether
the timer is enabled (see below).

### The weekly timer

```bash
bin/git-secret-guard install --with-timer      # or: git-secret-guard install --with-timer
journalctl --user -u git-secret-guard-doctor.service     # read the reports
systemctl --user list-timers git-secret-guard-doctor.timer
```

`install --with-timer` writes `git-secret-guard-doctor.service` (a one-shot `ExecStart="<share>/bin/git-secret-guard" doctor`,
with the `PATH` of the git install found first, followed by `/usr/local/bin:/usr/bin:/bin`, each directory once, because
the user manager has its own; `TimeoutStartSec=1h`, because systemd gives a one-shot service no start timeout otherwise; and
an `Environment=` line for each of `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CONFIG_HOME` and `GIT_CONFIG_GLOBAL` that was set
when you ran install, because the user manager does not pass your login environment on and a custom one would make the
timer's doctor report `not installed`) and `git-secret-guard-doctor.timer`
(`OnCalendar=weekly`, `Persistent=true`, `WantedBy=timers.target`) into `${XDG_CONFIG_HOME:-~/.config}/systemd/user/`, then
runs `systemctl --user enable --now git-secret-guard-doctor.timer`. The service output goes to the journal. Because doctor
exits 1 on a PROBLEM, the unit is shown as failed in `systemctl --user status git-secret-guard-doctor.service` whenever
the machine has a finding, which is what a timer can act on.

- **Without `--with-timer` nothing is installed**, and `systemctl` is never called.
- `systemctl` is looked up on `PATH` once, at install time, and its absolute path is written to the settings file as
  `SYSTEMCTL_BIN`, like `jq`, `setsid` and `timeout`. Uninstall and doctor use that path and never search `PATH`
  (`test_systemctl_is_looked_up_only_in_lib_install_sh`). A missing `systemctl` refuses the install before anything changes.
- The state records `timer_installed=yes` before the units are written, so an interrupted install can still be uninstalled.
  A plain `install` over an installed timer **keeps it recorded and leaves its enablement alone**: a timer you disabled
  stays disabled, `systemctl` is never called and is not needed (a machine that lost it can still upgrade the hook; the
  recorded `SYSTEMCTL_BIN` stays in the settings for `uninstall`). Units are rewritten only when they are ours and their text
  changed, with a hint to run `systemctl --user daemon-reload`; a foreign unit is left alone, and a value that cannot go into
  a unit file skips the refresh with a message. Only `--with-timer` writes and enables. `uninstall` is the way to remove it.
- Units are written atomically and carry a marker line. Install refuses to overwrite a unit of the same name that it did not
  write, and uninstall leaves such a unit alone and says so. A share, config or git path containing a quote, a backslash,
  `%`, `$` or a control character is refused (a unit file cannot carry it safely); spaces are quoted.
- A failing `systemctl --user enable --now` leaves the hook installed and scanning and says so; run
  `install --with-timer` again once the cause (usually no user manager reachable) is fixed.
- `uninstall` runs `systemctl --user disable --now git-secret-guard-doctor.timer`, removes both unit files, then runs
  `systemctl --user daemon-reload`, all before the share dir goes (the settings that name `systemctl` live there). If any
  step fails it stops with the units, share dir and state kept and says what to run; running `uninstall` again finishes.
  If `systemctl` from the settings cannot run, it prints the manual `systemctl --user disable --now ...` command. A
  `timers.target.wants/git-secret-guard-doctor.timer` enable link that dangles because the timer file is already gone is
  removed too, but only a symlink whose own text is our timer unit path (a link to anything else, a live link and a regular
  file stay).
- **Tests never touch the real user manager.** Lifecycle tests put a recording `systemctl` stand-in first on every `PATH`
  they use, write units into a scratch `XDG_CONFIG_HOME`, and validate the generated units with the real
  `systemd-analyze --user verify` (a parser; it runs in an in-process test manager with a scratch `XDG_RUNTIME_DIR`).
