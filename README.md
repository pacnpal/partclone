Partclone is a project similar to the well-known backup utility "Partition Image" a.k.a partimage. Partclone provides utilities to back up and restore used-blocks of a partition and it is designed for higher compatibility of the file system by using existing library, e.g. e2fslibs is used to read and write the ext2 partition.

Partclone now supports ext2, ext3, ext4, hfs+, reiserfs, reiser4, btrfs, vmfs3, vmfs5, xfs, jfs, ufs, ntfs, fat(12/16/32), exfat...

We made some utilities:

* partclone.ext2, partclone.ext3, partclone.ext4
* partclone.extfs
* partclone.reiserfs
* partclone.reiser4
* partclone.xfs
* partclone.exfat
* partclone.fat (fat 12, fat 16, fat 32)
* partclone.ntfs
* partclone.hfsp
* partclone.apfs
* partclone.vmfs(v3 and v5)
* partclone.ufs
* partclone.jfs
* partclone.btrfs
* partclone.minix
* partclone.f2fs
* partclone.nilfs
* partclone.info 
* partclone.restore
* partclone.chkimg
* partclone.dd
...

Basic Usage:

 - clone partition to image

    `partclone.ext4 -d -c -s /dev/sda1 -o sda1.img`

 - restore image to partition

    `partclone.ext4 -d -r -s sda1.img -o /dev/sda1`

 - partiiton to partition clone

    `partclone.ext4 -d -b -s /dev/sda1 -o /dev/sdb1`

 - display image information

    `partclone.info -s sda1.img`

 - check image

    `partclone.chkimg -s sda1.img`

Limitations:

  - Filesystem being backedup must be unmounted and inaccessible to other programs.

For more info about partclone, check our website http://partclone.org or github-wiki.

## Building on macOS

This branch ports the minimum needed to build `partclone.restore` (and the rest
of the unconditional binaries — `info`, `dd`, `chkimg`, `imager`,
`ntfsfixboot`) plus `partclone.fat` on Apple Silicon (arm64). All other
filesystem backends remain disabled in this pass.

### Prerequisites (Homebrew)

    brew install autoconf automake libtool pkg-config gettext xxhash zstd \
                 openssl@3 util-linux e2fsprogs

`openssl@3` and `util-linux` are keg-only, so their `.pc` files must be exposed
to `pkg-config` via `PKG_CONFIG_PATH`. Either of `util-linux` or `e2fsprogs`
satisfies the `uuid` dependency.

### Build

    ./autogen
    export PKG_CONFIG_PATH="$(brew --prefix util-linux)/lib/pkgconfig:$(brew --prefix openssl@3)/lib/pkgconfig:${PKG_CONFIG_PATH}"
    ./configure \
        --disable-fuse --disable-ncursesw \
        --enable-fat --enable-xxhash \
        CFLAGS="-std=gnu99 -g -O2 -Wno-deprecated-declarations"
    make -j$(sysctl -n hw.ncpu)

Binaries land in `src/`. Manpage targets fail when offline (xsltproc tries to
fetch the DocBook XSL stylesheet over HTTP); make ignores those failures, so
the binaries still build and the final exit code is 0.

### Restoring a FAT image (example)

    gzip -dc sdb1.vfat-ptcl-img.gz.aa | \
        src/partclone.restore -s - -O /tmp/sdb1.img -C -L /tmp/partclone.log

    hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage /tmp/sdb1.img
    fsck_msdos -n /dev/rdiskN     # sanity-check the restored FAT
    hdiutil detach /dev/diskN

### Restoring a whole Clonezilla `savedisk` (helper scripts)

The single-partition recipe above is fine for one slice, but a Clonezilla
"savedisk" image set contains an MBR, a post-MBR gap and one partclone
image per partition. `contrib/` ships a small set of POSIX-`sh` helpers
that orchestrate the whole sequence on macOS. They only call standard
macOS tools (`dd`, `diskutil`, `hdiutil`, `fsck_*`) plus the partclone
binaries built above.

