#!/bin/bash

# v1.0  Written 3/7/16 cpf
# v1.1  cpf 3/9/16   Added more safety and support for /opt
# v1.2  cpf 3/10/16  Turned off /opt -- breaks BSA job.  Working on solution...
# v2.0  cpf 3/31/16  Added support for /swap (for swap), /null, /tmp and /opt
# v2.1  cpf 4/1/16   Added commandline options to work with different device and VG
# v2.2  cpf 4/7/16   Added /var check.  We do NOT do /var
# v2.3  cpf 4/11/16  Added /nullX logic to allow for multiple /null entries
# v2.4  cpf 4/11/16  Modified to edit existing fstab fields for replacements rather than
#        comment out and append new lines.  This is needed to maintain order.
# v3.0  cpf 4/27/16  Added support for RHEL7 xfs file systems.
# v3.1  cpf 5/20/16  Fixed bug in /opt size
# v4.0  cpf 6/9/16   Renamed to setup_appvg.sh  (was setup_sdb_appvg.sh).  This was to prepare
#        for packaging as an RPM
# v4.1  cpf 6/16/16  Fixed issue in RHEL7 when "-" is in the filesystem dir name.
#        Modified to use /dev/<vg>/<vol> instead of /dev/mapper/<vg>-<vol>
# v4.2  cpf  7/5/16  Added more re-startability if SOE failed after that was successful once before.
# v4.3  cpf  12/20/16 Added ability to use parted for vmdks > 2T
# v4.4  cpf  12/21/16 Fixed bug in the size totalling function
# v4.5  cpf  2/14/17  Changed to bash shell
# v4.6  cpf  5/18/17  Added support for "type" param, if provided
#        Added support for /home
# v4.7  cpf  10/12/17  Added "raw" type.  Accept this without complaining.
# v4.8  cpf  1/16/18  Added support for conversion and copy of /usr/local from dir to filesystem
# v4.9  cpf  1/16/18  Added support for conversion and copy of /var/log from dir to filesystem
# v4.10 cpf 5/18/18  Added support for migration of /var/avamar to separate filesystem
#
###########################################################################
# Cloned to this new script (setup_mounts.sh).  Start numbering with 1.0 again
# v1.0/1.1 (was 5.0) cpf 2/11/19  Skip when filesystem size requested is 0.
#        Allow multiple disks to be provided
#        Add -u option to select all unused disks
#        Move contents of /opt/app or /app -- don't assume they're empty
#        Major enhancements to allow almost any existing dir or fs be expanded or moved.
# v1.2  cpf 5/3/19  Remove '<' from lvs output when getting volume sizes.
# v1.3  cpf 9/16/19 Modified to use 3.5% overhead (was 4%).  Needed to pass very small sizes (mongodb)
# v1.4  cpf 10/29/19 Updated convert_to_m function to NOT add 1 unit unless decimal value sent.
###########################################################################
# v2.0  cpf 4/17/20  Updated to accept scsi device information for disks.
#        Also, added -O (override) option for working with rootvg
#        Enhanced to understand using the partition (not the entire disk) for space calculations
#           (needed to work with rootvg)
#        Removed check for presense of args.  If no args provided, it will still create an empty
#           volume group
# v2.1  cpf 5/7/20  - fixed bug in call to standardize_disklist -- was missing quotes on arg
# v2.2  cpf 5/12/20  - Added exit 1 status if scsi disk not found
# v2.3  cpf 6/12/20  - Fixed bug for > 2tb vmdks -- added DiskMB check/display
# v2.4  cpf 7/1/20  - Added a lot of error checking so the script exits on failure, and doesn't leave orphans in /etc/fstab
# v2.5  cpf 7/10/20  - fixed bug when running in debug mode -- failing on parted
# v2.6  cpf 3/5/21  - added /usr/bin, /usr/sbin, /usr/lib to the list of "won't touch these" directories
# v2.7  cpf 3/12/21  - added /boot to the list of "won't touch these" directories
# v2.8  cpf 3/18/21  - Modified to use existing volume name for existing filesystems, in case the volume name doesn't
#        match our naming standard.  This fixes the /opt/Tanium  (mounted on lvopttanium) issue
# v2.9  cpf 10/19/21  - updated to support RHEL8:  partprobe output change, redhat-release format change
# v2.10 cpf 11/10/21  - Fixed bug in complicated sed -- tripped over paths with slashes in them
#        Fixed bug where mounts with dashes in the name failed to be moved
# v2.11 cpf 03/08/22  - Sliding percentage overhead scale from max of 3.5% @ 100g to min of 1.0% @ 1000g
#        Fixed logic in convert_to_M to handle TiB disks (rounded up badly)
# v2.12 cpf 3/25/22  - set min overhead to 0.7% at 1000g
# v2.13 cpf 4/5/22  - set min overhead to 0.2% at 1000g
# v2.14 cpf 12/6/22  - Do not allow mount under /dev.  Also, return error status if anything is refused or fails
#        Added flag to fail on refused requests -- default is to not fail
# v3.0.0.1 mmg 3/27/2025 - Add logic to allow for new filesystems under /opt on appvg

