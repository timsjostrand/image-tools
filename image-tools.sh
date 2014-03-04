#!/bin/bash -ei
#
# Utility for managing disk images produced by 'dd' and other tools.
#
# Author: Tim Sjöstrand <tim.sjostrand@gmail.com>

set -e

IMAGE_TOOLS_VERSION=0

DEPENDENCIES=(
	"awk"
	"sed"
	"tail"
	"fdisk"
	"partprobe"
	"sync"
	"losetup"
	"gparted"
	"truncate"
)

print_usage() {
	echo
	echo "image-tools.sh v${IMAGE_TOOLS_VERSION}"
	echo
	echo "Utility for managing raw disk images produced by 'dd' and other tools."
	echo
	echo "Usage: $0 <command>"
	echo
	echo "Available commands:"
	echo "  partitions <IMAGE>"
	echo "    List partitions contained in image."
	echo
	echo "  losetup    <IMAGE>"
	echo "    Sets up an image file on a loopback device."
	echo
	echo "  mount      <IMAGE> [PARTITION_NO] [MOUNT_POINT]"
	echo "    Mounts the selected partition from an image file."
#	echo
#	echo "  fsck       <IMAGE> [PARTITION_NO]"
#	echo "    Run file system check on one or all partitions in image."
	echo
	echo "  shrink     <IMAGE>"
	echo "    Graphically edit partitions then shrink image file."
	echo
	echo "  compare-fs <IMAGE> <PARTITION_NO> <DST>"
	echo "    Compare the filesystem in the source image to that in DST. DST can be specified as a rsync destination."
	echo
	echo "  compare-img <SRC_IMAGE> <SRC_PARTITION_NO> <DST_IMAGE> <DST_PARTITION_NO>"
	echo "    Compares two filesystems."
	echo
}

error() {
	echo "ERROR: $@" >&2
}

log() {
	echo "$@" >&2
}

warn() {
	log "WARNING: $@"
}

pad_out() {
	while read line; do print "    ${line}"; done
}

check_is_root() {
	if [ "$(whoami)" != "root" ]
	then
		error "Must run as root."
		exit 2
	fi
}

check_rtfm_nag() {
	if [ ! -f ".rtfm" ]
	then
		read -p "WARNING: Do you know what you are doing? [yN]: " -n1 ANSWER
		echo

		if [[ ! "${ANSWER}" =~ [yY] ]]
		then
			exit 1
		fi

		read -p "WARNING: Are you really sure? Type 'N' to see the source code and learn what you are doing! [yN]: " -n1 ANSWER
		echo

		if [[ ! "${ANSWER}" =~ [yY] ]]
		then
			${EDITOR:-"vi"} "${0}"
			exit 1
		fi
	fi
}

check_dependencies() {
	for dep in "${DEPENDENCIES[@]}"
	do
		command -v "${dep}" >/dev/null 2>&1 || {
			error "Required package '${dep}' is not installed!"
			exit 1
		}
	done
}

device_setup() {
	# TODO: check if losetup is being used; losetup -f. a lot of rework!

	echo "* Setting up \"${1}\" on /dev/loop0..."
	losetup /dev/loop0 "${1}"

	echo "* Probing for partitions..."
	partprobe /dev/loop0

	echo -n "* Partitions found: "
	ls --color=never /dev/loop0p* 2>/dev/null || echo "None"
}

device_cleanup() {
	log "* Cleaning up from losetup..."
	sync
	losetup -d /dev/loop0 || true
}

device_setup_u() {
	IMG=$1
	LOOP_DEV=$(losetup -f)

	log "* Setting up \"${IMG}\" on ${LOOP_DEV}..."
	losetup "${LOOP_DEV}" "${IMG}"

	log "* Finding partitions..."
	partprobe "${LOOP_DEV}"

	log -n "* Partitions found: "
	ls --color=never ${LOOP_DEV}p* >&2 || log "None"

	echo "${LOOP_DEV}"
}

device_loopdevs() {
	IMAGE=$1
	losetup -j "${IMAGE}" | sed -n 's/^\(.*\)\:.*:.*$/\1/p'
}

device_cleanup_u() {
	LOOP_DEV=$1
	log "* Cleaning up from losetup..."
	sync
	losetup -d "${LOOP_DEV}" || true
}

image_sector_size() {
	fdisk -l "${1}" | sed -n 's/Units = sectors of .* = \(.*\) bytes/\1/p'
}

