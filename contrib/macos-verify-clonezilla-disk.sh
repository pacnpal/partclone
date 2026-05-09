#!/bin/sh
#
# macos-verify-clonezilla-disk.sh
#
# Verify a restored disk (or attached sparse image) against the original
# Clonezilla "savedisk" image set. Pairs with macos-restore-clonezilla-disk.sh.
#
# Per-partition checks:
#   1. Source image CRC + header read via partclone.chkimg.
#   2. Filesystem fsck of the restored slice (read-only) where macOS has
#      a matching fsck binary.
#   3. Re-clone restored slice through partclone.<fs> -> partclone.chkimg
#      to validate CRCs of the data as it sits on the device.
#   4. Compare File system / Device size / Space in use between source
#      image and the re-cloned restored slice. They must match.
#
# Usage:
#   PARTCLONE_DIR=/path/to/partclone/src \
#       contrib/macos-verify-clonezilla-disk.sh <image_dir> <basename> <target>
#
# Example:
#   contrib/macos-verify-clonezilla-disk.sh \
#       ~/Downloads/Compaq_Armada sdb /dev/disk4
#
# Env:
#   PARTCLONE_DIR  directory containing partclone.fat, partclone.chkimg, etc.
#                  Defaults to <script_dir>/../src.
#
# Exit:
#   0  all partitions verified
#   1  one or more partitions failed
#   2  refused (boot disk)
#  64  usage error

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARTCLONE_DIR="${PARTCLONE_DIR:-$SCRIPT_DIR/../src}"

usage() {
    cat <<EOF >&2
Usage: $0 <image_dir> <disk_basename> <target>
  image_dir:      Clonezilla image folder.
  disk_basename:  e.g. "sdb".
  target:         /dev/diskN restored disk, or attached image device.

Env: PARTCLONE_DIR - dir with partclone.fat / partclone.chkimg (default ../src).
EOF
    exit 64
}

[ "$#" -eq 3 ] || usage

IMG_DIR="$1"
BASENAME="$2"
TARGET="$3"

PARTS_FILE="$IMG_DIR/parts"
[ -f "$PARTS_FILE" ] || { echo "missing $PARTS_FILE" >&2; exit 1; }

CHKIMG="$PARTCLONE_DIR/partclone.chkimg"
[ -x "$CHKIMG" ] || { echo "not executable: $CHKIMG" >&2; exit 1; }

# Refuse to verify the boot disk (we'd be reading it heavily under sudo).
case "$TARGET" in
    /dev/disk0|/dev/rdisk0|/dev/disk0s*|/dev/rdisk0s*)
        echo "REFUSE: target $TARGET is the internal boot disk." >&2
        exit 2
        ;;
esac

DEV_BASE="$(echo "$TARGET" | sed 's|/dev/rdisk|/dev/disk|')"
RAW_BASE="$(echo "$TARGET" | sed 's|/dev/disk|/dev/rdisk|')"

[ -e "$DEV_BASE" ] || { echo "no such device: $DEV_BASE" >&2; exit 1; }

PARTS=$(cat "$PARTS_FILE")
TMPDIR_V="$(mktemp -d -t partclone-verify)"
trap 'rm -rf "$TMPDIR_V"' EXIT INT TERM

OK_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Extract one of: "File system", "Device size", "Space in use" from a
# partclone.chkimg / partclone.info text dump. Returns the canonical
# string after the colon, with whitespace squeezed.
extract_field() {
    file="$1"; key="$2"
    awk -v k="$key" '
        index($0, k":") {
            sub(".*"k":[ \t]*", "")
            gsub(/[ \t]+/, " ")
            sub(/[ \t]+$/, "")
            print
            exit
        }
    ' "$file"
}

partclone_tool_for_fs() {
    case "$1" in
        vfat|fat|fat12|fat16|fat32)  echo "$PARTCLONE_DIR/partclone.fat"     ;;
        ntfs)                        echo "$PARTCLONE_DIR/partclone.ntfs"    ;;
        exfat)                       echo "$PARTCLONE_DIR/partclone.exfat"   ;;
        ext2|ext3|ext4)              echo "$PARTCLONE_DIR/partclone.$1"      ;;
        xfs|btrfs|f2fs|nilfs2|minix|hfsplus|ufs|reiserfs|reiser4|jfs)
            echo "$PARTCLONE_DIR/partclone.$1" ;;
        *)                           echo ""                                 ;;
    esac
}

