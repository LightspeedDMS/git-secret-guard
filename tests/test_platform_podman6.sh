#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# ^ external the container scripts read /proc and run apt; they are Linux only and macOS and Windows have neither
if [ "$TEST_OS" = Darwin ] || [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="the container isolation check reads /proc, Linux only"; fi

# ^ external fixtures/podman/mountinfo-podman-6.1.3.txt = mountinfo of the pinned Debian 13 image on podman 6.1.3 (crun 1.30.1, 12 CPUs), host paths scrubbed
PODMAN6_MOUNTINFO="$GSG_PROJECT/tests/fixtures/podman/mountinfo-podman-6.1.3.txt"
# ^ external mount ids in the sample for /sys, the cpu0 mask, the first powercap mask and the powercap mask on top of it; ids from 2001 up are free
P6_SYS=1529
P6_CPU0_THROTTLE=1675
P6_POWERCAP_FIRST=1670
P6_POWERCAP_STACKED=1740

# ^ invariant podman6_with [LINE...] = the podman 6 sample in $SANDBOX/mi plus the given raw mountinfo lines
podman6_with() {
    cp -- "$PODMAN6_MOUNTINFO" "$SANDBOX/mi" || return 1
    if [ "$#" -gt 0 ]; then printf '%s\n' "$@" >>"$SANDBOX/mi"; fi
}

# ^ invariant mi_line ID PARENT MP FSTYPE = a mountinfo line shaped like podman 6's masks (read-only, crun's empty directory as source)
mi_line() {
    printf '%s %s 0:3 /scrubbed %s ro,nosuid,nodev,relatime - %s scrubbed rw' "$1" "$2" "$3" "$4"
}

# ^ invariant p6_mounts = isolation_stray_mounts of tests/platform/ubuntu-container.sh on $SANDBOX/mi, in a clean bash
# shellcheck disable=SC2016
p6_mounts() {
    run_cap env -i PATH="/usr/local/bin:/usr/bin:/bin" bash -c 'source "$1" && isolation_stray_mounts "$2"' _ "$GSG_PROJECT/tests/platform/ubuntu-container.sh" "$SANDBOX/mi"
}

test_the_mount_check_accepts_the_mount_table_of_podman_6() {
    podman6_with || return 1
    p6_mounts
    assert_rc 0 "the table of podman 6.1.3: 12 thermal_throttle masks and powercap masked twice, one on top of the other"
    assert_empty "$OUT" "nothing is named"
}

test_the_mount_check_accepts_any_number_of_cpu_masks_and_names_every_other_thermal_throttle_path() {
    local cpu bad
    podman6_with "$(mi_line 2001 "$P6_SYS" /sys/devices/system/cpu/cpu12/thermal_throttle tmpfs)" "$(mi_line 2002 "$P6_SYS" /sys/devices/system/cpu/cpu128/thermal_throttle tmpfs)" || return 1
    p6_mounts
    assert_rc 0 "cpu12 and cpu128 follow the same rule as cpu0"
    for cpu in cpuN cpux cpu cpu1x cpu-1 CPU1 cpu01 cpu1.5; do
        podman6_with "$(mi_line 2001 "$P6_SYS" "/sys/devices/system/cpu/$cpu/thermal_throttle" tmpfs)" || return 1
        p6_mounts
        assert_rc 1 "[$cpu] is not a CPU index"
        assert_eq "$OUT" "/sys/devices/system/cpu/$cpu/thermal_throttle" "[$cpu] is named as it is"
    done
    for bad in /sys/devices/system/cpu/cpu1/thermal_throttle/x /sys/devices/system/cpu/cpu1/cpufreq /sys/devices/system/cpu/cpu1 /sys/devices/system/cpu/thermal_throttle \
        /sys/devices/system/cpux/cpu1/thermal_throttle /sys/devices/system/cpu/cpu1/thermal_throttlex /sys/devices/system/cpu/cpu1/a/thermal_throttle; do
        podman6_with "$(mi_line 2001 "$P6_SYS" "$bad" tmpfs)" || return 1
        p6_mounts
        assert_rc 1 "[$bad] is outside the rule"
        assert_eq "$OUT" "$bad" "[$bad] is named as it is"
    done
}

test_the_mount_check_names_a_thermal_throttle_mount_that_is_not_the_tmpfs_mask_or_is_repeated() {
    local fs
    for fs in xfs ext4 overlay devtmpfs; do
        podman6_with "$(mi_line 2001 "$P6_SYS" /sys/devices/system/cpu/cpu20/thermal_throttle "$fs")" || return 1
        p6_mounts
        assert_rc 1 "cpu20 as $fs"
        assert_eq "$OUT" "/sys/devices/system/cpu/cpu20/thermal_throttle (fstype $fs)" "named with the fstype it shows"
    done
    podman6_with "$(mi_line 2001 "$P6_CPU0_THROTTLE" /sys/devices/system/cpu/cpu0/thermal_throttle tmpfs)" || return 1
    p6_mounts
    assert_rc 1 "cpu0 masked twice, even on top of the first mask (mount id $P6_CPU0_THROTTLE in the sample)"
    assert_eq "$OUT" "/sys/devices/system/cpu/cpu0/thermal_throttle (mounted more than once)" "named"
}

test_the_mount_check_accepts_a_powercap_mask_stacked_once_on_the_first_and_nothing_looser() {
    local pc=/sys/devices/virtual/powercap
    podman6_with "$(mi_line 2001 "$P6_POWERCAP_STACKED" "$pc" tmpfs)" || return 1
    p6_mounts
    assert_rc 1 "a third powercap mount"
    assert_eq "$OUT" "$pc (mounted more than once)" "named"
    podman6_with "$(mi_line 2001 "$P6_POWERCAP_FIRST" "$pc" tmpfs)" || return 1
    p6_mounts
    assert_rc 1 "a third powercap mount on the first one"
    podman6_with || return 1
    sed -i "s|^$P6_POWERCAP_STACKED $P6_POWERCAP_FIRST |$P6_POWERCAP_STACKED $P6_SYS |" "$SANDBOX/mi" || return 1
    p6_mounts
    assert_rc 1 "the second powercap mount is beside the first, not on top of it"
    assert_eq "$OUT" "$pc (mounted more than once)" "named"
    podman6_with || return 1
    sed -i "/^$P6_POWERCAP_STACKED /s/ - tmpfs / - xfs /" "$SANDBOX/mi" || return 1
    p6_mounts
    assert_rc 1 "the stacked powercap mount is another filesystem"
    podman6_with || return 1
    sed -i "/^$P6_POWERCAP_FIRST /s/ - tmpfs / - xfs /;/^$P6_POWERCAP_STACKED /s/ - tmpfs / - xfs /" "$SANDBOX/mi" || return 1
    p6_mounts
    assert_rc 1 "both powercap mounts are the same wrong filesystem"
    assert_contains "$OUT" "$pc (fstype xfs)" "the first one is named"
    podman6_with "$(mi_line 2001 "$P6_SYS" /sys/dev/block tmpfs)" "$(mi_line 2002 2001 /sys/dev/block tmpfs)" || return 1
    p6_mounts
    assert_rc 1 "stacking is allowed for powercap only"
    assert_eq "$OUT" "/sys/dev/block (mounted more than once)" "named"
    podman6_with "$(mi_line 2001 "$P6_SYS" /root/injected tmpfs)" || return 1
    p6_mounts
    assert_rc 1 "a stray mount next to the podman 6 masks"
    assert_eq "$OUT" "/root/injected" "is the only name printed"
}

run_file_tests
