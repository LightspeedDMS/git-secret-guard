# lib/autoupdate: the update cycle and the doctor timer

CLI only. `autoupdate.sh` (the update run), `autoupdate_report.sh` (its status lines), `install_timer.sh` (the install side of
the doctor timer and the update job: checks, refresh, enabling) and `timer.sh` (the systemd unit texts and files of both timers, and their checks).

- **May depend on:** `lib/core/`, `lib/platform/` (launchd, schtasks, winupdate for the other operating systems), `lib/install/`,
  and the other CLI contexts as `bin/git-secret-guard` loads them.
- **Never loaded by the hook.**
