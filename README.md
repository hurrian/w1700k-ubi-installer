# w1700k-ubi-installer

OpenWrt firmware installer for the Gemtek W1700K (UBI) based on [owrt-ubi-installer by dangowrt](https://github.com/dangowrt/owrt-ubi-installer).

## Installation Instructions

**1) Installing U-Boot Chainloader**

On your PC, change your IP to 192.168.1.10.

Ensure that you are serving the U-Boot file as openwrt-airoha-an7581-gemtek_w1700k-ubi-chainload-uboot.itb 

On your UART console, enter the following commands:
```
> setenv one flash read 0x600000 0x100000 \$loadaddr
> setenv two "; bootm"
> setenv bootcmd "$one$two"
> saveenv
> setenv serverip 192.168.1.10 ; setenv ipaddr 192.168.1.1 ; tftpboot 0x89000000 openwrt-airoha-an7581-gemtek_w1700k-ubi-chainload-uboot.itb
> flash erase 0x600000 0x100000
> flash write 0x600000 0x100000 0x89000000
> reset
```

Your device will now reboot to the U-Boot Chainloader.

**2) Loading the W1700K UBI Installer**

With your TFTP server, ensure you are serving the installer as `openwrt-airoha-an7581-gemtek_w1700k-ubi-initramfs-installer.itb`

Select *Boot installer via TFTP* in the U-Boot Boot Menu, as below:
```
 *** U-Boot Boot Menu ***

     1. Run default boot command.
     2. Boot system via TFTP.
     3. Boot recovery system from flash.
     4. Boot installer via TFTP. <---------------- SELECT THIS
     5. Reboot.
     0. Exit
```

**3) Running the W1700K UBI Installer**

If you have previously installed OpenWrt on your device, you may be asked by the installer:
```
Existing UBI layout detected. Proceed and overwrite? (yes/no)
```

Please note that answering **yes** will proceed with reformatting your device.

Once started, all you have to do is wait until the Installer finishes.

It will perform the needed migration and automatically install an inital build of OpenWrt for the W1700K.

From there you may update to any build of your choosing.
