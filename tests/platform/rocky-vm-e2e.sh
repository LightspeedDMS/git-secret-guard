#!/usr/bin/env bash
set -u
# ^ external runs as the cloud user (passwordless sudo) inside the Rocky 9 cloud image under qemu with SELinux enforcing; started by rocky-vm.sh
# ^ coupled the install, takeover and restore steps are the Rocky functions of rpm-upgrade-e2e.sh; the VM adds labels, AVC denials and sshd
# ^ security the fake credential comes from fake_key there and is never printed

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
set -- rocky
# ^ external a Rocky 9 login shell lists /usr/bin first; the product tells the user to put the new git first, and this script does
export PATH="/usr/local/bin:$PATH"
# shellcheck source=tests/platform/rpm-upgrade-e2e.sh
source "$HERE/rpm-upgrade-e2e.sh" || exit 2

SRV="$HOME/srv/repo.git"
SSH_KEY="$HOME/.ssh/id_gsg"
AVC_MARK=""
CLONE_OUT=""
RPM_GIT_VERSION=""
ME="$(id -un)"

# ^ invariant true when ausearch finds no AVC or USER_AVC record since AVC_MARK; the records themselves go to OUT for the log
no_new_avc() {
    vm_policy_allows
    # shellcheck disable=SC2086
    OUT="$(sudo ausearch -m AVC,USER_AVC -ts $AVC_MARK 2>&1)"
    [[ $OUT == *"<no matches>"* ]]
}

# ^ invariant type_of PATH prints the SELinux type of PATH itself (a symlink is not followed), empty when the context cannot be read
type_of() { stat -c %C -- "$1" 2>/dev/null | awk -F: '{ print $3 }'; }

# ^ invariant restorecon -n names every path it would relabel; no output means every label is the policy's default
nothing_to_relabel() {
    local out
    out="$(sudo restorecon -n -v "$@" 2>&1)"
    if [ -n "$out" ]; then
        show "restorecon would change: $(printf '%s' "$out" | head -n 5)"
        return 1
    fi
}

vm_prepare() {
    printf '== Rocky VM: SELinux and the prerequisites\n'
    show "$(uname -r); $(cat /etc/rocky-release)"
    check "SELinux is enforcing" test "$(getenforce)" = Enforcing
    show "$(sestatus | head -n 3 | tr '\n' ' ')"
    check "the prerequisites install" bash -c 'sudo dnf install -y --setopt=install_weak_deps=False jq rpm-build createrepo_c policycoreutils audit libselinux-utils setools-console git >/dev/null 2>&1'
    check "auditd is running, so denials are recorded" sudo systemctl is-active auditd
    check "sshd is running" sudo systemctl is-active sshd
    AVC_MARK="$(date '+%x %T')"
    RPM_GIT_VERSION="$(/usr/bin/git --version | sed "s/^git version //")"
    show "AVC records are searched from $AVC_MARK"
    mkdir -p "$HOME/.ssh" "$HOME/srv" || return 1
    ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY" && cat "$SSH_KEY.pub" >>"$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
    /usr/bin/git init -q --bare "$SRV"
}

vm_labels_after_install() {
    printf '== Rocky VM: labels after the source install into /usr/local\n'
    show "$(stat -c "%C %n" /usr/local/bin/git /usr/local/libexec/git-core/git-upload-pack /usr/local/share/doc/git-*-local/MANIFEST 2>&1)"
    show "$(stat -c "%i %C %h %F %n" /usr/local/bin/git /usr/local/libexec/git-core/git-merge /usr/local/libexec/git-core/git-add 2>&1)"
    show "$(matchpathcon /usr/local/bin/git /usr/local/libexec/git-core/git-merge /usr/local/libexec/git-core/git-add 2>&1)"
    check "git in /usr/local/bin is labelled bin_t" test "$(type_of /usr/local/bin/git)" = bin_t
    check "git has one name: no hard link ties it to the libexec entries" test "$(stat -c %h /usr/local/bin/git)" = 1
    check "the libexec entry git-merge is a symlink" test -L /usr/local/libexec/git-core/git-merge
    check "restorecon would relabel nothing under /usr/local/bin" nothing_to_relabel -R /usr/local/bin
    show "libexec entries restorecon would relabel (symlinks and separate programs, by the policy): $(sudo restorecon -n -R /usr/local/libexec 2>&1 | wc -l)"
}

# ^ invariant clone_over_ssh PATH sets CLONE_OUT (the server's agent line) and RC; the server runs PATH as its upload-pack, the client is the git on PATH
clone_over_ssh() {
    local dest="$HOME/clone"
    rm -rf -- "$dest"
    GIT_SSH_COMMAND="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR" \
        GIT_TRACE_PACKET=1 git clone --upload-pack "$1" "ssh://$ME@127.0.0.1$SRV" "$dest" >"$OUTF" 2>&1
    RC=$?
    CLONE_OUT="$(grep -o 'agent=git/[0-9.]*' "$OUTF" | sort -u | tr '\n' ' ')"
}

push_over_ssh() {
    local work="$HOME/pushwork"
    rm -rf -- "$work"
    git init -q "$work" && git -C "$work" config user.name gsg && git -C "$work" config user.email gsg@example.invalid || return 1
    printf 'clean content\n' >"$work/a.txt" && git -C "$work" add a.txt && git -C "$work" commit -q -m first || return 1
    GIT_SSH_COMMAND="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR" \
        git -C "$work" push -q --receive-pack "$1" "ssh://$ME@127.0.0.1$SRV" HEAD:refs/heads/master >"$OUTF" 2>&1
}

