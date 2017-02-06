#!/bin/bash

# Install a bog-standard Debian bootable for ODROID XU3/XU4.
#
# Note: You will need u-boot-exynos >= 2016.05~rc3+dfsg1-1,
# which at the time of writing is in experimental (it will
# probably eventually hit stretch).
#
# Beware: This will ERASE ALL DATA on the target SD card
# or MMC partition.
#
# Copyright 2016, 2017 Takashi Yoshi
#
# based on work by:
#   Copyright 2016 Steinar H. Gunderson <steinar+odroid@gunderson.no>.
# Licensed under the GNU GPL, v2 or (at your option) any later version.

set -e -x

DEVICE=''
BOOTINIPART_MB=32
BOOTPART_MB=256
SUITE='jessie'
BACKPORTS_REPO=true
KERNEL_VERSION='4.6.0-0.bpo.1'
TYPE='mmc'
SWAP_MB=4096
VGNAME='odroid'
HOSTNAME='odroid'

while getopts 'b:s:t:' opt; do
	case $opt in
		b)
			BOOTPART_MB="$OPTARG"
			;;
		s)
			# Sorry, jessie won't work; the kernel doesn't support XU3/XU4.
			SUITE="$OPTARG"
			;;
		t)
			TYPE="$OPTARG"
			;;
		:)
			echo "Option -$OPTARG requires an argument."
			exit 1
			;;
	esac
done
shift $((OPTIND - 1))

DEVICE="$1"
if [ ! -b "$DEVICE" ]; then
	echo "Usage: $0 [-b BOOTPARTITION_SIZE] [-s SUITE] [-t sd|mmc] DEVICE [OTHER_DEBOOTSTRAP_ARGS...]"
	echo 'DEVICE is an SD card device, e.g. /dev/sdb.'
	exit 1
fi
shift

if [ "$TYPE" != 'sd' ] && [ "$TYPE" != 'mmc' ]; then
	echo "Card type must be 'sd' or 'mmc'."
	exit 1
fi

set -x


########################
### GET DEPENDENCIES ###
########################


# Get first stages of bootloader. (BL1 must be signed by Hardkernel,
# and TZSW comes without source anyway, so we can't build these ourselves)
# This is the only part that doesn't strictly need root.
if [ ! -d 'u-boot' ]; then
	echo 'Missing u-boot directory. Get it and try again'
	exit 1
fi




###############################
### SET UP PARTITION LAYOUT ###
###############################

# Clear beginning of device
dd if='/dev/zero' of="$DEVICE" count=2592 bs=512 conv=sync


# Partition the device.
parted "$DEVICE" mklabel msdos
parted "$DEVICE" mkpart primary fat32 4MiB $((BOOTINIPART_MB + 4))MiB
parted "$DEVICE" set 1 boot on
parted "$DEVICE" mkpart primary ext2 $((BOOTINIPART_MB + 4))MiB $((BOOTINIPART_MB + BOOTPART_MB + 4))MiB
parted "$DEVICE" mkpart primary ext4 $((BOOTINIPART_MB + BOOTPART_MB + 4))MiB 100%

sync


# Figure out if the partitions are of type ${DEVICE}1 or ${DEVICE}p1.
if [ -b "${DEVICE}1" ]; then
	DEVICE_STEM="$DEVICE"
elif [ -b "${DEVICE}p1" ]; then
	DEVICE_STEM="${DEVICE}p"
else
	echo "Could not find device files for partitions of ${DEVICE}. Exiting."
	exit 1
fi

# Put the different stages of U-Boot into the right place.
# The offsets come from /usr/share/doc/u-boot-exynos/README.odroid.gz.
if [ "$TYPE" = 'sd' ]; then
	UBOOT_DEVICE="$DEVICE"
	UBOOT_OFFSET=1
else
	UBOOT_DEVICE="${DEVICE}boot0"
	UBOOT_OFFSET=0
fi



###############
### SD FUSE ###
###############

