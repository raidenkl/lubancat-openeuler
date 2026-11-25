#!/bin/bash -e
#
# LubanCat 板型识别（首启）：读 SARADC 硬件 ID -> 选 dtb / uEnv -> 重启一次生效
#
# 识别逻辑移植自厂商 SDK 的 debian12/overlay/etc/init.d/boot_init.sh，全系共用一份：
#   保留  board_info() 全 SoC 映射表 / get_index() 的 10-bit 与 12-bit 阈值表及 bc 判定 /
#         board_id() 的 ch2+ch3（rk3128 用 ch0+ch2）/ 直读 iio:device0，
#         以及选型后 ln -sf、touch 标记、reboot 的动作序列
#   剪掉  仅 Debian 才成立的段：apt install /boot/kerneldeb、apt-mark hold、
#         /dev/disk/by-partlabel 等待与 mount /boot、追加 fstab、oem/userdata 分区、
#         cp logo_kernel.bmp、service lightdm stop、init.d 的 LSB 头
#
# 路径变量默认值等于厂商硬编码值，仅为构建机离线验证留出注入点：
#   BOOT=/tmp/b IIO_BASE=/tmp/iio COMPAT_FILE=/tmp/compat \
#   BOARD_NAME_FILE=/tmp/n REBOOT_CMD=/bin/true ./board-init.sh
#

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ---- 路径（默认值 = 厂商硬编码值）----
BOOT=${BOOT:-/boot}
IIO_BASE=${IIO_BASE:-/sys/bus/iio/devices/iio:device0}
COMPAT_FILE=${COMPAT_FILE:-/proc/device-tree/compatible}
BOARD_NAME_FILE=${BOARD_NAME_FILE:-/etc/lubancat/board-name}
REBOOT_CMD=${REBOOT_CMD:-reboot}

