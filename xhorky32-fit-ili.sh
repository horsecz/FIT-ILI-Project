#!/bin/bash

#
# ILI: Mid-semester assignment
#
# Author:       Dominik Horky, FIT
# File:         xhorky32-fit-ili.sh
# Date:         14. 11. 2020
# Description:  Bash script for clean Fedora32 Server installation performing operations with storage devices and filesystems.
# Note:         Script does not have to clean-up after itself.
# Requirements: 1 GB of free space on your HDD/SSD,
#               Linux OS with bash shell (Fedora32 Server, clean installation).
# Req. note:    For other distros than Fedora32 Server, adjustments such as installing necessary utilities may be needed.
#

#
# GLOBAL VARIABLES
#

VG_NAME="FIT_vg"
LV_NAME="FIT_lv"

#
# FUNCTIONS
#

faultyEmul () {
    printf "\t-> creating new 200MB file\n" 
    dd if=/dev/zero of=./newdevice.img bs=1MB count=200 1>/dev/null 2>/dev/null
    if ! [ -e "./newdevice.img" ]; then
        printf "Error: Can't create new 200MB file.\n"
        exit 10;
    fi
    
    printf "\t-> setting up new loop device\n"
    RES=$(losetup --show /dev/loop15 ./newdevice.img)
    if ! [ "$RES" = "/dev/loop15" ]; then
        printf "Error: Couldn't set up newdevice.img as 5th loop device\n"
        exit 10;
    fi
    
    printf "\t-> marking /dev/loop11 as faulty in RAID1 /dev/md0\n"
    mdadm --manage /dev/md0 --fail /dev/loop11 1>/dev/null 2>/dev/null # not needed, but are we emulating faulty disk replacement, right?
    printf "\t   output of /proc/mdstat: \n\n:"
    cat "/proc/mdstat" # it'll show [_U] or [U_] which means one of devices in RAID is faulty
    
    printf "\n\t-> removing faulty device (/dev/loop11) from RAID1\n"
    mdadm --manage /dev/md0 --remove /dev/loop11 1>/dev/null 2>/dev/null
    
    printf "\t-> replacing faulty device with new loop device\n"
    mdadm --manage /dev/md0 --add /dev/loop15 1>/dev/null 2>/dev/null
    
    printf "\t-> verifying the successful recovery of RAID\n"
    printf "\t   output of /proc/mdstat: \n\n"
    
    sleep 5 # it takes some time to recovery, if there was no sleep or short sleep time, we'd see progress of recovery and not the result (note: depends on your hardware - SSD/HDD speed)
    cat "/proc/mdstat"
    
    printf "\n\t-> if the recovery was successful, then blocks at md0 show [UU] (healthy), if not, it will show [_U] or [U_] where _ means faulty disk\n\t   (if there is progress (bar) in output, wait some time and then try cat /proc/mdstat again)\n"
}

createFile () {
    printf "\t-> creating file\n"
    dd if=/dev/urandom of=/mnt/test1/big_file bs=1MB count=300 1>/dev/null 2>/dev/null
    if ! [ -e "/mnt/test1/big_file" ]; then
        printf "Error: Can't create 300MB with data from /dev/urandom\n"
        exit 9;
    fi
    
    printf "\t-> creating checksum of the file\n"
    printf "\t   output: "
    sha512sum /mnt/test1/big_file --tag
}

resizeFS () {
    printf "\t-> resizing logical volume FIT_lv1 (to claim all available space in %s)\n" "$VG_NAME"
    printf "\t   current size: 100M\n"
    lvresize -l +100%FREE "/dev/$VG_NAME/FIT_lv1" 1>/dev/null 2>/dev/null
    
    printf "\t-> resizing filesystem on FIT_lv1 (to apply changes)\n"
    resize2fs "/dev/$VG_NAME/FIT_lv1" 1>/dev/null 2>/dev/null
    
    N_SIZE=$(df -h | grep FIT_lv1 | cut -f3 -d ' ')
    printf "\t   new size: %s\n" "$N_SIZE"
}

mountLV () {
    for i in {1..2}
    do
        mkdir "/mnt/test$i" 1>/dev/null 2>/dev/null
        if ! [ -e "/mnt/test$i" ]; then
            printf "Error: Can't create directory %s\n" "/mnt/test$i"
            exit 7;
        fi
        
        mount "/dev/$VG_NAME/$LV_NAME$i" "/mnt/test$i" 1>/dev/null 2>/dev/null
        if [ "$(lsblk | grep /mnt/test$i)" = "" ]; then # not great check but enough for clean installation
            printf "Error: Can't mount %s into %s\n" "/dev/$VG_NAME/$LV_NAME$i" "/mnt/test$i"
            exit 7;
        fi
    done
}