#
# script to create VG (appvg by default), and requested filesystems in it.
# Added  logic to exit w/o doing anything if no args provided.
#
# WARNING!!!!!
# this script was ONLY meant to be run on a new build early in the build process, but has been enhanced to
#   work with existing systems.  It might do damage if you send it bad/wrong data.
# It defaults to using sdb for the disk to work with and appvg for the volume group if no disk is specified, and the VG isn't provided

#
# RULES:
#  - if /tmp, /opt, /app /home or /opt/app is requested, we move it into the requested VG.
#  - if an exiting directory structure or filesystem is specified, we create a new FS and move the contents into it
#  - if the filesystem already exists in the VG, then we look to see if we need to grow it.
#  - if a hierarchy of mounts is needed, you should send the top first.  Order may be important
#  - if /swap is requested, we use it for additional swap
#  - if /null is requested, it affects the check for diskspace, but nothing else.  Forces free-space in disk.
#  - You cannot move or expand root (/), /var, /boot, /usr/lib, /usr/bin or /usr/sbin
#  - You can move and expand /opt, but cannot change its filesystem type from the system default (reboot needed)

# Defaults: sdb (set later) and appvg...
APPVG=appvg    # if you want something other than appvg, you MUST specify it.

OSVER=$(awk '{print $(NF-1)}' /etc/redhat-release | awk -F. '{print $1}')
if ((OSVER > 6)); then
    DEFAULT_FSTYPE=xfs    # for v7 and later
else
    DEFAULT_FSTYPE=ext4   # for v6 and earlier
fi

FINAL_STATUS=0  # default status for script

# Syntax:
syntax ()
{
  echo "Syntax:  $0 [-hDf] [-g <vgname>] [[-d <disk>]|-u|-s] [<data>]

 -d <disk>[,<disk>...]   device to work with.  No path.   Default: sdb
       <disk> can be one of two formats -- examples:
             sdb      Normal block device
             scsi0:1  VMware SCSI device
       Note that duplicate entries will be consolidated
       Also note: if no <disk> provided, the script will still create an empty VG

 -s   Use all disks NOT on base scsi (overrides -d)  (useful for RAC clusters)

 -u   Use all unused disks             (overrides -d)

 -g <vgname>  Volume group to work with.  Default: appvg

 -f   Exit with failed status (1) if any requested filesystems are refused by the script

 -h   Show this help/syntax info

 -D   Show most commands, but do not DO anything

 <data> is of the format:  <path>,<size>[,<type>]
 <type> is \"ext4\" or \"xfs\"
 If <type> is not provided, it defaults to the preferred type for each OS version:
   ext4 for RHEL6, and xfs for RHEL7

 Syntax Examples:
     NOTE:  no spaces or colons allowed in the <path>,<size>[,<type>] parameters that make up <data>
       <data> entries can be separated from each other with spaces or colons

     For standard (RHEL7.x) Apache setup:
  $0 /www,100G,ext4:/opt/app,100G,xfs:/home,5G,ext4

     For setup with 10g /www, 20g /opt/app, 30g /app, 40g /other
  $0   /www,10g /opt/app,20g /app,20g /other,40g

     Special \"mounts\":
  /null,10g  No volume/filesystem is created, but size is \"reserved\", if specified
   null,10g  No volume/filesystem is created, but size is \"reserved\", if specified
  /swap,32g  This will create a 32G swap area and add it to swap.  No mount.

     RULES:
     - if /tmp, /opt, /app /home or /opt/app is requested, we move it out of rootvg into the requested VG.
     - if an existing directory structure or filesystem is specified, we create a new FS and move the contents into it
     - if the filesystem already exists in the VG, then we look to see if we need to grow it.
     - if a hierarchy of mounts is needed, you should send the top first.  Order may be important
     - if /swap (or swap) is requested, we use it for additional swap
     - if /null (or null) is requested, it affects the check for diskspace, but nothing else.  Forces free-space in disk.
     - if no <disk> args are provided, it will still create an empty volume group
     - if an invalid disk is specified, the script will error out
     - You cannot move or expand root (/), /var, /boot, /usr/lib, /usr/bin or /usr/sbin
     - You can move and expand /opt, but cannot change its filesystem type from the system default (reboot needed)
     - You can not create any mounts/filesystems under the /dev directory structure
     "
  exit
}

