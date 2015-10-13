################################################################################
#
# Linux Deploy
# (C) 2012-2015 Anton Skshidlevsky <meefik@gmail.com>, GPLv3
#
################################################################################

msg()
{
echo "$1" "$2" 1>&3
}

get_platform()
{
local arch=$1
[ -z "${arch}" ] && arch=$(uname -m)
case "${arch}" in
arm*|aarch64)
	echo "arm"
;;
i[3-6]86|x86*|amd64)
	echo "intel"
;;
*)
	echo "unknown"
esac
}

multiarch_support()
{
local binfmt_dir=""
if [ -d "/proc/sys/fs/binfmt_misc" ]; then
	binfmt_dir="/proc/sys/fs/binfmt_misc"
elif [ -e "/proc/modules" -a "$(grep -c ^binfmt_misc /proc/modules)" -ne 0 ]; then
	binfmt_dir="/data/local/binfmt_misc"
fi
if [ -n "${binfmt_dir}" ]; then
	echo ${binfmt_dir}
	return 0
else
	return 1
fi
}

selinux_support()
{
if [ -e "/sys/fs/selinux" ]; then
	return 0
else
	return 1
fi
}

loop_support()
{
if [ -n "$(losetup -f)" ]; then
	return 0
else
	return 1
fi
}

container_mounted()
{
local is_mnt=$(grep -c " ${MNT_TARGET} " /proc/mounts)
[ "${is_mnt}" -eq 0 ] && return 1 || return 0
}

ssh_started()
{
local is_started=""
for f in /var/run/sshd.pid /run/sshd.pid
do
	local pidfile="${MNT_TARGET}${f}"
	local pid=$([ -e "${pidfile}" ] && cat ${pidfile})
	if [ -n "${pid}" ]; then
		is_started=$(ps | awk '{if ($1 == '${pid}') print $1}')
		[ -n "${is_started}" ] && return 0
	fi
done
return 1
}

gui_started()
{
local is_started=""
local pidfile="${MNT_TARGET}/tmp/xsession.pid"
local pid=$([ -e "${pidfile}" ] && cat ${pidfile})
[ -n "${pid}" ] && is_started=$(ps | awk '{if ($1 == '${pid}') print $1}')
[ -z "${is_started}" ] && return 1 || return 0
}

prepare_container()
{
container_mounted && { msg "The container is already mounted."; return 1; }

msg -n "Checking installation path ... "
case "${DEPLOY_TYPE}" in
file)
	if [ -e "${IMG_TARGET}" -a ! -f "${IMG_TARGET}" ]; then
		msg "fail"; return 1
	fi
;;
partition)
	if [ ! -b "${IMG_TARGET}" ]; then
		msg "fail"; return 1
	fi
;;
directory|ram)
	if [ -e "${IMG_TARGET}" -a ! -d "${IMG_TARGET}" ]; then
		msg "fail"; return 1
	fi
;;
esac
msg "done"

if [ "${DEPLOY_TYPE}" = "file" ]; then
	if [ "${IMG_SIZE}" -eq 0 ]; then
		local file_size=0
		[ -f "${IMG_TARGET}" ] && file_size=$(stat -c %s ${IMG_TARGET})
		local dir_name=$(dirname ${IMG_TARGET})
		local block_size=$(stat -c %s -f ${dir_name})
		local available_size=$(stat -c %a -f ${dir_name})
		let available_size="(${block_size}*${available_size})+${file_size}"
		let IMG_SIZE="(${available_size}-${available_size}/10)/1048576"
		[ "${IMG_SIZE}" -gt 4095 ] && IMG_SIZE=4095
		[ "${IMG_SIZE}" -lt 512 ] && IMG_SIZE=512
	fi
	msg -n "Making new disk image (${IMG_SIZE} MB) ... "
	dd if=/dev/zero of=${IMG_TARGET} bs=1048576 seek=$(expr ${IMG_SIZE} - 1) count=1 ||
	dd if=/dev/zero of=${IMG_TARGET} bs=1048576 count=${IMG_SIZE}
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }
fi

if [ "${DEPLOY_TYPE}" = "file" -o "${DEPLOY_TYPE}" = "partition" ]; then
	local fs_support=""
	for fs in ext4 ext3 ext2
	do
		if [ "$(grep -c ${fs} /proc/filesystems)" -gt 0 ]; then
			fs_support=${fs}
			break
		fi
	done
	[ -z "${fs_support}" ] && { msg "The filesystems ext2, ext3 or ext4 is not supported."; return 1; }
	[ "${FS_TYPE}" = "auto" ] && FS_TYPE=${fs_support}

	msg -n "Making file system (${FS_TYPE}) ... "
	local loop_exist=$(losetup -a | grep -c ${IMG_TARGET})
	local img_mounted=$(grep -c ${IMG_TARGET} /proc/mounts)
	[ "${loop_exist}" -ne 0 -o "${img_mounted}" -ne 0 ] && { msg "fail"; return 1; }
	mke2fs -qF -t ${FS_TYPE} -O ^has_journal ${IMG_TARGET}
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }
fi

if [ "${DEPLOY_TYPE}" = "ram" ]; then
	umount ${IMG_TARGET}
	if [ "${IMG_SIZE}" -eq 0 ]; then
		local ram_free=$(grep ^MemFree /proc/meminfo | awk '{print $2}')
		let IMG_SIZE="${ram_free}/1024"
	fi
	msg -n "Making new disk image (${IMG_SIZE} MB) ... "
	[ -d "${IMG_TARGET}" ] || mkdir ${IMG_TARGET}
	mount -t tmpfs -o size=${IMG_SIZE}M tmpfs ${IMG_TARGET}
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }
fi

return 0
}

mount_part()
{
case "$1" in
root)
	msg -n "/ ... "
	local is_mnt=$(grep -c " ${MNT_TARGET} " /proc/mounts)
	if [ "${is_mnt}" -eq 0 ]; then
		[ -d "${MNT_TARGET}" ] || mkdir -p ${MNT_TARGET}
		[ -d "${IMG_TARGET}" ] && local mnt_opts="bind" || local mnt_opts="rw,relatime"
		mount -o ${mnt_opts} ${IMG_TARGET} ${MNT_TARGET}
		[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }
	else
		msg "skip"
	fi
;;
proc)
	msg -n "/proc ... "
	local target=${MNT_TARGET}/proc
	local is_mnt=$(grep -c " ${target} " /proc/mounts)
	if [ "${is_mnt}" -eq 0 ]; then
		[ -d "${target}" ] || mkdir -p ${target}
		mount -t proc proc ${target}
		[ $? -eq 0 ] && msg "done" || msg "fail"
	else
		msg "skip"
	fi
;;
sys)
	msg -n "/sys ... "
	local target=${MNT_TARGET}/sys
	local is_mnt=$(grep -c " ${target} " /proc/mounts)
	if [ "${is_mnt}" -eq 0 ]; then
		[ -d "${target}" ] || mkdir -p ${target}
		mount -t sysfs sys ${target}
		[ $? -eq 0 ] && msg "done" || msg "fail"
	else
		msg "skip"
	fi
;;
selinux)
	selinux_support || return 0
	msg -n "/sys/fs/selinux ... "
	local target=${MNT_TARGET}/sys/fs/selinux
	local is_mnt=$(grep -c " ${target} " /proc/mounts)
	if [ "${is_mnt}" -eq 0 ]; then
		if [ -e "/sys/fs/selinux/enforce" ]; then
			cat /sys/fs/selinux/enforce > ${ENV_DIR%/}/etc/selinux_state
			echo 0 > /sys/fs/selinux/enforce
		fi
		mount -t selinuxfs selinuxfs ${target} &&
		mount -o remount,ro,bind ${target}
		[ $? -eq 0 ] && msg "done" || msg "fail"
	else
		msg "skip"
	fi
;;
dev)
	msg -n "/dev ... "
	local target=${MNT_TARGET}/dev
	local is_mnt=$(grep -c " ${target} " /proc/mounts)
	if [ "${is_mnt}" -eq 0 ]; then
		[ -d "${target}" ] || mkdir -p ${target}
		[ -e "/dev/fd" ] || ln -s /proc/self/fd /dev/
		[ -e "/dev/stdin" ] || ln -s /proc/self/fd/0 /dev/stdin
		[ -e "/dev/stdout" ] || ln -s /proc/self/fd/1 /dev/stdout
		[ -e "/dev/stderr" ] || ln -s /proc/self/fd/2 /dev/stderr
		mount -o bind /dev ${target}
		[ $? -eq 0 ] && msg "done" || msg "fail"
	else
		msg "skip"
	fi
;;
tty)
	msg -n "/dev/tty ... "
	if [ ! -e "/dev/tty0" ]; then
		ln -s /dev/null /dev/tty0
		[ $? -eq 0 ] && msg "done" || msg "fail"
	else
		msg "skip"
	fi
;;
pts)
	msg -n "/dev/pts ... "
	local target=${MNT_TARGET}/dev/pts
	local is_mnt=$(grep -c " ${target} " /proc/mounts)
	if [ "${is_mnt}" -eq 0 ]; then
		[ -d "${target}" ] || mkdir -p ${target}
		mount -o "mode=0620,gid=5" -t devpts devpts ${target}
		[ $? -eq 0 ] && msg "done" || msg "fail"
	else
		msg "skip"
	fi
;;
shm)
	msg -n "/dev/shm ... "
	local target=${MNT_TARGET}/dev/shm
	local is_mnt=$(grep -c " ${target} " /proc/mounts)
	if [ "${is_mnt}" -eq 0 ]; then
		[ -d "${target}" ] || mkdir -p ${target}
		mount -t tmpfs tmpfs ${target}
		[ $? -eq 0 ] && msg "done" || msg "fail"
	else
		msg "skip"
	fi
;;
binfmt_misc)
	local binfmt_dir=$(multiarch_support)
	[ -n "${binfmt_dir}" ] || return 0
	msg -n "${binfmt_dir} ... "
	[ -e "${binfmt_dir}" ] || mkdir ${binfmt_dir}
	[ -e "${binfmt_dir}/register" ] || mount -t binfmt_misc binfmt_misc ${binfmt_dir}
	case "$(get_platform)" in
	arm)
		if [ ! -e "${binfmt_dir}/qemu-i386" ]; then
			echo ':qemu-i386:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00:\xff\xff\xff\xff\xff\xfe\xfe\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/local/bin/qemu-i386-static:' > ${binfmt_dir}/register
			[ $? -eq 0 ] && msg "done" || msg "fail"
		else
			msg "skip"
		fi
	;;
	intel)
		if [ ! -e "${binfmt_dir}/qemu-arm" ]; then
			echo ':qemu-arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/local/bin/qemu-arm-static:' > ${binfmt_dir}/register
			[ $? -eq 0 ] && msg "done" || msg "fail"
		else
			msg "skip"
		fi
	;;
	*)
		msg "skip"
	;;
	esac
