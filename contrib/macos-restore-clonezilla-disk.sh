#!/bin/sh
#
# macos-restore-clonezilla-disk.sh
#
# Restore an entire Clonezilla "savedisk" image set to a target disk on
# macOS using the per-partition partclone.restore binary built from this
# tree. partclone itself only handles single partitions; this is a thin
# orchestrator that mirrors what Clonezilla's `ocs-sr restore-disk` does
# on Linux.
#
# Two target modes:
#   1. /dev/diskN     - real disk (USB/external). Destroys all data.
#   2. /path/to/file  - regular file. Creates a sparse image, writes the
#                       partition table into it, attaches it via hdiutil,
#                       restores partitions, leaves it attached for fsck.
#
# Usage:
#   PARTCLONE=/path/to/partclone.restore \
#       contrib/macos-restore-clonezilla-disk.sh <image_dir> <basename> <target>
#
# Example:
#   contrib/macos-restore-clonezilla-disk.sh \
#       ~/Downloads/Compaq_Armada sdb /tmp/sdb_full.img
#
# Limitations (this pass):
#   - MBR partition tables only. GPT not handled.
#   - Only file system images that this build of partclone can restore
#     (FAT12/16/32 in the macOS port). ext/ntfs/etc. are skipped with a
#     warning if encountered.
#   - On a real /dev/diskN, you may need to physically detach and reattach
#     the device after step 2 if macOS doesn't re-read the partition
#     table automatically.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARTCLONE="${PARTCLONE:-$SCRIPT_DIR/../src/partclone.restore}"
PARTCLONE_DIR="${PARTCLONE_DIR:-$(dirname "$PARTCLONE")}"
VERIFY=0
GROW_PART=""
NO_CONFIRM=0

usage() {
    cat <<EOF >&2
Usage: $0 [options] <image_dir> <disk_basename> <target>
  image_dir:      Clonezilla image folder (must contain <basename>-mbr,
                  <basename>-hidden-data-after-mbr, parts, and one
                  *-ptcl-img.gz.aa per partition).
  disk_basename:  short name of the source disk, e.g. "sdb".
  target:         /dev/diskN  - real disk (DESTRUCTIVE)
                  /path/file  - sparse file (will be created/overwritten).

Options:
  --verify             run macos-verify-clonezilla-disk.sh after restore.
  --grow N             grow restored partition N to fill trailing free
                       space (calls macos-grow-partition.sh). Use with a
                       /dev/diskN target, not a file image.
  --no-confirm         skip the "type the device path" prompt (the caller
                       has already confirmed). Combine with VERIFY=1 etc
                       in non-interactive wrappers.

Env:
  PARTCLONE       partclone.restore binary path.
  PARTCLONE_DIR   dir holding partclone.fat / chkimg (for verify).
  VERIFY=1        same as --verify.
  GROW_PART=N     same as --grow N.
EOF
    exit 64
}

# parse leading options, leave positional args alone
while [ "$#" -gt 0 ]; do
    case "$1" in
        --verify)      VERIFY=1; shift ;;
        --grow)        GROW_PART="${2:-}"; shift 2 ;;
        --grow=*)      GROW_PART="${1#--grow=}"; shift ;;
        --no-confirm)  NO_CONFIRM=1; shift ;;
        -h|--help)     usage ;;
        --)            shift; break ;;
        -*)            echo "unknown option: $1" >&2; usage ;;
        *)             break ;;
    esac
done

# env-var equivalents
[ "${VERIFY_RESTORE:-0}" = "1" ] && VERIFY=1
[ -n "${GROW_PART_ENV:-}" ] && GROW_PART="$GROW_PART_ENV"
[ "${NO_CONFIRM_ENV:-0}" = "1" ] && NO_CONFIRM=1

if [ "$#" -ne 3 ]; then usage; fi

IMG_DIR="$1"
BASENAME="$2"
TARGET="$3"

MBR="$IMG_DIR/${BASENAME}-mbr"
GAP="$IMG_DIR/${BASENAME}-hidden-data-after-mbr"
PARTS_FILE="$IMG_DIR/parts"

[ -f "$MBR" ]        || { echo "missing $MBR" >&2; exit 1; }
[ -f "$PARTS_FILE" ] || { echo "missing $PARTS_FILE" >&2; exit 1; }
[ -x "$PARTCLONE" ]  || { echo "PARTCLONE not executable: $PARTCLONE" >&2; exit 1; }

PARTS=$(cat "$PARTS_FILE")

