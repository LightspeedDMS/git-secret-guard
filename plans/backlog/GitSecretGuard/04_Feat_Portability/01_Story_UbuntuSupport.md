# Story: Ubuntu 24.04 support

**Feature:** 04_Feat_Portability

## Overview
As a **developer on Ubuntu**, I want git-secret-guard to install and scan exactly as it does on RHEL, **so that** the same protection works on the other Linux machines I use.

**Value after this story:** on Ubuntu 24.04, `git-secret-guard install` either works or names the exact missing prerequisite (with the apt/PPA command to get it). Every commit is then scanned with the same results as on RHEL, proven by the full test suite passing inside an Ubuntu container.

## Acceptance Criteria

```gherkin
Scenario: The full suite passes on Ubuntu 24.04
  Given a podman ubuntu:24.04 container with a copy of the checkout, the distro's default awk (mawk), jq from apt,
        and a git >= 2.54 (from the git-core PPA if it has one, otherwise built from the verified upstream tarball)
  When tests/platform/ubuntu.sh runs tests/run.sh inside it
  Then the summary shows 0 failed, and every SKIPPED test is explained (e.g. no network)
  And the same suite still passes on this RHEL 9-compatible machine (Rocky Linux 9.7)

Scenario: awk code is portable or gawk is an explicit, checked dependency
  Given the awk programs (lib/extract.awk, the inline awk in lib/*.sh, tests/comment-rules.awk)
  When they run under mawk
  Then they produce identical results to gawk (pinned by tests that run both when both are installed)
  Or, if a construct cannot be made portable, install refuses without gawk and prints "sudo apt install gawk",
     and the hook calls the recorded absolute gawk path (no PATH lookup, as for the other tools)

Scenario: Missing prerequisites are named with the fix
  Given Ubuntu's git is older than 2.54, or jq is missing
  When I run git-secret-guard install
  Then it refuses and prints the exact command to fix it (PPA or apt line), changing nothing

Scenario: Install E2E inside the container
  Given the container with the prerequisites
  When I install, commit a runtime-built fake secret (blocked by both scanners), upgrade, uninstall
  Then the results match RHEL and no value is printed

Scenario: The platform test never leaks host state
  When tests/platform/ubuntu.sh starts the container
  Then no host environment variables are passed in (no --env-host, no -e of host values), the host HOME,
       ~/.gitconfig and ~/.ssh are not mounted, and only a copy of the checkout is mounted read-only
  And no containers.conf layer (system or user) is read (CONTAINERS_CONF names a scratch file) and the OCI hooks directory is an empty scratch directory
  And the container aborts the run before any apt or network step when its mount points differ from the exact list of an unmodified
      container, when a podman-created target shows another fstype, when a mount point is mounted twice, when the /dev tree holds an
      entry outside the baseline, or when its cgroup, ipc, net, pid or uts namespace is the launcher's
  And what is only a trust decision (root-owned podman and runtime, storage.conf, registries.conf and policy.json, the user and time
      namespaces, the contents of /proc and /sys) is listed in README.md under "What the platform run trusts"

Scenario: Documentation states exactly what is supported
  Then README.md has a "Supported platforms" section: RHEL 9-compatible (tested on Rocky Linux 9.7), Ubuntu 24.04 (tested in
       a container, with the prerequisite commands), macOS not supported yet (port planned on a Mac)
```

## Implementation Status
- [x] tests/platform/ubuntu.sh (podman, read-only copy of the checkout, no host env)
- [x] Suite green in ubuntu:24.04 (mawk) and still green on RHEL 9
- [x] Portability fixes or an explicit, checked gawk dependency (no awk change was needed: every awk program is identical under mawk and gawk, pinned by tests/test_awk_portability.sh; the fixes were in the test infrastructure)
- [x] Prerequisite messages with apt/PPA commands
- [x] README "Supported platforms"

