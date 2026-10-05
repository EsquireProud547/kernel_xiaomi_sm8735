AnyKernel3 for Xiaomi SM8735 (onyx)
==================================

Scripts: upstream osm0sis/AnyKernel3 @ 020dfec (2026-09-04)
Binaries: aarch64 builds

This directory is byte-identical to the one in kernel_xiaomi_sm8735
(android15-6.6 @ 6.6.82). It was verified after copying: all seven
binaries report "ARM aarch64". The flashing logic does not depend on the
kernel version, so there is nothing version-specific to change here.

--------------------------------------------------------------------------
ARCHITECTURE: DO NOT "update" tools/ from upstream master
--------------------------------------------------------------------------

Upstream's repository ships **ARM (32-bit)** builds only. From its README:

  "The AK3 repo includes current ARM builds of magiskboot, magiskpolicy,
   lptools_static, httools_static, fec, snapshotupdater_static and busybox by
   default to keep the basic package small. Builds for other architectures and
   optional binaries (see below) are available from the latest Magisk zip, or
   my latest AIK-mobile and FlashIt packages"

Running `git pull` / copying tools/ from upstream master therefore replaces the
aarch64 binaries with 32-bit ARM ones. That happened once and broke flashing:

  * SM8735 is an Oryon-based SoC and does not execute AArch32 code, so every
    binary in tools/ fails with "exec format error".
  * The failure is not subtle under KernelSU managers. BakaSU's built-in AK3
    flasher (userspace/ksud/src/anykernel3.rs) injects

        cp -f '<BIN>/mkbootfs' "$AKHOME/tools/mkbootfs" || exit 1;

    at the "chmod -R 755 tools bin;" marker in update-binary. Because that
    marker sits after "$bb " in setup_bb(), the injection expands to

        $bb cp -f ... || exit 1;

    with $bb = tools/busybox. A 32-bit busybox cannot exec, the `|| exit 1`
    fires, and the install aborts immediately.

--------------------------------------------------------------------------
What to update and what not to
--------------------------------------------------------------------------

Safe to take from upstream master:
  - tools/ak3-core.sh
  - META-INF/com/google/android/update-binary
  - META-INF/com/google/android/updater-script
  - anykernel.sh (device setup lives in ours)

Must NOT be taken from upstream master (arch must stay aarch64):
  - tools/busybox, tools/magiskboot, tools/magiskpolicy,
    tools/fec, tools/httools_static, tools/lptools_static,
    tools/snapshotupdater_static

To refresh those, take the aarch64 builds from a Magisk release or from
osm0sis's AIK-mobile / FlashIt packages, then verify with:

    file tools/*

Every ELF should report "ARM aarch64". Note that upstream's arch detection in
setup_bb() only looks for tools/x86 and tools/arm, so the aarch64 binaries must
live directly in tools/ -- there is no tools/arm64 fallback.

## Audit findings (2026-10-06) — checked against upstream at 020dfec

Upstream `master` IS our pinned commit, so there is nothing to pull for
scripts; every file except `anykernel.sh` and the binaries matched
byte-for-byte. Verified rather than assumed.

### init_boot detection was fixed

`anykernel.sh` used to test

    [ -L "/dev/block/bootdevice/by-name/init_boot_a" -o ... ]

Two ways that fails, both silently resolved to the wrong branch:

  * `_a` is hardcoded, so a device currently booted into slot **b** with
    only `init_boot_b` present falls through to `dump_boot`.
  * `-L` only matches a symlink. A device that exposes `init_boot` as a
    plain node, or only unsuffixed, falls through the same way.

Falling through is not catastrophic — `unpack_ramdisk` aborts because a
kernel-only `boot` has no ramdisk — but the message ("No ramdisk found to
unpack") points nowhere near the real cause. Upstream's own lookup
(ak3-core.sh:920) uses `-e` against `init_boot$SLOT`, and `$SLOT` is set
by the `setup_ak` call that runs before this test. The new code uses `-e`
over both suffixed and unsuffixed names, in the same order ak3-core.sh
searches partitions. Verified against six layouts by building fake
by-name trees; three of them are cases the old test missed.

### A build that stages no kernel image would have flashed the stock one

`flash_boot` (ak3-core.sh:331-336) looks for Image/Image.gz/Image.gz-dtb
in the zip root and, finding none, reflashes the kernel it just dumped
off the device — the zip reports success and changes nothing. The
workflow's staging chain had no `else`, so a build producing none of the
three would have shipped that zip. It now fails the job instead, with the
contents of out/arch/arm64/boot printed.

### Two things we did NOT change, and why

**magiskboot and magiskpolicy are old.** They match the upstream
`arm64-tools` branch's first arm64 commit (a6e4c28, 2023-10-18) while the
other five binaries are at that branch's head (f1a6f5e, 2026-09-04,
magisk v31.0). Only `magiskboot` is actually executed on this path
(`magiskpolicy` and `fec` are referenced zero times by ak3-core.sh at
020dfec), so the risk of staying is bounded and the risk of swapping is
unknown — the zip flashes today, which is worth more than six releases of
bug fixes. Swap deliberately when there is a reason.

**PATCH_VBMETA_FLAG=auto degenerates to false.** ak3-core.sh:469-473
resolves `auto` from the Magisk config, which cannot exist because
NO_MAGISK_CHECK=1 disables detection. Whether onyx's vbmeta needs the
flag set for a replaced boot image is not knowable from the repo; the
device takes a custom boot without it, which is evidence it does not.

Compatibility check when bumping the scripts: the new ak3-core.sh invokes a
subset of the magiskboot subcommands the previous one used (it dropped
"magiskboot supports"), so these binaries remain sufficient.

--------------------------------------------------------------------------
Device setup
--------------------------------------------------------------------------

anykernel.sh keeps do.devicecheck=0 for a device-agnostic GKI Image, and picks
the install path by whether the device has an init_boot partition:

    init_boot present -> split_boot + flash_boot   (kernel half only)
    otherwise         -> dump_boot  + write_boot

kernel.string is a fallback; build-onyx.yml overwrites it at package time with
the real release string.
