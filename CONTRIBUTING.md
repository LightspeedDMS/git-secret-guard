# Contributing to git-secret-guard

Thanks for helping. git-secret-guard is plain bash (no Python or Node), and it guards commits for people who rely on
it, so changes are held to a high bar: every behaviour has a test, and every user-visible behaviour is documented.

## Reporting

- **Bugs and feature requests:** open a [GitHub issue](https://github.com/LightspeedDMS/git-secret-guard/issues). For a
  bug, include the platform (on Windows, whether you used Git Bash, PowerShell or cmd), `git --version`, `bash --version`, the output of `git-secret-guard status` and
  `git-secret-guard doctor`, the steps to reproduce, and what you expected instead.
- **A way to get a secret past the hook, or any other security problem:** do **not** open a public issue. Use
  [private vulnerability reporting](https://github.com/LightspeedDMS/git-secret-guard/security/advisories/new)
  (Security tab, "Report a vulnerability").
- **Never paste a real credential** into an issue, a pull request or a test, not even a revoked one.

## Setting up

You need the same tools as a user (see [README.md](README.md#requirements) and [docs/platforms.md](docs/platforms.md)).
Development is supported on all three platforms:

| | Windows x86_64 | macOS arm64 | Linux x86_64/arm64 |
|---|---|---|---|
| **Needs** | [Git for Windows](https://git-scm.com/download/win) | Homebrew, `brew install bash coreutils util-linux jq` | bash 4.4+, `jq`, `setsid`, `timeout`, `curl`, `tar`, gawk or mawk |
| **git 2.54 or newer** | the one on `PATH` | `/usr/bin/git` | `/usr/local/bin/git` |
| **Run the tests with** | `tests\run.cmd` (PowerShell, cmd) or `tests/run.sh` (Git Bash) | `tests/run.sh` | `tests/run.sh` |

Older git silently ignores config hooks, so most tests would prove nothing; set `GSG_TEST_GIT=/path/to/git` to use another.
`GSG_TEST_SERVICE_UNIT=<unit>` runs the service-environment tests against a systemd unit whose `User=` is you and that sets `PATH=`; unset, those tests skip.

- [shellcheck](https://github.com/koalaman/shellcheck) **0.11.0** for the lint gate (`pipx install shellcheck-py==0.11.0.1`;
  on Windows also the `shellcheck.exe` of the [0.11.0 release](https://github.com/koalaman/shellcheck/releases/tag/v0.11.0),
  put in `~/.local/bin`); with another version the gate is skipped, not passed. The gate uses `~/.local/bin/shellcheck`, else
  the one on `PATH`; `GSG_TEST_SHELLCHECK=/path/to/shellcheck` names another. The pin is `GSG_SHELLCHECK_PIN` in `tests/project/test_quality.sh`.
- Optional: `pre-commit`, for the framework coexistence tests.

The real trufflehog and betterleaks are needed only by the tests that pin their behaviour; without them those tests
skip with a reason. `tests/fetch-test-tools.sh [DIR]` downloads the versions pinned in `tools.lock` into
`${XDG_CACHE_HOME:-~/.cache}/git-secret-guard-test-tools` (or `DIR`) and checks their SHA-256, skipping a tool already there
at its pinned version; `--check [DIR]` only lists what the cache lacks (exit 3). On Windows and macOS the tests look in that
cache by default. On Linux trufflehog is `~/.local/bin/trufflehog` and betterleaks the cache's copy when there is one, else
`~/.local/bin/betterleaks`; `GSG_TEST_TRUFFLEHOG` and `GSG_TEST_BETTERLEAKS` name other files (the cached ones, or your own copies
of the pinned versions). On Windows, `tests/run.sh` fetches the cache for you the first time, with `jq.exe` and the pinned
Git for Windows installer (only read by the upgrade tests, never started), so Git for Windows is all you install.

## Running the tests

```bash
tests/run.sh                          # the whole suite
tests/run.sh tests/scan               # one folder: the tests of one lib/ context
tests/run.sh tests/integrations       # a folder that holds folders: smartgit and desktop
tests/run.sh tests/scan/test_hook.sh  # one file
```

From PowerShell or cmd on Windows:

```powershell
tests\run.cmd                         # the whole suite
tests\run.cmd tests\scan              # one folder
tests\run.cmd tests\scan\test_hook.sh # one file
```

The runner takes folders and files; an argument that is neither fails by name before any test runs. With no argument it runs every
`test_*.sh` one and two levels below `tests/`, ordered by base name (`tests/project/test_quality.sh` checks that no test file
sits where it would not be found).

Always go through the runner on macOS and Windows: on macOS it puts Homebrew's bash and the GNU tools first on `PATH`, on
Windows it fetches the test tools and `tests\run.cmd` finds Git for Windows' bash (never the WSL one in `System32`).

On an Intel Mac with Homebrew in `/usr/local` ([Homebrew on an Intel Mac](docs/platforms.md#homebrew-on-an-intel-mac)) the runner needs `brew`
on `PATH` and a git of 2.54 or newer, and a non-login shell (an `ssh host command`) has neither, so start it like this from the checkout:

```bash
PATH=/usr/local/bin:/usr/local/opt/coreutils/libexec/gnubin:$PATH GSG_TEST_GIT=/usr/local/bin/git /usr/local/bin/bash tests/run.sh
```

Apple Git (`/usr/bin/git`) is older than 2.54 there, which is why `GSG_TEST_GIT` names the Homebrew one. Homebrew builds every formula from
source on that Mac, so the first setup takes about an hour and a half; the suite itself runs as on any Mac.

On Windows a test that cannot apply there is reported as `SKIPPED` with its reason, never as passed: see
[what the suite covers on Windows](docs/platform-testing.md#the-test-suite-on-windows). The suite is slower there, because starting
a process costs far more than on Linux: files run in parallel by default (`GSG_TEST_JOBS` sets how many, default the number of
processors; also on Linux and macOS, where the default is one), and during development it is best to run the files you touched.

The runner prints one `PASS`, `FAIL` or `SKIPPED` line per test and ends with `SUMMARY: N passed, N failed, N skipped (total N)`;
it exits 0 only when nothing failed. A test file is killed after `GSG_TEST_FILE_TIMEOUT` seconds (default 900, 2400 on Windows),
and a file that reports no result, exits non-zero without a `FAIL` line, or (files in parallel) leaves no exit status because its
worker died, counts as one failure. A skip is not a pass: read the
skip count before calling a change tested.

Every test file runs in a throwaway sandbox with its own `HOME` and global git config, so the suite never touches your
own git configuration or installed hook. The container and VM runs (`tests/platform/`: Ubuntu and Debian through `ubuntu.sh`,
Rocky and Fedora through `rpm.sh`, a Rocky VM with SELinux enforcing through `rocky-vm.sh`, the old-git check `old-git-e2e.sh`,
and `wsl-ci.sh`, which refuses to run outside GitHub Actions) are described in [docs/platform-testing.md](docs/platform-testing.md#ci-on-real-platforms);
they are not part of `tests/run.sh`.

## Rules for changes

- **Tests first.** A bug fix starts with a test that fails without it; a feature comes with tests for its behaviour,
  including the failure paths. Prefer real git and real files; the scanner stand-ins in `tests/stubs/` exist to
  drive cases the real tools cannot produce on demand.
- **No secret-looking literals, anywhere.** Fake credentials are built at runtime from fragments (`fake_aws_key`,
  `fake_github_token` in `tests/support/lib.sh`) and never printed. `tests/project/test_quality.sh` scans the tree with the real
  scanners, and this repository is guarded by its own hook.
- **Never dump the environment** (`env`, `set`, `export -p`) in a test or debug hook: it can print real tokens.
- **Fail closed.** When the hook cannot scan what it is meant to scan, it blocks the commit and says why: an unusable
  tool, a settings or exemption file it cannot load, a failed extraction, an LFS object it cannot verify, a scanner that
  fails or times out. An error never becomes a pass. What is not scanned by design (binary and UTF-16 files, files the
  repository exempts, commits that fire no `pre-commit` or `commit-msg` event, tag messages and notes) is listed in
  [docs/scan.md](docs/scan.md#limits). Check every return value, keep
  loops bounded, use `set -u`.
- **Lint clean:** shellcheck 0.11.0 with no findings (info included). Comments use the coded form `# ^ tag clause`,
  checked by `awk -f tests/comment-rules.awk FILE` (`tests/run.sh tests/project/test_quality.sh` runs both).
- **Keep files under 1000 lines;** split by responsibility when one grows past that.
- **Document behaviour changes** in the matching file under `docs/` (and `README.md` when it is part of the overview).
  `tests/project/test_quality.sh` checks several documented promises.
- **Portability:** the hook and CLI run on Linux, macOS (BSD userland behind Homebrew's GNU tools) and Windows (Git for
  Windows bash with native `.exe` tools). The awk programs must give identical output under gawk, mawk and macOS awk
  (`tests/scan/test_awk_portability.sh`). On Windows, native tools answer in `C:/` paths while bash uses `/c/`, there are no
  process groups, and `ln -s` behaves differently: `lib/core/proc.sh`, `gsg_is_windows` and `tools_binary_name` are the places
  for that, and `tests/platform/test_windows.sh` is where it is tested on every platform.
- **`.cmd` files stay CRLF** (`.gitattributes`); everything else is LF, also in a Windows checkout.

[CLAUDE.md](CLAUDE.md) is the index of the rules and the invariants a "simplification" breaks; the maintainer notes (why the code is
shaped the way it is) are at the end of each file in `docs/`, and CLAUDE.md links the right one. Read it before changing the hook,
extraction, exemptions or install. It is written for AI coding agents too.

## Where a new file goes

`lib/` holds one folder per bounded context and no file sits directly in it. Pick the folder by what the code does, not by a name
prefix, and read that folder's README first: [core](lib/core/README.md), [scan](lib/scan/README.md), [install](lib/install/README.md),
[inspect](lib/inspect/README.md), [autoupdate](lib/autoupdate/README.md), [gitup](lib/gitup/README.md),
[integrations](lib/integrations/README.md), [platform](lib/platform/README.md), [cli](lib/cli/README.md). The hook loads only
`lib/core/` and `lib/scan/` (the lists `GSG_HOOK_LIBS` and `GSG_HOOK_FILES` in `lib/core/common.sh`, relative to `lib/`), and `lib/core/`
sources nothing outside itself. `tests/project/test_quality.sh` enforces this (`test_the_hook_lists_name_only_files_under_lib_core_and_lib_scan`,
`test_lib_core_sources_nothing_outside_lib_core`, `test_every_library_source_target_exists`, `test_no_file_sits_directly_in_lib`).
A library the CLI loads is added to the list in `bin/git-secret-guard` by its path relative to `lib/`.

## Where a new test goes

`tests/` follows the same folders: a test file goes in the folder of the `lib/` context it mostly exercises (`tests/scan/`,
`tests/install/`, and so on; `tests/integrations/smartgit/` and `tests/integrations/desktop/` for the integrations), and a gate on the
repository itself goes in `tests/project/`. Read the folder's README first. The file name stays `test_<name>.sh`, unique across all
folders, because a test's identity in the output, in `tests/windows-skips.list` and in `tests/macos-only.list` is `file::test` with the
base name. A helper that tests of more than one folder load goes in `tests/support/`; one that a single folder loads lives in that folder;
a test or helper loads helpers only from `tests/support/` and its own folder. `tests/run.sh`, `tests/coverage.sh`, the skip lists and
the other entry points stay directly in `tests/`; nothing else does. `tests/project/test_quality.sh` enforces this
(`test_no_test_file_or_helper_sits_directly_in_tests`, `test_every_test_helper_source_resolves_to_tests_support_or_the_files_own_folder`,
`test_test_file_base_names_are_unique`, `test_every_folder_holding_test_files_has_a_readme`,
`test_the_runners_no_argument_list_is_every_test_file_at_any_depth`, `test_every_skip_list_entry_names_an_existing_test`).

## Adding an OS module

`install` can offer to upgrade an old git (`install --upgrade-git`). The offer, the consent rules, the ordering with the other checks, the re-verification and the
"what changed" refusal text live in `lib/gitup/gitup.sh` and are shared. An OS plugs in with **one file and one line**, and edits none of that logic:

1. **The file** `lib/gitup/gitup_<module>.sh` (a plain lowercase word; `rpm` is the example). It is CLI-only: the hook never loads it. A module looks a tool up on `PATH` only
   through `install_find_bin NAME [PATH]` (`lib/install/install.sh`, sets `REPLY`): `type -P` is allowed only in `lib/install/install.sh`, `lib/platform/brew.sh` and the one line of `smartgit_tool`
   (`test_the_hook_never_looks_tools_up_on_PATH`).
2. **The line** in `gitup_registry` (`lib/gitup/gitup.sh`). Every class `gitup_os_class` detects (`rpm`, `ubuntu`, `debian`, `macos`, `windows`, `wsl`, `other`) has its line, and
   all have a module except `other) REPLY="" ;;`, the one reserved line left: a module for `other` replaces its `REPLY=""` by `REPLY=<module>`. A new class also needs
   `gitup_os_class` to detect it, and adds its own `name) REPLY=<module> ;;` line before `other)`. **Keep the comment line between the entries:** git treats two changed
   lines that touch as one conflict (real merges showed it); with a comment line between them, branches that each change a different existing line merge cleanly. Two
   branches that both add a line at the same place still conflict. `test_branches_that_each_take_one_reserved_registry_line_merge_without_conflicts` (`tests/gitup/test_gitup_round2.sh`) runs those merges
   over the lines still reserved (`REPLY=""`) and skips while fewer than two are, so with only `other` reserved it is dormant. The registry is a plain `case`; there is no globbing and no
   generated name outside `gitup_call`. `gitup_os_class` already detects every class, WSL (class `wsl`, the wrapper module `lib/gitup/gitup_wsl.sh`) included. Shared files a module branch does
   not edit: `tests/coverage.sh` globs `lib/gitup/gitup*.sh`, the registry test reads the class list from the library, the merge test (`test_branches_that_each_take_one_reserved_registry_line_merge_without_conflicts`) takes the classes still reserved from the library, the CLI loads only the shared `gitup` and
   `gitup_source`, a module sources its own helper libraries (`gitup_rpm.sh` does it for `gitup_takeover.sh`), and the contract tests use synthetic classes
   (`gu_tree_add_class` in `tests/support/gitup.sh`), so they need no edit. **What a class branch does edit:** the tests that pin today's refusal for that class, because the
   refusal goes away when the class gets a module (`test_a_class_with_no_module_keeps_todays_refusal_and_offers_nothing` in `tests/gitup/test_gitup.sh`, the cases of that class
   in `tests/install/test_prerequisites.sh`, and the takeover refusal in `tests/gitup/test_gitup_takeover.sh`). Two branches that both change the same test conflict there; agree who
   goes first.
3. **The contract.** Required:
   - `gitup_<module>_plan MODE` prints what `apply` would do and names each privileged command with `gitup_plan_priv "<command>"` (the full path of the tool root runs, from
     `gitup_system_bin NAME`) and each caveat with `gitup_plan_note "<text>"`. `MODE` is `upgrade` (git missing or old) or `refresh` (git is fine; rc 1 and nothing printed when
     nothing is stale, rc 2 with the reason printed when a rebuild is needed but cannot be done now: the install goes on, or is refused when `--upgrade-git` asked for it). It
     sets `GITUP_ROUTE` (`path-fix` with `GITUP_FOUND_GIT` when a qualifying git exists but is not first on `PATH`: the core prints the exact fix and refuses, `apply` is not
     called). rc 0 = a plan, rc 1 = no route, with the reason printed.
   - `gitup_<module>_apply` carries out `GITUP_ROUTE`. rc 0 = done (the core re-resolves git and requires 2.54; set `GITUP_NEW_GIT` to the git it installed so a refusal can
     print the `export PATH` line), rc 1 = failed (set `GITUP_CHANGED`, or add clauses with `gitup_changed_add`, so later refusals say what changed), rc 2 = it must finish
     outside this process (set `GITUP_NEXT`; the core stops with exit 3 and prints it).
   - Optional, **all five or none** (`gitup_module_check` refuses half): `gitup_<module>_takeover_supported PATH` (compare real paths), `_takeover_plan PATH` (prints only on rc 0; on
     rc 1 refused and rc 2 nothing to do it sets `GITUP_REASON`), `_takeover_apply PATH`, `_takeover_restore`, `_takeover_status` (sets `GITUP_TK_STATE`, `GITUP_TK_TEXT`,
     `GITUP_TK_HOWTO` and `GITUP_TK_TARGET`).
   - Optional, **both or neither**: `gitup_<module>_can_elevate` and `gitup_<module>_elevate CMD...`, for a platform with its own way to elevate that runs privileged commands from this process. The core's
     `gitup_can_elevate` and `gitup_elevate` call them first; every privileged command runs under `umask 022`. The `windows` module defines neither: it elevates in its PowerShell runner, after the process has ended.
   - Optional singles: `gitup_<module>_takeover_unavailable` prints why `--take-over-system-git` cannot be done on this platform, and the install continues instead of refusing;
     `gitup_<module>_abort` is called once when the process exits inside `apply` or `takeover_apply` (an interrupt), so the module can undo a half-made change.
   - **Core variables a module may read:** `GITUP_PLAN_REFUSED` is 1 after a module's plan returned rc 1, set before `install_require_git` prints its hint, so a hint can avoid recommending `--upgrade-git` where the flag would refuse again (only the Windows hint reads it today). `GSG_INSTALL_FLAGS` holds the flags of the install run besides `--upgrade-git`, for a module that prints a next step.
   - **A module that wraps another class** (WSL) calls `gitup_delegate CLASS KIND ARGS...` to run the inner module's `plan` or `apply` and adds its own `gitup_plan_note`.
     **A wrapper must also forward `abort`** (`gitup_<wrapper>_abort() { gitup_delegate CLASS abort; }` when the inner module defines one) and the takeover functions it
     supports. Nothing checks this: a wrapper without it leaves the inner module's half-made change in place when the process is interrupted.
   - **A module never prompts, never decides consent and never prints its own refusal after a failed apply.** Privileged commands go through `gitup_elevate` and are
     planned with `gitup_plan_priv`. Both resolve a tool given by name with `gitup_system_bin` (the fixed system path, root-owned, not writable by others), so the plan prints
     the full path that runs. A root run never finds a tool through the caller's `PATH`, and a name missing from the system path is refused by name. The plan lists every
     command, `mkdir` included, and takes its words from the same place as the apply step (the `cp` words of the source route are one array, `GITUP_SRC_CP`, used by both). Reuse `gitup_source_apply`, `gitup_source_print_plan` and
     `gitup_source_plan_refresh PREPARE_FN` (set `GITUP_SRC_DEPS` and `GITUP_SRC_FLAGS` in `PREPARE_FN`, and `GITUP_SRC_PRE` when a privileged command must run before the dependency install, as `apt-get update` does; the plan and `gitup_source_compile` both take it from there), `tools_fetch_verified` (SHA-256 against `tools.lock`) and
     `gitup_version_at_least`. A plan whose commands depend on checks made between them (a signing key, a version floor) sets `GITUP_PRIV_BYHAND=0`: with neither root nor `sudo` the core then tells the user to run install as root instead of listing commands to type. `gitup_offer_upgrade` and `gitup_offer_refresh` reset it to 1 before each plan.
4. **The tests.** `tests/support/gitup.sh` has the helpers (`gu_tree_with_module` builds a copy of the product with your module and its one registry line, `gu_tree_add_module` adds a
   second one), and `lc_begin` puts recording stand-ins for `sudo`, `dnf`, `rpm`, `restorecon`, `make`, `df`, `ldd` and (`tests/support/apt.sh`) `apt-get`, `apt-cache`, `add-apt-repository` and `gpg` first on `PATH` and as the only places the fixed system path
   looks in; a real tool is never reached. `test_every_registered_module_implements_the_contract` (in `tests/gitup/test_gitup.sh`) loads every module in the registry and fails
   naming the module and the missing function, so a new module is checked by being added. `tests/gitup/test_gitup_contract.sh` shows each optional capability driven through a test
   module. System paths come from `GSG_GITUP_ROOT` (a sandbox directory in tests), never from `/usr`, `/etc` or `/var` directly. **Fixtures copy the real layout**: the RPM
   has three relative symlinks among its six files, and fixtures of six regular files hid a data-loss bug.
5. **The docs** to update: `docs/platforms.md` (the platform section), `docs/install.md` (with its [git upgrade maintainer notes](docs/install.md#maintainer-notes-git-upgrade)), `lib/cli/usage.md`, and the install hint in
   `install_git_hint` for the class.

## Sign your commits (DCO)

Contributions are accepted under the [Developer Certificate of Origin](DCO.txt) 1.1: by signing off, you certify that you wrote
the change or have the right to submit it under this project's license. Every commit needs a `Signed-off-by:` line with the
name and email of its author:

```
Signed-off-by: Your Name <you@example.com>
```

- **New commits:** `git commit -s` adds the line from your `user.name` and `user.email`.
- **The last commit:** `git commit --amend -s --no-edit`.
- **A whole branch:** `git rebase --signoff origin/main`, then `git push --force-with-lease`.

CI checks every commit of a pull request (`.github/scripts/check-dco.sh BASE HEAD`, merge commits skipped) and fails, naming
the commits, when the sign-off is missing or does not match the commit's author. Commits already on `main` are not checked.
The copy of the script on the pull request's base judges it, so a change to the check cannot pass itself. Run it yourself with
`.github/scripts/check-dco.sh origin/main HEAD` (exit 0 all signed, 1 unsigned commits, 2 a usage or git error; a range of more
than 1000 commits, `DCO_MAX_COMMITS`, is refused rather than cut short).

## Pull requests

1. Open or pick an issue first for anything larger than a small fix, so the approach can be agreed.
2. Branch from `main`, keep the change focused, write commit messages that say why, not only what, and sign off every commit (see above).
3. Run the suite before pushing and mention in the PR anything you could not run (for example macOS, or Windows).
4. CI (`.github/workflows/tests.yml`) runs on every pull request, on a push to `main` or a `feat/**` branch, and by hand
   (*Run workflow*, compared with the default branch). Its jobs:
   - `dco` (pull requests only): the sign-off check above.
   - `suite (head)`: the suite on Ubuntu 24.04 with git from the git-core PPA, mawk as `awk` and the pinned scanners, for your
     branch, one test file per runner core (`GSG_TEST_JOBS`). Only when it has a failure does `suite (base)` run the suite on the
     base (a pull request's base, the default branch for a push to a feature branch); `compare` then compares their `FAIL` lines
     (timings stripped): it fails when your branch has a `FAIL` line the base does not (a new failure, or an old one whose message
     changed), or when your branch's log has no `SUMMARY` line. Without a base run (the head passed, or a push to the default
     branch) any failure counts. The head run also publishes the [bypass catalog](docs/bypass-detection-scenarios.md#automated-coverage) table.
   - `windows-suite` (not on a push to a feature branch): the whole suite through `tests\run.cmd`; `windows` (every run): a
     clean-machine install, leak and uninstall check. Each job fails on any failure (no comparison with the base).
   - `macos-suite` (not on a push to a feature branch): the whole suite on a GitHub-hosted arm64 Mac with the pinned scanners,
     one test file per core; it fails on any failure, and unless every test in `tests/macos-only.list` (the tests that skip anywhere else) shows as PASS. Add a test that
     can only run on a Mac to that list (the `macos-list-complete` job fails when one is missing).
   - **A docs-only pull request** (every changed file is Markdown, `*.md`, other than `lib/cli/usage.md`, the CLI help the tests
     read) skips `suite (head)`, `suite (base)`, `compare`, `windows-suite`, `macos-suite` and `macos-list-complete` (branch
     protection takes a skipped job as passed). The `docs` job runs instead, in a few minutes: `tests/project/test_quality.sh` (docs lint,
     links) and every test file that reads a Markdown file of the project (`.github/scripts/docs-tests.sh` lists them), and it
     fails on any failure. If the `plan` job fails, no suite is skipped: the head suites all run, without a base run (so any
     failure counts), and `docs` is skipped.

   `platforms.yml` (the container, VM and old-git runs) and `wsl.yml` (real WSL) run only when started by hand, never on a pull
   request: see [CI on real platforms](docs/platform-testing.md#ci-on-real-platforms) and
   [WSL test runs](docs/platform-testing.md#wsl-test-runs).
5. Link the issue in the PR description.

## Versions

The version is the one line of `VERSION` (`x.y.z`; `git-secret-guard version` prints it, `install` records it in the state file
and `status` shows it). It follows [Semantic Versioning](https://semver.org/); while it is `0.y.z`:

- **Feature and fix pull requests leave `VERSION` alone**, so two of them worked on in parallel never conflict on it. Docs never repeat
  the current version either; a sample of output writes it `<x.y.z>`.
- **A release pull request bumps it**, after one or more pull requests are merged to `main`. It contains only `VERSION`, and its description
  lists the pull requests merged since the last tag and the bump it chose, so the release pull request decides the bump. Several merged
  pull requests may share one release. The rule, judged from what was merged since the last tag: a change of what a user gets (the hook,
  the CLI, install, `status`, `doctor`, a pinned tool in `tools.lock`) that is a new feature or a changed behaviour raises `y` and resets
  `z`, a fix raises `z`.
- **Bumping a scanner pin** in `tools.lock` also needs the SHA-256 of the binary inside each archive, as the fifth column of its row
  (`<tool> <version> <platform> <archive sha256> <binary sha256>`): download the archive, check the fourth column, extract the binary, `sha256sum` it.
  Install refuses an extracted binary that differs, and a kept scanner with that hash is adopted as install's own; a test fails on a scanner row without it.
- **Docs, tests and CI only** keep the version: merged alone, they need no release. Tests read `VERSION`, never a literal. The first
  tagged version is 0.2.0.
- **After the release pull request is merged** its merge commit on `main` is tagged `v<VERSION>` (annotated,
  `git tag -a v0.2.0 -m "v0.2.0"`) and the tag is pushed. A tag is never moved, replaced or deleted and re-created: a mistake gets the
  next version.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE) of this project.
