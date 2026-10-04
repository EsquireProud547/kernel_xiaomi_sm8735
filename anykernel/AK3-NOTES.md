AnyKernel3 for Xiaomi SM8735 (onyx)
==================================

Scripts: upstream osm0sis/AnyKernel3 @ 020dfec (2026-09-04)
Binaries: aarch64 builds

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
