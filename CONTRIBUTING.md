# Contributing to git-secret-guard

Thanks for helping. git-secret-guard is plain bash (no Python or Node), and it guards commits for people who rely on
it, so changes are held to a high bar: every behaviour has a test, and every user-visible behaviour is documented.

## Reporting

- **Bugs and feature requests:** open a [GitHub issue](https://github.com/LightspeedDMS/git-secret-guard/issues). For a
  bug, include the platform, `git --version`, `bash --version`, the output of `git-secret-guard status` and
  `git-secret-guard doctor`, the steps to reproduce, and what you expected instead.
- **A way to get a secret past the hook, or any other security problem:** do **not** open a public issue. Use
  [private vulnerability reporting](https://github.com/LightspeedDMS/git-secret-guard/security/advisories/new)
  (Security tab, "Report a vulnerability").
- **Never paste a real credential** into an issue, a pull request or a test, not even a revoked one.

## Setting up

You need the same tools as a user (see [README.md](README.md#requirements) and [docs/platforms.md](docs/platforms.md)):

- Linux (x86_64/arm64) or macOS arm64 with Homebrew.
- **git 2.54 or newer.** Older git silently ignores config hooks, so most tests would prove nothing. The tests use
  `/usr/local/bin/git` unless you set `GSG_TEST_GIT=/path/to/git`.
- bash 4.4+, `jq`, `setsid`, `timeout`, `curl`, `tar`, and gawk or mawk.
- [shellcheck](https://github.com/koalaman/shellcheck) **0.11.0** for the lint gate (`pipx install shellcheck-py==0.11.0.1`);
  with another version the gate is skipped, not passed.
- Optional: `pre-commit`, for the framework coexistence tests.

The real trufflehog and betterleaks are needed only by the tests that pin their behaviour; without them those tests
skip with a reason. `tests/fetch-test-tools.sh` downloads the versions pinned in `tools.lock` and checks their SHA-256.

## Running the tests

```bash
tests/run.sh                       # the whole suite
tests/run.sh tests/test_hook.sh    # one file
```

On macOS always go through `tests/run.sh`: it puts Homebrew's bash and the GNU tools first on `PATH`.

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
  checked by `tests/comment-rules.awk` (`tests/run.sh tests/test_quality.sh` runs both).
- **Keep files under 1000 lines;** split by responsibility when one grows past that.
- **Document behaviour changes** in the matching file under `docs/` (and `README.md` when it is part of the overview).
  `tests/test_quality.sh` checks several documented promises.
- **Portability:** the hook and CLI run on Linux and macOS (BSD userland behind Homebrew's GNU tools). The awk
  programs must give identical output under gawk, mawk and macOS awk (`tests/test_awk_portability.sh`).

[CLAUDE.md](CLAUDE.md) holds the maintainer notes: why the code is shaped the way it is, and which "simplifications"
break it. Read it before changing the hook, extraction, exemptions or install. It is written for AI coding agents too.

## Pull requests

1. Open or pick an issue first for anything larger than a small fix, so the approach can be agreed.
2. Branch from `main`, keep the change focused, and write commit messages that say why, not only what.
3. Run `tests/run.sh` before pushing and mention in the PR anything you could not run (for example macOS).
4. CI runs the suite on Ubuntu 24.04 for both your branch and the base, and fails only on tests that pass on the base
   and fail on your branch. A Windows smoke job runs too, but its result doesn't count yet.
5. Link the issue in the PR description.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE) of this project.
