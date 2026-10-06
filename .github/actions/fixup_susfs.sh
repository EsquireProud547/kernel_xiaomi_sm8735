#!/bin/bash
# Make sure <linux/dma-buf.h> is included in fs/proc/base.c, which the SUSFS
# context hooks expect.
#
# On THIS tree (android15-6.6 @ 6.6.82) the include is genuinely absent, so
# this is what adds it. The sibling seventeen tree already has it at
# fs/proc/base.c:103 and treats the same script as a self-checking no-op,
# which is why it stays idempotent.
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
