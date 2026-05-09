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
#   - macOS diskutil resizes HFS+ and APFS containers in place reliably.
#     For FAT32 it usually only works when the disk uses GPT; on MBR
#     ("FDisk_partition_scheme") it returns "file system volume format
#     does not support resizing" because there is no FAT32 grow tool in
#     macOS. NTFS, ext{2,3,4}, exFAT, FAT12/16 are never resizable.
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

# diskutil resizeVolume needs the volume unmounted (or at least the whole
# disk quiesced). Detect any mounted slice on this disk and unmount it.
is_mounted() {
    # "Mounted" / "Mount Point" lines from diskutil info — robust against
    # localization edge cases by checking both fields.
    diskutil info "$1" 2>/dev/null | awk -F': ' '
        /^[ \t]*Mounted[ \t]*:/ {
            sub(/^ */, "", $2);
            if ($2 == "Yes") { found=1 }
        }
        /^[ \t]*Mount Point[ \t]*:/ {
            sub(/^ */, "", $2);
            if ($2 != "" && $2 != "Not applicable (no file system)") { found=1 }
        }
        END { exit (found ? 0 : 1) }
    '
}

NEEDS_UNMOUNT=0
if is_mounted "$SLICE"; then
    NEEDS_UNMOUNT=1
else
    # Sibling slices on the same disk can also block a resize.
    for s in $(diskutil list "$DISK_BUF" 2>/dev/null \
                 | awk -v d="$DISK_ID" '$NF ~ "^"d"s[0-9]+$" {print $NF}'); do
        if is_mounted "/dev/$s"; then
            NEEDS_UNMOUNT=1
            break
        fi
    done
fi

if [ "$NEEDS_UNMOUNT" -eq 1 ]; then
    echo "==> $DISK_BUF has mounted volumes; unmounting whole disk"
    if ! diskutil unmountDisk "$DISK_BUF"; then
        echo "==> retrying with force unmount"
        diskutil unmountDisk force "$DISK_BUF" || {
            echo "ERROR: could not unmount $DISK_BUF — close any apps using it and retry." >&2
            exit 1
        }
    fi
    echo
fi

# Capture size before/after for reporting.
SIZE_BEFORE=$(diskutil info "$SLICE" 2>/dev/null \
    | awk -F': ' '/Disk Size|Total Size/ {sub(/^ */, "", $2); print $2; exit}')

# Detect partition scheme + FS type so we can warn early when we already
# know diskutil's resize is going to fail (e.g. FAT32 inside MBR).
DISK_SCHEME=$(diskutil info "$DISK_BUF" 2>/dev/null \
    | awk -F': ' '/Content \(IOContent\)|Partition Type/ {sub(/^ */, "", $2); print $2; exit}')
SLICE_FS=$(diskutil info "$SLICE" 2>/dev/null \
    | awk -F': ' '/File System Personality|Type \(Bundle\)/ {sub(/^ */, "", $2); print $2; exit}')
case "$DISK_SCHEME" in
    *FDisk_partition_scheme*|*MBR*|*DOS*)
        case "$SLICE_FS" in
            *MS-DOS*FAT32*|*FAT32*|*msdos*)
                echo "WARNING: $SLICE is FAT32 inside an MBR scheme."
                echo "         macOS diskutil typically refuses this combination."
                echo "         If the next step fails, see the post-failure hints."
                echo
                ;;
        esac
        ;;
esac

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
  * Filesystem on $SLICE is not resizable by macOS. Common case:
    FAT32 inside an MBR scheme — diskutil's FAT32 resize is GPT-only,
    and macOS ships no FAT32 grow tool. NTFS, ext, exFAT, FAT12/16
    are never resizable on macOS.
  * The trailing free space is not physically adjacent to $SLICE.
    Check 'diskutil list $DISK_BUF' — the (free space) row must be
    immediately after the partition slot you're trying to grow.
  * The volume is in use. Try: diskutil unmountDisk $DISK_BUF

What actually works for FAT32 on MBR
  Option A — Linux live USB / VM (cleanest, keeps data):
    Boot a Linux ISO (Ubuntu, GParted Live, SystemRescue) with the
    target disk attached, then either run GParted and resize the slot
    + filesystem in one move, or:
        sudo parted /dev/sdX resizepart <N> 100%
        sudo fatresize -s max /dev/sdX<N>

  Option B — macOS, partition table only (advanced, NOT enough on its own):
    'sudo fdisk -e $DISK_BUF' grows the MBR slot, but the FAT32
    filesystem inside stays its original size. There is no FAT32
    grow utility in macOS or Homebrew (no fatresize, no parted),
    so finish the job from Linux as in Option A.

  Option C — reformat (loses data on $SLICE):
    Copy files off, then:
        sudo diskutil partitionDisk $DISK_BUF MBR MS-DOS DATA R
EOF
exit 1