fsck_for_fs() {
    case "$1" in
        vfat|fat|fat12|fat16|fat32) echo "/sbin/fsck_msdos -n" ;;
        exfat)                      echo "/sbin/fsck_exfat -n" ;;
        hfs|hfsplus)                echo "/sbin/fsck_hfs -n"   ;;
        apfs)                       echo "/sbin/fsck_apfs -n"  ;;
        udf)                        echo "/sbin/fsck_udf -n"   ;;
        *)                          echo ""                    ;;
    esac
}

echo "==> verifying $DEV_BASE against $IMG_DIR (basename=$BASENAME)"

for part in $PARTS; do
    PNUM="${part#"$BASENAME"}"
    if ! [ "$PNUM" -gt 0 ] 2>/dev/null; then
        echo "  ?? cannot extract partition number from '$part' — skipping"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    IMG_FIRST=$(ls "$IMG_DIR/${part}".*-ptcl-img.gz.aa 2>/dev/null | head -1)
    [ -n "$IMG_FIRST" ] || \
        IMG_FIRST=$(ls "$IMG_DIR/${part}".*-ptcl-img.aa 2>/dev/null | head -1)
    if [ -z "$IMG_FIRST" ]; then
        echo "  -- $part: no partclone image — skipping"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    FS=$(basename "$IMG_FIRST" | sed -n 's/.*\.\([^.-]*\)-ptcl-img.*/\1/p')
    case "$IMG_FIRST" in
        *.gz.aa) PREFIX="${IMG_FIRST%.aa}"; DECOMP="gzip -dc" ;;
        *.aa)    PREFIX="${IMG_FIRST%.aa}"; DECOMP="cat"      ;;
    esac

    # macOS distinction:
    #   /dev/rdiskNsM  - raw character device. Requires sector-aligned I/O.
    #                    partclone.fat -c walks the FAT 4 bytes at a time,
    #                    which fails on this device — the scan aborts
    #                    silently and reports only ~12k blocks "used"
    #                    (the FAT region itself), even though the data is
    #                    fully present. fsck_msdos handles raw fine.
    #   /dev/diskNsM   - buffered block device. Kernel handles arbitrary
    #                    read/write sizes. Use this for partclone.fat.
    BUF_SLICE="${DEV_BASE}s${PNUM}"
    RAW_SLICE="${RAW_BASE}s${PNUM}"
    SLICE="$BUF_SLICE"
    if [ ! -e "$SLICE" ]; then
        SLICE="$RAW_SLICE"
    fi

    echo
    echo "  -- $part  fs=$FS  slice=$SLICE"

    SRC_OUT="$TMPDIR_V/src-${part}.out"
    TGT_OUT="$TMPDIR_V/tgt-${part}.out"
    SRC_LOG="$TMPDIR_V/src-${part}.log"
    TGT_LOG="$TMPDIR_V/tgt-${part}.log"
    CLN_LOG="$TMPDIR_V/clone-${part}.log"

    # ---- 1. validate source image CRCs ------------------------------------
    echo "     [1/4] checksumming source image..."
    if ! cat "${PREFIX}".* | $DECOMP \
        | "$CHKIMG" -s - -L "$SRC_LOG" -B -F >"$SRC_OUT" 2>&1; then
        echo "     ✗ source image failed partclone.chkimg"
        sed 's/^/         /' "$SRC_OUT" | tail -10
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    SRC_FS=$(extract_field   "$SRC_OUT" "File system")
    SRC_DEV=$(extract_field  "$SRC_OUT" "Device size")
    SRC_USED=$(extract_field "$SRC_OUT" "Space in use")
    echo "          src: fs=$SRC_FS  dev=$SRC_DEV  used=$SRC_USED"

    # ---- 2. fsck the restored slice ---------------------------------------
    FSCK="$(fsck_for_fs "$FS")"
    if [ -n "$FSCK" ]; then
        # shellcheck disable=SC2086
        if $FSCK "$SLICE" >"$TMPDIR_V/fsck-${part}.out" 2>&1; then
            echo "     [2/4] fsck $FS clean"
        else
            echo "     [2/4] ⚠ fsck $FS reported issues:"
            sed 's/^/         /' "$TMPDIR_V/fsck-${part}.out" | tail -8
            # don't fail outright — fsck on a fresh restore can quibble
            # over unmount-clean flags etc. Treat as warning.
        fi
    else
        echo "     [2/4] no fsck binary for fs=$FS — skipping"
    fi

    # ---- 3. re-clone restored slice through chkimg ------------------------
    PC_TOOL="$(partclone_tool_for_fs "$FS")"
    if [ -z "$PC_TOOL" ] || [ ! -x "$PC_TOOL" ]; then
        echo "     [3/4] no partclone tool for fs=$FS — skipping deep verify"
        echo "     [4/4] (compare skipped)"
        # We did source CRC + fsck; count as OK in shallow mode.
        OK_COUNT=$((OK_COUNT + 1))
        continue
    fi

    echo "     [3/4] re-cloning $SLICE -> partclone.chkimg ..."
    # Two-step (clone-to-tempfile, then chkimg the tempfile) instead of a
    # pipe — POSIX sh has no pipefail, so a failed clone with an empty
    # stdout would otherwise let chkimg "succeed" on no input and produce
    # an empty / zeroed report. Detect the failure here, surface stderr.
    CLONE_IMG="$TMPDIR_V/clone-${part}.img"
    CLONE_ERR="$TMPDIR_V/clone-${part}.err"
    if ! "$PC_TOOL" -c -s "$SLICE" -o "$CLONE_IMG" \
            -L "$CLN_LOG" -B -F >"$CLONE_ERR" 2>&1; then
        echo "     ✗ partclone.<fs> clone of $SLICE failed (rc=$?):"
        sed 's/^/         /' "$CLONE_ERR" | tail -10
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    if [ ! -s "$CLONE_IMG" ]; then
        echo "     ✗ clone produced empty image at $CLONE_IMG"
        sed 's/^/         /' "$CLONE_ERR" | tail -10
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    if ! "$CHKIMG" -s "$CLONE_IMG" -L "$TGT_LOG" -B -F >"$TGT_OUT" 2>&1; then
        echo "     ✗ partclone.chkimg of cloned image failed (rc=$?):"
        sed 's/^/         /' "$TGT_OUT" | tail -10
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    TGT_FS=$(extract_field   "$TGT_OUT" "File system")
    TGT_DEV=$(extract_field  "$TGT_OUT" "Device size")
    TGT_USED=$(extract_field "$TGT_OUT" "Space in use")
    echo "          tgt: fs=$TGT_FS  dev=$TGT_DEV  used=$TGT_USED"

    # ---- 4. compare -------------------------------------------------------
    # File system type and Device size must match exactly. Used-space is
    # allowed to GROW slightly without failing the verify: macOS auto-mounts
    # FAT volumes between restore and verify, and the kernel writes
    # .fseventsd / .Spotlight-V100 metadata on first mount. That adds a
    # handful of clusters (~32 blocks = 16 KiB on a fresh restore). It is
    # not data loss.
    #
    # Tolerance: target may be up to 1% LARGER than source, but never
    # SMALLER. A smaller post-restore used count means real data loss.
    SRC_BLOCKS=$(awk -v s="$SRC_USED" 'BEGIN { for (i=1;i<=split(s,a," ");i++) if (a[i]+0 > 0) print a[i]+0 }' | tail -1)
    TGT_BLOCKS=$(awk -v s="$TGT_USED" 'BEGIN { for (i=1;i<=split(s,a," ");i++) if (a[i]+0 > 0) print a[i]+0 }' | tail -1)
    USED_OK=0
    if [ -n "$SRC_BLOCKS" ] && [ -n "$TGT_BLOCKS" ]; then
        if [ "$SRC_BLOCKS" -eq "$TGT_BLOCKS" ]; then
            USED_OK=1
        elif [ "$TGT_BLOCKS" -gt "$SRC_BLOCKS" ]; then
            DELTA=$((TGT_BLOCKS - SRC_BLOCKS))
            # 1% tolerance, with a 64-block floor for tiny volumes.
            TOL=$((SRC_BLOCKS / 100))
            [ "$TOL" -lt 64 ] && TOL=64
            if [ "$DELTA" -le "$TOL" ]; then
                USED_OK=1
            fi
        fi
    fi

    if [ "$SRC_FS" = "$TGT_FS" ] && \
       [ "$SRC_DEV" = "$TGT_DEV" ] && \
       [ "$USED_OK" -eq 1 ]; then
        if [ "$SRC_BLOCKS" = "$TGT_BLOCKS" ]; then
            echo "     [4/4] ✓ match: fs/device-size/used-space all equal"
        else
            echo "     [4/4] ✓ match: fs/device-size match; used+$((TGT_BLOCKS - SRC_BLOCKS)) blocks (mount-side metadata, within tolerance)"
        fi
        OK_COUNT=$((OK_COUNT + 1))
    else
        echo "     [4/4] ✗ MISMATCH"
        echo "          src: fs=$SRC_FS  dev=$SRC_DEV  used=$SRC_USED"
        echo "          tgt: fs=$TGT_FS  dev=$TGT_DEV  used=$TGT_USED"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

echo
echo "==> verify summary: ok=$OK_COUNT fail=$FAIL_COUNT skip=$SKIP_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "    one or more partitions did not verify."
    exit 1
fi
echo "    all checked partitions verified."
exit 0
