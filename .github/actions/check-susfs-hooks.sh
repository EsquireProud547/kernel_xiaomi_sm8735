#!/bin/bash
#
# check-susfs-hooks.sh -- assert the SUSFS kernel patch landed in the right place.
#
# Copy of the same check for the 6.6.82 tree.
#
# WHY THIS EXISTS
#
# Applying susfs4ksu's 50_add_susfs_in_gki-android15-6.6.patch to this tree
# succeeds, but not cleanly in the sense that matters: it exits 0 while 19 of
# ~120 hunks apply at offsets (the largest being +148 lines in
# fs/proc/task_mmu.c) and one hunk applies at fuzz 1. `patch --forward` only
# exits non-zero when a hunk cannot be placed at all.
#
# A hunk that is placed in the wrong function is indistinguishable from
# success. That is worth guarding because the fuzz hunk lands in
# show_map_vma() -- the function that decides which dev/ino/name
# /proc/pid/maps reports, i.e. the whole point of SUSFS' SUS_MAP and
# OPEN_REDIRECT features. A silently misplaced hunk there means a kernel that
# reports success while quietly not hiding what it was asked to hide.
#
# Gate 3 already catches total loss (CONFIG_KSU_SUSFS disappearing), and the
# patch exit code catches total failure. Neither catches relocation. This
# closes that specific hole, and nothing more.
#
# WHAT IT CHECKS
#
# In fs/proc/task_mmu.c:
#   1. show_map_vma() is defined.
#   2. `dev = inode->i_sb->s_dev;` appears after it.
#   3. SUSFS_IS_INODE_SUS_MAP appears between them -- inside the function,
#      before the dev assignment, which is exactly where the patch puts it.
#   4. SUSFS_IS_INODE_OPEN_REDIRECT likewise.
#   5. susfs_sus_kstat_spoof_show_map_vma's extern exists somewhere.
#
# Ordering is checked by line number, so a hunk that slid into a different
# function, or a different file, leaves the window empty and this fails.
#
# USAGE
#   check-susfs-hooks.sh [path-to-fs/proc/task_mmu.c]
#
# Defaults to fs/proc/task_mmu.c relative to the current directory.
# Exit 0 = hooks are where they belong. Exit 1 with an explanation = not.
#
# Verified both ways locally: fails on an unpatched tree, passes after the
# patch applies, and fails again when the SUS_MAP block is deliberately moved
# out of show_map_vma() to the end of the file.
#
set -e

TARGET="${1:-fs/proc/task_mmu.c}"

if [ ! -f "$TARGET" ]; then
    echo "check-susfs-hooks: $TARGET not found" >&2
    exit 1
fi

python3 - "$TARGET" <<'PYEOF'
import sys, re

path = sys.argv[1]
lines = open(path, encoding='utf-8', errors='replace').read().splitlines()

def first(pattern, start=0):
    """1-based line number of the first match at or after `start`."""
    for i in range(start, len(lines)):
        if re.search(pattern, lines[i]):
            return i + 1
    return None

fn = first(r'^show_map_vma\(struct seq_file')
if fn is None:
    sys.exit("show_map_vma() not found in %s" % path)

dev = first(r'dev = inode->i_sb->s_dev;', fn)
if dev is None:
    sys.exit("`dev = inode->i_sb->s_dev;` not found after show_map_vma() "
             "(fn=L%d) in %s" % (fn, path))

map_ln = first(r'SUSFS_IS_INODE_SUS_MAP', fn)
redir_ln = first(r'SUSFS_IS_INODE_OPEN_REDIRECT', fn)
spoof_ln = first(r'susfs_sus_kstat_spoof_show_map_vma', 0)

if map_ln is None or not (fn < map_ln < dev):
    sys.exit("SUS_MAP check outside show_map_vma(): fn=L%s map=L%s dev=L%s"
             % (fn, map_ln, dev))
if redir_ln is None or not (fn < redir_ln < dev):
    sys.exit("OPEN_REDIRECT check outside show_map_vma(): fn=L%s redir=L%s dev=L%s"
             % (fn, redir_ln, dev))
if not spoof_ln:
    sys.exit("susfs_sus_kstat_spoof_show_map_vma extern missing from %s" % path)

print("  hooks located in %s:" % path)
print("    show_map_vma() defined      L%d" % fn)
print("    kstat spoof extern          L%d" % spoof_ln)
print("    OPEN_REDIRECT check         L%d" % redir_ln)
print("    SUS_MAP check               L%d" % map_ln)
print("    dev = inode->i_sb->s_dev    L%d" % dev)
print("    ordering: fn < redir < map < dev -> %s"
      % ("OK" if fn < redir_ln < map_ln < dev else "UNEXPECTED"))
PYEOF

echo "check-susfs-hooks: PASS" >&2
exit 0