vm_taken_over() {
    printf '== Rocky VM: labels, denials and sshd with the takeover active\n'
    show "$(stat -c "%C %n" /usr/bin/git /usr/bin/git-upload-pack /etc/dnf/dnf.conf /var/lib/git-secret-guard 2>&1)"
    check "/usr/bin/git is a link of ours" test "$(readlink /usr/bin/git)" = /usr/local/bin/git
    check "the links carry bin_t, as the RPM files did" test "$(type_of /usr/bin/git-upload-pack)" = bin_t
    check "dnf.conf kept its label" test -n "$(type_of /etc/dnf/dnf.conf)"
    check "restorecon would relabel none of the six links, dnf.conf and the backup directory" \
        nothing_to_relabel /usr/bin/git /usr/bin/git-receive-pack /usr/bin/git-shell /usr/bin/git-upload-archive /usr/bin/git-upload-pack /usr/bin/scalar /etc/dnf/dnf.conf /var/lib/git-secret-guard
    check "sshd runs" sudo systemctl is-active sshd
    check "git-receive-pack through /usr/bin accepts a push over ssh" push_over_ssh /usr/bin/git-receive-pack
    clone_over_ssh /usr/bin/git-upload-pack
    show "the server answered with: $CLONE_OUT (exit $RC)"
    check "git-upload-pack through /usr/bin serves a real clone over ssh" test "$RC" -eq 0
    check "the cloned working tree holds the pushed file" test "$(cat "$HOME/clone/a.txt" 2>/dev/null)" = "clean content"
    # shellcheck disable=SC2016
    check "the server that answered is the taken-over git (its agent is the new version, not the RPM's)" bash -c '[[ $1 == *"agent=git/$2 "* && $1 != *"agent=git/$3 "* ]]' _ "$CLONE_OUT" "$(git_ver /usr/local/bin/git)" "$RPM_GIT_VERSION"
    check "no AVC denial has been logged since the start" no_new_avc
    show "$(printf '%s' "$OUT" | head -n 6 | cut -c1-200)"
}

vm_restored() {
    printf '== Rocky VM: labels, denials and sshd after the restore\n'
    show "$(stat -c "%C %n" /usr/bin/git /usr/bin/git-upload-pack /etc/dnf/dnf.conf 2>&1)"
    check "restorecon would relabel none of the six files and dnf.conf" \
        nothing_to_relabel /usr/bin/git /usr/bin/git-receive-pack /usr/bin/git-shell /usr/bin/git-upload-archive /usr/bin/git-upload-pack /usr/bin/scalar /etc/dnf/dnf.conf
    check "/usr/bin/git is the RPM file again" test ! -L /usr/bin/git
    clone_over_ssh /usr/bin/git-upload-pack
    show "the server answered with: $CLONE_OUT (exit $RC)"
    check "git-upload-pack through /usr/bin serves a clone again" test "$RC" -eq 0
    # shellcheck disable=SC2016
    check "and the server is the RPM git again (its agent is the RPM's version)" bash -c '[[ $1 == *"agent=git/$2 "* ]]' _ "$CLONE_OUT" "$RPM_GIT_VERSION"
    check "no AVC denial has been logged over the whole run" no_new_avc
    show "$(printf '%s' "$OUT" | head -n 6 | cut -c1-200)"
}

# ^ why a policy query, not a run; unconfined_t cannot enter a confined domain on these files (runcon says Permission denied even for /usr/bin/true)
vm_policy_allows() {
    local dom type n
    for dom in httpd_t git_script_t sshd_t; do
        for type in bin_t usr_t; do
            n="$(sudo sesearch -A -s "$dom" -t "$type" -c file -p execute 2>/dev/null | grep -c 'allow ')"
            show "policy: $dom may execute $type files: $n rule(s)"
        done
    done
}

vm_restorecon_effect() {
    local mark
    printf '== Rocky VM: what a real restorecon -R /usr/local does to git\n'
    mark="$(date '+%x %T')"
    show "before: $(stat -c '%C %n' /usr/local/bin/git /usr/local/libexec/git-core/git-upload-pack /usr/local/libexec/git-core/git-remote-https 2>&1)"
    sudo restorecon -R /usr/local
    show "after: $(stat -c '%C %n' /usr/local/bin/git /usr/local/libexec/git-core/git-upload-pack /usr/local/libexec/git-core/git-remote-https 2>&1)"
    check "/usr/local/bin/git is still bin_t after restorecon -R /usr/local" test "$(type_of /usr/local/bin/git)" = bin_t
    check "restorecon -n -R /usr/local/bin now reports nothing" nothing_to_relabel -R /usr/local/bin
    clone_over_ssh /usr/local/bin/git-upload-pack
    show "clone served through /usr/local/bin/git-upload-pack after the relabel: exit $RC; $CLONE_OUT"
    check "the clone still works" test "$RC" -eq 0
    # shellcheck disable=SC2086
    show "AVC records since: $(sudo ausearch -m AVC,USER_AVC -ts $mark 2>&1 | head -n 6 | cut -c1-240)"
}

main_vm() {
    vm_prepare
    rocky_upgrade
    vm_labels_after_install
    rocky_takeover
    vm_taken_over
    rocky_takeover_dnf
    rocky_restore
    vm_restored
    vm_restorecon_effect
    e2e_summary
}

main_vm
