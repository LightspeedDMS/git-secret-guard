#!/usr/bin/env bash
set -u
set -o pipefail

# ^ external Rocky 9.8 GenericCloud image, a dated file; the digest is the one in its CHECKSUM file on dl.rockylinux.org, read 2026-11-06
IMAGE_NAME=Rocky-9-GenericCloud-Base-9.8-20260525.0.x86_64.qcow2
IMAGE_URL="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/$IMAGE_NAME"
IMAGE_SHA256=92c206cc6f790c61583247eefe87890f8828420662c17cacf247cec78ab4eec8
VM_USER=rocky
SSH_PORT="${GSG_VM_SSH_PORT:-2222}"
KVM_DEVICE="${GSG_VM_KVM_DEVICE:-/dev/kvm}"
ACCEL_WANTED="${GSG_VM_ACCEL:-kvm}"
VM_CPUS="${GSG_VM_CPUS:-4}"
VM_MEMORY="${GSG_VM_MEMORY:-8G}"
DOWNLOAD_TIMEOUT=900
BOOT_TICKS=240
BOOT_STEP=5
GUEST_TIMEOUT="${GSG_VM_GUEST_TIMEOUT:-3300}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
PROJECT="${HERE%/tests/platform}"

usage() {
    printf 'usage: tests/platform/rocky-vm.sh [--dry-run]\n'
    printf 'Boots the pinned Rocky 9 cloud image under qemu (KVM when /dev/kvm is writable) with SELinux enforcing, runs rocky-vm-e2e.sh in it over ssh,\n'
    printf 'and leaves the logs in GSG_VM_LOGDIR (default: the scratch directory, which is removed). GSG_VM_ACCEL=tcg runs without KVM, slowly.\n'
}

dry=0
case "${1:-}" in
    --dry-run) dry=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    "") ;;
    *)
        usage >&2
        exit 2
        ;;
esac

# ^ invariant accel is kvm when the device is writable, tcg only when GSG_VM_ACCEL=tcg asks for it; otherwise exit 3 with the cost said plainly
if [ -w "$KVM_DEVICE" ] && [ "$ACCEL_WANTED" = kvm ]; then
    accel=kvm
elif [ "$ACCEL_WANTED" = tcg ]; then
    accel=tcg
else
    printf 'rocky-vm.sh: KVM is not available (%s is not writable). Without it qemu uses TCG software emulation, which boots and runs a guest roughly\n' "$KVM_DEVICE" >&2
    printf '10 to 50 times slower than hardware acceleration: a dnf transaction and a git build take hours instead of minutes. Set GSG_VM_ACCEL=tcg to run anyway.\n' >&2
    exit 3
fi