;;
custom)
	for disk in ${CUSTOM_MOUNTS}
	do
		local disk_name=$(basename /root/${disk})
		msg -n "/mnt/${disk_name} ... "
		local target=${MNT_TARGET}/mnt/${disk_name}
		local is_mnt=$(grep -c " ${target} " /proc/mounts)
		if [ "${is_mnt}" -eq 0 ]; then
			if [ -d "${disk}" ]; then
				[ -d "${target}" ] || mkdir -p ${target}
				mount -o bind ${disk} ${target}
				[ $? -eq 0 ] && msg "done" || msg "fail"
			elif [ -e "${disk}" ]; then
				[ -d "${target}" ] || mkdir -p ${target}
				mount -o rw,relatime ${disk} ${target}
				[ $? -eq 0 ] && msg "done" || msg "fail"
			else
				msg "skip"
			fi
		else
			msg "skip"
		fi
	done
;;
esac

return 0
}

mount_container()
{
if [ $# -eq 0 ]; then
	mount_container root proc sys selinux dev tty pts shm binfmt_misc custom
	[ $? -ne 0 ] && return 1
else
	msg "Mounting partitions: "
	for i in $*
	do
		mount_part $i
		[ $? -ne 0 ] && return 1
	done
fi

return 0
}

umount_container()
{
container_mounted || { msg "The container is not mounted." ; return 0; }

msg -n "Release resources ... "
local is_release=0
local lsof_full=$(lsof | awk '{print $1}' | grep -c '^lsof')
for i in 1 2 3
do
	if [ "${lsof_full}" -eq 0 ]; then
		local pids=$(lsof | grep ${MNT_TARGET} | awk '{print $1}' | uniq)
	else
		local pids=$(lsof | grep ${MNT_TARGET} | awk '{print $2}' | uniq)
	fi
	if [ -n "${pids}" ]; then
		kill -9 ${pids}
		sleep 1
	else
		is_release=1
		break
	fi
done
[ "${is_release}" -eq 1 ] && msg "done" || msg "fail"

msg "Unmounting partitions: "
local is_mounted=0
for i in '.*' '*'
do
	local parts=$(cat /proc/mounts | awk '{print $2}' | grep "^${MNT_TARGET}/${i}$" | sort -r)
	for p in ${parts}
	do
		local pp=$(echo ${p} | sed "s|^${MNT_TARGET}/*|/|g")
		msg -n "${pp} ... "
		local selinux=$(echo ${pp} | grep -ci "selinux")
		if [ "${selinux}" -gt 0 -a -e "/sys/fs/selinux/enforce" -a -e "${ENV_DIR%/}/etc/selinux_state" ]; then
			cat ${ENV_DIR%/}/etc/selinux_state > /sys/fs/selinux/enforce
		fi
		umount ${p}
		[ $? -eq 0 ] && msg "done" || msg "fail"
		is_mounted=1
	done
done
local binfmt_dir=$(multiarch_support)
if [ -n "${binfmt_dir}" ]; then
	local binfmt_qemu=""
	case "$(get_platform)" in
	arm)
		binfmt_qemu="${binfmt_dir}/qemu-i386"
	;;
	intel)
		binfmt_qemu="${binfmt_dir}/qemu-arm"
	;;
	esac
	if [ -e "${binfmt_qemu}" ]; then
		msg -n "${binfmt_dir} ... "
		echo -1 > ${binfmt_qemu}
		[ $? -eq 0 ] && msg "done" || msg "fail"
		is_mounted=1
	fi
fi
[ "${is_mounted}" -ne 1 ] && msg " ...nothing mounted"

msg -n "Disassociating loop device ... "
local loop=$(losetup -a | grep ${IMG_TARGET} | awk -F: '{print $1}')
if [ -n "${loop}" ]; then
	losetup -d ${loop}
fi
[ $? -eq 0 ] && msg "done" || msg "fail"

return 0
}

start_container()
{
if [ $# -eq 0 ]; then
	mount_container
	[ $? -ne 0 ] && return 1

	configure_container dns mtab

	msg "Starting services: "

	for i in ${STARTUP}
	do
		start_container ${i}
		[ $? -eq 0 ] || return 1
	done

	[ -z "${STARTUP}" ] && msg "...no active services"

	return 0
fi

dbus_init()
{
# dbus (Debian/Ubuntu/Arch Linux/Kali Linux)
[ -e "${MNT_TARGET}/run/dbus/pid" ] && rm ${MNT_TARGET}/run/dbus/pid
# dbus (Fedora)
[ -e "${MNT_TARGET}/var/run/messagebus.pid" ] && rm ${MNT_TARGET}/var/run/messagebus.pid
chroot ${MNT_TARGET} dbus-daemon --system --fork
}

case "$1" in
ssh)
	msg -n "SSH [:${SSH_PORT}] ... "
	ssh_started && { msg "skip"; return 0; }
	# prepare var
	[ -e "${MNT_TARGET}/var/run" -a ! -e "${MNT_TARGET}/var/run/sshd" ] && mkdir ${MNT_TARGET}/var/run/sshd
	[ -e "${MNT_TARGET}/run" -a ! -e "${MNT_TARGET}/run/sshd" ] && mkdir ${MNT_TARGET}/run/sshd
	# generate keys
	if [ -z "$(ls ${MNT_TARGET}/etc/ssh/ | grep key)" ]; then
		chroot ${MNT_TARGET} su - root -c 'ssh-keygen -A'
		echo
	fi
	# exec sshd
	local sshd='`which sshd`'
	chroot ${MNT_TARGET} su - root -c "${sshd} -p ${SSH_PORT}"
	[ $? -eq 0 ] && msg "done" || msg "fail"
;;
vnc)
	local vncport=5900
	let vncport=${vncport}+${VNC_DISPLAY}
	msg -n "VNC [:${vncport}] ... "
	gui_started && { msg "skip"; return 0; }
	dbus_init
	# remove locks
	[ -e "${MNT_TARGET}/tmp/.X${VNC_DISPLAY}-lock" ] && rm ${MNT_TARGET}/tmp/.X${VNC_DISPLAY}-lock
	[ -e "${MNT_TARGET}/tmp/.X11-unix/X${VNC_DISPLAY}" ] && rm ${MNT_TARGET}/tmp/.X11-unix/X${VNC_DISPLAY}
	# exec vncserver
	chroot ${MNT_TARGET} su - ${USER_NAME} -c "vncserver :${VNC_DISPLAY} -depth ${VNC_DEPTH} -geometry ${VNC_GEOMETRY} -dpi ${VNC_DPI} ${VNC_ARGS}"
	[ $? -eq 0 ] && msg "done" || msg "fail"
;;
xserver)
	msg -n "X Server [${XSERVER_HOST}:${XSERVER_DISPLAY}] ... "
	gui_started && { msg "skip"; return 0; }
	dbus_init
	chroot ${MNT_TARGET} su - ${USER_NAME} -c "export DISPLAY=${XSERVER_HOST}:${XSERVER_DISPLAY}; ~/.xinitrc &"
	[ $? -eq 0 ] && msg "done" || msg "fail"
;;
framebuffer)
	msg -n "Framebuffer [:${FB_DISPLAY}] ... "
	gui_started && { msg "skip"; return 0; }
	# update xorg.conf
	sed -i "s|Option.*\"fbdev\".*#linuxdeploy|Option \"fbdev\" \"${FB_DEV}\" #linuxdeploy|g" ${MNT_TARGET}/etc/X11/xorg.conf
	sed -i "s|Option.*\"Device\".*#linuxdeploy|Option \"Device\" \"${FB_INPUT}\" #linuxdeploy|g" ${MNT_TARGET}/etc/X11/xorg.conf
	dbus_init
	(set -e
		sync
		case "${FB_FREEZE}" in
		stop)
			setprop ctl.stop surfaceflinger
			chroot ${MNT_TARGET} su - ${USER_NAME} -c "xinit -- :${FB_DISPLAY} -dpi ${FB_DPI} ${FB_ARGS}"
			sync
			reboot
		;;
		pause)
			pkill -STOP system_server
			pkill -STOP surfaceflinger
			chroot ${MNT_TARGET} su - ${USER_NAME} -c "xinit -- :${FB_DISPLAY} -dpi ${FB_DPI} ${FB_ARGS}"
			pkill -CONT surfaceflinger
			pkill -CONT system_server
		;;
		*)
			chroot ${MNT_TARGET} su - ${USER_NAME} -c "xinit -- :${FB_DISPLAY} -dpi ${FB_DPI} ${FB_ARGS} &"
		;;
		esac
	exit 0)
	[ $? -eq 0 ] && msg "done" || msg "fail"
;;
custom)
	for script in ${CUSTOM_SCRIPTS}
	do
		msg -n "${script} ... "
		chroot ${MNT_TARGET} su - root -c "${script} start"
		[ $? -eq 0 ] && msg "done" || msg "fail"
	done
;;
esac

return 0
}

stop_container()
{
container_mounted || { msg "The container is already stopped." ; return 0; }

if [ $# -eq 0 ]; then
	msg "Stopping services: "

	for i in ${STARTUP}
	do
		stop_container ${i}
		[ $? -eq 0 ] || return 1
	done

	[ -z "${STARTUP}" ] && msg "...no active services"

	umount_container
	[ $? -ne 0 ] && return 1 || return 0
fi

sshd_kill()
{
local pid=""
for path in /run/sshd.pid /var/run/sshd.pid
do
	if [ -e "${MNT_TARGET}${path}" ]; then
		pid=$(cat ${MNT_TARGET}${path})
		break
	fi
done
if [ -n "${pid}" ]; then
	kill -9 ${pid} || return 1
fi
return 0
}

xsession_kill()
{
local pid=""
if [ -e "${MNT_TARGET}/tmp/xsession.pid" ]; then
	pid=$(cat ${MNT_TARGET}/tmp/xsession.pid)
fi
if [ -n "${pid}" ]; then
	kill -9 ${pid} || return 1
fi
return 0
}

case "$1" in
ssh)
	msg -n "SSH ... "
	sshd_kill
	[ $? -eq 0 ] && msg "done" || msg "fail"
;;
vnc)
	msg -n "VNC ... "
	xsession_kill
	chroot ${MNT_TARGET} su - ${USER_NAME} -c "vncserver -kill :${VNC_DISPLAY}"
	[ $? -eq 0 ] && msg "done" || msg "fail"
;;
xserver)
	msg -n "X Server ... "
	xsession_kill
	[ $? -eq 0 ] && msg "done" || msg "fail"
;;
framebuffer)
	msg -n "Framebuffer ... "
	pkill -CONT surfaceflinger
	pkill -CONT system_server
	xsession_kill
	[ $? -eq 0 ] && msg "done" || msg "fail"
