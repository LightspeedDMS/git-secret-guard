# lib/integrations/smartgit: SmartGit setup

CLI only. `smartgit.sh` (detection and the `preferences.yml` check), `smartgit_apply.sh` (the edit of the `executable:` lines),
`smartgit_flatpak.sh` (the Flatpak steps), `smartgit_lfs.sh`, `smartgit_offer.sh` and `smartgit_report.sh`.

- **May depend on:** `lib/core/`, `lib/gitup/`, `lib/install/`, and the other CLI contexts as `bin/git-secret-guard` loads them.
- **Never loaded by the hook.**
