usage: git-secret-guard <command> [options]

Machine-wide pre-commit secret scanning (trufflehog + gitleaks) through a git config hook.

commands:
  install [--replace-hooks-path] [--with-timer]
        Install, or upgrade when already installed. Needs git >= 2.54 and jq.
        Puts the pinned scanners in ~/.local/bin (checksum-verified), copies the hook to
        ${XDG_DATA_HOME:-~/.local/share}/git-secret-guard, and sets the global hook.git-secret-guard.* config.
        A global core.hooksPath is refused unless --replace-hooks-path is given: its value is
        recorded verbatim, the directory is backed up as a tarball, and the setting is unset.
        --with-timer also installs and enables a systemd user timer that runs doctor weekly
        (output in the journal); without it no unit is installed. Uninstall removes the timer.
  uninstall [--remove-tools]
        Remove what install added and restore the recorded core.hooksPath.
        --remove-tools also removes the scanners that install itself downloaded.
  status
        Show the installed version, hook command, tool versions and the recorded core.hooksPath.
        Exit 0 only when installed and the global config matches.
  doctor [--roots DIR...]
        Read-only coverage report: the machine (install, hook config, tools, core.hooksPath, old git)
        and every repository under the roots (default ~/Dev, at most 3 levels deep, node_modules skipped).
        Lists only the repositories with findings. Exit 0 = covered, 1 = findings, 2 = doctor error.
  version
        Print the package version.
  help
        Print this text.
