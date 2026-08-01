#!/bin/sh
set -eu

SOURCE_DIR="${1:?source directory required}"
DIST_DIR="${2:?dist directory required}"
FIP="$DIST_DIR/mt7981_360t7-fip-fixed-parts.bin"
UBOOT_CFG="$SOURCE_DIR/uboot-mtk-20230718-09eda825/configs/mt7981_360t7_defconfig"
UBOOT_FINAL_CFG="$SOURCE_DIR/uboot-mtk-20230718-09eda825/.config"
UBOOT_BIN="$SOURCE_DIR/uboot-mtk-20230718-09eda825/u-boot.bin"
MTD_HELPER="$SOURCE_DIR/uboot-mtk-20230718-09eda825/board/mediatek/common/mtd_helper.c"
MT7981_BOARD="$SOURCE_DIR/uboot-mtk-20230718-09eda825/board/mediatek/mt7981/mt7981_rfb.c"
BOARD_DTS="$SOURCE_DIR/uboot-mtk-20230718-09eda825/arch/arm/dts/mt7981-360t7.dts"
UPSTREAM_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
EXPECTED_COMMIT="abe158087c80ed1896f2c281e2dae5e43ffbee41"
EXPECTED_MTDIDS='spi-nand0=spi-nand0'
EXPECTED_MTDPARTS='spi-nand0:1024k(bl2),512k(u-boot-env),2048k(factory),2048k(fip),108M(ubi),1M(stock-config),512k(stock-factory),4M(stock-log)'
FIP_LIMIT=2097152

fail()
{
	echo "ERROR: $*" >&2
	exit 1
}

test -f "$FIP" || fail "FIP output is missing"
test -f "$UBOOT_BIN" || fail "U-Boot binary is missing"
test -f "$UBOOT_FINAL_CFG" || fail "Final U-Boot configuration is missing"
test "$UPSTREAM_COMMIT" = "$EXPECTED_COMMIT" || fail "unexpected upstream commit"
grep -qx 'CONFIG_DEFAULT_DEVICE_TREE="mt7981-360t7"' "$UBOOT_CFG" ||
	fail "wrong device tree"
if grep -qx 'CONFIG_ENABLE_NAND_NMBM=y' "$UBOOT_CFG"; then
	fail "NMBM must be disabled to match the ImmortalWrt raw SPI-NAND layout"
fi
if grep -qx 'CONFIG_CMD_NMBM=y' "$UBOOT_CFG"; then
	fail "the NMBM command must be disabled"
fi
if grep -qx 'CONFIG_ENABLE_NAND_NMBM=y' "$UBOOT_FINAL_CFG"; then
	fail "the final U-Boot build unexpectedly enabled NMBM"
fi
if grep -qx 'CONFIG_CMD_NMBM=y' "$UBOOT_FINAL_CFG"; then
	fail "the final U-Boot build unexpectedly enabled the NMBM command"
fi
grep -qx 'CONFIG_MTD_SPI_NAND=y' "$UBOOT_CFG" ||
	fail "SPI-NAND is not enabled"
grep -qx 'CONFIG_WEBUI_DHCP_SERVER=y' "$UBOOT_CFG" ||
	fail "failsafe DHCP server is not enabled"
grep -qx 'CONFIG_OF_SYSTEM_SETUP=y' "$UBOOT_CFG" ||
	fail "360T7 Linux device-tree fixups are not enabled"
grep -qx 'CONFIG_OF_SYSTEM_SETUP=y' "$UBOOT_FINAL_CFG" ||
	fail "final U-Boot build does not enable Linux device-tree fixups"
grep -Fqx "CONFIG_MTDPARTS_DEFAULT=\"$EXPECTED_MTDPARTS\"" "$UBOOT_CFG" ||
	fail "fixed partition layout changed"
grep -Fqx "CONFIG_MTDIDS_DEFAULT=\"$EXPECTED_MTDIDS\"" "$UBOOT_CFG" ||
	fail "raw SPI-NAND MTD identifier changed"
grep -Fqx "CONFIG_MTDIDS_DEFAULT=\"$EXPECTED_MTDIDS\"" "$UBOOT_FINAL_CFG" ||
	fail "final U-Boot build does not use the raw SPI-NAND MTD identifier"
grep -Fqx "CONFIG_MTDPARTS_DEFAULT=\"$EXPECTED_MTDPARTS\"" "$UBOOT_FINAL_CFG" ||
	fail "final U-Boot build does not preserve the fixed raw partition layout"
