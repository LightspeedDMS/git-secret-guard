# Feature 04: Machine rollout

## Objective
Replace the hand-built `~/.config/git/hooks` setup on this machine with git-secret-guard, prove it works on
real repositories, and report coverage, without touching any other repository's config unless the user
approves it per repo.

## Dependencies
- Features 01–04 complete, and the test results shown to and approved by the user.

## Stories (implementation order)
- [ ] 01_Story_MigrateThisMachine