board_info() {
	if [[ "$2" == "rk3128" ]]; then
		case $1 in
			0000)
				BOARD_NAME='LubanCat-0H'
				BOARD_DTB='rk3128-lubancat-0h.dtb'
				BOARD_uEnv='uEnvLubanCat0H.txt'
				;;
			*)
				echo "Device ID Error !!!"
				BOARD_NAME='LubanCat-RK3128'
				BOARD_DTB='rk3128-lubancat-generic.dtb'
				BOARD_uEnv='uEnvLubanCat.txt'
				;;
		esac
	elif [[ "$2" == "rk3528" ||  "$2" == "rk3528a" ]]; then
		case $1 in
			0001)
				BOARD_NAME='LubanCat-Q1'
				BOARD_DTB='rk3528-lubancat-q1.dtb'
				BOARD_uEnv='uEnvLubanCatQ1.txt'
				;;
			0002)
				BOARD_NAME='LubanCat-Q1IO'
				BOARD_DTB='rk3528-lubancat-q1io.dtb'
				BOARD_uEnv='uEnvLubanCatQ1IO.txt'
				;;
			0007)
				BOARD_NAME='LubanCat-Q1IO-test'
				BOARD_DTB='rk3528-lubancat-q1io-test.dtb'
				BOARD_uEnv='uEnvLubanCatQ1IO-test.txt'
				;;
			*)
				echo "Device ID Error !!!"
				BOARD_NAME='LubanCat-RK3528'
				BOARD_DTB='rk3528-lubancat-generic.dtb'
				BOARD_uEnv='uEnvLubanCat.txt'
				;;
		esac
	elif [[ "$2" == "rk3562" ]]; then
		case $1 in
			0000)
				BOARD_NAME='LubanCat-1HS'
				BOARD_DTB='rk3562-lubancat-1hs.dtb'
				BOARD_uEnv='uEnvLubanCat1HS.txt'
				;;
			0007)
				BOARD_NAME='LubanCat-1HS-test'
				BOARD_DTB='rk3562-lubancat-1hs-test.dtb'
				BOARD_uEnv='uEnvLubanCat1HS-test.txt'
				;;
			0100)
				BOARD_NAME='LubanCat-1HSI'
				BOARD_DTB='rk3562-lubancat-1hs.dtb'
				BOARD_uEnv='uEnvLubanCat1HS.txt'
				;;
			0107)
				BOARD_NAME='LubanCat-1HS-test'
				BOARD_DTB='rk3562-lubancat-1hs-test.dtb'
				BOARD_uEnv='uEnvLubanCat1HS-test.txt'
				;;
			*)
				echo "Device ID Error !!!"
				BOARD_NAME='LubanCat-RK3562'
				BOARD_DTB='rk3562-lubancat-generic.dtb'
				BOARD_uEnv='uEnvLubanCat.txt'
				;;
		esac
	elif [[ "$2" == "rk3566" ||  "$2" == "rk3568" ]]; then
		case $1 in
			0000)
				BOARD_NAME='LubanCat-1'
				BOARD_DTB='rk3566-lubancat-1.dtb'
				BOARD_uEnv='uEnvLubanCat1.txt'
				;;
			0001)
				BOARD_NAME='LubanCat-1IOF'
				BOARD_DTB='rk3566-lubancat-1io.dtb'
				BOARD_uEnv='uEnvLubanCat1IO.txt'
				;;
			0002)
				BOARD_NAME='LubanCat-1IOB'
				BOARD_DTB='rk3566-lubancat-1io.dtb'
				BOARD_uEnv='uEnvLubanCat1IO.txt'
				;;
			0007)
				BOARD_NAME='LubanCat-1IO-test'
				BOARD_DTB='rk3566-lubancat-1io-test.dtb'
				BOARD_uEnv='uEnvLubanCat1IO-test.txt'
				;;
			0100)
				BOARD_NAME='LubanCat-1N'
				BOARD_DTB='rk3566-lubancat-1n.dtb'
				BOARD_uEnv='uEnvLubanCat1N.txt'
				;;
			0102)
				BOARD_NAME='LubanCat-2IOBI'
				BOARD_DTB='rk3568-lubancat-2io.dtb'
				BOARD_uEnv='uEnvLubanCat2IO.txt'
				;;
			0200)
				BOARD_NAME='LubanCat-0N'
				BOARD_DTB='rk3566-lubancat-0.dtb'
				BOARD_uEnv='uEnvLubanCatZN.txt'
				;;
			0201)
				BOARD_NAME='LubanCat-1H'
				BOARD_DTB='rk3566-lubancat-1h.dtb'
				BOARD_uEnv='uEnvLubanCat1H.txt'
				;;
			0300)
				BOARD_NAME='LubanCat-0W'
				BOARD_DTB='rk3566-lubancat-0.dtb'
				BOARD_uEnv='uEnvLubanCatZW.txt'
				;;
			0304)
				BOARD_NAME='LubanCat-CM4'
				BOARD_DTB='rk3566-lubancat-cm4.dtb'
				BOARD_uEnv='uEnvLubanCatCM4.txt'
				;;
			0400)
				BOARD_NAME='LubanCat-2'
				BOARD_DTB='rk3568-lubancat-2.dtb'
				BOARD_uEnv='uEnvLubanCat2.txt'
				;;
			0402)
				BOARD_NAME='LubanCat-2 v1'
				BOARD_DTB='rk3568-lubancat-2-v1.dtb'
				BOARD_uEnv='uEnvLubanCat2-V1.txt'
				;;
			0403)
				BOARD_NAME='LubanCat-2 v2'
				BOARD_DTB='rk3568-lubancat-2-v2.dtb'
				BOARD_uEnv='uEnvLubanCat2-V2.txt'
				;;
			0404)
				BOARD_NAME='LubanCat-2 v3'
				BOARD_DTB='rk3568-lubancat-2-v3.dtb'
				BOARD_uEnv='uEnvLubanCat2-V3.txt'
				;;
			0500 |\
			0600)
				BOARD_NAME='LubanCat-2N'
				BOARD_DTB='rk3568-lubancat-2n.dtb'
				BOARD_uEnv='uEnvLubanCat2N.txt'
				;;
			0501)
				BOARD_NAME='LubanCat-2N v2'
				BOARD_DTB='rk3568-lubancat-2n-v2.dtb'
				BOARD_uEnv='uEnvLubanCat2N-V2.txt'
				;;
			0502)
				BOARD_NAME='LubanCat-2N v3'
				BOARD_DTB='rk3568-lubancat-2n-v3.dtb'
				BOARD_uEnv='uEnvLubanCat2N-V3.txt'
				;;
			0601)
				BOARD_NAME='LubanCat-2H'
				BOARD_DTB='rk3568-lubancat-2h.dtb'
				BOARD_uEnv='uEnvLubanCat2H.txt'
				;;
			0700)
				BOARD_NAME='LubanCat-2IOF'
				BOARD_DTB='rk3568-lubancat-2io.dtb'
				BOARD_uEnv='uEnvLubanCat2IO.txt'
				;;
			0701)
				BOARD_NAME='LubanCat-2IOB'
				BOARD_DTB='rk3568-lubancat-2io.dtb'
				BOARD_uEnv='uEnvLubanCat2IO.txt'
				;;
			*)
				echo "Device ID Error !!!"
				BOARD_NAME='LubanCat-RK356X'
				BOARD_DTB='rk356x-lubancat-generic.dtb'
				BOARD_uEnv='uEnvLubanCat.txt'
				;;
		esac
	elif [[ "$2" == "rk3576" ]]; then
			case $1 in
			0000)
				BOARD_NAME='LubanCat-3'
				BOARD_DTB='rk3576-lubancat-3.dtb'
				BOARD_uEnv='uEnvLubanCat3.txt'
				;;
			0001)
				BOARD_NAME='LubanCat-3IO'
				BOARD_DTB='rk3576-lubancat-3io.dtb'
				BOARD_uEnv='uEnvLubanCat3IO.txt'
				;;
			0100)
				BOARD_NAME='LubanCat-3 v2'
				BOARD_DTB='rk3576-lubancat-3-v2.dtb'
				BOARD_uEnv='uEnvLubanCat3-V2.txt'
				;;
			*)
				echo "Device ID Error !!!"
				BOARD_NAME='LubanCat-RK3576'
				BOARD_DTB='rk3576-lubancat-generic.dtb'
				BOARD_uEnv='uEnvLubanCat.txt'
				;;
		esac
	elif [[ "$2" == "rk3588" ||  "$2" == "rk3588s" ]]; then
			case $1 in
			0101)
				BOARD_NAME='LubanCat-4'
				BOARD_DTB='rk3588s-lubancat-4.dtb'
				BOARD_uEnv='uEnvLubanCat4.txt'
				;;
			0102)
				BOARD_NAME='LubanCat-4 v1'
				BOARD_DTB='rk3588s-lubancat-4-v1.dtb'
				BOARD_uEnv='uEnvLubanCat4-V1.txt'
				;;
			0201)
				BOARD_NAME='LubanCat-4IOF'
				BOARD_DTB='rk3588s-lubancat-4io.dtb'
				BOARD_uEnv='uEnvLubanCat4IO.txt'
				;;
			0301)
				BOARD_NAME='LubanCat-4IOB'
				BOARD_DTB='rk3588s-lubancat-4io.dtb'
				BOARD_uEnv='uEnvLubanCat4IO.txt'
				;;
			0401)
				BOARD_NAME='LubanCat-5'
				BOARD_DTB='rk3588-lubancat-5.dtb'
				BOARD_uEnv='uEnvLubanCat5.txt'
				;;
			0402)
				BOARD_NAME='LubanCat-5 v2'
				BOARD_DTB='rk3588-lubancat-5-v2.dtb'
				BOARD_uEnv='uEnvLubanCat5-V2.txt'
				;;
			0501)
				BOARD_NAME='LubanCat-5IOF'
				BOARD_DTB='rk3588-lubancat-5io.dtb'
				BOARD_uEnv='uEnvLubanCat5IO.txt'
				;;
			0601)
				BOARD_NAME='LubanCat-5IOB'
				BOARD_DTB='rk3588-lubancat-5io.dtb'
				BOARD_uEnv='uEnvLubanCat5IO.txt'
				;;
			0701)
				BOARD_NAME='LubanCat-5IOBI'
				BOARD_DTB='rk3588-lubancat-5ioi.dtb'
				BOARD_uEnv='uEnvLubanCat5IO.txt'
				;;
			*)
				echo "Device ID Error !!!"
				BOARD_NAME='LubanCat-RK3588'
				BOARD_DTB='rk3588-lubancat-generic.dtb'
				BOARD_uEnv='uEnvLubanCat.txt'
				;;
		esac
	fi

	echo "BOARD_NAME:"$BOARD_NAME
	echo "BOARD_DTB:"$BOARD_DTB
	echo "BOARD_uEnv:"$BOARD_uEnv
}