grep -qx 'CONFIG_MTK_FIXED_MTD_MTDPARTS=y' "$UBOOT_FINAL_CFG" ||
	fail "final U-Boot build does not enforce fixed MTD partitions"
grep -Fq 'ubi_set_separate_rootfs_bootargs' "$MTD_HELPER" ||
	fail "separate kernel/rootfs boot argument support is missing"
grep -Fq '{ "ubi.block", "0," PART_ROOTFS_NAME }' "$MTD_HELPER" ||
	fail "separate SquashFS root does not request an ubiblock device"
grep -Fq '"/dev/ubiblock%u_%u"' "$MTD_HELPER" ||
	fail "separate SquashFS root does not use the actual UBI volume ID"
grep -Fq 'cmdline_merge(bootargs, rootargs' "$MTD_HELPER" ||
	fail "separate root arguments do not replace stale boot arguments"
grep -Fq 'read_ubi_volume(PART_FIT_NAME' "$MTD_HELPER" ||
	fail "the FIT volume is not the primary boot target"
grep -Fq 'remove_ubi_volume(PART_KERNEL_NAME)' "$MTD_HELPER" ||
	fail "FIT Web upgrades do not remove the legacy kernel volume"
grep -Fq 'remove_ubi_volume(PART_ROOTFS_NAME)' "$MTD_HELPER" ||
	fail "FIT Web upgrades do not remove the legacy rootfs volume"
grep -Fq 'split_layout = ubi_find_volume(PART_KERNEL_NAME)' "$MTD_HELPER" ||
	fail "FIT Web upgrades do not detect the separate-volume layout"
grep -Fq 'user_volumes = ubi ? ubi->vol_count - UBI_INT_VOL_COUNT : -1' \
	"$MTD_HELPER" ||
	fail "FIT Web upgrades do not distinguish an empty attached UBI"
grep -Fq 'user_volumes > 0' "$MTD_HELPER" ||
	fail "unknown non-empty UBI layouts are no longer rebuilt"
grep -Fq 'Empty UBI detected; keeping current attachment' "$MTD_HELPER" ||
	fail "empty UBI attachments are still rebuilt"
grep -Fq 'required_pebs = DIV_ROUND_UP_ULL(size, ubi->leb_size)' \
	"$MTD_HELPER" ||
	fail "FIT volume capacity is not checked against the attached UBI geometry"
grep -Fq 'required_pebs > ubi->avail_pebs' "$MTD_HELPER" ||
	fail "FIT volume capacity does not use the available PEB count"
grep -Fq 'UBI_UPDATE_CREATE' "$MTD_HELPER" ||
	fail "FIT volume creation failures are not stage-specific"
grep -Fq 'UBI_UPDATE_WRITE' "$MTD_HELPER" ||
	fail "FIT volume write failures are not stage-specific"
grep -Fq 'ret > 0' "$MTD_HELPER" ||
	fail "UBI write errno signs are not normalized"
grep -Fq 'ret == -ENOSPC && stage == UBI_UPDATE_CREATE' "$MTD_HELPER" ||
	fail "FIT create ENOSPC does not use the distinct EFBIG result"
grep -Fq 'ret == -ENOSPC && stage == UBI_UPDATE_WRITE' "$MTD_HELPER" ||
	fail "FIT write ENOSPC is not distinguished from create ENOSPC"
grep -Fq 'BOARD=qihoo_360t7' "$MTD_HELPER" ||
	fail "standard sysupgrade images are not restricted to the 360T7"
grep -Fq 'Sysupgrade kernel is not a FIT image' "$MTD_HELPER" ||
	fail "standard sysupgrade kernel validation is missing"
grep -Fq 'Sysupgrade root is not SquashFS' "$MTD_HELPER" ||
	fail "standard sysupgrade rootfs validation is missing"
grep -Fq 'remove_ubi_volume(PART_FIT_NAME)' "$MTD_HELPER" ||
	fail "standard sysupgrade does not remove the old combined FIT volume"
grep -Fq 'Firmware write failed, err = %d' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/board/mediatek/common/bootmenu_mtd.c" ||
	fail "firmware write errors are still collapsed to ENOTSUPP"
grep -Fq 'label = "ubi";' "$BOARD_DTS" ||
	fail "the board device tree does not define the raw UBI partition"