if [ $(cat /sys/block/$(basename "${UBOOT_DEVICE}")/ro) -ne 1 ]; then
	dd if='u-boot/sd_fuse/hardkernel_1mb_uboot/bl1.bin.hardkernel' \
	   of="$UBOOT_DEVICE" seek="$UBOOT_OFFSET" conv=sync
	dd if='u-boot/sd_fuse/hardkernel_1mb_uboot/bl2.bin.hardkernel.1mb_uboot' \
	   of="$UBOOT_DEVICE" seek=$((UBOOT_OFFSET + 30)) conv=sync


	UBOOT_BIN=''
	for f in $(find './u-boot-dtb.bin' './u-boot.bin' \
		'/usr/lib/u-boot/odroid-xu3/u-boot-dtb.bin' '/usr/lib/u-boot/odroid-xu3/u-boot.bin' 2>&-); do
		if [ -f "$f" ]; then
			UBOOT_BIN="$f"
			break
		fi
	done

	if [ -f "$UBOOT_BIN" ]; then
		dd if="$UBOOT_BIN" of="$UBOOT_DEVICE" seek=$((UBOOT_OFFSET + 62)) conv=sync
	else
		echo "Cannot find odroid u-boot-dtb.bin. Install a new version of u-boot-exynos"
		exit 1
	fi

	dd if='u-boot/sd_fuse/hardkernel_1mb_uboot/tzsw.bin.hardkernel' \
	   of="$UBOOT_DEVICE" seek=$((UBOOT_OFFSET + 2110)) conv=sync
else
	echo "Skipping SD fusing because ${UBOOT_DEVICE} is force_ro"
fi



#########################
### CREATE PARTITIONS ###
#########################

# Create a /boot/ini partition. Strictly speaking, almost everything could be loaded
# from ext2, but Hardkernel's u-boot wants to load boot.ini from a FAT partition.
# (It doesn't support symlinks, though, which breaks flash-kernel, so we create a
# separate ext2 partition for /boot)
BOOTINI_PART="${DEVICE_STEM}1"
mkfs.vfat "$BOOTINI_PART"

# Create /boot partition.
BOOT_PART="${DEVICE_STEM}2"
mkfs.ext2 "$BOOT_PART"

# Put an LVM on the other partition; it's easier to deal with when expanding
# partitions or otherwise moving them around.
vgchange -an "$VGNAME" || true  # Could be left around from a previous copy of the partition.
pvcreate -ff "${DEVICE_STEM}3"
vgcreate "$VGNAME" "${DEVICE_STEM}3"
lvcreate -L${SWAP_MB:-1024} -n swap "$VGNAME"
lvcreate -l '100%FREE' -n root "$VGNAME"

# And the main filesystem.
if [ ! -d "/dev/${VGNAME}" ]; then
	echo 'Cant find volume group'
	exit 1
fi

# And the main filesystem and swap.
mkfs.ext4 "/dev/${VGNAME}/root"
mkswap "/dev/${VGNAME}/swap" || true


###################
### DEBOOTSTRAP ###
###################

# Mount the filesystem and debootstrap into it.
# isc-dhcp-client is, of course, not necessarily required, especially as
# systemd-networkd is included and can do networking just fine, but most people
# will probably find it very frustrating to install packages without it.
mkdir -p '/mnt/xu4/'
mount "/dev/${VGNAME}/root" '/mnt/xu4'
mkdir -p '/mnt/xu4/boot'
mount "$BOOT_PART" '/mnt/xu4/boot'
mkdir -p '/mnt/xu4/boot/ini'
mount "$BOOTINI_PART" '/mnt/xu4/boot/ini'

debootstrap --include=locales,linux-image-armmp-lpae,grub-efi-arm,lvm2,isc-dhcp-client \
	--foreign --arch 'armhf' "${SUITE}" '/mnt/xu4' "$@"

# Run the second stage debootstrap under qemu (via binfmt_misc).

cp "$(which qemu-arm-static /usr/bin/qemu-arm-static | head -n 1)" '/mnt/xu4/usr/bin/'

DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C \
	chroot '/mnt/xu4' '/debootstrap/debootstrap' --second-stage
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C \
	chroot '/mnt/xu4' dpkg --configure -a



#######################
### SETUP APT REPOS ###
#######################

# Enable security updates, and apply any that might be waiting.
if [ "$SUITE" != "unstable" ] && [ "$SUITE" != "sid" ]; then
	echo "deb http://security.debian.org $SUITE/updates main" >> /mnt/xu4/etc/apt/sources.list
fi

if [ "$SUITE" = "jessie" ] && $BACKPORTS_REPO; then
	# enable backports repo
	echo 'deb http://http.debian.net/debian jessie-backports main' > '/mnt/xu4/etc/apt/sources.list.d/jessie-backports.list'
fi

DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C \
	chroot '/mnt/xu4' apt update
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C \
	chroot '/mnt/xu4' apt -y dist-upgrade || true