#
# Get the last sector used by partitions.
#
# @1		Image file name.
# @return	The last used sector.
#
partitions_last_sector() {
	END=0
	ENDS=$(fdisk -l "${1}" | awk '{ print $3 }')

	for tmp in ${ENDS}
	do
		if [[ "${tmp}" =~ ^[0-9]+$ ]] && [ "${tmp}" -gt "${END}" ]
		then
			END="${tmp}"
		fi
	done

	echo ${END:-"-1"}
}

#
# Lists all the partitions contained in an image.
#
# @1	Image file name.
#
partitions_list() {
	fdisk -l "${1}" | tail -n+9
}

#
# Calculates the minimum size of an image file for all partitions to fit on it.
#
# @1		Last sector.
# @2		Sector size.
# @return	Size required in bytes.
#
partitions_min_size() {
	SECTOR_END=$1
	SECTOR_SIZE=$2
	NEW_SIZE=$(( (SECTOR_END + 1) * SECTOR_SIZE ))
	echo ${NEW_SIZE:-"-1"}
}

image_mount() {
	IMAGE=$1
	PARTITION_NO=$2
	MOUNT_POINT=$3

	if [ ! -f "${IMAGE}" ]
	then
		error "Image not specified!"
#		print_usage
		exit 2
	fi

	if [ -z "${PARTITION_NO}" ]
	then
		error "Partition number not specified!"
#		print_usage
		exit 2
	fi

	if [ ! -d "${MOUNT_POINT}" ]
	then
		error "Invalid mount point specified!"
#		print_usage
		exit 2
	fi

	LOOP_DEV=$(device_setup_u "${IMAGE}")
	PART_NAME="${LOOP_DEV}p${PARTITION_NO}"

# TODO: check if already mounted?

	{
	if [ -b "${PART_NAME}" ]
	then
		log "* Mounting ${PART_NAME} on ${MOUNT_POINT}..."
		mount "${PART_NAME}" "${MOUNT_POINT}"
	else
		error "No such partition: ${PART_NAME}"
		exit 2
	fi
	} || {
		device_cleanup_u "${IMAGE}"
		false
	}
}

image_umount() {
	IMAGE=$1
	PARTITION_NO=$2

	LOOP_DEVS=$(device_loopdevs "$IMAGE")

	if [ -z "${LOOP_DEVS}" ]
	then
		error "No loop device for image (is it mounted?)."
		false
	fi

	for LOOP_DEV in ${LOOP_DEVS}
	do
		LOOP_PART="${LOOP_DEV}p${PARTITION_NO}"

		if [ -b "${LOOP_PART}" ]
		then
			log "* Unmounting ${LOOP_PART}..."
			sync
			umount "${LOOP_PART}" || true
		else
			warn "No such partition: ${LOOP_PART}"
		fi

		# Clean up loop device if no longer mounted anywhere.
		sleep 0.1
		MOUNTED=$(mount | grep "${LOOP_DEV}") || true

		if [ -z "${MOUNTED}" ]
		then
			log "* Not using ${LOOP_DEV}; cleaning up..."
			device_cleanup_u "${LOOP_DEV}"
		fi
	done
}

cmd_partitions() {
	IMAGE=$1

	if [ ! -f "${IMAGE}" ]
	then
		print_usage
		exit 2
	fi

	partitions_list "${IMAGE}"
}

cmd_losetup() {
	IMAGE=$1

	if [ ! -f "${IMAGE}" ]
	then
		print_usage
		exit 2
	fi

	device_setup "${IMAGE}"
}

cmd_mount() {
	IMAGE=$1
	PARTITION_NO=$2
	MOUNT_POINT=$3
	image_mount "${IMAGE}" "${PARTITION_NO}" "${MOUNT_POINT}"
}

cmd_umount() {
	IMAGE=$1
	PARTITION_NO=$2
	image_umount "${IMAGE}" "${PARTITION_NO}"
}

cmd_shrink() {
	IMAGE=$1

	if [ ! -f "${IMAGE}" ]
	then
		print_usage
		exit 2
	fi

	echo "* Calculating sector size... "
	SECTOR_SIZE=$(image_sector_size "${IMAGE}")

	echo "    Sector size: ${SECTOR_SIZE} bytes."

	if [ -z "${SECTOR_SIZE}" \
		-o "${SECTOR_SIZE}" -le 0 ]
	then
		error "Could not calculate image sector size."
		exit 1
	fi

	device_setup "${IMAGE}"

	echo "* Starting gparted..."
	gparted /dev/loop0

	echo "* Calculating new image size..."
	SECTOR_END=$(partitions_last_sector "${IMAGE}")

	if [ -z "${SECTOR_END}" \
		-o "${SECTOR_END}" -le 0 ]
	then
		error "Could not find last partition sector end (${SECTOR_END})."
		exit 1
	fi

	NEW_SIZE=$(partitions_min_size "${SECTOR_END}" "${SECTOR_SIZE}")

	if [ -z "${NEW_SIZE}" \
		-o "${NEW_SIZE}" -le 0 ]
	then
		error "Could not calculate new size."
		exit 1
	fi

	echo "    Sector size: ${SECTOR_SIZE} (bytes)"
	echo "    Last partition end: ${SECTOR_END} (sectors)"
	echo "    New size: ${NEW_SIZE} (bytes)"

	echo "* Resizing image..."
	truncate --size="${NEW_SIZE}" "${IMAGE}"

	device_cleanup
}

