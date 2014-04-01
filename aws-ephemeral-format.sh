#!/bin/bash

#################################################################
# *** WARNING this script will format /dev/xvdb by default  *** #
# *** Verify your ephemeral storage location before running *** #
# *** as it *may* be different 								*** #
#################################################################

# Note: Add the following to rc.local BEFORE exit 0
# /home/ubuntu/scripts/swap_on.sh >> /tmp/swapon_log.log 2>&1

# TODO: Get $defaultPartitionSize from /proc/meminfo (eg. RAM / 2)

if [[ $EUID -ne 0 ]]; then
	echo "You must be a root user"
	exit 1
fi

usage() {
	cat <<EOF
	usage: aws-ephemeral-format.sh [ OPTION ]

	Format and or mount ephemeral storage on boot.

	Add to /etc/rc.local before exit 0 (/etc/rc.local must exit 0)

	Note: Remember to chown the -m directory if your planing on writing
		to it via a user other than root. 

	Options
	-t 		Partition type Linux Swap/Linux [ 82 | 83 ]
	-s 		Partition size in cylinders (required partition size in bytes divided by 8225697)
	-f 		File system format type [ swap | ext2 | ext3 | ext4 ]
	-m 		Mount location

EOF
}

while getopts "t:s:f:m:" opt; do
	case $opt in
		t)
			partitionTypeArg="$OPTARG" >&2
			;;
		s)
			partitionSizeArg="$OPTARG" >&2
			;;
		f)
			fileSystemFormatArg="$OPTARG" >&2
			;;
		m)
			mountLocationArg="$OPTARG" >&2
			;;
		\?)
			echo "Invalid option: -$OPTARG" >&2
			usage
			exit 1
			;;
		:)
			echo "backup.sh Requires an argument" >&2
			usage
			exit 1
			;;
	esac
done

#   ----------------------------------------------------------------
# 	Set function default function exist status
#			*** Do not modify ***
#   ----------------------------------------------------------------
createPartition_result=0
formatPartition_result=0
checkEphemeralStorage_result=0

PROGNAME=$(basename $0)

IFS="
"

function error_exit {
#	----------------------------------------------------------------
#	Function for exit due to fatal program error
#		Accepts 1 argument:
#			string containing descriptive error message
#	----------------------------------------------------------------

	echo "${PROGNAME}: ${1:-"Unknown Error"}" | tee >> $log
	cat $log
	exit 1
}


#   ----------------------------------------------------------------
#	Default log location
#   ----------------------------------------------------------------
log=/tmp/aws_ephemeral_format.log

#   ----------------------------------------------------------------
#	Cleanup log
#   ----------------------------------------------------------------
echo $date > $log

#   ----------------------------------------------------------------
#	Partition type is 82 (Linux Swap)
#	Change to 83 for Linux ext3/ext4
#   ----------------------------------------------------------------
if [ -z $partitionTypeArg ]; then
	error_exit "Partition type -t requires an argument!"
fi
partitionType="$partitionTypeArg"

#   ----------------------------------------------------------------
#	Partition size (disk cylinders) 1024 cylinders = 8032MB
#   ----------------------------------------------------------------
if [ -z $partitionSizeArg ]; then
	error_exit "Partition type -s requires an argument!"
fi
partitionSize="$partitionSizeArg"

#   ----------------------------------------------------------------
#	File system type. Supports: swap, ext2, ext3 & ext4
#   ----------------------------------------------------------------
if [ -z $fileSystemFormatArg ]; then
	error_exit "Partition type -f requires an argument!"
fi
fileSystemFormat="$fileSystemFormatArg"

#   ----------------------------------------------------------------
#	File system type. Supports: swap, ext2, ext3 & ext4
#   ----------------------------------------------------------------
	
if ! [[ $fileSystemFormat == swap ]]; then
	if [ -z $mountLocationArg ]; then
		error_exit "Partition type -m requires an argument!"
	fi
fi
mountLocation="$mountLocationArg"

function checkEphemeralStorage {
#	----------------------------------------------------------------
#	Function for checking Ephemeral storage which should be
#		on /dev/xvdb (Unless not avaiable for instance type)
#	----------------------------------------------------------------
	sfdisk -l /dev/xvdb > /dev/null 2>&1 || error_exit "Ephemeral storage not available"

	for line in `sfdisk -l /dev/xvdb 2>&1 | grep -A 1 \/dev\/xvdb:\ unrecognized\ partition\ table\ type`
	do
		if [[ $? -ne 0 ]]; then
			error_exit "Ephemeral storage not available"
		fi
		hddA+=( $line )
	done
	echo ${hddA[0]} | grep -q \/dev\/xvdb:\ unrecognized\ partition\ table\ type 
	if [[ $? = 0 ]]; then
		echo "Ephemeral storage available on /dev/xvdb" >> $log
		checkEphemeralStorage_result=1
	else
		echo "Ephemeral storage already has a partition structure or is unavailable!" >> $log
		checkEphemeralStorage_result=0
	fi
}

function createPartition {
#   ----------------------------------------------------------------
#   Function to create partitions on Ephemeral storage 
#   on /dev/xvdb (Unless not avaiable for instance type)
#	*** Caution will overwrite any data on /dev/xvdb ****
#   ----------------------------------------------------------------

	if [ -z $1 ]; then
		error_exit "partition type not selected! at line: $LINENO"
	elif ! [[ $1 =~ (82|83) ]]; then
		error_exit "partition type incorrect at line: $LINENO"
	fi

	if [ -z $2 ]; then
		error_exit "partition size not selected! at line: $LINENO"
	elif ! [[ $2 =~ [0-9]+ ]]; then
		error_exit "partition size \"$2\" invalid at line: $LINENO"
	fi

	local _partitionType=$1
	local _partitionSize=$2

	umount /dev/xvdb >> $log 2>&1
sfdisk /dev/xvdb  >> $log 2>&1 << EOF
,${_partitionSize},${_partitionType}
,
;
;
EOF
	if [ $? = 0 ]; then createPartition_result=1; fi
} 	

