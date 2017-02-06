IDOXU4: Installing Debian on ODROID-XU4
=======================================

Because there is no debian-installer for ODROID-XU4, we need to bootstrap it
from a different machine.

`mkimage.sh` will do that.

### Usage
``` sh
cd <path/to/here> ; ./mkimage.sh -s stable -t sd /dev/sdX
```

# Requirements

To run `mkimage.sh` a Debian system is recommended, but any GNU/Linux system
should to the job if it has  
bash, dd, debootstrap, dosfstools, e2fsprogs, lvm2, mount, parted, sed, tar,
wget, zerofree.

If the system used for bootstrapping is not armhf, you will additionally need
qemu-user-static.