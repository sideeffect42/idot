#!/usr/bin/env bash

set -e -x

MAINLINE_UBOOT="${DIR:?}/u-boot-amlogic/u-boot.bin"
UBOOT_IMG_OUT="${DIR:?}/u-boot.img"

SELF="$(realpath "${BASH_SOURCE[0]}")"
DIR="$(dirname "$SELF")"

HARDKERNEL_UBOOT_DIR="${DIR:?}/hardkernel/u-boot"


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

# check if running on amd64, because of Hardkernel fuckery and proprietary shit
# binaries.
if [ "x86_64" != "$(uname -m)" ]
then
	echo 'To create the FIP file and encrypt the u-boot image, you need to run this script on an amd64 machine.' >&2
	exit 1
fi


# fip_create
FIP_BIN_OUT="$(mktemp --tmpdir 'fip-amlogic.XXXX' --suffix='.bin')"

"${HARDKERNEL_UBOOT_DIR:?}/fip/fip_create" \
	--bl30 "${HARDKERNEL_UBOOT_DIR:?}/fip/gxb/bl30.bin" \
	--bl31 "${HARDKERNEL_UBOOT_DIR:?}/fip/gxb/bl301.bin" \
	--bl31 "${HARDKERNEL_UBOOT_DIR:?}/fip/gxb/bl31.bin" \
	--bl33 "$MAINLINE_UBOOT" \
	"$FIP_BIN_OUT"

# fip dump
"${HARDKERNEL_UBOOT_DIR:?}/fip/fip_create" \
	--dump "$FIP_BIN_OUT"

# prepend bl2 to fip
BOOT_NEW_BIN="$(mktemp --tmpdir 'boot_new-amlogic.XXXX' --suffix='.bin')"

cat "${HARDKERNEL_UBOOT_DIR:?}/fip/gxb/bl2.package" "$FIP_BIN_OUT" \
	> "$BOOT_NEW_BIN"

rm -v "$FIP_BIN_OUT"

# aml_encrypt_gxb
"${HARDKERNEL_UBOOT_DIR:?}/fip/gxb/aml_encrypt_gxb" \
	--bootsig \
	--input "$BOOT_NEW_BIN" \
	--output "$UBOOT_IMG_OUT"

rm -v "$BOOT_NEW_BIN"