########################
### CONFIGURE SYSTEM ###
########################

# Upgrade kernel
APT_KERNEL_OPTS='-t jessie-backports'
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C \
	chroot '/mnt/xu4' bash -c "apt -y ${APT_KERNEL_OPTS} install linux-image-$([ \"x$KERNEL_VERSION\" != \"x\" ] && echo ${KERNEL_VERSION}-)armmp-lpae"

DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C \
	chroot '/mnt/xu4' dpkg-reconfigure locales

# Create an fstab (this is normally done by partconf, in d-i).
BOOT_UUID="$(blkid -s UUID -o value "$BOOT_PART")"
BOOTINI_UUID="$(blkid -s UUID -o value "$BOOTINI_PART")"
cat <<EOF > '/mnt/xu4/etc/fstab'
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
/dev/${VGNAME}/root / ext4 errors=remount-ro 0 1
/dev/${VGNAME}/swap none swap sw 0 0
UUID=${BOOT_UUID} /boot ext2 defaults 0 2
UUID=${BOOTINI_UUID} /boot/ini vfat defaults 0 2
EOF

# Set a hostname.
echo "$HOSTNAME" > '/mnt/xu4/etc/hostname'

# Work around Debian bug #824391.
echo 'ttySAC2' >> '/mnt/xu4/etc/securetty'

# Configure eth0 interface
cat <<EOF > '/mnt/xu4/etc/network/interfaces.d/eth0'
allow-hotplug eth0
iface eth0 inet dhcp
EOF

# Set the root password. (It should be okay to have a dumb one as default,
# since there's no ssh by default. Yet, it would be nice to have a way
# to ask on first boot, or better yet, invoke debian-installer after boot.)
echo 'root:odroid' | chroot '/mnt/xu4' '/usr/sbin/chpasswd'



####################
### INSTALL GRUB ###
####################

# Install GRUB, chainloaded from U-Boot via UEFI.
mount --bind '/dev' '/mnt/xu4/dev'
mount --bind '/proc' '/mnt/xu4/proc'

chroot '/mnt/xu4' '/usr/sbin/grub-install' --removable --target=arm-efi \
	--boot-directory='/boot' --efi-directory='/boot/ini'

# Get the device tree in place (we need it to load GRUB).
# flash-kernel can do this (if you also have u-boot-tools installed),
# but it also includes its own boot script (which has higher priority than
# GRUB) and just seems to lock up.
cp -v $(find '/mnt/xu4' -name 'exynos5422-odroidxu4.dtb') '/mnt/xu4/boot/'
cp -v $(find '/mnt/xu4' -name 'exynos5422-odroidxu4.dtb') '/mnt/xu4/boot/ini/'
# TODO: Decide for one

# update-grub does not add “devicetree” statements for the
# each kernel (not that it's copied from /usr/lib without
# flash-kernel anyway), so we need to explicitly load it
# ourselves. See Debian bug #824399.
cat <<EOF > '/mnt/xu4/etc/grub.d/25_devicetree'
#! /bin/sh
set -e

# Hack added by prepare.sh when building the root image,
# to work around Debian bug #824399.
echo "echo 'Loading device tree ...'"
echo "devicetree /exynos5422-odroidxu4.dtb"
EOF

chmod 0755 '/mnt/xu4/etc/grub.d/25_devicetree'

# Work around Debian bug #823552.
sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT=".*\)"/\1 loglevel=4"/' '/mnt/xu4/etc/default/grub'

# Now we can create the GRUB boot menu.
chroot '/mnt/xu4' '/usr/sbin/update-grub'


################
### CLEAN UP ###
################

# Zero any unused blocks on /boot, for better packing if we are to compress the
# filesystem and publish it somewhere. (See below for the root device.)
echo 'Please ignore the following error about full disk.'
dd if='/dev/zero' of='/mnt/xu4/boot/ini/zerofill' bs=1M || true
rm -f '/mnt/xu4/boot/ini/zerofill'

#dd if=/dev/zero of=/mnt/xu4/boot/zerofill bs=1M || true
#rm -f /mnt/xu4/boot/zerofill

# All done, clean up.
rm '/mnt/xu4/usr/bin/qemu-arm-static'
umount -R '/mnt/xu4'


# The root/boot file system is ext2/4, so we can use zerofree, which is
# supposedly faster than dd-ing a zero file onto it.
zerofree -v "$BOOT_PART"
zerofree -v "/dev/${VGNAME}/root"

vgchange -an "$VGNAME"
