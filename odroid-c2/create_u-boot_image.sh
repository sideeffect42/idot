#!/usr/bin/env bash

set -e

SELF="$(realpath "${BASH_SOURCE[0]}")"
DIR="$(dirname "$SELF")"

MAINLINE_UBOOT="${DIR:?}/u-boot-amlogic/u-boot.bin"
UBOOT_IMG_OUT="${DIR:?}/u-boot.img"

HARDKERNEL_UBOOT_DIR="${DIR:?}/hardkernel/u-boot"

ARCH='arm'
[ 'x' == "x${CROSS_COMPILE}" ] && CROSS_COMPILE='aarch64-linux-gnu-'
export ARCH CROSS_COMPILE


echo '==> Checking prerequisites...'

if ! [ -d "$HARDKERNEL_UBOOT_DIR" ]
then
	echo "Could not find hardkernel/u-boot repo in ${HARDKERNEL_UBOOT_DIR}." >&2
	echo 'Make sure that it is checked out.' >&2
	exit 1
fi

if ! [ -f "$MAINLINE_UBOOT" ]
then
	echo "Make sure the mainline u-boot is present at ${MAINLINE_UBOOT}" >&2
	exit 1
fi

if ! which "${CROSS_COMPILE}gcc" &> '/dev/null'
then
	echo 'Make sure you have a cross compiler installed and that CROSS_COMPILE is set to the correct prefix' >&2
	exit 1
fi


echo '==> Building Hardkernel u-boot...'

# build fip.bin
make -C "${HARDKERNEL_UBOOT_DIR}" odroidc2_defconfig
make -C "${HARDKERNEL_UBOOT_DIR}"


echo "==> Checking if we're running on amd64..."
# check if running on amd64, because of Hardkernel fuckery and proprietary shit
# binaries.
if [ "x86_64" != "$(uname -m)" ]
then
	echo 'To create the FIP file and encrypt the u-boot image, you need to run this script on an amd64 machine.' >&2
	exit 1
fi


# Update FIP
echo '==> Updating FIP image with mainline u-boot...'
FIP_BIN="${HARDKERNEL_UBOOT_DIR:?}/fip/gxb/fip.bin"

"${HARDKERNEL_UBOOT_DIR:?}/fip/fip_create" \
	--bl30 "${HARDKERNEL_UBOOT_DIR:?}/fip/gxb/bl30.bin" \
	--bl31 "${HARDKERNEL_UBOOT_DIR:?}/fip/gxb/bl301.bin" \
	--bl31 "${HARDKERNEL_UBOOT_DIR:?}/fip/gxb/bl31.bin" \
	--bl33 "$MAINLINE_UBOOT" \
	"$FIP_BIN"

# fip dump
"${HARDKERNEL_UBOOT_DIR:?}/fip/fip_create" \
	--dump "$FIP_BIN"


# prepend bl2 to fip
echo '==> Generating boot_new.bin...'

BOOT_NEW_BIN="$(mktemp --tmpdir 'boot_new-amlogic.XXXX' --suffix='.bin')"

cat "${HARDKERNEL_UBOOT_DIR:?}/fip/gxb/bl2.package" "$FIP_BIN" \
	> "$BOOT_NEW_BIN"


# aml_encrypt_gxb
echo '==> Encrypting u-boot image...'
UBOOT_ENC_TMP="$(mktemp -d --tmpdir 'u-boot_enc-amlogic.XXXX')"
"${HARDKERNEL_UBOOT_DIR:?}/fip/gxb/aml_encrypt_gxb" \
	--bootsig \
	--input "$BOOT_NEW_BIN" \
	--output "${UBOOT_ENC_TMP:?}/u-boot.img"

mv "${UBOOT_ENC_TMP:?}/u-boot.img" "$UBOOT_IMG_OUT"
rm -rv "${UBOOT_ENC_TMP}/"
rm -v "$BOOT_NEW_BIN"


BL1="${HARDKERNEL_UBOOT_DIR:?}/sd_fuse/bl1.bin.hardkernel"

if [ -f "$BL1" ]
then
	echo '==> Generating mainline_sd_fusing.bin'
	FUSE_OUT="${DIR:?}/mainline_sd_fusing.bin"

	# put BL1 at the beginning of SD
	dd if="$BL1" of="$FUSE_OUT" conv=fsync,notrunc bs=1 count=442
	dd if="$BL1" of="$FUSE_OUT" conv=fsync,notrunc bs=512 skip=1 seek=1

	# append mainline u-boot
	dd if="$UBOOT_IMG_OUT" of="$FUSE_OUT" conv=fsync,notrunc bs=512 seek=97 skip=96

	sync
else
	echo 'Could not find BL1. You will have to to sd_fusing yourself.' >&2
fi

echo '==> Done'
