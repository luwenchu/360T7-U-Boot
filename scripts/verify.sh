#!/bin/sh
set -eu

SOURCE_DIR="${1:?source directory required}"
DIST_DIR="${2:?dist directory required}"
FIP="$DIST_DIR/mt7981_360t7-fip-fixed-parts.bin"
UBOOT_CFG="$SOURCE_DIR/uboot-mtk-20230718-09eda825/configs/mt7981_360t7_defconfig"
UBOOT_BIN="$SOURCE_DIR/uboot-mtk-20230718-09eda825/u-boot.bin"
UPSTREAM_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
EXPECTED_COMMIT="abe158087c80ed1896f2c281e2dae5e43ffbee41"
EXPECTED_MTDPARTS='nmbm0:1024k(bl2),512k(u-boot-env),2048k(factory),2048k(fip),108M(ubi),1M(stock-config),512k(stock-factory),4M(stock-log)'
FIP_LIMIT=2097152

fail()
{
	echo "ERROR: $*" >&2
	exit 1
}

test -f "$FIP" || fail "FIP output is missing"
test -f "$UBOOT_BIN" || fail "U-Boot binary is missing"
test "$UPSTREAM_COMMIT" = "$EXPECTED_COMMIT" || fail "unexpected upstream commit"
grep -qx 'CONFIG_DEFAULT_DEVICE_TREE="mt7981-360t7"' "$UBOOT_CFG" ||
	fail "wrong device tree"
grep -qx 'CONFIG_ENABLE_NAND_NMBM=y' "$UBOOT_CFG" ||
	fail "NMBM is not enabled"
grep -qx 'CONFIG_MTD_SPI_NAND=y' "$UBOOT_CFG" ||
	fail "SPI-NAND is not enabled"
grep -qx 'CONFIG_WEBUI_DHCP_SERVER=y' "$UBOOT_CFG" ||
	fail "failsafe DHCP server is not enabled"
grep -Fqx "CONFIG_MTDPARTS_DEFAULT=\"$EXPECTED_MTDPARTS\"" "$UBOOT_CFG" ||
	fail "fixed partition layout changed"
grep -Fq 'Qihoo 360T7 Recovery' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/index.html" ||
	fail "Web recovery overlay was not applied"
grep -Fq '首次通过 U-Boot Web 刷入本仓库固件可能需要约 10 分钟' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/index.html" ||
	fail "first firmware flash duration warning is missing"
if grep -Fq 'IPQ60xx 的 ART、CDT 或 NOR 分区操作' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/index.html"; then
	fail "obsolete IPQ60xx Web warning is still present"
fi
for page in index.html initramfs.html uboot.html; do
	grep -Fq '郑州子安信息科技 · 构建日期：2026-07-26' \
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
grep -Fq '构建日期：2026-07-26' \
	"$SOURCE_DIR/uboot-mtk-20230718-09eda825/failsafe/fsdata/uboot.html" ||
	fail "U-Boot update page has an unexpected build date"
strings "$UBOOT_BIN" | grep -Fq \
	'DHCP server: 192.168.1.100-192.168.1.199' ||
	fail "failsafe DHCP server was not linked into U-Boot"

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
	echo "nmbm=enabled"
	echo "fixed_mtdparts=enabled"
	echo "failsafe_dhcp_server=192.168.1.100-192.168.1.199"
	echo "fip_partition_limit=$FIP_LIMIT"
	echo "fip_size=$FIP_SIZE"
	echo "mtdparts=$EXPECTED_MTDPARTS"
	echo "web_overlay=Qihoo 360T7 Recovery"
	echo "web_uboot_update=enabled"
	echo "first_firmware_flash_warning=about_10_minutes"
	echo "web_footer=Zhengzhou_Zian_Information_Technology"
	echo "build_date=2026-07-26"
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