work="" qemu_pid=""
# shellcheck disable=SC2329
cleanup() {
    if [ -n "$qemu_pid" ] && kill -0 "$qemu_pid" 2>/dev/null; then kill "$qemu_pid" 2>/dev/null; fi
    if [ -n "$work" ] && [[ ${work##*/} == gsg-vm.* ]]; then rm -rf -- "$work"; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

qemu_args=(-name gsg-rocky-vm -smp "$VM_CPUS" -m "$VM_MEMORY" -display none -no-reboot)
if [ "$accel" = kvm ]; then
    qemu_args=(-enable-kvm -cpu host "${qemu_args[@]}")
else
    qemu_args=(-accel tcg -cpu max "${qemu_args[@]}")
fi
# ^ security the only host port is the ssh forward and it is bound to 127.0.0.1; the guest reaches the network through qemu user-mode NAT
net_args=(-netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22")
net_args+=(-device "virtio-net-pci,netdev=n0")

if [ "$dry" -eq 1 ]; then
    printf 'image-url: %s\nimage-sha256: %s\naccel: %s\n' "$IMAGE_URL" "$IMAGE_SHA256" "$accel"
    printf 'qemu-arg: %s\n' "${qemu_args[@]}"
    printf 'qemu-arg: %s\n' "${net_args[@]}"
    exit 0
fi

for tool in qemu-system-x86_64 qemu-img cloud-localds ssh ssh-keygen curl sha256sum; do
    if ! type -P "$tool" >/dev/null; then
        printf 'rocky-vm.sh: %s is required and was not found on PATH\n' "$tool" >&2
        exit 2
    fi
done
work="$(mktemp -d -t gsg-vm.XXXXXX)" || exit 2
if [ -z "$work" ] || [[ $work != /* ]]; then
    printf 'rocky-vm.sh: no absolute scratch directory\n' >&2
    exit 2
fi
logdir="${GSG_VM_LOGDIR:-$work/logs}"
mkdir -p -- "$logdir" || exit 2

printf '== fetching %s\n' "$IMAGE_NAME"
timeout "$DOWNLOAD_TIMEOUT" curl -fsSL -o "$work/base.qcow2" "$IMAGE_URL" || {
    printf 'rocky-vm.sh: cannot download the image\n' >&2
    exit 2
}
printf '%s  base.qcow2\n' "$IMAGE_SHA256" | (cd "$work" && sha256sum -c -) || {
    printf 'rocky-vm.sh: the image does not match its pinned digest\n' >&2
    exit 2
}

ssh-keygen -q -t ed25519 -N '' -f "$work/key" || exit 2
{
    printf '#cloud-config\nusers:\n  - name: %s\n    sudo: ALL=(ALL) NOPASSWD:ALL\n    ssh_authorized_keys:\n      - %s\nssh_pwauth: false\n' "$VM_USER" "$(<"$work/key.pub")"
} >"$work/user-data" || exit 2
printf 'instance-id: gsg-vm-%s\nlocal-hostname: gsg-rocky\n' "$$" >"$work/meta-data" || exit 2
cloud-localds "$work/seed.iso" "$work/user-data" "$work/meta-data" || exit 2
qemu-img create -q -f qcow2 -b "$work/base.qcow2" -F qcow2 "$work/vm.qcow2" 20G || exit 2

printf '== starting the guest (accel %s, %s cpus, %s)\n' "$accel" "$VM_CPUS" "$VM_MEMORY"
qemu-system-x86_64 "${qemu_args[@]}" "${net_args[@]}" \
    -drive "file=$work/vm.qcow2,if=virtio,format=qcow2" -drive "file=$work/seed.iso,if=virtio,format=raw,readonly=on" \
    -serial "file:$logdir/console.log" -monitor none -daemonize -pidfile "$work/qemu.pid" || {
    printf 'rocky-vm.sh: qemu did not start\n' >&2
    exit 2
}
qemu_pid="$(<"$work/qemu.pid")"

SSH=(ssh -p "$SSH_PORT" -i "$work/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes "$VM_USER@127.0.0.1")
booted=0
for ((tick = 0; tick < BOOT_TICKS; tick++)); do
    if "${SSH[@]}" true 2>/dev/null; then
        booted=1
        break
    fi
    sleep "$BOOT_STEP"
done
if [ "$booted" -ne 1 ]; then
    printf 'rocky-vm.sh: the guest did not accept ssh within %s seconds; the console log is %s/console.log\n' "$((BOOT_TICKS * BOOT_STEP))" "$logdir" >&2
    tail -n 30 "$logdir/console.log" >&2
    exit 2
fi
printf '== guest is up after about %s seconds\n' "$((tick * BOOT_STEP))"

git -C "$PROJECT" ls-files -z -co --exclude-standard | tar -C "$PROJECT" --null -T - -cf - | "${SSH[@]}" 'mkdir -p checkout && tar -C checkout -xf -' || {
    printf 'rocky-vm.sh: cannot copy the checkout into the guest\n' >&2
    exit 2
}
"${SSH[@]}" "timeout $GUEST_TIMEOUT bash -l checkout/tests/platform/rocky-vm-e2e.sh" 2>&1 | tee "$logdir/guest.log"
rc="${PIPESTATUS[0]}"
"${SSH[@]}" 'sudo poweroff' >/dev/null 2>&1
if [ "$rc" -eq 0 ]; then
    printf 'ROCKY VM TEST: PASS (image %s, accel %s)\n' "$IMAGE_NAME" "$accel"
else
    printf 'ROCKY VM TEST: FAIL (guest exit %s, image %s, accel %s)\n' "$rc" "$IMAGE_NAME" "$accel"
fi
exit "$rc"
