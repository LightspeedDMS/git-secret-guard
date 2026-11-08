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
  put in `~/.local/bin`); with another version the gate is skipped, not passed.
- Optional: `pre-commit`, for the framework coexistence tests.

The real trufflehog and betterleaks are needed only by the tests that pin their behaviour; without them those tests
skip with a reason. `tests/fetch-test-tools.sh` downloads the versions pinned in `tools.lock` into
`~/.cache/git-secret-guard-test-tools` and checks their SHA-256. On Windows and macOS the tests look there by default; on
Linux set `GSG_TEST_TRUFFLEHOG` and `GSG_TEST_BETTERLEAKS` to those files (or to your own copies of the pinned versions).
On Windows, `tests/run.sh` fetches them for you the first time, and `jq.exe` too, so Git for Windows is all you install.

## Running the tests

```bash
tests/run.sh                       # the whole suite
tests/run.sh tests/test_hook.sh    # one file
```

From PowerShell or cmd on Windows:

```powershell
tests\run.cmd                      # the whole suite
tests\run.cmd tests\test_hook.sh   # one file
```

Always go through the runner on macOS and Windows: on macOS it puts Homebrew's bash and the GNU tools first on `PATH`, on
Windows it fetches the test tools and `tests\run.cmd` finds Git for Windows' bash (never the WSL one in `System32`).

