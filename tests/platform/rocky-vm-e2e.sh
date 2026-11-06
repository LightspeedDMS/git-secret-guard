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
ME="$(id -un)"

# ^ invariant true when ausearch finds no AVC or USER_AVC record since AVC_MARK; the records themselves go to OUT for the log
no_new_avc() {
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
    check "the prerequisites install" bash -c 'sudo dnf install -y --setopt=install_weak_deps=False jq rpm-build createrepo_c policycoreutils audit libselinux-utils git >/dev/null 2>&1'
    check "auditd is running, so denials are recorded" sudo systemctl is-active auditd
    check "sshd is running" sudo systemctl is-active sshd
    AVC_MARK="$(date '+%x %T')"
    show "AVC records are searched from $AVC_MARK"
    mkdir -p "$HOME/.ssh" "$HOME/srv" || return 1
    ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY" && cat "$SSH_KEY.pub" >>"$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
    /usr/bin/git init -q --bare "$SRV"
}

vm_labels_after_install() {
    printf '== Rocky VM: labels after the source install into /usr/local\n'
    show "$(stat -c "%C %n" /usr/local/bin/git /usr/local/libexec/git-core/git-upload-pack /usr/local/share/doc/git-*-local/MANIFEST 2>&1)"
    check "git in /usr/local/bin is labelled bin_t" test "$(type_of /usr/local/bin/git)" = bin_t
    check "the helpers in libexec are labelled bin_t" test "$(type_of /usr/local/libexec/git-core/git-upload-pack)" = bin_t
    show "$(stat -c "%i %C %h %n" /usr/local/bin/git /usr/local/libexec/git-core/git-merge /usr/local/libexec/git-core/git-add 2>&1)"
    show "$(matchpathcon /usr/local/bin/git /usr/local/libexec/git-core/git-merge /usr/local/libexec/git-core/git-add 2>&1)"
    check "restorecon would relabel nothing under /usr/local" nothing_to_relabel -R /usr/local
}

# ^ invariant clone_over_ssh PATH sets CLONE_OUT (the server's agent line) and RC; the server runs PATH as its upload-pack, the client is the git on PATH
clone_over_ssh() {
    local dest="$HOME/clone"
    rm -rf -- "$dest"
    GIT_SSH_COMMAND="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR" \
        GIT_TRACE_PACKET=1 git clone --upload-pack "$1" "ssh://$ME@127.0.0.1$SRV" "$dest" >"$OUTF" 2>&1
    RC=$?
    CLONE_OUT="$(grep -o 'agent=git/[0-9.]*' "$OUTF" | sort -u | head -n 2 | tr '\n' ' ')"
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
    check "the server that answered is the taken-over git" test "$CLONE_OUT" = "agent=git/$(git_ver /usr/local/bin/git) "
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
    check "and the server is the RPM git again" test "$CLONE_OUT" = "agent=git/$(/usr/bin/git --version | sed 's/^git version //') "
    check "no AVC denial has been logged over the whole run" no_new_avc
    show "$(printf '%s' "$OUT" | head -n 6 | cut -c1-200)"
}

# ^ invariant informational; git and its hard links are one inode, bin_t under /usr/local/bin by policy and usr_t under /usr/local/libexec
# ^ invariant a relabel of /usr/local ends with the label of the last path it visits; the output shows what the does to a clone sshd serves
vm_restorecon_effect() {
    local mark
    printf '== Rocky VM: what restorecon -R /usr/local does to the shared inode (measured, not judged)\n'
    mark="$(date '+%x %T')"
    show "before: $(stat -c '%C %i %n' /usr/local/bin/git /usr/local/libexec/git-core/git-upload-pack 2>&1)"
    sudo restorecon -R /usr/local
    show "after: $(stat -c '%C %i %n' /usr/local/bin/git /usr/local/libexec/git-core/git-upload-pack 2>&1)"
    clone_over_ssh /usr/local/bin/git-upload-pack
    show "clone served through /usr/local/bin/git-upload-pack after the relabel: exit $RC; $CLONE_OUT"
    # shellcheck disable=SC2086
    show "AVC records since: $(sudo ausearch -m AVC,USER_AVC -ts $mark 2>&1 | head -n 6 | cut -c1-240)"
    check "the experiment ran to the end" true
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
