# Supported platforms

| Platform | Status |
|---|---|
| RHEL 9-compatible (x86_64) | Supported. RHEL 9-compatible (tested on Rocky Linux 9.7); there `/usr/local/bin/git` is built from source and `/usr/bin/git` 2.52 is left alone. |
| Ubuntu 24.04 LTS | Supported. The whole suite and an install E2E with real downloads run in a podman `ubuntu:24.04` container, as a non-root user, with mawk as the default awk: `tests/platform/ubuntu.sh`. |
| macOS arm64 (tested on macOS 26.7.1) | Supported, with Homebrew: see [macOS (Homebrew)](#macos-homebrew). The whole suite and an install E2E in a scratch home run on a real Mac. |
| macOS x86_64 (Intel) | Mapped (`darwin_amd64` / `darwin_x64` rows of `tools.lock`) but **not tested**. |
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

## macOS (Homebrew)

Tested on macOS 26.7.1, arm64, with Apple Git 2.54.0 (it meets the git >= 2.54 floor and honours `hook.<name>.command`; it has no
`hook.<event>.enabled`, so a repository switching the whole `pre-commit` event off that way is not visible to it either). Intel Macs
(x86_64) map to the `darwin_amd64` and `darwin_x64` rows of `tools.lock` and are **not tested**. Homebrew is required on macOS and
nowhere else; Linux behaviour, prerequisites and hints are unchanged.

```bash
git clone <this repository> && cd git-secret-guard
bin/git-secret-guard install        # lists what is missing, installs it with brew after the other checks pass, then installs as on Linux
```

- **What `install` asks of Homebrew.** It finds `brew` on `PATH` (without it: refusal with `https://brew.sh`, nothing changed), then
  checks four prerequisites and lists the missing ones in the prerequisite report: `bash` (bash 4.4 or newer; macOS ships 3.2),
  `coreutils` (GNU `timeout`, `realpath -m`, `mv -T`, `install -T` ... in `$(brew --prefix)/opt/coreutils/libexec/gnubin`), `util-linux`
  (`setsid`; keg-only, so it lives in `$(brew --prefix)/opt/util-linux/bin`) and `jq` only when none is on `PATH` (macOS 15 and later ship
  `/usr/bin/jq`).
- **When `brew install` runs.** Started by the system bash 3.2 and with no Homebrew bash 4.4 or newer present, `install` first runs
  `brew install bash` **alone** (it says so) and re-executes under that bash. That is the one Homebrew package installed before the checks. With a
  suitable bash already running or installed, nothing is installed up front. The other missing formulae (`coreutils`, `util-linux`, `jq`) are
  installed by **one** `brew install` only after every refusable check has passed (the `core.hooksPath` read and refusal, the CLI link,
  the global-config write probe, the state and recorded-`core.hooksPath` checks, the `tools.lock` lookup of every scanner for this platform).
  When a GNU `timeout` already exists (`coreutils` installed), the tool plan, the download, the SHA-256 check and the `--version` check run
  before that `brew install` as well, so a bad download refuses with nothing changed. Only on a Mac without `coreutils` do they follow it, because
  the version probes need a bounded `timeout`; a failed download there is a refusal that names what brew installed. An old git, an
  unsupported CPU, `--with-timer`, a set `core.hooksPath`, a lock without a row for this platform and the other refusals therefore install
  nothing beyond the bootstrap's `bash`.
- **The CLI needs the GNU directory.** On macOS every command except `install`, `version` and `help` refuses, naming `brew install coreutils`,
  when no GNU directory is known (the installed copy's settings have no `GNUBIN_DIR`, or a checkout finds no `brew` on `PATH`). A global-config
  `include` whose target does not exist (a dangling symlink) is skipped, as git does; one that exists but cannot be resolved is refused.
- **What a refusal says after a brew install.** Once any `brew install` ran in the invocation, no message claims that nothing was changed;
  it names what changed (`the only change made was the Homebrew install of bash in this run`). A failing `brew install` ends the run with brew's
  own message and says Homebrew may have installed part of the list before failing (see `brew list`).
- **The scanners are never installed with brew.** trufflehog and gitleaks come from the SHA-256-pinned darwin rows of `tools.lock`
  through the same download, verify, extract and `--version` path as on Linux, into `~/.local/bin`. Brew only has the latest release
  (trufflehog 3.99.7 against the pin 3.99.2 when this was written), and the documented behaviours are verified per pinned version.
- **Absolute paths, no `PATH` order.** The settings file records `BASH_BIN` (the Homebrew bash), `GNUBIN_DIR` (the GNU coreutils
  directory), `TIMEOUT_BIN` (`gnubin/timeout`), `SETSID_BIN` and `JQ_BIN`. The hook puts `GNUBIN_DIR` first on its own `PATH`
  (an absolute, existing directory or it blocks) and the CLI does the same, so no BSD tool answers where a GNU flag is used.
- **The hook never runs unscanned under bash 3.2.** The configured command is `'<BASH_BIN>' '<share>/hooks/secret-scan'`, so a GUI git
  client that starts with `/usr/bin:/bin` (and `/bin/bash` 3.2 first) still runs the hook under the recorded bash. A hook started any
  other way under bash older than 4.4 blocks with `nothing was scanned` before it reads another line. The CLI behaves the same: started
  by bash 3.2 it re-executes under the Homebrew bash (`install` first runs `brew install bash` alone when none exists), or refuses.
  An installed copy started that way with no `brew` on `PATH` (`env -i PATH=/usr/bin:/bin /bin/bash ~/.local/bin/git-secret-guard status`)
  reads `BASH_BIN` from its own `settings` as data (never sourced under 3.2; only a plain absolute path of letters, digits and
  `._/+@%-` is believed, so a value that needs shell quoting is ignored), checks that it is executable and reports bash 4.4 or
  newer, and re-executes under it once. If that fails it refuses with a message that names the command, the unusable `BASH_BIN`
  and what to do (put the Homebrew bash first on `PATH`, or `brew install bash`), never the install wording.
- **`install --with-timer` is refused** on macOS (`launchd is not supported yet`) and changes nothing; the weekly doctor timer is
  systemd only for now. `doctor` and `status` work and check `BASH_BIN` like the other recorded tools.
- **GNU flags and their answers.** `realpath -m`, `mktemp --suffix`, `mv -T`/`-n`, `install -T`, `chmod 700 -- DIR` and `sort -z` run from
  the GNU directory. `find -printf` (backup bounds) stays where `find` has it (Linux) and is `find -print0 | xargs stat` elsewhere (GNU or BSD `stat` format chosen by a probe);
  `find -ls` was tried and dropped, because an owner or group name with a space moves its size column;
  `find -readable`/`-executable` (doctor's unreadable directories) became `[ -r ]` and `[ -x ]` on the directories `find` lists; BSD `wc`
  pads its count with spaces, so the report line strips them. `cp -a`, `tar --no-same-owner`, `sed 's/\x1b...//'` and `find -quit` behave
  as on Linux with the BSD tools.
- **awk.** macOS `/usr/bin/awk` (one-true-awk 20200816) gives the expected results for `lib/extract.awk`, every malformed diff and the
  inline programs: `tests/test_awk_portability.sh` runs them under it (named `bwk`) next to the gawk and mawk cases.
- **Running the suite on a Mac.** `tests/run.sh` puts the Homebrew bash and the GNU directory first on `PATH` itself. The real-scanner
  suites use the pinned binaries: `tests/fetch-test-tools.sh` downloads them (SHA-256 checked against `tools.lock`) into
  `~/.cache/git-secret-guard-test-tools`, never into `~/.local/bin`. The brew steps are tested with a recording `brew` stand-in and a
  fake prefix (never a real `brew install`); the Linux-behaviour lifecycle suites run on a Mac under a fake Linux `uname`. Explained
  skips: the podman suite (`test_platform.sh`: Linux only), systemd tests (no `systemctl`), `hook.<event>.enabled` (Apple Git has no
  such key), the gawk and mawk cases when those awks are not installed.

## What differs on Ubuntu, and what was checked

- **awk.** Ubuntu's default `awk` is **mawk**, RHEL's is **gawk**. Every awk program of the project (`lib/extract.awk`, the inline programs in
  `lib/extract.sh`, `lib/install.sh` and `lib/report.sh`, and `tests/comment-rules.awk`, `tests/coverage.awk`) is portable: it gives
  identical results under both, so there is **no gawk dependency**. `tests/test_awk_portability.sh` runs them under each interpreter that is
  installed and compares mawk with gawk when both are (the platform test installs both; on a machine with one of them the other tests skip with
  a reason). The corpus includes odd file names, `++`/`--`/`@@` lookalike lines, a 25000-line file, a 200000-character line, backslashes,
  malformed diffs, and numeric edge cases (9 against 10, a 3 GB file against a 2 GiB bound).
- **Checked and found identical:** `realpath -m`, `stat`, `sha256sum`, `setsid`, `timeout --foreground`, `mktemp --suffix`,
  `tar`, `sed -E`, coreutils 9.4, bash 5.2, and dash as `/bin/sh` (the hook and the CLI use no `sh -c`; the test stand-ins use `#!/bin/sh`).
  The backup-bounds walk uses `find -printf` on Linux, exactly as before story 06.01 (the macOS size source only runs where `find` has no `-printf`).
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

## Linux containers from a Mac (a regression run, not a trust boundary)

```
brew install podman coreutils            # then: podman machine init && podman machine start
PATH=/opt/homebrew/bin:$PATH tests/platform/mac-linux.sh ubuntu    # Ubuntu 24.04, same pinned image as ubuntu.sh
PATH=/opt/homebrew/bin:$PATH tests/platform/mac-linux.sh rocky     # Rocky Linux 9.7 image (RHEL 9 family)
```

Both run the whole suite and the install E2E as a non-root user, in a podman-machine container (aarch64 on an Apple Silicon Mac), with the same
`--phase` / `--suite-file` options as `ubuntu.sh`; `--dry-run` prints the podman command. They check the macOS changes against Linux, nothing more.

- **The isolation check is skipped, loudly.** `check_isolation` (variable names, mount table, `/dev`, namespaces) was derived for rootless podman on
  RHEL and does not describe podman machine. The runner passes `--skip-isolation` with a fixed reason; the container prints it at the start and in the
  summary. `ubuntu.sh` and its checks are unchanged. The VM is the boundary here, and nothing verifies it. The container still gets no `-e`, no host
  `HOME`, no `~/.gitconfig` or `~/.ssh`, `--http-proxy=false`, and a read-only copy of the files `git ls-files -co --exclude-standard` lists.
- **`--tmpfs /run/secrets`**: podman machine mounts `/run/secrets/rhsm` into every container, and the suite's isolation test expects an empty directory.
- **Rocky** has its own script, `tests/platform/rocky-container.sh`, which sources `ubuntu-container.sh` and redefines only the prepare phase: dnf
  prerequisites (with `--allowerasing`, the image's `libcurl-minimal` conflicts with `libcurl-devel`), shellcheck 0.11.0 (SHA-256), pre-commit from pip
  (unpinned), git 2.56.0 built from the SHA-256 verified tarball into `/usr/local` next to the stock `/usr/bin/git`. The Rocky image is
  `docker.io/rockylinux/rockylinux:9.7@sha256:53f4c6dcb34e1403bd93207351f0af9a593610faeb7165cb8a037346765199b0` (manifest-list digest, looked up like the
  Ubuntu one: anonymous token from `auth.docker.io` for `repository:rockylinux/rockylinux:pull`, then `curl -I --max-time 30` on
  `registry-1.docker.io/v2/rockylinux/rockylinux/manifests/9.7` with the OCI index and Docker manifest-list `Accept` headers; it equals the DIGEST column of
  `podman images --digests`). Its repositories already serve 9.8, so the run mixes 9.7 base packages with current 9.x updates.
- **Not covered:** x86_64 (the `linux_x64` and `linux_amd64` rows of `tools.lock` are not exercised on an arm64 VM), and macOS itself, which
  `tests/run.sh` covers natively.

## Maintainer notes

- **Bumping the Ubuntu image digest.** `IMAGE` in `tests/platform/ubuntu.sh` is the manifest-list digest. Look it up without skopeo: an anonymous
  token from `auth.docker.io/token?service=registry.docker.io&scope=repository:library/ubuntu:pull`, then
  `curl -I -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'
  https://registry-1.docker.io/v2/library/ubuntu/manifests/24.04` and read `docker-content-digest`. It equals the DIGEST column of
  `podman images --digests` and one of the two `podman image inspect --format '{{.RepoDigests}}'` entries (the other is the platform manifest,
  not the list). Then `podman pull` the new reference, change `IMAGE` and the digest in this file (`test_the_docs_state_the_platform_test_trust_decisions`
  asserts it). The Rocky image (`ROCKY_IMAGE` in `tests/platform/mac-linux.sh`, `test_the_mac_runner_uses_the_pinned_images`) is bumped the same way.
- **Bumping the PPA key fingerprint.** On 24.04 `add-apt-repository` writes `/etc/apt/sources.list.d/git-core-ubuntu-ppa-noble.sources` with the
  key inlined in an indented `Signed-By:` block (blank armor lines as ` .`) and nothing under `trusted.gpg.d`. `ppa_key_fingerprints` feeds that
  armor to `gpg --show-keys --with-colons` in a scratch `GNUPGHOME` and prints field 10 of the first `fpr` record after each `pub`. To bump
  `PPA_PINNED_FPR` (in `tests/platform/ubuntu-container.sh`), read the new fingerprint the same way inside a container and compare it with
  Launchpad's page for the PPA before changing the constant.
- **shellcheck digests.** koalaman publishes no digests for the release tarballs; `SHELLCHECK_SHA256_X86_64` and `SHELLCHECK_SHA256_AARCH64` in
  `tests/platform/ubuntu-container.sh` were computed once from the downloads.
- **Deriving the mount table.** Podman's default masked and read-only paths are strings in its binary:
  `strings "$(command -v podman)" | grep -oE '/(proc|sys)/[A-Za-z0-9_./-]+'` (the Go strings run together, so read them by name). Probing a
  mask needs a path that exists: crun skips an absent masked path (no mount, rc 0), and `--tmpfs` on sysfs fails with `Permission denied`.
  Use an existing directory, for example `--security-opt mask=/sys/devices/virtual/misc`; the mask then shows as a `tmpfs` mount at exactly that
  mount point, which the check reports as stray until it is added to `ISOLATION_MOUNT_RULES` (`MOUNTPOINT=FSTYPE`, `*` = any fstype).
- **Entering the platform container from a shell.** `podman exec` needs the same `env -i` environment the script uses
  (`env -i HOME=<scratch> PATH XDG_RUNTIME_DIR XDG_DATA_HOME XDG_CONFIG_HOME LANG=C.UTF-8 podman exec ...`); a plain shell's podman falls back to
  cgroupfs and crun fails with `cgroup.procs: Permission denied` (rc 126). A container started with `sleep 7200` for iteration exits after two hours.
