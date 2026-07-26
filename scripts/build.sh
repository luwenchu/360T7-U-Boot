#!/bin/sh
set -eu

UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/hanwckf/bl-mt798x.git}"
UPSTREAM_COMMIT="${UPSTREAM_COMMIT:-abe158087c80ed1896f2c281e2dae5e43ffbee41}"
PROJECT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$PROJECT_DIR/work}"
SOURCE_DIR="$WORK_DIR/bl-mt798x"
DIST_DIR="${DIST_DIR:-$PROJECT_DIR/dist}"
UBOOT_DIR="uboot-mtk-20230718-09eda825"
ATF_DIR="atf-20240117-bacca82a8"

command -v git >/dev/null
command -v aarch64-linux-gnu-gcc >/dev/null
command -v python3 >/dev/null

rm -rf "$SOURCE_DIR" "$DIST_DIR"
mkdir -p "$WORK_DIR" "$DIST_DIR"

git init "$SOURCE_DIR"
git -C "$SOURCE_DIR" remote add origin "$UPSTREAM_REPO"
git -C "$SOURCE_DIR" sparse-checkout init --no-cone
git -C "$SOURCE_DIR" sparse-checkout set \
	/build.sh \
	"/$UBOOT_DIR/" \
	"/$ATF_DIR/"
git -C "$SOURCE_DIR" fetch --depth 1 origin "$UPSTREAM_COMMIT"
git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD

test "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$UPSTREAM_COMMIT"
test -f "$SOURCE_DIR/$ATF_DIR/configs/mt7981_360t7_defconfig"
test -f "$SOURCE_DIR/$UBOOT_DIR/configs/mt7981_360t7_defconfig"

for patch in "$PROJECT_DIR"/patches/*.patch; do
	git -C "$SOURCE_DIR" apply --check "$patch"
	git -C "$SOURCE_DIR" apply "$patch"
done

BUILD_DATE="2026-07-26"
SOURCE_DATE_EPOCH="1785024000"
export SOURCE_DATE_EPOCH
export BUILD_DATE
export KBUILD_BUILD_USER="360t7-builder"
export KBUILD_BUILD_HOST="github-actions"

cp -R "$PROJECT_DIR/overlay/." "$SOURCE_DIR/"

(
	cd "$SOURCE_DIR"
	SOC=mt7981 BOARD=360t7 FIXED_MTDPARTS=1 ./build.sh
)

cp "$SOURCE_DIR/output/mt7981_360t7-fip-fixed-parts.bin" "$DIST_DIR/"
sh "$PROJECT_DIR/scripts/verify.sh" "$SOURCE_DIR" "$DIST_DIR"