**Review round 1 (code review and manual E2E), all fixed test first:**
- [x] H1 podman starts under `env -i` with a fixed allow-list; the container checks variable NAMES against an allow-list; a failed check aborts before any apt or network step
- [x] H2 scratch `HOME` with an empty `.config/containers/mounts.conf` suppresses the RHEL `/run/secrets` mount (proved with a positive control); the check also fails on a non-empty `/run/secrets` (count only)
- [x] M1 `podman run --init` and `timeout -k 60`; M2 `tests/platform/ubuntu.sh` is mode 755
- [x] E2E-1 install checks every prerequisite and refuses once, naming all of them
- [x] L1 image pinned by manifest-list digest; L2 PPA key fingerprint pinned and checked, trust decisions in the README; L3 copy = `git ls-files -co --exclude-standard`
- [x] L4 awk's own error text sanitized; L5 and L9 os-release read as data, no raw bash error; L6, L7 notes in CLAUDE.md; L8 wording "RHEL 9-compatible (tested on Rocky Linux 9.7)"; nit on the uninstall message
- [x] Code review and manual test executor repeated (round 2: review REJECT, manual E2E PASS)

**Evidence (review round 1).** Real container run of `tests/platform/ubuntu.sh` to completion: `530 passed, 0 failed, 2 skipped (total 532)`, install E2E `31 passed, 0 failed`, mawk 1.3.4 as the default awk, git 2.56.0 from `ppa:git-core/ppa` with the key fingerprint check `ok`; the two skips are the host's `cidx-server` unit tests. Host suite: `525 passed, 0 failed, 7 skipped` (the extra skips need mawk, which this host lacks; they ran in the container). Probes: with a `containers.conf` `env` entry naming a marker variable, a container started the old way aborted with only the variable NAME printed and no apt step; the real script with the same override in the caller environment passed the isolation check and a `--timeout 20` run ended at 21 s with exit 124 and no container left behind.

**Review round 2 (code review and manual E2E round 2), all fixed test first:**
- [x] H `containers.conf` `volumes`/`devices` could put host paths into the container while `check_isolation` passed: the container now checks every mount point (field 5 of `/proc/self/mountinfo`) against an allow-list and the top level of `/dev` against the 15-entry baseline, fail closed on an unreadable source, names only; podman also gets a scratch `XDG_CONFIG_HOME`, so `~/.config/containers` is not read
- [x] M1 PPA: `add-apt-repository -y -n`, fingerprint check, then `apt-get update`; a mismatch deletes the `.sources` file and refreshes apt before the source build
- [x] M2 project `.gitignore` (`.tmp/ .analysis/ reports/ .env*`) pinned with `git check-ignore`; the README says untracked files that are not ignored ARE copied and points at the `copy-file:` list of `--dry-run`
- [x] L1 unreadable environ list fails closed; L2 an entry without `=` or with an empty name prints a fixed placeholder (and a variable named `PATH HOME` no longer passes the allow-list); L3 no stray `?` at the end of the sanitized awk error
- [x] Nits: `realpath` failure in `install_warn_other_gits` prints a message; the cleanup `podman rm -f` runs under `timeout`; "nothing was changed" is said once in the `--with-timer` refusal; CLAUDE.md note on `podman exec` (`env -i` style environment)
- [x] Code review and manual test executor repeated (round 3: review REJECT, manual E2E PASS except F1)

**Evidence (review round 2).** Real container run of `tests/platform/ubuntu.sh` to completion: `543 passed, 0 failed, 2 skipped (total 545)`, install E2E `31 passed, 0 failed`, mawk 1.3.4 as the default awk, git 2.56.0 from `ppa:git-core/ppa` (fingerprint check `ok`, added with `-n`); the two skips are the host's `cidx-server` unit tests. Host suite: `538 passed, 0 failed, 7 skipped (total 545)` (the extra host skips need mawk). Real H attack, `--phase e2e` so no apt step is reachable: a caller-exported `CONTAINERS_CONF_OVERRIDE`/`CONTAINERS_CONF` with a `volumes` entry and a caller `XDG_CONFIG_HOME` holding such a layer both pass the check (neither is read); a system-layer-like override with `volumes` aborts printing only `/root/injected`, one with `devices` only `gsgfuse`; each run ends `ABORT: the isolation check failed; nothing was installed or downloaded` and no container is left behind.

