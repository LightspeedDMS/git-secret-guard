usage: git-secret-guard <command> [options]

Machine-wide pre-commit secret scanning (trufflehog + betterleaks) through a git config hook.

commands:
  install [--replace-hooks-path] [--with-timer]
        Install, or upgrade when already installed. Needs git >= 2.54 and jq.
        Puts the pinned scanners in ~/.local/bin (checksum-verified), copies the hook to
        ${XDG_DATA_HOME:-~/.local/share}/git-secret-guard, and sets the global hook.git-secret-guard.* config.
        A global core.hooksPath is refused unless --replace-hooks-path is given: its value is
        recorded verbatim, the directory is backed up as a tarball, and the setting is unset.
        --with-timer also installs and enables a systemd user timer that runs doctor weekly
        (output in the journal), or on macOS a LaunchAgent (output in doctor.log in the state
        directory); without it nothing is installed. Uninstall removes the timer.
  uninstall [--remove-tools]
        Remove what install added and restore the recorded core.hooksPath.
        --remove-tools also removes the scanners that install itself downloaded.
  status
        Show the installed version, hook command, tool versions and the recorded core.hooksPath.
        Exit 0 only when installed and the global config matches.
  doctor [--roots DIR...]
        Coverage report: the machine (install, hook config, tools, core.hooksPath, old git)
        and every repository under the roots (default: your home directory, on macOS without ~/Library and ~/.Trash;
        at most 31 levels deep, node_modules skipped).
        Lists only the repositories with findings. Exit 0 = no PROBLEM, 1 = a PROBLEM, 2 = doctor error
        (a CLI startup failure exits 1 with no report).
        Changes nothing except its findings record (plus its lock and the state dir if missing),
        ${XDG_STATE_HOME:-~/.local/state}/git-secret-guard/findings
        (PROBLEMs only: the machine and every repository this run checked are replaced, other records are
        kept until their repository is proven gone).
  doctor --recheck
        Re-check only what the findings record holds (the machine and each recorded repository), no search.
        Prints what is still a PROBLEM, drops what was fixed or no longer exists (said on stderr), rewrites the record.
        No record or an empty one: prints nothing, exit 0. Exit 0 = nothing remains, 1 = a PROBLEM remains,
        2 = could not run (also an invalid record: run doctor to replace it).
  version
        Print the package version.
  help
        Print this text.
