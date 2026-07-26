# Qihoo 360T7 U-Boot Web Recovery

This repository builds a device-specific U-Boot FIP for the Qihoo 360T7.
It uses the MT7981, DDR3, SPI-NAND, NMBM and fixed-partition configuration
from `hanwckf/bl-mt798x`.

The Web recovery interface is restyled for the 360T7 while retaining the
upstream MediaTek upload, image validation and flashing handlers. No IPQ60xx
hardware code, NOR partition table, ART/CDT handler, or binary is used.
The interface provides dedicated pages for firmware update, initramfs RAM boot
and U-Boot FIP update. The U-Boot page only uses the upstream validated `fip`
upload path and writes the fixed-layout `fip` partition.
All three Web pages use the footer `郑州子安信息科技 · 构建日期：2026-07-26`
and do not display the upstream U-Boot version string.

While Web recovery is active, a minimal DHCPv4 server automatically assigns
temporary addresses from `192.168.1.100-192.168.1.199`. The recovery Web
address remains fixed at `192.168.1.1`, so it is still reachable with a manual
computer address if DHCP negotiation fails.

The first firmware installation through U-Boot Web can take about 10 minutes.
Do not power off or restart the router if the page temporarily stops updating;
wait for the write and initialization process to finish and for the device to
restart.

## Output

The GitHub Actions build produces:

- `mt7981_360t7-fip-fixed-parts.bin`
- `SHA256SUMS`
- `build-metadata.txt`
- `validation-report.txt`

The FIP is built for this exact fixed layout:

```text
nmbm0:1024k(bl2),512k(u-boot-env),2048k(factory),2048k(fip),
108M(ubi),1M(stock-config),512k(stock-factory),4M(stock-log)
```

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

`SOURCE_DATE_EPOCH` is fixed to `2026-07-26 00:00:00 UTC`; the visible Web
build date is also `2026-07-26`. `KBUILD_BUILD_USER` and `KBUILD_BUILD_HOST`
remain fixed so repeated builds of the same repository commit produce the same
FIP hash.

## Flashing warning

This is an untested bootloader build. A successful CI build and static
validation do not prove that it will boot on physical hardware.

Do not write BL2, Factory, the whole NAND, or this FIP without:

- a 3.3 V TTL serial console;
- a verified original BL2 and FIP backup;
- an MT7981 DDR3 RAM-boot recovery path using `mtk_uartboot`;
- confirmation that the installed layout is the same NMBM fixed layout.

Do not use this FIP with the official OpenWrt non-NMBM partition stack.
The first hardware test should be a RAM-assisted recovery test, not an
unattended NAND write.

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
