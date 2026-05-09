#!/bin/sh
#
# macos-clonezilla.sh
#
# Friendly entry point that wires together the rest of the contrib/
# scripts: pick a Clonezilla image, pick a target (real disk or .img
# file), restore, verify, and optionally grow the last partition to
# fill the disk.
#
# Usage:
#   contrib/macos-clonezilla.sh                    # fully interactive
#   contrib/macos-clonezilla.sh <image_dir>        # pick target only
#   contrib/macos-clonezilla.sh <image_dir> <target>
#
# Env (skip prompts):
#   IMAGE_DIR, BASENAME, TARGET, GROW=1|0, VERIFY=1|0, GROW_PART=N
#
# Examples:
#   # Interactive, pick everything
#   contrib/macos-clonezilla.sh
#
#   # Restore Compaq Armada to disk4, grow partition 1, verify
#   GROW=1 GROW_PART=1 VERIFY=1 \
#       contrib/macos-clonezilla.sh \
#           ~/Downloads/Compaq_Armada /dev/disk4
#
#   # Convert to a raw .img file
#   contrib/macos-clonezilla.sh ~/Downloads/Compaq_Armada ~/armada.img

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARTCLONE="${PARTCLONE:-$SCRIPT_DIR/../src/partclone.restore}"
PARTCLONE_DIR="${PARTCLONE_DIR:-$(dirname "$PARTCLONE")}"

RESTORE_SH="$SCRIPT_DIR/macos-restore-clonezilla-disk.sh"
VERIFY_SH="$SCRIPT_DIR/macos-verify-clonezilla-disk.sh"
GROW_SH="$SCRIPT_DIR/macos-grow-partition.sh"
RAW_SH="$SCRIPT_DIR/macos-clonezilla-to-raw.sh"

if ! [ -t 0 ] && [ -z "${IMAGE_DIR:-}" ]; then
    echo "non-interactive run requires IMAGE_DIR / TARGET env vars" >&2
    exit 64
fi

[ -x "$RESTORE_SH" ] || { echo "missing $RESTORE_SH" >&2; exit 1; }
[ -x "$PARTCLONE" ]  || { echo "missing $PARTCLONE (build src/ first)" >&2; exit 1; }

ask() {
    # ask "<prompt>" "<default>"  -> echoes the user's answer (or default).
    prompt="$1"; default="${2:-}"
    if [ -n "$default" ]; then
        printf "%s [%s]: " "$prompt" "$default" >&2
    else
        printf "%s: " "$prompt" >&2
    fi
    read -r ans
    if [ -z "$ans" ]; then ans="$default"; fi
    printf '%s' "$ans"
}

confirm() {
    # confirm "<prompt>" "<default y|n>"  -> exit 0 if yes
    p="$1"; d="${2:-n}"
    case "$d" in
        y|Y) hint="[Y/n]"; default="y" ;;
        *)   hint="[y/N]"; default="n" ;;
    esac
    printf "%s %s: " "$p" "$hint" >&2
    read -r a
    a="${a:-$default}"
    case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ------------------- pick image dir -------------------
IMAGE_DIR="${IMAGE_DIR:-${1:-}}"
if [ -z "$IMAGE_DIR" ]; then
    echo "==> Clonezilla image directories under ~/Downloads (depth 4):"
    i=0
    set --
    # Find folders that contain a `parts` file (the Clonezilla marker)
    while IFS= read -r d; do
        i=$((i + 1))
        echo "   $i) $d"
        set -- "$@" "$d"
    done <<EOF
$(find "$HOME/Downloads" -maxdepth 4 -type f -name parts 2>/dev/null \
     | sed 's|/parts$||' | sort -u)
EOF
    if [ "$i" -eq 0 ]; then
        echo "   (none found in ~/Downloads — enter a path manually)"
    fi
    PICK=$(ask "image dir number, or full path" "")
    [ -z "$PICK" ] && { echo "no image dir, aborting." >&2; exit 1; }
    case "$PICK" in
        ''|*[!0-9]*) IMAGE_DIR="$PICK" ;;
        *) eval "IMAGE_DIR=\${$PICK}" ;;
    esac
fi
[ -d "$IMAGE_DIR" ] || { echo "no such dir: $IMAGE_DIR" >&2; exit 1; }
[ -f "$IMAGE_DIR/parts" ] || { echo "$IMAGE_DIR is not a Clonezilla folder (no 'parts' file)" >&2; exit 1; }

