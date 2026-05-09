#!/bin/sh
#
# macos-grow-partition.sh
#
# Grow a partition slot (and the filesystem inside it) to fill any
# trailing free space on its disk. Useful after restoring a small
# partclone image onto a larger USB / SSD: the FAT32 slot stays at the
# original size unless something extends it.
#
# Strategy: use `diskutil resizeVolume <slice> R`, which on macOS knows
# how to resize FAT32 and HFS+ in place (both partition slot in the
# MBR/GPT and the filesystem within). For unsupported filesystems we
# print a clear error.
#
# Usage:
#   contrib/macos-grow-partition.sh <disk> <part_number> [<size>]
#
# Examples:
#   # Grow disk4 partition 1 to fill all trailing free space
#   contrib/macos-grow-partition.sh /dev/disk4 1
#
#   # Grow it to a specific size (diskutil syntax: "5G", "5500M", ...)
#   contrib/macos-grow-partition.sh /dev/disk4 1 5G
#
# Limitations:
#   - macOS diskutil only supports resizing FAT32, HFS+, APFS containers
#     in place. NTFS, ext{2,3,4}, exFAT, FAT12/16 will report an error.
#   - The trailing free space must be physically adjacent to the
#     partition's slot. Run `diskutil list <disk>` to confirm.
#   - Refuses to touch /dev/disk0 (the boot disk).

set -eu

usage() {
    cat <<EOF >&2
Usage: $0 <disk> <part_number> [<size>]
  disk:         /dev/diskN (NOT /dev/diskNsM, the whole disk).
  part_number:  partition slot number, e.g. 1 for diskNs1.
  size:         optional diskutil size (default: R = fill free space).
EOF
    exit 64
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage

DISK="$1"
PNUM="$2"
SIZE="${3:-R}"

case "$DISK" in
    /dev/disk0|/dev/rdisk0|/dev/disk0s*|/dev/rdisk0s*)
        echo "REFUSE: $DISK is the internal boot disk." >&2
        exit 2
        ;;
esac

# normalize: accept /dev/diskN or /dev/rdiskN or diskN
DISK_BUF=$(echo "$DISK" | sed 's|/dev/rdisk|/dev/disk|; s|^disk|/dev/disk|')
DISK_ID=$(echo "$DISK_BUF" | sed 's|^/dev/||')
SLICE="${DISK_BUF}s${PNUM}"

if [ ! -e "$DISK_BUF" ]; then
    echo "no such device: $DISK_BUF" >&2; exit 1
fi
if [ ! -e "$SLICE" ]; then
    echo "no such slice: $SLICE — partition $PNUM not present?" >&2
    diskutil list "$DISK_BUF" || true
    exit 1
fi

echo "==> current layout for $DISK_BUF"
diskutil list "$DISK_BUF" || true
echo

# Capture size before/after for reporting.
SIZE_BEFORE=$(diskutil info "$SLICE" 2>/dev/null \
    | awk -F': ' '/Disk Size|Total Size/ {sub(/^ */, "", $2); print $2; exit}')

echo "==> diskutil resizeVolume $SLICE $SIZE"
if diskutil resizeVolume "$SLICE" "$SIZE"; then
    echo
    SIZE_AFTER=$(diskutil info "$SLICE" 2>/dev/null \
        | awk -F': ' '/Disk Size|Total Size/ {sub(/^ */, "", $2); print $2; exit}')
    echo "==> grew $SLICE: ${SIZE_BEFORE:-?} -> ${SIZE_AFTER:-?}"
    echo
    diskutil list "$DISK_BUF" || true
    exit 0
fi

cat >&2 <<EOF

==> diskutil resizeVolume failed.

Possible reasons:
  * Filesystem on $SLICE is not resizable by macOS (NTFS, ext, exFAT,
    FAT12/16). For FAT16 you can reformat or use Linux tools instead.
  * The trailing free space is not physically adjacent to $SLICE.
    Check 'diskutil list $DISK_BUF' — the (free space) row must be
    immediately after the partition slot you're trying to grow.
  * The volume is in use. Try: diskutil unmountDisk $DISK_BUF

Manual MBR-edit fallback (advanced, FAT32 only):
  1. diskutil unmountDisk $DISK_BUF
  2. sudo fdisk -e $DISK_BUF       # interactive: edit slot $PNUM size
  3. sudo fsck_msdos -n ${DISK_BUF}s${PNUM}
EOF
exit 1
