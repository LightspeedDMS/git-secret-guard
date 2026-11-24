usage: git-secret-guard <command> [options]

Machine-wide secret scanning of every commit (the lines it adds and its message) with trufflehog and betterleaks,
through a git config hook (git >= 2.54, events pre-commit and commit-msg).

commands:
  install [--replace-hooks-path] [--with-timer] [--auto-update] [--upgrade-git] [--take-over-system-git]
          [--dont-configure-smartgit] [--allow-smartgit-sandbox-removal] [--dont-link-desktop-git]
          [--configure-smartgit] [--link-desktop-git] [--dont-change-path]
        Install, or upgrade when already installed. Needs git >= 2.54 first on PATH, jq, setsid, timeout and (Linux) awk
        (on Windows taskkill replaces setsid and a missing jq is downloaded; on macOS missing Homebrew tools are
        installed with brew after the other checks), and curl when something has to be downloaded. Puts the pinned
        scanners in ~/.local/bin (checksum-verified against tools.lock), copies the hook to
        ${XDG_DATA_HOME:-~/.local/share}/git-secret-guard, and sets the global hook.git-secret-guard.* config.
        Exit 0 = installed, 1 = refused or failed, 2 = usage error, 3 = a git upgrade was handed off (below).
        --replace-hooks-path: a global core.hooksPath is refused without it; with it the value is recorded
        verbatim, the directory is backed up as a tarball, and the setting is unset.
        --with-timer also installs and enables a systemd user timer that runs doctor weekly
        (output in the journal), or on macOS a LaunchAgent (output in doctor.log in the state
        directory); without it nothing is installed. Uninstall removes the timer. Refused on Windows,
        where docs/doctor.md has a Task Scheduler recipe.
        --auto-update (Linux, macOS and Windows) also installs and enables an hourly job of your own user
        that runs git-secret-guard update: a systemd user timer of its own on Linux (five minutes after
        boot, then every hour; output in the journal), a LaunchAgent of its own on macOS (every hour;
        output in update.log in the state directory), a Task Scheduler task on Windows (every hour while
        you are logged on; output in update.log of the state directory). On both, update.log keeps the
        runs, each line stamped with its UTC time, and one earlier file (update.log.1) once it passes
        1 MiB. It follows the git checkout
        install was run from; every install run from a checkout records it, and a later plain install
        keeps auto-update on. On Linux the timer runs only while you have a session unless linger is on
        (install prints the loginctl enable-linger command and does not run it). Refused before any
        change without systemctl (launchctl on macOS, schtasks on Windows), when your systemd user
        manager cannot be reached, on WSL without systemd, and when no checkout is known. Independent of
        --with-timer. Uninstall removes it.
        --upgrade-git lets install upgrade or rebuild git where its module can (RHEL, Rocky, AlmaLinux, CentOS,
        Fedora, Ubuntu, Debian, those inside WSL, Windows; macOS through Homebrew, as your user): it prints the
        plan with each privileged command, then runs it. In a terminal install asks first (default No); without a
        terminal the flag is the only way to say yes. Exit 3 = a module hands the upgrade off to finish outside
        install; nothing else changed. On Windows git-secret-guard.cmd runs the hand-off itself and then runs the
        command again; from Git Bash the printed PowerShell command does.
        --take-over-system-git (RPM systems) points the old package /usr/bin/git and its siblings at the new
        /usr/local build, keeps the originals, and makes dnf skip the git packages; undo with restore-system-git.
        On macOS it only reports that /usr/bin/git cannot be replaced (SIP), changes nothing, and install goes on;
        on any other system it is refused.
        SmartGit is set up by a plain install, with no flag and no question: when a SmartGit settings directory
        commits with a git older than 2.54, install points its Git Executable at the git in use (>= 2.54) and installs
        Git LFS for it when missing (not on Windows, which refuses with repair advice; SmartGit 26.1: macOS, Linux
        tarball or package, Linux Flatpak, Windows). It prints the plan, backs up preferences.yml with a manifest,
        edits only the executable lines, then checks a fake-token commit is blocked; any failure restores the backup.
        For the Flatpak it also adds a --user flatpak override, a wrapper running the host git and a
        smartgit.vmoptions line, each recorded first and undone exactly. That override removes the SmartGit sandbox,
        so it keeps its own yes: a question at a terminal, or --allow-smartgit-sandbox-removal; without either the
        Flatpak is refused. Git LFS is installed without a question only where it runs as your user at a terminal
        (brew on macOS); where it needs root (dnf, apt-get) or there is no terminal (also the unattended update),
        install names the command to run and leaves SmartGit as it is. A refusal (SmartGit running, a wizard not
        finished, a version not recorded, a file that is not of the recorded shape) is a printed notice with the
        manual steps, not a failed install; status and doctor keep reporting it. A Snap is only listed.
        --dont-configure-smartgit changes nothing of SmartGit and prints the hint. --configure-smartgit is still
        accepted and differs from a plain install in two ways: a refusal or a failure is exit status 1, and a
        missing Git LFS is installed as before (dnf or apt-get as root, brew also without a terminal).
        GitHub Desktop on Linux is linked by a plain install too (no flag, no question): its bundled git is older than
        2.54 and ignores the hook. install writes ${XDG_DATA_HOME:-~/.local/share}/git-secret-guard/desktop-hooks
        (a wrapper for every git hook but reference-transaction, whose repository hook does not run; the
        wrappers run the scan for pre-commit and commit-msg, then the repository's own hook) and a user launcher
        entry applications/github-desktop.desktop that starts Desktop with core.hooksPath set for it alone. It
        checks the result with Desktop's own git first; any failure removes the files of the link. A launcher
        file or hooks directory file that is not ours, an unreadable system launcher entry or a path that is not
        UTF-8 is a printed notice (the file is named and kept, nothing of the link is written), not a failed
        install. Restart Desktop from the menu afterwards; Desktop started any other way is not covered. On macOS
        and Windows nothing is linked; install, status and doctor only recommend updating Desktop when it is found.
        --dont-link-desktop-git writes no link (an existing link is still refreshed) and prints the note.
        --link-desktop-git is still accepted and differs from a plain install in three ways: a refusal is exit
        status 1 before any change, a failed self-check is exit status 1, and on macOS and Windows it is refused.
        Install says where the CLI is and whether its folder is on PATH. On macOS it adds one marked block to
        ~/.zprofile (zsh) or ~/.bash_profile (bash), the startup file of the account's login shell, and on Windows the
        folder to the user Path; on Linux no file is changed and the line to add is printed. Nothing is changed when the
        folder is already on PATH, or when the file is a link, not yours, or the shell is not zsh or bash (the line to
        add is printed). --dont-change-path leaves PATH alone for that run and prints the line. The unattended install
        of update never changes PATH. A change that fails is reported with the step to do by hand and does not fail
        install. uninstall takes out exactly what install added and names what the user changed.
  uninstall [--remove-tools] [--keep-system-git]
        Remove what install added and restore the recorded core.hooksPath (SmartGit and the Desktop link are
        undone first). Says "nothing to do" and exits 0 when nothing is installed.
        --remove-tools also removes the scanners that install itself downloaded.
        Stops, changing nothing, while a system git takeover is active or half done; --keep-system-git lets it
        finish and prints the undo by hand.
  restore-system-git
        Undo a system git takeover: puts the saved RPM files back (hash checked), removes the dnf excludepkgs entry
        and the backup directory. Needs no network. Says "nothing to restore" and exits 0 when there is no takeover.
  restore-smartgit
        Undo what install did to SmartGit: the Git Executable lines from the backup (only while they are
        still the ones this tool wrote), the filter.lfs.* settings that git lfs install added and, for the
        Flatpak, the recorded override, wrapper and smartgit.vmoptions line. Git LFS packages are kept.
        Says "nothing to restore" when SmartGit was never changed.
  unlink-desktop-git
        Undo the GitHub Desktop link install wrote: removes the launcher entry, the wrappers and the hooks directory, only files carrying
        the marker line (anything else is named and kept). Never touches Desktop's own files or /usr. Says "nothing to unlink"
        when there is nothing of ours. uninstall does the same.
  status
        Show the installed version, hook command, the git in use, tool versions and the recorded core.hooksPath, in the
        sections install, git, tools, clients and auto-update. Every line has a level: PROBLEM (exit 1), WARNING (look at
        it, no effect on the exit status), ok or info. The last line is "summary: N problems, M warnings".
        Exit 0 only when installed, the global config matches, git runs the hook (git hook list pre-commit and commit-msg), the
        first git on PATH is >= 2.54 and no line says MISMATCH or MISSING (tools, hook libraries, a system git takeover,
        the GitHub Desktop link, and a SmartGit settings directory while SmartGit itself is found).
        On a terminal with a UTF-8 locale the level is an icon instead of its word (red x, yellow triangle, green check,
        dim dot); doctor, the commit hook and the command outcome lines use the same icons. NO_COLOR (any value) turns
        them off, CLICOLOR_FORCE (any value) turns them on for a pipe, and TERM=dumb or a non-UTF-8 locale keeps plain text.
        Pipes, logs and the text of this help stay plain.
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
        2 = could not run (also an invalid record: run doctor to replace it). Takes no --roots.
  update
        One auto-update cycle, the command the timer of install --auto-update runs: the owner of the recorded
        checkout fetches origin and fast-forwards it to the newest released tag vX.Y.Z on origin/main, any
        other user only reads it; the install is then renewed from an export of that tag. Says "auto-update
        is off" (exit 0, nothing written) unless install --auto-update turned it on. Every other run writes its result to
        ${XDG_STATE_HOME:-~/.local/state}/git-secret-guard/update. Exit 0 = current, updated or skipped
        (a doubtful case changes nothing and records its reason), 1 = failed.
  version (also --version)
        Print the package version.
  help (also --help, -h)
        Print this text.

A missing or unknown command, an unknown option, or an argument a command does not take, prints this text on stderr and exits 2.
