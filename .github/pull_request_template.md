<!-- This text is public. No real credential, no machine, account or path of yours or anyone else's. -->

Fixes #

## What and why

<!-- What changes for a user or a contributor, and why. A reviewer reads this before the diff. -->

## Tests

<!-- The files or folders you ran, on which platform, and the SUMMARY line of each run with its skip count (a skip is not a pass). -->

**Not run:** <!-- what you could not run, for example macOS or Windows; "nothing" if you ran it all -->

## Checklist

- [ ] Every commit is signed off (`git commit -s`), see `CONTRIBUTING.md`, "Sign your commits (DCO)".
- [ ] A bug fix starts with a test that fails without it; a feature has tests for its behaviour and its failure paths.
- [ ] A change a user can see is documented under `docs/` (and in `README.md` when it belongs to the overview).
- [ ] `VERSION` is untouched (only a release pull request changes it, and it changes nothing else).
- [ ] No secret-looking literal and no environment dump in the code, the tests, the commit messages or this text.