;;
custom)
	for script in ${CUSTOM_SCRIPTS}
	do
		msg -n "${script} ... "
		chroot ${MNT_TARGET} su - root -c "${script} stop"
		[ $? -eq 0 ] && msg "done" || msg "fail"
	done
;;
esac

return 0
}

chroot_container()
{
container_mounted || mount_container
[ $? -ne 0 ] && return 1

configure_container dns mtab

[ -e "${MNT_TARGET}/etc/motd" ] && msg "$(cat ${MNT_TARGET}/etc/motd)"

SHELL="$*"
if [ -z "${SHELL}" ]; then
	[ -e "${MNT_TARGET}/bin/sh" ] && SHELL=/bin/sh
	[ -e "${MNT_TARGET}/bin/bash" ] && SHELL=/bin/bash
fi
[ -z "${SHELL}" ] && { msg "Shell not found."; return 1; }

USER="root"
HOME=$(grep -m1 "^${USER}:" ${MNT_TARGET}/etc/passwd | awk -F: '{print $6}')
LANG=${LOCALE}
PS1="\u@\h:\w\\$ "
export PATH TERM SHELL USER HOME LANG PS1

chroot ${MNT_TARGET} ${SHELL} 1>&3 2>&3
[ $? -ne 0 ] && return 1

return 0
}