function convert_to_M {
    case $2 in
       [mM]*) val=$1 ;;
       [gG]*) val=$(echo "scale=0 ; a=$1 ; a * 1024" | bc) ;;
       [tT]*) val=$(echo "scale=0 ; a=$1 ; a * 1024 * 1024" | bc) ;;
            *) val=0 ;;
    esac
    # return the base number -- no decimal
    echo ${val%\.*}
}

function check_it {
    LVworking=${1:-${LVname}}    # accept an optional arg to this function
    lvs ${APPVG}/lv${LVworking} > /dev/null 2>&1
    if (($?)); then
      return 0
    else
      echo "  *** Existing /${FSname} mounted on volume lv${LVworking} in vg ${APPVG} -- Skipping create ***"
      return 1
    fi
}

function is_fs_already {
    df --output=source /${FSname} > /dev/null 2>&1
    if (($?)); then # found -- it's a filesystem
      return 0
    else    # not a mounted filesystem
      return 1
    fi
}

function create_it {
    # here, we create the new volume, dir and do the mount...
     $DEBUG lvcreate -L $$Size -n lv${LVname} ${APPVG}
     (($?)) && echo "Failed lvcreate - exiting" && exit 1
     $DEBUG mkfs.${FSTYPE} /dev/${APPVG}/lv${LVname}
     (($?)) && echo "Failed mkfs - exiting" && exit 1
     $DEBUG mkdir -p /${FSname}
     (($?)) && echo "Failed mkdir - exiting" && exit 1
}

function extend_it {
    LVworking=${1:-${LVname}}    # accept an optional arg to this function
    num=$(echo $Size | sed 's/[A-Za-z]*//g')    # strip off alpha(s)
    unit=$(echo $Size | sed 's/[\.0-9]*//g')    # strip off "." and digits
    lvOut=$(lvs | grep " lv${LVworking} " | grep " ${APPVG} " | sed 's/<//<//g')
    lvSize=$(echo $lvOut | awk '{print $NF}')
    lvnum=$(echo $lvSize | sed 's/[A-Za-z]*//g')         # strip off alpha(s)
    lvunit=$(echo $lvSize | sed 's/[\.0-9]*//g')         # strip off "." and digits
    DesiredSize=$(convert_to_M $num $unit)
    CurrentSize=$(convert_to_M $lvnum $lvunit)
    if (( CurrentSize < DesiredSize )); then
      echo "  Growing lv$LVworking from ${lvnum}${lvunit} to ${num}${unit}"
      $DEBUG lvextend -L${DesiredSize}m /dev/${APPVG}/lv${LVworking}         # add space to volume
      case $? in
        0) ;;        # worked -- continue on with the filesystem stuff
        5) return ;; # already was the right size - quietly return
        *) echo "Failed lvextend - exiting" && exit 1 ;; # broken
      esac

      # check to see if this is xfs or not (ext)...
      if (($(mount -t xfs | grep lv${LVworking} | wc -l) > 0)); then
            $DEBUG xfs_growfs /${FSname}              # grow the filesystem
            (($?)) && echo "Failed xfs_growfs - exiting" && exit 1
      else
            $DEBUG resize2fs  /${FSname}              # grow the filesystem
            (($?)) && echo "Failed resize2fs - exiting" && exit 1
      fi
    else
      echo "  *** lv$LVworking size: ${lvnum}${lvunit} meets requirement already"
    fi
}

