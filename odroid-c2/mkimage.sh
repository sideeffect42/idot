#! /bin/bash

# Install a bog-standard (non-mainline kernel) Debian bootable for ODROID C2.
#
# Beware: This will ERASE ALL DATA on the target SD card
# or MMC partition.
#
#
# Copyright 2016 Takashi Yoshi
#
# based on a script by:
#   Copyright 2016 Steinar H. Gunderson <steinar+odroid@gunderson.no>.
#
# Licensed under the GNU GPL, v2 or (at your option) any later version.

set -e -x

DEVICE=''
SUITE=jessie
TYPE=sd
MIRROR=''

BOOTINIPART_MB=8
BOOTPART_MB=256
SWAP_MB=4096

HOSTNAME='odroid'
VGNAME='odroid-vg'


while getopts 'b:s:t:' opt; do
	case $opt in
		b)
			BOOTPART_MB=$OPTARG
			;;
		s)
			SUITE=$OPTARG
			;;
		t)
			TYPE=$OPTARG
			;;
		:)
			echo 'Option -$OPTARG requires an argument.'
			exit 1
			;;
	esac
done
shift $((OPTIND - 1))

DEVICE=$1
if [ ! -b "${DEVICE}" ]; then
	echo 'Usage: $0 [-b BOOTPARTITION_SIZE] [-s SUITE] [-t sd|mmc] DEVICE [OTHER_DEBOOTSTRAP_ARGS...]'
	echo 'DEVICE is an SD card device, e.g. /dev/sdb.'
	exit 1
fi
shift

if [ "$TYPE" != "sd" ] && [ "$TYPE" != "mmc" ]; then
	echo "Card type must be 'sd' or 'mmc'."
	exit 1
fi

set -x



########################
### GET DEPENDENCIES ###
########################

if [ ! -d ./c2_boot_ubuntu_release ]; then
	# we dont have hardkernel sd_fusing scripts, download them
	[ ! -f ./c2_boot_ubuntu_release.tar.gz ] && wget 'http://dn.odroid.com/S905/BootLoader/ODROID-C2/c2_boot_ubuntu_release.tar.gz'
	tar zxvf ./c2_boot_ubuntu_release.tar.gz

	# fix script to not eject device
	cp ./c2_boot_ubuntu_release/sd_fusing.sh{,.bkp}
	sed -i 's/^sudo eject/#sudo eject/' ./c2_boot_ubuntu_release/sd_fusing.sh
fi
exit 0



###############################
### SET UP PARTITION LAYOUT ###
###############################

# Clear beginning of device
dd if="/dev/zero" of="${DEVICE}" count=2592 bs=512 conv=sync


# Partition the device.
parted "${DEVICE}" mklabel msdos
parted "${DEVICE}" mkpart primary fat32 2MiB $((BOOTINIPART_MB + 2))MiB
parted "${DEVICE}" set 1 boot on
parted "${DEVICE}" mkpart primary ext2 $((BOOTINIPART_MB + 2))MiB $((BOOTPART_MB + BOOTINIPART_MB + 2))MiB
parted "${DEVICE}" mkpart primary ext4 $((BOOTINIPART_MB + BOOTPART_MB + 2))MiB 100%

sync


# Figure out if the partitions are of type ${DEVICE}1 or ${DEVICE}p1.
if [ -b "${DEVICE}1" ]; then
	DEVICE_STEM="${DEVICE}"
elif [ -b "${DEVICE}p1" ]; then
	DEVICE_STEM="${DEVICE}p"
else
	echo "Could not find device files for partitions of ${DEVICE}. Exiting."
	exit 1
fi



#################
### SD FUSING ###
#################

if [ "$TYPE" = "sd" ]; then
	UBOOT_DEVICE="${DEVICE}"
	UBOOT_OFFSET=1

	# Do sd_fusing
	sh -c "cd ./c2_boot_ubuntu_release; sh ./sd_fusing.sh \"${UBOOT_DEVICE}\""
else
	UBOOT_DEVICE="${DEVICE}boot0"
	UBOOT_OFFSET=0

	# TODO
fi



#########################
### CREATE PARTITIONS ###
#########################

# Create a /boot/ini partition. Strictly speaking, almost everything could be loaded
# from ext2, but Hardkernel's u-boot wants to load boot.ini from a FAT partition.
# (It doesn't support symlinks, though, which breaks flash-kernel, so we create a
# separate ext2 partition for /boot)
BOOTINI_PART="${DEVICE_STEM}1"
mkfs.vfat "${BOOTINI_PART}"

# Create /boot partition
BOOT_PART="${DEVICE_STEM}2"
mkfs.ext2 "${BOOT_PART}"

# Put an LVM on the other partition; it's easier to deal with when expanding
# partitions or otherwise moving them around.
vgchange -a n "${VGNAME}" || true  # Could be left around from a previous copy of the partition.
pvcreate -ff "${DEVICE_STEM}3"
vgcreate "${VGNAME}" "${DEVICE_STEM}3"
lvcreate -L${SWAP_MB:-1024} -n swap "${VGNAME}"
lvcreate -l 100%FREE -n root "${VGNAME}"

