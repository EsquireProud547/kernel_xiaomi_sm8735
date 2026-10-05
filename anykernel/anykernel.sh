### AnyKernel3 Ramdisk Mod Script
## Upstream: osm0sis @ https://github.com/osm0sis/AnyKernel3
##         @ 020dfec (2026-09-04)
##
## Xiaomi SM8735 (onyx) GKI 6.6.142 -- Capybara tuning.
##
## NOTE on variables: ak3-core.sh at 020dfec only reads UPPERCASE names
## (BLOCK, IS_SLOT_DEVICE, RAMDISK_COMPRESSION, PATCH_VBMETA_FLAG,
## NO_MAGISK_CHECK). Upstream commit cea8f97 "remove all backwards compat"
## dropped the lowercase spellings, so the lowercase form this file used
## before the update would have been silently ignored.

### AnyKernel setup
# global properties
properties() { '
## build-onyx.yml rewrites this line at package time with the real version
## string, so it cannot go stale. Keep the value below as a fallback only.
kernel.string=Onyx Kernel
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot files attributes
## none: this replaces the GKI Image, the ramdisk is not touched.

# boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;
NO_MAGISK_CHECK=1;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
# Devices with an init_boot partition carry the ramdisk there and keep only
# the kernel in boot, so replacing just the kernel half is both correct and
# much faster than unpacking and repacking the ramdisk. Everything else
# takes the ordinary dump_boot/write_boot path.
#
# The test used to be
#   [ -L "/dev/block/bootdevice/by-name/init_boot_a" -o -L "/dev/block/by-name/init_boot_a" ]
# which fails in two ways worth knowing: `-L` only matches a symlink, and
# `_a` is hardcoded rather than derived from the slot setup_ak just resolved.
# Upstream's own partition lookup (ak3-core.sh:920) uses existence tests
# against init_boot$SLOT instead. A device that exposes init_boot as a plain
# node, or only unsuffixed, falls into the else branch and hits
# unpack_ramdisk's abort (ak3-core.sh:229) because a kernel-only boot
# partition has no ramdisk -- a confusing failure on a device we know can
# take the init_boot path. $SLOT is set by the setup_ak call above at
# ak3-core.sh:887-903, so it is available here; on a non-A/B device it is
# empty and the unsuffixed name is what matches.
INIT_BOOT_PART=""
for _p in \
  "/dev/block/bootdevice/by-name/init_boot$SLOT" \
  "/dev/block/bootdevice/by-name/init_boot" \
  "/dev/block/by-name/init_boot$SLOT" \
  "/dev/block/by-name/init_boot"; do
  if [ -e "$_p" ]; then INIT_BOOT_PART="$_p"; break; fi;
done;
if [ -n "$INIT_BOOT_PART" ]; then
    ui_print "init_boot partition: $INIT_BOOT_PART"
    split_boot; # skip ramdisk unpack/repack on init_boot devices
    flash_boot; # repack only the kernel half
else
    dump_boot;  # ordinary boot partition
    write_boot;
fi;
## end boot install