function mountPartition {
#       ----------------------------------------------------------------
#       Function create partition on Ephemeral storage
#       /dev/xvdb (Unless not avaiable for instance type)
# 							*** WARNING ***
#		*** This function will remove all data on the selected partition ***
#							*** WARNING ***
#       ----------------------------------------------------------------
	
	cat /proc/mounts | grep -q \/dev\/xvdb1 >> $log 2>&1
	local _isAlreadyMounted=$?
	if [ $_isAlreadyMounted = 0 ]; then
		echo "/dev/xvdb1 device already mounted!" >> $log
		exit 0
	fi
	local _mountType=$1
	local _mountLocation=$2
	if [ -z $1 ]; then
		error_exit "files system format not selected! at line: $LINENO"
	elif ! [[ $1 =~ (swap|ext2|ext3|ext4) ]]; then
		error_exit "File system format incorrect or unsupported! at line: $LINENO"
	fi

	if ! [[ $_mountType == swap ]]; then
		if ! [ -d $_mountLocation ]; then
			error_exit "Mount location: $_mountLocation does not exist!"
		fi
	fi

    local _partitionType=`sfdisk --print-id /dev/xvdb 1`
    local _partitionTypeStatus=$?

    if [[ $_partitionTypeStatus = 0 ]] && [[ $_partitionType == 82 ]] && [[ $_mountType == swap ]]; then
		echo "Mounting swap partition" >> $log
		/sbin/swapon /dev/xvdb1 >> $log 2>&1
		if [ $? = 1 ]; then error_exit "Unable to mount swap at $LINENO"; fi
	elif [[ $_partitionTypeStatus = 0 ]] && [[ $_partitionType == 83 ]] && [[ $_mountType =~ (ext2|ext3|ext4) ]]; then
		echo "Mounting $_mountType partition" >> $log
		/bin/mount /dev/xvdb1 $mountLocation >> $log 2>&1
		if [ $? = 1 ]; then error_exit "Unable to mount $_mountType at $LINENO"; fi
	else
		error_exit "Unable to determine disk format or mount location at line: $LINENO"
	fi
}

function formatPartition {
#       ----------------------------------------------------------------
#       Function to format partition on Ephemeral storage
#       /dev/xvdb (Unless not avaiable for instance type)
# 							*** WARNING ***
#		*** This function will remove all data on the selected partition ***
#							*** WARNING ***
#       ----------------------------------------------------------------
	if [ -z $1 ]; then
		error_exit "files system format not selected! at line: $LINENO"
	elif ! [[ $1 =~ (swap|ext2|ext3|ext4) ]]; then
		error_exit "File system format incorrect or unsupported! at line: $LINENO"
	fi

	local _fileSystemFormat=$1
    local _partitionTypeCheck=`sfdisk --print-id /dev/xvdb 1`
    local _partitionTypeCheckStatus=$?

    if [[ $_partitionTypeCheckStatus == 0 ]] && [[ $_partitionTypeCheck == 82 ]] && [[ $_fileSystemFormat == swap ]]; then
	   	echo "Fomatting swap partition" >> $log
       	/sbin/mkswap /dev/xvdb1 >> $log 2>&1
       	if [ $? = 0 ]; then formatPartition_result=1; fi
	elif [[ $_partitionTypeCheckStatus == 0 ]] && [[ $_partitionTypeCheck == 83 ]] && [[ $_fileSystemFormat == ext2 ]]; then
		echo "Formatting Linux ext2 partition" >> $log
		/sbin/mkfs.ext2 /dev/xvdb1 >> $log 2>&1
		if [ $? = 0 ]; then formatPartition_result=1; fi
	elif [[ $_partitionTypeCheckStatus == 0 ]] && [[ $_partitionTypeCheck == 83 ]] && [[ $_fileSystemFormat == ext3 ]]; then
		echo "Formatting Linux ext3 partition" >> $log
		/sbin/mkfs.ext3 /dev/xvdb1 >> $log 2>&1
	elif [[ $_partitionTypeCheckStatus == 0 ]] && [[ $_partitionTypeCheck == 83 ]] && [[ $_fileSystemFormat == ext4 ]]; then
		echo "Formatting Linux ext4 partition" >> $log
		/sbin/mkfs.ext3 /dev/xvdb1 >> $log 2>&1
		if [ $? = 0 ]; then formatPartition_result=1; fi
	else
		error_exit "Error formating, Unable to determine disk format or file system format at line: $LINENO"
	fi
}

#   ----------------------------------------------------------------
#	Check if Ephemeral storage is avaiable and proceed. 
#   ----------------------------------------------------------------
checkEphemeralStorage

if [[ $checkEphemeralStorage_result = 1 ]]; then
	createPartition $partitionType $partitionSize
	if [ $createPartition_result = 1 ]; then
		formatPartition $fileSystemFormat
	fi
	if [ $formatPartition_result = 1 ]; then
		mountPartition $fileSystemFormat $mountLocation
	fi
elif [[ $checkEphemeralStorage_result = 0 ]]; then
	mountPartition $fileSystemFormat $mountLocation
else
	error_exit
fi