| Script | Purpose |
| --- | --- |
| `macos-clonezilla.sh` | Friendly entry point. Picks an image dir from `~/Downloads`, picks a target disk via `diskutil list`, then runs restore + verify (+ optional grow). |
| `macos-restore-clonezilla-disk.sh` | Low-level: writes MBR/gap and restores each partition to a `/dev/diskN` or sparse `.img` file. Accepts `--verify`, `--grow N`, `--no-confirm`. |
| `macos-verify-clonezilla-disk.sh` | After-restore check: `partclone.chkimg` on the source image, `fsck_*` on the restored slice, re-clones the slice through `partclone.chkimg`, and compares filesystem / device size / used space to the source. |
| `macos-grow-partition.sh` | Grows a partition slot + filesystem to fill trailing free space (FAT32, HFS+ — anything `diskutil resizeVolume` understands). |
| `macos-clonezilla-to-raw.sh` | Converts a Clonezilla image set into a flat raw `.img` file (sparse). The result is usable with `dd`, `hdiutil attach`, or as a VM disk. |

Typical usage — restore to an external disk, grow the FAT32 partition to
fill the disk, then verify:

    sudo PARTCLONE=$(pwd)/src/partclone.restore \
         contrib/macos-clonezilla.sh \
            ~/Downloads/Compaq_Armada \
            /dev/disk4

…or fully scripted:

    sudo VERIFY=1 GROW=1 GROW_PART=1 \
         PARTCLONE=$(pwd)/src/partclone.restore \
         contrib/macos-restore-clonezilla-disk.sh \
            --no-confirm --verify --grow 1 \
            ~/Downloads/Compaq_Armada sdb /dev/disk4

Convert the same image set into a raw `.img` file you can `dd` or boot
in a VM:

    PARTCLONE=$(pwd)/src/partclone.restore \
        contrib/macos-clonezilla-to-raw.sh \
            ~/Downloads/Compaq_Armada sdb \
            ~/Compaq_Armada.img --verify

For the full set of conversion recipes (single-partition,
whole-disk-to-image, whole-disk-to-USB, post-restore grow, recovery
procedure), the tested macOS gotchas, and a breakdown of what's actually
inside a Clonezilla `savedisk` directory, see
[`docs/clonezilla-macos.md`](docs/clonezilla-macos.md).

### Growing a restored partition to fill the target disk

Clonezilla preserves the original partition geometry, so a 3 GiB FAT32
restored onto an 8 GiB USB stick leaves 5 GiB unused. Two paths:

- **GPT FAT32, HFS+, APFS:** `contrib/macos-grow-partition.sh` calls
  `diskutil resizeVolume` and works.
- **MBR FAT32 (the common Clonezilla USB case):** `diskutil` refuses
  ("file system volume format does not support resizing") because macOS
  ships no FAT32 grow tool. Use [**fatgrow**][fatgrow] — a separate
  native-macOS tool written specifically for this case. It resizes the
  MBR slot AND the FAT32 inside in one shot, no libparted, no Linux VM:

      sudo /usr/local/bin/fatgrow --grow --size max --i-have-a-backup /dev/disk4

[fatgrow]: https://github.com/pacnpal/fatgrow

### Known limitations on macOS

- Only FAT12/16/32 is supported. `extfs`, `ntfs`, `hfs+`, `apfs`, `btrfs`,
  `xfs`, `jfs`, `ufs`, `vmfs`, `f2fs`, `nilfs2`, `reiserfs`, `reiser4`,
  `exfat`, and `minix` stay disabled.
- `partclone.ntfsfixboot` builds as a no-op stub (uses Linux-only
  `HDIO_GETGEO` from `<linux/hdreg.h>`).
- `--read-direct-io` / `--write-direct-io` are silent no-ops; macOS uses
  `fcntl(fd, F_NOCACHE, 1)` which is not yet wired in.
- `check_mount()` does not consult an mtab on Darwin and always returns
  "not mounted". When restoring to a real device, confirm the target with
  `diskutil list` and unmount it yourself first.
- FUSE (`partclone.imgfuse`) and the ncursesw progress UI are unsupported.