**Review round 3 (code review and manual E2E round 3), all fixed test first:**
- [x] H root cause: podman starts with `CONTAINERS_CONF=<scratch>/containers.conf`, so no system or user `containers.conf` layer (volumes, devices, env, namespaces, sysctls, hooks) is read; the file holds `hooks_dir` = an empty scratch directory, which turns the OCI-hook trust decision into a control (positive control: a hook in a configured `hooks_dir` ran, with the empty one it did not). The empty user `mounts.conf` stays (probed: still honoured under `CONTAINERS_CONF`, `default_mounts_file` has no effect for rootless). Pinned by `--dry-run`
- [x] H defence in depth: exact list of 33 mount points with the fstype of the targets podman creates, each mount point once, bounded; `/dev` listed to depth 4 against 17 baseline entries, names below `shm`/`mqueue`/`pts` only counted; cgroup, ipc, net, pid and uts namespaces compared by inode with the launcher's (`--host-ns` arguments); the `ok` line names what was checked; the run summary names the image digest
- [x] H bypass re-run (real containers, three variants each): volumes onto `/dev/shm`, `/dev/shm/x`, `/etc/hosts`, `/run/.containerenv`, `/dev/mqueue`, devices onto `/dev/shm/gsgfuse`, `ipcns = host`, `netns = host`, the tester's `:ro` variants: layer ignored by the shipped launcher, aborted with the layer forced through `CONTAINERS_CONF_OVERRIDE`. A volume onto `/src` is a no-op (the command-line `-v` wins)
- [x] M1 gap: `install_git_ppa` returns 2 when `ppa_disable` fails and `obtain_git` stops without the source build; stub tests for a failed disable (`rm` and `apt-get update`), a failing `add-apt-repository` after writing a `.sources` file, a failing `apt-get update (PPA)`; `ppa_disable` also removes a `.list` file
- [x] M2 `.gitignore` is exactly `.tmp/ .analysis/ reports/troubleshooting/ .env*` (the round 2 line above listed `reports/` whole, which kept `reports/bugs/` out of git); the check-ignore test says `reports/bugs/x.md` is not ignored
- [x] Nits: the hook's message after an awk write failure says the extraction failed and keeps the sanitized awk line; the stale `tar` comment in `ubuntu.sh` reworded
- [x] Docs: README "What the platform run enforces" and "What the platform run trusts", CLAUDE.md "Review round 3"
- [x] Code review and manual test executor repeated (round 4: review REJECT on powercap only, manual E2E PASS 6/6, F1 closed)

**Evidence (review round 3).** Real container run of `tests/platform/ubuntu.sh` to completion: `563 passed, 0 failed, 2 skipped (total 565)`, install E2E `31 passed, 0 failed`, mawk 1.3.4 as the default awk, git 2.56.0 from `ppa:git-core/ppa`, image `docker.io/library/ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852` named in the summary; the two skips are the host's `cidx-server` unit tests; no container left behind. Host suite: `558 passed, 0 failed, 7 skipped (total 565)` (the extra host skips need mawk). The comment lint and the shellcheck 0.11.0 gate pass.