cmd_fsck() {
	IMAGE=$1

	if [ ! -f "${IMAGE}" ]
	then
		print_usage
		exit 2
	fi

	device_setup "${IMAGE}"
	echo "* Running file system check..."
	fsck /dev/loop0* < /dev/stdin

	device_cleanup
}

fs_compare() {
	SRC=$1
	DST=$2
	rsync --dry-run \
		--archive \
		--delete \
		--checksum \
		--itemize-changes \
		--progress \
		"${SRC}/" \
		"${DST}/"
	echo
	echo "First byte legend:"
	echo "  <	Transferred to DST."
	echo "  > 	Transferred to SRC."
	echo "  c	Local change/creation."
	echo "  h	Hard link."
	echo "  .	Not being updated (except for attributes)."
	echo "  *	See message."
	echo
	echo "Second byte legend:"
	echo "  f	File."
	echo "  d	Directory."
	echo "  L	Symlink."
	echo "  D	Device file."
	echo "  S 	Special file (sockets, fifo:s, etc)."
}

cmd_compare_fs() {
	IMAGE=$1
	PARTITION_NO=$2
	DEST_FS=$3
	MOUNT_POINT="/tmp/image-tools.${RANDOM}"
	mkdir -p "${MOUNT_POINT}" || true
	image_mount "${IMAGE}" "${PARTITION_NO}" "${MOUNT_POINT}"
	log "* Comparing filesystems..."
	echo
	{
	fs_compare "${MOUNT_POINT}" "${DEST_FS}"
	} || true
	echo
	image_umount "${IMAGE}" "${PARTITION_NO}"
	log "* Removing temporary mount point ${MOUNT_POINT}..."
	rm -d "${MOUNT_POINT}"
}

cmd_compare_img() {
	SRC_IMAGE=$1
	SRC_PARTITION_NO=$2
	SRC_MOUNT_POINT="/tmp/image-tools.${RANDOM}"

	DST_IMAGE=$3
	DST_PARTITION_NO=$4
	DST_MOUNT_POINT="/tmp/image-tools.${RANDOM}"

	mkdir -p "${SRC_MOUNT_POINT}" || true
	image_mount "${SRC_IMAGE}" "${SRC_PARTITION_NO}" "${SRC_MOUNT_POINT}"

	mkdir -p "${DST_MOUNT_POINT}" || true
	image_mount "${DST_IMAGE}" "${DST_PARTITION_NO}" "${DST_MOUNT_POINT}"

	log "* Comparing filesystems..."
	echo
	{
	fs_compare "${SRC_MOUNT_POINT}" "${DST_MOUNT_POINT}"
	} || true
	echo

	image_umount "${SRC_IMAGE}" "${SRC_PARTITION_NO}"
	image_umount "${DST_IMAGE}" "${DST_PARTITION_NO}"

	log "* Removing temporary mount point ${SRC_MOUNT_POINT}..."
	rm -d "${SRC_MOUNT_POINT}"
	log "* Removing temporary mount point ${DST_MOUNT_POINT}..."
	rm -d "${DST_MOUNT_POINT}"
}

check_dependencies

CMD=$1
shift 1 || true

case "${CMD}" in
	"partitions")
		cmd_partitions ${@}
	;;
	"losetup")
		check_is_root
		check_rtfm_nag
		cmd_losetup ${@}
	;;
	"mount")
		check_is_root
		check_rtfm_nag
		cmd_mount ${@}
	;;
	"umount")
		check_is_root
		check_rtfm_nag
		cmd_umount ${@}
	;;
	"shrink")
		check_is_root
		check_rtfm_nag
		cmd_shrink ${@}
	;;
	"fsck")
		check_is_root
		check_rtfm_nag
		cmd_fsck ${@}
	;;
	"compare-fs")
		check_is_root
		check_rtfm_nag
		cmd_compare_fs ${@}
	;;
	"compare-img")
		check_is_root
		check_rtfm_nag
		cmd_compare_img ${@}
	;;
	*)
		print_usage
		exit 0
	;;
esac