configure_part()
{
msg -n "$1 ... "
(set -e
	case "$1" in
	dns)
		if [ -z "${SERVER_DNS}" ]; then
			local dns1=$(getprop net.dns1 || true)
			local dns2=$(getprop net.dns2 || true)
			local dns_list="${dns1} ${dns2}"
			[ -z "${dns1}" -a -z "${dns2}" ] && dns_list="8.8.8.8"
		else
			local dns_list=$(echo ${SERVER_DNS} | tr ',;' ' ')
		fi
		printf '' > ${MNT_TARGET}/etc/resolv.conf
		for dns in ${dns_list}
		do
			echo "nameserver ${dns}" >> ${MNT_TARGET}/etc/resolv.conf
		done
	;;
	mtab)
		rm -f ${MNT_TARGET}/etc/mtab || true
		grep ${MNT_TARGET} /proc/mounts | sed "s|${MNT_TARGET}/*|/|g" > ${MNT_TARGET}/etc/mtab
	;;
	motd)
		local linux_version="GNU/Linux (${DISTRIB})"
		if [ -f ${MNT_TARGET}/etc/os-release ]
		then
			linux_version=$(. ${MNT_TARGET}/etc/os-release; echo ${PRETTY_NAME})
		elif [ -f ${MNT_TARGET}/etc/arch-release ]
		then
			linux_version="Arch Linux"
		elif [ -f ${MNT_TARGET}/etc/gentoo-release ]
		then
			linux_version=$(cat ${MNT_TARGET}/etc/gentoo-release)
		elif [ -f ${MNT_TARGET}/etc/fedora-release ]
		then
			linux_version=$(cat ${MNT_TARGET}/etc/fedora-release)
		elif [ -f ${MNT_TARGET}/etc/redhat-release ]
		then
			linux_version=$(cat ${MNT_TARGET}/etc/redhat-release)
		elif [ -f ${MNT_TARGET}/etc/debian_version ]
		then
			linux_version=$(printf "Debian GNU/Linux " ; cat ${MNT_TARGET}/etc/debian_version)
		fi
		local motd="${linux_version} [running on Android via Linux Deploy]"
		rm -f ${MNT_TARGET}/etc/motd || true
		echo ${motd} > ${MNT_TARGET}/etc/motd
	;;
	hosts)
		local is_localhost=$(grep -c "^127.0.0.1" ${MNT_TARGET}/etc/hosts || true)
		[ "${is_localhost}" -eq 0 ] && echo '127.0.0.1 localhost' >> ${MNT_TARGET}/etc/hosts
	;;
	hostname)
		echo 'localhost' > ${MNT_TARGET}/etc/hostname
	;;
	timezone)
		local timezone=$(getprop persist.sys.timezone || true)
		[ -z "${timezone}" ] && timezone=$(cat /etc/timezone)
		[ -z "${timezone}" ] && exit 1
		rm -f ${MNT_TARGET}/etc/localtime || true
		cp ${MNT_TARGET}/usr/share/zoneinfo/${timezone} ${MNT_TARGET}/etc/localtime
		echo ${timezone} > ${MNT_TARGET}/etc/timezone
	;;
	su)
		case "${DISTRIB}" in
		fedora|opensuse)
			local pam_su="${MNT_TARGET}/etc/pam.d/su-l"
		;;
		*)
			local pam_su="${MNT_TARGET}/etc/pam.d/su"
		;;
		esac
		if [ -e "${pam_su}" -a -z "$(grep -e '^auth.*sufficient.*pam_succeed_if.so uid = 0 use_uid quiet$' ${pam_su})" ]; then
			sed -i '1,/^auth/s/^\(auth.*\)$/auth\tsufficient\tpam_succeed_if.so uid = 0 use_uid quiet\n\1/' ${pam_su}
		fi
	;;
	sudo)
		local sudo_str="${USER_NAME} ALL=(ALL:ALL) NOPASSWD:ALL"
		local is_str=$(grep -c "${sudo_str}" ${MNT_TARGET}/etc/sudoers || true)
		[ "${is_str}" -eq 0 ] && echo ${sudo_str} >> ${MNT_TARGET}/etc/sudoers
		chmod 440 ${MNT_TARGET}/etc/sudoers
	;;
	groups)
		local aids=$(cat ${ENV_DIR%/}/share/android-groups)
		for aid in ${aids}
		do
			local xname=$(echo ${aid} | awk -F: '{print $1}')
			local xid=$(echo ${aid} | awk -F: '{print $2}')
			sed -i "s|^${xname}:.*|${xname}:x:${xid}:${USER_NAME}|g" ${MNT_TARGET}/etc/group || true
			local is_group=$(grep -c "^${xname}:" ${MNT_TARGET}/etc/group || true)
			[ "${is_group}" -eq 0 ] && echo "${xname}:x:${xid}:${USER_NAME}" >> ${MNT_TARGET}/etc/group
			local is_passwd=$(grep -c "^${xname}:" ${MNT_TARGET}/etc/passwd || true)
			[ "${is_passwd}" -eq 0 ] && echo "${xname}:x:${xid}:${xid}::/:/bin/false" >> ${MNT_TARGET}/etc/passwd
			sed -i 's|^UID_MIN.*|UID_MIN 5000|g' ${MNT_TARGET}/etc/login.defs
			sed -i 's|^GID_MIN.*|GID_MIN 5000|g' ${MNT_TARGET}/etc/login.defs
		done
		# add users to aid_inet group
		local inet_users=""
		case "${DISTRIB}" in
		debian|ubuntu|kalilinux)
			inet_users="root messagebus www-data mysql postgres"
		;;
		archlinux)
			inet_users="root dbus"
		;;
		fedora)
			inet_users="root dbus"
		;;
		opensuse)
			inet_users="root messagebus"
		;;
		gentoo)
			inet_users="root messagebus"
		;;
		slackware)
			inet_users="root messagebus"
		;;
		esac
		for uid in ${inet_users}
		do
			if [ -z "$(grep \"^aid_inet:.*${uid}\" ${MNT_TARGET}/etc/group)" ]; then
				sed -i "s|^\(aid_inet:.*\)|\1,${uid}|g" ${MNT_TARGET}/etc/group
			fi
		done
	;;
	locales)
		local inputfile=$(echo ${LOCALE} | awk -F. '{print $1}')
		local charmapfile=$(echo ${LOCALE} | awk -F. '{print $2}')
		chroot ${MNT_TARGET} localedef -i ${inputfile} -c -f ${charmapfile} ${LOCALE}
		case "${DISTRIB}" in
		debian|ubuntu|kalilinux)
			echo "LANG=${LOCALE}" > ${MNT_TARGET}/etc/default/locale
		;;
		archlinux)
			echo "LANG=${LOCALE}" > ${MNT_TARGET}/etc/locale.conf
		;;
		fedora)
			echo "LANG=${LOCALE}" > ${MNT_TARGET}/etc/sysconfig/i18n
		;;
		opensuse)
			echo "RC_LANG=${LOCALE}" > ${MNT_TARGET}/etc/sysconfig/language
		;;
		slackware)
			sed -i "s|^export LANG=.*|export LANG=${LOCALE}|g" ${MNT_TARGET}/etc/profile.d/lang.sh
		;;
		esac
	;;
	repository)
		local platform=$(get_platform ${ARCH})
		case "${DISTRIB}" in
		debian|ubuntu|kalilinux)
			if [ -e "${MNT_TARGET}/etc/apt/sources.list" ]; then
				cp ${MNT_TARGET}/etc/apt/sources.list ${MNT_TARGET}/etc/apt/sources.list.bak
			fi
			if [ -z "$(grep "${MIRROR}.*${SUITE}" ${MNT_TARGET}/etc/apt/sources.list)" ]; then
				case "${DISTRIB}" in
				debian|kalilinux)
					echo "deb ${MIRROR} ${SUITE} main contrib non-free" > ${MNT_TARGET}/etc/apt/sources.list
					echo "deb-src ${MIRROR} ${SUITE} main contrib non-free" >> ${MNT_TARGET}/etc/apt/sources.list
				;;
				ubuntu)
					echo "deb ${MIRROR} ${SUITE} main universe multiverse" > ${MNT_TARGET}/etc/apt/sources.list
					echo "deb-src ${MIRROR} ${SUITE} main universe multiverse" >> ${MNT_TARGET}/etc/apt/sources.list
				;;
				esac
			fi
		;;
		archlinux)
			if [ "${platform}" = "intel" ]
			then local repo="${MIRROR%/}/\$repo/os/\$arch"
			else local repo="${MIRROR%/}/\$arch/\$repo"
			fi
			sed -i "s|^[[:space:]]*Architecture[[:space:]]*=.*$|Architecture = ${ARCH}|" ${MNT_TARGET}/etc/pacman.conf
			sed -i "s|^[[:space:]]*\(CheckSpace\)|#\1|" ${MNT_TARGET}/etc/pacman.conf
			sed -i "s|^[[:space:]]*SigLevel[[:space:]]*=.*$|SigLevel = Never|" ${MNT_TARGET}/etc/pacman.conf
			if [ $(grep -c -e "^[[:space:]]*Server" ${MNT_TARGET}/etc/pacman.d/mirrorlist) -gt 0 ]
			then sed -i "s|^[[:space:]]*Server[[:space:]]*=.*|Server = ${repo}|" ${MNT_TARGET}/etc/pacman.d/mirrorlist
			else echo "Server = ${repo}" >> ${MNT_TARGET}/etc/pacman.d/mirrorlist
			fi
		;;
		fedora)
			find ${MNT_TARGET}/etc/yum.repos.d/ -name *.repo | while read f; do sed -i 's/^enabled=.*/enabled=0/g' ${f}; done
			if [ "${platform}" = "intel" -o "${ARCH}" != "aarch64" -a "${SUITE}" -ge 20 ]
			then local repo="${MIRROR%/}/fedora/linux/releases/${SUITE}/Everything/${ARCH}/os"
			else local repo="${MIRROR%/}/fedora-secondary/releases/${SUITE}/Everything/${ARCH}/os"
			fi
			local repo_file="${MNT_TARGET}/etc/yum.repos.d/fedora-${SUITE}-${ARCH}.repo"
			echo "[fedora-${SUITE}-${ARCH}]" > ${repo_file}
			echo "name=Fedora ${SUITE} - ${ARCH}" >> ${repo_file}
			echo "failovermethod=priority" >> ${repo_file}
			echo "baseurl=${repo}" >> ${repo_file}
			echo "enabled=1" >> ${repo_file}
			echo "metadata_expire=7d" >> ${repo_file}
			echo "gpgcheck=0" >> ${repo_file}
			chmod 644 ${repo_file}
		;;
		opensuse)
			if [ "${platform}" = "intel" ]
			then local repo="${MIRROR%/}/distribution/${SUITE}/repo/oss/"
			else local repo="${MIRROR%/}/${ARCH}/distribution/${SUITE}/repo/oss/"
			fi
			local repo_name="openSUSE-${SUITE}-${ARCH}-Repo-OSS"
			local repo_file="${MNT_TARGET}/etc/zypp/repos.d/${repo_name}.repo"
			echo "[${repo_name}]" > ${repo_file}
			echo "name=${repo_name}" >> ${repo_file}
			echo "enabled=1" >> ${repo_file}
			echo "autorefresh=0" >> ${repo_file}
			echo "baseurl=${repo}" >> ${repo_file}
			echo "type=NONE" >> ${repo_file}
			chmod 644 ${repo_file}
		;;
		gentoo)
			if [ -z "$(grep '^aid_inet:.*,portage' ${MNT_TARGET}/etc/group)" ]; then
				sed -i "s|^\(aid_inet:.*\)|\1,portage|g" ${MNT_TARGET}/etc/group
			fi
			# set MAKEOPTS
			local ncpu=$(grep -c ^processor /proc/cpuinfo)
			let ncpu=${ncpu}+1
			if [ -z "$(grep '^MAKEOPTS=' ${MNT_TARGET}/etc/portage/make.conf)" ]; then
				echo "MAKEOPTS=\"-j${ncpu}\"" >> ${MNT_TARGET}/etc/portage/make.conf
			fi
		;;
		slackware)
			if [ -e "${MNT_TARGET}/etc/slackpkg/mirrors" ]; then
				cp ${MNT_TARGET}/etc/slackpkg/mirrors ${MNT_TARGET}/etc/slackpkg/mirrors.bak
			fi
			echo ${MIRROR} > ${MNT_TARGET}/etc/slackpkg/mirrors
			chmod 644 ${MNT_TARGET}/etc/slackpkg/mirrors
			sed -i 's|^WGETFLAGS=.*|WGETFLAGS="--passive-ftp -q"|g' ${MNT_TARGET}/etc/slackpkg/slackpkg.conf
		;;
		esac
	;;
	profile)
		local reserved=$(echo ${USER_NAME} | grep ^aid_ || true)
		if [ -n "${reserved}" ]; then
			echo "Username ${USER_NAME} is reserved."
			exit 1
		fi
		# cli
		if [ "${USER_NAME}" != "root" ]; then
			chroot ${MNT_TARGET} groupadd ${USER_NAME} || true
			chroot ${MNT_TARGET} useradd -m -g ${USER_NAME} -s /bin/bash ${USER_NAME} || true
			chroot ${MNT_TARGET} usermod -g ${USER_NAME} ${USER_NAME} || true
		fi
		local user_home=$(grep -m1 "^${USER_NAME}:" ${MNT_TARGET}/etc/passwd | awk -F: '{print $6}')
		local user_id=$(grep -m1 "^${USER_NAME}:" ${MNT_TARGET}/etc/passwd | awk -F: '{print $3}')
		local group_id=$(grep -m1 "^${USER_NAME}:" ${MNT_TARGET}/etc/passwd | awk -F: '{print $4}')
		local path_str="PATH=${PATH}"
		local is_path=$(grep "${path_str}" ${MNT_TARGET}${user_home}/.profile || true)
		[ -z "${is_path}" ] && echo ${path_str} >> ${MNT_TARGET}${user_home}/.profile
		# gui
		mkdir ${MNT_TARGET}${user_home}/.vnc || true
		echo 'XAUTHORITY=$HOME/.Xauthority' > ${MNT_TARGET}${user_home}/.vnc/xstartup
		echo 'export XAUTHORITY' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
		echo "LANG=$LOCALE" >> ${MNT_TARGET}${user_home}/.vnc/xstartup
		echo 'export LANG' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
		echo 'echo $$ > /tmp/xsession.pid' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
		case "${DESKTOP_ENV}" in
		xterm)
			echo 'xterm -max' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
		;;
		lxde)
			echo 'startlxde' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
		;;
		xfce)
			echo 'startxfce4' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
		;;
		gnome)
			echo 'XKL_XMODMAP_DISABLE=1' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
			echo 'export XKL_XMODMAP_DISABLE' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
			echo 'if [ -n "`gnome-session -h | grep "\-\-session"`" ]; then' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
			echo '   gnome-session --session=gnome' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
			echo 'else' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
			echo '   gnome-session' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
			echo 'fi' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
		;;
		kde)
			echo 'startkde' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
		;;
		other)
			echo '# desktop environment' >> ${MNT_TARGET}${user_home}/.vnc/xstartup
		;;
		esac
		chmod 755 ${MNT_TARGET}${user_home}/.vnc/xstartup
		rm ${MNT_TARGET}${user_home}/.xinitrc || true
		ln -s ./.vnc/xstartup ${MNT_TARGET}${user_home}/.xinitrc
		# set password for user
		chroot ${MNT_TARGET} sh -c "printf '%s\n' ${USER_PASSWORD} ${USER_PASSWORD} | passwd ${USER_NAME}"
		chroot ${MNT_TARGET} sh -c "echo ${USER_PASSWORD} | vncpasswd -f > ${user_home}/.vnc/passwd" ||
		echo "MPTcXfgXGiY=" | base64 -d > ${MNT_TARGET}${user_home}/.vnc/passwd
		chmod 600 ${MNT_TARGET}${user_home}/.vnc/passwd
		# set permissions
		chown -R ${user_id}:${group_id} ${MNT_TARGET}${user_home} || true
	;;
	dbus)
		case "${DISTRIB}" in
		debian|ubuntu|kalilinux|archlinux)
			mkdir ${MNT_TARGET}/run/dbus || true
			chmod 755 ${MNT_TARGET}/run/dbus
		;;
		fedora)
			mkdir ${MNT_TARGET}/var/run/dbus || true
			chmod 755 ${MNT_TARGET}/var/run/dbus
			chroot ${MNT_TARGET} sh -c "dbus-uuidgen > /etc/machine-id"
		;;
		esac
	;;
	xorg)
		# Xwrapper.config
		mkdir -p ${MNT_TARGET}/etc/X11
		if [ -n "$(grep -e '^allowed_users' ${MNT_TARGET}/etc/X11/Xwrapper.config)" ]; then
			sed -i 's/^allowed_users=.*/allowed_users=anybody/g' ${MNT_TARGET}/etc/X11/Xwrapper.config
		else
			echo "allowed_users=anybody" >> ${MNT_TARGET}/etc/X11/Xwrapper.config
		fi
		# xorg.conf
		mkdir -p ${MNT_TARGET}/etc/X11
		local xorg_conf="${MNT_TARGET}/etc/X11/xorg.conf"
		[ -e "${xorg_conf}" ] && cp ${xorg_conf} ${xorg_conf}.bak
		cp ${ENV_DIR%/}/share/xorg.conf ${xorg_conf}
		chmod 644 ${xorg_conf}
		# specific configuration
		case "${DISTRIB}" in
		gentoo)
			# set Xorg make configuration
			if [ -z "$(grep '^INPUT_DEVICES=' ${MNT_TARGET}/etc/portage/make.conf)" ]; then
				echo 'INPUT_DEVICES="evdev"' >> ${MNT_TARGET}/etc/portage/make.conf
			else
				sed -i 's|^\(INPUT_DEVICES=\).*|\1"evdev"|g' ${MNT_TARGET}/etc/portage/make.conf
			fi
			if [ -z "$(grep '^VIDEO_CARDS=' ${MNT_TARGET}/etc/portage/make.conf)" ]; then
				echo 'VIDEO_CARDS="fbdev"' >> ${MNT_TARGET}/etc/portage/make.conf
			else
				sed -i 's|^\(VIDEO_CARDS=\).*|\1"fbdev"|g' ${MNT_TARGET}/etc/portage/make.conf
			fi
		;;
		opensuse)
			[ -e "${MNT_TARGET}/usr/bin/Xorg" ] && chmod +s ${MNT_TARGET}/usr/bin/Xorg
		;;
		esac
	;;
	qemu)
		multiarch_support || exit 0
		local platform=$(get_platform)
		case "${platform}" in
		arm)
			local qemu_static=$(which qemu-i386-static)
			local qemu_target=${MNT_TARGET%/}/usr/local/bin/qemu-i386-static
		;;
		intel)
			local qemu_static=$(which qemu-arm-static)
			local qemu_target=${MNT_TARGET%/}/usr/local/bin/qemu-arm-static
		;;
		*)
			exit 0
		;;
		esac
		[ -e "${qemu_target}" ] && exit 0
		[ -z "${qemu_static}" ] && exit 1
		mkdir -p ${MNT_TARGET%/}/usr/local/bin || true
		cp ${qemu_static} ${qemu_target}
		chown 0:0 ${qemu_target}
		chmod 755 ${qemu_target}
	;;
	unchroot)
		local unchroot=${MNT_TARGET}/bin/unchroot
		echo '#!/bin/sh' > ${unchroot}
		echo "PATH=${PATH}" >> ${unchroot}
		echo 'if [ $# -eq 0 ]; then' >> ${unchroot}
		echo 'chroot /proc/1/cwd su -' >> ${unchroot}
		echo 'else' >> ${unchroot}
		echo 'chroot /proc/1/cwd $*' >> ${unchroot}
		echo 'fi' >> ${unchroot}
		chmod 755 ${unchroot}
	;;
	android)
		[ -e "/system" ] || exit 0
		[ ! -L "${MNT_TARGET}/system" ] && ln -s /mnt/system ${MNT_TARGET}/system
		local reboot=$(which reboot)
		if [ -n "${reboot}" ]; then
			rm ${MNT_TARGET}/sbin/reboot || true
			ln -s ${reboot} ${MNT_TARGET}/sbin/reboot
		fi
		local shutdown=$(which shutdown)
		if [ -n "${shutdown}" ]; then
			rm ${MNT_TARGET}/sbin/shutdown || true
			ln -s ${shutdown} ${MNT_TARGET}/sbin/shutdown
		fi
	;;
	misc)
		# Fix for upstart (Ubuntu)
		if [ -e "${MNT_TARGET}/sbin/initctl" ]; then
			chroot ${MNT_TARGET} dpkg-divert --local --rename --add /sbin/initctl
			chroot ${MNT_TARGET} ln -s /bin/true /sbin/initctl
		fi
		# Fix for yum (Fedora)
		if [ -e "${MNT_TARGET}/usr/bin/yum-deprecated" ]; then
			rm ${MNT_TARGET}/usr/bin/yum || true
			echo '#!/bin/sh' > ${MNT_TARGET}/usr/bin/yum
			echo '/usr/bin/yum-deprecated $*' >> ${MNT_TARGET}/usr/bin/yum
			chmod 755 ${MNT_TARGET}/usr/bin/yum
		fi
	;;
	esac
