# Working rules for AI agents

These rules hold for any AI coding agent, and any person, working on this repository from any machine. [CLAUDE.md](../CLAUDE.md) is
the index of the code's rules and invariants; this file says how the work moves: issues, test runs, test machines, pull requests,
releases and finishing. Where [CONTRIBUTING.md](../CONTRIBUTING.md) already says something, this file links it instead of repeating it.

## Issues and labels

- Work starts from an issue ([CONTRIBUTING.md#pull-requests](../CONTRIBUTING.md#pull-requests)). Its labels follow the work: `backlog`
  while it waits, `active` in place of `backlog` the moment someone starts on it, `completed` when its pull request is merged and the
  issue is closed. Set `active` before the first edit, so anyone reading the labels can tell what is in progress.
- One issue, one branch from `main`, one pull request, whose description says `Fixes #<n>`. Agents working at the same time each take
  their own issue and their own worktree or clone.

## Releases

- Feature, fix, docs, test and CI pull requests never touch `VERSION`; a release is a separate pull request that changes only `VERSION`,
  its merge commit is tagged, and a tag is never moved: [CONTRIBUTING.md#versions](../CONTRIBUTING.md#versions).
- **A tag is a deploy.** Auto-update moves every install that follows a checkout to the newest released tag within the hour
  ([install.md](install.md#auto-update---auto-update-and-update)). A tag goes only on a commit whose `main` CI is green.
- **The steps:**
  1. Nothing meant for this release is still open: `gh pr list --state open`, `gh issue list --state open`.
  2. `main` CI is green on the commit you release: `gh run list --workflow tests.yml --branch main --event push --limit 3`. Every
     push to `main` gets its own complete run, never cancelled by a later one; a run shown `cancelled` was cancelled by hand or hit a job
     timeout (only a branch or pull request run is cancelled by a newer push): look at why, rerun it, and never tag on a cancelled,
     failed or unfinished run.
  3. The pull requests merged since the last tag:
     `git log --merges --format='%s' "$(git describe --tags --abbrev=0 origin/main)"..origin/main` (no tag yet: every merge).
  4. Choose the bump by [CONTRIBUTING.md#versions](../CONTRIBUTING.md#versions); docs, tests and CI alone need no release.
  5. Branch `release/<x.y.z>` from `origin/main`, change only `VERSION`, commit `Release <x.y.z>` signed off, open the pull request
     `Release <x.y.z>`: its description lists the merged pull requests (number and title) and the bump with its reason. Watch its checks.
  6. After it is merged: `git fetch origin`, then tag its merge commit and push the tag:
     `git tag -a v<x.y.z> -m "v<x.y.z>" <merge commit> && git push origin v<x.y.z>`; check with `git ls-remote --tags origin v<x.y.z>`
     that the tag peels to that merge commit.
  7. A wrong tag is never moved, deleted or re-created: the fix is the next version.

## Repository settings (maintainers)

- `main` is protected: no force push, no deletion; required checks `suite (head)`, `windows-suite`, `macos-suite`, `windows`,
  `Analyze (actions)`, `macos-list-complete`, `docs` and `compare` (a skipped job counts as passed). Pull requests are merged by a person.
- **A check is required only after it was seen reporting on a pull request.** A required check that never reports blocks every pull
  request with all other checks green ("Expected — Waiting for status to be reported"). Read a blocked pull request's
  `mergeStateStatus` and the check names on its head commit before suspecting the code.
- CodeQL runs as GitHub's default setup for the language `actions` (the workflows); its language is set explicitly: enabled on an
  empty repository, it detects none and never runs.

## Running the tests

- **While developing**, run only the test files that cover the change ([CLAUDE.md](../CLAUDE.md#which-tests-to-run) says which). Several
  agents on one machine each running the whole suite starve each other until files time out.
- **The full suite** runs once on each machine the change is tested on, after the last edit: on the development machine right before the
  commit, on a test machine on that commit, and on all of them before the push. Never after each edit or review round; after a failure,
  fix it with the failing files, then run the full suite once more. Reviewers and manual testers name the files they ran and never run it.
- **Read the result:** the `SUMMARY` line of each run and its skip count. A skipped test proves nothing.
- **The knobs** (how to install each tool: [CONTRIBUTING.md#setting-up](../CONTRIBUTING.md#setting-up),
  [CONTRIBUTING.md#running-the-tests](../CONTRIBUTING.md#running-the-tests)):
  - `GSG_TEST_GIT`: the git of 2.54 or newer the tests use. The Linux default `/usr/local/bin/git` is missing on many machines, and then
    every file fails with "produced no test results"; name the machine's own git.
  - `GSG_TEST_SHELLCHECK`: a shellcheck **0.11.0** binary (`GSG_SHELLCHECK_PIN` in `tests/project/test_quality.sh`). With no shellcheck or another
    version the lint gate skips, which proves nothing, and a lint finding shows up only in CI. When the machine has no 0.11.0, download that
    release into a scratch directory and point this knob at it, rather than changing the machine's own setup.
  - `GSG_TEST_FILE_TIMEOUT`: seconds before a test file is killed (default 900, 2400 on Windows). With other suites running on the
    machine a slow file can pass 900 s and exit 124 on `main` too: raise it (2400) for a full suite on a busy machine. A 124 is a failure
    until shown otherwise: rerun that file alone with the raised timeout, or run `main` beside it, before calling it load.
  - `GSG_TEST_JOBS`: test files run in parallel (default 1, the number of processors on Windows). Keep it low on a machine others use.

## Test machines for other platforms

- **Edit only on the development machine**, where the repository's hook, the local checks and the reviews run; that holds for a temporary
  trace line too. A Windows or macOS test machine only runs: it receives a commit, runs tests, and its logs are copied back. An edit made
  on a test machine has escaped those checks: discard it there and make it again on the development machine.
- **Move a commit without GitHub:** `git bundle create <file> origin/main..HEAD`, copy the file over, `git fetch <file> HEAD` in a clone
  there; or `git push` over SSH into a bare repository on the test machine.
- **Never push to GitHub from a test machine.** Pushes go from the development machine only.
- **One work directory per issue** on each test machine, named for the issue, created by the agent that uses it and removed when it is
  done. Other agents and the machine's owner may be working on the same machine: never touch a directory or a process you did not
  create, kill only what you started, and check `ps` before a long run (when a full suite already runs there, run one file at a time).
- **Watch every remote run:** an agent that starts a run on another machine polls it (a bounded loop or a monitor) until it ends. A run
  nobody watches stalls silently.
- **Never run `wsl.exe`, `wsl` or `ubuntu.exe` on a Windows machine used for this repository** (development or test); real WSL runs are
  [platforms.md#wsl-windows-subsystem-for-linux](platforms.md#wsl-windows-subsystem-for-linux).

## A destructive step on a shared test machine

A step that removes or replaces a tool other runs use (uninstalling the package manager's git for an install test removes the git every
other run there uses as `GSG_TEST_GIT`) is coordinated:

- **Before it:** check with `ps` that no test run, package manager or `git-secret-guard` process from another work directory is running,
  and wait until none is.
- **Right after it:** put the tool back and verify it (for git: the path the other runs use answers 2.54 or newer).
- **In the report:** timestamp each step and say when the tool was missing.

## Flags that act without a terminal

An install flag is the consent: without a terminal it does not stop at the plan, it applies. `install --configure-smartgit` edits
SmartGit's `preferences.yml` (with a backup), and on a machine without Git LFS first installs it (`brew install git-lfs`, which on a Mac
without bottles builds from source for a long time, or `dnf`/`apt-get` as root; nothing on Windows). Before a real run of such a flag on any machine, read its consent rule in [install.md](install.md) and
[smartgit.md](smartgit.md); never use one as a dry run. To check the behaviour, run the test suite (it uses stand-ins), or ask first.

## No private details, in files or on GitHub

- Nothing in the repository names a test machine, an account, a home or scratch path, an agent session link, a worker name, or a
  tool vendor's credit status: say "the Windows test machine", "an Intel Mac test machine", "a measurement script (not shipped)".
- **GitHub text follows the same rule as files:** issue and pull request bodies, comments and commit messages are public too.
  Private notes and reports outside the repository may hold those details; nothing committed or posted may.
- **Commit messages carry no session or tool trailers** besides `Co-Authored-By` (no `Claude-Session:` link or the like), and the author
  and the sign-off use the same identity as the rest of the history. A merged commit stays in the history for good.
- **Read before you commit, push or post:** every changed line, every new file whole, the commit message and the pull request or
  issue text, for these details and for secrets. The hook's scanners catch only known secret formats; a host name, a person's
  address or a pasted log passes them. Anything doubtful goes to the maintainer before it is committed.

## Pull requests you open

- **Whoever opens a pull request watches it:** poll its checks after each push, read a failed job's log as soon as it fails, and fix it.
  A red pull request is never left for someone else to find.
- **Scratch pull requests** (to try something in CI): at most one open at a time, on one reused scratch branch; close it and delete its
  branch as soon as its check has run, and cancel any Actions run you started that is no longer needed.
- **Leave nothing behind:** scratch pull requests and branches, work directories on test machines, temporary files, processes. Say in the
  report what was cleaned.

## Finishing

- **The agent that did the work finishes it:** the full suite on each machine it touched, the push, the pull request, and its checks until
  green. Never end with "the next step is yours". The one exception is a worker whose instructions say another agent pushes: it stops at
  the commit and reports.
- Every commit is signed off: [CONTRIBUTING.md#sign-your-commits-dco](../CONTRIBUTING.md#sign-your-commits-dco).