# voltage_scale
# 1.7578125 1.8v/10bit
# 3.222656250 3.3v/10bit
# 0.439453125 1.8v/12bit
# 0.8056640625 3.3v/12bit
get_index(){

	ADC_RAW=$(cat "$IIO_BASE/in_voltage${1}_raw")
	echo ADC_CH:$1 ADC_RAW:$ADC_RAW
	INDEX=0xff

	# 厂商原行，bc 只会输出 0/1；保留原样，仅抑制 SC2046
	# shellcheck disable=SC2046
	if [ $(echo "$ADC_voltage_scale > 1 "|bc) -eq 1 ] ; then
		declare -a ADC_INDEX=(229 344 460 595 732 858 975 1024)
	else
		declare -a ADC_INDEX=(916 1376 1840 2380 2928 3432 3900 4096)
	fi

	for i in 00 01 02 03 04 05 06 07; do
		if [ $ADC_RAW -lt ${ADC_INDEX[$i]} ]; then
			INDEX=$i
			break
		fi
	done
}

board_id() {
	ADC_voltage_scale=$(cat "$IIO_BASE/in_voltage_scale")
	echo "ADC_voltage_scale:"$ADC_voltage_scale

	SOC_type=$(cut -d, -f 3 "$COMPAT_FILE" | sed 's/\x0//g')
	echo "SOC_type:"$SOC_type

	if [[ "$SOC_type" == "rk3128" ]]; then
		get_index 0; ADC_INDEX_H=$INDEX
		get_index 2; ADC_INDEX_L=$INDEX
	else
		get_index 2; ADC_INDEX_H=$INDEX
		get_index 3; ADC_INDEX_L=$INDEX
	fi

	BOARD_ID=$ADC_INDEX_H$ADC_INDEX_L
	echo "BOARD_ID:"$BOARD_ID
}

