# Qihoo 360T7 U-Boot Web Recovery

This repository builds a device-specific U-Boot FIP for the Qihoo 360T7.
It uses the MT7981, DDR3, raw SPI-NAND and fixed-partition configuration
from `hanwckf/bl-mt798x`. NMBM is deliberately disabled so U-Boot and the
ImmortalWrt `qihoo_360t7` kernel access the same NAND address space.

The Web recovery interface is restyled for the 360T7 while retaining the
upstream MediaTek upload, image validation and flashing handlers. No IPQ60xx
hardware code, NOR partition table, ART/CDT handler, or binary is used.
The interface provides dedicated pages for firmware update, initramfs RAM boot
and U-Boot FIP update. The U-Boot page only uses the upstream validated `fip`
upload path and writes the fixed-layout `fip` partition.
All three Web pages display the release marker `U-Boot v1.0.13` and use the
footer `郑州子安信息科技 · 构建日期：2026-08-01`. The release marker is static
and intentionally separate from the upstream U-Boot version string so the
installed recovery build can be identified without a serial console.

While Web recovery is active, a minimal DHCPv4 server automatically assigns
temporary addresses from `192.168.1.100-192.168.1.199`. The recovery Web
address remains fixed at `192.168.1.1`, so it is still reachable with a manual
computer address if DHCP negotiation fails.

Before the recovery network starts, U-Boot reads `lanMac` from the
device-specific `stock-factory` partition and uses it as `ethaddr`. This avoids
the repeatable pseudo-random fallback MAC appearing on multiple routers. The
value is used in memory and is not copied into another device's Factory data.

## Output

The GitHub Actions build produces:

- `mt7981_360t7-fip-fixed-parts.bin`
- `SHA256SUMS`
- `build-metadata.txt`
- `validation-report.txt`

The FIP is built for this exact fixed layout:

```text
spi-nand0:1024k(bl2),512k(u-boot-env),2048k(factory),2048k(fip),
108M(ubi),1M(stock-config),512k(stock-factory),4M(stock-log)
```

The same boundaries are embedded as fixed partitions in the 360T7 U-Boot
device tree. This keeps the `ubi` MTD partition available even if runtime
`mtdparts` environment parsing is unavailable or contains stale data.

Firmware update supports two content-validated formats:

- a combined FIT image, including a byte-identical `.bin` copy;
- a standard `qihoo_360t7` squashfs sysupgrade tar `.bin` containing a FIT
  `kernel`, SquashFS `root`, and `CONTROL` with `BOARD=qihoo_360t7`.

The layouts are mutually exclusive. A combined FIT update removes `kernel` and
`rootfs` before writing the single `fit` volume. A standard sysupgrade update
validates the complete archive before removing `fit` and writing separate
`kernel` and `rootfs` volumes. Both paths recreate `rootfs_data`.

When a combined FIT is selected after a separate `kernel`/`rootfs` image, the
UBI partition is rebuilt before the FIT volume is allocated. Unknown non-empty
layouts are also rebuilt, but an already empty and successfully attached UBI
device is kept in place instead of being erased and reattached a second time.
Before creating `fit`, U-Boot reports the required and available LEB counts and
rejects an image only when that attached UBI geometry cannot hold it.

When replacing an existing combined FIT, U-Boot removes the old `fit` volume
before performing the capacity check. The previous order checked only the
space remaining beside the old FIT reservation, which incorrectly rejected a
same-size replacement even though deleting the old volume released enough
PEBs.

FIT creation and data-writing failures are tracked separately, and positive
and negative UBI errno conventions are normalized before returning to the Web
handler. A FIT capacity or creation ENOSPC is reported as `failed:write:-27`;
a FIT data-write ENOSPC is reported as `failed:write:-5`; a later
`rootfs_data` allocation ENOSPC remains `failed:write:-28`.

For firmware write failures, the Web result also reports the last FIT/UBI
stage and the exact geometry seen by U-Boot, including image size, required
LEBs, available PEBs, LEB size, good and bad PEB counts, bad-block reserve,
total reserved PEBs, user volume count, read-only state and the original
unmapped errno. This diagnostic is read-only and does not relax UBI capacity
or bad-block safety checks.

The boot path prefers `fit` when present and otherwise boots the separate
`kernel`/`rootfs` layout by exposing the SquashFS root volume through
`ubiblock`. U-Boot reads the actual `rootfs` UBI volume ID and generates:

```text
ubi.mtd=ubi ubi.block=0,rootfs
root=/dev/ubiblock0_<rootfs-volume-id> rootfstype=squashfs rootwait
```

The boot argument merger replaces stale `ubi.mtd`, `ubi.block`, `root`,
`rootfstype`, and `rootwait` entries instead of appending a second conflicting
root device.

Some third-party 360T7 images, including the tested sagehou build, enable NMBM
in their Linux device tree even though this U-Boot stores UBI in raw
SPI-NAND. Before starting a `qihoo,360t7` Linux image, U-Boot removes the
`mediatek,nmbm`, `mediatek,bmt-max-ratio`, and
`mediatek,bmt-max-reserved-blocks` properties from the final runtime device
tree. The uploaded FIT or sysupgrade archive is not modified, and images whose
device tree already uses raw SPI-NAND are unchanged.

## Build

On Ubuntu or Debian:

```sh
sudo apt-get update
sudo apt-get install -y \
  build-essential gcc-aarch64-linux-gnu git python3 device-tree-compiler \
  libssl-dev bc bison flex swig python3-pyelftools
./scripts/build.sh
```

The upstream source is pinned in `scripts/build.sh`. The script performs a
sparse checkout, applies the local Web overlay and builds only:

```sh
SOC=mt7981 BOARD=360t7 FIXED_MTDPARTS=1 ./build.sh
```

`SOURCE_DATE_EPOCH` is fixed to `2026-08-01 00:00:00 UTC`; the visible Web
build date is also `2026-08-01`. `KBUILD_BUILD_USER` and `KBUILD_BUILD_HOST`
remain fixed so repeated builds of the same repository commit produce the same
FIP hash.

## Flashing warning

This raw SPI-NAND layout must be hardware-tested before it replaces an older
NMBM release. A successful CI build and static validation do not by themselves
prove that it will boot on every flash variant.

Do not write BL2, Factory, the whole NAND, or this FIP without:

- a 3.3 V TTL serial console;
- a verified original BL2 and FIP backup;
- an MT7981 DDR3 RAM-boot recovery path using `mtk_uartboot`;
- confirmation that Linux exposes the same raw fixed layout shown above.

This FIP is specifically intended to keep the bootloader and Linux on the
raw SPI-NAND address space. The runtime device-tree fixup adds compatibility
for 360T7 images that were built with NMBM properties, but it still requires
hardware validation. The first hardware test should retain a working initramfs
RAM recovery path.

## Baseline

The user-provided known FIP is recorded only as a comparison reference and is
not redistributed:

```text
File: mt7981_360t7-fip-fixed-parts.bin
Size: 754833 bytes
SHA-256: b547c6f157f65c2011ce42f5ef01f096896d420097ed37945d505d97588ee11f
```

## Licensing

The build wrapper and original Web assets in this repository are licensed
under GPL-2.0-only. The downloaded upstream source retains its own copyright
notices and license files.
