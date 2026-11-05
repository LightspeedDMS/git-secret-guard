# Security policy

## Reporting a vulnerability

Please report a vulnerability **privately**, and do not open a public issue, pull request or discussion for it.

Use GitHub's private vulnerability reporting: open the
[Security tab of LightspeedDMS/git-secret-guard](https://github.com/LightspeedDMS/git-secret-guard/security/advisories/new)
and choose **Report a vulnerability**. Only the maintainers can see the report.

What counts: a way to get a secret past the hook without the user's consent, a way for a repository or a commit to
change what is scanned or to run code during a scan, a secret (or part of one) printed or written somewhere it should
not be, and a flaw in `install`, `uninstall` or `doctor` that could damage a machine or its git configuration.

Please include:

- the platform (Linux distribution, macOS or Windows), `git --version`, `bash --version`, and the output of `git-secret-guard status`;
- the version (`git-secret-guard version`) or the commit you tested;
- the steps to reproduce, as a small script or a list of commands, and what you expected instead;
- what an attacker gains, if you know.

**Never put a real credential in a report**, not even a revoked one: a fake value that triggers the same behaviour is enough.

## What to expect

We aim to acknowledge a report within 5 business days, and to tell you what we found and what we plan to do after
that. Once a fix is released we will publish an advisory and, if you wish, credit you.

## Supported versions

Only the latest release on `main` is supported; fixes are made there and not backported.