board_id
board_info ${BOARD_ID} ${SOC_type}

# ---------------------------------------------------------------------------
# 首次启动：落地选型结果（厂商动作序列，去掉 Debian 专属部分）
# ---------------------------------------------------------------------------
FLAG=$BOOT/.board_init

if [ -e "$FLAG" ]; then
	echo "board-init: $FLAG exists, skip"
	exit 0
fi

if [ ! -d "$BOOT/dtb" ] || [ ! -d "$BOOT/uEnv" ]; then
	echo "board-init: WARN $BOOT/dtb or $BOOT/uEnv missing, retry next boot"
	exit 0
fi

if [ -z "$BOARD_DTB" ] || [ -z "$BOARD_uEnv" ]; then
	echo "board-init: ERROR no dtb/uenv selected for soc=$SOC_type, refuse to touch /boot"
	exit 1
fi

if [ ! -f "$BOOT/dtb/$BOARD_DTB" ]; then
	echo "board-init: ERROR $BOOT/dtb/$BOARD_DTB missing, refuse to switch"
	exit 1
fi

ln -sf "dtb/$BOARD_DTB" "$BOOT/rk-kernel.dtb"
ln -sf "$BOARD_uEnv" "$BOOT/uEnv/uEnv.txt"

mkdir -p "$(dirname "$BOARD_NAME_FILE")"
printf '%s\n' "$BOARD_NAME" > "$BOARD_NAME_FILE"

sync
touch "$FLAG"
sync

echo "board-init: name=$BOARD_NAME dtb=$BOARD_DTB uenv=$BOARD_uEnv"

# shellcheck disable=SC2086
$REBOOT_CMD