function move_it {
    LVworking=${1:-${LVname}}    # accept an optional arg to this function
    vgOLD=$(lvs | grep " lv${LVworking} " | awk '{print $2}')
    $DEBUG lvrename $vgOLD lv${LVworking} OLDlv${LVworking}
    (($?)) && echo "Failed lvrename - exiting" && exit 1
    $DEBUG lvcreate -L $$Size -n lv${LVname} ${APPVG}
    (($?)) && echo "Failed lvcreate - exiting" && exit 1
    $DEBUG sed -i "/lv${LVworking}[ \t]/s/${LVworking}/${LVname}/" /etc/fstab
    $DEBUG sed -i "/lv${LVname}[ \t]/s/${vgOLD}/${APPVG}/" /etc/fstab
    $DEBUG sed -i "/lv${LVname}[ \t][ \t]*[a-zA-Z0-9]*[ \t]*[a-zA-Z0-9]*[ \t]/${FSname}\t\t\t${FSTYPE}\t%" /etc/fstab
    $DEBUG mkfs.${FSTYPE} /dev/${APPVG}/lv${LVname}
    (($?)) && echo "Failed mkfs - exiting" && exit 1
    $DEBUG mkdir -p /temp_mount
    $DEBUG mount /dev/${APPVG}/lv${LVname} /temp_mount
    $DEBUG cp -ar /${FSname}/* /temp_mount 2>/dev/null
    $DEBUG umount /${FSname}
    $DEBUG umount /temp_mount
    $DEBUG rm -rf /temp_mount
    $DEBUG mount /${FSname}
    $DEBUG chmod 1777 /${FSname}
}

function find_scsi1_disks {
    # Find disks not on the same SCSI device as the boot disk, since we put these on a new SCSI controller
    base="host$(ls -l /sys/block/sda | awk -F /host '{print $2}' | awk -F/ '{print $1}')"
    for dev in $(/bin/ls -l /sys/block/sd* | grep -v "/${base}/" | awk -F/ '{print $NF}')
    do
        echo -n " ${dev}"
    done
}

function find_unused_disks {
    # Find disks not in any volume group.  Also be sure to skip sda
    for dev in $(/bin/ls -l /sys/block/sd* | grep -v "sda$" | awk -F/ '{print $NF}')
    do
        if (($(pvs | grep "/dev/${dev}" | wc -l) == 0)); then
        echo -n " ${dev}"
    fi
    done
}

function lookup_block_device_from_scsi {

    #assume format:  scsi<bus>:<instance>
    bus=$(echo $1 | awk -F: '{print $1}')
    instance=$(echo $1 | awk -F: '{print $2}')

    declare -A SCSItoHost   # create associative array

    # loop through the scsi host* devices, and assume they are numbered in vmware by their sort order
    cnt=0
    while read host pci_info
    do
        # since RHEL6 apparently doesn't have "ata" in the bus path, we check the instance 0 of each
        # path, and skip the host/path if there is no instance 0:0:0:0 there.
        [ -e /dev/disk/by-path/pci-${pci_info}-scsi-0:0:0:0 ] || continue

        SCSItoHost[scsi${cnt}]=${pci_info}
        ((cnt+1))
    done < <(ls -l /sys/bus/scsi/devices/host*  | grep -v ata  | awk '{print $NF}' | awk -F/ '{print $NF "${NF-1}"}' | sort)

    # now, generate the pci by-path information
    path="pci-${SCSItoHost[$bus]}-scsi-0:${instance}:0"

    # return the block device found from the symlink info:
    ls -l /dev/disk/by-path/${path} | awk '{print $NF}' | sed 's/.*\///'
}

function standardize_disklist {
    # walk through arg provided, and return a list of sd* device names
    for dev in $(echo $1 | sed 's/,/ /g')
    do
      case $dev in
          sd*)  sddev=${dev} ;;   # already in proper format
        scsi*)  # SCSI information provided -- convert to sd device
                sddev=$(lookup_block_device_from_scsi $dev)
                if ! [[ "$sddev" =~ ^sd ]]; then
                  echo "ERROR: $dev mapped to $sddev -- invalid device" >&2
                  return 1
                fi
                ;;
           *)  echo "ERROR:  Invalid device specifier:  $dev" >&2 ; return 1 ;;
      esac
      echo -n " ${sddev}"
    done
}

###########################################################################
###########################################################################
###########################################################################
# Beginning of script...

while getopts fOhDusd:g: arg
do
    case $arg in
      h) syntax;;
      D) DEBUG="echo " ;;
      g) APPVG="$OPTARG" ;;
      d) DISKLIST="$OPTARG" ;;
      f) fail_on_skip="true" ;;
      s) use_scsi="true" ;;
      u) use_unused="true" ;;
      O) OVERRIDE="true" ;;  # hidden option -- allows override for rootvg expansion
      *) echo "Invalid argument -- exiting.  See $0 -h for help" ; syntax ;;
    esac
done
shift $(($OPTIND - 1))

# Remove this check.  This allows storage to be put into VGs with no volumes created
#if ((${#InputData}==0)); then   # no options used
#    if ((${#*}==0)); then   # no list provided
#      echo "Nothing to do.  See $0 -h for help"  >&2
#      exit   # nothing to do.  Exit right away.
#    fi
#fi

# Do not allow this option for RAC clusters -- ASM shows up as unused
. /boot/PNC_PROVISION_CONFIG
if [ "$DBTYPE" = "RAC" ]; then
    if ((${#use_unused})); then
        echo "the -u option is not available for RAC clusters"
        exit 1
    fi
fi

# Restrict rootvg, but allow "secret" override...
if [ "$APPVG" = "rootvg" ]; then
    if  ((${#OVERRIDE}==0)); then
        echo "Can not resize ${APPVG} - exiting"
        exit 1
    fi
fi

###
### NOTE:  The 3 disk options conflict  (-d, -s, -u).  Precidence is set by the order here:
###

# if -s option is sent, override DISKLIST with the non-boot scsi disks...
((${#use_scsi})) && DISKLIST=$(find_scsi1_disks)

# if -u option is sent, override DISKLIST with the unused disks...
((${#use_unused})) && DISKLIST=$(find_unused_disks)

# convert DISKLIST to sd* device names (in case scsi* was provided)
DISKLIST=$(standardize_disklist "$DISKLIST")
(($?)) && echo "for syntax help see:  $0 -h" && exit 1

# Make DISKLIST a space separated list of devices...
DISKLIST=$(echo $DISKLIST | sed 's/,/ /g')

# verify that the device exists
for APPDISK in ${DISKLIST}
do
    fdisk -l | grep ${APPDISK}
    if (($?)); then
        echo "Device /dev/${APPDISK} not found.  Exiting"  >&2
        exit 1
    fi
done

# get the disk(s) currently in the VG.  Note: if the VG doesn't exist, this will be empty
OldDISKLIST=$(echo $(pvs | grep ${APPVG} | awk '{print $1}' | sed -e 's%/dev/%%' -e 's/[0-9]$//'))

# set a flag if the VG already exists...
vgs ${APPVG} >/dev/null 2>&1
if (($?)); then
    echo "$APPVG volume group does not exist.  It will be created"
    VGNeeded="true"
    if ((${#DISKLIST}==0)); then  # the DISKLIST is empty -- nothing specified
        DISKLIST=sdb  # default if no VG, and no disk options on command line
    fi
else
    echo "$APPVG volume group already exists"
    if ((${#DISKLIST}==0)); then  # the DISKLIST is empty -- nothing specified
        echo "Looking for the disks used by the volume group"
        DISKLIST=$OldDISKLIST  # default to disks in specified VG if none provided on command line
    fi
fi

# now, create a NewDISKLIST made up of disks provided, but not yet in the VG.
# and an updated DISKLIST that has a list of all disks in the VG (no dups).
for name in $(echo $DISKLIST $OldDISKLIST | sed 's/ /\n/g' | sort -ru)
do
    SumDISKLIST="${name} ${SumDISKLIST}"
    (($(pvs | grep ${APPVG} | grep ${name} | wc -1) == 0)) && NewDISKLIST="${name} ${NewDISKLIST}"
done

# first verify that $APPDISK is not already in use by a VG other than $APPVG
for APPDISK in ${SumDISKLIST}
do
    echo "Checking  ${APPDISK}"
    if (($(pvs | grep ${APPDISK} | wc -l) > 0)); then
      echo "NOTE: Device /dev/${APPDISK} already has been partitioned. Verifying Availability..."  >&2
      if (($(pvscan | grep ${APPDISK} | grep $APPVG | wc -l) > 0)); then
        echo "NOTE: Device /dev/${APPDISK} already has VG $APPVG.  Continuing..."  >&2
      elif (($(pvscan -n 2>/dev/null | grep ${APPDISK} | wc -l) > 0)); then
        echo "NOTE: Device /dev/${APPDISK} has no VG.  Continuing..."  >&2
      else
        echo "ERROR: Device /dev/${APPDISK} is not available for $APPVG.  Showing pvs output and exiting:" >&2
        pvs | grep ${APPDISK} >&2
        exit 1
      fi
    fi
done
echo ""

###########################################################################
# Quick sanity check to be sure we fit on the new disk set:
###########################################################################

# Initialize to avoid syntax errors later...
AvailDiskMB=0
TotalDiskMB=0
Additional=0

# Gather the OLD (existing) disk size info:
for APPDISK in ${OldDISKLIST}
do
    #DiskFree=$(pvs -o pv_name,pv_free | grep /dev/${APPDISK}1 | awk '{print $NF}')  # old logic - replaced by the loop
    # Don't assume a single partition on each device, or that the partition is #1 (ie, for rootvg):
    while read dev vg size
    do
      if [ "$vg" = "$APPVG" ]; then
          DiskFree=$size
          DiskSize=$(echo $DiskFree | sed 's/[<A-Za-z]*//g')   # strip off alpha(s)
          DiskUnit=$(echo $DiskFree | sed 's/[<\.0-9]*//g')    # strip off "." and digits
          AvailDiskMB=$((AvailDiskMB + $(convert_to_M $DiskSize $DiskUnit)))
      fi
    done < <(pvs -o pv_name,vgname,pv_free | grep ${APPVG} | grep /dev/${APPDISK})

    # this is for the base (entire) device...
    DiskSize=$(fdisk -l /dev/$APPDISK 2>/dev/null | grep  "^Disk /dev" | awk '{print $3}')
    DiskUnit=$(fdisk -l /dev/$APPDISK 2>/dev/null | grep  "^Disk /dev" | awk '{print $4}')
    TotalDiskMB=$((TotalDiskMB + $(convert_to_M $DiskSize $DiskUnit)))
done

# Gather the new disk size info and add it in to the Total and Available counters:
if ((${#NewDISKLIST})); then
    for APPDISK in ${NewDISKLIST}
    do
        DiskSize=$(fdisk -l /dev/$APPDISK 2>/dev/null | grep  "^Disk /dev" | awk '{print $3}')
        DiskUnit=$(fdisk -l /dev/$APPDISK 2>/dev/null | grep  "^Disk /dev" | awk '{print $4}')
        TotalDiskMB=$((TotalDiskMB + $(convert_to_M $DiskSize $DiskUnit)))
        AvailDiskMB=$((AvailDiskMB + $(convert_to_M $DiskSize $DiskUnit)))
    done
fi

# add up the requested additional size info:
for pair in $(echo $InputData $* | sed 's/:/ /g')
do
    # check here to see if the volume already exists.
    # It might exist, and might already be the right size.
    FSname=$(echo $pair | awk -F, '{print $1}')
    LVname="lv$(echo $pair | awk -F, '{print $1}' | sed 's/\////g')"  # remove all slashes
    lvOut=$(lvs | grep " ${LVname} " | grep " ${APPVG} " | sed 's/<//<//g')

    Size=$(echo $pair   | awk -F, '{print $2}')
    num=$(echo $Size | sed 's/[A-Za-z]*//g')    # strip off alpha(s)
    unit=$(echo $Size | sed 's/[\.0-9]*//g')    # strip off "." and digits
    DesiredSize=$(convert_to_M $num $unit)

    echo "  Checking ${FSname}  (volume name:  ${LVname})..."
    if ((${#lvOut})); then  # if something is found -- it exists...
        lvSize=$(echo $lvOut | awk '{print $NF}')
        lvnum=$(echo $lvSize | sed 's/[A-Za-z]*//g')    # strip off alpha(s)
        lvunit=$(echo $lvSize | sed 's/[\.0-9]*//g')    # strip off "." and digits

        CurrentSize=$(convert_to_M $lvnum $lvunit)
        if (( CurrentSize == DesiredSize )); then
            echo "    NOTE: volume $LVname of proper size found in group $APPVG"
        elif (( CurrentSize > DesiredSize )); then
            # It was found, but is too large...Skip it.
            echo "    WARNING: volume $LVname was found in $APPVG, but size is greater than requested. Skipping..."
        else
            echo "    $LVname found and will be grown from ${lvnum}${lvunit} to ${num}${unit}"
            ((Additional += (DesiredSize - CurrentSize)))
        fi
    else
        # we didn't find it, so we'll add it all
        echo "    NOTE: $FSname is not in the ${APPVG} volume group. It will be created with size: $DesiredSize"
        ((Additional += DesiredSize))
    fi
    echo ""
done

###########################################################################
# Overhead work -- Royal PITA
# Overhead: max 3.5% at 100g, min 0.7% at 1000g, linear decrease between
# PctFactor is (100 + percent) * 10
#
# Why these values...
# 3500 is max percentage (3.5 * 100)
#  900 is the width of the window for the linear change (1000 max - 100 min)
# 3300 is the percentage change from min to max * 1000 (3.5 - 0.2 * 1000)
PctFactor=$(echo "scale=6 ; a=$((Additional)); (3500 - ((a-(100*1024))*(3300/(900*1024))))" | bc )
PctFactor=$(echo "scale=0 ; a=$PctFactor ; (a+100000)/100" | bc)
PctFactor=${PctFactor%\.*}
((PctFactor < 1002)) && PctFactor=1002    # minimum is 0.2%
((PctFactor > 1035)) && PctFactor=1035    # maximum is 3.5%
percent=$(printf "%.1f\n" "$(((PctFactor-1000)*10/10))e-1")

# this is where the overhead is applied
d=${Additional} # save the original value
Additional=$(( (Additional * PctFactor)/1000 ))

# remember these converted values
a=$(echo "scale=1; $AvailDiskMB / 1024" | bc)
b=$(echo "scale=1; $TotalDiskMB / 1024" | bc)
c=$(echo "scale=1; $Additional  / 1024" | bc)

# report...
printf "List of New Disks to be used:              %-15s\n"     "${NewDISKLIST:-(none)}"
printf "List of Disks already in %-22s %-15s\n"   "${APPVG} ${OldDISKLIST:-(none)}"
printf "Total list of Disks to consider:           %-15s\n"     "${SumDISKLIST:-(none)}"
printf "Total space in disklist:                   %-5s %15s\n" "${b}g" "(${TotalDiskMB}mb)"
printf "Unused space in disklist:                  %-5s %15s\n" "${a}g" "(${AvailDiskMB}mb)"
printf "New space requested (includes %1.1f%% overhead):   %-5s %15s  (before overhead: %smb)\n" $percent "${c}g" "(${Additional}mb)" $d

# see if it fits:
if ((Additional > AvailDiskMB)); then
  echo -e "\nERROR: Available space in Disklist ($a G) is not enough to hold the total additional requests ($c G)"  >&2
  exit 1
else
  echo -e "\n### All pre-checks cleared.  Ready to start ###"
fi

###########################################################################
# AFTER HERE things happen.
###########################################################################

#
# label and partition the new devices
#
for APPDISK in ${NewDISKLIST}
do
    APPDISKPART="$APPDISK""1"
    partprobe -d -s /dev/$APPDISKPART > /dev/null 2>&1
    if (($?)); then
      DiskSize=$(fdisk -l /dev/$APPDISK 2>/dev/null | grep  "^Disk /dev" | awk '{print $3}')
      DiskUnit=$(fdisk -l /dev/$APPDISK 2>/dev/null | grep  "^Disk /dev" | awk '{print $4}')
      DiskMB=$(convert_to_M $DiskSize $DiskUnit)
      echo "Disk size:  ${DiskMB}M"
      if (( DiskMB > (2 * 1024 * 1024) )); then
          echo "Using parted for partitioning since $APPDISK is more than 2Tb"
          $DEBUG parted -s /dev/$APPDISK "mklabel gpt"
          $DEBUG parted -s /dev/$APPDISK "mkpart primary 1049k -0"
          $DEBUG parted -s /dev/$APPDISK "name 1 $APPVG"

      else
          echo "Using fdisk for partitioning since $APPDISK is less than 2Tb"
          $DEBUG echo -e "n\np\n1\n\n\n\n8e\nw\n" | $DEBUG fdisk /dev/$APPDISK
          $DEBUG pvcreate /dev/$APPDISKPART   # Should be able to skip the pvcreate, per Tom.  Need to test
      fi
    fi

    # try again -- this time is should work or else something failed - but don't fail in debug mode
    $DEBUG partprobe -d -s /dev/$APPDISKPART > /dev/null 2>&1
    (($?)) && echo "Failed to partition new disk /dev/$APPDISKPART - exiting" && exit 1

    # create VG if needed, then clear flag and extend as needed
    if ((${#VGNeeded})); then
      $DEBUG vgcreate ${APPVG} /dev/$APPDISKPART
      (($?)) && echo "Failed vgcreate ${APPVG} /dev/$APPDISKPART - exiting" && exit 1
      VGNeeded=""  # clear this now that we have the VG
    else
      $DEBUG vgextend ${APPVG} /dev/$APPDISKPART    # add disk to VG
      (($?)) && echo "Failed vgextend ${APPVG} /dev/$APPDISKPART - exiting" && exit 1
    fi
done

# FSTAB:  Always make sure we have an original (fstab.SOE) as well as current (fstab.$$)  backup copy...
test -f /etc/fstab.SOE || cp -p /etc/fstab /etc/fstab.SOE
cp -p /etc/fstab /tmp/fstab.$$    # put current backup in /tmp

# now, work on each dataset in the InputData string, and/or other args provided.
# this time, we also use the optional 3rd subfield...
for dataset in $(echo $InputData $* | sed 's/:/ /g')
do
    FSname=$(echo $dataset | awk -F, '{print $1}' | sed 's/^\/////')  # only remove leading slash...
    LVname=$(echo $dataset | awk -F, '{print $1}' | sed 's/\////g')  # remove all slashes
    Size=$(echo $dataset   | awk -F, '{print $2}')
    FSTYPE=$(echo $dataset | awk -F, '{print $3}')
    FSTYPE=${FSTYPE:-$DEFAULT_FSTYPE}  # set to default if not provided...


    # Verify appropriate FSTYPE has been requested...
    case $FSTYPE in
      ext4) ;;
      xfs)  if ((OSVER < 7)); then
                echo "  *** RHEL v${OSVER} does not support $FSTYPE.  Using system default:  $DEFAULT_FSTYPE ***"
                FSTYPE=$DEFAULT_FSTYPE
            fi
            ;;
      raw)  FSTYPE=$DEFAULT_FSTYPE ;; # added to avoid spurious message when creating swap space or "null"
       *)   echo "  *** Unknown filesystem type: $FSTYPE.  Using system default: $DEFAULT_FSTYPE ***"
            FSTYPE=$DEFAULT_FSTYPE
            ;;
    esac

    # check for /dev/... requests -- and reject them
    if [[ $FSname =~ ^dev/ ]]; then
      echo "  *** Change in /${FSname} requested.  Request DENIED ***" >&2
      echo "  *** We will NOT create mounts under /dev -- Skipping ***" >&2
      ((FINAL_STATUS += 1))
      continue
    fi

    case $LVname in
      "") # / is NEVER an option to change...
            echo "  *** Change in / requested.  Request DENIED ***" >&2
            echo "  *** We will NOT change root filesystem size.  Skipping ***" >&2
            ((FINAL_STATUS += 1))
            ;;

      # here is a list of locations to skip in addition to /
      usrlib    |\
      usrsbin   |\
      usrbin    |\
      boot      |\
      dev       |\
      var)
            echo "  *** Change in /${FSname} requested.  Request DENIED ***" >&2
            echo "  *** We will NOT touch /${FSname} -- Skipping ***" >&2
            ((FINAL_STATUS += 1))
            ;;

      null*) # /null is used to request space that is NOT mounted - allow more than one /null*
            # just ignore the request here
            echo "null requested.  No changes" >&2
            ;;

      swap) # /swap is used to create additional swap space...
            echo "Working on swap request"
            if check_it; then
                $DEBUG lvcreate -L $Size -n lv${LVname} ${APPVG}
                $DEBUG mkswap /dev/${APPVG}/lvswap
                ((${#DEBUG}==0)) && echo "/dev/${APPVG}/lv${LVname}  swap  swap  defaults  0 0" >>/etc/fstab
                $DEBUG swapon -a
            fi
            ;;

      opt) # /opt is mounted at /dev/rootvg/lvopt in the template...
            echo "Saving /opt for last..."
            OptSize=${Size}  # remember the size for /opt
            WorkOnOpt="true"
            ;;

      *) # standard (new, old or just dir) filesystem request...
            echo "Working on /${FSname}"
            df --output=target | grep "/${FSname}$" > /dev/null 2>&1
            if (($?)); then # not found -- it is NOT a mounted filesystem, but may be a dir with contents...
              if [ -d /${FSname} ]; then  # create and move old contents
                $DEBUG mv /${FSname} /${FSname}OLD  # rename the current directory
                create_it
                ((${#DEBUG}==0)) && echo "/dev/${APPVG}/lv${LVname}  /${FSname}  ${FSTYPE}  defaults  0 0" >>/etc/fstab
                $DEBUG mount /${FSname}
                $DEBUG mv /${FSname}OLD/* /${FSname}   # move the contents to the mount
                $DEBUG rmdir /${FSname}OLD
                $DEBUG chmod 1777 /${FSname}
              else  # create from scratch
                create_it
                ((${#DEBUG}==0)) && echo "/dev/${APPVG}/lv${LVname}  /${FSname}  ${FSTYPE}  defaults  0 0" >>/etc/fstab
                $DEBUG mount /${FSname}
              fi
            else  # already a mounted filesystem
                # before checking, get the actual volume name of the mounted filesystem.
                # don't just assume it is the properly derived name (eg: /opt/Tanium mounted from lvopttanium)
                # since we're getting the volume from the mapper target, we need to collapse double dashes
                LVactual=$(df --output=source /$FSname | grep -v Filesystem | awk -F[-/]lv '{print $2}' | sed 's/--/-/g')
                if check_it $LVactual; then  # it's not in the right VG
                  move_it $LVactual
                else  # it is in the right VG, so check size and extend if needed
                  extend_it $LVactual
                fi
            fi
            ;;
    esac
done

#
# /opt is a very special case:
#
if ((${#WorkOnOpt})); then  # now, if /opt was requested, work on it LAST
    LVname="opt"       # need to set this outside of case statement...
    FSname="opt"       # need to set this outside of case statement...
    Size=${OptSize}    # this is what was requested
    FSTYPE=$DEFAULT_FSTYPE  # I don't care what  they asked for... It's going to be the system default :)
    echo "Working on /opt"
    if check_it; then
      $DEBUG lvrename rootvg lvopt OLDlvopt
      (($?)) && echo "Failed lvrename - exiting" && exit 1
      $DEBUG sed -i "/lvopt[ \t]/s/rootvg/${APPVG}/" /etc/fstab
      $DEBUG mkdir -p /tmp/opt-new
      $DEBUG lvcreate -L $Size -n lv${LVname} ${APPVG}
      (($?)) && echo "Failed lvcreate - exiting" && exit 1
      $DEBUG mkfs.${FSTYPE} /dev/${APPVG}/lv${LVname}
      (($?)) && echo "Failed mkfs - exiting" && exit 1
      $DEBUG mount /dev/${APPVG}/lv${LVname} /tmp/opt-new
      $DEBUG cd /opt   # needed for next command
      $DEBUG ((${#DEBUG}==0)) && mv $(ls | egrep -v "bmc|app|lost") /tmp/opt-new
      $DEBUG mkdir -p /tmp/opt-new/app /tmp/opt-new/bmc
      $DEBUG cd /root   # go home
      $DEBUG umount /tmp/opt-new
      echo "  *** NOTICE:  Reboot is required for changing /opt ***"  >&2
    else
      extend_it
    fi
fi

if ((FINAL_STATUS > 0)) && ((${#fail_on_skip})) ; then
  echo " "
  echo "Exiting with error status.  One or more filesystem updates failed or were refused"
  echo "See error output for details"
  exit 1
else
  exit 0
fi