# ------------------- discover basename -------------------
BASENAME="${BASENAME:-}"
if [ -z "$BASENAME" ]; then
    MBR_FILE=$(ls "$IMAGE_DIR"/*-mbr 2>/dev/null | head -1 || true)
    if [ -n "$MBR_FILE" ]; then
        BASENAME=$(basename "$MBR_FILE" | sed 's/-mbr$//')
    fi
fi
[ -n "$BASENAME" ] || BASENAME=$(ask "disk basename (e.g. sdb)" "sdb")
[ -f "$IMAGE_DIR/${BASENAME}-mbr" ] || {
    echo "no $IMAGE_DIR/${BASENAME}-mbr — wrong basename?" >&2
    exit 1
}

PARTS=$(cat "$IMAGE_DIR/parts")
echo "==> image:    $IMAGE_DIR"
echo "    basename: $BASENAME"
echo "    parts:    $PARTS"
echo

# ------------------- pick target -------------------
TARGET="${TARGET:-${2:-}}"
if [ -z "$TARGET" ]; then
    echo "==> external disks:"
    diskutil list external physical 2>/dev/null \
        | awk '/^\/dev\/disk/ {dev=$1} /^\/dev\/disk|GB|MB|TB/ {print "   " $0}' \
        | head -40
    echo
    echo "   options:"
    echo "     /dev/diskN     - real disk (DESTRUCTIVE)"
    echo "     /path/file.img - convert to a raw image file"
    TARGET=$(ask "target" "")
    [ -z "$TARGET" ] && { echo "no target, aborting." >&2; exit 1; }
fi

# ------------------- run -------------------
case "$TARGET" in
    /dev/disk0*|/dev/rdisk0*)
        echo "REFUSE: $TARGET is the internal boot disk." >&2
        exit 2
        ;;
esac

# Default flags: verify yes, grow only if user asks.
VERIFY="${VERIFY:-1}"
GROW="${GROW:-0}"
GROW_PART="${GROW_PART:-}"

is_real_disk=0
case "$TARGET" in /dev/disk*|/dev/rdisk*) is_real_disk=1 ;; esac

if [ "$is_real_disk" -eq 1 ]; then
    if [ -t 0 ] && [ -z "${SKIP_PROMPTS:-}" ]; then
        echo
        echo "==> $TARGET is a real disk — restoring is DESTRUCTIVE."
        diskutil list "$TARGET" || true
        if ! confirm "proceed" "n"; then echo "aborted." >&2; exit 3; fi
        if [ -z "${VERIFY_SET:-}" ] && confirm "run verify after restore" "y"; then
            VERIFY=1
        fi
        if [ "$GROW" -eq 0 ] && [ -z "${GROW_SET:-}" ] && \
           confirm "grow last partition to fill disk after restore" "n"; then
            GROW=1
            if [ -z "$GROW_PART" ]; then
                LAST=$(echo "$PARTS" | awk -v b="$BASENAME" '
                    { gsub(b, ""); for(i=1;i<=NF;i++) if($i+0>m) m=$i+0 } END {print m}')
                GROW_PART=$(ask "  partition number to grow" "$LAST")
            fi
        fi
    fi

    RESTORE_ARGS="--no-confirm"
    [ "$VERIFY" -eq 1 ]    && RESTORE_ARGS="$RESTORE_ARGS --verify"
    [ "$GROW" -eq 1 ] && [ -n "$GROW_PART" ] && \
        RESTORE_ARGS="$RESTORE_ARGS --grow $GROW_PART"

    # shellcheck disable=SC2086
    PARTCLONE="$PARTCLONE" PARTCLONE_DIR="$PARTCLONE_DIR" \
        "$RESTORE_SH" $RESTORE_ARGS "$IMAGE_DIR" "$BASENAME" "$TARGET"
else
    # File target — delegate to clonezilla-to-raw which auto-detaches.
    [ -x "$RAW_SH" ] || { echo "missing $RAW_SH" >&2; exit 1; }
    if [ "$VERIFY" -eq 1 ]; then
        PARTCLONE="$PARTCLONE" PARTCLONE_DIR="$PARTCLONE_DIR" \
            "$RAW_SH" "$IMAGE_DIR" "$BASENAME" "$TARGET" --verify
    else
        PARTCLONE="$PARTCLONE" PARTCLONE_DIR="$PARTCLONE_DIR" \
            "$RAW_SH" "$IMAGE_DIR" "$BASENAME" "$TARGET"
    fi
fi