grep -Fq 'reg = <0x0580000 0x6c00000>;' "$BOARD_DTS" ||
	fail "the board device tree raw UBI partition boundary changed"
grep -Fq '"qihoo,360t7"' "$MT7981_BOARD" ||
	fail "360T7 Linux device-tree fixup is not board restricted"
for prop in \
	'mediatek,nmbm' \
	'mediatek,bmt-max-ratio' \
	'mediatek,bmt-max-reserved-blocks'
do
	grep -Fq "\"$prop\"" "$MT7981_BOARD" ||
		fail "360T7 Linux device-tree fixup is missing $prop"
done
grep -Fq '360T7: forced Linux device tree to raw SPI-NAND' "$MT7981_BOARD" ||
	fail "360T7 raw SPI-NAND Linux device-tree fixup is missing"
grep -Fq "Raw FIT upgrade requires the '%s' MTD partition" "$MTD_HELPER" ||
	fail "missing explicit diagnostic for an unavailable raw UBI partition"
grep -Fq 'Qihoo 360T7 Recovery' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/index.html" ||
	fail "Web recovery overlay was not applied"
grep -Fq 'FIT + SYSUPGRADE' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/index.html" ||
	fail "Web recovery does not advertise both supported firmware formats"
for page in index.html initramfs.html uboot.html; do
	grep -Fq 'U-Boot v1.0.12' \
		"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/$page" ||
		fail "visible U-Boot v1.0.12 marker is missing from $page"
done
grep -Fq '支持 combined FIT BIN 和标准 qihoo_360t7 sysupgrade BIN' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/index.html" ||
	fail "Web recovery firmware format guidance is missing"
grep -Fq '郑州子安信息科技 · 构建日期：2026-08-01' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/index.html" ||
	fail "company footer is missing from index.html"
if grep -Fq 'IPQ60xx 的 ART、CDT 或 NOR 分区操作' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/index.html"; then
	fail "obsolete IPQ60xx Web warning is still present"
fi
if grep -Fq '首次通过 U-Boot Web 刷入本仓库固件可能需要约 10 分钟' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/index.html"; then
	fail "obsolete first firmware flash duration warning is still present"
fi
for page in initramfs.html uboot.html; do
	grep -Fq '郑州子安信息科技 · 构建日期：2026-08-01' \
		"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/$page" ||
		fail "company footer is missing from $page"
	if grep -Fq 'id="version"' \
		"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/$page"; then
		fail "U-Boot version footer is still enabled in $page"
	fi
done
grep -Fq "upload('fip')" \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/uboot.html" ||
	fail "U-Boot update page does not use the upstream FIP upload handler"
grep -Fq '构建日期：2026-08-01' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/uboot.html" ||
	fail "U-Boot update page has an unexpected build date"
strings "$UBOOT_BIN" | grep -Fq \
	'DHCP server: 192.168.1.100-192.168.1.199' ||
	fail "failsafe DHCP server was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq \
	'Factory MAC: using %pM for Web recovery' ||
	fail "Factory MAC initialization was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq "$EXPECTED_MTDPARTS" ||
	fail "fixed MTD partition layout was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq '0,rootfs' ||
	fail "separate rootfs ubiblock arguments were not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq '/dev/ubiblock%u_%u' ||
	fail "dynamic rootfs ubiblock path was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq 'Using SquashFS root volume %s as %s' ||
	fail "separate SquashFS root diagnostic was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq 'BOARD=qihoo_360t7' ||
	fail "360T7 sysupgrade board validation was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq 'Sysupgrade root is not SquashFS' ||
	fail "sysupgrade rootfs validation was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq 'fail:no-supported-file-field' ||
	fail "detailed Web upload errors were not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq 'failed:write:%d' ||
	fail "detailed Web write errors were not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq \
	'360T7: forced Linux device tree to raw SPI-NAND' ||
	fail "360T7 raw SPI-NAND Linux device-tree fixup was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq 'mediatek,bmt-max-reserved-blocks' ||
	fail "NMBM property removal was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq 'U-Boot v1.0.12' ||
	fail "visible U-Boot v1.0.12 marker was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq \
	'Empty UBI detected; keeping current attachment' ||
	fail "empty UBI preservation diagnostic was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq \
	'FIT size %zu requires %llu LEBs; %d are available' ||
	fail "FIT capacity diagnostic was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq \
	'FIT volume stage %d failed, err = %d' ||
	fail "FIT update-stage diagnostic was not linked into U-Boot"
