# git-secret-guard: project notes

Bash only (no Python/Node). A git config hook (`hook.git-secret-guard.*`, git >= 2.54) runs trufflehog and betterleaks on the lines each
commit adds; `bin/git-secret-guard` installs it. Issues: GitHub LightspeedDMS/git-secret-guard (epics #1, #8). This file is an index: each
topic states what must not break and links the doc holding the detail. Read that doc's **Maintainer notes** before changing the area, and put
new internals there, not here.

## Where things are

- Hook: `hooks/secret-scan` plus the files in `GSG_HOOK_LIBS`/`GSG_HOOK_FILES` (`lib/common.sh`; a new hook library goes only there). The
  rest of `lib/` is CLI-only and never loaded by the hook (`test_the_hook_never_loads_*`). How a scan runs: [scan.md#how-it-works](docs/scan.md#how-it-works).
- Behaviour per area: [install.md](docs/install.md) (install, status, uninstall, git upgrade), [doctor.md](docs/doctor.md),
  [exemptions.md](docs/exemptions.md), [platforms.md](docs/platforms.md), [smartgit.md](docs/smartgit.md) (`lib/smartgit*.sh`); CLI help `lib/usage.md`.
- Tests: `tests/run.sh [FILE...]`, harness `tests/lib.sh`, helpers `tests/{lifecycle,doctor,gitup,apt,gitup_windows,smartgit}.sh` (knobs: their
  header comments and the docs' maintainer notes), stand-ins `tests/stubs/`; container and VM runs in `tests/platform/`, not in `run.sh`. Runner and CI:
  [CONTRIBUTING.md#running-the-tests](CONTRIBUTING.md#running-the-tests), [CONTRIBUTING.md#pull-requests](CONTRIBUTING.md#pull-requests).

## Rules for every task

- **Never touch the real git setup.** Each test file runs in `~/.tmp/git-secret-guard-tests.XXXXXX` (scratch `HOME`, `GIT_CONFIG_GLOBAL`,
  `GIT_CONFIG_NOSYSTEM=1`, `env -i`). The real `~/.gitconfig` sets `core.hooksPath=~/.config/git/hooks`: it must never apply, nothing
  under `~/.config/git/` is modified. `PYTHONUSERBASE` points at the real `~/.local` (pre-commit is a `pip --user` install).
- **No secret-looking literal, no environment dump.** Fake secrets come from `fake_aws_key`, `fake_github_token`, `fake_aws_secret`, never
  printed; leak tests assert absence with `no_leak`. A probe hook logs only `GIT_*` under `env -i` (`env` once printed real API keys).
- **No real `brew` or `systemctl` in lifecycle tests** (`lc_begin` puts recording stand-ins first); the one real call is the read-only
  `systemctl show $GSG_TEST_SERVICE_UNIT` in `service_prepare`.
- **Tool paths come only from the settings file** (`install_write_settings`; `load_settings` unsets every key before sourcing); an unusable
  path blocks the commit ("nothing was scanned"). `type -P` only in `lib/install.sh`, `lib/brew.sh` and the one line of `smartgit_tool` (pinned by tests).
- **Fail closed**, `set -u`, check every return value, bounded loops, files under 1000 lines, shellcheck 0.11.0 clean including info
  (`GSG_SHELLCHECK_PIN`; any other version skips the gate, which proves nothing).
- **git >= 2.54**, older git ignores config hooks silently. Tests use `GSG_TEST_GIT` (Linux default `/usr/local/bin/git`; set it where that
  path does not exist). Config hooks run before the hookdir hook, both run, either failing blocks, whatever `core.hooksPath` says.
- **Never run `wsl.exe`, `wsl` or `ubuntu.exe` on the Windows development host** (it blue-screened twice); real WSL runs are
  `.github/workflows/wsl.yml`: [platforms.md#wsl-windows-subsystem-for-linux](docs/platforms.md#wsl-windows-subsystem-for-linux).
- **Commits:** DCO sign-off ([CONTRIBUTING.md#sign-your-commits-dco](CONTRIBUTING.md#sign-your-commits-dco)); `VERSION` bump in a PR that
  changes what a user gets, tag the merge commit, never move a tag ([CONTRIBUTING.md#versions](CONTRIBUTING.md#versions)).

## Which tests to run

- **While developing:** only the files that cover the change (`tests/run.sh tests/test_x.sh ...`, Windows `tests\run.cmd`); a shared
  helper change (`lib/common.sh`, `tests/lib.sh`, `tests/lifecycle.sh`) means the files that use it. On a Mac always go through
  `tests/run.sh` (plain `bash` gets BSD tools).
- **The full suite** (`tests/run.sh` alone) runs once, right before commit and push: never after each edit or review round (it is slow and
  starves other agents). Fix a failure with the failing files alone, then run the full suite once more only before a commit. Reviewers
  and manual testers never run it; they report which files ran.
- **A skip proves nothing:** `tests/test_gitup_*.sh` skip on Windows; a Mac-only test goes in `tests/macos-only.list`, a Windows exception in
  `tests/windows-skips.list`. Read the skip count before calling a change tested.

## Invariants a "simplification" breaks (the link holds the why and the tests)

- **Scanners** are pinned per version (trufflehog exit 0 needs `chunks >= 1`; betterleaks `--exit-code 42`, `WRN skipping` = error); offline
  tests use the dead proxy `HTTPS_PROXY=http://127.0.0.1:9`: [scan.md#maintainer-notes](docs/scan.md#maintainer-notes). Our `aws-access-key-id`
  rule always runs, a second `--enable-rule` run when HEAD has a config: [scan.md#limits](docs/scan.md#limits).
- **Output:** a clean commit prints one pass line, then the coverage reminder only after `REMINDER_READY=1`; the commit's exit status
  never depends on the reminder: [scan.md#the-coverage-reminder](docs/scan.md#the-coverage-reminder),
  [scan.md#maintainer-notes](docs/scan.md#maintainer-notes).
- **A commit cannot mute itself:** exemptions and betterleaks config come from HEAD only, root ignore files are renamed, built-in-rule status
  is judged by betterleaks' behaviour, never by parsing TOML: [exemptions.md#maintainer-notes](docs/exemptions.md#maintainer-notes).
- **Extraction:** added line N stays at line N (never count scan-tree lines); fixed diff flags and `-c` pins (new keys into
  `tests/test_inherited_config.sh`): [scan.md#maintainer-notes](docs/scan.md#maintainer-notes). Every diff is `diff-tree -M` of `write-tree` against
  HEAD with `GIT_INDEX_FILE` missing (`staged_trees_init`), never `diff --cached` (git reads the work tree file, #103); tests use `touch -d` old
  mtimes. Pathspecs `:(exclude,top,glob)` with two diffs, `GIT_NO_REPLACE_OBJECTS=1`, the `GIT_*_PATHSPECS` unset:
  [exemptions.md](docs/exemptions.md) (table and maintainer notes).
- **Git LFS (#98):** the hook never runs git-lfs; a pointer is known by content exactly as git-lfs decodes it, never by `.gitattributes`;
  the object comes from git config only (never `.lfsconfig`), size and SHA-256 are checked on the scanned copy, and every failure or `ext-`
  pointer blocks; no git process per file: [scan.md#maintainer-notes](docs/scan.md#maintainer-notes).
- **Signals:** scanners and the reminder run in their own group (`lib/proc.sh`); `cleanup` kills, waits, then removes the work dir; adapters
  keep `timeout --foreground`, doctor's git shim omits it; a git or find that Ctrl-C must stop never runs inside `< <(...)` (bash 5.3):
  [scan.md#maintainer-notes](docs/scan.md#maintainer-notes), [doctor.md#maintainer-notes](docs/doctor.md#maintainer-notes).
- **Install order:** refusable checks before any lasting change, state before config, unset `core.hooksPath` last, uninstall restores it
  first; our scanner files are known by hash (recorded, or a kept file equal to the lock's binary-hash column); `/etc/os-release` is data: [install.md#maintainer-notes](docs/install.md#maintainer-notes).
- **One verdict, git's:** `status` and doctor share `hooklist_probe_line` (a bare repo written by hand, never `git init`); `status` exits 1 on
  any `MISMATCH`/`MISSING`: [install.md#maintainer-notes](docs/install.md#maintainer-notes).
- **Doctor** exits 1 only for a PROBLEM, runs nothing a repository configures, never prints a hook `command`/`event` value; the findings
  record is data, merged under the lock: [doctor.md#maintainer-notes](docs/doctor.md#maintainer-notes).
- **macOS:** `/bin/bash` 3.2 cannot parse the libs (bootstrap re-exec, two loop bounds); every install refusal uses `brew_unchanged_text`.
  **Windows:** three path forms, compare in one (`cygpath -m -l`); no process groups: [platforms.md#maintainer-notes](docs/platforms.md#maintainer-notes).
- **Git upgrade** (`lib/gitup*.sh`): one module file plus one reserved registry line ([CONTRIBUTING.md#adding-an-os-module](CONTRIBUTING.md#adding-an-os-module));
  privileged tools only through `gitup_system_bin`, the printed plan is what runs; partly applied states are tested contracts; the PPA key
  check precedes `apt-get update`; on Windows bash never runs the installer: [install.md#maintainer-notes-git-upgrade](docs/install.md#maintainer-notes-git-upgrade).
- **SmartGit:** only the `executable:` lines of a recorded `preferences.yml`, never re-serialised YAML; the Flatpak's four steps are one unit,
  each recorded before it acts. Per settings root only the newest set-up major is live; an older one is left over (info, no exit status, never
  edited) unless an install has exactly that major (#88): [smartgit.md](docs/smartgit.md).
- **CI on real platforms** (`platforms.yml`): `workflow_dispatch` only, never merge a `push:` trigger; read the artifacts, not the logs;
  `ubuntu.sh` never mentions `--skip-isolation`: [platforms.md#ci-on-real-platforms](docs/platforms.md#ci-on-real-platforms).

## Testing tricks

- The hook never sees a fake `git` on `PATH` (git prepends its exec-path): inject `setsid`/`timeout` through settings (`use_stubs
  "SETSID_BIN=..."`); break only the probe repo with `GIT_CONFIG_GLOBAL` (`set_env`) plus `[includeIf "gitdir:<TMPDIR>/"]`; break doctor's
  git with a wrapper failing `git -C /` with 128; `GIT_TEST_ASSUME_DIFFERENT_OWNER=1` simulates `safe.directory`.
- Stand-ins report the configured findings whatever the tree holds: clear `STUB_GL_FINDINGS` between steps, assert on `STUB_RECORD`; one
  that must be killed needs `exec sleep`.
- Background jobs start with SIGINT ignored: INT tests launch git with `env --default-signal=INT`. Never `pkill -f` a pattern that is in your
  own command line.
- With a socket on stdin, `env -i ... bash -c` reads `~/.bashrc`: tool-lookup helpers redirect stdin from `/dev/null`.
- Old git: compute expectations from `/usr/bin/git --version`; a fake old git goes after the real one on `PATH`.
- Without the tools in `~/.local/bin` set `GSG_TEST_TRUFFLEHOG`, `GSG_TEST_SHELLCHECK` (and `GSG_TEST_BETTERLEAKS` unless cached), or those
  tests skip; real-scanner tests read `~/.cache/git-secret-guard-test-tools` (`tests/fetch-test-tools.sh`).
- Git upgrade tests: force root with `gitup_is_root() { return 0; }` in `gu_run`, never a fake `id`; use synthetic classes
  (`gu_tree_add_class`), never a reserved one; system paths only through `GSG_GITUP_ROOT`.

## Conventions

- Coded comments `# ^ tag clause` (tags: hazard coupled security invariant external order why see perf todo; `why X, not Y; reason`;
  <= 160 chars, <= 3 coded lines in a row; no ` so `, ` but `, ` because `, ` which `, ` that `, ` then `, ` while `, `: `); lint
  `awk -f tests/comment-rules.awk FILE`.
- A local named like a sourced array (`lines`) trips SC2178/SC2128; names must not be confusable (`INSTALL_TIMEOUT_BIN` is a path).

## Correct as written: do not "fix"

- `wait "$!"` after `done < <(find ...)` or `mapfile < <(git ...)` returns the substituted command's status (bash 4.4+); a stderr filter is a
  pipe plus `PIPESTATUS`, never a process substitution (it races).
- `${v%"${v##*[!/]}"}` trims all trailing slashes; `type -aP git` is valid; `A=0 B=""` alone on a line sets both; `${kv#*$'\n'}` needs its guard.
- `doctor_unreadable` returning 1 means "not explained by permissions" (caller exits 2); `$key` in `doctor_repo_info` is the absolute common dir.
- A token of a remote URL in `EXEMPT_GIT_ERR` on the user's own stderr is accepted (the user's config shown to the user).
- `/proc/self/mountinfo` field 5 is the mount point, fstype follows the lone `-`; `awk -F: '$1 == "fpr" {print $10}'` is right for `gpg --with-colons`;
  `lib/extract.awk` writes nothing to stdout, so `2>&1 |` swallows no extracted line.
- `hooklist_bind_timeout` keeps `--foreground` (that call starts no child, and Ctrl-C must reach git), unlike doctor's shim.
