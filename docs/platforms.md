# Supported platforms

| Platform | Status |
|---|---|
| RHEL 9-compatible (x86_64) | Supported. RHEL 9-compatible (tested on Rocky Linux 9.7); there `/usr/local/bin/git` is built from source and `/usr/bin/git` 2.52 is left alone. |
| Ubuntu 24.04 LTS | Supported. The whole suite and an install E2E with real downloads run in a podman `ubuntu:24.04` container, as a non-root user, with mawk as the default awk: `tests/platform/ubuntu.sh`. |
| macOS | **macOS is not supported yet.** `install` refuses it; the darwin rows of `tools.lock` are data only. The port is planned on a Mac. |
| Other Linux | Not tested. `install` names what is missing and falls back to generic advice when `/etc/os-release` is not Ubuntu or Debian. |

## Ubuntu 24.04: prerequisites

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

## What differs on Ubuntu, and what was checked

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

## `tests/platform/ubuntu.sh`: the repeatable container run

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

### What the platform run enforces

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

### What the platform run trusts

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

### What the container run trusts

- **The PPA signing key** is fetched from Launchpad over TLS by `add-apt-repository` the first time, so the channel is TLS plus Launchpad itself. The
  run adds the repository with `add-apt-repository -y -n` (which runs no apt update), compares the fingerprint of the key in
  `/etc/apt/sources.list.d/git-core-ubuntu-ppa-*.sources` with the pinned `F911AB184317630C59970973E363C90F8F1B6217`, and only then runs
  `apt-get update`. A mismatch fails the PPA path: the `.sources` file is deleted and `apt-get update` runs again, so the SHA-256 verified source
  build that follows in `auto` mode never runs apt as root with the unchecked PPA enabled.
- **apt packages are not version-pinned.** `jq`, `curl`, `gawk`, `mawk`, `pre-commit`, `dbus` and the others come from the Ubuntu archive (signed by
  apt's own keyring) and the PPA at whatever version they carry on the day; the summary prints the versions that were used.
- **Pinned by SHA-256:** the `git-2.56.0.tar.xz` source tarball from kernel.org and the shellcheck 0.11.0 release tarballs. **Pinned by digest:** the
  base image. **Pinned in `tools.lock`:** trufflehog and gitleaks, which the install E2E downloads for real.