exit 0)
[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }

return 0
}

configure_container()
{
if [ $# -eq 0 ]; then
	configure_container qemu dns mtab motd hosts hostname timezone su sudo groups locales repository profile dbus xorg unchroot android misc
	[ $? -ne 0 ] && return 1

	install_components
	[ $? -ne 0 ] && return 1
else 
	container_mounted || mount_container
	[ $? -ne 0 ] && return 1

	msg "Configuring the container: "
	for i in $*
	do
		configure_part $i
	done

	return 0
fi

return 0
}

install_components()
{
[ -z "${USE_COMPONENTS}" ] && return 1

msg "Installing additional components: "
(set -e
	case "${DISTRIB}" in
	debian|ubuntu|kalilinux)
		local pkgs=""
		selinux_support && pkgs="${pkgs} selinux-basics"
		for component in ${USE_COMPONENTS}
		do
			case "${component}" in
			desktop)
				pkgs="${pkgs} desktop-base x11-xserver-utils xfonts-base xfonts-utils"
				[ "${DISTRIB}" = "kalilinux" ] && pkgs="${pkgs} kali-defaults kali-menu"
				case "${DESKTOP_ENV}" in
				xterm)
					pkgs="${pkgs} xterm"
				;;
				lxde)
					pkgs="${pkgs} lxde menu-xdg hicolor-icon-theme gtk2-engines"
				;;
				xfce)
					pkgs="${pkgs} xfce4 xfce4-terminal tango-icon-theme hicolor-icon-theme"
				;;
				gnome)
					pkgs="${pkgs} gnome-core"
				;;
				kde)
					pkgs="${pkgs} kde-standard"
				;;
				esac
			;;
			ssh)
				pkgs="${pkgs} openssh-server"
			;;
			vnc)
				pkgs="${pkgs} tightvncserver"
			;;
			xserver)
				pkgs="${pkgs} xinit xserver-xorg xserver-xorg-video-fbdev xserver-xorg-input-evdev"
			;;
			kali-linux)
				pkgs="${pkgs} kali-linux-top10"
			;;
			esac
		done
		[ -z "$pkgs" ] && return 1
		export DEBIAN_FRONTEND=noninteractive
		chroot ${MNT_TARGET} apt-get update -yq
		chroot ${MNT_TARGET} apt-get install -yf
		chroot ${MNT_TARGET} apt-get install ${pkgs} --no-install-recommends -yq
		chroot ${MNT_TARGET} apt-get clean
	;;
	archlinux)
		local pkgs=""
		for component in ${USE_COMPONENTS}
		do
			case "${component}" in
			desktop)
				pkgs="${pkgs} xorg-utils xorg-fonts-misc ttf-dejavu"
				case "${DESKTOP_ENV}" in
				xterm)
					pkgs="${pkgs} xterm"
				;;
				lxde)
					pkgs="${pkgs} lxde gtk-engines"
				;;
				xfce)
					pkgs="${pkgs} xfce4"
				;;
				gnome)
					pkgs="${pkgs} gnome"
				;;
				kde)
					pkgs="${pkgs} kdebase"
				;;
				esac
			;;
			ssh)
				pkgs="${pkgs} openssh"
			;;
			vnc)
				pkgs="${pkgs} tigervnc"
			;;
			xserver)
				pkgs="${pkgs} xorg-xinit xorg-server xf86-video-fbdev xf86-input-evdev"
			;;
			esac
		done
		[ -z "${pkgs}" ] && return 1
		#rm -f ${MNT_TARGET}/var/lib/pacman/db.lck || true
		chroot ${MNT_TARGET} pacman -Syq --noconfirm ${pkgs}
		rm -f ${MNT_TARGET}/var/cache/pacman/pkg/* || true
	;;
	fedora)
		local pkgs=""
		local igrp=""
		for component in ${USE_COMPONENTS}
		do
			case "${component}" in
			desktop)
				pkgs="${pkgs} xorg-x11-server-utils xorg-x11-fonts-misc dejavu-*"
				case "${DESKTOP_ENV}" in
				xterm)
					pkgs="${pkgs} xterm"
				;;
				lxde)
					igrp="lxde-desktop"
				;;
				xfce)
					igrp="xfce-desktop"
				;;
				gnome)
					igrp="gnome-desktop"
				;;
				kde)
					igrp="kde-desktop"
				;;
				esac
			;;
			ssh)
				pkgs="${pkgs} openssh-server"
			;;
			vnc)
				pkgs="${pkgs} tigervnc-server"
			;;
			xserver)
				pkgs="${pkgs} xorg-x11-xinit xorg-x11-server-Xorg xorg-x11-drv-fbdev xorg-x11-drv-evdev"
			;;
			esac
		done
		[ -z "${pkgs}" ] && return 1
		chroot ${MNT_TARGET} yum install ${pkgs} --nogpgcheck --skip-broken -y
		[ -n "${igrp}" ] && chroot ${MNT_TARGET} yum groupinstall "${igrp}" --nogpgcheck --skip-broken -y
		chroot ${MNT_TARGET} yum clean all
	;;
	opensuse)
		local pkgs=""
		for component in ${USE_COMPONENTS}
		do
			case "${component}" in
			desktop)
				pkgs="${pkgs} xorg-x11-fonts-core dejavu-fonts xauth"
				case "${DESKTOP_ENV}" in
				xterm)
					pkgs="${pkgs} xterm"
				;;
				lxde)
					pkgs="${pkgs} patterns-openSUSE-lxde"
				;;
				xfce)
					pkgs="${pkgs} patterns-openSUSE-xfce"
				;;
				gnome)
					pkgs="${pkgs} patterns-openSUSE-gnome"
				;;
				kde)
					pkgs="${pkgs} patterns-openSUSE-kde"
				;;
				esac
			;;
		ssh)
				pkgs="${pkgs} openssh"
			;;
			vnc)
				pkgs="${pkgs} tightvnc"
			;;
			xserver)
				pkgs="${pkgs} xinit xorg-x11-server xf86-video-fbdev xf86-input-evdev"
			;;
			esac
		done
		[ -z "${pkgs}" ] && return 1
		chroot ${MNT_TARGET} zypper --no-gpg-checks --non-interactive install ${pkgs}
		chroot ${MNT_TARGET} zypper clean
	;;
	gentoo)
		local pkgs=""
		for component in ${USE_COMPONENTS}
		do
			case "${component}" in
			desktop)
				pkgs="${pkgs} xauth"
				case "${DESKTOP_ENV}" in
				xterm)
					pkgs="${pkgs} xterm"
				;;
				lxde)
					pkgs="${pkgs} lxde-meta gtk-engines"
				;;
				xfce)
					pkgs="${pkgs} xfce4-meta"
				;;
				gnome)
					pkgs="${pkgs} gnome"
				;;
				kde)
					pkgs="${pkgs} kde-meta"
				;;
				esac
			;;
			ssh)
				pkgs="${pkgs} openssh"
			;;
			vnc)
				# set server USE flag for tightvnc
				if [ -z "$(grep '^net-misc/tightvnc' ${MNT_TARGET}/etc/portage/package.use)" ]; then
					echo "net-misc/tightvnc server" >> ${MNT_TARGET}/etc/portage/package.use
				fi
				if [ -z "$(grep '^net-misc/tightvnc.*server' ${MNT_TARGET}/etc/portage/package.use)" ]; then
					sed -i "s|^\(net-misc/tightvnc.*\)|\1 server|g" ${MNT_TARGET}/etc/portage/package.use
				fi
				pkgs="${pkgs} tightvnc"
			;;
			xserver)
				pkgs="${pkgs} xinit xorg-server"
			;;
			esac
		done
		[ -z "${pkgs}" ] && return 1
		chroot ${MNT_TARGET} emerge --autounmask-write ${pkgs} || {
			mv ${MNT_TARGET}/etc/portage/._cfg0000_package.use ${MNT_TARGET}/etc/portage/package.use
			chroot ${MNT_TARGET} emerge ${pkgs}
		}
	;;
	slackware)
		local pkgs=""
		for component in ${USE_COMPONENTS}
		do
			case "${component}" in
			ssh)
				pkgs="${pkgs} openssh"
			;;
			esac
		done
		[ -z "${pkgs}" ] && return 1
		chroot ${MNT_TARGET} slackpkg update || true
		chroot ${MNT_TARGET} slackpkg -checkgpg=off -batch=on -default_answer=y install ${pkgs}
	;;
	*)
		msg " ...not supported"
		exit 1
	;;
	esac
exit 0) 1>&3 2>&3
[ $? -ne 0 ] && return 1

return 0
}

install_container()
{
prepare_container
[ $? -ne 0 ] && return 1

mount_container root binfmt_misc
[ $? -ne 0 ] && return 1

case "${DISTRIB}" in
debian|ubuntu|kalilinux)
	msg "Installing Debian-based distribution: "

	local basic_packages="locales,sudo,man-db"

	(set -e
		DEBOOTSTRAP_DIR=${ENV_DIR%/}/share/debootstrap
		. ${DEBOOTSTRAP_DIR}/debootstrap --no-check-gpg --arch ${ARCH} --foreign --extractor=ar --include=${basic_packages} ${SUITE} ${MNT_TARGET} ${MIRROR}
	exit 0) 1>&3 2>&3
	[ $? -ne 0 ] && return 1

	configure_container qemu dns mtab

	unset DEBOOTSTRAP_DIR
	chroot ${MNT_TARGET} /debootstrap/debootstrap --second-stage 1>&3 2>&3
	[ $? -ne 0 ] && return 1

	mount_container
;;
archlinux)
	msg "Installing Arch Linux distribution: "

	local basic_packages="filesystem acl archlinux-keyring attr bash bzip2 ca-certificates coreutils cracklib curl db e2fsprogs expat findutils gawk gcc-libs gdbm glibc gmp gnupg gpgme grep keyutils krb5 libarchive libassuan libcap libgcrypt libgpg-error libgssglue libidn libksba libldap libsasl libssh2 libtirpc linux-api-headers lzo ncurses nettle openssl pacman pacman-mirrorlist pam pambase perl pinentry pth readline run-parts sed shadow sudo tzdata util-linux xz which zlib"

	local platform=$(get_platform ${ARCH})
	if [ "${platform}" = "intel" ]
	then local repo="${MIRROR%/}/core/os/${ARCH}"
	else local repo="${MIRROR%/}/${ARCH}/core"
	fi

	local cache_dir="${MNT_TARGET}/var/cache/pacman/pkg"

	msg "Repository: ${repo}"

	msg -n "Preparing for deployment ... "
	(set -e
		cd ${MNT_TARGET}
		mkdir etc
		echo "root:x:0:0:root:/root:/bin/bash" > etc/passwd
		echo "root:x:0:" > etc/group
		touch etc/fstab
		mkdir tmp; chmod 01777 tmp
		mkdir -p ${cache_dir}
	exit 0)
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }

	msg -n "Retrieving packages list ... "
	local pkg_list=$(wget -q -O - "${repo}/" | sed -n '/<a / s/^.*<a [^>]*href="\([^\"]*\)".*$/\1/p' | awk -F'/' '{print $NF}' | sort -rn)
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }

	msg "Retrieving base packages: "
	for package in ${basic_packages}; do
		msg -n "${package} ... "
		local pkg_file=$(echo "${pkg_list}" | grep -m1 -e "^${package}-[[:digit:]].*\.xz$" -e "^${package}-[[:digit:]].*\.gz$")
		test "${pkg_file}" || { msg "fail"; return 1; }
		# download
		for i in 1 2 3
		do
			[ ${i} -gt 1 ] && sleep 30s
			wget -q -c -O ${cache_dir}/${pkg_file} ${repo}/${pkg_file}
			[ $? -eq 0 ] && break
		done
		# unpack
		case "${pkg_file}" in
		*.gz) tar xzf ${cache_dir}/${pkg_file} -C ${MNT_TARGET};;
		*.xz) xz -dc ${cache_dir}/${pkg_file} | tar x -C ${MNT_TARGET};;
		*) msg "fail"; return 1;;
		esac
		[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }
	done

	mount_container

	configure_container qemu dns mtab repository

	msg "Installing base packages: "
	(set -e
		chroot ${MNT_TARGET} /usr/bin/pacman --noconfirm -Sy
		extra_packages=$(chroot ${MNT_TARGET} /usr/bin/pacman --noconfirm -Sg base | awk '{print $2}' | grep -v -e 'linux' -e 'kernel')
		chroot ${MNT_TARGET} /usr/bin/pacman --noconfirm --force -Sq ${basic_packages} ${extra_packages}
	exit 0) 1>&3 2>&3
	[ $? -ne 0 ] && return 1

	msg -n "Clearing cache ... "
	(set -e
		rm -f ${cache_dir}/* $(find ${MNT_TARGET} -type f -name "*.pacorig")
	exit 0)
	[ $? -eq 0 ] && msg "done" || msg "fail"
;;
fedora)
	msg "Installing Fedora distribution: "

	local basic_packages="filesystem audit-libs basesystem bash bzip2-libs ca-certificates chkconfig coreutils cpio cracklib cracklib-dicts crypto-policies cryptsetup-libs curl cyrus-sasl-lib dbus dbus-libs device-mapper device-mapper-libs diffutils elfutils-libelf elfutils-libs expat fedora-release fedora-repos file-libs fipscheck fipscheck-lib gamin gawk gdbm glib2 glibc glibc-common gmp gnupg2 gnutls gpgme grep gzip hwdata info keyutils-libs kmod kmod-libs krb5-libs libacl libarchive libassuan libattr libblkid libcap libcap-ng libcom_err libcurl libdb libdb4 libdb-utils libffi libgcc libgcrypt libgpg-error libidn libmetalink libmicrohttpd libmount libpwquality libseccomp libselinux libselinux-utils libsemanage libsepol libsmartcols libssh2 libstdc++ libtasn1 libuser libutempter libuuid libverto libxml2 lua lzo man-pages ncurses ncurses-base ncurses-libs nettle nspr nss nss-myhostname nss-softokn nss-softokn-freebl nss-sysinit nss-tools nss-util openldap openssl-libs p11-kit p11-kit-trust pam pcre pinentry pkgconfig policycoreutils popt pth pygpgme pyliblzma python python-chardet python-iniparse python-kitchen python-libs python-pycurl python-six python-urlgrabber pyxattr qrencode-libs readline rootfiles rpm rpm-build-libs rpm-libs rpm-plugin-selinux rpm-python sed selinux-policy setup shadow-utils shared-mime-info sqlite sudo systemd systemd-libs systemd-sysv tcp_wrappers-libs trousers tzdata ustr util-linux vim-minimal xz-libs yum yum-metadata-parser yum-utils which zlib"

	local platform=$(get_platform ${ARCH})
	if [ "${platform}" = "intel" -o "${ARCH}" != "aarch64" -a "${SUITE}" -ge 20 ]
	then local repo="${MIRROR%/}/fedora/linux/releases/${SUITE}/Everything/${ARCH}/os"
	else local repo="${MIRROR%/}/fedora-secondary/releases/${SUITE}/Everything/${ARCH}/os"
	fi

	msg "Repository: ${repo}"

	msg -n "Preparing for deployment ... "
	(set -e
		cd ${MNT_TARGET}
		mkdir etc
		echo "root:x:0:0:root:/root:/bin/bash" > etc/passwd
		echo "root:x:0:" > etc/group
		touch etc/fstab
		mkdir tmp; chmod 01777 tmp
	exit 0)
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }

	msg -n "Retrieving packages list ... "
	local pkg_list="${MNT_TARGET}/tmp/packages.list"
	(set -e
		repodata=$(wget -q -O - ${repo}/repodata | sed -n '/<a / s/^.*<a [^>]*href="\([^\"]*\-primary\.xml\.gz\)".*$/\1/p')
		[ -z "${repodata}" ] && exit 1
		wget -q -O - ${repo}/repodata/${repodata} | gzip -dc | sed -n '/<location / s/^.*<location [^>]*href="\([^\"]*\)".*$/\1/p' > ${pkg_list}
	exit 0)
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }

	msg "Retrieving base packages: "
	for package in ${basic_packages}; do
		msg -n "${package} ... "
		local pkg_url=$(grep -m1 -e "^.*/${package}-[0-9][0-9\.\-].*\.rpm$" ${pkg_list})
		test "${pkg_url}" || { msg "skip"; continue; }
		local pkg_file=$(basename ${pkg_url})
		# download
		for i in 1 2 3
		do
			[ ${i} -gt 1 ] && sleep 30s
			wget -q -c -O ${MNT_TARGET}/tmp/${pkg_file} ${repo}/${pkg_url}
			[ $? -eq 0 ] && break
		done
		# unpack
		(cd ${MNT_TARGET}; rpm2cpio ${MNT_TARGET}/tmp/${pkg_file} | cpio -idmu)
		[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }
	done

	configure_container qemu

	msg "Installing base packages: "
	chroot ${MNT_TARGET} /bin/rpm -iv --force --nosignature --nodeps /tmp/*.rpm 1>&3 2>&3
	msg -n "Updating packages database ... "
	chroot ${MNT_TARGET} /bin/rpm -i --force --nosignature --nodeps --justdb /tmp/*.rpm
	[ $? -eq 0 ] && msg "done" || msg "fail"
	# clean cache
	rm -rf ${MNT_TARGET}/tmp/*

	mount_container

	configure_container dns mtab misc repository

	msg "Installing minimal environment: "
	(set -e
		chroot ${MNT_TARGET} yum groupinstall minimal-environment --nogpgcheck --skip-broken -y --exclude openssh-server
		chroot ${MNT_TARGET} yum clean all
	exit 0) 1>&3 2>&3
	[ $? -ne 0 ] && return 1
;;
opensuse)
	msg "Installing openSUSE distribution: "

	local basic_packages=""
	case "${SUITE}" in
	12.3) basic_packages="filesystem aaa_base aaa_base-extras autoyast2-installation bash bind-libs bind-utils branding-openSUSE bridge-utils bzip2 coreutils cpio cracklib cracklib-dict-full cron cronie cryptsetup curl cyrus-sasl dbus-1 dbus-1-x11 device-mapper dhcpcd diffutils dirmngr dmraid e2fsprogs elfutils file fillup findutils fontconfig gawk gio-branding-openSUSE glib2-tools glibc glibc-extra glibc-i18ndata glibc-locale gnu-unifont-bitmap-fonts-20080123 gpg2 grep groff gzip hwinfo ifplugd info initviocons iproute2 iputils-s20101006 kbd kpartx krb5 less-456 libX11-6 libX11-data libXau6 libXext6 libXft2 libXrender1 libacl1 libadns1 libaio1 libasm1 libassuan0 libattr1 libaudit1 libaugeas0 libblkid1 libbz2-1 libcairo2 libcap-ng0 libcap2 libcom_err2 libcrack2 libcryptsetup4 libcurl4 libdaemon0 libdb-4_8 libdbus-1-3 libdrm2 libdw1 libedit0 libelf0 libelf1 libestr0 libexpat1 libext2fs2 libffi4 libfreetype6 libgcc_s1 libgcrypt11 libgdbm4 libgio-2_0-0 libglib-2_0-0 libgmodule-2_0-0 libgmp10 libgnutls28 libgobject-2_0-0 libgpg-error0 libgssglue1 libharfbuzz0 libhogweed2 libicu49 libidn11 libiw30 libjson0 libkeyutils1 libkmod2-12 libksba8 libldap-2_4-2 liblua5_1 liblzma5 libmagic1 libmicrohttpd10 libmodman1 libmount1 libncurses5 libncurses6 libnettle4 libnl3-200 libopenssl1_0_0 libp11-kit0 libpango-1_0-0 libparted0 libpci3 libpcre1 libpipeline1 libpixman-1-0 libply-boot-client2 libply-splash-core2 libply-splash-graphics2 libply2 libpng15-15 libpolkit0 libpopt0 libprocps1 libproxy1 libpth20 libpython2_7-1_0 libqrencode3 libreadline6 libreiserfs-0_3-0 libselinux1 libsemanage1 libsepol1 libsolv-tools libssh2-1 libstdc++6 libstorage4 libtasn1 libtasn1-6 libtirpc1 libudev1-195 libusb-0_1-4 libusb-1_0-0 libustr-1_0-1 libuuid1 libwrap0 libxcb-render0 libxcb-shm0 libxcb1 libxml2-2 libxtables9 libyui-ncurses-pkg4 libyui-ncurses4 libyui4 libz1 libzio1 libzypp logrotate lsscsi lvm2 man man-pages mdadm mkinitrd module-init-tools multipath-tools ncurses-utils net-tools netcfg openSUSE-build-key openSUSE-release-12.3 openSUSE-release-ftp-12.3 openslp openssl pam pam-config pango-tools parted pciutils pciutils-ids perl perl-Bootloader perl-Config-Crontab perl-XML-Parser perl-XML-Simple perl-base perl-gettext permissions pinentry pkg-config polkit procps python-base rpcbind rpm rsyslog sed shadow shared-mime-info sudo suse-module-tools sysconfig sysfsutils syslog-service systemd-195 systemd-presets-branding-openSUSE systemd-sysvinit-195 sysvinit-tools tar tcpd terminfo-base timezone-2012j tunctl u-boot-tools udev-195 unzip update-alternatives util-linux vim vim-base vlan wallpaper-branding-openSUSE wireless-tools wpa_supplicant xz yast2 yast2-bootloader yast2-core yast2-country yast2-country-data yast2-firstboot yast2-hardware-detection yast2-installation yast2-packager yast2-perl-bindings yast2-pkg-bindings yast2-proxy yast2-slp yast2-storage yast2-trans-stats yast2-transfer yast2-update yast2-xml yast2-ycp-ui-bindings zypper"
	;;
	13.2) basic_packages="filesystem aaa_base aaa_base-extras autoyast2-installation bash bind-libs bind-utils branding-openSUSE bridge-utils bzip2 coreutils cpio cracklib cracklib-dict-full cron cronie cryptsetup curl cyrus-sasl dbus-1 dbus-1-x11 device-mapper dhcpcd diffutils dirmngr dmraid e2fsprogs elfutils file fillup findutils fontconfig gawk gio-branding-openSUSE glib2-tools glibc glibc-extra glibc-i18ndata glibc-locale gnu-unifont-bitmap-fonts-20080123 gpg2 grep groff gzip hwinfo ifplugd info initviocons iproute2 iputils-s20121221 kbd kpartx krb5 less-458 libX11-6 libX11-data libXau6 libXext6 libXft2 libXrender1 libacl1 libadns1 libaio1 libasm1 libassuan0 libattr1 libaudit1 libaugeas0 libblkid1 libbz2-1 libcairo2 libcap-ng0 libcap2 libcom_err2 libcrack2 libcryptsetup4 libcurl4 libdaemon0 libdb-4_8 libdbus-1-3 libdrm2 libdw1 libedit0 libelf0 libelf1 libestr0 libexpat1 libext2fs2 libffi4 libfreetype6 libgcc_s1 libgcrypt20 libgdbm4 libgio-2_0-0 libglib-2_0-0 libgmodule-2_0-0 libgmp10 libgnutls28 libgobject-2_0-0 libgpg-error0 libgssglue1 libharfbuzz0 libhogweed2 libicu53_1 libidn11 libiw30 libjson-c2 libkeyutils1 libkmod2-18 libksba8 libldap-2_4-2 liblua5_1 liblua5_2 liblzma5 libmagic1 libmicrohttpd10 libmodman1 libmount1 libncurses5 libncurses6 libnettle4 libnl3-200 libopenssl1_0_0 libp11-kit0 libpango-1_0-0 libparted0 libpci3 libpcre1 libpipeline1 libpixman-1-0 libply-boot-client2 libply-splash-core2 libply-splash-graphics2 libply2 libpng16-16 libpolkit0 libpopt0 libprocps3 libproxy1 libpth20 libpython2_7-1_0 libqrencode3 libreadline6 libreiserfs-0_3-0 libsasl2-3 libselinux1 libsemanage1 libsepol1 libsolv-tools libssh2-1 libstdc++6 libstorage5 libtasn1 libtasn1-6 libtirpc1 libudev1-210 libusb-0_1-4 libusb-1_0-0 libustr-1_0-1 libuuid1 libwrap0 libxcb-render0 libxcb-shm0 libxcb1 libxml2-2 libxtables10 libyui-ncurses-pkg6 libyui-ncurses6 libyui6 libz1 libzio1 libzypp logrotate lsscsi lvm2 man man-pages mdadm multipath-tools ncurses-utils net-tools netcfg openSUSE-build-key openSUSE-release-13.2 openSUSE-release-ftp-13.2 openslp openssl pam pam-config pango-tools parted pciutils pciutils-ids perl perl-Bootloader perl-Config-Crontab perl-XML-Parser perl-XML-Simple perl-base perl-gettext permissions pinentry pkg-config polkit procps python-base rpcbind rpm rsyslog sed shadow shared-mime-info sudo suse-module-tools sysconfig sysfsutils syslog-service systemd-210 systemd-presets-branding-openSUSE systemd-sysvinit-210 sysvinit-tools tar tcpd terminfo-base timezone-2014h tunctl u-boot-tools udev-210 unzip update-alternatives util-linux vim vlan wallpaper-branding-openSUSE which wireless-tools wpa_supplicant xz yast2 yast2-bootloader yast2-core yast2-country yast2-country-data yast2-firstboot yast2-hardware-detection yast2-installation yast2-packager yast2-perl-bindings yast2-pkg-bindings yast2-proxy yast2-slp yast2-storage yast2-trans-stats yast2-transfer yast2-update yast2-xml yast2-ycp-ui-bindings zypper"
	;;
	esac

	local platform=$(get_platform ${ARCH})
	if [ "${platform}" = "intel" ]
	then local repo="${MIRROR%/}/distribution/${SUITE}/repo/oss/suse"
	else local repo="${MIRROR%/}/${ARCH}/distribution/${SUITE}/repo/oss/suse"
	fi

	msg "Repository: ${repo}"

	msg -n "Preparing for deployment ... "
	(set -e
		cd ${MNT_TARGET}
		mkdir etc
		echo "root:x:0:0:root:/root:/bin/bash" > etc/passwd
		echo "root:x:0:" > etc/group
		touch etc/fstab
		mkdir tmp; chmod 01777 tmp
	exit 0)
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }

	msg -n "Retrieving packages list ... "
	local pkg_list="$MNT_TARGET/tmp/packages.list"
	(set -e
		repodata=$(wget -q -O - ${repo}/repodata | sed -n '/<a / s/^.*<a [^>]*href="\([^\"]*\-primary\.xml\.gz\)".*$/\1/p')
		[ -z "${repodata}" ] && exit 1
		wget -q -O - ${repo}/repodata/${repodata} | gzip -dc | sed -n '/<location / s/^.*<location [^>]*href="\([^\"]*\)".*$/\1/p' > ${pkg_list}
	exit 0)
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }

	msg "Retrieving base packages: "
	for package in ${basic_packages}; do
		msg -n "${package} ... "
		local pkg_url=$(grep -e "^${ARCH}" -e "^noarch" ${pkg_list} | grep -m1 -e "/${package}-[0-9]\{1,4\}\..*\.rpm$")
		test "${pkg_url}" || { msg "fail"; return 1; }
		local pkg_file=$(basename ${pkg_url})
		# download
		for i in 1 2 3
		do
			[ ${i} -gt 1 ] && sleep 30s
			wget -q -c -O ${MNT_TARGET}/tmp/${pkg_file} ${repo}/${pkg_url}
			[ $? -eq 0 ] && break
		done
		# unpack
		(cd ${MNT_TARGET}; rpm2cpio ${MNT_TARGET}/tmp/${pkg_file} | cpio -idmu)
		[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }
	done

	configure_container qemu

	msg "Installing base packages: "
	chroot ${MNT_TARGET} /bin/rpm -iv --force --nosignature --nodeps /tmp/*.rpm 1>&3 2>&3
	[ $? -ne 0 ] && return 1
	# clean cache
	rm -rf ${MNT_TARGET}/tmp/*

	mount_container
;;
gentoo)
	msg "Installing Gentoo distribution: "

	msg -n "Preparing for deployment ... "
	(set -e
		cd ${MNT_TARGET}
		mkdir tmp; chmod 01777 tmp
	exit 0)
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }

	msg -n "Getting repository path ... "
	local repo="${MIRROR%/}/autobuilds"
	local stage3="${MNT_TARGET}/tmp/latest-stage3.tar.bz2"
	local archive=$(wget -q -O - "${repo}/latest-stage3-${ARCH}.txt" | grep -v ^# | awk '{print $1}')
	[ -n "${archive}" ] && msg "done" || { msg "fail"; return 1; }

	msg -n "Retrieving stage3 archive ... "
	for i in 1 2 3
	do
		[ ${i} -gt 1 ] && sleep 30s
		wget -c -O ${stage3} ${repo}/${archive}
		[ $? -eq 0 ] && break
	done
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }

	msg -n "Unpacking stage3 archive ... "
	(set -e
		tar xjpf ${stage3} -C ${MNT_TARGET}
		rm ${stage3}
	exit 0)
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }

	mount_container

	configure_container qemu dns mtab repository

	msg -n "Updating portage tree ... "
	(set -e
		chroot ${MNT_TARGET} emerge --sync
		chroot ${MNT_TARGET} eselect profile set 1
	exit 0) 1>/dev/null
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }

	msg "Installing base packages: "
	(set -e
		chroot ${MNT_TARGET} emerge sudo
	exit 0) 1>&3 2>&3
	[ $? -eq 0 ] || return 1

	msg -n "Updating configuration ... "
	find ${MNT_TARGET}/ -name "._cfg0000_*" | while read f; do mv "${f}" "$(echo ${f} | sed 's/._cfg0000_//g')"; done
	[ $? -eq 0 ] && msg "done" || msg "skip"
;;
slackware)
	msg "Installing Slackware distribution: "

	local repo=${MIRROR%/}/slackware
	local cache_dir=${MNT_TARGET}/tmp
	local extra_packages="l/glibc l/libtermcap l/ncurses ap/diffutils ap/groff ap/man ap/nano ap/slackpkg ap/sudo n/gnupg n/wget"

	msg -n "Preparing for deployment ... "
	(set -e
		cd ${MNT_TARGET}
		mkdir etc
		touch etc/fstab
		mkdir tmp; chmod 01777 tmp
	exit 0)
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }

	msg -n "Retrieving packages list ... "
	local basic_packages=$(wget -q -O - ${repo}/a/tagfile | grep -v -e 'kernel' -e 'efibootmgr' -e 'lilo' -e 'grub' | awk -F: '{if ($1!="") print "a/"$1}')
	local pkg_list="${cache_dir}/packages.list"
	wget -q -O - ${repo}/FILE_LIST | grep -o -e '/.*\.\tgz$' -e '/.*\.\txz$' > ${pkg_list}
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }

	msg "Retrieving base packages: "
	for package in ${basic_packages} ${extra_packages}; do
		msg -n "${package} ... "
		local pkg_url=$(grep -m1 -e "/${package}\-" ${pkg_list})
		test "${pkg_url}" || { msg "fail"; return 1; }
		local pkg_file=$(basename ${pkg_url})
		# download
		for i in 1 2 3
		do
			[ ${i} -gt 1 ] && sleep 30s
			wget -q -c -O ${cache_dir}/${pkg_file} ${repo}${pkg_url}
	    		[ $? -eq 0 ] && break
	    	done
		# unpack
		case "${pkg_file}" in
		*gz) tar xzf ${cache_dir}/${pkg_file} -C ${MNT_TARGET};;
		*xz) tar xJf ${cache_dir}/${pkg_file} -C ${MNT_TARGET};;
		*) msg "fail"; return 1;;
		esac
		[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }
		# install
		if [ -e "${MNT_TARGET}/install/doinst.sh" ]; then
			(cd ${MNT_TARGET}; . ./install/doinst.sh)
		fi
		if [ -e "${MNT_TARGET}/install" ]; then
			rm -rf ${MNT_TARGET}/install
		fi
	done

	msg -n "Clearing cache ... "
	rm -f ${cache_dir}/*
	[ $? -eq 0 ] && msg "done" || msg "fail"

	mount_container
;;
rootfs)
	msg "Getting and unpacking rootfs archive: "
	if [ -n "$(echo ${MIRROR} | grep -i 'gz$')" ]; then
		if [ -e "${MIRROR}" ]; then
			(set -e
				tar xzpvf "${MIRROR}" -C ${MNT_TARGET}
			exit 0) 1>&3 2>&3
			[ $? -eq 0 ] || return 1
		fi
		if [ -n "$(echo ${MIRROR} | grep -i '^http')" ]; then
			(set -e
				wget -q -O - "${MIRROR}" | tar xzpv -C ${MNT_TARGET}
			exit 0) 1>&3 2>&3
			[ $? -eq 0 ] || return 1
		fi
	fi
	if [ -n "$(echo ${MIRROR} | grep -i 'bz2$')" ]; then
		if [ -e "${MIRROR}" ]; then
			(set -e
				tar xjpvf "${MIRROR}" -C ${MNT_TARGET}
			exit 0) 1>&3 2>&3
			[ $? -eq 0 ] || return 1
		fi
		if [ -n "$(echo ${MIRROR} | grep -i '^http')" ]; then
			(set -e
				wget -q -O - "${MIRROR}" | tar xjpv -C ${MNT_TARGET}
			exit 0) 1>&3 2>&3
			[ $? -eq 0 ] || return 1
		fi
	fi
	if [ -n "$(echo ${MIRROR} | grep -i 'xz$')" ]; then
		if [ -e "${MIRROR}" ]; then
			(set -e
				tar xJpvf "${MIRROR}" -C ${MNT_TARGET}
			exit 0) 1>&3 2>&3
			[ $? -eq 0 ] || return 1
		fi
		if [ -n "$(echo ${MIRROR} | grep -i '^http')" ]; then
			(set -e
				wget -q -O - "${MIRROR}" | tar xJpv -C ${MNT_TARGET}
			exit 0) 1>&3 2>&3
			[ $? -eq 0 ] || return 1
		fi
	fi
	[ "$(ls ${MNT_TARGET} | wc -l)" -le 1 ] && { msg " ...installation failed."; return 1; }

	mount_container
;;
*)
	msg "This Linux distribution is not supported."
	return 1
;;
esac

configure_container
[ $? -ne 0 ] && return 1

return 0
}

export_container()
{
local rootfs_archive="$1"
[ -z "${rootfs_archive}" ] && { msg "Incorrect export parameters."; return 1; }

container_mounted || mount_container root
[ $? -ne 0 ] && return 1

case "${rootfs_archive}" in
*gz)
	msg -n "Exporting rootfs as tar.gz archive ... "
	tar cpzvf ${rootfs_archive} --one-file-system -C ${MNT_TARGET} .
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }
;;
*bz2)
	msg -n "Exporting rootfs as tar.bz2 archive ... "
	tar cpjvf ${rootfs_archive} --one-file-system -C ${MNT_TARGET} .
	[ $? -eq 0 ] && msg "done" || { msg "fail"; return 1; }
;;
*)
	msg "Incorrect filename, supported only gz or bz2 archives."
	return 1
;;
esac
}

status_container()
{
msg -n "Linux Deploy version: "
msg "$(cat ${ENV_DIR%/}/etc/version)"

msg -n "Device: "
msg "$(getprop ro.product.model || echo unknown)"

msg -n "Android: "
msg "$(getprop ro.build.version.release || echo unknown)"

msg -n "Architecture: "
msg "$(uname -m)"

msg -n "Kernel: "
msg "$(uname -r)"

msg -n "Memory: "
local mem_total=$(grep ^MemTotal /proc/meminfo | awk '{print $2}')
let mem_total=${mem_total}/1024
local mem_free=$(grep ^MemFree /proc/meminfo | awk '{print $2}')
let mem_free=${mem_free}/1024
msg "${mem_free}/${mem_total} MB"

msg -n "Swap: "
local swap_total=$(grep ^SwapTotal /proc/meminfo | awk '{print $2}')
let swap_total=${swap_total}/1024
local swap_free=$(grep ^SwapFree /proc/meminfo | awk '{print $2}')
let swap_free=${swap_free}/1024
msg "${swap_free}/${swap_total} MB"

msg -n "SELinux: "
selinux_support && msg "yes" || msg "no"

msg -n "Loop devices: "
loop_support && msg "yes" || msg "no"

msg -n "Support binfmt_misc: "
multiarch_support && msg "yes" || msg "no"

msg -n "Supported FS: "
local supported_fs=$(printf '%s ' $(grep -v nodev /proc/filesystems | sort))
msg "${supported_fs}"

msg -n "Mounted system: "
local linux_version=$([ -r "${MNT_TARGET}/etc/os-release" ] && . "${MNT_TARGET}/etc/os-release"; [ -n "${PRETTY_NAME}" ] && echo "${PRETTY_NAME}" || echo "unknown")
msg "${linux_version}"

msg "Running services: "
msg -n "* SSH: "
ssh_started && msg "yes" || msg "no"
msg -n "* GUI: "
gui_started && msg "yes" || msg "no"

msg "Mounted parts on Linux: "
local is_mounted=0
for i in $(grep ${MNT_TARGET} /proc/mounts | awk '{print $2}' | sed "s|${MNT_TARGET}/*|/|g")
do
	msg "* $i"
	local is_mounted=1
done
[ "${is_mounted}" -ne 1 ] && msg " ...nothing mounted"

msg "Available mount points: "
local is_mountpoints=0
for p in $(grep -v ${MNT_TARGET} /proc/mounts | grep ^/ | awk '{print $2":"$3}')
do
	local part=$(echo $p | awk -F: '{print $1}')
	local fstype=$(echo $p | awk -F: '{print $2}')
	local block_size=$(stat -c '%s' -f ${part})
	local available=$(stat -c '%a' -f ${part} | awk '{printf("%.1f",$1*'${block_size}'/1024/1024/1024)}')
	local total=$(stat -c '%b' -f ${part} | awk '{printf("%.1f",$1*'${block_size}'/1024/1024/1024)}')
	if [ -n "${available}" -a -n "${total}" ]; then
		msg "* ${part}: ${available}/${total} GB (${fstype})"
		is_mountpoints=1
	fi
done
[ "${is_mountpoints}" -ne 1 ] && msg " ...no mount points"

msg "Available partitions: "
local is_partitions=0
for i in /sys/block/*/dev
do
	if [ -f $i ]; then
		local devname=$(echo $i | sed -e 's@/dev@@' -e 's@.*/@@')
		[ -e "/dev/${devname}" ] && local devpath="/dev/${devname}"
		[ -e "/dev/block/${devname}" ] && local devpath="/dev/block/${devname}"
		[ -n "${devpath}" ] && local parts=$(fdisk -l ${devpath} | grep ^/dev/ | awk '{print $1}')
		for part in ${parts}
		do
			local size=$(fdisk -l ${part} | grep 'Disk.*bytes' | awk '{ sub(/,/,""); print $3" "$4}')
			local type=$(fdisk -l ${devpath} | grep ^${part} | tr -d '*' | awk '{str=$6; for (i=7;i<=10;i++) if ($i!="") str=str" "$i; printf("%s",str)}')
			msg "* ${part}: ${size} (${type})"
			local is_partitions=1
		done
	fi
