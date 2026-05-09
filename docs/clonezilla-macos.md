# Clonezilla restore on macOS — findings + conversion recipes

This doc captures everything we learned getting Clonezilla "savedisk"
images to restore, verify, grow, and convert to raw on macOS. None of it
needs Clonezilla itself to be running — only the partclone binaries
built from this tree, plus stock macOS utilities (`dd`, `diskutil`,
`hdiutil`, `fsck_msdos`).

> **Audience:** anyone with a Clonezilla Live backup taken on a
> Linux/Clonezilla host who now wants to restore it from a Mac (because
> the original Linux host is gone, or just to avoid spinning up a
> Linux VM).
>
> **Scope:** MBR disks containing FAT12/16/32 partitions. GPT and
> ext/NTFS/etc. fall outside what this build of partclone supports on
> macOS today.

---

## Table of contents

- [What's actually inside a Clonezilla savedisk image](#whats-actually-inside-a-clonezilla-savedisk-image)
- [Why it doesn't restore on macOS without help](#why-it-doesnt-restore-on-macos-without-help)
- [Conversion paths](#conversion-paths)
  - [A. Single FAT partition → raw .img](#a-single-fat-partition--raw-img)
  - [B. Whole-disk Clonezilla image → raw .img file](#b-whole-disk-clonezilla-image--raw-img-file)
  - [C. Whole-disk Clonezilla image → physical USB stick](#c-whole-disk-clonezilla-image--physical-usb-stick)
  - [D. Raw .img file → physical USB stick](#d-raw-img-file--physical-usb-stick)
  - [E. Restored partition smaller than its slot → grow it](#e-restored-partition-smaller-than-its-slot--grow-it)
- [contrib/ helper scripts](#contrib-helper-scripts)
- [macOS-specific gotchas](#macos-specific-gotchas)
- [Post-restore verification](#post-restore-verification)
- [Recovery if a restore goes wrong](#recovery-if-a-restore-goes-wrong)

---

## What's actually inside a Clonezilla savedisk image

Clonezilla writes a **directory**, not a single file. A typical
`savedisk` image of a small USB stick (e.g. basename `sdb`) looks like:

```
Compaq_Armada/
├── blkdev.list                  # block devices Clonezilla saw on the source
├── blkid.list                   # blkid -o list output for each
├── clonezilla-img               # Clonezilla's own log
├── disk                         # one line: "sdb"  (the source disk basename)
├── parts                        # one line per partition: "sdb1 sdb2 ..."
├── sdb-chs.sf                   # sfdisk -l (CHS view)
├── sdb-hidden-data-after-mbr    # bytes 512..(first-partition-LBA*512)-1
├── sdb-mbr                      # exactly 512 bytes — the boot record
├── sdb-pt.parted                # parted -l human-readable layout
├── sdb-pt.parted.compact        # parted -l --machine
├── sdb-pt.sf                    # sfdisk -l (LBA view)
├── sdb1.vfat-ptcl-img.gz.aa     # gzip-compressed partclone image, chunk .aa
├── sdb1.vfat-ptcl-img.gz.ab     # chunk .ab
├── sdb1.vfat-ptcl-img.gz.ac     # ...
└── Info-OS-prober               # bookkeeping, not used for restore
```

Per-partition image filenames follow the pattern:

```
<basename><N>.<fstype>-ptcl-img[.<comp>].aa[bcd...]
```

- `<fstype>` — `vfat`, `fat32`, `ext4`, `ntfs`, etc. (from blkid).
- `<comp>` — usually `gz`, sometimes `xz` or `zst`. Absent if Clonezilla
  was run with `-z0` (no compression).
- `.aa`, `.ab`, … — split into ~2 GiB chunks for filesystems that
  pre-date large-file support.

**Key fact that's not in Clonezilla's docs:** the order matters. To
reconstruct the original partclone stream you must `cat` the chunks in
**filename order**, then pipe through the matching decompressor:

```sh
cat sdb1.vfat-ptcl-img.gz.* | gzip -dc | <partclone>
```

Every `contrib/macos-*.sh` helper does this — they're not magic, just
plumbing.

## Why it doesn't restore on macOS without help

Clonezilla's restore script (`ocs-sr`) is a Linux shell program that
shells out to `partclone.<fs>`, `sfdisk`, `parted`, `dd`, `cat`, etc. On
macOS:

| Linux tool            | macOS situation                              |
|-----------------------|----------------------------------------------|
| `partclone.fat32`     | Builds from this tree (Darwin port).         |
| `partclone.ntfs/ext*` | Disabled on Darwin — no upstream FS deps.    |
| `sfdisk`              | Not present. `gpt` and `fdisk` partial subs. |
| `parted`              | Not present. No Homebrew port either.        |
| `udevadm` / `kpartx`  | Linux-only.                                  |
| `losetup`             | Replaced by `hdiutil attach -nomount`.       |

So `ocs-sr` does not work as-is. The `contrib/` scripts in this repo
implement just enough of `ocs-sr restore-disk` to handle the common
case: an MBR disk with FAT partitions, possibly with a small post-MBR
gap and a hidden diagnostic slot.

## Conversion paths

The five recipes below cover everything we tested. Each starts from a
Clonezilla image dir and ends at one of: a raw `.img` file, a real
physical disk, or a single-partition raw image.

### A. Single FAT partition → raw .img

Cheapest case. Just decompress + restore one partition.

```sh
gzip -dc Compaq_Armada/sdb1.vfat-ptcl-img.gz.aa Compaq_Armada/sdb1.vfat-ptcl-img.gz.ab \
  | src/partclone.restore -s - -O sdb1.img -C -L /tmp/partclone.log

# sanity-check
hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage sdb1.img
fsck_msdos -n /dev/rdiskN
hdiutil detach /dev/diskN
```

If the image was compressed with `xz`, replace `gzip -dc` with `xz -dc`.
If `zstd`, use `zstd -dc`. If uncompressed (no `.gz` in the filename),
just `cat`.

This drops the partition table — you get only the contents of the FAT
partition, mountable directly. You won't be able to `dd` it to a USB
stick as-is; you'd have to format the USB with an MBR + FAT partition of
matching size first.

### B. Whole-disk Clonezilla image → raw .img file

This is the most generally useful conversion. Output is a sparse `.img`
with a real MBR; you can `dd` it, attach it with `hdiutil`, or boot it
in QEMU.

```sh
PARTCLONE=$(pwd)/src/partclone.restore \
  contrib/macos-clonezilla-to-raw.sh \
    ~/Downloads/Compaq_Armada \
    sdb \
    ~/Compaq_Armada.img \
    --verify
```

What the script does, step-by-step:

1. Estimates the source disk size from `sdb-pt.parted.compact`'s
   `Disk /dev/sdb: <N>MB` line. Adds 64 MiB headroom.
2. Creates a sparse `.img` of that size with `dd seek=` (macOS `dd`
   accepts `seek=N count=0` to extend a sparse hole).
3. Writes `sdb-mbr` to sector 0 with `dd if=... of=... bs=512 count=1
   conv=notrunc`.
4. Writes `sdb-hidden-data-after-mbr` starting at sector 1, also with
   `conv=notrunc`. This restores any post-MBR boot code or diagnostic
   data that lived between the MBR and the first partition.
5. Attaches the file as a virtual disk:
   `hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage`.
   The kernel reads the just-written MBR and synthesizes
   `/dev/diskNs1`, `/dev/diskNs2`, etc.
6. For each partition listed in `parts`, finds the matching
   `*-ptcl-img.gz.aa` chunk-set, concatenates the chunks, decompresses,
   pipes through `partclone.restore -s - -O /dev/rdiskNsM`.
7. Optionally runs `macos-verify-clonezilla-disk.sh` end-to-end.
8. Detaches the loopback. The `.img` file is now standalone.

The result:

```sh
$ ls -la ~/Compaq_Armada.img
-rw-r--r--  1 talor  staff  2147483648  May 9 14:40 /Users/talor/Compaq_Armada.img
$ du -h ~/Compaq_Armada.img
418M    /Users/talor/Compaq_Armada.img        # actual on-disk size: sparse
```

### C. Whole-disk Clonezilla image → physical USB stick

```sh
sudo PARTCLONE=$(pwd)/src/partclone.restore \
     contrib/macos-clonezilla.sh \
       ~/Downloads/Compaq_Armada \
       /dev/disk4
```

Or fully scripted with verify + grow:

```sh
sudo PARTCLONE=$(pwd)/src/partclone.restore \
     contrib/macos-restore-clonezilla-disk.sh \
       --no-confirm --verify --grow 1 \
       ~/Downloads/Compaq_Armada \
       sdb \
       /dev/disk4
```

What changes vs. recipe B: the script writes the MBR + gap directly to
`/dev/rdisk4` (not to a file), then `partclone.restore` writes each
partition into `/dev/rdiskNsM` (the kernel re-reads the partition
table once the MBR lands; if it doesn't, force a refresh with
`diskutil unmountDisk force /dev/disk4`).

**Boot-disk safety:** every `contrib/macos-*.sh` script refuses
`/dev/disk0` outright. There is no override.

### D. Raw .img file → physical USB stick

Just `dd`. The raw `.img` from recipe B is bootable / writable as-is:

```sh
diskutil unmountDisk /dev/disk4
sudo dd if=~/Compaq_Armada.img of=/dev/rdisk4 bs=4m status=progress
sync
diskutil eject /dev/disk4
# physically replug
```

### E. Restored partition smaller than its slot → grow it

Clonezilla preserves the original partition geometry. If you restored
a 3 GiB FAT32 image onto an 8 GiB USB stick, you'll have 5 GiB of free
space sitting unused after the restore.

Two tools, two scenarios:

#### Slot uses GPT, FS is APFS / HFS+ / FAT32-on-GPT

`contrib/macos-grow-partition.sh` calls `diskutil resizeVolume` and
hands the work off to macOS. Works in this combination. **Does not
work on FAT32 inside MBR** — `diskutil` returns "file system volume
format does not support resizing" because macOS ships no FAT32 grow
tool of its own. The script prints a clear error explaining this.

```sh
# GPT FAT32 / APFS / HFS+
contrib/macos-grow-partition.sh /dev/disk4 1
```

#### Slot uses MBR, FS is FAT32 — the common Clonezilla case

Use [**fatgrow**](https://github.com/pacnpal/fatgrow), a separate
native-macOS tool that resizes the MBR slot AND the FAT32 inside it,
without needing libparted or a Linux live USB:

```sh
# Backup first — non-negotiable.
sudo dd if=/dev/rdisk4 of=$HOME/disk4-backup.img bs=4m status=progress

# Combined MBR slot + FAT32 grow on a real disk
sudo /usr/local/bin/fatgrow --grow --size max --i-have-a-backup /dev/disk4
```

fatgrow was written specifically because `contrib/macos-grow-partition.sh`
hits a wall on the most common Clonezilla restore target (FAT32 inside
MBR on a USB stick) and macOS has no other native tool for this. It is
NOT part of this partclone tree — install it separately.

## contrib/ helper scripts

| Script | Purpose |
|---|---|
| `contrib/macos-clonezilla.sh` | Friendly entry point. Picks an image dir from `~/Downloads`, picks a target via `diskutil list`, runs restore + verify + optional grow. |
| `contrib/macos-restore-clonezilla-disk.sh` | Low-level restore: writes MBR + gap, restores each partition. Accepts `--verify`, `--grow N`, `--no-confirm`. Target can be `/dev/diskN` or a file path. |
| `contrib/macos-verify-clonezilla-disk.sh` | After-restore: `partclone.chkimg` on the source image, `fsck_*` on the restored slice, re-clones the slice through `partclone.chkimg`, compares filesystem / device size / used-cluster count. |
| `contrib/macos-grow-partition.sh` | Wraps `diskutil resizeVolume`. Works on GPT FAT32, HFS+, APFS. Refuses gracefully on MBR FAT32 and points at fatgrow. |
| `contrib/macos-clonezilla-to-raw.sh` | Recipe B. Converts a Clonezilla image set to a flat sparse `.img`. |

## macOS-specific gotchas

These bit us during development. Documented so you don't rediscover them.

1. **`newfs_msdos` cannot operate on a regular file.** It uses ioctls
   that require a block-or-character device. Use `hdiutil attach
   -nomount` to get a `/dev/diskN` for an image, then format that.

2. **macOS raw character devices (`/dev/rdiskN`) require sector-aligned
   I/O.** Reads or writes whose length is not a multiple of the device's
   block size return `EINVAL`. partclone's own buffer sizes are fine,
   but ad-hoc one-off reads need rounding up to a sector.

3. **`F_FULLFSYNC` returns `ENOTTY` on character devices.** `/dev/rdiskN`
   writes are already synchronous to the driver, so calling
   `fcntl(F_FULLFSYNC)` is both unsupported and unnecessary. Treat the
   ENOTTY as success.

4. **`O_EXLOCK` returns `EBUSY` (not `EAGAIN`) when `diskarbitrationd`
   is mid-arbitration.** This is normal after any I/O operation on a
   removable disk — a few seconds of "the kernel is figuring out what
   just changed." Either retry after a brief sleep, or fall back to
   plain `O_RDWR` once you've confirmed the disk isn't actually
   mounted (`getmntinfo` to enumerate mounted filesystems).

5. **Mounted FAT volumes carry a "currently-mounted" flag on disk.**
   `boot_flags & 0x01` at offset `0x041` in the FAT32 boot sector is
   set by macOS at mount, cleared at clean unmount. `fsck_msdos` of a
   *mounted* FAT will report it as dirty even though the FS is fine.
   Force-unmount with `diskutil unmountDisk force` before fsck.

6. **The kernel may not re-read the partition table on its own after
   you write a new MBR.** The most reliable refresh is detach +
   reattach (for `hdiutil`-attached images) or eject + replug (for real
   USB sticks). `diskutil unmountDisk force` plus a fresh `diskutil
   list` sometimes triggers a re-arbitration; sometimes it doesn't.
   Belt-and-suspenders: don't rely on slice-device paths
   (`/dev/diskNsM`) until `diskutil list` shows the right sizes.

7. **Some Clonezilla OEM-format images use type 0x0B (FAT32 CHS),
   not 0x0C (FAT32 LBA).** Both work, but `parted` and many Linux
   tools prefer the CHS variant. `partclone.restore` doesn't care.

8. **`partclone.<fs> -c` reads the FAT 4 bytes at a time and FAILS
   on `/dev/rdiskN` (raw character) — silently.** `EINVAL` from
   the kernel is returned, the cluster scanner aborts on the first
   read, and "Space in use" gets reported as just the FAT region
   size (~12k blocks for a 3 GB FAT32). The verify script worked
   around this by switching to `/dev/diskN` (the buffered block
   device) for clone-mode reads. fsck and partclone.restore handle
   raw fine because they use larger buffered I/O.

9. **`partclone.fat -c` and pipefail.** POSIX sh has no `pipefail`,
   so a `partclone.<fs> -c | partclone.chkimg -s -` pipeline where
   the cloner fails silently (see #8) will produce empty stdout
   that chkimg "successfully" parses as zero values. The verify
   script clones to a tempfile first, then chkimgs the tempfile,
   so any cloner failure surfaces immediately.

10. **macOS auto-mount writes metadata before you can fsck cleanly.**
    Between a successful `partclone.restore` and a follow-up verify
    pass, macOS arbitrates the disk and mounts visible FAT volumes,
    creating `.fseventsd/`, `.Spotlight-V100/`, etc. on first mount.
    These add roughly 4 clusters (≈ 16 KiB / 32 sectors) of legitimate
    new data. The verify script accepts up to 1% growth (with a
    64-block floor for small volumes) without flagging mismatch.
    Below the floor or any SHRINK is treated as real data loss.

## Post-restore verification

`contrib/macos-verify-clonezilla-disk.sh` does four passes:

1. **Source image integrity.** Concatenate the chunks, pipe through
   `partclone.chkimg`. Catches `gz` corruption, missing `.ab` chunks,
   wrong fs type tag.
2. **macOS fsck.** `fsck_msdos -n /dev/rdiskNsM` on FAT slices,
   `fsck_hfs -n` on HFS+ if any.
3. **Round-trip clone-and-check.** `partclone.fat32 -c -s
   /dev/rdiskNsM | partclone.chkimg -s -`. Reads back the restored
   slice, walks its FAT, confirms cluster chains are consistent.
4. **Size + used-cluster comparison.** Compares the source image's
   reported FS size and used-cluster count vs. the restored slice's.
   They should match exactly for FAT32.

Run with `--verify` on either of the orchestrator scripts, or directly:

```sh
PARTCLONE_DIR=$(pwd)/src \
  contrib/macos-verify-clonezilla-disk.sh \
    ~/Downloads/Compaq_Armada sdb /dev/disk4
```

## Recovery if a restore goes wrong

The honest answer: if a partclone restore was interrupted partway, the
target disk is in an inconsistent state. There's no "rollback" — the FAT
or directory entries are partially overwritten.

**Plan ahead:**

1. **Always image the target disk before restoring.** If you're about
   to write to `/dev/disk4`, take a `dd` image first:

   ```sh
   sudo dd if=/dev/rdisk4 of=$HOME/disk4-pre-restore.img bs=4m status=progress
   shasum -a 256 $HOME/disk4-pre-restore.img > $HOME/disk4-pre-restore.sha256
   ```

2. **Restore from the backup if anything goes sideways:**

   ```sh
   sudo dd if=$HOME/disk4-pre-restore.img of=/dev/rdisk4 bs=4m status=progress
   sync
   diskutil eject /dev/disk4
   ```

The fact that the restore *target* is what you're saving (not the source
Clonezilla image) is unintuitive — but partclone is destructive on the
target by design. The Clonezilla image itself is read-only during a
restore, so it never needs backing up.

---

*Found a Clonezilla image format / FS combination this doc doesn't
cover? File an issue with `partclone.fstype <input>` output and the
listing of the image directory.*