On Windows a test that cannot apply there is reported as `SKIPPED` with its reason, never as passed: see
[what the suite covers on Windows](docs/platforms.md#the-test-suite-on-windows). The suite is slower there, because starting
a process costs far more than on Linux: files run in parallel by default (`GSG_TEST_JOBS` sets how many, also on Linux and
macOS, where the default is one), and during development it is best to run the files you touched.

Every test file runs in a throwaway sandbox with its own `HOME` and global git config, so the suite never touches your
own git configuration or installed hook. The Ubuntu and Rocky container runs live in `tests/platform/` and are described
in [docs/platforms.md](docs/platforms.md); they are not part of `tests/run.sh`.

## Rules for changes

- **Tests first.** A bug fix starts with a test that fails without it; a feature comes with tests for its behaviour,
  including the failure paths. Prefer real git and real files; the scanner stand-ins in `tests/stubs/` exist to
  drive cases the real tools cannot produce on demand.
- **No secret-looking literals, anywhere.** Fake credentials are built at runtime from fragments (`fake_aws_key`,
  `fake_github_token` in `tests/lib.sh`) and never printed. `tests/test_quality.sh` scans the tree with the real
  scanners, and this repository is guarded by its own hook.
- **Never dump the environment** (`env`, `set`, `export -p`) in a test or debug hook: it can print real tokens.
- **Fail closed.** If the hook cannot scan, it blocks the commit and says why; it never lets a commit through
  unscanned. Check every return value, keep loops bounded, use `set -u`.
- **Lint clean:** shellcheck 0.11.0 with no findings (info included). Comments use the coded form `# ^ tag clause`,
  checked by `awk -f tests/comment-rules.awk FILE` (`tests/run.sh tests/test_quality.sh` runs both).
- **Keep files under 1000 lines;** split by responsibility when one grows past that.
- **Document behaviour changes** in the matching file under `docs/` (and `README.md` when it is part of the overview).
  `tests/test_quality.sh` checks several documented promises.
- **Portability:** the hook and CLI run on Linux, macOS (BSD userland behind Homebrew's GNU tools) and Windows (Git for
  Windows bash with native `.exe` tools). The awk programs must give identical output under gawk, mawk and macOS awk
  (`tests/test_awk_portability.sh`). On Windows, native tools answer in `C:/` paths while bash uses `/c/`, there are no
  process groups, and `ln -s` behaves differently: `lib/proc.sh`, `gsg_is_windows` and `tools_binary_name` are the places
  for that, and `tests/test_windows.sh` is where it is tested on every platform.
- **`.cmd` files stay CRLF** (`.gitattributes`); everything else is LF, also in a Windows checkout.

[CLAUDE.md](CLAUDE.md) holds the maintainer notes: why the code is shaped the way it is, and which "simplifications"
break it. Read it before changing the hook, extraction, exemptions or install. It is written for AI coding agents too.

## Adding an OS module

`install` can offer to upgrade an old git (`install --upgrade-git`). The offer, the consent rules, the ordering with the other checks, the re-verification and the
"what changed" refusal text live in `lib/gitup.sh` and are shared. An OS plugs in with **one file and one line**, and edits none of that logic:

1. **The file** `lib/gitup_<module>.sh` (a plain lowercase word; `rpm` is the example). It is CLI-only: the hook never loads it, and `lib/install.sh` is the only place
   that may look a tool up on `PATH` (`install_find_bin NAME [PATH]` sets `REPLY`).
2. **The line** in `gitup_registry` (`lib/gitup.sh`). Each planned class has its own reserved line (`ubuntu`, `debian`, `macos`, `windows`, `other`), so parallel branches
   change different lines: replace `windows) REPLY="" ;;` by `windows) REPLY=windows ;;`. **Keep the comment line between the entries:** git treats two changed lines
   that touch as one conflict (real merges showed it), and with a comment line between them any two class branches merge cleanly
   (`test_branches_that_each_take_one_reserved_registry_line_merge_without_conflicts` runs those merges). The registry is a plain `case`; there is no globbing and no
   generated name outside `gitup_call`. `gitup_os_class` already detects every class, WSL (class `wsl`, the wrapper module `lib/gitup_wsl.sh`) included. Shared files a module branch does
   not edit: `tests/coverage.sh` globs `lib/gitup*.sh`, the registry test reads the class list from the library, the merge test (`test_branches_that_each_take_one_reserved_registry_line_merge_without_conflicts`) takes the classes still reserved from the library, the CLI loads only the shared `gitup` and
   `gitup_source`, a module sources its own helper libraries (`gitup_rpm.sh` does it for `gitup_takeover.sh`), and the contract tests use synthetic classes
   (`gu_tree_add_class` in `tests/gitup.sh`), so they need no edit. **What a class branch does edit:** the tests that pin today's refusal for that class, because the
   refusal goes away when the class gets a module (`test_a_class_with_no_module_keeps_todays_refusal_and_offers_nothing` in `tests/test_gitup.sh`, the cases of that class
   in `tests/test_prerequisites.sh`, and the takeover refusal in `tests/test_gitup_takeover.sh`). Two branches that both change the same test conflict there; agree who
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
     `gitup_source_plan_refresh PREPARE_FN` (set `GITUP_SRC_DEPS` and `GITUP_SRC_FLAGS` in `PREPARE_FN`, and `GITUP_SRC_PRE` when a privileged command must run before the dependency install, as `apt-get update` does; the plan and `gitup_source_compile` both take it from there). A plan whose commands depend on checks made between them (a signing key, a version floor) sets `GITUP_PRIV_BYHAND=0`: with neither root nor `sudo` the core then tells the user to run install as root instead of listing commands to type. `gitup_offer_upgrade` and `gitup_offer_refresh` reset it to 1 before each plan, `tools_fetch_verified` (SHA-256 against `tools.lock`) and
     `gitup_version_at_least`.
4. **The tests.** `tests/gitup.sh` has the helpers (`gu_tree_with_module` builds a copy of the product with your module and its one registry line, `gu_tree_add_module` adds a
   second one), and `lc_begin` puts recording stand-ins for `sudo`, `dnf`, `rpm`, `restorecon`, `make`, `df`, `ldd` and (`tests/apt.sh`) `apt-get`, `apt-cache`, `add-apt-repository` and `gpg` first on `PATH` and as the only places the fixed system path
   looks in; a real tool is never reached. `test_every_registered_module_implements_the_contract` (in `tests/test_gitup.sh`) loads every module in the registry and fails
   naming the module and the missing function, so a new module is checked by being added. `tests/test_gitup_contract.sh` shows each optional capability driven through a test
   module. System paths come from `GSG_GITUP_ROOT` (a sandbox directory in tests), never from `/usr`, `/etc` or `/var` directly. **Fixtures copy the real layout**: the RPM
   has three relative symlinks among its six files, and fixtures of six regular files hid a data-loss bug.
5. **The docs** to update: `docs/platforms.md` (the platform section), `docs/install.md`, `lib/usage.md`, `CLAUDE.md` (layout and facts), and the install hint in
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
Run it yourself with `.github/scripts/check-dco.sh origin/main HEAD`.

## Pull requests

1. Open or pick an issue first for anything larger than a small fix, so the approach can be agreed.
2. Branch from `main`, keep the change focused, write commit messages that say why, not only what, and sign off every commit (see above).
3. Run the suite before pushing and mention in the PR anything you could not run (for example macOS, or Windows).
4. CI runs the suite on Ubuntu 24.04 for both your branch and the base and compares their `FAIL` lines (timings
   stripped): it fails when your branch has a `FAIL` line the base does not (a new failure, or an old one whose message
   changed), or when your branch's log has no `SUMMARY` line. A push to the default branch runs that branch alone, so any
   failure counts. On Windows it runs the whole suite (pull requests and the default branch only) and, on every run, a
   clean-machine install, leak and uninstall check; a failure in either fails the job. On a GitHub-hosted arm64 Mac
   (`macos-suite`, pull requests and the default branch only) it also runs the whole suite and fails unless every test
   in `tests/macos-only.list` (the tests that skip anywhere else) shows as PASS; add a test that can only run on a Mac to that list.
5. Link the issue in the PR description.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE) of this project.
