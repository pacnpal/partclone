#!/bin/sh
#
# macos-clonezilla-to-raw.sh
#
# Convert a Clonezilla "savedisk" image set into a flat raw .img file
# (the kind you can `dd` to a USB stick, or attach with hdiutil, or
# mount in a VM). Wraps macos-restore-clonezilla-disk.sh, then detaches
# the loop device so the output is a standalone file.
#
# Usage:
#   contrib/macos-clonezilla-to-raw.sh <image_dir> <basename> <output.img> [--verify]
#
# Example:
#   contrib/macos-clonezilla-to-raw.sh \
#       ~/Downloads/Compaq_Armada sdb ~/Compaq_Armada.img --verify
#
# The result is a sparse file with a real MBR; you can:
#   * dd if=Compaq_Armada.img of=/dev/rdiskN bs=1m   # write to USB
#   * hdiutil attach -nomount Compaq_Armada.img      # inspect partitions
#   * qemu-system-i386 -hda Compaq_Armada.img        # boot in a VM

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<EOF >&2
Usage: $0 <image_dir> <disk_basename> <output.img> [--verify]
  image_dir:    Clonezilla folder.
  basename:     e.g. "sdb".
  output.img:   target file path. Will be created/overwritten.
  --verify:     run partition-level verify after conversion.
EOF
    exit 64
}

VERIFY_FLAG=""
POS=""
for arg in "$@"; do
    case "$arg" in
        --verify) VERIFY_FLAG="--verify" ;;
        -h|--help) usage ;;
        -*) echo "unknown option: $arg" >&2; usage ;;
        *) POS="$POS $arg" ;;
    esac
done
# shellcheck disable=SC2086
set -- $POS
[ "$#" -eq 3 ] || usage

IMG_DIR="$1"
BASENAME="$2"
OUT_IMG="$3"

case "$OUT_IMG" in
    /dev/*) echo "output must be a file path, not a device: $OUT_IMG" >&2; exit 64 ;;
esac

RESTORE_SH="$SCRIPT_DIR/macos-restore-clonezilla-disk.sh"
[ -x "$RESTORE_SH" ] || { echo "missing $RESTORE_SH" >&2; exit 1; }

echo "==> converting $IMG_DIR (basename=$BASENAME) -> $OUT_IMG"

# The restore script handles file targets and leaves the image attached.
# We re-attach later if --verify is requested, then always detach at end.
# shellcheck disable=SC2086
"$RESTORE_SH" "$IMG_DIR" "$BASENAME" "$OUT_IMG"

# After restore, the image is still attached. Find the device and detach.
ATTACH_INFO=$(hdiutil info)
DEV=$(printf '%s\n' "$ATTACH_INFO" | awk -v t="$OUT_IMG" '
    /^image-path *:/ { path = $0; sub(/^image-path *: /, "", path) }
    /^\/dev\/disk[0-9]+/ {
        if (path == t) { print $1; exit }
    }
')

if [ -n "$VERIFY_FLAG" ]; then
    if [ -n "$DEV" ]; then
        echo
        echo "==> verifying $DEV"
        VERIFY_SH="$SCRIPT_DIR/macos-verify-clonezilla-disk.sh"
        if [ -x "$VERIFY_SH" ]; then
            "$VERIFY_SH" "$IMG_DIR" "$BASENAME" "$DEV" || \
                echo "    ⚠ verify reported failures"
        else
            echo "    ⚠ $VERIFY_SH not found"
        fi
    else
        echo "    ⚠ could not locate attached device for $OUT_IMG; skipping verify"
    fi
fi

if [ -n "$DEV" ]; then
    echo
    echo "==> detaching $DEV"
    hdiutil detach "$DEV" >/dev/null 2>&1 || \
        hdiutil detach -force "$DEV" >/dev/null 2>&1 || \
        echo "    ⚠ could not detach $DEV (run: hdiutil detach $DEV)"
fi

if [ -f "$OUT_IMG" ]; then
    echo
    PHYS_BYTES=$(/usr/bin/stat -f '%z' "$OUT_IMG" 2>/dev/null || echo "?")
    DISK_BLOCKS=$(/usr/bin/du -k "$OUT_IMG" 2>/dev/null | awk '{print $1*1024}')
    echo "==> done."
    echo "    output:        $OUT_IMG"
    echo "    apparent size: $PHYS_BYTES bytes (sparse)"
    echo "    on-disk size:  ${DISK_BLOCKS:-?} bytes"
    echo
    echo "    write to USB:  sudo dd if=$OUT_IMG of=/dev/rdiskN bs=1m"
    echo "    inspect:       hdiutil attach -nomount $OUT_IMG"
fi
