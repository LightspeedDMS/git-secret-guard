# Supported platforms

| Platform | Status |
|---|---|
| RHEL 9-compatible (x86_64) | Supported. RHEL 9-compatible (tested on Rocky Linux 9.7); there `/usr/local/bin/git` is built from source and `/usr/bin/git` 2.52 is left alone. |
| Ubuntu 24.04 LTS | Supported. The whole suite and an install E2E with real downloads run in a podman `ubuntu:24.04` container, as a non-root user, with mawk as the default awk: `tests/platform/ubuntu.sh`. `install` offers the git upgrade: see [Ubuntu and Debian (apt)](#ubuntu-and-debian-apt). |
| Ubuntu 22.04 LTS and Debian 13 | Offer tested against stand-ins (2.34.1 on 22.04 takes the PPA in its older `.list` form, Debian takes the source build) and, with real apt, in debootstrap chroots (22.04, 24.04, Debian 13, 20.04). Both ran in podman containers on hosted x86_64 runners ([CI record](platform-testing.md#results)): the `--phase upgrade` E2E (22.04 PPA route in the `.list` form, 28/0; Debian 13 source route, 21/0) and the default phases (install E2E 31/0, whole suite 1108 passed, 0 failed). Debian 13's upgrade E2E also ran on an arm64 Mac ([details](#ubuntu-and-debian-apt)). |
| macOS arm64 (tested on macOS 26.7.1) | Supported, with Homebrew: see [macOS (Homebrew)](#macos-homebrew). The whole suite and an install E2E in a scratch home run on a real Mac, and the whole suite runs on every pull request on a GitHub-hosted Mac: see [CI on a hosted Mac](platform-testing.md#ci-on-a-hosted-mac). |
| Windows x86_64 (tested on Windows Server 2019) | Supported with Git for Windows: see [Windows (Git for Windows)](#windows-git-for-windows). No weekly timer. The whole suite runs there (CI job `windows-suite`); a test that cannot apply on Windows is reported as skipped with its reason (most are named in `tests/windows-skips.list`): see [The test suite on Windows](platform-testing.md#the-test-suite-on-windows). |
| WSL (Ubuntu, Debian, RPM distributions) | Implemented, fixture-tested, and run for real on hosted WSL 1 and WSL 2: Ubuntu 22.04 and 24.04 on both, Rocky 9.8 and Fedora 44 on WSL 2 only (the vendor images cannot be imported on WSL 1), a typed yes and No, a `metadata` mount; see [WSL](#wsl-windows-subsystem-for-linux). WSL 1 on Windows Server 2019 blue-screened the maintainer's host twice in its own driver; the cause is not established. |
| macOS x86_64 (Intel; tested on macOS 12.7.6) | Supported, with Homebrew set up by hand: see [Homebrew on an Intel Mac](#homebrew-on-an-intel-mac) (the Command Line Tools and Homebrew are the user's to install, and every formula builds from source there, about an hour and a half for bash, coreutils, util-linux, jq and git together). The `darwin_amd64` / `darwin_x64` rows of `tools.lock` are used. The tested setup and the suite result are in that section. macOS 12 has no `realpath`: the hook and the CLI find their own location without it (#157, see [the maintainer notes](#maintainer-notes)), and the SmartGit Git LFS check models the `PATH` SmartGit gives git on an Intel Mac with `/usr/local/bin` added (modelled, not measured at runtime; #158, [smartgit.md](smartgit.md#maintainer-notes-the-macos-spike-smartgit-261)). |
| Other Linux | Not tested. `install` names what is missing and falls back to generic advice when `/etc/os-release` is not Ubuntu or Debian. |

## RHEL, Rocky and Fedora (RPM)

`dnf` systems (the `rpm` class: `ID` or `ID_LIKE` names `rhel`, `fedora`, `centos`, `rocky` or `almalinux`) get a git upgrade from `install`.
Config hooks need git 2.54 or newer, and RHEL 9 ships 2.52. `git-secret-guard install` refuses an older git as before, and now **offers
the upgrade**; it never prompts without a terminal, and the default answer is No:

```bash
git-secret-guard install --upgrade-git        # consent up front (also the way to say yes with no terminal)
git-secret-guard install                      # in a terminal: prints the plan, asks "Upgrade git now with the plan above? [y/N]"
```

Every refusable check a git can run (jq, setsid, timeout, the global git config being writable, the state file, `core.hooksPath`, the CLI link, and with `--with-timer` the systemd timer checks) runs
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
`GSG_GITUP_QUERY_TIMEOUT`), and `--assumeno` answers every prompt, a GPG key import included, with no. The query runs as your user, not as root. A third-party repository that fails for the user while it works for root (the `acli` repository on the reference host; the reason is not established, a key held per user is the likely one) makes the whole query fail; install then asks each enabled
repository alone (as the user, never root: no privileged command runs before consent), **names the ones that fail** as "could not be read by this unprivileged query" (a repository that works for root can fail there, so it is not called broken), shows
the first `Error:` line dnf wrote after that sentence and none of its key-import text, and imports nothing. dnf's output is kept in a variable, never in a file, and runs under `LC_ALL=C`.
**The route follows the repositories that were read.** If one of them offers git-core >= 2.54 and the check was complete, the route is `package`, and the root command is an allow list: `dnf install|upgrade -y --disablerepo=* --enablerepo=<id> ... git-core`, one `--enablerepo` per repository the plan read (from the user's `dnf repolist --enabled`, one more unprivileged call under the same timeout, with stdin from `/dev/null` and `LC_ALL=C`; ids are validated and `*` is one argument, never expanded by a shell). The plan prints that same command and says that only the repositories read are enabled. This fails closed on purpose: dnf 4.14 (`dnf/conf/read.py`) catches the error for a `.repo` file the user cannot read (mode 0600, often because it holds credentials), logs a warning and skips it, so such a repository is absent from the user's list, is never queried and never named, yet root's dnf would still use it and `-y` could import its key and install a git-core the plan never showed. A deny list (`--disablerepo=<failed>`) cannot cover what the plan never saw. The price: a dependency of git-core that lives only in a repository the user could not read makes dnf fail instead of installing it. If the readable repositories offer only an older git-core, the route is `source`, the reason says what they offer, and the plan still names the unread ones as not considered. The check is incomplete when the repository list could not be read or is empty, the retry budget was used up, or the whole query failed with no repository named (every such line is parenthesised, or no repository could be read at all); the route is then `source`. The source route's dependency install stays an open `dnf install -y` of build packages, so its note says plainly that a pending key can be imported; the two routes differ because the package route installs a package from a repository the plan names, and the source route installs build tools from whatever the system trusts.
That per-repository retry has a total budget (twice the query timeout); repositories beyond it are not tried and the plan says so.

**The privileged `dnf install -y` is different.** `-y` answers yes to every prompt, a repository GPG key import included (read from dnf's
`cli/output.py`, `CliKeyImport._confirm`, which returns true under `assumeyes`; not run). A key that is pending for a configured repository would
therefore be imported by that step, on the package route and on the source route (the dependency install), and the plan says so before asking.
Root runs the `dnf` found only in the fixed system path (`/usr/bin:/bin:/usr/sbin:/sbin`), never the one first on your `PATH`; it must be a root-owned file that
group and others cannot write, and the plan prints its full path (`as root: /usr/bin/dnf install -y ...`). `sudo` and `restorecon` are found the same way
(`restorecon` lives in `/usr/sbin`, which is why the sbin directories are in the list). The build keeps its own `PATH` of `/usr/bin:/bin`.

**The source route** follows the procedure that worked on the reference host, in this order:

1. Check the free space (at least 800 MB free in the build directory, because the build itself uses about 570 MB, and at least 300 MB free for `/usr/local`) before anything changes.
2. Download `git-<version>.tar.xz` and `git-manpages-<version>.tar.xz` from kernel.org and check both SHA-256 digests against `tools.lock`
   (`git` and `git-manpages`, platform `source`). A mismatch stops here with the machine untouched. (The story listed the dependency install
   first; the downloads come first because a tampered tarball then changes nothing.)
3. As root: `dnf install -y` with the names among `gcc make perl-interpreter xz tar openssl-devel zlib-devel libcurl-devel expat-devel pcre2-devel perl-ExtUtils-MakeMaker` that `rpm -q` does not know (none installed means no such step). `perl-interpreter`, not the `perl` metapackage, which pulled 141 packages on a host where the build only needs the interpreter and the modules named. A host with only `perl-interpreter` may lack the Perl modules that `git send-email` and similar scripts load at run time (the build itself passed without them); this is a behaviour change from `perl`, and `dnf install perl` adds them. **`dnf install -y` can still upgrade installed packages** when a missing name needs a newer build of one, and it cannot always be undone (an older build may no longer be in the repositories). The plan says so, with the counts of `dnf --assumeno install` of the missing names (no `-q`: dnf 4 hides its table under it). dnf 4 refuses that dry run to a user who is not root, and the plan then names that as the reason it did not count; a timeout is named as a timeout. The plan is computed once; the root commands that run are the ones it printed.
4. As the invoking user, in a `mktemp` directory, under `env -i PATH=/usr/bin:/bin` with a scratch `HOME` and `TMPDIR`:
   `make prefix=/usr/local NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 USE_LIBPCRE2=1 sysconfdir=/etc INSTALL_SYMLINKS=1 all`, then the same with `DESTDIR=<stage> install` (INSTALL_SYMLINKS=1 makes git install its siblings as symlinks, see [CI on real platforms](platform-testing.md#rocky-vm-selinux-enforcing); `sysconfdir=/etc` makes the new git read `/etc/gitconfig`, as the distribution's git does, see [a build made before 0.2.2](#a-source-build-made-before-022); the plan prints these words); the man pages
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

#### A source build made before 0.2.2

Builds made by git-secret-guard before 0.2.2 got no `sysconfdir`, and git's default is `$(prefix)/etc`, so that `/usr/local/bin/git` reads
`/usr/local/etc/gitconfig` and silently ignores `/etc/gitconfig` (measured on Debian 13: the `filter.lfs.*` settings the git-lfs package keeps there
were invisible to it; [#90](https://github.com/LightspeedDMS/git-secret-guard/issues/90)). With the RPM takeover that build is also `/usr/bin/git`.
A rerun of `install` does not rebuild a git already at the pinned version; the next pinned git is built with `sysconfdir=/etc`. Until then, point the
old build at the distribution's file (this writes nothing when `/usr/local/etc/gitconfig` already exists):

```bash
sudo mkdir -p /usr/local/etc && sudo test ! -e /usr/local/etc/gitconfig \
  && printf '[include]\n\tpath = /etc/gitconfig\n' | sudo tee /usr/local/etc/gitconfig >/dev/null
/usr/local/bin/git config --system --includes --list    # shows the settings of /etc/gitconfig
```

Normal git commands follow the include; `git config --system` alone does not, hence `--includes` in the check. Delete the file once a rebuild with
`sysconfdir=/etc` has happened (`/usr/local/bin/git var GIT_CONFIG_SYSTEM` then prints `/etc/gitconfig`).

The package-owned git in `/usr/bin` is **not touched** by any of this: `rpm -q git-core` reports the same version and `rpm -V git-core`
reports nothing. `/usr/local/bin/git` comes first on `PATH` in a login shell, under `sudo` and in the systemd manager, **not** in cron
(`/etc/crontab` sets `PATH=/sbin:/bin:/usr/sbin:/usr/bin`; a job in `/etc/cron.d` logged `PATH=/usr/bin:/bin` on the reference host; either way there is no `/usr/local/bin`): a script that calls `/usr/bin/git` by its full path is not scanned, and `install`
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
- **Not run on the reference host:** the takeover and the Rocky E2E. SELinux (labels, `restorecon`, `sshd` serving `git-upload-pack` through the taken-over path) is covered by the enforcing Rocky VM job, see [CI on real platforms](platform-testing.md#rocky-vm-selinux-enforcing).

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

**In that run, not run:** the Ubuntu 22.04 container (`--os` cannot be forwarded through `mac-linux.sh`) and any x86_64 container; both ran in CI on hosted x86_64 runners ([CI record](platform-testing.md#results)). Earlier real-apt chroot runs (22.04, 24.04, Debian 13, 20.04) covered the file forms.

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
  && make -j"$(nproc)" prefix=/usr/local sysconfdir=/etc NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 all \
  && sudo make prefix=/usr/local sysconfdir=/etc NO_RUST=1 NO_TCLTK=1 NO_GETTEXT=1 install     # /usr/local/bin must come before /usr/bin on PATH
```

Then `git clone <this repository> && cd git-secret-guard && bin/git-secret-guard install` works as on RHEL. `install` names the missing
prerequisite with its fix, always before it changes anything: git (the offer above on Ubuntu, Debian and their derivatives, with the manual PPA command as the second line, generic text elsewhere), `jq` (`sudo apt install jq`), `setsid` (`util-linux`), `timeout` (`coreutils`), `curl`, and
`systemctl` for `--with-timer` (`systemd`; on macOS `launchctl` instead, which ships with the system). It checks all of them first and names **every** missing one with its fix in a single refusal
(with the count when there are several), so one run is enough to see everything to install. The distribution is read from `/etc/os-release`
as data (never sourced); a missing or unreadable file gives the generic hint and no shell error.

## macOS (Homebrew)

Tested on macOS 26.7.1, arm64, with Apple Git 2.54.0 (it meets the git >= 2.54 floor and honours `hook.<name>.command`; it has no
`hook.<event>.enabled`, so a repository switching the whole `pre-commit` event off that way is not visible to it either). Intel Macs
(x86_64) map to the `darwin_amd64` and `darwin_x64` rows of `tools.lock` and were tested on macOS 12.7.6: see
[Homebrew on an Intel Mac](#homebrew-on-an-intel-mac). Homebrew is required on macOS and
nowhere else; Linux behaviour, prerequisites and hints are unchanged. `install` never installs Homebrew or the Command Line Tools; it names
what is missing and installs the rest.

```bash
git clone <this repository> && cd git-secret-guard
bin/git-secret-guard install        # lists what is missing, installs it with brew after the other checks pass, then installs as on Linux
```

- **What `install` asks of Homebrew.** It finds `brew` on `PATH` (without it: refusal with `https://brew.sh`, nothing changed; on an Intel Mac
  the same line also says `on an Intel Mac Homebrew's installer may refuse to run: see "Homebrew on an Intel Mac" in docs/platforms.md for the
  manual steps`, because that installer refused one: [Homebrew on an Intel Mac](#homebrew-on-an-intel-mac)), then
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
- **No Command Line Tools: refused before the git offer.** When the git in use is `/usr/bin/git` and `xcode-select -p` reports no developer
  directory, that git is the shim that opens an install dialog (it is never run). `install` refuses at once, with or without `--upgrade-git`, and
  does not show the git upgrade: `/usr/bin/git is the Command Line Tools shim and there are no Command Line Tools on this Mac (xcode-select -p
  failed); install them with: xcode-select --install (Homebrew needs them too), then run install again; nothing was changed`. Homebrew needs
  the Command Line Tools to install or build git, so `brew install git` could not work there. The other prerequisite checks still run and are reported with it.
- **A source-build notice on Intel.** Before three installs (the bootstrap's `brew install bash`, the prerequisite install, and the git
  upgrade's `brew install git` or `brew upgrade git`; not the Git LFS install of the SmartGit commands) an Intel Mac (`uname -m` is `x86_64`) prints one line: `on an Intel Mac Homebrew may build these
  formulae from source (no bottles); this can take an hour or more`. Only the CPU decides, no bottle is looked up; brew's own output follows
  it, and there is no timeout around the build. Apple Silicon prints nothing.
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
  [the launchd section of the doctor chapter](doctor.md#the-weekly-timer-on-macos-launchd)). `doctor` and `status` check `BASH_BIN`
  (executable, bash 4.4 or newer) and, when a timer is recorded, `LAUNCHCTL_BIN`, like the other recorded tools. `status` also checks
  `GNUBIN_DIR` (when set, an absolute existing directory, the rule the hook blocks on). The `bash:` and `launchctl:` lines of `status` exist on
  macOS only, whatever the settings hold elsewhere; `GNUBIN_DIR:` is checked on every platform whenever the key is set, because the hook blocks
  on it on every platform (unset prints nothing).
- **What a commit does with a broken `BASH_BIN`.** Observed with git 2.56 through the fake-uname harness (`tests/platform/test_macos.sh`), **not on a
  real Mac**. The hook command is `'<BASH_BIN>' '<share>/hooks/secret-scan'`, and git runs it through `sh`. Each claim names its test, and in each
  case `status` exits 1.
  - `BASH_BIN` missing, a file without the executable bit, or a directory: the shell prints `<BASH_BIN>: No such file or directory`,
    `Permission denied` or `Is a directory`, the hook never starts and the commit fails (exit 1, no commit made). A program that is no bash and
    exits 3 also fails the commit, with no message. A program that is no bash and exits 0 starts nothing: git counts the hook as passed and the
    commit **lands unscanned**, with no message
    (`test_a_commit_with_a_recorded_bash_that_cannot_run_fails_and_one_that_is_no_bash_passes_unscanned`).
  - `BASH_BIN` relative, or unset (the hook command is then the bare hook path): the hook still starts, under the bash `PATH` or the shebang finds,
    and ran on to the scanners here because that bash is 5.x. Under a bash 3.2 first on `PATH` the hook's version check blocks every commit (read
    in `hooks/secret-scan`, not run: no bash 3.2 was available)
    (`test_status_on_macos_exits_1_when_the_recorded_bash_is_not_an_executable_bash_4_4`).
  - A relative `GNUBIN_DIR` is the hook's own block, `GNUBIN_DIR in the settings file is not an absolute directory (...); nothing was scanned`
    (`test_status_on_macos_exits_1_when_gnubin_dir_is_not_an_absolute_directory`).
- **GNU flags and their answers.** `realpath -m`, `mktemp --suffix`, `mv -T`/`-n`, `install -T`, `chmod 700 -- DIR` and `sort -z` run from
  the GNU directory. `find -printf` (backup bounds) stays where `find` has it (Linux) and is `find -print0 | xargs stat` elsewhere (GNU or BSD `stat` format chosen by a probe);
  `find -ls` was tried and dropped, because an owner or group name with a space moves its size column;
  `find -readable`/`-executable` (doctor's unreadable directories) became `[ -r ]` and `[ -x ]` on the directories `find` lists; BSD `wc`
  pads its count with spaces, so the report line strips them. `cp -a`, `tar --no-same-owner`, `sed 's/\x1b...//'` and `find -quit` behave
  as on Linux with the BSD tools.
- **awk.** macOS `/usr/bin/awk` (one-true-awk 20200816) gives the expected results for `lib/scan/extract.awk`, every malformed diff and the
  inline programs: `tests/scan/test_awk_portability.sh` runs them under it (named `bwk`) next to the gawk and mawk cases.
- **Running the suite on a Mac.** `tests/run.sh` puts the Homebrew bash and the GNU directory first on `PATH` itself. The real-scanner
  suites use the pinned binaries: `tests/fetch-test-tools.sh` downloads them (SHA-256 checked against `tools.lock`) into
  `~/.cache/git-secret-guard-test-tools`, never into `~/.local/bin`. The brew steps are tested with a recording `brew` stand-in and a
  fake prefix (never a real `brew install`); the Linux-behaviour lifecycle suites run on a Mac under a fake Linux `uname`. Explained
  skips: the podman suite (`test_platform.sh`: Linux only), systemd tests (no `systemctl`), `hook.<event>.enabled` (Apple Git has no
  such key), the gawk and mawk cases when those awks are not installed. The `hook.pre-commit.enabled` halves of `test_status` and
  `test_doctor` run only when `git_enabled_sections` (`tests/support/lib.sh`) finds that the git under test lists the hook as `event-disabled`
  (a probe of behaviour, not of the version); the `hook.git-secret-guard.enabled` halves always run. A Mac whose only git is Apple Git
  2.54.0 passes both files this way (#76). `test_status_names_the_git_in_use_and_its_version` strips the ` (Apple Git-N)` suffix, as `install_git_version` does.

### Homebrew on an Intel Mac

`install` never installs the Command Line Tools or Homebrew: both are yours to set up, and everything else (bash, coreutils, util-linux, jq, git,
the scanners) `install` installs itself. On an Intel Mac two of the usual steps fail, so this is what a maintainer did by hand on a Mac with
macOS 12.7.6 (all values observed there; adapt the user name `<user>`):

**Step 1, the Command Line Tools, headless** (no dialog; `xcode-select --install` opens one and is the normal way on a Mac you sit at). Without
them `/usr/bin/git` is only a shim and `xcode-select -p` fails:

```bash
sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
softwareupdate -l                      # find the label, "Command Line Tools for Xcode-<version>"
sudo softwareupdate -i "<label>"
sudo rm /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
xcode-select -p                        # /Library/Developer/CommandLineTools
```

**Step 2, Homebrew by hand.** Homebrew's official `install.sh` (from https://brew.sh) aborted on this Mac with "only supported on Apple Silicon
processors". A clone of Homebrew into `/usr/local/Homebrew`, linked into `/usr/local/bin`, worked:

```bash
sudo mkdir -p /usr/local/Homebrew && sudo chown <user>:admin /usr/local/Homebrew
git clone --depth 1 https://github.com/Homebrew/brew /usr/local/Homebrew
ln -sf /usr/local/Homebrew/bin/brew /usr/local/bin/brew
```

**Step 3, the `/usr/local` directories owned by you.** Without them `brew` failed with "Failed to install Homebrew Portable Ruby (and your
system version is too old)". Create each of `var etc include lib opt sbin share Cellar Caskroom Frameworks` under `/usr/local` when missing and
give it to your user (`sudo chown -R <user>:admin /usr/local/<name>`); `/usr/local/Homebrew` and `/usr/local/bin` too.

**Step 4, PATH.** A non-login shell (an `ssh host command`, a GUI client, `env -i`) has `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so `brew` is not
found and `install` refuses with "Homebrew (brew) was not found on PATH". A login zsh has `/usr/local/bin` first. In a non-login shell run
`eval "$(/usr/local/bin/brew shellenv)"` first. `install` never edits a shell profile.

**Source builds.** Homebrew calls macOS 12 on Intel "a Tier 3 configuration": there are no bottles and every formula builds from source (use
`HOMEBREW_NO_ANALYTICS=1`). Times on that Mac (12 GB, x86_64), each with its dependencies: bash about 58 minutes
(`gettext`, `cmake` and `libunistring` take most of it), coreutils about 26, util-linux about 2, jq about 1, git about 1 (3 with its
dependencies, through `install --upgrade-git`); the five together took about an hour and a half. `install` prints a notice before its
three kinds of `brew install` (see above) and does not time them out; Ctrl-C stops the build (exit 130) and Homebrew may have installed part of
it (see `brew list`).

**The tested setup.** macOS 12.7.6 (21H1320), x86_64; Homebrew 7.0.14 at `/usr/local` (the clone above); formulae bash 5.3.20, coreutils 9.12,
util-linux 2.42.4, jq 1.8.2, git 2.56.1; Apple Git 2.37.1 as `/usr/bin/git`; scanners trufflehog 3.99.2 and betterleaks 1.9.0 (the
`darwin_amd64` and `darwin_x64` rows of `tools.lock`). When this setup was recorded, every GUI and SmartGit commit was blocked by #157 (macOS 12 has no `realpath`; `hooks/secret-scan`) and SmartGit's launch `PATH` lacked `/usr/local/bin` (#158); commits from a terminal worked. Both are fixed since (see the table above). Run the suite there as [CONTRIBUTING.md](../CONTRIBUTING.md#running-the-tests) says.
Suite at this story's commit (294b38d, before the #157 fix): `SUMMARY: 1454 passed, 35 failed, 430 skipped (total 1919)`; all 35 failures are #157 (`test_smartgit` 27, `test_macos` 6, `test_hook` 1, `test_ui_restore` 1).

## Windows (Git for Windows)

Install [Git for Windows](https://git-scm.com/download/win), then, from PowerShell or cmd:

```powershell
git clone <this repository>
cd git-secret-guard
bin\git-secret-guard.cmd install    # downloads what is missing
git-secret-guard status             # in a new terminal, once %USERPROFILE%\.local\bin is on PATH
```

Git Bash works the same way with `bin/git-secret-guard install`. Commits are scanned from any shell and from GUI clients
that run a git 2.54 or newer, because the hook lives in the global git config.

- **GUI clients with their own git.** SmartGit 26.1 bundles git 2.53.0, so its commits are not scanned until it is
  pointed at Git for Windows: `install --configure-smartgit` does that (it writes the `cmd\git.exe` of that Git for Windows, by default `C:\Program Files\Git\cmd\git.exe`; see
  [smartgit.md](smartgit.md#windows)). The portable SmartGit archive is not detected and is set by hand. `status` and
  `doctor` report each SmartGit settings directory they find.

- **Prerequisites.** Git for Windows with git 2.54 or newer (an older one is upgraded with `install --upgrade-git`, see below) on x86_64. `taskkill`,
  `timeout`, `curl`, `sha256sum` and the System32 `tar.exe` come with Windows or Git for Windows. `~/.local/bin` should be
  on `PATH` for the `git-secret-guard` command.
- **jq is handled by `install`.** With no `jq` on `PATH`, `install` downloads the pinned `jq.exe` from the jqlang release,
  checks its SHA-256 against `tools.lock`, and places it in `~/.local/bin` beside the scanners. No package manager is
  needed (the Windows Server 2019 test host has no winget). It follows the scanner rules: all downloads are verified before anything
  changes, a rerun keeps it, a pin bump replaces it, and `uninstall --remove-tools` removes it. A `jq` you already have on
  `PATH` is used as it is and never recorded as ours. The one exception is the file `uninstall` left behind: a regular file (not a link) at
  `~/.local/bin/jq.exe` whose SHA-256 equals the `tools.lock` pin is taken as install's own on the next `install`, when it is the `jq`
  found on `PATH` or no `jq` is found at all (a `~/.local/bin` that is not on `PATH`); a `jq` found elsewhere on `PATH` keeps it yours. It is
  recorded (`jq:<sha256>` in `tools_placed`, and in `tools_installed_by_us`), so a pin bump replaces it in place and `--remove-tools` removes
  it. The test is the hash alone: a byte-identical copy of the pinned jq that you put there yourself counts as ours and is removed by
  `--remove-tools`. A file at that path with any other hash is never recorded or removed; when no `jq` is on `PATH` and it is not at the
  pinned version, it is moved aside and `uninstall` puts it back, as for the scanners (bug [#97](https://github.com/LightspeedDMS/git-secret-guard/issues/97)).
  The scanners follow the same hash rule since [#101](https://github.com/LightspeedDMS/git-secret-guard/issues/101), with the SHA-256 of the extracted
  `trufflehog.exe` or `betterleaks.exe` taken from the fifth column of their `tools.lock` rows, and without the `PATH` condition
  ([install.md](install.md#uninstall)).
- **`git` in PowerShell.** The Git for Windows installer normally puts `git` on `PATH`. If `git` is not found there, re-run
  it and choose "Git from the command line", or add `C:\Program Files\Git\cmd` to `PATH`. `git-secret-guard.cmd` finds Git
  for Windows either way, next to `git.exe` or in its default locations, and never uses the WSL `bash.exe` in `System32`.
- **File names.** The scanners and jq keep their `.exe` names. `~/.local/bin/git-secret-guard` is a small wrapper script,
  not a symlink, and `git-secret-guard.cmd` next to it serves PowerShell and cmd. `uninstall` removes both. `JQ_BIN` names a wrapper in the share dir adding `-b`,
  because a native `jq.exe` otherwise writes CRLF.
- **Weekly doctor.** `--with-timer` needs systemd or launchd. Use [Task Scheduler](doctor.md#a-weekly-run-on-windows-task-scheduler).
- **Auto-update.** `install --auto-update` registers an hourly Task Scheduler task of your own user (`git-secret-guard-update`) that runs while you are logged on; the
  interval knob of the tests is ignored there. Details: [Auto-update on Windows](install.md#auto-update-on-windows).
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

When the git on `PATH` is older than 2.54, `install` offers to upgrade Git for Windows (story 30, the `windows` module in `lib/gitup/gitup_windows.sh`). The consent rules are those of
[the other platforms](install.md#upgrading-an-old-git---upgrade-git-and---take-over-system-git): a prompt in a terminal (default No), or `--upgrade-git`; with no terminal and no flag
`install` refuses, names `--upgrade-git` and changes nothing.

```powershell
bin\git-secret-guard.cmd install --upgrade-git
```

- **Route.** winget when it is on `PATH`, otherwise the pinned installer. The Windows Server 2019 test host has no winget, so it took the installer route. The installer is `Git-2.56.0.4-64-bit.exe` of the
  release `v2.56.0.windows.4` of git-for-windows/git, pinned in `tools.lock` (row `git-for-windows`, not a scanner) with its SHA-256. `install` downloads it over HTTPS, checks the
  digest and removes a file that differs. The winget route was run for real on a windows-2025 runner (see [CI on real platforms](platform-testing.md#ci-on-real-platforms)): it ran with `--scope machine`, winget checked the installer hash itself and git was upgraded (whether the scope was kept was not asserted by that scenario); the Windows Server 2019 host has none. The runner passes
  `--scope machine` or `--scope user` as planned and the plan says the rest is not tested.
- **Why the hand-off.** The upgrade replaces the `bash.exe` that `install` runs in, so bash only decides, plans, downloads and verifies. `lib/gitup/gitup_windows.sh` writes a hand-off file
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
- **What the tests run on the Windows host:** `tests/gitup/test_gitup_windows.sh` (its safety nets, the path guards, the never-start guards and the certificate hygiene, are in `tests/gitup/test_gitup_windows_safety.sh`) drives the module with registry, `whoami` and `winget` stand-ins (the sandbox stands for System32 through
  `GSG_GITUP_ROOT`), the runner with Windows PowerShell and a compiled stand-in installer carrying a throw-away signature, `git-secret-guard.cmd` (checkout and installed copy) with real
  `cmd.exe`, and the real `bin/git-secret-guard install --upgrade-git` with a fake old git. The module logic also runs on Linux through a faked `uname`; the runner and `.cmd` tests skip there.
  The runner reads no variable for its checks: tests run a sandbox copy of it with its own `tools.lock` (and its signer line), changed in one line for the untrusted test signature and for the elevation check,
  and wrap `Start-Process` to record, hold, fail or skip the start. The self-signed test signer is built once into the tools cache and its key and store copies are deleted. No test starts
  a real Git for Windows installer or winget.

## WSL (Windows Subsystem for Linux)

> **WSL 1 warning.** On the maintainer's Windows Server 2019 machine (build 17763, `lxcore.sys` 10.0.17763.2268) WSL 1 blue-screened the host twice, both
> times in its own driver (bugcheck `0x3B`, `LXCORE.SYS+0xa223c`, stack through `Wof.sys` and `FLTMGR.SYS`). The first came under heavy load, the second about two
> minutes after a plain `wsl.exe -d Ubuntu -- git --version` with no tests running. The first crash came in the same minute that a script renaming the directory of a running script was written (it may or may not have run); the rename probe of the workflow is that same kind of operation, so it runs last. **The cause is not established.** It is not known that git-secret-guard caused
> it, and not known that it did not. Do not run installs or the test suite in WSL 1 on a machine that must not crash; the real WSL checks run on a disposable
> GitHub runner (see [WSL test runs](platform-testing.md#wsl-test-runs)), never on that machine.

WSL support is implemented for Ubuntu, Debian and RPM-family distributions. Hosted run coverage and the known limits are in [WSL test runs](platform-testing.md#wsl-test-runs).
WSL runs a real Linux distribution, so `install` takes the Linux path and the distribution's own git route: Ubuntu and Debian follow
[the apt rule](#ubuntu-and-debian-apt) and RPM distributions the [RPM route](#rhel-rocky-and-fedora-rpm), with the same checks and the same plan. WSL adds only this:

- **Detection** (`lib/platform/wsl.sh`, `wsl_is`): `uname -s` is `Linux` and either the kernel release (`/proc/sys/kernel/osrelease`) contains `microsoft` in any case, or
  `/proc/sys/fs/binfmt_misc/WSLInterop` exists. WSL 1 reports `4.4.0-17763-Microsoft` (capital M, read on a real machine); `WSL_DISTRO_NAME` is not set there, so it is
  not the signal. A Linux container on a WSL 2 host shows the same kernel text and is taken for WSL too, which only adds the notes and the timer check below.
- **Class `wsl`** (`gitup_os_class`): a WSL distribution of the `rpm`, `ubuntu` or `debian` family. The `wsl` module (`lib/gitup/gitup_wsl.sh`) runs that family's module unchanged and adds two plan notes: the upgrade applies to this distribution only,
  and Windows-side git is a separate setup. Any other WSL distribution stays class `other` with today's refusal.
- **Two git setups.** WSL git reads the WSL `~/.gitconfig`, `git.exe` the Windows one. When a `git.exe` is reachable, `install` ends with a note naming it: commits made
  with it are not covered; run `install` in Git for Windows bash for that. `git.exe` is never an install candidate and never an "other git" warning (`type -aP git` does not match it).
- **`--with-timer`** needs systemd running (`/run/systemd/system` exists, what `sd_booted` tests). `systemctl` being on `PATH` proves nothing: on WSL 1 it is installed and pid 1 is `init`.
  Without systemd `install` refuses before any change. On WSL 2 it prints the fix: `[boot]` `systemd=true` in `/etc/wsl.conf`, then `wsl --shutdown` in Windows (the `[boot]` section needs Windows 11 or Windows Server 2022).
  On WSL 1 it says the timer is not available and prints no `wsl.conf` fix, because that section does not exist there. Run `git-secret-guard doctor` by hand instead.
- **`--take-over-system-git`** behaves as on the same distribution outside WSL: on Ubuntu or Debian (the apt classes have no takeover) it is refused with exit 1, naming class `wsl`; on an RPM distribution it works as on RPM. The wrapper module defines the takeover functions only when the inner module has them.
- **Installed CLI on WSL 1.** The install path avoids renaming the directory of a running script; see [WSL test runs](platform-testing.md#wsl-test-runs) for the measured behavior.

## How each platform is tested

What runs where, the container and VM runs, what they enforce and trust, the CI jobs on real platforms and their recorded
results: [platform-testing.md](platform-testing.md).

## GitHub Desktop on Linux

Behaviour and commands: [install.md](install.md#github-desktop-on-linux---link-desktop-git-and-unlink-desktop-git). This section holds what was measured and what was not.

**Measured on Fedora 45 (2026-11-13), read only on the installed Desktop (`github-desktop` 3.4.13.linux1, the shiftkey fork), with its real `bin/git` 2.45.3 run in scratch repositories and a scratch `HOME`:**

- `renderer.js` runs `process.env.LOCAL_GIT_DIRECTORY = path.resolve(__dirname, "git"), delete process.env.GIT_EXEC_PATH` at the top level of the renderer entry module, before any git call; dugite's `exec` and `spawn` exist only in `renderer.js` (`main.js` has none). A `LOCAL_GIT_DIRECTORY` set by a launcher or by `environment.d` is therefore overwritten before git runs, and a replacement git directory cannot be used. This is why the first design (a git directory under the share dir) was dropped.
- `core.hooksPath` through `GIT_CONFIG_PARAMETERS` (`'core.hooksPath=<dir>'`) is honoured by the bundled git: our `pre-commit` ran with no argument and `commit-msg` with the message file; the scope is `command`, it beats a repository's own `core.hooksPath=.husky` (scope `local`), and `git config --show-scope -z --get-all core.hooksPath` lists both, which is how the wrapper finds and runs the repository's hook.
- `GIT_CONFIG_PARAMETERS` survives both branches of Desktop's network code in `renderer.js`. The default branch sets `GIT_CONFIG_COUNT=2` with `credential.helper=` and `credential.helper=desktop` (git showed our path and the helper `desktop` both); the preview branch, taken only with `GITHUB_DESKTOP_PREVIEW_FEATURES=1`, appends `'credential.helper=' 'credential.helper=desktop'` to an existing `GIT_CONFIG_PARAMETERS`. The install check runs both, each with a fake token that must be blocked.
- **Cost of the wrappers** (Desktop's real git 2.45.3 in a scratch home, one wrapper = one bash and one git call, two runs on a 12-core host, plain then wrapped, seconds): a fetch of 2000 tags 0.07 and 0.07, then 0.07 and 0.08 (no wrapper runs, `reference-transaction` is not wrapped); a rebase of 30 commits 0.03 and 0.03, then 0.44 and 0.53; 20 checkouts 0.08 and 0.08, then 0.23 and 0.28. That is about 7 to 10 ms per hook run. The first design (two bash starts, `git config` and `git rev-parse`, and a `reference-transaction` wrapper) measured, by review, 49.7 s for the same fetch (4000 runs), 6.2 s for the rebase and 1.9 s for 20 checkouts. The suite guards the design by counting, not by time (`test_a_checkout_through_the_wrappers_starts_one_bash_and_one_git_per_hook_run`: a counting `bash` and a counting git in the fixture show that each hook run of a checkout starts exactly one bash and one git call, and that the scan never runs). Time cannot guard it: wrapped checkouts take about 3.7 times the plain ones by construction (#150), and an earlier ceiling of three times plain plus five seconds failed on macOS CI by 65 ms. The timings came from a measurement script (not shipped).
- **Decision: no `reference-transaction` wrapper.** A repository's own `reference-transaction` hook does not run in Desktop under the link; the other 27 hooks are chained.
- Our hook runs unchanged under git 2.45.3 started from the wrapper: its `git` resolves through the exec path to Desktop's own, `write-tree`, `diff-tree` and the message scan work, a fake token in a file and one only in the message are blocked with the usual text, a clean commit prints the pass line, and the repository's own hooks (a husky-style `core.hooksPath`, `.git/hooks/pre-commit`, `pre-push` with its arguments and standard input) ran with their exit status. Nothing in the hook needed git 2.54 or newer.
- The `.desktop` entry survives GLib's own parser: the generated file was launched through `Gio.DesktopAppInfo` for directory names with spaces, quotes, `$`, backticks, backslashes and `%`, and git read each directory back exactly (`test_the_launcher_exec_survives_desktop_entry_parsing_and_git_parameter_parsing_for_awkward_paths`).
- When `LOCAL_GIT_DIRECTORY` is set Desktop does not set `GIT_SSL_CAINFO`; the link does not set it either, so nothing changes about certificates.

**Not measured:** a real Desktop GUI run (the suite and the install check use Desktop's git binary with Desktop's environment, not its Electron process); Desktop started other than from the menu entry; a Desktop that builds its environment differently from the 3.4.13 code read here; the Flatpak and Snap builds (out of scope); the cost on a slower disk or a repository with many more hook events than the three scenarios above (every index write runs `post-index-change`, which is why a rebase costs more than a fetch).

**Owner's check in the real GUI, after the PR** (record the result here):

1. `git-secret-guard install --link-desktop-git`, then quit Desktop completely and start it from the applications menu.
2. In a scratch repository add a file with a fake token and commit it in Desktop: the commit must be blocked and the message shown. A clean commit must pass.
3. Sign in, fetch, push and an LFS action must still work (the credential helper and the LFS filter are Desktop's own).
4. A repository with husky or other hooks must still run them.
5. `git-secret-guard status` and `doctor` must show `GitHub Desktop: linked`.

Result: not yet recorded.

## Maintainer notes

- **SmartGit (`lib/integrations/smartgit/smartgit*.sh`, [smartgit.md](smartgit.md)).** What was measured: SmartGit 26.1.056 on a real Mac (the `git:` block of `preferences.yml`, a plain absolute path accepted, edits while closed and while running, bundled git 2.53.0 and git-lfs 3.7.1) and 26.1.057 on Fedora 45, Flatpak and tarball (settings paths, bundled state, an outside edit accepted, the `startup` file, `flatpak ps` stale entries; see the Linux maintainer notes of smartgit.md). Automated: the two-line edit for macOS, a Linux tarball or package and Windows (26.1.057 on Windows Server 2019 with Git for Windows 2.56.0: the spike, then on 2026-11-12 the tool against that SmartGit with commits through its GUI, the 26.1.056 to 26.1.057 and 25.1.100 to 26.1.057 updates, Git LFS through the GUI, an install in `%LOCALAPPDATA%\Programs\SmartGit` and the consent prompt in mintty; see the Windows maintainer notes of smartgit.md), and for the Flatpak the four steps as one recorded unit with its own consent (`--allow-smartgit-sandbox-removal` without a terminal). Refused by design: any other major version. Snap is only detected (a `status` line); no Snap-specific settings location is searched and nothing is edited for it. Not detected: the portable Windows `7z` (settings in `<unpack dir>\.settings`, no `<major>` directory; measured, docs only). The content of Git LFS files is not scanned on any platform (#98). The automated Flatpak unit ran on Fedora 45 on 2026-11-11 (install, verify inside the sandbox, rerun, restore, a commit through the GUI; the `--user` override alone was enough). On 2026-11-12, in containers with a virtual display: the tool against the 26.1.057 tarball (install, GUI commits, rerun, restore) and, on the Flatpak, an authenticated push through the rewritten credential helper and a Git LFS commit and push through the GUI (the container runs in the maintainer notes of smartgit.md). On 2026-11-12 on a real Ubuntu 26.04.1 VM: the tool against the 26.1.057 `.deb` (no bundled git; the PPA route raised `/usr/bin/git` itself to 2.56.1, so SmartGit needed no edit; with SmartGit pointed at a git 2.53.0 the edit, GUI commits, rerun, restore and uninstall; the Ubuntu run in the maintainer notes of smartgit.md). Also on that VM: SmartGit updates after configuring (26.1.056 to 26.1.057 kept the setting; 25.1.100 to 26.1.057 carried the old git into the new directory, see #88 for the left-over directory). In a Debian 13 container: the `.deb` with the source route, where the edit is needed (one install run built git into `/usr/local/bin` and pointed SmartGit at it; GUI commits, rerun, restore, uninstall). Syntevo publishes no `.rpm` for 26.1. Not run: Snap. The macOS Git LFS check runs under the PATH SmartGit gives git, measured in the maintainer notes of smartgit.md; the Linux one under the git's directory plus `/usr/local/bin:/usr/bin:/bin` (not measured). The recorded set is `SMARTGIT_RECORDED_MAJOR` plus the kinds in `smartgit_check_dir`; recording a new platform means adding its spike here first. Files: `smartgit.sh` (detection, shape), `smartgit_report.sh` (status, doctor), `smartgit_offer.sh` (refusals, plan, consent), `smartgit_lfs.sh`, `smartgit_apply.sh` (backup, manifest, edit, verify, restore), `smartgit_flatpak.sh` (the Flatpak unit: override, wrapper, vmoptions line, `flatpak.record`, undo, verify inside the sandbox).
- **Bumping the Ubuntu image digest.** `IMAGE` in `tests/platform/ubuntu.sh` is the manifest-list digest. Look it up without skopeo: an anonymous
  token from `auth.docker.io/token?service=registry.docker.io&scope=repository:library/ubuntu:pull`, then
  `curl -I -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'
  https://registry-1.docker.io/v2/library/ubuntu/manifests/24.04` and read `docker-content-digest`. It equals the DIGEST column of
  `podman images --digests` and one of the two `podman image inspect --format '{{.RepoDigests}}'` entries (the other is the platform manifest,
  not the list). Then `podman pull` the new reference, change `IMAGE` and the digest in this file (`test_the_docs_state_the_platform_test_trust_decisions`
  asserts it). The Rocky image (`ROCKY_IMAGE` in `tests/platform/mac-linux.sh`, `test_the_mac_runner_uses_the_pinned_images`) is bumped the same way.
- **Bumping the PPA key fingerprint.** On 24.04 `add-apt-repository` writes `/etc/apt/sources.list.d/git-core-ubuntu-ppa-noble.sources` with the
  key inlined in an indented `Signed-By:` block (blank armor lines as ` .`) and nothing under `trusted.gpg.d`; on 22.04 it writes `git-core-ubuntu-ppa-jammy.list` and
  the key goes to `/etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg`. `gitup_apt_show_keys` (`lib/gitup/gitup_apt.sh`) feeds either to `gpg --show-keys --with-colons` in a
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
  runs only when executed) -> `ubuntu-e2e.sh` (`gsguser`), tested through `--dry-run` and sourced functions by `tests/project/test_platform.sh`
  (skipped on Darwin). Helpers there: `isolation_with`, `dev_baseline`, `ns_fixture`, `baseline_with`, `mountinfo_fixture MP[=FSTYPE]`,
  `gua_container_ppa` (`tests/gitup/test_gitup_apt_ppa.sh`). `ubuntu.sh` must never mention `--skip-isolation` (`tests/project/test_mac_runner.sh`). `install_git_ppa` is a
  wrapper over the product's `gitup_apt_ppa_apply`; a failed disable makes it return 2 and no source build runs (its root `apt-get install` would trust a PPA that may still be
  enabled). `--phase upgrade` (`tests/platform/apt-phase.sh`, then `apt-upgrade-e2e.sh` as `gsguser` with sudo) is the real `install --upgrade-git`; `ubuntu.sh --os`
  chooses the pinned image and passes `--expect-os ID:VERSION` for the isolation check. Rocky also installs the stock distro git, because a doctor test calls `/usr/bin/git` directly.
- **Mac runner gotchas.** `stage_checkout` runs `git init` in the copy (`tests/project/test_quality.sh` uses `git ls-files`); BSD `mktemp -t`
  appends a suffix; macOS bash rejects a regex repetition over 255.
- **Shell traps that bit.** `set -o pipefail` plus `sed ...q` inside `$( )` is a race (the writer gets SIGPIPE); it once turned a good
  PPA install into a silent source build. A failed redirection is reported before `2>/dev/null` applies: write
  `{ mapfile ... <"$f"; } 2>/dev/null`. bash 5.3 in the C locale reads a UTF-8 `…` after `$name` as part of the name: write `${name}…`.
- **awk portability**: `tests/scan/test_awk_portability.sh` picks each interpreter through `awk_farm` and skips with a reason when one is absent.
- **No `realpath` at start-up (#157).** macOS 12 has no `realpath` in `/usr/bin` or `/bin` (Homebrew coreutils links one into `/usr/local/bin` only), and a GUI
  git client or SmartGit starts the hook with a PATH that has nothing else. `hooks/secret-scan` and `bin/git-secret-guard` therefore find their own location
  with builtins plus plain `readlink` (no `-f`, BSD has none): `cd -P` on the directory part under `CDPATH=`, then a symlink is read and the walk repeats,
  at most 40 times, and a chain without an end blocks the commit (hook, `nothing was scanned`) or exits 1 (CLI). One copy per file, neither can source
  a library before it knows where it is; the CLI copy is bash 3.2 syntax. Tests: `test_the_hook_scans_with_a_PATH_that_has_no_realpath`,
  `test_the_hook_blocks_when_its_own_location_cannot_be_resolved` (`tests/scan/test_hook.sh`), `test_the_cli_started_through_links_finds_its_share_with_a_PATH_that_has_no_realpath`,
  `test_the_cli_refuses_a_link_that_never_settles_instead_of_hanging`, `test_the_cli_refuses_a_link_that_readlink_cannot_read_instead_of_guessing` (`tests/cli/test_cli.sh`); `realpath_free_path_dir` in `tests/support/lib.sh` builds the PATH.
  The walk settles only on a regular file (`-f`), as `realpath` without `-m` did: a missing target blocks or exits 1 (`test_the_hook_blocks_when_the_link_target_is_not_a_file`,
  `test_the_cli_refuses_a_link_whose_target_is_not_a_file`). The tests reach these paths with a `readlink` stand-in, as the kernel refuses a real loop or a dangling link
  before bash reads the script. On every macOS (12 and 26 alike) the shebang `bash` is 3.2 and the bootstrap refuses by design, so the link-walk test runs the harness bash by absolute path
  and `test_the_cli_started_by_its_shebang_through_a_link_without_realpath_reaches_the_bootstrap` pins that the refusal is the bootstrap's, never the walk's. That directory
  also hides `jq` (macOS 12 has none in `/usr/bin`); `tests/stubs/trufflehog` and `tests/stubs/betterleaks` take the jq from `STUB_JQ` (`TEST_JQ`, set in `GSG_ENV`),
  never from PATH, and fail loudly without it; a hand-built `env -i` that runs a stand-in passes `STUB_JQ` itself.
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
- **macOS git upgrade** (`lib/gitup/gitup_macos.sh`, story #32; routes `path-fix`, `brew-upgrade`, `brew-install`, state read from the file `$(brew --prefix)/bin/git`).
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
  with launchd's `PATH` (`launchctl getenv PATH` is empty, the default is `/usr/bin:/bin:/usr/sbin:/sbin`) and so keep running Apple Git. *Guard:* `brew_git_shim_unusable` (lib/platform/brew.sh) never
  runs the system directory's `git` on macOS when its `xcode-select -p` (no dialog) reports no developer directory; that git counts as unknown version, and
  `gitup_defers_git` (lib/gitup/gitup.sh) refuses it before the offer with `brew_refuse_git_shim`, with or without `--upgrade-git` (Homebrew needs the
  Command Line Tools too; #156), the other prerequisite checks still reported
  (`test_a_mac_without_developer_tools_never_runs_the_git_shim_and_refuses_naming_the_command_line_tools` and its `--upgrade-git` twin use a shim that records and sleeps).
  The Intel texts are `brew_find` (the pointer to "Homebrew on an Intel Mac", `brew_is_intel_mac`) and `brew_build_notice` (called by `brew_run_install` and
  `gitup_macos_brew_run`, which covers the bootstrap's `brew install bash`, the prerequisites and the git install and upgrade); `tests/platform/test_macos_intel.sh`
  runs them under a fake `uname` x86_64 and arm64 (the bootstrap redefines `brew_running_bash_ok`; the real bash 3.2 runs are in `tests/platform/test_macos.sh`). No version probe has a timeout of its own. The macOS prompt test (`gu_pty_bsd`) uses the BSD `/usr/bin/script`, since Homebrew's util-linux ships no `script` (probed), and feeds the answer after a lead with stdin held open (BSD `script` sends EOF first when stdin ends at once).
- **BSD differences that shaped code**: no `realpath -m`, `mktemp --suffix`, `mv -T`, `stat -c`, `env --default-signal`; `install -T`
  means tags; `chmod 700 -- DIR` fails; `find` lacks `-printf`/`-readable`/`-executable` (sizes via `install_entry_sizes`; never
  `find -ls`: `test_the_backup_bounds_do_not_depend_on_the_owner_columns_of_find_ls`); `wc -l` pads.
- **Mac test harness.** `tests/support/lib.sh` picks per-OS `TEST_BASE_PATH`, `TEST_BASH`, `TEST_GNUBIN`, `TEST_TRUE` and the cached scanners;
  `lc_begin` fakes a Linux `uname`, and `tests/platform/test_macos.sh` uses `lc_real_uname`/`as_macos`. A test that replaces `PATH` must keep
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
  from it, so `install_copy_share` rewrites only the generated files when `GSG_ROOT` is the share dir. A working directory in it
  pins it as well, and so does a non-`exec` parent waiting for a child (all probed). `update` therefore `exec`s a private copy of
  the share (`winupdate_reexec`, [autoupdate-maintainer.md](autoupdate-maintainer.md)); MSYS `exec` keeps the pid, which keeps the update lock valid.
- **Windows: what the MSYS tools lack.** `ps` has no `-o` (the update lock reads `/proc/<pid>/ppid`), `[ -O ]` is true for any owner (git is
  asked, `winupdate_role`), there is no `setsid` (GNU `timeout` alone ends git and the processes below it, also inside a scheduled
  task), and Git Credential Manager ignores `GIT_TERMINAL_PROMPT=0` (`GCM_INTERACTIVE=never`). `schtasks` needs `MSYS_NO_PATHCONV=1`, rejects a
  `/TR` over 261 characters and asks a question without `/F`; `/NP` asks for a password.
- **Windows: a here-string or here-doc of 64 KiB + 1 to 128 bytes never returns** (#155; Git for Windows 2.56.0.windows.4, bash 5.3.15,
  measured: 65,536 and 65,665 bytes return, 65,537 to 65,664 do not; a pipe of the same bytes returns; Linux and macOS bash are not affected).
  So no value without a bound well below 64 KiB goes through `<<<` or a here-doc in `hooks/`, `bin/` or `lib/`:
  - **Replaced:** the `.secret-scan-ignore` rows (1,000 lines of any length) go through `<probe dir>.rows` in the work dir (`exempt_warn_rows`);
    `ps -W` (about 100 bytes per Windows process) is piped (`smartgit_windows_running`); doctor's worktree lists use `split_lines`
    (`lib/core/common.sh`); a betterleaks log line is cut to `GSG_MSG_WORDS_MAX`, a tool's `--version` output to `GSG_VERSION_OUTPUT_MAX`, and
    `state_read` refuses a line over `GSG_STATE_LINE_MAX`, which bounds every `ST_*` word list.
  - **Kept, bounded:** `git rev-parse --local-env-vars` (git's fixed list), one `ls-tree` or `diff --raw` record, the probe repository's listing
    (18 names), an LFS pointer (at most `GSG_LFS_POINTER_MAX` bytes), the hook-list probe line (its message cut at 200), the four numbers of the
    message split, one pid list, one `cksum` line, a line of our own lock file, one registry key of the Git for Windows setup, and
    `GSG_SMARTGIT_INSTALL_DIRS` (an environment variable holds at most 32,767 characters on Windows).
  - **Kept, never on Windows:** the git upgrade modules of Linux and macOS, GitHub Desktop and Flatpak on Linux, `brew`, and the BSD `realpath`
    fallback (`lifecycle_realpath_m`; Git for Windows has `realpath -m`).
  - **The lint:** `tests/herestring-bounded.list` names every allowed token per file (`tests/herestring-tokens.awk` finds them);
    `test_here_strings_and_here_docs_in_the_product_are_only_the_listed_bounded_ones` fails on a new one and on a stale entry. Add a token only
    with its bound here. The regression tests drive each replaced place with 65,600 bytes under a short `timeout` (124 = it hung).
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
  reason. Inspect a failing fail-closed test before skipping it. `tests/platform/test_windows.sh` fakes `uname` around the real libs so the
  Windows branches are also tested on Linux and macOS; `tests/windows-skips.list` names the tests that cannot apply, with reasons.
- **WSL internals.** `lib/platform/wsl.sh` (CLI-only, loaded before `gitup`): `wsl_is`, `wsl_version` (REPLY 1 when the raw kernel text holds `Microsoft` with a capital M, else 2: real WSL 2 kernels exist without a `WSL2`
  suffix, such as `4.19.128-microsoft-standard`), `wsl_systemd_running`, `wsl_check_timer` (called by `install_precheck_timer`), `wsl_announce_overrides` (only when an override makes the run a WSL run, so a plain
  fixture adds nothing to stderr), `install_pins_running_script` and `install_wsl_notice`. The last one finds `git.exe` with `install_find_bin` of `lib/install/install.sh` (`type -P` is allowed only in `lib/install/install.sh`, `lib/platform/brew.sh` and the one line of `smartgit_tool`).
  The test harness (`sandbox_create` in `tests/support/lib.sh`) points the three seams at a plain kernel for every test file, so no result depends on the kernel of the machine running the suite; `tests/platform/test_wsl.sh` sets its own.
  `gitup_os_class` returns `wsl` only for an rpm, ubuntu or debian family; the wrapper module `lib/gitup/gitup_wsl.sh` sets `GITUP_INNER_CLASS` and delegates with `gitup_delegate`; the apt module reads
  `gitup_inner_class` where it used to read `GITUP_CLASS`. The wrapper defines all five takeover functions (the set is all or none) and answers "not supported" for an inner module without them.
  Tests: `tests/platform/test_wsl.sh` (fixture kernel files, faked `uname`, a synthetic inner module in a copy of the tree, so no apt stand-in and no `setsid` are needed and it runs on Git for Windows).