# Refuse to write to the boot disk under any circumstances.
case "$TARGET" in
    /dev/disk0|/dev/rdisk0|/dev/disk0s*|/dev/rdisk0s*)
        echo "REFUSE: target $TARGET is the internal boot disk." >&2
        exit 2
        ;;
esac

# ---------- prepare target ----------------------------------------------------

ATTACHED_DEV=""
DEV_BASE=""        # e.g. /dev/disk5  (the path to write per-partition slices)
RAW_BASE=""        # e.g. /dev/rdisk5
CLEANUP_DETACH=""  # if non-empty, detach this device on EXIT

cleanup() {
    if [ -n "$CLEANUP_DETACH" ]; then
        echo "==> detaching $CLEANUP_DETACH"
        hdiutil detach "$CLEANUP_DETACH" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

case "$TARGET" in
    /dev/disk*|/dev/rdisk*)
        DEV_BASE="$(echo "$TARGET" | sed 's|/dev/rdisk|/dev/disk|')"
        RAW_BASE="$(echo "$TARGET" | sed 's|/dev/disk|/dev/rdisk|')"

        if [ ! -e "$DEV_BASE" ]; then
            echo "no such device: $DEV_BASE" >&2
            exit 1
        fi

        echo "==> Target: $DEV_BASE  (DESTRUCTIVE)"
        diskutil list "$DEV_BASE" || true
        echo
        if [ "$NO_CONFIRM" -ne 1 ]; then
            printf "Type the literal device path (%s) to proceed, anything else to abort: " "$DEV_BASE"
            read -r CONFIRM
            if [ "$CONFIRM" != "$DEV_BASE" ]; then
                echo "aborted." >&2; exit 3
            fi
        fi

        diskutil unmountDisk force "$DEV_BASE" >/dev/null 2>&1 || true
        ;;
    *)
        echo "==> Target is a file image: $TARGET"
        # size = source disk size, taken from the MBR's parted dump if we
        # can find it; otherwise pick something generous.
        SIZE_MB=4096
        PARTED_FILE="$IMG_DIR/${BASENAME}-pt.parted.compact"
        if [ -f "$PARTED_FILE" ]; then
            SZ=$(awk -F'[: ]+' '/^Disk \//{print $4}' "$PARTED_FILE" \
                | sed 's/MB$//; s/GB$/000/')
            if [ -n "$SZ" ]; then SIZE_MB=$(( SZ + 64 )); fi
        fi

        echo "    creating sparse image, $SIZE_MB MB"
        rm -f "$TARGET"
        # truncate(1) is not on macOS — use mkfile -n for sparse, or dd seek
        dd if=/dev/zero of="$TARGET" bs=1m count=0 seek="$SIZE_MB" 2>/dev/null

        # Write MBR + gap into the file BEFORE attaching, so hdiutil sees
        # the partition table and creates /dev/diskNsM slices on attach.
        echo "    writing MBR (sector 0)"
        dd if="$MBR" of="$TARGET" bs=512 count=1 conv=notrunc 2>/dev/null

        if [ -f "$GAP" ]; then
            echo "    writing post-MBR gap"
            dd if="$GAP" of="$TARGET" bs=512 seek=1 conv=notrunc 2>/dev/null
        fi

        echo "    attaching as raw disk image"
        ATTACH_OUT=$(hdiutil attach -nomount \
                        -imagekey diskimage-class=CRawDiskImage "$TARGET")
        ATTACHED_DEV=$(printf '%s' "$ATTACH_OUT" \
            | awk '/^\/dev\/disk[0-9]+/ {print $1; exit}')
        if [ -z "$ATTACHED_DEV" ]; then
            echo "hdiutil attach failed:" >&2
            echo "$ATTACH_OUT" >&2
            exit 1
        fi
        DEV_BASE="$ATTACHED_DEV"
        RAW_BASE="$(echo "$DEV_BASE" | sed 's|/dev/disk|/dev/rdisk|')"
        CLEANUP_DETACH="$DEV_BASE"
        echo "    attached: $DEV_BASE"
        diskutil list "$DEV_BASE" || true
        ;;
esac

# ---------- write MBR + gap to a real device ---------------------------------

