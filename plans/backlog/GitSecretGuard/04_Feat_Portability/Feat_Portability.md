# Feature 04: Portability

## Objective
The package works, and is tested, on the Linux distributions it claims. RHEL 9-compatible is this machine (tested on Rocky Linux 9.7). Ubuntu 24.04 LTS is verified in a container. macOS is out of scope for this epic: the user will port it on a Mac.

## Architecture
- A repeatable platform test (`tests/platform/ubuntu.sh`) runs the full suite and an install E2E inside a podman `ubuntu:24.04` container, against a copy of the checkout.
- Distribution differences, such as mawk as the default `awk` and an older git in the distro repos, are fixed in the code with portable constructs, or turned into explicit, checked dependencies with install hints.

## Dependencies
- Features 01 to 03 complete.

## Stories (implementation order)
- [x] 01_Story_UbuntuSupport