**Review round 4 (code review round 4), fixed test first:**
- [x] M1: `/sys/devices/virtual/powercap=tmpfs` added to `ISOLATION_MOUNT_RULES` as an optional entry (podman 5.6.0 default mask, present where `intel_rapl` exists); `test_the_mount_check_accepts_the_optional_masked_paths_other_kernels_add` extended (failed before: `[/sys/devices/virtual/powercap] as tmpfs ... expected exit 0 got 1`; passes after). The rest of podman's default masked and read-only paths were compared with the binary: nothing else was missing
- [x] L1: the seccomp profile (`/usr/share/containers/seccomp.json`, root-owned, not covered by `CONTAINERS_CONF`) moved into the trusted root-owned files in README "What the platform run trusts"
- [x] L2: README says podman is "the podman found first on your `PATH`" (the launcher passes the caller's `PATH`); not pinned
- [x] L3: CLAUDE.md no longer claims a kernel without selinuxfs aborts (the check rejects extra, duplicate or wrong-fstype mount points, never a missing one); README "What the platform run enforces" says the mount table is host-specific and how to adjust it; cgroup v1 aborts by design
- [x] Code review and manual test executor repeated (round 5: **review APPROVE**, manual E2E PASS 3/3)

**Final approval (review round 5).** code-reviewer: APPROVE. It independently re-derived podman 5.6.0's default masked and read-only lists from the binary, and all are in the table. The powercap entry is optional, tmpfs-only and exact; lookalikes, a duplicate, the wrong fstype and a submount are all named. Host suite: `558 passed, 0 failed, 7 skipped`; shellcheck clean; dry run clean. manual-test-executor: PASS. The platform run from a snapshot gave `563 passed, 0 failed, 2 skipped`, E2E `31 passed, 0 failed`, `UBUNTU PLATFORM TEST: PASS`. In real pinned-image containers a `/sys/dev/block` mask is rejected and named, and the default container is admitted. A real powercap mask cannot be exercised on this VM, which has no powercap; a synthetic mountinfo line is admitted only as tmpfs. The machine fingerprint is unchanged. The round-5 low doc findings (`/proc/asound` is read-only, `/sys/fs/selinux` is masked, the `/etc/containers/seccomp.json` override path, powercap is not tied only to `intel_rapl`) are fixed in README.md and CLAUDE.md. Left as is: the `intel_rapl` wording in the `ubuntu-container.sh:184` comment and an optional rc assertion in the test.

**Evidence (review round 4).** Real container run of `tests/platform/ubuntu.sh` to completion: `563 passed, 0 failed, 2 skipped (total 565)`, install E2E `31 passed, 0 failed`, mawk 1.3.4 as the default awk, git 2.56.0 from `ppa:git-core/ppa`, image `docker.io/library/ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852` named in the summary, `UBUNTU PLATFORM TEST: PASS`; the two skips are the host's `cidx-server` unit tests; no container left behind. Host suite (five batches, each under `timeout 590`): `558 passed, 0 failed, 7 skipped (total 565)`. The comment lint and shellcheck pass (`tests/test_quality.sh` 21 of 21). Real mask probe on the pinned image under the launcher's settings (`env -i`, scratch home, `CONTAINERS_CONF`): this VM has no `/sys/devices/virtual/powercap`, so crun skips `--security-opt mask=/sys/devices/virtual/powercap` (no mount appears) and `--tmpfs` there fails (`crun: mkdir ... Permission denied`); with an existing directory instead (`--security-opt mask=/sys/devices/virtual/misc`) the container shows a `tmpfs` mount at that mount point, the shipped table names it (rc 1) and the table with that one entry accepts it (rc 0); the negative control `--security-opt mask=/sys/dev/block` still fails naming `/sys/dev/block` (rc 1).

**Evidence (implementation round 1).** Final real container run: `510 passed, 0 failed, 2 skipped (total 512)` as a non-root user with mawk 1.3.4 as the default awk, plus the install E2E `31 passed, 0 failed`; the two skips are the host's own `cidx-server` unit tests ("cidx-server unit cannot be read"). git came from `ppa:git-core/ppa` (`1:2.56.0-0ppa1~ubuntu24.04.2`); the SHA-256 verified source build of `git-2.56.0.tar.xz` was also run for real (508 passed on the first run, the two failures were a stale copy). Code review and the manual test executor are still to come.

## Technical Requirements (pseudocode only)
```
ubuntu.sh:
  require podman; image ubuntu:24.04 (pull if absent)
  run container: --rm, no host env, mount a fresh copy of the checkout read-only, work in a container tmp dir
    apt-get install jq ca-certificates curl (+ software-properties-common for the PPA) ...
    get git >= 2.54: PPA if it has it, else verified source build
    run tests/run.sh; then an install E2E as a non-root user
  print the summary; exit nonzero on any failure
```

## Testing Requirements
- Run the container test for real, not as a dry run. Paste the summary.
- Verify that the git source for the container (PPA version or tarball SHA) is pinned and checked.

## Definition of Done
- All scenarios pass, code-reviewer approves, and manual-test-executor reproduces the container run with evidence. The README is updated.