case "$TARGET" in
    /dev/disk*|/dev/rdisk*)
        echo
        echo "==> writing MBR to $RAW_BASE (sector 0)"
        dd if="$MBR" of="$RAW_BASE" bs=512 count=1 conv=sync 2>&1 | tail -1
        if [ -f "$GAP" ]; then
            echo "==> writing post-MBR gap to $RAW_BASE (sector 1+)"
            dd if="$GAP" of="$RAW_BASE" bs=512 seek=1 conv=sync 2>&1 | tail -1
        fi
        echo "==> nudging kernel to re-read partition table"
        # try a few different things; one of them usually wins
        diskutil unmountDisk force "$DEV_BASE" >/dev/null 2>&1 || true
        diskutil list "$DEV_BASE"
        ;;
esac

# ---------- restore each partition --------------------------------------------

echo
echo "==> restoring partitions"
for part in $PARTS; do
    PNUM="${part#"$BASENAME"}"
    if ! [ "$PNUM" -gt 0 ] 2>/dev/null; then
        echo "  ?? cannot extract partition number from '$part' — skipping"
        continue
    fi

    IMG_FIRST=$(ls "$IMG_DIR/${part}".*-ptcl-img.gz.aa 2>/dev/null | head -1)
    if [ -z "$IMG_FIRST" ]; then
        # also accept uncompressed
        IMG_FIRST=$(ls "$IMG_DIR/${part}".*-ptcl-img.aa 2>/dev/null | head -1)
    fi
    if [ -z "$IMG_FIRST" ]; then
        echo "  -- $part: no partclone image in $IMG_DIR — skipping"
        continue
    fi

    SLICE="${RAW_BASE}s${PNUM}"
    SLICE_BUF="${DEV_BASE}s${PNUM}"
    if [ ! -e "$SLICE_BUF" ]; then
        echo "  -- $part: slice $SLICE_BUF does not exist; partition table" \
             "may not have been re-read. Skipping."
        echo "     ↳ try: hdiutil detach $DEV_BASE; hdiutil attach -nomount" \
             "-imagekey diskimage-class=CRawDiskImage $TARGET"
        continue
    fi

    case "$IMG_FIRST" in
        *.gz.aa)  PREFIX="${IMG_FIRST%.aa}";  DECOMP="gzip -dc" ;;
        *.aa)     PREFIX="${IMG_FIRST%.aa}";  DECOMP="cat"      ;;
    esac

    echo
    echo "  -- $part -> $SLICE   ($(basename "$IMG_FIRST"))"
    # cat all chunks (.aa, .ab, .ac, ...) → decompress → partclone.restore
    cat "${PREFIX}".* | $DECOMP | \
        "$PARTCLONE" -s - -O "$SLICE" -C \
            -L "/tmp/partclone-restore-${part}.log"
done

echo
echo "==> restore done."

# ---------- optional grow -----------------------------------------------------
if [ -n "$GROW_PART" ]; then
    case "$TARGET" in
        /dev/disk*|/dev/rdisk*)
            GROW_SH="$SCRIPT_DIR/macos-grow-partition.sh"
            if [ -x "$GROW_SH" ]; then
                echo
                echo "==> growing partition $GROW_PART on $DEV_BASE"
                "$GROW_SH" "$DEV_BASE" "$GROW_PART" || \
                    echo "    ⚠ grow step failed (continuing)"
            else
                echo "    ⚠ macos-grow-partition.sh not found/executable; skipping --grow"
            fi
            ;;
        *)
            echo "    --grow ignored: target is a file image, not /dev/diskN"
            ;;
    esac
fi

# ---------- optional verify ---------------------------------------------------
VERIFY_RC=0
if [ "$VERIFY" -eq 1 ]; then
    VERIFY_SH="$SCRIPT_DIR/macos-verify-clonezilla-disk.sh"
    if [ -x "$VERIFY_SH" ]; then
        echo
        echo "==> running verify pass"
        PARTCLONE_DIR="$PARTCLONE_DIR" "$VERIFY_SH" \
            "$IMG_DIR" "$BASENAME" "$DEV_BASE" || VERIFY_RC=$?
    else
        echo "    ⚠ macos-verify-clonezilla-disk.sh not found/executable"
        VERIFY_RC=1
    fi
fi

case "$TARGET" in
    /dev/disk*|/dev/rdisk*)
        echo "    target: $DEV_BASE — eject when ready: diskutil eject $DEV_BASE"
        ;;
    *)
        echo "    image:  $TARGET (still attached as $DEV_BASE)"
        echo "    detach when done: hdiutil detach $DEV_BASE"
        # disable trap so we leave it attached for the caller
        CLEANUP_DETACH=""
        ;;
esac

exit "$VERIFY_RC"
