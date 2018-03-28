INBSDODS106: Installing NetBSD 7 on Synology DS106
==================================================

#### Prerequisites
 - A TFTP server

#### Guide

1.  **Put the NetBSD installer onto your TFTP server**  
    You need the files `altboot.bin` and `netbsd-INSTALL`

2.  **Connect power, network and UART to the NAS**  
    Use the [NetBSD Synology DiskStation Installation Guide](http://wiki.netbsd.org/ports/sandpoint/instsynology/)
    as a reference for how to connect the UART.

3.  **Boot to u-boot**  
    Power on the NAS.  When asked press the keys (usually `[space]` or
    `C-c`) to interrupt automatic startup.

    If successful you will be greeted with a `_MPC824X > ` prompt.

    Then execute these commands to boot the NetBSD installer from TFTP:
    ```
    _MPC824X > setenv ipaddr <NAS IP address, e.g. 192.168.0.200>
    _MPC824X > setenv serverip <TFTP server IP, e.g. 192.168.0.2>
    _MPC824X > setenv netmask <your netmask, e.g. 255.255.255.0>

    _MPC824X > tftpboot 1000000 <path/to/altboot.bin>
    ARP broadcast 1
    ARP broadcast 2
    TFTP from server <TFTP server IP>; our IP address is <NAS IP>
    Filename 'altboot.bin'.
    Load address: 0x1000000
    Loading: #################
    done
    Bytes transferred = 86018 (15002 hex)

    _MPC824X > tftpboot 100000 <path/to/netbsd-INSTALL>
    ARP broadcast 1
    TFTP from server <TFTP server IP>; our IP address is <NAS IP>
    Filename 'netbsd-INSTALL'.
    Load address: 0x100000
    Loading: #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #################################################################
             #########################
    done
    Bytes transferred = 6115852 (5d520c hex)

    _MPC824X > go 1000000 mem:100000
    ```
4.  **Install NetBSD through installer**  

5.  **Auto-boot NetBSD**  
    By default the NAS will still boot the Synology recovery system by
    default.

    If you're lucky the u-boot on your NAS has `saveenv` enabled. If so, use
    the NetBSD installation guide as a reference for how to auto-boot to
    NetBSD.

    If you fear bricking your NAS, you can use the provided minicom runscript
    to jump start.

    If you have a working net booting setup in your network, use it to boot:
    ```
    DHCP=1 \
    minicom -S bin/boot_netbsd.run
    ```

    If not, no worries, you can also use static IP configuration to netboot, e.g.:
    ```
    DHCP=0 \
    NET_IP=192.168.0.195 \
    NET_MASK=255.255.255.0 \
    TFTP_SERVER=192.168.0.3 \
    TFTP_PREFIX=netbsd/sandpoint/ \
    minicom -S boot_netbsd.run
    ```