done
[ "${is_partitions}" -ne 1 ] && msg " ...no available partitions"

echo "Configuration file: "
cat ${CONF_FILE}
}

load_conf()
{
if [ -r "$1" ]; then
	. $1
	[ $? -ne 0 ] && exit 1
else
	echo "Configuration file not found."
	exit 1
fi
}

helper()
{
local version=$(cat ${ENV_DIR%/}/etc/version)

cat <<EOF 1>&3
Linux Deploy ${version}
(c) 2012-2015 Anton Skshidlevsky, GPLv3

USAGE:
   linuxdeploy [OPTIONS] COMMAND [ARGS]

OPTIONS:
   -c FILE - configuration file
   -d - enable debug mode
   -t - enable trace mode

COMMANDS:
   prepare - create the disk image and make the file system
   install - begin a new installation of the distribution
   configure - configure or reconfigure a container
   mount - mount a container
   umount - unmount a container
   start - start services in the container
   stop - stop all services in the container
   shell [app] - execute application in the container, be default /bin/bash
   export <archive> - export the container as rootfs archive (tgz or tbz2)
   status - show information about the system

EOF
}

################################################################################

# init env
TERM="linux"
export PATH TERM
unset LD_PRELOAD
umask 0022

cd ${ENV_DIR}

true || { msg "Detected a problem with the operating environment."; exit 1; }