grep -Fq 'mtd_get_last_upgrade_diagnostic' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/board/mediatek/common/mtd_helper.c" ||
	fail "FIT/UBI Web diagnostic getter is missing"
grep -Fq '"failed:write:%d;%s"' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/failsafe.c" ||
	fail "Web result does not append the FIT/UBI diagnostic"
for field in \
	'stage=%s' \
	'size=%zu' \
	'required=%llu' \
	'avail=%d' \
	'leb=%d' \
	'good=%d' \
	'bad=%d' \
	'beb_rsvd=%d' \
	'rsvd=%d' \
	'vols=%d' \
	'ro=%d' \
	'raw=%d'
do
	grep -Fq "$field" "$MTD_HELPER" ||
		fail "FIT/UBI Web diagnostic is missing $field"
done
strings "$UBOOT_BIN" | grep -Fq \
	'stage=%s;addr=%lx;size=%zu;mtd=%s;mtd_size=%llu;' ||
	fail "FIT/UBI geometry diagnostic was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq 'failed:write:%d;%s' ||
	fail "extended Web write result was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq 'fit-create' ||
	fail "FIT create-stage Web diagnostic was not linked into U-Boot"
strings "$UBOOT_BIN" | grep -Fq 'fit-write' ||
	fail "FIT write-stage Web diagnostic was not linked into U-Boot"

FIP_SIZE="$(wc -c < "$FIP" | tr -d ' ')"
test "$FIP_SIZE" -gt 262144 || fail "FIP is unexpectedly small"
test "$FIP_SIZE" -le "$FIP_LIMIT" || fail "FIP exceeds the 2 MiB partition"

(
	cd "$DIST_DIR"
	sha256sum mt7981_360t7-fip-fixed-parts.bin > SHA256SUMS
)

{
	echo "Qihoo 360T7 FIP static validation"
	echo "result=PASS"
	echo "target=mt7981"
	echo "board=360t7"
	echo "dram=DDR3 (board-specific upstream configuration)"
	echo "storage=SPI-NAND"
	echo "nmbm=disabled"
	echo "flash_address_space=raw_spi_nand"
	echo "fixed_mtdparts=enabled"
	echo "failsafe_dhcp_server=192.168.1.100-192.168.1.199"
	echo "failsafe_mac_source=stock-factory lanMac"
	echo "fip_partition_limit=$FIP_LIMIT"
	echo "fip_size=$FIP_SIZE"
	echo "mtdparts=$EXPECTED_MTDPARTS"
	echo "web_overlay=Qihoo 360T7 Recovery"
	echo "web_uboot_update=enabled"
	echo "web_firmware_formats=combined_fit,qihoo_360t7_sysupgrade_tar"
	echo "web_version=v1.0.12"
	echo "web_footer=Zhengzhou_Zian_Information_Technology"
	echo "linux_dtb_fixup=qihoo_360t7_force_raw_spinand"
	echo "separate_rootfs=dynamic_ubiblock_volume_id"
	echo "build_date=2026-08-01"
} > "$DIST_DIR/validation-report.txt"

{
	echo "upstream_repository=https://github.com/hanwckf/bl-mt798x.git"
	echo "upstream_commit=$UPSTREAM_COMMIT"
	echo "uboot_tree=uboot-mtk-20230718-09eda825"
	echo "atf_tree=atf-20240117-bacca82a8"
	echo "build_command=SOC=mt7981 BOARD=360t7 FIXED_MTDPARTS=1 ./build.sh"
	echo "build_date=${BUILD_DATE:-unknown}"
	echo "source_date_epoch=${SOURCE_DATE_EPOCH:-unknown}"
	echo "kbuild_build_user=${KBUILD_BUILD_USER:-unknown}"
	echo "kbuild_build_host=${KBUILD_BUILD_HOST:-unknown}"
	echo "baseline_size=754833"
	echo "baseline_sha256=b547c6f157f65c2011ce42f5ef01f096896d420097ed37945d505d97588ee11f"
} > "$DIST_DIR/build-metadata.txt"

FIPTOOL="$(find "$SOURCE_DIR" -type f -name fiptool -perm -u+x | head -n 1 || true)"
if test -n "$FIPTOOL"; then
	"$FIPTOOL" info "$FIP" > "$DIST_DIR/fiptool-info.txt"
fi

cat "$DIST_DIR/validation-report.txt"
cat "$DIST_DIR/SHA256SUMS"
