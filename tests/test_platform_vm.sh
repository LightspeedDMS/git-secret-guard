#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# ^ external the Rocky VM launcher is a Linux-host tool (qemu, KVM); --dry-run starts nothing and the scripts use GNU tools
if [ "$TEST_OS" = Darwin ] || [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="the Rocky VM launcher is a Linux-host tool (qemu, KVM)"; fi

VM_SH="$GSG_PROJECT/tests/platform/rocky-vm.sh"

# ^ invariant vm_dry [VAR=VALUE]... = rocky-vm.sh --dry-run under env -i with a fake writable KVM device; later assignments win
vm_dry() {
    mkdir -p -- "$SANDBOX/home" "$SANDBOX/tmp" || return 1
    : >"$SANDBOX/kvm" && chmod 666 "$SANDBOX/kvm" || return 1
    run_cap env -i HOME="$SANDBOX/home" PATH="/usr/local/bin:/usr/bin:/bin" TMPDIR="$SANDBOX/tmp" GSG_VM_KVM_DEVICE="$SANDBOX/kvm" "$@" bash "$VM_SH" --dry-run
}

test_the_vm_image_is_pinned_by_file_name_and_digest_and_fetched_over_https() {
    vm_dry || return 1
    assert_rc 0 "dry run"
    assert_contains "$OUT" "image-url: https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base-9." "https, a dated file"
    assert_not_contains "$OUT" "latest" "a moving name is not a pin"
    if [[ ! $OUT =~ image-sha256:\ [0-9a-f]{64} ]]; then fail "the image digest is not 64 hex digits"; fi
}

test_the_guest_is_reachable_from_the_host_only_and_has_no_graphics() {
    vm_dry || return 1
    assert_contains "$OUT" "hostfwd=tcp:127.0.0.1:" "the ssh forward is bound to the loopback"
    assert_not_contains "$OUT" "tcp::" "no forward on every address"
    assert_not_contains "$OUT" "0.0.0.0" "nothing listens on all interfaces"
    assert_contains "$OUT" "qemu-arg: -nographic" "no display"
}

test_with_kvm_the_guest_runs_hardware_accelerated_and_says_so() {
    vm_dry || return 1
    assert_contains "$OUT" "accel: kvm" "the launcher names the accelerator"
    assert_contains "$OUT" "qemu-arg: -enable-kvm" "and asks for it"
}

test_without_kvm_it_stops_plainly_unless_software_emulation_is_asked_for() {
    vm_dry GSG_VM_KVM_DEVICE="$SANDBOX/no-such-device"
    assert_rc 3 "no KVM device"
    assert_contains "$ERR" "KVM is not available" "says so"
    assert_contains "$ERR" "TCG" "names the software emulation it would fall back to"
    assert_contains "$ERR" "GSG_VM_ACCEL=tcg" "and how to ask for it"
    vm_dry GSG_VM_KVM_DEVICE="$SANDBOX/no-such-device" GSG_VM_ACCEL=tcg
    assert_rc 0 "software emulation asked for"
    assert_contains "$OUT" "accel: tcg" "named"
    assert_not_contains "$OUT" "-enable-kvm" "and no KVM argument"
}

run_file_tests
