# Platform testing and CI

Contributor and maintainer procedures and evidence for the platform runs. User setup and behavior are in [platforms.md](platforms.md).


## WSL test runs

- **Checkout and repository on `/mnt/c` (measured).** DrvFs without `metadata` shows every file as mode 777. `install` copies the checkout with `cp -a` and then removes group and other write bits from the share tree. With the drive mounted for the user (`uid=1000`, measured on drvfs and 9p), a repository on `/mnt/c` blocks the fake key and passes a clean commit (2 s on WSL 1, 4 s on WSL 2), `install` from a checkout there exits 0, and nothing in the installed tree is group or other writable. The mount must belong to the user: in the first run, with the runner default mount for root (`uid=0`), the repository could not be prepared and the checkout could not be copied by the normal user. A `metadata` mount was tried: see the later runs below.
- **`install` from the installed CLI on WSL 1** failed with `mv: cannot move '.../git-secret-guard' to '.../git-secret-guard.old.XXXXXX/previous': Permission denied` (jammy and noble).
  **Measured (GitHub-hosted `windows-2022`, Ubuntu 22.04):** renaming the directory that holds a running script fails on WSL 1 (`4.4.0-20348-Microsoft`, rc 1, `Permission denied`) and works on WSL 2
  (`6.18.54.1-microsoft-standard-WSL2`, rc 0). `main`'s installed CLI gives the same `mv` error on WSL 1 and passes on WSL 2, so the pin applies to WSL 1 only (`install_pins_running_script`): from the installed copy only the
  generated files (`settings`) change, as on Windows. This branch's installed-CLI install passes on both. WSL 1 on that runner (build 20348) ran the rename without a crash; that says nothing about the 17763 host, which is not cleared.

**Order of the real run.** The workflow runs `facts`, `upgrade`, `mount-for-user` and `mntc`, writes their results to the job summary and uploads the logs, and only then runs `tests`, the rename `probe` and the
`installed-cli` phase, because the probe is the kind of operation that coincided with the first blue screen (no cause is claimed). `tests` comes after the first upload for the same reason:
`test_install` has an installed-copy test that runs under the plain-kernel pin and so renames the directory of a running script; it failed on WSL 1 as the measured limit predicts, and now skips there with that reason while a second test runs the WSL 1 path through the fixture seams. A failure on WSL 1 stays recorded, not hidden. `tests/platform/wsl-ci.sh` refuses to run unless `GITHUB_ACTIONS` is `true`.

**Running it.** `gh workflow run wsl.yml --ref BRANCH -f distribution=Ubuntu-22.04|Ubuntu-24.04|Rocky-9|Fedora-44 -f consent=flag|typed` (the Actions tab has the same form). Ubuntu comes from `setup-wsl`.
Rocky 9.8 (`Rocky-9-WSL-Base-9.8-20260525.0.x86_64.wsl`, SHA-256 `58de2455cd47...3829221`) and Fedora 44 (`Fedora-WSL-Base-44-1.7.x86_64.wsl`, SHA-256 `2e5b153ba4b6...d319a`) are the vendors' own WSL tars, imported
with `wsl --import`; the digests are the ones in the vendors' CHECKSUM files, checked in the job (a mismatch stops it), and the same files were hashed once by hand. To bump an image, read the new file name and digest from the vendor's
CHECKSUM file and change both in the `Import the RPM distribution` step. `consent=typed` types the answer at the real prompt on a pty instead of passing `--upgrade-git`. Every phase runs through `tests/platform/wsl-phase.ps1`
in the distribution named by `WSL_TARGET`. Rocky and Fedora run the WSL 2 leg only (the matrix has no WSL 1 entry for them), because `wsl --import` of their vendor tars fails on WSL 1 (see the later runs below); a typed No is always run first, and on a stock git that is already new enough the flow checks that nothing is offered.

**Tested where.** `tests/platform/test_wsl.sh` drives all of this through fixture kernel files (`GSG_WSL_OSRELEASE`, `GSG_WSL_INTEROP`, `GSG_WSL_SYSTEMD_DIR`, announced on stderr like the other test seams, except that seams which look like plain Linux are silent) and a faked
`uname`, so it runs on Linux, macOS and Git for Windows alike. The real runs are `tests/platform/wsl-ci.sh`, started by `.github/workflows/wsl.yml`.

