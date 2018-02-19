IDOBPI: Installing Debian on Banana Pi M1 via debian-installer
==============================================================

Note: This guide has been tested with Debian Jessie and Stretch.

1.  **Download debian-installer images**
    - [firmware.BananaPi.img.gz](http://ftp.debian.org/debian/dists/stable/main/installer-armhf/current/images/netboot/SD-card-images/firmware.BananaPi.img.gz)
    - [partition.img.gz](http://ftp.debian.org/debian/dists/stable/main/installer-armhf/current/images/netboot/SD-card-images/partition.img.gz)

2.  **Make a bootable SD image**
    more information: [README.concatenateable_images](http://ftp.debian.org/debian/dists/jessie/main/installer-armhf/current/images/netboot/SD-card-images/README.concatenateable_images)

    ``` sh
    zcat firmware.BananaPi.img.gz partition.img.gz > bpi_d-i_boot.img
    ```
    (or use the pre-built image for Debian Stretch [bpi_d-i_stretch_boot.img](bin/bpi_d-i_stretch_boot.img))

3.  **Copy image `bananapi_boot.img` to SD card**
    (`<sdcard>` is usually `sdX` or `mmcblkX` on Linux, `diskX` on Mac OS X)
    ``` sh
    dd if=bpi_d-i_boot.img of=/dev/<sdcard>
    ```

4.  **Run debian-installer**
    - Put the SD card in the Banana Pi.
    - Connect a serial cable to the Banana Pi and your computer  
      more information: [Adding a serial port](http://linux-sunxi.org/LeMaker_Banana_Pi#Adding_a_serial_port)
    - Start your terminal
      (`tty` is usually `ttyUSB0` for USB-TTL adapters)
      ``` sh
      minicom -D /dev/<tty>
      ```
    - Connect power to the Banana Pi

5.  **Install Debian as you normally would...**