createXFS () {
    printf "\t-> formatting FIT_lv2 volume to XFS fs\n"
    mkfs.xfs "/dev/$VG_NAME/FIT_lv2" 1>/dev/null 2>/dev/null
}

createEXT4 () {
    printf "\t-> formatting FIT_lv1 volume to EXT4 fs\n"
    mkfs.ext4 "/dev/$VG_NAME/FIT_lv1" 1>/dev/null 2>/dev/null
}

createLV () {
    for i in {1..2}
    do
        printf "\t-> creating logical volume %s (size: 100MB)\n" "$LV_NAME$i"
        lvcreate "$VG_NAME" -n "$LV_NAME$i" -L100M 1>/dev/null 2>/dev/null
        
        if ! [ -e "/dev/$VG_NAME/$LV_NAME$i" ]; then
            printf "Error: Couldn't create logical volume %s in group %s\n" "$LV_NAME$i" "$VG_NAME"
            exit 4;
        fi
    done
}

createVG () {
    printf "\t-> creating physical volumes from RAID devices (for volume group)\n"
    pvcreate /dev/md0 1>/dev/null 2>/dev/null
    pvcreate /dev/md1 1>/dev/null 2>/dev/null
    
    printf "\t-> creating volume %s group on top of these RAID devices\n" "$VG_NAME"
    vgcreate "$VG_NAME" /dev/md0 /dev/md1 1>/dev/null 2>/dev/null
    
    if [ "$(vgdisplay | grep FIT_vg)" = "" ]; then # nonperfect check but it'll work on clean installation
        printf "Error: Couldn't create volume group %s\n" "$VG_NAME"
        exit 3;
    fi
}

createRAID () {
    printf "\t-> creating RAID1 on first 2 loop devices\n"
    echo yes | mdadm --create /dev/md0 --level=mirror --raid-devices=2 /dev/loop11 /dev/loop12 1>/dev/null 2>/dev/null
    if ! [ -e /dev/md0 ]; then
        printf "Error: Couldn't create RAID1 on first two loop devices\n"
        exit 2;
    fi
    
    printf "\t-> creating RAID0 on other loop devices\n"
    echo yes | mdadm --create /dev/md1 --level=0 --raid-devices=2 /dev/loop13 /dev/loop14 1>/dev/null 2>/dev/null
    if ! [ -e /dev/md1 ]; then
        printf "Error: Couldn't create RAID0 on other two loop devices\n"
        exit 2;
    fi
}

createLoops () {
    for i in {1..4}
    do
        printf "\t-> creating file number %s (size: 200MB)\n" "$i"
        dd if=/dev/zero of=./device$i.img bs=1MB count=200 1>/dev/null 2>/dev/null
        if ! [ -e ./device$i.img ]; then
            printf "Error: Couldn't create file %s\n" "device$i.img"
            exit 1;
        fi
        RES=$(losetup --show /dev/loop$((i+10)) ./device$i.img)
        if ! [ "$RES" = "/dev/loop$((i+10))" ]; then
            printf "Error: Couldn't set up loop device '%s' to '%s'\n" "device$i.img" "/dev/loop$((i+10))"
            exit 1;
        fi
    done
}

main () {
    printf "1) Creating 4 loop devices\n"
    createLoops
    printf "2) Creating software RAID on loop devices\n"
    createRAID
    printf "3) Creating volume group on top of these RAID devices\n"
    createVG
    printf "4) Creating 2 logical volumes in volume group\n"
    createLV
    printf "5) Creating EXT4 filesystem on FIT_lv1 logical volume\n"
    createEXT4
    printf "6) Creating XFS filesystem on FIT_lv2 logical volume\n"
    createXFS
    printf "7) Mounting logical volumes to test directories\n"
    mountLV
    printf "8) Resizing filesystem on FIT_lv1\n"
    resizeFS
    printf "9) Creating 300MB file in /mnt/test1\n"
    createFile
    printf "10) Emulating faulty disk replacement\n"
    faultyEmul
}


#
# INIT
#

# run the script
main

# exit with 0 if script ran successfully, otherwise exit code reflects the part when script failed
exit 0;
