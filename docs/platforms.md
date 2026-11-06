# Supported platforms

| Platform | Status |
|---|---|
| RHEL 9-compatible (x86_64) | Supported. RHEL 9-compatible (tested on Rocky Linux 9.7); there `/usr/local/bin/git` is built from source and `/usr/bin/git` 2.52 is left alone. |
| Ubuntu 24.04 LTS | Supported. The whole suite and an install E2E with real downloads run in a podman `ubuntu:24.04` container, as a non-root user, with mawk as the default awk: `tests/platform/ubuntu.sh`. `install` offers the git upgrade: see [Ubuntu and Debian (apt)](#ubuntu-and-debian-apt). |
| Ubuntu 22.04 LTS and Debian 13 | Offer tested against stand-ins (2.34.1 on 22.04 takes the PPA in its older `.list` form, Debian takes the source build) and, with real apt, in debootstrap chroots (22.04, 24.04, Debian 13, 20.04). Debian 13 also ran the `--phase upgrade` container E2E (source route, 21/0). **Not run:** an Ubuntu 22.04 container and an x86_64 container ([details](#ubuntu-and-debian-apt)). |
| macOS arm64 (tested on macOS 26.7.1) | Supported, with Homebrew: see [macOS (Homebrew)](#macos-homebrew). The whole suite and an install E2E in a scratch home run on a real Mac. |
| Windows x86_64 (tested on Windows Server 2019) | Supported with Git for Windows: see [Windows (Git for Windows)](#windows-git-for-windows). No weekly timer; the lifecycle test suites do not run there. |
| WSL (Ubuntu, Debian, RPM distributions) | Implemented, fixture-tested, and run for real on hosted WSL 1 and WSL 2: Ubuntu 22.04 and 24.04 on both, Rocky 9.8 and Fedora 44 on WSL 2 only (the vendor images cannot be imported on WSL 1), a typed yes and No, a `metadata` mount; see [WSL](#wsl-windows-subsystem-for-linux). WSL 1 on Windows Server 2019 blue-screened the maintainer's host twice in its own driver; the cause is not established. |
| macOS x86_64 (Intel) | Mapped (`darwin_amd64` / `darwin_x64` rows of `tools.lock`) but **not tested**. |
| Other Linux | Not tested. `install` names what is missing and falls back to generic advice when `/etc/os-release` is not Ubuntu or Debian. |

## RHEL, Rocky and Fedora (RPM)

`dnf` systems (the `rpm` class: `ID` or `ID_LIKE` names `rhel`, `fedora`, `centos`, `rocky` or `almalinux`) get a git upgrade from `install`.
Config hooks need git 2.54 or newer, and RHEL 9 ships 2.52. `git-secret-guard install` refuses an older git as before, and now **offers
the upgrade**; it never prompts without a terminal, and the default answer is No:

```bash
git-secret-guard install --upgrade-git        # consent up front (also the way to say yes with no terminal)
git-secret-guard install                      # in a terminal: prints the plan, asks "Upgrade git now with the plan above? [y/N]"
```

Every refusable check a git can run (jq, setsid, timeout, the global git config being writable, the state file, `core.hooksPath`, the CLI link, and with `--with-timer` the timer unit or launchd agent checks) runs
before the first privileged command, so a malformed state file or a read-only global config is refused with the machine untouched. A missing git, or one
older than 2.26 (it cannot run `git config --show-scope`), has its hooks-path and state checks right after the upgrade; a refusal there says what
the upgrade changed.

**Which route.**

| Situation | Route |
|---|---|
| `/usr/local/bin/git` is already 2.54 or newer but not first on `PATH` | `path-fix`: install prints the exact `export PATH="/usr/local/bin:$PATH"` line and refuses; no profile is edited. |
| An enabled repository offers `git-core` 2.54 or newer (Fedora) | `package`: `dnf install -y git-core`, or `dnf upgrade -y git-core` when an older git-core is installed (dnf 5 leaves an installed package alone on `install`). |
| Otherwise (RHEL 9, Rocky 9: the repositories carry 2.52) | `source`: the pinned source build below. |
| `dnf` is missing | no route; the usual refusal follows. |

**The repository query cannot hang or import a key.** It is `dnf --assumeno -q repoquery --latest-limit=1 --queryformat '%{version}\n' git-core`
(the same on dnf 4 on Rocky 9 and dnf 5 on Fedora 44), with stdin from `/dev/null`, bounded by a timeout (60 seconds, kept short in tests by
`GSG_GITUP_QUERY_TIMEOUT`), and `--assumeno` answers every prompt, a GPG key import included, with no. A third-party repository whose key is
not imported (the `acli` repository on the reference host stops at such a prompt) makes the query fail; install then asks each enabled
repository alone, **names the ones that fail**, imports nothing, and takes the source route. That per-repository retry has a total budget
(twice the query timeout); repositories beyond it are not tried and the plan says so.

**The privileged `dnf install -y` is different.** `-y` answers yes to every prompt, a repository GPG key import included (read from dnf's
`cli/output.py`, `CliKeyImport._confirm`, which returns true under `assumeyes`; not run). A key that is pending for a configured repository would
therefore be imported by that step, on the package route and on the source route (the dependency install), and the plan says so before asking.
Root runs the `dnf` found only in the fixed system path (`/usr/bin:/bin:/usr/sbin:/sbin`), never the one first on your `PATH`; it must be a root-owned file that
group and others cannot write, and the plan prints its full path (`as root: /usr/bin/dnf install -y ...`). `sudo` and `restorecon` are found the same way
(`restorecon` lives in `/usr/sbin`, which is why the sbin directories are in the list). The build keeps its own `PATH` of `/usr/bin:/bin`.

**The source route** follows the procedure that worked on the reference host, in this order:

1. Check the free space (about 570 MB in the build directory, 300 MB for `/usr/local`) before anything changes.
2. Download `git-<version>.tar.xz` and `git-manpages-<version>.tar.xz` from kernel.org and check both SHA-256 digests against `tools.lock`
   (`git` and `git-manpages`, platform `source`). A mismatch stops here with the machine untouched. (The story listed the dependency install
   first; the downloads come first because a tampered tarball then changes nothing.)
3. As root: `dnf install -y gcc make perl xz tar openssl-devel zlib-devel libcurl-devel expat-devel pcre2-devel perl-ExtUtils-MakeMaker`.
4. As the invoking user, in a `mktemp` directory, under `env -i PATH=/usr/bin:/bin` with a scratch `HOME` and `TMPDIR`:
   `make prefix=/usr/local NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 USE_LIBPCRE2=1 INSTALL_SYMLINKS=1 all`, then the same with `DESTDIR=<stage> install` (INSTALL_SYMLINKS=1 makes git install its siblings as symlinks, see [CI on real platforms](#rocky-vm-selinux-enforcing)); the man pages
   are unpacked into `<stage>/usr/local/share/man`. Homebrew's tools and libraries on the caller's `PATH` cannot reach the build (a Homebrew
   `PATH` made the linker fail on the reference host). `NO_RUST=1` is needed: without it git 2.56 wants cargo.
5. Every built binary is checked with `ldd`: a Homebrew path or a missing library refuses.
6. The manifest of staged files is compared with `/usr/local`: a path that exists there and is **not listed in an earlier `MANIFEST` of ours**
   (`/usr/local/share/doc/git-*-local/MANIFEST`) refuses and is named; nothing is overwritten. A build made by hand with a
   `MANIFEST` at that path (the reference host's `git-2.56.0-local`) counts as ours.
7. As root, under `umask 022` (the stage is built under it too, so a hardened `umask 027` cannot make root-owned directories unreadable to you or rewrite
   the mode of a shared one such as `share/man`): save the `MANIFEST` as `MANIFEST.partial`, run `cp -dR --remove-destination --preserve=timestamps,links
   <stage>/usr/local/. /usr/local/` (no `mode`: an existing directory keeps its mode), then rename `MANIFEST.partial` to `MANIFEST`. A copy that stops leaves the
   partial file; it counts as ours for the foreign-file check and as unfinished for the plan, so `install --upgrade-git` again finishes the copy (it is offered as a
   rebuild even when `git` itself already landed). Files an earlier MANIFEST listed and the new one does not are removed. A relative `TMPDIR` is refused.
8. The build directory is removed on every exit path, an interrupt included. The old git keeps working until `/usr/local/bin/git` is in place.

The package-owned git in `/usr/bin` is **not touched** by any of this: `rpm -q git-core` reports the same version and `rpm -V git-core`
reports nothing. `/usr/local/bin/git` comes first on `PATH` in a login shell, under `sudo` and in the systemd manager, **not** in cron
(`/etc/crontab` sets `PATH=/sbin:/bin:/usr/sbin:/usr/bin`): a script that calls `/usr/bin/git` by its full path is not scanned, and `install`
keeps warning about it and names `--take-over-system-git`. A Homebrew git is never a route on Linux (it needs Homebrew's glibc and loads
code from a tree the user owns).

**A newer pin.** When `tools.lock` pins a newer git than the build of ours that is first on `PATH`, `install` offers the rebuild (same
consent rules; declining or having no terminal continues). A git newer than the pin, or one that is not listed in a MANIFEST of ours, is left alone.

**The system git takeover (opt-in).** Where `/usr/bin/git` stays old, `install --take-over-system-git` (or the prompt `Take over ... [y/N]`, default
No, offered on every install that finds the old package git next to a qualifying build of ours) points it and its five siblings at
`/usr/local/bin`:

- Refused unless `/usr/bin/git` is owned by `git-core` and older than 2.54, `/usr/local/bin/git` and its siblings exist, are listed in a **finished**
  MANIFEST of ours (a `MANIFEST.partial` does not count), are owned by root and not writable by group or others, every file below
  `libexec/git-core` has the same owner and write bits and no symlink there leaves the prefix, and `ldd` of every program shows no Homebrew path, no missing
  library and no library outside `/lib`, `/lib64`, `/usr/lib`, `/usr/lib64`, `/usr/local/lib` and the prefix's own `lib` directories.
- Order (a safety rule): add the `excludepkgs` entry to `/etc/dnf/dnf.conf` behind a marker comment (nothing is written when a marker is already there, and
  the file is replaced by a rename that keeps its mode); copy the originals with `cp -a` (modes and SELinux labels) to
  `orig.new` beside `/var/lib/git-secret-guard/system-git/orig`, check each copy, write `record.new`, and only then rename them into place; for each path
  that is not already our link make a temporary symlink beside it and `mv -T` it over the path (there is no moment without a git), then `restorecon`; verify that `/usr/bin/git --version`
  is 2.54 or newer, that a commit through it reaches a hook in a scratch repository and that `git-upload-pack` runs. Three of the six RPM files are relative
  symlinks to `git` (`git-receive-pack`, `git-upload-archive`, `git-upload-pack`); they are saved as links and compared by link target, never followed.
  **The saved originals are never replaced as long as any `/usr/bin` file is a link of ours:** a takeover that finds such links with a record it
  cannot trust refuses and changes nothing. Any failure, and an INT, TERM or HUP, runs the same undo as `restore-system-git` (below), hash checked.
- **The six files** are what `rpm -ql git-core` lists in `/usr/bin` on Rocky 9.7 and on Fedora 44: `git`, `git-receive-pack`, `git-shell`,
  `git-upload-archive`, `git-upload-pack` and `scalar`. `/usr/libexec/git-core/git` is an RPM symlink to `../../bin/git`, so it follows.
- **`excludepkgs` must name every installed package built from the same source RPM** (`git git-core git-core-doc perl-Git`, read from
  `rpm -qa --qf '%{NAME} %{SOURCERPM}\n'`). Probed against a local repository holding newer packages: `excludepkgs=git-core` alone, or `git git-core`,
  makes `dnf update` fail on dnf 4 ("package git-core-doc requires git-core = ..., filtered out by exclude filtering") and skip the broken
  packages on dnf 5; with all four, the rest of the update resolves. dnf 5 reads the same `/etc/dnf/dnf.conf`. An `excludepkgs` line that already
  exists is extended, and `restore-system-git` puts the original line back.
- **The cost, printed before asking:** dnf stops updating git, so git updates arrive only through a pin bump in `tools.lock` and `install --upgrade-git`;
  `rpm -V` reports the files as changed; a broken build in `/usr/local` breaks everything that uses git, `gh` and `glab` included. The RPM stays installed
  (other packages need it).
- **Undo:** `git-secret-guard restore-system-git` acts on what is on disk (the record, the `dnf.conf` marker, the links). It puts back every recorded file that is
  our link or missing (hash checked), accepts a file that is neither ours nor the saved original only when `rpm -qf` names `git-core` as its owner and
  `rpm -V git-core` does not list it (otherwise it says so and the backup stays), removes the `dnf.conf` entry from the marker alone (a package you added
  to the line stays, and an unrelated line below the marker is kept), and removes the backup directory last, then the empty `/var/lib/git-secret-guard` (a second run removes one a by-hand restore left behind). A Ctrl-C or SIGTERM during the restore ends it with
  the state of the machine and the command to run next (`restore-system-git` again; the backup is removed last, so a repeat is safe), and no temporary directory is left
  behind. The upgrade plan and the takeover plan list every privileged command by its full path, `mkdir` included, and those are the files that run. It needs no
  network and no dnf, and says `nothing to restore` on a second run. `uninstall` stops in every takeover state except none (active, partial, undone, broken) and names
  `restore-system-git` and `uninstall --keep-system-git` (which prints the by-hand commands). When the record cannot be read, `restore-system-git` and
  `install --take-over-system-git` refuse and print those commands, built from the saved originals in `orig/` (or `dnf reinstall` when the originals are gone). `active`
  needs the `excludepkgs` line itself below the marker, not only the marker comment; a rerun of `install --take-over-system-git` puts a deleted line back.
  `status` and `doctor` report an active takeover and a
  leftover one as a problem, with the fix: "the takeover is half done" (`/usr/bin/git` is still our link, so commits are scanned; finish with `install --take-over-system-git`
  or undo with `restore-system-git`) and "the takeover is partly undone" (`/usr/bin/git` is not our link, so commits through it are no longer scanned).
- **A rebuild under an active takeover is refused**, before any privileged command: `cp` would replace the files the links point at in place, and an
  interruption there would break `/usr/bin/git`. The way out is `restore-system-git`, `install --upgrade-git`, then the takeover again.
- A takeover is recorded on the machine only by its backup directory and its symlinks; no key was added to the install state.

**Pins.** `tools.lock` holds `git 2.56.0 source` and `git-manpages 2.56.0 source`. The digests came from kernel.org's `sha256sums.asc` over HTTPS
from two hosts (`www.kernel.org`, `mirrors.edge.kernel.org`) on 2026-11-04; **the GPG signature of that file was not verified** (the key that
signs it, the one kernel.org lists on its signing-keys page, has no user ID on keys.openpgp.org). To bump: fetch both files from both hosts, compare the digests, change the two
rows together (a lock whose two versions differ is refused), and run `tests/platform/rpm.sh rocky`.

**The container runs (Linux host).** `tests/platform/rpm.sh rocky|fedora [--dry-run]` starts a podman container the way `tests/platform/ubuntu.sh`
does (private copy of the tracked files, `env -i`, `CONTAINERS_CONF` with an empty `hooks_dir`, an empty `mounts.conf`, the host namespace ids as arguments,
`--init`, a kill-after timeout, no proxy variables) and runs the real E2E as a non-root user with sudo: `tests/platform/rpm-upgrade-e2e.sh`.

- Rocky 9.7 (`docker.io/rockylinux/rockylinux:9.7@sha256:53f4c6dcb34e1403bd93207351f0af9a593610faeb7165cb8a037346765199b0`, the pin of `mac-linux.sh`):
  the stock RPM git 2.52, the refusal without the flag, `install --upgrade-git` with a real build, a blocked fake key, a rerun, the takeover offer and
  `--take-over-system-git`, a blocked key and `git-upload-pack` through `/usr/bin`, `dnf update` against a local repository holding git 2.99.0
  packages (control run first), `status`, `uninstall`, `restore-system-git`, `rpm -V` clean, and a real rollback (the sixth rename fails after five
  links were swapped).
- Fedora 44 (`registry.fedoraproject.org/fedora:44@sha256:4688bc8003a1a6a7815e5f9d1f1b5c6bc9cafa582654af7cec61435d91655e3b`): the image has no git;
  `install --upgrade-git` takes the package route (dnf 5), a blocked fake key, a rerun, and the takeover has nothing to do.
  To bump the digest: `curl -I -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'
  https://registry.fedoraproject.org/v2/fedora/manifests/44` and read `docker-content-digest` (it equals the DIGEST column of `podman images --digests`).
- **`sudo` and Ctrl-C.** With `use_pty` (on by default since sudo 1.9.14) `sudo` runs the command on its own pseudo-terminal. A Ctrl-C
  typed during a `sudo` call can then be absorbed there and never reach bash, so the interrupt traps of `install` and `restore-system-git` do not fire; the
  privileged command finishes or fails by itself and the run goes on. Every step can be repeated (backup last, partial states are
  reported by `status` and `doctor`). The test suite sends its signals to the process group of the CLI and not through a terminal.
- **Not run on the reference host:** the takeover and the Rocky E2E. SELinux (labels, `restorecon`, `sshd` serving `git-upload-pack` through the taken-over path) is covered by the enforcing Rocky VM job, see [CI on real platforms](#rocky-vm-selinux-enforcing).

## Ubuntu and Debian (apt)

`apt` systems (the `ubuntu` class: `ID` or `ID_LIKE` names `ubuntu`, so Linux Mint and other derivatives follow Ubuntu's rules, except that Mint's `add-apt-repository` has no `-n` (read from the mintsources source, not run on Mint), which sends it to the source build; the `debian` class: names `debian`) get the same offer as the
RPM systems. Ubuntu 22.04 ships git 2.34.1 and 24.04 ships 2.43, and both ignore config-based hooks without any message. `git-secret-guard install` finishes its
other checks first, prints the plan and **offers the upgrade**; it never prompts without a terminal and the default answer is No:

```bash
git-secret-guard install --upgrade-git        # consent up front (also the way to say yes with no terminal)
git-secret-guard install                      # in a terminal: prints the plan, asks "Upgrade git now with the plan above? [y/N]"
```

Without the flag and without a terminal `install` refuses, names `--upgrade-git` and changes nothing. The consent rules, the checks before the first privileged command, the
"what changed" text of a later refusal and the rerun rule are the ones of [the RPM section](#rhel-rocky-and-fedora-rpm); only the route differs.

**Which route.** The route comes from what apt can deliver, never from the release number, so a new release needs no code change:

| Situation | Route |
|---|---|
| `/usr/local/bin/git` is already 2.54 or newer but not first on `PATH` | `path-fix`, as on RPM systems. |
| apt's own candidate for `git` is 2.54 or newer | `package`: `apt-get update`, then `apt-get install -y --no-install-recommends git`; no PPA is added. The plan and the report name where the candidate comes from (its first source in `apt-cache policy`). |
| Ubuntu class, otherwise | `ppa`: the git-core PPA, counted only if its candidate is 2.54 or newer after the key check and `apt-get update`; **otherwise the pinned source build follows**. |
| Debian class, otherwise | `source`: the pinned source build (Debian has no PPA). |
| `apt-get`, `apt-cache` or `env` is missing from the system path | no route; the usual refusal follows. |

What the PPA carried on 2026-11-04 (`dists/<release>/main/binary-amd64/Packages.gz`) and the route that gives today: 20.04 focal 2.50.1 (source: a real focal run is refused at the floor, because the PPA's git stays below 2.54; its add-apt-repository 0.99.9.12 writes the key as `git-core_ubuntu_ppa.gpg` with underscores, which the key check reads as well), 22.04 jammy 2.56.0 (stock 2.34.1, measured; security updates stay on it), 24.04 noble 2.56.0 (stock 2.43), 25.10 questing 2.54.0 (at the floor),
26.04 resolute, 26.10 stonking and 27.04 tenacious 2.56.0 (package or PPA). Supported: **22.04 and later**; earlier releases follow the same rule but are not tested. After a
package route git updates arrive through the normal `apt upgrade`, and nothing is scheduled by `install`. WSL takes this same rule (it runs real Ubuntu packages): see [WSL](#wsl-windows-subsystem-for-linux).

**The query cannot hang or change anything.** The candidate is read with `apt-cache policy git` (no `apt-get update`, no lock, nothing written), stdin from `/dev/null`, `LC_ALL=C`
(the label is translated otherwise), bounded by the same timeout as the RPM query (60 seconds, `GSG_GITUP_QUERY_TIMEOUT` in tests). A version such as `1:2.34.1-1ubuntu1.11` or
`1:2.56.0-0ppa1~ubuntu22.04.1` is reduced to its upstream release (epoch and packaging suffix dropped); a tilde right after the number (`2.54.0~rc1`) is a pre-release and does not
pass the floor. The output is read in a loop with `break`, never through `sed ...q` under `pipefail` (the writer gets SIGPIPE, which once turned a good PPA install into a silent
source build).

**The PPA route, in this order (the order is a security rule).**

0. **The PPA files already on the machine are looked at first**, before the candidate chooses a route (a wrong key with a 2.56 candidate must not take the package route). Files that pass the key check below are kept and used as they are: no `add-apt-repository`, nothing removed if the route fails. A file is no enabled PPA when it holds only a key left by `add-apt-repository -r`, an entry with `Enabled: no`, or commented-out lines. Apt reads the false words `no false without off disable 0` in any case. A leftover key or a disabled entry does not hide the distribution's own good package: when apt's candidate is new enough and not offered by a PPA, the leftover goes aside and the package route follows. Files that are no enabled PPA, or that carry another key, are moved to a root-owned `/var/lib/git-secret-guard/ppa-aside-<UTC>/` (never deleted; the output names the place and prints the `mv -n` commands that put each file back; `install` and `uninstall` keep that directory) and apt is refreshed before the fresh route starts. The rebuild route (a build of ours older than the pin) runs the same preflight and lists the same commands. The scan reads the URL on any non-comment line, so `URIs:https://...` and a folded `URIs:` value are found too. An entry for the PPA under any other file name (found by content in `sources.list`, `*.list` and `*.sources`) cannot be checked and stops the route with the file named.
1. As root, only when `add-apt-repository` or `gpg` is missing: `apt-get update`, then `apt-get install -y --no-install-recommends software-properties-common gnupg`. An `add-apt-repository` whose `--help` does not name `--no-update` (Linux Mint's) is not used: the source build follows.
2. `add-apt-repository -y -n ppa:git-core/ppa`. `-n` runs no `apt-get update`, so no apt run has seen the new key yet. The real tool keeps an entry that exists and imports the key into the existing keyring, so its result can hold more keys than the pin.
The layouts add-apt-repository wrote on real systems (E2E of 2026-11-05, WSL 1 chroots):

| Release | software-properties | Source file | Key |
|---|---|---|---|
| 20.04 focal | 0.99.9.12 | `git-core-ubuntu-ppa-focal.list` with `http://ppa.launchpad.net/...` | `trusted.gpg.d/git-core_ubuntu_ppa.gpg` (underscores) |
| 22.04 jammy | 0.99.22.9 and 0.99.22.3 | `git-core-ubuntu-ppa-jammy.list` with `https://ppa.launchpadcontent.net/...` | `trusted.gpg.d/git-core-ubuntu-ppa.gpg`, plus a `.gpg~` backup left by gpg |
| 24.04 noble | 0.99.49.4 | `git-core-ubuntu-ppa-noble.sources` (34 lines) | embedded in `Signed-By:`, nothing in `trusted.gpg.d` |

Because the key file name differs between releases, the check does not rely on a name alone: it reads both known names, and it lists `sources.list.d` and `trusted.gpg.d` before and after `add-apt-repository`. A new file is the PPA's, and so removable on failure, only when that is proved: a known name, a sources file whose content names the PPA, or a key holding exactly the pin. Any other new file (a neighbour process's vendor source or key) is named, left alone and never deleted. It does not fail a PPA whose own key passed; but when the route fails and a new key remains that cannot be judged, the upgrade stops (no source build, no root apt install) and names it, because apt trusts that key for every repository. The "removed" sentence lists the files that were removed and nothing else.

3. **Check the key fingerprint against the pin `F911AB184317630C59970973E363C90F8F1B6217`** (Launchpad's `signing_key_fingerprint` for the PPA), in the form this release wrote.
   Ubuntu 24.04 writes `git-core-ubuntu-ppa-noble.sources` with the key embedded in the `Signed-By:` field; Ubuntu 22.04 (software-properties 0.99.22) writes
   `git-core-ubuntu-ppa-jammy.list` and puts the key in `/etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg` (read from `softwareproperties/shortcuthandler.py`; the container run for
   22.04 is what proves it for real). Both forms are read by `gpg --show-keys --with-colons` in a scratch `GNUPGHOME`; `trusted.gpg.d/git-core-ubuntu-ppa.gpg` is read whenever it exists, also next to a `.sources` file. Apt trusts every key in it for every repository, so a key file that holds the pin plus any other key, is over 1 MiB or is
   missing for a `.list` file is not the pin; a gpg that exits non-zero is a failure, whatever it printed.
4. `apt-get update`.
5. **The PPA candidate must be 2.54 or newer** (a PPA can exist and still lag, as 20.04's does); below the floor counts as a failure.
6. `apt-get install -y --no-install-recommends git`.

Any failure from step 2 on **removes only what this run added** (the `.sources` and `.list` files and `/etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg`, which apt trusts for every repository; a PPA that was already there and verified stays),
**refreshes apt** when lists or files were touched, and only then follows the pinned source build, whose root `apt-get install` therefore never runs with an unchecked PPA enabled. The output says why. Removal is proved by content, not by name: an entry of the PPA left in any sources file, a `rm` that exits 0 and leaves a file, or a failed removal stops the install (no source build, no root apt install) and the message says the PPA may still be enabled and what to remove by hand. A refresh that fails after a good removal also stops it, with its own text (the PPA is not enabled, apt just could not refresh). An interrupt (Ctrl-C) between step 2 and a passed key check removes what this run added and says why it stopped; signals are ignored during that clean-up.

**After a successful install the PPA stays enabled**, so `apt upgrade` keeps git current; `uninstall` leaves the PPA, a `ppa-aside-*` directory and git as they are (uninstall keeps all of them). With neither root nor `sudo`, `install` does not list commands for you to type: the PPA route depends on checks between its commands (the key, the version floor), so it tells you to run `install --upgrade-git` as root. The package route and the Debian source route still list theirs, unless an old PPA has to be moved aside first (then the same message applies).

**Every apt command is non-interactive, also under `sudo`.** `sudo` drops the caller's environment, so each is run as
`env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a APT_LISTCHANGES_FRONTEND=none <apt-get> -o DPkg::Lock::Timeout=120 ...` with `-y`; the plan prints exactly those words, with the full
paths of `env`, `apt-get` and `add-apt-repository` found only in the fixed system path (root-owned, not writable by group or others), and marks the commands that run only in some cases
(`[only when ...]`), including the whole source build as the fallback of the PPA route.

**The source route on Debian and as the Ubuntu fallback** is the shared one of [the RPM section](#rhel-rocky-and-fedora-rpm) (verified downloads first, build as your user under `env -i`, `MANIFEST`,
copy into `/usr/local`). Its dependencies come from `apt-get update` followed by `apt-get install -y --no-install-recommends build-essential libcurl4-openssl-dev libssl-dev libexpat1-dev zlib1g-dev perl libpcre2-dev xz-utils tar`
and the flags are `NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 USE_LIBPCRE2=1` (the same as RPM; the container build of Debian 13 with `libpcre2-dev` was not run by the author). The source route leaves the
distribution's `/usr/bin/git` in place, so `install` still warns about it; `--take-over-system-git` is refused on these classes.

The container runs: `tests/platform/ubuntu.sh --phase upgrade` (24.04, `.sources` form), `tests/platform/ubuntu.sh --os ubuntu-22.04 --phase upgrade` (22.04, `.list` form) and
`tests/platform/ubuntu.sh --os debian-13 --phase upgrade` (source route) start from the stock git, run `install --upgrade-git` as a non-root user with real apt, the real PPA and real downloads,
check the file form of the PPA, a blocked fake key, a rerun and uninstall.

Ran on 2026-11-06 (arm64 Mac, podman, branch head 29763a8). `mac-linux.sh` takes `ubuntu|rocky` only, has no `--os` and always starts the 24.04 image:
- `ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852`, via `mac-linux.sh ubuntu --phase upgrade`: E2E 27 passed, 0 failed, PPA route (2.43.0 to 2.56.0 from the PPA package).
- `debian:13@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6` (the `ubuntu.sh` pin), via the same podman command `mac-linux.sh` builds with that image and `ubuntu-container.sh --expect-os debian:13 --skip-isolation <reason> --phase upgrade`: E2E 21 passed, 0 failed, source route (2.47.3 to `/usr/local` 2.56.0).

**Not run:** the Ubuntu 22.04 container (`--os` cannot be forwarded through `mac-linux.sh`) and any x86_64 container. Earlier real-apt chroot runs (22.04, 24.04, Debian 13, 20.04) covered the file forms.

### By hand

If you prefer to do it yourself, or `install` cannot (no sudo, no apt), get a git >= 2.54 first:

```bash
sudo apt install jq curl ca-certificates          # setsid (util-linux) and timeout (coreutils) are already there
sudo add-apt-repository ppa:git-core/ppa && sudo apt install git     # add-apt-repository: sudo apt install software-properties-common
git --version                                     # must say 2.54 or newer, first on PATH
```

The PPA (`ppa:git-core/ppa`) carried git 2.56.0 (`1:2.56.0-0ppa1~ubuntu24.04.2`) when this was tested. Debian has no PPA, and a PPA
may lag behind: then build git from source. The commands are chained with `&&`, so nothing is unpacked or built
unless the download succeeded and its SHA-256 matches:

```bash
sudo apt install build-essential libcurl4-openssl-dev libssl-dev libexpat1-dev zlib1g-dev perl
curl -fsSLO https://www.kernel.org/pub/software/scm/git/git-2.56.0.tar.xz \
  && echo '26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3  git-2.56.0.tar.xz' | sha256sum -c - \
  && tar -xf git-2.56.0.tar.xz && cd git-2.56.0 \
  && make -j"$(nproc)" prefix=/usr/local NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 all \
  && sudo make prefix=/usr/local NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 install     # /usr/local/bin must come before /usr/bin on PATH
```

Then `git clone <this repository> && cd git-secret-guard && bin/git-secret-guard install` works as on RHEL. `install` names the missing
prerequisite with its fix, always before it changes anything: git (the offer above on Ubuntu, Debian and their derivatives, with the manual PPA command as the second line, generic text elsewhere), `jq` (`sudo apt install jq`), `setsid` (`util-linux`), `timeout` (`coreutils`), `curl`, and
`systemctl` for `--with-timer` (`systemd`; on macOS `launchctl` instead, which ships with the system). It checks all of them first and names **every** missing one with its fix in a single refusal
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
  the version probes need a bounded `timeout`; a failed download there is a refusal that names what brew installed. An old git you
  do not agree to upgrade (see the next item), an unsupported CPU, a `--with-timer` without `launchctl`, a set `core.hooksPath`, a lock without a row for this platform and the other refusals therefore install
  nothing beyond the bootstrap's `bash`.
- **An old git: `install --upgrade-git`.** A git older than 2.54 (Apple Git older than 2.54, or none) is offered an upgrade through Homebrew, after
  the other refusable checks, with the plan printed first and the answer defaulting to No (no terminal: the flag is the only yes). Routes: a Homebrew git
  (`$(brew --prefix)/bin/git`) that is >= 2.54 but not first on `PATH` gets a refusal with the exact `export PATH="<prefix>/bin:$PATH"` line (no shell
  profile is ever edited); an older Homebrew git runs `brew upgrade git`; none runs `brew install git`. `brew` runs as your user, never as root and
  never through `sudo`; Homebrew only has the latest git, so nothing is pinned. This `brew install git` is its own call, before the one for
  `coreutils`, `util-linux` and `jq` (a later refusal names both: `the only change made was the git upgrade of this run (Homebrew installed git at <prefix>/bin/git)`). **`/usr/bin/git` cannot be replaced**
  (SIP), so `--take-over-system-git` says so and install goes on. After the upgrade, GUI clients and tools that start with `PATH=/usr/bin:/bin` still use the old Apple Git and
  are not scanned (the warning says so); the LaunchAgent's `PATH` starts with the Homebrew git's directory.
- **The CLI needs the GNU directory.** On macOS every command except `install`, `version` and `help` refuses, naming `brew install coreutils`,
  when no GNU directory is known (the installed copy's settings have no `GNUBIN_DIR`, or a checkout finds no `brew` on `PATH`). A global-config
  `include` whose target does not exist (a dangling symlink) is skipped, as git does; one that exists but cannot be resolved is refused.
- **What a refusal says after a brew install.** Once any `brew install` ran in the invocation, no message claims that nothing was changed;
  it names what changed (`the only change made was the Homebrew install of bash in this run`). A failing `brew install` ends the run with brew's
  own message and says Homebrew may have installed part of the list before failing (see `brew list`).
- **The scanners are never installed with brew.** trufflehog and betterleaks come from the SHA-256-pinned darwin rows of `tools.lock`
  through the same download, verify, extract and `--version` path as on Linux, into `~/.local/bin`. Brew only has the latest release
  (trufflehog 3.99.7 against the pin 3.99.2 when this was written), and the documented behaviours are verified per pinned version.
- **Absolute paths, no `PATH` order.** The settings file records `BASH_BIN` (the Homebrew bash), `GNUBIN_DIR` (the GNU coreutils
  directory), `TIMEOUT_BIN` (`gnubin/timeout`), `SETSID_BIN` and `JQ_BIN`. The hook puts `GNUBIN_DIR` first on its own `PATH`
  (a non-empty value must be an absolute, existing directory or the hook blocks; an empty one adds nothing) and the CLI does the same (it checks only
  that the directory exists), so no BSD tool answers where a GNU flag is used.
- **The hook never runs unscanned under bash 3.2.** The configured command is `'<BASH_BIN>' '<share>/hooks/secret-scan'`, so a GUI git
  client that starts with `/usr/bin:/bin` (and `/bin/bash` 3.2 first) still runs the hook under the recorded bash. A hook started any
  other way under bash older than 4.4 blocks with `nothing was scanned` before it reads another line. The CLI behaves the same: started
  by bash 3.2 it re-executes under the Homebrew bash (`install` first runs `brew install bash` alone when none exists), or refuses.
  An installed copy started that way with no `brew` on `PATH` (`env -i PATH=/usr/bin:/bin /bin/bash ~/.local/bin/git-secret-guard status`)
  reads `BASH_BIN` from its own `settings` as data (never sourced under 3.2; only a plain absolute path of letters, digits and
  `._/+@%-` is believed, so a value that needs shell quoting is ignored), checks that it is executable and reports bash 4.4 or
  newer, and re-executes under it once. If that fails it refuses with a message that names the command, the unusable `BASH_BIN`
  and what to do (put the Homebrew bash first on `PATH`, or `brew install bash`), never the install wording.
- **`install --with-timer` installs a LaunchAgent** on macOS: `~/Library/LaunchAgents/com.lightspeeddms.git-secret-guard.doctor.plist`,
  loaded with `launchctl bootstrap gui/<uid>`, running doctor weekly through the recorded bash with its output in
  `doctor.log` in the state directory; `launchctl` is recorded as `LAUNCHCTL_BIN` (details in
  [the launchd section of the doctor chapter](doctor.md#the-weekly-timer-on-macos-launchd)). `doctor` checks `BASH_BIN`
  (executable, bash 4.4 or newer) and, when a timer is recorded, `LAUNCHCTL_BIN`, like the other recorded tools;
  `status` checks neither.
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

## Windows (Git for Windows)

Install [Git for Windows](https://git-scm.com/download/win), then, from PowerShell or cmd:

```powershell
git clone <this repository>
cd git-secret-guard
bin\git-secret-guard.cmd install    # downloads what is missing
git-secret-guard status             # in a new terminal, once %USERPROFILE%\.local\bin is on PATH
```

Git Bash works the same way with `bin/git-secret-guard install`. Commits are scanned from any shell and from GUI clients,
because the hook lives in the global git config.

- **Prerequisites.** Git for Windows with git 2.54 or newer (an older one is upgraded with `install --upgrade-git`, see below) on x86_64. `taskkill`,
  `timeout`, `curl`, `sha256sum` and the System32 `tar.exe` come with Windows or Git for Windows. `~/.local/bin` should be
  on `PATH` for the `git-secret-guard` command.
- **jq is handled by `install`.** With no `jq` on `PATH`, `install` downloads the pinned `jq.exe` from the jqlang release,
  checks its SHA-256 against `tools.lock`, and places it in `~/.local/bin` beside the scanners. No package manager is
  needed (the Windows Server 2019 test host has no winget). It follows the scanner rules: all downloads are verified before anything
  changes, a rerun keeps it, a pin bump replaces it, and `uninstall --remove-tools` removes it. A `jq` you already have on
  `PATH` is used as it is and never recorded as ours.
- **`git` in PowerShell.** The Git for Windows installer normally puts `git` on `PATH`. If `git` is not found there, re-run
  it and choose "Git from the command line", or add `C:\Program Files\Git\cmd` to `PATH`. `git-secret-guard.cmd` finds Git
  for Windows either way, next to `git.exe` or in its default locations, and never uses the WSL `bash.exe` in `System32`.
- **File names.** The scanners and jq keep their `.exe` names. `~/.local/bin/git-secret-guard` is a small wrapper script,
  not a symlink, and `git-secret-guard.cmd` next to it serves PowerShell and cmd. `uninstall` removes both. `JQ_BIN` names a wrapper in the share dir adding `-b`,
  because a native `jq.exe` otherwise writes CRLF.
- **Weekly doctor.** `--with-timer` needs systemd or launchd. Use [Task Scheduler](doctor.md#a-weekly-run-on-windows-task-scheduler).
- **Line endings.** A checkout keeps LF whatever `core.autocrlf` says (`.gitattributes`), so the bash files run as they
  are. The warning `LF will be replaced by CRLF` in your own repositories comes from Git for Windows' default config and
  has nothing to do with the scan.
- **UTF-16.** Windows PowerShell 5.1 can write UTF-16 with `>` and `Out-File`. Git treats such a file as binary, so it is
  [not scanned](scan.md#limits). Use `Set-Content -Encoding utf8`, or PowerShell 7.
- **Stopping a scan.** There are no process groups: on an interrupt or a timeout the hook finds every process below each
  scanner and stops them with `taskkill /T /F`, without a grace period, then removes its work dir.
- **What was checked by hand.** On Windows Server 2019 with git 2.56.0.windows.4, from a machine with no jq: install from Git
  Bash and from PowerShell, a rerun, `status`, `doctor` (including a worktree and a repository with the hook disabled),
  `doctor --recheck`, the coverage reminder, `--replace-hooks-path` and the restore on uninstall, `uninstall --remove-tools`
  from Git Bash and from PowerShell, a foreign scanner moved aside and restored, and a `jq` of the user's left alone. In
  commits: a clean one passes and a leak is blocked from Git Bash and PowerShell, findings from both scanners,
  `.secret-scan-ignore`, `--no-verify` and a broken probe repository blocking with `nothing was scanned` from Git Bash.

### Upgrading Git for Windows

When the git on `PATH` is older than 2.54, `install` offers to upgrade Git for Windows (story 30, the `windows` module in `lib/gitup_windows.sh`). The consent rules are those of
[the other platforms](install.md#upgrading-an-old-git---upgrade-git-and---take-over-system-git): a prompt in a terminal (default No), or `--upgrade-git`; with no terminal and no flag
`install` refuses, names `--upgrade-git` and changes nothing.

```powershell
bin\git-secret-guard.cmd install --upgrade-git
```

- **Route.** winget when it is on `PATH`, otherwise the pinned installer. The Windows Server 2019 test host has no winget, so it took the installer route. The installer is `Git-2.56.0.4-64-bit.exe` of the
  release `v2.56.0.windows.4` of git-for-windows/git, pinned in `tools.lock` (row `git-for-windows`, not a scanner) with its SHA-256. `install` downloads it over HTTPS, checks the
  digest and removes a file that differs. The winget route was run for real on a windows-2025 runner (see [CI on real platforms](#ci-on-real-platforms)): its `--scope`, its own hash check and the kept scope worked there; the Windows Server 2019 host has none. The runner passes
  `--scope machine` or `--scope user` as planned and the plan says the rest is not tested.
- **Why the hand-off.** The upgrade replaces the `bash.exe` that `install` runs in, so bash only decides, plans, downloads and verifies. `lib/gitup_windows.sh` writes a hand-off file
  (`route`, `scope`, `version`, installer path; no digest) into a directory below the profile (NTFS ignores chmod, so the profile ACL is what keeps it private; a state directory outside the profile has no such protection) and returns the module status "finish outside this process": `install` stops with exit 3.
  `bin/gsg-gitup.ps1` then runs the upgrade from Windows PowerShell, outside bash:
  - from `git-secret-guard.cmd` (checkout or the one `install` wrote to `~/.local/bin`) it runs by itself, and then the same command runs once more with its own arguments, with
    `GSG_GIT_UPGRADED=1` so a refusal there does not claim that nothing was changed. The `.cmd` names the hand-off place, `%LocalAppData%\git-secret-guard\git-upgrade\handoff.txt`,
    through `GSG_HANDOFF` (accepted only below `LOCALAPPDATA`, without regard to case, and only as `git-upgrade\handoff.txt`); it deletes a stale hand-off first, and a failing runner
    stops there with the runner's exit code;
  - from Git Bash (no `.cmd` parent) `install` stops and prints the exact commands, with the flags of the run that stopped: close every Git Bash window, run
    `powershell -NoProfile -ExecutionPolicy Bypass -File "...\gsg-gitup.ps1" "...\handoff.txt"` in PowerShell or cmd, then `git-secret-guard.cmd install ...` in a new terminal. The hand-off
    is then in the state directory (the same name and link checks apply to that route).
- **What the runner checks before it starts the installer.** The SHA-256 must equal the pin in `tools.lock` (read by the runner itself from the lock beside `bin`, never from the hand-off or the environment),
  the Authenticode signature must be `Valid` and by the signer the lock names (a `# gsg-signer` line next to the digest row: `CN=Johannes Schindelin, O=Johannes Schindelin, L=Bruehl, C=DE`; a subject pin,
  so a renewed certificate with another subject needs a new pin), and neither the installer file nor the two directories install made for it (`git-secret-guard` and `git-upgrade`) may be a junction or
  symbolic link; bash checks the same two directories, and a link above them (a profile moved to another disk) is accepted by both. A file with another digest is deleted and never started;
  a link or a signature refusal keeps the file, because it matched its pin, and says so. No environment variable steers its checks (the lock, the signer and the status are not taken from the environment; only winget, on the winget route, is found through `PATH`). A signer other than the pin, with a valid signature, gets its own refusal text (the pin does not describe the file), and every comparison of the pin is case-sensitive. The file is opened without write and delete sharing before these checks
  and stays open until the installer has ended: a test holds the runner between the checks and the start and fails to write, delete or rename the file, its directory and the directory above it.
- **What is not defended.** Code running as the same user. It can edit `bin/gsg-gitup.ps1`, `tools.lock` or the hand-off, and so is not stopped by any of the above. The checks defend against
  a changed or substituted installer file and against a hand-off that vouches for itself, not against a compromised account.
- **What the signature status means here.** `Valid` does not prove that the signing certificate is unrevoked: Windows checks revocation from its cache only in this call (probed with a CAPI2 trace:
  cache-only retrieval, revocation result "offline", status still `Valid`). It also rests on the timestamp countersignature, because the signing certificate of 2.56.0.4 expired on 2026-10-27.
  The chain ends in a Microsoft root of 2020; a stale host without it may report `UnknownError`, and the runner then refuses with Windows' own message and tells the user to install Git for Windows by hand
  (a rerun cannot help). That case was not reproduced. A test checks the real asset against the production pins without starting it (`test_real_the_pinned_installer_...`; it skips with a reason when
  the pinned file named by the lock row is not in the tools cache; `tests/run.sh` fetches it on Windows when it is missing, and a fetch that fails prints a warning and the test skips, except that with `CI` set the test fails instead of skipping). It can never start the installer: it checks before running that the runner has no start path besides the two `Start-Process` calls, and the wrapper fails closed for any mode but the listed ones.
- **The hand-off is used once.** The runner deletes it before it starts anything, and deletes the installer after a successful run, so an old hand-off cannot downgrade git later.
  `uninstall` removes both leftovers from both places.
- **Scope is kept, never switched.** The plan reads the Inno Setup record `HKLM` or `HKCU` `SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Git_is1` whose `Inno Setup: App Path` contains
  the git on `PATH`, and says `machine-wide` or `per-user`. Another install (portable, scoop, MinGit, a git elsewhere on `PATH`) is refused, not upgraded. Machine-wide needs
  administrator rights: from a prompt that is not elevated the runner starts the installer with the `RunAs` verb (tested through a wrapper and with the exit code coming back, on an elevated
  prompt where no dialog appears). The exit code 1223 that the cmdlet reports for a declined dialog is exit 11, "nothing was changed", with the command to run again; any other start failure is
  exit 15 and is not called a decline. **The real dialog was never declined by a person.** A per-user install is never started from an elevated prompt (exit 14, nothing ran), because the
  setup might then install machine-wide; that behaviour of the setup was not tested either.
- **Flags.** `/VERYSILENT /NORESTART /NOCANCEL /SP-`. No `/DIR`, `/LOADINF` or component flag is passed.
- **What a real run proved (Windows Server 2019, no winget, machine-wide install, elevated prompt, nothing else holding Git open).** From Git for Windows 2.53.0.3 to the pinned 2.56.0.4 with
  `bin\git-secret-guard.cmd install --upgrade-git`: the setup record `Git_is1` differed afterwards only in `InstallDate` (install directory, selected and deselected components, every
  `Inno Setup CodeFile:` option, setup type and icon group were kept), `etc/gitconfig` was byte-identical, the file set was identical except `unins000.dat`, and `usr\bin\bash.exe` was replaced
  cleanly (no pending file renames naming Git, although 72 unrelated ones existed before the run; no `.tmp`/`.old` leftovers). The runner's `-Wait` followed the installer and its helper processes; the rerun of install started after the installer tree was gone.
  Commits were scanned afterwards (a clean one passed, a fake key was blocked). Nothing was passed for the directory or the options.
- **Still unproven:** a real UAC decline by a person, a typed yes at a real prompt (the real runs used the flag; a pseudo console on the hosted runner returned no text), and a Windows client. Files in use, a killed installer, a refusal for a wrong signer pin (the signature itself was valid; an invalid signature was not produced), a refusal in the rerun and the winget route were run on a hosted runner.
- **A downgrade is never allowed.** In that run the 2.53 installer, started under `/VERYSILENT` without `/ALLOWDOWNGRADE=1`, stopped on a Yes/No "really downgrade?" message box and waited until it was
  killed. So a stale hand-off run after git has moved past the pin could hang under the runner's unbounded `-Wait` (a hypothesis: the stale case itself was not run). The runner therefore reads the installed
  version (`Git_is1` `DisplayVersion`, `HKLM` for machine-wide and `HKCU` for per-user) after its checks and, when it is not older than the pin, deletes the stale hand-off and installer and exits 17 with
  "nothing is needed". It never passes `/ALLOWDOWNGRADE`. The wait itself is not bounded: `Start-Process -Wait` also waits for helper processes, and a bound that is simple and safe was not found. A killed
  runner or installer leaves whatever the installer had done by then. Check `git --version`. If `git-secret-guard` still starts, run `git-secret-guard install --upgrade-git` again. If it says Git for Windows
  "looks half installed" (exit 127: the stopped installer removed `usr\bin\bash.exe`), run the installer file the first run kept, `%LocalAppData%\git-secret-guard\git-upgrade\Git-<version>-64-bit.exe`, by hand
  with `/VERYSILENT /NORESTART /NOCANCEL /SP-` (measured: that repaired the machine and `install --upgrade-git` then completed); the exit 12 text and the `.cmd` message say the same. Programs of other users are
  not seen without elevation (`Get-Process` gives no path for them), so with one of them running from the install directory the silent installer can still wait.
- **Where the hand-off is.** From `git-secret-guard.cmd` it is in `%LocalAppData%\git-secret-guard\git-upgrade`; started from Git Bash it is in the state directory, `~/.local/state/git-secret-guard/git-upgrade`.
  Files are removed after a run, the empty directories stay until `uninstall`.
- **After the upgrade** open a new terminal when `PATH` changed. The IDE and GUI client warning stays: this changes the Git for Windows that `PATH` finds, not a git an IDE bundles.
- **Exit codes of the runner:** 0 done; 10 installer refused (digest, signature, signer, junction or missing) and nothing ran; 11 elevation declined, nothing changed; 12 installer or winget
  returned non-zero (check `git --version`, run again); 13 invalid, unknown or already used hand-off, or a missing or unusable `tools.lock`; 14 per-user install from an elevated prompt (nothing ran); 15 the installer could not be
  started for another reason; 16 unexpected error; 17 the installed Git for Windows is not older than the pin (stale hand-off, nothing ran); 18 its version string is not a plain a.b.c[.d] version (for example `garbage`, `2.57.0-rc1`), so it cannot be compared, nothing ran and the user is pointed to a manual install (an empty or missing record goes on); 19 programs of the install directory (a Git Bash, an editor terminal) are running: nothing ran, the hand-off is kept and the message names them (measured: with one running, the silent installer gave no output for 15 minutes until the harness killed it); 1 PowerShell itself refused to run the script (for example a group policy that blocks `-ExecutionPolicy Bypass`).
- **What the tests run on the Windows host:** `tests/test_gitup_windows.sh` (its safety nets, the path guards, the never-start guards and the certificate hygiene, are in `tests/test_gitup_windows_safety.sh`) drives the module with registry, `whoami` and `winget` stand-ins (the sandbox stands for System32 through
  `GSG_GITUP_ROOT`), the runner with Windows PowerShell and a compiled stand-in installer carrying a throw-away signature, `git-secret-guard.cmd` (checkout and installed copy) with real
  `cmd.exe`, and the real `bin/git-secret-guard install --upgrade-git` with a fake old git. The module logic also runs on Linux through a faked `uname`; the runner and `.cmd` tests skip there.
  The runner reads no variable for its checks: tests run a sandbox copy of it with its own `tools.lock` (and its signer line), changed in one line for the untrusted test signature and for the elevation check,
  and wrap `Start-Process` to record, hold, fail or skip the start. The self-signed test signer is built once into the tools cache and its key and store copies are deleted. No test starts
  a real Git for Windows installer or winget.

### The test suite on Windows

```powershell
tests\run.cmd                      # the whole suite (tests/run.sh from Git Bash)
tests\run.cmd tests\test_hook.sh   # one file
```

Git for Windows is all it needs: `tests/run.sh` fetches the pinned scanners and `jq.exe` into
`~/.cache/git-secret-guard-test-tools` the first time (SHA-256 checked against `tools.lock`). Test files run in parallel, one
per core (`GSG_TEST_JOBS=1` for one at a time), because starting a process costs far more than on Linux. Each file still
has its own sandbox, and `GSG_TEST_GIT` picks another git.

The suites run on the real Windows flow, not a fake Linux one: real `.exe` names, native git, `taskkill`. Two things keep
one set of tests working on every platform. `run_cap` turns the sandbox's `C:/` prefix and the `.exe` tool names back into
the POSIX spelling before assertions read them, and `git_path` gives a path in the form native git needs inside a config
file. A test that cannot apply is reported as `SKIPPED` with its reason: a whole file through `FILE_SKIP_REASON` (systemd,
launchd, the container launchers), a single test through [`tests/windows-skips.list`](../tests/windows-skips.list). Read that
list to see exactly what is not covered on Windows. Add to it only what truly cannot apply, with the reason; a failure
that could be a bug gets fixed.

`tests/test_windows.sh` tests the Windows branches through a faked `uname`, so a change that breaks them also fails on Linux.

## WSL (Windows Subsystem for Linux)

> **WSL 1 warning.** On the maintainer's Windows Server 2019 machine (build 17763, `lxcore.sys` 10.0.17763.2268) WSL 1 blue-screened the host twice, both
> times in its own driver (bugcheck `0x3B`, `LXCORE.SYS+0xa223c`, stack through `Wof.sys` and `FLTMGR.SYS`). The first came under heavy load, the second about two
> minutes after a plain `wsl.exe -d Ubuntu -- git --version` with no tests running. The first crash came in the same minute that a script renaming the directory of a running script was written (it may or may not have run); the rename probe of the workflow is that same kind of operation, so it runs last. **The cause is not established.** It is not known that git-secret-guard caused
> it, and not known that it did not. Do not run installs or the test suite in WSL 1 on a machine that must not crash; the real WSL checks run on a disposable
> GitHub runner (below), never on that machine.

**Status: implemented, fixture-tested and run for real on hosted WSL 1 and WSL 2 (see the runs below, every leg that could start passes).** Not possible: Rocky and Fedora on WSL 1, because wsl --import fails there. Still unproven: Fedora's upgrade route (the vendor image already holds git 2.56.0), and the Windows Server 2019 build 17763 host (a crash there is neither explained nor cleared). What a WSL 1 chroot E2E of the apt route on Windows Server 2019 showed is recorded in issue #29
(its comments). The `wsl` workflow (`.github/workflows/wsl.yml`, started by hand from the Actions tab) runs the scenarios below on a hosted runner; until its first results are written into
this section, treat what the status line lists as unproven as unproven. The measured answers are in the table below.

WSL runs a real Linux distribution, so `install` takes the Linux path and the distribution's own git route: Ubuntu and Debian follow
[the apt rule](#ubuntu-and-debian-apt) and RPM distributions the [RPM route](#rhel-rocky-and-fedora-rpm), with the same checks and the same plan. WSL adds only this:

- **Detection** (`lib/wsl.sh`, `wsl_is`): `uname -s` is `Linux` and either the kernel release (`/proc/sys/kernel/osrelease`) contains `microsoft` in any case, or
  `/proc/sys/fs/binfmt_misc/WSLInterop` exists. WSL 1 reports `4.4.0-17763-Microsoft` (capital M, read on a real machine); `WSL_DISTRO_NAME` is not set there, so it is
  not the signal. A Linux container on a WSL 2 host shows the same kernel text and is taken for WSL too, which only adds the notes and the timer check below.
- **Class `wsl`** (`gitup_os_class`): a WSL distribution of the `rpm`, `ubuntu` or `debian` family. The `wsl` module (`lib/gitup_wsl.sh`) runs that family's module unchanged and adds two plan notes: the upgrade applies to this distribution only,
  and Windows-side git is a separate setup. Any other WSL distribution stays class `other` with today's refusal.
- **Two git setups.** WSL git reads the WSL `~/.gitconfig`, `git.exe` the Windows one. When a `git.exe` is reachable, `install` ends with a note naming it: commits made
  with it are not covered; run `install` in Git for Windows bash for that. `git.exe` is never an install candidate and never an "other git" warning (`type -aP git` does not match it).
- **`--with-timer`** needs systemd running (`/run/systemd/system` exists, what `sd_booted` tests). `systemctl` being on `PATH` proves nothing: on WSL 1 it is installed and pid 1 is `init`.
  Without systemd `install` refuses before any change. On WSL 2 it prints the fix: `[boot]` `systemd=true` in `/etc/wsl.conf`, then `wsl --shutdown` in Windows (the `[boot]` section needs Windows 11 or Windows Server 2022).
  On WSL 1 it says the timer is not available and prints no `wsl.conf` fix, because that section does not exist there. Run `git-secret-guard doctor` by hand instead.
- **`--take-over-system-git`** behaves as on the same distribution outside WSL: on Ubuntu or Debian (the apt classes have no takeover) it is refused with exit 1, naming class `wsl`; on an RPM distribution it works as on RPM. The wrapper module defines the takeover functions only when the inner module has them.
- **Checkout and repository on `/mnt/c` (measured, run 42240922868).** DrvFs without `metadata` shows every file as mode 777. `install` copies the checkout with `cp -a` and then removes group and other write bits from the share tree. With the drive mounted for the user (`uid=1000`, measured on drvfs and 9p), a repository on `/mnt/c` blocks the fake key and passes a clean commit (2 s on WSL 1, 4 s on WSL 2), `install` from a checkout there exits 0, and nothing in the installed tree is group or other writable. The mount must belong to the user: in the first run, with the runner default mount for root (`uid=0`), the repository could not be prepared and the checkout could not be copied by the normal user. A `metadata` mount was tried: see the later runs below.
- **`install` from the installed CLI on WSL 1** failed with `mv: cannot move '.../git-secret-guard' to '.../git-secret-guard.old.XXXXXX/previous': Permission denied` (issue #29, jammy and noble).
  **Measured (run 42237326449, GitHub-hosted `windows-2022`, Ubuntu 22.04):** renaming the directory that holds a running script fails on WSL 1 (`4.4.0-20348-Microsoft`, rc 1, `Permission denied`) and works on WSL 2
  (`6.18.54.1-microsoft-standard-WSL2`, rc 0). `main`'s installed CLI gives the same `mv` error on WSL 1 and passes on WSL 2, so the pin applies to WSL 1 only (`install_pins_running_script`): from the installed copy only the
  generated files (`settings`) change, as on Windows. This branch's installed-CLI install passes on both. WSL 1 on that runner (build 20348) ran the rename without a crash; that says nothing about the 17763 host, which is not cleared.

**Order of the real run.** The workflow runs `facts`, `upgrade`, `mount-for-user` and `mntc`, writes their results to the job summary and uploads the logs, and only then runs `tests`, the rename `probe` and the
`installed-cli` phase, because the probe is the kind of operation that coincided with the first blue screen (no cause is claimed). `tests` comes after the first upload for the same reason:
`test_install` has an installed-copy test that runs under the plain-kernel pin and so renames the directory of a running script; it failed on WSL 1 as the measured limit predicts, and now skips there with that reason while a second test runs the WSL 1 path through the fixture seams. A failure on WSL 1 stays recorded, not hidden. `tests/platform/wsl-ci.sh` refuses to run unless `GITHUB_ACTIONS` is `true`.

**Running it.** `gh workflow run wsl.yml --ref BRANCH -f distribution=Ubuntu-22.04|Ubuntu-24.04|Rocky-9|Fedora-44 -f consent=flag|typed` (the Actions tab has the same form). Ubuntu comes from `setup-wsl`.
Rocky 9.8 (`Rocky-9-WSL-Base-9.8-20260525.0.x86_64.wsl`, SHA-256 `58de2455cd47...3829221`) and Fedora 44 (`Fedora-WSL-Base-44-1.7.x86_64.wsl`, SHA-256 `2e5b153ba4b6...d319a`) are the vendors' own WSL tars, imported
with `wsl --import`; the digests are the ones in the vendors' CHECKSUM files, checked in the job (a mismatch stops it), and the same files were hashed once by hand. To bump an image, read the new file name and digest from the vendor's
CHECKSUM file and change both in the `Import the RPM distribution` step. `consent=typed` types the answer at the real prompt on a pty instead of passing `--upgrade-git`. Every phase runs through `tests/platform/wsl-phase.ps1`
in the distribution named by `WSL_TARGET`. Rocky and Fedora run the WSL 2 leg only (the matrix has no WSL 1 entry for them), because `wsl --import` of their vendor tars fails on WSL 1 (see the later runs above); a typed No is always run first, and on a stock git that is already new enough the flow checks that nothing is offered.

**Tested where.** `tests/test_wsl.sh` drives all of this through fixture kernel files (`GSG_WSL_OSRELEASE`, `GSG_WSL_INTEROP`, `GSG_WSL_SYSTEMD_DIR`, announced on stderr like the other test seams, except that seams which look like plain Linux are silent) and a faked
`uname`, so it runs on Linux, macOS and Git for Windows alike. The real runs are `tests/platform/wsl-ci.sh`, started by `.github/workflows/wsl.yml`.

**What the hosted runner offers** (sources, not assumptions): the `windows-2022` image lists "Windows Subsystem for Linux (WSLv1): Enabled" and no distribution
([actions/runner-images, Windows2022-Readme](https://github.com/actions/runner-images/blob/main/images/windows/Windows2022-Readme.md), image 20261101.353.1). `Vampire/setup-wsl` v7.2.0 installs a distribution
(`Ubuntu-26.04` to `Ubuntu-16.04`, `Debian-13`, default `Debian-13`) and takes `wsl-version` 1 or 2 (default 2; "WSLv1 and WSLv2 are tested"); its README says WSL 2 "is also available" on later `windows-2022` images
but does not discuss nested virtualization. Another setup action states that it "requires WSL2 with nested virtualization". Whether WSL 2 starts on a hosted runner is therefore **not documented
by GitHub in the places read**; the first real run answered it: both versions start on `windows-2022` with `Vampire/setup-wsl`, WSL 2 included, with systemd running in the WSL 2 distribution.

**Measured in run 42237326449** (GitHub-hosted `windows-2022`, Ubuntu 22.04, stock git 2.34.1, one run, both versions):

| | WSL 2 | WSL 1 |
|---|---|---|
| Kernel | `6.18.54.1-microsoft-standard-WSL2` | `4.4.0-20348-Microsoft` |
| `wsl_is` / `wsl_version` | WSL / 2 | WSL / 1 |
| systemd | pid 1 is systemd, `/run/systemd/system` present | pid 1 is `init`, directory absent |
| `install --upgrade-git` | rc 0, git 2.56.0, fake key blocked (4 to 5 s over two runs), clean commit passes, rerun offers nothing | the same (blocked commit 2 s) |
| `git.exe` on the distribution's PATH | `/mnt/c/Program Files/Git/bin/git.exe`; the separate-setups note was printed | the same |
| `install --with-timer` | rc 0, timer installed | rc 1, "not available on WSL 1", no `wsl.conf` fix, nothing changed |
| Rename of the directory of a running script | rc 0 | rc 1, `Permission denied` |
| `main`'s installed-CLI `install` | passes | `mv ... Permission denied`, rc 1 |
| This branch's installed-CLI `install` | passes | passes |
| Test files (`GSG_TEST_JOBS=1`) | 273 passed, 0 failed (run 42263902872) | 270 passed, 0 failed, 3 skipped: one `test_install` test that needs the real rename and two `test_timer` tests that need systemd-analyze |
| `/mnt/c` mount | 9p, `uid=0;gid=0` | drvfs, `uid=0,gid=0,case=off` |

The first run's `mntc` phase failed on both legs because the runner mounts the drive for root while the test user is `gsg`. The workflow now remounts `/mnt/c` for that user (phase `mount-for-user`, as root, before `mntc`); the second run passed on both legs with the mount shown as `uid=1000,gid=1000` (drvfs on WSL 1, 9p on WSL 2).

**Later runs** (same runner, `windows-2022`; every figure is a line of the run's `results.txt`, read from the artifact, not from the job colour):

| What | Run | Result |
|---|---|---|
| Ubuntu 24.04, `--upgrade-git`, both versions | 42273224706, 42283187095 | WSL 1: `4.4.0-20348-Microsoft`, WSL 2: `6.18.54.1-microsoft-standard-WSL2`. `/etc/os-release` says `VERSION_ID="24.04"`, stock git 2.43.0 from `apt`, route `ppa`, git 2.56.0 from `1:2.56.0-0ppa1~ubuntu24.04.2`, blocked commit and clean commit pass. Test files: WSL 1 271 passed, 3 skipped; WSL 2 274 passed (42283187095, with the awk test added since). Stock 24.04 on WSL 1 did **not** hit the `systemd-sysusers` / `Failed to take /etc/passwd lock` failure seen in the 2026-11-05 chroots of issue #29: that failure belongs to a minimal debootstrap chroot, not to a WSL 1 distribution. |
| A typed yes and a typed No at the real prompt, Ubuntu 22.04 and Rocky 9.8 | 42281638988, 42283182724, 42288773262 (Ubuntu); 42288768426 and 42304862946, 42304866361, 42304869555, 42304873368 (Rocky, WSL 2) | Install runs on a pty (`script -qefc`) with the answer typed, on stock git 2.34.1. **Typed No:** `Upgrade git now with the plan above? [y/N]` is printed, install exits 1, `git --version` is still 2.34.1, no `/usr/local/bin/git`, no git-core PPA file, no install state. **Typed yes:** the same prompt, install exits 0, git 2.56.0, blocked commit passes. Both versions (42288773262: WSL 1 47 PASS, 0 FAIL; WSL 2 45 PASS, 0 FAIL). On Rocky (WSL 2) the typed yes also meets the second prompt, `Take over /usr/bin/git with the plan above? [y/N]`, and the typed `n` leaves `/usr/bin/git` 2.52.0 as it is. **A hang in the harness, not shown in the product:** when both answers were typed at the start (`y`, then `n`), every Rocky run but one sat at the takeover prompt until it was cancelled after 10 to 22 minutes (about a dozen runs, for example 42286936636, 42292067132, 42294847222, 42297097396, 42299444734, 42301621519; the exception is the run with the 15 s repeat). With strace (42303388833) the install bash was blocked in `read(0)` at that prompt for 240 s, so the second answer never reached it. Why is not established (a terminal flush by `sudo` or `dnf` is a guess). The one run that passed (42288768426) had a 15 s repeat of the answer, which is a single result. The harness now types each answer after its prompt shows in the log: 4 of 4 runs passed (47 PASS, 0 FAIL each; 42304862946, 42304866361, 42304869555, 42304873368), and each took the takeover `n`. A person answers a prompt they see, so this is also the realistic case; whether the product loses an answer typed ahead of its prompt on a real terminal is untested. **Inference, not established:** the review noted that `sudo` 1.9.17p2 has `use_pty` on by default, so `sudo` may read the terminal and relay it to its own inner pty, where the `n` is echoed and never read (raw log line 17 shows `[y/N] n`); nothing in `lib/`, `bin/` or the hook flushes the terminal. |
| Rocky Linux 9.8 on WSL 2 (vendor WSL image, SHA-256 pinned) | 42280195949 | `/etc/os-release` `ID="rocky" VERSION_ID="9.8"`, stock git 2.52.0. Typed No: prompt, exit 1, git unchanged. `install --upgrade-git` follows the RPM route as outside WSL: `route: source (the newest git-core the repositories offer is 2.52.0)`, `dnf install` of the build dependencies, copy into `/usr/local`, git 2.56.0, plus the two WSL notes. The offer to take over `/usr/bin/git` is printed again on a rerun (as on Rocky outside WSL). Blocked commit 4 s. 46 PASS, 0 FAIL; test files 196 passed. |
| Fedora 44 on WSL 2 (vendor WSL image, SHA-256 pinned) | 42278544995 | Stock git is already 2.56.0, so there is no upgrade to offer: install exits 0 and offers nothing. The image has no `awk` and no `xz`: see the product bug below. 42 PASS, 0 FAIL; test files 188 passed, 8 skipped. |
| Rocky and Fedora on WSL 1 | 42275534015, 42277560907, 42278541531, 42280195949 (Rocky), 42275538317, 42277565255, 42278544995 (Fedora) | **Not possible.** `wsl --import` of the vendor WSL tar fails with `Unspecified error` (exit -1) on the WSL 1 leg, in every form tried (the full ladder is in 42280195949: the tar as shipped, as `.tar.gz`, unpacked to a plain `.tar`; with `--version 1` and through `--set-default-version`; into `C:` and `D:`, both NTFS), after 8 to 47 s. The same tars import on WSL 2. The cause is not known. |
| `metadata` mount of `/mnt/c`, Ubuntu 22.04 and Rocky 9.8 | 42283182724, 42288773262 (Ubuntu), 42288768426 (Rocky, WSL 2) | Remounted as root with `-o uid=1000,gid=1000,noatime,metadata`; `/proc/mounts` shows it (WSL 1 drvfs: `uid=1000,gid=1000,metadata,case=off`; WSL 2 9p: `uid=1000;gid=1000;metadata;`). **Without** `metadata` a new file and directory show mode 777 whatever `chmod` says. **With** it a new file after `chmod 644` shows 644, a new directory 755, and `chmod 640` on a copied file shows 640. Files copied with `cp -a` from the runner's `D:` checkout keep that drive's mode 777, since they have no mode to copy. Repository on the drive: fake key blocked and clean commit passes (2 s on WSL 1, 4 to 5 s on WSL 2); install from a checkout on it exits 0 and leaves nothing group or other writable. Rocky on WSL 2 gives the same (42288768426: new file 777 without `metadata`, 644 with it, directory 777 and 755, `chmod 640` sticks). |

**Product bug found and fixed.** The Fedora 44 WSL image has no `awk`. `install` finished, and then every commit was blocked with `awk: command not found` ("nothing was scanned"): safe, but found out at the first commit. `install` now names `awk` with its package (`gawk`) among the prerequisites on Linux and WSL (`install_resolve_bins`; macOS goes through `install_macos_inspect` and has no awk check; `test_a_missing_awk_is_refused_by_install_with_its_package_not_found_out_at_the_first_commit`). The workflow shows it on Fedora: the first `install` refuses with `awk is required but was not found on PATH`, `dnf install gawk` follows, and the rest passes.

**Findings about the test setup, not the product.** `wsl.exe -e bash` starts with `SHELL=bash`, a bare name, and `script -c` then fails with `No such file or directory` for its command (run 42278536933, `script from util-linux 2.37.2`); with `SHELL=/bin/bash` it works, and so does `python3` `pty`. The phase script exports `SHELL=/bin/bash`. Four `test_prerequisites` tests failed on a machine that already held a build of ours in `/usr/local` (the path-fix refusal, run 42278541531); they now run with a sandbox `GSG_GITUP_ROOT`. An RPM image needs `dnf upgrade` first: `libcurl-devel` could not be installed against the image's older `libcurl` (run 42277560907).

### Real scenarios and where each one runs

| Scenario (issue #31) | Fixture test (`tests/test_wsl.sh`, runs anywhere) | Real run (`wsl.yml`, phase of `tests/platform/wsl-ci.sh`) |
|---|---|---|
| Detection on WSL 1 and WSL 2 | `test_the_wsl1_kernel_text_*`, `test_the_wsl2_kernel_text_*`, interop file, plain Linux, macOS and Windows | `facts` |
| Plan is the inner plan plus notes | `test_the_wsl_plan_is_the_inner_plan_plus_two_notes` | `upgrade` |
| Old git, accept the offer, blocked commit | (module dispatch only) | `upgrade` |
| Rerun does nothing to git | `test_a_wsl_refresh_with_nothing_stale_prints_nothing_at_all` | `upgrade` |
| Windows git never mistaken for the WSL git | `test_a_windows_git_is_never_taken_for_a_git_of_the_distribution` | `facts` (`git.exe` on PATH) |
| The two setups are explained | `test_a_reachable_windows_git_is_explained_as_a_separate_setup` | `upgrade`, checked when `git.exe` is on the PATH inside the distribution; otherwise recorded as not exercised |
| Timer without systemd, WSL 1 and WSL 2 | `test_with_timer_is_refused_on_wsl1_*`, `..._wsl2_*` | `upgrade` |
| Timer with systemd | `test_with_timer_goes_on_when_systemd_runs_*` | measured on WSL 2: systemd runs and `install --with-timer` exits 0 (run 42237326449) |
| Repository and checkout under `/mnt/c` | none possible | `mount-for-user` and `mntc`: measured, both legs pass (blocked commit 2 s on WSL 1, 4 s on WSL 2; install from the checkout exits 0; files show mode 777) |
| `install` from the installed CLI | `test_an_install_from_the_installed_copy_on_wsl1_never_renames_*` | `probe`, `installed-cli` |
| Rocky or Fedora in WSL | `test_the_wsl_module_for_an_rpm_distribution_wraps_the_rpm_module` | Rocky 9.8 on WSL 2 follows the RPM route (source build, 2.52.0 to 2.56.0); Fedora 44 on WSL 2 has git 2.56.0 and offers nothing; neither can be imported on WSL 1 (later runs above) |
| A typed yes and a typed No at the prompt | none (`test_gitup` drives the prompt through `script` outside WSL) | `upgrade` with consent `typed`: Ubuntu 22.04 on both versions, Rocky 9.8 on WSL 2 |
| A `metadata` mount of `/mnt/c` | none possible | `mount-for-user metadata` and `mntc metadata`: Ubuntu 22.04 on both versions, Rocky 9.8 on WSL 2 |
| Not WSL: nothing changes | `test_the_class_outside_wsl_is_unchanged`, `test_with_timer_is_unchanged_outside_wsl` | the Linux suite |
| Test files that apply | | `tests`, `GSG_TEST_JOBS=1` |

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
- **Test infrastructure that moved:** the suite drives `$GSG_TEST_GIT` (default `/usr/local/bin/git` on Linux, `/usr/bin/git` on macOS), because the
  PPA git lives in `/usr/bin/git`; the timer tests compute the unit `PATH` from the first git on the lifecycle `PATH`.

## `tests/platform/ubuntu.sh`: the repeatable container run

```bash
tests/platform/ubuntu.sh                 # PPA first, source build when the PPA has no git >= 2.54 (--git ppa|source|auto)
tests/platform/ubuntu.sh --phase upgrade  # the real install --upgrade-git on a stock git (--os ubuntu-22.04 or debian-13 pick the other pinned images)
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

- Podman starts under `env -i` with only `PATH`, `XDG_RUNTIME_DIR` and `XDG_DATA_HOME` taken from the host (the rest point into the
  scratch home or are fixed); no host variable reaches the container (names checked), and the container has no `~/.ssh`, `~/.gitconfig` or `.git`.
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
(`tests/platform/ubuntu-e2e.sh`: install with real downloads, a runtime-built fake token blocked by trufflehog and betterleaks, upgrade, uninstall,
second uninstall, no value printed) and `tests/run.sh` (some tests use `chmod 000`, which root ignores). Every step runs under `timeout`; the
run ends with a summary, the list of skipped tests with their reasons, and exits nonzero on any failure. Tests that need something the container
lacks skip with a reason; none is faked. The service-environment tests emulate a systemd unit's `User=` and `PATH=` and run only when
`GSG_TEST_SERVICE_UNIT` names such a unit on the machine (and it runs as the current user); unset, they skip with `GSG_TEST_SERVICE_UNIT is not set`.

### What the container run trusts

- **The PPA signing key** is fetched from Launchpad over TLS by `add-apt-repository` the first time, so the channel is TLS plus Launchpad itself. The
  run calls `gitup_apt_ppa_apply` of the product (`lib/gitup_apt.sh`, the same code `install --upgrade-git` runs, no second copy): it adds the repository with
  `add-apt-repository -y -n` (which runs no apt update), compares the fingerprint of the key (embedded in `/etc/apt/sources.list.d/git-core-ubuntu-ppa-*.sources`, or in
  `/etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg` for a `.list` file) with the pinned `F911AB184317630C59970973E363C90F8F1B6217`, and only then runs
  `apt-get update`. A mismatch fails the PPA path: the sources or list file and the `trusted.gpg.d` key are deleted and `apt-get update` runs again, so the SHA-256 verified source
  build that follows in `auto` mode never runs apt as root with the unchecked PPA enabled.
- **apt packages are not version-pinned.** `jq`, `curl`, `gawk`, `mawk`, `pre-commit`, `dbus` and the others come from the Ubuntu archive (signed by
  apt's own keyring) and the PPA at whatever version they carry on the day; the summary prints the versions that were used.
- **Pinned by SHA-256:** the `git-2.56.0.tar.xz` source tarball from kernel.org and the shellcheck 0.11.0 release tarballs. **Pinned by digest:** the
  base image. **Pinned in `tools.lock`:** trufflehog and betterleaks, which the install E2E downloads for real.

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
- **Rocky** has its own script, `tests/platform/rocky-container.sh`, which sources `ubuntu-container.sh` and redefines `usage`, `install_git_source`, `install_pre_commit` and `phase_prepare`: dnf
  prerequisites (with `--allowerasing`, the image's `libcurl-minimal` conflicts with `libcurl-devel`), shellcheck 0.11.0 (SHA-256), pre-commit from pip
  (unpinned), git 2.56.0 built from the SHA-256 verified tarball into `/usr/local` next to the stock `/usr/bin/git`. The Rocky image is
  `docker.io/rockylinux/rockylinux:9.7@sha256:53f4c6dcb34e1403bd93207351f0af9a593610faeb7165cb8a037346765199b0` (manifest-list digest, looked up like the
  Ubuntu one: anonymous token from `auth.docker.io` for `repository:rockylinux/rockylinux:pull`, then `curl -I --max-time 30` on
  `registry-1.docker.io/v2/rockylinux/rockylinux/manifests/9.7` with the OCI index and Docker manifest-list `Accept` headers; it equals the DIGEST column of
  `podman images --digests`). Its repositories already serve 9.8, so the run mixes 9.7 base packages with current 9.x updates.
- **Not covered:** x86_64 (the `linux_x64` and `linux_amd64` rows of `tools.lock` are not exercised on an arm64 VM), and macOS itself, which
  `tests/run.sh` covers natively.

## CI on real platforms

`.github/workflows/platforms.yml` runs what no unit test can: real containers, a real VM and real Windows installs, on disposable GitHub-hosted runners. It is not a pull request check
and not part of `tests.yml`. It runs only by `workflow_dispatch`.

- **Starting it.** By hand only: `gh workflow run platforms.yml --ref BRANCH` runs every job (about 45 minutes, the Rocky source builds and the three suites dominate). There is no push, pull request or schedule
  trigger on purpose: a run costs hours of hosted runners and its answer changes only when the product or a pinned image does; run it before a release and when `lib/gitup*.sh`, the platform scripts or a pin change.
  A branch can iterate with a temporary `push:` trigger, which must not be merged. Third-party actions are pinned by full SHA. The concurrency group names the commit.
  Job logs are readable through the API only when the whole run has ended; every job uploads its log as an artifact (`gh run download RUN -n NAME`).
- **The runner.** `ubuntu-24.04`, 4 vCPUs, 16 GB, rootless podman 4.9.3 with crun 1.14.1 and cgroups v2, `/dev/kvm` present (`crw-rw---- root kvm`; a udev rule makes it usable), qemu from apt.
  `windows-2025` is elevated and has winget 1.11 with `Git.Git`.

### What had to change for the runner (and what did not)

- **Isolation checks: one mount rule added, nothing skipped.** Podman 4.9.3 masks `/sys/dev/block` as well (the `maskedPaths` of its `config.json`, read in a probe job). `ISOLATION_MOUNT_RULES`
  gained `/sys/dev/block=tmpfs`; the fstype is checked like every other entry, and the variable, `/dev`, namespace, `/run/secrets` and read-only `/src` checks are unchanged. `ubuntu.sh` still has no way to skip a check.
- **Debian 13 prepare.** `software-properties-common` does not exist on Debian; the package list is now per distribution (`apt_prerequisites`), the Debian default is the source build (no Launchpad PPA is tried), and the
  stock `git` is installed as on Rocky. This was a real failure of the default phases on Debian (run 42252845651).
- **Rocky containers need `/etc/shadow` at mode 0400** (`rpm_fix_shadow`). At the image's 000 every `sudo` of a non-root user failed with "PAM account management error" under this runner's rootless podman.
  A setuid `unix_chkpwd` and `rpm --setcaps` did not help; only the mode did (probe job, run 42260761407). A fixture, not a product change.
- **The Rocky VM guest runs with `/usr/local/bin` first on `PATH`**, as the product tells a user to do; a Rocky 9 login shell lists `/usr/bin` first.

### Results
The final full run, dispatched on `626295d` (the commits after it change documentation only): `gh workflow run platforms.yml --ref ci/real-platform-runs`, run 42304848378, all 24 jobs green (`1152 passed, 0 failed, 69 skipped` in each of the three suites). Older run ids below are the first appearance of a result.

| Item | Result | Run | Real output |
|---|---|---|---|
| Ubuntu 24.04 `--phase upgrade` (PPA, `.sources`) | PASS | 42252266035, 42273585581 | `E2E SUMMARY: 27 passed, 0 failed` |
| Ubuntu 22.04 `--phase upgrade` (PPA, `.list`; first container run) | PASS | same | `E2E SUMMARY: 28 passed, 0 failed` |
| Debian 13 `--phase upgrade` (source build) | PASS | same | `E2E SUMMARY: 21 passed, 0 failed` |
| Ubuntu 24.04 and 22.04, default phases (prepare, install E2E, whole suite) | PASS | 42282142479 | install `E2E SUMMARY: 31 passed, 0 failed`; `SUMMARY: 1108 passed, 0 failed, 67 skipped (total 1175)` on both |
| Debian 13, default phases | PASS | 42284768674 | install `E2E SUMMARY: 31 passed, 0 failed`; `SUMMARY: 1108 passed, 0 failed, 67 skipped (total 1175)` |
| Rocky 9.7 `rpm.sh rocky` (source route, takeover, dnf update control, restore, interrupts) | PASS | 42261480647, 42273585581 | `E2E SUMMARY: 92 passed, 0 failed` |
| Fedora 44 `rpm.sh fedora` (package route) | PASS | same | `E2E SUMMARY: 13 passed, 0 failed` |
| Fedora 44 with git-core 2.47.0 installed (#40, old git) | PASS after a product fix | 42259957123, 42273585581 | `E2E SUMMARY: 16 passed, 0 failed`; before the fix `Package "git-core-2.47.0-1.fc41.x86_64" is already installed. Nothing to do.` |
| `sudo` with a real password prompt (pty through `script`, random password in a 0600 file) | PASS | 42261480647, 42273585581 | three `[sudo] password for gsguser:` for a wrong password, then `sudo: 3 incorrect password attempts` and nothing built; right password: `E2E SUMMARY: 16 passed, 0 failed` |
| Takeover restore with the network off (`--network none` after `podman commit`) | PASS | same | stage 1 `41 passed, 0 failed`; stage 2 (only `lo`, `curl` and name lookup fail) `12 passed, 0 failed` |
| Direct root run of the full flow, no `sudo` installed | PASS | same | `E2E SUMMARY: 65 passed, 0 failed` |
| Real pin bump (git 2.55.0 built, then the current pin 2.56.0) | PASS | 42273585581 | `E2E SUMMARY: 17 passed, 0 failed` |
| Rocky 9.8 VM, SELinux enforcing, KVM (`/dev/kvm` present) | PASS; the label finding is fixed and checked; a confined domain executing libexec programs is open (see the VM section) | 42304848378 | `SELinux is enforcing`; `E2E SUMMARY: 88 passed, 0 failed`; `ROCKY VM TEST: PASS (... accel kvm)` |
| GitHub Desktop's bundled git | measured | 42259957123, 42273585581 | `old git: exit 0; output: []` for 2.45.3 built from the tarball and for the git in the Desktop 3.4.13 `.deb` |
| Windows scenarios | see "Windows" | | |

**Suite failures this work found and fixed.** Debian 13 failed the prepare step (above); once it ran, `test_prerequisites` (four tests) saw the real `/usr/local/bin/git` of the machine and now moves the system paths into the sandbox
like the other gitup tests, and the doctor test needs the stock `/usr/bin/git`, which the Debian prepare step now installs.
Six `test_exemptions_real` tests failed on two of eight runs: they shared one random 32-character `generic-api-key` draw per run. The logs of those runs do not record the key, so the cause is inferred, not proven: the built-in rule
skips a value holding a dictionary stopword (`vpn` is one), and a 62-symbol draw meets one of the many three-letter stopwords far more often than a vowel-free draw does. A vowel-free draw was tried first and still misses by chance (about 1 run in 300 by the reviewer's count), so
the key is now fixed, built from fragments at run time, and the whole file passes with the real betterleaks (27 passed, 0 failed, 1 skipped).

### Rocky VM (SELinux enforcing)

`tests/platform/rocky-vm.sh` boots the dated image `Rocky-9-GenericCloud-Base-9.8-20260525.0.x86_64.qcow2` (SHA-256 in the script, taken from the file's CHECKSUM) under qemu with KVM, cloud-init and an
ed25519 key; the ssh forward is bound to 127.0.0.1 and the guest has no display. `tests/platform/rocky-vm-e2e.sh` runs inside it: `getenforce` must say `Enforcing`, then the Rocky E2E (source install, takeover,
dnf update control, restore), plus labels (`stat -c %C`, `matchpathcon`, `restorecon -n -v`), `ausearch -m AVC,USER_AVC` from the start of the run, and `sshd` serving a real push and clone over ssh through
`/usr/bin/git-receive-pack` and `/usr/bin/git-upload-pack` while the takeover is active (the server's `agent=git/2.56.0` shows it is the taken-over git; after the restore it is `agent=git/2.52.0`).
Without a writable `/dev/kvm` the launcher exits 3 and says that TCG software emulation is roughly 10 to 50 times slower, unless `GSG_VM_ACCEL=tcg` is set. This runner has KVM, so TCG was not run.

- **Boot**: the guest accepted ssh after about 10 seconds.
- **SELinux**: enforcing, auditd active; no AVC record from the start of the run to its end, across the install, the takeover, a push and a clone served by sshd through the taken-over links, and the restore.
- **Labels**: `/usr/local/bin/git` gets `bin_t` and has one link; the `bin/git-*` siblings and the `libexec/git-core` entries are symlinks (`usr_t` under libexec, as the policy says) and the separate programs there (`git-remote-https`, `git-shell` and the like) are `usr_t`
  too; `/usr/bin/git` and its five links are `bin_t`, `dnf.conf` keeps `etc_t`, `/var/lib/git-secret-guard` is `var_lib_t`; `restorecon -n -v` on `/usr/local/bin`, the six links, `dnf.conf` and the backup directory reports nothing.
- **Finding, fixed.** git installs its siblings as hard links, so git and 150 other names were one inode that the policy labels `bin_t` under `/usr/local/bin` but `usr_t` under `/usr/local/libexec/git-core`:
  a real `restorecon -R /usr/local` relabelled `/usr/local/bin/git` to `usr_t` (run 42282871381). The source route now passes `INSTALL_SYMLINKS=1` to `make`, so the libexec entries and the `bin/git-*` siblings are symlinks to `git`, `git` has one name
  and keeps `bin_t`. In the VM (run in the record above) the checks are real: `git` is `bin_t` with one link, `restorecon -n -R /usr/local/bin` reports nothing, and after a real `restorecon -R /usr/local` `git` is still `bin_t` and a clone served through it works.
  **The fix applies to new builds.** A build made before `INSTALL_SYMLINKS=1` has hard links, and at the same pin it is not rebuilt (the Rocky `bump` scenario runs `install --upgrade-git` again over such a build: no plan, the hard links stay, git keeps more than one name).
  Its first rebuild is the next pin bump: the copy uses `cp --remove-destination`, so each hard link is replaced by a symlink (the same scenario checks `stat -c %h /usr/local/bin/git` is 1 and `libexec/git-core/git-merge` is a symlink afterwards). Until then an administrator who runs `restorecon -R /usr/local`
  on such a machine gets the old behaviour (`/usr/local/bin/git` becomes `usr_t`). Removing the files the MANIFEST lists and running `install --upgrade-git` again should rebuild at once; that was not run.
  The separate programs in `libexec/git-core` (`git-remote-https` and the like) are `usr_t`, as the policy says, from the day they are copied. The takeover judges the target of a symlinked sibling (`gitup_tk_check_owner`) instead of the 777 mode of the link.
  Whether a confined domain may execute `usr_t` files was asked of the policy with `sesearch -A -s DOMAIN -t TYPE -c file -p execute` (rule counts, run 42304848378): `httpd_t` 1 rule for `bin_t` and 1 for `usr_t`, `sshd_t` 1 and 1,
  `git_script_t` 2 and 2. Equal counts suggest the same rules cover both types, not more. **Open:** no confined process was run (`runcon` cannot enter a confined domain from `unconfined_t` here, even for `/usr/bin/true`),
  so whether a confined domain can execute the `usr_t` programs in `libexec/git-core` is unproven.

### GitHub Desktop's bundled git

A git older than 2.54 ignores `hook.<name>.*` configuration without a word. `tests/platform/old-git-e2e.sh` installs the hook with a current git into a scratch home, then commits a fake key with (1) the current
git and (2) the old git under the same home. Measured with git 2.45.3 built from the pinned tarball (SHA-256 `38f20f95...`) and with the git inside `GitHubDesktop-linux-amd64-3.4.13-linux1.deb` (SHA-256 `8b557776...`;
its `usr/lib/github-desktop/resources/app/git/bin/git` is 2.45.3): the current git blocks (`1 potential secret(s) in lines this commit adds`), both old gits finish the commit with exit 0 and **no output at all**, and
the key is in the history. **Commits made by GitHub Desktop's bundled git are not scanned.** The warning of `install` and `doctor` says so now; it used to say "has not been tested".

### Windows

The `windows` job runs on `windows-2025` (Windows Server 2025, build 26100, elevated). `tests/platform/windows-gitup-e2e.ps1 -Scenario NAME` first installs Git for Windows 2.53.0.3 over the image's git
(`/ALLOWDOWNGRADE=1` is for this fixture only; the digest `bc88381e...` equals the release's own table), then drives `bin\git-secret-guard.cmd install --upgrade-git`. The installer route needs winget off `PATH`, so those scenarios remove it for the product only.

| Scenario | Result |
|---|---|
| `winget` | winget 1.11 is on the runner and lists `Git.Git 2.56.0.4`. The plan named the route `winget`, `--scope machine` and "this prompt is already elevated"; winget downloaded, verified the installer hash and upgraded; `git --version` 2.56.0.windows.4; a fake key was blocked. `E2E SUMMARY: 8 passed, 0 failed` (run 42263939621). |
| `inuse-winget` | A running Git Bash (`bash.exe`) during the upgrade: winget's installer failed at once with `Installer failed with exit code: 1`, the runner exited 12, git stayed 2.53.0.3, `Git_is1` unchanged, no pending file rename; after the holder ended, the same command upgraded. `7 passed, 0 failed` (run 42270097343). That measurement is from before exit 19: the runner now stops first for this route too, so the final run gives exit 19 here. |
| `inuse` (installer route) | The silent installer **hung**: 15 minutes with no output until the harness killed it; git unchanged, no pending rename; after the holder ended, the same command upgraded (run 42270993343). Fixed here: the runner now stops first with exit 19 and names the programs. |
| `killed` | The installer was killed 12 seconds after it appeared: product exit 12, `git --version` already 2.56.0.windows.4 but the `Git_is1` record gone, `unins000.exe` present, `usr\bin\bash.exe` missing, no pending renames. A plain rerun could not start (Git Bash was gone). Fixed here: `gsg-bash.cmd` says "looks half installed ... run its installer again" and exits 127. Running the installer file the first run kept (`%LocalAppData%\git-secret-guard\git-upgrade\Git-2.56.0.4-64-bit.exe`) by hand repaired it; `install --upgrade-git` then ended in a blocked fake-key commit. `8 passed, 0 failed` (run 42269584889). |
| `signature` | A sandbox copy of the repository whose `tools.lock` pins another signer: the runner exited 10, named both subjects, kept the file (it matched its digest), git unchanged; the unmodified lock then upgraded. `11 passed, 0 failed` (run 42267563578). |
| `rerun` | The two legs of the `.cmd` run by hand, the second with a dead proxy and `GSG_GIT_UPGRADED=1`: `install refused; the only change made was the git upgrade of this run (Git for Windows was upgraded just before this run)`; without the proxy the same command completed. `10 passed, 0 failed` (run 42269584889). |
| `prompt` | **Not possible on this runner.** A ConPTY is created and sends its set-up sequences, but returns no text of any child (not even `cmd /c echo`), so a typed answer cannot be given to a real prompt. A person at a console must do this one. |

- **Found by these runs, fixed with a test first:** the runner failed with `Get-AuthenticodeSignature ... the module could not be loaded` whenever the parent was PowerShell 7 (its module path leaks into Windows
  PowerShell 5.1) and now resets `PSModulePath` for its own process (`bin/gsg-gitup.ps1`); `bin/gsg-bash.cmd` names a half-installed Git for Windows; the runner stops with the new exit 19 when programs of the install directory run, before the hand-off is used up.
- **Not done:** a real UAC decline (needs a person) and the typed yes above.

## Maintainer notes

- **Bumping the Ubuntu image digest.** `IMAGE` in `tests/platform/ubuntu.sh` is the manifest-list digest. Look it up without skopeo: an anonymous
  token from `auth.docker.io/token?service=registry.docker.io&scope=repository:library/ubuntu:pull`, then
  `curl -I -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'
  https://registry-1.docker.io/v2/library/ubuntu/manifests/24.04` and read `docker-content-digest`. It equals the DIGEST column of
  `podman images --digests` and one of the two `podman image inspect --format '{{.RepoDigests}}'` entries (the other is the platform manifest,
  not the list). Then `podman pull` the new reference, change `IMAGE` and the digest in this file (`test_the_docs_state_the_platform_test_trust_decisions`
  asserts it). The Rocky image (`ROCKY_IMAGE` in `tests/platform/mac-linux.sh`, `test_the_mac_runner_uses_the_pinned_images`) is bumped the same way.
- **Bumping the PPA key fingerprint.** On 24.04 `add-apt-repository` writes `/etc/apt/sources.list.d/git-core-ubuntu-ppa-noble.sources` with the
  key inlined in an indented `Signed-By:` block (blank armor lines as ` .`) and nothing under `trusted.gpg.d`; on 22.04 it writes `git-core-ubuntu-ppa-jammy.list` and
  the key goes to `/etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg`. `gitup_apt_show_keys` (`lib/gitup_apt.sh`) feeds either to `gpg --show-keys --with-colons` in a
  scratch `GNUPGHOME` and prints field 10 of the first `fpr` record after each `pub`. To bump `GITUP_APT_PPA_FPR` (same file), read the new fingerprint the same way inside a
  container and compare it with Launchpad's page for the PPA before changing the constant. `test_real_gpg_reads_the_fingerprint_of_both_ppa_file_forms` runs the real gpg on
  both forms; the other tests use a stand-in gpg that prints the real colon format for a `STUBKEY:` marker.
- **Bumping the 22.04 and Debian images.** `IMAGE_2204` and `IMAGE_DEBIAN` in `tests/platform/ubuntu.sh` are bumped like `IMAGE` above (repository `library/ubuntu` with tag
  `22.04`, `library/debian` with tag `13`; the method reproduced the pinned 24.04 digest on 2026-11-05). The mount and `/dev` baselines (`ISOLATION_MOUNT_RULES`,
  `ISOLATION_ALLOWED_DEV`) were derived on the 24.04 image; check them on each new image before trusting a run, and add an image for each new LTS.
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
- **Container script chain.** `ubuntu.sh` (host launcher, the trust boundary) -> `ubuntu-container.sh` (root; sourceable, `main`
  runs only when executed) -> `ubuntu-e2e.sh` (`gsguser`), tested through `--dry-run` and sourced functions by `tests/test_platform.sh`
  (skipped on Darwin). Helpers there: `isolation_with`, `dev_baseline`, `ns_fixture`, `baseline_with`, `mountinfo_fixture MP[=FSTYPE]`,
  `gua_container_ppa` (`tests/test_gitup_apt_ppa.sh`). `ubuntu.sh` must never mention `--skip-isolation` (`tests/test_mac_runner.sh`). `install_git_ppa` is a
  wrapper over the product's `gitup_apt_ppa_apply`; a failed disable makes it return 2 and no source build runs (its root `apt-get install` would trust a PPA that may still be
  enabled). `--phase upgrade` (`tests/platform/apt-phase.sh`, then `apt-upgrade-e2e.sh` as `gsguser` with sudo) is the real `install --upgrade-git`; `ubuntu.sh --os`
  chooses the pinned image and passes `--expect-os ID:VERSION` for the isolation check. Rocky also installs the stock distro git, because a doctor test calls `/usr/bin/git` directly.
- **Mac runner gotchas.** `stage_checkout` runs `git init` in the copy (`tests/test_quality.sh` uses `git ls-files`); BSD `mktemp -t`
  appends a suffix; macOS bash rejects a regex repetition over 255.
- **Shell traps that bit.** `set -o pipefail` plus `sed ...q` inside `$( )` is a race (the writer gets SIGPIPE); it once turned a good
  PPA install into a silent source build. A failed redirection is reported before `2>/dev/null` applies: write
  `{ mapfile ... <"$f"; } 2>/dev/null`. bash 5.3 in the C locale reads a UTF-8 `…` after `$name` as part of the name: write `${name}…`.
- **awk portability**: `tests/test_awk_portability.sh` picks each interpreter through `awk_farm` and skips with a reason when one is absent.
- **macOS bash bootstrap.** `/bin/bash` 3.2 cannot parse the libs (`mapfile`, `declare -g`, `local -A`). `brew_cli_bootstrap` re-execs
  under a Homebrew bash 4.4 or newer; `brew_refuse_old_bash` refuses for other commands; an installed copy without `brew` reads
  `BASH_BIN` through `brew_recorded_bash` and checks it with `brew_bash_ok`. Two loop bounds: the pid-bound `GSG_BREW_BOOTSTRAPPED`
  (`test_a_recorded_bash_that_is_really_bash_3_2_is_refused_after_one_exec_not_looped`) and `GSG_BREW_REEXEC_DEPTH` at
  `BREW_REEXEC_MAX` (`test_a_recorded_bash_wrapper_that_runs_bash_as_a_child_is_refused_by_the_depth_bound_not_looped`); both need a
  real bash 3.2 and skip on Linux.
- **macOS install order** (a user decision). `brew_inspect` (`brew_find` = `type -P brew` only, never a guessed `/opt/homebrew`) and
  `install_macos_inspect` only detect; the one `brew install` (after the bash bootstrap) is in `install_macos_finish` (through
  `install_tools_ready`), after every refusable check except the staging, which follows it when no GNU `timeout` exists; `install_stage_refused` handles a stage that fails after brew ran. Every install refusal uses `brew_unchanged_text`
  (`test_every_install_refusal_wording_is_honest_after_a_brew_install`, two allow-listed exceptions); `curl_order_recorder` proves the
  download order. The hook command comes from `hook_command_text`, shared through `share_recorded_bash` and `DR_HOOK_CMD`; the hook has a
  bash 3.2 syntax guard at the top. `brew_use_gnubin` prepends the recorded `GNUBIN_DIR` for the CLI and refuses every command but
  `install`, `version` and `help` without a GNU directory
  (`test_a_command_that_needs_the_gnu_tools_refuses_when_their_directory_is_missing`); a settings file `load_settings` refuses
  prints `cannot read <file>: <reason>`, the reason sanitised and cut (`test_a_refused_settings_file_names_the_reason_on_macos`).
- **macOS git upgrade** (`lib/gitup_macos.sh`, story #32; routes `path-fix`, `brew-upgrade`, `brew-install`, state read from the file `$(brew --prefix)/bin/git`).
  *Ordering (decided):* git runs through the core's offer alone, not inside the single `brew install` of the other formulae. The offer must come first
  (the `core.hooksPath` checks, the re-verification and the PATH line need the new git) and the single install is the last step after every refusable
  check. The module's own runner `gitup_macos_brew_run` (not `brew_run_install`, whose failure line is a second refusal) records the change only in `GITUP_CHANGED`
  (`Homebrew installed|upgraded git at <prefix>/bin/git`); `brew_unchanged_text` combines it with a later `BREW_INSTALLED`, and `brew_run_install` counts
  `GITUP_CHANGED` when it says what happened before a failing formulae install. A failed git run prints brew's message and the facts; the core prints the one refusal.
  *Proven on a Mac (arm64, macOS 26.7.1, Apple Git 2.54.0, no Homebrew git):* SIP is enabled, `/usr/bin/git` carries the `restricted` flag and `touch /usr/bin/x`
  fails with `Operation not permitted` (no takeover; the module has `gitup_macos_takeover_unavailable`). `/etc/paths` and `path_helper` give
  `/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:...` with no Homebrew directory; `$(brew --prefix)/bin` is on `PATH` only through the user's profile
  (`eval "$(brew shellenv)"` in `~/.zprofile`), so the path-fix route is the normal case. `/usr/bin/git` is a shim (78 hard links, one binary) that exits at once
  (rc 1, 2 ms) when its developer directory is unusable. *Inferred, not proven here (CLT cannot be removed on this Mac):* a Mac with no Command Line Tools
  answers `git --version` through that shim by opening the install dialog and exiting 1, so it cannot hang, but it would open the dialog; GUI clients start
  with launchd's `PATH` (`launchctl getenv PATH` is empty, the default is `/usr/bin:/bin:/usr/sbin:/sbin`) and so keep running Apple Git. *Guard:* `brew_git_shim_unusable` (lib/brew.sh) never
  runs the system directory's `git` on macOS when its `xcode-select -p` (no dialog) reports no developer directory; that git counts as unknown version
  (`test_a_mac_without_developer_tools_never_runs_the_git_shim_and_still_shows_the_offer` uses a shim that records and sleeps). No version probe has a timeout of its own. The macOS prompt test (`gu_pty_bsd`) uses the BSD `/usr/bin/script`, since Homebrew's util-linux ships no `script` (probed), and feeds the answer after a lead with stdin held open (BSD `script` sends EOF first when stdin ends at once).
- **BSD differences that shaped code**: no `realpath -m`, `mktemp --suffix`, `mv -T`, `stat -c`, `env --default-signal`; `install -T`
  means tags; `chmod 700 -- DIR` fails; `find` lacks `-printf`/`-readable`/`-executable` (sizes via `install_entry_sizes`; never
  `find -ls`: `test_the_backup_bounds_do_not_depend_on_the_owner_columns_of_find_ls`); `wc -l` pads.
- **Mac test harness.** `tests/lib.sh` picks per-OS `TEST_BASE_PATH`, `TEST_BASH`, `TEST_GNUBIN`, `TEST_TRUE` and the cached scanners;
  `lc_begin` fakes a Linux `uname`, and `tests/test_macos.sh` uses `lc_real_uname`/`as_macos`. A test that replaces `PATH` must keep
  `$SANDBOX/pathbin`, or the real `brew` is reachable. `FILE_SKIP_REASON` skips a whole file with a reason.
- **Windows: three path forms.** bash and `find` say `/c/dir`; native git, curl and tar want or answer `C:/dir`; `cmd` wants
  `C:\dir`. Compare and display in one form: every check that treats a path as absolute with `/*` is wrong for what native git
  prints. Found that way: `doctor_origin_text` (`file:C:/...` taken as relative made a finding repeat per worktree),
  `install_resolve_hooks_dir` (`--type=path` output called relative, so `--replace-hooks-path` refused every value) and
  `doctor_resolves_here`. `cygpath -m -l` gives git's long form; plain `-m` keeps `ADMINI~1`.
- **Windows: stopping processes.** No process groups, and MSYS `exec` keeps the MSYS pid while replacing the Windows process
  (details in docs/scan.md#maintainer-notes). Tests: `test_windows_only_an_interrupted_scan_leaves_no_native_process_and_no_work_dir`
  proves it with `PING.EXE`.
- **Windows: slow process starts change timing logic.** Each lock attempt starts a few processes, so 300 attempts outlast
  `GSG_FINDINGS_LOCK_MAX_AGE_MIN` and a live holder's lock was broken at 60 s instead of refused. The wait is bounded in
  seconds there (`GSG_FINDINGS_LOCK_WAIT_SECONDS_WINDOWS`, 45): fewer attempts made a queued run give up under load, an
  intermittent failure of `test_concurrent_runs_over_different_roots_keep_both_sets`. A holder in a test must outlive the whole wait.
- **Windows: a running script pins its directory.** Windows refuses to rename the share dir while `bin/git-secret-guard` runs
  from it, so `install_copy_share` rewrites only the generated files when `GSG_ROOT` is the share dir.
- **Windows: XDG variables.** Native git hands the hook `XDG_*` as `C:/dir` and only `HOME`, `PATH` and `TMP` are turned back;
  `gsg_posix_path` normalises them for `state_dir_path` and `paths_init`, which also accepts a `C:\dir` a Windows user typed.
- **Windows: `ln -s`** refuses a missing target and copies an existing one unless `MSYS=winsymlinks:sys`; native git cannot read
  those links, so a symlink fixture feeds nothing to git (skip list). The test process exports the variable, `GSG_ENV`
  deliberately does not, so the product cannot lean on it.
- **Windows: the work dir ignores a `TMPDIR` outside `HOME`** (NTFS ignores `chmod`, the profile ACL keeps staged lines private).
  Tests look at `TEST_WORK_BASE`, never `$SANDBOX/tmp`; an `includeIf` aimed at the wrong one silently sabotages nothing, and a
  fail-closed test goes green or red for the wrong reason.
- **Windows: batch files.** `cmd` re-reads a batch file line by line, so a file deleted while it runs ends in `The batch file
  cannot be found`, also with `call`. The installed `.cmd` therefore deletes itself after bash returns, with
  `(goto) 2>nul & del "%~f0"`, once the share dir is gone (`GSG_CMD_ENTRY` tells uninstall to leave it). The checkout's `.cmd`
  files are never deleted and use plain `exit /b %errorlevel%`. `!errorlevel!` after a same-line `setlocal EnableDelayedExpansion`
  does not work. Use `bin\bash.exe`, which sets up `PATH`; `usr\bin\bash.exe` does not. PowerShell finds `git-secret-guard.cmd`
  before the extensionless wrapper through `PATHEXT`.
- **Windows: test-side quirks.** MSYS `[ -e x ]` is true when only `x.exe` exists: assert on a listing. `NUL` is a reserved
  name, so a file called `nul.txt` cannot exist. Native curl needs `file:///C:/...` (`lc_fixture_url`). The betterleaks asset is a
  `.zip` (`lc_asset_name`); appending to a guessed `.tar.gz` tampers with nothing and the test then "fails" for the wrong
  reason. Inspect a failing fail-closed test before skipping it. `tests/test_windows.sh` fakes `uname` around the real libs so the
  Windows branches are also tested on Linux and macOS; `tests/windows-skips.list` names the tests that cannot apply, with reasons.
- **WSL internals.** `lib/wsl.sh` (CLI-only, loaded before `gitup`): `wsl_is`, `wsl_version` (REPLY 1 when the raw kernel text holds `Microsoft` with a capital M, else 2: real WSL 2 kernels exist without a `WSL2`
  suffix, such as `4.19.128-microsoft-standard`), `wsl_systemd_running`, `wsl_check_timer` (called by `install_precheck_timer`), `wsl_announce_overrides` (only when an override makes the run a WSL run, so a plain
  fixture adds nothing to stderr), `install_pins_running_script` and `install_wsl_notice`. The last one finds `git.exe` with `install_find_bin` of `lib/install.sh`, the one place that may call `type -P`.
  The test harness (`sandbox_create` in `tests/lib.sh`) points the three seams at a plain kernel for every test file, so no result depends on the kernel of the machine running the suite; `tests/test_wsl.sh` sets its own.
  `gitup_os_class` returns `wsl` only for an rpm, ubuntu or debian family; the wrapper module `lib/gitup_wsl.sh` sets `GITUP_INNER_CLASS` and delegates with `gitup_delegate`; the apt module reads
  `gitup_inner_class` where it used to read `GITUP_CLASS`. The wrapper defines all five takeover functions (the set is all or none) and answers "not supported" for an inner module without them.
  Tests: `tests/test_wsl.sh` (fixture kernel files, faked `uname`, a synthetic inner module in a copy of the tree, so no apt stand-in and no `setsid` are needed and it runs on Git for Windows).