# load default config
CONF_FILE="${ENV_DIR%/}/etc/deploy.conf"
[ -e "${CONF_FILE}" ] && load_conf "${CONF_FILE}"

# parse options
while getopts :c:dt FLAG
do
	case ${FLAG} in
	c)
		CONF_FILE=${OPTARG}
		load_conf "${CONF_FILE}"
	;;
	d)
		DEBUG_MODE="y"
	;;
	t)
		TRACE_MODE="y"
	;;
	esac
done
shift $((OPTIND-1))

# exit if config not found
[ -e "${CONF_FILE}" ] || load_conf "${CONF_FILE}"

# log level
exec 3>&1
[ "${DEBUG_MODE}" != "y" -a "${TRACE_MODE}" != "y" ] && { exec 1>/dev/null; exec 2>/dev/null; }
[ "${TRACE_MODE}" = "y" ] && set -x

# exec command
case "$1" in
prepare)
	prepare_container
;;
install)
	install_container
;;
configure)
	configure_container
;;
mount)
	mount_container
;;
umount)
	umount_container
;;
start)
	start_container
;;
stop)
	stop_container
;;
shell)
	shift
	chroot_container "$*"
;;
export)
	export_container "$2"
;;
status)
	status_container
;;
*)
	helper
;;
esac