# And the main filesystem.
if [ ! -d "/dev/${VGNAME}" ]; then
	echo 'Cant find volume group'
	exit 1
fi

mkfs.ext4 "/dev/${VGNAME}/root"
mkswap "/dev/${VGNAME}/swap"



#############################
### 1st STAGE DEBOOTSTRAP ###
#############################

# Mount the filesystem and debootstrap into it.
# isc-dhcp-client is, of course, not necessarily required, especially as
# systemd-networkd is included and can do networking just fine, but most people
# will probably find it very frustrating to install packages without it.
mkdir -p /mnt/c2/
mount "/dev/${VGNAME}/root" /mnt/c2
mkdir /mnt/c2/boot/
mount "${BOOT_PART}" /mnt/c2/boot
mkdir /mnt/c2/boot/ini
mount "${BOOTINI_PART}" /mnt/c2/boot/ini


debootstrap --include=locales,lvm2,isc-dhcp-client --foreign --arch arm64 "${SUITE}" /mnt/c2 "$@"



###########################
### 2nd STAGE BOOTSTRAP ###
###########################

# Run the second stage debootstrap under qemu (via binfmt_misc).
cp /usr/bin/qemu-aarch64-static /mnt/c2/usr/bin/

DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/c2 /debootstrap/debootstrap --second-stage
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/c2 dpkg --configure -a



#############################
### GET HARDKERNEL KERNEL ###
#############################

# Add odroid.in repo
echo "deb http://deb.odroid.in/c2/ xenial main" > /mnt/c2/etc/apt/sources.list.d/odroid_in.list

# only get kernel package from odroid.in
cat <<EOF > /mnt/c2/etc/apt/preferences.d/odroid_in
Package: *
Pin: origin deb.odroid.in
Pin-Priority: -1

Package: linux-*
Pin: origin deb.odroid.in
Pin-Priority: 501
EOF

# get repo pgp key
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/c2 /usr/bin/apt-key adv --keyserver 'keyserver.ubuntu.com' --recv-keys '5360FB9DAB19BAC9'

DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/c2 /usr/bin/apt update
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/c2 /usr/bin/apt -y install u-boot-tools
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/c2 /usr/bin/apt -y install linux-image-c2 ||

# it looks like sometimes linux-image-c2 installation can fail, so let's run it 
# again. That appears to fix it sometimes.
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/c2 /usr/bin/apt-get -f install



########################
### CONFIGURE SYSTEM ###
########################

# Set a hostname.
echo "${HOSTNAME}" > /mnt/c2/etc/hostname

# Work around Debian bug #824391.
echo ttySAC2 >> /mnt/c2/etc/securetty


# Set apt repos
# Enable security updates, and apply any that might be waiting.
if [ "$SUITE" != "unstable" ] && [ "$SUITE" != "sid" ]; then
	echo "deb http://security.debian.org $SUITE/updates main" >> /mnt/c2/etc/apt/sources.list
	echo "deb-src http://security.debian.org $SUITE/updates main" >> /mnt/c2/etc/apt/sources.list
fi

DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/c2 apt update || true
DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/c2 apt -y dist-upgrade || true

DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C chroot /mnt/c2 dpkg-reconfigure locales

# Create an fstab (this is normally done by partconf, in d-i).
BOOT_UUID=$(blkid -s UUID -o value ${BOOT_PART})
BOOTINI_UUID=$(blkid -s UUID -o value ${BOOTINI_PART})
cat <<EOF > /mnt/c2/etc/fstab
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


# Configure eth0 interface
cat <<EOF > /mnt/c2/etc/network/interfaces.d/eth0
allow-hotplug eth0
iface eth0 inet dhcp
EOF



########################
### INSTALL BOOT.INI ###
########################

cp ./boot.ini /mnt/c2/boot/ini/
sed -i "s/##VGNAME##/${VGNAME}/" /mnt/c2/boot/ini/boot.ini



##############
### FINISH ###
##############

# Set the root password. (It should be okay to have a dumb one as default,
# since there's no ssh by default. Yet, it would be nice to have a way
# to ask on first boot, or better yet, invoke debian-installer after boot.)
echo root:odroid | chroot /mnt/c2 /usr/sbin/chpasswd



################
### CLEAN UP ###
################

# Zero any unused blocks on /boot, for better packing if we are to compress the
# filesystem and publish it somewhere. (See below for the root device.)
echo 'Please ignore the following error about full disk.'
dd if=/dev/zero of=/mnt/c2/boot/zerofill bs=1M || true
rm -f /mnt/c2/boot/zerofill

# All done, clean up.
rm /mnt/c2/usr/bin/qemu-aarch64-static
umount -R /mnt/c2

# The root file system is ext4, so we can use zerofree, which is
# supposedly faster than dd-ing a zero file onto it.
zerofree -v "/dev/${VGNAME}/root"

vgchange -a n "${VGNAME}"

rm -r /mnt/c2
