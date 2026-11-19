# lib/integrations/desktop: the GitHub Desktop link

CLI only. `desktop_git.sh` (link and unlink), `desktop_git_check.sh` (the check of both branches with Desktop's git),
`desktop_git_report.sh` and `desktop-chain.sh` (the body of the wrapper that install prints into Desktop's git directory; it is
copied as text, never sourced).

- **May depend on:** `lib/core/`, `lib/gitup/`, `lib/install/`, and the other CLI contexts as `bin/git-secret-guard` loads them.
- **Never loaded by the hook.**