**What the hosted runner offers** (sources, not assumptions): the `windows-2022` image lists "Windows Subsystem for Linux (WSLv1): Enabled" and no distribution
([actions/runner-images, Windows2022-Readme](https://github.com/actions/runner-images/blob/main/images/windows/Windows2022-Readme.md), image 20261101.353.1). `Vampire/setup-wsl` v7.2.0 installs a distribution
(`Ubuntu-26.04` to `Ubuntu-16.04`, `Debian-13`, default `Debian-13`) and takes `wsl-version` 1 or 2 (default 2; "WSLv1 and WSLv2 are tested"); its README says WSL 2 "is also available" on later `windows-2022` images
but does not discuss nested virtualization. Another setup action states that it "requires WSL2 with nested virtualization". Whether WSL 2 starts on a hosted runner is therefore **not documented
by GitHub in the places read**; the first real run answered it: both versions start on `windows-2022` with `Vampire/setup-wsl`, WSL 2 included, with systemd running in the WSL 2 distribution.

**Measured** (GitHub-hosted `windows-2022`, Ubuntu 22.04, stock git 2.34.1, one run, both versions):

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
| Test files (`GSG_TEST_JOBS=1`) | 273 passed, 0 failed | 270 passed, 0 failed, 3 skipped: one `test_install` test that needs the real rename and two `test_timer` tests that need systemd-analyze |
| `/mnt/c` mount | 9p, `uid=0;gid=0` | drvfs, `uid=0,gid=0,case=off` |

The first run's `mntc` phase failed on both legs because the runner mounts the drive for root while the test user is `gsg`. The workflow now remounts `/mnt/c` for that user (phase `mount-for-user`, as root, before `mntc`); the second run passed on both legs with the mount shown as `uid=1000,gid=1000` (drvfs on WSL 1, 9p on WSL 2).

**Later runs** (same runner, `windows-2022`; every figure is a line of the run's `results.txt`, read from the artifact, not from the job colour):

| What | Result |
|---|---|
| Ubuntu 24.04, `--upgrade-git`, both versions | WSL 1: `4.4.0-20348-Microsoft`, WSL 2: `6.18.54.1-microsoft-standard-WSL2`. `/etc/os-release` says `VERSION_ID="24.04"`, stock git 2.43.0 from `apt`, route `ppa`, git 2.56.0 from `1:2.56.0-0ppa1~ubuntu24.04.2`, blocked commit and clean commit pass. Test files: WSL 1 271 passed, 3 skipped; WSL 2 274 passed (with the awk test added since). Stock 24.04 on WSL 1 did **not** hit the `systemd-sysusers` / `Failed to take /etc/passwd lock` failure seen in the 2026-11-05 chroot runs: that failure belongs to a minimal debootstrap chroot, not to a WSL 1 distribution. |
| A typed yes and a typed No at the real prompt, Ubuntu 22.04 and Rocky 9.8 | Install runs on a pty (`script -qefc`) with the answer typed, on stock git 2.34.1. **Typed No:** `Upgrade git now with the plan above? [y/N]` is printed, install exits 1, `git --version` is still 2.34.1, no `/usr/local/bin/git`, no git-core PPA file, no install state. **Typed yes:** the same prompt, install exits 0, git 2.56.0, blocked commit passes. Both versions (WSL 1 47 PASS, 0 FAIL; WSL 2 45 PASS, 0 FAIL). On Rocky (WSL 2) the typed yes also meets the second prompt, `Take over /usr/bin/git with the plan above? [y/N]`, and the typed `n` leaves `/usr/bin/git` 2.52.0 as it is. **A hang in the harness, not shown in the product:** when both answers were typed at the start (`y`, then `n`), every Rocky run but one sat at the takeover prompt until it was cancelled after 10 to 22 minutes (about a dozen runs; the exception is the run with the 15 s repeat). With strace the install bash was blocked in `read(0)` at that prompt for 240 s, so the second answer never reached it. Why is not established (a terminal flush by `sudo` or `dnf` is a guess). The one run that passed had a 15 s repeat of the answer, which is a single result. The harness now types each answer after its prompt shows in the log: 4 of 4 runs passed (47 PASS, 0 FAIL each), and each took the takeover `n`. A person answers a prompt they see, so this is also the realistic case; whether the product loses an answer typed ahead of its prompt on a real terminal is untested. **Inference, not established:** the review noted that `sudo` 1.9.17p2 has `use_pty` on by default, so `sudo` may read the terminal and relay it to its own inner pty, where the `n` is echoed and never read (raw log line 17 shows `[y/N] n`); nothing in `lib/`, `bin/` or the hook flushes the terminal. |
| Rocky Linux 9.8 on WSL 2 (vendor WSL image, SHA-256 pinned) | `/etc/os-release` `ID="rocky" VERSION_ID="9.8"`, stock git 2.52.0. Typed No: prompt, exit 1, git unchanged. `install --upgrade-git` follows the RPM route as outside WSL: `route: source (the newest git-core the repositories offer is 2.52.0)`, `dnf install` of the build dependencies, copy into `/usr/local`, git 2.56.0, plus the two WSL notes. The offer to take over `/usr/bin/git` is printed again on a rerun (as on Rocky outside WSL). Blocked commit 4 s. 46 PASS, 0 FAIL; test files 196 passed. |
| Fedora 44 on WSL 2 (vendor WSL image, SHA-256 pinned) | Stock git is already 2.56.0, so there is no upgrade to offer: install exits 0 and offers nothing. The image has no `awk` and no `xz`: see the product bug below. 42 PASS, 0 FAIL; test files 188 passed, 8 skipped. |
| Rocky and Fedora on WSL 1 | **Not possible.** `wsl --import` of the vendor WSL tar fails with `Unspecified error` (exit -1) on the WSL 1 leg, in every form tried (the full ladder: the tar as shipped, as `.tar.gz`, unpacked to a plain `.tar`; with `--version 1` and through `--set-default-version`; into `C:` and `D:`, both NTFS), after 8 to 47 s. The same tars import on WSL 2. The cause is not known. |
| `metadata` mount of `/mnt/c`, Ubuntu 22.04 and Rocky 9.8 | Remounted as root with `-o uid=1000,gid=1000,noatime,metadata`; `/proc/mounts` shows it (WSL 1 drvfs: `uid=1000,gid=1000,metadata,case=off`; WSL 2 9p: `uid=1000;gid=1000;metadata;`). **Without** `metadata` a new file and directory show mode 777 whatever `chmod` says. **With** it a new file after `chmod 644` shows 644, a new directory 755, and `chmod 640` on a copied file shows 640. Files copied with `cp -a` from the runner's `D:` checkout keep that drive's mode 777, since they have no mode to copy. Repository on the drive: fake key blocked and clean commit passes (2 s on WSL 1, 4 to 5 s on WSL 2); install from a checkout on it exits 0 and leaves nothing group or other writable. Rocky on WSL 2 gives the same (new file 777 without `metadata`, 644 with it, directory 777 and 755, `chmod 640` sticks). |

**Product bug found and fixed.** The Fedora 44 WSL image has no `awk`. `install` finished, and then every commit was blocked with `awk: command not found` ("nothing was scanned"): safe, but found out at the first commit. `install` now names `awk` with its package (`gawk`) among the prerequisites on Linux and WSL (`install_resolve_bins`; macOS goes through `install_macos_inspect` and has no awk check; `test_a_missing_awk_is_refused_by_install_with_its_package_not_found_out_at_the_first_commit`). The workflow shows it on Fedora: the first `install` refuses with `awk is required but was not found on PATH`, `dnf install gawk` follows, and the rest passes.

**Findings about the test setup, not the product.** `wsl.exe -e bash` starts with `SHELL=bash`, a bare name, and `script -c` then fails with `No such file or directory` for its command (`script from util-linux 2.37.2`); with `SHELL=/bin/bash` it works, and so does `python3` `pty`. The phase script exports `SHELL=/bin/bash`. Four `test_prerequisites` tests failed on a machine that already held a build of ours in `/usr/local` (the path-fix refusal); they now run with a sandbox `GSG_GITUP_ROOT`. An RPM image needs `dnf upgrade` first: `libcurl-devel` could not be installed against the image's older `libcurl`.

### CI on a hosted Mac

The `macos-suite` job of `.github/workflows/tests.yml` runs the whole suite (`tests/run.sh`) on a GitHub-hosted arm64 Mac. It is a pull request check like `windows-suite`: it runs for pull requests and for `main`, not for every push to a feature branch.
It needs no secrets (`contents: read`) and is bounded by `timeout-minutes: 120`. Setup is the [macOS prerequisites](platforms.md#macos-homebrew) (`brew install bash coreutils util-linux jq`) and `tests/fetch-test-tools.sh` for the pinned scanners.
The Homebrew formulae are not pinned: they float with the image and with Homebrew, which is why each run prints the versions it used (step summary and artifact). The job does not install git; it uses the image's Homebrew git.
The scanner fetch is tried up to 4 times (sleeping 20, 40 and 80 seconds in between) and then fails the job with an error: a GitHub release download answered 504 on and off for more than twenty minutes on one day (all four attempts of one run failed on it: two network tests of the suite, then the fetch step three times), and a retry is safe because the script skips tools it already has and checks every download against `tools.lock`. `actions/cache` is not used: a restored file would be checked only for its version, not against the pin.

- **Which git.** The job tries `/usr/bin/git`, then Homebrew's, and exports the first one that is 2.54 or newer as `GSG_TEST_GIT`; it fails with an error when neither is. The image's Apple Git is 2.50.1, which ignores `hook.<name>.command`, so the suite runs on Homebrew's git 2.56.0. The suite therefore did **not** run on an Apple git that meets the floor in CI; that case was only checked by hand on the maintainer's Mac (Apple Git 2.54.0).
- **The macOS-only tests must pass, not skip.** `tests/macos-only.list` names the 29 tests that skip on every other system (`test_macos` 17, `test_hook` 4, `test_launchd` 3, `test_launchd_update` 1, the `bwk` tests of `test_awk_portability` 4). After the suite, `.github/scripts/check-macos-tests.sh` reads that list and the log and fails the job when a listed test is skipped, failed, or not in the log at all, so a rename cannot make it pass quietly. The job `macos-list-complete` runs `.github/scripts/check-macos-unlisted.sh` on the Mac log and the Linux `log-head` artifact of `suite`: a test that PASSes on the Mac and is SKIPPED on Linux with a macOS-only reason (pattern `MAC_REASON` in that script) but is not in the list fails it (tests in `tests/project/test_macos_ci.sh`).
  A new test that can only run on a Mac belongs in the list (`test_the_checker_*` and `test_the_list_*` in `tests/project/test_macos_ci.sh` check the checker and that every listed name is a real test function).
- **Reading a run.** Job logs can be read only when the whole run has ended; the job uploads its log and the version list as the artifact `macos-log` (`gh run download RUN -n macos-log`).

**Record** (a run from before this repository started over; the commits after it, as of this record, changed documentation only. All eight jobs of that run passed, `windows-suite` and the Ubuntu head and base suites included):

| Item | Value |
|---|---|
| Runner image | `macos-26`, image `macos26` version 20261102.0473.1, arm64 |
| macOS | 26.7.2 (25G332) |
| git used by the tests | Homebrew 2.56.0 (`/opt/homebrew/bin/git`); `/usr/bin/git` is Apple Git 2.50.1 and was not used |
| bash | Homebrew 5.3.20 (the tests and the CLI); system `/bin/bash` 3.2.57 (the tests that need it) |
| awk | `/usr/bin/awk`, one-true-awk 20200816 (`bwk`) |
| other tools | jq 1.8.2, Homebrew 7.0.11, GNU coreutils `timeout` 9.12, `plutil` present |
| Run time | the suite took 21 minutes 47 seconds (log start to end), the whole job 22 minutes 10 seconds; the run before it, on the same code except one added test, took 21 minutes 21 seconds and 21 minutes 40 seconds |
| Result | `SUMMARY: 958 passed, 0 failed, 331 skipped (total 1289)` |
| macOS-only tests | `check-macos-tests.sh`: `28 of 28 macOS-only tests passed` |

**What the first runs found** (all on a real Mac, none on Linux):

- `test_status` interrupt tests started `status` through a bare `setsid`. On a Mac util-linux is keg-only and not on the test's `PATH`, so `status` never started. They use `$TEST_SETSID` now (reproduced on Linux with a `PATH` that lacks `setsid`).
- `test_timer::test_the_unit_path_has_no_duplicate_entries` knew only `/usr/local/bin` and `/usr/bin` as the first git directory. With Homebrew's git first it is `/opt/homebrew/bin`; any other directory goes first and the rest follow, as the test already asserted for `/opt/git/bin`.
- **Product bug.** `test_an_interrupt_during_the_hook_check_stops_status_with_130` failed with `git was still running after SIGINT ended status`. `hooklist_read` (used by `status` and by `doctor`) ran `git hook list` as `mapfile < <(timeout ... git hook list)`. On the runner,
  Homebrew bash 5.3.20 starts a process substitution child with SIGINT ignored (`trap -p` in the child printed `trap -- '' SIGINT`). Measured on the runner with `kill -INT` sent to the `sleep` alone: a `sleep` started in a process substitution survived, with or without `timeout --foreground` in between;
  the same `timeout --foreground ... sleep` outside a process substitution died. So a Ctrl-C ended `status` and left git running until its 30 second bound. On Linux the child of `timeout` showed no ignored signal (`SigIgn: 0` in `/proc`), and a bash 5.1.8 and a locally built bash 5.3.0 did not reproduce the failure.
  `hooklist_read` (used by `status` and `doctor`) now runs git as a foreground command writing to `ERRFILE.out`. Because Linux cannot show the failure, `test_the_hook_list_call_runs_in_the_foreground_not_in_a_process_substitution` pins the code shape on every bash.
  `hp_records` in the same file (`lib/install/hookspath.sh`) read `git config` through a process substitution as well; it was not part of the failing test, and it now also runs git in the foreground into two files (bash may reap a process substitution's child before its status is read).

**Still not covered by this job:** Intel Macs; a long-lived Mac with git-secret-guard already installed; GUI git clients; an Apple git that is 2.54 or newer (see above); macOS releases other than the image's (26.x).
Of the 331 tests that skipped, 210 are the RPM source route tests, which need GNU `find` (`this PATH has only BSD find`); installing `findutils` would presumably run them (not tried). The rest are Linux, Windows or podman only, plus the `gawk` and `mawk` awk tests
(not installed), three tests that need `pre-commit`, and the shellcheck gate (it runs in the Ubuntu job).

### The test suite on Windows

```powershell
tests\run.cmd                      # the whole suite (tests/run.sh from Git Bash)
tests\run.cmd tests\scan\test_hook.sh   # one file
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

The gitup tests that build the signed stand-in (a certificate with a key) skip with "user DPAPI unavailable in this logon session
(key-based SSH)" where user DPAPI is denied, because a key-based SSH logon has no password; they run in a credentialed session such as the hosted runner.

`tests/platform/test_windows.sh` tests the Windows branches through a faked `uname`, so a change that breaks them also fails on Linux.

### Real scenarios and where each one runs

| Scenario | Fixture test (`tests/platform/test_wsl.sh`, runs anywhere) | Real run (`wsl.yml`, phase of `tests/platform/wsl-ci.sh`) |
|---|---|---|
| Detection on WSL 1 and WSL 2 | `test_the_wsl1_kernel_text_*`, `test_the_wsl2_kernel_text_*`, interop file, plain Linux, macOS and Windows | `facts` |
| Plan is the inner plan plus notes | `test_the_wsl_plan_is_the_inner_plan_plus_two_notes` | `upgrade` |
| Old git, accept the offer, blocked commit | (module dispatch only) | `upgrade` |
| Rerun does nothing to git | `test_a_wsl_refresh_with_nothing_stale_prints_nothing_at_all` | `upgrade` |
| Windows git never mistaken for the WSL git | `test_a_windows_git_is_never_taken_for_a_git_of_the_distribution` | `facts` (`git.exe` on PATH) |
| The two setups are explained | `test_a_reachable_windows_git_is_explained_as_a_separate_setup` | `upgrade`, checked when `git.exe` is on the PATH inside the distribution; otherwise recorded as not exercised |
| Timer without systemd, WSL 1 and WSL 2 | `test_with_timer_is_refused_on_wsl1_*`, `..._wsl2_*` | `upgrade` |
| Timer with systemd | `test_with_timer_goes_on_when_systemd_runs_*` | measured on WSL 2: systemd runs and `install --with-timer` exits 0 |
| Repository and checkout under `/mnt/c` | none possible | `mount-for-user` and `mntc`: measured, both legs pass (blocked commit 2 s on WSL 1, 4 s on WSL 2; install from the checkout exits 0; files show mode 777) |
| `install` from the installed CLI | `test_an_install_from_the_installed_copy_on_wsl1_never_renames_*` | `probe`, `installed-cli` |
| Rocky or Fedora in WSL | `test_the_wsl_module_for_an_rpm_distribution_wraps_the_rpm_module` | Rocky 9.8 on WSL 2 follows the RPM route (source build, 2.52.0 to 2.56.0); Fedora 44 on WSL 2 has git 2.56.0 and offers nothing; neither can be imported on WSL 1 (later runs above) |
| A typed yes and a typed No at the prompt | none (`test_gitup` drives the prompt through `script` outside WSL) | `upgrade` with consent `typed`: Ubuntu 22.04 on both versions, Rocky 9.8 on WSL 2 |
| A `metadata` mount of `/mnt/c` | none possible | `mount-for-user metadata` and `mntc metadata`: Ubuntu 22.04 on both versions, Rocky 9.8 on WSL 2 |
| Not WSL: nothing changes | `test_the_class_outside_wsl_is_unchanged`, `test_with_timer_is_unchanged_outside_wsl` | the Linux suite |
| Test files that apply | | `tests`, `GSG_TEST_JOBS=1` |

## What differs on Ubuntu, and what was checked

- **awk.** Ubuntu's default `awk` is **mawk**, RHEL's is **gawk**. The awk programs the portability test runs (`lib/scan/extract.awk`, the inline programs in
  `lib/scan/extract.sh`, `lib/install/install.sh`, `lib/scan/report.sh` and `lib/core/message.sh`, and `tests/comment-rules.awk`, `tests/coverage.awk`) are portable: they give
  identical results under both, so there is **no gawk dependency** there. The other inline programs (`lib/scan/scanners/betterleaks.sh`,
  `lib/integrations/smartgit/smartgit.sh`, `lib/gitup/gitup_apt.sh`, `gitup_source.sh`, `gitup_takeover.sh`) are not run by it. `tests/scan/test_awk_portability.sh` runs the programs it covers under each interpreter that is
  installed and compares mawk with gawk when both are (the platform test installs both; on a machine with one of them the other tests skip with
  a reason). The corpus includes odd file names, `++`/`--`/`@@` lookalike lines, a 25000-line file, a 200000-character line, backslashes,
  malformed diffs, and numeric edge cases (9 against 10, a 3 GB file against a 2 GiB bound).
- **Checked and found identical:** `realpath -m`, `stat`, `sha256sum`, `setsid`, `timeout --foreground`, `mktemp --suffix`,
  `tar`, `sed -E`, coreutils 9.4, bash 5.2, and dash as `/bin/sh` (the hook and the CLI use no `sh -c`; the test stand-ins use `#!/bin/sh`).
  The backup-bounds walk uses `find -printf` on Linux, unchanged by the macOS work (the macOS size source only runs where `find` has no `-printf`).
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
  - The tree of `/dev` to depth 4 may hold only the 16 baseline entries (plus `pts/<digits>` for a pty), at most 500 entries are read, and a
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

`tests/project/test_platform.sh` pins the command line (`--dry-run`), the checks, the abort and the copy rule. The run ends with
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
  run calls `gitup_apt_ppa_apply` of the product (`lib/gitup/gitup_apt.sh`, the same code `install --upgrade-git` runs, no second copy): it adds the repository with
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
- **Not covered in that run:** x86_64 (the `linux_x64` and `linux_amd64` rows of `tools.lock` are not exercised on an arm64 VM; the x86_64 containers run in CI, see [Results](#results)), and macOS itself, which
  `tests/run.sh` covers natively.

## CI on real platforms

`.github/workflows/platforms.yml` runs what no unit test can: real containers, a real VM and real Windows installs, on disposable GitHub-hosted runners. It is not a pull request check
and not part of `tests.yml`. It runs only by `workflow_dispatch`.

- **Starting it.** By hand only: `gh workflow run platforms.yml --ref BRANCH` runs every job (about 45 minutes, the Rocky source builds and the three suites dominate). There is no push, pull request or schedule
  trigger on purpose: a run costs hours of hosted runners and its answer changes only when the product or a pinned image does; run it before a release and when `lib/gitup/gitup*.sh`, the platform scripts or a pin change.
  A branch can iterate with a temporary `push:` trigger, which must not be merged. Third-party actions are pinned by full SHA. The concurrency group names the commit.
  Job logs are readable through the API only when the whole run has ended; every job uploads its log as an artifact (`gh run download RUN -n NAME`).
- **The runner.** `ubuntu-24.04`, 4 vCPUs, 16 GB, rootless podman 4.9.3 with crun 1.14.1 and cgroups v2, `/dev/kvm` present (`crw-rw---- root kvm`; a udev rule makes it usable), qemu from apt.
  `windows-2025` is elevated and has winget 1.11 with `Git.Git`.

### What had to change for the runner (and what did not)

- **Isolation checks: one mount rule added, nothing skipped.** Podman 4.9.3 masks `/sys/dev/block` as well (the `maskedPaths` of its `config.json`, read in a probe job). `ISOLATION_MOUNT_RULES`
  gained `/sys/dev/block=tmpfs`; the fstype is checked like every other entry, and the variable, `/dev`, namespace, `/run/secrets` and read-only `/src` checks are unchanged. `ubuntu.sh` still has no way to skip a check.
- **Isolation checks on podman 6.1.3 (Fedora 45 with SELinux, crun 1.30.1, 12 CPUs).** The Debian 13 image aborted the run on three things, all measured in a probe container with the
  launcher's flags: 12 mounts of `/sys/devices/system/cpu/cpu<N>/thermal_throttle`, `/sys/devices/virtual/powercap` mounted twice, and `find: '/dev/mqueue': Permission denied`. Podman 6's `maskedPaths`
  names every `thermal_throttle` directory and `powercap` twice. The first two are accepted only as proven masks; the third has a known limit:
  - Each `thermal_throttle` mount must be a `tmpfs`; the path matches `^/sys/devices/system/cpu/cpu(0|[1-9][0-9]*)/thermal_throttle$` and nothing else (`isolation_mount_want`). Each CPU still counts once.
    Podman 4.9.3 and 5 do not mask these paths, so a volume there must not pass: the mount also has to be the mask itself (`isolation_mask_gate`). It must be read-only (`ro` in the options),
    a `tmpfs`, and have the same device (field 3) and root (field 4) as the `/sys/firmware` mount of the same table, which must itself be a read-only `tmpfs`. Without that reference line the
    allowance is refused. Measured in the podman 6.1.3 sample: all 18 crun masks (`/proc/acpi`, `/proc/scsi`, `/sys/firmware`, `/sys/fs/selinux`, powercap twice, 12 `thermal_throttle`) share device `0:3`
    and root `/crun/.empty-directory`; `/sys/firmware` is masked by every podman version, so it is the reference. The root is compared and never printed. Not measured: the `/sys/firmware` device and root on
    4.9.3, which does not matter while no `thermal_throttle` line exists there.
  - `powercap` may repeat once, only as a `tmpfs` mounted on top of the first (the second line's parent id is the first line's mount id; `ISOLATION_MOUNT_STACKABLE`) and only as the same proven
    mask. A third mount, a mount beside the first, another fstype, a repeat that is not the mask (a host tmpfs on top is the visible one) or any other path still fails.
  - `/dev/mqueue` is not listed by `find` when it cannot be opened. `isolation_mqueue_check` requires `stat` to say `directory 1777` (the mode the kernel gives the root of an mqueue
    filesystem), lists it when it can (any entry is stray), and accepts an unreadable one only on the exact `find: '<dir>/mqueue': Permission denied` message (`LC_ALL=C`); any other `find` error still stops the run.
    **Known limit, weaker than before on this path:** where SELinux makes the directory unreadable, a host `/dev/mqueue` bound into the container looks the same as the container's own (fstype `mqueue`,
    mode 1777, same error), and the ipc namespace check only compares the launcher's ids. No sound extra check exists: the host's mqueue device number cannot be known from inside the container, and stat
    fields (owner, time) are mapping artefacts. Where the directory is readable, a non-empty host mqueue is still caught.
  Podman 4.9.3 is proven by the `platforms.yml` run, not by a unit test: no raw 4.9.3 table was kept, and the optional-masks test covers the `/sys/dev/block` rule. The podman 6 sample is
  `tests/fixtures/podman/mountinfo-podman-6.1.3.txt` (host paths scrubbed; tests in `tests/project/test_platform_podman6.sh`). The mount list is read to at most `ISOLATION_MAX_MOUNT_LINES` (500) lines and fails closed beyond that: with about 37 other
  mounts, a host of about 460 CPUs or more aborts the run until the limit is raised.
- **Debian 13 prepare.** `software-properties-common` does not exist on Debian; the package list is now per distribution (`apt_prerequisites`), the Debian default is the source build (no Launchpad PPA is tried), and the
  stock `git` is installed as on Rocky. This was a real failure of the default phases on Debian.
- **Rocky containers need `/etc/shadow` at mode 0400** (`rpm_fix_shadow`). At the image's 000 every `sudo` of a non-root user failed with "PAM account management error" under this runner's rootless podman.
  A setuid `unix_chkpwd` and `rpm --setcaps` did not help; only the mode did (measured in a probe job). A fixture, not a product change.
- **The Rocky VM guest runs with `/usr/local/bin` first on `PATH`** (`bash -l`), as the product tells a user to do; a Rocky 9 login shell lists `/usr/bin` first.

### Results
`ubuntu-container.sh` accepts the phases `upgrade-root|password|bump|old|takeover|offline` besides `upgrade`; `rpm-phase.sh` runs them through `rpm-more-e2e.sh MODE`, which sources `rpm-upgrade-e2e.sh`. The final full run before this repository started over (the commits after it, as of this record, changed documentation only): `gh workflow run platforms.yml --ref ci/real-platform-runs`, all 24 jobs green (`1152 passed, 0 failed, 69 skipped` in each of the three suites). Some results below were first recorded in earlier runs.

| Item | Result | Real output |
|---|---|---|
| Ubuntu 24.04 `--phase upgrade` (PPA, `.sources`) | PASS | `E2E SUMMARY: 27 passed, 0 failed` |
| Ubuntu 22.04 `--phase upgrade` (PPA, `.list`; first container run) | PASS | `E2E SUMMARY: 28 passed, 0 failed` |
| Debian 13 `--phase upgrade` (source build) | PASS | `E2E SUMMARY: 21 passed, 0 failed` |
| Ubuntu 24.04 and 22.04, default phases (prepare, install E2E, whole suite) | PASS | install `E2E SUMMARY: 31 passed, 0 failed`; `SUMMARY: 1108 passed, 0 failed, 67 skipped (total 1175)` on both |
| Debian 13, default phases | PASS | install `E2E SUMMARY: 31 passed, 0 failed`; `SUMMARY: 1108 passed, 0 failed, 67 skipped (total 1175)` |
| Rocky 9.7 `rpm.sh rocky` (source route, takeover, dnf update control, restore, interrupts) | PASS | `E2E SUMMARY: 92 passed, 0 failed` |
| Fedora 44 `rpm.sh fedora` (package route) | PASS | `E2E SUMMARY: 13 passed, 0 failed` |
| Fedora 44 with git-core 2.47.0 installed (old git) | PASS after a product fix | `E2E SUMMARY: 16 passed, 0 failed`; before the fix `Package "git-core-2.47.0-1.fc41.x86_64" is already installed. Nothing to do.` |
| `sudo` with a real password prompt (pty through `script`, random password in a 0600 file) | PASS | three `[sudo] password for gsguser:` for a wrong password, then `sudo: 3 incorrect password attempts` and nothing built; right password: `E2E SUMMARY: 16 passed, 0 failed` |
| Takeover restore with the network off (`--network none` after `podman commit`) | PASS | stage 1 `41 passed, 0 failed`; stage 2 (only `lo`, `curl` and name lookup fail) `12 passed, 0 failed` |
| Direct root run of the full flow, no `sudo` installed | PASS | `E2E SUMMARY: 65 passed, 0 failed` |
| Real pin bump (git 2.55.0 built, then the current pin 2.56.0) | PASS | `E2E SUMMARY: 17 passed, 0 failed` |
| Rocky 9.8 VM, SELinux enforcing, KVM (`/dev/kvm` present) | PASS; the label finding is fixed and checked; a confined domain executing libexec programs was not run here and was later run on a real machine (see the VM section) | `SELinux is enforcing`; `E2E SUMMARY: 88 passed, 0 failed`; `ROCKY VM TEST: PASS (... accel kvm)` |
| GitHub Desktop's bundled git | measured | `old git: exit 0; output: []` for 2.45.3 built from the tarball and for the git in the Desktop 3.4.13 `.deb` |
| Windows scenarios | see "Windows" | |

**Suite failures this work found and fixed.** Debian 13 failed the prepare step (above); once it ran, `test_prerequisites` (four tests) saw the real `/usr/local/bin/git` of the machine and now moves the system paths into the sandbox
like the other gitup tests, and the doctor test needs the stock `/usr/bin/git`, which the Debian prepare step now installs.
Six `test_exemptions_real` tests failed on two of eight runs: they shared one random 32-character `generic-api-key` draw per run. The logs of those runs do not record the key, so the cause is inferred, not proven: the built-in rule
skips a value holding a dictionary stopword (`vpn` is one), and a 62-symbol draw meets one of the many three-letter stopwords far more often than a vowel-free draw does. A vowel-free draw was tried first and still misses by chance (about 1 run in 300 by the reviewer's count), so
the key is now fixed, built from fragments at run time, and the whole file passes with the real betterleaks (27 passed, 0 failed, 1 skipped).

### Rocky VM (SELinux enforcing)

`tests/platform/rocky-vm.sh` boots the dated image `Rocky-9-GenericCloud-Base-9.8-20260525.0.x86_64.qcow2` (SHA-256 in the script, taken from the file's CHECKSUM) under qemu with KVM, cloud-init and an
ed25519 key; the ssh forward is bound to 127.0.0.1 and the guest has no display (`-display none`: `-nographic` cannot be combined with `-daemonize`); the guest script runs under `bash -l`. `tests/platform/rocky-vm-e2e.sh` runs inside it: `getenforce` must say `Enforcing`, then the Rocky E2E (source install, takeover,
dnf update control, restore), plus labels (`stat -c %C`, `matchpathcon`, `restorecon -n -v`), `ausearch -m AVC,USER_AVC` from the start of the run, and `sshd` serving a real push and clone over ssh through
`/usr/bin/git-receive-pack` and `/usr/bin/git-upload-pack` while the takeover is active (the server's `agent=git/2.56.0` shows it is the taken-over git; after the restore it is `agent=git/2.52.0`).
Without a writable `/dev/kvm` the launcher exits 3 and says that TCG software emulation is roughly 10 to 50 times slower, unless `GSG_VM_ACCEL=tcg` is set. This runner has KVM, so TCG was not run.

- **Boot**: the guest accepted ssh after about 10 seconds.
- **SELinux**: enforcing, auditd active; no AVC record from the start of the run to its end, across the install, the takeover, a push and a clone served by sshd through the taken-over links, and the restore.
- **Labels** (what the VM log shows): `/usr/local/bin/git` gets `bin_t` and has one link; in `libexec/git-core`, `git-merge` is a symlink and `git-merge`, `git-upload-pack` and `git-remote-https` are `usr_t`, as the policy says for that directory.
  Which other `bin/git-*` siblings and libexec entries are symlinks, and which are separate programs, was not listed; `/usr/bin/git` and its five links are `bin_t`, `dnf.conf` keeps `etc_t`, `/var/lib/git-secret-guard` is `var_lib_t`; `restorecon -n -v` on `/usr/local/bin`, the six links, `dnf.conf` and the backup directory reports nothing.
- **Finding, fixed.** git installs its siblings as hard links, so git and 150 other names were one inode that the policy labels `bin_t` under `/usr/local/bin` but `usr_t` under `/usr/local/libexec/git-core`:
  a real `restorecon -R /usr/local` relabelled `/usr/local/bin/git` to `usr_t`. The source route now passes `INSTALL_SYMLINKS=1` to `make`, so the installed names are symlinks to `git` (the VM log shows `git-merge` in libexec as one; other entries and the `bin/git-*` siblings were not listed), `git` has one name
  and keeps `bin_t`. In the VM (run in the record above) the checks are real: `git` is `bin_t` with one link, `restorecon -n -R /usr/local/bin` reports nothing, and after a real `restorecon -R /usr/local` `git` is still `bin_t` and a clone served through it works.
  **The fix applies to new builds.** A build made before `INSTALL_SYMLINKS=1` has hard links, and at the same pin it is not rebuilt (the Rocky `bump` scenario runs `install --upgrade-git` again over such a build: no plan, the hard links stay, git keeps more than one name).
  Its first rebuild is the next pin bump: the copy uses `cp --remove-destination`, so each hard link is replaced by a symlink (the same scenario checks `stat -c %h /usr/local/bin/git` is 1 and `libexec/git-core/git-merge` is a symlink afterwards). Until then an administrator who runs `restorecon -R /usr/local`
  on such a machine gets the old behaviour (`/usr/local/bin/git` becomes `usr_t`). Removing the files the MANIFEST lists and running `install --upgrade-git` again rebuilds at once. That ran on a real Rocky 9.7 machine (SELinux enforcing) over a hard-link build: the new build has `git` with one link and `bin_t`, its libexec names are symlinks, and after a real `restorecon -R /usr/local` `git` is still `bin_t` (it changed 138 labels under `/usr/local`; the only git file among them is `share/gitweb/gitweb.cgi`, which became `httpd_sys_script_exec_t`). The dependency install of that rebuild did upgrade installed packages: its dnf transaction installed 141 packages and upgraded 10 (see the source route, step 3).
  The separate programs in `libexec/git-core` (`git-remote-https` and the like) are `usr_t`, as the policy says, from the day they are copied. The takeover judges the target of a symlinked sibling (`gitup_tk_check_owner`) instead of the 777 mode of the link.
  Whether a confined domain may execute `usr_t` files was asked of the policy with `sesearch -A -s DOMAIN -t TYPE -c file -p execute` (rule counts): `httpd_t` 1 rule for `bin_t` and 1 for `usr_t`, `sshd_t` 1 and 1,
  `git_script_t` 2 and 2. Equal counts suggest the same rules cover both types, not more. In the VM no confined process was run (`runcon` cannot enter a confined domain from `unconfined_t` there, even for `/usr/bin/true`).
  **A confined process ran on a real Rocky 9.7 machine** (SELinux enforcing): a CGI script under httpd, in `httpd_sys_script_t` as user `apache`, ran `/usr/local/bin/git`, `/usr/bin/git` through the takeover,
  the separate `usr_t` programs `git-remote-http`, `git-http-fetch`, `git-imap-send`, `git-daemon` and `git-sh-i18n--envsubst` in `libexec/git-core`, and `git ls-remote` over HTTP, once with the hard-link layout and once with the symlink layout.
  No execute was denied. The audit log held only `setpgid` denials of the probe's own `timeout` and the three positive controls (two reads and a write the policy must refuse, all denied). `sshd_t` and `httpd_t` itself were not run.

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
| `winget` | winget 1.11 is on the runner and lists `Git.Git 2.56.0.4`. The plan named the route `winget`, `--scope machine` and "this prompt is already elevated"; winget downloaded, verified the installer hash and upgraded; `git --version` 2.56.0.windows.4; a fake key was blocked. `E2E SUMMARY: 8 passed, 0 failed`. |
| `inuse-winget` | A running Git Bash (`bash.exe`) during the upgrade: winget's installer failed at once with `Installer failed with exit code: 1`, the runner exited 12, git stayed 2.53.0.3, `Git_is1` unchanged, no pending file rename; after the holder ended, the same command upgraded. `7 passed, 0 failed`. That measurement is from before exit 19: the runner now stops first for this route too, so the final run gives exit 19 here. |
| `inuse` (installer route) | The silent installer **hung**: 15 minutes with no output until the harness killed it; git unchanged, no pending rename; after the holder ended, the same command upgraded. Fixed here: the runner now stops first with exit 19 and names the programs. |
| `killed` | The installer was killed 12 seconds after it appeared: product exit 12, `git --version` already 2.56.0.windows.4 but the `Git_is1` record gone, `unins000.exe` present, `usr\bin\bash.exe` missing, no pending renames. A plain rerun could not start (Git Bash was gone). Fixed here: `gsg-bash.cmd` and the installed `.cmd` say `Git for Windows at "<folder>" looks half installed (usr\bin\bash.exe is missing; an installer may have been stopped); run the installer kept in "%LocalAppData%\git-secret-guard\git-upgrade" (Git-version-64-bit.exe), or download one from https://git-scm.com/download/win` and exit 127; a Git for Windows removed completely gets "was not found" instead. An existing install keeps its older installed `.cmd` until its next `install` rewrites it, and only then gets this check. Running the installer file the first run kept (`%LocalAppData%\git-secret-guard\git-upgrade\Git-2.56.0.4-64-bit.exe`) by hand repaired it; `install --upgrade-git` then ended in a blocked fake-key commit. `8 passed, 0 failed`. |
| `signature` | A sandbox copy of the repository whose `tools.lock` pins another signer: the runner exited 10, named both subjects, kept the file (it matched its digest), git unchanged; the unmodified lock then upgraded. `11 passed, 0 failed`. |
| `rerun` | The two legs of the `.cmd` run by hand, the second with a dead proxy and `GSG_GIT_UPGRADED=1`: `install refused; the only change made was the git upgrade of this run (Git for Windows was upgraded just before this run)`; without the proxy the same command completed. `10 passed, 0 failed`. |
| `prompt` | **Not possible on this runner.** A ConPTY is created and sends its set-up sequences, but returns no text of any child (not even `cmd /c echo`), so a typed answer cannot be given to a real prompt. A person at a console must do this one. |

- **Found by these runs, fixed with a test first:** the runner failed with `Get-AuthenticodeSignature ... the module could not be loaded` whenever the parent was PowerShell 7 (its module path leaks into Windows
  PowerShell 5.1) and now resets `PSModulePath` for its own process (`bin/gsg-gitup.ps1`); `bin/gsg-bash.cmd` names a half-installed Git for Windows; the runner stops with the new exit 19 when programs of the install directory run, before the hand-off is used up.
- **Not done:** a real UAC decline (needs a person) and the typed yes above.

