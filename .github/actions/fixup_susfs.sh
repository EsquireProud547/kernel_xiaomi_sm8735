#!/bin/bash
# SUSFS context fixup for CLO kernels
# The SUSFS patch expects <linux/dma-buf.h> in fs/proc/base.c
# which AOSP GKI has but CLO kernels don't.
set -e

KERNEL_ROOT="${1:-.}"
cd "$KERNEL_ROOT"

BASE_C="fs/proc/base.c"
if grep -q '#include <linux/dma-buf.h>' "$BASE_C" 2>/dev/null; then
  echo "  [✓] fs/proc/base.c: <linux/dma-buf.h> already present"
else
  echo "  [*] fs/proc/base.c: adding <linux/dma-buf.h> for SUSFS context..."
  sed -i '/#include <linux\/cpufreq_times.h>/a #include <linux/dma-buf.h>' "$BASE_C"
  grep -q '#include <linux/dma-buf.h>' "$BASE_C" && echo "  [✓] Done" || exit 1
fi
